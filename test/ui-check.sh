#!/bin/bash
# Ask the UI sandbox (test/serve-ui.sh) the questions LuCI's pages ask, over the
# same ubus JSON-RPC endpoint the browser uses, and say which ones fail. It is
# the quick check that the imaginary router (test/stubs/sandbox.uc) still
# answers everything: run it after changing a stub, or before opening pages.
# Read-only: it logs in as the sandbox's root and only reads.
#
#   PORT=8089 test/ui-check.sh        (on the build box; or through the ssh tunnel)
#
# Needs curl and jq. Exit status 1 if any check fails.
set -uo pipefail
PORT="${PORT:-8088}"
URL="http://127.0.0.1:$PORT/ubus"
PASSWORD='sandbox-only'	# see serve-ui.sh

rpc() {	# rpc <session> <object> <method> <params-json>  -> the reply's [status, data]
	curl -s --max-time 40 "$URL" -H 'Content-Type: application/json' \
		-d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"$1\",\"$2\",\"$3\",$4]}"
}

SID="$(rpc 00000000000000000000000000000000 session login \
	"{\"username\":\"root\",\"password\":\"$PASSWORD\"}" | jq -r '.result[1].ubus_rpc_session // empty')"
if [ -z "$SID" ]; then
	echo "cannot log in on port $PORT (is the sandbox running? PORT=... test/ui-check.sh)" >&2
	exit 2
fi

pass=0
fail=0
chk() {	# chk <page> <object> <method> <params-json> <jq test on the data>
	local page="$1" obj="$2" method="$3" params="$4" test="$5" reply status
	reply="$(rpc "$SID" "$obj" "$method" "$params")"
	status="$(printf '%s' "$reply" | jq -r 'if .error then "error \(.error.code) \(.error.message)" elif .result[0] == 0 then "ok" else "ubus status \(.result[0])" end' 2>/dev/null)"
	if [ "$status" = ok ] && printf '%s' "$reply" | jq -e ".result[1] | ($test)" >/dev/null 2>&1; then
		pass=$((pass + 1))
		printf '  ok    %-26s %s.%s\n' "$page" "$obj" "$method"
	else
		fail=$((fail + 1))
		printf '  FAIL  %-26s %s.%s  (%s)\n' "$page" "$obj" "$method" "${status:-no reply}"
	fi
}
exec_cmd() {	# exec_cmd <page> <test> <command> [arg...]  through rpcd's file plugin, as fs.exec does
	local page="$1" test="$2" cmd="$3" args="[]"
	shift 3
	[ $# -gt 0 ] && args="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
	chk "$page" file exec "{\"command\":\"$cmd\",\"params\":$args}" "$test"
}

cgi_exec() {	# cgi_exec <page> <jq test on the output, or -> <command> [arg...]
	# the way fs.exec_direct runs a command: through the cgi-exec CGI, not through ubus
	local page="$1" test="$2" cmd="$3" cmdstr body code a
	shift 3
	cmdstr="$(printf '%s' "$cmd" | sed 's/[\\ ]/\\&/g')"
	for a in "$@"; do cmdstr="$cmdstr $(printf '%s' "$a" | sed 's/[\\ ]/\\&/g')"; done
	body="$(mktemp)"
	code="$(curl -s --max-time 40 -o "$body" -w '%{http_code}' -d "sessionid=$SID" --data-urlencode "command=$cmdstr" \
		-d stderr=0 "http://127.0.0.1:$PORT/cgi-bin/cgi-exec")"
	if [ "$code" = 200 ] && { [ "$test" = - ] || jq -e "$test" "$body" >/dev/null 2>&1; }; then
		pass=$((pass + 1))
		printf '  ok    %-26s cgi-exec %s %s\n' "$page" "$(basename "$cmd")" "${1:-}"
	else
		fail=$((fail + 1))
		printf '  FAIL  %-26s cgi-exec %s %s  (HTTP %s)\n' "$page" "$(basename "$cmd")" "${1:-}" "$code"
	fi
	rm -f "$body"
}

echo "sandbox on port $PORT"

echo "Status > Overview"
chk Overview system board '{}' '.hostname == "beryl7" and (.release.version | length > 0)'
chk Overview system info '{}' '.uptime > 0 and .memory.total > 0 and (.load | length) == 3'
chk Overview luci getVersion '{}' '.branch | length > 0'
chk Overview network.interface dump '{}' '(.interface | length) >= 5 and ([.interface[] | select(.up)] | length) >= 4'
chk Overview network.interface dump '{}' '[.interface[] | select(.route | length > 0)] | length >= 2'
chk Overview network.device status '{"name":"eth0"}' '.up == true and .carrier == true'
chk Overview network get_proto_handlers '{}' 'has("static") and has("dhcp")'
chk Overview luci-rpc getBoardJSON '{}' '.model.id == "glinet,gl-mt3600be"'
chk Overview luci-rpc getNetworkDevices '{}' 'has("br-lan") and has("eth0") and has("phy0.1-sta0") and ."br-lan".bridge == true'
chk Overview luci-rpc getWirelessDevices '{}' '.radio0.iwinfo.hwmodes_text and (.radio1.interfaces | length) >= 2'
chk Overview luci-rpc getHostHints '{}' 'length >= 5'
chk Overview luci-rpc getDHCPLeases '{}' '.dhcp_leases | length >= 4'
chk Overview luci getBuiltinEthernetPorts '{}' '.result | length == 2'
chk Overview luci getMountPoints '{}' '.result | length > 0'
chk Overview luci getOdhcp6cStats '{}' 'has("result")'
chk Overview iwinfo assoclist '{"device":"phy0.1-ap0"}' '.results | length >= 3'
chk Overview file read '{"path":"/proc/sys/net/netfilter/nf_conntrack_max"}' '.data | length > 0'

echo "Status > Routing, System Log, Processes"
exec_cmd Routing '.code == 0 and (.stdout | test("default via"))' /sbin/ip -4 route show table all
exec_cmd Routing '.code == 0 and (.stdout | test("lladdr"))' /sbin/ip -4 neigh show
exec_cmd Routing '.code == 0 and (.stdout | test("lookup main"))' /sbin/ip -4 rule show
chk "System Log" log read '{"lines":1000,"stream":false,"oneshot":true}' '.log | length > 10'
chk Processes luci getProcessList '{}' '.result | length > 5'

echo "Status > Realtime Graphs"
chk Load luci getRealtimeStats '{"mode":"load"}' '.result | length >= 30'
chk Bandwidth luci getRealtimeStats '{"mode":"interface","device":"eth0"}' '(.result | length >= 30) and (.result[-1][1] > .result[0][1])'
chk Wireless luci getRealtimeStats '{"mode":"wireless","device":"phy0.1-ap0"}' '.result | length >= 30'
chk Connections luci getRealtimeStats '{"mode":"conntrack"}' '.result | length >= 30'
chk Connections luci getConntrackList '{}' '.result | length >= 20'

echo "Network"
chk Interfaces network.device status '{"name":"br-lan"}' '."bridge-members" | length >= 1'
chk Wireless iwinfo info '{"device":"phy0.1-sta0"}' '.mode == "Client" and .ssid == "Hotel_Guest" and .signal < 0'
chk Wireless iwinfo freqlist '{"device":"radio1"}' '.results | length > 10'
chk Wireless iwinfo txpowerlist '{"device":"radio0"}' '.results | length > 5'
chk Wireless iwinfo countrylist '{"device":"radio0"}' '.results | length > 10'
chk Wireless iwinfo scan '{"device":"radio1"}' '.results | length >= 3'
chk "DHCP and DNS" service list '{}' 'has("dnsmasq")'
chk "DHCP and DNS" luci-rpc getDUIDHints '{}' '. == null or type == "object"'
chk Firewall luci getConntrackHelpers '{}' 'has("result")'
chk Firewall uci get '{"config":"firewall"}' '.values | length > 5'

echo "System"
chk System luci getTimezones '{}' 'length > 100'
chk System luci getFeatures '{}' '.firewall4 == true and .hostapd.sae == true and .wifi == true'
chk System uci get '{"config":"system"}' '.values | length >= 1'
chk Startup rc list '{}' 'length > 5'
chk "Mount Points" luci getBlockDevices '{}' 'has("sda1")'
chk "LED Configuration" luci getLEDs '{}' 'length >= 1'
exec_cmd Software '.code == 0 and (.stdout | length > 100)' /usr/libexec/package-manager-call list-installed
cgi_exec Software 'type == "array" and length > 10' /usr/libexec/package-manager-call list-installed
cgi_exec Software - /usr/libexec/package-manager-call list-available
chk Administration uci get '{"config":"dropbear"}' '.values | length >= 1'

echo "Travel and travelmate"
chk Travel travel status '{}' '(.uplinks | length == 3) and (.uplinks[0].online == true) and (.devices | length >= 4)'
chk Travel travel wifi_saved '{}' '.networks | length >= 3'
chk Travelmate file stat '{"path":"/var/run/travelmate/travelmate.runtime.json"}' '.size > 0'
chk Travelmate uci get '{"config":"travelmate"}' '.values | length >= 4'
chk nlbwmon file exec '{"command":"/usr/libexec/nlbwmon-action","params":["periods"]}' '.code == 0 and (.stdout | test("periods"))'

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
