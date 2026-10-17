import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "quick-notes"
  ipcTarget: "quick-notes"

  property var notes: []
  property string view: "list"
  property string editingId: ""
  property string confirmDeleteId: ""

  property int selectedIndex: -1
  property bool cursorActive: false

  property bool suppressSave: false

  // True once the on-disk notes have been read (or the file is confirmed
  // absent). Writes are refused until then: a plugin reload while the panel
  // is open would otherwise persist an not-yet-loaded empty list and wipe
  // every saved note.
  property bool notesLoaded: false

  // Restored when the panel reopens so the editor keeps its caret.
  property int savedBodyCursor: 0

  readonly property int maxNotes: 500
  readonly property int maxTitleLength: 200
  readonly property int maxBodyLength: 20000
  readonly property int maxFileBytes: 12 * 1024 * 1024

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/plugins/" + root.moduleName
  readonly property string notesPath: root.stateDir + "/notes.json"

  readonly property var sortedNotes: {
    var arr = root.notes.slice()
    arr.sort(function(a, b) { return (b.updatedAt || 0) - (a.updatedAt || 0) })
    return arr
  }

  function makeId() {
    return Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
  }

  function findNote(id) {
    for (var i = 0; i < root.notes.length; i++) {
      if (root.notes[i].id === id) return root.notes[i]
    }
    return null
  }

  // The first non-empty line of the body is the note title.
  function noteTitleFor(note) {
    var lines = String((note && note.body) || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line !== "") return line.length > 60 ? line.slice(0, 60) + "…" : line
    }
    var t = String((note && note.title) || "").trim()
    return t !== "" ? t : "New note"
  }

  // Everything below the title line is the preview.
  function notePreviewFor(note) {
    var lines = String((note && note.body) || "").split("\n")
    var first = -1
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim() !== "") { first = i; break }
    }
    if (first === -1) return ""
    var b = lines.slice(first + 1).join(" ").replace(/\s+/g, " ").trim()
    return b.length > 72 ? b.slice(0, 72) + "…" : b
  }

  function sanitizeNote(raw) {
    if (!raw || typeof raw !== "object") return null
    var id = typeof raw.id === "string" && raw.id !== "" ? raw.id : root.makeId()
    var title = typeof raw.title === "string" ? raw.title.slice(0, root.maxTitleLength) : ""
    var body = typeof raw.body === "string" ? raw.body.slice(0, root.maxBodyLength) : ""
    var updatedAt = Number(raw.updatedAt)
    if (!isFinite(updatedAt)) updatedAt = 0
    return { id: id, title: title, body: body, updatedAt: updatedAt }
  }

  function loadNotesText(text) {
    if (typeof text !== "string") { root.notes = []; return }
    if (text.trim() === "") { root.notes = []; root.notesLoaded = true; return }
    if (text.length > root.maxFileBytes) {
      console.warn("Quick Notes: refusing to load notes.json - " + text.length + " bytes exceeds the " + root.maxFileBytes + " byte limit")
      root.notes = []
      return
    }
    var parsed
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      root.notes = []
      return
    }
    if (!Array.isArray(parsed)) { root.notes = []; return }

    var seenIds = ({})
    var cleaned = []
    for (var i = 0; i < parsed.length; i++) {
      var n = root.sanitizeNote(parsed[i])
      if (!n) continue
      if (seenIds[n.id]) n.id = root.makeId()
      seenIds[n.id] = true
      cleaned.push(n)
    }
    cleaned.sort(function(a, b) { return (b.updatedAt || 0) - (a.updatedAt || 0) })
    if (cleaned.length > root.maxNotes) cleaned = cleaned.slice(0, root.maxNotes)
    root.notes = cleaned
    root.notesLoaded = true
  }

  function checkAndLoad(reason) {
    if (statProc.running) return
    statProc.pendingReason = reason
    statProc.command = ["stat", "-c", "%s", root.notesPath]
    statProc.running = true
  }

  function handleStatResult(output, reason) {
    var size = parseInt(String(output).trim(), 10)
    if (!isFinite(size)) {
      // A missing file only means "no notes" on the very first read. During a
      // normal run the path is briefly absent while an atomic write renames
      // into place, so never treat that as an empty vault.
      if (reason === "initial") { root.notes = []; root.notesLoaded = true }
      return
    }
    if (size > root.maxFileBytes) {
      console.warn("Quick Notes: notes.json is " + size + " bytes, exceeds the " + root.maxFileBytes + " byte limit; refusing to load it.")
      return
    }
    notesFile.reload()
  }

  function persist() {
    if (!root.notesLoaded) {
      console.warn("Quick Notes: refusing to write notes.json before it has been read")
      return
    }
    var payload = JSON.stringify(root.notes, null, 2)
    if (payload.length > root.maxFileBytes) {
      console.warn("Quick Notes: refusing to write notes.json - serialized size exceeds the " + root.maxFileBytes + " byte limit")
      return
    }
    Quickshell.execDetached(["mkdir", "-p", root.stateDir])
    // Best-effort copy of the previous revision, so a bad write can never
    // destroy the whole vault silently.
    Quickshell.execDetached(["cp", "-f", root.notesPath, root.notesPath + ".bak"])
    notesFile.setText(payload)
  }

  function removeNoteInternal(id) {
    root.notes = root.notes.filter(function(n) { return n.id !== id })
  }

  function createNote() {
    if (!root.notesLoaded) return
    if (root.confirmDeleteId !== "" || root.notes.length >= root.maxNotes) return
    var note = { id: root.makeId(), title: "", body: "", updatedAt: Date.now() }
    root.notes = root.notes.concat([note])
    root.openNote(note.id)
  }

  function openNote(id) {
    root.confirmDeleteId = ""
    var n = root.findNote(id)
    root.suppressSave = true
    root.editingId = id
    bodyArea.text = n ? n.body : ""
    root.suppressSave = false
    root.view = "edit"
    // The editor is the body; the first line doubles as the title.
    Qt.callLater(function() {
      bodyArea.forceActiveFocus()
      bodyArea.cursorPosition = bodyArea.length
    })
  }

  function scheduleSave() {
    saveDebounce.restart()
  }

  function saveNow() {
    saveDebounce.stop()
    root.commitEdit()
  }

  function newNoteFromEditor() {
    root.goBack()
    root.createNote()
  }

  function commitEdit() {
    if (root.editingId === "") return
    var id = root.editingId
    var body = bodyArea.text.slice(0, root.maxBodyLength)
    root.notes = root.notes.map(function(n) {
      if (n.id !== id) return n
      return { id: n.id, title: n.title, body: body, updatedAt: Date.now() }
    })
    root.persist()
  }

  function goBack() {
    saveDebounce.stop()
    if (root.editingId !== "") root.commitEdit()
    var n = root.findNote(root.editingId)
    if (n && String(n.title).trim() === "" && String(n.body).trim() === "") {
      root.removeNoteInternal(root.editingId)
      root.persist()
    }
    root.editingId = ""
    root.view = "list"
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function requestDelete(id) {
    root.confirmDeleteId = id
    // Always start on Delete, as asked, so Enter is a one-key confirm.
    confirmDialog.selectedIndex = 1
  }

  function cancelDeleteConfirm() {
    root.confirmDeleteId = ""
  }

  function performDelete() {
    var id = root.confirmDeleteId
    if (id === "") return
    root.confirmDeleteId = ""
    root.removeNoteInternal(id)
    root.persist()
    if (root.editingId === id) {
      root.editingId = ""
      root.view = "list"
    }
    var count = root.sortedNotes.length
    if (root.selectedIndex > count) root.selectedIndex = count
  }

  function handleMove(dx, dy) {
    if (root.confirmDeleteId !== "") return
    var count = root.sortedNotes.length
    if (!root.cursorActive) {
      root.cursorActive = true
      if (root.selectedIndex < 0 || root.selectedIndex > count) root.selectedIndex = count > 0 ? 1 : 0
      return
    }
    var delta = dx !== 0 ? dx : dy
    root.selectedIndex = Math.max(0, Math.min(count, root.selectedIndex + delta))
  }

  function handleActivate() {
    if (root.confirmDeleteId !== "" || !root.cursorActive) return
    if (root.selectedIndex === 0) { root.createNote(); return }
    var list = root.sortedNotes
    var i = root.selectedIndex - 1
    if (i >= 0 && i < list.length) root.openNote(list[i].id)
  }

  function handleDeleteKey() {
    if (root.confirmDeleteId !== "" || !root.cursorActive || root.selectedIndex === 0) return
    var list = root.sortedNotes
    var i = root.selectedIndex - 1
    if (i >= 0 && i < list.length) root.requestDelete(list[i].id)
  }

  function handlePanelClose() {
    if (root.confirmDeleteId !== "") { root.cancelDeleteConfirm(); return }
    if (root.view === "edit") { root.goBack(); return }
    root.close()
  }

  function open() {
    root.controller.show()
  }

  function close() {
    root.savedBodyCursor = bodyArea.cursorPosition
    root.confirmDeleteId = ""
    root.controller.hide()
  }

  function toggle() {
    root.opened ? root.close() : root.open()
  }

  // Reopening keeps whatever the panel showed last: the same note, the same
  // editor/list view, and the same caret position.
  function restoreSession() {
    Qt.callLater(function() {
      if (!root.opened) return
      if (root.view === "edit" && root.editingId !== "" && root.findNote(root.editingId)) {
        bodyArea.forceActiveFocus()
        bodyArea.cursorPosition = Math.min(root.savedBodyCursor, bodyArea.length)
      } else if (keyCatcher) {
        keyCatcher.forceActiveFocus()
      }
    })
  }

  Component.onCompleted: root.checkAndLoad("initial")

  onOpenedChanged: {
    if (root.opened) root.restoreSession()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Timer {
    id: saveDebounce
    interval: 400
    repeat: false
    onTriggered: root.commitEdit()
  }

  Process {
    id: statProc
    property string pendingReason: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleStatResult(text, statProc.pendingReason)
    }
  }

  FileView {
    id: notesFile
    path: root.notesPath
    // preload must stay true: with preload false this FileView never reads the
    // file on its own, and reload() from the stat check is a no-op until a
    // load has happened, so the list started empty and the next save wiped
    // the saved notes. loadNotesText() still enforces the size limit.
    preload: true
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadNotesText(text())
    // Do not treat a failed read as an empty file: handleStatResult() decides
    // that, and only when the file is genuinely absent.
    onLoadFailed: console.warn("Quick Notes: notes.json could not be read")
    onFileChanged: root.checkAndLoad("changed")
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    tooltipText: "Notes (Super+Alt+N)"
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.toggle()
    }
  }

  // Centered overlay instead of a bar-anchored popup: a fullscreen
  // transparent layer-shell surface with the card pinned to the middle of
  // the screen.
  PanelWindow {
    id: panel
    visible: root.opened
    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }
    color: "transparent"
    WlrLayershell.namespace: "quick-notes"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    readonly property real padX: Style.spacing.popupPadding
    readonly property real padY: Style.spacing.popupPadding
    readonly property real sideMargin: Style.gapsOut
    readonly property real availableWidth: Math.max(Style.space(220), width - sideMargin * 2)
    readonly property real availableHeight: Math.max(Style.space(220), height - sideMargin * 2)
    readonly property real cardWidth: Math.min(Style.space(420), availableWidth)

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
      onClicked: root.close()
    }

    Rectangle {
      id: card
      // Horizontally centered, one third of the way down the screen
      // (Raycast-style), clamped so it always stays fully on screen.
      x: Math.round(Math.max(panel.sideMargin, Math.min((panel.width - width) / 2, panel.width - width - panel.sideMargin)))
      y: Math.round(Math.max(panel.sideMargin, Math.min(panel.height / 3 - height / 2, panel.height - height - panel.sideMargin)))
      width: panel.cardWidth
      height: Math.min(mainColumn.implicitHeight + panel.padY * 2, panel.availableHeight)
      color: Color.popups.background
      radius: Style.cornerRadius
      border.color: Color.popups.border
      border.width: Math.max(1, Style.space(2))

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
      }
    }

    PanelKeyCatcher {
      id: keyCatcher
      x: card.x + panel.padX
      y: card.y + panel.padY
      width: card.width - panel.padX * 2
      height: card.height - panel.padY * 2
      // In the editor every key belongs to the text body. The exception is the
      // delete confirmation, which needs h/l and Enter routed to its buttons.
      blocked: root.view === "edit" && root.confirmDeleteId === ""

      onMoveRequested: function(dx, dy) {
        if (root.confirmDeleteId !== "") {
          if (dx !== 0) confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
          return
        }
        if (root.view === "list") root.handleMove(dx, dy)
      }
      onActivateRequested: {
        if (root.confirmDeleteId !== "") {
          if (confirmDialog.selectedIndex === 0) root.cancelDeleteConfirm()
          else root.performDelete()
          return
        }
        if (root.view === "list") root.handleActivate()
      }
      onCloseRequested: root.handlePanelClose()
      onDeleteRequested: if (root.view === "list") root.handleDeleteKey()
      onTabRequested: function(direction) {
        if (root.confirmDeleteId !== "") {
          confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
          return
        }
        if (root.view === "list") root.switchPanel(direction)
      }
      onTextKey: function(t) {
        if (root.view !== "list" || root.confirmDeleteId !== "") return
        if (t === "n" || t === "N") root.createNote()
      }

      Shortcut {
        sequence: "Ctrl+S"
        enabled: root.opened && root.view === "edit"
        onActivated: root.saveNow()
      }

      Shortcut {
        sequence: "Ctrl+N"
        enabled: root.opened
        onActivated: {
          if (root.view === "edit") root.newNoteFromEditor()
          else root.createNote()
        }
      }

      Shortcut {
        sequence: "Ctrl+Backspace"
        enabled: root.opened && root.view === "edit"
        onActivated: if (root.editingId !== "") root.requestDelete(root.editingId)
      }

      Column {
        id: mainColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        Column {
          id: listSection
          visible: root.view === "list"
          width: parent.width
          spacing: Style.space(10)

          Item {
            width: parent.width
            implicitHeight: Math.max(listHeaderLabel.implicitHeight, addButton.implicitHeight)

            PanelSectionHeader {
              id: listHeaderLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "NOTES"
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }

            PanelActionButton {
              id: addButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: ""
              foreground: root.barForeground
              enabled: root.notes.length < root.maxNotes
              hasCursor: root.cursorActive && root.selectedIndex === 0
              onClicked: root.createNote()
              onHovered: function(h) { if (h) { root.cursorActive = true; root.selectedIndex = 0 } }
            }

            Text {
              text: "n"
              color: Qt.darker(root.barForeground, 1.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.right: addButton.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: addButton.verticalCenter
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.barForeground
          }

          ListView {
            id: notesListView
            width: parent.width
            height: Math.min(contentHeight, Style.space(280))
            visible: root.sortedNotes.length > 0
            clip: true
            spacing: Style.space(8)
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            model: root.sortedNotes

            delegate: CursorSurface {
              id: noteRow
              required property var modelData
              required property int index

              width: notesListView.width
              implicitHeight: rowContent.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              hasCursor: root.cursorActive && root.selectedIndex === (index + 1)
              foreground: root.barForeground

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: { root.cursorActive = true; root.selectedIndex = noteRow.index + 1 }
                onClicked: root.openNote(noteRow.modelData.id)
              }

              Column {
                id: rowContent
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.right: deleteRowHint.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  text: root.noteTitleFor(noteRow.modelData)
                  textFormat: Text.PlainText
                  color: root.barForeground
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: root.notePreviewFor(noteRow.modelData)
                  textFormat: Text.PlainText
                  visible: text !== ""
                  color: Qt.darker(root.barForeground, 1.5)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }

              PanelActionButton {
                id: deleteRowButton
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                iconText: ""
                foreground: root.barForeground
                hoverColor: Color.urgent
                onClicked: root.requestDelete(noteRow.modelData.id)
              }

              Text {
                id: deleteRowHint
                text: "x"
                opacity: noteRow.hasCursor ? 1 : 0
                color: Qt.darker(root.barForeground, 1.6)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.bodySmall
                anchors.right: deleteRowButton.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: deleteRowButton.verticalCenter
              }
            }
          }

          Text {
            visible: root.sortedNotes.length === 0
            width: parent.width
            text: "No notes yet. Press n to create one."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Qt.darker(root.barForeground, 1.5)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        Column {
          id: editSection
          visible: root.view === "edit"
          width: parent.width
          spacing: Style.space(10)

          Item {
            width: parent.width
            implicitHeight: Math.max(backButton.implicitHeight, editDeleteButton.implicitHeight)

            PanelActionButton {
              id: backButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              iconText: ""
              foreground: root.barForeground
              onClicked: root.goBack()
            }

            Text {
              text: "Esc"
              color: Qt.darker(root.barForeground, 1.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.left: backButton.right
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: backButton.verticalCenter
            }

            PanelActionButton {
              id: editDeleteButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: ""
              foreground: root.barForeground
              hoverColor: Color.urgent
              onClicked: if (root.editingId !== "") root.requestDelete(root.editingId)
            }

            Text {
              text: "Ctrl+Backspace"
              color: Qt.darker(root.barForeground, 1.6)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.bodySmall
              anchors.right: editDeleteButton.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: editDeleteButton.verticalCenter
            }
          }

          BorderSurface {
            id: bodyBox
            width: parent.width
            height: Style.space(240)
            radius: Style.cornerRadius
            color: Style.normalFill
            borderSpec: Border.controlSpec("normal", root.barForeground, Color.accent)
            padding: Style.spacing.controlPaddingX

            ScrollView {
              anchors.fill: parent
              clip: true

              TextArea {
                id: bodyArea
                width: bodyBox.width - Style.spacing.controlPaddingX * 2
                wrapMode: TextArea.Wrap
                textFormat: TextEdit.PlainText
                placeholderText: "First line becomes the title…"
                color: root.barForeground
                placeholderTextColor: Qt.darker(root.barForeground, 1.6)
                selectionColor: Style.selectionFill
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.body
                background: null

                onTextChanged: {
                  if (text.length > root.maxBodyLength) {
                    var pos = cursorPosition
                    text = text.slice(0, root.maxBodyLength)
                    cursorPosition = Math.min(pos, text.length)
                    return
                  }
                  if (!root.suppressSave) root.scheduleSave()
                }
                onActiveFocusChanged: if (activeFocus) {
                  root.cursorActive = true
                }

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    root.goBack()
                    event.accepted = true
                  }
                }
              }
            }
          }
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 50
        opened: root.confirmDeleteId !== ""
        message: "Delete this note? This can't be undone."
        cancelText: "Cancel"
        confirmText: "Delete"
        background: Color.popups.background
        foreground: root.barForeground
        onCanceled: root.cancelDeleteConfirm()
        onConfirmed: root.performDelete()
      }
    }
  }
}
