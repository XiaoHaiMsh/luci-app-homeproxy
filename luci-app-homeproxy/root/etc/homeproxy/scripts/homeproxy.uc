
import { mkstemp, popen, rename, writefile } from 'fs';
import { urldecode_params } from 'luci.http';

export const HP_DIR = '/etc/homeproxy';
export const RUN_DIR = '/var/run/homeproxy';

export function shellQuote(s) {
	return `'${replace(s, "'", "'\\''")}'`;
};

export function isBinary(str) {
	for (let off = 0, byte = ord(str); off < length(str); byte = ord(str, ++off))
		if (byte <= 8 || (byte >= 14 && byte <= 31))
			return true;

	return false;
};

export function executeCommand(...args) {
	let outfd = mkstemp();
	let errfd = mkstemp();

	const exitcode = system(`${join(' ', args)} >&${outfd.fileno()} 2>&${errfd.fileno()}`);

	outfd.seek(0);
	errfd.seek(0);

	const stdout = outfd.read(1024 * 512) ?? '';
	const stderr = errfd.read(1024 * 512) ?? '';

	outfd.close();
	errfd.close();

	const binary = isBinary(stdout);

	return {
		command: join(' ', args),
		stdout: binary ? null : stdout,
		stderr,
		exitcode,
		binary
	};
};

export function getTime(epoch) {
	const local_time = localtime(epoch);
	return replace(replace(sprintf(
		'%d-%2d-%2d@%2d:%2d:%2d',
		local_time.year,
		local_time.mon,
		local_time.mday,
		local_time.hour,
		local_time.min,
		local_time.sec
	), ' ', '0'), '@', ' ');

};

export function curlGET(url, ua, proxyUrl) {
	if (!url || type(url) !== 'string')
		return null;

	if (!ua)
		ua = 'v2rayNG/2.3.2';

	const maxSize = 4 * 1024 * 1024;
	const proxyArg = proxyUrl ? `--proxy ${shellQuote(proxyUrl)} ` : '';

	const outfd = popen(
		`/usr/bin/curl -fsSL --compressed --retry 3 --retry-all-errors --retry-delay 1 ` +
		`--connect-timeout 10 --max-time 60 ` +
		`--max-filesize ${maxSize} ${proxyArg}-A ${shellQuote(ua)} ${shellQuote(url)} ` +
		`2>/dev/null`
	);
	if (!outfd)
		return null;

	let chunks = [], total = 0, oversized = false;
	while (true) {
		const chunk = outfd.read(64 * 1024);
		if (chunk === null || chunk === '')
			break;
		total += length(chunk);
		if (total > maxSize) {
			oversized = true;
			break;
		}
		push(chunks, chunk);
	}
	const exitcode = outfd.close();
	const output = join('', chunks);

	if (exitcode !== 0 || oversized || isBinary(output))
		return null;

	return trim(output);
};

export function isEmpty(res) {
	return !res || res === 'nil' || (type(res) in ['array', 'object'] && length(res) === 0);
};

export function normalizeList(value) {
	if (isEmpty(value))
		return [];
	return (type(value) === 'array') ? value : [value];
};

export function createNodeLabelRegistry() {
	return {
		'direct-out': true,
		'block-out': true,
		'main-out': true,
		'main-udp-out': true
	};
};

export function reserveUniqueLabel(used, label, fallback) {
	let base = trim(label || '') || fallback;
	let candidate = base;
	let suffix = 2;

	while (used[candidate])
		candidate = `${base} (${suffix++})`;
	used[candidate] = true;

	return candidate;
};

export function synchronizeNodeLabels(uci, config, include) {
	const used = {};
	let changed = 0;

	uci.foreach(config, 'node', (section) => {
		if (type(include) === 'function' && !include(section)) {
			used[trim(section.label || '') || section['.name']] = true;
			return;
		}

		const label = reserveUniqueLabel(used, section.label, section['.name']);
		if (section.label !== label) {
			uci.set(config, section['.name'], 'label', label);
			changed++;
		}
	});

	return { changed, used };
};

export function filterExistingNodes(uci, config, value, onRemove) {
	let nodes = normalizeList(value);
	let result = [], seen = {};

	for (let node in nodes) {
		if (isEmpty(node) || seen[node])
			continue;
		seen[node] = true;

		if (uci.get(config, node) !== 'node') {
			if (type(onRemove) === 'function')
				onRemove(node);
			continue;
		}

		push(result, node);
	}

	return result;
};

export function reconcileUrltestNodes(uci, config, logger) {
	let changed = false, removed = 0;

	function log(message) {
		if (type(logger) === 'function')
			logger(message);
	};

	const is_valid_node = (id) => uci.get(config, id) === 'node';

	/* A provider only counts as a usable group member when it is enabled,
	 * has a recognised type and carries the source it needs (path for local,
	 * url for remote) - the same gate the config generator applies. */
	const is_valid_provider = (id) => {
		if (uci.get(config, id) !== 'provider')
			return false;
		const type = uci.get(config, id, 'type');
		if (isEmpty(type) || !(type in ['local', 'remote']))
			return false;
		if (uci.get(config, id, 'enabled') === '0')
			return false;
		return (type === 'local') ? !isEmpty(uci.get(config, id, 'path')) : !isEmpty(uci.get(config, id, 'url'));
	};

	function reconcileList(section, option) {
		const current = uci.get(config, section, option);
		const normalized = normalizeList(current);
		const available = filterExistingNodes(uci, config, normalized, (node) => {
			removed++;
			log(sprintf('Node %s is gone, removing it from %s.%s.', node, section, option));
		});

		if (sprintf('%J', normalized) !== sprintf('%J', available)) {
			if (length(available))
				uci.set(config, section, option, available);
			else
				uci.delete(config, section, option);
			changed = true;
		}

		return available;
	};

	/* "URLTest nodes" is a single merged picker holding both node ids and
	 * provider ids, so an entry is kept as long as it still resolves to
	 * either one. */
	function reconcileMixedList(section, option) {
		const current = uci.get(config, section, option);
		const normalized = normalizeList(current);
		const available = [];
		for (let id in normalized) {
			if (is_valid_node(id) || is_valid_provider(id))
				push(available, id);
			else {
				removed++;
				log(sprintf('Node/provider %s is gone, removing it from %s.%s.', id, section, option));
			}
		}

		if (sprintf('%J', normalized) !== sprintf('%J', available)) {
			if (length(available))
				uci.set(config, section, option, available);
			else
				uci.delete(config, section, option);
			changed = true;
		}

		return available;
	};

	function first_valid_provider() {
		let result = null;
		uci.foreach(config, 'provider', (cfg) => {
			if (!result && is_valid_provider(cfg['.name']))
				result = cfg['.name'];
		});
		return result;
	};

	function fallbackFirstTarget() {
		return uci.get_first(config, 'node') || first_valid_provider() || 'nil';
	};

	const main_node = uci.get(config, 'config', 'main_node') || 'nil';
	if (main_node === 'urltest') {
		const mainNodes = reconcileMixedList('config', 'main_urltest_nodes');
		if (!length(mainNodes)) {
			const fallback = fallbackFirstTarget();
			uci.set(config, 'config', 'main_node', fallback);
			changed = true;
			log((fallback === 'nil') ?
				'Main URLTest group is empty; disabling the client.' :
				sprintf('Main URLTest group is empty; switching main node to %s.', fallback));
		}
	} else if (main_node !== 'nil' && !is_valid_node(main_node) && !is_valid_provider(main_node)) {
		const fallback = fallbackFirstTarget();
		uci.set(config, 'config', 'main_node', fallback);
		changed = true;
		log((fallback === 'nil') ?
			'Main node is gone; disabling the client.' :
			sprintf('Main node is gone; switching main node to %s.', fallback));
	}

	const main_udp_node = uci.get(config, 'config', 'main_udp_node') || 'nil';
	if (main_udp_node === 'urltest') {
		const mainUdpNodes = reconcileMixedList('config', 'main_udp_urltest_nodes');
		if (!length(mainUdpNodes)) {
			uci.set(config, 'config', 'main_udp_node', 'same');
			changed = true;
			log('Main UDP URLTest group is empty; falling back to using the main node for UDP.');
		}
	} else if (main_udp_node !== 'nil' && main_udp_node !== 'same' && !is_valid_node(main_udp_node) && !is_valid_provider(main_udp_node)) {
		uci.set(config, 'config', 'main_udp_node', 'same');
		changed = true;
		log('Main UDP node is gone; falling back to using the main node for UDP.');
	}

	uci.foreach(config, 'app_rule', (cfg) => {
		const label = trim(cfg.custom_service_name || '') || cfg.source || cfg['.name'];
		const node = cfg.node || 'main-out';

		if (node === 'urltest') {
			const ruleNodes = reconcileList(cfg['.name'], 'urltest_nodes');
			if (!length(ruleNodes)) {
				uci.set(config, cfg['.name'], 'node', 'main-out');
				changed = true;
				log(sprintf('Proxy Rule "%s" URLTest group is empty; falling back to the main node.', label));
			}
		} else if (node !== 'main-out' && node !== 'direct-out' && node !== 'reject-out' && uci.get(config, node) !== 'node' && !is_valid_provider(node)) {
			uci.set(config, cfg['.name'], 'node', 'main-out');
			changed = true;
			log(sprintf('Proxy Rule "%s" node is gone; falling back to the main node.', label));
		}
	});

	return { changed, removed };
};

export function strToBool(str) {
	return (str === '1') || null;
};

export function strToInt(str) {
	return !isEmpty(str) ? (int(str) || null) : null;
};

export function strToTime(str) {
	return !isEmpty(str) ? (str + 's') : null;
};

export function atomicWrite(path, content) {
	const tmp = `${path}.tmp`;
	if (writefile(tmp, content) === null)
		return false;
	if (!rename(tmp, path)) {
		system(`rm -f ${shellQuote(tmp)}`);
		return false;
	}
	return true;
};

export function removeBlankAttrs(res) {
	let content;

	if (type(res) === 'object') {
		content = {};
		map(keys(res), (k) => {
			if (type(res[k]) in ['array', 'object'])
				content[k] = removeBlankAttrs(res[k]);
			else if (res[k] !== null && res[k] !== '')
				content[k] = res[k];
		});
	} else if (type(res) === 'array') {
		content = [];
		map(res, (k, i) => {
			if (type(k) in ['array', 'object'])
				push(content, removeBlankAttrs(k));
			else if (k !== null && k !== '')
				push(content, k);
		});
	} else
		return res;

	return content;
};

export function validation(datatype, data) {
	if (!datatype || !data)
		return null;

	const ret = system(`/sbin/validate_data ${shellQuote(datatype)} ${shellQuote(data)} 2>/dev/null`);
	return (ret === 0);
};

export function decodeBase64Str(str) {
	if (isEmpty(str))
		return null;

	str = trim(str);
	str = replace(str, '_', '/');
	str = replace(str, '-', '+');

	const padding = length(str) % 4;
	if (padding)
		str = str + substr('====', padding);

	return b64dec(str);
};

export function parseURL(url) {
	if (type(url) !== 'string')
		return null;

	const services = {
		http: '80',
		https: '443'
	};

	const objurl = {};

	objurl.href = url;

	url = replace(url, /#(.+)$/, (_, val) => {
		objurl.hash = val;
		return '';
	});

	url = replace(url, /^(\w[A-Za-z0-9\+\-\.]+):/, (_, val) => {
		objurl.protocol = val;
		return '';
	});

	url = replace(url, /\?(.+)/, (_, val) => {
		objurl.search = val;
		objurl.searchParams = urldecode_params(val);
		return '';
	});

	url = replace(url, /^\/\/([^\/]+)/, (_, val) => {
		val = replace(val, /^([^@]+)@/, (_, val) => {
			objurl.userinfo = val;
			return '';
		});

		val = replace(val, /:(\d+)$/, (_, val) => {
			objurl.port = val;
			return '';
		});

		if (validation('ip4addr', val) ||
		    validation('ip6addr', replace(val, /\[|\]/g, '')) ||
		    validation('hostname', val))
			objurl.hostname = val;

		return '';
	});

	objurl.pathname = url || '/';

	if (!objurl.protocol || !objurl.hostname)
		return null;

	if (objurl.userinfo) {
		objurl.userinfo = replace(objurl.userinfo, /:(.+)$/, (_, val) => {
			objurl.password = val;
			return '';
		});

		if (match(objurl.userinfo, /^[A-Za-z0-9\+\-\_\.]+$/)) {
			objurl.username = objurl.userinfo;
			delete objurl.userinfo;
		} else {
			delete objurl.userinfo;
			delete objurl.password;
		}
	};

	if (!objurl.port)
		objurl.port = services[objurl.protocol];

	objurl.host = objurl.hostname + (objurl.port ? `:${objurl.port}` : '');
	objurl.origin = `${objurl.protocol}://${objurl.host}`;

	return objurl;
};
