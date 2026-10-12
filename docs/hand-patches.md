# Hand patches to other packages' files

The image changes two files that belong to upstream packages: one in travelmate, one in OpenWrt's
wifi scripts (a third, travelmate's login-page check, was taken upstream and dropped in image v5; see
"Taken upstream" below). They are not built into those packages: scripts in `files/etc/uci-defaults/` edit the
installed files at first boot. That has two consequences every firmware or package update must
respect:

- **An upgrade removes them.** `apk upgrade travelmate` (or wifi-scripts) on a router replaces the
  file, and the fix is gone until the script runs again. Never upgrade those packages on a trip.
- **They fail quietly.** Each script hooks onto a line of upstream code. When that code changes, the
  script refuses at first boot and only logs it; the router then runs without the fix and nothing
  in the panel shows it.

This register says what each patch changes, why, how to see it on a router, whether upstream has
taken it, and when to drop it. Written 2026-10-06; keep it in step with the scripts.

## The checks

- **Every build:** `build/build.sh` runs `build/check-hand-patches.sh` on the exact travelmate and
  wifi-scripts sources the build uses, right after the feeds are installed, and stops if a patch no
  longer applies, or if a fix we dropped because upstream took it is missing from upstream's code. It
  also prints a `NOTE` when the unpatched source looks like upstream has taken a fix over. Proven 2026-10-06 on the sources image v4 was built from (all apply) and on four broken
  copies (each refused, exit 1).
- **A router:** `test/router-drift.sh` (run from the mini) counts each patch's mark on the live
  router; each should be 1.
- **By hand on a router:** `grep -c "<mark>" <file>`, with the marks and files below.

## Updating travelmate or OpenWrt (moving `PACKAGES_PIN` or `OPENWRT_PIN` in `build/versions.env`)

1. Read what changed upstream in `travelmate-functions.sh` (`f_scan`, `f_net`) and in wifi-scripts'
   `supplicant.uc` (`setup_sta`) between the old pin and the new one.
2. Build, or run the check alone on the build box after `./scripts/feeds update -a`:
   `build/check-hand-patches.sh feeds/packages/net/travelmate/files/travelmate-functions.sh package/network/config/wifi-scripts/files-ucode/usr/share/ucode/wifi/supplicant.uc`
   - `applies` and no `NOTE`: keep the patch.
   - `DOES NOT APPLY`: the code it hooks onto changed. Read the new code. If upstream fixed the
     problem, delete the script and its section here. If not, rewrite the script for the new code,
     keep its mark text so the checks still find it, and run the check again.
   - `NOTE`: upstream seems to have taken the fix over. Confirm by reading the code and testing on the
     router, then delete the script and its section, and its mark from `test/router-drift.sh`.
3. After flashing, `test/router-drift.sh` should show each remaining mark once.

## A router whose package was upgraded

Run the scripts again; each is idempotent and refuses if its hook is gone. From the mini:
`ssh root@<router> 'sh -s' < files/etc/uci-defaults/96_beryl7_travelmate_scan` (likewise 98), then
`/etc/init.d/travelmate restart` after 96, or `wifi reload` after 98. Check the marks afterwards.

## The patches

### 96: travelmate scans through the access point

- **File:** `/usr/lib/travelmate-functions.sh`, function `f_scan` (package travelmate,
  openwrt/packages `net/travelmate`). Script: `files/etc/uci-defaults/96_beryl7_travelmate_scan`.
- **Mark:** `beryl7: ap-force scan`. The router flashed 2026-10-05 carries the earlier hand-applied
  version, marked `beryl7 hotfix 2026-10-05`; both count.
- **Why (found on the hardware 2026-10-05):** both bands share one wiphy (mt7996e). A scan while the
  radio runs an access point only heard that access point's own channel block, so a 5 GHz-only
  network on another channel never appeared and travelmate never connected. Scanning through the
  access point interface with `iw dev <ap> scan ap-force` hears the whole band, and iwinfo's results
  then include it.
- **Cost:** during each scan the radio's own access point leaves its channel for a moment, as during
  the panel's search.
- **Known waste:** iwinfo's scan call then scans again, about 6 s per band (measured 2026-10-06). The
  panel's search reads the list with `iw ... scan dump` instead (`b26e984`); travelmate does not yet.
- **Upstream:** declined. Reported 2026-10-06 (https://github.com/openwrt/packages/issues/30710),
  closed "won't fix" the same night. The maintainer's
  reasons: the driver can scan other channels while an access point runs (our ap-force result shows
  it), so the limit comes from below travelmate, most likely how iwinfo or wpa_supplicant scan on one
  wiphy that serves several radios; and an ap-force pre-scan takes the router's own access point off
  its channel on every scan cycle, relies on the shared scan cache as a side effect, and adds an `iw`
  dependency for one driver. So 96 stays ours. A fix upstream would belong in OpenWrt itself (iwinfo's
  scan on a radio that runs an access point), not in travelmate.
- **Drop when:** iwinfo (or travelmate) hears other channels on a radio that runs an access point. The
  check prints a `NOTE` when "ap-force" appears in travelmate.

### 98: a Wi-Fi uplink stays on its radio's band

- **File:** `/usr/share/ucode/wifi/supplicant.uc`, function `setup_sta` (package wifi-scripts,
  openwrt/openwrt `package/network/config/wifi-scripts/files-ucode/`). Script:
  `files/etc/uci-defaults/98_beryl7_station_band`.
- **Mark:** `beryl7: station held to its band`.
- **Why (found on the hardware 2026-10-05):** `supplicant.uc` writes the radio's frequencies only as
  wpa_supplicant's global `freq_list`, which limits scanning, not which access point is chosen. Both
  bands share one wiphy, so the other band's access points are in the station's scan results anyway,
  and an uplink saved on the 2.4 GHz radio joined the same network's 5 GHz access point and took the
  router's own 2.4 GHz Wi-Fi with it. With `freq_list` in the network block as well, wpa_supplicant
  only chooses access points on that radio's frequencies.
- **Upstream:** not in openwrt-25.12 or main on 2026-10-06. Reported 2026-10-06:
  https://github.com/openwrt/openwrt/issues/25662.
  Still open on 2026-10-07. The evening it was filed (2026-10-06 22:30 Taipei) a contributor asked for a
  pull request; that needs the author's own Signed-off-by, so it is not sent automatically.
- **Drop when:** upstream writes `freq_list` in the network block. The check prints a `NOTE`.

## Taken upstream

### 97: travelmate sees a login page on https (dropped in image v5, 2026-10-07)

- **What it did:** in `f_net` of `/usr/lib/travelmate-functions.sh`, after a redirect to another host,
  any curl error counted as a login page. Found on the hardware 2026-10-05: once a UniFi hotspot's login
  page moved to https with the gateway's own certificate (curl error 60), travelmate saw "no internet"
  instead of a login page, so no login script ran, and with `trm_netcheck=1` it connected and dropped
  every few seconds, taking the router's own Wi-Fi with it.
- **Upstream:** reported 2026-10-06 (https://github.com/openwrt/packages/issues/30709) and fixed by the
  maintainer the same night: "travelmate: minor cp fixes", master 990a907, openwrt-25.12 `e23a399`,
  travelmate 2.4.9-r3. Any curl error other than 6 after a redirect to another host is now a login page,
  the same rule as ours. The same commit strips the port from the login page's host, so the dnsmasq
  rebind list gets `192.168.10.1`, no longer `192.168.10.1:8444`.
- **Now:** `PACKAGES_PIN` is `e23a399` and the script is gone. `build/check-hand-patches.sh` requires
  upstream's line (`elif [ -n "${json_cp}" ] && [ "${json_cp}" != "${probe_host}" ]; then` in `f_net`)
  and stops the build if a later travelmate loses it (proven 2026-10-07: r3 passes; r2, and r3 with the
  line removed, fail). `test/router-drift.sh` counts that line on the router.
- **If upstream loses it:** read the new `f_net` first. Our script is in git:
  `git show 1c3441f^:files/etc/uci-defaults/97_beryl7_travelmate_https_portal`. It hooks onto r2's code,
  so it will likely need rewriting for the new one.

## Not hand patches, for completeness

- **Driver patches** (`patches/mt76/`, listed in `docs/third-party.md`) are applied by OpenWrt's build
  itself; one that no longer applies stops the build on its own.
- **travelmate settings** (`trm_netcheck=0` and the rest) are configuration, set by
  `package/luci-app-travel/root/etc/uci-defaults/80_travel`.
- **MU EDCA** (normal best-effort values on every radio, which raised uploads into the Beryl by about 50%)
  is our own Wi-Fi setting, set by `files/etc/uci-defaults/94_beryl7_mu_edca`
  (DEC-2026-1007-INFRA-BERYL7-UPLOAD-WAIT-FOR-UPSTREAM).
