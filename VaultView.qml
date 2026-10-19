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
    if (settingsOpen) return "settings"
    if (!vault.initialized) return "setup"
    if (!vault.unlocked) return "locked"
    return editing ? "edit" : "list"
  }

  property bool editing: false
  property bool settingsOpen: false
  // Auto-lock minutes being edited in the settings; 0 = never.
  property int settingsTtl: 15
  readonly property var lockStops: [5, 15, 30, 60, 120, 240, 480, 1440, 0]
  readonly property int lockStopIndex: lockStops.indexOf(settingsTtl)

  function lockLabel(minutes) {
    if (minutes === 0) return "Never"
    if (minutes % 1440 === 0) return minutes / 1440 + (minutes === 1440 ? " day" : " days")
    if (minutes % 60 === 0) return minutes / 60 + (minutes === 60 ? " hour" : " hours")
    return minutes + " min"
  }

  // The stop closest to a custom value, so the slider still points somewhere sensible.
  function nearestLockStop(minutes) {
    if (minutes === 0) return lockStops.length - 1
    var best = 0
    for (var i = 1; i < lockStops.length - 1; i++)
      if (Math.abs(lockStops[i] - minutes) < Math.abs(lockStops[best] - minutes)) best = i
    return best
  }
  property string editOldEnv: ""
  property string editOldKey: ""
  property bool showValue: false

  property int selectedIndex: 0
  // The entry the host's confirm dialog is asking about, or null.
  property var deleteCandidate: null
  property string renamingEnv: ""
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
    function onUnlockedChanged() {
      if (view.vault.unlocked) return
      view.cancelEdit()
      view.renamingEnv = ""
      view.deleteCandidate = null
    }
  }

  function focusInput() {
    var target = { setup: setupPass, locked: unlockPass, list: search, settings: settingsDir, edit: editEnv.text === "" ? editEnv : (editKey.text === "" ? editKey : editValue) }[view.mode]
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
    view.deleteCandidate = null
  }

  // Escape: leave a rename or the editor first, then let the host close.
  function back() {
    if (view.settingsOpen) { view.settingsOpen = false; return true }
    if (view.renamingEnv !== "") { view.cancelRename(); return true }
    if (view.mode !== "edit") return false
    view.cancelEdit()
    return true
  }

  function validEnv(env) {
    return /^[A-Za-z0-9][A-Za-z0-9._-]*\/[A-Za-z0-9][A-Za-z0-9._-]*$/.test(env) && env.indexOf("..") === -1
  }

  function startRename(env) {
    view.renamingEnv = env
  }

  function cancelRename() {
    view.renamingEnv = ""
    Qt.callLater(view.focusInput)
  }

  function submitRename(from, to) {
    to = to.trim()
    if (to === from) { view.cancelRename(); return }
    if (!view.validEnv(to)) { view.vault.error = "Env must look like project/env"; return }
    view.vault.renameEnv(from, to, function() { view.cancelRename() })
  }

  // Tab/Shift+Tab within a form; false when the mode has no form so the
  // host can switch panels instead.
  function cycleFocus(direction) {
    var fields = {
      setup: [setupPass, setupConfirm],
      edit: [editEnv, editKey, editValue],
      settings: [settingsDir, syncChoice].concat(settingsRemote.visible ? [settingsRemote] : []).concat([lockSlider, ttlField.field, lockToggle])
    }[view.mode]
    if (!fields) return false
    var current = fields.findIndex(function(f) { return f.activeFocus })
    var next = fields[(current + direction + fields.length) % fields.length]
    next.forceActiveFocus()
    view.revealSetting(next === ttlField.field ? ttlField : next)
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
    if (!view.validEnv(env)) {
      view.vault.error = "Env must look like project/env"
      return
    }
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
      view.vault.error = "Key must be letters, digits and underscores"
      return
    }
    view.vault.save(env, key, editValue.text, view.editOldEnv, view.editOldKey, function() { view.cancelEdit() })
  }

  // Deleting always goes through the host's confirm dialog.
  function requestDelete(e) {
    view.deleteCandidate = e
  }

  function deleteSelected() {
    var e = view.filtered[view.selectedIndex]
    if (e) view.requestDelete(e)
  }

  function confirmDelete() {
    var e = view.deleteCandidate
    view.deleteCandidate = null
    if (e) view.vault.remove(e.env, e.key)
    Qt.callLater(view.focusInput)
  }

  function cancelDelete() {
    view.deleteCandidate = null
    Qt.callLater(view.focusInput)
  }

  function openSettings() {
    var c = view.vault.config
    settingsDir.text = c.dir || ""
    syncChoice.value = c.sync || "github"
    settingsRemote.text = c.remote || ""
    view.settingsTtl = Math.round((c.ttl === undefined ? 900 : c.ttl) / 60)
    lockToggle.checked = c.lockOnScreenLock !== false
    settingsScroll.contentY = 0
    view.settingsOpen = true
  }

  // Only what changed, in an order where each step can rely on the last:
  // the repo folder first, so a remote lands on the right repo.
  function saveSettings() {
    var c = view.vault.config, changes = []
    var dir = settingsDir.text.trim()
    if (dir !== (c.dir || "")) changes.push(["dir", dir])
    if (syncChoice.value !== (c.sync || "github")) changes.push(["sync", syncChoice.value])
    if (syncChoice.value === "github" && settingsRemote.text.trim() !== (c.remote || ""))
      changes.push(["remote", settingsRemote.text.trim()])
    if (view.settingsTtl * 60 !== (c.ttl === undefined ? 900 : c.ttl)) changes.push(["ttl", view.settingsTtl * 60])
    if (lockToggle.checked !== (c.lockOnScreenLock !== false))
      changes.push(["lock-on-screen-lock", lockToggle.checked ? "true" : "false"])
    view.vault.saveConfig(changes, function() { view.settingsOpen = false })
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
          if (view.mode === "settings") return "Settings"
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

      PanelActionButton {
        iconText: String.fromCodePoint(0xF0415)
        tooltipText: "Add a secret (Ctrl+N)"
        foreground: view.foreground
        fontFamily: view.fontFamily
        visible: view.mode === "list"
        onClicked: view.startAdd()
      }
      PanelActionButton {
        iconText: view.vault.syncing ? "" : String.fromCodePoint(0xF04E6)
        tooltipText: view.vault.remote ? "Sync with GitHub" : "No git remote"
        foreground: view.foreground
        fontFamily: view.fontFamily
        visible: view.vault.unlocked && view.vault.config.sync !== "local" && view.mode !== "settings"
        enabled: view.vault.remote && !view.vault.busy
        onClicked: view.vault.sync()

        // Spins while a sync runs; the button's own glyph is blanked meanwhile.
        // It rotates around the glyph's ink, not its text box: the two
        // centers differ, and spinning around the box makes it wobble.
        Item {
          anchors.centerIn: parent
          visible: view.vault.syncing
          width: spinMetrics.tightBoundingRect.width
          height: spinMetrics.tightBoundingRect.height

          TextMetrics {
            id: spinMetrics
            text: spinGlyph.text
            font: spinGlyph.font
          }

          Text {
            id: spinGlyph
            x: -spinMetrics.tightBoundingRect.x
            y: -(baselineOffset + spinMetrics.tightBoundingRect.y)
            text: String.fromCodePoint(0xF04E6)
            color: view.foreground
            font.family: view.fontFamily
            font.pixelSize: Style.font.icon
          }

          // Counter-clockwise, the way the glyph's arrows point.
          RotationAnimation on rotation {
            from: 0
            to: -360
            duration: 900
            loops: Animation.Infinite
            running: view.vault.syncing
          }
        }
      }
      PanelActionButton {
        iconText: String.fromCodePoint(0xF033E)
        tooltipText: "Lock now"
        foreground: view.foreground
        fontFamily: view.fontFamily
        visible: view.vault.unlocked && view.mode !== "settings"
        onClicked: view.vault.lock()
      }
      PanelActionButton {
        iconText: String.fromCodePoint(0xF0493)
        tooltipText: "Settings (Ctrl+,)"
        foreground: view.foreground
        fontFamily: view.fontFamily
        visible: view.mode !== "settings" && view.mode !== "loading"
        onClicked: view.openSettings()
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
      else if (event.key === Qt.Key_F2) {
        var current = view.filtered[view.selectedIndex]
        if (current) view.startRename(current.env)
        event.accepted = true
      }
      else if (ctrl && event.key === Qt.Key_N) { view.startAdd(); event.accepted = true }
      else if (ctrl && event.key === Qt.Key_Comma) { view.openSettings(); event.accepted = true }
      else if (ctrl && event.key === Qt.Key_E) { view.editSelected(); event.accepted = true }
      else if (ctrl && event.key === Qt.Key_D) { view.deleteSelected(); event.accepted = true }
      else if (event.key === Qt.Key_Insert) { view.editSelected(); event.accepted = true }
      // Delete only when it has nothing to delete in the field itself.
      else if (event.key === Qt.Key_Delete && search.selectedText === "" && search.cursorPosition === search.text.length) {
        view.deleteSelected()
        event.accepted = true
      }
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
      readonly property bool confirming: view.deleteCandidate !== null && view.entryId(view.deleteCandidate) === rowId
      readonly property string copied: view.copiedId === rowId ? view.copiedWhat : ""

      width: ListView.view.width
      readonly property bool renaming: header && view.renamingEnv === modelData.env

      height: header
        ? (index === 0 ? Style.space(renaming ? 34 : 24) : Style.space(44))
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

        // Clicking the name renames the group.
        PanelSectionHeader {
          id: sectionTitle
          visible: !row.renaming
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
          color: titleMouse.containsMouse ? Color.accent : Qt.darker(view.foreground, 1.4)

          MouseArea {
            id: titleMouse
            width: Math.min(parent.width, parent.contentWidth)
            height: parent.height
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            enabled: !view.vault.busy
            onClicked: view.startRename(row.modelData.env)
          }
        }

        TextField {
          id: renameField
          visible: row.renaming
          anchors.left: parent.left
          anchors.right: sectionCount.left
          anchors.rightMargin: Style.spacing.lg
          anchors.bottom: parent.bottom
          verticalPadding: Style.spacing.xxs
          foreground: view.foreground
          font.family: view.fontFamily
          font.pixelSize: Style.font.caption
          onVisibleChanged: if (visible) {
            text = row.modelData.env
            selectAll()
            forceActiveFocus()
          }
          onAccepted: view.submitRename(row.modelData.env, text)
        }

        Text {
          id: sectionCount
          anchors.right: parent.right
          anchors.rightMargin: Style.spacing.xl
          anchors.verticalCenter: row.renaming ? renameField.verticalCenter : sectionTitle.verticalCenter
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
      placeholderText: "project/env, e.g. acme-api/production"
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

  // --- settings -----------------------------------------------------------------

  component FieldLabel: Text {
    color: view.foreground
    font.family: view.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.bold: true
  }

  component FieldHelp: Text {
    width: parent ? parent.width : implicitWidth
    wrapMode: Text.Wrap
    color: Qt.darker(view.foreground, 1.6)
    font.family: view.fontFamily
    font.pixelSize: Style.font.caption
  }

  // Scrolls the settings so a field reached with Tab isn't hidden. Qt moves
  // focus between fields itself, so each field calls this when it gets focus.
  function revealSetting(item) {
    if (!item || view.mode !== "settings") return
    // The whole field (label, control, help), not just the control.
    if (item.parent && item.parent !== settingsForm) item = item.parent
    var p = item.mapToItem(settingsForm, 0, 0)
    var top = p.y - Style.spacing.lg
    if (top < Style.space(48)) top = 0
    var bottom = p.y + item.height + Style.spacing.lg
    if (top < settingsScroll.contentY) settingsScroll.contentY = Math.max(0, top)
    else if (bottom > settingsScroll.contentY + settingsScroll.height)
      settingsScroll.contentY = Math.min(settingsScroll.contentHeight - settingsScroll.height, bottom - settingsScroll.height)
  }

  Item {
    id: settingsPane
    width: parent.width
    visible: view.mode === "settings"
    height: visible ? Math.max(0, view.height - y - footer.height - view.spacing) : 0

    Flickable {
      id: settingsScroll
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: settingsButtons.top
      anchors.bottomMargin: Style.spacing.xl
      contentHeight: settingsForm.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: settingsForm
        width: settingsScroll.width
        spacing: Style.spacing.huge

        // --- storage ---

        Column {
          width: parent.width
          spacing: Style.spacing.xxl

          PanelSectionHeader {
            text: "Storage"
            foreground: view.foreground
            fontFamily: view.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.spacing.sm

            FieldLabel { text: "Repo folder" }
            TextField {
              id: settingsDir
              onActiveFocusChanged: if (activeFocus) view.revealSetting(settingsDir)
              width: parent.width
              placeholderText: "~/.local/share/secrets"
              foreground: view.foreground
              font.family: view.fontFamily
              onAccepted: view.saveSettings()
            }
            FieldHelp { text: "An existing secrets repo, or an empty folder to start a new one." }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.sm

            FieldLabel { text: "Sync" }
            ButtonGroup {
              id: syncChoice
              onActiveFocusChanged: if (activeFocus) view.revealSetting(syncChoice)
              options: [{ value: "github", label: "GitHub" }, { value: "local", label: "Local only" }]
              value: "github"
              foreground: view.foreground
              fontFamily: view.fontFamily
              onChanged: function(v) { syncChoice.value = v }
            }
            FieldHelp {
              text: syncChoice.value === "github"
                ? "Every change is committed and pushed to your remote."
                : "Changes are committed on this machine and never pushed."
            }
          }

          Column {
            width: parent.width
            spacing: Style.spacing.sm
            visible: syncChoice.value === "github"

            FieldLabel { text: "Remote URL" }
            TextField {
              id: settingsRemote
              onActiveFocusChanged: if (activeFocus) view.revealSetting(settingsRemote)
              width: parent.width
              placeholderText: "git@github.com:you/secrets.git"
              foreground: view.foreground
              font.family: view.fontFamily
              onAccepted: view.saveSettings()
            }
            FieldHelp { text: "Use a private repo." }
          }
        }

        PanelSeparator { foreground: view.foreground }

        // --- locking ---

        Column {
          width: parent.width
          spacing: Style.spacing.xxl

          PanelSectionHeader {
            text: "Locking"
            foreground: view.foreground
            fontFamily: view.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.spacing.sm

            Item {
              width: parent.width
              height: lockTitle.height

              FieldLabel { id: lockTitle; text: "Auto-lock after" }
              Text {
                anchors.right: parent.right
                anchors.baseline: lockTitle.baseline
                text: view.lockStopIndex === -1 ? "Custom: " + view.lockLabel(view.settingsTtl) : view.lockLabel(view.settingsTtl)
                color: Color.accent
                font.family: view.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
            }

            // Preset stops from 5 minutes up to never; ←/→ step through them.
            PanelSlider {
              id: lockSlider
              onActiveFocusChanged: if (activeFocus) view.revealSetting(lockSlider)
              // Inset so the knob's hover growth isn't clipped at either end.
              x: Style.spacing.sm
              width: parent.width - 2 * Style.spacing.sm
              minimum: 0
              maximum: view.lockStops.length - 1
              integer: true
              step: 1
              tickCount: view.lockStops.length
              value: view.lockStopIndex === -1 ? view.nearestLockStop(view.settingsTtl) : view.lockStopIndex
              trackColor: Style.selectedFillFor(view.foreground, Color.accent)
              fillColor: activeFocus ? Color.accent : view.foreground
              knobColor: activeFocus ? Color.accent : view.foreground
              tickColor: Color.popups.background
              activeFocusOnTab: true
              onMoved: function(v) { view.settingsTtl = view.lockStops[Math.round(v)] }
              Keys.onPressed: function(event) {
                var i = Math.round(lockSlider.value)
                if (event.key === Qt.Key_Left && i > 0) view.settingsTtl = view.lockStops[i - 1]
                else if (event.key === Qt.Key_Right && i < view.lockStops.length - 1) view.settingsTtl = view.lockStops[i + 1]
                else return
                event.accepted = true
              }
            }

            Row {
              spacing: Style.spacing.lg

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Or exactly"
                color: Qt.darker(view.foreground, 1.6)
                font.family: view.fontFamily
                font.pixelSize: Style.font.caption
              }
              NumberField {
                id: ttlField
                anchors.verticalCenter: parent.verticalCenter
                fieldWidth: Style.space(110)
                from: 0
                to: 10080
                stepSize: 5
                value: view.settingsTtl
                foreground: view.foreground
                fontFamily: view.fontFamily
                onModified: function(v) { view.settingsTtl = v }

                Connections {
                  target: ttlField.field
                  function onActiveFocusChanged() { if (ttlField.field.activeFocus) view.revealSetting(ttlField) }
                }
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "minutes (0 = never)"
                color: Qt.darker(view.foreground, 1.6)
                font.family: view.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // A plain row like the other fields rather than the kit's carded Toggle.
          Item {
            id: lockToggle
            onActiveFocusChanged: if (activeFocus) view.revealSetting(lockToggle)
            property bool checked: true
            width: parent.width
            height: Math.max(lockToggleText.height, lockSwitch.height)
            activeFocusOnTab: true
            Keys.onSpacePressed: lockToggle.checked = !lockToggle.checked
            Keys.onReturnPressed: lockToggle.checked = !lockToggle.checked

            Column {
              id: lockToggleText
              anchors.left: parent.left
              anchors.right: lockSwitch.left
              anchors.rightMargin: Style.spacing.xxl
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.sm

              FieldLabel { text: "Lock when the screen locks" }
              FieldHelp { text: "Suspending locks the screen first, so this covers it too." }
            }

            ToggleSwitch {
              id: lockSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: lockToggle.checked
              interactive: false
              hasCursor: lockToggle.activeFocus
              foreground: view.foreground
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: lockToggle.checked = !lockToggle.checked
            }
          }
        }
      }
    }

    Row {
      id: settingsButtons
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      spacing: Style.spacing.controlGap

      Button {
        text: "Cancel"
        foreground: view.foreground
        fontFamily: view.fontFamily
        onClicked: view.settingsOpen = false
      }
      Button {
        text: "Save"
        bordered: true
        foreground: view.foreground
        fontFamily: view.fontFamily
        enabled: !view.vault.busy
        onClicked: view.saveSettings()
      }
    }
  }

  // --- footer -----------------------------------------------------------------

  // Status line: errors, then notices, then hints.
  Column {
    id: footer
    width: parent.width
    spacing: Style.spacing.md

    readonly property string hint: {
      if (view.mode === "settings") return "↵ save   Tab move   Esc cancel"
      if (view.renamingEnv !== "") return "↵ rename   Esc cancel"
      if (view.mode === "list") return "↵ value  ⇧↵ name  ⌃↵ line  ⌃N new  Ins edit  Del delete"
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
        || (view.vault.trusted ? "" : ".age-recipients changed upstream: review it, then run secrets trust")
        || view.vault.notice
        || footer.hint
      color: view.vault.error || !view.vault.trusted ? Color.urgent
        : (view.vault.notice ? Color.accent : Qt.darker(view.foreground, 1.6))
      font.family: view.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
