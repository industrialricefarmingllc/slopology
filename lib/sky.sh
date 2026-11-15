# slopology — daylight, twilight and weather for any place on Earth.
#
# POSIX shell library. Source it, then call the sky_* functions. Every
# function writes JSON to stdout and returns non-zero on failure, with a
# message on stderr.
#
#   . /usr/local/lib/slopology/sky.sh
#   sky_solar now 48.8566 2.3522 Europe/Paris
#
# Requirements: a POSIX shell, POSIX awk, and curl or wget for the weather
# and place lookups. Everything else is arithmetic in awk.
#
# Environment:
#   SKY_LIB_DIR    where sky.awk lives (default /usr/local/lib/slopology)
#   SKY_AWK        awk to use (default awk)
#   SKY_UNITS      metric (default) or imperial
#   SKY_DAYS       forecast days, 1-16 (default 7)
#   SKY_HOURS      forecast hours, 1-384 (default 25)
#   SKY_LANG       language for place names (default en)
#   SKY_MAX_AGE    forecast cache lifetime in seconds (default 900)
#   SKY_CACHE      0 disables the forecast cache (default 1)
#   SKY_CACHE_DIR  cache directory (default ${XDG_CACHE_HOME:-~/.cache}/slopology)
#   SKY_OFFLINE    1 uses the cache only and never touches the network
#   SKY_REFRESH    1 ignores a fresh cache entry and fetches again
#   SKY_FETCH_CMD  shell snippet that prints a URL's body; $1 is the URL.
#                  Use it to plug in another HTTP client or a local fixture.
#   SKY_CURRENT / SKY_HOURLY / SKY_DAILY
#                  override the Open-Meteo variable lists
#   SKY_HOUR12     1 prints clocks as 12-hour times

SKY_VERSION="0.1.0"
SKY_LIB_DIR="${SKY_LIB_DIR:-/usr/local/lib/slopology}"
SKY_AWK="${SKY_AWK:-awk}"
SKY_AWK_FILE="${SKY_AWK_FILE:-${SKY_LIB_DIR}/sky.awk}"

_sky_die() {
    printf 'slopology: %s\n' "$*" >&2
    return 2
}

_sky_awk() {
    LC_ALL=C "${SKY_AWK}" -f "${SKY_AWK_FILE}" "$@"
}

sky_version() {
    printf '%s\n' "${SKY_VERSION}"
}

# ---------------------------------------------------------------------------
# time zones
# ---------------------------------------------------------------------------

# "+01:00" / "-0500" / "+02" / "3600" -> seconds east of UTC
_sky_offset_seconds() {
    _z="$1"
    case "${_z}" in
        ''|local|auto) _z="$(date +%z)" ;;
        Z|z|UTC|utc|GMT|gmt) printf '0\n'; return 0 ;;
    esac
    case "${_z}" in
        [+-]*)
            _sign=1
            case "${_z}" in -*) _sign=-1 ;; esac
            _digits=$(printf '%s' "${_z}" | tr -d '+:-')
            case "${_digits}" in
                ''|*[!0-9]*) return 1 ;;
            esac
            if [ "${#_digits}" -le 2 ]; then
                _h=${_digits}
                _m=0
            else
                _h=${_digits%??}
                _m=${_digits#"${_h}"}
            fi
            _h=${_h#0}; [ -n "${_h}" ] || _h=0
            _m=${_m#0}; [ -n "${_m}" ] || _m=0
            printf '%s\n' $(( _sign * (_h * 3600 + _m * 60) ))
            return 0
            ;;
        *[!0-9-]*|'') return 1 ;;
        *) printf '%s\n' "${_z}"; return 0 ;;
    esac
}

# How this system's date(1) reads an arbitrary epoch: gnu (-d @N),
# bsd (-r N), or none (current offset only).
_sky_date_flavor() {
    if [ -z "${_SKY_DATE_FLAVOR:-}" ]; then
        if date -u -d @0 +%z >/dev/null 2>&1; then
            _SKY_DATE_FLAVOR=gnu
        elif date -u -r 0 +%z >/dev/null 2>&1; then
            _SKY_DATE_FLAVOR=bsd
        else
            _SKY_DATE_FLAVOR=none
        fi
    fi
    printf '%s\n' "${_SKY_DATE_FLAVOR}"
}

# sky_offset TIMEZONE [EPOCH] -> seconds east of UTC
# An empty timezone means the machine's local zone. The lookup honours DST
# through the system's tzdata, so it works for any IANA zone.
sky_offset() {
    _tz="$1"
    _epoch="${2:-$(date +%s)}"
    case "${_tz}" in
        ''|local|auto) _sky_offset_seconds "$(date +%z)"; return $? ;;
        Z|z|UTC|utc|GMT|gmt) printf '0\n'; return 0 ;;
        [+-]*) _sky_offset_seconds "${_tz}"; return $? ;;
    esac
    case "$(_sky_date_flavor)" in
        gnu) _z=$(TZ="${_tz}" date -d "@${_epoch}" +%z 2>/dev/null) ;;
        bsd) _z=$(TZ="${_tz}" date -r "${_epoch}" +%z 2>/dev/null) ;;
        *)   _z=$(date +%z) ;;
    esac
    [ -n "${_z}" ] || _z=$(date +%z)
    _sky_offset_seconds "${_z}"
}

# Accepts "now", epoch seconds, YYYY-MM-DD, or ISO-8601 local/zoned text.
_sky_instant() {
    _when="$1"
    _tz="$2"
    case "${_when}" in
        ''|now) date +%s; return 0 ;;
    esac
    # Epoch seconds: digits, optionally signed. Anything else is a date.
    case "${_when}" in
        *[!0-9-]*) _is_epoch=0 ;;
        *-*-*) _is_epoch=0 ;;
        -) _is_epoch=0 ;;
        *) _is_epoch=1 ;;
    esac
    if [ "${_is_epoch}" = "1" ]; then
        printf '%s\n' "${_when}"
        return 0
    fi
    _now=$(date +%s)
    _off=$(sky_offset "${_tz}" "${_now}") || return 1
    _ep=$(_sky_awk -v mode=parse -v text="${_when}" -v off="${_off}" -v now_epoch="${_now}") || return 1
    if [ -n "${_tz}" ]; then
        _off2=$(sky_offset "${_tz}" "${_ep}") || _off2="${_off}"
        if [ "${_off}" != "${_off2}" ]; then
            _ep=$(_sky_awk -v mode=parse -v text="${_when}" -v off="${_off2}" -v now_epoch="${_now}") || return 1
        fi
    fi
    printf '%s\n' "${_ep}"
}

_sky_check_position() {
    _lat="$1"
    _lon="$2"
    case "${_lat}" in ''|*[!0-9.eE+-]*) _sky_die "latitude must be a number" >&2; return 2 ;; esac
    case "${_lon}" in ''|*[!0-9.eE+-]*) _sky_die "longitude must be a number" >&2; return 2 ;; esac
    return 0
}

# ---------------------------------------------------------------------------
# sun, phase, night
# ---------------------------------------------------------------------------

# The zone offset in force at local noon of the date containing EPOCH.
# Solar events are formatted with this offset, because a DST switch happens
# at night while sunrise and sunset do not; using the offset at the input
# instant would shift every event on a transition day.
_sky_sun_offset() {
    _tz="$1"
    _ep="$2"
    _off=$(sky_offset "${_tz}" "${_ep}") || return 1
    _midnight=$(( ((_ep + _off) / 86400) * 86400 - _off ))
    sky_offset "${_tz}" "$((_midnight + 43200))"
}

# Local noon (epoch seconds) of the date containing EPOCH.
_sky_local_noon() {
    _tz="$1"
    _ep="$2"
    _off=$(sky_offset "${_tz}" "${_ep}") || return 1
    printf '%s\n' $(( ((_ep + _off) / 86400) * 86400 - _off + 43200 ))
}

# sky_solar [WHEN] LAT LON [TIMEZONE] -> JSON
sky_solar() {
    _when="${1:-now}"
    _lat="$2"
    _lon="$3"
    _tz="${4:-}"
    _sky_check_position "${_lat}" "${_lon}" || return $?
    _ep=$(_sky_instant "${_when}" "${_tz}") || return $?
    _noon=$(_sky_local_noon "${_tz}" "${_ep}") || return $?
    _off=$(sky_offset "${_tz}" "${_noon}") || return $?
    _sky_awk -v mode=solar -v epoch="${_noon}" -v lat="${_lat}" -v lon="${_lon}" \
        -v off="${_off}" -v tz="${_tz}"
}

# sky_phase [WHEN] LAT LON [TIMEZONE] -> JSON
sky_phase() {
    _when="${1:-now}"
    _lat="$2"
    _lon="$3"
    _tz="${4:-}"
    _sky_check_position "${_lat}" "${_lon}" || return $?
    _ep=$(_sky_instant "${_when}" "${_tz}") || return $?
    _off=$(sky_offset "${_tz}" "${_ep}") || return $?
    _sun_off=$(_sky_sun_offset "${_tz}" "${_ep}") || return $?
    _sky_awk -v mode=phase -v epoch="${_ep}" -v lat="${_lat}" -v lon="${_lon}" \
        -v off="${_off}" -v sun_off="${_sun_off}" -v tz="${_tz}"
}

# sky_position [WHEN] LAT LON [TIMEZONE] -> JSON
sky_position() {
    _when="${1:-now}"
    _lat="$2"
    _lon="$3"
    _tz="${4:-}"
    _sky_check_position "${_lat}" "${_lon}" || return $?
    _ep=$(_sky_instant "${_when}" "${_tz}") || return $?
    _off=$(sky_offset "${_tz}" "${_ep}") || return $?
    _sky_awk -v mode=position -v epoch="${_ep}" -v lat="${_lat}" -v lon="${_lon}" \
        -v off="${_off}" -v tz="${_tz}"
}

# sky_night [WHEN] LAT LON [TIMEZONE] -> JSON (the sunset -> sunrise window)
sky_night() {
    _when="${1:-now}"
    _lat="$2"
    _lon="$3"
    _tz="${4:-}"
    _sky_check_position "${_lat}" "${_lon}" || return $?
    _ep=$(_sky_instant "${_when}" "${_tz}") || return $?
    _off=$(sky_offset "${_tz}" "${_ep}") || return $?
    _sun_off=$(_sky_sun_offset "${_tz}" "${_ep}") || return $?
    _sky_awk -v mode=night -v epoch="${_ep}" -v lat="${_lat}" -v lon="${_lon}" \
        -v off="${_off}" -v sun_off="${_sun_off}" -v tz="${_tz}"
}

# ---------------------------------------------------------------------------
# weather
# ---------------------------------------------------------------------------

_sky_cache_dir() {
    printf '%s\n' "${SKY_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/slopology}"
}

_sky_cache_key() {
    printf 'weather_%s_%s_%s_%s_%s_%s' "$1" "$2" "${3:-metric}" "${4:-7}" "${5:-25}" "${6:-auto}" \
        | tr -c 'A-Za-z0-9._-' '_'
}

_sky_forecast_url() {
    _lat="$1"
    _lon="$2"
    _tz="$3"
    _units="${SKY_UNITS:-metric}"
    _days="${SKY_DAYS:-7}"
    _hours="${SKY_HOURS:-25}"
    _cur="${SKY_CURRENT:-temperature_2m,relative_humidity_2m,apparent_temperature,is_day,precipitation,rain,showers,snowfall,weather_code,cloud_cover,pressure_msl,surface_pressure,wind_speed_10m,wind_direction_10m,wind_gusts_10m,visibility,dew_point_2m,uv_index}"
    _hrl="${SKY_HOURLY:-temperature_2m,apparent_temperature,relative_humidity_2m,dew_point_2m,precipitation_probability,precipitation,rain,showers,snowfall,weather_code,cloud_cover,visibility,wind_speed_10m,wind_direction_10m,wind_gusts_10m,uv_index,is_day,pressure_msl}"
    _dly="${SKY_DAILY:-weather_code,temperature_2m_max,temperature_2m_min,apparent_temperature_max,apparent_temperature_min,sunrise,sunset,daylight_duration,sunshine_duration,uv_index_max,precipitation_sum,rain_sum,showers_sum,snowfall_sum,precipitation_hours,precipitation_probability_max,wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant,shortwave_radiation_sum,et0_fao_evapotranspiration}"
    _url="https://api.open-meteo.com/v1/forecast?latitude=${_lat}&longitude=${_lon}"
    _url="${_url}&current=${_cur}&hourly=${_hrl}&daily=${_dly}"
    _url="${_url}&timezone=${_tz:-auto}&forecast_days=${_days}&forecast_hours=${_hours}&format=csv"
    if [ "${_units}" = "imperial" ]; then
        _url="${_url}&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch"
    fi
    printf '%s\n' "${_url}"
}

_sky_fetch() {
    _url="$1"
    if [ -n "${SKY_FETCH_CMD:-}" ]; then
        sh -c "${SKY_FETCH_CMD}" slopology "${_url}"
        return $?
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 20 -A "slopology/${SKY_VERSION}" "${_url}"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- --timeout=20 --user-agent="slopology/${SKY_VERSION}" "${_url}"
    else
        _sky_die "needs curl or wget, or set SKY_FETCH_CMD"
        return 2
    fi
}

_sky_cache_read() {
    _file="$1"
    _at="$2"
    _max="$3"
    [ -f "${_file}" ] || return 1
    [ -f "${_at}" ] || return 1
    _stamp=$(cat "${_at}" 2>/dev/null)
    case "${_stamp}" in ''|*[!0-9]*) return 1 ;; esac
    _age=$(( $(date +%s) - _stamp ))
    [ "${_age}" -le "${_max}" ] || return 1
    cat "${_file}"
}

_sky_cache_write() {
    _file="$1"
    _at="$2"
    _dir=$(dirname "${_file}")
    mkdir -p "${_dir}" 2>/dev/null || return 0
    _tmp="${_file}.$$"
    cat > "${_tmp}" 2>/dev/null && mv "${_tmp}" "${_file}" 2>/dev/null
    date +%s > "${_at}.$$" 2>/dev/null && mv "${_at}.$$" "${_at}" 2>/dev/null
    return 0
}

# Latest raw Open-Meteo CSV for a position, honouring the cache settings.
sky_weather_csv() {
    _lat="$1"
    _lon="$2"
    _tz="${3:-${SKY_TZ:-}}"
    _sky_check_position "${_lat}" "${_lon}" || return $?

    _units="${SKY_UNITS:-metric}"
    _days="${SKY_DAYS:-7}"
    _hours="${SKY_HOURS:-25}"
    _max="${SKY_MAX_AGE:-900}"
    _key=$(_sky_cache_key "${_lat}" "${_lon}" "${_units}" "${_days}" "${_hours}" "${_tz:-auto}")
    _dir=$(_sky_cache_dir)
    _file="${_dir}/${_key}.csv"
    _at="${_dir}/${_key}.at"

    if [ "${SKY_CACHE:-1}" != "0" ] && [ "${SKY_REFRESH:-0}" != "1" ]; then
        if _sky_cache_read "${_file}" "${_at}" "${_max}"; then
            return 0
        fi
    fi

    if [ "${SKY_OFFLINE:-0}" = "1" ]; then
        _sky_die "no cached forecast for ${_lat},${_lon} and offline mode is on"
        return 1
    fi

    _url=$(_sky_forecast_url "${_lat}" "${_lon}" "${_tz}")
    _body=$(_sky_fetch "${_url}") || {
        _sky_die "could not reach the forecast service"
        return 1
    }
    [ -n "${_body}" ] || {
        _sky_die "the forecast service returned nothing"
        return 1
    }

    if [ "${SKY_CACHE:-1}" != "0" ]; then
        printf '%s\n' "${_body}" | _sky_cache_write "${_file}" "${_at}"
    fi
    printf '%s\n' "${_body}"
}

# sky_weather LAT LON [TIMEZONE] -> JSON
sky_weather() {
    _lat="$1"
    _lon="$2"
    _tz="${3:-${SKY_TZ:-}}"
    _csv=$(sky_weather_csv "${_lat}" "${_lon}" "${_tz}") || return $?
    printf '%s\n' "${_csv}" | _sky_awk -v mode=weather -v now="$(date +%s)"
}

# ---------------------------------------------------------------------------
# places
# ---------------------------------------------------------------------------

_sky_urlencode() {
    printf '%s' "$1" | _sky_awk -v mode=urlencode
}

# sky_place SEARCH [COUNT] -> JSON array
sky_place() {
    _query="$1"
    _count="${2:-5}"
    _lang="${SKY_LANG:-en}"
    [ -n "${_query}" ] || { _sky_die "type a town or city first"; return 2; }
    case "${_count}" in ''|*[!0-9]*) _sky_die "count must be a number"; return 2 ;; esac
    _q=$(_sky_urlencode "${_query}")
    _url="https://geocoding-api.open-meteo.com/v1/search?name=${_q}&count=${_count}&language=${_lang}&format=json"
    _body=$(_sky_fetch "${_url}") || {
        _sky_die "could not reach the place lookup"
        return 1
    }
    _flat=$(printf '%s\n' "${_body}" | _sky_awk -v mode=flatten) || return $?
    printf '%s\n' "${_flat}" | _sky_awk -v mode=place
}

# sky_where -> JSON object for the current network position
sky_where() {
    for _url in "https://ipapi.co/json/" "http://ip-api.com/json/"; do
        _body=$(_sky_fetch "${_url}" 2>/dev/null) || continue
        [ -n "${_body}" ] || continue
        _flat=$(printf '%s\n' "${_body}" | _sky_awk -v mode=flatten 2>/dev/null) || continue
        _out=$(printf '%s\n' "${_flat}" | _sky_awk -v mode=ip 2>/dev/null) || continue
        [ -n "${_out}" ] && { printf '%s\n' "${_out}"; return 0; }
    done
    _sky_die "could not detect the location"
    return 1
}

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

# sky_wmo [CODE] [NIGHT] -> JSON
sky_wmo() {
    _code="${1:-}"
    _night="${2:-0}"
    _sky_awk -v mode=wmo -v code="${_code}" -v night="${_night}"
}

# sky_convert VALUE FROM TO -> number
sky_convert() {
    _sky_awk -v mode=convert -v value="$1" -v from="$2" -v to="$3"
}

# sky_in_window NOW FROM TO -> 1 when NOW is inside the minute window
# (an evening start and a morning end runs over midnight)
sky_in_window() {
    _sky_awk -v mode=window -v now="$1" -v from="$2" -v to="$3"
}

# sky_next_edge NOW FROM TO -> the window edge that comes next, in minutes
sky_next_edge() {
    _sky_awk -v mode=edge -v now="$1" -v from="$2" -v to="$3"
}

# sky_json_get PATH reads JSON on stdin and prints one flattened value
sky_json_get() {
    _flat=$(_sky_awk -v mode=flatten) || return $?
    printf '%s\n' "${_flat}" | _sky_awk -v mode=get -v path="$1"
}

# sky_format_minute MINUTES -> HH:MM or h:MM am/pm
sky_format_minute() {
    _m=$((${1:-0} % 1440))
    [ "${_m}" -lt 0 ] && _m=$((_m + 1440))
    _h=$((_m / 60))
    _mm=$((_m % 60))
    if [ "${2:-${SKY_HOUR12:-0}}" = "1" ]; then
        _suffix=am
        [ "${_h}" -ge 12 ] && _suffix=pm
        _h=$((_h % 12))
        [ "${_h}" -eq 0 ] && _h=12
        printf '%d:%02d %s\n' "${_h}" "${_mm}" "${_suffix}"
    else
        printf '%02d:%02d\n' "${_h}" "${_mm}"
    fi
}

# sky_json_pretty is deliberately absent: JSON is the API, not a display
# format. Pipe through jq, python -m json.tool, or the CLI's human output.
