'use strict';
// Shared fake state for the UI sandbox (test/serve-ui.sh).
//
// The sandbox is an x86-64 OpenWrt userland with no netifd, no procd, no logd
// and no Wi-Fi, so LuCI's status and network pages have nothing to ask. The
// rpcd stubs (test/stubs/rpcd-*), the stand-in tools (ip, nlbw, nft, dmesg), the
// ticker that keeps a fake /sys moving and a small hook in rpcd's own "luci"
// plugin all print slices of THIS one description, so every page tells the
// same story:
//
//   a Beryl 7 on a hotel desk. Ethernet from the hotel into eth0 (wan), the
//   hotel's own Wi-Fi joined on the 5 GHz radio (trm_wwan on phy0.1-sta0),
//   your Wi-Fi "Beryl7" on both radios, five of your own devices around it.
//
// What is configured (interfaces, radios, SSIDs) is read from UCI, so it
// follows /etc/config/*; what is happening (addresses, signal, traffic) is
// written down here. Installed as /usr/share/ucode/sandbox.uc.

import { readfile, stat, stdin } from 'fs';
import { cursor } from 'uci';
import { sin, cos, pow } from 'math';

// ---- time ------------------------------------------------------------------
// serve.sh touches this file when the sandbox starts; the imaginary router
// had already been up for a day and a bit by then.
const MARK = '/tmp/.sandbox-start';
const T0 = stat(MARK)?.mtime ?? time();
const BOOT_OFFSET = 1 * 86400 + 7 * 3600 + 21 * 60 + 9;

function elapsed() { return time() - T0; }
function uptime() { return BOOT_OFFSET + elapsed(); }
function boot_epoch() { return T0 - BOOT_OFFSET; }

// ---- rpcd plumbing ----------------------------------------------------------
// serve({ method: { args: { name: 'str' }, call: (args) => reply } })
function serve(methods) {
	let cmd = ARGV[0];
	if (cmd == 'list') {
		let l = {};
		for (let name, m in methods)
			l[name] = m.args ?? {};
		printf('%J\n', l);
	}
	else if (cmd == 'call') {
		let m = methods[ARGV[1]];
		let args = {};
		try { args = json(stdin.read('all') || '{}') ?? {}; } catch (e) { }
		printf('%J\n', m ? m.call(args) : {});
	}
}

// ---- helpers -----------------------------------------------------------------
function uci_sections(cfg, type) {
	let out = [];
	cursor().foreach(cfg, type, (s) => push(out, s));
	return out;
}
function as_list(v) { return (v == null) ? [] : (type(v) == 'array' ? v : split(v, /[ \t]+/)); }
function ip2int(ip) {
	let p = split(ip, '.');
	return ((+p[0] * 256 + +p[1]) * 256 + +p[2]) * 256 + +p[3];
}
function int2ip(n) {
	return sprintf('%d.%d.%d.%d', (n / 16777216) & 255, (n / 65536) & 255, (n / 256) & 255, n & 255);
}
function span_of(bits) {			// how many addresses a /bits holds
	let size = 1;
	for (let i = bits; i < 32; i++) size *= 2;
	return size;
}
function bits2mask(bits) { return int2ip(4294967296 - span_of(bits)); }
function mask2bits(mask) {
	let n = 4294967296 - ip2int(mask), bits = 32;
	while (n > 1) { n /= 2; bits--; }
	return bits;
}
function network_of(ip, bits) {
	let n = ip2int(ip), s = span_of(bits);
	return int2ip(n - n % s);
}
function broadcast_of(ip, bits) { return int2ip(ip2int(network_of(ip, bits)) + span_of(bits) - 1); }
function bridge_id(mac) { return '8000.' + replace(mac, ':', ''); }

// ---- the imaginary place ---------------------------------------------------------
const MAC = {
	lan: '94:83:c4:0b:7e:80',
	wan: '94:83:c4:0b:7e:81',
	ap24: '94:83:c4:0b:7e:82',
	ap5: '94:83:c4:0b:7e:83',
	sta5: '94:83:c4:0b:7e:84',
	hotel_wired_gw: '00:1b:0d:6c:9a:01',
	hotel_wifi_gw: 'c8:7f:54:3a:9d:40',
	hotel_ap: 'c8:7f:54:3a:9d:41'
};

// what the two hotel networks handed out
const WAN = { ip: '192.168.100.23', bits: 24, gw: '192.168.100.1', dns: [ '192.168.100.1' ], search: 'hotel.lan', lease: 86400 };
const WWAN = { ip: '10.20.30.145', bits: 22, gw: '10.20.28.1', dns: [ '10.20.28.1', '8.8.8.8' ], search: 'guest.hotel.lan', lease: 3600 };
const TS_IP = '100.64.0.2';

// seconds each interface has been up: fixed for the uplinks (they came up
// when you plugged in), since boot for the rest
function iface_uptime(name) {
	switch (name) {
	case 'wan': case 'wan6': return 8040 + elapsed();	// cable in 2 h 14 min ago
	case 'trm_wwan': return 2820 + elapsed();		// hotel Wi-Fi joined 47 min ago
	case 'tailscale': return uptime() - 31;
	case 'loopback': return uptime() - 14;
	default: return uptime() - 19;
	}
}

// devices in the house. rx/tx = [ rate kbit/s, MHz, MCS, streams ] as the
// access point sees them; age = seconds already connected when the sandbox started
const CLIENTS = [
	{ name: 'iPhone', mac: 'da:3f:6a:15:9c:02', ip: '172.31.77.101', ap: 'phy0.1-ap0', signal: -47, rx: [ 1441100, 80, 11, 2 ], tx: [ 1201000, 80, 11, 2 ], age: 5310, gen: 'he' },
	{ name: 'MacBook-Air', mac: '4a:8e:27:b1:03:6d', ip: '172.31.77.102', ap: 'phy0.1-ap0', signal: -54, rx: [ 1201000, 80, 11, 2 ], tx: [ 960800, 80, 9, 2 ], age: 21050, gen: 'he' },
	{ name: 'iPad', mac: 'ce:52:81:94:e7:1b', ip: '172.31.77.103', ap: 'phy0.1-ap0', signal: -60, rx: [ 866700, 80, 9, 2 ], tx: [ 720600, 80, 8, 2 ], age: 3620, gen: 'he' },
	{ name: 'Kindle-Paperwhite', mac: 'f0:27:2d:5a:44:e9', ip: '172.31.77.104', ap: 'phy0.0-ap0', signal: -66, rx: [ 144400, 20, 15, 2 ], tx: [ 130000, 20, 14, 2 ], age: 88400, gen: 'ht' },
	{ name: 'Chromecast', mac: 'f4:f5:d8:20:b7:6c', ip: '172.31.77.105', ap: null }	// asleep: has a lease, is not associated
];
function clients_on(ifname) { return filter(CLIENTS, (c) => c.ap == ifname); }

// ---- radios ---------------------------------------------------------------------
const CHAN_2G = [ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 ];
const CHAN_5G = [ 36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144, 149, 153, 157, 161, 165 ];
const RADIO = {
	'2g': {
		hwmodes: [ 'b', 'g', 'n', 'ax', 'be' ], hwtext: 'bgnaxbe',
		htmodes: [ 'HT20', 'HT40', 'HE20', 'HE40', 'EHT20', 'EHT40' ],
		noise: -93, txpower: 20, maxpower: 20
	},
	'5g': {
		hwmodes: [ 'a', 'n', 'ac', 'ax', 'be' ], hwtext: 'nacaxbe',
		htmodes: [ 'HT20', 'HT40', 'VHT20', 'VHT40', 'VHT80', 'VHT160', 'HE20', 'HE40', 'HE80', 'HE160', 'EHT20', 'EHT40', 'EHT80', 'EHT160' ],
		noise: -95, txpower: 23, maxpower: 23
	}
};
function chan2freq(band, ch) { return (band == '2g') ? 2407 + 5 * ch : 5000 + 5 * ch; }

// what the 5 GHz radio sees of the hotel's Wi-Fi (the uplink)
const UPLINK = { bssid: MAC.hotel_ap, channel: 36, signal: -58, noise: -95, rate_rx: 866700 };

// ---- devices (what the kernel would list) -----------------------------------------
// bytes per second, long-run average, as seen by the device: [ rx, tx ]
const TRAFFIC = {
	lo: [ 3000, 3000 ],
	eth0: [ 420000, 55000 ],
	eth1: [ 60000, 210000 ],
	'br-lan': [ 150000, 470000 ],
	'phy0.0-ap0': [ 18000, 72000 ],
	'phy0.1-ap0': [ 92000, 380000 ],
	'phy0.1-sta0': [ 6000, 2500 ],
	tailscale0: [ 30000, 8000 ]
};
const IFINDEX = { lo: 1, eth0: 2, eth1: 3, 'br-lan': 4, 'phy0.0-ap0': 5, 'phy0.1-ap0': 6, 'phy0.1-sta0': 7, tailscale0: 8 };

// A smooth wiggle on the rate makes the graphs move. The counter is the
// integral of  avg * (1 + sum a_i sin(w_i t + p_i))  and therefore stays
// monotonic, the same counter for every page that shows it.
const WIG = [ [ 0.40, 110.0, 0.0 ], [ 0.27, 37.0, 1.3 ], [ 0.15, 11.0, 2.1 ], [ 0.10, 4.3, 0.7 ] ];
function seed_of(name, dir) {
	let h = dir;
	for (let i = 0; i < length(name); i++) h = (h * 31 + ord(name, i)) % 1000;
	return h / 1000.0 * 6.28318;
}
function wobble(name, dir, t) {			// integral of the sine terms, in seconds
	let s = 0.0, p0 = seed_of(name, dir);
	for (let k in WIG) {
		let w = 6.28318 / k[1];
		s -= k[0] / w * cos(w * t + k[2] + p0);
	}
	return s;
}
function counter(name, dir, t) {		// dir 0 = rx, 1 = tx; bytes
	let avg = (TRAFFIC[name] ?? [ 0, 0 ])[dir];
	return int(avg * (t - boot_epoch()) + avg * wobble(name, dir, t));
}
function packets(name, dir, t) {
	return int(counter(name, dir, t) / (dir ? 420 : 950));
}

const DEVS = {
	lo:            { type: 772, kind: 'loopback', mac: '00:00:00:00:00:00', mtu: 65536, carrier: true },
	eth0:          { type: 1, kind: 'ethernet', mac: MAC.wan, mtu: 1500, carrier: true, speed: 1000, duplex: 'full' },
	eth1:          { type: 1, kind: 'ethernet', mac: MAC.lan, mtu: 1500, carrier: true, speed: 2500, duplex: 'full', master: 'br-lan' },
	'br-lan':      { type: 1, kind: 'bridge', mac: MAC.lan, mtu: 1500, carrier: true, ports: [ 'eth1', 'phy0.0-ap0', 'phy0.1-ap0' ] },
	'phy0.0-ap0':  { type: 1, kind: 'wireless', mac: MAC.ap24, mtu: 1500, carrier: true, master: 'br-lan' },
	'phy0.1-ap0':  { type: 1, kind: 'wireless', mac: MAC.ap5, mtu: 1500, carrier: true, master: 'br-lan' },
	'phy0.1-sta0': { type: 1, kind: 'wireless', mac: MAC.sta5, mtu: 1500, carrier: true },
	tailscale0:    { type: 65534, kind: 'tun', mac: null, mtu: 1280, carrier: true }
};

// addresses on a device: from UCI for the LAN, from what the hotel handed out
// for the two uplinks
function lan_addrs() {
	let out = [], u = cursor();
	for (let a in as_list(u.get('network', 'lan', 'ipaddr'))) {
		let m = match(a, /^([0-9.]+)\/([0-9]+)$/);
		if (m) push(out, [ m[1], +m[2] ]);
		else if (u.get('network', 'lan', 'netmask'))
			push(out, [ a, mask2bits(u.get('network', 'lan', 'netmask')) ]);
	}
	return length(out) ? out : [ [ '172.31.77.1', 24 ] ];
}
function dev_ipv4(name) {
	switch (name) {
	case 'lo': return [ [ '127.0.0.1', 8 ] ];
	case 'eth0': return [ [ WAN.ip, WAN.bits ] ];
	case 'phy0.1-sta0': return [ [ WWAN.ip, WWAN.bits ] ];
	case 'tailscale0': return [ [ TS_IP, 32 ] ];
	case 'br-lan': return lan_addrs();
	}
	return [];
}

// ---- Wi-Fi layout, from /etc/config/wireless ------------------------------------------------
// Names follow OpenWrt 25.12's multi-radio mac80211: one wiphy, phy0.<radio>-apN
// and phy0.<radio>-staN. A disabled wifi-iface has a section but no device.
function wifi_layout() {
	let radios = {};
	for (let s in uci_sections('wireless', 'wifi-device'))
		radios[s['.name']] = { name: s['.name'], conf: s, idx: +(s.radio ?? 0), band: s.band ?? '5g', ifaces: [], n: { ap: 0, sta: 0 } };
	for (let s in uci_sections('wireless', 'wifi-iface')) {
		let r = radios[s.device];
		if (!r) continue;
		let mode = s.mode ?? 'ap';
		let e = { section: s['.name'], conf: s, mode, radio: r.name, band: r.band };
		// only one station per radio is ever up
		if (s.disabled != '1' && (mode == 'ap' || (mode == 'sta' && r.n.sta == 0))) {
			e.ifname = sprintf('phy0.%d-%s%d', r.idx, mode, r.n[mode]);
			r.n[mode]++;
		}
		push(r.ifaces, e);
	}
	return radios;
}
// which radio does a device / phy / radio name refer to
function radio_of(devname) {
	let lay = wifi_layout();
	if (lay[devname]) return lay[devname];
	for (let name, r in lay)
		for (let i in r.ifaces)
			if (i.ifname == devname) return r;
	if (match(devname, /^phy[0-9]+$/)) return lay[keys(lay)[0]];	// the wiphy holds both radios
	return null;
}
function radio_state(r) {
	let ch = +(r.conf.channel ?? 0);
	for (let i in r.ifaces)		// a joined station pins its radio to the uplink's channel
		if (i.mode == 'sta' && i.ifname) ch = UPLINK.channel;
	if (!ch) ch = (r.band == '2g') ? 6 : 36;
	return { channel: ch, freq: chan2freq(r.band, ch) };
}
function iface_by_name(name) {		// a wifi-iface that is up, by its netdev name
	for (let rn, r in wifi_layout())
		for (let i in r.ifaces)
			if (i.ifname == name) return i;
	return null;
}
// the netdev an interface runs on
function iface_device(name, s) {
	if (name == 'loopback') return 'lo';
	if (s.device) return s.device;
	for (let rn, r in wifi_layout())
		for (let i in r.ifaces)
			if (i.ifname && index(as_list(i.conf.network), name) >= 0) return i.ifname;
	return null;
}

// ---- netifd: network.interface dump -------------------------------------------------
function netifd_dump() {
	let res = [];
	for (let s in uci_sections('network', 'interface')) {
		let name = s['.name'];
		let i = {
			interface: name, up: false, pending: false, available: true,
			autostart: (s.auto ?? '1') != '0', dynamic: false, uptime: 0,
			proto: s.proto ?? 'none', metric: +(s.metric ?? 0), dns_metric: 0, delegation: true,
			'ipv4-address': [], 'ipv6-address': [], 'ipv6-prefix': [],
			'ipv6-prefix-assignment': [], route: [], 'dns-server': [], 'dns-search': [],
			neighbors: [],
			inactive: { 'ipv4-address': [], 'ipv6-address': [], route: [], 'dns-server': [], 'dns-search': [], neighbors: [] },
			data: {}
		};
		let dev = iface_device(name, s);
		if (dev) i.device = dev;
		// what is running: the known interfaces, provided their device exists and they are not disabled
		if (dev && DEVS[dev] && s.disabled != '1' && (name == 'loopback' || name == 'lan' || name == 'wan' || name == 'wan6' || name == 'trm_wwan' || name == 'tailscale')) {
			i.up = true;
			i.l3_device = dev;
			i.uptime = iface_uptime(name);
			i.updated = [ 'addresses', 'routes' ];
			switch (name) {
			case 'loopback': case 'lan':
				for (let a in dev_ipv4(dev)) push(i['ipv4-address'], { address: a[0], mask: a[1] });
				break;
			case 'wan': case 'trm_wwan': {
				let n = (name == 'wan') ? WAN : WWAN;
				push(i['ipv4-address'], { address: n.ip, mask: n.bits });
				push(i.route, { target: '0.0.0.0', mask: 0, nexthop: n.gw, source: n.ip + '/32' });
				push(i.route, { target: network_of(n.ip, n.bits), mask: n.bits, nexthop: '0.0.0.0', source: n.ip + '/32' });
				i['dns-server'] = n.dns;
				i['dns-search'] = [ n.search ];
				i.data = { leasetime: n.lease, domain: n.search };
				break;
			}
			}
		}
		push(res, i);
	}
	return res;
}

// netifd: network.device status
function device_status(name) {
	let d = DEVS[name];
	if (!d) return null;
	let t = time();
	let st = {
		external: false, present: true,
		type: (d.kind == 'bridge') ? 'bridge' : 'Network device',
		up: true, carrier: d.carrier, mtu: d.mtu, txqueuelen: 1000,
		ipv6: (d.kind != 'tun'), promisc: false, rpfilter: 0, acceptlocal: false,
		igmpversion: 0, mldversion: 0, neigh4reachabletime: 30000, neigh6reachabletime: 30000,
		neigh4gcstale: 60, neigh6gcstale: 60, neigh4locktime: 0, dadtransmits: 1,
		multicast: (d.kind != 'loopback'), sendredirects: true,
		neigh6retranstime: 1000, neigh4retranstime: 1000,
		statistics: {
			collisions: 0, rx_frame_errors: 0, tx_compressed: 0, multicast: (d.kind == 'loopback') ? 0 : int(counter(name, 0, t) / 60000),
			rx_length_errors: 0, tx_dropped: 0, rx_bytes: counter(name, 0, t), rx_missed_errors: 0,
			tx_errors: 0, rx_compressed: 0, rx_over_errors: 0, tx_fifo_errors: 0, rx_crc_errors: 0,
			rx_packets: packets(name, 0, t), tx_heartbeat_errors: 0, rx_dropped: 0, tx_aborted_errors: 0,
			tx_packets: packets(name, 1, t), rx_errors: 0, tx_bytes: counter(name, 1, t),
			tx_window_errors: 0, rx_nohandler: 0, tx_carrier_errors: 0
		}
	};
	if (d.mac) st.macaddr = d.mac;
	if (d.speed) st.speed = sprintf('%d%s', d.speed, (d.duplex == 'full') ? 'F' : 'H');
	if (d.ports) st['bridge-members'] = d.ports;
	return st;
}
function device_status_all() {
	let r = {};
	for (let n in keys(DEVS)) r[n] = device_status(n);
	return r;
}

// ---- luci-rpc: what the rpcd-mod-luci C plugin would read from /sys -------------------
function luci_devices() {
	let t = time(), res = {};
	for (let name, d in DEVS) {
		let e = {
			name, up: true, mtu: d.mtu, qlen: 1000,
			devtype: (d.kind == 'bridge') ? 'bridge' : ((d.kind == 'wireless') ? 'wlan' : 'ethernet'),
			wireless: (d.kind == 'wireless'),
			ipaddrs: [], ip6addrs: [],
			type: d.type, ifindex: IFINDEX[name],
			stats: {
				rx_bytes: counter(name, 0, t), tx_bytes: counter(name, 1, t),
				tx_errors: 0, rx_errors: 0,
				tx_packets: packets(name, 1, t), rx_packets: packets(name, 0, t),
				multicast: (d.kind == 'loopback') ? 0 : int(counter(name, 0, t) / 60000),
				collisions: 0, rx_dropped: 0, tx_dropped: 0
			},
			flags: {
				up: true, broadcast: (d.kind != 'loopback' && d.kind != 'tun'), promisc: false,
				loopback: (d.kind == 'loopback'), noarp: (d.kind == 'loopback' || d.kind == 'tun'),
				multicast: (d.kind != 'loopback'), pointtopoint: (d.kind == 'tun')
			},
			link: { carrier: d.carrier, changes: 2, up_count: 1, down_count: 1 }
		};
		if (d.speed) { e.link.speed = d.speed; e.link.duplex = d.duplex; }
		if (d.mac && d.type == 1) e.mac = d.mac;
		if (d.kind == 'bridge') { e.bridge = true; e.ports = d.ports; e.id = bridge_id(d.mac); e.stp = false; }
		if (d.master) e.master = d.master;
		for (let a in dev_ipv4(name)) {
			let ad = { address: a[0], netmask: bits2mask(a[1]) };
			if (d.kind == 'tun') ad.remote = a[0];
			else if (d.kind != 'loopback' && a[1] < 31) ad.broadcast = broadcast_of(a[0], a[1]);
			push(e.ipaddrs, ad);
		}
		res[name] = e;
	}
	return res;
}

// ---- Wi-Fi: network.wireless status, iwinfo -----------------------------------------------
const SECRET = [ 'key', 'sae_password', 'password', 'auth_secret', 'wpa_psk' ];
function conf_keys(sect) {
	let out = {};
	for (let k, v in sect) {
		if (index(k, '.') == 0 || index(SECRET, k) >= 0) continue;
		out[k] = v;
	}
	return out;
}
function wireless_status() {
	let res = {};
	for (let name, r in wifi_layout()) {
		let cfg = conf_keys(r.conf);
		cfg.disabled = (r.conf.disabled == '1');
		if (r.conf.channel != null && r.conf.channel != 'auto') cfg.channel = +r.conf.channel;
		if (r.conf.radio != null) cfg.radio = +r.conf.radio;
		let st = {
			up: (r.conf.disabled != '1'), pending: false, autostart: true,
			disabled: (r.conf.disabled == '1'), retry_setup_failed: false,
			config: cfg, interfaces: []
		};
		for (let i in r.ifaces) {
			let ic = conf_keys(i.conf);
			ic.network = as_list(i.conf.network);
			ic.mode = i.mode;
			let e = { section: i.section, config: ic };
			if (i.ifname) {
				e.ifname = i.ifname;
				e.vlans = [];
				e.stas = [];
				if (i.mode == 'ap')
					for (let c in clients_on(i.ifname)) push(e.stas, { mac: c.mac });
			}
			push(st.interfaces, e);
		}
		res[name] = st;
	}
	return res;
}

function enc_of(v) {
	v = v ?? 'none';
	if (v == 'none' || v == '') return { enabled: false };
	let wpa = [], auth = [], ciphers = [ 'ccmp' ];
	if (match(v, /sae-mixed/)) { wpa = [ 2, 3 ]; auth = [ 'psk', 'sae' ]; }
	else if (match(v, /sae/)) { wpa = [ 3 ]; auth = [ 'sae' ]; }
	else if (match(v, /psk2/)) { wpa = [ 2 ]; auth = [ 'psk' ]; }
	else if (match(v, /psk/)) { wpa = [ 1 ]; auth = [ 'psk' ]; ciphers = [ 'tkip', 'ccmp' ]; }
	else if (match(v, /owe/)) { wpa = [ 3 ]; auth = [ 'owe' ]; }
	else { wpa = [ 2 ]; auth = [ '802.1x' ]; }
	return { enabled: true, wpa, authentication: auth, ciphers };
}
function avg_signal(ifname) {
	let cl = clients_on(ifname), s = 0;
	if (!length(cl)) return null;
	for (let c in cl) s += c.signal;
	return int(s / length(cl));
}
function quality_of(sig) {
	if (sig == null) return 0;
	let q = sig + 110;
	return (q < 0) ? 0 : ((q > 70) ? 70 : q);
}

// iwinfo info for a netdev, radio or phy name; null if it is not Wi-Fi
function iwinfo_info(dev) {
	let r = radio_of(dev);
	if (!r) return null;
	let iface = iface_by_name(dev);
	let rs = radio_state(r), hw = RADIO[r.band];
	let info = {
		phy: 'phy0', country: r.conf.country ?? 'TW', channel: rs.channel,
		frequency: rs.freq, frequency_offset: 0, txpower: hw.txpower, txpower_offset: 0,
		noise: hw.noise, hwmodes: hw.hwmodes, hwmodes_text: hw.hwtext, htmodes: hw.htmodes,
		hardware: { id: [ 5315, 30962, 0, 0 ], name: 'MediaTek MT7992' }
	};
	if (iface) {
		info.mode = (iface.mode == 'sta') ? 'Client' : 'Master';
		info.ssid = iface.conf.ssid;
		info.encryption = enc_of(iface.conf.encryption);
		if (iface.mode == 'sta') {
			info.bssid = uc(UPLINK.bssid);
			info.signal = UPLINK.signal; info.noise = UPLINK.noise;
			info.quality = quality_of(UPLINK.signal); info.quality_max = 70;
			info.bitrate = UPLINK.rate_rx;
		}
		else {
			info.bssid = uc((iface.band == '2g') ? MAC.ap24 : MAC.ap5);
			let sg = avg_signal(iface.ifname);
			if (sg != null) info.signal = sg;
			info.quality = quality_of(sg ?? -60); info.quality_max = 70;
			let cl = clients_on(iface.ifname), br = 0;
			for (let c in cl) br += c.tx[0];
			info.bitrate = length(cl) ? int(br / length(cl)) : 0;
		}
	}
	return info;
}
function iwinfo_devices() {
	let out = [];
	for (let rn, r in wifi_layout())
		for (let i in r.ifaces)
			if (i.ifname) push(out, i.ifname);
	return out;
}
function iwinfo_assoc(dev) {
	let out = [], t = time();
	for (let c in clients_on(dev)) {
		let n = t - T0 + c.age;
		let rxr = { drop_misc: 3, packets: n * 40, bytes: n * 40 * 780,
			ht: (c.gen == 'ht'), vht: (c.gen == 'vht'), he: (c.gen == 'he'), eht: false,
			mhz: c.rx[1], rate: c.rx[0], mcs: c.rx[2], short_gi: (c.gen == 'ht') };
		let txr = { failed: 11, retries: 240, packets: n * 90, bytes: n * 90 * 1080,
			ht: rxr.ht, vht: rxr.vht, he: rxr.he, eht: false,
			mhz: c.tx[1], rate: c.tx[0], mcs: c.tx[2], short_gi: rxr.short_gi };
		if (c.gen != 'ht') { rxr.nss = c.rx[3]; txr.nss = c.tx[3]; }	// plain HT has no stream count
		if (c.gen == 'he') { rxr.he_gi = 0; rxr.he_dcm = 0; txr.he_gi = 0; txr.he_dcm = 0; }
		push(out, {
			mac: uc(c.mac), signal: c.signal, signal_avg: c.signal - 1, noise: (dev == 'phy0.1-ap0') ? -95 : -93,
			inactive: 40 + ord(c.mac, 3) * 3, connected_time: n, thr: int(c.tx[0] * 0.55),
			authorized: true, authenticated: true, preamble: 'long', wme: true, mfp: true, tdls: false,
			rx: rxr, tx: txr
		});
	}
	return out;
}
function iwinfo_freqlist(dev) {
	let r = radio_of(dev);
	if (!r) return [];
	let out = [], is2 = (r.band == '2g');
	for (let ch in (is2 ? CHAN_2G : CHAN_5G)) {
		let dfs = (!is2 && ch >= 52 && ch <= 144);
		push(out, {
			band: is2 ? 2 : 5, channel: ch, mhz: chan2freq(r.band, ch),
			restricted: dfs, no_ir: dfs, no_outdoor: false, radar: dfs
		});
	}
	return out;
}
function iwinfo_txpowers(dev) {
	let r = radio_of(dev);
	let out = [], max = r ? RADIO[r.band].maxpower : 20;
	for (let d = 0; d <= max; d++)
		push(out, { dbm: d, mw: int(pow(10, d / 10.0) + 0.5) });
	return out;
}
const COUNTRIES = [ [ 'AU', 'Australia' ], [ 'AT', 'Austria' ], [ 'BE', 'Belgium' ], [ 'BR', 'Brazil' ], [ 'CA', 'Canada' ], [ 'CN', 'China' ], [ 'DK', 'Denmark' ], [ 'FI', 'Finland' ], [ 'FR', 'France' ], [ 'DE', 'Germany' ], [ 'HK', 'Hong Kong' ], [ 'IN', 'India' ], [ 'ID', 'Indonesia' ], [ 'IE', 'Ireland' ], [ 'IT', 'Italy' ], [ 'JP', 'Japan' ], [ 'KR', 'Korea, Republic of' ], [ 'MY', 'Malaysia' ], [ 'NL', 'Netherlands' ], [ 'NZ', 'New Zealand' ], [ 'NO', 'Norway' ], [ 'PH', 'Philippines' ], [ 'SG', 'Singapore' ], [ 'ES', 'Spain' ], [ 'SE', 'Sweden' ], [ 'CH', 'Switzerland' ], [ 'TW', 'Taiwan' ], [ 'TH', 'Thailand' ], [ 'GB', 'United Kingdom' ], [ 'US', 'United States' ], [ 'VN', 'Viet Nam' ] ];
function iwinfo_countries() {
	return map(COUNTRIES, (c) => ({ code: c[0], iso3166: c[0], country: c[1] }));
}
// what is in the air around the desk: the hotel's own networks and the neighbours
const AIR = [
	{ ssid: 'Hotel_Guest', bssid: 'C8:7F:54:3A:9D:41', channel: 36, signal: -58, enc: 'none', band: '5g' },
	{ ssid: 'Hotel_Guest', bssid: 'C8:7F:54:3A:9D:51', channel: 1, signal: -63, enc: 'none', band: '2g' },
	{ ssid: 'Hotel_Guest', bssid: 'C8:7F:54:71:0B:C1', channel: 149, signal: -71, enc: 'none', band: '5g' },
	{ ssid: 'Hotel_Staff', bssid: 'C8:7F:54:3A:9D:42', channel: 36, signal: -59, enc: 'psk2', band: '5g' },
	{ ssid: 'Hotel_Conference', bssid: 'C8:7F:54:3A:9D:43', channel: 36, signal: -60, enc: 'psk2', band: '5g' },
	{ ssid: 'DIRECT-3c-HP OfficeJet', bssid: '0A:5B:7E:C3:11:04', channel: 6, signal: -74, enc: 'psk2', band: '2g' },
	{ ssid: 'TP-Link_4F2A', bssid: '5C:A6:E6:4F:2A:10', channel: 11, signal: -79, enc: 'psk2', band: '2g' },
	{ ssid: 'CoffeeShopWiFi', bssid: '84:16:F9:92:7C:E0', channel: 44, signal: -82, enc: 'sae', band: '5g' },
	{ ssid: '', bssid: 'E4:18:6B:0D:C3:18', channel: 6, signal: -85, enc: 'psk2', band: '2g' }
];
function iwinfo_scan(dev) {
	let r = radio_of(dev);
	if (!r) return [];
	let out = [];
	for (let a in AIR) {
		if (a.band != r.band) continue;
		push(out, {
			ssid: a.ssid, bssid: a.bssid, mode: 'Master', channel: a.channel,
			mhz: chan2freq(a.band, a.channel), signal: a.signal, quality: quality_of(a.signal), quality_max: 70,
			encryption: enc_of(a.enc)
		});
	}
	return out;
}

// ---- hosts, leases -----------------------------------------------------------------------
function leases() {
	// dnsmasq lease file: expiry mac ip hostname clientid
	let out = [], t = time();
	for (let line in split(readfile('/tmp/dhcp.leases') ?? '', '\n')) {
		let f = split(line, ' ');
		if (length(f) < 4) continue;
		push(out, { expires: +f[0] - t, macaddr: uc(f[1]), ipaddr: f[2], hostname: (f[3] == '*') ? '' : f[3], clientid: f[4] });
	}
	return out;
}
function host_hints() {
	let res = {};
	for (let c in CLIENTS)
		res[uc(c.mac)] = { name: c.name, ipaddrs: [ c.ip ], ip6addrs: [] };
	res[uc(MAC.hotel_wired_gw)] = { ipaddrs: [ WAN.gw ], ip6addrs: [] };
	res[uc(MAC.hotel_wifi_gw)] = { ipaddrs: [ WWAN.gw ], ip6addrs: [] };
	return res;
}
// the ARP table, as `ip neigh` would print it
function neigh4() {
	let out = [];
	for (let c in CLIENTS)
		if (c.ap) push(out, { ip: c.ip, dev: 'br-lan', mac: c.mac, state: (ord(c.mac, 1) % 2) ? 'REACHABLE' : 'STALE' });
	push(out, { ip: WAN.gw, dev: 'eth0', mac: MAC.hotel_wired_gw, state: 'REACHABLE' });
	push(out, { ip: WWAN.gw, dev: 'phy0.1-sta0', mac: MAC.hotel_wifi_gw, state: 'STALE' });
	return out;
}

// ---- system ---------------------------------------------------------------------------------
function load_avg() {
	let t = time() * 1.0;
	return [ 0.11 + 0.05 * sin(t / 40.0), 0.09 + 0.04 * sin(t / 130.0 + 1), 0.07 + 0.02 * sin(t / 400.0 + 2) ];
}
function system_info() {
	let total = 1002520576;
	let used = 172000000 + int(4000000 * sin(time() / 90.0));
	return {
		uptime: uptime(), localtime: time(),
		load: map(load_avg(), (x) => int(x * 65535)),
		memory: { total, free: total - used - 39000000 - 3300000, shared: 274432, buffered: 3300000, available: total - used - 3300000 + 20000000, cached: 39000000 },
		swap: { total: 0, free: 0 },
		root: { total: 380604, free: 361200, used: 19404, avail: 361200 },
		tmp: { total: 489472, free: 486900, used: 2572, avail: 486900 }
	};
}
function board_json() {
	return json(readfile('/etc/board.json') ?? '{}') ?? {};
}

// ---- log ------------------------------------------------------------------------------------
// what logd would return for `ubus call log read`: [ seconds ago, facility, severity, message ]
// facility 0 kern, 3 daemon, 10 authpriv; severity 3 err, 4 warn, 5 notice, 6 info
const LOG = [
	[ 8140, 3, 6, 'netifd: Network device \'eth0\' link is up' ],
	[ 8138, 3, 6, 'netifd: Interface \'wan\' is enabled' ],
	[ 8138, 3, 6, 'netifd: Interface \'wan6\' is enabled' ],
	[ 8136, 3, 6, 'netifd: wan (3811): udhcpc: sending discover' ],
	[ 8135, 3, 6, 'netifd: wan (3811): udhcpc: sending select for 192.168.100.23' ],
	[ 8134, 3, 6, 'netifd: wan (3811): udhcpc: lease of 192.168.100.23 obtained from 192.168.100.1, lease time 86400' ],
	[ 8133, 3, 6, 'netifd: Interface \'wan\' is now up' ],
	[ 8130, 3, 4, 'odhcp6c[3821]: Failed to send DHCPV6 message to ff02::1:2 (Network is unreachable)' ],
	[ 8128, 3, 6, 'dnsmasq[1893]: using nameserver 192.168.100.1#53' ],
	[ 8127, 3, 6, 'dnsmasq[1893]: using only locally-known addresses for hotel.lan' ],
	[ 7990, 3, 6, 'trm-2.4.9[2652]: travelmate instance started ::: action: start, pid: 2652' ],
	[ 5410, 3, 6, 'trm-2.4.9[2652]: scan on radio1 finished ::: 3 uplink(s) in range, 1 saved' ],
	[ 5400, 3, 6, 'trm-2.4.9[2652]: connect to uplink \'radio1/Hotel_Guest/C8:7F:54:3A:9D:41\' (1/3, GL.iNet GL-MT3600BE)' ],
	[ 3620, 3, 6, 'hostapd: phy0.1-ap0: STA ce:52:81:94:e7:1b IEEE 802.11: authenticated' ],
	[ 3620, 3, 6, 'hostapd: phy0.1-ap0: STA ce:52:81:94:e7:1b IEEE 802.11: associated (aid 3)' ],
	[ 3619, 3, 6, 'hostapd: phy0.1-ap0: STA ce:52:81:94:e7:1b WPA: pairwise key handshake completed (RSN)' ],
	[ 3618, 3, 6, 'dnsmasq-dhcp[1893]: DHCPREQUEST(br-lan) 172.31.77.103 ce:52:81:94:e7:1b' ],
	[ 3618, 3, 6, 'dnsmasq-dhcp[1893]: DHCPACK(br-lan) 172.31.77.103 ce:52:81:94:e7:1b iPad' ],
	[ 2860, 3, 6, 'wpa_supplicant[2988]: phy0.1-sta0: SME: Trying to authenticate with c8:7f:54:3a:9d:41 (SSID=\'Hotel_Guest\' freq=5180 MHz)' ],
	[ 2859, 3, 6, 'wpa_supplicant[2988]: phy0.1-sta0: Trying to associate with c8:7f:54:3a:9d:41 (SSID=\'Hotel_Guest\' freq=5180 MHz)' ],
	[ 2858, 3, 6, 'wpa_supplicant[2988]: phy0.1-sta0: Associated with c8:7f:54:3a:9d:41' ],
	[ 2857, 3, 6, 'wpa_supplicant[2988]: phy0.1-sta0: CTRL-EVENT-CONNECTED - Connection to c8:7f:54:3a:9d:41 completed [id=0 id_str=]' ],
	[ 2856, 3, 6, 'netifd: Network device \'phy0.1-sta0\' link is up' ],
	[ 2855, 3, 6, 'netifd: Interface \'trm_wwan\' is now up' ],
	[ 2853, 3, 6, 'netifd: trm_wwan (4102): udhcpc: lease of 10.20.30.145 obtained from 10.20.28.1, lease time 3600' ],
	[ 2810, 3, 4, 'trm-2.4.9[2652]: captive portal detected ::: url: http://192.168.100.1/login' ],
	[ 2790, 3, 5, 'trm-2.4.9[2652]: connected to uplink \'radio1/Hotel_Guest/C8:7F:54:3A:9D:41\' (1/3, GL.iNet GL-MT3600BE) ::: net ok/78' ],
	[ 120, 3, 6, 'trm-2.4.9[2652]: uplink \'radio1/Hotel_Guest/C8:7F:54:3A:9D:41\' is online ::: net ok/78' ],
	[ 1210, 0, 4, 'kernel: [111342.518203] mt7996e 0000:01:00.0: MCU message 0x2e timed out, retrying' ],
	[ 640, 3, 3, 'tailscaled[2404]: health(warnable=no-derp-home): error: Tailscale could not connect to any relay server. Check your Internet connection.' ],
	[ 610, 3, 6, 'tailscaled[2404]: control: RegisterReq: got response; nodeKeyExpired=false, machineAuthorized=true; authURL=false' ],
	[ 300, 3, 6, 'dnsmasq-dhcp[1893]: DHCPREQUEST(br-lan) 172.31.77.101 da:3f:6a:15:9c:02' ],
	[ 300, 3, 6, 'dnsmasq-dhcp[1893]: DHCPACK(br-lan) 172.31.77.101 da:3f:6a:15:9c:02 iPhone' ],
	[ 96, 10, 6, 'dropbear[6120]: Child connection from 172.31.77.102:52144' ],
	[ 95, 10, 6, 'dropbear[6120]: Pubkey auth succeeded for \'root\' with key sha1!! 6f:21:0a:5b:aa:04:c7:39:91:b0:e8:d3:5e:7f:22:19:0c:bb:1a:d4 from 172.31.77.102:52144' ],
	[ 12, 10, 6, 'luci: accepted login on / for root from 172.31.77.102' ]
];
function log_entries() {
	let t = time(), out = [], id = 0;
	for (let e in sort(slice(LOG), (a, b) => b[0] - a[0])) {
		push(out, { id: ++id, source: (e[1] == 0) ? 0 : 1, priority: e[1] * 8 + e[2], time: (t - e[0]) * 1000, msg: e[3] });
	}
	return out;
}

// ---- for the status pages ---------------------------------------------------------
function processes() {
	// [ pid, ppid, user, stat, vsz KiB, %cpu, %mem, command ]
	let rows = [
		[ 1, 0, 'root', 'S', 1516, 0, 0, '/sbin/procd' ],
		[ 96, 1, 'root', 'S', 1276, 0, 0, '/sbin/ubusd' ],
		[ 133, 1, 'root', 'S', 1340, 0, 0, '/sbin/logd -S 64' ],
		[ 1402, 1, 'root', 'S', 3068, 0, 0, '/sbin/rpcd -s /var/run/ubus/ubus.sock -t 30' ],
		[ 1466, 1, 'root', 'S', 3168, 0, 0, '/sbin/netifd' ],
		[ 1493, 1, 'root', 'S', 1988, 0, 0, '/usr/sbin/odhcpd' ],
		[ 1893, 1, 'dnsmasq', 'S', 3844, 0, 0, '/usr/sbin/dnsmasq -C /var/etc/dnsmasq.conf.cfg01411c -k -x /var/run/dnsmasq/dnsmasq.cfg01411c.pid' ],
		[ 1985, 1, 'root', 'S', 5824, 0, 0, '/usr/sbin/hostapd -s -g /var/run/hostapd/global' ],
		[ 2211, 1, 'root', 'S', 1428, 0, 0, '/usr/sbin/dropbear -F -P /var/run/dropbear.1.pid -p 22 -K 300 -T 3' ],
		[ 2318, 1, 'root', 'S', 2260, 0, 0, '/usr/sbin/uhttpd -f -h /www -r beryl7 -x /cgi-bin -u /ubus -t 60 -T 30 -k 20 -A 1 -n 3 -N 100 -R -p 0.0.0.0:80 -p [::]:80' ],
		[ 2404, 1, 'root', 'S', 1288224, 1, 5, '/usr/sbin/tailscaled --state=/etc/tailscale/tailscaled.state --port 41641' ],
		[ 2652, 1, 'root', 'S', 1712, 0, 0, '/bin/sh /usr/bin/travelmate-service.sh start' ],
		[ 2988, 1, 'root', 'S', 3512, 0, 0, '/usr/sbin/wpa_supplicant -n -s -g /var/run/wpa_supplicant/global' ],
		[ 3121, 1, 'root', 'S', 1300, 0, 0, '/usr/sbin/crond -f -c /etc/crontabs -l 5' ],
		[ 3122, 1, 'root', 'S', 1044, 0, 0, '/usr/sbin/ntpd -n -N -l -S /usr/sbin/ntpd-hotplug -p 0.openwrt.pool.ntp.org -p 1.openwrt.pool.ntp.org' ],
		[ 3380, 1, 'root', 'S', 3384, 0, 0, '/usr/sbin/nlbwmon -o /var/run/nlbwmon -b 524288 -i 1d -r 30s -s 35 -p /usr/share/nlbwmon/protocols' ],
		[ 6120, 2211, 'root', 'S', 1428, 0, 0, '/usr/sbin/dropbear -F -P /var/run/dropbear.1.pid -p 22 -K 300 -T 3' ],
		[ 6121, 6120, 'root', 'S', 1160, 0, 0, '-ash' ]
	];
	return map(rows, (r) => ({
		PID: r[0], PPID: r[1], USER: r[2], STAT: r[3], VSZ: '' + r[4], '%VSZ': r[6] + '%',
		'%CPU': r[5] + '%', '%MEM': r[6] + '%', COMMAND: r[7]
	}));
}
// what a real router has mounted; the overview page skips the four system ones.
// A USB drive is plugged in (its fstab entry is in fixtures/ui/ui-defaults.sh).
const USB = { dev: '/dev/sda1', size: 31914983424, free: 27520000000, uuid: '5a1c7d3e-8f42-4b0e-9c61-2d7e3f9a0b14', label: 'TravelDrive', type: 'ext4', mount: '/mnt/sda1' };
function mounts() {
	return [
		{ device: '/dev/root', mount: '/rom', size: 25165824, avail: 0, free: 0 },
		{ device: 'tmpfs', mount: '/tmp', size: 501219328, avail: 498585600, free: 498585600 },
		{ device: '/dev/ubi0_2', mount: '/overlay', size: 389738496, avail: 369868800, free: 369868800 },
		{ device: 'overlayfs:/overlay', mount: '/', size: 389738496, avail: 369868800, free: 369868800 },
		{ device: 'tmpfs', mount: '/dev', size: 524288, avail: 524288, free: 524288 },
		{ device: USB.dev, mount: USB.mount, size: USB.size, avail: USB.free, free: USB.free }
	];
}
function block_devices() {
	return { sda1: { dev: USB.dev, size: USB.size, uuid: USB.uuid, label: USB.label, type: USB.type, mount: USB.mount } };
}
// what /sys/class/leds would hold
function leds() {
	let triggers = [ 'none', 'default-on', 'heartbeat', 'timer', 'transient', 'oneshot', 'netdev', 'usbport', 'phy0rx', 'phy0tx', 'phy0assoc', 'phy0radio', 'phy0tpt' ];
	return {
		'white:system': { triggers, active_trigger: 'default-on', brightness: 255, max_brightness: 255 },
		'white:wlan': { triggers, active_trigger: 'phy0tpt', brightness: 0, max_brightness: 255 }
	};
}
function conntrack() {
	let out = [], n = 0;
	// destinations the devices talk to: [ address, port, protocol ]
	let dests = [
		[ '17.253.144.10', 443, 'tcp' ], [ '17.57.146.84', 5223, 'tcp' ], [ '142.250.204.46', 443, 'tcp' ], [ '142.250.204.46', 443, 'udp' ],
		[ '104.18.32.47', 443, 'tcp' ], [ '151.101.1.140', 443, 'tcp' ], [ '31.13.72.53', 443, 'udp' ], [ '31.13.72.53', 443, 'tcp' ],
		[ '52.94.236.248', 443, 'tcp' ], [ '54.230.110.24', 443, 'tcp' ], [ '13.107.42.14', 443, 'tcp' ], [ '23.220.75.245', 443, 'tcp' ],
		[ '185.199.108.153', 443, 'tcp' ], [ '20.190.151.68', 443, 'tcp' ], [ '140.82.112.3', 443, 'tcp' ], [ '34.107.243.93', 443, 'tcp' ],
		[ '199.232.65.91', 443, 'tcp' ], [ '172.217.163.46', 443, 'tcp' ], [ '157.240.15.35', 443, 'tcp' ], [ '198.41.215.162', 443, 'udp' ],
		[ '35.186.224.25', 443, 'tcp' ], [ '3.33.152.147', 443, 'tcp' ], [ '216.58.200.99', 443, 'udp' ], [ '17.248.176.11', 443, 'tcp' ]
	];
	let active = filter(CLIENTS, (c) => c.ap != null);
	for (let i = 0; i < 60; i++) {
		let c = active[i % length(active)], d = dests[(i * 7 + 3) % length(dests)];
		let bytes = 300;
		for (let k = 0; k < (i * 37) % 19; k++) bytes *= 2;
		bytes += (i * 7919) % 997;
		let pk = int(bytes / (d[2] == 'udp' ? 900 : 1100)) + 2;
		push(out, {
			layer3: 'ipv4', layer4: d[2], src: c.ip, dst: d[0], sport: 32768 + (i * 977) % 28000, dport: d[1],
			bytes, packets: pk, rx_bytes: int(bytes * 0.85), rx_packets: int(pk * 0.7), tx_bytes: int(bytes * 0.15), tx_packets: int(pk * 0.3)
		});
	}
	// the small stuff: name lookups, Tailscale, a ping
	let extra = [
		[ 'udp', '172.31.77.101', 60321, '8.8.8.8', 53, 412, 4 ], [ 'udp', '172.31.77.102', 57210, '192.168.100.1', 53, 380, 4 ],
		[ 'udp', '172.31.77.104', 34012, '192.168.100.1', 53, 233, 2 ], [ 'udp', '192.168.100.23', 41641, '100.64.1.7', 41641, 410233, 620 ],
		[ 'udp', '172.31.77.102', 41930, '100.64.0.11', 41641, 1310522, 1610 ], [ 'tcp', '172.31.77.102', 60644, '100.64.0.11', 22, 220433, 1220 ],
		[ 'icmp', '172.31.77.102', 0, '1.1.1.1', 0, 588, 6 ]
	];
	for (let f in extra)
		push(out, {
			layer3: 'ipv4', layer4: f[0], src: f[1], dst: f[3], sport: f[2], dport: f[4], bytes: f[5], packets: f[6],
			rx_bytes: int(f[5] * 0.85), rx_packets: int(f[6] * 0.7), tx_bytes: int(f[5] * 0.15), tx_packets: int(f[6] * 0.3)
		});
	return out;
}

// ---- nlbwmon: traffic per device, per day ----------------------------------------------------------
// [ client, layer7, connections, rx bytes (downloaded), tx bytes ] for today; other days are scaled
const USAGE = [
	[ 'iPhone', 'HTTPS', 1210, 1420000000, 96000000 ],
	[ 'iPhone', 'QUIC', 862, 2310000000, 180000000 ],
	[ 'iPhone', 'DNS', 940, 410000, 210000 ],
	[ 'iPhone', '', 233, 12000000, 3100000 ],
	[ 'MacBook-Air', 'HTTPS', 2010, 3120000000, 410000000 ],
	[ 'MacBook-Air', 'QUIC', 1502, 1850000000, 220000000 ],
	[ 'MacBook-Air', 'SSH', 12, 5200000, 3100000 ],
	[ 'MacBook-Air', 'DNS', 1410, 640000, 330000 ],
	[ 'MacBook-Air', 'IMAPS', 8, 1100000, 210000 ],
	[ 'iPad', 'HTTPS', 720, 2730000000, 65000000 ],
	[ 'iPad', 'QUIC', 1300, 3900000000, 90000000 ],
	[ 'iPad', 'DNS', 512, 210000, 96000 ],
	[ 'Kindle-Paperwhite', 'HTTPS', 62, 21000000, 2100000 ],
	[ 'Kindle-Paperwhite', 'DNS', 41, 12000, 5100 ],
	[ 'Chromecast', 'HTTPS', 88, 512000000, 12000000 ],
	[ 'Chromecast', 'QUIC', 55, 1010000000, 8000000 ],
	[ 'Chromecast', 'DNS', 30, 9000, 4000 ]
];
function nlbw_periods() {
	let out = [], now = time();
	for (let i = 0; i < 31; i++) {
		let d = gmtime(now - i * 86400);
		push(out, sprintf('%04d-%02d-%02d', d.year, d.mon, d.mday));
	}
	return out;
}
function nlbw_rows(group, order, period) {
	let cols = { family: 0, mac: 1, ip: 2, layer7: 3 };
	let scale = 1.0;
	if (period && period != nlbw_periods()[0]) {
		let h = 0;
		for (let i = 0; i < length(period); i++) h = (h * 7 + ord(period, i)) % 100;
		scale = 0.35 + h / 100.0;
	}
	let recs = {};
	for (let u in USAGE) {
		let c = null;
		for (let x in CLIENTS) if (x.name == u[0]) c = x;
		let r = [ 4, c.mac, c.ip, u[1] ];
		let key = join('|', map(group, (g) => '' + r[cols[g]]));
		recs[key] ??= { key: map(group, (g) => r[cols[g]]), conns: 0, rx: 0, rxp: 0, tx: 0, txp: 0 };
		recs[key].conns += int(u[2] * scale);
		recs[key].rx += int(u[3] * scale);
		recs[key].rxp += int(u[3] * scale / 1200);
		recs[key].tx += int(u[4] * scale);
		recs[key].txp += int(u[4] * scale / 700);
	}
	let data = [];
	for (let k, v in recs) push(data, [ ...v.key, v.conns, v.rx, v.rxp, v.tx, v.txp ]);
	let ncol = length(group);
	let sortcols = { conns: ncol, rx_bytes: ncol + 1, rx_pkts: ncol + 2, tx_bytes: ncol + 3, tx_pkts: ncol + 4 };
	if (order) {
		let specs = split(order, ',');
		sort(data, (a, b) => {
			for (let sp in specs) {
				let desc = index(sp, '-') == 0, name = desc ? substr(sp, 1) : sp;
				let ix = (sortcols[name] != null) ? sortcols[name] : index(group, name);
				if (ix < 0) continue;
				let d = (a[ix] < b[ix]) ? -1 : ((a[ix] > b[ix]) ? 1 : 0);
				if (d) return desc ? -d : d;
			}
			return 0;
		});
	}
	return { columns: [ ...group, 'conns', 'rx_bytes', 'rx_pkts', 'tx_bytes', 'tx_pkts' ], data };
}

// ---- luci-bwc: the realtime graphs -------------------------------------------------------------
// the last five minutes, one sample a second (the graphs draw a column per sample), in the shape luci-bwc prints them:
//   -i dev: [ t, rx bytes, rx packets, tx bytes, tx packets ]      -l: [ t, load1, load5, load15 ] x 100
//   -c:     [ t, udp, tcp, other ] established connections           -r radio: [ t, rate kbit/s, signal + 255, noise + 255 ]
function bwc_rows(mode, arg) {
	let now = time(), rows = [];
	for (let i = 319; i >= 0; i--) {
		let t = now - i, tf = t * 1.0;
		switch (mode) {
		case '-i':
			push(rows, [ t, counter(arg, 0, t), packets(arg, 0, t), counter(arg, 1, t), packets(arg, 1, t) ]);
			break;
		case '-l':
			push(rows, [ t, int(100 * (0.11 + 0.05 * sin(tf / 40.0))), int(100 * (0.09 + 0.04 * sin(tf / 130.0 + 1))), int(100 * (0.07 + 0.02 * sin(tf / 400.0 + 2))) ]);
			break;
		case '-c':
			push(rows, [ t, 22 + int(6 * sin(tf / 45.0)), 96 + int(20 * sin(tf / 70.0 + 1)) + int(8 * sin(tf / 13.0)), 3 ]);
			break;
		case '-r': {
			let r = radio_of(arg), band = r ? r.band : '5g';
			push(rows, [ t, (band == '5g') ? 866700 - int(60000 * (1 + sin(tf / 23.0))) : 144400,
				((band == '5g') ? -55 : -63) + int(3 * sin(tf / 17.0)) + 255, RADIO[band].noise + 255 ]);
			break;
		}
		}
	}
	return rows;
}

// ---- rpcd's own "luci" plugin --------------------------------------------------------------------
// serve-ui.sh hooks this into /usr/share/rpcd/ucode/luci: those methods read
// /proc, /sys and the host's netlink, which in the sandbox describe the build
// box. Everything else in that plugin (init scripts, timezones, ...) stays real.
function patch_luci(m) {
	m.getMountPoints.call = () => ({ result: mounts() });
	m.getProcessList.call = () => ({ result: processes() });
	m.getConntrackList.call = () => ({ result: conntrack() });
	m.getBuiltinEthernetPorts.call = () => ({ result: [ { role: 'lan', device: 'eth1' }, { role: 'wan', device: 'eth0' } ] });
	m.getBlockDevices.call = () => block_devices();
	m.getLEDs.call = () => leds();
	m.getUSBDevices.call = () => ({ devices: [], ports: [] });
	// The stock method asks ubus for network.device, which here is one of rpcd's
	// own plugins: rpcd would be waiting for itself until the 30 s call timeout
	// (and every other call, the login included, would queue behind it).
	if (m.getOdhcp6cStats)	// 25.12 and later; LuCI 24.10 has no such method (2026-10-08)
		m.getOdhcp6cStats.call = () => ({ result: {} });
	m.getRealtimeStats.call = (req) => {
		switch (req.args.mode) {
		case 'interface': return { result: bwc_rows('-i', req.args.device) };
		case 'wireless': return { result: bwc_rows('-r', req.args.device) };
		case 'conntrack': return { result: bwc_rows('-c') };
		case 'load': return { result: bwc_rows('-l') };
		}
		return { error: 'Invalid mode' };
	};
	// no hostapd / wpa_supplicant binaries in the sandbox: describe the full build the router has
	let features = m.getFeatures.call;
	m.getFeatures.call = (req) => {
		let r = features(req);
		let wifi = { cli: true, '11ac': true, '11ax': true, '11be': true, '11r': true, acs: true, eap: true,
			mesh: true, ocv: true, owe: true, sae: true, suiteb192: true, wep: false, wps: true };
		r.hostapd = { ...wifi };
		r.wpasupplicant = { ...wifi };
		r.wifi = true;
		return r;
	};
}

export { serve, uptime, elapsed, boot_epoch, uci_sections, as_list, MAC, WAN, WWAN, CLIENTS,
	DEVS, IFINDEX, netifd_dump, device_status, device_status_all, luci_devices, wireless_status,
	iwinfo_info, iwinfo_devices, iwinfo_assoc, iwinfo_freqlist, iwinfo_txpowers, iwinfo_countries,
	iwinfo_scan, radio_of, leases, host_hints, neigh4, system_info, board_json, log_entries,
	processes, mounts, conntrack, bwc_rows, patch_luci, lan_addrs, network_of, bits2mask, wifi_layout, dev_ipv4,
	counter, packets, RADIO, nlbw_periods, nlbw_rows };
