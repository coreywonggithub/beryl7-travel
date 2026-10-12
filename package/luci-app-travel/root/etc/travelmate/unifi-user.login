#!/bin/sh
# Captive portal auto-login for a UniFi login page that asks for a username and a
# password (UniFi's "RADIUS" method; hotels hand them out at check-in) (Beryl 7 build,
# 2026-10-06). script_args: "<username> <password>", the username one word.
# It is unifi-password.login in username mode: travelmate resolves symlinks before
# running a script, so a symlink could not tell the two apart.
UNIFI_BY=radius
. /etc/travelmate/unifi-password.login
