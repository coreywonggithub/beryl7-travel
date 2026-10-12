#!/bin/sh
# Captive portal auto-login for a click-through login page: "I accept" and a button,
# no code (Beryl 7 build, 2026-10-06). travelmate runs it when it finds a login page
# on an uplink whose "script" option points here; it takes no arguments.
#
#   uci set travelmate.@uplink[N].script='/etc/travelmate/click-through.login'
#
# UniFi's no-password page (auth "none", terms optional) logs in with an empty POST to
# <page origin><page path>login, as its own JavaScript does (kl = () => xl(null), read
# on 2026-10-06); the terms tick box only enables the button on the page. Other kinds
# of page are not handled yet: they are recorded as not-supported, and travelmate
# leaves them to the traveller (the panel's login card, a phone). Each run leaves its
# outcome in /var/run/travel/autologin.json for the panel.

export LC_ALL=C
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

trm_funlib="/usr/lib/travelmate-functions.sh"
if [ -z "${trm_bver}" ]; then
	. "${trm_funlib}"
	f_conf
fi

jar="/tmp/click-login.$$"
trap 'rm -f "${jar}"' EXIT

# finish <exit code> <outcome>: record the outcome for the panel, then exit
finish() {
	local ssid
	ssid="$(jsonfilter -q -i /var/run/travelmate/travelmate.runtime.json -e '@.data.station_id' | awk -F/ '{ print $2 }')"
	mkdir -p /var/run/travel
	printf '{"method":"%s","ssid":"%s","result":"%s","at":%s}\n' "${TRAVEL_LOGIN_METHOD:-click-through}" \
		"$(printf '%s' "${ssid}" | sed 's/[\\"]/\\&/g')" "${2}" "$(date +%s)" >/var/run/travel/autologin.json.new &&
		mv /var/run/travel/autologin.json.new /var/run/travel/autologin.json
	exit "${1}"
}

# 1. the login page, reached as a browser is (TRM_LOGIN_PAGE is a test seam)
probe="${trm_captiveurl:-http://detectportal.firefox.com}"
page="${TRM_LOGIN_PAGE:-}"
rc=0
if [ -z "${page}" ]; then
	page="$("${trm_fetchcmd}" ${trm_fetchparm} --user-agent "${trm_useragent}" --cookie-jar "${jar}" \
		--output /dev/null --write-out "%{url_effective}" "${probe}" 2>/dev/null)" || rc=$?
fi
case "${page}" in
	http://*/guest/s/*/* | https://*/guest/s/*/*) ;;
	"${probe%/}"*)	# not redirected: online already, or no internet at all
		[ "${rc}" = 0 ] && finish 0 already-online
		finish 1 failed
		;;
	*) finish 1 not-supported ;;	# a login page this script does not know yet
esac
base="${page%%\?*}"
base="${base%/*}/"
tls=""
case "${page}" in https://*) tls="--insecure" ;; esac	# the gateway's own certificate
origin="$(printf '%s' "${page}" | awk -F/ '{ printf "%s//%s", $1, $3 }')"

# open the page itself, for any cookie that ties the login to this router
"${trm_fetchcmd}" ${trm_fetchparm} ${tls} --user-agent "${trm_useragent}" --cookie "${jar}" --cookie-jar "${jar}" \
	--output /dev/null "${page}" 2>/dev/null

# The login request goes once and may take 20 s: travelmate's fetch options retry twice
# with 7 s each, which sends a login three times (2026-10-06). Later options win in curl.
# 2. UniFi's login with no credentials: an empty POST, from the page's own origin
#    (without Origin and Referer UniFi does not process a login at all, 2026-10-05)
answer="$("${trm_fetchcmd}" ${trm_fetchparm} ${tls} --user-agent "${trm_useragent}" --cookie "${jar}" --cookie-jar "${jar}" \
	--referer "${page}" --header "Origin: ${origin}" --retry 0 --max-time 20 --data '' "${base}login" 2>/dev/null)" || finish 255 failed
authorized=0
case "${answer}" in
	*'"rc":"error"'*) finish 255 refused ;;
	*'"authorized":true'* | *'"authorized": true'*) authorized=1 ;;
esac

# 3. the internet is the judge (the gateway takes a few seconds to let the router through)
n=0
while [ "${n}" -lt 5 ]; do
	sleep 3
	now="$("${trm_fetchcmd}" ${trm_fetchparm} --user-agent "${trm_useragent}" --output /dev/null \
		--write-out "%{url_effective}" "${probe}" 2>/dev/null)" && case "${now}" in "${probe%/}"*) finish 0 ok ;; esac
	n=$((n + 1))
done
[ "${authorized}" = 1 ] && finish 0 ok
finish 255 failed
