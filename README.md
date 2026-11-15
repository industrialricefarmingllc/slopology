# slopology

Daylight, twilight and weather for any place on Earth — as a **POSIX shell
library and command-line tool**. No build step, no runtime, no dependencies
beyond the tools a base Arch (or any Unix) system already has: `sh`, `awk`,
`date`, and `curl` (or `wget`) for the network calls.

It answers the questions a desktop shell, a bar, a wallpaper daemon, a night
light or a script tends to ask:

- When is sunrise, sunset, solar noon? When do the three twilights start and end?
- Where is the sun right now — elevation, azimuth, zenith?
- Is it day, night, golden hour, blue hour, civil/nautical/astronomical twilight?
- How much daylight is left, and when is the next boundary?
- What is the weather now, hour by hour and day by day?
- Which place is a name, a set of coordinates, or this network?

Every question has one JSON answer. The JSON is the API; the shell functions
are thin wrappers around it, and the CLI is a thin wrapper around them.

Everything in `lib/sky.awk` is NOAA's general solar position algorithm and
Open-Meteo's forecast data — no proprietary services, no API key, no account.

```
slopology sun --place Tokyo
```
```
Tokyo, Japan · Asia/Tokyo
Sunday 2026-11-15
  astronomical dawn    04:48
  nautical dawn        05:18
  civil dawn           05:49
  sunrise              06:16
  golden hour ends     06:53
  solar noon           11:25
  golden hour starts   15:57
  sunset               16:34
  civil dusk           17:01
  nautical dusk        17:32
  astronomical dusk    18:02
  day length           10 h 17 min
```

---

## Why a shell library?

This started as the day/night and weather code inside **Lucid**, a Quickshell
desktop. Extracting it as a library meant answering a harder question than
"how do I share a QML singleton": the answer has to run on a server, in a
Waybar module, in a `cron` job, in a shell prompt, on a BSD box and on an ARM
board, with nothing installed.

That rules out Node, Python and Qt. It leaves the one runtime every Unix has:
the shell and its `awk`. The solar maths is a few hundred lines of
trigonometry (POSIX `awk` has `sin`, `cos`, `atan2` and `sqrt`), the date
arithmetic is Howard Hinnant's civil-calendar algorithm, and the weather
parser reads Open-Meteo's CSV rather than its JSON, because CSV needs no
parser. The one optional piece is `curl`/`wget`; the sun and the moonless
parts have no network at all.

## Install

```sh
git clone git@irfllc.github.com:industrialricefarmingllc/slopology.git
cd slopology
sudo make install        # /usr/local/bin + /usr/local/lib/slopology + man page
```

Or run it from the checkout, with no install:

```sh
./bin/slopology --help
./bin/slopology sun --lat 51.5074 --lon -0.1278 --tz Europe/London
```

`make install PREFIX=$HOME/.local` puts it under `~/.local`; `make uninstall`
removes it. The installer copies `bin/slopology`, `lib/sky.sh`, `lib/sky.awk`
and `man/slopology.1`; nothing else is touched.

### Requirements

| Need | Why | Arch package |
| --- | --- | --- |
| POSIX `sh` | the library and CLI | `bash` (in `base`) |
| POSIX `awk` | all the maths | `gawk` (in `base`) |
| `date`, `mkdir`, `mv`, `tr`, `sed` | time zones, cache, labels | `coreutils` / `sed` (in `base`) |
| `curl` **or** `wget` | weather and place lookups only | `curl` (in `base`) |
| tzdata | DST-correct zone offsets | `tzdata` |

No compiler, no interpreter beyond `awk`, no package manager at runtime.
`gawk`, `mawk`, `nawk`, `busybox awk` and the BSD `awk` all work; the tests
run against whichever `awk` is first in `PATH`. Everything is 64-bit-safe on
any CPU architecture because it is arithmetic, not native code.

Portability notes:

- Zone offsets use `TZ=Zone date`; on a system without tzdata or with a
  `date` that cannot read an arbitrary epoch, the library falls back to the
  machine's current offset and says so nowhere — the sun maths never needs
  the network.
- `curl` is preferred, `wget` is the fallback, and `SKY_FETCH_CMD` lets you
  substitute any HTTP client (or a local file) entirely.

## Command line

```
slopology [command] [options]
```

| Command | What it prints |
| --- | --- |
| `now` (default) | phase, next boundary, and the current weather |
| `sun` | sunrise, sunset, solar noon, all six twilight boundaries, golden and blue hour, day length |
| `phase` | phase, sun elevation/azimuth, daylight progress, next and upcoming boundaries |
| `night` | the sunset → sunrise window (for night lights and schedules) |
| `position` | elevation, azimuth, zenith |
| `weather` | current conditions, next hours, daily forecast |
| `place <query>` | geocoder results with coordinates and time zones |
| `where` | the position this network appears to be at |
| `wmo [code]` | WMO weather-code descriptions and icon kinds |
| `convert <v> <from> <to>` | unit conversion |

Place and time options work on every command:

```
--lat N --lon N       an explicit position
--place NAME          geocode a place instead
--tz ZONE             IANA zone, e.g. Europe/Paris
--date WHEN           now, epoch seconds, YYYY-MM-DD, or ISO-8601
--hour12              print 12-hour clocks
--json                print the full JSON document
```

With neither `--lat/--lon` nor `--place`, the position is detected from the
network (ipapi.co, then ip-api.com). Pass coordinates in scripts, so a
rate-limited lookup can never break a bar module. Geocoding and network
detection are network calls; a module that refreshes every minute should pass
`--lat/--lon` and `--tz` rather than `--place`. `--offline` therefore requires
coordinates: it refuses a place lookup.

Weather options:

```
--units metric|imperial     °C/km-h/mm, or °F/mph/inch
--days N                    forecast days, 1-16 (default 7)
--hours N                   forecast hours, 1-384 (default 25)
--max-age SECONDS           cache lifetime (default 900)
--no-cache                  neither read nor write the cache
--offline                   cache only, never the network
--refresh                   ignore a fresh cache entry
--csv                       the provider's raw CSV, unmodified
```

Examples:

```sh
slopology sun --place Reykjavik
slopology phase --lat 69.6492 --lon 18.9553 --tz Europe/Oslo --date 2024-06-21
slopology weather --lat 51.5074 --lon -0.1278 --units imperial --json
slopology night --place Paris --json
slopology now --json | jq '{phase: .phase.phase, temp: .weather.current.temperature}'
slopology place "Springfield" --count 3
slopology convert 1013.25 hpa inhg
```

Exit status is `0` on success, `2` for a bad invocation and `1` when the
service or the cache cannot answer. Errors go to stderr; stdout is always
either the requested JSON or human-readable text.

## Shell library

The project is called slopology; the public API keeps the short `sky_*` and
`SKY_*` names, because they read better inside a script than a long prefix on
every call.

```sh
. /usr/local/lib/slopology/sky.sh

sky_solar now 51.5074 -0.1278 Europe/London | jq .sunrise
```

When working from a checkout, point `SKY_LIB_DIR` at `lib/`:

```sh
SKY_LIB_DIR=$PWD/lib . $PWD/lib/sky.sh
```

Every function writes JSON to stdout, returns non-zero on failure, and takes
an optional time first (`now`, epoch, `YYYY-MM-DD`, or ISO-8601). Clocks and
dates are interpreted in the supplied zone.

| Function | Result |
| --- | --- |
| `sky_solar [WHEN] LAT LON [TZ]` | the whole solar day: events, twilights, golden/blue hour |
| `sky_phase [WHEN] LAT LON [TZ]` | phase, flags, sun position, daylight progress, next events, embedded solar day |
| `sky_position [WHEN] LAT LON [TZ]` | elevation, azimuth, zenith |
| `sky_night [WHEN] LAT LON [TZ]` | sunset → next sunrise window, active flag, polar state |
| `sky_weather LAT LON [TZ]` | normalized forecast (current, hourly, daily, units) |
| `sky_weather_csv LAT LON [TZ]` | the raw provider CSV |
| `sky_place QUERY [COUNT]` | geocoder array |
| `sky_where` | network position object |
| `sky_wmo [CODE] [NIGHT]` | one code, or the whole table |
| `sky_offset TZ [EPOCH]` | seconds east of UTC, DST-aware |
| `sky_convert VALUE FROM TO` | a number |
| `sky_in_window NOW FROM TO` | `1`/`0`; overnight windows supported |
| `sky_next_edge NOW FROM TO` | the next window edge, in minutes |
| `sky_format_minute MIN [12H]` | `HH:MM` or `h:MM am/pm` |
| `sky_json_get PATH` | one value from JSON on stdin |
| `sky_version` | the version string |

`sky_json_get` is the escape hatch for scripts:

```sh
sunset=$(sky_solar now 48.8566 2.3522 Europe/Paris | sky_json_get sunset.iso)
```

## The JSON API

Values are not rounded unless the provider rounds them. Times are given three
ways so a consumer never has to parse a date: `at` (Unix seconds, UTC),
`iso` (ISO-8601 with the place's offset) and `minute` (wall-clock minutes
after local midnight, `0`–`1439`). An event that does not occur is `null`.

### `sun`

```json
{
  "date": "2026-11-15",
  "weekday": "Sunday",
  "weekday_short": "Sun",
  "latitude": 48.8566,
  "longitude": 2.3522,
  "timezone": "Europe/Paris",
  "utc_offset_seconds": 3600,
  "declination": -18.4,
  "equation_of_time_minutes": 15.6,
  "sunrise": { "at": 1794725940, "iso": "2026-11-15T07:59:00+01:00", "minute": 479 },
  "sunset":  { "at": 1794759000, "iso": "2026-11-15T17:10:00+01:00", "minute": 1030 },
  "solar_noon": { "at": 1794742470, "iso": "2026-11-15T12:34:30+01:00", "minute": 754 },
  "day_length_seconds": 33060,
  "polar": null,
  "events": {
    "astronomical_dawn": { },
    "nautical_dawn": { },
    "civil_dawn": { },
    "blue_hour_morning_end": { },
    "sunrise": { },
    "golden_hour_morning_end": { },
    "solar_noon": { },
    "golden_hour_evening_start": { },
    "sunset": { },
    "blue_hour_evening_start": { },
    "civil_dusk": { },
    "nautical_dusk": { },
    "astronomical_dusk": { }
  },
  "twilight": {
    "civil": { "dawn": { }, "dusk": { } },
    "nautical": { "dawn": { }, "dusk": { } },
    "astronomical": { "dawn": { }, "dusk": { } }
  },
  "golden_hour": {
    "morning": { "start": { }, "end": { } },
    "evening": { "start": { }, "end": { } }
  },
  "blue_hour": {
    "morning": { "start": { }, "end": { } },
    "evening": { "start": { }, "end": { } }
  }
}
```

- `polar` is `null`, `"midnight-sun"` (the sun never sets) or
  `"polar-night"` (it never rises). In polar night `day_length_seconds` is
  `0`; in midnight sun it is `86400`. Twilight events can still exist in
  polar night — the sun may reach −6° even when it never reaches 0°.
- `golden_hour` is the sun between the horizon and +6°; `blue_hour` is
  between −6° and −4°.
- `declination` and `equation_of_time_minutes` are the two numbers the
  solar maths is built from, exposed for anyone doing their own.

### `phase`

```json
{
  "at": 1794706200,
  "iso": "2026-11-15T02:50:00+01:00",
  "timezone": "Europe/Paris",
  "utc_offset_seconds": 3600,
  "latitude": 48.8566,
  "longitude": 2.3522,
  "phase": "night",
  "twilight": null,
  "is_day": false,
  "is_dark": true,
  "is_night": true,
  "is_golden_hour": false,
  "is_blue_hour": false,
  "elevation": -46.2,
  "azimuth": 41.1,
  "day_length_seconds": 33060,
  "daylight_elapsed_seconds": null,
  "daylight_remaining_seconds": null,
  "daylight_progress": null,
  "next": {
    "event": "astronomical_dawn",
    "at": 1794730800,
    "iso": "2026-11-15T09:20:00+01:00",
    "minute": 560,
    "in_seconds": 24600
  },
  "upcoming": [ ],
  "sun": { }
}
```

`phase` is one of `day`, `golden_hour`, `dawn`, `dusk`, `night`.
`twilight` is `null`, `civil`, `nautical` or `astronomical`.

The three flags are deliberately different:

| Flag | Meaning |
| --- | --- |
| `is_day` | the sun's centre is above −0.833° (the refracted horizon) |
| `is_dark` | the opposite of `is_day` — "not daylight" |
| `is_night` | the sun is below −18° (astronomical night) |

So a civil dusk is `is_day: false`, `is_dark: true`, `is_night: false`.
`daylight_progress` is 0 at sunrise and 1 at sunset, `null` outside daylight
or in polar conditions. `upcoming` is the next eight boundaries, sorted.

### `night`

```json
{
  "at": 1794706200,
  "iso": "2026-11-15T02:50:00+01:00",
  "timezone": "Europe/Paris",
  "utc_offset_seconds": 3600,
  "active": true,
  "sunset":  { "at": 1794670200, "iso": "2026-11-14T17:10:00+01:00", "minute": 1030 },
  "sunrise": { "at": 1794725940, "iso": "2026-11-15T07:59:00+01:00", "minute": 479 },
  "duration_seconds": 53340,
  "start_minute": 1030,
  "end_minute": 479,
  "polar": null
}
```

`start_minute`/`end_minute` are exactly what a "on at sunset, off at sunrise"
schedule wants. `active` is true when the sun is below the horizon now. In
midnight sun `polar` is `"midnight-sun"` and `active` is false; in polar
night it is `"polar-night"` and `active` is true.

### `position`

```json
{
  "at": 1794706200,
  "iso": "2026-11-15T02:50:00+01:00",
  "latitude": 48.8566,
  "longitude": 2.3522,
  "elevation": -46.2,
  "azimuth": 41.1,
  "zenith": 136.2,
  "declination": -18.4,
  "hour_angle": -130.2,
  "equation_of_time_minutes": 15.6
}
```

`azimuth` is degrees clockwise from north. `elevation` is degrees above the
horizon (negative below). `zenith` is `90 - elevation`.

### `weather`

```json
{
  "provider": "open-meteo",
  "fetched_at": 1794706200,
  "latitude": 48.853382,
  "longitude": 2.355208,
  "elevation": 46.0,
  "timezone": "Europe/Paris",
  "timezone_abbreviation": "GMT+1",
  "utc_offset_seconds": 3600,
  "units": {
    "temperature": "°C",
    "wind_speed": "km/h",
    "precipitation": "mm",
    "pressure": "hPa",
    "visibility": "m",
    "daylight_duration": "s"
  },
  "current": {
    "time": "2026-11-15T02:45",
    "at": 1794707100,
    "minute": 165,
    "temperature": 7.2,
    "apparent_temperature": 5.0,
    "humidity": 89,
    "dew_point": 5.5,
    "precipitation": 0.0,
    "rain": 0.0,
    "showers": 0.0,
    "snowfall": 0.0,
    "weather_code": 61,
    "description": "Slight rain",
    "kind": "rain",
    "is_day": false,
    "cloud_cover": 100,
    "pressure": 1009.9,
    "surface_pressure": 1004.3,
    "wind_speed": 6.9,
    "wind_direction": 208,
    "wind_compass": "SW",
    "wind_gusts": 14.8,
    "visibility": 20420.0,
    "uv_index": 0.0
  },
  "hourly": [ ],
  "daily": [ ]
}
```

Each row carries its provider values under normalized names and the units in
the report's `units` object. A field the provider did not return is omitted
rather than invented. `kind` is the icon taxonomy used by Lucid and most
weather icon sets:

```
clear  clear-night  partly  partly-night  cloud  fog  rain  snow  storm
```

Current and hourly rows add `description`, `kind`, `wind_compass` and
`is_day`. Daily rows use `date` instead of `time`, and `sunrise`/`sunset` are
event objects. Daily fields available by default:

```
weather_code  temperature_max  temperature_min
apparent_temperature_max  apparent_temperature_min
sunrise  sunset  daylight_duration  sunshine_duration
uv_index_max  precipitation_sum  rain_sum  showers_sum  snowfall_sum
precipitation_hours  precipitation_probability_max
wind_speed_max  wind_gusts_max  wind_direction_dominant
shortwave_radiation_sum  et0_fao_evapotranspiration
```

The variable lists are overridable with `SKY_CURRENT`, `SKY_HOURLY` and
`SKY_DAILY`; anything Open-Meteo can return can therefore come through this
library. `--csv` / `sky_weather_csv` gives the unmodified provider response
when the normalized form is not enough.

### `place` and `where`

```json
[
  {
    "name": "Paris",
    "label": "Paris, Île-de-France Region, France",
    "id": 2988507,
    "latitude": 48.85341,
    "longitude": 2.3488,
    "elevation": 42.0,
    "timezone": "Europe/Paris",
    "country": "France",
    "country_code": "FR",
    "admin1": "Île-de-France Region",
    "admin2": "Paris Department",
    "population": 2138551,
    "feature_code": "PPLC"
  }
]
```

`where` is the same shape as one result, plus `city`, `region` and `label`,
without `id`/`population`.

### `wmo`

```json
{ "code": 61, "description": "Slight rain", "kind": "rain" }
```

With no code, an array of all 28 WMO codes Open-Meteo emits, in table order.

## Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `SKY_LIB_DIR` | `/usr/local/lib/slopology` | where `sky.sh` and `sky.awk` live |
| `SKY_AWK` | `awk` | awk to run |
| `SKY_UNITS` | `metric` | `metric` or `imperial` |
| `SKY_DAYS` | `7` | forecast days |
| `SKY_HOURS` | `25` | forecast hours |
| `SKY_LANG` | `en` | geocoder language |
| `SKY_MAX_AGE` | `900` | cache lifetime in seconds |
| `SKY_CACHE` | `1` | `0` disables the forecast cache |
| `SKY_CACHE_DIR` | `$XDG_CACHE_HOME/slopology` | cache location |
| `SKY_OFFLINE` | `0` | `1` = cache only |
| `SKY_REFRESH` | `0` | `1` = ignore a fresh cache entry |
| `SKY_FETCH_CMD` | — | shell snippet that prints a URL's body; `$1` is the URL |
| `SKY_CURRENT`, `SKY_HOURLY`, `SKY_DAILY` | built in | Open-Meteo variable lists |
| `SKY_HOUR12` | `0` | `1` = 12-hour clocks |

The cache is one CSV file plus a timestamp per position, unit system,
forecast length and zone. It is written atomically and only used when it is
younger than `SKY_MAX_AGE`; a failed fetch never overwrites a good entry.
Set `SKY_CACHE_DIR` per user or per application to keep forecasts apart.

## Accuracy

- Sun and twilight times come from NOAA's general solar-position equations:
  typically within a minute or two of published tables, at any latitude,
  without a network. They account for the standard −0.833° refraction at the
  horizon and for the observer's longitude, not for local terrain or unusual
  refraction.
- Zone offsets and DST come from the system's tzdata, so they are correct for
  any IANA zone as long as tzdata is installed and `date` can read an
  arbitrary epoch. On stripped-down systems the fallback is the current offset.
  A solar day is formatted with the offset in force at **local noon**, because
  daylight-saving switches happen at night; on the two transition days a
  twilight that falls before the switch can be an hour out, while sunrise,
  sunset and every phase instant are exact.
- The forecast is Open-Meteo's model output; resolution, update cadence and
  the absence of a station are theirs.
- The network position is whatever ipapi.co (then ip-api.com) says the public
  address is — behind a VPN that is the VPN, and behind CGNAT it may be a
  city far away.

## Tests

```sh
make test          # sh tests/run.sh
SKY_LIVE=1 make test
```

The suite covers calendar arithmetic (including pre-1970 dates), DST and
quarter-hour zones, published sunrise/sunset values for Paris, Sydney,
Reykjavik, Quito and Tromsø, midnight sun and polar night, twilight in polar
night, phase boundaries, the night window, WMO codes, unit conversions, the
JSON reader, geocoding and IP fixtures, caching with the network removed, and
the CLI. It needs no network unless `SKY_LIVE=1`.

## Using it from a desktop shell

Quickshell (Lucid), Waybar and anything else can call the CLI and parse its
JSON; `examples/quickshell/Sky.qml` is a singleton that does exactly that.
`examples/waybar-sun.sh` and `examples/night-light.sh` are small,
copy-pasteable schedules. The library is also a normal shell function set,
so a `cron` job or a `systemd` timer needs nothing else:

```sh
#!/bin/sh
. /usr/local/lib/slopology/sky.sh
case $(sky_night now 48.8566 2.3522 Europe/Paris | sky_json_get active) in
    true)  hyprctl hyprsunset temperature 3500 ;;
    false) hyprctl hyprsunset identity ;;
esac
```

## Data and licence

- Forecast and geocoding: [Open-Meteo](https://open-meteo.com/), CC BY 4.0.
  A free, keyless service; please keep the attribution if you redistribute.
- Network position: [ipapi.co](https://ipapi.co/) and
  [ip-api.com](https://ip-api.com/), used only when no coordinates are given.
- Solar position: NOAA Solar Calculator equations (public domain).
- Code: MIT, see [LICENSE](LICENSE).

`slopology` was extracted from [Lucid](https://github.com/Sn3akyy1/lucid),
the Material 3 desktop shell, where it drives the bar clock, the lock screen,
the weather widgets and the night light schedule.
