#!/bin/sh
# UI sandbox only (test/serve-ui.sh runs this after the package's own
# first-boot script): the extra state a router that has been used for a while
# would have, so the pages have something to show. The backend tests do not
# use it.

# Taipei time
uci set system.@system[0].zonename='Asia/Taipei'
uci set system.@system[0].timezone='CST-8'
uci commit system

# the hotel Wi-Fi you are on (travelmate enabled it), and two saved for other
# places, the way the panel and travelmate write them
uci set wireless.trm_uplink1=wifi-iface
uci set wireless.trm_uplink1.device='radio1'
uci set wireless.trm_uplink1.mode='sta'
uci set wireless.trm_uplink1.network='trm_wwan'
uci set wireless.trm_uplink1.ssid='Hotel_Guest'
uci set wireless.trm_uplink1.encryption='none'
uci set wireless.trm_uplink2=wifi-iface
uci set wireless.trm_uplink2.device='radio0'
uci set wireless.trm_uplink2.mode='sta'
uci set wireless.trm_uplink2.network='trm_wwan'
uci set wireless.trm_uplink2.ssid='Airport_Free_WiFi'
uci set wireless.trm_uplink2.encryption='none'
uci set wireless.trm_uplink2.disabled='1'
uci set wireless.trm_uplink3=wifi-iface
uci set wireless.trm_uplink3.device='radio1'
uci set wireless.trm_uplink3.mode='sta'
uci set wireless.trm_uplink3.network='trm_wwan'
uci set wireless.trm_uplink3.ssid='Home-WiFi'
uci set wireless.trm_uplink3.encryption='sae-mixed'
uci set wireless.trm_uplink3.key='not-a-real-key'
uci set wireless.trm_uplink3.disabled='1'
uci commit wireless

for spec in radio1:Hotel_Guest radio0:Airport_Free_WiFi radio1:Home-WiFi; do
	n="$(uci add travelmate uplink)"
	uci set "travelmate.$n.enabled=1"
	uci set "travelmate.$n.device=${spec%%:*}"
	uci set "travelmate.$n.ssid=${spec#*:}"
	uci set "travelmate.$n.bssid="
done
uci commit travelmate

# a USB drive in the port, mounted by uuid (stubs/sandbox.uc has the drive)
touch /etc/config/fstab
uci set fstab.global=global
uci set fstab.global.anon_swap='0'
uci set fstab.global.anon_mount='0'
uci set fstab.global.auto_swap='1'
uci set fstab.global.auto_mount='1'
uci set fstab.global.delay_root='5'
uci set fstab.global.check_fs='0'
n="$(uci add fstab mount)"
uci set "fstab.$n.uuid=5a1c7d3e-8f42-4b0e-9c61-2d7e3f9a0b14"
uci set "fstab.$n.target=/mnt/sda1"
uci set "fstab.$n.enabled=1"
uci commit fstab

# the Wi-Fi light follows Wi-Fi traffic
n="$(uci add system led)"
uci set "system.$n.name=WLAN"
uci set "system.$n.sysfs=white:wlan"
uci set "system.$n.trigger=phy0tpt"
uci commit system

# one device pinned to an address
n="$(uci add dhcp host)"
uci set "dhcp.$n.name=MacBook-Air"
uci set "dhcp.$n.mac=4a:8e:27:b1:03:6d"
uci set "dhcp.$n.ip=172.31.77.102"
uci commit dhcp
exit 0
