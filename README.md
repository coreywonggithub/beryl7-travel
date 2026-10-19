# beryl7-travel

OpenWrt 25.12 firmware and a phone-first travel panel for the **GL.iNet Beryl 7 (GL-MT3600BE)**, a
Wi-Fi 7 travel router with both bands on one MediaTek MT7996 radio. Built from source at pinned commits,
with fixes for the Wi-Fi driver and hostapd that this router needed, and tested on the hardware in
week-long runs.

This is a personal project, not affiliated with GL.iNet. "Beryl" and "GL.iNet" are theirs; the name only
says which router this is for. Flashing replaces the stock firmware; GL.iNet's recovery page always lets
you go back (see [docs/FLASHING.md](docs/FLASHING.md)).

## Why this exists

The Beryl 7 is excellent hardware held back by its firmware. As of October 2026, GL.iNet's stock firmware
for it (4.9.0) is still **OpenWrt 21.02**, whose security support ended in April 2023, on **Linux 5.4**, a
kernel series that reached end of life in December 2025. Its Wi-Fi runs on MediaTek's closed driver,
built for that kernel only, so nothing newer can be dropped in. GL.iNet's older Beryl AX already has an
OpenWrt 24.10 option; for the Beryl 7, GL.iNet's answer has been that an OpenWrt 25.12 build is being
compiled and tested, with no date
([GL.iNet forum](https://forum.gl-inet.com/t/is-the-beryl-7-mt3600be-expected-to-get-option-of-op24-or-newer-firmware-in-the-foreseeable-future/69671)).

We got tired of waiting for GL.iNet's update schedule and moved the router to **OpenWrt 25.12** ourselves:
Linux 6.12, the open mt76 Wi-Fi driver, firewall4, and packages that need a current base, such as nikki.
The open driver is still young on this chip, which is why this repository carries patches for it and for
hostapd, and why every build is soak-tested on the router before we travel with it.

**Status, October 2026.** The current image ran a four-day soak test on our router before a trip: as a
Tailscale exit-node client and through nikki, behind a hotel-style login page, with hourly speed tests and a
laptop on its Wi-Fi the whole time. It found no Wi-Fi crash, no unexpected restart and no lost uplink, and
one problem: Tailscale's memory. That is fixed since (below), tested on the router but not yet soak-tested
in an image.

## What the panel does

The panel is the first page after login (LuCI, `luci-app-travel`). Everything a hotel room needs is on one
screen:

- **Wi-Fi login pages.** Hotel login pages are detected and the tunnel is paused while you log in, then
  resumed. A login can be saved per network and done automatically the next time.
- **Where your traffic exits:** directly, through a **Tailscale exit node** (with names you give them),
  through a **WireGuard** profile, or through **nikki** (mihomo) for networks that need a proxy. A
  physical slider on the router can switch between two of these.
- **Internet sources in order:** Ethernet, hotel Wi-Fi and a phone over USB. A health check moves traffic
  to the next source when one stops answering, and re-joins a Wi-Fi that dropped with nothing else up.
- **Choose Wi-Fi:** networks appear as the search finds them; saved ones first; join by QR code.
- **Devices:** who is connected, data use, rename, block.
- **Your Wi-Fi:** name, password, channels, and country rules taken from the network you join.
- **More:** the MAC address the hotel sees (original, random or your own), hiding that several devices
  share the connection (TTL), Tailscale login, VPN profiles.

Two themes come with it: **Beryl Console** (`luci-theme-beryl`) and
[Aquamarine](https://github.com/coreywonggithub/luci-theme-aquamarine), the same look as a standalone
LuCI theme.

## What is in the image

- OpenWrt 25.12 at the commit in [build/versions.env](build/versions.env), with the feeds pinned too.
- **mt76 (Wi-Fi driver) patches** in [patches/mt76](patches/mt76): TX rates on the MT7990, stale TX
  status, a cached rate kept after a station re-joins, and frames stranded in the TX queue.
- **hostapd patches** in [patches/hostapd](patches/hostapd):
  - `991` is hostapd's own upstream fix `bf9a9eac9` (2026-03-04), which OpenWrt 25.12's hostapd predates: it
    cancels the scan timeout of an access point that is removed while it scans. With both bands on one
    radio, the 5 GHz access point was removed in the middle of its start-up scan whenever the uplink
    reconnected; the timeout fired later into freed memory and hostapd crashed, dropping all Wi-Fi. We first
    fixed it ourselves before finding upstream's commit; the analysis is in
    [docs/hostapd-crash.md](docs/hostapd-crash.md).
  - `990` and `hostapd-files/hostapd.uc.patch`: fixes backported from OpenWrt main (2026-10-08).
- **travelmate** (the Wi-Fi uplink manager) with two small first-boot patches, explained in
  [docs/hand-patches.md](docs/hand-patches.md): scanning through the access point on a shared radio, and
  keeping the uplink station on its own band.
- **Tailscale** 1.102.3 (OpenWrt 25.12's own build) with a Go memory limit set at first boot, and a guard
  that restarts it every 10 minutes if its memory still passes 180 MB. As an exit-node client it grew past
  200 MB on this 512 MB router: not a leak, but WireGuard's packet-buffer pool plus Go keeping freed memory.
  With the limit it peaked at 77 MB at the same speed ([docs/hand-patches.md](docs/hand-patches.md), 95).
- nikki, zram, CAKE-ready traffic shaping modules, and USB tethering for Android and iPhone.

## Build

On an x86-64 Linux box (Ubuntu 24.04 tested) with OpenWrt's
[build prerequisites](https://openwrt.org/docs/guide-developer/toolchain/install-buildsystem):

```sh
W=~/beryl7-build
git clone https://github.com/coreywonggithub/beryl7-travel "$W/project"
git clone https://github.com/coreywonggithub/luci-theme-aquamarine "$W/aquamarine-repo"
IMAGE_LABEL=mine bash "$W/project/build/build.sh"
```

The first build clones OpenWrt into `$W/openwrt` and compiles the toolchain, which takes a while; later
builds take a few minutes. The
image is `$W/openwrt/bin/targets/mediatek/filogic/openwrt-mediatek-filogic-glinet_gl-mt3600be-squashfs-sysupgrade.bin`.
`build.sh` runs without root; its header says how to supply the two host tools Ubuntu lacks without root.
OpenWrt makes a package signing key during the first build and `build.sh` keeps a copy in `$W/keys`; keep
it, so routers trust the packages of your later builds.

The router reads its first-boot settings from `files/`. Our own image also gets a root password, a Wi-Fi
name and password, and the exit-node names of our tailnet from files kept out of this repository. Yours
starts like a fresh OpenWrt: no password, Wi-Fi off until you set a Wi-Fi password in the panel, and the
LAN at `172.31.77.1` (moved off `192.168.1.1`, which clashes with many hotel networks).

## Tests

```sh
bash test/run.sh
```

244 checks of the panel's backend, the first-boot scripts and the health check, run in a throwaway
OpenWrt 25.12 x86-64 root filesystem under a user namespace: no root, and no network the tests can touch.
Put `openwrt-25.12-*-x86-64-rootfs.tar.gz` (from downloads.openwrt.org) in `~/beryl7-build/testbed` first.
`test/serve-ui.sh` serves the whole LuCI with the panel against an imaginary router, for looking at it in a
browser.

## Documentation

- [docs/FLASHING.md](docs/FLASHING.md): flashing, upgrading and going back to stock
- [docs/panel-design.md](docs/panel-design.md) and [docs/panel-api.md](docs/panel-api.md): the panel
- [docs/hostapd-crash.md](docs/hostapd-crash.md): the hostapd crash and its fix
- [docs/hand-patches.md](docs/hand-patches.md): the first-boot patches to other packages
- [docs/sqm-design.md](docs/sqm-design.md): traffic shaping
- [docs/third-party.md](docs/third-party.md): bundled third-party code

## Licence

Our code is GPL-2.0-only ([LICENSE](LICENSE)). Some parts keep their own licences:

- `package/luci-theme-beryl` is Apache-2.0: it is derived from LuCI's Bootstrap theme
  (see its [NOTICE](package/luci-theme-beryl/NOTICE)).
- `jsQR.js` in the panel is Apache-2.0 ([docs/third-party.md](docs/third-party.md)).
- The patches in `patches/` modify mt76 (ISC) and hostapd (BSD-3-Clause) and are offered under those
  projects' licences.

The analysis and much of the code were written with the help of an AI assistant (Claude) and tested on the
hardware.
