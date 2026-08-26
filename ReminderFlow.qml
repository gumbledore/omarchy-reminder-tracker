import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "ReminderFlowModel.js" as ReminderFlowModel

// The reminder list. One surface for both jobs: the filter line is the search
// box AND the new-item field, so seeing what is open and adding to it are the
// same gesture. Nothing here writes items.json — every mutation goes through
// `rem`, which is the only writer.
Item {
  id: root

  property string homePath: Quickshell.env("HOME")
  readonly property string remPath: homePath + "/.local/bin/rem"
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string filterText: ""
  property string fontFamily: Style.font.menuFamily

  // "list" is the resting state. "snooze" is a one-shot prompt that borrows
  // the same filter line rather than opening a second surface.
  property string mode: "list"
  property int snoozeTargetId: -1

  property var items: []
  property int selectedIndex: 0
  property int nowSeconds: 0
  property string createPreview: ""
  property bool createValid: false

  readonly property bool creating: ReminderFlowModel.isCreateIntent(filterText)
  readonly property var visibleItems: ReminderFlowModel.visibleItems(items, filterText)
  // Typing something no existing item matches is itself a create gesture — it
  // saves an explicit "new item" key and reads naturally.
  readonly property bool canCreate: creating || (filterText.length > 0 && visibleItems.length === 0)

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  readonly property int rowHeight: Style.space(34)
  readonly property int headerHeight: Style.space(34)
  readonly property int previewHeight: Style.space(20)
  readonly property int footerHeight: Style.space(20)
  readonly property int maxVisibleRows: 10
  readonly property int listHeight: Math.max(rowHeight, Math.min(visibleItems.length, maxVisibleRows) * rowHeight)

  readonly property string promptText: root.mode === "snooze"
    ? "Snooze for… (2h, 3d, tomorrow 9am)"
    : "Filter, or type a new item…"

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.fontFamily) root.fontFamily = payload.fontFamily

    root.opened = true
    root.mode = "list"
    root.snoozeTargetId = -1
    root.filterText = ""
    root.selectedIndex = 0
    root.reload()

    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  function close() { root.opened = false }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "gumbledore.reminders")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function reload() {
    root.nowSeconds = Math.floor(Date.now() / 1000)
    if (!listProc.running) listProc.running = true
  }

  function applyList(raw) {
    var data = ({})
    try { data = JSON.parse(String(raw || "{}")) } catch (e) { data = ({}) }
    root.items = Array.isArray(data.items) ? data.items : []
    root.nowSeconds = Math.floor(Date.now() / 1000)
    root.clampSelection()
  }

  function clampSelection() {
    var count = root.visibleItems.length
    if (count === 0) root.selectedIndex = 0
    else if (root.selectedIndex >= count) root.selectedIndex = count - 1
    else if (root.selectedIndex < 0) root.selectedIndex = 0
  }

  function selectedItem() {
    var list = root.visibleItems
    if (root.selectedIndex < 0 || root.selectedIndex >= list.length) return null
    return list[root.selectedIndex]
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    if (root.mode === "list") previewTimer.restart()
  }

  // Every mutation is a `rem` call followed by a reload, so the overlay never
  // holds an opinion about state that the store has not confirmed.
  function run(args) {
    actionProc.command = [root.remPath].concat(args)
    actionProc.running = true
  }

  function createFromFilter() {
    var text = root.filterText.trim()
    if (!text) return
    root.run(["add", text])
    root.setFilter("")
    root.createPreview = ""
  }

  function completeSelected() {
    var item = root.selectedItem()
    if (!item) return
    root.run(["done", String(item.id)])
  }

  function dropSelected() {
    var item = root.selectedItem()
    if (!item) return
    root.run(["rm", String(item.id)])
  }

  function beginSnooze() {
    var item = root.selectedItem()
    if (!item) return
    root.snoozeTargetId = item.id
    root.mode = "snooze"
    root.filterText = ""
    root.createPreview = ""
  }

  function commitSnooze() {
    var args = ReminderFlowModel.snoozeArgs(root.snoozeTargetId, root.filterText)
    root.mode = "list"
    root.snoozeTargetId = -1
    root.filterText = ""
    if (args.length) root.run(args)
  }

  function submit() {
    if (root.mode === "snooze") { root.commitSnooze(); return }
    if (root.canCreate) { root.createFromFilter(); return }
    if (root.visibleItems.length === 0) { root.dismiss(); return }
    root.completeSelected()
  }

  Process {
    id: listProc
    command: [root.remPath, "ls", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyList(text)
    }
  }

  Process {
    id: actionProc
    onExited: root.reload()
  }

  // The preview resolves "@ when" through `rem parse`, which is one subprocess
  // per keystroke if left unguarded — hence the debounce.
  Process {
    id: parseProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var data = ({})
        try { data = JSON.parse(String(text || "{}")) } catch (e) { data = ({}) }
        root.createPreview = String(data.preview || "")
        root.createValid = data.ok === true
      }
    }
  }

  Timer {
    id: previewTimer
    interval: 150
    onTriggered: {
      if (!root.canCreate) { root.createPreview = ""; return }
      parseProc.command = [root.remPath, "parse", root.filterText]
      parseProc.running = true
    }
  }

  // Keeps "in 3m" and the OVERDUE flip honest while the panel sits open.
  Timer {
    running: root.opened
    interval: 15000
    repeat: true
    onTriggered: root.nowSeconds = Math.floor(Date.now() / 1000)
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "reminder-tracker"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(460), panel.width - Style.gapsOut * 2)
      height: Math.min(root.contentMargin * 2 + root.headerHeight + root.previewHeight
                       + (root.mode === "snooze" ? 0 : root.listHeight + root.footerHeight),
                       panel.height - Style.gapsOut * 2)
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0

          if (event.key === Qt.Key_Escape) {
            if (root.mode === "snooze") { root.mode = "list"; root.filterText = "" }
            else if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.selectedIndex = Math.min(root.selectedIndex + 1, root.visibleItems.length - 1)
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.selectedIndex = Math.max(root.selectedIndex - 1, 0)
            event.accepted = true
          } else if (ctrl && event.key === Qt.Key_Z) {
            root.run(["undo"])
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            root.dropSelected()
            event.accepted = true
          } else if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
            root.beginSnooze()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.submit()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.text && event.text.length === 1
                     && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: 0

        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || root.promptText
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: root.previewHeight

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: text.length > 0
            text: root.mode === "snooze"
              ? "Enter to snooze, Esc to cancel"
              : (root.canCreate
                 ? "↳ " + (root.createPreview || "…")
                 : (root.items.length === 0 ? "Nothing open. Type to add one." : ""))
            color: root.createValid || !root.canCreate ? root.foreground : Color.menu.text
            opacity: 0.62
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Item {
          width: parent.width
          height: root.mode === "snooze" ? 0 : root.listHeight
          visible: root.mode !== "snooze"
          clip: true

          ListView {
            id: resultList
            anchors.fill: parent
            model: root.visibleItems
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            currentIndex: root.selectedIndex
            highlightMoveDuration: 0
            onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

            delegate: BorderSurface {
              id: row
              required property int index
              required property var modelData

              readonly property bool hasCursor: row.index === root.selectedIndex
              readonly property string dueText: ReminderFlowModel.dueLabel(row.modelData, root.nowSeconds)
              readonly property bool isOverdue: row.modelData && row.modelData.overdue === true

              width: ListView.view.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: row.hasCursor ? root.selectedBackground : "transparent"
              borderSpec: row.hasCursor ? root.borderSpec : Border.none()

              MouseArea {
                anchors.fill: parent
                onClicked: {
                  root.selectedIndex = row.index
                  root.completeSelected()
                }
              }

              Text {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.right: dueLabel.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: row.modelData ? row.modelData.text : ""
                color: row.hasCursor ? root.selectedText : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                id: dueLabel
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: row.dueText
                color: row.hasCursor ? root.selectedText : root.foreground
                opacity: row.isOverdue ? 1 : 0.55
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: row.isOverdue
              }
            }
          }
        }

        Item {
          width: parent.width
          height: root.mode === "snooze" ? 0 : root.footerHeight
          visible: root.mode !== "snooze"

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.canCreate
              ? "Enter  add    •    “text @ fri 2pm” to schedule"
              : "Enter  done    Ctrl+Enter  snooze    Del  drop    Ctrl+Z  undo"
            color: root.foreground
            opacity: 0.42
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }
}
