#!/usr/bin/ucode
// Uplink health (2026-10-08, after Corey's failover test B). The router uses the uplink with the lowest
// metric that has a route out, and a route is all it checks: a hotel Wi-Fi that stays connected while its
// internet is dead kept all the traffic for the whole test (60 s), with the phone ready beside it.
//
// Every 10 s this pings two addresses (one reachable from China, one outside; either will do) out of the
// uplink in use, bound to its device, so neither nikki nor Tailscale is in the way. After 3 misses in a
// row it adds a default route through the next uplink that answers, one metric better than the dead one's
// and marked "proto 251": traffic moves without netifd re-applying anything and without touching the saved
// order. After 6 answers in a row from the demoted uplink, the route goes and traffic returns. It gives the
// routing back to netifd at once if the backup goes away, stops answering, or the order changes. While a
// Wi-Fi login page is being handled (the watcher's portal hold) it judges nothing: pings fail there by
// design, and travelmate's login must not be fought.
//
// When the Wi-Fi uplink is dead and nothing else answers, it re-joins the Wi-Fi (2026-10-12, after soak run 1:
// the office guest Wi-Fi kept the router associated but passed nothing from 01:38 to 06:30, and only the access
// point's own kick at 06:28 brought it back, by a re-join that found the login page). It waits 3 minutes, then
// re-joins; if that does not help, again after 10, 30 and then every 60 minutes, never during a login page.
// A re-join is wpa_supplicant's REASSOCIATE: about a second offline, the DHCP lease renewed, travelmate's
// login-page check run again (measured on the router 2026-10-12). A cable or a phone has nothing to re-join.
//
// /var/run/travel/failover holds the current detour as JSON, for the panel's status.
//   health.uc            the loop (the travel service runs it)
//   health.uc once       one step, its memory in $HEALTH_STATE (tests; with HEALTH_PING, HEALTH_IP and
//                        HEALTH_DUMP standing in for ping, ip and netifd, HEALTH_NOW for the clock and
//                        HEALTH_REJOIN for the re-join command)
'use strict';

import { readfile, writefile, unlink, popen } from 'fs';
import { connect } from 'ubus';

const RUN = '/var/run/travel';
const DETOUR = `${RUN}/failover`;
const PROTO = 251;
const TARGETS = [ '223.5.5.5', '1.1.1.1' ];	// AliDNS, Cloudflare
const FAIL_N = 3;
const OK_N = 6;
const INTERVAL = 10;
const PING = getenv('HEALTH_PING') ?? 'ping';
const IP = getenv('HEALTH_IP') ?? 'ip';
const REJOIN = getenv('HEALTH_REJOIN');
const REJOIN_AFTER = [ 180, 600, 1800, 3600 ];	// seconds before each re-join; the last one repeats

function now() {
	const n = getenv('HEALTH_NOW');

	return n ? +n : time();
}

function sh(cmd) {
	const p = popen(cmd);

	if (!p)
		return '';

	const out = p.read('all');

	p.close();

	return trim(out ?? '');
}

function note(msg) {
	system(`logger -t travel ${sprintf('%J', msg)}`);
}

function answers(dev) {
	for (let t in TARGETS)
		if (system(`${PING} -I ${dev} -c 1 -W 2 -q ${t} >/dev/null 2>&1`) == 0)
			return true;

	return false;
}

// the uplinks netifd has with a way out, best first: { name, dev, gw, metric }
function uplinks() {
	let dump;

	if (getenv('HEALTH_DUMP'))
		dump = json(readfile(getenv('HEALTH_DUMP')) ?? '{}');
	else {
		const bus = connect();

		dump = bus?.call('network.interface', 'dump', {});
		bus?.disconnect();
	}

	const out = [];

	for (let i in (dump?.interface ?? [])) {
		if (!i.up || !i.l3_device)
			continue;

		if (i.interface != 'wan' && i.interface != 'trm_wwan' && index(i.interface, 'tether_') != 0)
			continue;

		for (let r in (i.route ?? []))
			if (r.target == '0.0.0.0' && r.mask == 0) {
				push(out, { name: i.interface, dev: i.l3_device, gw: r.nexthop, metric: +(i.metric ?? 0) });
				break;
			}
	}

	return sort(out, (a, b) => a.metric - b.metric);
}

// the Wi-Fi uplink is dead and no other uplink answers: re-join it, with the backoff above
function rejoin(s, cur) {
	const t = now();
	const wifi = (cur.name == 'trm_wwan');

	if (!s.dead) {
		s.dead = t;
		s.tries = 0;
		note(`no internet through ${cur.name} (${cur.dev}), and no other uplink answers either` +
			(wifi ? `: re-joining the Wi-Fi in ${REJOIN_AFTER[0] / 60} min if it stays so` : ''));
	}

	if (!wifi)
		return;

	const wait = REJOIN_AFTER[min(s.tries, length(REJOIN_AFTER) - 1)];

	if (t - (s.last_try ?? s.dead) < wait)
		return;

	s.tries++;
	s.last_try = t;
	note(`no internet through ${cur.name} for ${int((t - s.dead) / 60)} min: re-joining the Wi-Fi (attempt ${s.tries}, the next in ${REJOIN_AFTER[min(s.tries, length(REJOIN_AFTER) - 1)] / 60} min if it stays down)`);

	if (REJOIN)
		system(`${REJOIN} ${cur.dev}`);
	else
		system(`ubus call wpa_supplicant.${cur.dev} control '{"command":"REASSOCIATE"}' >/dev/null 2>&1`);
}

function ours_present() {
	return sh(`${IP} -4 route show default proto ${PROTO} 2>/dev/null`) != '';
}

function give_back(s, why) {
	system(`${IP} -4 route flush proto ${PROTO} >/dev/null 2>&1`);
	unlink(DETOUR);

	if (s.detour)
		note(`${s.detour.from}: ${why}; routing back to normal`);

	s.detour = null;
	s.fails = 0;
	s.oks = 0;
	s.bad_backup = 0;
}

function step(s) {
	if (readfile(`${RUN}/portal`) != null) {	// a login page is being handled
		s.fails = 0;
		s.oks = 0;
		return;
	}

	const ups = uplinks();

	if (!s.detour) {
		const cur = ups[0];

		// no uplink with a route at all (one is re-joining, or none is plugged in): nothing to judge, and the
		// backoff must not start over because a re-join took the route away for a moment
		if (!cur) {
			s.fails = 0;
			return;
		}

		if (answers(cur.dev)) {
			if (s.dead)
				note(`internet back through ${cur.name} after ${int((now() - s.dead) / 60)} min${s.tries ? ` and ${s.tries} re-join(s)` : ''}`);

			s.fails = 0;
			s.dead = null;
			s.tries = 0;
			s.last_try = null;
			return;
		}

		s.fails++;

		if (s.fails < FAIL_N)
			return;

		s.fails = 0;

		let alt = null;

		for (let k = 1; k < length(ups); k++)
			if (answers(ups[k].dev)) {
				alt = ups[k];
				break;
			}

		if (!alt)
			return rejoin(s, cur);

		// one better than the dead one's, at a number no other route has
		let m = cur.metric - 1;

		while (m >= 0 && sh(`${IP} -4 route show default metric ${m} 2>/dev/null`) != '')
			m--;

		if (m < 0) {
			note(`no internet through ${cur.name}, but no metric left below ${cur.metric} to route around it`);
			return;
		}

		system(`${IP} -4 route add default via ${alt.gw} dev ${alt.dev} metric ${m} proto ${PROTO} >/dev/null 2>&1`);

		s.detour = { from: cur.name, from_dev: cur.dev, from_metric: cur.metric, to: alt.name, to_dev: alt.dev, since: time() };
		s.oks = 0;
		s.bad_backup = 0;
		writefile(DETOUR, sprintf('%J', s.detour));
		note(`no internet through ${cur.name} (${cur.dev}) for ${FAIL_N * INTERVAL} s: traffic moved to ${alt.name} (${alt.dev})`);
		return;
	}

	const d = s.detour;
	const from = filter(ups, (u) => u.name == d.from)[0];
	const to = filter(ups, (u) => u.name == d.to)[0];

	if (!to || !ours_present())
		return give_back(s, `${d.to} is gone`);

	if (from && from.metric != d.from_metric)
		return give_back(s, 'the order changed');

	if (!from)
		return give_back(s, 'it disconnected');	// netifd's next uplink carries traffic by itself

	if (!answers(to.dev)) {
		if (++s.bad_backup >= FAIL_N)
			return give_back(s, `${d.to} stopped answering too`);
	}
	else
		s.bad_backup = 0;

	if (answers(from.dev)) {
		if (++s.oks >= OK_N)
			return give_back(s, `internet back for ${OK_N * INTERVAL} s`);
	}
	else
		s.oks = 0;
}

if (ARGV[0] == 'once') {
	const file = getenv('HEALTH_STATE') ?? '/tmp/health-state.json';
	const s = json(readfile(file) ?? '{}') ?? {};

	s.fails ??= 0;
	s.oks ??= 0;
	s.bad_backup ??= 0;
	s.tries ??= 0;
	step(s);
	writefile(file, sprintf('%J', s));
	exit(0);
}

// a detour left by an earlier run is stale: netifd's routes are the truth at start
const s = { fails: 0, oks: 0, bad_backup: 0, detour: null, dead: null, tries: 0, last_try: null };

give_back(s, 'restart');

while (true) {
	step(s);
	system(`sleep ${INTERVAL}`);
}
