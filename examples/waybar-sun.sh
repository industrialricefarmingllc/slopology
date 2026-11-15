#!/bin/sh
# A Waybar custom module: the next sun boundary and how long until it.
#
# Put this in your Waybar config:
#
#   "custom/sun": {
#       "exec": "SKY_ARGS='--place Paris' ~/bin/waybar-sun.sh",
#       "interval": 60,
#       "format": "{}"
#   }
#
# SKY_ARGS is passed to slopology verbatim, for example
# "--lat 48.8566 --lon 2.3522 --tz Europe/Paris" or "--place Tokyo".

set -u

SKY_LIB_DIR="${SKY_LIB_DIR:-/usr/local/lib/slopology}"
. "${SKY_LIB_DIR}/sky.sh" 2>/dev/null || {
    printf 'slopology not installed\n'
    exit 0
}

json=$(slopology phase --json ${SKY_ARGS:-}) || {
    printf 'sky ?\n'
    exit 0
}

next=$(printf '%s\n' "${json}" | sky_json_get next.event)
at=$(printf '%s\n' "${json}" | sky_json_get next.minute)
secs=$(printf '%s\n' "${json}" | sky_json_get next.in_seconds)

[ -n "${next}" ] || {
    printf 'no boundary\n'
    exit 0
}

h=$((secs / 3600))
m=$(((secs % 3600) / 60))
if [ "${h}" -gt 0 ]; then
    left="${h}h ${m}m"
else
    left="${m}m"
fi

printf '%s %s (%s)\n' "$(printf '%s' "${next}" | tr '_' ' ')" "$(sky_format_minute "${at}")" "${left}"
