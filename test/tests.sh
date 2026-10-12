#!/bin/sh
# Backend tests. Runs INSIDE the sandboxed OpenWrt 25.12 x86-64 system that
# test/run.sh prepares (real ubusd, rpcd, uci, ucode, jsonfilter; stand-ins
# for tailscale, radios and services). Prints one line per check.

pass=0
fail=0
check() {	# check "<what>" <command...>
	local what="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		pass=$((pass + 1)); echo "PASS  $what"
	else
		fail=$((fail + 1)); echo "FAIL  $what"
	fi
}
checks() {	# checks "<what>" '<shell condition>' (for && / || conditions)
	local what="$1"
	if eval "$2" >/dev/null 2>&1; then
		pass=$((pass + 1)); echo "PASS  $what"
	else
		fail=$((fail + 1)); echo "FAIL  $what"
	fi
}
call() { ubus call travel "$@" 2>&1; }
jf() { jsonfilter -q -s "$1" -e "$2"; }
calls_has() { grep -qF -- "$1" /tmp/calls.log; }
reset_calls() { : >/tmp/calls.log; }

# ---------------------------------------------------------------- boot-like setup
( . /etc/uci-defaults/80_travel )
check "first boot: LAN moved to 172.31.77.1/24" [ "$(uci -q get network.lan.ipaddr)" = "172.31.77.1/24" ]
check "first boot: no IPv6 to devices" [ "$(uci -q get dhcp.lan.ra)" = disabled ]
check "first boot: trm_wwan exists with metric 20" [ "$(uci -q get network.trm_wwan.metric)" = 20 ]
check "first boot: wan metric 10" [ "$(uci -q get network.wan.metric)" = 10 ]
check "first boot: travelmate enabled on trm_wwan" [ "$(uci -q get travelmate.global.trm_iface)" = trm_wwan ]
check "first boot: travelmate does no background scans" [ "$(uci -q get travelmate.global.trm_proactive)" = 0 ]
check "first boot: travelmate waits 30 s before it starts" [ "$(uci -q get travelmate.global.trm_triggerdelay)" = 30 ]
( . /etc/uci-defaults/70_beryl7_zram )
check "first boot: zram swap compresses with zstd" [ "$(uci -q get system.@system[0].zram_comp_algo)" = zstd ]
( . /etc/uci-defaults/94_beryl7_mu_edca )
( . /etc/uci-defaults/95_beryl7_log_size )
check "first boot: a 10 MB system log" [ "$(uci -q get system.@system[0].log_size)" = 10240 ]
uci set system.@system[0].log_size=20480; uci commit system
( . /etc/uci-defaults/95_beryl7_log_size )
check "first boot: a bigger log someone chose is kept" [ "$(uci -q get system.@system[0].log_size)" = 20480 ]
uci set system.@system[0].log_size=10240; uci commit system
checks "first boot: every radio gets the normal best-effort MU EDCA values" '[ "$(uci show wireless | grep -c "he_mu_edca_ac_be_aifsn=.3.")" = "$(uci show wireless | grep -c "=wifi-device")" ] && [ "$(uci show wireless | grep -c "=wifi-device")" -ge 2 ] && [ "$(uci -q get wireless.radio1.he_mu_edca_ac_be_ecwmin)" = 4 ] && [ "$(uci -q get wireless.radio1.he_mu_edca_ac_be_ecwmax)" = 10 ]'
z1="$(uci show firewall | grep -c "\.name='tailscale'")"
z2="$(uci show firewall | grep -c "\.name='vpn'")"
f1="$(uci show firewall | grep -c "=forwarding")"
( . /etc/uci-defaults/80_travel )
checks "first boot twice: still one tailscale zone" '[ "$z1" = 1 ] && [ "$(uci show firewall | grep -c "name=.tailscale.")" = 1 ]'
checks "first boot twice: still one vpn zone" '[ "$z2" = 1 ] && [ "$(uci show firewall | grep -c "name=.vpn.")" = 1 ]'
check "first boot twice: no duplicate forwardings" [ "$f1" = "$(uci show firewall | grep -c "=forwarding")" ]
check "first boot: trm_wwan in the wan zone once" [ "$(uci show firewall | grep -o "trm_wwan" | wc -l)" = 1 ]

# ---------------------------------------------------------------- status
s="$(call status)"
check "status: valid JSON with a mode" [ -n "$(jf "$s" '@.mode.desired')" ]
check "status: three uplinks" [ "$(jf "$s" '@.uplinks[*].name' | wc -l)" = 3 ]
check "status: Wi-Fi name read" [ "$(jf "$s" '@.wifi.ssid')" = Beryl7 ]
check "status: two radios" [ "$(jf "$s" '@.wifi.radios[*].band' | wc -l)" = 2 ]
check "status: tailscale state reported" [ "$(jf "$s" '@.tailscale.state')" = NeedsLogin ]
check "status: nikki reported absent" [ "$(jf "$s" '@.nikki.installed')" = false ]

# ---------------------------------------------------------------- exit node, not logged in
reset_calls
r="$(call set_mode '{"mode":"exitnode","exit_node":"100.64.0.11"}')"
check "exit node while logged out: refused with a reason" [ "$(jf "$r" '@.error')" = "Tailscale isn't logged in." ]
check "exit node while logged out: still direct" [ "$(cat /var/run/travel/active)" = direct ]
check "exit node while logged out: desire kept for later" [ "$(uci -q get travel.main.mode)" = exitnode ]

# ---------------------------------------------------------------- exit node, logged in
cat >/tmp/ts-status.json <<'EOF'
{ "BackendState": "Running", "AuthURL": "",
  "Self": { "HostName": "beryl7", "TailscaleIPs": ["100.64.0.2", "fd7a::2"] },
  "Peer": {
    "k1": { "HostName": "Office_NAS", "DNSName": "office-nas.tail.ts.net.", "TailscaleIPs": ["100.64.0.11"], "Online": true, "ExitNodeOption": true, "ExitNode": false },
    "k2": { "HostName": "Backup-NAS", "DNSName": "backup-nas.tail.ts.net.", "TailscaleIPs": ["100.64.0.12"], "Online": false, "ExitNodeOption": true, "ExitNode": false },
    "k4": { "HostName": "apple-tv", "DNSName": "appletv2.tail.ts.net.", "TailscaleIPs": ["100.64.0.15"], "Online": true, "ExitNodeOption": true, "ExitNode": false },
    "k5": { "HostName": "apple-tv", "DNSName": "appletv3.tail.ts.net.", "TailscaleIPs": ["100.64.0.14"], "Online": true, "ExitNodeOption": true, "ExitNode": false },
    "k3": { "HostName": "server1", "DNSName": "server1.tail.ts.net.", "TailscaleIPs": ["100.64.0.16"], "Online": true, "ExitNodeOption": false }
  } }
EOF
# exit node names, as a router's own config gives them (the package ships none)
uci -q delete travel.main.label
for l in 'office-nas=Office' 'backup-nas=Home: NAS' 'appletv3=Home: Study Apple TV' 'appletv2=Home: Living room Apple TV'; do
	uci add_list "travel.main.label=$l"
done
uci commit travel
cp /etc/config/dhcp /tmp/dhcp.before
reset_calls
r="$(call set_mode '{"mode":"exitnode","exit_node":"100.64.0.11"}')"
check "exit node: accepted" [ "$(jf "$r" '@.ok')" = true ]
check "exit node: tailscale told to use it, LAN access kept" calls_has "tailscale set --exit-node=100.64.0.11 --exit-node-allow-lan-access=true"
check "exit node: running" [ "$(cat /var/run/travel/active)" = exitnode ]
check "exit node: lookups go through the tunnel" [ "$(uci -q get dhcp.@dnsmasq[0].noresolv)" = 1 ]
check "exit node: tunnel resolvers set" sh -c "uci -q get dhcp.@dnsmasq[0].server | grep -q '1.1.1.1'"
s="$(call status)"
# peers named the way a real tailnet names them: a host name with its own spelling and a MagicDNS
# short name; the labels are keyed by either (two Apple TVs share the host name 'apple-tv').
check "status: exit nodes listed with labels" [ "$(jf "$s" "@.tailscale.exit_nodes[@.name='Office_NAS'].label")" = "Office" ]
checks "status: two Apple TVs, both 'apple-tv', each with its own label" '[ "$(jf "$s" "@.tailscale.exit_nodes[@.ip=\"100.64.0.14\"].label")" = "Home: Study Apple TV" ] && [ "$(jf "$s" "@.tailscale.exit_nodes[@.ip=\"100.64.0.15\"].label")" = "Home: Living room Apple TV" ]'
check "status: non exit nodes not listed" [ -z "$(jf "$s" "@.tailscale.exit_nodes[@.name='server1'].name")" ]
check "status: offline exit node marked" [ "$(jf "$s" "@.tailscale.exit_nodes[@.name='Backup-NAS'].online")" = false ]

r="$(call set_mode '{"mode":"exitnode","exit_node":"100.64.0.12"}')"
check "offline exit node: refused" [ "$(jf "$r" '@.error')" = "That exit node is offline." ]
check "offline exit node: back to direct, exit node cleared" calls_has "tailscale set --exit-node="

reset_calls
r="$(call set_mode '{"mode":"direct"}')"
check "direct: accepted" [ "$(jf "$r" '@.ok')" = true ]
check "direct: exit node cleared" calls_has "tailscale set --exit-node="
check "direct: your DNS settings restored exactly" cmp -s /tmp/dhcp.before /etc/config/dhcp

# ---------------------------------------------------------------- hotel login page
uci set travel.main.mode=exitnode; uci set travel.main.exit_node=100.64.0.11; uci commit travel
/usr/libexec/travel/egress apply
mkdir -p /var/run/travelmate
echo '{"data":{"travelmate_status":"connected, net cp '"'"'wifi.hotel.de'"'"'/80","station_id":"radio1/Hotel_Guest/-"}}' \
	>/var/run/travelmate/travelmate.runtime.json
/usr/libexec/travel/watch &
wpid=$!
sleep 5
check "login page: tunnel paused" [ "$(cat /var/run/travel/active)" = direct ]
check "login page: host remembered" grep -q wifi.hotel.de /var/run/travel/portal
s="$(call status)"
check "status: login page reported" [ "$(jf "$s" '@.portal.state')" = detected ]
check "status: hold shown" [ "$(jf "$s" '@.mode.hold')" = portal ]
echo '{"data":{"travelmate_status":"connected, net ok/80","station_id":"radio1/Hotel_Guest/-"}}' \
	>/var/run/travelmate/travelmate.runtime.json
sleep 5
check "after login: tunnel resumed" [ "$(cat /var/run/travel/active)" = exitnode ]
check "after login: hold cleared" [ ! -e /var/run/travel/portal ]
kill "$wpid" 2>/dev/null

# ---------------------------------------------------------------- mode switch
uci set travel.main.switch_on=exitnode; uci set travel.main.switch_off=direct; uci commit travel
/usr/libexec/travel/switch released
checks "switch down: direct" '[ "$(uci -q get travel.main.mode)" = direct ] && [ "$(cat /var/run/travel/active)" = direct ]'
/usr/libexec/travel/switch pressed
checks "switch up: exit node" '[ "$(uci -q get travel.main.mode)" = exitnode ] && [ "$(cat /var/run/travel/active)" = exitnode ]'
r="$(call set_switch_map '{"on":"direct","off":"banana"}')"
check "switch map: rejects unknown modes" [ "$(jf "$r" '@.ok')" = false ]

# ---------------------------------------------------------------- UniFi WireGuard profile
conf='[Interface]
PrivateKey = cHJpdmF0ZWtleXByaXZhdGVrZXlwcml2YXRla2V5MTI=
Address = 192.168.5.2/32
DNS = 192.168.5.1

[Peer]
PublicKey = cHVibGlja2V5cHVibGlja2V5cHVibGlja2V5cHViMTI=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = office.example.com:51820'
r="$(ubus call travel wg_import "$(printf '{"label":"Office","conf":%s}' "$(printf '%s' "$conf" | ucode -e 'import {stdin} from "fs"; printf("%J", stdin.read("all"))')")")"
check "wireguard import: accepted" [ "$(jf "$r" '@.ok')" = true ]
wg="$(jf "$r" '@.name')"
check "wireguard import: interface created" [ "$(uci -q get "network.$wg.proto")" = wireguard ]
check "wireguard import: does not start by itself" [ "$(uci -q get "network.$wg.auto")" = 0 ]
checks "wireguard import: peer endpoint split" '[ "$(uci -q get "network.${wg}_peer.endpoint_host")" = office.example.com ] && [ "$(uci -q get "network.${wg}_peer.endpoint_port")" = 51820 ]'
check "wireguard import: both allowed ranges kept" [ "$(uci -q get "network.${wg}_peer.allowed_ips")" = "0.0.0.0/0 ::/0" ]
check "wireguard import: keepalive defaulted" [ "$(uci -q get "network.${wg}_peer.persistent_keepalive")" = 25 ]
check "wireguard import: in the vpn zone" sh -c "uci show firewall | grep -q \"network='$wg'\""
bad="$(call wg_import '{"label":"x","conf":"[Interface]\nPrivateKey = nope\n"}')"
check "wireguard import: rejects a damaged file" [ "$(jf "$bad" '@.ok')" = false ]
reset_calls
r="$(call set_mode "{\"mode\":\"wireguard\",\"wg\":\"$wg\"}")"
check "wireguard: exit node cleared first" calls_has "tailscale set --exit-node="
check "wireguard: tunnel brought up" calls_has "ifup $wg"
check "wireguard: lookups use the profile's DNS" sh -c "uci -q get dhcp.@dnsmasq[0].server | grep -q '192.168.5.1'"
s="$(call status)"
check "status: profile listed" [ "$(jf "$s" "@.wireguard[@.name='$wg'].label")" = "Office" ]
r="$(call wg_delete "{\"name\":\"$wg\"}")"
checks "wireguard delete: gone" '[ -z "$(uci -q get "network.$wg")" ] && [ -z "$(uci -q get "network.${wg}_peer")" ]'
check "wireguard delete: mode falls back to direct" [ "$(uci -q get travel.main.mode)" = direct ]

# ---------------------------------------------------------------- Choose Wi-Fi
r="$(call wifi_join '{"ssid":"Airbnb_Ehrenfeld","band":"5g","security":"psk","key":"short"}')"
check "join: short password refused" [ "$(jf "$r" '@.ok')" = false ]
r="$(call wifi_join '{"ssid":"Airbnb_Ehrenfeld","band":"5g","security":"sae-mixed","key":"hunter-koeln-2026"}')"
check "join: saved" [ "$(jf "$r" '@.ok')" = true ]
checks "join: station on the 5 GHz radio, travelmate style" '[ "$(uci -q get wireless.trm_uplink1.device)" = radio1 ] && [ "$(uci -q get wireless.trm_uplink1.network)" = trm_wwan ]'
check "join: travelmate uplink entry" sh -c "uci show travelmate | grep -q \"ssid='Airbnb_Ehrenfeld'\""
r="$(call wifi_join '{"ssid":"Airbnb_Ehrenfeld","band":"5g","security":"sae-mixed","key":"another-password"}')"
checks "join again: updates, no duplicate" '[ "$(uci show wireless | grep -c "ssid=.Airbnb_Ehrenfeld.")" = 1 ] && [ "$(uci show travelmate | grep -c "ssid=.Airbnb_Ehrenfeld.")" = 1 ]'
r="$(call wifi_saved)"
check "saved list shows it" [ "$(jf "$r" "@.networks[@.ssid='Airbnb_Ehrenfeld'].band")" = 5g ]

# switching (2026-10-06): the chosen network first and on, the others off, one reload,
# travelmate paused around it; a saved network joined with no password keeps its own
reset_calls
r="$(call wifi_join '{"ssid":"Cafe_Two","band":"2g","security":"open"}')"
sleep 1
check "switch: joined" [ "$(jf "$r" '@.ok')" = true ]
cafe="$(uci show wireless | sed -n "s/^wireless\.\([^.]*\)\.ssid='Cafe_Two'$/\1/p")"
checks "switch: chosen station on, the other off" '[ "$(uci -q get wireless.$cafe.disabled)" = 0 ] && [ "$(uci -q get wireless.trm_uplink1.disabled)" = 1 ]'
checks "switch: chosen station first in the Wi-Fi config" '[ "$(uci show wireless | sed -n "s/^wireless\.\([^.]*\)\.mode=.sta.$/\1/p" | head -n1)" = "$cafe" ]'
check "switch: its radio first for travelmate (2.4 GHz)" [ "$(uci -q get travelmate.global.trm_revradio)" = 0 ]
checks "switch: travelmate stopped, Wi-Fi reloaded once, travelmate started" 'calls_has "travelmate stop" && [ "$(grep -c "^wifi reload" /tmp/calls.log)" = 1 ] && calls_has "travelmate start"'
r="$(call wifi_join '{"ssid":"Airbnb_Ehrenfeld","band":"5g"}')"
check "Connect, no password: accepted" [ "$(jf "$r" '@.ok')" = true ]
check "Connect, no password: the saved one kept" [ "$(uci -q get wireless.trm_uplink1.key)" = another-password ]
check "Connect: its radio first now (5 GHz)" [ "$(uci -q get travelmate.global.trm_revradio)" = 1 ]
r="$(call wifi_join '{"ssid":"Airbnb_Ehrenfeld","band":"5g","security":"psk"}')"
check "Connect, no password, security changed: refused" [ "$(jf "$r" '@.ok')" = false ]
check "Connect refused: nothing changed" [ "$(uci -q get wireless.trm_uplink1.encryption)" = sae-mixed ]
r="$(call wifi_join '{"ssid":"Never_Saved","band":"5g","security":"psk"}')"
check "a new network with no password: refused" [ "$(jf "$r" '@.ok')" = false ]

# automatic login at a login page (2026-10-06)
r="$(call login_set '{"ssid":"Nowhere","method":"unifi-password","code":"abc"}')"
check "login: an unsaved network refused" [ "$(jf "$r" '@.ok')" = false ]
r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"magic","code":"abc"}')"
check "login: an unknown method refused" [ "$(jf "$r" '@.ok')" = false ]
r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"unifi-password","code":""}')"
check "login: an empty code refused" [ "$(jf "$r" '@.ok')" = false ]
r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"unifi-password","code":"ab\"c"}')"
check "login: a quote in the code refused" [ "$(jf "$r" '@.ok')" = false ]
check "login: nothing set by the refusals" [ -z "$(uci -q get travelmate.$(uci show travelmate | sed -n "s/^travelmate\.\([^.]*\)\.ssid='Airbnb_Ehrenfeld'$/\1/p").script)" ]
r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"unifi-password","code":"huang zicong"}')"
check "login: set" [ "$(jf "$r" '@.ok')" = true ]
ab="$(uci show travelmate | sed -n "s/^travelmate\.\([^.]*\)\.ssid='Airbnb_Ehrenfeld'$/\1/p")"
checks "login: travelmate runs the UniFi script with the code" '[ "$(uci -q get travelmate.$ab.script)" = /etc/travelmate/unifi-password.login ] && [ "$(uci -q get travelmate.$ab.script_args)" = "huang zicong" ]'
r="$(call login_get '{"ssid":"Airbnb_Ehrenfeld"}')"
checks "login: read back, method and code" '[ "$(jf "$r" @.method)" = unifi-password ] && [ "$(jf "$r" @.code)" = "huang zicong" ]'
echo '{"data":{"travelmate_status":"connected, net cp '"'"'192.0.2.1:8444'"'"'/80","station_id":"radio1/Airbnb_Ehrenfeld/-"}}' >/var/run/travelmate/travelmate.runtime.json
echo '{"method":"unifi-password","ssid":"Airbnb_Ehrenfeld","result":"wrong-code","at":1791000000}' >/var/run/travel/autologin.json
s="$(call status)"
check "login: status names the method for this network" [ "$(jf "$s" '@.portal.autologin.method')" = unifi-password ]
check "login: status shows how the last try went" [ "$(jf "$s" '@.portal.autologin.last.result')" = wrong-code ]
checks "login: status never carries the code" '! printf "%s" "$s" | grep -q "huang zicong"'
echo '{"method":"unifi-password","ssid":"Other_Net","result":"ok","at":1791000000}' >/var/run/travel/autologin.json
s="$(call status)"
check "login: another network's last try not shown" [ -z "$(jf "$s" '@.portal.autologin.last.result')" ]
echo '{"method":"click-through","ssid":"Airbnb_Ehrenfeld","result":"failed","at":1791000000}' >/var/run/travel/autologin.json
s="$(call status)"
check "login: another method's last try not shown" [ -z "$(jf "$s" '@.portal.autologin.last.result')" ]
checks "login: reading codes needs the write permission" '! jsonfilter -i /usr/share/rpcd/acl.d/luci-app-travel.json -e "@[\"luci-app-travel\"].read.ubus.travel[*]" | grep -q login && jsonfilter -i /usr/share/rpcd/acl.d/luci-app-travel.json -e "@[\"luci-app-travel\"].write.ubus.travel[*]" | grep -q login_get'
r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"click-through","code":"ignored"}')"
check "login: an \"I accept\" page needs no code" [ "$(jf "$r" '@.ok')" = true ]
checks "login: \"I accept\" runs its script, and no code is kept" '[ "$(uci -q get travelmate.$ab.script)" = /etc/travelmate/click-through.login ] && [ -z "$(uci -q get travelmate.$ab.script_args)" ]'
r="$(call login_get '{"ssid":"Airbnb_Ehrenfeld"}')"
check "login: read back as click-through" [ "$(jf "$r" @.method)" = click-through ]
r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"unifi-user","code":"secret 1"}')"
check "login: username + code without a username refused" [ "$(jf "$r" '@.ok')" = false ]
r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"unifi-user","user":"Room 1203","code":"secret 1"}')"
check "login: a username with a space refused" [ "$(jf "$r" '@.ok')" = false ]
r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"unifi-user","user":"1203","code":""}')"
check "login: username + code without a code refused" [ "$(jf "$r" '@.ok')" = false ]
r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"unifi-user","user":"1203","code":"wong family"}')"
check "login: username + code set" [ "$(jf "$r" '@.ok')" = true ]
checks "login: travelmate runs the username script with both" '[ "$(uci -q get travelmate.$ab.script)" = /etc/travelmate/unifi-user.login ] && [ "$(uci -q get travelmate.$ab.script_args)" = "1203 wong family" ]'
r="$(call login_get '{"ssid":"Airbnb_Ehrenfeld"}')"
checks "login: read back as username and code" '[ "$(jf "$r" @.method)" = unifi-user ] && [ "$(jf "$r" @.user)" = 1203 ] && [ "$(jf "$r" @.code)" = "wong family" ]'
r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"auto","user":"","code":""}')"
checks "login: Automatic with nothing saved (an \"I accept\" page)" '[ "$(jf "$r" @.ok)" = true ] && [ "$(uci -q get travelmate.$ab.script)" = /etc/travelmate/auto.login ] && [ "$(uci -q get travelmate.$ab.script_args)" = "-" ]'
r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"auto","user":"","code":"hotel 88"}')"
check "login: Automatic with a code only" [ "$(uci -q get travelmate.$ab.script_args)" = "- hotel 88" ]
r="$(call login_get '{"ssid":"Airbnb_Ehrenfeld"}')"
checks "login: read back, no username, the code" '[ "$(jf "$r" @.method)" = auto ] && [ -z "$(jf "$r" @.user)" ] && [ "$(jf "$r" @.code)" = "hotel 88" ]'
r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"auto","user":"1203","code":"wong family"}')"
r="$(call login_get '{"ssid":"Airbnb_Ehrenfeld"}')"
checks "login: Automatic with a username and code, read back" '[ "$(jf "$r" @.user)" = 1203 ] && [ "$(jf "$r" @.code)" = "wong family" ]'
r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"auto","user":"1203","code":""}')"
r="$(call login_get '{"ssid":"Airbnb_Ehrenfeld"}')"
checks "login: Automatic with a username only, read back with no code" '[ "$(uci -q get travelmate.$ab.script_args)" = 1203 ] && [ "$(jf "$r" @.user)" = 1203 ] && [ -z "$(jf "$r" @.code)" ]'
r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"auto","user":"-","code":"x"}')"
check "login: a username of \"-\" refused (it means none)" [ "$(jf "$r" '@.ok')" = false ]
r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"auto","user":"Room 12","code":"x"}')"
check "login: Automatic, a username with a space refused" [ "$(jf "$r" '@.ok')" = false ]
s="$(call status)"
check "login: the status names Automatic" [ "$(jf "$s" '@.portal.autologin.method')" = auto ]

# the form reader on login pages as hotels serve them (BusyBox awk, as on the router)
SEP="$(printf '\037')"
f="$(awk -f /usr/libexec/travel/form.awk /portals/tos.html)"
check "form: a terms page's form and where it goes" [ "$(printf '%s\n' "$f" | head -n1)" = "FORM${SEP}post${SEP}/accept?x=1&y=2" ]
check "form: an empty value keeps its place (the required terms box)" [ "$(printf '%s\n' "$f" | grep accept_terms)" = "F${SEP}checkbox${SEP}accept_terms${SEP}${SEP}r" ]
f="$(awk -f /usr/libexec/travel/form.awk /portals/userpass.html)"
checks "form: username page, password field and chosen language" 'printf "%s\n" "$f" | grep -q "^F${SEP}password${SEP}password${SEP}${SEP}r$" && printf "%s\n" "$f" | grep -q "^F${SEP}select${SEP}lang${SEP}zh"'
f="$(awk -f /usr/libexec/travel/form.awk /portals/roomname.html)"
check "form: an unnamed button keeps an empty name" sh -c "printf '%s\n' \"\$1\" | grep -q '^F${SEP}submit${SEP}${SEP}Go'" _ "$f"
check "form: a page built by script has no form" [ -z "$(awk -f /usr/libexec/travel/form.awk /portals/spa.html)" ]

r="$(call login_set '{"ssid":"Airbnb_Ehrenfeld","method":"none","code":""}')"
check "login: off removes the script and the code" [ -z "$(uci -q get travelmate.$ab.script)$(uci -q get travelmate.$ab.script_args)" ]
rm -f /var/run/travel/autologin.json /var/run/travelmate/travelmate.runtime.json
call wifi_forget '{"ssid":"Cafe_Two"}' >/dev/null

r="$(call wifi_forget '{"ssid":"Airbnb_Ehrenfeld"}')"
check "forget: removed everywhere" [ "$(uci show wireless travelmate 2>/dev/null | grep -c Airbnb_Ehrenfeld)" = 0 ]

# ---------------------------------------------------------------- devices, MAC, your Wi-Fi
r="$(call device_block '{"mac":"AA:BB:CC:DD:EE:01","blocked":true}')"
check "block: firewall rule added" [ "$(uci -q get firewall.travel_block_aabbccddee01.target)" = REJECT ]
r="$(call device_block '{"mac":"AA:BB:CC:DD:EE:01","blocked":false}')"
check "unblock: rule removed" [ -z "$(uci -q get firewall.travel_block_aabbccddee01)" ]
r="$(call device_rename '{"mac":"aa:bb:cc:dd:ee:01","name":"Alex iPhone"}')"
check "rename: stored as a DNS-safe name" sh -c "uci show dhcp | grep -q \"name='Alex-iPhone'\""
r="$(call device_kind '{"mac":"AA:BB:CC:DD:EE:01","kind":"tablet"}')"
check "type: stored for the device, MAC in lower case" [ "$(uci -q get travel.@device[0].mac)/$(uci -q get travel.@device[0].kind)" = aa:bb:cc:dd:ee:01/tablet ]
r="$(call device_kind '{"mac":"aa:bb:cc:dd:ee:01","kind":"laptop"}')"
check "type: changed in place, not added twice" [ "$(uci show travel | grep -c '=device$')/$(uci -q get travel.@device[0].kind)" = 1/laptop ]
s="$(call status)"
checks "type: status carries it" '[ "$(jf "$s" "@.devices[@.mac=\"aa:bb:cc:dd:ee:01\"].kind")" = laptop ]'
r="$(call device_kind '{"mac":"aa:bb:cc:dd:ee:01","kind":"toaster"}')"
checks "type: unknown kind refused" '[ "$(jf "$r" @.ok)" = false ] && [ "$(uci -q get travel.@device[0].kind)" = laptop ]'
r="$(call device_kind '{"mac":"02:00:00:00:00:99","kind":"phone"}')"
s="$(call status)"
checks "type: a stored type never adds a device" '[ -z "$(jf "$s" "@.devices[@.mac=\"02:00:00:00:00:99\"].mac")" ]'
call device_kind '{"mac":"02:00:00:00:00:99","kind":""}' >/dev/null
r="$(call device_kind '{"mac":"aa:bb:cc:dd:ee:01","kind":""}')"
check "type: empty goes back to the guess" [ "$(uci show travel | grep -c '=device$')" = 0 ]
checks "type: needs the write permission" 'jsonfilter -i /usr/share/rpcd/acl.d/luci-app-travel.json -e "@[\"luci-app-travel\"].write.ubus.travel[*]" | grep -qx device_kind && ! jsonfilter -i /usr/share/rpcd/acl.d/luci-app-travel.json -e "@[\"luci-app-travel\"].read.ubus.travel[*]" | grep -qx device_kind'

# how a device asks for its address (dnsmasq's DHCP hook -> hotplug.d/dhcp)
fp() { env -i PATH="$PATH" ACTION="$1" MACADDR="$2" DNSMASQ_VENDOR_CLASS="$3" DNSMASQ_REQUESTED_OPTIONS="$4" sh /etc/hotplug.d/dhcp/50-travel-fingerprint; }
fpos() { jf "$(call status)" '@.devices[@.mac="aa:bb:cc:dd:ee:01"].os'; }
rm -rf /var/run/travel/fp
fp add AA:BB:CC:DD:EE:01 android-dhcp-14 1,3,6,15,26,28,51,58,59,43,114,108
checks "fingerprint: Android, with its version" '[ "$(fpos)" = android ] && [ "$(jf "$(call status)" "@.devices[@.mac=\"aa:bb:cc:dd:ee:01\"].os_ver")" = 14 ]'
fp update AA:BB:CC:DD:EE:01 "" 1,121,3,6,15,108,114,119,252,95,44,46
check "fingerprint: a Mac" [ "$(fpos)" = macos ]
fp update AA:BB:CC:DD:EE:01 "" 1,121,3,6,15,108,114,119,252
check "fingerprint: an iPhone or iPad" [ "$(fpos)" = ios ]
fp update AA:BB:CC:DD:EE:01 "MSFT 5.0" 1,3,6,15,31,33,43,44,46,47,119,121,249,252
check "fingerprint: Windows" [ "$(fpos)" = windows ]
fp update AA:BB:CC:DD:EE:01 "udhcp 1.36.1" 1,3,6,12,15,28,42
check "fingerprint: a BusyBox gadget is Linux" [ "$(fpos)" = linux ]
fp update AA:BB:CC:DD:EE:01 "" ""
check "fingerprint: a renewal that says nothing keeps the last" [ "$(fpos)" = linux ]
fp remove AA:BB:CC:DD:EE:01 android-dhcp-9 1,3
check "fingerprint: a lease removal changes nothing" [ "$(fpos)" = linux ]
fp add 02:00:00:00:00:77 android-dhcp-14 1,3,6
s="$(call status)"
checks "fingerprint: never adds a device" '[ -z "$(jf "$s" "@.devices[@.mac=\"02:00:00:00:00:77\"].mac")" ]'
fp add 'aa:bb;rm -rf /' android-dhcp-14 1,3
check "fingerprint: a malformed MAC writes nothing" [ "$(ls /var/run/travel/fp | wc -l)" = 2 ]
fp add AA:BB:CC:DD:EE:01 "$(printf 'android-dhcp-14\001x')" '1,3;reboot'
checks "fingerprint: control characters and junk dropped" '[ "$(sed -n "s/^vendor=//p" /var/run/travel/fp/aabbccddee01)" = android-dhcp-14x ] && grep -qx "opts=1,3" /var/run/travel/fp/aabbccddee01'
sh /etc/uci-defaults/81_travel_fingerprint; sh /etc/uci-defaults/81_travel_fingerprint
check "fingerprint: dnsmasq asked for renewals, once" [ "$(grep -cx script-on-renewal /etc/dnsmasq.conf)" = 1 ]
rm -rf /var/run/travel/fp
rm -f /var/run/travelmate/travelmate.runtime.json
r="$(call mac '{"target":"wifi","action":"random"}')"
checks "MAC for Wi-Fi, not connected: explained" '[ "$(jf "$r" @.error)" = "Connect to a Wi-Fi network first." ]'
echo '{"data":{"travelmate_status":"connected, net ok/80","station_id":"radio1/Unsaved_Net/-"}}' >/var/run/travelmate/travelmate.runtime.json
r="$(call mac '{"target":"wifi","action":"random"}')"
checks "MAC for Wi-Fi, network not saved: explained" '[ "$(jf "$r" @.error)" = "That Wi-Fi isn'"'"'t saved yet." ]'
call wifi_join '{"ssid":"Hotel_Guest","band":"5g","security":"open"}' >/dev/null
echo '{"data":{"travelmate_status":"connected, net ok/80","station_id":"radio1/Hotel_Guest/-"}}' >/var/run/travelmate/travelmate.runtime.json
r="$(call mac '{"target":"wifi","action":"set","mac":"02:11:22:33:44:55"}')"
checks "MAC clone for the hotel Wi-Fi: stored on that uplink" '[ "$(uci show travelmate | sed -n "s/.*macaddr=.\(.*\)./\1/p")" = "02:11:22:33:44:55" ]'
# and put on the station at once, with that radio reconnected (2026-10-08: the panel said "Now using" an
# address travelmate would only use at the next connect); in the background, so wait for the call
n=0; while ! calls_has "wifi reload" && [ $n -lt 10 ]; do sleep 1; n=$((n + 1)); done
sta="$(uci -q show wireless | sed -n "s/^wireless\.\([^.=]*\)\.ssid='Hotel_Guest'$/\1/p" | head -n1)"
checks "MAC for the hotel Wi-Fi: on its station now, the radio reconnected" '[ "$(uci -q get wireless.$sta.macaddr)" = 02:11:22:33:44:55 ] && calls_has "wifi reload $(uci -q get wireless.$sta.device)"'
r="$(call mac '{"target":"wifi","action":"set","mac":"not-a-mac"}')"
checks "MAC clone: nonsense refused" '[ "$(jf "$r" @.ok)" = false ]'
# one change at a time (2026-10-12: two at once ran two travelmate starts and flapped the uplink for minutes)
r="$(call mac '{"target":"wifi","action":"reset"}')"
checks "MAC: a second change while the first still reconnects is refused" '[ "$(jf "$r" @.ok)" = false ] && jf "$r" @.error | grep -q "still changing"'
# the first change waits up to 30 s for a station this sandbox does not have, then lets go
n=0; while [ -d /var/run/travel/mac.busy ] && [ $n -lt 40 ]; do sleep 1; n=$((n + 1)); done
check "MAC: the change lets go when it is done" [ ! -d /var/run/travel/mac.busy ]
r="$(call mac '{"target":"wifi","action":"reset"}')"
checks "MAC reset: back to the real one" '! uci show travelmate | grep -q macaddr'
check "MAC reset: off the station too" sh -c "! uci -q get wireless.$sta.macaddr"
n=0; while [ -d /var/run/travel/mac.busy ] && [ $n -lt 40 ]; do sleep 1; n=$((n + 1)); done
r="$(call mac '{"target":"ethernet","action":"random"}')"
m="$(jf "$r" '@.mac')"
check "random MAC: locally administered unicast" sh -c "echo '$m' | grep -qiE '^[0-9a-f][26ae](:[0-9a-f]{2}){5}$'"
check "random MAC: applied to eth0" [ "$(uci -q get network.wan_eth0.macaddr)" = "$m" ]
check "random MAC: remembered as one the panel made up" sh -c "uci -q get travel.main.mac_random | grep -qw '$m'"
s="$(call status)"
checks "status: Ethernet's address saved, and it is a random one" '[ "$(jf "$s" @.mac.ethernet.saved)" = "$m" ] && [ "$(jf "$s" @.mac.ethernet.kind)" = random ]'
r="$(call mac '{"target":"ethernet","action":"set","mac":"02:aa:bb:cc:dd:ee"}')"
s="$(call status)"
check "status: an address typed in is custom" [ "$(jf "$s" @.mac.ethernet.kind)" = custom ]
r="$(call mac '{"target":"ethernet","action":"reset"}')"
s="$(call status)"
checks "status: after reset, the original" '[ "$(jf "$s" @.mac.ethernet.kind)" = original ] && [ -z "$(jf "$s" @.mac.ethernet.saved)" ]'
r="$(call set_ap '{"key":"short"}')"
check "your Wi-Fi: short password refused" [ "$(jf "$r" '@.ok')" = false ]
r="$(call set_ap '{"ssid":"Travel-7","country":"DE"}')"
check "your Wi-Fi: renamed on both bands" [ "$(uci show wireless | grep -c "ssid='Travel-7'")" = 2 ]
checks "your Wi-Fi: manual country turns auto off" '[ "$(uci -q get travel.main.auto_country)" = 0 ] && [ "$(uci -q get wireless.radio1.country)" = DE ]'
# a fresh OpenWrt's access point is open and off: a password turns on WPA2/WPA3 and the Wi-Fi; one that
# already has a password (here switched off on purpose) keeps its mode and stays off
uci set wireless.default_radio0.encryption=none; uci set wireless.default_radio0.disabled=1; uci set wireless.radio0.disabled=1
uci set wireless.default_radio1.encryption=psk2; uci set wireless.default_radio1.disabled=1; uci commit wireless
r="$(call set_ap '{"key":"a-new-password"}')"
checks "your Wi-Fi: a password on an open access point turns on WPA2/WPA3 and the Wi-Fi" '[ "$(uci -q get wireless.default_radio0.encryption)" = sae-mixed ] && [ -z "$(uci -q get wireless.default_radio0.disabled)" ] && [ -z "$(uci -q get wireless.radio0.disabled)" ] && [ "$(uci -q get wireless.default_radio0.key)" = a-new-password ]'
checks "your Wi-Fi: an access point with a password keeps its mode and its off switch" '[ "$(uci -q get wireless.default_radio1.encryption)" = psk2 ] && [ "$(uci -q get wireless.default_radio1.disabled)" = 1 ] && [ "$(uci -q get wireless.default_radio1.key)" = a-new-password ]'
uci set wireless.default_radio1.encryption=sae-mixed; uci -q delete wireless.default_radio1.disabled; uci commit wireless
r="$(call uplink_order '{"order":["trm_wwan","wan","tether"]}')"
checks "order: Wi-Fi first" '[ "$(uci -q get network.trm_wwan.metric)" = 10 ] && [ "$(uci -q get network.wan.metric)" = 20 ] && [ "$(uci -q get travel.main.tether_metric)" = 30 ]'
# The uplink carrying traffic keeps its number: a changed metric makes netifd re-apply that interface,
# which drops every connection through it (2026-10-08). A phone already plugged in is re-added with its new
# number (/usr/libexec/travel/tether-metric, logged here), and only when the number changes.
echo '{"up":true,"metric":10,"device":"phy0.1-sta0","route":[{"target":"0.0.0.0","mask":0,"nexthop":"192.168.50.1"}]}' >/tmp/ifstatus-trm_wwan.json
echo '{"up":true,"metric":30,"device":"eth2","route":[{"target":"0.0.0.0","mask":0,"nexthop":"172.20.10.1"}]}' >/tmp/ifstatus-tether_eth2.json
echo eth2 >/var/run/travel/phone.eth2
reset_calls
r="$(call uplink_order '{"order":["wan","trm_wwan","tether"]}')"
checks "order: Ethernet above the Wi-Fi in use, the Wi-Fi keeps its number" '[ "$(jf "$r" @.ok)" = true ] && [ "$(uci -q get network.trm_wwan.metric)" = 10 ] && [ "$(uci -q get network.wan.metric)" -ge 1 ] && [ "$(uci -q get network.wan.metric)" -lt 10 ]'
checks "order: the plugged-in phone re-added with its new number" '[ "$(uci -q get travel.main.tether_metric)" = 20 ] && calls_has "tether-metric tether_eth2 20"'
r="$(call status)"
checks "order: the panel is told the saved order, with Ethernet unplugged" '[ "$(jf "$r" "@.uplinks[@.name=\"wan\"].metric")" = "$(uci -q get network.wan.metric)" ] && [ "$(jf "$r" "@.uplinks[@.name=\"tether\"].metric")" = 20 ]'
sed -i 's/"metric":30/"metric":20/' /tmp/ifstatus-tether_eth2.json
reset_calls
r="$(call uplink_order '{"order":["wan","trm_wwan","tether"]}')"
check "order: the same order again re-adds nothing" sh -c '! grep -q tether-metric /tmp/calls.log'
r="$(call uplink_order '{"order":["tether","trm_wwan","wan"]}')"
checks "order: phone first while the Wi-Fi is in use" '[ "$(uci -q get network.trm_wwan.metric)" = 10 ] && [ "$(uci -q get travel.main.tether_metric)" -lt 10 ] && [ "$(uci -q get network.wan.metric)" -gt 10 ]'
sed -i 's/"metric":10/"metric":1/' /tmp/ifstatus-trm_wwan.json
r="$(call uplink_order '{"order":["wan","trm_wwan","tether"]}')"
checks "order: no number free below the one in use, so all renumbered" '[ "$(uci -q get network.wan.metric)" = 10 ] && [ "$(uci -q get network.trm_wwan.metric)" = 20 ] && [ "$(uci -q get travel.main.tether_metric)" = 30 ]'
r="$(call uplink_order '{"order":["wan","wan","tether"]}')"
check "order: a source twice refused" [ "$(jf "$r" @.ok)" = false ]
r="$(call uplink_order '{"order":["wan","trm_wwan"]}')"
check "order: a missing source refused" [ "$(jf "$r" @.ok)" = false ]
rm -f /tmp/ifstatus-trm_wwan.json /tmp/ifstatus-tether_eth2.json /var/run/travel/phone.eth2

# ---------------------------------------------------------------- uplink health (health.uc, 2026-10-08)
# One step at a time, with ping, ip and netifd replaced by files: which devices answer, which routes exist.
cat >/tmp/fakeping <<'EOS'
#!/bin/sh
dev=""
while [ $# -gt 0 ]; do [ "$1" = -I ] && { dev="$2"; shift; }; shift; done
grep -qx "$dev" /tmp/answering 2>/dev/null
EOS
cat >/tmp/fakeip <<'EOS'
#!/bin/sh
echo "ip $*" >>/tmp/calls.log
case "$*" in
*"route show default proto 251"*) cat /tmp/ours 2>/dev/null ;;
*"route show default metric "*) m="${*##*metric }"; m="${m%% *}"; [ -e "/tmp/metric-$m" ] && echo "default metric $m" ;;
*"route add default"*"proto 251"*) echo "$*" >/tmp/ours ;;
*"route flush proto 251"*) rm -f /tmp/ours ;;
esac
exit 0
EOS
chmod 755 /tmp/fakeping /tmp/fakeip
hdump() {	# hdump <Wi-Fi metric>
	echo '{"interface":[{"interface":"wan","up":false},{"interface":"trm_wwan","up":true,"l3_device":"phy0.1-sta0","metric":'"$1"',"route":[{"target":"0.0.0.0","mask":0,"nexthop":"192.168.50.1"}]},{"interface":"tether_eth2","up":true,"l3_device":"eth2","metric":30,"route":[{"target":"0.0.0.0","mask":0,"nexthop":"172.20.10.1"}]}]}' >/tmp/dump.json
}
hstep() {	# hstep [n]: n steps of the health check
	local i=0
	while [ "$i" -lt "${1:-1}" ]; do
		HEALTH_PING=/tmp/fakeping HEALTH_IP=/tmp/fakeip HEALTH_DUMP=/tmp/dump.json HEALTH_STATE=/tmp/hs.json \
			HEALTH_NOW="${HNOW:-}" HEALTH_REJOIN=/tmp/fakerejoin ucode /usr/libexec/travel/health.uc once
		i=$((i + 1))
	done
}
hreset() { rm -f /tmp/hs.json /tmp/ours /tmp/metric-* /var/run/travel/failover /var/run/travel/portal; hdump 10; reset_calls; }
hreset
printf 'phy0.1-sta0\neth2\n' >/tmp/answering
hstep 4
check "health: a Wi-Fi with internet is left alone" sh -c '! grep -q "route add" /tmp/calls.log'
echo eth2 >/tmp/answering
hstep 2
check "health: two misses are not enough" sh -c '! grep -q "route add" /tmp/calls.log'
hstep
check "health: on the third, traffic routed to the phone, one metric better than the Wi-Fi" calls_has "ip -4 route add default via 172.20.10.1 dev eth2 metric 9 proto 251"
checks "health: the detour recorded for the panel" '[ "$(jsonfilter -i /var/run/travel/failover -e @.from)" = trm_wwan ] && [ "$(jsonfilter -i /var/run/travel/failover -e @.to)" = tether_eth2 ]'
s="$(call status)"
checks "health: status says the phone carries the traffic, and why" '[ "$(jf "$s" @.internet.uplink)" = tether ] && [ "$(jf "$s" @.internet.failover.from)" = trm_wwan ]'
printf 'phy0.1-sta0\neth2\n' >/tmp/answering
reset_calls
hstep 5
check "health: five answers are not enough to go back" sh -c '! grep -q "route flush" /tmp/calls.log'
hstep
checks "health: after six, back to the Wi-Fi" 'calls_has "ip -4 route flush proto 251" && [ ! -e /var/run/travel/failover ]'
hreset
echo eth2 >/tmp/answering
: >/var/run/travel/portal
hstep 5
check "health: a login page in progress pauses all judgement" sh -c '! grep -q "route add" /tmp/calls.log'
rm -f /var/run/travel/portal
: >/tmp/metric-9
hstep 3
check "health: a metric another route has is skipped" calls_has "ip -4 route add default via 172.20.10.1 dev eth2 metric 8 proto 251"
hdump 20
hstep
checks "health: the order changed, routing given back" '[ ! -e /tmp/ours ] && [ ! -e /var/run/travel/failover ]'
hreset
echo eth2 >/tmp/answering
hstep 3
: >/tmp/answering
hstep 3
checks "health: the phone stops answering too, routing given back" '[ ! -e /tmp/ours ] && [ ! -e /var/run/travel/failover ]'
hreset
: >/tmp/answering
hstep 6
check "health: no backup answers, nothing done" sh -c '! grep -q "route add" /tmp/calls.log'
echo eth2 >/tmp/answering
hstep 3
r="$(call uplink_order '{"order":["trm_wwan","wan","tether"]}')"
check "health: a new order ends the detour" [ ! -e /var/run/travel/failover ]
hreset
# re-joining a dead Wi-Fi (2026-10-12), inside this section: its fakes are removed at the end of it
# Soak run 1: the office Wi-Fi passed nothing for 4.9 h while the router stayed associated and did nothing.
printf '#!/bin/sh\necho "rejoin $1" >>/tmp/rejoins.log\n' >/tmp/fakerejoin; chmod 755 /tmp/fakerejoin
rejoins() { wc -l </tmp/rejoins.log | tr -d ' '; }	# (grep -c prints 0 and fails on an empty file: "0 0")
hdead() {	# hdead <seconds after T0>: one judging cycle (three steps) at that time
	HNOW=$((1000000 + $1)) hstep 3
}
hreset; : >/tmp/rejoins.log; : >/tmp/answering		# neither the Wi-Fi nor the phone answers
hdead 0
check "rejoin: nothing at once when the Wi-Fi dies" [ "$(rejoins)" = 0 ]
hdead 170
check "rejoin: nothing before 3 minutes" [ "$(rejoins)" = 0 ]
hdead 181
checks "rejoin: after 3 minutes, the Wi-Fi is re-joined" '[ "$(rejoins)" = 1 ] && grep -qx "rejoin phy0.1-sta0" /tmp/rejoins.log'
hdead 500
check "rejoin: not again 5 minutes later (the next waits 10)" [ "$(rejoins)" = 1 ]
# a re-join takes the route away for a moment: that must not start the backoff over
echo '{"interface":[{"interface":"trm_wwan","up":false},{"interface":"tether_eth2","up":false}]}' >/tmp/dump.json
hdead 600
hdump 10
hdead 790
check "rejoin: the second after 10 more minutes" [ "$(rejoins)" = 2 ]
hdead 2580
check "rejoin: a route gone during a re-join does not restart the backoff (the third waits 30 min)" [ "$(rejoins)" = 2 ]
hdead 2595
check "rejoin: the third after 30 more minutes" [ "$(rejoins)" = 3 ]
hdead 6190
check "rejoin: then hourly, not sooner" [ "$(rejoins)" = 3 ]
hdead 6200
check "rejoin: then hourly" [ "$(rejoins)" = 4 ]
echo phy0.1-sta0 >/tmp/answering
HNOW=1006300 hstep 1
checks "rejoin: internet back clears the dead spell and the backoff" '[ -z "$(jsonfilter -i /tmp/hs.json -e @.dead)" ] && [ "$(jsonfilter -i /tmp/hs.json -e @.tries)" = 0 ]'
[ -n "$(jsonfilter -i /tmp/hs.json -e @.dead)" ] && echo "      state: $(cat /tmp/hs.json | tr -d '\n\t')"
: >/tmp/answering; : >/tmp/rejoins.log
hdead 7000; hdead 7181
check "rejoin: a new dead spell starts at 3 minutes again" [ "$(rejoins)" = 1 ]
hreset; : >/tmp/rejoins.log; : >/tmp/answering; touch /var/run/travel/portal
hdead 0; hdead 4000
check "rejoin: never while a login page is being handled" [ "$(rejoins)" = 0 ]
rm -f /var/run/travel/portal
hreset; : >/tmp/rejoins.log; : >/tmp/answering
echo '{"interface":[{"interface":"wan","up":true,"l3_device":"eth0","metric":10,"route":[{"target":"0.0.0.0","mask":0,"nexthop":"192.168.1.1"}]}]}' >/tmp/dump.json
hdead 0; hdead 4000
check "rejoin: a dead cable is not re-joined (nothing to re-join)" [ "$(rejoins)" = 0 ]
hreset; : >/tmp/rejoins.log

rm -f /tmp/fakeping /tmp/fakeip /tmp/dump.json /tmp/answering /tmp/fakerejoin /tmp/rejoins.log

# ---------------------------------------------------------------- look like one device (TTL)
check "TTL: firewall include set up" [ "$(uci -q get firewall.travel_ttl.chain)" = mangle_postrouting ]
/usr/libexec/travel/ttl
check "TTL: 64 for everything leaving" grep -q 'oifname != "br-lan" ip ttl set 64' /etc/travel/ttl.nft
echo usb0 >/var/run/travel/phone.usb0
/usr/libexec/travel/ttl
check "TTL: 65 through a tethered phone" grep -q 'oifname { "usb0" } ip ttl set 65' /etc/travel/ttl.nft
if fw4 print >/tmp/fw4.nft 2>/tmp/fw4.err; then
	check "TTL: the real firewall4 includes our rules file" grep -q "include \"/etc/travel/ttl.nft\"" /tmp/fw4.nft
	check "TTL: nftables accepts the whole firewall" nft -c -f /tmp/fw4.nft
	if nft -f /tmp/fw4.nft 2>/tmp/nft.err; then
		checks "TTL: kernel loaded the rules (sandbox network only)" 'nft list chain inet fw4 mangle_postrouting | grep -q "ip ttl set 65"'
	else
		echo "SKIP  loading into the kernel: $(head -1 /tmp/nft.err)"
	fi
else
	echo "SKIP  firewall4 render: $(head -1 /tmp/fw4.err)"
fi
r="$(call set_hide_router '{"enabled":false}')"
checks "TTL off: rules removed" '! grep -q "ttl set" /etc/travel/ttl.nft'
checks "TTL off: status says so" '[ "$(jf "$(call status)" @.hide_router)" = false ]'
r="$(call set_hide_router '{"enabled":true}')"
checks "TTL on again: rules back" 'grep -q "ttl set 64" /etc/travel/ttl.nft'
rm -f /var/run/travel/phone.usb0

# ---------------------------------------------------------------- region: China / rest of the world
echo on >/var/run/travel/switch
r="$(call set_region '{"region":"china"}')"
checks "China mode: slider on means nikki" '[ "$(uci -q get travel.main.switch_on)" = nikki ] && [ "$(uci -q get travel.main.region)" = china ]'
checks "China mode: applied at once while the slider is on" '[ "$(uci -q get travel.main.mode)" = nikki ]'
checks "China mode: status reports it" '[ "$(jf "$(call status)" @.switch.region)" = china ]'
r="$(call set_region '{"region":"world","world_mode":"wireguard"}')"
checks "World mode: slider on means the VPN profile" '[ "$(uci -q get travel.main.switch_on)" = wireguard ] && [ "$(uci -q get travel.main.mode)" = wireguard ]'
r="$(call set_region '{"region":"world","world_mode":"exitnode"}')"
checks "World mode: or a Tailscale exit node" '[ "$(uci -q get travel.main.switch_on)" = exitnode ]'
checks "Slider off is always direct" '[ "$(uci -q get travel.main.switch_off)" = direct ]'
r="$(call set_region '{"region":"mars"}')"
checks "Region: nonsense refused" '[ "$(jf "$r" @.ok)" = false ]'
rm -f /var/run/travel/switch

# ---------------------------------------------------------------- Wi-Fi search, one band at a time
# test/stubs/iw prints test/fixtures/iw: 17 access points, 4 of them without a name to show
net() { jf "$r" "@.networks[@.ssid='$1' && @.band='$2'].$3"; }
# a saved station of its own: what earlier tests left saved varies
uci set wireless.scantest=wifi-iface; uci set wireless.scantest.mode=sta; uci set wireless.scantest.ssid='Cafe WPA3'
uci set wireless.scantest.disabled=1; uci commit wireless
reset_calls
r="$(call wifi_scan '{"band":"2g"}')"
checks "search 2.4 GHz: scans through the 2.4 GHz access point only" 'calls_has "iw dev phy0.0-ap0 scan ap-force" && ! calls_has "phy0.1-ap0"'
check "search: the answer holds every band, without the nameless" [ "$(jf "$r" '@.networks[*].ssid' | wc -l)" = 13 ]
checks "search: one entry per name and band, the stronger access point" '[ "$(jf "$r" "@.networks[@.ssid='"'"'Hotel_Guest'"'"'].band" | wc -l)" = 2 ] && [ "$(net Hotel_Guest 2g bssid)" = 02:00:00:00:01:02 ] && [ "$(net Hotel_Guest 2g channel)" = 11 ]'
checks "search: signal on the old scale (-50 dBm is 85, -40 is 100)" '[ "$(net Hotel_Guest 2g quality)" = 85 ] && [ "$(net "Mixed Mode" 2g quality)" = 100 ]'
checks "search: security read from the access point" '[ "$(net Hotel_Guest 2g security)" = open ] && [ "$(net Airbnb_Ehrenfeld 5g security)" = psk ] && [ "$(net "Cafe WPA3" 5g security)" = sae ] && [ "$(net "Mixed Mode" 2g security)" = sae-mixed ] && [ "$(net Corp 5g security)" = enterprise ] && [ "$(net "OWE Net" 5g security)" = owe ] && [ "$(net "Old Router" 2g security)" = psk ] && [ "$(net Ancient 2g security)" = psk ]'
checks "search: a saved network is marked, others not" '[ "$(net "Cafe WPA3" 5g saved)" = true ] && [ "$(net Corp 5g saved)" = false ]'
checks "search: channel from the frequency (5500 MHz is 100, 5260 is 52)" '[ "$(net Airbnb_Ehrenfeld 5g channel)" = 100 ] && [ "$(net Corp 5g channel)" = 52 ]'
check "search: a Chinese name comes back whole" [ "$(net '酒店WiFi' 2g security)" = open ]
check "search: a name starting with a space keeps it" [ "$(net ' Lobby' 5g band)" = 5g ]
checks "search: a backslash in a name comes back as one" 'jf "$r" "@.networks[*].ssid" | grep -qxF "Back\\slash"'
checks "search: no name, an empty name or zero bytes are left out" '! printf "%s" "$r" | grep -q -E "02:00:00:00:0(c|d|e):01|Nested_Profile"'
reset_calls
r="$(call wifi_scan '{"band":"5g"}')"
checks "search 5 GHz: scans through the 5 GHz access point only" 'calls_has "iw dev phy0.1-ap0 scan ap-force" && ! calls_has "phy0.0-ap0"'
reset_calls
r="$(call wifi_scan '{"band":"all"}')"
checks "search all: both bands, 2.4 GHz first" '[ "$(grep -c "scan ap-force" /tmp/calls.log)" = 2 ] && [ "$(head -n1 /tmp/calls.log)" = "iw dev phy0.0-ap0 scan ap-force" ]'
reset_calls
touch /tmp/iw-busy
r="$(call wifi_scan '{"band":"5g"}')"
rm -f /tmp/iw-busy
checks "search while another scan runs: three tries, then the list anyway" '[ "$(grep -c "phy0.1-ap0 scan ap-force" /tmp/calls.log)" = 3 ] && [ "$(jf "$r" @.ok)" = true ] && [ "$(jf "$r" "@.networks[*].ssid" | wc -l)" = 13 ]'
uci delete wireless.scantest; uci commit wireless

# ---------------------------------------------------------------- the Beryl theme wins on first boot
# The image ships luci with mediaurlbase=bootstrap and runs both themes' first-boot
# scripts in name order, as OpenWrt does.
uci set luci.main.mediaurlbase=/luci-static/bootstrap; uci commit luci
for f in $(ls /etc/uci-defaults/ | grep '^30_luci-theme-' | sort); do ( . "/etc/uci-defaults/$f" ) >/dev/null 2>&1; done
# ---------------------------------------------------------------- the travel service's instances (2026-10-09)
# start_service with procd's calls and ip written out instead of done: which instances it declares
svc() {
	( . /lib/functions.sh
	  procd_open_instance() { echo "instance ${1:-main}"; }
	  procd_set_param() { [ "$1" = command ] && { shift; echo "command $*"; }; return 0; }
	  procd_close_instance() { :; }
	  ip() { echo "ip $*" >>/tmp/svc-ip.log; }	# the service sends ip's output to /dev/null
	  : >/tmp/svc-ip.log
	  . /etc/init.d/travel
	  "${1:-start_service}"
	  cat /tmp/svc-ip.log ) 2>&1
}
uci -q delete travel.main.health; uci -q delete travel.main.log_events; uci commit travel
o="$(svc)"
checks "service: a kept config without the new options gets the health check" 'echo "$o" | grep -qx "instance health"'
checks "service: ... and the Wi-Fi and route events, with the right commands" 'echo "$o" | grep -qx "command /usr/sbin/iw event -t" && echo "$o" | grep -qx "command /sbin/ip monitor route address link"'
checks "service: a running health check is not undone at start" '! echo "$o" | grep -q "route flush"'
uci set travel.main.health=0; uci commit travel
o="$(svc)"
checks "service: health 0, no health check" '! echo "$o" | grep -qx "instance health"'
checks "service: health 0 removes a detour left behind" 'echo "$o" | grep -qx "ip -4 route flush proto 251"'
checks "service: health 0 leaves the watcher and the events" 'echo "$o" | grep -qx "instance main" && echo "$o" | grep -qx "instance wifi_events"'
uci set travel.main.health=1; uci set travel.main.log_events=0; uci commit travel
o="$(svc)"
checks "service: log_events 0, no event instances" '! echo "$o" | grep -q "_events" && echo "$o" | grep -qx "instance health"'
checks "service: stopping it removes the health check's detour" 'svc stop_service | grep -qx "ip -4 route flush proto 251"'
uci set travel.main.log_events=1; uci commit travel

checks "theme: Beryl is the default after first boot" '[ "$(uci -q get luci.main.mediaurlbase)" = /luci-static/beryl ]'
checks "theme: Bootstrap still selectable" '[ -n "$(uci -q get luci.themes.Bootstrap)" ]'
# A firmware upgrade that keeps settings runs the same scripts again, without PKG_UPGRADE: the
# Console look chosen before it must survive (image v5, 2026-10-07)
uci set luci.main.mediaurlbase=/luci-static/beryl-console; uci commit luci
for f in $(ls /etc/uci-defaults/ | grep '^30_luci-theme-' | sort); do ( . "/etc/uci-defaults/$f" ) >/dev/null 2>&1; done
checks "theme: a kept Console look survives a firmware upgrade" '[ "$(uci -q get luci.main.mediaurlbase)" = /luci-static/beryl-console ]'
# ... and so must Aquamarine, the Console look as its own package (2026-10-08)
for v in aquamarine aquamarine-dark; do
	uci set luci.main.mediaurlbase=/luci-static/$v; uci commit luci
	for f in $(ls /etc/uci-defaults/ | grep '^30_luci-theme-' | sort); do ( . "/etc/uci-defaults/$f" ) >/dev/null 2>&1; done
	checks "theme: a kept $v survives a firmware upgrade" '[ "$(uci -q get luci.main.mediaurlbase)" = /luci-static/'$v' ]'
done

echo "RESULT $pass passed, $fail failed"
