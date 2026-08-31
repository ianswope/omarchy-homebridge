import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Reads Homebridge accessory state on a timer, and carries out the two things
// the panel can ask for: toggling an accessory on or off, and setting a
// dimmable light's brightness. Every poll is one read-only request; the only
// things that change a device are setOn and setBrightness, each dispatched
// explicitly from the panel.
Item {
  id: root

  property var settings: ({})

  property var status: Model.emptyStatus()
  property var healthInfo: ({ level: "ok", headline: "Reading Homebridge…", issues: [] })
  property bool everLoaded: false
  property string lastError: ""
  property string actionStatus: ""

  // Optimistic overrides, keyed by uniqueId, so a toggle shows on screen the
  // instant it is pressed rather than a second later when the next poll lands.
  // Each entry carries an `until`; a poll that agrees clears it, and one that
  // never comes lets it expire so the server's truth wins in the end.
  property var pending: ({})
  property int pendingRev: 0
  readonly property int pendingTtlMs: 6000

  readonly property string level: healthInfo.level
  readonly property string headline: healthInfo.headline
  readonly property var issues: healthInfo.issues
  readonly property bool configured: status.configured
  readonly property string configPath: status.configPath

  // The accessory list the panel renders: the polled truth with any unexpired
  // optimistic override laid over the top.
  readonly property var accessories: {
    pendingRev // re-evaluate when an override changes
    var list = (status && status.accessories) || []
    var now = Date.now()
    return list.map(function(a) { return applyPending(a, now) })
  }

  readonly property string summary: Model.summaryText(status)
  readonly property string barCountText: Model.barCountText(status, everLoaded)

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 15, 5, 300)
  readonly property bool showCount: setting("showCount", true) === true

  readonly property string pluginDir: String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string statusHelper: pluginDir + "/bin/omarchy-homebridge-status"
  readonly property string setHelper: pluginDir + "/bin/omarchy-homebridge-set"
  readonly property string loginHelper: pluginDir + "/bin/omarchy-homebridge-login"
  readonly property string configOverride: String(setting("configPath", ""))
  readonly property string configFile: configOverride !== ""
    ? configOverride
    : (Quickshell.env("HOME") + "/.config/omarchy-homebridge/config.json")

  // The boundary where bytes become QML objects; the helper already refuses an
  // oversized reply, but this should not depend on the helper being the only
  // thing that ever writes to that pipe.
  readonly property int maxOutputChars: 8388608

  // A poll that fails is not news — the bar starts before the network is up, and
  // a wifi blip fails a poll or two. A server that is genuinely gone keeps
  // failing; after this many in a row the panel says so, and one success resets.
  readonly property int failuresBeforeFault: Math.max(3, Math.ceil(45 / Math.max(1, refreshIntervalSec)))
  property int consecutiveFailures: 0

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // ------------------------------------------------------------- optimism

  function applyPending(a, now) {
    var p = pending[a.uniqueId]
    if (!p || p.until < now) return a
    var out = {
      uniqueId: a.uniqueId, name: a.name, type: a.type,
      on: a.on, dimmable: a.dimmable, brightness: a.brightness
    }
    if (p.on !== undefined) out.on = p.on
    if (p.brightness !== undefined) { out.brightness = p.brightness; out.dimmable = true }
    return out
  }

  function setPending(id, patch) {
    var entry = pending[id] || {}
    for (var k in patch) entry[k] = patch[k]
    entry.until = Date.now() + pendingTtlMs
    pending[id] = entry
    pendingRev += 1
  }

  // Drop overrides the latest poll already agrees with, and any that have
  // outlived their window. What remains is only the actions still in flight.
  function reconcilePending(parsed) {
    var now = Date.now()
    var byId = {}
    var list = (parsed && parsed.accessories) || []
    for (var i = 0; i < list.length; i++) byId[list[i].uniqueId] = list[i]
    var changed = false
    for (var id in pending) {
      var p = pending[id]
      var real = byId[id]
      var settled = p.until < now
      if (!settled && real) {
        var onMatches = (p.on === undefined) || (real.on === p.on)
        var briMatches = (p.brightness === undefined) || (real.brightness === p.brightness)
        if (onMatches && briMatches) settled = true
      }
      if (settled) { delete pending[id]; changed = true }
    }
    if (changed) pendingRev += 1
  }

  // ------------------------------------------------------------- polling

  function refresh() {
    if (statusProcess.running) return
    statusProcess.command = ["bash", statusHelper, configFile]
    statusProcess.running = true
  }

  function applyStatus(raw) {
    var parsed = Model.parseStatus(raw)
    var failed = parsed.configured && !parsed.ok

    if (failed) consecutiveFailures += 1
    else consecutiveFailures = 0

    // Hold the last good picture while a fault is still inside its grace period:
    // blanking every light because one poll timed out is worse than a few
    // seconds stale.
    if (failed && consecutiveFailures < failuresBeforeFault && everLoaded) return

    status = parsed
    reconcilePending(parsed)
    healthInfo = Model.health(parsed)
    everLoaded = true
    lastError = parsed.ok ? "" : (parsed.error || "")
  }

  function note(text) {
    actionStatus = Model.sanitize(text)
    actionStatusTimer.restart()
  }

  // ------------------------------------------------------------- actions

  // A single worker drains a queue, so toggling three lights in quick
  // succession runs three requests in order rather than dropping two.
  property var actionQueue: []

  function enqueue(cmd, noteText) {
    actionQueue.push({ cmd: cmd, note: noteText })
    drain()
  }

  function drain() {
    if (actionProcess.running || actionQueue.length === 0) return
    var next = actionQueue.shift()
    if (next.note) note(next.note)
    actionProcess.command = next.cmd
    actionProcess.running = true
  }

  function setOn(accessory, value) {
    if (!accessory) return
    if (!Model.isSafeUniqueId(accessory.uniqueId)) { note("That accessory has an id Homebridge will not accept back"); return }
    var on = value === true
    setPending(accessory.uniqueId, { on: on })
    enqueue(["bash", setHelper, configFile, String(accessory.uniqueId), "On", on ? "true" : "false"],
            (on ? "Turning on " : "Turning off ") + accessory.name)
    settleTimer.restart()
  }

  function toggle(accessory) {
    if (!accessory) return
    setOn(accessory, !Model.isOn(accessory))
  }

  function setBrightness(accessory, value) {
    if (!accessory) return
    if (!Model.isSafeUniqueId(accessory.uniqueId)) { note("That accessory has an id Homebridge will not accept back"); return }
    var b = Model.clampBrightness(value)
    var patch = { brightness: b }
    if (b > 0) patch.on = true
    setPending(accessory.uniqueId, patch)
    enqueue(["bash", setHelper, configFile, String(accessory.uniqueId), "Brightness", String(b)],
            "Setting " + accessory.name + " to " + b + "%")
    settleTimer.restart()
  }

  // Signing in writes a credential and asks for a password, so it runs in a
  // visible terminal rather than silently behind the panel.
  function signIn() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                             "bash " + Model.shellQuote(loginHelper) + " " + Model.shellQuote(configFile)])
    note("Signing in to Homebridge in a terminal…")
    settleTimer.restart()
  }

  function openConfig() {
    if (configFile.charAt(0) !== "/") { note("Config path must be absolute: " + configFile); return }
    Quickshell.execDetached(["omarchy-launch-config-editor", configFile])
    note("Opened " + configFile)
  }

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // A toggled device takes a moment to report its new state, so re-read a few
  // times after an action rather than waiting for the next ordinary tick.
  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 800
    repeat: true
    running: false
    onRunningChanged: if (running) ticks = 0
    onTriggered: {
      ticks += 1
      root.refresh()
      if (ticks >= 4) running = false
    }
  }

  Timer {
    id: actionStatusTimer
    interval: 3500
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(statusStdout.text || "")
      if (out.length > root.maxOutputChars) {
        root.everLoaded = true
        root.lastError = "Status output was too large to read"
        root.healthInfo = { level: "critical", headline: root.lastError,
                            issues: [{ level: "critical", text: root.lastError }] }
        return
      }
      if (out.trim() !== "") { root.applyStatus(out); return }
      root.everLoaded = true
      root.lastError = Model.sanitize(statusStderr.text) || ("Could not run " + root.statusHelper)
      root.healthInfo = { level: "critical", headline: root.lastError,
                          issues: [{ level: "critical", text: root.lastError }] }
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { id: actionStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var parsed = {}
      var raw = String(actionStdout.text || "{}")
      if (raw.length > root.maxOutputChars) raw = "{}"
      try { parsed = JSON.parse(raw) } catch (e) { parsed = {} }
      if (!parsed || parsed.ok !== true) root.note(Model.sanitize(parsed.error) || "That did not go through")
      root.drain()
      root.refresh()
    }
  }
}
