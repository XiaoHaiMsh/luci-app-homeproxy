Import { mkstemp, popen, readfile, rename, writefile } from 'fs';
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

	function fallbackFirstNode() {
		return uci.get_first(config, 'node') || 'nil';
	};

	const main_node = uci.get(config, 'config', 'main_node') || 'nil';
	if (main_node === 'urltest') {
		const mainNodes = reconcileList('config', 'main_urltest_nodes');
		if (!length(mainNodes)) {
			const fallback = fallbackFirstNode();
			uci.set(config, 'config', 'main_node', fallback);
			changed = true;
			log((fallback === 'nil') ?
				'Main URLTest group is empty; disabling the client.' :
				sprintf('Main URLTest group is empty; switching main node to %s.', fallback));
		}
	} else if (main_node !== 'nil' && uci.get(config, main_node) !== 'node') {
		const fallback = fallbackFirstNode();
		uci.set(config, 'config', 'main_node', fallback);
		changed = true;
		log((fallback === 'nil') ?
			'Main node is gone; disabling the client.' :
			sprintf('Main node is gone; switching main node to %s.', fallback));
	}

	const main_udp_node = uci.get(config, 'config', 'main_udp_node') || 'nil';
	if (main_udp_node === 'urltest') {
		const mainUdpNodes = reconcileList('config', 'main_udp_urltest_nodes');
		if (!length(mainUdpNodes)) {
			uci.set(config, 'config', 'main_udp_node', 'same');
			changed = true;
			log('Main UDP URLTest group is empty; falling back to using the main node for UDP.');
		}
	} else if (main_udp_node !== 'nil' && main_udp_node !== 'same' && uci.get(config, main_udp_node) !== 'node') {
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
		} else if (node !== 'main-out' && node !== 'direct-out' && node !== 'reject-out' && uci.get(config, node) !== 'node') {
			uci.set(config, cfg['.name'], 'node', 'main-out');
			changed = true;
			log(sprintf('Proxy Rule "%s" node is gone; falling back to the main node.', label));
		}
	});

	return { changed, removed };
};

/* sing-box-extended FATALs with "x_padding_bytes cannot be disabled" whenever xhttp
 * padding resolves to empty: an explicit "0"/"0-0" disables it, and an absent field
 * decodes to "" which counts as disabled too. So the field must always be present
 * and non-empty on every xhttp transport. Coerce any disabling/empty value to a
 * sane default range instead of leaving it empty/omitted. */
export function xhttpPadding(v) {
	return (isEmpty(v) || v === '0' || v === '0-0') ? '100-1000' : v;
};

/* Parses a DynamicList of "Key: Value" lines (as used by the xhttp_headers
 * field) into a headers object, or null if there's nothing usable. */
export function parseHeaderList(list) {
	if (isEmpty(list))
		return null;

	let headers = {};
	for (let line in list) {
		let pos = index(line, ':');
		if (pos < 0)
			continue;

		let key = trim(substr(line, 0, pos));
		let val = trim(substr(line, pos + 1));
		if (!isEmpty(key))
			headers[key] = val;
	}

	return length(keys(headers)) ? headers : null;
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

/* ---- Async job status files (/var/run/homeproxy/jobs/<name>.json) ----
 * Shared by the rpcd endpoint (luci.homeproxy) and update_core.uc, so the
 * status file format and its atomic-write behaviour can never drift apart. */
const JOBS_DIR = `${RUN_DIR}/jobs`;

function jobEsc(s) {
	return replace(replace('' + (s ?? ''), '\\', '\\\\'), '"', '\\"');
};

export function jobWrite(name, state, stage, message, version) {
	system(`mkdir -p ${shellQuote(JOBS_DIR)}`);

	let fields = [ `"ts":"${time()}"`, `"state":"${jobEsc(state)}"`, `"stage":"${jobEsc(stage)}"` ];
	if (message) push(fields, `"message":"${jobEsc(message)}"`);
	if (version) push(fields, `"version":"${jobEsc(version)}"`);

	atomicWrite(`${JOBS_DIR}/${name}.json`, '{' + join(',', fields) + '}');
};

export function jobRead(name) {
	const raw = readfile(`${JOBS_DIR}/${name}.json`);
	if (!raw)
		return { state: 'idle' };

	try {
		const parsed = json(raw);
		return (type(parsed) === 'object') ? parsed : { state: 'idle' };
	} catch (e) {
		return { state: 'idle' };
	}
};

/* ---- sing-box core update helpers ----
 * Shared by the rpcd endpoint (luci.homeproxy, for core_check_remote) and
 * update_core.uc (the actual background download/install job). */
export const CORE_REPO_OFFICIAL = 'shtorm-7/sing-box-extended';

export function coreDetectArch() {
	const os_rel = readfile('/etc/os-release') || '';
	const m = match(os_rel, /OPENWRT_ARCH="?([^"\n]+)"?/);
	return m ? trim(m[1]) : '';
};

export const CORE_GOARCH_MAP = {
	'x86_64': 'amd64',
	'i386_pentium4': '386', 'i386_pentium-mmx': '386',
	'aarch64_generic': 'arm64', 'aarch64_cortex-a53': 'arm64',
	'aarch64_cortex-a72': 'arm64', 'aarch64_cortex-a76': 'arm64',
	'arm_cortex-a7': 'armv7', 'arm_cortex-a7_neon-vfpv4': 'armv7',
	'arm_cortex-a7_vfpv4': 'armv7', 'arm_cortex-a8_vfpv3': 'armv7',
	'arm_cortex-a9': 'armv7', 'arm_cortex-a9_vfpv3-d16': 'armv7',
	'arm_cortex-a15_neon-vfpv4': 'armv7',
	'arm_arm1176jzf-s_vfp': 'armv6', 'arm_mpcore': 'armv6',
	'arm_xscale': 'armv5', 'arm_arm926ej-s': 'armv5', 'arm_fa526': 'armv5',
	'mipsel_24kc': 'mipsle', 'mipsel_74kc': 'mipsle', 'mipsel_mips32': 'mipsle',
	'mips_24kc': 'mips', 'mips_4kec': 'mips', 'mips_mips32': 'mips',
	'mips64_octeonplus': 'mips64', 'mips64_mips64r2': 'mips64',
	'mips64el_mips64r2': 'mips64le',
	'riscv64_generic': 'riscv64',
	'loongarch64_generic': 'loong64'
};

export function coreGoarch(owrt_arch) {
	if (owrt_arch in CORE_GOARCH_MAP) return CORE_GOARCH_MAP[owrt_arch];
	if (match(owrt_arch, /^aarch64/)) return 'arm64';
	if (match(owrt_arch, /^arm_cortex/)) return 'armv7';
	if (match(owrt_arch, /^mipsel/)) return 'mipsle';
	if (match(owrt_arch, /^mips_/)) return 'mips';
	if (match(owrt_arch, /^mips64el/)) return 'mips64le';
	if (match(owrt_arch, /^mips64/)) return 'mips64';
	if (match(owrt_arch, /^riscv64/)) return 'riscv64';
	if (match(owrt_arch, /^loongarch64/)) return 'loong64';
	if (match(owrt_arch, /^i386/)) return '386';
	return null;
};

export function coreGhTokenHeader() {
	let token = null;
	const fd = popen('uci -q get homeproxy.config.github_token 2>/dev/null');
	if (fd) { token = trim(fd.read('all')); fd.close(); }
	return (token && length(token)) ? `-H ${shellQuote(`Authorization: Bearer ${token}`)}` : '';
};

export function coreFetchJson(url) {
	const token_hdr = coreGhTokenHeader();
	const fd = popen(`/usr/bin/curl -4 -fsSL --connect-timeout 10 --max-time 15 ${token_hdr} ${shellQuote(url)} 2>/dev/null`);
	if (!fd) return null;
	const raw = trim(fd.read('all')); fd.close();
	if (!length(raw)) return null;

	try { return json(raw); } catch (e) { return null; }
};

export function coreFetchRelease(repo, channel) {
	if (channel === 'latest') {
		const data = coreFetchJson(`https://api.github.com/repos/${repo}/releases?per_page=1`);
		return (type(data) === 'array' && length(data)) ? data[0] : null;
	}

	const data = coreFetchJson(`https://api.github.com/repos/${repo}/releases/latest`);
	if (data?.tag_name) return data;

	const list = coreFetchJson(`https://api.github.com/repos/${repo}/releases?per_page=30`);
	if (type(list) === 'array')
		for (let rel in list)
			if (rel?.tag_name && !rel.prerelease && !rel.draft)
				return rel;

	return null;
};

export function coreArchMatches(filename, goarch) {
	return !!match(filename, regexp('(^|[-_.])' + goarch + '($|[-_.])'));
};
