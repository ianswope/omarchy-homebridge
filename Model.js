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
    serverUrl: "", accessories: [], totals: { count: 0, on: 0 }
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

function sanitizeAccessory(a) {
  if (!a || typeof a !== "object") return null
  var out = {
    uniqueId: String(a.uniqueId === undefined || a.uniqueId === null ? "" : a.uniqueId),
    name: sanitize(a.name),
    type: sanitize(a.type),
    on: asBool(a.on),
    dimmable: a.dimmable === true,
    brightness: (a.brightness === null || a.brightness === undefined) ? null : clampBrightness(a.brightness)
  }
  if (out.name === "") out.name = out.type || "Accessory"
  // An accessory with no id it can name back to the server, or an id with
  // characters the server never issues, is not controllable and is dropped
  // rather than shown as a row that cannot act.
  if (!isSafeUniqueId(out.uniqueId)) return null
  return out
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
    status.accessories = (Array.isArray(parsed.accessories) ? parsed.accessories : [])
      .map(sanitizeAccessory)
      .filter(function(a) { return a !== null })
    var t = parsed.totals || {}
    status.totals = {
      count: Number(t.count || status.accessories.length),
      on: (t.on !== undefined && t.on !== null)
        ? Number(t.on)
        : status.accessories.filter(function(a) { return a.on }).length
    }
    return status
  } catch (e) {
    var broken = emptyStatus()
    broken.error = "Could not parse the Homebridge status"
    return broken
  }
}

// -------------------------------------------------------------- per accessory

function isOn(a) {
  return !!a && a.on === true
}

function brightnessText(a) {
  if (!a || !a.dimmable || a.brightness === null) return ""
  return String(clampBrightness(a.brightness)) + "%"
}

function stateText(a) {
  if (!a) return ""
  if (isOn(a)) {
    var b = brightnessText(a)
    return b !== "" ? b : "On"
  }
  return "Off"
}

// The id is spliced into a URL path by the set helper, which checks it again.
// This copy lets the panel refuse before it acts, rather than asking the helper
// to reject something the panel should never have sent.
function isSafeUniqueId(id) {
  return /^[A-Za-z0-9]+$/.test(String(id || ""))
}

// -------------------------------------------------------------- whole server

function summaryText(status) {
  if (!status || !status.configured) return "Not signed in"
  var count = status.totals ? status.totals.count : 0
  if (count === 0) return "No controllable devices"
  var on = status.totals ? status.totals.on : 0
  if (on === 0) return "All off · " + count + (count === 1 ? " device" : " devices")
  return on + " on · " + count + (count === 1 ? " device" : " devices")
}

// The count worth carrying in the bar is the number that are on; a home at rest
// says nothing rather than showing a zero.
function barCountText(status, everLoaded) {
  if (!everLoaded || !status || !status.configured) return ""
  var on = status.totals ? Number(status.totals.on) : 0
  return on > 0 ? String(on) : ""
}

// A server that cannot be reached is critical: everything else on the panel is
// then unknown rather than fine. There is no in-between warning state here —
// an accessory is either reported or it is not.
function health(status) {
  if (!status || !status.configured) {
    return { level: "ok", headline: "Not signed in", issues: [] }
  }
  if (!status.ok || status.error) {
    var message = status.error || "Homebridge is not answering"
    return { level: "critical", headline: message, issues: [{ level: "critical", text: message }] }
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
