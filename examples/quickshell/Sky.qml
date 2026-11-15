pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// A Quickshell singleton over the slopology CLI. Drop it next to your shell,
// set `latitude`, `longitude` and `timezone` (or use the place lookup), and
// read `sun` / `weather` from anywhere in QML.
//
//   import qs.Sky
//   text: Sky.sun ? Sky.sun.sunrise.iso : ""
//
// The CLI prints JSON; QML parses it. One process per refresh, no QML plugin,
// no compiled module, and the same binary works in Waybar and in a terminal.
Singleton {
    id: root

    property string latitude: "48.8566"
    property string longitude: "2.3522"
    property string timezone: "Europe/Paris"

    // Set these to override the binary or its location.
    property string binary: "slopology"
    property var binaryArgs: []

    property var sun: null
    property var weather: null
    property var night: null
    property string error: ""

    readonly property bool ready: root.sun !== null

    function refreshSun() {
        sunProc.running = false;
        sunProc.running = true;
    }

    function refreshWeather() {
        weatherProc.running = false;
        weatherProc.running = true;
    }

    function refreshNight() {
        nightProc.running = false;
        nightProc.running = true;
    }

    function refresh() {
        root.refreshSun();
        root.refreshNight();
        root.refreshWeather();
    }

    function args(command) {
        return [root.binary].concat(root.binaryArgs).concat([
            command, "--json",
            "--lat", root.latitude,
            "--lon", root.longitude,
            "--tz", root.timezone
        ]);
    }

    Component.onCompleted: root.refresh()

    Process {
        id: sunProc
        command: root.args("sun")

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.sun = JSON.parse(this.text);
                    root.error = "";
                } catch (e) {
                    root.error = "slopology sun: " + e;
                }
            }
        }

        onExited: (code) => {
            if (code !== 0)
                root.error = "slopology sun exited " + code;
        }
    }

    Process {
        id: nightProc
        command: root.args("night")

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.night = JSON.parse(this.text);
                } catch (e) {
                }
            }
        }
    }

    Process {
        id: weatherProc
        command: root.args("weather")

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.weather = JSON.parse(this.text);
                } catch (e) {
                    root.weather = null;
                }
            }
        }
    }

    // A minute is plenty for the sun; the forecast does not move faster than
    // the service updates it, so the CLI's own cache handles the rest.
    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: root.refreshSun()
    }

    Timer {
        interval: 600000
        running: true
        repeat: true
        onTriggered: {
            root.refreshNight();
            root.refreshWeather();
        }
    }
}
