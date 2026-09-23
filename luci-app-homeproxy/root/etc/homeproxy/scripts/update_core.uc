#!/usr/bin/ucode -S

'use strict';

import { access, popen, readfile } from 'fs';

import {
	shellQuote, HP_DIR, RUN_DIR, jobWrite, coreDetectArch,
	coreGoarch, coreFetchRelease, coreArchMatches, CORE_REPO_OFFICIAL
} from 'homeproxy';

const JOB_NAME = 'core_official';

const SINGBOX_BIN     = '/usr/bin/sing-box';
const CORE_REPO       = CORE_REPO_OFFICIAL;

function job_write(state, stage, message, version) {
	jobWrite(JOB_NAME, state, stage, message, version);
}

function fail(stage, message, version) {
	job_write('error', stage, message, version);
	exit(0);
}

function core_cache_paths() {
	let paths = [
		`${HP_DIR}/cache/core_cache.db`,
		`${HP_DIR}/cache/cache.db`,
		`${RUN_DIR}/cache.db`
	];

	for (let run_conf in [ `${RUN_DIR}/sing-box-c.json` ]) {
		if (!access(run_conf)) continue;
		let conf;
		try { conf = json(readfile(run_conf)); } catch (e) { conf = null; }
		const p = conf?.experimental?.cache_file?.path;
		if (p && index(paths, p) < 0)
			push(paths, p);
	}

	return paths;
}

const channel = (ARGV[0] === 'stable') ? 'stable' : 'latest';

const arch = coreDetectArch();
if (!arch)
	fail('preparing', 'could not detect device architecture');

const goarch = coreGoarch(arch);
if (!goarch)
	fail('preparing', `no Go-arch mapping for OpenWrt arch "${arch}"`);

const release = coreFetchRelease(CORE_REPO, channel);
if (!release?.assets)
	fail('preparing', 'could not read release info from GitHub');

const version = replace(release.tag_name, /^v/, '');

let candidates = [];
for (let asset in release.assets) {
	const n = asset?.name || '';
	if (!match(n, /linux/i)) continue;
	if (match(n, /openwrt|alpine|\.apk$|\.deb$|\.rpm$/i)) continue;
	if (!match(n, /\.(tar\.gz|tgz)$/i)) continue;
	if (!coreArchMatches(n, goarch)) continue;
	push(candidates, asset);
}
let chosen = null;
for (let a in candidates)
	if (match(a?.name, /musl/i)) { chosen = a; break; }
if (!chosen) chosen = candidates[0];

if (!chosen)
	fail('preparing', `no linux/${goarch} tarball found in the latest official release`);

job_write('running', 'downloading', null, version);

const dl_url = chosen.browser_download_url;
const tmp_path = `/tmp/sing-box-official.tar.gz`;

const max_tries = 3;
let exit_code = 1;
for (let attempt = 1; attempt <= max_tries; attempt++) {
	exit_code = system(`/usr/bin/curl -4 -fsSL -o ${shellQuote(tmp_path)} -C - --connect-timeout 10 --max-time 30 ${shellQuote(dl_url)} 2>/dev/null`, 60000);
	if (exit_code === 0) break;
}
if (exit_code !== 0) {
	system(`rm -f ${shellQuote(tmp_path)}`);
	fail('downloading', 'download failed', version);
}

job_write('running', 'installing', null, version);

const extract_dir = '/tmp/singbox-core-extract';
system(`rm -rf ${shellQuote(extract_dir)}; mkdir -p ${shellQuote(extract_dir)}`);
const untar = system(`tar -xzf ${shellQuote(tmp_path)} -C ${shellQuote(extract_dir)} 2>/dev/null`, 60000);

let bin_path = null;
if (untar === 0) {
	const fd = popen(`find ${shellQuote(extract_dir)} -type f -name 'sing-box*' ! -name '*.txt' 2>/dev/null | head -n1`);
	if (fd) { bin_path = trim(fd.read('all')); fd.close(); }
}

let ok = false;
if (bin_path && length(bin_path) && access(bin_path)) {

	const version_check = system(`${shellQuote(bin_path)} version -n >/dev/null 2>&1`, 15000);
	if (version_check !== 0) {
		system(`rm -rf ${shellQuote(extract_dir)} ${shellQuote(tmp_path)}`);
		fail('installing', 'downloaded sing-box executable failed validation', version);
	}

	system('/etc/init.d/homeproxy stop >/dev/null 2>&1');
	const new_bin = `${SINGBOX_BIN}.new`;
	system(`rm -f ${shellQuote(new_bin)}; cp -f ${shellQuote(bin_path)} ${shellQuote(new_bin)} && chmod 755 ${shellQuote(new_bin)}`);
	if (access(new_bin) && system(`${shellQuote(new_bin)} version -n >/dev/null 2>&1`, 15000) === 0 &&
		system(`mv -f ${shellQuote(new_bin)} ${shellQuote(SINGBOX_BIN)}`) === 0)
		ok = true;
	else
		system(`rm -f ${shellQuote(new_bin)}`);

	if (ok) {
		for (let p in core_cache_paths())
			system(`rm -f ${shellQuote(p)} 2>/dev/null`);
	}
}

system(`rm -rf ${shellQuote(extract_dir)} ${shellQuote(tmp_path)}`);
system('/etc/init.d/homeproxy start >/dev/null 2>&1');

if (!ok)
	fail('installing', 'installation failed', version);

job_write('success', 'done', null, version);
