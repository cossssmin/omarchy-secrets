import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon for the Secrets window: shows lock state and toggles the window.
BarWidget {
  id: root
  moduleName: "cossssmin.secrets"

  property bool unlocked: false
  readonly property string cli: decodeURIComponent(Qt.resolvedUrl("bin/secrets").toString().replace(/^file:\/\//, ""))

  function toggle() {
    Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "cossssmin.secrets"])
    statusTimer.restart()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Lock state changes in the window or a terminal; poll it cheaply.
  Timer {
    id: statusTimer
    interval: 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: statusProc.running = true
  }

  Process {
    id: statusProc
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.unlocked = JSON.parse(text).unlocked === true } catch (e) { root.unlocked = false }
      }
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.unlocked ? String.fromCodePoint(0xF0FC6) : String.fromCodePoint(0xF033E)
    tooltipText: root.unlocked ? "Secrets (unlocked)" : "Secrets"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }
}
