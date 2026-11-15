#!/bin/sh
# Warm the screen from sunset to sunrise with hyprsunset.
#
#   night-light.sh LAT LON TZ [TEMPERATURE]
#   night-light.sh 48.8566 2.3522 Europe/Paris 3500
#
# Run it from cron every five minutes, from a systemd timer, or from a shell
# loop; it is idempotent. It needs hyprsunset and a Hyprland session.
#
# For a desktop shell that already knows its position, use --place instead:
#
#   json=$(slopology night --json --place Paris)

set -u

SKY_LIB_DIR="${SKY_LIB_DIR:-/usr/local/lib/slopology}"
. "${SKY_LIB_DIR}/sky.sh" 2>/dev/null || exit 0

lat="${1:-}"
lon="${2:-}"
tz="${3:-}"
temp="${4:-3500}"

[ -n "${lat}" ] && [ -n "${lon}" ] || {
    printf 'usage: %s LAT LON [TZ] [TEMPERATURE]\n' "$0" >&2
    exit 2
}

json=$(sky_night now "${lat}" "${lon}" "${tz}") || exit 1
active=$(printf '%s\n' "${json}" | sky_json_get active)
polar=$(printf '%s\n' "${json}" | sky_json_get polar)

if [ "${polar}" = "midnight-sun" ]; then
    hyprctl hyprsunset identity >/dev/null 2>&1
    exit 0
fi

if [ "${active}" = "true" ]; then
    if ! pgrep -x hyprsunset >/dev/null 2>&1; then
        setsid -f hyprsunset -i >/dev/null 2>&1
        sleep 1
    fi
    hyprctl hyprsunset temperature "${temp}" >/dev/null 2>&1
else
    hyprctl hyprsunset identity >/dev/null 2>&1
fi
