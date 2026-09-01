// Model.js is plain data logic, so it can be exercised without a bar, a server,
// or a running shell: node test/model-test.js
//
// The cases here are the ones where a plausible-looking implementation is wrong
// rather than merely untested — a closed door read as open, a light Homebridge
// reports as `1` read as off, a house claimed secure the instant the button was
// pressed, a mode offered that the alarm does not have.

const fs = require('fs')
const path = require('path')
const vm = require('vm')

const Model = {}
vm.createContext(Model)
vm.runInContext(fs.readFileSync(path.join(__dirname, '..', 'Model.js'), 'utf8'), Model)

let failures = 0

function assert(condition, name) {
  if (condition) {
    console.log('ok - ' + name)
  } else {
    console.log('not ok - ' + name)
    failures += 1
  }
}

function assertEqual(actual, expected, name) {
  assert(actual === expected, name + (actual === expected ? '' : ' (got ' + JSON.stringify(actual) + ')'))
}

// The shape the status helper emits.
function statusDoc(accessories, extra) {
  return JSON.stringify(Object.assign({
    ok: true, error: '', configured: true, configPath: '/tmp/c.json',
    now: 1730000000, serverUrl: 'http://homebridge.local:8581',
    accessories: accessories
  }, extra || {}))
}
function parse(accessories, extra) { return Model.parseStatus(statusDoc(accessories, extra)) }

const lamp = { uniqueId: 'a1b2c3', kind: 'switch', name: 'Desk Lamp', type: 'Lightbulb', on: true, dimmable: true, brightness: 40 }
const outlet = { uniqueId: 'ff00ff', kind: 'switch', name: 'Kettle', type: 'Outlet', on: false, dimmable: false, brightness: null }
const alarm = { uniqueId: 'sec001', kind: 'security', name: 'Alarm', type: 'Security System', securityCurrent: 3, securityTarget: 3, securityModes: [0, 1, 3] }
const frontDoor = { uniqueId: 'con001', kind: 'sensor', name: 'Front Door', type: 'Contact Sensor', sensor: 'ContactSensorState', sensorValue: 0, lowBattery: true }
const garage = { uniqueId: 'con002', kind: 'sensor', name: 'Garage', type: 'Contact Sensor', sensor: 'ContactSensorState', sensorValue: 1 }
const hallway = { uniqueId: 'mot001', kind: 'sensor', name: 'Hallway', type: 'Motion Sensor', sensor: 'MotionDetected', sensorValue: true }
const kitchen = { uniqueId: 'smo001', kind: 'sensor', name: 'Kitchen', type: 'Smoke Sensor', sensor: 'SmokeDetected', sensorValue: 0 }
const nursery = { uniqueId: 'tmp001', kind: 'sensor', name: 'Nursery', type: 'Temperature Sensor', sensor: 'CurrentTemperature', sensorValue: 21.5 }

// ---- the reading a naive implementation gets backwards

// HomeKit's ContactSensorState is 0 for CONTACT_DETECTED, which is a door that
// is SHUT. Read the number as a truthiness and every closed door in the house
// reports itself open.
assertEqual(Model.stateText(frontDoor), 'Closed', 'a contact sensor reading 0 is a closed door')
assertEqual(Model.stateText(garage), 'Open', 'and 1 is an open one')
assertEqual(parse([frontDoor, garage]).totals.open, 1, 'only the open one is counted open')

// The other direction: an On characteristic plenty of plugins report as 0 or 1.
assertEqual(parse([{ uniqueId: 'aa', kind: 'switch', on: 1 }]).accessories[0].on, true,
  'a light Homebridge reports as 1 is on')
assertEqual(parse([{ uniqueId: 'aa', kind: 'switch', on: 0 }]).accessories[0].on, false,
  'and 0 is off')
assertEqual(Model.stateText(hallway), 'Motion', 'a motion sensor reading true is motion')
assertEqual(Model.stateText({ kind: 'sensor', sensor: 'MotionDetected', sensorValue: false }), 'Clear',
  'and false is clear')

// ---- a house is not secure the moment you press the button

// Arming an away mode gives you a minute to leave. Target and current disagree
// for the whole of it, and claiming the house is armed in that window is the
// one lie this panel must not tell.
const arming = Object.assign({}, alarm, { securityCurrent: 3, securityTarget: 1 })
assertEqual(Model.stateText(arming), 'Arming…', 'a system on its way to armed says so')
assertEqual(Model.stateText(Object.assign({}, alarm, { securityCurrent: 1, securityTarget: 3 })), 'Disarming…',
  'and on its way to off')
assertEqual(Model.stateText(alarm), 'Off', 'a settled system reads its actual state')
assertEqual(Model.stateText(Object.assign({}, alarm, { securityCurrent: 1, securityTarget: 1 })), 'Away',
  'once it has got there')
assertEqual(Model.securityChosen(arming), 1, 'the chip stays lit on the mode that was asked for')
assert(!Model.isArmed(alarm), 'an off system is not armed')
assert(Model.isArmed(Object.assign({}, alarm, { securityCurrent: 1 })), 'an away system is')
assert(Model.isArmed(Object.assign({}, alarm, { securityCurrent: 4 })), 'and one that is going off certainly is')

// A system going off has not been asked for anything — it is reporting.
const going = Object.assign({}, alarm, { securityCurrent: 4, securityTarget: 1 })
assert(!Model.securityInTransition(going), 'an alarm going off is not read as a transition')
assertEqual(Model.stateText(going), 'Alarm triggered', 'it says what it is')
assert(Model.isAlarming(going), 'and is alarming')

// ---- only the modes the system actually has

assertEqual(JSON.stringify(Model.securityModes(alarm)),
  JSON.stringify([{ value: 0, label: 'Home' }, { value: 1, label: 'Away' }, { value: 3, label: 'Off' }]),
  'a system declaring [0,1,3] is offered exactly those, in HomeKit order')
assertEqual(Model.securityModes(alarm).length, 3, 'so no Night button appears for a system without one')
assertEqual(Model.securityModes({ kind: 'security', securityModes: [] }).length, 4,
  'a system that declares nothing is offered all four rather than none')
assertEqual(Model.securityModes(null).length, 0,
  'but no accessory at all is no modes — a delegate built before its accessory is bound must not flash four chips')
assertEqual(Model.securityModes(lamp).length, 0, 'and a light has no modes to offer')
assertEqual(parse([Object.assign({}, alarm, { securityModes: [0, 1, 9, 'x', 3] })]).accessories[0].securityModes.length, 3,
  'a declared mode outside HomeKit is dropped at the parse boundary')

assert(Model.isSafeSecurityTarget(0), 'home is a mode')
assert(Model.isSafeSecurityTarget(3), 'so is off')
assert(!Model.isSafeSecurityTarget(4), 'alarm-triggered is a state, not something to ask for')
assert(!Model.isSafeSecurityTarget('1'), 'a string that looks like a mode is not one')
assert(!Model.isSafeSecurityTarget(null), 'and neither is nothing')

// ---- what raises an alarm, and what merely gets mentioned

const smoking = Object.assign({}, kitchen, { sensorValue: 1 })
assert(Model.sensorAlerts(smoking), 'smoke is an alert')
assert(Model.sensorAlerts({ kind: 'sensor', sensor: 'LeakDetected', sensorValue: 1 }), 'so is water')
assert(Model.sensorAlerts({ kind: 'sensor', sensor: 'CarbonMonoxideDetected', sensorValue: 1 }), 'and carbon monoxide')
assert(!Model.sensorAlerts(garage), 'an open door is not — houses have doors that open')
assert(!Model.sensorAlerts(hallway), 'nor is someone walking past a motion sensor')

assertEqual(Model.health(parse([kitchen, garage, hallway])).level, 'ok', 'a house going about its business is fine')
assertEqual(Model.health(parse([smoking])).level, 'critical', 'smoke is not')
assertEqual(Model.health(parse([smoking])).headline, 'Smoke detected in Kitchen', 'and it names the room')
assertEqual(Model.health(parse([going])).level, 'critical', 'an alarm going off is critical')
assertEqual(Model.health(parse([going])).headline, 'Alarm is going off', 'and leads with it')

// A low battery is true for weeks. An icon that has been amber since March is
// an icon nobody reads, so it goes in the summary and not in the level.
assertEqual(Model.health(parse([frontDoor])).level, 'ok', 'a low battery does not turn the bar red')
assert(Model.summaryText(parse([frontDoor])).indexOf('1 low battery') !== -1, 'but the summary says so')
assertEqual(Model.summaryText(parse([frontDoor, Object.assign({}, garage, { lowBattery: true })])).indexOf('2 low batteries') !== -1,
  true, 'and pluralises without inventing "batterys"')
assertEqual(JSON.stringify(Model.badges(frontDoor)), JSON.stringify(['battery low']), 'the row carries a badge for it')
assertEqual(JSON.stringify(Model.badges({ tampered: true, fault: true })), JSON.stringify(['tampered', 'fault']),
  'as it does for tampering and faults')
assertEqual(Model.badges(lamp).length, 0, 'a healthy accessory carries none')

// ---- what the bar carries

const quiet = parse([alarm, outlet, frontDoor])
assertEqual(Model.barText(quiet, true, true, true), '',
  'a disarmed house with nothing on says nothing in the bar')
const away = parse([Object.assign({}, alarm, { securityCurrent: 1, securityTarget: 1 }), outlet])
assertEqual(Model.barText(away, true, true, true), 'Away', 'an armed house is worth a word')
assertEqual(Model.barText(away, true, true, false), '', 'unless that has been switched off')
const awayAndLit = parse([Object.assign({}, alarm, { securityCurrent: 1, securityTarget: 1 }), lamp])
assertEqual(Model.barText(awayAndLit, true, true, true), 'Away 1', 'a light left on while away is worth knowing')
assertEqual(Model.barText(awayAndLit, true, false, true), 'Away', 'the count can be turned off on its own')
assertEqual(Model.barText(parse([lamp]), true, true, true), '1', 'a house with no alarm just counts what is on')
assertEqual(Model.barText(parse([going]), true, true, true), 'Alarm', 'an alarm going off displaces everything')
assertEqual(Model.barText(parse([going]), true, false, false), 'Alarm',
  'and shows even with both bar settings off, because that is not a preference')
assertEqual(Model.barText(parse([smoking, lamp]), true, true, true), 'Smoke', 'so does smoke')
assertEqual(Model.barText(parse([lamp]), false, true, true), '', 'nothing is claimed before the first read lands')
assertEqual(Model.barText(Model.parseStatus(JSON.stringify({ ok: true, configured: false })), true, true, true), '',
  'an unconfigured plugin claims nothing')

// ---- the summary

assertEqual(Model.summaryText(parse([alarm, frontDoor])), 'Off · 1 low battery',
  'the summary leads with the alarm and then what wants attention')
assertEqual(Model.summaryText(parse([alarm, garage, hallway])), 'Off · 1 open · motion',
  'an open door and someone moving both get a mention')
assertEqual(Model.summaryText(parse([alarm, outlet, kitchen])), 'Off · 3 devices',
  'an alarm at rest states where the house stands, so the summary still gives its size')
assertEqual(Model.summaryText(parse([outlet, kitchen])), 'All quiet · 2 devices',
  'and a house with no alarm and nothing to report says exactly that')
assertEqual(Model.summaryText(parse([outlet])), 'All quiet · 1 device', 'one device is singular')
assertEqual(Model.summaryText(parse([])), 'Nothing to show', 'an empty bridge says so')
assertEqual(Model.summaryText(Model.parseStatus(JSON.stringify({ ok: true, configured: false }))), 'Not signed in',
  'and a fresh install says that instead')
assertEqual(Model.health(Model.parseStatus(JSON.stringify({ ok: true, configured: false }))).level, 'ok',
  'not signed in is not a fault')

const down = Model.parseStatus(JSON.stringify({ ok: false, configured: true, error: 'cannot reach http://homebridge.local:8581' }))
assertEqual(Model.health(down).level, 'critical', 'a server that cannot be reached is critical')
assertEqual(Model.health(down).headline, 'cannot reach http://homebridge.local:8581', 'and the reason is the headline')
assertEqual(Model.health(parse([lamp], { error: 'Homebridge answered HTTP 502' })).level, 'critical',
  'an error alongside ok:true is still critical')

// ---- rows, order and the cursor

const mixed = parse([hallway, lamp, alarm, garage, outlet])
assertEqual(mixed.accessories.map(function(a) { return a.kind }).join(','),
  'security,switch,switch,sensor,sensor', 'security first, then what can be switched, then what can only be read')
assertEqual(mixed.accessories[3].name, 'Hallway', 'order inside a group is the server\'s, so rows do not move between polls')

const nav = Model.navItems(mixed.accessories)
assertEqual(nav.length, 3, 'only the rows that do something are reachable by the cursor')
assertEqual(nav.map(function(n) { return n.accessory.kind }).join(','), 'security,switch,switch',
  'a sensor is never landed on, because space would do nothing there')
assertEqual(nav[0].index, 0, 'and each nav entry points back at its row')
assert(Model.isActionable(lamp), 'a switch is actionable')
assert(Model.isActionable(alarm), 'so is a security system')
assert(!Model.isActionable(garage), 'a sensor is not')

// ---- an id the panel cannot send back

// A switch or an alarm with an unusable id is dropped: a row that cannot act is
// worse than no row. A sensor is only ever read, so it stays and is shown.
const badIds = parse([
  { uniqueId: 'a1/../b2', kind: 'switch', name: 'Hallway Light', on: true },
  { uniqueId: 'a1/../b3', kind: 'security', name: 'Alarm', securityCurrent: 1 },
  { uniqueId: 'a1/../b4', kind: 'sensor', name: 'Back Door', sensor: 'ContactSensorState', sensorValue: 1 }
])
assertEqual(badIds.accessories.length, 1, 'the two that would need to act are dropped')
assertEqual(badIds.accessories[0].kind, 'sensor', 'and the one that only reads is kept')
assertEqual(badIds.totals.on, 0, 'so the bar never promises a switch the panel cannot reach')
assertEqual(Model.navItems(badIds.accessories).length, 0, 'and the cursor has nowhere to land')

assert(Model.isSafeUniqueId('7f3a9c2e4b'), 'the hex id config-ui-x issues is accepted')
assert(!Model.isSafeUniqueId('a1/../../etc'), 'an id that would climb out of the endpoint is refused')
assert(!Model.isSafeUniqueId('a1?value=1'), 'an id that would start a query is refused')
assert(!Model.isSafeUniqueId('a1-b2'), 'and so is a shape config-ui-x never issues')
assert(!Model.isSafeUniqueId(''), 'an empty id is refused')

// ---- a confirmation is bound to the accessory it was asked about

// The panel asks about row 0 and the poll behind it replaces the list while the
// question is on screen.
const asked = parse([alarm, lamp])
const now = parse([lamp, alarm])
assertEqual(Model.accessoryById(now, asked.accessories[0].uniqueId).name, 'Alarm',
  'a reordered list still resolves to the accessory that was confirmed')
assertEqual(Model.accessoryById(now, 'gone'), null,
  'an accessory that has since disappeared resolves to nothing rather than to its neighbour')
assertEqual(Model.accessoryById(now, ''), null, 'an empty id matches nothing')
assertEqual(Model.accessoryById(null, 'sec001'), null, 'no status at all is not a crash')

assert(Model.securityConfirmMessage(alarm, 1).indexOf('Set Alarm to Away?') === 0,
  'the confirmation names the system and the mode')
assert(Model.securityConfirmMessage(alarm, 1).indexOf('It is Off now.') !== -1,
  'and says where it is coming from')
assert(Model.securityConfirmMessage(Object.assign({}, alarm, { securityCurrent: 1 }), 3).indexOf('until you set it again') !== -1,
  'disarming spells out what disarming means')
assertEqual(Model.securityConfirmMessage(null, 1), '', 'no subject is an empty question, not a crash')

// ---- measurements

assertEqual(Model.stateText(nursery), '21.5°C', 'a temperature reads in Celsius by default')
assertEqual(Model.stateText(nursery, 'fahrenheit'), '71°F', 'and in Fahrenheit when asked')
assertEqual(Model.stateText({ kind: 'sensor', sensor: 'CurrentRelativeHumidity', sensorValue: 43.6 }), '44%',
  'humidity is a whole percent')
assertEqual(Model.stateText({ kind: 'sensor', sensor: 'CurrentTemperature', sensorValue: null }), '',
  'a measurement with no value says nothing rather than NaN')
assert(!Model.sensorActive(nursery), 'a thermometer is never "active" — there is no resting state to differ from')
assert(Model.sensorActive(garage), 'an open door is')

// ---- switches keep working

assertEqual(Model.stateText(lamp), '40%', 'a dimmable light that is on shows its brightness')
assertEqual(Model.stateText({ kind: 'switch', on: true, dimmable: false }), 'On', 'a switch that is on just says On')
assertEqual(Model.stateText({ kind: 'switch', on: true, dimmable: true, brightness: null }), 'On',
  'a dimmable light that reports no brightness says On rather than null%')
assertEqual(Model.stateText(outlet), 'Off', 'anything off says Off')
assertEqual(Model.stateText(null), '', 'no accessory at all is not a crash')
assertEqual(Model.clampBrightness(255), 100, 'an out-of-range brightness is clamped down')
assertEqual(Model.clampBrightness(-5), 0, 'and clamped up')
assertEqual(Model.clampBrightness(33.6), 34, 'a fractional brightness rounds to a whole percent')
assertEqual(Model.clampBrightness('nonsense'), 0, 'a brightness that is not a number is 0, not NaN')

// ---- names come off a server and reach a Text

// QML's Text defaults to AutoText, which renders anything markup-shaped as rich
// text and fetches what it references. Whoever can name a device can put this
// on the screen.
const nasty = parse([{ uniqueId: 'aa', kind: 'switch', name: '<img src="http://x/p.png">Lamp', on: true }])
assertEqual(nasty.accessories[0].name.indexOf('<'), -1, 'a name shaped like markup loses its angle brackets')
assertEqual(nasty.accessories[0].name.indexOf('>'), -1, 'both of them')
assertEqual(parse([{ uniqueId: 'aa', kind: 'switch', name: 'Hall\tLamp' }]).accessories[0].name, 'Hall Lamp',
  'control characters become a space rather than reaching the screen')
assertEqual(parse([{ uniqueId: 'aa', kind: 'switch', name: '   ', type: 'Outlet' }]).accessories[0].name, 'Outlet',
  'a blank name falls back to what the thing is')
assertEqual(parse([{ uniqueId: 'aa', kind: 'switch' }]).accessories[0].name, 'Accessory',
  'and a nameless, typeless accessory is still a row that reads as something')
const long = parse([{ uniqueId: 'aa', kind: 'switch', name: 'L'.repeat(400) }]).accessories[0].name
assertEqual(long.length, 120, 'a name long enough to push the panel off screen is truncated')
assertEqual(long.slice(-1), '…', 'and says it was')
assertEqual(Model.plainForShared('Kitchen & <b>Hall</b>'), 'Kitchen and bHall/b',
  'text bound for a shared component is made inert')

// ---- the one string that reaches a shell

assertEqual(Model.shellQuote('/home/ian/.config/omarchy-homebridge/config.json'),
  "'/home/ian/.config/omarchy-homebridge/config.json'", 'an ordinary path is quoted whole')
assertEqual(Model.shellQuote("/tmp/it's here/c.json"), "'/tmp/it'\\''s here/c.json'",
  'a path containing a quote cannot close the quoting around it')
assertEqual(Model.shellQuote('/tmp/x; rm -rf ~'), "'/tmp/x; rm -rf ~'",
  'and a path carrying another command stays one argument')

// ---- parsing

const parsed = parse([lamp, alarm, garage])
assertEqual(parsed.ok, true, 'a good document parses')
assertEqual(parsed.accessories.length, 3, 'accessories survive parsing')
assertEqual(parsed.serverUrl, 'http://homebridge.local:8581', 'as does the server it read')
assertEqual(parse([{ uniqueId: 'aa', name: 'Mystery', on: true }]).accessories.length, 0,
  'an accessory with no kind is not a row: the helper classifies, the panel does not guess')
assertEqual(parse([{ uniqueId: 'aa', kind: 'camera', name: 'Driveway' }]).accessories.length, 0,
  'and neither is a kind this panel does not know')
assertEqual(Model.parseStatus('not json').error, 'Could not parse the Homebridge status', 'garbage is reported, not thrown')
assertEqual(Model.parseStatus('not json').ok, false, 'and is not mistaken for a healthy read')
assertEqual(Model.parseStatus('').accessories.length, 0, 'an empty read is an empty status')
assertEqual(Model.parseStatus('[1,2,3]').accessories.length, 0, 'a document of the wrong shape is empty, not partial')
assertEqual(Model.parseStatus(statusDoc('not an array')).accessories.length, 0,
  'accessories that are not a list are no accessories')

console.log(failures === 0 ? '\nall passed' : '\n' + failures + ' failed')
process.exit(failures === 0 ? 0 : 1)
