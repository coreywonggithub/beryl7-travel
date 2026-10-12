# hostapd crash: a scan timeout outlives a removed access point (found 2026-10-12; fix in image v10)

## What happened

The Wi-Fi uplink dropped two to six times in the first minutes after a boot in exit-node mode, at the
morning login-page expiry, and during MAC changes and failover tests. The complete log showed 14 of these
since 2026-10-09: both radios torn down and rebuilt within two seconds, with no `wifi reload` before it.

Core dumps (`/tmp/hostapd.<time>.<pid>.11.core`, signal 11) and the unstripped `wpad` from the build tree
showed the same crash every time: hostapd in `hostapd_wpa_event()` handling event 3 (`EVENT_SCAN_RESULTS`)
called `iface->scan_cb` and jumped to garbage (`0xf0`, a heap address, and once the ASCII bytes of
`pd-phy0.`, the freed memory already reused for a string). A scan result reached an interface that had
been freed. Each crash came just after hostapd failed to re-create an access point:
`Failed to create interface phy0.x-ap0: -23 (Too many open files in system)`. procd restarts hostapd,
netifd rebuilds both radios, and travelmate, seeing the uplink gone, disables it, reloads and scans again.

In exit-node mode travelmate also starts before the uplink is up (Tailscale's interface comes up first),
finds it down and does that disable, reload and scan at boot, which is why that mode reproduced it on
every traced boot and direct mode did not.

## The fix

Upstream fixed this family on 2026-10-08, after our pin (openwrt-25.12 at 7673104, hostapd 2025-08-26):

- `1e0e106` hostapd: undo a failed AP BSS add in the nl80211 driver (C). Ours:
  `patches/hostapd/990-beryl7-nl80211-undo-a-failed-ap-bss-add.patch`, the same two hunks regenerated
  against our fully patched source so it applies last with no fuzz (upstream's applies with fuzz here,
  because our older 370 patch changes one context line).
- `a75b4c4` hostapd: continue a pending interface setup from the event loop, and
  `f3371c7` hostapd: abort a pending interface setup when its config is removed (both `hostapd.uc`).
  Ours: `patches/hostapd-files/hostapd.uc.patch`, which also adds `import * as uloop from "uloop"`:
  our older file lacks it and the new timer needs it (without it the callback throws).

`build/build.sh` copies the first into the package's patches and applies the second to the tree's file.

The two `hostapd.uc` fixes alone, hand-applied to a v8 router, cut an exit-node boot from two crashes to
one. The C fix is what handles the failed add itself.

## How to check a build

On the router after an exit-node reboot: `ls /tmp/*.core` (none), and the log's
`Failed to create interface` lines are no longer followed by both radios being torn down.
The reproducer kit (a `wifi` caller wrapper, one-second Wi-Fi config snapshots, `ubus monitor`) is
described in the router note; it lived in `/root/boottrace/` on the router.

## Image v9: the upstream fixes are not enough (2026-10-12 16:46)

v9 carries all three backports (checked in the image: `hostapd.uc` md5 fa518fc4, the C fix in the compiled
source, `wpad` rebuilt). The exit-node reboot still crashed hostapd twice in four minutes, as v8 did: 5 uplink
drops, 11 failed adds (-23). Both dumps are the same crash, event 3 in `hostapd_wpa_event()`, the bad pointer
once the ASCII of `pw=2#\nw` (a `wpa=2` config line in the freed memory).

Neither crash came during automatic channel selection (2.4 GHz is on Auto; ACS had finished at boot), and no
scan was logged before them. What fits: hostapd's nl80211 code hands an event that carries the wiphy index,
such as new scan results, to every BSS on that wiphy (`process_global_event()`), so any scan by the uplink
(wpa_supplicant reconnecting, travelmate looking for networks) reaches hostapd's access points. That is
harmless while their context is alive. After the failed re-adds, one BSS keeps a context that points at a
freed `hostapd_data`, and the next scan result crashes. Not yet proven which removal leaves it (hostapd's
debug level would show it); the upstream fixes cover a failed `nl80211_setup_ap()` and a re-entrant add, not
a failed interface creation (-23).

Next, in order: (1) find where the stale context is left, with hostapd's debug output during the exit-node
reboot; (2) cut the churn that feeds it (travelmate starting before the uplink is up, and its disable,
reload and bounce cycles); (3) report upstream with the dumps and the reproducer.

## The cause, found in the v9 dumps (2026-10-12 17:00 to 17:20)

hostapd's debug messages are compiled out in OpenWrt, so `-d` shows nothing; the dumps answered instead.

- The crash comes through a **timer**, not a netlink event: in every dump `hostapd_wpa_event()` is called
  straight from `eloop_run()`'s timeout branch (`handler(eloop_data, user_data)` at `eloop_run+520`), the
  handler's own frame gone to a tail call. The only timer that ends in
  `wpa_supplicant_event(ctx, EVENT_SCAN_RESULTS, NULL)` is `wpa_driver_nl80211_scan_timeout()`.
- Its two arguments were still in the caller's registers: x27 the driver (alive; its `phyname` reads `phy0`)
  and x28 the context, equal to the freed `hostapd_data` the crash used.
- Both bands are one wiphy here, so one nl80211 driver holds both access points; the 2.4 GHz one is its first
  BSS and the 5 GHz one a later one. `wpa_driver_nl80211_if_remove()` cancels the scan timeout when it
  removes the **first** BSS, and does not when it removes **another** one (also true of upstream hostap
  master, checked 2026-10-12). The 5 GHz AP starts an HT40 scan when it comes up (`COUNTRY_UPDATE->HT_SCAN`),
  and the station reconnects on the same radio remove it in the same second (`HT_SCAN->DISABLED`); its
  30 s timeout survives with the freed context, and when it fires and aborting the scan fails, hostapd
  dies. Run A: HT_SCAN and removal at 17:02:02, crash at 17:02:56.

Fix: `patches/hostapd/991-beryl7-nl80211-cancel-scan-timeout-of-removed-bss.patch` cancels that BSS's scan
timeout in the other branch too (cancel only: firing it early, as the first-BSS branch does, would run scan
handling on an access point being torn down). The 990 and hostapd.uc backports stay: correct, just not this.

Reported upstream 2026-10-12: https://github.com/openwrt/openwrt/issues/25840 (the code is upstream hostap's too).
