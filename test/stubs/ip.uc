'use strict';
// The tables `ip` would print on the imaginary router; see sandbox.uc.
import { neigh4, netifd_dump, dev_ipv4, network_of, MAC, DEVS } from 'sandbox';

const fam = ARGV[0], what = ARGV[1];

function line(s) { printf('%s\n', s); }

if (fam == '-4' && what == 'neigh') {
	for (let n in neigh4())
		line(`${n.ip} dev ${n.dev} lladdr ${n.mac} ${n.state}`);
}
else if (fam == '-6' && what == 'neigh') {
	line(`fe80::1 dev eth0 lladdr ${MAC.hotel_wired_gw} router REACHABLE`);
}
else if (fam == '-4' && what == 'route') {
	let ifaces = filter(netifd_dump(), (i) => i.up && i.l3_device && length(i['ipv4-address']));
	// main table: default routes, then connected subnets
	for (let i in ifaces)
		for (let r in i.route)
			if (r.target == '0.0.0.0' && r.mask == 0)
				line(`default via ${r.nexthop} dev ${i.l3_device} proto static src ${i['ipv4-address'][0].address} metric ${i.metric}`);
	for (let i in ifaces) {
		if (i.l3_device == 'lo') continue;
		let a = i['ipv4-address'][0];
		line(`${network_of(a.address, a.mask)}/${a.mask} dev ${i.l3_device} proto kernel scope link src ${a.address}` + (i.metric ? ` metric ${i.metric}` : ''));
	}
	// Tailscale keeps its routes in table 52
	line('100.100.100.100 dev tailscale0 table 52');
	line('100.64.0.11 dev tailscale0 table 52');
	line('100.64.0.12 dev tailscale0 table 52');
	// the local table: every address, its broadcasts
	for (let dname in keys(DEVS)) {
		for (let a in dev_ipv4(dname)) {
			let net = network_of(a[0], a[1]);
			if (dname == 'lo') {
				line(`local 127.0.0.0/8 dev lo table local proto kernel scope host src 127.0.0.1`);
				line(`local 127.0.0.1 dev lo table local proto kernel scope host src 127.0.0.1`);
				continue;
			}
			if (a[1] < 31) line(`broadcast ${net} dev ${dname} table local proto kernel scope link src ${a[0]}`);
			line(`local ${a[0]} dev ${dname} table local proto kernel scope host src ${a[0]}`);
		}
	}
}
else if (fam == '-6' && what == 'route') {
	for (let d in [ 'eth0', 'br-lan', 'phy0.1-sta0' ]) line(`fe80::/64 dev ${d} proto kernel metric 256`);
	line('local ::1 dev lo table local proto kernel metric 0');
	line('local fe80::9683:c4ff:fe0b:7e80 dev br-lan table local proto kernel metric 0');
	line('ff00::/8 dev br-lan table local metric 256');
}
else if (what == 'rule') {
	line('0:\tfrom all lookup local');
	line('5210:\tfrom all fwmark 0x80000/0xff0000 lookup main');
	line('5230:\tfrom all fwmark 0x80000/0xff0000 lookup default');
	line('5250:\tfrom all fwmark 0x80000/0xff0000 unreachable');
	line('5270:\tfrom all lookup 52');
	line('32766:\tfrom all lookup main');
	if (fam == '-4') line('32767:\tfrom all lookup default');
}
