#!/bin/sh
# Automatic login at a Wi-Fi login page, whatever the page (Beryl 7 build, 2026-10-06).
# travelmate runs it when it finds a login page on an uplink whose "script" points
# here. script_args: "<username or -> [code]", both optional (an "I accept" page needs
# neither); the username is one word, the code may hold spaces.
#
#   UniFi pages (/guest/s/<site>/): the page's public settings (hotspotconfig) say which
#   login it takes, and the matching UniFi script does it: no password (click-through),
#   a code (unifi-password) or a username and code (unifi-user, UniFi's RADIUS).
#   Any other page: its first <form> is read (form.awk) and sent as a browser would.
#   Hidden fields go as they are; a box is ticked only when it is required or reads as
#   terms and conditions (never a newsletter); a saved username goes to the first name
#   field and the code to the password field, or to the second name field when there
#   is none (room number + surname); the form's submit button is named.
#   A page built entirely by JavaScript has no form to read: recorded as no-form, and
#   left to the traveller (the panel's login card, a phone). The watcher keeps a copy.
# Outcomes in /var/run/travel/autologin.json (method "auto"): ok, already-online,
# no-form, needs-details (a required field nothing was saved for: nothing is sent),
# not-accepted (sent, still not let in), failed; and what the UniFi scripts record.

export LC_ALL=C
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

trm_funlib="/usr/lib/travelmate-functions.sh"
if [ -z "${trm_bver}" ]; then
	. "${trm_funlib}"
	f_conf
fi

user="${1:-}"
[ "${user}" = "-" ] && user=""
[ "$#" -gt 0 ] && shift
code="$*"

jar="/tmp/auto-login.$$"
html="/tmp/auto-login.$$.html"
trap 'rm -f "${jar}" "${html}"' EXIT
export TRAVEL_LOGIN_METHOD=auto	# the UniFi scripts record their outcome as "auto" too

# finish <exit code> <outcome>: record the outcome for the panel, then exit
finish() {
	local ssid
	ssid="$(jsonfilter -q -i /var/run/travelmate/travelmate.runtime.json -e '@.data.station_id' | awk -F/ '{ print $2 }')"
	mkdir -p /var/run/travel
	printf '{"method":"auto","ssid":"%s","result":"%s","at":%s}\n' \
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
	"${probe%/}"*)	# not redirected: online already, or no internet at all
		[ "${rc}" = 0 ] && finish 0 already-online
		finish 1 failed
		;;
	http://* | https://*) ;;
	*) finish 1 failed ;;
esac
tls=""
case "${page}" in https://*) tls="--insecure" ;; esac	# login pages' own certificates
origin="$(printf '%s' "${page}" | awk -F/ '{ printf "%s//%s", $1, $3 }')"

# 2. a UniFi page: its settings say which login it takes
case "${page}" in
	*/guest/s/*/*)
		base="${page%%\?*}"
		base="${base%/*}/"
		cfg="$("${trm_fetchcmd}" ${trm_fetchparm} ${tls} --user-agent "${trm_useragent}" "${base}hotspotconfig" 2>/dev/null)"
		auth="$(printf '%s' "${cfg}" | jsonfilter -q -e '@.data[0].auth')"
		pw="$(printf '%s' "${cfg}" | jsonfilter -q -e '@.data[0].password_enabled')"
		rad="$(printf '%s' "${cfg}" | jsonfilter -q -e '@.data[0].radius_enabled')"
		[ "${auth}" = none ] && exec /etc/travelmate/click-through.login
		[ "${rad}" = true ] && [ -n "${user}" ] && [ -n "${code}" ] && exec /etc/travelmate/unifi-user.login "${user}" ${code}
		[ "${pw}" = true ] && [ -n "${code}" ] && exec /etc/travelmate/unifi-password.login ${code}
		[ -z "${cfg}" ] && [ -n "${code}" ] && exec /etc/travelmate/unifi-password.login ${code}	# older UniFi: no settings to read
		[ -z "${cfg}" ] && exec /etc/travelmate/click-through.login
		finish 255 needs-details
		;;
esac

# 3. any other page: read its first form (cookies kept, as a browser would)
"${trm_fetchcmd}" ${trm_fetchparm} ${tls} --user-agent "${trm_useragent}" --cookie "${jar}" --cookie-jar "${jar}" \
	--max-filesize 524288 --output "${html}" "${page}" 2>/dev/null
[ -s "${html}" ] || finish 255 failed
fields="$(awk -f /usr/libexec/travel/form.awk "${html}")"
form="$(printf '%s\n' "${fields}" | grep '^FORM' | head -n 1)"
[ -n "${form}" ] || finish 1 no-form
SEP="$(printf '\037')"	# form.awk's separator (never merged by read, unlike tabs)
method="$(printf '%s' "${form}" | cut -d "${SEP}" -f 2)"
action="$(printf '%s' "${form}" | cut -d "${SEP}" -f 3)"

# where the form goes, as a browser resolves it
case "${action}" in
	"") target="${page%%#*}" ;;
	http://* | https://*) target="${action}" ;;
	//*) target="${page%%:*}:${action}" ;;
	/*) target="${origin}${action}" ;;
	*) target="${page%%\?*}"; target="${target%/*}/${action}" ;;
esac
case "${target}" in https://*) tls="--insecure" ;; esac

# how many password fields: none means the code goes to the second name field
npass="$(printf '%s\n' "${fields}" | awk -F "${SEP}" '$1 == "F" && $2 == "password"' | wc -l)"

# the fields, in the form's order: "set --" collects the curl arguments
set --
ntext=0
pass_done=0
submit_done=0
need=0
radios=" "
while IFS="${SEP}" read -r kind type name value flags; do
	[ "${kind}" = F ] && [ -n "${name}" ] || continue
	case "${type}" in
	hidden)
		set -- "$@" --data-urlencode "${name}=${value}"
		;;
	checkbox)
		case "${flags}" in
		*c* | *r*) set -- "$@" --data-urlencode "${name}=${value:-on}" ;;
		*)
			printf '%s %s' "${name}" "${value}" | grep -q -i -E 'term|tos|agree|accept|polic|condition|aup|consent|rule' &&
				set -- "$@" --data-urlencode "${name}=${value:-on}"
			;;
		esac
		;;
	radio)	# the checked one, else the first of its group
		case "${radios}" in *" ${name} "*) continue ;; esac
		if [ "${flags#*c}" != "${flags}" ] || ! printf '%s\n' "${fields}" | awk -F "${SEP}" -v n="${name}" '$2 == "radio" && $3 == n && $5 ~ /c/ { f = 1 } END { exit !f }'; then
			set -- "$@" --data-urlencode "${name}=${value}"
			radios="${radios}${name} "
		fi
		;;
	text | email | tel | number | search | "")
		ntext=$((ntext + 1))
		if [ "${ntext}" = 1 ] && [ -n "${user}" ]; then
			set -- "$@" --data-urlencode "${name}=${user}"
		elif [ "${ntext}" = 2 ] && [ "${npass}" = 0 ] && [ -n "${code}" ]; then
			set -- "$@" --data-urlencode "${name}=${code}"
		elif [ -n "${value}" ]; then
			set -- "$@" --data-urlencode "${name}=${value}"
		else
			[ "${flags#*r}" != "${flags}" ] && need=1
			set -- "$@" --data-urlencode "${name}="
		fi
		;;
	password)
		if [ -n "${code}" ] && [ "${pass_done}" = 0 ]; then
			set -- "$@" --data-urlencode "${name}=${code}"
			pass_done=1
		else
			need=1
		fi
		;;
	select)
		set -- "$@" --data-urlencode "${name}=${value}"
		;;
	submit | button-submit | image)
		if [ "${submit_done}" = 0 ]; then
			set -- "$@" --data-urlencode "${name}=${value}"
			submit_done=1
		fi
		;;
	esac
done <<EOF
${fields}
EOF
[ "${need}" = 0 ] || finish 255 needs-details

# 4. send it, once, from the page's own origin (see unifi-password.login on retries)
if [ "${method}" = post ]; then
	"${trm_fetchcmd}" ${trm_fetchparm} ${tls} --retry 0 --max-time 20 --user-agent "${trm_useragent}" \
		--cookie "${jar}" --cookie-jar "${jar}" --referer "${page}" --header "Origin: ${origin}" \
		--output /dev/null "$@" "${target}" 2>/dev/null || finish 255 failed
else
	"${trm_fetchcmd}" ${trm_fetchparm} ${tls} --retry 0 --max-time 20 --user-agent "${trm_useragent}" \
		--cookie "${jar}" --cookie-jar "${jar}" --referer "${page}" \
		--output /dev/null --get "$@" "${target}" 2>/dev/null || finish 255 failed
fi

# 5. the internet is the judge
n=0
while [ "${n}" -lt 5 ]; do
	sleep 3
	now="$("${trm_fetchcmd}" ${trm_fetchparm} --user-agent "${trm_useragent}" --output /dev/null \
		--write-out "%{url_effective}" "${probe}" 2>/dev/null)" && case "${now}" in "${probe%/}"*) finish 0 ok ;; esac
	n=$((n + 1))
done
finish 255 not-accepted
