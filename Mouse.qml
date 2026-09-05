import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The mouse in the bar: how much battery the wireless one has left, and a
// slider for its pointer sensitivity behind a right click.
//
// Two halves that only look unrelated. The battery comes from UPower, which
// the kernel's HID++ driver feeds for Logitech's wireless mice; the
// sensitivity goes to Hyprland as a per-device rule. They meet in
// `pointerName`: the pointer the slider moves is picked by matching Hyprland's
// device list against the model string of the battery UPower is reporting, so
// the widget speaks for one physical mouse rather than for whatever pointer
// happened to enumerate first.
Panel {
  id: root
  moduleName: "leonavas.mouse"
  ipcTarget: "leonavas.mouse"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the extra methods below.
  manageIpc: false

  // ------------------------------------------------------------- settings
  readonly property string glyph: String(setting("glyph", "󰍽"))
  readonly property string absentGlyph: String(setting("absentGlyph", "󰍾"))
  readonly property bool showPercentage: Model.truthy(setting("showPercentage", false), false)
  readonly property bool hideWhenAbsent: Model.truthy(setting("hideWhenAbsent", false), false)
  readonly property bool dimWhenAbsent: Model.truthy(setting("dimWhenAbsent", true), true)
  readonly property bool tintWhenLow: Model.truthy(setting("tintWhenLow", true), true)
  readonly property int lowThreshold: Math.max(0, Math.min(100, Number(setting("lowThreshold", 15))))
  // Below this the tint turns from amber to the theme's urgent red and the
  // notification goes critical. Never above the low threshold: red implies low.
  readonly property int criticalThreshold: Math.min(root.lowThreshold,
    Math.max(0, Math.min(100, Number(setting("criticalThreshold", 5)))))
  readonly property bool notifyLow: Model.truthy(setting("notifyLow", true), true)
  readonly property string pinnedDevice: String(setting("deviceName", ""))
  readonly property bool globalScope: String(setting("scope", "This mouse")) === "All pointers"

  // Hyprland's sensitivity runs -1..1, so a 0.05 step is 5 hundredths — the
  // grain the +/- buttons, the wheel, and the arrow keys all move by.
  readonly property real sensitivityStep: 0.05

  // The sensitivity this widget owns. Absent (null) means "leave Hyprland
  // alone" — the mouse follows whatever input.lua set, and the slider opens on
  // that value instead of on an invented one.
  readonly property var storedSensitivity: setting("sensitivity", null)
  readonly property bool hasOverride: Model.isSensitivity(root.storedSensitivity)
  readonly property real sensitivity: root.hasOverride
    ? Model.clampSensitivity(root.storedSensitivity)
    : root.globalSensitivity

  // -------------------------------------------------------------- battery
  readonly property var device: {
    var list = UPower.devices ? (UPower.devices.values || []) : []
    // Gaming mice sometimes land under GamingInput rather than Mouse.
    return Model.mouseBattery(list, [UPowerDeviceType.Mouse, UPowerDeviceType.GamingInput])
  }
  readonly property bool hasBattery: !!root.device
  readonly property real fraction: Model.batteryFraction(root.device)
  readonly property int percent: Math.round(root.fraction * 100)
  readonly property bool charging: !!root.device && root.device.state === UPowerDeviceState.Charging
  readonly property bool full: !!root.device &&
    (root.device.state === UPowerDeviceState.FullyCharged ||
     (root.fraction >= 1 && !root.discharging))
  readonly property bool discharging: !!root.device && root.device.state === UPowerDeviceState.Discharging
  // A reading of 0 is not a flat mouse, it is a mouse that has not reported
  // yet: UPower publishes the device as soon as the receiver sees it and the
  // HID++ level arrives afterwards, so every reconnect passes through 0%. A
  // mouse that really is at 0 is off, and off means no device at all.
  readonly property bool hasReading: root.hasBattery && root.device.ready !== false && root.percent > 0
  readonly property string alertLevel: root.hasReading
    ? Model.alertLevel(root.percent, root.discharging, root.lowThreshold, root.criticalThreshold)
    : ""
  readonly property bool low: root.alertLevel.length > 0
  readonly property bool critical: root.alertLevel === "critical"
  readonly property string modelName: Model.deviceLabel(root.device, "")

  // The colour the icon, the percentage and the charge bar turn once the
  // battery is low: amber while there is still time, the theme's urgent red
  // once it is about to switch off. Above the threshold they keep the bar's
  // foreground, so the tint itself is the signal.
  property string themeYellow: ""
  readonly property color warning: root.themeYellow.length > 0 ? root.themeYellow : "#e0af68"
  readonly property color alertColor: root.critical
    ? root.bar.urgent
    : (root.low ? root.warning : root.bar.foreground)

  // -------------------------------------------------------------- pointer
  // Hyprland's device list, and the one entry out of it the slider writes to.
  property var mice: []
  property real globalSensitivity: 0
  readonly property string pointerName: Model.pickPointer(root.mice, root.pinnedDevice, root.modelName)
  readonly property bool hasPointer: root.globalScope || root.pointerName.length > 0

  readonly property string scopeCaption: root.globalScope
    ? "all pointers"
    : (root.pointerName.length > 0 ? root.pointerName : "no pointer found")

  // ---------------------------------------------------------------- state
  // Notified-once latches for the low and the critical warning, so a mouse
  // sitting at 14% does not toast every time UPower publishes a reading.
  PersistentProperties {
    id: persisted
    reloadableId: "leonavas-mouse"
    property bool notifiedLow: false
    property bool notifiedCritical: false
  }

  // The shell exposes foreground/accent/urgent from the theme but not its
  // yellow, so the amber for the low state is read from the same colors.toml
  // the shell reads. Re-read when the shell's palette moves, which is how a
  // theme switch shows up from inside a plugin.
  FileView {
    id: themeColors
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: false
    printErrors: false
    onLoaded: root.themeYellow = Model.themeColor(text(), ["yellow", "bright_yellow"], "")
    onLoadFailed: root.themeYellow = ""
  }
  Connections {
    target: Color
    function onForegroundChanged() { themeColors.reload() }
    function onUrgentChanged() { themeColors.reload() }
  }

  // ------------------------------------------------------------- behavior

  function refreshDevices() {
    if (!devicesProc.running) devicesProc.running = true
    if (!optionProc.running) optionProc.running = true
  }

  // Push `value` to Hyprland without recording it. Used while the slider is
  // being dragged so the pointer answers under the hand.
  function previewSensitivity(value) {
    var lua = root.globalScope
      ? Model.globalSensitivityLua(value)
      : Model.deviceSensitivityLua(root.pointerName, value)
    if (lua.length === 0) return
    // Fire and forget: a drag emits these faster than a Process round-trip
    // would allow, and Hyprland applies them in order anyway.
    //
    // execArgv rather than bar.run: the snippet carries a device name that
    // came from a HID descriptor, and argv means no shell ever gets a chance
    // to re-tokenize it.
    Util.execArgv(["hyprctl", "eval", lua])
  }

  // Push and remember. `value === null` drops the override, handing the mouse
  // back to the global setting.
  function commitSensitivity(value) {
    if (value === null) {
      root.previewSensitivity(root.globalSensitivity)
      root.persist({ sensitivity: null })
      return
    }

    // Snapped, so a drag lands on the same grid the +/- buttons and the wheel
    // step along and the readout stays a number you could dial back to.
    var snapped = Model.snapSensitivity(value, root.sensitivityStep)
    root.previewSensitivity(snapped)
    root.persist({ sensitivity: snapped })
  }

  // One step of the +/- buttons, the wheel, and the arrow keys.
  function nudgeSensitivity(steps) {
    var from = Model.snapSensitivity(root.sensitivity, root.sensitivityStep)
    root.commitSensitivity(from + steps * root.sensitivityStep)
  }

  // Re-assert the stored sensitivity. `hyprctl eval` writes live config state,
  // which every config reload throws away — and Omarchy reloads on theme
  // changes and on any save under ~/.config/hypr. Without this the slider
  // would silently lose its value a few times a day.
  function reapply() {
    if (!root.hasOverride || !root.hasPointer) return
    root.previewSensitivity(root.sensitivity)
  }

  function persist(patch) {
    var next = {}
    for (var key in root.settings) next[key] = root.settings[key]
    for (var patchKey in patch) {
      if (patch[patchKey] === null) delete next[patchKey]
      else next[patchKey] = patch[patchKey]
    }
    root.settings = next
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, next)
  }

  function togglePercentage() {
    root.persist({ showPercentage: !root.showPercentage })
  }

  // Two warnings per discharge: a normal-urgency heads-up at the low
  // threshold, and a critical one — the kind that stays on screen — at the
  // critical threshold. Each re-arms once the mouse is charged back above its
  // own line, or as soon as it is plugged in.
  function checkLow() {
    if (!root.notifyLow || !root.hasReading) return

    if (!root.low && (root.percent > root.lowThreshold || root.charging)) persisted.notifiedLow = false
    if (!root.critical && (root.percent > root.criticalThreshold || root.charging)) persisted.notifiedCritical = false
    if (!root.low || notifyProc.running) return

    var name = root.modelName.length > 0 ? root.modelName : "Mouse"
    if (root.critical) {
      if (persisted.notifiedCritical) return
      persisted.notifiedCritical = true
      // The low warning has been overtaken; no point sending it afterwards.
      persisted.notifiedLow = true
      notifyProc.command = [
        "notify-send",
        "--app-name=Mouse",
        "--urgency=critical",
        "--expire-time=30000",
        "--icon=battery-caution",
        name + " battery critical",
        root.percent + "% left — charge it now, it is about to switch off."
      ]
    } else {
      if (persisted.notifiedLow) return
      persisted.notifiedLow = true
      notifyProc.command = [
        "notify-send",
        "--app-name=Mouse",
        "--urgency=normal",
        "--icon=input-mouse",
        name + " battery running out",
        root.percent + "% left — better to find that charger soon."
      ]
    }
    notifyProc.running = true
  }

  onLowChanged: root.checkLow()
  onCriticalChanged: root.checkLow()
  onPercentChanged: root.checkLow()

  // A mouse that just woke up is a mouse Hyprland re-enumerated, so the
  // pointer name may have moved and the device rule may be gone with it.
  onHasBatteryChanged: {
    if (root.hasBattery) reconnectTimer.restart()
    else persisted.notifiedLow = false
  }

  onPointerNameChanged: root.reapply()

  Component.onCompleted: root.refreshDevices()

  // ------------------------------------------------------------------ IPC
  IpcHandler {
    target: "leonavas.mouse"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function togglePercentage(): void { root.togglePercentage() }
    function reapply(): void { root.reapply() }
    function battery(): string { return root.hasReading ? String(root.percent) : "" }
    function alert(): string { return root.alertLevel.length > 0 ? root.alertLevel + " " + String(root.alertColor) : "" }
    function sensitivity(): string { return Model.formatSensitivity(root.sensitivity) }
    function pointer(): string { return root.scopeCaption }

    // Everything UPower is publishing, for when the widget shows no battery
    // and the question is whether the mouse is missing or merely unreadable.
    // This is the call that caught `percentage` being a 0..1 fraction rather
    // than a 0..100 number.
    function debugDevices(): string {
      var list = UPower.devices ? (UPower.devices.values || []) : []
      var out = []
      for (var i = 0; i < list.length; i++) {
        var d = list[i]
        out.push({ model: String(d.model), type: d.type, ready: d.ready,
                   percentage: d.percentage, isPresent: d.isPresent,
                   powerSupply: d.powerSupply, nativePath: String(d.nativePath) })
      }
      return JSON.stringify({ mouseEnum: UPowerDeviceType.Mouse,
                              gamingEnum: UPowerDeviceType.GamingInput,
                              devices: out })
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      // A reload rebuilds Hyprland's config state from disk: the global
      // sensitivity may have moved and our device rule is certainly gone.
      if (String(event.name) === "configreloaded") reloadTimer.restart()
    }
  }

  // Both timers coalesce a burst of events into one round-trip, and give
  // Hyprland a moment to finish rebuilding before we read it back.
  Timer {
    id: reloadTimer
    interval: 300
    onTriggered: root.refreshDevices()
  }

  Timer {
    id: reconnectTimer
    interval: 600
    onTriggered: root.refreshDevices()
  }

  Process {
    id: devicesProc
    command: ["hyprctl", "-j", "devices"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.mice = Model.parseMice(text)
        // Ordering matters: `mice` feeds `pointerName`, and only a resolved
        // pointer can be written to.
        root.reapply()
      }
    }
  }

  Process {
    id: optionProc
    command: ["hyprctl", "-j", "getoption", "input:sensitivity"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.globalSensitivity = Model.parseOption(text)
    }
  }

  Process { id: notifyProc }

  // --------------------------------------------------------------- widget
  readonly property bool shown: root.hasBattery || !root.hideWhenAbsent

  visible: root.shown
  implicitWidth: root.shown ? button.implicitWidth : 0
  implicitHeight: root.shown ? button.implicitHeight : 0

  onShownChanged: if (!root.shown) close()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    readonly property bool labelled: root.showPercentage && root.hasReading && !vertical

    text: {
      var icon = root.hasBattery ? root.glyph : root.absentGlyph
      return labelled ? root.percent + "% " + icon : icon
    }
    slotSize: Style.bar.iconSlot * (labelled ? 2 : 1)
    active: root.tintWhenLow && root.low
    activeColor: root.alertColor
    dimmed: root.dimWhenAbsent && !root.hasBattery
    tooltipText: {
      if (!root.hasBattery) return "Mouse — no battery reported"
      if (!root.hasReading) return "Mouse — waiting for a battery reading"
      var name = root.modelName.length > 0 ? root.modelName : "Mouse"
      return name + " — " + root.percent + "%, " +
             Model.stateLabel(root.device, { Charging: UPowerDeviceState.Charging,
                                             Discharging: UPowerDeviceState.Discharging,
                                             PendingCharge: UPowerDeviceState.PendingCharge,
                                             Empty: UPowerDeviceState.Empty },
                              root.full).toLowerCase()
    }
    onPressed: function(b) {
      // Right click is the gesture this widget was asked for; left click opens
      // the same panel because every other widget in the bar does, and a bar
      // icon that ignores a left click reads as broken.
      if (b === Qt.MiddleButton) root.togglePercentage()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      if (!root.hasPointer) return
      root.nudgeSensitivity(delta > 0 ? 1 : -1)
    }
  }

  // ---------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.shown
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.hasPointer) return
        if (dx !== 0) root.nudgeSensitivity(dx)
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: battery glyph · name/state · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            text: root.hasReading
              ? Model.batteryIcon(root.fraction, root.charging, root.full)
              : (root.hasBattery ? root.glyph : root.absentGlyph)
            color: root.alertColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: root.modelName.length > 0 ? root.modelName : "Mouse"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: Model.stateLabel(root.device,
                                     { Charging: UPowerDeviceState.Charging,
                                       Discharging: UPowerDeviceState.Discharging,
                                       PendingCharge: UPowerDeviceState.PendingCharge,
                                       Empty: UPowerDeviceState.Empty },
                                     root.full).toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            text: root.hasReading ? root.percent + "%" : "—"
            color: root.alertColor
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Charge bar ----------
        Item {
          visible: root.hasReading
          width: parent.width
          implicitHeight: root.hasReading ? Style.space(8) : 0

          Rectangle {
            id: chargeTrack
            anchors.fill: parent
            radius: height / 2
            color: Util.alpha(root.bar.foreground, 0.12)
          }

          Rectangle {
            anchors.left: chargeTrack.left
            anchors.verticalCenter: chargeTrack.verticalCenter
            height: chargeTrack.height
            radius: chargeTrack.radius
            color: root.alertColor
            width: Math.max(chargeTrack.height, chargeTrack.width * root.fraction)

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }

            SequentialAnimation on opacity {
              running: root.charging && !root.full && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Sensitivity ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            implicitHeight: sectionLabel.implicitHeight

            PanelSectionHeader {
              id: sectionLabel
              text: "󰓅  POINTER SENSITIVITY"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              text: Model.formatSensitivity(root.sensitivity)
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              anchors.right: parent.right
              anchors.verticalCenter: sectionLabel.verticalCenter
            }
          }

          // A step button at each end of the track, for setting the value by
          // clicking rather than by aiming: the slider is 2.0 wide in a couple
          // of hundred pixels, so one step is about six pixels of travel and
          // not something a hand hits reliably.
          Item {
            width: parent.width
            implicitHeight: slider.implicitHeight
            enabled: root.hasPointer
            opacity: root.hasPointer ? 1 : 0.4

            StepButton {
              id: stepDown
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              glyph: "󰍴"
              // Nothing left to give: the track bottoms out at -1.
              enabled: root.sensitivity > -1
              tooltipText: "Slower by " + root.sensitivityStep.toFixed(2)
              onClicked: root.nudgeSensitivity(-1)
            }

            PanelSlider {
              id: slider
              bar: root.bar
              anchors.left: stepDown.right
              anchors.right: stepUp.left
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              minimum: -1
              maximum: 1
              step: root.sensitivityStep
              // -1, -0.5, 0, +0.5, +1 — the notch in the middle is the one
              // worth finding by feel, since 0 is the device's own default.
              tickCount: 5
              value: root.sensitivity
              onMoved: function(v) { root.previewSensitivity(v) }
              onReleased: function(v) { root.commitSensitivity(v) }
            }

            StepButton {
              id: stepUp
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              glyph: "󰐕"
              enabled: root.sensitivity < 1
              tooltipText: "Faster by " + root.sensitivityStep.toFixed(2)
              onClicked: root.nudgeSensitivity(1)
            }
          }

          // What the slider is actually writing to, and the way back out.
          Item {
            width: parent.width
            implicitHeight: Math.max(scopeText.implicitHeight, resetButton.implicitHeight)

            Text {
              id: scopeText
              anchors.left: parent.left
              anchors.right: resetButton.visible ? resetButton.left : parent.right
              anchors.rightMargin: resetButton.visible ? Style.space(8) : 0
              anchors.verticalCenter: parent.verticalCenter
              text: root.scopeCaption
              color: root.bar.foreground
              opacity: 0.6
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
            }

            Button {
              id: resetButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              visible: root.hasOverride
              text: "Reset"
              tooltipText: "Follow the global setting (" +
                           Model.formatSensitivity(root.globalSensitivity) + ")"
              fontSize: Style.font.caption
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              bordered: true
              verticalPadding: Style.spacing.controlPaddingY - Style.space(2)
              onClicked: root.commitSensitivity(null)
            }
          }
        }
      }
    }
  }

  // The square glyph button that bookends the sensitivity track. Kept as one
  // component so both ends are the same size — a Row would otherwise let the
  // minus and plus glyphs size themselves differently and leave the track
  // off-centre.
  component StepButton: Button {
    property string glyph: ""

    iconText: glyph
    iconSize: Style.font.body
    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
    foreground: root.bar ? root.bar.foreground : Color.foreground
    accent: root.bar ? root.bar.urgent : Color.urgent
    bordered: true
    horizontalPadding: Style.spacing.controlPaddingX - Style.space(3)
    verticalPadding: Style.spacing.controlPaddingY - Style.space(2)
    // At either end of the range there is no step left to take. The button
    // stays in place rather than disappearing, so the track keeps its width
    // and the row does not jump as the value reaches the limit.
    opacity: enabled ? 1 : 0.3
  }
}
