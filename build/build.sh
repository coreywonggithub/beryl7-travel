#!/bin/bash
# Reproducible OpenWrt build for the GL.iNet Beryl 7 (GL-MT3600BE).
# Runs unprivileged on the build box. Ubuntu lacks ncurses headers and unzip,
# so those come from ./hostdeps (dpkg -x of the .debs, no root needed).
set -euo pipefail
W="${W:-$HOME/beryl7-build}"
PROJ="$W/project"          # rsynced copy of ~/src/beryl7-travel from the mini
SRC="$W/openwrt"
JOBS="${JOBS:-18}"
HD="$W/hostdeps/root"
. "$PROJ/build/versions.env"
# Only unzip goes on PATH. The ncurses*-config scripts from the same .debs must
# stay off it: host tools' configure (util-linux) would find them and enable
# ncurses support without the headers, then fail on cur_term.
mkdir -p "$W/hostdeps/bin"
ln -sf "$HD/usr/bin/unzip" "$W/hostdeps/bin/unzip"
export PATH="$W/hostdeps/bin:$PATH"
log(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

# The -dev package's linker names point at runtime libs by relative path;
# point them at the system copies so the prerequisite link test works.
L="$HD/usr/lib/x86_64-linux-gnu"
for so in libncurses.so.6 libncursesw.so.6 libtinfo.so.6; do
  [ -e "$L/$so" ] || ln -sf "/usr/lib/x86_64-linux-gnu/$so" "$L/$so"
done

if [ ! -d "$SRC/.git" ]; then
  log "cloning $OPENWRT_BRANCH"
  git clone --branch "$OPENWRT_BRANCH" https://github.com/openwrt/openwrt.git "$SRC"
fi
cd "$SRC"
git fetch -q origin "$OPENWRT_BRANCH"
# a named branch at the pin, tracking upstream, so getver.sh reports r33249, not r0+33249
git checkout -q -B "$OPENWRT_BRANCH" "$OPENWRT_PIN"
git branch -q --set-upstream-to="origin/$OPENWRT_BRANCH"
log "openwrt $(git rev-parse --short HEAD) $(./scripts/getver.sh)"

# ncurses is only needed by the prerequisite check, whose result is cached in a
# stamp. toplevel.mk unexports C_INCLUDE_PATH, so hand the header over via CPATH,
# and only to the metadata steps below (feeds, defconfig). The compile never sees it.
PRE_ENV=(env CPATH="$HD/usr/include" LIBRARY_PATH="$L")

# Upstream feeds float with the branch tip; pin each to the commit in versions.env
sed -e "s|packages.git;$OPENWRT_BRANCH|packages.git^$PACKAGES_PIN|" \
    -e "s|luci.git;$OPENWRT_BRANCH|luci.git^$LUCI_PIN|" \
    -e "s|routing.git;$OPENWRT_BRANCH|routing.git^$ROUTING_PIN|" \
    -e "s|telephony.git;$OPENWRT_BRANCH|telephony.git^$TELEPHONY_PIN|" \
    -e "/^src-git video /d" feeds.conf.default > feeds.conf
# Aquamarine, the Console look as its own theme package, built from its pinned release commit
AQUA="$W/feed-aquamarine"
git -C "$W/aquamarine-repo" cat-file -e "$AQUAMARINE_PIN^{commit}" ||
	{ log "aquamarine-repo lacks $AQUAMARINE_PIN: git clone https://github.com/coreywonggithub/luci-theme-aquamarine $W/aquamarine-repo (or update it)"; exit 1; }
rm -rf "$AQUA" && mkdir -p "$AQUA/luci-theme-aquamarine"
git -C "$W/aquamarine-repo" archive "$AQUAMARINE_PIN" | tar -x -C "$AQUA/luci-theme-aquamarine"
sed -e "s|@NIKKI_PIN@|$NIKKI_PIN|" -e "s|@PROJ@|$PROJ|" -e "s|@AQUA@|$AQUA|" "$PROJ/build/feeds.extra" >> feeds.conf
grep -q ";$OPENWRT_BRANCH" feeds.conf && { log "unpinned feed left in feeds.conf"; exit 1; }
"${PRE_ENV[@]}" ./scripts/feeds update -a >/dev/null
"${PRE_ENV[@]}" ./scripts/feeds install -a >/dev/null
log "feeds ready"

# Our driver patches (mt76 carries none upstream on this branch)
mkdir -p package/kernel/mt76/patches
rm -f package/kernel/mt76/patches/9[0-9][0-9]-*.patch
cp "$PROJ"/patches/mt76/*.patch package/kernel/mt76/patches/

# Our hostapd fixes, backported from openwrt main (2026-10-08): hostapd crashed in hostapd_wpa_event()
# after a failed interface add, which dropped the Wi-Fi uplink at boots, login expiries and MAC changes
# (docs/hostapd-crash.md). The C fix goes into the package's patches; the hostapd.uc one is applied to the
# tree's own file, reset first so every build starts from the pinned version, and with no fuzz allowed.
rm -f package/network/services/hostapd/patches/99[0-9]-beryl7-*.patch
cp "$PROJ"/patches/hostapd/*.patch package/network/services/hostapd/patches/
git checkout -q -- package/network/services/hostapd/files/hostapd.uc
patch -s -p1 -F0 --no-backup-if-mismatch <"$PROJ/patches/hostapd-files/hostapd.uc.patch" ||
	{ log "patches/hostapd-files/hostapd.uc.patch no longer fits this tree"; exit 1; }

# First-boot overlay
rm -rf files && cp -a "$PROJ/files" files
# Which image this is, readable on the router: /etc/beryl7-image (IMAGE_LABEL, e.g. v5)
printf 'image=%s\ncommit=%s\nbuilt=%s\n' "${IMAGE_LABEL:-unlabelled}" \
	"$(git -C "$PROJ" rev-parse --short HEAD 2>/dev/null || echo unknown)$(git -C "$PROJ" status --porcelain -- \
		package files patches build 2>/dev/null | grep -q . && echo +local)" "$(date -u +%FT%TZ)" >files/etc/beryl7-image

# Hand patches to other packages' files (docs/hand-patches.md) run at first boot and refuse quietly
# when the code they hook onto has changed, so try them on this build's own sources first
"$PROJ/build/check-hand-patches.sh" feeds/packages/net/travelmate/files/travelmate-functions.sh \
	package/network/config/wifi-scripts/files-ucode/usr/share/ucode/wifi/supplicant.uc ||
	{ log "a hand patch no longer fits this build's sources: see docs/hand-patches.md"; exit 1; }
log "hand patches fit"

# Browsers cache the Beryl theme's stylesheets by ?v=<beryl_rev> in its header.ut: a stylesheet change
# without a newer beryl_rev reaches nobody who has opened the panel before (the Glow on 2026-10-08 and the
# menu fix on 2026-10-09 both missed it). Compared by day, from the project's own history.
rev_day=$(sed -n "s/^[[:space:]]*const beryl_rev = '\([0-9]\{8\}\).*/\1/p" "$PROJ/package/luci-theme-beryl/ucode/template/themes/beryl/header.ut")
# (no history, e.g. a downloaded archive: nothing to compare)
css_day=$(git -C "$PROJ" log -1 --format=%cd --date=format:%Y%m%d -- package/luci-theme-beryl/htdocs 2>/dev/null || true)
[ -n "$rev_day" ] && [ "$rev_day" -ge "${css_day:-0}" ] ||
	{ log "beryl_rev ($rev_day) is older than the theme's last stylesheet change ($css_day): bump it in header.ut"; exit 1; }

# One signing key for every build, so a router flashed today trusts the
# packages built next year. Keep the private key safe outside the source tree;
# the working copy is $W/keys. build/apk-signing-public-key.pem, when present,
# pins the key every build must use (without it, OpenWrt makes a key on the
# first build and keeps using it from $W/keys).
if [ -f "$W/keys/private-key.pem" ]; then
	cp -p "$W/keys/private-key.pem" "$W/keys/public-key.pem" "$SRC/"
elif [ -f "$SRC/private-key.pem" ]; then
	mkdir -p -m 700 "$W/keys" && cp -p "$SRC/private-key.pem" "$SRC/public-key.pem" "$W/keys/"
fi
if [ -f "$PROJ/build/apk-signing-public-key.pem" ] && ! cmp -s "$SRC/public-key.pem" "$PROJ/build/apk-signing-public-key.pem"; then
	log "signing key differs from build/apk-signing-public-key.pem: put the matching private key in $W/keys"
	exit 1
fi

cp "$PROJ/build/config.seed" .config
"${PRE_ENV[@]}" make defconfig
./scripts/diffconfig.sh > "$W/diffconfig.resolved"
for p in wpad-mbedtls travelmate tailscale nikki usbmuxd kmod-usb-net-ipheth ethtool \
         zram-swap kmod-zram kmod-lib-zstd kmod-sched-core kmod-sched-cake kmod-ifb tc-tiny \
         luci-theme-aquamarine; do
  grep -q "^CONFIG_PACKAGE_$p=y" .config || { log "MISSING from .config: $p"; exit 1; }
done
# zstd must be zram's compressor; defconfig silently falls back to lzo-rle otherwise
grep -q "^CONFIG_KERNEL_ZRAM_DEF_COMP_ZSTD=y" .config || { log "zram compressor is not zstd"; exit 1; }
log "config resolved"

# Host tools (util-linux's meson has ncurses=enabled) need ncurses headers, libs
# and a .pc file at compile time, not only at the prerequisite check. Give them
# to the build's own host prefix, staging_dir/host, which OpenWrt already puts on
# every host compile's search path. The system stays untouched; the runtime
# libraries are Ubuntu's own libncurses6/libtinfo6.
SH="$SRC/staging_dir/host"
mkdir -p "$SH/include" "$SH/lib/pkgconfig"
cp -a "$HD/usr/include/." "$SH/include/"
for n in ncurses ncursesw tinfo; do
  ln -sf "/usr/lib/x86_64-linux-gnu/lib$n.so.6" "$SH/lib/lib$n.so.6"
  cp -a "$HD/usr/lib/x86_64-linux-gnu/lib$n.so" "$SH/lib/lib$n.so"   # linker script or symlink
done
for pc in "$HD"/usr/lib/x86_64-linux-gnu/pkgconfig/*.pc; do
  sed -e "s|^prefix=.*|prefix=$SH|" -e "s|^exec_prefix=.*|exec_prefix=$SH|" \
      -e "s|^libdir=.*|libdir=$SH/lib|" -e "s|^includedir=.*|includedir=$SH/include|" \
      "$pc" > "$SH/lib/pkgconfig/$(basename "$pc")"
done
log "ncurses provided to host tools"

make -j"$JOBS" download
log "sources downloaded"
nice -n 19 ionice -c 3 make -j"$JOBS" world
log "BUILD OK"
ls -la bin/targets/mediatek/filogic/*gl-mt3600be*
