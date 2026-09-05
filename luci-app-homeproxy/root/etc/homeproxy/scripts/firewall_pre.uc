#!/usr/bin/ucode -S

'use strict';

import { writefile } from 'fs';
import { cursor } from 'uci';
import { isEmpty, RUN_DIR } from 'homeproxy';

const cfgname = 'homeproxy';
const uci = cursor();
uci.load(cfgname);

const main_node = uci.get(cfgname, 'config', 'main_node') || 'nil',
      proxy_mode = uci.get(cfgname, 'config', 'proxy_mode') || 'tun';

const outbound_node = main_node;
const server_enabled = uci.get(cfgname, 'server', 'enabled');

let forward = [],
    input = [];

if (server_enabled === '1') {
	uci.foreach(cfgname, 'server', (s) => {
		if (s.enabled !== '1' || s.firewall !== '1')
			return;

		let proto = s.network || '{ tcp, udp }';
		push(input, `meta l4proto ${proto} th dport ${s.port} counter accept comment "!${cfgname}: accept server ${s['.name']}"`);
	});
}

writefile(RUN_DIR + '/fw4_forward.nft', isEmpty(forward) ? '' : (join('\n', forward) + '\n'));

writefile(RUN_DIR + '/fw4_input.nft', isEmpty(input) ? '' : (join('\n', input) + '\n'));
