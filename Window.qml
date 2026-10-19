import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// A regular floating window (the Hyprland rule floats it), so clicking
// elsewhere doesn't close it. keepLoaded keeps it, and any draft, alive
// between opens. The bar widget passes its settings in the summon payload.
Item {
  id: root

  property var shell: null
  property bool closingFromHost: false
  property var settings: ({})

  function open(payloadJson) {
    if (payloadJson) {
      try {
        var parsed = JSON.parse(String(payloadJson))
        if (parsed && typeof parsed === "object" && Object.keys(parsed).length > 0) root.settings = parsed
      } catch (e) { /* keep previous settings */ }
    }
    root.closingFromHost = false
    window.visible = true
    vault.refresh(true)
    Qt.callLater(view.focusInput)
  }

  // Host-initiated close (`shell hide`/toggle): it already knows.
  function close() {
    root.closingFromHost = true
    window.visible = false
    root.closingFromHost = false
  }

  // Esc or the compositor closing the window: tell the shell so toggle
  // stays in sync.
  function requestClose() {
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide("cossssmin.secrets")
    else window.visible = false
  }

  Vault {
    id: vault
    settingFn: function(name, fallback) {
      var v = root.settings[name]
      return v === undefined || v === null ? fallback : v
    }
  }

  FloatingWindow {
    id: window
    title: "Secrets"
    color: Color.popups.background
    implicitWidth: 460
    implicitHeight: 560
    minimumSize: Qt.size(360, 320)

    onVisibleChanged: {
      if (!visible) view.reset()
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide("cossssmin.secrets")
    }

    FocusScope {
      id: keyScope
      anchors.fill: parent
      anchors.margins: Style.spacing.panelPadding
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (deleteDialog.handleKey(event)) { event.accepted = true; return }
        if (event.key === Qt.Key_Escape) { if (!view.back()) root.requestClose(); event.accepted = true }
        else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          view.cycleFocus(event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1)
          event.accepted = true
        }
        else if (event.key === Qt.Key_Down) { view.moveSelection(1); event.accepted = true }
        else if (event.key === Qt.Key_Up) { view.moveSelection(-1); event.accepted = true }
      }

      VaultView {
        id: view
        anchors.fill: parent
        vault: vault
        foreground: Color.popups.text
        fontFamily: Style.font.family
      }

      // Holds focus while the dialog is up, so keys skip the search field's
      // handlers and reach the dialog through this scope.
      Item { id: dialogFocus }
    }

    ConfirmDialog {
      id: deleteDialog
      anchors.fill: parent
      opened: view.deleteCandidate !== null
      message: opened ? "Delete " + view.deleteCandidate.key + "?\nfrom " + view.deleteCandidate.env : ""
      confirmText: "Delete"
      background: Color.popups.background
      foreground: Color.popups.text
      fontFamily: Style.font.family
      // Cancel is preselected: a reflexive Enter never deletes.
      onOpenedChanged: if (opened) {
        selectedIndex = 0
        dialogFocus.forceActiveFocus()
      }
      onCanceled: view.cancelDelete()
      onConfirmed: view.confirmDelete()
    }
  }
}
