import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Tablet mode: bar icon plus a touch-sized card in the style of Omarchy's own
// panels. The card switches modes, shows the on-screen keyboard, locks or turns
// the screen, and turns the whole plugin off (plain Omarchy). Everything goes
// through bin/tablet-mode; live state comes from the daemon's state file.
Panel {
  id: root
  moduleName: "alanroman117.tablet-mode"
  ipcTarget: "alanroman117.tablet-mode"
  // Own the IPC target so it can also carry refresh().
  manageIpc: false

  // From `tablet-mode status --json`.
  property var info: ({})
  property string busy: ""
  property string actionError: ""

  readonly property string cli: decodeURIComponent(Qt.resolvedUrl("bin/tablet-mode").toString().replace("file://", ""))
  readonly property string runDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-tablet-mode"
  readonly property string setup: info.setup || "unknown"
  readonly property bool ready: setup === "ready"
  readonly property bool tablet: ready && info.mode === "tablet"
  readonly property var rotations: ["normal", "90", "180", "270"]

  readonly property string tabletGlyph: "󰓶"
  readonly property string laptopGlyph: "󰌢"

  // The bar API handed to third-party plugins has run() but not shellQuote(),
  // so quote locally.
  function quote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function refresh() {
    if (!infoProc.running) infoProc.running = true
  }

  // Refresh every copy of the widget (one per monitor), as BarWidget.broadcast does.
  function refreshAll() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) {
      if (items[i] && typeof items[i].refresh === "function") items[i].refresh()
    }
  }

  function runAction(kind, args) {
    if (busy !== "") return
    busy = kind
    actionError = ""
    actionProc.command = [cli].concat(args)
    actionProc.running = true
  }

  // Install asks for a password, and calibrate and doctor talk to you, so they get a terminal.
  function openTerminal(command) {
    if (!bar) return
    close()
    // The helper runs its arguments through `bash -c` again, so the path is quoted twice.
    bar.run("omarchy-launch-floating-terminal-with-presentation " + quote(quote(cli)) + " " + command)
  }

  function statusCaption() {
    if (busy === "disable") return "TURNING OFF..."
    if (busy === "enable") return "STARTING..."
    if (setup === "disabled") return "OFF: PLAIN OMARCHY"
    if (setup === "install") return "NOT SET UP"
    if (setup === "enable") return "ONE STEP LEFT"
    if (setup === "stopped") return "STOPPED"
    if (setup !== "ready") return ""
    return tablet ? "TABLET MODE" : "LAPTOP MODE"
  }

  function setupText() {
    if (setup === "disabled") return "Turned off. Nothing runs and nothing is changed: rotation, the on-screen keyboard and the touch tweaks are all back to plain Omarchy."
    if (setup === "install") return "Needs iio-sensor-proxy (reads the accelerometer) and wvkbd (the on-screen keyboard). Setup installs them; it asks for your password."
    if (setup === "enable") return "Installed. Last step: start the service and add the menu entries."
    if (setup === "stopped") return "The tablet-mode service isn't running."
    return ""
  }

  function modeSubtitle() {
    if (actionError !== "") return actionError
    if (info.source === "manual") return tablet ? "Turned on by hand" : "Turned off by hand"
    if (info.keyboard === "detached") return "Keyboard detached"
    if (info.keyboard === "attached") return "Keyboard attached"
    return "Detach the keyboard, or switch here"
  }

  function rotationSubtitle() {
    if (info.lock) return "Locked where it is"
    return tablet ? "Following the accelerometer" : "Follows the accelerometer in tablet mode"
  }

  IpcHandler {
    target: "alanroman117.tablet-mode"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refreshAll() }
  }

  onOpenedChanged: {
    if (opened) {
      actionError = ""
      refresh()
    }
  }

  Component.onCompleted: refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: infoProc
    command: [root.cli, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.info = JSON.parse(String(text || "{}")) } catch (e) { }
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      id: actionErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        var lines = String(actionErr.text || "").trim().split("\n")
        root.actionError = lines[lines.length - 1].replace(/^.*Error:\s*/, "") || "That didn't work"
      }
      root.busy = ""
      root.refreshAll()
    }
  }

  // The daemon rewrites this on every change, so the icon follows the keyboard live.
  FileView {
    path: root.runDir + "/state.json"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
    onLoadFailed: root.refresh()
  }

  Timer {
    interval: root.opened ? 3000 : 20000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.tablet ? root.tabletGlyph : root.laptopGlyph
    active: root.tablet
    dimmed: !root.ready
    tooltipText: root.opened ? "" : (root.ready
      ? (root.tablet ? "Tablet mode" : "Laptop mode") + (root.info.lock ? ", rotation locked" : "")
      : (root.setup === "disabled" ? "Tablet mode: off" : "Tablet mode: not set up"))
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: icon, title/status, keyboard ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroValue.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.tablet ? root.tabletGlyph : root.laptopGlyph
            color: root.bar.foreground
            opacity: root.ready ? 1 : 0.45
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroValue.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Tablet Mode"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.statusCaption()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Column {
            id: heroValue
            visible: root.ready && root.info.keyboard !== "unknown"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Text {
              anchors.right: parent.right
              textFormat: Text.PlainText
              text: root.info.keyboard === "detached" ? "Off" : "On"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              anchors.right: parent.right
              text: "KEYBOARD"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1.2
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        // ---------- Setup, stopped or disabled ----------
        Column {
          visible: !root.ready
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            text: root.actionError !== "" ? root.actionError : root.setupText()
            color: root.actionError !== "" ? Color.urgent : root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
            width: parent.width
          }

          Row {
            id: setupRow
            width: parent.width
            spacing: Style.space(6)
            readonly property real cellWidth: (width - spacing) / 2

            Button {
              width: setupRow.cellWidth
              iconText: root.setup === "install" ? "" : "󰐥"
              text: root.setup === "install" ? "Set up" : (root.setup === "enable" ? "Finish setup" : (root.setup === "stopped" ? "Start" : "Turn on"))
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.setup === "install" ? root.openTerminal("install") : root.runAction("enable", ["enable"])
            }

            Button {
              width: setupRow.cellWidth
              iconText: ""
              text: "Check"
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              onClicked: root.openTerminal("doctor")
            }
          }
        }

        // ---------- Switches ----------
        Column {
          visible: root.ready
          width: parent.width
          spacing: Style.space(12)

          SwitchRow {
            title: "Tablet mode"
            subtitle: root.modeSubtitle()
            warn: root.actionError !== ""
            checked: root.tablet
            onToggled: root.runAction("mode", ["toggle"])
          }

          SwitchRow {
            title: "On-screen keyboard"
            subtitle: root.info.osk ? "Shown" : "Hidden"
            checked: !!root.info.osk
            onToggled: root.runAction("osk", ["osk", "toggle"])
          }

          SwitchRow {
            title: "Rotation lock"
            subtitle: root.rotationSubtitle()
            checked: !!root.info.lock
            onToggled: root.runAction("lock", ["lock", "toggle"])
          }
        }

        PanelSeparator { visible: root.ready; foreground: root.bar.foreground }

        // ---------- Turn the screen ----------
        Column {
          visible: root.ready
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "TURN THE SCREEN"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          ButtonGroup {
            width: parent.width
            options: [
              { value: "normal", label: "0°" },
              { value: "90", label: "90°" },
              { value: "180", label: "180°" },
              { value: "270", label: "270°" }
            ]
            value: root.rotations[root.info.transform || 0] || "normal"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            focusable: false
            onChanged: function(value) { root.runAction("rotate", ["rotate", value]) }
          }

          Text {
            textFormat: Text.PlainText
            text: "Picking one locks rotation. Upside down or sideways when you turn it? Calibrate."
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            width: parent.width
          }
        }

        PanelSeparator { visible: root.ready; foreground: root.bar.foreground }

        Row {
          id: toolsRow
          visible: root.ready
          width: parent.width
          spacing: Style.space(6)
          readonly property real cellWidth: (width - spacing * 2) / 3

          Button {
            width: toolsRow.cellWidth
            iconText: "󰑵"
            text: "Calibrate"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.openTerminal("calibrate")
          }

          Button {
            width: toolsRow.cellWidth
            iconText: ""
            text: "Check"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.openTerminal("doctor")
          }

          Button {
            width: toolsRow.cellWidth
            iconText: "󰐥"
            text: "Turn off"
            tooltipText: "Plain Omarchy: stop everything and undo every change"
            fontSize: Style.font.bodySmall
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.runAction("disable", ["disable"])
          }
        }
      }
    }
  }

  component SwitchRow: Item {
    id: row
    property string title: ""
    property string subtitle: ""
    property bool checked: false
    property bool warn: false
    signal toggled()

    width: parent ? parent.width : 0
    implicitHeight: Math.max(labels.implicitHeight, toggle.implicitHeight)

    Column {
      id: labels
      anchors.left: parent.left
      anchors.right: toggle.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        text: row.title
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        width: parent.width
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        text: row.subtitle
        color: row.warn ? Color.urgent : root.bar.foreground
        opacity: row.warn ? 1 : 0.6
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.bodySmall
        width: parent.width
        wrapMode: Text.WordWrap
      }
    }

    ToggleSwitch {
      id: toggle
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: row.checked
      busy: root.busy !== ""
      foreground: root.bar.foreground
      onToggled: row.toggled()
    }
  }
}
