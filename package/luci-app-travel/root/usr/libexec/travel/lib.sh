# shellcheck shell=sh
# Shared by the travel panel scripts. Sourced, never executed.

TRAVEL_RUN=/var/run/travel
mkdir -p "$TRAVEL_RUN"

tlog() { logger -t travel "$*"; }

# tget <option> [default] / tset <option> <value>: travel.main in /etc/config/travel
tget() {
	local v
	v="$(uci -q get "travel.main.$1")"
	printf '%s' "${v:-$2}"
}
tset() {
	uci -q set "travel.main.$1=$2" && uci -q commit travel
}

valid_mode() {
	case "$1" in
	direct|exitnode|wireguard|nikki) return 0 ;;
	esac
	return 1
}

# Tailscale facts via a small ucode helper (JSON is painful in shell)
tsinfo() { ucode /usr/libexec/travel/tsinfo.uc "$@" 2>/dev/null; }

# The WireGuard interfaces this panel manages (created by wg_import)
wg_profiles() {
	uci -q show network | sed -n "s/^network\.\([^.=]*\)\.travel_label=.*/\1/p"
}
