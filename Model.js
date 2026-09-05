.pragma library

// Pure helpers for the mouse widget. Kept out of the QML so the widget body
// stays layout code. Nothing here touches Hyprland or UPower directly — the
// QML hands in the objects and the enum values it read from the real
// singletons, which keeps this file testable and keeps QML binding capture
// working.

// ---------------------------------------------------------------- settings

function truthy(value, fallback) {
  if (value === undefined || value === null) return fallback
  if (typeof value === "boolean") return value
  if (typeof value === "number") return value !== 0
  var text = String(value).toLowerCase()
  if (text === "true" || text === "1" || text === "yes") return true
  if (text === "false" || text === "0" || text === "no") return false
  return fallback
}

// Hyprland's sensitivity is a libinput accel speed: -1 (slowest) to 1
// (fastest), 0 being the device's own default. Anything outside that range is
// rejected by the config parser, so clamp before it ever reaches Lua.
function clampSensitivity(value) {
  var n = Number(value)
  if (!isFinite(n)) return 0
  return Math.max(-1, Math.min(1, n))
}

function isSensitivity(value) {
  return typeof value === "number" && isFinite(value)
}

// The slider drags continuously but the +/- buttons and the wheel move in
// steps of 0.05, so every committed value is snapped onto that grid. Without
// it a drag leaves something like -0.8070423315602837 in shell.json and the
// readout shows a number the buttons could never produce.
function snapSensitivity(value, step) {
  var grid = Number(step) > 0 ? Number(step) : 0.05
  var snapped = Math.round(clampSensitivity(value) / grid) * grid
  // Multiplying back out reintroduces binary float dust (0.15000000000000002),
  // which would then be written to shell.json verbatim.
  return clampSensitivity(Number(snapped.toFixed(4)))
}

function formatSensitivity(value) {
  var n = clampSensitivity(value)
  return (n > 0 ? "+" : "") + n.toFixed(2)
}

// ---------------------------------------------------------------- battery

// The mouse UPower is willing to talk about. `types` carries the
// UPowerDeviceType enum values the caller considers a mouse, since a JS
// library cannot import QML enums.
//
// A device is only taken once `ready` is true: UPower publishes the object
// before its properties land, and an unready device reads as 0% present,
// which would paint an empty battery for a moment on every reconnect.
function mouseBattery(devices, types) {
  var list = devices || []
  var wanted = types || []
  var best = null

  for (var i = 0; i < list.length; i++) {
    var device = list[i]
    if (!device || device.ready === false) continue
    if (wanted.indexOf(device.type) === -1) continue
    if (device.isPresent === false) continue
    // A mouse plugged in by cable is a power supply for itself and reports no
    // meaningful charge; the wireless one is what this widget is about.
    if (device.powerSupply === true) continue
    // Prefer the first mouse that actually reports a level. Some HID++
    // devices publish the object with percentage 0 until the first report
    // arrives, so a later device with real data wins over an empty one.
    if (!best) best = device
    else if (!(best.percentage > 0) && device.percentage > 0) best = device
  }

  return best
}

// Quickshell's UPowerDevice.percentage is already a 0..1 fraction, not a
// 0..100 number — the same scale the first-party power panel reads.
function batteryFraction(device) {
  if (!device || device.isPresent === false) return 0
  var fraction = Number(device.percentage)
  if (!isFinite(fraction)) return 0
  return Math.max(0, Math.min(1, fraction))
}

// The same ten-step glyph ramp the first-party power panel paints, so a mouse
// battery and a laptop battery read as the same kind of thing in the bar.
function batteryIcon(fraction, charging, full) {
  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var index = Math.max(0, Math.min(9, Math.floor(Number(fraction) * 10)))
  if (full) return "󰂅"
  return charging ? chargingIcons[index] : defaultIcons[index]
}

// Which alert a reading calls for: "critical" at or under the critical line,
// "low" at or under the low line, "" otherwise. Only a discharging mouse is
// ever low — one on the charger is on its way back up.
function alertLevel(percent, discharging, lowThreshold, criticalThreshold) {
  if (!discharging) return ""
  var n = Number(percent)
  if (!isFinite(n) || n <= 0) return ""
  var low = Number(lowThreshold)
  var critical = Math.min(low, Number(criticalThreshold))
  if (n <= critical) return "critical"
  if (n <= low) return "low"
  return ""
}

// ------------------------------------------------------------------ theme

// One "#rrggbb" out of the theme's colors.toml, by the first of `keys` that
// is set. The shell exposes foreground/accent/urgent from that file but not
// its yellow, and the low state wants the theme's own amber rather than a
// hard-coded one. Same line shape the shell's Color.qml matches on.
function themeColor(raw, keys, fallback) {
  var wanted = keys || []
  var found = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
    if (match) found[match[1]] = match[2]
  }
  for (var k = 0; k < wanted.length; k++) {
    if (found[wanted[k]]) return found[wanted[k]]
  }
  return fallback || ""
}

function stateLabel(device, states, full) {
  if (!device) return "Not connected"
  if (full) return "Fully charged"
  if (device.state === states.Charging) return "Charging"
  if (device.state === states.PendingCharge) return "Pending charge"
  if (device.state === states.Empty) return "Empty"
  if (device.state === states.Discharging) return "On battery"
  return "Unknown"
}

// UPower's model string, tidied for display. The kernel and UPower disagree on
// case and prefix for the same mouse ("Logitech X2 SUPERSTRIKE" vs "PRO X2
// SUPERSTRIKE"), so this only trims — it never tries to be clever.
function deviceLabel(device, fallback) {
  if (!device) return fallback || ""
  var model = String(device.model || "").trim()
  return model.length > 0 ? model : (fallback || "")
}

// ---------------------------------------------------------------- pointer

// Hyprland device names come from USB/HID descriptors, lowercased and
// hyphenated. Split into comparable tokens so a UPower model string can be
// matched against them.
function tokens(text) {
  return String(text || "")
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(function (t) { return t.length > 1 })
}

// Names that are reported under `mice` but are not the mouse anyone means:
// touchpads, and the pointer half of a keyboard's HID descriptor.
var NON_MOUSE = ["touchpad", "trackpad", "touchscreen", "keyboard", "stylus",
                 "pen", "tablet", "eraser", "wireless-radio-control",
                 "consumer-control", "system-control"]

function looksLikeMouse(name) {
  var lower = String(name || "").toLowerCase()
  if (lower.length === 0) return false
  for (var i = 0; i < NON_MOUSE.length; i++) {
    if (lower.indexOf(NON_MOUSE[i]) !== -1) return false
  }
  return true
}

// Which Hyprland pointer the sensitivity applies to.
//
// Hyprland lists every HID that can move a cursor under `mice`, so a keyboard
// and a touchpad sit in the same list as the mouse, and it disambiguates
// same-named devices with a `-1` suffix that shifts as devices come and go.
// Scoring against the UPower model is what makes the pick survive that: the
// battery and the pointer are the same physical mouse, so its name is the one
// that shares the most tokens with the model string.
//
// `pinned` (the deviceName setting) always wins — it is the escape hatch for
// when the guess is wrong or there are two mice.
function pickPointer(mice, pinned, modelHint) {
  var list = mice || []
  var names = []
  for (var i = 0; i < list.length; i++) {
    var name = list[i] && list[i].name ? String(list[i].name) : ""
    if (name.length > 0) names.push(name)
  }

  if (pinned && names.indexOf(String(pinned)) !== -1) return String(pinned)

  var candidates = names.filter(looksLikeMouse)
  if (candidates.length === 0) candidates = names
  if (candidates.length === 0) return ""

  var hint = tokens(modelHint)
  if (hint.length > 0) {
    var best = ""
    var bestScore = 0
    for (var c = 0; c < candidates.length; c++) {
      var own = tokens(candidates[c])
      var score = 0
      for (var h = 0; h < hint.length; h++) {
        if (own.indexOf(hint[h]) !== -1) score++
      }
      if (score > bestScore) {
        bestScore = score
        best = candidates[c]
      }
    }
    if (bestScore > 0) return best
  }

  // No battery to match against (a wired mouse, or UPower not reporting yet).
  // Prefer a name that says "mouse" outright, else the first plausible one.
  for (var m = 0; m < candidates.length; m++) {
    if (String(candidates[m]).toLowerCase().indexOf("mouse") !== -1) return candidates[m]
  }
  return candidates[0]
}

function parseMice(raw) {
  try {
    var parsed = JSON.parse(String(raw))
    return Array.isArray(parsed.mice) ? parsed.mice : []
  } catch (e) {
    return []
  }
}

function parseOption(raw) {
  try {
    var parsed = JSON.parse(String(raw))
    var value = Number(parsed.float)
    return isFinite(value) ? value : 0
  } catch (e) {
    return 0
  }
}

// ---------------------------------------------------------------- lua

// Omarchy configures Hyprland through the Lua parser, which refuses
// `hyprctl keyword` outright ("keyword can't work with non-legacy parsers.
// Use eval."). Every write therefore goes out as a Lua snippet through
// `hyprctl eval`.
//
// Device names come from HID descriptors — data, never code. They are wrapped
// in a long-bracket literal, which has no escape sequences and no
// interpolation, and any name that could close that bracket or carry a newline
// is refused rather than escaped. Same rule Omarchy's own
// disabled-input-device.lua follows for the touchpad toggle.
function luaString(value) {
  var text = String(value === undefined || value === null ? "" : value)
  if (text.length === 0) return null
  if (/[\r\n\0]/.test(text)) return null
  if (text.indexOf("]==]") !== -1) return null
  return "[==[" + text + "]==]"
}

// A per-device rule, so the sensitivity lands on this mouse and leaves the
// touchpad and any second pointer on whatever the config gave them.
function deviceSensitivityLua(name, value) {
  var quoted = luaString(name)
  if (!quoted) return ""
  return "hl.device({ name = " + quoted + ", sensitivity = " +
         clampSensitivity(value).toFixed(4) + " })"
}

// The global input section, for when the slider is meant to move every
// pointer at once.
function globalSensitivityLua(value) {
  return "hl.config({ input = { sensitivity = " +
         clampSensitivity(value).toFixed(4) + " } })"
}
