'use strict';
// The panel's status report (see docs/panel-api.md). Read-only: it only
// collects what OpenWrt's own parts already know and prints one JSON object.

import { popen, readfile, writefile, stat, lsdir } from 'fs';
import { cursor } from 'uci';
import { connect } from 'ubus';

const RUN = '/var/run/travel';
const TRM = '/var/run/travelmate/travelmate.runtime.json';

let uci = cursor();
let bus = connect();

function sh(cmd) {
	let p = popen(cmd, 'r');
	if (!p) return '';
	let out = p.read('all');
	p.close();
	return out ?? '';
}
function rd(path) { return trim(readfile(path) ?? ''); }
// JSON that may be half-written (travelmate truncates then rewrites) must
// never take the whole report down
function pj(text) {
	try { return json(text || '{}') ?? {}; }
	catch (e) { return {}; }
}
function b2i(b) { return b ? 1 : 0; }
function tget(opt, dflt) { return uci.get('travel', 'main', opt) ?? dflt; }
function band_of(freq) { return (+freq < 3000) ? '2g' : '5g'; }

let st = { time: time() };
st.hostname = uci.get_first('system', 'system', 'hostname') ?? 'OpenWrt';

// ---- mode and switch -------------------------------------------------------
let portal_file = split(rd(`${RUN}/portal`), '\n');
st.mode = {
	desired: tget('mode', 'direct'),
	active: rd(`${RUN}/active`) || 'direct',
	hold: stat(`${RUN}/portal`) ? 'portal' : '',
	exit_node: tget('exit_node', ''),
	wg: tget('wg', ''),
	error: rd(`${RUN}/error`)
};
st.switch = {
	region: tget('region', 'world'),
	world_mode: tget('world_mode', 'exitnode'),
	position: rd(`${RUN}/switch`) || 'unknown',
	on: tget('switch_on', 'exitnode'),
	off: tget('switch_off', 'direct')
};

// ---- travelmate (Wi-Fi uplink and login-page detection) ------------------
let trm = pj(readfile(TRM)).data ?? {};
let trm_status = trm.travelmate_status ?? '';

// ---- uplinks ---------------------------------------------------------------
let ifaces = {};
for (let i in (bus.call('network.interface', 'dump', {})?.interface ?? []))
	ifaces[i.interface] = i;

function has_default(i) {
	for (let r in (i?.route ?? []))
		if (r.target == '0.0.0.0' && r.mask == 0) return true;
	return false;
}

let uplinks = [];

let wan = ifaces.wan;
let carrier = rd('/sys/class/net/eth0/carrier');
push(uplinks, {
	name: 'wan', kind: 'ethernet', label: 'Ethernet', present: true,
	up: !!wan?.up, online: !!wan?.up && has_default(wan),
	// the saved order (what the panel shows and sorts by); an interface that is down has no live metric
	metric: +(uci.get('network', 'wan', 'metric') ?? 10),
	live_metric: wan?.metric,
	detail: (carrier != '1') ? 'No cable' : (wan?.up ? '' : 'Connecting…')
});

let ww = ifaces.trm_wwan;
let wifi_up = { name: 'trm_wwan', kind: 'wifi', label: 'Wi-Fi', present: true,
	up: !!ww?.up, online: !!ww?.up && match(trm_status, /net ok/) != null,
	metric: +(uci.get('network', 'trm_wwan', 'metric') ?? 20),
	live_metric: ww?.metric };
if (ww?.up && ww.l3_device) {
	let info = bus.call('iwinfo', 'info', { device: ww.l3_device }) ?? {};
	wifi_up.ssid = info.ssid;
	wifi_up.signal = info.signal;
	wifi_up.channel = info.channel;
	wifi_up.band = info.frequency ? band_of(info.frequency) : null;
	wifi_up.quality = (info.quality_max > 0) ? int(info.quality * 100 / info.quality_max) : null;
}
if (!ww?.up)
	wifi_up.detail = match(trm_status, /processing/) ? 'Connecting…' : 'Not connected';
else if (match(trm_status, /net cp/))
	wifi_up.detail = 'Login page';
push(uplinks, wifi_up);

let tether = null;
for (let n, i in ifaces)
	if (index(n, 'tether_') == 0 && (!tether || i.up)) tether = i;
push(uplinks, {
	name: 'tether', kind: 'phone', label: 'Phone over USB', present: !!tether,
	up: !!tether?.up, online: !!tether?.up && has_default(tether),
	metric: +tget('tether_metric', '30'),
	live_metric: tether?.metric,
	detail: tether ? (tether.up ? '' : 'Connecting…') : 'Plug in and unlock your phone'
});
st.uplinks = uplinks;

// ---- the address each uplink shows the network (More, "MAC address the network sees") ------------------
// saved: what the router is told to use (null = the router's own); now: the address in use; kind: original,
// random (one the panel made up) or custom. The Wi-Fi's belongs to the network it is connected to.
let made_up = map(uci.get('travel', 'main', 'mac_random') ?? [], (m) => lc(m));
function mac_kind(saved) { return !saved ? 'original' : (index(made_up, lc(saved)) >= 0 ? 'random' : 'custom'); }
let wifi_saved = null;
if (wifi_up.ssid)
	uci.foreach('travelmate', 'uplink', (s) => { if (s.ssid == wifi_up.ssid && s.macaddr) wifi_saved = lc(s.macaddr); });
let eth_saved = null;
uci.foreach('network', 'device', (s) => { if (s.name == 'eth0' && s.macaddr) eth_saved = lc(s.macaddr); });
st.mac = {
	wifi: { ssid: wifi_up.ssid ?? null, saved: wifi_saved, kind: mac_kind(wifi_saved),
		now: (ww?.up && ww.l3_device) ? (rd(`/sys/class/net/${ww.l3_device}/address`) || null) : null },
	ethernet: { saved: eth_saved, kind: mac_kind(eth_saved), now: rd('/sys/class/net/eth0/address') || null }
};

// the source actually carrying traffic: lowest metric with a default route
let active = null;
for (let n in ['wan', 'trm_wwan']) {
	let i = ifaces[n];
	if (i?.up && has_default(i) && (!active || i.metric < active.metric)) active = i;
}
if (tether?.up && has_default(tether) && (!active || tether.metric < active.metric)) active = tether;
let active_name = active ? ((index(active.interface, 'tether_') == 0) ? 'tether' : active.interface) : '';
st.internet = {
	online: !!active && (active.interface != 'trm_wwan' || match(trm_status, /net ok/) != null),
	uplink: active_name,
	failover: false
};

// routed around an uplink with no internet (health.uc, since 2026-10-08): that one reads "No internet" and
// the backup carries the traffic, whatever the metrics say
let detour = pj(readfile(`${RUN}/failover`) ?? '');
if (detour?.from && detour?.to) {
	let short = (n) => (index(n, 'tether_') == 0) ? 'tether' : n;
	for (let u in uplinks)
		if (u.name == short(detour.from)) {
			u.online = false;
			u.detail = 'No internet';
		}
	st.internet = { online: true, uplink: short(detour.to),
		failover: { from: short(detour.from), to: short(detour.to), since: detour.since } };
}

// ---- Wi-Fi login page (hotel, plane, campus) -----------------------------------------------------
let cp = match(trm_status, /net cp '([^']+)'/);
let phost = portal_file[0] || (cp ? cp[1] : '');
st.portal = {
	state: (stat(`${RUN}/portal`) || cp) ? 'detected' : (trm_status ? 'none' : 'unknown'),
	host: phost,
	// A portal's bare address is not its login page: UniFi answers 400 without the
	// session code it adds when it catches a request (found 2026-10-05). The panel
	// opens a plain-http page instead (neverssl.com), which the hotel redirects.
	url: '',
	since: +(portal_file[1] || 0)
};
// Automatic login on the current Wi-Fi uplink: the method only, never the code (the
// panel reads that with login_get, which needs the write permission), and how the
// last attempt went, from the login script's own record (2026-10-06)
let cur_ssid = wifi_up.ssid ?? split(trm.station_id ?? '', '/')[1] ?? '';
let al_method = 'none';
uci.foreach('travelmate', 'uplink', (s) => {
	if (cur_ssid && s.ssid == cur_ssid && match(s.script ?? '', /^\/etc\/travelmate\/[a-z0-9-]+\.login$/))
		al_method = replace(replace(s.script, /^.*\//, ''), /\.login$/, '');
});
let al_last = pj(readfile(`${RUN}/autologin.json`));
st.portal.autologin = {
	ssid: cur_ssid,
	method: al_method,
	// only a try on this network with the method set now: after a switch, the old
	// method's failure is not news about the new one (2026-10-06)
	last: (al_last.ssid && al_last.ssid == cur_ssid && al_last.method == al_method) ? { result: al_last.result, at: +al_last.at } : null
};

// ---- live speed of the active source (bytes since the previous report) ----
st.speed = { rx_bps: 0, tx_bps: 0, uplink: active_name };
let dev = active?.l3_device;
if (dev) {
	let rx = +rd(`/sys/class/net/${dev}/statistics/rx_bytes`);
	let tx = +rd(`/sys/class/net/${dev}/statistics/tx_bytes`);
	let prev = split(rd(`${RUN}/speed`), ' ');
	let now = time();
	if (prev[0] == dev && +prev[1] < now) {
		let dt = now - +prev[1];
		let drx = rx - +prev[2], dtx = tx - +prev[3];
		st.speed.rx_bps = (drx > 0) ? int(drx * 8 / dt) : 0;
		st.speed.tx_bps = (dtx > 0) ? int(dtx * 8 / dt) : 0;
	}
	writefile(`${RUN}/speed`, `${dev} ${now} ${rx} ${tx}`);
}

// ---- your Wi-Fi -------------------------------------------------------------
let wstat = bus.call('network.wireless', 'status', {}) ?? {};
let radios = [], ap_ifnames = {}, sta_radio = {};
for (let rname, r in wstat) {
	for (let ifc in (r.interfaces ?? [])) {
		if (ifc.config?.mode == 'ap' && ifc.ifname) ap_ifnames[ifc.ifname] = r.config?.band;
		if (ifc.config?.mode == 'sta' && ifc.ifname && ww?.up && ifc.ifname == ww.l3_device)
			sta_radio[rname] = true;
	}
}
let ap_ssid = null;
uci.foreach('wireless', 'wifi-iface', (s) => {
	if (s.mode == 'ap' && s.disabled != '1' && ap_ssid == null) ap_ssid = s.ssid;
});
uci.foreach('wireless', 'wifi-device', (s) => {
	let live = wstat[s['.name']]?.interfaces ?? [];
	let chan = s.channel ?? 'auto';
	for (let ifc in live) {
		if (!ifc.ifname) continue;
		let info = bus.call('iwinfo', 'info', { device: ifc.ifname });
		if (info?.channel) { chan = info.channel; break; }
	}
	push(radios, {
		band: s.band, channel: chan,
		auto: (s.channel ?? 'auto') == 'auto',
		locked: !!sta_radio[s['.name']]
	});
});
let ctry = split(rd(`${RUN}/country`), '\n');
st.wifi = {
	ssid: ap_ssid,
	country: uci.get('wireless', 'radio0', 'country') ?? '',
	country_detected: ctry[0] ?? '',
	country_source: ctry[1] ?? '',
	radios
};

// ---- devices -----------------------------------------------------------------
let devices = {};
function devrec(mac) {
	mac = lc(mac);
	devices[mac] ??= { mac, name: '', ip: '', band: null, signal: null, blocked: false, rx_bytes: 0, tx_bytes: 0, online: false };
	return devices[mac];
}
for (let line in split(readfile('/tmp/dhcp.leases') ?? '', '\n')) {
	let f = split(line, ' ');
	if (length(f) < 4) continue;
	let d = devrec(f[1]);
	d.ip = f[2];
	if (f[3] != '*') d.name = f[3];
}
for (let ifname, band in ap_ifnames) {
	for (let c in (bus.call('iwinfo', 'assoclist', { device: ifname })?.results ?? [])) {
		let d = devrec(c.mac);
		d.band = band;
		d.signal = c.signal;
		d.online = true;
	}
}
uci.foreach('dhcp', 'host', (s) => {
	for (let m in (type(s.mac) == 'array' ? s.mac : split(s.mac ?? '', ' ')))
		if (m && s.name) devrec(m).name = s.name;
});
uci.foreach('firewall', 'rule', (s) => {
	if (index(s['.name'], 'travel_block_') == 0 && s.src_mac)
		devrec(type(s.src_mac) == 'array' ? s.src_mac[0] : s.src_mac).blocked = true;
});
// what Corey said a device is (the panel's Type); only for devices already known,
// so a type set long ago does not bring back a device that has gone
uci.foreach('travel', 'device', (s) => {
	let d = s.mac ? devices[lc(s.mac)] : null;
	if (d && s.kind) d.kind = s.kind;
});
// the system a device runs, from how it asked for its address (its DHCP
// fingerprint, noted by hotplug.d/dhcp/50-travel-fingerprint); for the icon when
// its name says nothing. Apple sends no vendor class: iPhones and iPads ask for
// 1,121,3,6,15,...,252 and a Mac asks for the same plus 95,44,46.
function system_of(vendor, opts) {
	let v = lc(vendor ?? ''), o = opts ?? '';
	let m = match(v, /^android-dhcp-([0-9]+)/);
	if (m) return { os: 'android', ver: m[1] };
	if (index(v, 'msft') == 0) return { os: 'windows' };
	if (index(v, 'udhcp') == 0 || index(v, 'dhcpcd') == 0) return { os: 'linux' };
	if (v == '' && match(o, /^1,121,3,6,15(,|$)/))
		return { os: match(o, /(^|,)(95|44|46)(,|$)/) ? 'macos' : 'ios' };
	return null;
}
for (let f in (lsdir(`${RUN}/fp`) ?? [])) {
	if (!match(f, /^[0-9a-f]{12}$/)) continue;
	let d = devices[join(':', map([ 0, 2, 4, 6, 8, 10 ], (i) => substr(f, i, 2)))];
	if (!d) continue;	// only devices we already know
	let kv = {};
	for (let line in split(readfile(`${RUN}/fp/${f}`) ?? '', '\n')) {
		let i = index(line, '=');
		if (i > 0) kv[substr(line, 0, i)] = substr(line, i + 1);
	}
	let sys = system_of(kv.vendor, kv.opts);
	if (sys) {
		d.os = sys.os;
		if (sys.ver) d.os_ver = sys.ver;
	}
}
let nl = pj(sh('nlbw -c json -g mac 2>/dev/null'));
let col = {};
for (let i, c in (nl.columns ?? [])) col[c] = i;
if (col.mac != null) {
	for (let row in (nl.data ?? [])) {
		if (!devices[lc(row[col.mac])]) continue;	// only devices we can name
		let d = devrec(row[col.mac]);
		d.rx_bytes = row[col.rx_bytes] ?? 0;
		d.tx_bytes = row[col.tx_bytes] ?? 0;
	}
}
st.devices = sort(values(devices), (a, b) => (b2i(b.online) - b2i(a.online)) || (b.rx_bytes - a.rx_bytes));

// ---- Tailscale ---------------------------------------------------------------
let ts = pj(sh('tailscale status --json 2>/dev/null'));
let labels = {};
for (let l in (uci.get('travel', 'main', 'label') ?? [])) {
	let kv = match(l, /^([^=]+)=(.*)$/);
	if (kv) labels[kv[1]] = kv[2];
}
function v4(ips) {
	for (let ip in (ips ?? [])) if (index(ip, '.') >= 0) return ip;
	return (ips ?? [])[0];
}
let exits = [];
for (let k, p in (ts.Peer ?? {})) {
	if (!p.ExitNodeOption) continue;
	let short = split(p.DNSName ?? '', '.')[0];
	push(exits, {
		name: p.HostName,
		label: labels[p.HostName] ?? labels[short] ?? p.HostName,
		ip: v4(p.TailscaleIPs),
		online: !!p.Online,
		active: !!p.ExitNode
	});
}
st.tailscale = {
	state: ts.BackendState ?? 'NoState',
	ip: v4(ts.Self?.TailscaleIPs) ?? '',
	name: ts.Self?.HostName ?? '',
	auth_url: ts.AuthURL ?? '',
	exit_nodes: sort(exits, (a, b) => (b2i(b.online) - b2i(a.online)) || ((a.label < b.label) ? -1 : 1))
};

// ---- UniFi WireGuard profiles --------------------------------------------------
let wgs = [];
uci.foreach('network', 'interface', (s) => {
	if (s.proto != 'wireguard' || !s.travel_label) return;
	let n = s['.name'], ep = '';
	uci.foreach('network', `wireguard_${n}`, (p) => {
		if (!ep && p.endpoint_host) ep = `${p.endpoint_host}:${p.endpoint_port ?? 51820}`;
	});
	let hs = 0;
	for (let line in split(sh(`wg show ${n} latest-handshakes 2>/dev/null`), '\n')) {
		let t = +(split(line, '\t')[1] ?? 0);
		if (t > hs) hs = t;
	}
	push(wgs, { name: n, label: s.travel_label, up: !!ifaces[n]?.up, endpoint: ep, handshake: hs });
});
st.wireguard = wgs;

// ---- "look like one device" (TTL) -----------------------------------------------
st.hide_router = tget('hide_router', '1') == '1';

// ---- nikki -------------------------------------------------------------------
st.nikki = {
	installed: !!stat('/etc/init.d/nikki'),
	running: stat('/etc/init.d/nikki') ? system('/etc/init.d/nikki running >/dev/null 2>&1') == 0 : false
};

printf('%J\n', st);
