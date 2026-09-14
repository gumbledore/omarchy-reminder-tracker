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
//
// Tab flips to the Notes tab: the same card, wider, with note titles down the
// left and the selected note's body wrapped on the right. Notes are read here
// and written in $EDITOR — Enter hands off to a terminal and the overlay gets
// out of the way.
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

  // "reminders" or "notes". Always opens on reminders: triage first. The
  // derived flag must not be called onNotes: QML reads an "on" + capital name
  // as a signal handler and silently never binds it.
  property string tab: "reminders"
  readonly property bool notesTab: tab === "notes"

  // Anything larger than this from `rem` is treated as garbage rather than
  // handed to JSON.parse. The worst legitimate `ls --json` (500 items of 500
  // four-byte characters plus framing) is a little over 1 MiB.
  readonly property int maxOutputBytes: 4 * 1024 * 1024
  // Mirrors MAX_INPUT in `rem`: the filter line is also what gets passed to it.
  readonly property int maxFilterLength: 800

  property var items: []
  property int selectedIndex: 0
  property int nowSeconds: 0
  property string createPreview: ""
  property bool createValid: false

  property var notes: []

  readonly property bool creating: !notesTab && ReminderFlowModel.isCreateIntent(filterText)
  readonly property var visibleItems: notesTab ? [] : ReminderFlowModel.visibleItems(items, filterText)
  readonly property var visibleNotes: notesTab ? ReminderFlowModel.visibleNotes(notes, filterText) : []
  readonly property int visibleCount: notesTab ? visibleNotes.length : visibleItems.length
  // Typing something no existing item matches is itself a create gesture — it
  // saves an explicit "new item" key and reads naturally. Same on the Notes
  // tab, where the typed text becomes the new note's title.
  readonly property bool canCreate: creating || (filterText.length > 0 && visibleCount === 0)

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
  readonly property int listHeight: notesTab
    ? maxVisibleRows * rowHeight
    : Math.max(rowHeight, Math.min(visibleItems.length, maxVisibleRows) * rowHeight)
  readonly property int cardWidth: Style.space(notesTab ? 760 : 460)
  readonly property int titleColumnWidth: Style.space(240)

  readonly property string promptText: root.mode === "snooze"
    ? "Snooze for… (2h, 3d, tomorrow 9am)"
    : (root.notesTab ? "Filter notes, or type a title for a new one…" : "Filter, or type a new item…")

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    if (payload.fontFamily) root.fontFamily = payload.fontFamily

    root.opened = true
    root.mode = "list"
    root.tab = "reminders"
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
    if (root.notesTab) {
      if (!notesProc.running) notesProc.running = true
    } else if (!listProc.running) {
      listProc.running = true
    }
  }

  function switchTab() {
    root.tab = root.notesTab ? "reminders" : "notes"
    root.filterText = ""
    root.createPreview = ""
    root.selectedIndex = 0
    root.reload()
  }

  function parseOutput(raw) {
    var text = String(raw || "")
    if (text.length > root.maxOutputBytes) return ({})
    try { return JSON.parse(text || "{}") } catch (e) { return ({}) }
  }

  function applyList(raw) {
    var data = root.parseOutput(raw)
    root.items = ReminderFlowModel.sanitizeItems(data.items)
    root.nowSeconds = Math.floor(Date.now() / 1000)
    root.clampSelection()
  }

  function applyNotes(raw) {
    var data = root.parseOutput(raw)
    root.notes = ReminderFlowModel.sanitizeNotes(data.notes)
    root.clampSelection()
  }

  function clampSelection() {
    var count = root.visibleCount
    if (count === 0) root.selectedIndex = 0
    else if (root.selectedIndex >= count) root.selectedIndex = count - 1
    else if (root.selectedIndex < 0) root.selectedIndex = 0
  }

  function selectedItem() {
    var list = root.visibleItems
    if (root.selectedIndex < 0 || root.selectedIndex >= list.length) return null
    return list[root.selectedIndex]
  }

  function selectedNote() {
    var list = root.visibleNotes
    if (root.selectedIndex < 0 || root.selectedIndex >= list.length) return null
    return list[root.selectedIndex]
  }

  function setFilter(nextFilter) {
    root.filterText = String(nextFilter).slice(0, root.maxFilterLength)
    root.selectedIndex = 0
    if (root.mode === "list" && !root.notesTab) previewTimer.restart()
  }

  // Writing a note is the editor's job. The overlay closes, a terminal opens
  // on `rem note …`, and nothing reopens when the editor exits.
  function handOffToEditor(args) {
    root.dismiss()
    Quickshell.execDetached(["omarchy-launch-terminal", root.remPath, "note"].concat(args))
  }

  function editSelectedNote() {
    var note = root.selectedNote()
    if (!note) return
    root.handOffToEditor(["edit", String(note.id)])
  }

  function createNoteFromFilter() {
    var title = root.filterText.trim()
    if (!title) return
    root.handOffToEditor(["add", title])
  }

  function removeSelectedNote() {
    var note = root.selectedNote()
    if (!note) return
    root.run(["note", "rm", String(note.id)])
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
    if (root.notesTab) {
      if (root.canCreate) root.createNoteFromFilter()
      else if (root.visibleNotes.length === 0) root.dismiss()
      else root.editSelectedNote()
      return
    }
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
    id: notesProc
    command: [root.remPath, "note", "ls", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyNotes(text)
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
        var data = root.parseOutput(text)
        root.createPreview = String(data.preview || "").slice(0, 200)
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
      width: Math.min(root.cardWidth, panel.width - Style.gapsOut * 2)
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

          // Escape is a strict walk toward closed: prompt, filter, tab, gone.
          if (event.key === Qt.Key_Escape) {
            if (root.mode === "snooze") { root.mode = "list"; root.filterText = "" }
            else if (root.filterText) root.setFilter("")
            else if (root.notesTab) root.switchTab()
            else root.dismiss()
            event.accepted = true
          } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
            if (root.mode === "list") root.switchTab()
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.selectedIndex = Math.max(0, Math.min(root.selectedIndex + 1, root.visibleCount - 1))
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.selectedIndex = Math.max(root.selectedIndex - 1, 0)
            event.accepted = true
          } else if (ctrl && event.key === Qt.Key_Z) {
            if (!root.notesTab) root.run(["undo"])
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            if (root.notesTab) root.removeSelectedNote()
            else root.dropSelected()
            event.accepted = true
          } else if (ctrl && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
            if (!root.notesTab) root.beginSnooze()
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
            textFormat: Text.PlainText
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
              : root.notesTab
                ? (root.canCreate
                   ? "↳ new note “" + root.filterText.trim() + "” — Enter opens your editor"
                   : (root.notes.length === 0 ? "No notes. Type a title and press Enter." : ""))
                : (root.canCreate
                   ? "↳ " + (root.createPreview || "…")
                   : (root.items.length === 0 ? "Nothing open. Type to add one." : ""))
            color: root.notesTab || root.createValid || !root.canCreate ? root.foreground : Color.menu.text
            textFormat: Text.PlainText
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

          // Notes: titles down the left, the selected body wrapped on the
          // right. Both are plain text; a note titled <b> is titled <b>.
          Item {
            anchors.fill: parent
            visible: root.notesTab

            ListView {
              id: noteList
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: root.titleColumnWidth
              model: root.visibleNotes
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              currentIndex: root.selectedIndex
              highlightMoveDuration: 0
              onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

              delegate: BorderSurface {
                id: noteRow
                required property int index
                required property var modelData

                readonly property bool hasCursor: noteRow.index === root.selectedIndex

                width: ListView.view.width
                height: root.rowHeight
                radius: root.cornerRadius
                color: noteRow.hasCursor ? root.selectedBackground : "transparent"
                borderSpec: noteRow.hasCursor ? root.borderSpec : Border.none()

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.selectedIndex = noteRow.index
                }

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: noteRow.modelData ? noteRow.modelData.id + "  " + noteRow.modelData.title : ""
                  textFormat: Text.PlainText
                  color: noteRow.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
              }
            }

            Flickable {
              id: bodyPane
              anchors.left: noteList.right
              anchors.leftMargin: Style.space(12)
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              clip: true
              contentWidth: width
              contentHeight: bodyText.implicitHeight
              boundsBehavior: Flickable.StopAtBounds
              onContentHeightChanged: contentY = 0

              Text {
                id: bodyText
                width: bodyPane.width
                text: root.selectedNote() ? root.selectedNote().body : ""
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          ListView {
            id: resultList
            visible: !root.notesTab
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
                textFormat: Text.PlainText
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
                textFormat: Text.PlainText
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
            text: root.notesTab
              ? (root.canCreate
                 ? "Enter  new note    Tab  reminders"
                 : "Enter  edit    Del  remove    Tab  reminders")
              : (root.canCreate
                 ? "Enter  add    •    “text @ fri 2pm” to schedule    Tab  notes"
                 : "Enter  done    Ctrl+Enter  snooze    Del  drop    Ctrl+Z  undo    Tab  notes")
            textFormat: Text.PlainText
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
