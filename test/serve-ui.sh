#!/bin/bash
# Serve the real LuCI (with the travel panel) from a throwaway OpenWrt 25.12
# x86-64 system on the build box, for looking at the panel, and at LuCI's own
# pages, in a browser. Unprivileged; listens on 127.0.0.1:$PORT of the build
# box only. Reach it from the mini with:  ssh -N -L 8088:127.0.0.1:8088 <build box>
# then open http://127.0.0.1:8088/cgi-bin/luci  (user root, password below).
# Say 127.0.0.1, not localhost: a browser keeps one login cookie per host name,
# not per port, so two sandboxes opened as localhost log each other out.
#
#   test/serve-ui.sh start | stop
#
# The sandbox has no netifd, procd, logd or Wi-Fi, which LuCI's status and
# network pages need. stubs/sandbox.uc describes an imaginary router (a Beryl 7
# on a hotel desk: Ethernet and hotel Wi-Fi as uplinks, five devices on your own
# Wi-Fi) and the rpcd stubs, patched tools and fake /sys around it print slices
# of that description, so every page tells the same story. Interfaces, radios
# and SSIDs follow /etc/config/*; addresses, signal and traffic are in the .uc
# file. The first-boot scripts of every installed package run, as on a router.
# Travelmate and nlbwmon come from the packages this build produced (APK and
# PKGDIR, default under ~/beryl7-build/openwrt).
#
# Two checks, once it runs:
#   PORT=8089 test/ui-check.sh                    the ubus calls the pages make
#   node test/ui-pages.js --port 8089 [--shots D]  the pages themselves, in a browser
#
# A second, independent sandbox can run beside the first: every instance has
# its own port, root directory, pid file and log, and stop only ever touches its
# own processes.
#   PORT=8089 ROOT=~/beryl7-build/testbed/uiroot2 test/serve-ui.sh start
#   PORT=8089 ROOT=~/beryl7-build/testbed/uiroot2 test/serve-ui.sh stop
# Overrides (environment): PORT (8088), ROOT ($T/uiroot), PIDFILE and LOGFILE
# (default to $T/ui.pid and $T/ui.log for port 8088, $T/ui-$PORT.* otherwise).
# EXTRA_THEMES: theme package folders to install beside Beryl (Beryl stays active).
# ROOTFS: another x86-64 root filesystem (for example OpenWrt 24.10, to try a theme there),
# usually with NO_EXTRA_PKGS=1: travelmate and nlbwmon come from this 25.12 build.
# Careful: "start" rebuilds ROOT from scratch, and with the defaults that is the
# sandbox on 8088.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$HERE")"
T="${T:-$HOME/beryl7-build/testbed}"
PORT="${PORT:-8088}"
R="$(readlink -m "${ROOT:-$T/uiroot}")"
[ -n "$R" ] && [ "$R" != / ] || { echo "refusing to use '$R' as the sandbox root" >&2; exit 1; }
if [ "$PORT" = 8088 ]; then SFX=""; else SFX="-$PORT"; fi
PIDFILE="${PIDFILE:-$T/ui$SFX.pid}"
LOGFILE="${LOGFILE:-$T/ui$SFX.log}"
TEST_PASSWORD='sandbox-only'	# this sandbox's root login; bound to localhost

stop() {
	local p
	[ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null || true
	rm -f "$PIDFILE"
	# anything a previous sandbox of THIS root left behind: from the host each
	# process shows the chroot it runs in, so a sibling sandbox with another
	# root (and port) is never touched
	for p in /proc/[0-9]*; do
		[ "$(readlink "$p/root" 2>/dev/null)" = "$R" ] && kill "${p#/proc/}" 2>/dev/null || true
	done
	sleep 1
}

# Status > Firewall shows nft's ruleset. The sandbox may not touch the build
# box's netfilter, so let firewall4 generate the ruleset for this router's
# config (inside the sandbox), load it into a throwaway network namespace here
# and keep its JSON for stubs/nft to print. Without nft or nsenter on this
# machine the page just says no ruleset is loaded.
firewall_ruleset() {
	command -v nft >/dev/null 2>&1 && command -v nsenter >/dev/null 2>&1 || return 0
	local p pid="" out="$R/usr/libexec/sandbox/nft.json"
	for p in /proc/[0-9]*; do
		[ "$(readlink "$p/root" 2>/dev/null)" = "$R" ] || continue
		case "$(tr '\0' ' ' <"$p/cmdline" 2>/dev/null)" in /usr/sbin/uhttpd\ *) pid="${p#/proc/}"; break ;; esac
	done
	[ -n "$pid" ] || return 0
	nsenter --preserve-credentials -U -m -p -r -t "$pid" /sbin/fw4 print 2>/dev/null |
		sed "s|include \"/etc/|include \"$R/etc/|g" |
		unshare -Urn sh -c 'nft -f - && nft --terse --json list ruleset' >"$out" 2>/dev/null || rm -f "$out"
}

start() {
	stop
	local rootfs
	rootfs="${ROOTFS:-$(ls "$T"/openwrt-25.12-*-x86-64-rootfs.tar.gz | head -n1)}"
	rm -rf "$R"
	mkdir -p "$R"
	unshare -r tar -xzf "$rootfs" -C "$R" 2>/dev/null || true

	# Travelmate and nlbwmon (with their LuCI apps) are what the router runs
	# beside the travel panel; unpack the packages this build produced. Their
	# files are architecture-independent scripts and LuCI views, except
	# nlbwmon's daemon, which the sandbox never starts (stubs/nlbw answers for it).
	local apk="${APK:-$HOME/beryl7-build/openwrt/staging_dir/host/bin/apk}"
	local pkgdir="${PKGDIR:-$HOME/beryl7-build/openwrt/bin/packages}"
	local pat f
	if [ -n "${NO_EXTRA_PKGS:-}" ]; then
		echo "note: NO_EXTRA_PKGS set; travelmate and nlbwmon are not added" >&2
	elif [ -x "$apk" ]; then
		for pat in 'travelmate-[0-9]*' 'luci-app-travelmate-[0-9]*' 'nlbwmon-[0-9]*' 'luci-app-nlbwmon-[0-9]*' 'luci-lib-chartjs-[0-9]*'; do
			f="$(ls "$pkgdir"/*/*/$pat.apk 2>/dev/null | head -n1)" || true
			if [ -n "$f" ]; then "$apk" extract --allow-untrusted --destination "$R" "$f" >/dev/null 2>&1 || echo "WARNING: could not unpack $f" >&2
			else echo "note: no $pat package under $pkgdir (its LuCI page will be missing)" >&2; fi
		done
	else
		echo "note: $apk not found; travelmate and nlbwmon pages will be missing (set APK and PKGDIR)" >&2
	fi

	cp -a "$PROJ/package/luci-app-travel/root/." "$R/"
	cp -a "$PROJ/package/luci-app-travel/htdocs/." "$R/www/"
	# the Beryl theme, laid out the way luci.mk installs it; its first-boot
	# script makes it the default, as on the router
	cp -a "$PROJ/package/luci-theme-beryl/root/." "$R/"
	cp -a "$PROJ/package/luci-theme-beryl/htdocs/." "$R/www/"
	mkdir -p "$R/usr/share/ucode/luci"
	cp -a "$PROJ/package/luci-theme-beryl/ucode/." "$R/usr/share/ucode/luci/"
	# other theme packages to try beside it (EXTRA_THEMES="dir ...", each laid
	# out like a LuCI package), installed the same way; their first-boot scripts
	# run before Beryl's, so Beryl stays the active theme
	local th
	for th in ${EXTRA_THEMES:-}; do
		cp -a "$th/root/." "$R/"
		cp -a "$th/htdocs/." "$R/www/"
		cp -a "$th/ucode/." "$R/usr/share/ucode/luci/"
	done
	cp "$HERE"/fixtures/config/* "$R/etc/config/"
	install -m 755 "$HERE/stubs/tailscale" "$R/usr/sbin/tailscale"
	install -m 755 "$HERE/stubs/ifstatus" "$R/sbin/ifstatus"
	for c in ifup ifdown wifi; do install -m 755 "$HERE/stubs/logcall" "$R/sbin/$c"; done

	# The imaginary router the LuCI pages describe (see stubs/sandbox.uc): the
	# ubus objects netifd, procd, logd and the Wi-Fi driver would provide, as
	# rpcd plugins, and a few tools that would otherwise show the build box.
	install -d "$R/usr/share/ucode" "$R/usr/libexec/sandbox"
	install -m 644 "$HERE/stubs/sandbox.uc" "$R/usr/share/ucode/sandbox.uc"
	for o in system network.interface network.device network network.wireless luci-rpc iwinfo service log; do
		install -m 755 "$HERE/stubs/rpcd-$o" "$R/usr/libexec/rpcd/$o"
	done
	# rpcd's C plugins "luci-rpc" and "iwinfo" read /sys, netlink and nl80211 of
	# the host; the stubs above are their replacements
	rm -f "$R/usr/lib/rpcd/luci.so" "$R/usr/lib/rpcd/iwinfo.so"
	# rpcd's "luci" plugin (init scripts, timezones, ...) stays; hook the few
	# methods that read /proc, /sys and conntrack of the host
	local lucirpc="$R/usr/share/rpcd/ucode/luci"
	sed -i "0,/^'use strict';/s//'use strict';\nimport { patch_luci } from 'sandbox';/" "$lucirpc"
	sed -i "s/^return { luci: methods };/patch_luci(methods);\nreturn { luci: methods };/" "$lucirpc"
	[ "$(grep -c patch_luci "$lucirpc")" = 2 ] || echo "WARNING: could not hook $lucirpc; the status pages will show the build box" >&2
	rm -f "$R/sbin/ip"
	install -m 755 "$HERE/stubs/ip" "$R/sbin/ip"
	install -m 644 "$HERE/stubs/ip.uc" "$R/usr/libexec/sandbox/ip.uc"
	install -m 755 "$HERE/stubs/nlbw" "$R/usr/sbin/nlbw"
	mv "$R/usr/sbin/nft" "$R/usr/sbin/nft.real"
	install -m 755 "$HERE/stubs/nft" "$R/usr/sbin/nft"
	rm -f "$R/usr/sbin/nlbwmon"	# an aarch64 binary; it would only fail to start
	install -m 644 "$HERE/stubs/ticker.uc" "$R/usr/libexec/sandbox/ticker.uc"
	rm -f "$R/bin/dmesg"
	install -m 755 "$HERE/stubs/dmesg" "$R/bin/dmesg"
	# the Mount Points and LED pages only appear when the tools and the sysfs class exist
	install -m 755 "$HERE/stubs/logcall" "$R/sbin/block"
	mkdir -p "$R/sys/class/leds/white:system" "$R/sys/class/leds/white:wlan"
	install -m 755 "$HERE/fixtures/ui/ui-defaults.sh" "$R/usr/libexec/sandbox/ui-defaults.sh"
	install -m 644 "$HERE/fixtures/board.json" "$R/etc/board.json"
	for s in dnsmasq firewall travelmate tailscale nlbwmon; do
		rm -f "$R/etc/init.d/$s"
		install -m 755 "$HERE/stubs/initd" "$R/etc/init.d/$s"
	done

	# root login for this sandbox only (hash made outside; busybox passwd wants a tty)
	local hash
	hash="$(printf '%s' "$TEST_PASSWORD" | openssl passwd -6 -stdin)"
	sed -i "s|^root:[^:]*:|root:$hash:|" "$R/etc/shadow"

	cat >"$R/serve.sh" <<EOF
#!/bin/sh
mkdir -p /var/run/ubus /var/lock /var/state /tmp/run /var/run/travelmate /tmp/resolv.conf.d
touch /tmp/.sandbox-start
echo 'CST-8' >/tmp/TZ
ucode /usr/libexec/sandbox/ticker.uc &
# first boot, the way a router does it: every uci-defaults script in order (LuCI
# registers its themes there, the travel package shapes the network), then the
# extras that make the sandbox look used
for f in /etc/uci-defaults/*; do ( . "\$f" ) >/dev/null 2>&1; done
( sh /usr/libexec/sandbox/ui-defaults.sh ) >/dev/null 2>&1
# a believable moment: on hotel Wi-Fi, logged in to Tailscale, exit node on
cat >/var/run/travelmate/travelmate.runtime.json <<JSON
{"data":{"travelmate_status":"connected, net ok/78","frontend_ver":"2.4.9","backend_ver":"2.4.9","station_id":"radio1/Hotel_Guest/C8:7F:54:3A:9D:41","station_mac":"94:83:C4:0B:7E:84","station_interfaces":"trm_wwan, -","station_subnet":"10.20.28.0/22","run_flags":"autoadd: ✘, captive: ✔, eviltwin: ✘, mail: ✘, netcheck: ✔, ntp: ✔, proactive: ✘, randomize: ✘, vpn: ✘","last_run":"mode: connected, date / time: \$(date '+%Y-%m-%d %H:%M:%S'), memory: 776 MB available","system_info":"cores: 4, fetch: curl, OpenWrt 25.12-SNAPSHOT r33249-7673104ad5"}}
JSON
cat >/tmp/ts-status.json <<'TS'
{ "BackendState": "Running", "AuthURL": "",
  "Self": { "HostName": "beryl7", "TailscaleIPs": ["100.64.0.2"] },
  "Peer": {
    "k1": { "HostName": "home-nas", "TailscaleIPs": ["100.64.0.11"], "Online": true, "ExitNodeOption": true, "ExitNode": true },
    "k2": { "HostName": "backup-nas", "TailscaleIPs": ["100.64.0.12"], "Online": true, "ExitNodeOption": true, "ExitNode": false },
    "k3": { "HostName": "office-mini", "TailscaleIPs": ["100.64.0.13"], "Online": false, "ExitNodeOption": true, "ExitNode": false } } }
TS
# what dnsmasq learned from the hotel (its lease file is kept up by ticker.uc)
cat >/tmp/resolv.conf.d/resolv.conf.auto <<L
# Interface wan
search hotel.lan
nameserver 192.168.100.1
# Interface trm_wwan
search guest.hotel.lan
nameserver 10.20.28.1
nameserver 8.8.8.8
L
: >/tmp/calls.log
/sbin/ubusd &
sleep 1
/sbin/rpcd &
sleep 1
exec /usr/sbin/uhttpd -f -h /www -r beryl7 -x /cgi-bin -u /ubus -t 60 -T 30 -k 20 -A 1 -n 3 -N 100 -R -p 127.0.0.1:$PORT
EOF
	chmod 755 "$R/serve.sh"

	nohup unshare --user --map-root-user --mount --pid --fork --kill-child bash -c "
		mount -t proc proc '$R/proc'
		mount -t tmpfs tmpfs '$R/tmp'
		# the Overview page reads the connection count from /proc: show the router's, not the build box's
		for n in count:120 max:16384; do
			echo \${n#*:} >'$R/tmp/.nf_conntrack_'\${n%%:*}
			[ -e '$R/proc/sys/net/netfilter/nf_conntrack_'\${n%%:*} ] &&
				mount --bind '$R/tmp/.nf_conntrack_'\${n%%:*} '$R/proc/sys/net/netfilter/nf_conntrack_'\${n%%:*} || true
		done
		for d in null zero urandom random; do touch '$R/dev/'\$d; mount --bind /dev/\$d '$R/dev/'\$d; done
		exec chroot '$R' /bin/sh /serve.sh
	" >"$LOGFILE" 2>&1 &
	echo $! >"$PIDFILE"
	for _ in $(seq 1 20); do
		curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/cgi-bin/luci" 2>/dev/null | grep -q '^\(200\|302\|403\)$' && break
		sleep 1
	done
	firewall_ruleset
	curl -s -o /dev/null -w "LuCI answered HTTP %{http_code} on port $PORT (root $R)\n" "http://127.0.0.1:$PORT/cgi-bin/luci"
}

case "${1:-start}" in
start) start ;;
stop) stop ;;
*) echo "usage: $0 start|stop" >&2; exit 1 ;;
esac
