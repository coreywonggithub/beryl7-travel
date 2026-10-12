#!/usr/bin/env node
// Open LuCI's standard pages in a headless browser against the UI sandbox
// (test/serve-ui.sh), the way a person would, and report what a person would
// see go wrong: error banners, failed RPC calls, script errors. Optionally
// keep a screenshot of each page, which is what a theme is designed against.
//
//   node test/ui-pages.js [options] [page ...]
//
//   --port N        sandbox port on this machine (default 8088; reach a build-box
//                   sandbox with  ssh -N -L 8089:127.0.0.1:8089 <build box>)
//   --shots DIR     save one PNG per page into DIR
//   --dark          render with prefers-color-scheme: dark
//   --width N       viewport width in px (default 1280; 390 is a phone)
//   --text          also print the visible text of each page
//   page            path below /cgi-bin/luci/, e.g. admin/network/wireless
//                   (default: the pages listed in PAGES below). It is LuCI's own
//                   path, so admin/system/package-manager has a hyphen; a path LuCI
//                   does not know fails at once and names the nearest real one.
//                   Screenshot file names are not paths: every / and - becomes _.
//
// Needs playwright-core and a Chromium it can start: set PLAYWRIGHT_CORE to
// its directory if it is not resolvable from here. Uses 127.0.0.1, not
// "localhost": browsers share cookies between ports of one host name, so two
// sandboxes on one host name would log each other out.
// Exit status 1 if any page shows a banner or a failed call.
'use strict';

const PAGES = [
	'admin/status/overview', 'admin/status/routes', 'admin/status/nftables', 'admin/status/logs/syslog', 'admin/status/logs/dmesg',
	'admin/status/processes', 'admin/status/channel_analysis',
	'admin/status/realtime/load', 'admin/status/realtime/bandwidth', 'admin/status/realtime/wireless',
	'admin/status/realtime/connections',
	'admin/network/network', 'admin/network/wireless', 'admin/network/dhcp', 'admin/network/dns',
	'admin/network/routes', 'admin/network/diagnostics',
	'admin/network/firewall/zones', 'admin/network/firewall/forwards', 'admin/network/firewall/rules',
	'admin/network/firewall/snats',
	'admin/system/system', 'admin/system/admin/password', 'admin/system/admin/dropbear',
	'admin/system/admin/sshkeys', 'admin/system/admin/uhttpd', 'admin/system/package-manager',
	'admin/system/startup', 'admin/system/crontab', 'admin/system/mounts', 'admin/system/leds', 'admin/system/flash',
	'admin/system/reboot',
	'admin/travel',
	'admin/services/travelmate/overview', 'admin/services/travelmate/stations', 'admin/services/travelmate/logread',
	'admin/services/nlbw/display', 'admin/services/nlbw/config', 'admin/services/nlbw/backup'
];
const PASSWORD = process.env.SANDBOX_PASSWORD || 'sandbox-only';	// see serve-ui.sh

const args = process.argv.slice(2);
let port = 8088, shots = null, dark = false, width = 1280, showText = false;
const pages = [];
for (let i = 0; i < args.length; i++) {
	if (args[i] === '--port') port = +args[++i];
	else if (args[i] === '--shots') shots = args[++i];
	else if (args[i] === '--dark') dark = true;
	else if (args[i] === '--width') width = +args[++i];
	else if (args[i] === '--text') showText = true;
	else if (args[i].startsWith('-')) { console.error(`unknown option ${args[i]}`); process.exit(2); }
	else pages.push(args[i]);
}
if (!pages.length) pages.push(...PAGES);

let chromium;
try { ({ chromium } = require(process.env.PLAYWRIGHT_CORE || 'playwright-core')); }
catch (e) { console.error('playwright-core not found: npm i playwright-core, or set PLAYWRIGHT_CORE'); process.exit(2); }
const fs = require('fs');

// LuCI probes for optional files, configs and names: "not found" (ubus status 4)
// from these is its normal answer. From anything else it means a stub is missing.
const UBUS_NOT_FOUND = 4;
const PROBES = /^(file|uci|network\.rrdns)\./;

(async () => {
	const base = `http://127.0.0.1:${port}`;
	const browser = await chromium.launch({ headless: true });
	const ctx = await browser.newContext({ viewport: { width, height: 900 }, colorScheme: dark ? 'dark' : 'light' });
	const page = await ctx.newPage();
	let calls = [], scriptErrors = [];

	page.on('pageerror', (e) => scriptErrors.push(String(e.message).split('\n')[0].slice(0, 200)));
	page.on('response', async (resp) => {
		if (!/\/ubus/.test(resp.url())) return;
		try {
			const req = JSON.parse(resp.request().postData() || 'null');
			const res = await resp.json();
			const reqs = Array.isArray(req) ? req : [req];
			(Array.isArray(res) ? res : [res]).forEach((r, i) => {
				const q = reqs.find((x) => x && x.id === r.id) || reqs[i] || {};
				const p = q.params || [], a = p[3] || {};
				const arg = a.path || a.config || a.name || a.device || a.mode || '';
				const what = `${p[1]}.${p[2]}${arg ? `(${arg})` : ''}`;
				if (r.error) calls.push({ what, bad: true, why: `${r.error.code} ${r.error.message}` });
				else if (Array.isArray(r.result) && typeof r.result[0] === 'number' && r.result[0] !== 0)
					calls.push({ what, bad: !(r.result[0] === UBUS_NOT_FOUND && PROBES.test(what)), why: `ubus status ${r.result[0]}` });
			});
		} catch (e) { /* not a JSON-RPC exchange */ }
	});

	await page.goto(`${base}/cgi-bin/luci`, { waitUntil: 'load' });
	await page.fill('input[type=password]', PASSWORD);
	await Promise.all([page.waitForNavigation({ waitUntil: 'load' }).catch(() => {}), page.keyboard.press('Enter')]);
	if (shots) fs.mkdirSync(shots, { recursive: true });

	// every page LuCI's menu knows, to name the right path when one is mistyped
	const menuPaths = await page.evaluate(async () => {
		const out = [];
		const walk = (n, path) => { for (const k of Object.keys(n.children || {})) { out.push(`${path}/${k}`.replace(/^\//, '')); walk(n.children[k], `${path}/${k}`); } };
		try { walk(await (await fetch('/cgi-bin/luci/admin/menu', { credentials: 'same-origin' })).json(), ''); } catch (e) { /* no hint then */ }
		return out;
	});
	const squash = (x) => x.toLowerCase().replace(/[-_]/g, '');
	const nearest = (p) => menuPaths.filter((m) => squash(m) === squash(p) || squash(m.split('/').pop()) === squash(p.split('/').pop()));

	let failed = 0;
	for (const p of pages) {
		calls = []; scriptErrors = [];
		const t0 = Date.now();
		const resp = await page.goto(`${base}/cgi-bin/luci/${p}`, { waitUntil: 'load' });
		const status = resp ? resp.status() : 0;
		if (status === 404 || status === 403 || status >= 500) {	// no view will ever appear: say why, at once
			const near = nearest(p);
			const why = status === 404 ? `HTTP 404: LuCI has no page at this path${near.length ? `; did you mean ${near.join(' or ')}?` : ''}`
				: status === 403 ? 'HTTP 403: the login page came back (session lost: did the sandbox restart?)'
				: `HTTP ${status}: LuCI failed to build the page`;
			failed++;
			console.log(`FAIL  ${p}  (${Date.now() - t0} ms)\n        ${why}`);
			continue;
		}
		let rendered = true;
		try {
			await page.waitForFunction(() => {
				const v = document.querySelector('#view');
				return v && v.children.length && !/Loading view/.test(v.innerText) && !v.querySelector(':scope > .spinning');
			}, null, { timeout: 30000 });
		} catch (e) { rendered = false; }
		await page.waitForTimeout(2500);	// what the view fills in after its first paint
		const info = await page.evaluate(() => ({
			banners: [...document.querySelectorAll('.alert-message')]
				.filter((e) => e.offsetParent !== null)
				.map((e) => e.innerText.replace(/\s+/g, ' ').trim().slice(0, 300)),
			text: (document.querySelector('#view') || document.body).innerText.replace(/[ \t]+/g, ' ').replace(/\n{2,}/g, '\n').trim()
		}));
		const shot = shots ? `${shots}/${p.replace(/[^a-z0-9]+/gi, '_')}.png` : null;
		if (shot) await page.screenshot({ path: shot, fullPage: true });

		const bad = calls.filter((c) => c.bad).map((c) => `${c.what} -> ${c.why}`);
		const probes = [...new Set(calls.filter((c) => !c.bad).map((c) => c.what))];
		const problems = [];
		if (!rendered) problems.push('the page never finished loading');
		for (const b of info.banners) problems.push(`banner: ${b}`);
		for (const b of new Set(bad)) problems.push(`rpc: ${b}`);
		for (const s of new Set(scriptErrors)) problems.push(`script: ${s}`);
		if (problems.length) failed++;

		console.log(`${problems.length ? 'FAIL' : 'ok  '}  ${p}  (${Date.now() - t0} ms)${shot ? `  -> ${shot}` : ''}`);
		for (const x of problems) console.log(`        ${x}`);
		if (probes.length && process.env.VERBOSE) console.log(`        not found (normal): ${probes.join(', ')}`);
		if (showText) console.log(info.text.split('\n').map((l) => `        | ${l}`).join('\n'));
	}
	await browser.close();
	console.log(`\n${pages.length - failed} of ${pages.length} pages clean${failed ? `, ${failed} with problems` : ''}`);
	process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
