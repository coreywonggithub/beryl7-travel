'use strict';
// Nearby Wi-Fi for the panel's "Choose Wi-Fi". Usage: scan.uc [2g|5g|all]
// The argument says which band to scan now; the answer is always every network the radios have
// heard in the last 30 s (the kernel forgets older ones), one entry per network name and band,
// so a network on both bands offers both (2026-10-05: one entry per name kept the stronger
// 2.4 GHz access point and hid the 5 GHz one the router was connected to).
// The panel asks for 2.4 GHz first (about 1 s on the router), then 5 GHz (about 6 s), and shows
// the list after each (Corey, 2026-10-06: show networks as they come in). Until then the search
// read its results with iwinfo, whose scan call runs a fresh scan of its own: 19.3 s in all,
// against 7 s now (measured on the router 2026-10-06).
// A radio running its own access point stays on its channel unless asked with ap-force (found on
// the router 2026-10-05: a 5 GHz-only uplink on channel 157 never appeared), so each band is
// scanned through its access point, or through a station on that band when there is none.

import { cursor } from 'uci';
import { popen } from 'fs';

let uci = cursor();
let want = ARGV[0] ?? 'all';

let saved = {};
uci.foreach('wireless', 'wifi-iface', (s) => {
	if (s.mode == 'sta' && s.ssid) saved[s.ssid] = true;
});

function run(cmd) {
	let p = popen(cmd);
	if (!p) return { out: '', rc: -1 };
	let out = p.read('all') ?? '';
	let rc = p.close();
	return { out, rc };
}

function band_of(freq) {
	return (freq < 3000) ? '2g' : '5g';	// no 6 GHz radio on this router
}

function channel_of(freq) {
	if (freq == 2484) return 14;
	if (freq >= 2412 && freq < 2484) return int((freq - 2407) / 5);
	if (freq >= 5000 && freq < 5900) return int((freq - 5000) / 5);
	return 0;
}

// the router's Wi-Fi interfaces, from "iw dev": name, phy, type and the band it is on now
function interfaces() {
	let list = [], phy = '', cur = null;
	for (let line in split(run('iw dev 2>/dev/null').out, '\n')) {
		let m = match(line, /^phy#([0-9]+)/);
		if (m) { phy = m[1]; continue; }
		m = match(line, /^\tInterface ([A-Za-z0-9._-]+)$/);
		if (m) { cur = { name: m[1], phy, type: '', band: '' }; push(list, cur); continue; }
		if (!cur) continue;
		m = match(line, /^\t\ttype (.+)$/);
		if (m) { cur.type = m[1]; continue; }
		m = match(line, /^\t\tchannel [0-9]+ \(([0-9]+) MHz\)/);
		if (m) cur.band = band_of(+m[1]);
	}
	return list;
}

// One band's scan. Busy (another scan is running, e.g. travelmate's): wait a second and try
// again, three tries at most; the list is read either way.
function scan_band(ifs, b) {
	let dev = null;
	for (let i in ifs) if (i.band == b && i.type == 'AP') { dev = i; break; }
	if (!dev) for (let i in ifs) if (i.band == b) { dev = i; break; }
	if (!dev) return;
	let cmd = sprintf('iw dev %s scan%s >/dev/null 2>&1', dev.name, (dev.type == 'AP') ? ' ap-force' : '');
	for (let n = 0; n < 3; n++) {
		if (run(cmd).rc == 0) return;
		if (n < 2) run('sleep 1');
	}
}

// iw prints a byte that is not plain printable ASCII as \xNN (so every non-English name, in UTF-8),
// and a backslash, or a space at either end, the same way
function unescape(s) {
	return replace(s, /\\x([0-9a-fA-F][0-9a-fA-F])/g, (m, h) => chr(hex(h)));
}

function security(n) {
	if (!n.rsn && !n.wpa) return n.privacy ? 'psk' : 'open';	// WEP lists as a password network, as before
	let a = n.akm;
	if (match(a, /802\.1X|EAP|SUITE-B/)) return 'enterprise';
	let sae = !!match(a, /SAE/), psk = !!match(a, /PSK/);
	if (sae && psk) return 'sae-mixed';
	if (sae) return 'sae';
	if (match(a, /OWE/)) return 'owe';
	return 'psk';
}

let ifs = interfaces();
if (want == '2g' || want == 'all') scan_band(ifs, '2g');
if (want == '5g' || want == 'all') scan_band(ifs, '5g');

let best = {};
function add(n) {
	if (!n?.freq || n.ssid == null) return;	// no name heard: hidden networks are joined by name instead
	if (n.ssid == '' || match(n.ssid, /^(\\x00)+$/)) return;
	let ssid = unescape(n.ssid);
	let b = band_of(n.freq);
	// iwinfo's scale, which the panel's words for signal strength were made for: dBm + 110, 0 to 70
	let q = int(min(max(n.signal + 110, 0), 70) * 100 / 70);
	let k = ssid + '\n' + b;
	if (best[k] && best[k].quality >= q) return;
	best[k] = {
		ssid, bssid: n.bssid, band: b, channel: channel_of(n.freq),
		quality: q, security: security(n), saved: !!saved[ssid]
	};
}

// every phy keeps its own list: read it once per phy, through any of its interfaces
let read = {};
for (let i in ifs) {
	if (read[i.phy]) continue;
	read[i.phy] = true;
	let n = null;
	for (let line in split(run(sprintf('iw dev %s scan dump 2>/dev/null', i.name)).out, '\n')) {
		let m = match(line, /^BSS ([0-9a-f:]{17})/);
		if (m) {
			add(n);
			n = { bssid: m[1], ssid: null, freq: 0, signal: -110, privacy: false, rsn: false, wpa: false, akm: '' };
			continue;
		}
		if (!n) continue;
		if ((m = match(line, /^\tfreq: ([0-9]+)/))) n.freq = +m[1];
		else if ((m = match(line, /^\tsignal: (-?[0-9.]+) dBm/))) n.signal = +m[1];
		else if ((m = match(line, /^\tSSID: ?(.*)$/))) { if (n.ssid == null) n.ssid = m[1]; }
		else if ((m = match(line, /^\tcapability: (.*)$/))) n.privacy = !!match(m[1], /Privacy/);
		else if (match(line, /^\tRSN:/)) n.rsn = true;
		else if (match(line, /^\tWPA:/)) n.wpa = true;
		if ((m = match(line, /Authentication suites: (.*)$/))) n.akm += ' ' + m[1];
	}
	add(n);
}

printf('%J\n', { ok: true, networks: sort(values(best), (a, b) => b.quality - a.quality) });
