#!/bin/bash
# Run the backend tests in a throwaway OpenWrt 25.12 x86-64 system on the
# build box. Unprivileged: a user namespace provides a fake root, and a fresh
# network namespace means nothing in the test can touch a real network.
#
#   test/run.sh            (from the project copy on the build box)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(dirname "$HERE")"
T="${T:-$HOME/beryl7-build/testbed}"
ROOTFS="$(ls "$T"/openwrt-25.12-*-x86-64-rootfs.tar.gz | head -n1)"

rm -rf "$T/root"
mkdir -p "$T/root"
unshare -r tar -xzf "$ROOTFS" -C "$T/root" 2>/dev/null || true
R="$T/root"

# the package under test, exactly as it would be installed
cp -a "$PROJ/package/luci-app-travel/root/." "$R/"
cp -a "$PROJ/package/luci-app-travel/htdocs/." "$R/www/"
cp -a "$PROJ/package/luci-theme-beryl/root/." "$R/"
install -m 755 "$PROJ/files/etc/uci-defaults/70_beryl7_zram" "$R/etc/uci-defaults/"
install -m 755 "$PROJ/files/etc/uci-defaults/94_beryl7_mu_edca" "$R/etc/uci-defaults/"
install -m 755 "$PROJ/files/etc/uci-defaults/95_beryl7_log_size" "$R/etc/uci-defaults/"
# a fresh router's config, as first boot would have generated it
cp "$HERE"/fixtures/config/* "$R/etc/config/"
# stand-ins for hardware and daemons the sandbox doesn't have
install -m 755 "$HERE/stubs/tailscale" "$R/usr/sbin/tailscale"
install -m 755 "$HERE/stubs/ifstatus" "$R/sbin/ifstatus"
for c in ifup ifdown wifi; do install -m 755 "$HERE/stubs/logcall" "$R/sbin/$c"; done
# re-adding a phone needs netifd and the device: logged instead (tests: "order: ...")
install -m 755 "$HERE/stubs/logcall" "$R/usr/libexec/travel/tether-metric"
for s in dnsmasq firewall travelmate tailscale nikki; do
	rm -f "$R/etc/init.d/$s"
done
for s in dnsmasq firewall travelmate tailscale; do
	install -m 755 "$HERE/stubs/initd" "$R/etc/init.d/$s"
done
install -m 755 "$HERE/tests.sh" "$R/tests.sh"
# login pages for the form reader (auto.login), as hotels serve them
mkdir -p "$R/portals"
cp "$HERE"/fixtures/portals/*.html "$R/portals/"
# the radios for the Wi-Fi search: iw's interface list and scan list, as the router prints them
install -m 755 "$HERE/stubs/iw" "$R/usr/sbin/iw"
mkdir -p "$R/test-fixtures/iw"
cp "$HERE"/fixtures/iw/*.txt "$R/test-fixtures/iw/"

cat >"$R/inner.sh" <<'EOF'
#!/bin/sh
mkdir -p /var/run/ubus /var/lock /var/state /tmp/run
ip link set lo up 2>/dev/null
/sbin/ubusd &
sleep 1
/sbin/rpcd &
sleep 1
if ! ubus list travel >/dev/null 2>&1; then
	echo "FAIL  rpcd did not load the travel plugin"
	/usr/libexec/rpcd/travel list | jsonfilter -e '@' >/dev/null 2>&1 && echo "  (list output is valid JSON)" || echo "  (list output is NOT valid JSON)"
	/usr/libexec/rpcd/travel list | head -5
	ls -la /usr/libexec/rpcd/
	exit 1
fi
: >/tmp/calls.log
sh /tests.sh
EOF
chmod 755 "$R/inner.sh"

unshare --user --map-root-user --mount --pid --fork --net bash -c "
	mount -t proc proc '$R/proc'
	mount -t tmpfs tmpfs '$R/tmp'
	for d in null zero urandom random; do touch '$R/dev/'\$d; mount --bind /dev/\$d '$R/dev/'\$d; done
	exec chroot '$R' /bin/sh /inner.sh
"
