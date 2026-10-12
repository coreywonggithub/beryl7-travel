#!/bin/bash
# What on the router differs from the repo (2026-10-06). Run from the mini while it can reach the
# router; read-only on both sides. For each package file: identical, differs (with the known reasons
# a difference is expected), or missing; plus the hand-applied patches and settings that the image's
# first-boot scripts would set. Files changed since the image the router was flashed with (v8 =
# 9cfeebf since 2026-10-12; v7 was d62104a, v6 603a052, v5 1c3441f, v4 ece91a9) are marked: those exist on the router only because they
# were copied there by hand.
#
#   test/router-drift.sh [ref]          ref defaults to HEAD; an older ref shows the drift test failing
set -u
REF="${1:-HEAD}"
IMAGE="${IMAGE:-9cfeebf}"
ROUTER="${ROUTER:-root@172.31.77.1}"
cd "$(dirname "$0")/.." || exit 1

map() {	# repo path -> router path
	case "$1" in
	package/luci-app-travel/root/*) echo "/${1#package/luci-app-travel/root/}" ;;
	package/luci-app-travel/htdocs/*) echo "/www/${1#package/luci-app-travel/htdocs/}" ;;
	package/luci-theme-beryl/root/*) echo "/${1#package/luci-theme-beryl/root/}" ;;
	package/luci-theme-beryl/htdocs/*) echo "/www/${1#package/luci-theme-beryl/htdocs/}" ;;
	package/luci-theme-beryl/ucode/*) echo "/usr/share/ucode/luci/${1#package/luci-theme-beryl/ucode/}" ;;
	esac
}
expected() {	# router path, "since" flag -> why a difference is normal, or nothing
	case "$1" in
	/etc/config/*) echo "live settings" ;;
	/etc/uci-defaults/*) echo "first-boot script: runs once, then removed" ;;
	*.js | *.css)	# the build minifies them; a file copied by hand since the image must match
		[ -z "$2" ] && echo "minified by the image build" ;;
	esac
}
s() { /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=8 "$ROUTER" "$@"; }

changed=" $(git diff --name-only "$IMAGE" "$REF" -- package | tr '\n' ' ') "
list="$(mktemp)"; got="$(mktemp)"
trap 'rm -f "$list" "$got"' EXIT
git ls-tree -r "$REF" -- package/luci-app-travel/root package/luci-app-travel/htdocs \
	package/luci-theme-beryl/root package/luci-theme-beryl/htdocs package/luci-theme-beryl/ucode |
while read -r mode _ _ path; do
	r="$(map "$path")"
	[ -n "$r" ] || continue
	if [ "$mode" = 120000 ]; then echo "LINK $path $r -"; else echo "FILE $path $r $(git show "$REF:$path" | md5 -q)"; fi
done >"$list"
# header.ut: the build stamps "cbi.js?v=<version>" into it, so that stamp is removed before comparing
awk '{ print $3 }' "$list" | s 'while read -r f; do
	if [ -L "$f" ]; then echo "$f LINK"
	elif [ -f "$f" ] && [ "${f##*/}" = header.ut ]; then echo "$f $(sed "s/cbi\.js?v=[^\"]*\"/cbi.js\"/" "$f" | md5sum | cut -d" " -f1)"
	elif [ -f "$f" ]; then echo "$f $(md5sum "$f" | cut -d" " -f1)"
	else echo "$f MISSING"; fi
done' >"$got" || { echo "router not reachable"; exit 2; }

same=0; drift=0
while read -r kind path r sum; do
	have="$(awk -v f="$r" '$1 == f { print $2 }' "$got")"
	since=""; case "$changed" in *" $path "*) since=" [changed since the image]" ;; esac
	why="$(expected "$r" "$since")"
	if { [ "$kind" = LINK ] && [ "$have" = LINK ]; } || [ "$have" = "$sum" ]; then
		same=$((same + 1))
	elif [ -n "$why" ]; then
		echo "differs, expected ($why): $r$since"
	else
		echo "DRIFT ${have/MISSING/missing on router}: $r$since"; drift=$((drift + 1))
	fi
done <"$list"
echo "identical to $REF: $same of $(wc -l <"$list" | tr -d ' '); unexplained: $drift"

echo "--- hand-applied changes the image's first-boot scripts would make"
s 'c() { printf "%-46s %s\n" "$1" "$2"; }
c "96 travelmate ap-force scan (want 1)" "$(grep -c -E "beryl7: ap-force scan|beryl7 hotfix 2026-10-05" /usr/lib/travelmate-functions.sh)"
c "97 upstream https login page fix (want 1)" "$(grep -c -F "elif [ -n \"\${json_cp}\" ] && [ \"\${json_cp}\" != \"\${probe_host}\" ]; then" /usr/lib/travelmate-functions.sh)"
c "image (from /etc/beryl7-image)" "$(sed -n "s/^image=//p" /etc/beryl7-image 2>/dev/null)"
c "98 station held to its band (want 1)" "$(grep -c "beryl7: station held to its band" /usr/share/ucode/wifi/supplicant.uc)"
c "80 trm_netcheck (want 0)" "$(uci -q get travelmate.global.trm_netcheck)"
c "80 rpcd timeout, running (want 60)" "$(ps w | grep "[/]sbin/rpcd" | grep -o "\-t [0-9]*" | cut -c4-)"
c "81 dnsmasq script-on-renewal (want 1)" "$(grep -c -x script-on-renewal /etc/dnsmasq.conf)"
c "94 best-effort MU EDCA on radio0, radio1 (want 3 3)" "$(uci -q get wireless.radio0.he_mu_edca_ac_be_aifsn) $(uci -q get wireless.radio1.he_mu_edca_ac_be_aifsn)"
c "95 system log size in KB (want 10240 or more)" "$(uci -q get system.@system[0].log_size)"
c "30 theme BerylConsole registered" "$(uci -q get luci.themes.BerylConsole)"
c "active theme" "$(uci -q get luci.main.mediaurlbase)"
c "travelmate debug log (normally 0)" "$(uci -q get travelmate.global.trm_debug)"'
[ "$drift" = 0 ]
