'use strict';
'require view';
'require rpc';
'require poll';
'require ui';

/*
 * Travel panel for the Beryl 7 (luci-app-travel).
 *
 * The page talks to the router only through the ubus object "travel"
 * (see docs/panel-api.md). It shows measured state from "status" and never
 * what it last sent: every command is followed by a fresh status read.
 *
 * Notes for anyone editing this file:
 *  - Text that comes from the network (SSIDs, device names, login page URLs) is
 *    untrusted. LuCI's E() treats a bare string child as HTML, so every child
 *    goes through h() below, which only ever creates text nodes.
 *  - LuCI's E() also turns null items inside a child array into the text
 *    "null". h() drops null, undefined and false children for that reason.
 *  - A poll must never rebuild something the user is touching. Lists are
 *    reconciled by key (syncRows) and forms are built once and left alone.
 *  - No em dashes or emoji in copy. Sentence case. No "please".
 */

/* ------------------------------------------------------------------ *
 *  Constants
 * ------------------------------------------------------------------ */

const POLL_SECONDS = 5;
const SPEED_SAMPLES = 40;
const SAMPLE_GAP_MS = 4000;
const MIN_BUSY_MS = 350;
const FOLLOW_UPS_MS = [ 1500, 4000 ];
const SEP = ' \u00B7 ';
const FALLBACK_LOGIN_URL = 'http://neverssl.com/';

const MODES = [ 'direct', 'exitnode', 'wireguard', 'nikki' ];

const MODE_LABEL = {
	direct: _('Direct'),
	exitnode: _('Tailscale exit'),
	wireguard: _('VPN'),
	nikki: _('nikki (China)')
};

/* The name a VPN profile gets when none is typed. */
const DEFAULT_VPN_LABEL = 'VPN';

const NO_ANSWER = _('The router did not answer. Check that you are still on its Wi-Fi, then try again.');
const RESTARTING = _('The router is restarting its Wi-Fi. Reconnect to it, then reload this page.');
const GENERIC_ERROR = _('That did not work. Try again.');

/* Channels offered in the picker. The router checks them against the country
 * rules, so this list only has to be safe, not complete: no radar-wait (DFS)
 * channels, and the ones every country allows. The current channel is always
 * added to the list. */
const CHANNELS = {
	'2g': [ 1, 6, 11 ],
	'5g': [ 36, 40, 44, 48 ]
};

const COUNTRIES = [
	[ 'AL', 'Albania' ], [ 'DZ', 'Algeria' ], [ 'AR', 'Argentina' ], [ 'AM', 'Armenia' ],
	[ 'AU', 'Australia' ], [ 'AT', 'Austria' ], [ 'AZ', 'Azerbaijan' ], [ 'BH', 'Bahrain' ],
	[ 'BD', 'Bangladesh' ], [ 'BY', 'Belarus' ], [ 'BE', 'Belgium' ], [ 'BO', 'Bolivia' ],
	[ 'BA', 'Bosnia and Herzegovina' ], [ 'BR', 'Brazil' ], [ 'BN', 'Brunei' ],
	[ 'BG', 'Bulgaria' ], [ 'KH', 'Cambodia' ], [ 'CA', 'Canada' ], [ 'CL', 'Chile' ],
	[ 'CN', 'China' ], [ 'CO', 'Colombia' ], [ 'CR', 'Costa Rica' ], [ 'HR', 'Croatia' ],
	[ 'CY', 'Cyprus' ], [ 'CZ', 'Czechia' ], [ 'DK', 'Denmark' ], [ 'DO', 'Dominican Republic' ],
	[ 'EC', 'Ecuador' ], [ 'EG', 'Egypt' ], [ 'SV', 'El Salvador' ], [ 'EE', 'Estonia' ],
	[ 'FI', 'Finland' ], [ 'FR', 'France' ], [ 'GE', 'Georgia' ], [ 'DE', 'Germany' ],
	[ 'GR', 'Greece' ], [ 'GT', 'Guatemala' ], [ 'HK', 'Hong Kong' ], [ 'HU', 'Hungary' ],
	[ 'IS', 'Iceland' ], [ 'IN', 'India' ], [ 'ID', 'Indonesia' ], [ 'IE', 'Ireland' ],
	[ 'IL', 'Israel' ], [ 'IT', 'Italy' ], [ 'JP', 'Japan' ], [ 'JO', 'Jordan' ],
	[ 'KZ', 'Kazakhstan' ], [ 'KE', 'Kenya' ], [ 'KR', 'South Korea' ], [ 'KW', 'Kuwait' ],
	[ 'LA', 'Laos' ], [ 'LV', 'Latvia' ], [ 'LB', 'Lebanon' ], [ 'LI', 'Liechtenstein' ],
	[ 'LT', 'Lithuania' ], [ 'LU', 'Luxembourg' ], [ 'MO', 'Macao' ], [ 'MY', 'Malaysia' ],
	[ 'MT', 'Malta' ], [ 'MX', 'Mexico' ], [ 'MD', 'Moldova' ], [ 'MC', 'Monaco' ],
	[ 'MN', 'Mongolia' ], [ 'ME', 'Montenegro' ], [ 'MA', 'Morocco' ], [ 'NP', 'Nepal' ],
	[ 'NL', 'Netherlands' ], [ 'NZ', 'New Zealand' ], [ 'NG', 'Nigeria' ],
	[ 'MK', 'North Macedonia' ], [ 'NO', 'Norway' ], [ 'OM', 'Oman' ], [ 'PK', 'Pakistan' ],
	[ 'PA', 'Panama' ], [ 'PY', 'Paraguay' ], [ 'PE', 'Peru' ], [ 'PH', 'Philippines' ],
	[ 'PL', 'Poland' ], [ 'PT', 'Portugal' ], [ 'QA', 'Qatar' ], [ 'RO', 'Romania' ],
	[ 'RU', 'Russia' ], [ 'SA', 'Saudi Arabia' ], [ 'RS', 'Serbia' ], [ 'SG', 'Singapore' ],
	[ 'SK', 'Slovakia' ], [ 'SI', 'Slovenia' ], [ 'ZA', 'South Africa' ], [ 'ES', 'Spain' ],
	[ 'LK', 'Sri Lanka' ], [ 'SE', 'Sweden' ], [ 'CH', 'Switzerland' ], [ 'TW', 'Taiwan' ],
	[ 'TH', 'Thailand' ], [ 'TR', 'Turkey' ], [ 'UA', 'Ukraine' ],
	[ 'AE', 'United Arab Emirates' ], [ 'GB', 'United Kingdom' ], [ 'US', 'United States' ],
	[ 'UY', 'Uruguay' ], [ 'UZ', 'Uzbekistan' ], [ 'VN', 'Vietnam' ]
];

const TS_STATE = {
	Running: [ 'ok', _('Connected') ],
	NeedsLogin: [ 'warn', _('Login needed') ],
	NeedsMachineAuth: [ 'warn', _('Waiting for approval') ],
	Stopped: [ 'idle', _('Stopped') ],
	Starting: [ 'idle', _('Starting') ],
	NoState: [ 'idle', _('Not ready') ]
};

/* ------------------------------------------------------------------ *
 *  Backend: one rpc function per method of the ubus object "travel"
 * ------------------------------------------------------------------ */

const CMD_EXPECT = { '': { ok: false, error: NO_ANSWER } };

const callStatus = rpc.declare({ object: 'travel', method: 'status', expect: { '': {} } });

const callSetMode = rpc.declare({ object: 'travel', method: 'set_mode', params: [ 'mode', 'exit_node', 'wg' ], expect: CMD_EXPECT });
/* nobatch: LuCI sends calls made together as one request and answers when the slowest
 * is done, so the saved networks waited 10 to 20 s for the search (2026-10-06) */
const callWifiScan = rpc.declare({ object: 'travel', method: 'wifi_scan', params: [ 'band' ], expect: CMD_EXPECT, nobatch: true });
const callWifiJoin = rpc.declare({ object: 'travel', method: 'wifi_join', params: [ 'ssid', 'band', 'security', 'bssid', 'key', 'identity', 'password' ], expect: CMD_EXPECT });
const callWifiForget = rpc.declare({ object: 'travel', method: 'wifi_forget', params: [ 'ssid' ], expect: CMD_EXPECT });
const callWifiSaved = rpc.declare({ object: 'travel', method: 'wifi_saved', expect: CMD_EXPECT });
const callLoginGet = rpc.declare({ object: 'travel', method: 'login_get', params: [ 'ssid' ], expect: CMD_EXPECT });
const callLoginSet = rpc.declare({ object: 'travel', method: 'login_set', params: [ 'ssid', 'method', 'code', 'user' ], expect: CMD_EXPECT });
const callSetAp = rpc.declare({ object: 'travel', method: 'set_ap', params: [ 'ssid', 'key', 'country' ], expect: CMD_EXPECT });
const callSetChannel = rpc.declare({ object: 'travel', method: 'set_channel', params: [ 'band', 'channel' ], expect: CMD_EXPECT });
const callMac = rpc.declare({ object: 'travel', method: 'mac', params: [ 'target', 'action', 'mac' ], expect: CMD_EXPECT });
const callDeviceBlock = rpc.declare({ object: 'travel', method: 'device_block', params: [ 'mac', 'blocked' ], expect: CMD_EXPECT });
const callDeviceRename = rpc.declare({ object: 'travel', method: 'device_rename', params: [ 'mac', 'name' ], expect: CMD_EXPECT });
const callDeviceKind = rpc.declare({ object: 'travel', method: 'device_kind', params: [ 'mac', 'kind' ], expect: CMD_EXPECT });
const callTailscaleLogin = rpc.declare({ object: 'travel', method: 'tailscale_login', expect: CMD_EXPECT });
const callTailscaleLogout = rpc.declare({ object: 'travel', method: 'tailscale_logout', expect: CMD_EXPECT });
const callWgImport = rpc.declare({ object: 'travel', method: 'wg_import', params: [ 'label', 'conf' ], expect: CMD_EXPECT });
const callWgDelete = rpc.declare({ object: 'travel', method: 'wg_delete', params: [ 'name' ], expect: CMD_EXPECT });
const callUplinkOrder = rpc.declare({ object: 'travel', method: 'uplink_order', params: [ 'order' ], expect: CMD_EXPECT });
const callSetHideRouter = rpc.declare({ object: 'travel', method: 'set_hide_router', params: [ 'enabled' ], expect: CMD_EXPECT });
const callSetRegion = rpc.declare({ object: 'travel', method: 'set_region', params: [ 'region', 'world_mode' ], expect: CMD_EXPECT });

/* Runs one command. Never rejects: a lost connection becomes
 * { ok: false, transport: true, error: ... } so the caller has one shape to handle. */
function send(fn /* , args... */) {
	const args = Array.prototype.slice.call(arguments, 1);

	return fn.apply(null, args).then(function(res) {
		if (res != null && typeof(res) == 'object' && !Array.isArray(res))
			return res;

		return { ok: false, error: NO_ANSWER };
	}, function() {
		return { ok: false, transport: true, error: NO_ANSWER };
	});
}

/* send() with a longer request limit, for this call only. The Wi-Fi search scanned
 * both radios around a live connection and took 20 s on the hardware (2026-10-05),
 * exactly LuCI's request limit, so the panel said the router did not answer. Since
 * 2026-10-06 it asks one band at a time (about 1 s and 6 s), but a crowded place
 * takes longer; the router allows 60 s too. Every other call keeps the short limit,
 * so a router that is really gone shows quickly. */
function sendSlow(seconds, fn /* , args... */) {
	const prev = L.env.rpctimeout;

	L.env.rpctimeout = Math.max(prev ?? 20, seconds);

	return send.apply(null, Array.prototype.slice.call(arguments, 1)).finally(function() {
		L.env.rpctimeout = prev;
	});
}

/* ------------------------------------------------------------------ *
 *  Small helpers: values
 * ------------------------------------------------------------------ */

function O(v) { return (v != null && typeof(v) == 'object' && !Array.isArray(v)) ? v : {}; }
function A(v) { return Array.isArray(v) ? v : []; }
function num(v) { return (typeof(v) == 'number' && isFinite(v)) ? v : null; }

/* A channel arrives as a number (read from the radio) or as a string (read from
 * the config, so "36" or "auto"). Returns a number, or null when there is none. */
function toChannel(v) {
	const n = (typeof(v) == 'string' && /^\d+$/.test(v)) ? parseInt(v, 10) : v;

	return (typeof(n) == 'number' && isFinite(n) && n > 0) ? n : null;
}
function str(v) { return (typeof(v) == 'string') ? v : (v == null ? '' : String(v)); }
function hasData(st) { return Object.keys(O(st)).length > 0; }
function join(parts) { return parts.filter(Boolean).join(SEP); }

let uidCounter = 0;
function uid(prefix) { return 'tp-' + prefix + '-' + (++uidCounter); }

/* Only http(s) links are ever opened. Login page addresses come from the
 * network being joined, so a "javascript:" address must never reach an href. */
function safeUrl(u) {
	try {
		const url = new URL(str(u));
		return (url.protocol == 'http:' || url.protocol == 'https:') ? url.href : null;
	}
	catch (e) {
		return null;
	}
}

function reportBug(err) {
	if (window.console && console.error)
		console.error(err);

	const msg = (err && err.message) ? err.message : String(err);

	if (reportBug.seen[msg])
		return;

	reportBug.seen[msg] = true;
	ui.addNotification(_('Travel panel error'), E('pre', {}, [ msg ]), 'danger');
}
reportBug.seen = {};

/* ------------------------------------------------------------------ *
 *  Small helpers: DOM
 * ------------------------------------------------------------------ */

const BOOLEAN_ATTRS = { disabled: 1, hidden: 1, readonly: 1, required: 1, checked: 1, selected: 1, multiple: 1 };

function addKids(el, kids) {
	if (Array.isArray(kids))
		kids.forEach(function(k) { addKids(el, k); });
	else if (kids == null || kids === false || kids === true)
		return;
	else if (kids.nodeType)
		el.appendChild(kids);
	else
		el.appendChild(document.createTextNode(String(kids)));
}

/* h('div', { class: 'x', click: fn }, [ children ]) - E() with the quirks removed. */
function h(tag, attrs, kids) {
	const a = {};

	if (attrs)
		Object.keys(attrs).forEach(function(k) {
			const v = attrs[k];

			if (v == null || v === false)
				return;

			a[k] = (v === true) ? (BOOLEAN_ATTRS[k] ? '' : 'true') : v;
		});

	const el = E(tag, a);

	if (kids != null)
		addKids(el, kids);

	return el;
}

function clear(el) {
	while (el.firstChild)
		el.removeChild(el.firstChild);

	return el;
}

function setText(el, text) {
	text = str(text);

	if (el.textContent !== text)
		el.textContent = text;
}

function toggleHidden(el, hide) {
	if (hide)
		el.setAttribute('hidden', '');
	else
		el.removeAttribute('hidden');
}

function setPill(el, tone, text) {
	const cls = 'tp-pill ' + tone;

	if (el.className !== cls)
		el.className = cls;

	setText(el, text);
}

function pill(tone, text) {
	return h('span', { class: 'tp-pill ' + tone }, text);
}

function setSelectValue(sel, value) {
	if (!Array.prototype.some.call(sel.options, function(o) { return o.value === value; }))
		sel.appendChild(h('option', { value: value }, value));

	sel.value = value;
}

function isFocused(el) {
	return document.activeElement === el;
}

/* Marks a control busy while a command runs (spinner, disabled). */
function setBusy(b, on) {
	if (!b)
		return;

	if (on) {
		b._tpDisabled = b.disabled;
		b.classList.add('is-busy');
		b.setAttribute('aria-busy', 'true');
		b.disabled = true;
	}
	else {
		b.classList.remove('is-busy');
		b.removeAttribute('aria-busy');
		b.disabled = !!b._tpDisabled;
		b._tpDisabled = false;
	}
}

/* A small inline message near a control. Amber by default. */
function msgSlot() {
	const el = h('p', { class: 'tp-note', role: 'status', hidden: true });

	return {
		el: el,
		show: function(msg, tone) {
			el.className = 'tp-note ' + (tone || 'warn');
			el.textContent = msg;
			el.removeAttribute('hidden');
		},
		clear: function() {
			el.textContent = '';
			el.setAttribute('hidden', '');
		}
	};
}

/* For messages that come from status and are re-evaluated on every poll. */
function setNote(el, msg) {
	setText(el, msg);
	toggleHidden(el, !msg);
}

/*
 * Keeps a list of child nodes in step with an array of items without
 * rebuilding rows that did not change.
 *
 *   key(item)            unique string per row
 *   make(item)           builds a new row element
 *   patch(el, item)      updates a row in place (patch mode), or
 *   sig(item)            a string; the row is rebuilt only when it changes
 */
function syncRows(container, items, o) {
	const old = {};
	const seen = {};
	const used = {};

	Array.prototype.forEach.call(container.children, function(c) {
		old[c.getAttribute('data-key')] = c;
	});

	let cursor = container.firstElementChild;

	items.forEach(function(item) {
		let key = o.key(item);

		if (seen[key])
			key += '#' + (++seen[key]);
		else
			seen[key] = 1;

		let el = old[key];

		if (el) {
			if (o.sig) {
				const sig = o.sig(item);

				if (el.getAttribute('data-sig') !== sig) {
					const fresh = o.make(item);
					fresh.setAttribute('data-key', key);
					fresh.setAttribute('data-sig', sig);
					container.replaceChild(fresh, el);

					if (el === cursor)
						cursor = fresh;

					el = fresh;
				}
			}
			else if (o.patch) {
				o.patch(el, item);
			}
		}
		else {
			el = o.make(item);
			el.setAttribute('data-key', key);

			if (o.sig)
				el.setAttribute('data-sig', o.sig(item));
			else if (o.patch)
				o.patch(el, item);
		}

		used[key] = el;

		if (el === cursor)
			cursor = cursor.nextElementSibling;
		else
			container.insertBefore(el, cursor);
	});

	Array.prototype.slice.call(container.children).forEach(function(c) {
		if (used[c.getAttribute('data-key')] !== c)
			container.removeChild(c);
	});
}

/* ------------------------------------------------------------------ *
 *  Small helpers: formatting
 * ------------------------------------------------------------------ */

function fmtMbps(bps) {
	const n = num(bps);

	if (n == null)
		return '-';

	const m = n / 1e6;

	if (m >= 100)
		return String(Math.round(m));

	if (m >= 0.1)
		return m.toFixed(1);

	return (m > 0) ? m.toFixed(2) : '0';
}

function fmtBytes(bytes) {
	let n = num(bytes);

	if (n == null)
		return '';

	const units = [ 'B', 'KB', 'MB', 'GB', 'TB' ];
	let i = 0;

	while (n >= 1000 && i < units.length - 1) {
		n /= 1000;
		i++;
	}

	return (i === 0 ? String(Math.round(n)) : (n >= 10 ? n.toFixed(0) : n.toFixed(1))) + ' ' + units[i];
}

function bandName(band) {
	switch (band) {
	case '2g': return '2.4 GHz';
	case '5g': return '5 GHz';
	case '6g': return '6 GHz';
	default: return str(band);
	}
}

function qualityWord(q) {
	q = num(q);

	if (q == null)
		return '';

	return (q >= 70) ? _('Strong') : (q >= 45) ? _('Good') : (q >= 25) ? _('Fair') : _('Weak');
}

function dbmToQuality(dbm) {
	dbm = num(dbm);

	return (dbm == null) ? null : Math.max(0, Math.min(100, Math.round((dbm + 90) * 2)));
}

/* Signal word for anything that has a quality (0 to 100) and/or a dBm value. */
function signalWord(quality, dbm) {
	const q = (num(quality) != null) ? quality : dbmToQuality(dbm);

	return qualityWord(q);
}

function qualityLevel(q) {
	q = num(q);

	if (q == null || q <= 0)
		return 0;

	return (q >= 75) ? 4 : (q >= 50) ? 3 : (q >= 25) ? 2 : 1;
}

function agoText(seconds) {
	seconds = num(seconds);

	if (seconds == null || seconds < 0)
		return '';

	if (seconds < 45)
		return _('just now');

	if (seconds < 3600)
		return _('%d min ago').format(Math.round(seconds / 60));

	if (seconds < 86400)
		return _('%d h ago').format(Math.round(seconds / 3600));

	return _('%d d ago').format(Math.round(seconds / 86400));
}

function prettyHost(name) {
	name = str(name);

	if (!name || /^beryl-?7$/i.test(name))
		return 'Beryl 7';

	return name;
}

function countryLabel(code) {
	code = str(code).toUpperCase();

	const hit = COUNTRIES.find(function(c) { return c[0] === code; });

	return hit ? '%s (%s)'.format(hit[1], code) : code;
}

/* Accepts aa:bb:cc:dd:ee:ff, aa-bb-..., or aabbccddeeff. Returns null when it is
 * not a usable address for one device. */
function normalizeMac(s) {
	const hex = str(s).replace(/[\s:.\-]/g, '').toLowerCase();

	if (!/^[0-9a-f]{12}$/.test(hex))
		return null;

	if (parseInt(hex.slice(0, 2), 16) & 1)
		return null;

	if (/^0+$/.test(hex))
		return null;

	return hex.replace(/(..)(?=.)/g, '$1:');
}

/* ------------------------------------------------------------------ *
 *  Icons (inline SVG, no requests)
 * ------------------------------------------------------------------ */

const ICON_PATHS = {
	ethernet: '<rect x="4" y="5" width="16" height="11" rx="2"/><path d="M8 9v3M12 9v3M16 9v3M9 16v3h6v-3"/>',
	wifi: '<path d="M2.5 9a14 14 0 0 1 19 0M5.7 12.4a9.5 9.5 0 0 1 12.6 0M8.9 15.8a5 5 0 0 1 6.2 0"/><circle cx="12" cy="19.2" r="1.1" fill="currentColor" stroke="none"/>',
	phone: '<rect x="7" y="2.5" width="10" height="19" rx="2.4"/><path d="M11 18.5h2"/>',
	tablet: '<rect x="4.5" y="3" width="15" height="18" rx="2.2"/><path d="M11 18h2"/>',
	reader: '<rect x="5" y="2.5" width="14" height="19" rx="2"/><path d="M8.5 7h7M8.5 10.5h7M8.5 14h4.5"/>',
	laptop: '<rect x="4.5" y="5" width="15" height="10.5" rx="1.6"/><path d="M2.5 18.5h19"/>',
	desktop: '<rect x="3" y="4" width="18" height="12" rx="1.8"/><path d="M9 20.5h6M12 16v4.5"/>',
	tv: '<rect x="2.5" y="6" width="19" height="12.5" rx="2"/><path d="M8.5 2.8L12 6l3.5-3.2M8 21.2h8"/>',
	speaker: '<rect x="6" y="2.5" width="12" height="19" rx="2.6"/><circle cx="12" cy="14" r="3.4"/><path d="M12 6.6h.01"/>',
	watch: '<rect x="7" y="7" width="10" height="10" rx="2.6"/><path d="M9 7l.6-3.5h4.8L15 7M9 17l.6 3.5h4.8L15 17"/>',
	game: '<path d="M7.2 8h9.6a4.2 4.2 0 0 1 4.2 4.2v1.3a3 3 0 0 1-5.4 1.8L14.5 14h-5l-1.1 1.3A3 3 0 0 1 3 13.5v-1.3A4.2 4.2 0 0 1 7.2 8z"/><path d="M7.5 10.2v3.2M5.9 11.8h3.2M15.6 11.2h.01M17.6 12.6h.01"/>',
	printer: '<path d="M7 8.5v-5h10v5"/><rect x="3.5" y="8.5" width="17" height="8" rx="2"/><path d="M7 13.5h10v7H7z"/>',
	camera: '<path d="M4 7.5h3l1.5-2.5h7L17 7.5h3a1 1 0 0 1 1 1V18a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8.5a1 1 0 0 1 1-1z"/><circle cx="12" cy="13" r="3.4"/>',
	router: '<rect x="3" y="11.5" width="18" height="8" rx="2.5"/><path d="M7 11.5L5.4 4.2M17 11.5l1.6-7.3M7.5 15.5h.01M10.5 15.5h.01M13.5 15.5h.01"/>',
	auto: '<path d="M12 3.5l1.9 4.6 4.6 1.9-4.6 1.9L12 16.5l-1.9-4.6L5.5 10l4.6-1.9z"/><path d="M18.5 15.5l.8 1.9 1.9.8-1.9.8-.8 1.9-.8-1.9-1.9-.8 1.9-.8z"/>',
	globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3 3 15 0 18M12 3c-3 3-3 15 0 18"/>',
	lock: '<rect x="5" y="11" width="14" height="9.5" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
	refresh: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
	close: '<path d="M6 6l12 12M18 6L6 18"/>',
	back: '<path d="M15 5l-7 7 7 7"/>',
	'chev-right': '<path d="M9 5l7 7-7 7"/>',
	'chev-down': '<path d="M5 9l7 7 7-7"/>',
	'arrow-up': '<path d="M12 19V6M6 12l6-6 6 6"/>',
	'arrow-down': '<path d="M12 5v13M6 12l6 6 6-6"/>',
	grip: '<path d="M5 8h14M5 12h14M5 16h14"/>',
	qr: '<rect x="3.5" y="3.5" width="6.5" height="6.5" rx="1"/><rect x="14" y="3.5" width="6.5" height="6.5" rx="1"/><rect x="3.5" y="14" width="6.5" height="6.5" rx="1"/><path d="M14 14h3v3M20.5 14v.01M14 20.5h.01M17 20.5h3.5v-3.5"/>',
	eye: '<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
	'eye-off': '<path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/><path d="M4 4l16 16"/>',
	external: '<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
	check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
	plus: '<path d="M12 5v14M5 12h14"/>'
};

function icon(name, cls) {
	return E('<svg class="tp-ico' + (cls ? ' ' + cls : '') + '" viewBox="0 0 24 24" width="20" height="20" ' +
		'fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" ' +
		'aria-hidden="true" focusable="false">' + (ICON_PATHS[name] || '') + '</svg>');
}

function signalIcon(level) {
	let bars = '';

	for (let i = 0; i < 4; i++) {
		const height = 5 + i * 4;

		bars += '<rect x="' + (3 + i * 5) + '" y="' + (21 - height) + '" width="3.4" height="' + height +
			'" rx="1" opacity="' + (i < level ? '1' : '.25') + '"/>';
	}

	return E('<svg class="tp-ico tp-signal" viewBox="0 0 24 24" width="22" height="22" fill="currentColor" ' +
		'aria-hidden="true" focusable="false">' + bars + '</svg>');
}

/* ------------------------------------------------------------------ *
 *  Widgets
 * ------------------------------------------------------------------ */

function btn(label, o) {
	o = o || {};

	const kids = [];

	if (o.icon)
		kids.push(icon(o.icon));

	kids.push(h('span', { class: 'tp-btn-label' }, label));

	return h('button', {
		type: o.type || 'button',
		class: 'tp-btn' + (o.kind ? ' ' + o.kind : ''),
		click: o.click,
		disabled: o.disabled,
		hidden: o.hidden,
		'aria-label': o.aria,
		'aria-expanded': o.expanded
	}, kids);
}

function setBtnLabel(b, text) {
	const l = b.querySelector('.tp-btn-label');

	if (l)
		setText(l, text);
}

/* A row of exclusive choices. options: [ [ value, label ], ... ] */
function segmented(label, options, value, onChange, cls) {
	const btns = {};
	const el = h('div', { class: 'tp-seg ' + (cls || ''), role: 'radiogroup', 'aria-label': label });
	const api = {
		el: el,
		value: value,
		set: function(v) {
			api.value = v;

			Object.keys(btns).forEach(function(k) {
				btns[k].classList.toggle('is-on', k === v);
				btns[k].setAttribute('aria-checked', k === v ? 'true' : 'false');
			});
		}
	};

	options.forEach(function(o) {
		const b = h('button', {
			type: 'button',
			class: 'tp-seg-btn',
			role: 'radio',
			'aria-checked': 'false',
			click: function() {
				api.set(o[0]);

				if (onChange)
					onChange(o[0]);
			}
		}, h('span', { class: 'tp-seg-label' }, o[1]));

		btns[o[0]] = b;
		el.appendChild(b);
	});

	api.set(value);

	return api;
}

/* A label plus one control. Groups of buttons get a div instead of a label,
 * because tapping a label activates its first button. */
function field(labelText, control, hint, group) {
	return h(group ? 'div' : 'label', { class: 'tp-field' }, [
		h('span', { class: 'tp-label' }, labelText),
		control,
		hint ? h('span', { class: 'tp-hint' }, hint) : null
	]);
}

/* name: a stable hook for skins (data-card), never shown */
function card(title, right, kids, name) {
	return h('section', { class: 'tp-card', 'data-card': name }, [
		h('div', { class: 'tp-card-head' }, [ h('h3', { class: 'tp-h2' }, title), right ]),
		kids
	]);
}

/* ------------------------------------------------------------------ *
 *  Status helpers
 * ------------------------------------------------------------------ */

function isOnline(st) {
	const net = O(st.internet);

	if (typeof(net.online) == 'boolean')
		return net.online;

	const ups = A(st.uplinks);

	return ups.length ? ups.some(function(u) { return u && u.online; }) : null;
}

function sortUplinks(list) {
	return list.filter(function(u) { return u && u.name; }).map(function(u, i) {
		return { u: u, i: i };
	}).sort(function(a, b) {
		const ma = num(a.u.metric), mb = num(b.u.metric);

		if (ma != null && mb != null && ma !== mb)
			return ma - mb;

		return a.i - b.i;
	}).map(function(x) { return x.u; });
}

function uplinkKindLabel(kind) {
	switch (kind) {
	case 'ethernet': return _('Ethernet');
	case 'wifi': return _('Wi-Fi');
	case 'phone': return _('Phone over USB');
	default: return _('Internet');
	}
}

function uplinkTitle(u) {
	return str(u.label) || uplinkKindLabel(u.kind);
}

function uplinkIcon(kind) {
	switch (kind) {
	case 'ethernet': return 'ethernet';
	case 'wifi': return 'wifi';
	case 'phone': return 'phone';
	default: return 'globe';
	}
}

function uplinkDetail(u) {
	const detail = str(u.detail);

	if (u.kind == 'wifi' && u.ssid)
		return join([ u.ssid, detail || join([ bandName(u.band), (u.up || u.online) ? signalWord(u.quality, u.signal) : '' ]) ]);

	return detail;
}

/* Which pill an uplink row gets. */
function uplinkState(u, usedName, anyOnline) {
	if (u.online && u.name === usedName)
		return { tone: 'ok', text: _('In use') };

	if (u.online)
		return { tone: 'idle', text: _('Standby') };

	const wired = (u.kind == 'ethernet' || u.kind == 'phone');

	if (u.present === false)
		return { tone: 'idle', text: wired ? _('No cable') : _('Off') };

	if (u.up)
		return { tone: 'warn', text: _('No internet') };

	if (/cable/i.test(str(u.detail)))
		return { tone: 'idle', text: _('No cable') };

	if (/connecting/i.test(str(u.detail)))
		return { tone: 'idle', text: _('Connecting') };

	/* Not being connected is only worth an amber pill when nothing else works. */
	return anyOnline ? { tone: 'idle', text: _('Not connected') } : { tone: 'warn', text: _('Down') };
}

function targetLabel(st, mode) {
	const m = O(st.mode);

	if (mode == 'exitnode') {
		const n = A(O(st.tailscale).exit_nodes).find(function(x) { return x && x.ip === m.exit_node; });

		return n ? (n.label || n.name || n.ip) : null;
	}

	if (mode == 'wireguard') {
		const p = A(st.wireguard).find(function(x) { return x && x.name === m.wg; });

		return p ? (p.label || p.name) : null;
	}

	return null;
}

function describeHeader(st) {
	if (!hasData(st))
		return { tone: 'idle', pill: _('Reading status'), line: _('Waiting for the router to answer.') };

	const mode = O(st.mode);

	if (mode.hold === 'portal')
		return {
			tone: 'warn',
			pill: _('Paused: log in first'),
			line: _('Traffic leaves directly until you finish the Wi-Fi login.')
		};

	const online = isOnline(st);

	if (online === false)
		return {
			tone: 'warn',
			pill: _('Offline'),
			line: _('No internet source is working. Choose a Wi-Fi network below or plug in a cable.')
		};

	if (online === null)
		return { tone: 'idle', pill: _('Status unknown'), line: '' };

	const active = (MODES.indexOf(mode.active) >= 0) ? mode.active : null;

	if (mode.desired && active && mode.desired !== active)
		return {
			tone: 'warn',
			pill: _('Online, tunnel off'),
			line: _('Traffic leaves through %s instead of %s. See below.').format(
				MODE_LABEL[active], MODE_LABEL[mode.desired] || mode.desired)
		};

	const target = active ? targetLabel(st, active) : null;

	switch (active) {
	case 'exitnode':
		return {
			tone: 'ok',
			pill: _('Online via %s').format(target || _('Tailscale')),
			line: _('Traffic leaves through %s, a Tailscale exit node.').format(target || _('an exit node'))
		};

	case 'wireguard':
		return {
			tone: 'ok',
			pill: _('Online via %s').format(target || _('VPN')),
			line: _('Traffic leaves through %s, a VPN.').format(target || _('a VPN profile'))
		};

	case 'nikki':
		return {
			tone: 'ok',
			pill: _('Online via nikki'),
			line: _('Traffic goes through nikki, set up for China.')
		};

	case 'direct':
		return { tone: 'ok', pill: _('Online'), line: _('Traffic leaves directly from this connection.') };

	default:
		return { tone: 'ok', pill: _('Online'), line: '' };
	}
}

/* ------------------------------------------------------------------ *
 *  Wi-Fi QR codes
 * ------------------------------------------------------------------ */

/* Parses WIFI:T:WPA;S:name;P:pass;H:false;; with backslash escapes.
 * Returns null when the text is not a Wi-Fi code. */
function parseWifiQR(text) {
	const s = str(text).trim();

	if (!/^WIFI:/i.test(s))
		return null;

	const fields = {};
	let cur = '', key = null, inKey = true, esc = false;

	const commit = function() {
		if (key !== null)
			fields[key.toUpperCase()] = cur;

		key = null;
		cur = '';
	};

	for (let i = 5; i < s.length; i++) {
		const c = s.charAt(i);

		if (esc) {
			cur += c;
			esc = false;
		}
		else if (c === '\\') {
			esc = true;
		}
		else if (inKey) {
			if (c === ':') {
				key = cur;
				cur = '';
				inKey = false;
			}
			else if (c === ';') {
				cur = '';
			}
			else {
				cur += c;
			}
		}
		else if (c === ';') {
			commit();
			inKey = true;
		}
		else {
			cur += c;
		}
	}

	if (!inKey)
		commit();

	/* Values that could be mistaken for hex are wrapped in double quotes. */
	const unquote = function(v) {
		v = str(v);

		return (v.length >= 2 && v.charAt(0) === '"' && v.charAt(v.length - 1) === '"') ? v.slice(1, -1) : v;
	};

	const type = str(fields.T).toUpperCase();
	let security;

	if (type === 'WEP')
		security = 'wep';
	else if (fields.E || /EAP/.test(type))
		security = 'enterprise';
	else if (type === 'SAE' || type === 'WPA3')
		security = 'sae';
	else if (type === 'NOPASS' || type === 'NONE')
		security = 'open';
	else if (/^WPA/.test(type))
		security = 'psk';
	else
		security = fields.P ? 'psk' : 'open';

	return {
		ssid: unquote(fields.S),
		password: unquote(fields.P),
		identity: unquote(fields.I),
		hidden: /^true$/i.test(str(fields.H)),
		security: security
	};
}

let jsQRPromise = null;

/* The decoder is 250 KB, so it is only fetched when someone taps "QR code". */
function loadJsQR() {
	if (typeof(window.jsQR) == 'function')
		return Promise.resolve(window.jsQR);

	if (!jsQRPromise)
		jsQRPromise = new Promise(function(resolve, reject) {
			const script = E('script', { src: L.resource('travel/jsQR.js') });

			script.addEventListener('load', function() {
				if (typeof(window.jsQR) == 'function')
					resolve(window.jsQR);
				else
					reject(new Error('jsQR missing'));
			});
			script.addEventListener('error', function() { reject(new Error('jsQR failed to load')); });
			document.head.appendChild(script);
		}).catch(function(err) {
			jsQRPromise = null;
			throw err;
		});

	return jsQRPromise;
}

function loadImage(file) {
	const viaElement = function() {
		return new Promise(function(resolve, reject) {
			const url = URL.createObjectURL(file);
			const img = new Image();

			img.onload = function() { URL.revokeObjectURL(url); resolve(img); };
			img.onerror = function() { URL.revokeObjectURL(url); reject(new Error('image')); };
			img.src = url;
		});
	};

	if (typeof(window.createImageBitmap) == 'function')
		return window.createImageBitmap(file).catch(viaElement);

	return viaElement();
}

/* Resolves to the text of the QR code in the photo, or null when there is none. */
function decodeQr(file) {
	const reader = loadJsQR().catch(function() { throw { tpMsg: _('The QR reader did not load. Type the password instead.') }; });
	const photo = loadImage(file).catch(function() { throw { tpMsg: _("Couldn't read that photo. Try another one.") }; });

	return Promise.all([ reader, photo ]).then(function(r) {
		const img = r[1];
		const w0 = img.naturalWidth || img.width;
		const h0 = img.naturalHeight || img.height;
		let found = null;

		/* Big phone photos decode best after shrinking; small codes sometimes
		 * need a second try at another size. */
		[ 1024, 640, 400 ].some(function(max) {
			const k = Math.min(1, max / Math.max(w0, h0));
			const w = Math.max(1, Math.round(w0 * k));
			const hh = Math.max(1, Math.round(h0 * k));
			const canvas = E('canvas');

			canvas.width = w;
			canvas.height = hh;

			const g = canvas.getContext('2d', { willReadFrequently: true });

			g.drawImage(img, 0, 0, w, hh);

			const data = g.getImageData(0, 0, w, hh);
			const code = window.jsQR(data.data, data.width, data.height);

			if (code && code.data) {
				found = code.data;
				return true;
			}

			return false;
		});

		if (typeof(img.close) == 'function')
			img.close();

		return found;
	});
}

/* ------------------------------------------------------------------ *
 *  Card: header
 * ------------------------------------------------------------------ */

function buildHeader(app) {
	const title = h('h2', { class: 'tp-title' }, 'Beryl 7');
	const status = h('span', { class: 'tp-pill idle' }, '');
	const line = h('p', { class: 'tp-sub' }, '');
	const el = h('section', { class: 'tp-card tp-head' }, [
		h('div', { class: 'tp-head-row' }, [ title, status ]),
		line
	]);

	return {
		el: el,
		update: function(st) {
			const d = describeHeader(st);

			setText(title, prettyHost(st.hostname));
			setPill(status, d.tone, d.pill);
			setText(line, d.line);
			toggleHidden(line, !d.line);
		}
	};
}

/* ------------------------------------------------------------------ *
 *  Suggestion: the country changed, so the mode switch may want to as well
 * ------------------------------------------------------------------ */

const DISMISS_KEY = 'travel.dismiss.';
const DISMISS_MS = 30 * 24 * 3600 * 1000;

/* "Not now" is remembered per country. Storage can be missing or blocked (private
 * windows, some phones), so every access is guarded and the choice is also kept in
 * page memory. A stored time stamp lapses after a month so the next trip is not
 * silenced for good; any other stored value counts as dismissed. */
function isDismissed(app, cc) {
	if (app.ux.dismissed[cc])
		return true;

	try {
		const v = window.localStorage.getItem(DISMISS_KEY + cc);

		if (v == null)
			return false;

		const t = parseInt(v, 10);

		return !(t > 1e12 && Date.now() - t > DISMISS_MS);
	}
	catch (e) {
		return false;
	}
}

function dismiss(app, cc) {
	app.ux.dismissed[cc] = true;

	try {
		window.localStorage.setItem(DISMISS_KEY + cc, String(Date.now()));
	}
	catch (e) {
		/* no storage: the choice lasts until the page is closed */
	}
}

/* Never switches anything on its own: it asks, and only the button changes the region. */
function buildSuggest(app) {
	let cur = null;		/* what is being suggested right now: { cc, region, text, label } */

	const err = msgSlot();
	const text = h('p', { class: 'tp-suggest-text' }, '');
	const sub = h('p', { class: 'tp-suggest-sub' }, '');
	const goBtn = btn('', { kind: 'primary', click: function() {
		if (!cur)
			return;

		const region = cur.region;

		app.run(goBtn, function() { return send(callSetRegion, region); }, err);
	} });
	const laterBtn = btn(_('Not now'), { kind: 'quiet', click: function() {
		if (!cur)
			return;

		dismiss(app, cur.cc);
		update(app.status);
	} });
	const el = h('section', { class: 'tp-suggest', hidden: true, 'aria-live': 'polite' }, [
		text,
		sub,
		h('div', { class: 'tp-actions' }, [ goBtn, laterBtn ]),
		err.el
	]);

	function update(st) {
		const w = O(st.wifi);
		const region = O(st.switch).region;
		const det = str(w.country_detected).toUpperCase();
		let want = null;

		if (det === 'CN' && region === 'world')
			want = {
				cc: det,
				region: 'china',
				text: _("Looks like you're in China. Switch to China mode?"),
				label: _('Switch to China mode')
			};
		else if (det && det !== 'CN' && region === 'china')
			want = {
				cc: det,
				region: 'world',
				text: _("Looks like you've left China. Switch back to rest of the world?"),
				label: _('Switch back')
			};

		if (want && isDismissed(app, want.cc))
			want = null;

		cur = want;
		toggleHidden(el, !want);

		if (!want) {
			err.clear();
			return;
		}

		const src = str(w.country_source);

		setText(text, want.text);
		setBtnLabel(goBtn, want.label);
		setText(sub, src ? _('Detected: %s, from %s.').format(countryLabel(det), src) : _('Detected: %s.').format(countryLabel(det)));
	}

	return { el: el, update: update };
}

/* ------------------------------------------------------------------ *
 *  Card: live speed
 * ------------------------------------------------------------------ */

function buildSpeed(app) {
	const W = 160, H = 44;
	const down = h('span', { class: 'tp-big' }, '-');
	const up = h('span', { class: 'tp-big' }, '-');
	const via = h('p', { class: 'tp-sub' }, '');
	const spark = E('<svg class="tp-spark" viewBox="0 0 ' + W + ' ' + H + '" preserveAspectRatio="none" role="img" ' +
		'aria-label="Speed over the last few minutes" focusable="false">' +
		'<path class="tp-spark-base" d="M0 ' + (H - 1) + 'H' + W + '"/>' +
		'<path class="tp-spark-area" d=""/><path class="tp-spark-down" d=""/><path class="tp-spark-up" d=""/></svg>');
	const area = spark.querySelector('.tp-spark-area');
	const lineDown = spark.querySelector('.tp-spark-down');
	const lineUp = spark.querySelector('.tp-spark-up');

	const el = h('section', { class: 'tp-card tp-speed' }, [
		h('div', { class: 'tp-speed-row' }, [
			h('div', { class: 'tp-stat' }, [
				h('span', { class: 'tp-k' }, _('Down')),
				h('span', { class: 'tp-stat-v' }, [ down, h('span', { class: 'tp-unit' }, 'Mbps') ])
			]),
			h('div', { class: 'tp-stat' }, [
				h('span', { class: 'tp-k' }, _('Up')),
				h('span', { class: 'tp-stat-v' }, [ up, h('span', { class: 'tp-unit' }, 'Mbps') ])
			])
		]),
		h('div', { class: 'tp-spark-box' }, spark),
		via
	]);

	function draw(samples) {
		if (samples.length < 2) {
			area.setAttribute('d', '');
			lineDown.setAttribute('d', '');
			lineUp.setAttribute('d', '');
			return;
		}

		let max = 1e6;

		samples.forEach(function(s) { max = Math.max(max, s.rx, s.tx); });

		const step = W / (SPEED_SAMPLES - 1);
		const x0 = W - (samples.length - 1) * step;
		const y = function(v) { return (H - 2) - (v / max) * (H - 6); };
		let dd = '', du = '';

		samples.forEach(function(s, i) {
			const x = (x0 + i * step).toFixed(1);

			dd += (i ? 'L' : 'M') + x + ' ' + y(s.rx).toFixed(1);
			du += (i ? 'L' : 'M') + x + ' ' + y(s.tx).toFixed(1);
		});

		lineDown.setAttribute('d', dd);
		lineUp.setAttribute('d', du);
		area.setAttribute('d', dd + 'L' + W + ' ' + (H - 2) + 'L' + x0.toFixed(1) + ' ' + (H - 2) + 'Z');
	}

	return {
		el: el,
		update: function(st) {
			const sp = O(st.speed);
			const net = O(st.internet);
			const name = sp.uplink || net.uplink;
			const u = A(st.uplinks).find(function(x) { return x && x.name === name; });

			setText(down, fmtMbps(sp.rx_bps));
			setText(up, fmtMbps(sp.tx_bps));
			draw(app.speed);

			if (u)
				setText(via, _('Using %s.').format((u.kind == 'wifi' && u.ssid) ? uplinkTitle(u) + ': ' + u.ssid : uplinkTitle(u)));
			else
				setText(via, hasData(st) ? _('No internet source in use.') : '');
		}
	};
}

/* ------------------------------------------------------------------ *
 *  Card: Wi-Fi login
 * ------------------------------------------------------------------ */

function buildLogin(app) {
	const status = h('span', { class: 'tp-pill idle' }, '');
	const text = h('p', { class: 'tp-text' }, '');
	const sub = h('p', { class: 'tp-sub' }, '');
	const open = h('a', {
		class: 'tp-btn',
		href: FALLBACK_LOGIN_URL,
		target: '_blank',
		rel: 'noopener noreferrer'
	}, [ icon('external'), h('span', { class: 'tp-btn-label' }, _('Open login page')) ]);

	/* automatic login on this network: its method, and how the last try went (2026-10-06) */
	const autoText = h('p', { class: 'tp-sub' }, '');
	const autoBtn = btn(_('Set up automatic login'), { kind: 'sm', click: function() {
		const al = O(O(app.status && app.status.portal).autologin);

		if (al.ssid)
			openLoginSheet(app, al.ssid, autoBtn);
	} });
	const autoRow = h('div', { class: 'tp-auto', hidden: true }, [ autoText, h('div', { class: 'tp-actions' }, autoBtn) ]);

	const el = card(_('Wi-Fi login'), status, [
		text,
		sub,
		h('div', { class: 'tp-actions' }, open),
		autoRow
	], 'login');

	return {
		el: el,
		update: function(st) {
			const p = O(st.portal);
			const mode = O(st.mode);
			const detected = (p.state === 'detected');
			const url = safeUrl(p.url) || FALLBACK_LOGIN_URL;

			if (detected) {
				setPill(status, 'warn', _('Login needed'));
				setText(text, mode.hold === 'portal'
					? _('The Wi-Fi is asking for a login. The tunnel waits until you are through.')
					: _('The Wi-Fi is asking for a login.'));
			}
			else if (p.state === 'none') {
				setPill(status, 'ok', _('Not needed'));
				setText(text, _('No login page is in the way.'));
			}
			else {
				setPill(status, 'idle', _('Not checked yet'));
				setText(text, _('The router has not checked for a login page yet.'));
			}

			const host = (detected && p.host) ? _('Page: %s.').format(p.host) : '';
			const since = (detected && num(p.since) != null && num(st.time) != null)
				? _('Found %s.').format(agoText(st.time - p.since)) : '';

			setText(sub, [ host, since ].filter(Boolean).join(' '));
			toggleHidden(sub, !host && !since);

			if (open.getAttribute('href') !== url)
				open.setAttribute('href', url);

			open.classList.toggle('primary', detected);

			const al = O(p.autologin);

			toggleHidden(autoRow, !al.ssid);

			if (al.ssid) {
				setText(autoText, autoLoginLine(al, st.time));
				setBtnLabel(autoBtn, (al.method && al.method !== 'none') ? _('Change automatic login') : _('Set up automatic login'));
			}
		}
	};
}

/* auto is what the sheet sets; the UniFi-only methods are older settings it still reads */
const LOGIN_METHOD_NAMES = { 'auto': _('Automatic'), 'unifi-password': _('UniFi page code'), 'unifi-user': _('UniFi username and code'), 'click-through': _('"I accept" page') };

/* One line on the login card: the method, and the login script's own record of
 * its last try on this network (written to /var/run/travel/autologin.json). */
function autoLoginLine(al, now) {
	if (!al.method || al.method === 'none')
		return _('Automatic login on %s: off.').format(al.ssid);

	const last = O(al.last);
	const ago = (num(last.at) != null && num(now) != null) ? agoText(now - last.at) : '';
	const results = {
		'ok': _('the last login worked %s.'),
		'already-online': _('the last check found the internet already open %s.'),
		'wrong-code': _('the last try failed: wrong code, %s.'),
		'refused': _('the last try was refused by the page %s.'),
		'not-unifi': _('the last login page was not a UniFi page (%s).'),
		'not-supported': _('the last login page was not one it knows yet (%s).'),
		'no-form': _('the last login page could not be filled in by itself (%s): log in by hand, a copy is kept for later.'),
		'needs-details': _('the last login page asked for details that are not saved (%s).'),
		'not-accepted': _('the last login page did not let it in (%s).'),
		'failed': _('the last try failed %s.')
	};
	const tail = (last.result && results[last.result]) ? results[last.result].format(ago) : _('no login page so far.');

	if (al.method === 'auto')
		return _('Automatic login on %s is on; %s').format(al.ssid, tail);

	return _('Automatic login on %s: %s; %s').format(al.ssid, LOGIN_METHOD_NAMES[al.method] || al.method, tail);
}

/* ------------------------------------------------------------------ *
 *  Sheet: automatic login for one network
 * ------------------------------------------------------------------ */

function openLoginSheet(app, ssid, opener) {
	const sheet = app.openSheet({ title: _('Automatic login'), opener: opener });
	const err = msgSlot();
	let method = 'none';

	/* Off or Automatic: the router finds out what each page wants (2026-10-06); a
	 * traveller cannot know which system a hotel runs before the page shows */
	const methodSeg = segmented(_('Automatic login'), [ [ 'none', _('Off') ], [ 'auto', _('On') ] ], method,
		function(v) { method = v; paintForm(); }, 'tp-seg-2');
	const userIn = h('input', {
		type: 'text', class: 'tp-input', maxlength: '64', autocomplete: 'off',
		autocapitalize: 'none', autocorrect: 'off', spellcheck: 'false'
	});
	const userRow = field(_('Username (if the page asks)'), userIn, _('One word, as on the login page: a room number, a name.'));
	const codeIn = h('input', {
		type: 'password', class: 'tp-input', maxlength: '64', autocomplete: 'off',
		autocapitalize: 'none', autocorrect: 'off', spellcheck: 'false'
	});
	const eye = h('button', { type: 'button', class: 'tp-icon-btn', 'aria-label': _('Show code'), 'aria-pressed': 'false', click: function() {
		const show = (codeIn.type === 'password');

		codeIn.type = show ? 'text' : 'password';
		eye.setAttribute('aria-pressed', show ? 'true' : 'false');
		eye.setAttribute('aria-label', show ? _('Hide code') : _('Show code'));
		clear(eye).appendChild(icon(show ? 'eye-off' : 'eye'));
	} }, icon('eye'));
	const codeRow = field(_('Code or password (if the page asks)'), h('span', { class: 'tp-input-row' }, [ codeIn, eye ]),
		_('Leave both empty for a page that only asks you to accept. Kept on the router only.'));
	const saveBtn = btn(_('Save'), { kind: 'primary', type: 'submit' });

	function paintForm() {
		toggleHidden(userRow, method === 'none');
		toggleHidden(codeRow, method === 'none');
	}

	const form = h('form', {
		class: 'tp-form',
		novalidate: '',
		submit: function(ev) {
			ev.preventDefault();

			const code = codeIn.value.trim();

			const user = userIn.value.trim();

			if (user && /\s/.test(user)) {
				err.show(_('The username is one word. Leave it empty if the page does not ask for one.'));
				userIn.focus();
				return;
			}

			app.run(saveBtn, function() {
				return send(callLoginSet, ssid, method, method === 'auto' ? code : '', method === 'auto' ? user : '');
			}, err, function() {
				err.show(method === 'none'
					? _('Saved. Login pages on this network are left to you.')
					: _('Saved. The next login page on this network will use it.'), 'ok');
			});
		}
	}, [
		h('p', { class: 'tp-sub' }, _('When %s shows its login page, the router logs in by itself: it accepts the terms, and fills in a username and code if you save them here. A page it cannot fill in is left to you (the login card, your phone), and a copy of every login page is kept on the router.').format(ssid)),
		field(_('Automatic login'), methodSeg.el, null, true),
		userRow,
		codeRow,
		h('div', { class: 'tp-actions' }, saveBtn),
		err.el
	]);

	addKids(sheet.body, [ form ]);
	paintForm();

	/* what is saved now, the code included (it needs the write permission) */
	setBusy(saveBtn, true);
	send(callLoginGet, ssid).then(function(res) {
		setBusy(saveBtn, false);

		if (res.ok !== true)
			return err.show(res.error || GENERIC_ERROR);

		method = LOGIN_METHOD_NAMES[res.method] ? 'auto' : 'none';
		methodSeg.set(method);
		codeIn.value = str(res.code);
		userIn.value = str(res.user);
		paintForm();
	});

	return sheet;
}

/* ------------------------------------------------------------------ *
 *  Card: where your traffic exits
 * ------------------------------------------------------------------ */

function buildExit(app) {
	const ux = app.ux;
	const err = msgSlot();
	const note = h('p', { class: 'tp-note warn', hidden: true });
	const hint = h('p', { class: 'tp-sub', hidden: true }, '');
	const segBtns = {};
	const seg = h('div', { class: 'tp-seg tp-seg-grid', role: 'radiogroup', 'aria-label': _('Where your traffic exits') });

	const pickTitle = h('h4', { class: 'tp-h3' }, '');
	const pickList = h('div', { class: 'tp-list', role: 'radiogroup' });
	const pickEmpty = h('div', { class: 'tp-empty' }, '');
	const pick = h('div', { class: 'tp-picker', hidden: true }, [ pickTitle, pickList, pickEmpty ]);

	function pickMode(m, b) {
		const st = app.status;
		const mode = O(st.mode);
		const healthy = (mode.desired === m && mode.active === m && !mode.error && mode.hold !== 'portal');

		if (m === 'direct' || m === 'nikki') {
			ux.pendingMode = null;

			if (healthy) {
				sync(st);
				return;
			}

			app.run(b, function() { return send(callSetMode, m); }, err);
			return;
		}

		if (m === 'exitnode') {
			const nodes = A(O(st.tailscale).exit_nodes);
			const keep = nodes.find(function(n) { return n && n.ip && n.ip === mode.exit_node && n.online !== false; });

			if (keep) {
				ux.pendingMode = null;

				if (healthy) {
					sync(st);
					return;
				}

				app.run(b, function() { return send(callSetMode, 'exitnode', keep.ip); }, err);
				return;
			}
		}
		else {
			const profiles = A(st.wireguard).filter(function(p) { return p && p.name; });
			const keep = profiles.find(function(p) { return p.name === mode.wg; }) ||
				(profiles.length === 1 ? profiles[0] : null);

			if (keep) {
				ux.pendingMode = null;

				if (healthy) {
					sync(st);
					return;
				}

				app.run(b, function() { return send(callSetMode, 'wireguard', undefined, keep.name); }, err);
				return;
			}
		}

		/* No target chosen yet: show the picker and wait for a tap. */
		ux.pendingMode = m;
		err.clear();
		sync(st);
	}

	MODES.forEach(function(m) {
		const sub = h('span', { class: 'tp-seg-note' }, '');
		const b = h('button', {
			type: 'button',
			class: 'tp-seg-btn',
			role: 'radio',
			'aria-checked': 'false',
			click: function() { pickMode(m, b); }
		}, [ h('span', { class: 'tp-seg-label' }, MODE_LABEL[m]), sub ]);

		segBtns[m] = { btn: b, note: sub };
		seg.appendChild(b);
	});

	function exitRow(n, chosen) {
		const offline = (n.online === false);
		const b = h('button', {
			type: 'button',
			class: 'tp-choice' + (offline ? ' is-offline' : ''),
			role: 'radio',
			'aria-checked': chosen ? 'true' : 'false',
			disabled: offline && !chosen,
			click: function() {
				app.run(b, function() { return send(callSetMode, 'exitnode', n.ip); }, err, function() {
					ux.pendingMode = null;
				});
			}
		}, [
			h('span', { class: 'tp-radio', 'aria-hidden': 'true' }),
			h('span', { class: 'tp-choice-text' }, [
				h('span', { class: 'tp-row-title' }, n.label || n.name || n.ip),
				h('span', { class: 'tp-row-sub' }, join([ n.ip, (n.label && n.name) ? n.name : '' ]))
			]),
			n.active ? pill('ok', _('In use')) : (offline ? pill('idle', _('Offline')) : null)
		]);

		return b;
	}

	function wgRow(p, chosen) {
		const b = h('button', {
			type: 'button',
			class: 'tp-choice',
			role: 'radio',
			'aria-checked': chosen ? 'true' : 'false',
			click: function() {
				app.run(b, function() { return send(callSetMode, 'wireguard', undefined, p.name); }, err, function() {
					ux.pendingMode = null;
				});
			}
		}, [
			h('span', { class: 'tp-radio', 'aria-hidden': 'true' }),
			h('span', { class: 'tp-choice-text' }, [
				h('span', { class: 'tp-row-title' }, p.label || p.name),
				h('span', { class: 'tp-row-sub' }, str(p.endpoint))
			]),
			p.up ? pill('ok', _('Connected')) : null
		]);

		return b;
	}

	function emptyState(text, actionLabel, action) {
		const key = text + '|' + (actionLabel || '');

		/* Rebuilt only when the wording changes, so a poll never swaps the button under a finger. */
		if (pickEmpty._key !== key) {
			clear(pickEmpty);
			addKids(pickEmpty, [ h('p', { class: 'tp-text' }, text) ]);

			if (actionLabel)
				pickEmpty.appendChild(h('div', { class: 'tp-actions' }, btn(actionLabel, { kind: 'sm', click: action })));

			pickEmpty._key = key;
		}

		toggleHidden(pickEmpty, false);
	}

	function renderPicker(shown, st) {
		const mode = O(st.mode);
		const ts = O(st.tailscale);
		const wantsExit = (shown === 'exitnode');
		const wantsWg = (shown === 'wireguard');

		toggleHidden(pick, !wantsExit && !wantsWg);

		if (wantsExit) {
			const nodes = A(ts.exit_nodes).filter(function(n) { return n && n.ip; });
			const chosen = (ux.pendingMode === 'exitnode') ? null : mode.exit_node;

			setText(pickTitle, _('Exit node'));
			syncRows(pickList, nodes, {
				key: function(n) { return 'x:' + n.ip; },
				sig: function(n) { return JSON.stringify([ n.label, n.name, n.ip, n.online, n.active, n.ip === chosen ]); },
				make: function(n) { return exitRow(n, n.ip === chosen); }
			});

			if (nodes.length)
				toggleHidden(pickEmpty, true);
			else if (ts.state && ts.state !== 'Running')
				emptyState(_('Tailscale is not logged in.'), _('Log in'), function() { app.openMore('tailscale'); });
			else
				emptyState(_('No exit nodes found on your tailnet. Turn one on from another device first.'));
		}
		else if (wantsWg) {
			const profiles = A(st.wireguard).filter(function(p) { return p && p.name; });
			const chosen = (ux.pendingMode === 'wireguard') ? null : mode.wg;

			setText(pickTitle, _('VPN profile'));
			syncRows(pickList, profiles, {
				key: function(p) { return 'w:' + p.name; },
				sig: function(p) { return JSON.stringify([ p.label, p.name, p.endpoint, p.up, p.name === chosen ]); },
				make: function(p) { return wgRow(p, p.name === chosen); }
			});

			if (profiles.length)
				toggleHidden(pickEmpty, true);
			else
				emptyState(_('No VPN profiles yet.'), _('Add a profile'), function() { app.openMore('wg'); });
		}
		else {
			clear(pickList);
		}
	}

	function sync(st) {
		const mode = O(st.mode);
		const nikki = O(st.nikki);
		const shown = ux.pendingMode || ((MODES.indexOf(mode.desired) >= 0) ? mode.desired : null);

		MODES.forEach(function(m) {
			const s = segBtns[m];
			const on = (m === shown);
			const missing = (m === 'nikki' && nikki.installed === false);

			s.btn.classList.toggle('is-on', on);
			s.btn.setAttribute('aria-checked', on ? 'true' : 'false');
			setText(s.note, missing ? _('Not installed') : (mode.active === m ? _('In use') : ''));
			s.note.classList.toggle('is-active', !missing && mode.active === m);

			if (!s.btn.classList.contains('is-busy'))
				s.btn.disabled = missing && !on;
		});

		let warn = '';

		if (mode.error)
			warn = str(mode.error);
		else if (mode.hold === 'portal')
			warn = _('Waiting for the Wi-Fi login. Traffic leaves directly until you log in.');

		setNote(note, warn);

		const wait = ux.pendingMode
			? (ux.pendingMode === 'exitnode' ? _('Choose an exit node below.') : _('Choose a VPN profile below.'))
			: '';

		setNote(hint, wait);
		renderPicker(shown, st);
	}

	const el = card(_('Where your traffic exits'), null, [
		seg,
		err.el,
		note,
		hint,
		pick
	], 'exit');

	return { el: el, update: sync };
}

/* ------------------------------------------------------------------ *
 *  Card: internet source
 * ------------------------------------------------------------------ */

function buildUplinks(app) {
	const ux = app.ux;
	const err = msgSlot();
	const list = h('div', { class: 'tp-list', role: 'list' });
	const empty = h('p', { class: 'tp-empty' }, _('No internet sources reported yet.'));
	const help = h('p', { class: 'tp-sub', hidden: true }, _('Drag a row by its handle (or focus it and press the arrow keys), then Apply. The top row is preferred; the router moves to the next one if it stops working.'));
	/* Arranging changes nothing on the router; Apply sends the order once (Corey, 2026-10-08: each press
	 * used to cut the internet for a moment and the list never moved). The note says beforehand whether
	 * traffic will move, the only case that interrupts it: the router keeps the number of the source in use. */
	const note = h('p', { class: 'tp-sub tp-order-note', hidden: true }, '');
	/* the health check moved traffic off an uplink that is connected but has no internet */
	const detourNote = h('p', { class: 'tp-note warn', hidden: true }, '');
	const applyBtn = btn(_('Apply'), { kind: 'primary', click: function() { apply(); } });
	const cancelBtn = btn(_('Cancel'), { kind: 'quiet', click: function() { stopOrdering(); } });
	const orderActions = h('div', { class: 'tp-actions', hidden: true }, [ applyBtn, cancelBtn ]);
	const orderBtn = btn(_('Order'), { kind: 'quiet sm', hidden: true, click: function() {
		if (ux.ordering)
			stopOrdering();
		else {
			ux.ordering = true;
			ux.uplinkDraft = null;
			sync(app.status);
		}
	} });
	const chooseBtn = btn(_('Choose Wi-Fi'), { icon: 'wifi', click: function() { openWifiSheet(app, chooseBtn); } });

	function savedNames(st) {
		return sortUplinks(A(st.uplinks)).map(function(u) { return u.name; });
	}

	/* the order on screen: the draft while arranging, then the order just applied until the router reports it */
	function shownNames(st) {
		const saved = savedNames(st);
		const same = function(d) { return d && d.length === saved.length && saved.every(function(n) { return d.indexOf(n) >= 0; }); };

		if (ux.ordering && same(ux.uplinkDraft))
			return ux.uplinkDraft.slice();

		const p = ux.uplinkPending;

		if (p && same(p.names) && Date.now() < p.until && p.names.join() !== saved.join())
			return p.names.slice();

		ux.uplinkPending = null;

		return saved;
	}

	function stopOrdering() {
		ux.ordering = false;
		ux.uplinkDraft = null;
		err.clear();
		sync(app.status);
	}

	function place(name, to) {
		const names = shownNames(app.status).filter(function(n) { return n !== name; });

		names.splice(Math.max(0, Math.min(to, names.length)), 0, name);

		if (names.join() !== shownNames(app.status).join()) {
			const had = document.activeElement;

			ux.uplinkDraft = names;
			sync(app.status);

			/* moving a row in the list takes the focus off its handle: give it back, so the arrow keys
			 * keep working */
			if (had && had !== document.activeElement && list.contains(had))
				had.focus();
		}
	}

	function move(name, dir) {
		const i = shownNames(app.status).indexOf(name);

		if (i >= 0)
			place(name, i + dir);
	}

	function apply() {
		const names = shownNames(app.status);

		app.run(applyBtn, function() { return send(callUplinkOrder, names); }, err, function() {
			ux.uplinkPending = { names: names, until: Date.now() + 15000 };
			ux.ordering = false;
			ux.uplinkDraft = null;
			sync(app.status);
		});
	}

	/* drag by the handle: pointer events, so a finger and a mouse alike; the row moves as the pointer
	 * passes the middle of its neighbours */
	function startDrag(ev, row, name) {
		if (ev.button != null && ev.button !== 0)
			return;

		const handle = ev.currentTarget;

		ev.preventDefault();

		try { handle.setPointerCapture(ev.pointerId); } catch (e) { /* older browsers: no capture, still works */ }

		row.classList.add('is-dragging');

		function onMove(e) {
			const others = Array.prototype.filter.call(list.children, function(r) { return r !== row && !r.hidden; });
			let to = others.length;

			for (let k = 0; k < others.length; k++) {
				const b = others[k].getBoundingClientRect();

				if (e.clientY < b.top + b.height / 2) {
					to = k;
					break;
				}
			}

			place(name, to);
		}

		function onUp() {
			row.classList.remove('is-dragging');
			handle.removeEventListener('pointermove', onMove);
			handle.removeEventListener('pointerup', onUp);
			handle.removeEventListener('pointercancel', onUp);
		}

		handle.addEventListener('pointermove', onMove);
		handle.addEventListener('pointerup', onUp);
		handle.addEventListener('pointercancel', onUp);
	}

	function makeRow(item) {
		const u = item.u;
		const iconBox = h('span', { class: 'tp-row-icon' }, icon(uplinkIcon(u.kind)));
		const title = h('span', { class: 'tp-row-title' }, '');
		const detail = h('span', { class: 'tp-row-sub' }, '');
		const status = h('span', { class: 'tp-pill idle' }, '');
		let row = null;
		/* the handle only: arrow buttons beside it squeezed the names to one letter a line on a phone */
		const grip = h('button', {
			type: 'button', class: 'tp-icon-btn tp-grip',
			pointerdown: function(ev) { startDrag(ev, row, u.name); },
			keydown: function(ev) {
				if (ev.key === 'ArrowUp' || ev.key === 'ArrowDown') {
					ev.preventDefault();
					move(u.name, ev.key === 'ArrowUp' ? -1 : 1);
				}
			}
		}, icon('grip'));
		const arrows = h('span', { class: 'tp-arrows', hidden: true }, [ grip ]);

		row = h('div', { class: 'tp-row', role: 'listitem' }, [
			iconBox,
			h('span', { class: 'tp-row-text' }, [ title, detail ]),
			status,
			arrows
		]);

		row._tp = { iconBox: iconBox, kind: u.kind, title: title, detail: detail, status: status, grip: grip, arrows: arrows };

		return row;
	}

	function patchRow(row, item) {
		const u = item.u;
		const r = row._tp;
		const state = uplinkState(u, item.used, item.any);

		if (r.kind !== u.kind) {
			clear(r.iconBox).appendChild(icon(uplinkIcon(u.kind)));
			r.kind = u.kind;
		}

		setText(r.title, uplinkTitle(u));
		setText(r.detail, uplinkDetail(u));
		toggleHidden(r.detail, !r.detail.textContent);
		setPill(r.status, state.tone, state.text);
		toggleHidden(r.arrows, !ux.ordering);
		r.grip.setAttribute('aria-label', _('Move %s: drag, or press the up and down arrow keys').format(uplinkTitle(u)));
	}

	function sync(st) {
		const byName = {};

		A(st.uplinks).forEach(function(u) { if (u && u.name) byName[u.name] = u; });

		const ups = shownNames(st).filter(function(n) { return byName[n]; }).map(function(n) { return byName[n]; });
		const net = O(st.internet);
		const first = ups.find(function(u) { return u.online; });
		const used = net.uplink || (first ? first.name : null);
		const any = ups.some(function(u) { return u.online; });
		const items = ups.map(function(u, i) { return { u: u, i: i, n: ups.length, used: used, any: any }; });

		if (ups.length < 2) {
			ux.ordering = false;
			ux.uplinkDraft = null;
		}

		const dirty = ux.ordering && ups.map(function(u) { return u.name; }).join() !== savedNames(st).join();
		const fo = net.failover;

		setNote(detourNote, (fo && byName[fo.from] && byName[fo.to])
			? _('%s is connected but has no internet, so traffic goes through %s. It moves back by itself once %s works again.')
				.format(uplinkTitle(byName[fo.from]), uplinkTitle(byName[fo.to]), uplinkTitle(byName[fo.from]))
			: '');

		toggleHidden(empty, ups.length > 0);
		toggleHidden(orderBtn, ups.length < 2 || dirty);
		toggleHidden(help, !ux.ordering);
		toggleHidden(orderActions, !dirty);
		setNote(note, !dirty ? '' : (first && used && first.name !== used)
			? _('Applying moves traffic to %s, so your devices reconnect for a moment.').format(uplinkTitle(first))
			: _('No interruption: the source in use stays first among those connected.'));
		setBtnLabel(orderBtn, ux.ordering ? _('Done') : _('Order'));
		orderBtn.setAttribute('aria-pressed', ux.ordering ? 'true' : 'false');

		syncRows(list, items, {
			key: function(item) { return 'u:' + item.u.name; },
			make: makeRow,
			patch: patchRow
		});
	}

	const el = card(_('Internet source'), orderBtn, [
		detourNote,
		help,
		list,
		empty,
		note,
		orderActions,
		err.el,
		h('div', { class: 'tp-actions' }, chooseBtn)
	], 'uplinks');

	return { el: el, update: sync };
}

/* ------------------------------------------------------------------ *
 *  Card: devices
 * ------------------------------------------------------------------ */

function deviceName(d) {
	const name = str(d.name);

	if (name)
		return name;

	return _('Unknown device') + ' (' + str(d.mac).slice(-8) + ')';
}

/* What a device probably is, from the name it announces: a hook for skins
 * (data-kind on the avatar), never shown as text. A guess, so the order
 * matters (a Galaxy Tab is a tablet before it is a Galaxy) and anything
 * unclear stays "other". */
const DEVICE_KINDS = [
	[ 'router', /router|openwrt|\bgl-[a-z]{2}\d|fritz|unifi|\budm\b|ubnt|beryl|archer|\bdeco\b/i ],
	[ 'reader', /kindle|kobo|e-?reader|boox|pocketbook/i ],
	[ 'tablet', /ipad|tablet|galaxy-?tab|\btab\b|matepad|mediapad|fire-?hd/i ],
	[ 'watch', /watch/i ],
	[ 'tv', /chromecast|apple-?tv|roku|fire-?(tv|stick)|shield|bravia|webos|\btv\b/i ],
	[ 'speaker', /homepod|sonos|speaker|echo|nest-?(audio|mini|hub)|google-?home/i ],
	[ 'game', /nintendo|\bswitch\b|playstation|\bps[345]\b|xbox|steam-?deck/i ],
	[ 'printer', /printer|epson|canon|brother|laserjet|officejet|deskjet|kyocera/i ],
	[ 'camera', /camera|\bcam\b|doorbell/i ],
	[ 'laptop', /macbook|mac-?air|laptop|notebook|thinkpad|surface|chromebook|zenbook|vivobook|ideapad|\bxps\b|\bmbp\b|\bmba\b/i ],
	[ 'desktop', /imac|mac-?mini|mac-?studio|mac-?pro|desktop|workstation|\bpc\b|\bnuc\b/i ],
	[ 'phone', /iphone|android|galaxy|pixel|phone|\bs\d{2}\b|\b(z-?)?(fold|flip)\d?\b|\bnote-?\d{1,2}\b|redmi|xiaomi|oneplus|huawei|honor|oppo|\bvivo\b|realme|nokia|moto/i ]
];

/* Corey's own choice (Type in the device sheet) wins; then the name, which can
 * be specific (an iPad, a Mac mini); then the system the device runs, from how
 * it asked for its address (its DHCP fingerprint, d.os from status.uc) */
function deviceKind(d) {
	return KIND_NAMES[d.kind] ? d.kind : kindGuess(d).kind;
}

const OS_KINDS = { android: 'phone', ios: 'phone', macos: 'laptop', windows: 'desktop' };

function kindGuess(d) {
	const name = str(d.name);
	const k = DEVICE_KINDS.find(function(x) { return x[1].test(name); });

	if (k)
		return { kind: k[0], from: 'name' };

	if (OS_KINDS[d.os])
		return { kind: OS_KINDS[d.os], from: 'system' };

	return { kind: 'other', from: '' };
}

function systemName(d) {
	switch (d.os) {
	case 'android': return d.os_ver ? _('Android %s').format(d.os_ver) : _('Android');
	case 'ios': return _('iPhone or iPad');
	case 'macos': return _('Mac');
	case 'windows': return _('Windows');
	case 'linux': return _('Linux (a router or gadget)');
	}

	return '';
}

const KIND_NAMES = {
	phone: _('Phone'), tablet: _('Tablet'), laptop: _('Laptop'), desktop: _('Computer'),
	tv: _('TV'), speaker: _('Speaker'), watch: _('Watch'), reader: _('E-reader'),
	game: _('Console'), printer: _('Printer'), camera: _('Camera'), router: _('Router')
};

function deviceSub(d) {
	const usage = (num(d.rx_bytes) != null || num(d.tx_bytes) != null)
		? join([ _('%s down').format(fmtBytes(d.rx_bytes || 0)), _('%s up').format(fmtBytes(d.tx_bytes || 0)) ])
		: '';

	/* The router only sees Wi-Fi clients as connected, so this says what it
	 * knows: not on Wi-Fi right now (a cable device shows the same). */
	if (d.online === false)
		return join([ _('Not on Wi-Fi now'), usage ]);

	return join([ bandName(d.band), signalWord(null, d.signal), usage ]);
}

function buildDevices(app) {
	const err = msgSlot();
	const count = h('span', { class: 'tp-sub tp-count' }, '');
	const list = h('div', { class: 'tp-list', role: 'list' });
	const empty = h('p', { class: 'tp-empty' }, _('No devices are connected right now.'));
	const note = h('p', { class: 'tp-sub', hidden: true }, _("Data use is for today."));

	function makeRow(d) {
		const avatar = h('span', { class: 'tp-avatar', 'aria-hidden': 'true' }, '');
		const title = h('span', { class: 'tp-row-title' }, '');
		const blocked = pill('warn', _('Blocked'));
		const sub = h('span', { class: 'tp-row-sub' }, '');
		const main = h('button', {
			type: 'button',
			class: 'tp-row-main',
			click: function() { openDeviceSheet(app, row._tp.d.mac, main); }
		}, [
			avatar,
			h('span', { class: 'tp-row-text' }, [ h('span', { class: 'tp-row-line' }, [ title, blocked ]), sub ])
		]);
		const toggle = btn('', { kind: 'sm', click: function() {
			const dev = row._tp.d;

			app.run(toggle, function() { return send(callDeviceBlock, dev.mac, !dev.blocked); }, err);
		} });
		const row = h('div', { class: 'tp-row', role: 'listitem' }, [ main, toggle ]);

		row._tp = { d: d, avatar: avatar, title: title, blocked: blocked, sub: sub, toggle: toggle, main: main };

		return row;
	}

	function patchRow(row, d) {
		const r = row._tp;
		const name = deviceName(d);

		r.d = d;
		const kind = deviceKind(d);

		if (r.kind !== kind) {
			r.kind = kind;
			r.avatar.setAttribute('data-kind', kind);
			clear(r.avatar);

			if (kind !== 'other')
				r.avatar.appendChild(icon(kind));
		}

		if (kind === 'other')
			setText(r.avatar, name.charAt(0).toUpperCase());
		setText(r.title, name);
		toggleHidden(r.blocked, !d.blocked);
		setText(r.sub, deviceSub(d));
		toggleHidden(r.sub, !r.sub.textContent);
		setBtnLabel(r.toggle, d.blocked ? _('Unblock') : _('Block'));
		r.toggle.setAttribute('aria-label', (d.blocked ? _('Unblock %s') : _('Block %s')).format(name));
		r.main.setAttribute('aria-label', _('Open details for %s').format(name));
		row.classList.toggle('is-blocked', !!d.blocked);
		row.classList.toggle('is-away', d.online === false);
	}

	function sync(st) {
		const devs = A(st.devices).filter(function(d) { return d && d.mac; }).sort(function(a, b) {
			const away = (a.online === false ? 1 : 0) - (b.online === false ? 1 : 0);

			return away || deviceName(a).toLowerCase().localeCompare(deviceName(b).toLowerCase());
		});

		const here = devs.filter(function(d) { return d.online !== false; }).length;

		setText(count, devs.length ? (here === devs.length ? _('%d connected').format(devs.length) : _('%d connected, %d known').format(here, devs.length)) : '');
		toggleHidden(empty, devs.length > 0);
		toggleHidden(note, devs.length === 0);

		syncRows(list, devs, {
			key: function(d) { return 'd:' + d.mac; },
			make: makeRow,
			patch: patchRow
		});

	}

	const el = card(_('Devices'), count, [ note, list, empty, err.el ], 'devices');

	return { el: el, update: sync };
}

/* ------------------------------------------------------------------ *
 *  Card: your Wi-Fi
 * ------------------------------------------------------------------ */

function utf8Length(s) {
	return (typeof(TextEncoder) == 'function') ? new TextEncoder().encode(s).length : s.length;
}

function buildWifi(app) {
	const ux = app.ux;
	const nameVal = h('span', { class: 'tp-kv-v' }, '-');
	const editErr = msgSlot();
	const okNote = msgSlot();
	const ssidIn = h('input', { type: 'text', class: 'tp-input', maxlength: '32', autocomplete: 'off', autocapitalize: 'none', spellcheck: 'false' });
	const pwIn = h('input', {
		type: 'password', class: 'tp-input', autocomplete: 'new-password', autocapitalize: 'none', spellcheck: 'false',
		placeholder: _('Leave empty to keep the current one')
	});
	const eye = h('button', { type: 'button', class: 'tp-icon-btn', 'aria-label': _('Show password'), 'aria-pressed': 'false', click: function() {
		const show = (pwIn.type === 'password');

		pwIn.type = show ? 'text' : 'password';
		eye.setAttribute('aria-pressed', show ? 'true' : 'false');
		eye.setAttribute('aria-label', show ? _('Hide password') : _('Show password'));
		clear(eye).appendChild(icon(show ? 'eye-off' : 'eye'));
	} }, icon('eye'));
	const saveBtn = btn(_('Save'), { kind: 'primary', type: 'submit' });
	const cancelBtn = btn(_('Cancel'), { kind: 'quiet', click: function() { closeEdit(); } });
	const editBtn = btn(_('Change name or password'), { kind: 'sm', expanded: 'false', click: function() {
		ux.wifiEdit = !ux.wifiEdit;

		if (!ux.wifiEdit)
			closeEdit();
		else
			sync(app.status);
	} });

	function closeEdit() {
		ux.wifiEdit = false;
		ux.wifiDirty = false;
		pwIn.value = '';
		editErr.clear();
		sync(app.status);
	}

	[ ssidIn, pwIn ].forEach(function(i) { i.addEventListener('input', function() { ux.wifiDirty = true; }); });

	const form = h('form', {
		class: 'tp-form',
		hidden: true,
		novalidate: '',
		submit: function(ev) {
			ev.preventDefault();

			const cur = str(O(app.status.wifi).ssid);
			const name = ssidIn.value;
			const key = pwIn.value;
			const changes = {};

			if (name !== cur) {
				if (!name || utf8Length(name) > 32) {
					editErr.show(_('The name can be 1 to 32 characters. Change it and try again.'));
					ssidIn.focus();
					return;
				}

				changes.ssid = name;
			}

			if (key) {
				if (key.length < 8 || key.length > 63) {
					editErr.show(_('The password needs 8 to 63 characters. Change it and try again.'));
					pwIn.focus();
					return;
				}

				changes.key = key;
			}

			if (!changes.ssid && !changes.key) {
				editErr.show(_('Nothing to save yet. Change the name or type a new password.'));
				return;
			}

			app.run(saveBtn, function() {
				return send(callSetAp, changes.ssid, changes.key, undefined);
			}, editErr, function() {
				closeEdit();
				okNote.show(_('Saved. Devices reconnect in a few seconds.'), 'ok');
			}, RESTARTING);
		}
	}, [
		field(_('Wi-Fi name'), ssidIn),
		field(_('New password'), h('span', { class: 'tp-input-row' }, [ pwIn, eye ]), _('8 to 63 characters.')),
		h('p', { class: 'tp-sub' }, _('Devices reconnect after you save. Your phone may drop for a few seconds.')),
		h('div', { class: 'tp-actions' }, [ saveBtn, cancelBtn ]),
		editErr.el
	]);

	const chanBox = h('div', { class: 'tp-chans' });

	/* channel rows */
	function makeChanRow(r) {
		const label = h('span', { class: 'tp-kv-k' }, '');
		const locked = h('span', { class: 'tp-locked', hidden: true }, [ icon('lock'), h('span', { class: 'tp-locked-text' }, '') ]);
		const sel = h('select', { class: 'tp-select' }, '');
		const apply = btn(_('Apply'), { kind: 'primary sm', hidden: true });
		const rowErr = msgSlot();
		const ctl = h('span', { class: 'tp-chan-ctl' }, [ sel, apply ]);
		const row = h('div', { class: 'tp-chan' }, [
			h('div', { class: 'tp-kv' }, [ label, locked, ctl ]),
			rowErr.el
		]);
		const st = { band: r.band, current: '', dirty: false, label: label, locked: locked, sel: sel, apply: apply, ctl: ctl };

		sel.addEventListener('change', function() {
			st.dirty = true;
			toggleHidden(apply, sel.value === st.current);
		});
		apply.addEventListener('click', function() {
			const v = sel.value;

			app.run(apply, function() {
				return send(callSetChannel, st.band, String(v));
			}, rowErr, function() {
				st.dirty = false;
			}, RESTARTING);
		});

		row._tp = st;

		return row;
	}

	function patchChanRow(row, r) {
		const st = row._tp;
		const channel = toChannel(r.channel);
		const autoLabel = (channel != null && r.auto) ? _('Auto (now %s)').format(channel) : _('Auto');
		const wanted = [ 'auto' ].concat((CHANNELS[r.band] || []).map(String));

		setText(st.label, _('%s channel').format(bandName(r.band)));

		if (channel != null && wanted.indexOf(String(channel)) < 0)
			wanted.push(String(channel));

		/* Options are only rebuilt when the list changes, so an open picker stays open. */
		const have = Array.prototype.map.call(st.sel.options, function(o) { return o.value; }).join(',');

		if (have !== wanted.join(',')) {
			const keep = st.sel.value;

			clear(st.sel);
			wanted.forEach(function(v) { st.sel.appendChild(h('option', { value: v }, v === 'auto' ? autoLabel : v)); });
			st.sel.value = keep;
		}

		Array.prototype.forEach.call(st.sel.options, function(o) {
			if (o.value === 'auto')
				setText(o, autoLabel);
		});

		if (r.locked) {
			setText(st.locked.querySelector('.tp-locked-text'),
				(channel != null ? _("Locked: %s, follows the Wi-Fi you're connected to").format(channel) : _("Locked, follows the Wi-Fi you're connected to")));
			toggleHidden(st.locked, false);
			toggleHidden(st.ctl, true);
			return;
		}

		toggleHidden(st.locked, true);
		toggleHidden(st.ctl, false);

		st.current = r.auto ? 'auto' : (channel != null ? String(channel) : 'auto');

		if (!st.dirty && !isFocused(st.sel))
			setSelectValue(st.sel, st.current);

		toggleHidden(st.apply, st.sel.value === st.current);
	}

	/* country rules */
	const countrySel = h('select', { class: 'tp-select' }, [ h('option', { value: 'auto' }, _('Automatic (from nearby Wi-Fi)')) ].concat(COUNTRIES.map(function(c) {
		return h('option', { value: c[0] }, '%s (%s)'.format(c[1], c[0]));
	})));
	const countryApply = btn(_('Apply'), { kind: 'primary sm', hidden: true });
	const countryErr = msgSlot();
	const countryInfo = h('p', { class: 'tp-sub', hidden: true }, '');
	let countryCurrent = '';
	let countryDirty = false;

	countrySel.addEventListener('change', function() {
		countryDirty = true;
		toggleHidden(countryApply, countrySel.value === countryCurrent);
	});
	countryApply.addEventListener('click', function() {
		const v = countrySel.value;

		app.run(countryApply, function() {
			return send(callSetAp, undefined, undefined, v);
		}, countryErr, function() {
			countryDirty = false;

			if (v === 'auto')
				countryErr.show(_('Automatic is on. The router picks the country from nearby Wi-Fi.'), 'ok');
		}, RESTARTING);
	});

	const countryRow = h('div', { class: 'tp-country' }, [
		h('div', { class: 'tp-kv' }, [
			h('span', { class: 'tp-kv-k' }, _('Country rules')),
			h('span', { class: 'tp-chan-ctl' }, [ countrySel, countryApply ])
		]),
		h('p', { class: 'tp-sub' }, _('Sets which channels and power levels are allowed.')),
		countryInfo,
		countryErr.el
	]);

	function sync(st) {
		const w = O(st.wifi);
		const known = hasData(st.wifi);

		setText(nameVal, w.ssid || '-');
		toggleHidden(form, !ux.wifiEdit);
		editBtn.setAttribute('aria-expanded', ux.wifiEdit ? 'true' : 'false');
		toggleHidden(editBtn, ux.wifiEdit);

		if (!ux.wifiDirty && !isFocused(ssidIn))
			ssidIn.value = str(w.ssid);

		syncRows(chanBox, A(w.radios).filter(function(r) { return r && r.band; }), {
			key: function(r) { return 'r:' + r.band; },
			make: makeChanRow,
			patch: patchChanRow
		});

		toggleHidden(chanBox, !chanBox.children.length);
		toggleHidden(countryRow, !known || !w.country);

		if (w.country) {
			const code = str(w.country).toUpperCase();

			countryCurrent = code;

			if (!countryDirty && !isFocused(countrySel))
				setSelectValue(countrySel, code);

			toggleHidden(countryApply, countrySel.value === countryCurrent);

			const det = str(w.country_detected).toUpperCase();
			const src = str(w.country_source);

			if (det)
				setText(countryInfo, src ? _('Detected: %s, from %s.').format(countryLabel(det), src) : _('Detected: %s.').format(countryLabel(det)));

			toggleHidden(countryInfo, !det);
		}
	}

	const el = card(_('Your Wi-Fi'), null, [
		h('div', { class: 'tp-kv' }, [ h('span', { class: 'tp-kv-k' }, _('Name')), nameVal ]),
		h('div', { class: 'tp-actions' }, editBtn),
		form,
		okNote.el,
		chanBox,
		countryRow
	], 'wifi');

	return { el: el, update: sync };
}

/* ------------------------------------------------------------------ *
 *  Card: mode switch (the slider on the router)
 * ------------------------------------------------------------------ */

const WORLD_MODES = [ 'exitnode', 'wireguard' ];

/* What a slider position does, in words. */
function sliderWord(mode) {
	switch (mode) {
	case 'nikki': return 'nikki';
	case 'exitnode': return _('Tailscale exit node');
	case 'wireguard': return _('VPN');
	default: return _('direct');
	}
}

function buildModeSwitch(app) {
	const regionErr = msgSlot();
	const worldErr = msgSlot();
	const status = h('span', { class: 'tp-pill idle' }, '');
	const regions = {};
	const seg = h('div', { class: 'tp-seg tp-seg-2', role: 'radiogroup', 'aria-label': _('Where the slider works') });

	/* Both controls send the same command; what they show comes back in status. */
	function setRegion(b, slot, region, worldMode) {
		app.run(b, function() { return send(callSetRegion, region, worldMode); }, slot);
	}

	[ [ 'china', _('China') ], [ 'world', _('Rest of the world') ] ].forEach(function(r) {
		const b = h('button', {
			type: 'button',
			class: 'tp-seg-btn',
			role: 'radio',
			'aria-checked': 'false',
			click: function() {
				const sw = O(app.status.switch);

				if (sw.region === r[0])
					return;

				setRegion(b, regionErr, r[0], (r[0] === 'world' && WORLD_MODES.indexOf(sw.world_mode) >= 0) ? sw.world_mode : undefined);
			}
		}, h('span', { class: 'tp-seg-label' }, r[1]));

		regions[r[0]] = b;
		seg.appendChild(b);
	});

	/* China */
	const offChina = h('p', { class: 'tp-text' }, '');
	const noNikki = h('p', { class: 'tp-note warn', hidden: true }, _('nikki is not installed on this router, so the slider cannot turn it on.'));
	const chinaBox = h('div', { class: 'tp-mode-detail', hidden: true }, [
		h('p', { class: 'tp-text' }, _('Slider on: nikki. Smart routing; Chinese sites go direct.')),
		offChina,
		h('p', { class: 'tp-note warn' }, _('In China, WireGuard tunnels (Tailscale exit nodes, VPN profiles) get blocked. nikki is the one that works.')),
		noNikki
	]);

	/* rest of the world */
	const offWorld = h('p', { class: 'tp-text' }, '');
	const worldRows = {};
	const worldList = h('div', { class: 'tp-list', role: 'radiogroup', 'aria-label': _('Slider on turns on') });

	[ [ 'exitnode', _('Tailscale exit node') ], [ 'wireguard', _('VPN') ] ].forEach(function(w) {
		const sub = h('span', { class: 'tp-row-sub' }, '');
		const b = h('button', {
			type: 'button',
			class: 'tp-choice',
			role: 'radio',
			'aria-checked': 'false',
			click: function() {
				if (O(app.status.switch).world_mode === w[0])
					return;

				setRegion(b, worldErr, 'world', w[0]);
			}
		}, [
			h('span', { class: 'tp-radio', 'aria-hidden': 'true' }),
			h('span', { class: 'tp-choice-text' }, [ h('span', { class: 'tp-row-title' }, w[1]), sub ])
		]);

		worldRows[w[0]] = { btn: b, sub: sub };
		worldList.appendChild(b);
	});

	const worldBox = h('div', { class: 'tp-mode-detail', hidden: true }, [
		h('p', { class: 'tp-text' }, _('Slider on turns on:')),
		worldList,
		worldErr.el,
		offWorld
	]);

	/* The label of what is chosen in the exit card, so the two cards agree. */
	function exitSub(st) {
		const ip = O(st.mode).exit_node;

		if (!ip)
			return _('Choose an exit node above');

		const n = A(O(st.tailscale).exit_nodes).find(function(x) { return x && x.ip === ip; });

		return n ? (n.label || n.name || n.ip) : str(ip);
	}

	function vpnSub(st) {
		const profiles = A(st.wireguard).filter(function(x) { return x && x.name; });

		if (!profiles.length)
			return _('Add a VPN profile in More');

		const p = profiles.find(function(x) { return x.name === O(st.mode).wg; });

		return p ? (p.label || p.name) : _('Choose a VPN profile above');
	}

	const el = card(_('Mode switch'), status, [ seg, regionErr.el, chinaBox, worldBox ], 'mode');

	function update(st) {
		const sw = O(st.switch);
		const region = sw.region;
		const off = _('Slider off: %s').format(sliderWord(MODES.indexOf(sw.off) >= 0 ? sw.off : 'direct'));

		/* No region in status: an older router, nothing to show. */
		toggleHidden(el, region !== 'china' && region !== 'world');

		if (sw.position === 'on')
			setPill(status, 'ok', _('Slider is on'));
		else if (sw.position === 'off')
			setPill(status, 'idle', _('Slider is off'));
		else
			setPill(status, 'idle', _('Position unknown'));

		Object.keys(regions).forEach(function(k) {
			regions[k].classList.toggle('is-on', k === region);
			regions[k].setAttribute('aria-checked', k === region ? 'true' : 'false');
		});

		toggleHidden(chinaBox, region !== 'china');
		toggleHidden(worldBox, region !== 'world');
		toggleHidden(noNikki, O(st.nikki).installed !== false);
		setText(offChina, off);
		setText(offWorld, off);

		Object.keys(worldRows).forEach(function(k) {
			worldRows[k].btn.setAttribute('aria-checked', sw.world_mode === k ? 'true' : 'false');
		});

		setText(worldRows.exitnode.sub, exitSub(st));
		setText(worldRows.wireguard.sub, vpnSub(st));
	}

	return { el: el, update: update };
}

/* ------------------------------------------------------------------ *
 *  Card: more (expanding rows)
 * ------------------------------------------------------------------ */

function accordion(app, key, title, summary, body) {
	const chev = icon('chev-down', 'tp-chev');
	const head = h('button', {
		type: 'button',
		class: 'tp-acc-head',
		'aria-expanded': 'false',
		click: function() { app.toggleMore(key); }
	}, [ h('span', { class: 'tp-acc-title' }, title), summary, chev ]);
	const panel = h('div', { class: 'tp-acc-body', hidden: true }, body);
	const el = h('div', { class: 'tp-acc' }, [ head, panel ]);

	return {
		el: el,
		set: function(open) {
			head.setAttribute('aria-expanded', open ? 'true' : 'false');
			toggleHidden(panel, !open);
			el.classList.toggle('is-open', !!open);
		}
	};
}

function buildMacBody(app) {
	const err = msgSlot();
	let target = 'wifi';
	let pick = null;	/* the choice being made, not yet applied */
	let pending = null;	/* just applied: { target, before, until } until the new address is in use */

	/* Corey, 2026-10-08: the three rows looked like a menu but each tap applied at once, nothing showed which
	 * was in use, and "Now using" was only true after the next reconnect. Now: a real choice with the one in
	 * use checked, the address in use always shown, and one Apply that reconnects and says so first. */
	const seg = segmented(_('Connection'), [ [ 'wifi', _('Wi-Fi') ], [ 'ethernet', _('Ethernet') ] ], 'wifi', function(v) {
		target = v;
		pick = null;
		err.clear();
		paint(app.status);
	}, 'tp-seg-2');
	const nowLine = h('p', { class: 'tp-note ok' }, '');

	function option(kind, title, sub) {
		return h('button', {
			type: 'button', class: 'tp-choice', role: 'radio', 'aria-checked': 'false',
			click: function() {
				pick = kind;
				err.clear();
				paint(app.status);

				if (kind === 'custom')
					macIn.focus();
			}
		}, [
			h('span', { class: 'tp-radio', 'aria-hidden': 'true' }),
			h('span', { class: 'tp-choice-text' }, [
				h('span', { class: 'tp-row-title' }, title),
				h('span', { class: 'tp-row-sub' }, sub)
			])
		]);
	}

	const opts = {
		original: option('original', _('Original address'), _('The address the router was made with.')),
		random: option('random', _('Random address'), _('A made-up address. Good when a network limits devices or time per device. Choose it again for a new one.')),
		custom: option('custom', _('Enter an address'), _('Copy the address of a device that already logged in.'))
	};
	const macIn = h('input', {
		type: 'text', class: 'tp-input', placeholder: 'aa:bb:cc:dd:ee:ff', autocomplete: 'off',
		autocapitalize: 'none', spellcheck: 'false', inputmode: 'text', maxlength: '17',
		input: function() { paint(app.status); }
	});
	const customField = h('div', { hidden: true }, field(_('Address'), macIn));
	const warn = h('p', { class: 'tp-note warn', hidden: true }, '');
	const applyBtn = btn(_('Apply'), { kind: 'primary', hidden: true, click: function() { apply(); } });

	function cur(st) {
		return O(O(st.mac)[target]);
	}

	function paint(st) {
		const c = cur(st);
		const kind = c.kind || 'original';
		const chosen = pick || kind;
		const kindName = { original: _('the original'), random: _('a random one'), custom: _('one you entered') }[kind];
		const off = (target === 'wifi' && !c.ssid);

		/* the uplink reconnects after Apply: until the address in use changes, say so rather than show the
		 * old address under the new kind */
		if (pending && (pending.target !== target || Date.now() > pending.until ||
				(c.saved ? c.now === c.saved : c.now !== pending.before)))
			pending = (pending.target !== target) ? pending : null;

		if (!st.mac)
			setNote(nowLine, '');	/* an older router: it does not report this */
		else if (pending && pending.target === target)
			setNote(nowLine, (target === 'wifi')
				? _('Changing the address: the Wi-Fi is reconnecting…')
				: _('Changing the address: the Ethernet connection is restarting…'));
		else if (off)
			setNote(nowLine, _('Not connected to a Wi-Fi network. The address is kept per network: connect first.'));
		else
			setNote(nowLine, (target === 'wifi'
				? _('Now using %s on %s: %s.').format(c.now || '?', c.ssid, kindName)
				: _('Now using %s: %s.').format(c.now || '?', kindName)));

		Object.keys(opts).forEach(function(k) {
			opts[k].setAttribute('aria-checked', chosen === k ? 'true' : 'false');
			opts[k].disabled = off;
		});

		if (kind === 'custom' && !pick && !isFocused(macIn))
			macIn.value = str(c.saved);

		toggleHidden(customField, chosen !== 'custom' || off);

		const changing = !off && pick != null && (pick !== kind || pick === 'random' ||
			(pick === 'custom' && normalizeMac(macIn.value) !== str(c.saved)));

		toggleHidden(applyBtn, !changing);
		setNote(warn, !changing ? '' : (target === 'wifi')
			? _('The Wi-Fi uplink reconnects with the new address: devices on the router lose the internet for a few seconds, and the network may ask for its login again.')
			: _('The Ethernet connection restarts with the new address: devices on the router lose the internet for a few seconds.'));
	}

	function apply() {
		let action = 'reset', mac;

		if (pick === 'random')
			action = 'random';
		else if (pick === 'custom') {
			mac = normalizeMac(macIn.value);

			if (!mac) {
				err.show(_('That is not a valid address. Type it like aa:bb:cc:dd:ee:ff.'));
				macIn.focus();
				return;
			}

			action = 'set';
		}

		const before = cur(app.status).now;

		app.run(applyBtn, function() { return send(callMac, target, action, mac); }, err, function() {
			pick = null;
			pending = { target: target, before: before, until: Date.now() + 30000 };
			paint(app.status);
		});
	}

	paint(app.status || {});

	return {
		el: h('div', { class: 'tp-acc-inner' }, [
			h('p', { class: 'tp-sub' }, _('This is the hardware address the network sees for the router. Some networks tie a login to one device.')),
			seg.el,
			nowLine,
			h('div', { class: 'tp-list', role: 'radiogroup' }, [ opts.original, opts.random, opts.custom ]),
			customField,
			warn,
			h('div', { class: 'tp-actions' }, applyBtn),
			err.el
		]),
		update: paint
	};
}

function buildTailscaleBody(app) {
	const ux = app.ux;
	const err = msgSlot();
	const statePill = h('span', { class: 'tp-pill idle' }, '');
	const nameV = h('span', { class: 'tp-kv-v' }, '-');
	const ipV = h('span', { class: 'tp-kv-v' }, '-');
	const info = h('p', { class: 'tp-sub', hidden: true }, '');
	const authLink = h('a', { class: 'tp-btn primary', href: '#', target: '_blank', rel: 'noopener noreferrer', hidden: true }, [
		icon('external'), h('span', { class: 'tp-btn-label' }, _('Open Tailscale login'))
	]);
	const loginBtn = btn(_('Log in'), { kind: 'primary', click: function() {
		app.run(loginBtn, function() { return send(callTailscaleLogin); }, err, function(res) {
			ux.tsAuth = safeUrl(res.auth_url) || '';
			ux.tsWaitSince = ux.tsAuth ? 0 : Date.now();
			sync(app.status);
		});
	} });
	const logoutBtn = btn(_('Log out'), { click: function() { ux.confirm = 'ts-logout'; sync(app.status); } });
	const doLogout = btn(_('Log out'), { kind: 'danger', click: function() {
		app.run(doLogout, function() { return send(callTailscaleLogout); }, err, function() {
			ux.confirm = null;
			ux.tsAuth = '';
			sync(app.status);
		});
	} });
	const confirmBox = h('div', { class: 'tp-confirm', hidden: true }, [
		h('p', { class: 'tp-text' }, _('Log out of Tailscale? Exit nodes stop working until you log in again.')),
		h('div', { class: 'tp-actions' }, [
			btn(_('Cancel'), { kind: 'quiet', click: function() { ux.confirm = null; sync(app.status); } }),
			doLogout
		])
	]);
	const actions = h('div', { class: 'tp-actions' }, [ authLink, loginBtn, logoutBtn ]);

	function sync(st) {
		const ts = O(st.tailscale);
		const s = TS_STATE[ts.state] || [ 'idle', ts.state ? str(ts.state) : _('Unknown') ];
		const running = (ts.state === 'Running');
		const auth = safeUrl(ts.auth_url) || (running ? '' : ux.tsAuth);

		setPill(statePill, s[0], s[1]);
		setText(nameV, ts.name || '-');
		setText(ipV, ts.ip || '-');

		if (ts.state === 'NeedsMachineAuth')
			setNote(info, _('Approve this router in the Tailscale admin page, then it connects by itself.'));
		else if (ts.state === 'NeedsLogin')
			setNote(info, auth
				? _('Open the login page, sign in, then come back here.')
				: ((ux.tsWaitSince && Date.now() - ux.tsWaitSince < 60000)
					? _('Login started. The link appears here in a few seconds.')
					: _('Tap Log in to get a login link.')));
		else
			setNote(info, '');

		toggleHidden(authLink, !auth);

		if (auth && authLink.getAttribute('href') !== auth)
			authLink.setAttribute('href', auth);

		toggleHidden(loginBtn, running || !hasData(st.tailscale));
		toggleHidden(logoutBtn, !running || ux.confirm === 'ts-logout');
		toggleHidden(confirmBox, ux.confirm !== 'ts-logout' || !running);
		toggleHidden(actions, !hasData(st.tailscale));

		if (running)
			ux.tsAuth = '';
	}

	const body = h('div', { class: 'tp-acc-inner' }, [
		h('div', { class: 'tp-kv' }, [ h('span', { class: 'tp-kv-k' }, _('State')), statePill ]),
		h('div', { class: 'tp-kv' }, [ h('span', { class: 'tp-kv-k' }, _('This router')), nameV ]),
		h('div', { class: 'tp-kv' }, [ h('span', { class: 'tp-kv-k' }, _('Address')), ipV ]),
		info,
		actions,
		confirmBox,
		err.el
	]);

	return { el: body, update: sync };
}

function buildWgBody(app) {
	const ux = app.ux;
	const err = msgSlot();
	const okNote = msgSlot();
	const list = h('div', { class: 'tp-list', role: 'list' });
	const empty = h('p', { class: 'tp-empty' }, _('No VPN profiles yet.'));

	function makeRow(p) {
		const confirming = (ux.confirm === 'wg:' + p.name);
		const delBtn = btn(_('Delete'), { kind: 'sm danger', aria: _('Delete %s').format(p.label || p.name), click: function() {
			ux.confirm = 'wg:' + p.name;
			sync(app.status);
		} });
		const yes = btn(_('Delete'), { kind: 'sm danger', click: function() {
			app.run(yes, function() { return send(callWgDelete, p.name); }, err, function() {
				ux.confirm = null;
				sync(app.status);
			});
		} });
		const no = btn(_('Cancel'), { kind: 'sm quiet', click: function() { ux.confirm = null; sync(app.status); } });

		return h('div', { class: 'tp-row tp-row-wrap', role: 'listitem' }, [
			h('span', { class: 'tp-row-text' }, [
				h('span', { class: 'tp-row-title' }, p.label || p.name),
				h('span', { class: 'tp-row-sub' }, str(p.endpoint))
			]),
			p.up ? pill('ok', _('Connected')) : pill('idle', _('Not connected')),
			confirming ? h('span', { class: 'tp-confirm-inline' }, [
				h('span', { class: 'tp-sub' }, _('Delete this profile?')), no, yes
			]) : delBtn
		]);
	}

	/* add form */
	const addErr = msgSlot();
	const labelIn = h('input', { type: 'text', class: 'tp-input', maxlength: '32', autocomplete: 'off', spellcheck: 'false', placeholder: DEFAULT_VPN_LABEL });
	const confIn = h('textarea', { class: 'tp-input tp-textarea', rows: '7', spellcheck: 'false', autocomplete: 'off', autocapitalize: 'none', wrap: 'off',
		placeholder: '[Interface]\nPrivateKey = ...\nAddress = ...\n\n[Peer]\nPublicKey = ...\nEndpoint = ...' });
	const fileIn = h('input', { type: 'file', accept: '.conf,text/plain', class: 'tp-vh', tabindex: '-1', 'aria-hidden': 'true', change: function() {
		const f = fileIn.files && fileIn.files[0];

		fileIn.value = '';

		if (!f)
			return;

		if (f.size > 65536) {
			addErr.show(_('That file is too big for a WireGuard profile. Pick the .conf file itself.'));
			return;
		}

		const rd = new FileReader();

		rd.onload = function() {
			confIn.value = str(rd.result);
			addErr.clear();
		};
		rd.onerror = function() { addErr.show(_("Couldn't read that file. Try again or paste its text.")); };
		rd.readAsText(f);
	} });
	const addBtn = btn(_('Add profile'), { kind: 'primary', type: 'submit' });
	const addForm = h('form', {
		class: 'tp-form',
		hidden: true,
		novalidate: '',
		submit: function(ev) {
			ev.preventDefault();

			const label = labelIn.value.trim() || DEFAULT_VPN_LABEL;
			const conf = confIn.value;

			if (!/\[Interface\]/i.test(conf) || !/\[Peer\]/i.test(conf)) {
				addErr.show(_('That does not look like a WireGuard file. It needs an [Interface] and a [Peer] section.'));
				confIn.focus();
				return;
			}

			app.run(addBtn, function() { return send(callWgImport, label, conf); }, addErr, function() {
				labelIn.value = '';
				confIn.value = '';
				ux.wgAdd = false;
				sync(app.status);
				okNote.show(_('Added. Choose it under Where your traffic exits.'), 'ok');
			});
		}
	}, [
		h('p', { class: 'tp-sub' }, _('A WireGuard file from UniFi, Proton, Mullvad or any provider that offers WireGuard.')),
		field(_('Profile name'), labelIn, _('Letters, numbers, spaces, dots and dashes. Left empty, it is called VPN.')),
		h('div', { class: 'tp-actions' }, btn(_('Load from file'), { kind: 'sm', click: function() { fileIn.click(); } })),
		field(_('Configuration'), confIn),
		h('div', { class: 'tp-actions' }, [ addBtn, btn(_('Cancel'), { kind: 'quiet', click: function() { ux.wgAdd = false; sync(app.status); } }) ]),
		addErr.el
	]);
	const addToggle = btn(_('Add profile'), { icon: 'plus', kind: 'sm', click: function() {
		ux.wgAdd = true;
		okNote.clear();
		sync(app.status);
		labelIn.focus();
	} });

	function sync(st) {
		const profiles = A(st.wireguard).filter(function(p) { return p && p.name; });

		syncRows(list, profiles, {
			key: function(p) { return 'w:' + p.name; },
			sig: function(p) { return JSON.stringify([ p.label, p.name, p.endpoint, p.up, ux.confirm === 'wg:' + p.name ]); },
			make: makeRow
		});

		toggleHidden(empty, profiles.length > 0);
		toggleHidden(addForm, !ux.wgAdd);
		toggleHidden(addToggle, !!ux.wgAdd);
	}

	const body = h('div', { class: 'tp-acc-inner' }, [ list, empty, err.el, okNote.el, h('div', { class: 'tp-actions' }, addToggle), addForm, fileIn ]);

	return { el: body, update: sync };
}

/* "Look like one device": a switch that shows status.hide_router and sends set_hide_router. */
function buildHideRouter(app) {
	const err = msgSlot();
	const labelId = uid('hide');
	const sw = h('button', {
		type: 'button',
		class: 'tp-switch-ctl',
		role: 'switch',
		'aria-checked': 'false',
		'aria-labelledby': labelId,
		click: function() {
			const on = (app.status.hide_router === true);

			app.run(sw, function() { return send(callSetHideRouter, !on); }, err);
		}
	}, h('span', { class: 'tp-switch-thumb' }));

	const el = h('div', { class: 'tp-toggle', hidden: true }, [
		h('div', { class: 'tp-toggle-row' }, [
			h('div', { class: 'tp-toggle-text' }, [
				h('span', { class: 'tp-row-title', id: labelId }, _('Look like one device')),
				h('span', { class: 'tp-row-sub' }, _("Wi-Fi networks and phone carriers can't tell a router is sharing the connection. While on, traceroute from your devices won't show the route."))
			]),
			sw
		]),
		err.el
	]);

	return {
		el: el,
		update: function(st) {
			/* No field, no switch: an older router cannot do this. */
			const on = (st.hide_router === true);

			toggleHidden(el, typeof(st.hide_router) != 'boolean');
			sw.setAttribute('aria-checked', on ? 'true' : 'false');
			sw.classList.toggle('is-on', on);
		}
	};
}

function buildMore(app) {
	const ux = app.ux;
	const hide = buildHideRouter(app);

	const macSummary = h('span', { class: 'tp-acc-sum' }, '');
	const macBody = buildMacBody(app);
	const macAcc = accordion(app, 'mac', _('MAC address the network sees'), macSummary, macBody.el);

	const tsBody = buildTailscaleBody(app);
	const tsSummary = pill('idle', '');
	const tsAcc = accordion(app, 'tailscale', _('Tailscale'), tsSummary, tsBody.el);

	const wgSummary = h('span', { class: 'tp-acc-sum' }, '');
	const wgBody = buildWgBody(app);
	const wgAcc = accordion(app, 'wg', _('VPN profiles'), wgSummary, wgBody.el);

	const settings = h('a', { class: 'tp-acc-link', href: L.url('admin/status/overview') }, [
		h('span', { class: 'tp-acc-title' }, _('All OpenWrt settings')),
		icon('chev-right', 'tp-chev-r')
	]);

	const accs = { mac: macAcc, tailscale: tsAcc, wg: wgAcc };

	function summaries(st) {
		const ts = O(st.tailscale);
		const s = TS_STATE[ts.state];

		const mw = O(O(st.mac).wifi);

		setText(macSummary, mw.ssid ? ({ original: _('Original'), random: _('Random'), custom: _('Custom') }[mw.kind] || '') : '');

		if (s)
			setPill(tsSummary, s[0], s[1]);
		else
			setPill(tsSummary, 'idle', ts.state ? str(ts.state) : '');

		toggleHidden(tsSummary, !ts.state);

		const n = A(st.wireguard).length;

		setText(wgSummary, n ? (n === 1 ? _('1 profile') : _('%d profiles').format(n)) : _('None yet'));
	}

	const el = h('section', { class: 'tp-card tp-more' }, [
		h('div', { class: 'tp-card-head' }, h('h3', { class: 'tp-h2' }, _('More'))),
		h('div', { class: 'tp-acc-list' }, [ hide.el, macAcc.el, tsAcc.el, wgAcc.el, settings ])
	]);

	return {
		el: el,
		accs: accs,
		update: function(st) {
			hide.update(st);
			summaries(st);
			macBody.update(st);
			tsBody.update(st);
			wgBody.update(st);

			Object.keys(accs).forEach(function(k) { accs[k].set(!!ux.more[k]); });
		}
	};
}

/* ------------------------------------------------------------------ *
 *  Sheet: one device
 * ------------------------------------------------------------------ */

function openDeviceSheet(app, mac, opener) {
	const sheet = app.openSheet({ title: _('Device'), opener: opener });
	const find = function(st) { return A(st.devices).find(function(d) { return d && d.mac === mac; }) || null; };
	const dev0 = find(app.status) || { mac: mac };

	const facts = h('div', { class: 'tp-facts' });
	const gone = h('p', { class: 'tp-note', hidden: true }, _('This device is not connected right now.'));

	/* type: what the device is, for its icon, when the guess from its name is wrong */
	const kindErr = msgSlot();
	const kindNote = h('p', { class: 'tp-hint' }, '');
	const kindBtns = {};
	const kindGrid = h('div', { class: 'tp-kinds', role: 'group', 'aria-label': _('Type') },
		[ '' ].concat(Object.keys(KIND_NAMES)).map(function(k) {
			const b = h('button', {
				type: 'button',
				class: 'tp-kind-btn',
				'aria-pressed': 'false',
				click: function() { app.run(b, function() { return send(callDeviceKind, mac, k); }, kindErr); }
			}, [ icon(k || 'auto'), h('span', { class: 'tp-kind-label' }, k ? KIND_NAMES[k] : _('Automatic')) ]);

			kindBtns[k] = b;

			return b;
		}));

	/* rename */
	const renameErr = msgSlot();
	const nameIn = h('input', { type: 'text', class: 'tp-input', maxlength: '40', autocomplete: 'off', spellcheck: 'false', value: str(dev0.name) });
	const renameBtn = btn(_('Save name'), { kind: 'primary', type: 'submit' });
	let nameDirty = false;

	nameIn.addEventListener('input', function() { nameDirty = true; });

	const renameForm = h('form', {
		class: 'tp-form',
		novalidate: '',
		submit: function(ev) {
			ev.preventDefault();

			const name = nameIn.value.trim();

			if (!name) {
				renameErr.show(_('Enter a name first.'));
				nameIn.focus();
				return;
			}

			app.run(renameBtn, function() { return send(callDeviceRename, mac, name); }, renameErr, function() {
				nameDirty = false;
				renameErr.show(_('Saved.'), 'ok');
			});
		}
	}, [ field(_('Name'), nameIn, _('Letters, numbers and dashes. Spaces become dashes.')), h('div', { class: 'tp-actions' }, renameBtn), renameErr.el ]);

	/* block */
	const blockErr = msgSlot();
	const blockHelp = h('p', { class: 'tp-sub' }, '');
	const blockBtn = btn('', { click: function() {
		const d = find(app.status) || dev0;

		app.run(blockBtn, function() { return send(callDeviceBlock, mac, !d.blocked); }, blockErr);
	} });

	/* address for the Wi-Fi login. A phone or a Mac uses a private address per network (the locally
	 * administered bit): the one the router sees is not the one the hotel approved, so the button would
	 * copy the wrong address. All three of Corey's devices do this (2026-10-08). */
	const privateMac = (parseInt(str(mac).slice(0, 2), 16) & 2) === 2;
	const macErr = msgSlot();
	const macBtn = btn(_("Use this device's MAC for the Wi-Fi login"), { hidden: privateMac, click: function() {
		app.run(macBtn, function() { return send(callMac, 'wifi', 'set', mac); }, macErr, function() {
			macErr.show(_("Done. The Wi-Fi reconnects with this device's address; the network may ask for its login again."), 'ok');
		});
	} });
	const macHelp = h('p', { class: 'tp-sub' }, privateMac
		? _("This device uses a private address for each Wi-Fi network, so the network it logged in to saw a different one. Look it up on the device (iPhone: Settings, Wi-Fi, the ⓘ next to that network, Wi-Fi Address; Android: that network's details), then enter it under More, MAC address the network sees.")
		: _('Some Wi-Fi networks tie a login to one device. Use this after that device has logged in, so the network sees the router as that device. The Wi-Fi reconnects with its address.'));

	function paint(st) {
		const d = find(st);
		const cur = d || dev0;
		const name = deviceName(cur);

		sheet.setHead(name, null, []);

		clear(facts);
		addKids(facts, [
			[ _('Address'), cur.mac ],
			[ _('IP'), cur.ip ],
			[ _('System'), systemName(cur) ],
			[ _('Connection'), join([ bandName(cur.band), signalWord(null, cur.signal) ]) ]
		].filter(function(r) { return r[1]; }).map(function(r) {
			return h('div', { class: 'tp-kv' }, [ h('span', { class: 'tp-kv-k' }, r[0]), h('span', { class: 'tp-kv-v' }, r[1]) ]);
		}));

		toggleHidden(gone, !!d);

		const chosen = KIND_NAMES[cur.kind] ? cur.kind : '';
		const guess = kindGuess(cur);

		Object.keys(kindBtns).forEach(function(k) {
			kindBtns[k].classList.toggle('is-on', k === chosen);
			kindBtns[k].setAttribute('aria-pressed', k === chosen ? 'true' : 'false');
		});
		setText(kindNote, (guess.from === 'name')
			? _('Automatic: %s, going by the name it announces.').format(KIND_NAMES[guess.kind])
			: (guess.from === 'system')
				? _('Automatic: %s, from how it asked for its address (%s).').format(KIND_NAMES[guess.kind], systemName(cur))
				: _('Automatic: nothing in its name or its address request to go by, so it shows its first letter.'));

		if (!nameDirty && !isFocused(nameIn))
			nameIn.value = str(cur.name);

		setBtnLabel(blockBtn, cur.blocked ? _('Unblock internet') : _('Block internet'));
		setText(blockHelp, cur.blocked ? _('This device is blocked. Unblock it to let it reach the internet again.') : _('Stops this device from reaching the internet.'));
	}

	sheet.update = paint;

	addKids(sheet.body, [
		facts,
		gone,
		h('h3', { class: 'tp-h3' }, _('Type')),
		kindGrid,
		kindNote,
		kindErr.el,
		h('h3', { class: 'tp-h3' }, _('Rename')),
		renameForm,
		h('h3', { class: 'tp-h3' }, _('Internet access')),
		blockHelp,
		h('div', { class: 'tp-actions' }, blockBtn),
		blockErr.el,
		h('h3', { class: 'tp-h3' }, _('Wi-Fi login')),
		macHelp,
		h('div', { class: 'tp-actions', hidden: privateMac }, macBtn),
		macErr.el
	]);

	paint(app.status);

	return sheet;
}

/* ------------------------------------------------------------------ *
 *  Sheet: choose Wi-Fi
 * ------------------------------------------------------------------ */

const SECURITY_CHOICES = [
	[ 'psk', _('Password (WPA2)') ],
	[ 'sae', _('Password (WPA3)') ],
	[ 'sae-mixed', _('Password (WPA2 or WPA3)') ],
	[ 'open', _('No password') ],
	[ 'enterprise', _('Username and password') ]
];

function normalizeNetworks(list) {
	const best = {};

	A(list).forEach(function(n) {
		n = O(n);

		const ssid = str(n.ssid);

		if (!ssid)
			return;

		const key = ssid + '\n' + str(n.band);
		const q = (num(n.quality) != null) ? n.quality : 0;
		const prev = best[key];

		if (!prev || q > prev.quality)
			best[key] = {
				ssid: ssid,
				bssid: str(n.bssid),
				band: str(n.band),
				channel: n.channel,
				quality: q,
				security: n.security || 'psk',
				saved: !!n.saved || !!(prev && prev.saved)
			};
		else if (n.saved)
			prev.saved = true;
	});

	return Object.keys(best).map(function(k) { return best[k]; }).sort(function(a, b) {
		return (b.quality - a.quality) || a.ssid.localeCompare(b.ssid);
	});
}

function wifiCountryLine(st) {
	const w = O(st.wifi);

	if (!w.country)
		return _('Country rules: not known yet.');

	const cur = str(w.country).toUpperCase();
	const det = str(w.country_detected).toUpperCase();

	/* The source only describes the detected country. */
	if (det && det !== cur)
		return _('Country rules: %s, set by you.').format(countryLabel(cur));

	return w.country_source
		? _('Country rules: %s, from %s.').format(countryLabel(cur), w.country_source)
		: _('Country rules: %s.').format(countryLabel(cur));
}

function openWifiSheet(app, opener) {
	const S = {
		view: 'list',
		scanning: false,
		scanned: false,
		scanErr: '',
		networks: [],
		saved: [],
		scanPromise: null,
		confirmForget: null,
		progress: null
	};

	const sheet = app.openSheet({ title: _('Choose Wi-Fi'), opener: opener });
	const qrErr = msgSlot();
	const savedErr = msgSlot();
	let countryEl = null, scanLine = null, scanText = null, scanNote = null, netList = null, savedBox = null;

	const refreshBtn = h('button', {
		type: 'button',
		class: 'tp-icon-btn',
		'aria-label': _('Scan again'),
		click: function() { scan(); }
	}, icon('refresh'));

	const fileInput = h('input', {
		type: 'file',
		accept: 'image/*',
		capture: 'environment',
		class: 'tp-vh',
		tabindex: '-1',
		'aria-hidden': 'true',
		change: function() {
			const f = fileInput.files && fileInput.files[0];

			fileInput.value = '';

			if (f)
				onQrFile(f);
		}
	});
	const qrBtn = btn(_('QR code'), { icon: 'qr', click: function() {
		/* Start fetching the decoder now, while the camera or file picker is open. */
		loadJsQR().catch(function() {});
		fileInput.click();
	} });
	const hiddenBtn = btn(_('Hidden network'), { icon: 'eye-off', click: function() {
		showJoin({ hidden: true, ssid: '', band: '2g', security: 'psk', saved: false, key: '', identity: '', note: '' });
	} });

	sheet.el.appendChild(fileInput);

	/* ---- scanning ---- */

	function scan() {
		if (S.scanning)
			return S.scanPromise;

		S.scanning = true;
		S.scanErr = '';
		setBusy(refreshBtn, true);
		renderNets();

		/* One band at a time, 2.4 GHz first (about 1 s), then 5 GHz (about 6 s). Each
		 * answer holds every network heard so far, so the list fills in as the search
		 * goes (Corey, 2026-10-06: nothing showed until the whole search was done, 19 s). */
		let listed = false, lastErr = '';
		const step = function(band) {
			return sendSlow(60, callWifiScan, band).then(function(res) {
				if (res.ok === true) {
					listed = true;
					S.networks = normalizeNetworks(res.networks);
				}
				else
					lastErr = res.error || GENERIC_ERROR;

				renderNets();
			});
		};

		S.scanPromise = step('2g').then(function() { return step('5g'); }).then(function() {
			S.scanning = false;
			S.scanned = true;
			setBusy(refreshBtn, false);

			if (!listed)
				S.scanErr = lastErr;

			renderNets();

			return S.networks;
		});

		return S.scanPromise;
	}

	function loadSaved() {
		return send(callWifiSaved).then(function(res) {
			if (res.ok === true)
				S.saved = A(res.networks).filter(function(n) { return n && n.ssid; });

			renderNets();
			renderSaved();
		});
	}

	function isSaved(ssid) {
		return S.saved.some(function(s) { return s.ssid === ssid; });
	}

	/* ---- list view ---- */

	function netRow(n) {
		const secured = (n.security !== 'open');
		const label = join([ n.ssid, bandName(n.band), qualityWord(n.quality), secured ? _('password needed') : _('open') ]).replace(/ \u00B7 /g, ', ');

		return h('button', {
			type: 'button',
			class: 'tp-net',
			'aria-label': label,
			click: function() {
				showJoin({ hidden: false, ssid: n.ssid, band: n.band, security: n.security, saved: n.saved, key: '', identity: '', note: '' });
			}
		}, [
			signalIcon(qualityLevel(n.quality)),
			h('span', { class: 'tp-row-text' }, [
				h('span', { class: 'tp-row-title' }, n.ssid),
				h('span', { class: 'tp-row-sub' }, join([ bandName(n.band), qualityWord(n.quality), n.saved ? _('Saved') : '' ]))
			]),
			secured ? icon('lock', 'tp-net-lock') : null
		]);
	}

	function renderNets() {
		if (!netList)
			return;

		const nets = S.networks.map(function(n) {
			return Object.assign({}, n, { saved: n.saved || isSaved(n.ssid) });
		});

		syncRows(netList, nets, {
			key: function(n) { return n.ssid + '|' + n.band; },
			sig: function(n) { return JSON.stringify([ n.ssid, n.band, n.quality, n.security, n.saved ]); },
			make: netRow
		});

		toggleHidden(scanLine, !S.scanning);
		toggleHidden(netList, nets.length === 0);

		if (scanText)
			scanText.textContent = nets.length ? _('Looking for more networks\u2026') : _('Looking for networks\u2026');

		if (S.scanErr)
			setNote(scanNote, S.scanErr + ' ' + _('Tap the refresh button to scan again.'));
		else if (S.scanned && !S.scanning && !nets.length)
			setNote(scanNote, _('No networks found. Move closer to a window, then scan again.'));
		else
			setNote(scanNote, '');
	}

	function renderSaved() {
		if (!savedBox)
			return;

		clear(savedBox);

		if (!S.saved.length)
			return;

		savedBox.appendChild(h('h3', { class: 'tp-h3' }, _('Saved networks')));

		const rows = h('div', { class: 'tp-list' });

		S.saved.forEach(function(s) {
			const confirming = (S.confirmForget === s.ssid);
			const forgetBtn = btn(_('Forget'), { kind: 'sm', aria: _('Forget %s').format(s.ssid), click: function() {
				S.confirmForget = s.ssid;
				savedErr.clear();
				renderSaved();
			} });
			const yes = btn(_('Forget'), { kind: 'sm danger', click: function() {
				app.run(yes, function() { return send(callWifiForget, s.ssid); }, savedErr, function() {
					S.confirmForget = null;
					S.networks.forEach(function(n) { if (n.ssid === s.ssid) n.saved = false; });
					loadSaved();
				});
			} });
			const no = btn(_('Cancel'), { kind: 'sm quiet', click: function() { S.confirmForget = null; renderSaved(); } });

			/* Connect switches to a saved network with what is saved: no password typed
			 * again (2026-10-05: a saved network offered only Forget). The router reloads
			 * its Wi-Fi, so this page may lose it for a moment; the main page shows how it goes. */
			const cur = A(O(app.status).uplinks).filter(function(u) { return u && u.kind === 'wifi' && u.up && u.ssid; })[0];
			const inUse = !!cur && cur.ssid === s.ssid && (!cur.band || !s.band || cur.band === s.band);
			const connectBtn = btn(_('Connect'), { kind: 'sm', aria: _('Connect to %s').format(s.ssid), click: function() {
				app.run(connectBtn, function() {
					return send(callWifiJoin, s.ssid, s.band, '', undefined, '', '', '');
				}, savedErr, function() {
					app.closeSheet();
				}, RESTARTING);
			} });

			rows.appendChild(h('div', { class: 'tp-row tp-row-wrap' }, [
				h('span', { class: 'tp-row-text' }, [
					h('span', { class: 'tp-row-title' }, s.ssid),
					h('span', { class: 'tp-row-sub' }, join([ bandName(s.band), s.enabled === false ? _('Off') : '', inUse ? _('In use') : '' ]))
				]),
				confirming ? h('span', { class: 'tp-confirm-inline' }, [ h('span', { class: 'tp-sub' }, _('Forget this network?')), no, yes ])
					: h('span', { class: 'tp-confirm-inline' }, [ inUse ? null : connectBtn, forgetBtn ])
			]));
		});

		savedBox.appendChild(rows);
		savedBox.appendChild(savedErr.el);
	}

	function showList() {
		S.view = 'list';
		S.progress = null;
		sheet.sticky = false;
		sheet.setHead(_('Choose Wi-Fi'), null, [ refreshBtn ]);
		clear(sheet.body);

		countryEl = h('p', { class: 'tp-sub' }, wifiCountryLine(app.status));
		scanText = h('span', {}, _('Looking for networks\u2026'));
		scanLine = h('p', { class: 'tp-sub tp-scanline', hidden: true, role: 'status' }, [
			h('span', { class: 'tp-spin', 'aria-hidden': 'true' }), scanText
		]);
		scanNote = h('p', { class: 'tp-note warn', hidden: true }, '');
		netList = h('div', { class: 'tp-list', role: 'list' });
		savedBox = h('div', { class: 'tp-saved' });

		/* saved networks first: switching between them needs no search (Corey, 2026-10-06) */
		addKids(sheet.body, [
			countryEl,
			h('div', { class: 'tp-actions tp-two' }, [ qrBtn, hiddenBtn ]),
			qrErr.el,
			savedBox,
			scanLine,
			scanNote,
			netList
		]);

		renderNets();
		renderSaved();
	}

	/* ---- QR ---- */

	function onQrFile(file) {
		qrErr.clear();
		setBusy(qrBtn, true);

		const fail = function(msg) {
			setBusy(qrBtn, false);
			qrErr.show(msg);
		};

		/* Let the busy state paint before the decoder takes over the thread. */
		new Promise(function(resolve) { window.setTimeout(resolve, 40); })
			.then(function() { return decodeQr(file); })
			.then(function(text) {
				if (text == null)
					return fail(_("Couldn't find a QR code in that photo. Try again closer."));

				const w = parseWifiQR(text);

				if (!w)
					return fail(_("That QR code is not for a Wi-Fi network. Look for the one that says Wi-Fi."));

				if (w.security === 'wep')
					return fail(_('This network uses WEP, which the router cannot join. Ask the owner of the network for another way to connect.'));

				if (!w.ssid)
					return fail(_('That QR code has no network name in it. Try another code for the network.'));

				/* Wait for a scan in progress, so a fast photo is not mistaken for a hidden network. */
				return Promise.resolve(S.scanning ? S.scanPromise : null).then(function() {
					setBusy(qrBtn, false);

					const hit = S.networks.find(function(n) { return n.ssid === w.ssid; });

					if (hit)
						showJoin({
							hidden: false, ssid: hit.ssid, band: hit.band, security: hit.security,
							saved: hit.saved || isSaved(hit.ssid), key: w.password, identity: w.identity,
							note: _('Filled in from the QR code.')
						});
					else
						showJoin({
							hidden: true, ssid: w.ssid, band: '2g', security: w.security,
							saved: isSaved(w.ssid), key: w.password, identity: w.identity,
							note: _('This network was not in the scan, so it is treated as hidden. Choose its band if you know it.')
						});
				});
			})
			.catch(function(err) {
				fail((err && err.tpMsg) || _("Couldn't read that photo. Try another one."));
			});
	}

	/* ---- join view ---- */

	function showJoin(j) {
		S.view = 'join';
		S.confirmForget = null;
		sheet.sticky = true;
		sheet.setHead(j.hidden ? _('Hidden network') : _('Join %s').format(j.ssid), function() { showList(); }, []);
		clear(sheet.body);

		const err = msgSlot();
		const ssidIn = h('input', {
			type: 'text', class: 'tp-input', value: j.ssid, readonly: !j.hidden, maxlength: '32',
			autocomplete: 'off', autocapitalize: 'none', autocorrect: 'off', spellcheck: 'false'
		});
		const bandSeg = segmented(_('Band'), [ [ '2g', bandName('2g') ], [ '5g', bandName('5g') ] ], j.band, function(v) { j.band = v; }, 'tp-seg-2');
		const secSel = h('select', { class: 'tp-select' }, SECURITY_CHOICES.map(function(c) { return h('option', { value: c[0] }, c[1]); }));
		const idIn = h('input', {
			type: 'text', class: 'tp-input', value: j.identity || '', autocomplete: 'off',
			autocapitalize: 'none', autocorrect: 'off', spellcheck: 'false'
		});
		const pwIn = h('input', {
			type: 'password', class: 'tp-input', value: j.key || '', autocomplete: 'off',
			autocapitalize: 'none', autocorrect: 'off', spellcheck: 'false', enterkeyhint: 'go'
		});
		const eye = h('button', { type: 'button', class: 'tp-icon-btn', 'aria-label': _('Show password'), 'aria-pressed': 'false', click: function() {
			const show = (pwIn.type === 'password');

			pwIn.type = show ? 'text' : 'password';
			eye.setAttribute('aria-pressed', show ? 'true' : 'false');
			eye.setAttribute('aria-label', show ? _('Hide password') : _('Show password'));
			clear(eye).appendChild(icon(show ? 'eye-off' : 'eye'));
		} }, icon('eye'));

		const idRow = field(_('Username'), idIn);
		const pwRow = field(_('Password'), h('span', { class: 'tp-input-row' }, [ pwIn, eye ]));
		const noPw = h('p', { class: 'tp-text', hidden: true }, _('This network has no password.'));
		const savedNote = h('p', { class: 'tp-sub', hidden: !j.saved }, _('Already saved: leave the password empty to use the saved one, or type a new one.'));
		const joinBtn = btn(_('Join'), { kind: 'primary block', type: 'submit' });
		const result = h('div', { class: 'tp-result', hidden: true });

		secSel.value = SECURITY_CHOICES.some(function(c) { return c[0] === j.security; }) ? j.security : 'psk';
		secSel.addEventListener('change', function() { j.security = secSel.value; creds(); });

		function creds() {
			const sec = j.security;
			const open = (sec === 'open' || sec === 'owe');

			toggleHidden(idRow, sec !== 'enterprise');
			toggleHidden(pwRow, open);
			toggleHidden(noPw, !open);
		}

		function bad(msg, el) {
			err.show(msg);

			if (el)
				el.focus();
		}

		/* What the join looks like from status: the Wi-Fi uplink shows the network it is on. */
		function progressText(st) {
			const ups = A(st.uplinks);
			const u = ups.find(function(x) { return x && x.ssid === j.joined; });
			const wifi = ups.find(function(x) { return x && (x.name === 'trm_wwan' || x.kind === 'wifi'); });
			const p = O(st.portal);

			if (u && u.online)
				return { tone: 'ok', pill: _('Connected'), text: _('Internet works.') };

			if (u && u.up)
				return {
					tone: 'warn',
					pill: _('No internet yet'),
					text: (p.state === 'detected' || /login/i.test(str(u.detail)))
						? _('The Wi-Fi wants a login first.')
						: _('Connected to the Wi-Fi, but the internet is not answering yet.')
				};

			/* A wrong password never says so; after a while, say what to try. */
			if (Date.now() - (j.joinedAt || Date.now()) > 45000)
				return { tone: 'warn', pill: _('Not connected'), text: _('Still not connected. Check the password, then join again.') };

			if (wifi && wifi.up && wifi.ssid && wifi.ssid !== j.joined)
				return { tone: 'idle', pill: _('Connecting'), text: _('Still on %s. Waiting for the new network.').format(wifi.ssid) };

			/* The router's own words, unless they only repeat the pill. */
			const detail = wifi ? str(wifi.detail) : '';

			return { tone: 'idle', pill: _('Connecting'), text: (detail && !/^connecting/i.test(detail)) ? detail : _('Waiting for the network to answer.') };
		}

		function done() {
			const status = pill('idle', _('Connecting'));
			const line = h('p', { class: 'tp-text' }, '');
			const loginLink = h('a', { class: 'tp-btn sm', target: '_blank', rel: 'noopener noreferrer', href: FALLBACK_LOGIN_URL, hidden: true }, [
				icon('external'), h('span', { class: 'tp-btn-label' }, _('Open login page'))
			]);

			clear(result);
			addKids(result, [
				h('p', { class: 'tp-note ok' }, _('Saved. The router reconnects to it next time by itself.')),
				h('div', { class: 'tp-progress' }, [ status, line ]),
				h('div', { class: 'tp-actions' }, [
					loginLink,
					btn(_('Done'), { kind: 'primary', click: function() { app.closeSheet(); } })
				])
			]);
			toggleHidden(result, false);
			toggleHidden(joinBtn, true);

			S.progress = function(st) {
				const p = progressText(st);
				const url = safeUrl(O(st.portal).url) || FALLBACK_LOGIN_URL;

				setPill(status, p.tone, p.pill);
				setText(line, p.text);
				toggleHidden(loginLink, O(st.portal).state !== 'detected');
				loginLink.setAttribute('href', url);
			};
			S.progress(app.status);
		}

		function submit() {
			const ssid = j.hidden ? ssidIn.value : j.ssid;
			const sec = j.security;
			let key, identity, password;

			if (!ssid)
				return bad(_('Enter the network name first.'), ssidIn);

			if (utf8Length(ssid) > 32)
				return bad(_('Network names have at most 32 characters. Check the name and try again.'), ssidIn);

			if (sec === 'psk' || sec === 'sae' || sec === 'sae-mixed') {
				const v = pwIn.value;

				/* empty on a saved network: the router keeps the password it has */
				if (!v && !j.saved)
					return bad(_('Enter the password first.'), pwIn);

				if (v && (v.length < 8 || v.length > 63))
					return bad(_('Wi-Fi passwords have 8 to 63 characters. Check it and try again.'), pwIn);

				key = v;
			}
			else if (sec === 'enterprise' && !(j.saved && !idIn.value && !pwIn.value)) {
				if (!idIn.value)
					return bad(_('Enter the username first.'), idIn);

				if (!pwIn.value)
					return bad(_('Enter the password first.'), pwIn);

				identity = idIn.value;
				password = pwIn.value;
			}

			j.joined = ssid;
			j.joinedAt = Date.now();

			app.run(joinBtn, function() {
				return send(callWifiJoin, ssid, j.band, sec, undefined, key, identity, password);
			}, err, function() {
				/* No new scan here: scanning while the router is still joining can drop the link. */
				S.networks.forEach(function(n) { if (n.ssid === ssid) n.saved = true; });
				done();
				loadSaved();
			}, RESTARTING);
		}

		creds();

		addKids(sheet.body, h('form', {
			class: 'tp-form',
			novalidate: '',
			submit: function(ev) { ev.preventDefault(); submit(); }
		}, [
			j.note ? h('p', { class: 'tp-note info' }, j.note) : null,
			field(_('Network name'), ssidIn),
			j.hidden ? field(_('Band'), bandSeg.el, null, true) : null,
			j.hidden ? field(_('Security'), secSel) : null,
			idRow,
			pwRow,
			noPw,
			savedNote,
			err.el,
			h('div', { class: 'tp-actions' }, joinBtn),
			result
		]));

		if (j.hidden && !j.ssid)
			ssidIn.focus();
		else if (!pwRow.hasAttribute('hidden') && !j.key)
			(j.security === 'enterprise' ? idIn : pwIn).focus();
	}

	sheet.update = function(st) {
		if (S.view === 'list' && countryEl)
			setText(countryEl, wifiCountryLine(st));

		if (S.progress)
			S.progress(st);
	};

	showList();
	scan();
	loadSaved();

	return sheet;
}

/* ------------------------------------------------------------------ *
 *  The view
 * ------------------------------------------------------------------ */

return view.extend({
	load: function() {
		return callStatus().catch(function() { return {}; });
	},

	render: function(status) {
		const app = this;

		app.status = O(status);
		app.speed = [];
		app.lastSample = 0;
		app.failures = hasData(app.status) ? 0 : 1;
		app.inflight = null;
		app.again = false;
		app.sheet = null;
		app.ux = {
			pendingMode: null,
			ordering: false,
			uplinkDraft: null,	/* the order being arranged, not yet applied */
			uplinkPending: null,	/* the order just applied, until status reports it */
			wifiEdit: false,
			wifiDirty: false,
			wgAdd: false,
			confirm: null,
			dismissed: {},
			tsAuth: '',
			tsWaitSince: 0,
			more: {}
		};

		/* versioned like LuCI's own scripts (luciversion-pkgs_update_time): without it a
		 * browser kept an old panel.css after an update (2026-10-06) */
		const link = E('link', { rel: 'stylesheet', href: L.resource('travel/panel.css') +
			(L.env.resource_version ? '?v=' + encodeURIComponent(L.env.resource_version) : '') });

		app.banner = h('p', { class: 'tp-banner', role: 'status', hidden: true },
			_('Lost contact with the router. Stay on its Wi-Fi and wait a few seconds.'));

		app.cards = [
			buildHeader(app),
			buildSuggest(app),
			buildSpeed(app),
			buildLogin(app),
			buildExit(app),
			buildUplinks(app),
			buildDevices(app),
			buildWifi(app),
			buildModeSwitch(app),
			buildMore(app)
		];

		app.moreCard = app.cards[app.cards.length - 1];

		const wrap = h('div', { class: 'tp-wrap' }, [ app.banner ].concat(app.cards.map(function(c) { return c.el; })));

		/* Hidden until the stylesheet is in, so the page never flashes unstyled. */
		const root = h('div', { class: 'travel-panel', style: 'visibility:hidden' }, [ link, wrap ]);
		const reveal = function() { root.style.visibility = ''; };

		link.addEventListener('load', reveal);
		link.addEventListener('error', reveal);
		window.setTimeout(reveal, 2500);

		app.root = root;
		app.applyStatus(app.status);
		app.setBanner();

		poll.add(function() {
			return document.hidden ? Promise.resolve() : app.refresh();
		}, POLL_SECONDS);

		document.addEventListener('visibilitychange', function() {
			if (!document.hidden)
				app.refresh();
		});

		return root;
	},

	/* Reads status once. Overlapping calls are folded into one follow-up read. */
	refresh: function() {
		const app = this;

		if (app.inflight) {
			app.again = true;
			return app.inflight;
		}

		app.inflight = callStatus().then(function(res) {
			res = O(res);

			if (!hasData(res)) {
				app.failures++;
			}
			else {
				app.failures = 0;
				app.applyStatus(res);
			}
		}, function() {
			app.failures++;
		}).catch(reportBug).then(function() {
			app.inflight = null;
			app.setBanner();

			if (app.again) {
				app.again = false;
				return app.refresh();
			}
		});

		return app.inflight;
	},

	setBanner: function() {
		toggleHidden(this.banner, !(this.failures >= 2 || (this.failures >= 1 && !hasData(this.status))));
	},

	applyStatus: function(st) {
		const app = this;
		const now = Date.now();
		const sp = O(st.speed);

		app.status = st;

		if ((num(sp.rx_bps) != null || num(sp.tx_bps) != null) && now - app.lastSample >= SAMPLE_GAP_MS) {
			app.lastSample = now;
			app.speed.push({ rx: num(sp.rx_bps) || 0, tx: num(sp.tx_bps) || 0 });

			while (app.speed.length > SPEED_SAMPLES)
				app.speed.shift();
		}

		app.cards.forEach(function(c) {
			try { c.update(st); }
			catch (e) { reportBug(e); }
		});

		if (app.sheet && app.sheet.update) {
			try { app.sheet.update(st); }
			catch (e) { reportBug(e); }
		}
	},

	/*
	 * Runs one command from a button: busy state on the button, the message
	 * from the router (if any) in `slot`, then a fresh status read.
	 * onOk(res) runs when the command worked. `restartNote` replaces the
	 * message when the connection dropped, which is what happens when the
	 * router's own Wi-Fi restarts.
	 */
	run: function(b, fn, slot, onOk, restartNote) {
		const app = this;

		if (b && b.classList.contains('is-busy'))
			return Promise.resolve(null);

		const started = Date.now();
		let p;

		setBusy(b, true);

		if (slot)
			slot.clear();

		try {
			p = Promise.resolve(fn());
		}
		catch (e) {
			reportBug(e);
			p = Promise.resolve({ ok: false, error: GENERIC_ERROR });
		}

		return p.then(function(res) {
			return new Promise(function(resolve) {
				window.setTimeout(function() { resolve(res); }, Math.max(0, MIN_BUSY_MS - (Date.now() - started)));
			});
		}).then(function(res) {
			res = O(res);
			setBusy(b, false);

			if (res.ok === true) {
				if (onOk)
					onOk(res);
			}
			else if (slot) {
				slot.show((res.transport && restartNote) ? restartNote : (res.error || GENERIC_ERROR));
			}

			app.afterCommand();

			return res;
		}).catch(reportBug);
	},

	afterCommand: function() {
		const app = this;

		app.refresh();
		FOLLOW_UPS_MS.forEach(function(ms) { window.setTimeout(function() { app.refresh(); }, ms); });
	},

	openMore: function(key) {
		this.ux.more[key] = true;
		this.moreCard.update(this.status);

		const el = this.moreCard.accs[key] && this.moreCard.accs[key].el;

		if (el && typeof(el.scrollIntoView) == 'function')
			el.scrollIntoView({ behavior: 'smooth', block: 'center' });
	},

	toggleMore: function(key) {
		this.ux.more[key] = !this.ux.more[key];
		this.moreCard.update(this.status);
	},

	updateMoreSummary: function() {
		this.moreCard.update(this.status);
	},

	/* One sheet at a time. Returns { el, body, setHead, close, update, sticky }. */
	openSheet: function(opts) {
		const app = this;

		app.closeSheet();

		const titleId = uid('sheet');
		const titleEl = h('h2', { class: 'tp-sheet-title', id: titleId }, opts.title || '');
		const back = h('button', { type: 'button', class: 'tp-icon-btn', 'aria-label': _('Back'), hidden: true }, icon('back'));
		const actions = h('span', { class: 'tp-sheet-actions' });
		const closeBtn = h('button', { type: 'button', class: 'tp-icon-btn', 'aria-label': _('Close'), click: function() { app.closeSheet(); } }, icon('close'));
		const body = h('div', { class: 'tp-sheet-body' });
		const box = h('div', {
			class: 'tp-sheet',
			role: 'dialog',
			'aria-modal': 'true',
			'aria-labelledby': titleId,
			tabindex: '-1'
		}, [ h('div', { class: 'tp-sheet-head' }, [ back, titleEl, actions, closeBtn ]), body ]);
		const overlay = h('div', { class: 'tp-overlay' }, box);
		const prevOverflow = document.body.style.overflow;

		const api = {
			el: box,
			body: body,
			sticky: false,
			update: null,
			setHead: function(title, backFn, extra) {
				setText(titleEl, title);
				back.onclick = backFn ? function() { backFn(); } : null;
				toggleHidden(back, !backFn);
				clear(actions);
				addKids(actions, extra || []);
			},
			close: function() { app.closeSheet(); }
		};

		const onKey = function(ev) {
			if (ev.key === 'Escape') {
				ev.preventDefault();
				app.closeSheet();
				return;
			}

			if (ev.key !== 'Tab')
				return;

			const items = Array.prototype.filter.call(
				box.querySelectorAll('button, input, select, textarea, a[href]'),
				function(n) { return !n.disabled && n.tabIndex >= 0 && n.offsetParent !== null; });

			if (!items.length)
				return;

			const first = items[0], last = items[items.length - 1];

			if (ev.shiftKey && (document.activeElement === first || document.activeElement === box)) {
				ev.preventDefault();
				last.focus();
			}
			else if (!ev.shiftKey && document.activeElement === last) {
				ev.preventDefault();
				first.focus();
			}
		};

		overlay.addEventListener('click', function(ev) {
			if (ev.target === overlay && !api.sticky)
				app.closeSheet();
		});

		document.addEventListener('keydown', onKey);
		document.body.style.overflow = 'hidden';
		app.root.appendChild(overlay);

		api.setHead(opts.title || '', null, []);

		app.sheet = api;
		api._teardown = function() {
			document.removeEventListener('keydown', onKey);
			document.body.style.overflow = prevOverflow;

			if (overlay.parentNode)
				overlay.parentNode.removeChild(overlay);

			if (opts.opener && document.body.contains(opts.opener) && typeof(opts.opener.focus) == 'function')
				opts.opener.focus();
		};

		box.focus();

		return api;
	},

	closeSheet: function() {
		const s = this.sheet;

		if (!s)
			return;

		this.sheet = null;
		s._teardown();
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
