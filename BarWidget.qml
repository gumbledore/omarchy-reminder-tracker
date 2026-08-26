import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The ambient half of the design: since firing never completes an item, an
// overdue reminder needs somewhere to keep nagging from. One glyph, one count,
// click to open the list.
BarWidget {
  id: root
  moduleName: "gumbledore.reminders"

  readonly property string homePath: Quickshell.env("HOME")
  readonly property string remPath: homePath + "/.local/bin/rem"
  readonly property string itemsPath: (Quickshell.env("XDG_STATE_HOME") || (homePath + "/.local/state"))
    + "/rem/items.json"

  property int openCount: 0
  property int overdueCount: 0
  property string tooltip: "Reminders"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    if (!jsonProc.running) jsonProc.running = true
  }

  function update(raw) {
    var data = ({})
    try { data = JSON.parse(String(raw || "{}")) } catch (e) { data = ({}) }
    root.openCount = Number(data.count || 0)
    root.overdueCount = Number(data.overdue || 0)
    root.tooltip = String(data.tooltip || "Reminders")
  }

  Component.onCompleted: refresh()

  // No IpcHandler here: the plugin id is already claimed as an IPC target by
  // the overlay, so a second handler on "gumbledore.reminders" is silently dropped
  // (and warns on every startup). Nothing needs to poke this widget anyway —
  // the two triggers below cover both reasons the count can change: the store
  // was edited (file change), or time passed and something is now overdue.
  // store was edited (file change), or time simply passed and something is now
  // overdue (timer).
  FileView {
    path: root.itemsPath
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: jsonProc
    command: [root.remPath, "ls", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.update(text)
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        root.openCount = 0
        root.overdueCount = 0
      }
    }
  }

  BarIconButton {
    id: button
    bar: root.bar
    // Overdue is the only state worth colouring; "3 things on the list" is
    // information, not an alarm.
    active: root.overdueCount > 0
    useActiveColor: true
    text: root.openCount > 0 ? "󰢌 " + root.openCount : "󰢌"
    tooltipText: root.tooltip
    dimmed: root.openCount === 0
    onPressed: Quickshell.execDetached([root.remPath, "show-overlay"])
  }
}
