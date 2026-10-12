#!/bin/sh
# Captive portal auto-login for a UniFi hotspot with a password login page
# (Beryl 7 build, 2026-10-05). travelmate runs it when it finds a login page on
# an uplink whose "script" option points here; the uplink's script_args are the
# arguments: the hotspot's password, the code guests type on the page.
#
#   uci set travelmate.@uplink[N].script='/etc/travelmate/unifi-password.login'
#   uci set travelmate.@uplink[N].script_args='<the code>'
#
# It does what UniFi's own page does (read from its JavaScript on 2026-10-05):
# open the login page the way a browser is sent there, then POST
# {"by":"password","password":...} to <page origin><page path>login. It exits 0
# only when UniFi answers "authorized"; travelmate then checks the internet again.
# The code goes nowhere but a page under /guest/s/<site>/, and is never logged.
# Each run leaves its outcome (never the code) in /var/run/travel/autologin.json for
# the panel: ok, wrong-code, refused, not-unifi or failed.

export LC_ALL=C
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

trm_funlib="/usr/lib/travelmate-functions.sh"
if [ -z "${trm_bver}" ]; then
	. "${trm_funlib}"
	f_conf
fi

# UNIFI_BY=radius (set by unifi-user.login, which sources this file) is UniFi's
# username-and-password page: script_args are then "<username> <password>", the
# username one word. Otherwise the arguments are the code; it may hold spaces, which
# travelmate splits script_args on, so they are joined back.
by="${UNIFI_BY:-password}"
method="${TRAVEL_LOGIN_METHOD:-unifi-password}"	# auto.login hands over as "auto"
user=""
if [ "${by}" = radius ]; then
	method="${TRAVEL_LOGIN_METHOD:-unifi-user}"
	user="${1}"
	shift
fi
code="$*"
jar="/tmp/unifi-login.$$"
trap 'rm -f "${jar}"' EXIT

# finish <exit code> <outcome>: record the outcome for the panel, then exit
finish() {
	local ssid
	ssid="$(jsonfilter -q -i /var/run/travelmate/travelmate.runtime.json -e '@.data.station_id' | awk -F/ '{ print $2 }')"
	mkdir -p /var/run/travel
	printf '{"method":"%s","ssid":"%s","result":"%s","at":%s}\n' "${method}" \
		"$(printf '%s' "${ssid}" | sed 's/[\\"]/\\&/g')" "${2}" "$(date +%s)" >/var/run/travel/autologin.json.new &&
		mv /var/run/travel/autologin.json.new /var/run/travel/autologin.json
	exit "${1}"
}
[ -n "${code}" ] || finish 1 failed
[ "${by}" = radius ] && [ -z "${user}" ] && finish 1 failed

# 1. the login page, reached as a browser is: the probe is redirected there, and the
#    page may set the cookie that ties the login to this router. TRM_LOGIN_PAGE is a
#    test seam: a page address to use instead of probing.
probe="${trm_captiveurl:-http://detectportal.firefox.com}"
page="${TRM_LOGIN_PAGE:-}"
rc=0
if [ -z "${page}" ]; then
	# no "|| exit": a login page on https with the gateway's own certificate fails the
	# fetch (curl 60) after the redirect, and the address it got to is all we need here
	page="$("${trm_fetchcmd}" ${trm_fetchparm} --user-agent "${trm_useragent}" --cookie-jar "${jar}" \
		--output /dev/null --write-out "%{url_effective}" "${probe}" 2>/dev/null)" || rc=$?
fi
case "${page}" in
	http://*/guest/s/*/* | https://*/guest/s/*/*) ;;
	"${probe%/}"*)	# not redirected: online already, or no internet at all
		[ "${rc}" = 0 ] && finish 0 already-online
		finish 1 failed
		;;
	*) finish 1 not-unifi ;;	# a login page, but not UniFi's
esac
base="${page%%\?*}"
base="${base%/*}/"

# UniFi's secure login page uses the gateway's own certificate, which nothing can
# verify; the same page on plain http would send the code in the clear anyway, so it
# gets --insecure, and only it (2026-10-05: UniFi switched to https:8444 by itself)
tls=""
case "${page}" in https://*) tls="--insecure" ;; esac

# open the page itself, for any cookie that ties the login to this router
"${trm_fetchcmd}" ${trm_fetchparm} ${tls} --user-agent "${trm_useragent}" --cookie "${jar}" --cookie-jar "${jar}" \
	--output /dev/null "${page}" 2>/dev/null

# The login request goes once and may take 20 s: travelmate's fetch options retry twice
# with 7 s each, which sent a login three times and gave up on a RADIUS check that UniFi
# was still waiting on (2026-10-06). Later options win in curl, so these override them.
# 2. the login, as UniFi's page sends it: a JSON body (the page sets no content type),
#    from the page's own origin. Without Origin and Referer (travelmate's fetch
#    options send a placeholder referer) UniFi does not even check the code: it
#    answers 302 to google.com (seen 2026-10-05); with them it answers in JSON
esc="$(printf '%s' "${code}" | sed 's/[\\"]/\\&/g')"
body="{\"by\":\"password\",\"password\":\"${esc}\"}"
if [ "${by}" = radius ]; then	# as UniFi's page sends it: Pl=(e,t)=>xl({by:radius,username:e,password:t})
	uesc="$(printf '%s' "${user}" | sed 's/[\\"]/\\&/g')"
	body="{\"by\":\"radius\",\"username\":\"${uesc}\",\"password\":\"${esc}\"}"
fi
origin="$(printf '%s' "${page}" | awk -F/ '{ printf "%s//%s", $1, $3 }')"
answer="$("${trm_fetchcmd}" ${trm_fetchparm} ${tls} --user-agent "${trm_useragent}" --cookie "${jar}" --cookie-jar "${jar}" \
	--referer "${page}" --header "Origin: ${origin}" --header "Content-Type: text/plain;charset=UTF-8" \
	--retry 0 --max-time 20 --data "${body}" "${base}login" 2>/dev/null)" || finish 255 failed
authorized=0
case "${answer}" in
	*'"msg":"InvalidPassword"'*) finish 255 wrong-code ;;
	*'"rc":"error"'*) finish 255 refused ;;	# UniFi said no for another reason
	*'"authorized":true'* | *'"authorized": true'*) authorized=1 ;;
esac

# 3. the internet is the judge, also after "authorized": the gateway takes a few
#    seconds to let the router through, and travelmate checks again the moment this
#    exits, so exiting early cost a whole 30 s round (seen 2026-10-05). UniFi answers
#    a device that is already in with a redirect to google.com, and versions differ.
n=0
while [ "${n}" -lt 5 ]; do
	sleep 3
	now="$("${trm_fetchcmd}" ${trm_fetchparm} --user-agent "${trm_useragent}" --output /dev/null \
		--write-out "%{url_effective}" "${probe}" 2>/dev/null)" && case "${now}" in "${probe%/}"*) finish 0 ok ;; esac
	n=$((n + 1))
done
# UniFi said yes but the internet is slow to open: travelmate keeps checking anyway
[ "${authorized}" = 1 ] && finish 0 ok
finish 255 failed
