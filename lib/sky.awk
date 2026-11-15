# slopology core — daylight, twilight, solar position and weather.
# Plain POSIX awk: no gawk extensions, no external commands, no network.
#
# The shell library (lib/sky.sh) fills in `mode` and the inputs; every mode
# prints one JSON document on stdout. Errors go to stderr and exit 3.
#
# Modes:
#   parse      ISO-8601 local text            -> epoch seconds
#   solar      epoch lat lon off              -> solar day (events, twilights)
#   position   epoch lat lon                  -> sun elevation / azimuth
#   phase      epoch lat lon off              -> day/night phase + next event
#   night      epoch lat lon off              -> sunset -> sunrise window
#   weather    Open-Meteo CSV on stdin        -> normalised forecast
#   flatten    JSON on stdin                  -> path<TAB>value lines
#   get        path<TAB>value on stdin        -> one value
#   place      flattened geocoder JSON        -> place array
#   ip         flattened IP lookup JSON       -> place object
#   wmo        code (optional)                -> description / kind / table
#   convert    value from to                  -> number
#   window     now from to (minutes)          -> 1 or 0
#   edge       now from to (minutes)          -> next edge in minutes
#   urlencode  text on stdin                  -> percent-encoded text

BEGIN {
    RAD = 3.141592653589793 / 180
    DEG = 1 / RAD
    PI = 3.141592653589793
    for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
    if (mode == "")
        mode = "solar"
    if (sun_off == "")
        sun_off = off
    if (mode != "weather" && mode != "flatten" && mode != "place" && mode != "ip" && mode != "get" && mode != "urlencode") {
        run_mode()
        exit 0
    }
}

{ LINES[++LN] = $0 }

END {
    if (mode == "weather" || mode == "flatten" || mode == "place" || mode == "ip" || mode == "get" || mode == "urlencode")
        run_mode()
}

# ---------------------------------------------------------------------------
# scalar helpers
# ---------------------------------------------------------------------------

function abs_(x) { return x < 0 ? -x : x }
function round_(x) { return x >= 0 ? int(x + 0.5) : -int(-x + 0.5) }
function clamp_(x, lo, hi) { return x < lo ? lo : (x > hi ? hi : x) }

function fdiv(a, b,   q) {
    q = int(a / b)
    if (q * b != a && ((a < 0) != (b < 0)))
        q--
    return q
}

function mod_(a, n) { return a - n * fdiv(a, n) }

function acos_(x) {
    x = clamp_(x, -1, 1)
    if (x >= 1) return 0
    if (x <= -1) return PI
    return atan2(sqrt(1 - x * x), x)
}

function asin_(x) {
    x = clamp_(x, -1, 1)
    if (x >= 1) return PI / 2
    if (x <= -1) return -PI / 2
    return atan2(x, sqrt(1 - x * x))
}

function trim_(s) {
    sub(/^[ \t\r\n]+/, "", s)
    sub(/[ \t\r\n]+$/, "", s)
    return s
}

function jesc(s,   out, i, n, c) {
    out = ""
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\") out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else if (c == "\n") out = out "\\n"
        else if (c == "\r") out = out "\\r"
        else if (c == "\t") out = out "\\t"
        else if (c < " ") out = out " "
        else out = out c
    }
    return out
}

function fail(msg) {
    print "slopology: " msg > "/dev/stderr"
    failed = 1
    exit 3
}

function isnum(s) {
    return s ~ /^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/
}

function num_or_null(s) {
    s = trim_(s)
    if (s == "" || !isnum(s)) return "null"
    return s
}

function str_or_null(s) {
    s = trim_(s)
    if (s == "") return "null"
    return "\"" jesc(s) "\""
}

# ---------------------------------------------------------------------------
# civil calendar (Howard Hinnant's algorithms, floor division)
# ---------------------------------------------------------------------------

function days_from_civil(y, m, d,   era, yoe, doy, doe) {
    y -= (m <= 2)
    if (y >= 0) era = fdiv(y, 400)
    else era = fdiv(y - 399, 400)
    yoe = y - era * 400
    doy = fdiv(153 * (m + (m > 2 ? -3 : 9)) + 2, 5) + d - 1
    doe = yoe * 365 + fdiv(yoe, 4) - fdiv(yoe, 100) + doy
    return era * 146097 + doe - 719468
}

function civil_from_days(z,   era, doe, yoe, y, doy, mp, d, m) {
    z += 719468
    if (z >= 0) era = fdiv(z, 146097)
    else era = fdiv(z - 146096, 146097)
    doe = z - era * 146097
    yoe = fdiv(doe - fdiv(doe, 1460) + fdiv(doe, 36524) - fdiv(doe, 146096), 365)
    y = yoe + era * 400
    doy = doe - (365 * yoe + fdiv(yoe, 4) - fdiv(yoe, 100))
    mp = fdiv(5 * doy + 2, 153)
    d = doy - fdiv(153 * mp + 2, 5) + 1
    m = mp + (mp < 10 ? 3 : -9)
    y += (m <= 2)
    CY = y; CM = m; CD = d
}

function weekday_from_days(z) { return mod_(z + 4, 7) } # 0 = Sunday
function weekday_name(z,   names, parts) {
    names = "Sunday Monday Tuesday Wednesday Thursday Friday Saturday"
    split(names, parts, " ")
    return parts[weekday_from_days(z) + 1]
}
function weekday_short(z,   names, parts) {
    names = "Sun Mon Tue Wed Thu Fri Sat"
    split(names, parts, " ")
    return parts[weekday_from_days(z) + 1]
}

function off_string(off,   s, a, h, m) {
    s = off < 0 ? "-" : "+"
    a = abs_(off)
    h = int(a / 3600)
    m = int((a - h * 3600) / 60)
    return sprintf("%s%02d:%02d", s, h, m)
}

function iso_local(epoch, off,   local, days, secs, hh, mm, ss) {
    local = round_(epoch) + off
    days = fdiv(local, 86400)
    secs = local - days * 86400
    civil_from_days(days)
    hh = int(secs / 3600); secs -= hh * 3600
    mm = int(secs / 60); ss = secs - mm * 60
    if (ss >= 60) { ss -= 60; mm++ }
    if (mm >= 60) { mm -= 60; hh++ }
    if (hh >= 24) { hh -= 24; days++; civil_from_days(days) }
    return sprintf("%04d-%02d-%02dT%02d:%02d:%02d%s", CY, CM, CD, hh, mm, ss, off_string(off))
}

function date_local(epoch, off,   days) {
    days = fdiv(round_(epoch) + off, 86400)
    civil_from_days(days)
    return sprintf("%04d-%02d-%02d", CY, CM, CD)
}

function minute_local(epoch, off,   secs) {
    secs = mod_(round_(epoch) + off, 86400)
    return mod_(int(secs / 60), 1440)
}

function clock_local(epoch, off, hour12,   m, h, suffix) {
    m = minute_local(epoch, off)
    h = int(m / 60)
    m = m % 60
    if (hour12) {
        suffix = h < 12 ? "am" : "pm"
        h = h % 12
        if (h == 0) h = 12
        return sprintf("%d:%02d %s", h, m, suffix)
    }
    return sprintf("%02d:%02d", h, m)
}

function event_json(epoch, off,   m) {
    if (epoch == "")
        return "null"
    m = minute_local(epoch, off)
    return "{\"at\":" round_(epoch) ",\"iso\":\"" iso_local(epoch, off) "\",\"minute\":" m "}"
}

function off_parse(zp,   sign, digits) {
    sign = substr(zp, 1, 1) == "-" ? -1 : 1
    digits = zp
    gsub(/[:+-]/, "", digits)
    if (length(digits) == 4)
        return sign * (substr(digits, 1, 2) * 3600 + substr(digits, 3, 2) * 60)
    if (length(digits) == 2)
        return sign * substr(digits, 1, 2) * 3600
    return 0
}

function parse_iso(text, base_off,   t, dt, ymd, hms, y, m, d, hh, mm, ss, tail) {
    t = trim_(text)
    if (t == "now")
        return now_epoch + 0
    if (t ~ /^-?[0-9]+$/)
        return t + 0
    if (t ~ /[Zz]$/) {
        base_off = 0
        t = substr(t, 1, length(t) - 1)
    } else if (match(t, /[+-][0-9][0-9]:[0-9][0-9]$/)) {
        tail = substr(t, RSTART)
        base_off = off_parse(tail)
        t = substr(t, 1, RSTART - 1)
    } else if (match(t, /[+-][0-9][0-9][0-9][0-9]$/)) {
        tail = substr(t, RSTART)
        base_off = off_parse(tail)
        t = substr(t, 1, RSTART - 1)
    }
    if (index(t, "T") > 0) {
        split(t, dt, "T")
    } else if (index(t, " ") > 0) {
        split(t, dt, " ")
    } else {
        dt[1] = t
        dt[2] = ""
    }
    split(dt[1], ymd, "-")
    y = ymd[1] + 0
    m = ymd[2] + 0
    d = ymd[3] + 0
    hh = 0; mm = 0; ss = 0
    if (dt[2] != "") {
        split(dt[2], hms, ":")
        hh = hms[1] + 0
        mm = hms[2] + 0
        if (hms[3] != "") ss = hms[3] + 0
    }
    if (m < 1 || m > 12 || d < 1 || d > 31 || hh > 23 || mm > 59 || ss > 60)
        fail("not a date: " text)
    return days_from_civil(y, m, d) * 86400 + hh * 3600 + mm * 60 + ss - base_off
}

# ---------------------------------------------------------------------------
# NOAA solar position
# ---------------------------------------------------------------------------

function tan_(x) { return sin(x) / cos(x) }

function solar_params(epoch,   jd, T, L0, M, e, C, trueLong, omega, appLong, meanObliq, obliq, y, eq) {
    jd = epoch / 86400 + 2440587.5
    T = (jd - 2451545.0) / 36525
    L0 = mod_(280.46646 + T * (36000.76983 + T * 0.0003032), 360)
    M = 357.52911 + T * (35999.05029 - 0.0001537 * T)
    e = 0.016708634 - T * (0.000042037 + 0.0000001267 * T)
    C = sin(M * RAD) * (1.914602 - T * (0.004817 + 0.000014 * T)) \
      + sin(2 * M * RAD) * (0.019993 - 0.000101 * T) \
      + sin(3 * M * RAD) * 0.000289
    trueLong = L0 + C
    omega = 125.04 - 1934.136 * T
    appLong = trueLong - 0.00569 - 0.00478 * sin(omega * RAD)
    meanObliq = 23 + (26 + (21.448 - T * (46.815 + T * (0.00059 - T * 0.001813))) / 60) / 60
    obliq = meanObliq + 0.00256 * cos(omega * RAD)
    SP_DECL = asin_(sin(obliq * RAD) * sin(appLong * RAD)) * DEG
    y = (tan_(obliq * RAD / 2)) ^ 2
    eq = 4 * DEG * ( y * sin(2 * L0 * RAD) \
         - 2 * e * sin(M * RAD) \
         + 4 * e * y * sin(M * RAD) * cos(2 * L0 * RAD) \
         - 0.5 * y * y * sin(4 * L0 * RAD) \
         - 1.25 * e * e * sin(2 * M * RAD) )
    SP_EQ = eq
    SP_L0 = L0
    SP_M = M
    SP_T = T
}

function solar_position(epoch, lat, lon,   minutes, tst, ha, cosz, zen, az, ca, denom) {
    solar_params(epoch)
    minutes = mod_(epoch, 86400) / 60
    tst = mod_(minutes + SP_EQ + 4 * lon, 1440)
    ha = tst / 4 - 180
    if (ha < -180) ha += 360
    cosz = sin(lat * RAD) * sin(SP_DECL * RAD) + cos(lat * RAD) * cos(SP_DECL * RAD) * cos(ha * RAD)
    cosz = clamp_(cosz, -1, 1)
    zen = acos_(cosz) * DEG
    denom = cos(lat * RAD) * sin(zen * RAD)
    if (abs_(denom) < 1e-12) {
        az = 0
    } else {
        ca = clamp_((sin(lat * RAD) * cos(zen * RAD) - sin(SP_DECL * RAD)) / denom, -1, 1)
        if (ha > 0) az = mod_(acos_(ca) * DEG + 180, 360)
        else az = mod_(540 - acos_(ca) * DEG, 360)
    }
    POS_ELEV = 90 - zen
    POS_ZEN = zen
    POS_AZ = az
    POS_HA = ha
}

# A pair of rise/set instants for one zenith. PAIR_STATE tells how the day
# behaves when the sun never crosses that altitude:
#   ok | above (always higher) | below (always lower)
function pair(zenith, lat, lon, noonEpoch,   utcDayStart, cosH, den, ha, elev) {
    PAIR_RISE = ""
    PAIR_SET = ""
    PAIR_STATE = "ok"
    solar_params(noonEpoch)
    utcDayStart = fdiv(noonEpoch, 86400) * 86400
    den = cos(lat * RAD) * cos(SP_DECL * RAD)
    elev = 90 - zenith
    if (abs_(den) < 1e-12) {
        solar_position(noonEpoch, lat, lon)
        PAIR_STATE = POS_ELEV > elev ? "above" : "below"
        return 0
    }
    cosH = (cos(zenith * RAD) - sin(lat * RAD) * sin(SP_DECL * RAD)) / den
    if (cosH > 1) { PAIR_STATE = "below"; return 0 }
    if (cosH < -1) { PAIR_STATE = "above"; return 0 }
    ha = acos_(cosH) * DEG
    PAIR_RISE = utcDayStart + (720 - 4 * (lon + ha) - SP_EQ) * 60
    PAIR_SET  = utcDayStart + (720 - 4 * (lon - ha) - SP_EQ) * 60
    return 1
}

function add_event(name, epoch) {
    if (epoch == "")
        return
    EV_N++
    EV_NAME[EV_N] = name
    EV_EP[EV_N] = epoch
}

# Fills EV_NAME/EV_EP in chronological order for the local day whose solar
# noon is at noonEpoch.
function build_day(noonEpoch, lat, lon,   a, b, c, d, e, f, g, h) {
    EV_N = 0

    if (pair(108, lat, lon, noonEpoch)) add_event("astronomical_dawn", PAIR_RISE)
    if (pair(102, lat, lon, noonEpoch)) add_event("nautical_dawn", PAIR_RISE)
    if (pair(96,  lat, lon, noonEpoch)) add_event("civil_dawn", PAIR_RISE)
    if (pair(94,  lat, lon, noonEpoch)) add_event("blue_hour_morning_end", PAIR_RISE)
    if (pair(90.833, lat, lon, noonEpoch)) add_event("sunrise", PAIR_RISE)
    if (pair(84, lat, lon, noonEpoch)) add_event("golden_hour_morning_end", PAIR_RISE)

    solar_params(noonEpoch)
    add_event("solar_noon", fdiv(noonEpoch, 86400) * 86400 + (720 - 4 * lon - SP_EQ) * 60)

    if (pair(84, lat, lon, noonEpoch)) add_event("golden_hour_evening_start", PAIR_SET)
    if (pair(90.833, lat, lon, noonEpoch)) add_event("sunset", PAIR_SET)
    if (pair(94,  lat, lon, noonEpoch)) add_event("blue_hour_evening_start", PAIR_SET)
    if (pair(96,  lat, lon, noonEpoch)) add_event("civil_dusk", PAIR_SET)
    if (pair(102, lat, lon, noonEpoch)) add_event("nautical_dusk", PAIR_SET)
    if (pair(108, lat, lon, noonEpoch)) add_event("astronomical_dusk", PAIR_SET)
}

function find_event(name,   i) {
    for (i = 1; i <= EV_N; i++)
        if (EV_NAME[i] == name) return EV_EP[i]
    return ""
}

function find_in(prefix, name,   i) {
    for (i = 1; i <= EVCOUNT[prefix]; i++)
        if (EVNAME[prefix, i] == name) return EVEP[prefix, i]
    return ""
}

function copy_events(prefix,   i) {
    EVCOUNT[prefix] = EV_N
    for (i = 1; i <= EV_N; i++) {
        EVNAME[prefix, i] = EV_NAME[i]
        EVEP[prefix, i] = EV_EP[i]
    }
}

function local_noon(epoch, off,   d) {
    d = fdiv(round_(epoch) + off, 86400)
    return d * 86400 - off + 43200
}

# ---------------------------------------------------------------------------
# modes
# ---------------------------------------------------------------------------

function run_mode() {
    if (mode == "parse") {
        print parse_iso(text, off + 0)
    } else if (mode == "solar") {
        do_solar()
    } else if (mode == "position") {
        do_position()
    } else if (mode == "phase") {
        do_phase()
    } else if (mode == "night") {
        do_night()
    } else if (mode == "weather") {
        do_weather()
    } else if (mode == "flatten") {
        do_flatten()
    } else if (mode == "get") {
        do_get()
    } else if (mode == "place") {
        do_place()
    } else if (mode == "ip") {
        do_ip()
    } else if (mode == "wmo") {
        do_wmo()
    } else if (mode == "convert") {
        do_convert()
    } else if (mode == "window") {
        print in_window(now + 0, from + 0, to + 0)
    } else if (mode == "edge") {
        print next_edge(now + 0, from + 0, to + 0)
    } else if (mode == "urlencode") {
        do_urlencode()
    } else {
        fail("unknown mode: " mode)
    }
}

function do_solar(   noon, offn, rise, set, state, decl, eq, i, j, out, sep, d) {
    if (lat < -90 || lat > 90) fail("latitude out of range")
    if (lon < -180 || lon > 180) fail("longitude out of range")
    noon = local_noon(epoch, off)
    build_day(noon, lat, lon)
    copy_events("t")

    solar_params(noon)
    decl = SP_DECL
    eq = SP_EQ

    pair(90.833, lat, lon, noon)
    rise = PAIR_RISE; set = PAIR_SET; state = PAIR_STATE

    out = "{\"date\":\"" date_local(epoch, off) "\""
    out = out ",\"weekday\":\"" weekday_name(fdiv(epoch + off, 86400)) "\""
    out = out ",\"weekday_short\":\"" weekday_short(fdiv(epoch + off, 86400)) "\""
    out = out ",\"latitude\":" lat ",\"longitude\":" lon
    if (tz != "") out = out ",\"timezone\":\"" jesc(tz) "\""
    out = out ",\"utc_offset_seconds\":" off
    out = out ",\"declination\":" sprintf("%.6f", decl)
    out = out ",\"equation_of_time_minutes\":" sprintf("%.6f", eq)
    out = out ",\"sunrise\":" event_json(rise, off)
    out = out ",\"sunset\":" event_json(set, off)
    out = out ",\"solar_noon\":" event_json(find_event("solar_noon"), off)
    if (state == "above") {
        out = out ",\"day_length_seconds\":86400,\"polar\":\"midnight-sun\""
    } else if (state == "below") {
        out = out ",\"day_length_seconds\":0,\"polar\":\"polar-night\""
    } else {
        d = mod_(set - rise, 86400)
        out = out ",\"day_length_seconds\":" round_(d) ",\"polar\":null"
    }

    out = out ",\"events\":{"
    sep = ""
    for (i = 1; i <= EVCOUNT["t"]; i++) {
        out = out sep "\"" EVNAME["t", i] "\":" event_json(EVEP["t", i], off)
        sep = ","
    }
    out = out "}"

    out = out ",\"twilight\":{"
    out = out "\"civil\":{\"dawn\":" event_json(rise_at(96, noon), off) ",\"dusk\":" event_json(set_at(96, noon), off) "}"
    out = out ",\"nautical\":{\"dawn\":" event_json(rise_at(102, noon), off) ",\"dusk\":" event_json(set_at(102, noon), off) "}"
    out = out ",\"astronomical\":{\"dawn\":" event_json(rise_at(108, noon), off) ",\"dusk\":" event_json(set_at(108, noon), off) "}"
    out = out "}"

    out = out ",\"golden_hour\":{"
    out = out "\"morning\":{\"start\":" event_json(rise, off) ",\"end\":" event_json(rise_at(84, noon), off) "}"
    out = out ",\"evening\":{\"start\":" event_json(set_at(84, noon), off) ",\"end\":" event_json(set, off) "}"
    out = out "}"

    out = out ",\"blue_hour\":{"
    out = out "\"morning\":{\"start\":" event_json(rise_at(96, noon), off) ",\"end\":" event_json(rise_at(94, noon), off) "}"
    out = out ",\"evening\":{\"start\":" event_json(set_at(94, noon), off) ",\"end\":" event_json(set_at(96, noon), off) "}"
    out = out "}"

    out = out "}"
    print out
}

function rise_at(zenith, noon) {
    if (pair(zenith, lat, lon, noon)) return PAIR_RISE
    return ""
}

function set_at(zenith, noon) {
    if (pair(zenith, lat, lon, noon)) return PAIR_SET
    return ""
}

function do_position() {
    if (lat < -90 || lat > 90) fail("latitude out of range")
    if (lon < -180 || lon > 180) fail("longitude out of range")
    solar_position(epoch, lat, lon)
    printf "{\"at\":%d,\"iso\":\"%s\",\"latitude\":%s,\"longitude\":%s,", round_(epoch), iso_local(epoch, off), lat, lon
    printf "\"elevation\":%.4f,\"azimuth\":%.4f,\"zenith\":%.4f,", POS_ELEV, POS_AZ, POS_ZEN
    printf "\"declination\":%.6f,\"hour_angle\":%.4f,\"equation_of_time_minutes\":%.6f}\n", SP_DECL, POS_HA, SP_EQ
}

function do_phase(   noon, tm, i, j, n, nextAt, nextName, elev, before, phase, tw, rise, set, daylen, prog, elapsed, remaining, out, sep, list_n, ups, p, a1, a2, k) {
    if (lat < -90 || lat > 90) fail("latitude out of range")
    if (lon < -180 || lon > 180) fail("longitude out of range")

    solar_position(epoch, lat, lon)
    elev = POS_ELEV
    noon = local_noon(epoch, off)
    build_day(noon, lat, lon)
    copy_events("t")
    build_day(noon + 86400, lat, lon)
    copy_events("m")

    before = epoch < find_in("t", "solar_noon") + 0
    if (elev > 6) phase = "day"
    else if (elev > 0) phase = "golden_hour"
    else if (elev > -18) phase = before ? "dawn" : "dusk"
    else phase = "night"

    if (elev > -0.833) tw = "null"
    else if (elev > -6) tw = "\"civil\""
    else if (elev > -12) tw = "\"nautical\""
    else if (elev > -18) tw = "\"astronomical\""
    else tw = "null"

    rise = find_in("t", "sunrise")
    set = find_in("t", "sunset")
    daylen = ""
    elapsed = ""
    remaining = ""
    prog = ""
    if (rise != "" && set != "") {
        daylen = mod_(set - rise, 86400)
        if (elev > -0.833) {
            elapsed = round_(epoch - rise)
            if (elapsed < 0) elapsed = 0
            if (elapsed > daylen) elapsed = daylen
            remaining = daylen - elapsed
            prog = daylen > 0 ? elapsed / daylen : 0
        }
    } else {
        pair(90.833, lat, lon, noon)
        if (PAIR_STATE == "above") daylen = 86400
        else if (PAIR_STATE == "below") daylen = 0
    }

    # next boundary across today and tomorrow
    nextAt = ""
    nextName = ""
    list_n = 0
    for (i = 1; i <= 2; i++) {
        p = i == 1 ? "t" : "m"
        for (j = 1; j <= EVCOUNT[p]; j++) {
            tm = EVEP[p, j]
            if (tm > epoch + 0.5) {
                list_n++
                UPS_AT[list_n] = tm
                UPS_NAME[list_n] = EVNAME[p, j]
            }
        }
    }
    # insertion sort by time
    for (i = 2; i <= list_n; i++) {
        a1 = UPS_AT[i]; a2 = UPS_NAME[i]
        j = i - 1
        while (j >= 1 && UPS_AT[j] > a1) {
            UPS_AT[j + 1] = UPS_AT[j]
            UPS_NAME[j + 1] = UPS_NAME[j]
            j--
        }
        UPS_AT[j + 1] = a1
        UPS_NAME[j + 1] = a2
    }
    if (list_n > 0) {
        nextAt = UPS_AT[1]
        nextName = UPS_NAME[1]
    }

    out = "{\"at\":" round_(epoch) ",\"iso\":\"" iso_local(epoch, off) "\""
    if (tz != "") out = out ",\"timezone\":\"" jesc(tz) "\""
    out = out ",\"utc_offset_seconds\":" off
    out = out ",\"latitude\":" lat ",\"longitude\":" lon
    out = out ",\"phase\":\"" phase "\""
    out = out ",\"twilight\":" tw
    out = out ",\"is_day\":" (elev > -0.833 ? "true" : "false")
    out = out ",\"is_dark\":" (elev > -0.833 ? "false" : "true")
    out = out ",\"is_night\":" (elev < -18 ? "true" : "false")
    out = out ",\"is_golden_hour\":" (elev > 0 && elev <= 6 ? "true" : "false")
    out = out ",\"is_blue_hour\":" (elev > -6 && elev < -4 ? "true" : "false")
    out = out sprintf(",\"elevation\":%.4f,\"azimuth\":%.4f", elev, POS_AZ)
    out = out ",\"day_length_seconds\":" (daylen == "" ? "null" : round_(daylen))
    out = out ",\"daylight_elapsed_seconds\":" (elapsed == "" ? "null" : elapsed)
    out = out ",\"daylight_remaining_seconds\":" (remaining == "" ? "null" : remaining)
    out = out ",\"daylight_progress\":" (prog == "" ? "null" : sprintf("%.6f", prog))
    if (nextAt == "") out = out ",\"next\":null"
    else out = out ",\"next\":{\"event\":\"" nextName "\",\"at\":" round_(nextAt) ",\"iso\":\"" iso_local(nextAt, sun_off) "\",\"minute\":" minute_local(nextAt, sun_off) ",\"in_seconds\":" round_(nextAt - epoch) "}"
    out = out ",\"upcoming\":["
    sep = ""
    for (i = 1; i <= list_n && i <= 8; i++) {
        out = out sep "{\"event\":\"" UPS_NAME[i] "\",\"at\":" round_(UPS_AT[i]) ",\"iso\":\"" iso_local(UPS_AT[i], sun_off) "\",\"minute\":" minute_local(UPS_AT[i], sun_off) ",\"in_seconds\":" round_(UPS_AT[i] - epoch) "}"
        sep = ","
    }
    out = out "]"

    # today's full solar day, so one call gives everything
    out = out ",\"sun\":" solar_json(noon, sun_off)
    out = out "}"
    print out
}

# Solar JSON without printing, for embedding.
function solar_json(epoch, off,   noon, rise, set, state, i, out, sep, d, decl, eq) {
    noon = local_noon(epoch, off)
    build_day(noon, lat, lon)
    copy_events("s")
    pair(90.833, lat, lon, noon)
    rise = PAIR_RISE; set = PAIR_SET; state = PAIR_STATE
    solar_params(noon)
    decl = SP_DECL; eq = SP_EQ

    out = "{\"date\":\"" date_local(epoch, off) "\""
    out = out ",\"weekday\":\"" weekday_name(fdiv(epoch + off, 86400)) "\""
    out = out ",\"sunrise\":" event_json(rise, off)
    out = out ",\"sunset\":" event_json(set, off)
    out = out ",\"solar_noon\":" event_json(find_event("solar_noon"), off)
    if (state == "above") out = out ",\"day_length_seconds\":86400,\"polar\":\"midnight-sun\""
    else if (state == "below") out = out ",\"day_length_seconds\":0,\"polar\":\"polar-night\""
    else out = out ",\"day_length_seconds\":" round_(mod_(set - rise, 86400)) ",\"polar\":null"
    out = out ",\"declination\":" sprintf("%.6f", decl) ",\"equation_of_time_minutes\":" sprintf("%.6f", eq)
    out = out ",\"events\":{"
    sep = ""
    for (i = 1; i <= EVCOUNT["s"]; i++) {
        out = out sep "\"" EVNAME["s", i] "\":" event_json(EVEP["s", i], off)
        sep = ","
    }
    out = out "}}"
    return out
}

function do_night(   noon, tm, i, j, set, rise, nextRise, active, elev, dur, out, day2, p) {
    if (lat < -90 || lat > 90) fail("latitude out of range")
    if (lon < -180 || lon > 180) fail("longitude out of range")
    solar_position(epoch, lat, lon)
    elev = POS_ELEV
    active = elev <= -0.833

    noon = local_noon(epoch, off)
    build_day(noon, lat, lon)
    copy_events("t")
    build_day(noon + 86400, lat, lon)
    copy_events("m")

    set = find_in("t", "sunset")
    nextRise = ""
    for (i = 1; i <= 2; i++) {
        p = i == 1 ? "t" : "m"
        for (j = 1; j <= EVCOUNT[p]; j++) {
            if (EVNAME[p, j] == "sunrise" && EVEP[p, j] > epoch + 0.5) {
                if (nextRise == "" || EVEP[p, j] < nextRise) nextRise = EVEP[p, j]
            }
        }
    }

    out = "{\"at\":" round_(epoch) ",\"iso\":\"" iso_local(epoch, off) "\""
    if (tz != "") out = out ",\"timezone\":\"" jesc(tz) "\""
    out = out ",\"utc_offset_seconds\":" off
    out = out ",\"active\":" (active ? "true" : "false")
    out = out ",\"sunset\":" event_json(set, sun_off)
    out = out ",\"sunrise\":" event_json(nextRise, sun_off)
    if (set != "" && nextRise != "") {
        dur = mod_(nextRise - set, 86400)
        out = out ",\"duration_seconds\":" round_(dur)
        out = out ",\"start_minute\":" minute_local(set, sun_off)
        out = out ",\"end_minute\":" minute_local(nextRise, sun_off)
    } else {
        out = out ",\"duration_seconds\":null,\"start_minute\":null,\"end_minute\":null"
    }
    if (set == "" && nextRise == "") {
        if (active) out = out ",\"polar\":\"polar-night\""
        else out = out ",\"polar\":\"midnight-sun\""
    } else {
        out = out ",\"polar\":null"
    }
    out = out "}"
    print out
}

function do_flatten(   i, doc) {
    doc = ""
    for (i = 1; i <= LN; i++) doc = doc LINES[i] "\n"
    JD = doc
    JL = length(doc)
    JP = 1
    js_skip_ws()
    if (JP > JL) fail("empty JSON")
    js_parse_value("")
    if (failed) exit 3
}

function do_get(   i, p, line, tab, pathv, val) {
    for (i = 1; i <= LN; i++) {
        line = LINES[i]
        tab = index(line, "\t")
        if (!tab) continue
        pathv = substr(line, 1, tab - 1)
        if (pathv == path) {
            val = substr(line, tab + 1)
            print unescape_flat(val)
            return
        }
    }
    exit 1
}

function unescape_flat(s) {
    gsub(/\\n/, "\n", s)
    gsub(/\\t/, "\t", s)
    gsub(/\\r/, "\r", s)
    return s
}

function js_emit(path, v) {
    gsub(/\\/, "\\\\", v)
    gsub(/\t/, "\\t", v)
    gsub(/\n/, "\\n", v)
    gsub(/\r/, "\\r", v)
    print path "\t" v
}

# --------------------------- JSON reader ------------------------------------

function js_skip_ws(   c) {
    while (JP <= JL) {
        c = substr(JD, JP, 1)
        if (c == " " || c == "\t" || c == "\n" || c == "\r") JP++
        else return
    }
}

function js_parse_string(   c, c2, out) {
    JP++
    out = ""
    while (JP <= JL) {
        c = substr(JD, JP, 1)
        if (c == "\\") {
            JP++
            c2 = substr(JD, JP, 1)
            if (c2 == "n") out = out "\n"
            else if (c2 == "t") out = out "\t"
            else if (c2 == "r") out = out "\r"
            else if (c2 == "b") out = out "\b"
            else if (c2 == "f") out = out "\f"
            else if (c2 == "/") out = out "/"
            else if (c2 == "\\") out = out "\\"
            else if (c2 == "\"") out = out "\""
            else if (c2 == "u") { out = out "\\u" substr(JD, JP + 1, 4); JP += 4 }
            else out = out c2
            JP++
        } else if (c == "\"") {
            JP++
            return out
        } else {
            out = out c
            JP++
        }
    }
    fail("unterminated string in JSON")
}

function js_parse_scalar(path,   start, c, v) {
    start = JP
    while (JP <= JL) {
        c = substr(JD, JP, 1)
        if (c == "," || c == "}" || c == "]" || c == " " || c == "\t" || c == "\n" || c == "\r")
            break
        JP++
    }
    v = substr(JD, start, JP - start)
    if (v != "")
        js_emit(path, v)
}

function js_parse_object(path,   key, c) {
    JP++
    js_skip_ws()
    if (substr(JD, JP, 1) == "}") { JP++; return }
    while (JP <= JL) {
        js_skip_ws()
        if (substr(JD, JP, 1) != "\"") { fail("expected a key in JSON"); return }
        key = js_parse_string()
        js_skip_ws()
        if (substr(JD, JP, 1) == ":") JP++
        else { fail("expected ':' in JSON"); return }
        js_parse_value(path == "" ? key : path "." key)
        if (failed) return
        js_skip_ws()
        c = substr(JD, JP, 1)
        JP++
        if (c == "}") return
        if (c != ",") { fail("expected ',' in JSON"); return }
    }
    fail("unterminated object in JSON")
}

function js_parse_array(path,   idx, c) {
    JP++
    idx = 0
    js_skip_ws()
    if (substr(JD, JP, 1) == "]") { JP++; return }
    while (JP <= JL) {
        js_parse_value(path == "" ? idx : path "." idx)
        if (failed) return
        js_skip_ws()
        c = substr(JD, JP, 1)
        JP++
        if (c == "]") return
        if (c != ",") { fail("expected ',' in JSON"); return }
        idx++
    }
    fail("unterminated array in JSON")
}

function js_parse_value(path,   c) {
    js_skip_ws()
    if (JP > JL) { fail("unexpected end of JSON"); return }
    c = substr(JD, JP, 1)
    if (c == "{") { js_parse_object(path); return }
    if (c == "[") { js_parse_array(path); return }
    if (c == "\"") { js_emit(path, js_parse_string()); return }
    js_parse_scalar(path)
}

# --------------------------- geocoder ---------------------------------------

function do_place(   i, line, tab, pathv, val, seg, n, idx, field, j, maxi, out, sep, name, admin1, country) {
    for (i = 1; i <= LN; i++) {
        line = LINES[i]
        tab = index(line, "\t")
        if (!tab) continue
        pathv = substr(line, 1, tab - 1)
        val = unescape_flat(substr(line, tab + 1))
        n = split(pathv, seg, ".")
        if (n != 3 || seg[1] != "results") continue
        idx = seg[2] + 0
        field = seg[3]
        P[idx, field] = val
        if (idx > maxi) maxi = idx
        SEEN[field] = 1
    }
    out = "["
    sep = ""
    for (i = 0; i <= maxi; i++) {
        if (!((i, "name") in P) && !((i, "latitude") in P)) continue
        name = (i, "name") in P ? P[i, "name"] : ""
        admin1 = (i, "admin1") in P ? P[i, "admin1"] : ""
        country = (i, "country") in P ? P[i, "country"] : ""
        label = name
        if (admin1 != "" && admin1 != name) label = label ", " admin1
        if (country != "") label = label ", " country
        out = out sep "{"
        out = out "\"name\":" str_or_null(name)
        out = out ",\"label\":" str_or_null(label)
        out = out ",\"id\":" ((i, "id") in P ? num_or_null(P[i, "id"]) : "null")
        out = out ",\"latitude\":" ((i, "latitude") in P ? num_or_null(P[i, "latitude"]) : "null")
        out = out ",\"longitude\":" ((i, "longitude") in P ? num_or_null(P[i, "longitude"]) : "null")
        out = out ",\"elevation\":" ((i, "elevation") in P ? num_or_null(P[i, "elevation"]) : "null")
        out = out ",\"timezone\":" ((i, "timezone") in P ? str_or_null(P[i, "timezone"]) : "null")
        out = out ",\"country\":" str_or_null(country)
        out = out ",\"country_code\":" ((i, "country_code") in P ? str_or_null(P[i, "country_code"]) : "null")
        out = out ",\"admin1\":" ((i, "admin1") in P ? str_or_null(P[i, "admin1"]) : "null")
        out = out ",\"admin2\":" ((i, "admin2") in P ? str_or_null(P[i, "admin2"]) : "null")
        out = out ",\"population\":" ((i, "population") in P ? num_or_null(P[i, "population"]) : "null")
        out = out ",\"feature_code\":" ((i, "feature_code") in P ? str_or_null(P[i, "feature_code"]) : "null")
        out = out "}"
        sep = ","
    }
    out = out "]"
    print out
}

function do_ip(   i, line, tab, pathv, val, lat, lon, city, region, country, cc, tzname, label, out) {
    for (i = 1; i <= LN; i++) {
        line = LINES[i]
        tab = index(line, "\t")
        if (!tab) continue
        pathv = substr(line, 1, tab - 1)
        val = unescape_flat(substr(line, tab + 1))
        K[pathv] = val
    }
    if (("error" in K) && K["error"] == "true")
        fail("the location service refused: " (("reason" in K) ? K["reason"] : "unknown"))
    if (("status" in K) && K["status"] == "fail")
        fail("the location service refused: " (("message" in K) ? K["message"] : "unknown"))

    lat = ("latitude" in K) ? K["latitude"] : (("lat" in K) ? K["lat"] : "")
    lon = ("longitude" in K) ? K["longitude"] : (("lon" in K) ? K["lon"] : "")
    if (lat == "" || lon == "")
        fail("the location service did not return a position")
    city = ("city" in K) ? K["city"] : ""
    region = ("region_name" in K) ? K["region_name"] : (("region" in K) ? K["region"] : "")
    country = ("country_name" in K) ? K["country_name"] : (("country" in K) ? K["country"] : "")
    cc = ("country_code" in K) ? K["country_code"] : (("countryCode" in K) ? K["countryCode"] : "")
    tzname = ("timezone" in K) ? K["timezone"] : ""

    label = city
    if (region != "" && region != city) label = label == "" ? region : label ", " region
    if (country != "") label = label == "" ? country : label ", " country

    out = "{\"latitude\":" num_or_null(lat) ",\"longitude\":" num_or_null(lon)
    out = out ",\"city\":" str_or_null(city)
    out = out ",\"region\":" str_or_null(region)
    out = out ",\"country\":" str_or_null(country)
    out = out ",\"country_code\":" str_or_null(cc)
    out = out ",\"timezone\":" str_or_null(tzname)
    out = out ",\"label\":" str_or_null(label)
    out = out "}"
    print out
}

# --------------------------- WMO codes --------------------------------------

function wmo_desc(c) {
    c = c + 0
    if (c == 0) return "Clear sky"
    if (c == 1) return "Mainly clear"
    if (c == 2) return "Partly cloudy"
    if (c == 3) return "Overcast"
    if (c == 45) return "Fog"
    if (c == 48) return "Depositing rime fog"
    if (c == 51) return "Light drizzle"
    if (c == 53) return "Moderate drizzle"
    if (c == 55) return "Dense drizzle"
    if (c == 56) return "Light freezing drizzle"
    if (c == 57) return "Dense freezing drizzle"
    if (c == 61) return "Slight rain"
    if (c == 63) return "Moderate rain"
    if (c == 65) return "Heavy rain"
    if (c == 66) return "Light freezing rain"
    if (c == 67) return "Heavy freezing rain"
    if (c == 71) return "Slight snowfall"
    if (c == 73) return "Moderate snowfall"
    if (c == 75) return "Heavy snowfall"
    if (c == 77) return "Snow grains"
    if (c == 80) return "Slight rain showers"
    if (c == 81) return "Moderate rain showers"
    if (c == 82) return "Violent rain showers"
    if (c == 85) return "Slight snow showers"
    if (c == 86) return "Heavy snow showers"
    if (c == 95) return "Thunderstorm"
    if (c == 96) return "Thunderstorm with slight hail"
    if (c == 99) return "Thunderstorm with heavy hail"
    return "Unknown"
}

function wmo_kind(c, night) {
    c = c + 0
    if (c == 0) return night ? "clear-night" : "clear"
    if (c == 1 || c == 2) return night ? "partly-night" : "partly"
    if (c == 3) return "cloud"
    if (c == 45 || c == 48) return "fog"
    if (c >= 51 && c <= 57) return "rain"
    if (c >= 61 && c <= 67) return "rain"
    if (c >= 71 && c <= 77) return "snow"
    if (c >= 80 && c <= 82) return "rain"
    if (c == 85 || c == 86) return "snow"
    if (c >= 95 && c <= 99) return "storm"
    return "cloud"
}

function do_wmo(   i, out, sep, codes) {
    codes = "0 1 2 3 45 48 51 53 55 56 57 61 63 65 66 67 71 73 75 77 80 81 82 85 86 95 96 99"
    if (code == "") {
        n = split(codes, A, " ")
        out = "["; sep = ""
        for (i = 1; i <= n; i++) {
            out = out sep "{\"code\":" A[i] ",\"description\":\"" wmo_desc(A[i]) "\",\"kind\":\"" wmo_kind(A[i], night + 0) "\"}"
            sep = ","
        }
        print out "]"
    } else {
        print "{\"code\":" (code + 0) ",\"description\":\"" wmo_desc(code) "\",\"kind\":\"" wmo_kind(code, night + 0) "\"}"
    }
}

# --------------------------- units ------------------------------------------

function do_convert(   v, out) {
    v = value + 0
    f = from
    t = to
    if (f == t) out = v
    else if (f == "c" && t == "f") out = v * 9 / 5 + 32
    else if (f == "f" && t == "c") out = (v - 32) * 5 / 9
    else if (f == "kmh" && t == "mph") out = v * 0.621371
    else if (f == "mph" && t == "kmh") out = v / 0.621371
    else if (f == "kmh" && t == "ms") out = v / 3.6
    else if (f == "ms" && t == "kmh") out = v * 3.6
    else if (f == "ms" && t == "mph") out = v * 2.236936
    else if (f == "mph" && t == "ms") out = v / 2.236936
    else if (f == "kmh" && t == "kn") out = v / 1.852
    else if (f == "kn" && t == "kmh") out = v * 1.852
    else if (f == "mm" && t == "in") out = v / 25.4
    else if (f == "in" && t == "mm") out = v * 25.4
    else if (f == "cm" && t == "in") out = v / 2.54
    else if (f == "in" && t == "cm") out = v * 2.54
    else if (f == "m" && t == "ft") out = v * 3.28084
    else if (f == "ft" && t == "m") out = v / 3.28084
    else if (f == "m" && t == "mi") out = v / 1609.344
    else if (f == "mi" && t == "m") out = v * 1609.344
    else if (f == "km" && t == "mi") out = v / 1.609344
    else if (f == "mi" && t == "km") out = v * 1.609344
    else if (f == "hpa" && t == "inhg") out = v * 0.0295299830714
    else if (f == "inhg" && t == "hpa") out = v / 0.0295299830714
    else if (f == "hpa" && t == "mmhg") out = v * 0.750061683
    else if (f == "mmhg" && t == "hpa") out = v / 0.750061683
    else fail("cannot convert " f " to " t)
    if (out == int(out)) printf "%d\n", out
    else printf "%.6f\n", out
}

# --------------------------- minute windows ---------------------------------

function in_window(nowm, fromm, tom) {
    nowm = mod_(round_(nowm), 1440)
    fromm = mod_(round_(fromm), 1440)
    tom = mod_(round_(tom), 1440)
    if (fromm == tom) return 0
    if (fromm < tom) return (nowm >= fromm && nowm < tom) ? 1 : 0
    return (nowm >= fromm || nowm < tom) ? 1 : 0
}

function next_edge(nowm, fromm, tom) {
    return in_window(nowm, fromm, tom) ? mod_(round_(tom), 1440) : mod_(round_(fromm), 1440)
}

# --------------------------- percent encoding -------------------------------

function do_urlencode(   i, j, line, s, out, c, n) {
    for (i = 1; i <= LN; i++) {
        line = LINES[i]
        n = length(line)
        out = ""
        for (j = 1; j <= n; j++) {
            c = substr(line, j, 1)
            if (c ~ /[A-Za-z0-9._~-]/) out = out c
            else out = out sprintf("%%%02X", ord(c))
        }
        print out
    }
}

# POSIX awk has no ord(): use the byte lookup built in BEGIN.
function ord(c) {
    if (c in ORD) return ORD[c]
    return 63
}

# --------------------------- weather CSV ------------------------------------

function csv_split(line, arr,   n, i, c, q, cur, len) {
    n = 0; cur = ""; q = 0
    len = length(line)
    for (i = 1; i <= len; i++) {
        c = substr(line, i, 1)
        if (q) {
            if (c == "\"") {
                if (substr(line, i + 1, 1) == "\"") { cur = cur "\""; i++ }
                else q = 0
            } else cur = cur c
        } else if (c == "\"") {
            q = 1
        } else if (c == ",") {
            arr[++n] = cur
            cur = ""
        } else {
            cur = cur c
        }
    }
    arr[++n] = cur
    return n
}

function col_name(h,   p) {
    p = index(h, " (")
    if (p) return substr(h, 1, p - 1)
    return trim_(h)
}

function col_unit(h,   p) {
    p = index(h, " (")
    if (!p) return ""
    return substr(h, p + 2, length(h) - p - 2)
}

function norm_key(n) {
    if (n == "temperature_2m") return "temperature"
    if (n == "apparent_temperature") return "apparent_temperature"
    if (n == "relative_humidity_2m") return "humidity"
    if (n == "dew_point_2m") return "dew_point"
    if (n == "precipitation_probability") return "precipitation_probability"
    if (n == "weather_code") return "weather_code"
    if (n == "cloud_cover") return "cloud_cover"
    if (n == "pressure_msl") return "pressure"
    if (n == "surface_pressure") return "surface_pressure"
    if (n == "wind_speed_10m") return "wind_speed"
    if (n == "wind_direction_10m") return "wind_direction"
    if (n == "wind_gusts_10m") return "wind_gusts"
    if (n == "wind_direction_10m_dominant") return "wind_direction_dominant"
    if (n == "wind_speed_10m_max") return "wind_speed_max"
    if (n == "wind_gusts_10m_max") return "wind_gusts_max"
    if (n == "temperature_2m_max") return "temperature_max"
    if (n == "temperature_2m_min") return "temperature_min"
    return n
}

function add_unit(key, unit) {
    if (key == "" || unit == "") return
    if (!(key in UNIT)) {
        UNIT[key] = unit
        UNIT_KEYS[++UNIT_N] = key
    }
}

function wind_compass(deg,   d, names, n) {
    if (deg == "" || !isnum(deg)) return "null"
    d = mod_(deg + 0, 360)
    names = "N NE E SE S SW W NW"
    n = split(names, W, " ")
    return "\"" W[int((d + 22.5) / 45) % 8 + 1] "\""
}

function row_json(hdr, hc, row, type, off,   vals, n, i, k, v, out, sep, isday, code, desc, kind, t, ep, unit, key) {
    n = csv_split(row, vals)

    isday = -1
    code = ""
    for (i = 1; i <= hc; i++) {
        k = norm_key(col_name(hdr[i]))
        if (k == "is_day") isday = trim_(vals[i]) + 0
        if (k == "weather_code") code = trim_(vals[i])
    }

    out = "{"
    sep = ""
    for (i = 1; i <= hc; i++) {
        k = norm_key(col_name(hdr[i]))
        v = trim_(vals[i])
        unit = col_unit(hdr[i])
        if (k == "time" || k == "date") {
            if (v != "") {
                ep = parse_iso(v, off)
                key = (type == "daily") ? "date" : "time"
                out = out sep "\"" key "\":\"" jesc(v) "\""
                out = out ",\"at\":" round_(ep)
                out = out ",\"minute\":" (type == "daily" ? 0 : minute_local(ep, off))
                sep = ","
            }
            continue
        }
        if (k == "sunrise" || k == "sunset") {
            if (v != "") {
                ep = parse_iso(v, off)
                out = out sep "\"" k "\":" event_json(ep, off)
                sep = ","
            }
            continue
        }
        if (k == "is_day") {
            out = out sep "\"is_day\":" (v == "" ? "null" : (v + 0 ? "true" : "false"))
            sep = ","
            continue
        }
        if (k == "weather_code") {
            if (v != "") {
                desc = wmo_desc(v)
                kind = wmo_kind(v, isday == 1)
                out = out sep "\"weather_code\":" num_or_null(v)
                out = out ",\"description\":\"" jesc(desc) "\""
                out = out ",\"kind\":\"" kind "\""
                sep = ","
            }
            continue
        }
        if (unit == "" || v == "") {
            if (v == "") continue
            if (isnum(v)) out = out sep "\"" k "\":" v
            else out = out sep "\"" k "\":" str_or_null(v)
            sep = ","
            continue
        }
        add_unit(k, unit)
        out = out sep "\"" k "\":" num_or_null(v)
        if (k == "wind_direction" || k == "wind_direction_dominant") {
            out = out ",\"wind_compass\":" wind_compass(v)
        }
        sep = ","
    }
    out = out "}"
    return out
}

function do_weather(   i, n, mk, mv, hdr, hc, rows, rc, block, type, off, cur, hrl, dly, sep, j, line, mkey, out, summary, temp, tunit, fetched) {
    n = LN
    i = 1
    while (i <= n && trim_(LINES[i]) == "") i++
    if (i > n) fail("empty forecast")
    mk = LINES[i]; i++
    if (i > n) fail("incomplete forecast")
    mv = LINES[i]; i++
    hc = csv_split(mk, HDR)
    csv_split(mv, META_V)
    for (j = 1; j <= hc; j++) META[trim_(HDR[j])] = META_V[j]

    off = META["utc_offset_seconds"] + 0
    fetched = now + 0

    cur = "null"; hrl = ""; dly = ""
    block = 0
    while (i <= n) {
        while (i <= n && trim_(LINES[i]) == "") i++
        if (i > n) break
        hc = csv_split(LINES[i], HDR)
        i++
        rc = 0
        while (i <= n && trim_(LINES[i]) != "") {
            rc++
            ROWS[rc] = LINES[i]
            i++
        }
        block++
        type = "hourly"
        for (j = 1; j <= hc; j++) if (col_name(HDR[j]) == "sunrise") type = "daily"
        if (type == "hourly" && block == 1 && rc == 1) type = "current"

        if (type == "current") {
            cur = row_json(HDR, hc, ROWS[1], type, off)
        } else if (type == "hourly") {
            sep = ""
            for (j = 1; j <= rc; j++) {
                hrl = hrl sep row_json(HDR, hc, ROWS[j], type, off)
                sep = ","
            }
        } else if (type == "daily") {
            sep = ""
            for (j = 1; j <= rc; j++) {
                dly = dly sep row_json(HDR, hc, ROWS[j], type, off)
                sep = ","
            }
        }
    }

    out = "{\"provider\":\"open-meteo\""
    out = out ",\"fetched_at\":" round_(fetched)
    out = out ",\"latitude\":" num_or_null(META["latitude"])
    out = out ",\"longitude\":" num_or_null(META["longitude"])
    out = out ",\"elevation\":" num_or_null(META["elevation"])
    out = out ",\"timezone\":" str_or_null(META["timezone"])
    out = out ",\"timezone_abbreviation\":" str_or_null(META["timezone_abbreviation"])
    out = out ",\"utc_offset_seconds\":" off
    out = out ",\"units\":{"
    sep = ""
    for (j = 1; j <= UNIT_N; j++) {
        out = out sep "\"" UNIT_KEYS[j] "\":\"" jesc(UNIT[UNIT_KEYS[j]]) "\""
        sep = ","
    }
    out = out "}"
    out = out ",\"current\":" cur
    out = out ",\"hourly\":[" hrl "]"
    out = out ",\"daily\":[" dly "]"
    out = out "}"
    print out
}
