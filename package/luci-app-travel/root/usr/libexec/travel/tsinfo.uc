'use strict';
// Tailscale facts for the shell scripts.
//   tsinfo.uc state          -> BackendState (Running, NeedsLogin, ...)
//   tsinfo.uc online <ip>    -> true | false  (is that peer online)
//   tsinfo.uc exitnode       -> the active exit node's 100.x address, or nothing
import { popen } from 'fs';

let st = {};
let p = popen('tailscale status --json 2>/dev/null', 'r');
if (p) {
	try { st = json(p.read('all') || '{}') ?? {}; }
	catch (e) { st = {}; }
	p.close();
}

let cmd = ARGV[0];
if (cmd == 'state') {
	print(st.BackendState ?? 'NoState', '\n');
}
else if (cmd == 'online') {
	let found = false;
	for (let k, peer in st.Peer ?? {})
		if (index(peer.TailscaleIPs ?? [], ARGV[1]) >= 0)
			found = !!peer.Online;
	print(found ? 'true' : 'false', '\n');
}
else if (cmd == 'exitnode') {
	for (let k, peer in st.Peer ?? {})
		if (peer.ExitNode)
			print((peer.TailscaleIPs ?? [])[0] ?? '', '\n');
}
