// Parsing, formatting and health policy for the Homebridge panel. The status
// script reports facts about accessories; every judgement about what to show
// and how is made here, on plain data.

// Accessory names come off a server the user configured but that this plugin
// does not otherwise trust, and reach the screen. QML's Text defaults to
// AutoText, which renders anything that looks like markup as rich text and
// fetches what it references, so strings are cleaned at this one boundary — the
// shared components (PanelHero, tooltips) are covered too, since a plugin
// cannot set their textFormat.
var MAX_TEXT = 120

function sanitize(value) {
  var s = String(value === undefined || value === null ? "" : value)
  s = s.replace(/[<>]/g, "")
  s = s.replace(/[\x00-\x1f\x7f]/g, " ")
  s = s.replace(/\s+/g, " ").trim()
  if (s.length > MAX_TEXT) s = s.substring(0, MAX_TEXT - 1) + "…"
  return s
}

function emptyStatus() {
  return {
    ok: false, error: "", configured: false, configPath: "", now: 0,
    serverUrl: "", accessories: [],
    totals: { count: 0, on: 0, open: 0, motion: 0, lowBattery: 0, alarm: 0 }
  }
}

function asBool(v) {
  return v === true || v === 1 || v === "1" || v === "true"
}

function clampBrightness(v) {
  var n = Math.round(Number(v))
  if (!isFinite(n)) return 0
  return Math.max(0, Math.min(100, n))
}

// ------------------------------------------------------------ security modes

// HomeKit's four. The names are the ones Apple's own Home app puts on the tile,
// because a person setting their alarm from a Linux bar should not have to
// learn a second vocabulary for it.
var SECURITY_MODES = [
  { value: 0, label: "Home" },
  { value: 1, label: "Away" },
  { value: 2, label: "Night" },
  { value: 3, label: "Off" }
]
// A fifth current-state that is not a mode you can ask for: the system is going
// off right now.
var SECURITY_ALARM = 4

function securityLabel(code) {
  var n = Number(code)
  if (n === SECURITY_ALARM) return "Alarm triggered"
  for (var i = 0; i < SECURITY_MODES.length; i++) {
    if (SECURITY_MODES[i].value === n) return SECURITY_MODES[i].label
  }
  return "Unknown"
}

// Only the modes the accessory itself declares. A SimpliSafe bridge declares
// [0,1,3] and has no Night at all, so offering a hardcoded four would put a
// button on screen whose only possible outcome is the server refusing it.
function securityModes(a) {
  // No accessory is no modes. The fallback below is for a system that exists
  // but declares nothing — reaching it with null would put four chips on screen
  // during the instant a delegate is built before its accessory is bound, and a
  // Night button that should never have existed can stick there.
  if (!a || a.kind !== "security") return []
  var declared = Array.isArray(a.securityModes) ? a.securityModes : []
  var allowed = declared.length > 0 ? declared : [0, 1, 2, 3]
  var out = []
  for (var i = 0; i < SECURITY_MODES.length; i++) {
    var mode = SECURITY_MODES[i]
    if (allowed.indexOf(mode.value) !== -1) out.push(mode)
  }
  return out
}

// The value reaches a burglar alarm, so it is matched against the four rather
// than range-checked. The set helper checks this again; this copy lets the
// panel refuse before it asks the question, rather than asking "arm the house?"
// about something it was never going to be able to send.
function isSafeSecurityTarget(value) {
  return value === 0 || value === 1 || value === 2 || value === 3
}

// Which mode reads as chosen on the row. During a transition that is the one
// asked for, so the button you pressed stays lit while the house catches up.
function securityChosen(a) {
  if (!a || a.kind !== "security") return null
  if (a.securityTarget !== null && a.securityTarget !== undefined) return Number(a.securityTarget)
  return a.securityCurrent === null ? null : Number(a.securityCurrent)
}

function isArmed(a) {
  if (!a || a.kind !== "security") return false
  var n = Number(a.securityCurrent)
  return n === 0 || n === 1 || n === 2 || n === SECURITY_ALARM
}

function isAlarming(a) {
  return !!a && a.kind === "security" && Number(a.securityCurrent) === SECURITY_ALARM
}

// Arming a real system is not instant — an away mode gives you a minute to
// leave — so target and current disagree for as long as it takes. That gap is
// the honest thing to show: the panel does not pretend the house is armed the
// moment the button is pressed, and it does not have to invent a timer either,
// because the server says so itself.
function securityInTransition(a) {
  if (!a || a.kind !== "security") return false
  if (a.securityTarget === null || a.securityCurrent === null) return false
  // A system going off has not been asked for anything; it is reporting.
  if (Number(a.securityCurrent) === SECURITY_ALARM) return false
  return Number(a.securityTarget) !== Number(a.securityCurrent)
}

// ------------------------------------------------------------------- sensors

// What each reading is called, and which way round it reads. HomeKit says 1 for
// "contact not detected", which is a door standing open — the least intuitive
// value in the whole API, and the one a panel gets backwards.
var SENSOR_READINGS = {
  ContactSensorState:      { on: "Open",     off: "Closed", alerts: false },
  MotionDetected:          { on: "Motion",   off: "Clear",  alerts: false },
  OccupancyDetected:       { on: "Occupied", off: "Clear",  alerts: false },
  SmokeDetected:           { on: "Smoke",    off: "Clear",  alerts: true },
  CarbonMonoxideDetected:  { on: "CO",       off: "Clear",  alerts: true },
  LeakDetected:            { on: "Leak",     off: "Dry",    alerts: true }
}

function isMeasurement(type) {
  return type === "CurrentTemperature" || type === "CurrentRelativeHumidity"
}

// HomeKit reports temperature in Celsius always. Plenty of the people who will
// install this do not think in it.
function temperatureText(celsius, unit) {
  // Number(null) is 0, and a thermometer that has not reported yet must not be
  // rendered as a room at freezing.
  if (celsius === null || celsius === undefined || celsius === '') return ''
  var c = Number(celsius)
  if (!isFinite(c)) return ""
  if (unit === "fahrenheit") return String(Math.round(c * 9 / 5 + 32)) + "°F"
  return String(Math.round(c * 10) / 10) + "°C"
}

function sensorText(a, unit) {
  if (!a || a.kind !== "sensor") return ""
  var type = String(a.sensor || "")
  if (type === "CurrentTemperature") return temperatureText(a.sensorValue, unit)
  if (type === "CurrentRelativeHumidity") {
    if (a.sensorValue === null || a.sensorValue === undefined || a.sensorValue === '') return ''
    var h = Number(a.sensorValue)
    return isFinite(h) ? String(Math.round(h)) + "%" : ""
  }
  var reading = SENSOR_READINGS[type]
  if (!reading) return ""
  return asBool(a.sensorValue) ? reading.on : reading.off
}

// A sensor that is merely reporting something — a door open, someone moving —
// is not a fault. Smoke, carbon monoxide and water are.
function sensorAlerts(a) {
  if (!a || a.kind !== "sensor") return false
  var reading = SENSOR_READINGS[String(a.sensor || "")]
  return !!reading && reading.alerts && asBool(a.sensorValue)
}

// A sensor that is saying something other than its resting state. Used to
// decide emphasis on the row, not to raise an alarm.
function sensorActive(a) {
  if (!a || a.kind !== "sensor") return false
  if (isMeasurement(a.sensor)) return false
  return asBool(a.sensorValue)
}

// ------------------------------------------------------------------ parsing

function sanitizeAccessory(a) {
  if (!a || typeof a !== "object") return null

  var kind = String(a.kind || "")
  if (kind !== "switch" && kind !== "security" && kind !== "sensor") return null

  var out = {
    uniqueId: String(a.uniqueId === undefined || a.uniqueId === null ? "" : a.uniqueId),
    kind: kind,
    name: sanitize(a.name),
    type: sanitize(a.type),
    on: asBool(a.on),
    dimmable: a.dimmable === true,
    brightness: (a.brightness === null || a.brightness === undefined) ? null : clampBrightness(a.brightness),
    securityCurrent: (a.securityCurrent === null || a.securityCurrent === undefined) ? null : Number(a.securityCurrent),
    securityTarget: (a.securityTarget === null || a.securityTarget === undefined) ? null : Number(a.securityTarget),
    securityModes: (Array.isArray(a.securityModes) ? a.securityModes : [])
      .map(Number)
      .filter(isSafeSecurityTarget),
    sensor: sanitize(a.sensor),
    sensorValue: (a.sensorValue === undefined) ? null : a.sensorValue,
    lowBattery: a.lowBattery === true,
    tampered: a.tampered === true,
    fault: a.fault === true
  }
  if (out.name === "") out.name = out.type || "Accessory"

  // An accessory with no id it can name back to the server, or an id with
  // characters the server never issues, cannot be acted on. A switch or a
  // security system is dropped rather than shown as a row that cannot act; a
  // sensor is only ever read, so it stays.
  if (!isSafeUniqueId(out.uniqueId) && out.kind !== "sensor") return null

  return out
}

// Security first — it is the one row where being wrong matters — then the
// things that can be switched, then the things that can only be read. Order
// within each group is the server's, so rows do not move under the cursor
// between polls. A smoke alarm going off is carried by the headline rather than
// by shuffling it to the top, because a row that jumps is a row mis-clicked.
var KIND_ORDER = { security: 0, switch: 1, sensor: 2 }

function sortAccessories(list) {
  return list
    .map(function(a, i) { return { a: a, i: i } })
    .sort(function(x, y) {
      var dk = KIND_ORDER[x.a.kind] - KIND_ORDER[y.a.kind]
      return dk !== 0 ? dk : x.i - y.i
    })
    .map(function(entry) { return entry.a })
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return emptyStatus()
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return emptyStatus()
    var status = emptyStatus()
    status.ok = parsed.ok === true
    status.error = sanitize(parsed.error)
    status.configured = parsed.configured === true
    status.configPath = sanitize(parsed.configPath)
    status.now = Number(parsed.now || 0)
    status.serverUrl = sanitize(parsed.serverUrl)
    status.accessories = sortAccessories(
      (Array.isArray(parsed.accessories) ? parsed.accessories : [])
        .map(sanitizeAccessory)
        .filter(function(a) { return a !== null })
    )
    // Counted from the list that survives sanitising, never from the totals the
    // helper sent. The two differ exactly when an accessory is dropped here for
    // an id this panel will not send back, and a bar reading "3 on" above two
    // rows promises a light the panel cannot reach.
    status.totals = countTotals(status.accessories)
    return status
  } catch (e) {
    var broken = emptyStatus()
    broken.error = "Could not parse the Homebridge status"
    return broken
  }
}

function countTotals(list) {
  var totals = { count: list.length, on: 0, open: 0, motion: 0, lowBattery: 0, alarm: 0 }
  for (var i = 0; i < list.length; i++) {
    var a = list[i]
    if (a.kind === "switch" && a.on) totals.on += 1
    if (a.sensor === "ContactSensorState" && asBool(a.sensorValue)) totals.open += 1
    if (a.sensor === "MotionDetected" && asBool(a.sensorValue)) totals.motion += 1
    if (a.lowBattery) totals.lowBattery += 1
    if (isAlarming(a)) totals.alarm += 1
  }
  return totals
}

// -------------------------------------------------------------- per accessory

function isOn(a) {
  return !!a && a.on === true
}

// A row you can press: a switch to toggle, or a security system to set. A
// sensor is a reading, so the cursor skips it rather than landing somewhere
// that space does nothing.
function isActionable(a) {
  return !!a && (a.kind === "switch" || a.kind === "security") && isSafeUniqueId(a.uniqueId)
}

function navItems(accessories) {
  var list = accessories || []
  var items = []
  for (var i = 0; i < list.length; i++) {
    if (isActionable(list[i])) items.push({ index: i, accessory: list[i] })
  }
  return items
}

// The panel asks about an accessory and the poll behind it keeps replacing the
// list, so an accepted confirmation is resolved by the id it was opened for
// rather than by where that row used to sit. A list that reordered between the
// question and the answer would otherwise arm or disarm whatever had moved into
// the old position.
function accessoryById(status, id) {
  var wanted = String(id || "")
  if (wanted === "") return null
  var list = (status && status.accessories) || []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && String(list[i].uniqueId) === wanted) return list[i]
  }
  return null
}

function brightnessText(a) {
  if (!a || !a.dimmable || a.brightness === null) return ""
  return String(clampBrightness(a.brightness)) + "%"
}

// What a row says on its right-hand side, whatever kind it is.
function stateText(a, unit) {
  if (!a) return ""
  if (a.kind === "security") {
    if (securityInTransition(a)) return Number(a.securityTarget) === 3 ? "Disarming…" : "Arming…"
    return securityLabel(a.securityCurrent)
  }
  if (a.kind === "sensor") return sensorText(a, unit)
  if (isOn(a)) {
    var b = brightnessText(a)
    return b !== "" ? b : "On"
  }
  return "Off"
}

// The row's badges: things true of the accessory that its main reading does not
// carry. A dead sensor battery is the reason a door looks permanently shut.
function badges(a) {
  var out = []
  if (!a) return out
  if (a.lowBattery) out.push("battery low")
  if (a.tampered) out.push("tampered")
  if (a.fault) out.push("fault")
  return out
}

// The id is spliced into a URL path by the set helper, which checks it again.
// This copy lets the panel refuse before it acts, rather than asking the helper
// to reject something the panel should never have sent.
function isSafeUniqueId(id) {
  return /^[A-Za-z0-9]+$/.test(String(id || ""))
}

// -------------------------------------------------------------- whole server

function securitySystem(status) {
  var list = (status && status.accessories) || []
  for (var i = 0; i < list.length; i++) {
    if (list[i].kind === "security") return list[i]
  }
  return null
}

function alertingSensors(status) {
  var list = (status && status.accessories) || []
  return list.filter(sensorAlerts)
}

// Both forms spelled out. A rule that appends an "s" turns "low battery" into
// "low batterys" and "open" into "opens".
function count(n, one, many) {
  return n + " " + (n === 1 ? one : many)
}

// What the panel says under its title: everything notable about the home, in
// descending order of how much it wants you to know. A home with nothing to
// report says so rather than reciting a zero for each thing it checked.
function summaryText(status) {
  if (!status || !status.configured) return "Not signed in"
  var totals = status.totals || {}
  if ((totals.count || 0) === 0) return "Nothing to show"

  // The alarm's mode leads when there is one, but it states where the house
  // stands rather than asking for anything — so on its own it is not news, and
  // the summary still says how big the house is.
  var security = securitySystem(status)
  var lead = security ? securityLabel(security.securityCurrent) : ""

  var notable = []
  var alerting = alertingSensors(status)
  for (var i = 0; i < alerting.length; i++) {
    notable.push(sensorText(alerting[i]) + " in " + alerting[i].name)
  }
  if (totals.on > 0) notable.push(totals.on + " on")
  if (totals.open > 0) notable.push(totals.open + " open")
  if (totals.motion > 0) notable.push("motion")
  if (totals.lowBattery > 0) notable.push(count(totals.lowBattery, "low battery", "low batteries"))

  var scale = count(totals.count, "device", "devices")
  if (notable.length === 0) return lead === "" ? "All quiet · " + scale : lead + " · " + scale
  return (lead === "" ? notable : [lead].concat(notable)).join(" · ")
}

// What the bar carries beside the icon. A home at rest says nothing: a disarmed
// alarm and no lights on is the normal state of a house with someone in it, and
// a widget that announces that is noise. An armed house is worth a word,
// because leaving with it disarmed is the mistake this can actually prevent.
function barText(status, everLoaded, showCount, showSecurity) {
  if (!everLoaded || !status || !status.configured) return ""
  var totals = status.totals || {}
  if ((totals.alarm || 0) > 0) return "Alarm"
  var alerting = alertingSensors(status)
  if (alerting.length > 0) return sensorText(alerting[0])

  var parts = []
  if (showSecurity !== false) {
    var security = securitySystem(status)
    if (security && isArmed(security)) parts.push(securityLabel(security.securityCurrent))
  }
  if (showCount !== false && totals.on > 0) parts.push(String(totals.on))
  return parts.join(" ")
}

// A server that cannot be reached is critical: everything else on the panel is
// then unknown rather than fine. So is a house whose alarm is going off, or a
// sensor reporting smoke, carbon monoxide or water — those are the three
// readings where a bar widget noticing first is the whole point of it.
//
// A low battery is deliberately not one of them. It is true for weeks at a
// time, and an icon that has been amber since March is an icon nobody reads.
// It goes in the summary, where opening the panel finds it.
function health(status) {
  if (!status || !status.configured) {
    return { level: "ok", headline: "Not signed in", issues: [] }
  }
  if (!status.ok || status.error) {
    var message = status.error || "Homebridge is not answering"
    return { level: "critical", headline: message, issues: [{ level: "critical", text: message }] }
  }

  var issues = []
  var security = securitySystem(status)
  if (security && isAlarming(security)) {
    issues.push({ level: "critical", text: security.name + " is going off" })
  }
  var alerting = alertingSensors(status)
  for (var i = 0; i < alerting.length; i++) {
    issues.push({ level: "critical", text: sensorText(alerting[i]) + " detected in " + alerting[i].name })
  }
  if (issues.length > 0) {
    return { level: "critical", headline: issues[0].text, issues: issues }
  }
  return { level: "ok", headline: summaryText(status), issues: [] }
}

// The sign-in runs in a terminal, and the terminal launcher takes one command
// string that a shell re-parses. A config path is the only thing interpolated
// into it, but a path may contain spaces, so it is quoted for that shell rather
// than trusted to be one word.
function shellQuote(value) {
  return "'" + String(value === undefined || value === null ? "" : value).split("'").join("'\\''") + "'"
}

// Text handed to a shared component rather than to one of this plugin's own
// Text elements. This plugin sets textFormat: Text.PlainText on the Texts it
// owns; it cannot on PanelHero or a tooltip, whose Text defaults to AutoText.
// sanitize() already strips angle brackets, but that is a property of each field
// passing through sanitize, not of this boundary — so a composed string is made
// inert here, where it leaves for a component this plugin does not control.
function plainForShared(text) {
  return String(text === undefined || text === null ? "" : text)
    .replace(/&/g, "and")
    .replace(/[<>]/g, "")
    .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "")
}

// The sentence the confirmation puts on screen. Composed here rather than in
// the panel because it is a judgement about what someone needs to know before
// they disarm a house, not a layout concern.
function securityConfirmMessage(accessory, target) {
  if (!accessory) return ""
  var to = securityLabel(target)
  var from = securityLabel(accessory.securityCurrent)
  var lead = "Set " + accessory.name + " to " + to + "?"
  var body = target === 3
    ? "It is " + from + " now. Disarming turns the alarm off until you set it again."
    : "It is " + from + " now."
  return plainForShared(lead + "\n\n" + body)
}
