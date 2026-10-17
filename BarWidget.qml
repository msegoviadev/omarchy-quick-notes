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

  property int editFocusIndex: 0
  property bool editFieldActive: false

  property bool suppressSave: false

  // True once the on-disk notes have been read (or the file is confirmed
  // absent). Writes are refused until then: a plugin reload while the panel
  // is open would otherwise persist an not-yet-loaded empty list and wipe
  // every saved note.
  property bool notesLoaded: false

  // Restored when the panel reopens so the editor keeps its caret.
  property int savedTitleCursor: 0
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

  readonly property bool editCursorOnBack: root.view === "edit" && root.cursorActive && !root.editFieldActive && root.editFocusIndex === 0
  readonly property bool editCursorOnTitle: root.view === "edit" && root.cursorActive && !root.editFieldActive && root.editFocusIndex === 1
  readonly property bool editCursorOnBody: root.view === "edit" && root.cursorActive && !root.editFieldActive && root.editFocusIndex === 2
  readonly property bool editCursorOnDelete: root.view === "edit" && root.cursorActive && !root.editFieldActive && root.editFocusIndex === 3

  function makeId() {
    return Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
  }

  function findNote(id) {
    for (var i = 0; i < root.notes.length; i++) {
      if (root.notes[i].id === id) return root.notes[i]
    }
    return null
  }

  function noteHasTitle(note) {
    return String((note && note.title) || "").trim() !== ""
  }

  // A note without a title shows the start of its body instead, so the list
  // reads like the first line of the note.
  function noteTitleFor(note) {
    var t = String((note && note.title) || "").trim()
    if (t !== "") return t
    var b = String((note && note.body) || "").replace(/\s+/g, " ").trim()
    if (b === "") return "New note"
    return b.length > 50 ? b.slice(0, 50) + "…" : b
  }

  function notePreviewFor(note) {
    var b = String((note && note.body) || "").replace(/\s+/g, " ").trim()
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
    titleField.text = n ? n.title : ""
    bodyArea.text = n ? n.body : ""
    root.suppressSave = false
    root.view = "edit"
    // Start in the body, like Raycast: the title is optional and falls back
    // to the first characters written here.
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

  function handleEditorFieldEscape() {
    if (root.confirmDeleteId !== "") { root.cancelDeleteConfirm(); return }
    root.editFieldActive = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function commitEdit() {
    if (root.editingId === "") return
    var id = root.editingId
    var title = titleField.text.slice(0, root.maxTitleLength)
    var body = bodyArea.text.slice(0, root.maxBodyLength)
    root.notes = root.notes.map(function(n) {
      if (n.id !== id) return n
      return { id: n.id, title: title, body: body, updatedAt: Date.now() }
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
    root.editFieldActive = false
    root.editFocusIndex = 0
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function requestDelete(id) {
    root.confirmDeleteId = id
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
      root.editFieldActive = false
      root.editFocusIndex = 0
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

  function handleEditMove(dx, dy) {
    if (root.confirmDeleteId !== "") return
    if (!root.cursorActive) { root.cursorActive = true; return }
    var delta = dx !== 0 ? dx : dy
    root.editFocusIndex = Math.max(0, Math.min(3, root.editFocusIndex + delta))
  }

  function handleEditActivate() {
    if (root.confirmDeleteId !== "" || !root.cursorActive) return
    if (root.editFocusIndex === 0) { root.goBack(); return }
    if (root.editFocusIndex === 1) { titleField.forceActiveFocus(); return }
    if (root.editFocusIndex === 2) { bodyArea.forceActiveFocus(); return }
    if (root.editFocusIndex === 3) { if (root.editingId !== "") root.requestDelete(root.editingId); return }
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
    root.savedTitleCursor = titleField.cursorPosition
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
        if (root.editFieldActive) root.restoreFieldFocus()
        else if (keyCatcher) keyCatcher.forceActiveFocus()
      } else if (keyCatcher) {
        keyCatcher.forceActiveFocus()
      }
    })
  }

  function restoreFieldFocus() {
    if (root.editFocusIndex === 2) {
      bodyArea.forceActiveFocus()
      bodyArea.cursorPosition = Math.min(root.savedBodyCursor, bodyArea.length)
    } else {
      titleField.forceActiveFocus()
      titleField.cursorPosition = Math.min(root.savedTitleCursor, titleField.length)
    }
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
    preload: false
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadNotesText(text())
    onLoadFailed: root.loadNotesText("[]")
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
      blocked: root.view === "edit" && root.editFieldActive

      onMoveRequested: function(dx, dy) {
        if (root.view === "list") root.handleMove(dx, dy)
        else root.handleEditMove(dx, dy)
      }
      onActivateRequested: {
        if (root.view === "list") root.handleActivate()
        else root.handleEditActivate()
      }
      onCloseRequested: root.handlePanelClose()
      onDeleteRequested: if (root.view === "list") root.handleDeleteKey()
      onTabRequested: function(direction) { if (root.view === "list") root.switchPanel(direction) }
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
                  visible: root.noteHasTitle(noteRow.modelData) && text !== ""
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
              hasCursor: root.editCursorOnBack
              onClicked: root.goBack()
              onHovered: function(h) { if (h) { root.cursorActive = true; root.editFocusIndex = 0 } }
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
              hasCursor: root.editCursorOnDelete
              onClicked: if (root.editingId !== "") root.requestDelete(root.editingId)
              onHovered: function(h) { if (h) { root.cursorActive = true; root.editFocusIndex = 3 } }
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

          TextField {
            id: titleField
            width: parent.width
            placeholderText: "Title"
            foreground: root.barForeground
            font.pixelSize: Style.font.title
            maximumLength: root.maxTitleLength
            hasCursor: root.editCursorOnTitle

            onTextChanged: if (!root.suppressSave) root.scheduleSave()
            onActiveFocusChanged: if (activeFocus) {
              root.editFieldActive = true
              root.cursorActive = true
              root.editFocusIndex = 1
            }

            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.handleEditorFieldEscape()
                event.accepted = true
              }
            }
          }

          BorderSurface {
            id: bodyBox
            width: parent.width
            height: Style.space(240)
            radius: Style.cornerRadius
            color: root.editCursorOnBody ? Style.hoverFill : Style.normalFill
            borderSpec: Border.controlSpec(root.editCursorOnBody ? "hover-cursor" : "normal", root.barForeground, Color.accent)
            padding: Style.spacing.controlPaddingX

            ScrollView {
              anchors.fill: parent
              clip: true

              TextArea {
                id: bodyArea
                width: bodyBox.width - Style.spacing.controlPaddingX * 2
                wrapMode: TextArea.Wrap
                textFormat: TextEdit.PlainText
                placeholderText: "Write your note…"
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
                  root.editFieldActive = true
                  root.cursorActive = true
                  root.editFocusIndex = 2
                }

                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    root.handleEditorFieldEscape()
                    event.accepted = true
                  }
                }
              }
            }
          }
        }
      }

      ConfirmDialog {
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
