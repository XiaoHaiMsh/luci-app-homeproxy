#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Copyright (C) 2026 ImmortalWrt.org
 */

'use strict';

import { cursor } from 'uci';

const uci = cursor();
const uciconfig = 'homeproxy';
uci.load(uciconfig);

const uciinfra = 'infra',
      ucimigration = 'migration',
      ucimain = 'config',
      ucicontrol = 'control',
      ucinode = 'node',
      ucirouting = 'routing',
      uciroutingnode = 'routing_node',
      uciroutingrule = 'routing_rule',
      ucidns = 'dns',
      ucidnsserver = 'dns_server',
      ucidnsrule = 'dns_rule',
      uciruleset = 'ruleset',
      uciserver = 'server';

const MIGRATION_VERSION = '3';

const OLD_COMMON_PORT =
	'22,53,80,143,443,465,587,853,873,993,995,5222,8080,8443,9418';
const NEW_COMMON_PORT =
	'20,21,22,25,53,80,110,119,123,143,389,443,465,514,563,587,636,853,873,989,990,993,995,1194,1883,3306,3389,5222,5432,5671,5672,5900,6379,6443,6514,8080,8443,8883,9418';

const DEFAULT_DNS_FALLBACK = [
	'https://dns.google/dns-query',
	'https://cloudflare-dns.com/dns-query'
];
const DEFAULT_CHINA_DNS_FALLBACK = [
	'https://doh.pub/dns-query',
	'https://dns.alidns.com/dns-query'
];

function empty(value) {
	return value === null || value === '' || value === 'nil' ||
		((type(value) === 'array' || type(value) === 'object') && length(value) === 0);
}

function list(value) {
	if (empty(value))
		return [];

	return type(value) === 'array' ? value : [value];
}

function unique_list(value) {
	let result = [], seen = {};
	for (let item in list(value)) {
		item = trim(item || '');
		if (empty(item) || seen[item])
			continue;
		seen[item] = true;
		push(result, item);
	}
	return result;
}

function section_type(section) {
	return uci.get(uciconfig, section);
}

function section_exists(section, type_name) {
	return section_type(section) === type_name;
}

function named_section_exists(section) {
	return section_type(section) === uciconfig;
}

function option_defined(section, option) {
	const cfg = uci.get_all(uciconfig, section);
	return type(cfg) === 'object' && (option in cfg);
}

function option_empty(section, option) {
	return empty(uci.get(uciconfig, section, option));
}

function set_if_missing(section, option, value) {
	if (!option_defined(section, option))
		uci.set(uciconfig, section, option, value);
}

function collect_sections(type_name) {
	let sections = [];
	uci.foreach(uciconfig, type_name, (cfg) => {
		if (cfg && cfg['.name'])
			push(sections, cfg['.name']);
	});
	return sections;
}

function first_node() {
	let result = null;
	uci.foreach(uciconfig, ucinode, (cfg) => {
		if (!result && cfg && cfg['.name'])
			result = cfg['.name'];
	});
	return result;
}

function node_exists(id) {
	return !empty(id) && section_exists(id, ucinode);
}

function normalize_node_list(value) {
	let result = [], seen = {};
	for (let id in list(value)) {
		id = trim(id || '');
		if (empty(id) || seen[id])
			continue;
		seen[id] = true;
		if (node_exists(id))
			push(result, id);
	}
	return result;
}

function normalize_default_port_list(value) {
	return replace(trim(value || ''), /[ \t\r\n]+/g, '');
}

function filter_urltest_nodes(section, option) {
	const value = normalize_node_list(uci.get(uciconfig, section, option));
	if (length(value))
		uci.set(uciconfig, section, option, value);
	else if (option_defined(section, option))
		uci.delete(uciconfig, section, option);
	return value;
}

function prune_orphan_urltest_nodes() {
	if (uci.get(uciconfig, ucimain, 'main_node') !== 'urltest' &&
	    option_defined(ucimain, 'main_urltest_nodes'))
		uci.delete(uciconfig, ucimain, 'main_urltest_nodes');

	if (uci.get(uciconfig, ucimain, 'main_udp_node') !== 'urltest' &&
	    option_defined(ucimain, 'main_udp_urltest_nodes'))
		uci.delete(uciconfig, ucimain, 'main_udp_urltest_nodes');
}

const previous_migration_version = uci.get(uciconfig, ucimigration, 'version') || '';
if (previous_migration_version === MIGRATION_VERSION)
	exit(0);

if (!named_section_exists(uciinfra))
	uci.set(uciconfig, uciinfra, uciconfig);
if (!named_section_exists(ucimain))
	uci.set(uciconfig, ucimain, uciconfig);
if (!named_section_exists(ucicontrol))
	uci.set(uciconfig, ucicontrol, uciconfig);
if (!named_section_exists(ucimigration))
	uci.set(uciconfig, ucimigration, uciconfig);

const old_routing_mode = uci.get(uciconfig, ucimain, 'routing_mode') || 'bypass_mainland_china';
const old_proxy_mode = uci.get(uciconfig, ucimain, 'proxy_mode') || 'tun';

if (normalize_default_port_list(uci.get(uciconfig, uciinfra, 'common_port')) === normalize_default_port_list(OLD_COMMON_PORT))
	uci.set(uciconfig, uciinfra, 'common_port', NEW_COMMON_PORT);
else
	set_if_missing(uciinfra, 'common_port', NEW_COMMON_PORT);

set_if_missing(uciinfra, 'mixed_port', '5330');
set_if_missing(uciinfra, 'dns_port', '5333');
set_if_missing(uciinfra, 'dns_redirect', '1');
set_if_missing(uciinfra, 'ntp_server', 'nil');
set_if_missing(uciinfra, 'udp_timeout', '');
set_if_missing(uciinfra, 'tun_name', 'singtun0');
set_if_missing(uciinfra, 'tun_addr4', '172.19.0.1/30');
set_if_missing(uciinfra, 'tun_addr6', 'fdfe:dcba:9876::1/126');
set_if_missing(uciinfra, 'tun_mtu', '9000');

const infra_github_token = uci.get(uciconfig, uciinfra, 'github_token');
if (!empty(infra_github_token) && option_empty(ucimain, 'github_token'))
	uci.set(uciconfig, ucimain, 'github_token', infra_github_token);
if (option_defined(uciinfra, 'github_token'))
	uci.delete(uciconfig, uciinfra, 'github_token');

for (let option in [
	'china_dns_port', 'redirect_port', 'tproxy_port', 'sniff_override',
	'tun_gso', 'table_mark', 'self_mark', 'tproxy_mark', 'tun_mark'
])
	if (option_defined(uciinfra, option))
		uci.delete(uciconfig, uciinfra, option);

uci.foreach(uciconfig, ucinode, (cfg) => {
	if (!empty(cfg.hysteria_revc_window)) {
		if (option_empty(cfg['.name'], 'hysteria_recv_window'))
			uci.set(uciconfig, cfg['.name'], 'hysteria_recv_window', cfg.hysteria_revc_window);
		uci.delete(uciconfig, cfg['.name'], 'hysteria_revc_window');
	}

	for (let option in [
		'override_address', 'override_port',
		'tls_ech_tls_disable_drs', 'tls_ech_enable_pqss', 'wireguard_gso'
	])
		if (option_defined(cfg['.name'], option))
			uci.delete(uciconfig, cfg['.name'], option);
});

let target_main_node = uci.get(uciconfig, ucimain, 'main_node') || 'nil';
let target_main_udp_node = uci.get(uciconfig, ucimain, 'main_udp_node') || 'same';

if (old_routing_mode === 'global')
	uci.set(uciconfig, ucimain, 'routing_mode', 'global');
else
	uci.set(uciconfig, ucimain, 'routing_mode', 'bypass_mainland_china');

if (old_routing_mode === 'custom') {
	target_main_node = 'nil';
	target_main_udp_node = 'same';
} else {
	if (target_main_node !== 'nil' && target_main_node !== 'urltest' && !node_exists(target_main_node))
		target_main_node = first_node() || 'nil';

	if (target_main_node === 'urltest') {
		const main_nodes = filter_urltest_nodes(ucimain, 'main_urltest_nodes');
		if (!length(main_nodes))
			target_main_node = first_node() || 'nil';
	}

	if (target_main_udp_node === 'urltest') {
		const main_udp_nodes = filter_urltest_nodes(ucimain, 'main_udp_urltest_nodes');
		if (!length(main_udp_nodes))
			target_main_udp_node = 'same';
	} else if (target_main_udp_node !== 'nil' && target_main_udp_node !== 'same' && !node_exists(target_main_udp_node)) {
		target_main_udp_node = 'same';
	}
}

uci.set(uciconfig, ucimain, 'main_node', target_main_node || 'nil');
uci.set(uciconfig, ucimain, 'main_udp_node', target_main_udp_node || 'same');

prune_orphan_urltest_nodes();

set_if_missing(ucimain, 'tcpip_stack', 'mixed');
uci.set(uciconfig, ucimain, 'proxy_mode', 'tun');

if (uci.get(uciconfig, ucimain, 'routing_port') === 'all')
	uci.delete(uciconfig, ucimain, 'routing_port');

if (!option_defined(ucimain, 'dns_server_fallback'))
	uci.set(uciconfig, ucimain, 'dns_server_fallback', DEFAULT_DNS_FALLBACK);
if (!option_defined(ucimain, 'china_dns_server_fallback'))
	uci.set(uciconfig, ucimain, 'china_dns_server_fallback', DEFAULT_CHINA_DNS_FALLBACK);
set_if_missing(ucimain, 'dns_fallback_strategy', 'sequential');

const china_dns_server = uci.get(uciconfig, ucimain, 'china_dns_server');
if (type(china_dns_server) === 'array') {
	const first = unique_list(china_dns_server)[0];
	if (!empty(first))
		uci.set(uciconfig, ucimain, 'china_dns_server', first);
} else if (china_dns_server === 'wan_114') {
	uci.set(uciconfig, ucimain, 'china_dns_server', '114.114.114.114');
} else if (!empty(china_dns_server) && match(china_dns_server, /,/)) {
	uci.set(uciconfig, ucimain, 'china_dns_server', split(china_dns_server, ',')[0]);
}

set_if_missing(ucimain, 'dashboard_port', '9096');
set_if_missing(ucimain, 'dashboard_secret', '');
set_if_missing(ucimain, 'ipv6_support', '1');
set_if_missing(ucimain, 'log_level', 'warn');
set_if_missing(uciserver, 'log_level', 'warn');

for (let option in [
	'lan_proxy_mode', 'lan_direct_ipv6_ips', 'lan_proxy_ipv6_ips',
	'lan_global_proxy_ipv6_ips', 'lan_gaming_mode_ipv6_ips',
	'lan_gaming_mode_ipv4_ips', 'lan_gaming_mode_mac_addrs',
	'lan_global_proxy_ipv4_ips', 'lan_global_proxy_mac_addrs',
	'direct_domain_list_checksum', 'proxy_domain_list_checksum'
])
	if (option_defined(ucicontrol, option))
		uci.delete(uciconfig, ucicontrol, option);

set_if_missing(ucicontrol, 'lan_whitelist_mode', '0');

if (!named_section_exists('subscription'))
	uci.set(uciconfig, 'subscription', uciconfig);
set_if_missing('subscription', 'allow_insecure', '1');
set_if_missing('subscription', 'user_agent', 'HomeProxy');

const auto_firewall = uci.get(uciconfig, uciserver, 'auto_firewall');
if (!empty(auto_firewall))
	uci.delete(uciconfig, uciserver, 'auto_firewall');

uci.foreach(uciconfig, uciserver, (cfg) => {
	if (auto_firewall === '1')
		uci.set(uciconfig, cfg['.name'], 'firewall', '1');
	for (let option in ['sniff_override', 'domain_strategy'])
		if (option_defined(cfg['.name'], option))
			uci.delete(uciconfig, cfg['.name'], option);
	});

if (previous_migration_version === '2') {
	for (let section in collect_sections('app_rule')) {
		if (match(section, /^_migration_(ruleset_)?app_rule_/))
			uci.delete(uciconfig, section);
	}
}

for (let type_name in [
	uciroutingnode, uciroutingrule,
	ucidnsserver, ucidnsrule, uciruleset
]) {
	for (let section in collect_sections(type_name))
		uci.delete(uciconfig, section);
}

for (let section in [ucirouting, ucidns, 'experimental'])
	if (named_section_exists(section))
		uci.delete(uciconfig, section);

uci.set(uciconfig, ucimigration, 'crontab', '1');
uci.set(uciconfig, ucimigration, 'version', MIGRATION_VERSION);

if (uci.get(uciconfig, ucimain, 'routing_mode') !== 'global' &&
	uci.get(uciconfig, ucimain, 'routing_mode') !== 'bypass_mainland_china')
	uci.set(uciconfig, ucimain, 'routing_mode', 'bypass_mainland_china');

if (uci.get(uciconfig, ucimain, 'proxy_mode') !== 'tun')
	uci.set(uciconfig, ucimain, 'proxy_mode', 'tun');

if (uci.get(uciconfig, ucimain, 'main_udp_node') === 'urltest') {
	const udp_nodes = normalize_node_list(uci.get(uciconfig, ucimain, 'main_udp_urltest_nodes'));
	if (length(udp_nodes))
		uci.set(uciconfig, ucimain, 'main_udp_urltest_nodes', udp_nodes);
	else
		uci.set(uciconfig, ucimain, 'main_udp_node', 'same');
}

prune_orphan_urltest_nodes();

if (!empty(uci.changes(uciconfig)))
	uci.commit(uciconfig);
