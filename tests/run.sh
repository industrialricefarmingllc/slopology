#!/bin/sh
# slopology tests. No network unless SKY_LIVE=1.
#
#   ./tests/run.sh
#   SKY_LIVE=1 ./tests/run.sh     # also checks the live services

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
BIN="${ROOT}/bin/slopology"
FIX="${ROOT}/tests/fixtures"
SKY_LIB_DIR="${ROOT}/lib"
export SKY_LIB_DIR
SKY_AWK_FILE="${SKY_LIB_DIR}/sky.awk"
export SKY_AWK_FILE
. "${SKY_LIB_DIR}/sky.sh"

PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
}

bad() {
    FAIL=$((FAIL + 1))
    printf 'FAIL  %s\n' "$*" >&2
}

assert_eq() {
    _name="$1"
    _got="$2"
    _want="$3"
    if [ "${_got}" = "${_want}" ]; then ok; else bad "${_name}: want [${_want}] got [${_got}]"; fi
}

assert_near() {
    _name="$1"
    _got="$2"
    _want="$3"
    _tol="$4"
    if LC_ALL=C awk -v a="${_got}" -v b="${_want}" -v t="${_tol}" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= t) }'; then
        ok
    else
        bad "${_name}: want ${_want} ±${_tol} got ${_got}"
    fi
}

assert_contains() {
    _name="$1"
    _hay="$2"
    _needle="$3"
    case "${_hay}" in
        *"${_needle}"*) ok ;;
        *) bad "${_name}: [${_needle}] not in [${_hay}]" ;;
    esac
}

assert_status() {
    _name="$1"
    _want="$2"
    shift 2
    "$@" >/dev/null 2>&1
    _st=$?
    assert_eq "${_name} status" "${_st}" "${_want}"
}

get() {
    printf '%s\n' "$1" | sky_json_get "$2"
}

parse() {
    _sky_awk -v mode=parse -v text="$1" -v off="${2:-0}" -v now_epoch=0
}

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t slopology)
trap 'rm -rf "${TMP}"' EXIT INT TERM

# ---------------------------------------------------------------------------
printf '\ncalendar\n'
# ---------------------------------------------------------------------------

assert_eq "epoch origin" "$(parse 1970-01-01 0)" "0"
assert_eq "epoch 2000" "$(parse 2000-01-01 0)" "946684800"
assert_eq "epoch before origin" "$(parse 1969-12-31 0)" "-86400"
assert_eq "local date with offset" "$(parse 2024-06-21T23:00 7200)" "1719003600"
assert_eq "zulu suffix" "$(parse 2024-06-21T23:00Z 3600)" "1719010800"
assert_eq "explicit offset" "$(parse 2024-06-21T23:00+02:00 0)" "1719003600"
assert_eq "space separator" "$(parse '2024-06-21 12:00' 0)" "1718971200"
assert_eq "date only is local midnight" "$(parse 2024-06-21 7200)" "1718920800"
assert_eq "version matches VERSION" "$(sky_version)" "$(cat "${ROOT}/VERSION")"

# ---------------------------------------------------------------------------
printf 'time zones\n'
# ---------------------------------------------------------------------------

assert_eq "Paris winter offset" "$(sky_offset Europe/Paris 1700000000)" "3600"
assert_eq "Paris summer offset" "$(sky_offset Europe/Paris 1719007200)" "7200"
assert_eq "New York winter" "$(sky_offset America/New_York 1700000000)" "-18000"
assert_eq "New York summer" "$(sky_offset America/New_York 1719007200)" "-14400"
assert_eq "Kathmandu quarter hour" "$(sky_offset Asia/Kathmandu 1719007200)" "20700"
assert_eq "fixed +05:30" "$(sky_offset +05:30 0)" "19800"
assert_eq "fixed -0400" "$(sky_offset -0400 0)" "-14400"
assert_eq "UTC" "$(sky_offset UTC 0)" "0"

# ---------------------------------------------------------------------------
printf 'solar times\n'
# ---------------------------------------------------------------------------

PARIS=$(sky_solar 2024-06-21 48.8566 2.3522 Europe/Paris)
assert_near "Paris sunrise 05:47" "$(get "${PARIS}" sunrise.minute)" "347" "3"
assert_near "Paris sunset 21:58" "$(get "${PARIS}" sunset.minute)" "1317" "3"
assert_near "Paris day length" "$(get "${PARIS}" day_length_seconds)" "58248" "180"
assert_near "Paris declination" "$(get "${PARIS}" declination)" "23.4376" "0.02"
assert_eq "Paris date" "$(get "${PARIS}" date)" "2024-06-21"
assert_eq "Paris weekday" "$(get "${PARIS}" weekday)" "Friday"
assert_eq "Paris civil dawn present" "$(get "${PARIS}" twilight.civil.dawn.minute)" "304"
assert_eq "Paris astronomical dawn absent" "$(get "${PARIS}" twilight.astronomical.dawn)" "null"

SYDNEY=$(sky_solar 2024-12-21 -33.8688 151.2093 Australia/Sydney)
assert_near "Sydney sunrise 05:41" "$(get "${SYDNEY}" sunrise.minute)" "341" "4"
assert_near "Sydney sunset 20:05" "$(get "${SYDNEY}" sunset.minute)" "1205" "4"

REYKJAVIK=$(sky_solar 2024-06-21 64.1466 -21.9426 Atlantic/Reykjavik)
assert_near "Reykjavik sunrise 02:55" "$(get "${REYKJAVIK}" sunrise.minute)" "175" "4"
assert_near "Reykjavik sunset 00:04" "$(get "${REYKJAVIK}" sunset.minute)" "4" "4"
assert_near "Reykjavik day length 21h08" "$(get "${REYKJAVIK}" day_length_seconds)" "76121" "300"

QUITO=$(sky_solar 2024-03-20 -0.1807 -78.4678 America/Guayaquil)
assert_near "equator day length 12h07" "$(get "${QUITO}" day_length_seconds)" "43599" "300"

TROMSO_SUMMER=$(sky_solar 2024-06-21 69.6492 18.9553 Europe/Oslo)
assert_eq "Tromso midnight sun" "$(get "${TROMSO_SUMMER}" polar)" "midnight-sun"
assert_eq "Tromso midnight sun length" "$(get "${TROMSO_SUMMER}" day_length_seconds)" "86400"
assert_eq "Tromso no sunrise" "$(get "${TROMSO_SUMMER}" sunrise)" "null"

TROMSO_WINTER=$(sky_solar 2024-12-21 69.6492 18.9553 Europe/Oslo)
assert_eq "Tromso polar night" "$(get "${TROMSO_WINTER}" polar)" "polar-night"
assert_eq "Tromso polar night length" "$(get "${TROMSO_WINTER}" day_length_seconds)" "0"

# civil twilight exists even though the sun never rises
_tromso_civil=$(get "${TROMSO_WINTER}" twilight.civil.dawn.minute)
case "${_tromso_civil}" in ''|null) bad "Tromso civil dawn should exist, got [${_tromso_civil}]" ;; *) ok ;; esac

# DST is reflected in the JSON
WINTER=$(sky_solar 2024-01-15 48.8566 2.3522 Europe/Paris)
SUMMER=$(sky_solar 2024-07-15 48.8566 2.3522 Europe/Paris)
assert_eq "winter offset in solar JSON" "$(get "${WINTER}" utc_offset_seconds)" "3600"
assert_eq "summer offset in solar JSON" "$(get "${SUMMER}" utc_offset_seconds)" "7200"

# On a transition day the events use the post-switch offset while the phase
# instant uses the offset in force at that instant.
SPRING_DAY=$(sky_phase 2024-03-31T01:30 48.8566 2.3522 Europe/Paris)
assert_eq "spring phase offset" "$(get "${SPRING_DAY}" utc_offset_seconds)" "3600"
assert_contains "spring sunrise uses summer time" "$(get "${SPRING_DAY}" sun.sunrise.iso)" "+02:00"
AUTUMN_DAY=$(sky_solar 2024-10-27 48.8566 2.3522 Europe/Paris)
assert_eq "autumn date survives the switch" "$(get "${AUTUMN_DAY}" date)" "2024-10-27"
assert_eq "autumn offset in solar JSON" "$(get "${AUTUMN_DAY}" utc_offset_seconds)" "3600"

# ---------------------------------------------------------------------------
printf 'position and phase\n'
# ---------------------------------------------------------------------------

POS=$(sky_position 2024-06-21T13:52:30 48.8566 2.3522 Europe/Paris)
assert_near "Paris noon elevation" "$(get "${POS}" elevation)" "64.58" "0.6"
assert_near "equation of time 3 Nov" \
    "$(get "$(sky_position 2024-11-03T12:00:00Z 0 0 UTC)" equation_of_time_minutes)" "16.49" "0.5"
assert_near "equation of time 11 Feb" \
    "$(get "$(sky_position 2024-02-11T12:00:00Z 0 0 UTC)" equation_of_time_minutes)" "-14.23" "0.5"

PHASE_DAY=$(sky_phase 2024-06-21T14:00 48.8566 2.3522 Europe/Paris)
assert_eq "afternoon phase" "$(get "${PHASE_DAY}" phase)" "day"
assert_eq "afternoon is day" "$(get "${PHASE_DAY}" is_day)" "true"
assert_eq "afternoon next event present" "$(get "${PHASE_DAY}" next.event)" "golden_hour_evening_start"

PHASE_DUSK=$(sky_phase 2024-06-21T23:00 48.8566 2.3522 Europe/Paris)
assert_eq "late evening phase" "$(get "${PHASE_DUSK}" phase)" "dusk"
assert_eq "late evening twilight" "$(get "${PHASE_DUSK}" twilight)" "nautical"
assert_eq "late evening is dark" "$(get "${PHASE_DUSK}" is_dark)" "true"
assert_eq "late evening next" "$(get "${PHASE_DUSK}" next.event)" "nautical_dusk"
assert_eq "upcoming starts with next" "$(get "${PHASE_DUSK}" upcoming.0.event)" "nautical_dusk"
assert_eq "embedded solar day" "$(get "${PHASE_DUSK}" sun.date)" "2024-06-21"

PHASE_NIGHT=$(sky_phase 2024-12-21T23:00 48.8566 2.3522 Europe/Paris)
assert_eq "winter night phase" "$(get "${PHASE_NIGHT}" phase)" "night"
assert_eq "winter night flag" "$(get "${PHASE_NIGHT}" is_night)" "true"

PHASE_POLAR=$(sky_phase 2024-06-21T23:00 69.6492 18.9553 Europe/Oslo)
assert_eq "midnight sun at 23:00" "$(get "${PHASE_POLAR}" is_day)" "true"

# ---------------------------------------------------------------------------
printf 'night window\n'
# ---------------------------------------------------------------------------

NIGHT=$(sky_night 2024-06-21T23:00 48.8566 2.3522 Europe/Paris)
assert_eq "night active" "$(get "${NIGHT}" active)" "true"
assert_eq "night start minute" "$(get "${NIGHT}" start_minute)" "1317"
assert_eq "night end minute" "$(get "${NIGHT}" end_minute)" "347"
assert_near "night duration" "$(get "${NIGHT}" duration_seconds)" "28170" "180"

NIGHT_POLAR=$(sky_night 2024-06-21T23:00 69.6492 18.9553 Europe/Oslo)
assert_eq "midnight sun has no night" "$(get "${NIGHT_POLAR}" polar)" "midnight-sun"
assert_eq "midnight sun not active" "$(get "${NIGHT_POLAR}" active)" "false"

# ---------------------------------------------------------------------------
printf 'weather\n'
# ---------------------------------------------------------------------------

CSV_FIXTURE="${FIX}/weather-paris.csv"
SKY_FETCH_CMD="cat ${CSV_FIXTURE}"
export SKY_FETCH_CMD
SKY_CACHE=0
export SKY_CACHE

WEATHER=$(sky_weather 48.85 2.35 Europe/Paris)
assert_eq "weather provider" "$(get "${WEATHER}" provider)" "open-meteo"
assert_eq "weather timezone" "$(get "${WEATHER}" timezone)" "Europe/Paris"
assert_eq "weather temp" "$(get "${WEATHER}" current.temperature)" "7.2"
assert_eq "weather description" "$(get "${WEATHER}" current.description)" "Slight rain"
assert_eq "weather kind" "$(get "${WEATHER}" current.kind)" "rain"
assert_eq "weather wind compass" "$(get "${WEATHER}" current.wind_compass)" "SW"
assert_eq "weather is_day" "$(get "${WEATHER}" current.is_day)" "false"
assert_eq "weather unit" "$(get "${WEATHER}" units.temperature)" "°C"
assert_eq "hourly rows" "$(get "${WEATHER}" hourly.3.time)" "2026-11-15T05:00"
assert_eq "daily rows" "$(get "${WEATHER}" daily.2.date)" "2026-11-17"
assert_eq "daily sunrise" "$(get "${WEATHER}" daily.0.sunrise.minute)" "479"
assert_eq "daily sunset" "$(get "${WEATHER}" daily.0.sunset.minute)" "1030"
assert_eq "daily high" "$(get "${WEATHER}" daily.0.temperature_max)" "12.8"
assert_eq "daily rain chance" "$(get "${WEATHER}" daily.0.precipitation_probability_max)" "78"
assert_eq "uv is a number" "$(get "${WEATHER}" current.uv_index)" "0.00"

# the raw CSV stays available
_raw=$(sky_weather_csv 48.85 2.35 Europe/Paris)
assert_contains "raw csv latitude header" "${_raw}" "latitude,longitude,elevation"

# imperial is a request option and shows up in the URL
SKY_UNITS=imperial
_imperial_url=$(_sky_forecast_url 48.85 2.35 Europe/Paris)
assert_contains "imperial temperature unit" "${_imperial_url}" "temperature_unit=fahrenheit"
assert_contains "imperial wind unit" "${_imperial_url}" "wind_speed_unit=mph"
assert_contains "imperial rain unit" "${_imperial_url}" "precipitation_unit=inch"
SKY_UNITS=metric

# cache: second read must work with the network taken away
CACHE_DIR="${TMP}/cache"
SKY_CACHE=1
SKY_CACHE_DIR="${CACHE_DIR}"
export SKY_CACHE SKY_CACHE_DIR
SKY_FETCH_CMD="cat ${CSV_FIXTURE}"
_weather_a=$(sky_weather 48.85 2.35 Europe/Paris)
SKY_FETCH_CMD="false"
_weather_b=$(sky_weather 48.85 2.35 Europe/Paris)
assert_eq "cache serves the forecast offline" \
    "$(get "${_weather_b}" current.temperature)" "$(get "${_weather_a}" current.temperature)"

(
    SKY_CACHE=0
    SKY_FETCH_CMD=false
    sky_weather 48.85 2.35 Europe/Paris >/dev/null 2>&1
)
assert_eq "missing cache fails with the network down" "$?" "1"

SKY_CACHE=0
export SKY_CACHE

# ---------------------------------------------------------------------------
printf 'WMO codes\n'
# ---------------------------------------------------------------------------

assert_eq "wmo 0 day" "$(get "$(sky_wmo 0)" kind)" "clear"
assert_eq "wmo 0 night" "$(get "$(sky_wmo 0 1)" kind)" "clear-night"
assert_eq "wmo 2 night" "$(get "$(sky_wmo 2 1)" kind)" "partly-night"
assert_eq "wmo 3" "$(get "$(sky_wmo 3)" kind)" "cloud"
assert_eq "wmo 45" "$(get "$(sky_wmo 45)" kind)" "fog"
assert_eq "wmo 61" "$(get "$(sky_wmo 61)" description)" "Slight rain"
assert_eq "wmo 71" "$(get "$(sky_wmo 71)" kind)" "snow"
assert_eq "wmo 95" "$(get "$(sky_wmo 95)" kind)" "storm"
assert_eq "wmo 99" "$(get "$(sky_wmo 99)" description)" "Thunderstorm with heavy hail"
assert_eq "wmo table size" "$(printf '%s\n' "$(sky_wmo)" | _sky_awk -v mode=flatten | _sky_awk -v mode=get -v path=27.code)" "99"

# ---------------------------------------------------------------------------
printf 'units and windows\n'
# ---------------------------------------------------------------------------

assert_eq "c to f" "$(sky_convert 20 c f)" "68"
assert_eq "f to c" "$(sky_convert 32 f c)" "0"
assert_near "kmh to mph" "$(sky_convert 100 kmh mph)" "62.137119" "0.0001"
assert_eq "mm to in" "$(sky_convert 25.4 mm in)" "1"
assert_near "hpa to inhg" "$(sky_convert 1013.25 hpa inhg)" "29.921" "0.01"

assert_eq "window inside evening" "$(sky_in_window 1380 1200 420)" "1"
assert_eq "window after midnight" "$(sky_in_window 60 1200 420)" "1"
assert_eq "window outside" "$(sky_in_window 600 1200 420)" "0"
assert_eq "window empty" "$(sky_in_window 1380 1200 1200)" "0"
assert_eq "next edge is sunrise" "$(sky_next_edge 1380 1200 420)" "420"
assert_eq "next edge is sunset" "$(sky_next_edge 600 1200 420)" "1200"

assert_eq "format minute" "$(sky_format_minute 347)" "05:47"
assert_eq "format minute 12h" "$(sky_format_minute 1317 1)" "9:57 pm"

# ---------------------------------------------------------------------------
printf 'places\n'
# ---------------------------------------------------------------------------

GEO="${FIX}/geocode-paris.json"
SKY_FETCH_CMD="cat ${GEO}"
PLACES=$(sky_place Paris 2)
assert_eq "place count" "$(get "${PLACES}" 1.name)" "Paris"
assert_eq "place label" "$(get "${PLACES}" 0.label)" "Paris, Île-de-France Region, France"
assert_eq "place latitude" "$(get "${PLACES}" 0.latitude)" "48.85341"
assert_eq "place timezone" "$(get "${PLACES}" 0.timezone)" "Europe/Paris"
assert_eq "place second result" "$(get "${PLACES}" 1.country)" "United States"

SKY_FETCH_CMD="cat ${FIX}/ip-paris.json"
WHERE=$(sky_where)
assert_eq "where latitude" "$(get "${WHERE}" latitude)" "48.85341"
assert_eq "where label" "$(get "${WHERE}" label)" "Paris, IDF, France"
assert_eq "where timezone" "$(get "${WHERE}" timezone)" "Europe/Paris"

assert_eq "urlencode" "$(_sky_urlencode 'Paris, Île-de-France & co')" \
    "Paris%2C%20%C3%8Ele-de-France%20%26%20co"

# ---------------------------------------------------------------------------
printf 'JSON reader\n'
# ---------------------------------------------------------------------------

FLAT=$(printf '%s' '{"a":{"b":"x\ty","c":[1,2,{"d":null}]}}' | _sky_awk -v mode=flatten)
assert_eq "flatten string" "$(printf '%s\n' "${FLAT}" | _sky_awk -v mode=get -v path=a.b)" "x	y"
assert_eq "flatten array" "$(printf '%s\n' "${FLAT}" | _sky_awk -v mode=get -v path=a.c.1)" "2"
assert_eq "flatten null" "$(printf '%s\n' "${FLAT}" | _sky_awk -v mode=get -v path=a.c.2.d)" "null"
assert_status "get missing path" "1" sh -c "printf '%s' '{\"a\":1}' | '${SKY_AWK}' -f '${SKY_AWK_FILE}' -v mode=flatten | '${SKY_AWK}' -f '${SKY_AWK_FILE}' -v mode=get -v path=nope"

# ---------------------------------------------------------------------------
printf 'cli\n'
# ---------------------------------------------------------------------------

SKY_FETCH_CMD="cat ${CSV_FIXTURE}"
export SKY_FETCH_CMD

"${BIN}" --version >/dev/null 2>&1
assert_eq "cli version status" "$?" "0"
"${BIN}" --help >"${TMP}/help" 2>&1
assert_contains "cli help" "$(cat "${TMP}/help")" "usage: slopology"

_sun_json=$("${BIN}" sun --lat 48.8566 --lon 2.3522 --tz Europe/Paris --date 2024-06-21 --json)
assert_eq "cli sun json sunrise" "$(get "${_sun_json}" sunrise.minute)" "347"

_phase_text=$("${BIN}" phase --lat 48.8566 --lon 2.3522 --tz Europe/Paris --date 2024-06-21T23:00)
assert_contains "cli phase text" "${_phase_text}" "dusk"

_weather_text=$("${BIN}" weather --lat 48.85 --lon 2.35 --tz Europe/Paris --no-cache)
assert_contains "cli weather text" "${_weather_text}" "Slight rain"
assert_contains "cli weather forecast" "${_weather_text}" "12.8"

_csv=$("${BIN}" weather --lat 48.85 --lon 2.35 --tz Europe/Paris --no-cache --csv)
assert_contains "cli csv" "${_csv}" "time,temperature_2m"

_place_text=$(SKY_FETCH_CMD="cat ${GEO}" "${BIN}" place Paris --count 1)
assert_contains "cli place text" "${_place_text}" "Paris, Île-de-France Region, France"

_now_json=$(SKY_FETCH_CMD="cat ${CSV_FIXTURE}" "${BIN}" now --lat 48.85 --lon 2.35 --tz Europe/Paris --json --no-cache)
assert_eq "cli now place lat" "$(get "${_now_json}" place.latitude)" "48.85"
assert_eq "cli now weather temp" "$(get "${_now_json}" weather.current.temperature)" "7.2"

assert_status "cli unknown command" "2" "${BIN}" nonsense
assert_status "cli bad units" "2" "${BIN}" sun --units kelvin --lat 0 --lon 0

# ---------------------------------------------------------------------------
printf 'live services\n'
# ---------------------------------------------------------------------------

if [ "${SKY_LIVE:-0}" = "1" ]; then
    _live=$(SKY_FETCH_CMD= "${BIN}" sun --place Tokyo --json)
    case "$(get "${_live}" sunrise.minute)" in
        ''|null|*[!0-9]*) bad "live geocode/solar" ;;
        *) ok ;;
    esac
    _livew=$(SKY_FETCH_CMD= "${BIN}" weather --place Tokyo --no-cache --json)
    case "$(get "${_livew}" current.temperature)" in
        ''|null|*[!0-9.-]*) bad "live weather" ;;
        *) ok ;;
    esac
else
    printf '  skipped (set SKY_LIVE=1 to run)\n'
fi

# ---------------------------------------------------------------------------

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
