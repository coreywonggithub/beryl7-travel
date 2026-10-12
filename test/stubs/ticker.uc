'use strict';
// UI sandbox only: keeps the imaginary router's files moving. Started by
// serve.sh in the background; see sandbox.uc for the devices.
//   - a small /sys/class/net and its packet counters. The travel panel reads the
//     Ethernet carrier and the byte counters of the active uplink from there (its
//     "No cable" note and the live speed); LuCI's interface pages read a few
//     bridge-port flags.
//   - the connection count the Overview page shows (bind-mounted over
//     /proc/sys/net/netfilter/nf_conntrack_count by serve-ui.sh)
//   - dnsmasq's lease file, its leases renewed the way clients renew them, so the
//     "remaining time" columns never run out however long the sandbox stays up
import { mkdir, writefile, rename, symlink, stat } from 'fs';
import { DEVS, IFINDEX, counter, packets, bwc_rows } from 'sandbox';

const NET = '/sys/class/net';

function mkdirp(path) {
	let cur = '';
	for (let part in split(path, '/')) {
		if (!part) continue;
		cur += '/' + part;
		if (!stat(cur)) mkdir(cur);
	}
}
function put(path, value) { writefile(path, value + '\n'); }

mkdirp('/sys/class/ieee80211/phy0');
put('/sys/class/ieee80211/phy0/index', '0');
mkdirp('/sys/devices/virtual/net');
mkdirp(NET);

for (let name, d in DEVS) {
	let dir = `/sys/devices/virtual/net/${name}`;
	mkdirp(dir + '/statistics');
	if (!stat(`${NET}/${name}`)) symlink(`../../devices/virtual/net/${name}`, `${NET}/${name}`);
	put(`${dir}/ifindex`, IFINDEX[name]);
	put(`${dir}/iflink`, IFINDEX[name]);
	put(`${dir}/type`, d.type);
	put(`${dir}/mtu`, d.mtu);
	put(`${dir}/tx_queue_len`, 1000);
	put(`${dir}/carrier`, d.carrier ? 1 : 0);
	put(`${dir}/carrier_changes`, 2);
	put(`${dir}/carrier_up_count`, 1);
	put(`${dir}/carrier_down_count`, 1);
	put(`${dir}/operstate`, (d.kind == 'loopback' || d.kind == 'tun') ? 'unknown' : (d.carrier ? 'up' : 'down'));
	put(`${dir}/flags`, (d.kind == 'loopback') ? '0x9' : '0x1003');
	if (d.mac) put(`${dir}/address`, d.mac);
	if (d.speed) { put(`${dir}/speed`, d.speed); put(`${dir}/duplex`, d.duplex); }
	put(`${dir}/uevent`, 'DEVTYPE=' + ((d.kind == 'bridge') ? 'bridge' : ((d.kind == 'wireless') ? 'wlan' : 'ethernet')) + '\nINTERFACE=' + name + '\nIFINDEX=' + IFINDEX[name]);
	if (d.kind == 'wireless' && !stat(dir + '/phy80211')) symlink('/sys/class/ieee80211/phy0', dir + '/phy80211');
	if (d.kind == 'bridge') {
		mkdirp(dir + '/bridge');
		put(dir + '/bridge/bridge_id', '8000.' + replace(d.mac, ':', ''));
		put(dir + '/bridge/stp_state', 0);
		for (let port in d.ports) mkdirp(`${dir}/brif/${port}`);
	}
	if (d.master && !stat(dir + '/master')) symlink(`../${d.master}`, dir + '/master');
}

// dnsmasq lease file: 12 h leases that clients renew half way through, each on its own clock
const HOSTS = [
	[ 'da:3f:6a:15:9c:02', '172.31.77.101', 'iPhone', 5000 ],
	[ '4a:8e:27:b1:03:6d', '172.31.77.102', 'MacBook-Air', 15000 ],
	[ 'ce:52:81:94:e7:1b', '172.31.77.103', 'iPad', 1000 ],
	[ 'f0:27:2d:5a:44:e9', '172.31.77.104', 'Kindle-Paperwhite', 9000 ],
	[ 'f4:f5:d8:20:b7:6c', '172.31.77.105', 'Chromecast', 18000 ]	// asleep, but its lease is still good
];
function write_leases(t) {
	let out = '';
	for (let h in HOSTS) {
		let renewed = t - ((t + h[3]) % 21600);		// last renewal
		out += sprintf('%d %s %s %s %s\n', renewed + 43200, h[0], h[1], h[2], (h[2] == 'Chromecast') ? '*' : '01:' + h[0]);
	}
	writefile('/tmp/.dhcp.leases.new', out);		// replaced whole, so a reader never sees half a file
	rename('/tmp/.dhcp.leases.new', '/tmp/dhcp.leases');
}

// counters: the same functions the ubus stubs use, so every page agrees
for (;;) {
	let t = time();
	for (let name in keys(DEVS)) {
		let dir = `/sys/devices/virtual/net/${name}/statistics`;
		put(`${dir}/rx_bytes`, counter(name, 0, t));
		put(`${dir}/tx_bytes`, counter(name, 1, t));
		put(`${dir}/rx_packets`, packets(name, 0, t));
		put(`${dir}/tx_packets`, packets(name, 1, t));
		for (let f in [ 'rx_errors', 'tx_errors', 'rx_dropped', 'tx_dropped', 'collisions' ]) put(`${dir}/${f}`, 0);
		put(`${dir}/multicast`, (DEVS[name].kind == 'loopback') ? 0 : int(counter(name, 0, t) / 60000));
	}
	// the connection count the Overview page reads (serve-ui.sh bind-mounts this
	// file over /proc/sys/net/netfilter/nf_conntrack_count)
	let c = bwc_rows('-c')[319];
	writefile('/tmp/.nf_conntrack_count', (c[1] + c[2] + c[3]) + '\n');
	write_leases(t);
	sleep(2000);
}
