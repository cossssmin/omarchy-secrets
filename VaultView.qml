import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The panel body: setup, unlock, the searchable key list, and the editor.
// The host owns the window, sizes this to fill it, and routes
// Up/Down/Escape/Tab here.
Column {
  id: view

  required property var vault
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  readonly property string mode: {
    if (!vault.loaded) return "loading"
    if (!vault.initialized) return "setup"
    if (!vault.unlocked) return "locked"
    return editing ? "edit" : "list"
  }

  property bool editing: false
  property string editOldEnv: ""
  property string editOldKey: ""
  property bool showValue: false

  property int selectedIndex: 0
  property string pendingDelete: ""
  property string copiedId: ""
  property string copiedWhat: ""


  readonly property var filtered: {
    var terms = search.text.toLowerCase().split(/\s+/).filter(function(t) { return t !== "" })
    return vault.entries.filter(function(e) {
      var hay = (e.env + " " + e.key).toLowerCase()
      return terms.every(function(t) { return hay.indexOf(t) !== -1 })
    })
  }

  // `filtered` arrives grouped by env (the CLI lists env by env); the list
  // shows it with a header above each env's keys.
  readonly property var rows: {
    var out = [], group = null
    for (var i = 0; i < filtered.length; i++) {
      var e = filtered[i]
      if (!group || group.env !== e.env) { group = { header: true, env: e.env, count: 0 }; out.push(group) }
      group.count++
      out.push({ header: false, env: e.env, key: e.key, entryIndex: i })
    }
    return out
  }

  spacing: Style.space(10)

  onModeChanged: Qt.callLater(view.focusInput)
  onFilteredChanged: view.selectedIndex = Math.min(view.selectedIndex, Math.max(0, filtered.length - 1))

  Connections {
    target: view.vault
    function onUnlockedNow() { search.text = "" }
    function onUnlockedChanged() { if (!view.vault.unlocked) view.cancelEdit() }
  }

  function focusInput() {
    var target = { setup: setupPass, locked: unlockPass, list: search, edit: editEnv.text === "" ? editEnv : (editKey.text === "" ? editKey : editValue) }[view.mode]
    if (!target) return
    if (target === search) search.selectAll()
    target.forceActiveFocus()
  }

  // Called when the panel closes, which any outside click does. Drafts and
  // search survive so you can go copy a value and come back; passphrases don't.
  function reset() {
    setupPass.text = ""
    setupConfirm.text = ""
    unlockPass.text = ""
    view.pendingDelete = ""
  }

  // Escape: leave the editor first, then let the host close.
  function back() {
    if (view.mode !== "edit") return false
    view.cancelEdit()
    return true
  }

  // Tab/Shift+Tab within a form; false when the mode has no form so the
  // host can switch panels instead.
  function cycleFocus(direction) {
    var fields = { setup: [setupPass, setupConfirm], edit: [editEnv, editKey, editValue] }[view.mode]
    if (!fields) return false
    var current = fields.findIndex(function(f) { return f.activeFocus })
    fields[(current + direction + fields.length) % fields.length].forceActiveFocus()
    return true
  }

  function moveSelection(delta) {
    if (view.mode !== "list" || view.filtered.length === 0) return
    view.selectedIndex = Math.max(0, Math.min(view.selectedIndex + delta, view.filtered.length - 1))
    var at = view.rows.findIndex(function(r) { return !r.header && r.entryIndex === view.selectedIndex })
    if (at > 0 && view.rows[at - 1].header) list.positionViewAtIndex(at - 1, ListView.Contain)
    list.positionViewAtIndex(at, ListView.Contain)
  }

  function entryId(e) { return e.env + "\n" + e.key }

  function copyEntry(e, what) {
    view.vault.copy(e.env, e.key, what)
    view.copiedId = view.entryId(e)
    view.copiedWhat = what
    copiedTimer.restart()
  }

  function startAdd() {
    var current = view.filtered[view.selectedIndex]
    view.editOldEnv = ""
    view.editOldKey = ""
    editEnv.text = current ? current.env : ""
    editKey.text = ""
    editValue.text = ""
    view.showValue = false
    view.editing = true
  }

  function startEdit(e) {
    view.vault.reveal(e.env, e.key, function(value) {
      view.editOldEnv = e.env
      view.editOldKey = e.key
      editEnv.text = e.env
      editKey.text = e.key
      editValue.text = value
      view.showValue = false
      view.editing = true
    })
  }

  function editSelected() {
    var e = view.filtered[view.selectedIndex]
    if (e) view.startEdit(e)
  }

  // "KEY=value" (also "export KEY=value", quoted or not) typed or pasted into
  // the env or key field splits into key and value. Neither field can hold
  // "=", so there's no ambiguity; values keep theirs.
  function splitAssignment(field) {
    var m = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$/.exec(field.text)
    if (!m) return
    var value = m[2].trim()
    var quoted = /^(["'])(.*)\1$/.exec(value)
    if (quoted) value = quoted[2]
    if (field === editEnv) editEnv.text = ""
    editKey.text = m[1]
    editValue.text = value
    if (editEnv.text === "") editEnv.forceActiveFocus()
    else editValue.forceActiveFocus()
  }

  function cancelEdit() {
    editValue.text = ""
    view.editing = false
  }

  function save() {
    var env = editEnv.text.trim()
    var key = editKey.text.trim()
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*$/.test(env) || env.indexOf("..") !== -1) {
      view.vault.error = "Env must look like project/env"
      return
    }
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
      view.vault.error = "Key must be letters, digits and underscores"
      return
    }
    view.vault.save(env, key, editValue.text, view.editOldEnv, view.editOldKey, function() { view.cancelEdit() })
  }

  function requestDelete(e) {
    var id = view.entryId(e)
    if (view.pendingDelete === id) {
      view.pendingDelete = ""
      view.vault.remove(e.env, e.key)
      return
    }
    view.pendingDelete = id
    deleteTimer.restart()
  }

  function submitSetup() {
    if (setupPass.text === "") return
    if (setupPass.text !== setupConfirm.text) { view.vault.error = "Passphrases don't match"; return }
    view.vault.init(setupPass.text)
    setupPass.text = ""
    setupConfirm.text = ""
  }

  function submitUnlock() {
    if (unlockPass.text === "") return
    view.vault.unlock(unlockPass.text)
    unlockPass.text = ""
  }

  Timer { id: copiedTimer; interval: 1500; onTriggered: view.copiedId = "" }
  Timer { id: deleteTimer; interval: 3000; onTriggered: view.pendingDelete = "" }

  // --- header ---------------------------------------------------------------

  Item {
    width: parent.width
    height: Math.max(glyph.height, headerText.height, actions.height)

    Text {
      id: glyph
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: view.vault.unlocked ? String.fromCodePoint(0xF0FC6) : String.fromCodePoint(0xF033E)
      color: Color.accent
      font.family: view.fontFamily
      font.pixelSize: Style.space(30)
    }

    Column {
      id: headerText
      anchors.left: glyph.right
      anchors.leftMargin: Style.space(12)
      anchors.right: actions.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        text: "Secrets"
        color: view.foreground
        font.family: view.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Text {
        width: parent.width
        elide: Text.ElideRight
        text: {
          if (view.mode === "loading") return "…"
          if (view.mode === "setup") return "Not set up yet"
          if (view.mode === "locked") return "Locked"
          var parts = [view.vault.expires === "perm" || view.vault.expires === "" ? "Unlocked" : "Locks in " + view.vault.expires]
          if (view.vault.unpushed > 0) parts.push(view.vault.unpushed + " unpushed")
          return parts.join(" · ")
        }
        color: Util.alpha(view.foreground, 0.64)
        font.family: view.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Row {
      id: actions
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)
      visible: view.vault.unlocked

      PanelActionButton {
        iconText: String.fromCodePoint(0xF0415)
        tooltipText: "Add a secret (Ctrl+N)"
        foreground: view.foreground
        fontFamily: view.fontFamily
        visible: view.mode === "list"
        onClicked: view.startAdd()
      }
      PanelActionButton {
        iconText: String.fromCodePoint(0xF04E6)
        tooltipText: view.vault.remote ? "Sync with GitHub" : "No git remote"
        foreground: view.foreground
        fontFamily: view.fontFamily
        enabled: view.vault.remote && !view.vault.busy
        onClicked: view.vault.sync()
      }
      PanelActionButton {
        iconText: String.fromCodePoint(0xF033E)
        tooltipText: "Lock now"
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: view.vault.lock()
      }
    }
  }

  // --- setup ------------------------------------------------------------------

  Column {
    width: parent.width
    spacing: Style.space(8)
    visible: view.mode === "setup"

    Text {
      width: parent.width
      wrapMode: Text.Wrap
      text: "Pick a passphrase. It protects the key that encrypts everything, and it can't be recovered, so keep it somewhere safe."
      color: Util.alpha(view.foreground, 0.72)
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }

    TextField {
      id: setupPass
      width: parent.width
      password: true
      placeholderText: "passphrase"
      foreground: view.foreground
      font.family: view.fontFamily
      onAccepted: setupConfirm.forceActiveFocus()
    }

    TextField {
      id: setupConfirm
      width: parent.width
      password: true
      placeholderText: "again"
      foreground: view.foreground
      font.family: view.fontFamily
      onAccepted: view.submitSetup()
    }

    Button {
      text: "Create"
      bordered: true
      foreground: view.foreground
      fontFamily: view.fontFamily
      enabled: !view.vault.busy
      onClicked: view.submitSetup()
    }
  }

  // --- locked -----------------------------------------------------------------

  TextField {
    id: unlockPass
    width: parent.width
    visible: view.mode === "locked"
    enabled: !view.vault.busy
    password: true
    placeholderText: view.vault.busy ? "unlocking…" : "passphrase"
    foreground: view.foreground
    font.family: view.fontFamily
    onAccepted: view.submitUnlock()
  }

  // --- list -------------------------------------------------------------------

  TextField {
    id: search
    width: parent.width
    visible: view.mode === "list"
    placeholderText: "search..."
    foreground: view.foreground
    font.family: view.fontFamily
    onTextChanged: view.selectedIndex = 0
    // Before the field's own handling, which takes Ctrl+E as end-of-line.
    // Enter copies the value, Shift+Enter the name, Ctrl+Enter KEY=value.
    Keys.onPressed: function(event) {
      var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        var e = view.filtered[view.selectedIndex]
        if (e) view.copyEntry(e, ctrl ? "line" : ((event.modifiers & Qt.ShiftModifier) ? "name" : "value"))
        event.accepted = true
      }
      else if (ctrl && event.key === Qt.Key_N) { view.startAdd(); event.accepted = true }
      else if (ctrl && event.key === Qt.Key_E) { view.editSelected(); event.accepted = true }
    }
  }

  Text {
    width: parent.width
    visible: view.mode === "list" && view.filtered.length === 0
    horizontalAlignment: Text.AlignHCenter
    topPadding: Style.space(6)
    bottomPadding: Style.space(6)
    text: view.vault.entries.length === 0 ? "Nothing here yet. Press + to add a secret." : "No matches"
    color: Util.alpha(view.foreground, 0.5)
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
  }

  ListView {
    id: list
    width: parent.width
    visible: view.mode === "list" && count > 0
    // Fills what the window leaves between the search field and the footer.
    height: Math.max(0, view.height - y - footer.height - view.spacing)
    spacing: Style.spacing.xxs
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: view.rows

    delegate: Item {
      id: row
      required property var modelData
      required property int index
      readonly property bool header: modelData.header === true
      readonly property string rowId: view.entryId(modelData)
      readonly property bool selected: !header && view.selectedIndex === modelData.entryIndex
      readonly property bool confirming: view.pendingDelete === rowId
      readonly property string copied: view.copiedId === rowId ? view.copiedWhat : ""

      width: ListView.view.width
      height: header
        ? (index === 0 ? Style.space(24) : Style.space(44))
        : Style.spacing.popupRowHeight + Style.spacing.rowPaddingX

      function select() { view.selectedIndex = row.modelData.entryIndex }

      // --- group header ---

      Item {
        anchors.fill: parent
        visible: row.header

        PanelSeparator {
          visible: row.index > 0
          anchors.top: parent.top
          anchors.topMargin: Style.spacing.lg
          foreground: view.foreground
        }

        PanelSectionHeader {
          id: sectionTitle
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.xl
          anchors.right: sectionCount.left
          anchors.rightMargin: Style.spacing.lg
          anchors.bottom: parent.bottom
          anchors.bottomMargin: Style.spacing.sm
          elide: Text.ElideRight
          text: row.modelData.env
          foreground: view.foreground
          fontFamily: view.fontFamily
        }

        Text {
          id: sectionCount
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.xl
          anchors.baseline: sectionTitle.baseline
          text: row.header ? row.modelData.count + (row.modelData.count === 1 ? " key" : " keys") : ""
          color: Qt.darker(view.foreground, 1.6)
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // --- entry ---

      CursorSurface {
        anchors.fill: parent
        visible: !row.header
        hasCursor: row.selected
        foreground: view.foreground

        // Anywhere on the row copies the value; the name and the dots are
        // the explicit targets.
        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onContainsMouseChanged: if (containsMouse) row.select()
          onClicked: view.copyEntry(row.modelData, "value")
        }

        Text {
          id: keyText
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.xl
          anchors.right: valueText.left
          anchors.rightMargin: Style.spacing.xxl
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          text: row.modelData.key || ""
          color: row.copied === "name" || row.copied === "line" || keyMouse.containsMouse ? Color.accent : view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.body

          MouseArea {
            id: keyMouse
            width: Math.min(parent.width, parent.contentWidth)
            height: parent.height
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: if (containsMouse) row.select()
            onClicked: view.copyEntry(row.modelData, "name")
          }
        }

        Text {
          id: valueText
          anchors.right: divider.left
          anchors.rightMargin: Style.spacing.xxl
          anchors.verticalCenter: parent.verticalCenter
          text: "••••••••"
          color: valueMouse.containsMouse || row.copied === "value" || row.copied === "line" ? Color.accent
            : (row.selected ? view.foreground : Util.alpha(view.foreground, 0.5))
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption

          MouseArea {
            id: valueMouse
            anchors.fill: parent
            anchors.margins: -Style.spacing.sm
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onContainsMouseChanged: if (containsMouse) row.select()
            onClicked: view.copyEntry(row.modelData, "value")
          }
        }

        Rectangle {
          id: divider
          anchors.right: actions.left
          anchors.rightMargin: Style.spacing.lg
          anchors.verticalCenter: parent.verticalCenter
          width: Style.spacing.hairline
          height: Style.font.body
          color: Util.alpha(view.foreground, 0.14)
        }

        Row {
          id: actions
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xs

          PanelActionButton {
            iconText: String.fromCodePoint(0xF03EB)
            foreground: row.selected ? view.foreground : Util.alpha(view.foreground, 0.4)
            fontFamily: view.fontFamily
            enabled: !view.vault.busy
            onHovered: function(isHovered) { if (isHovered) row.select() }
            onClicked: view.startEdit(row.modelData)
          }
          PanelActionButton {
            iconText: String.fromCodePoint(0xF01B4)
            foreground: row.confirming ? Color.urgent : (row.selected ? view.foreground : Util.alpha(view.foreground, 0.4))
            fontFamily: view.fontFamily
            enabled: !view.vault.busy
            onHovered: function(isHovered) { if (isHovered) row.select() }
            onClicked: view.requestDelete(row.modelData)
          }
        }
      }
    }
  }

  // --- editor -----------------------------------------------------------------

  Column {
    width: parent.width
    spacing: Style.spacing.lg
    visible: view.mode === "edit"

    TextField {
      id: editEnv
      width: parent.width
      placeholderText: "project/env, e.g. primire/production"
      foreground: view.foreground
      font.family: view.fontFamily
      onTextChanged: view.splitAssignment(editEnv)
      onAccepted: editKey.forceActiveFocus()
    }

    TextField {
      id: editKey
      width: parent.width
      placeholderText: "KEY_NAME, or paste KEY=value"
      foreground: view.foreground
      font.family: view.fontFamily
      onTextChanged: view.splitAssignment(editKey)
      onAccepted: editValue.forceActiveFocus()
    }

    Item {
      width: parent.width
      height: editValue.height

      TextField {
        id: editValue
        anchors.left: parent.left
        anchors.right: eye.left
        anchors.rightMargin: Style.spacing.md
        password: !view.showValue
        placeholderText: "value"
        foreground: view.foreground
        font.family: view.fontFamily
        onAccepted: view.save()
      }

      PanelActionButton {
        id: eye
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: String.fromCodePoint(view.showValue ? 0xF0209 : 0xF0208)
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: view.showValue = !view.showValue
      }
    }

    Row {
      spacing: Style.spacing.controlGap

      Button {
        text: view.editOldKey === "" ? "Add" : "Save"
        bordered: true
        foreground: view.foreground
        fontFamily: view.fontFamily
        enabled: !view.vault.busy
        onClicked: view.save()
      }
      Button {
        text: "Cancel"
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: view.cancelEdit()
      }
    }
  }

  // --- footer -----------------------------------------------------------------

  // Status line: errors, then the pending delete, then notices, then hints.
  Column {
    id: footer
    width: parent.width
    spacing: Style.spacing.md

    readonly property string pendingKey: view.pendingDelete.split("\n")[1] || ""
    readonly property string hint: {
      if (view.mode === "list") return "↵ copy value   ⇧↵ name   ⌃↵ KEY=value   ⌃N new"
      if (view.mode === "edit") return "↵ next / save   Tab move   Esc cancel"
      return ""
    }

    PanelSeparator {
      foreground: view.foreground
      visible: footerText.text !== ""
    }

    Text {
      id: footerText
      width: parent.width
      visible: text !== ""
      elide: Text.ElideRight
      text: view.vault.error
        || (footer.pendingKey ? "Click delete again to remove " + footer.pendingKey : "")
        || view.vault.notice
        || footer.hint
      color: view.vault.error || footer.pendingKey ? Color.urgent
        : (view.vault.notice ? Color.accent : Qt.darker(view.foreground, 1.6))
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
