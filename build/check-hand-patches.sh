#!/bin/bash
# Do the hand patches to other packages' files still fit? (2026-10-06)
# The image changes travelmate, OpenWrt's wifi scripts and tailscale's init script at first boot
# (files/etc/uci-defaults/96, 98 and 95; the register is docs/hand-patches.md). Each one refuses quietly when the code it hooks onto
# has changed, and the router then runs without that fix with nothing to show it. build.sh runs this
# against the exact sources of each build and stops if a patch would not apply. By hand, after
# changing PACKAGES_PIN or OPENWRT_PIN, on the build box:
#   build/check-hand-patches.sh <travelmate-functions.sh> <wifi-scripts supplicant.uc> <tailscale.init>
# Each patch, on a copy: applies once, a second run changes nothing, and the file still parses. Signs
# that upstream has taken a fix over are printed as NOTE: then read the register on dropping that
# patch. A fix we dropped because upstream took it (97, since travelmate 2.4.9-r3) must still be
# there: if upstream loses it, the check fails and the register says how to bring ours back.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
D="$HERE/../files/etc/uci-defaults"
TRM="${1:?usage: check-hand-patches.sh <travelmate-functions.sh> <supplicant.uc> <tailscale.init>}"
SUP="${2:?usage: check-hand-patches.sh <travelmate-functions.sh> <supplicant.uc> <tailscale.init>}"
TSI="${3:?usage: check-hand-patches.sh <travelmate-functions.sh> <supplicant.uc> <tailscale.init>}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
# the scripts report through logger at first boot; here that would land in the build box's journal
mkdir -p "$T/bin" && printf '#!/bin/sh\nexit 0\n' >"$T/bin/logger" && chmod 755 "$T/bin/logger"
export PATH="$T/bin:$PATH"

bad=0
# try <label> <source file> <sh|-> <script:mark>...: the scripts run in order, twice; each mark once
try() {
	local label="$1" src="$2" syn="$3" c="$T/copy" n round pm
	shift 3
	cp "$src" "$c" 2>/dev/null || { echo "MISSING         $src"; bad=1; return; }
	for round in 1 2; do
		for pm in "$@"; do sh "$D/${pm%%:*}" "$c" >/dev/null 2>&1; done
		for pm in "$@"; do
			n="$(grep -c -F -- "${pm#*:}" "$c")"
			if [ "$n" != 1 ]; then
				echo "DOES NOT APPLY  $label: ${pm%%:*} (its mark found $n times after run $round)"
				bad=1
				return
			fi
		done
	done
	if [ "$syn" = sh ] && ! sh -n "$c" 2>/dev/null; then
		echo "BREAKS THE FILE $label: sh -n fails on the result"
		bad=1
		return
	fi
	echo "applies         $label"
}

try "96 (travelmate: scan through the access point)" "$TRM" sh "96_beryl7_travelmate_scan:beryl7: ap-force scan"
# 97 (an https login page after a redirect) is upstream's since 2.4.9-r3 (openwrt/packages e23a399): any
# curl error after a redirect to another host is a login page. That one line in f_net carries it.
if grep -q -F 'elif [ -n "${json_cp}" ] && [ "${json_cp}" != "${probe_host}" ]; then' "$TRM" 2>/dev/null; then
	echo "upstream has    97 (travelmate: https login page)"
else
	echo "UPSTREAM LOST   97 (travelmate: https login page): restore our patch, see docs/hand-patches.md"
	bad=1
fi
try "98 (wifi scripts: station held to its band)" "$SUP" - "98_beryl7_station_band:beryl7: station held to its band"
try "95 (tailscale: a Go memory limit)" "$TSI" sh "95_beryl7_tailscale_memlimit:beryl7: memlimit"

# signs, in the unpatched sources, that upstream has taken a fix over
grep -q -- 'ap-force' "$TRM" 2>/dev/null &&
	echo "NOTE  upstream travelmate scans with ap-force itself: see whether 96 is still needed"
grep -F "'bssid_blacklist'" "$SUP" 2>/dev/null | grep -q -F "'freq_list'" &&
	echo "NOTE  upstream supplicant.uc writes freq_list per network: 98 is probably no longer needed"
grep -q -- 'GOMEMLIMIT' "$TSI" 2>/dev/null &&
	echo "NOTE  upstream's tailscale init script sets GOMEMLIMIT itself: see whether 95 is still needed"
exit "$bad"
