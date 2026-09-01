import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus popup for a Homebridge server. One row per accessory this
// plugin has something to say about, in three kinds: the security system, the
// things that can be switched, and the things that can only be read.
//
// The two kinds differ in how much ceremony they get, deliberately. A lamp is
// toggled the instant it is clicked — it is your lamp, and the worst case is
// standing up to press it again. A security system is asked about first,
// because the worst case is a house left unlocked.
Panel {
  id: root
  moduleName: "ianswope.homebridge"
  ipcTarget: "ianswope.homebridge"
  manageIpc: false

  // selectedIndex walks the *actionable* rows, not every row. A cursor that
  // could land on a motion sensor would be a cursor that mostly does nothing.
  property int selectedIndex: 0
  property bool cursorActive: false
  // Which mode chip is lit on the selected security row. -1 means "not decided
  // yet", so it lands on whatever the system is currently set to.
  property int securityModeIndex: -1

  // What the confirmation is about, captured when it opens rather than looked up
  // again when it closes. The poll behind this panel replaces the accessory list
  // every few seconds, so an index does not survive the question being asked —
  // and the subject is held as the object that was on screen, so the wording
  // cannot change under someone reading it.
  property string confirmId: ""
  property int confirmTarget: -1
  property var confirmSubject: null
  readonly property bool confirming: confirmId !== ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color notice: Qt.lighter(urgent, 1.35)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var rows: hb.accessories
  readonly property var items: Model.navItems(hb.accessories)
  readonly property bool countVisible: hb.barText !== ""

  // Where the read-only half of the list starts, so it can be introduced with a
  // heading rather than running on from the things you can press.
  readonly property int firstSensorIndex: {
    var list = rows || []
    for (var i = 0; i < list.length; i++) {
      if (list[i].kind === "sensor") return i
    }
    return -1
  }

  // Only a genuine fault recolours the bar icon: an unreachable server, a system
  // going off, smoke or water. An accessory being off, a door being open, a
  // sensor wanting a battery — those are the house being a house.
  readonly property color barIconColor: hb.level === "critical" ? urgent : barForeground
  readonly property color heroColor: hb.level === "critical" ? urgent : foreground

  // Composed through plainForShared because ConfirmDialog's Text is the shell's,
  // not this plugin's, and defaults to AutoText.
  readonly property string confirmMessage:
    confirmSubject ? Model.securityConfirmMessage(confirmSubject, confirmTarget) : ""
  readonly property string confirmButtonText:
    confirmTarget === 3 ? "Disarm" : Model.securityLabel(confirmTarget)

  // ------------------------------------------------------------- navigation

  function selectedNav() {
    if (items.length === 0) return null
    return items[Math.max(0, Math.min(selectedIndex, items.length - 1))]
  }

  function selectedAccessory() {
    var nav = selectedNav()
    return nav ? nav.accessory : null
  }

  function rowHasCursor(rowIndex) {
    if (!cursorActive) return false
    var nav = selectedNav()
    return !!nav && nav.index === rowIndex
  }

  function ensureCursor() {
    if (items.length === 0) { selectedIndex = 0; return }
    selectedIndex = Math.max(0, Math.min(selectedIndex, items.length - 1))
  }

  function selectRow(rowIndex) {
    for (var i = 0; i < items.length; i++) {
      if (items[i].index === rowIndex) {
        if (selectedIndex !== i) securityModeIndex = -1
        cursorActive = true
        selectedIndex = i
        return
      }
    }
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy !== 0) {
      selectedIndex = Math.max(0, Math.min(items.length - 1, selectedIndex + dy))
      securityModeIndex = -1
      scrollCursorIntoView()
      return
    }
    if (dx === 0) return
    // Sideways means different things to the two kinds of row, and the row under
    // the cursor decides which.
    var a = selectedAccessory()
    if (!a) return
    if (a.kind === "security") moveSecurityMode(dx > 0 ? 1 : -1)
    else nudgeSelectedBrightness(dx > 0 ? 10 : -10)
  }

  function ensureSecurityModeIndex() {
    var a = selectedAccessory()
    if (!a || a.kind !== "security") { securityModeIndex = -1; return }
    if (securityModeIndex >= 0) return
    var modes = Model.securityModes(a)
    var chosen = Model.securityChosen(a)
    for (var i = 0; i < modes.length; i++) {
      if (modes[i].value === chosen) { securityModeIndex = i; return }
    }
    securityModeIndex = 0
  }

  function moveSecurityMode(step) {
    var a = selectedAccessory()
    if (!a || a.kind !== "security") return
    var modes = Model.securityModes(a)
    if (modes.length === 0) return
    ensureSecurityModeIndex()
    securityModeIndex = Math.max(0, Math.min(modes.length - 1, securityModeIndex + step))
  }

  function activateSelected() {
    var a = selectedAccessory()
    if (!a) return
    if (a.kind === "security") {
      var modes = Model.securityModes(a)
      ensureSecurityModeIndex()
      var mode = modes[securityModeIndex]
      if (mode) askSecurity(a, mode.value)
      return
    }
    hb.toggle(a)
  }

  function nudgeSelectedBrightness(delta) {
    var a = selectedAccessory()
    if (!a || !a.dimmable) return
    var base = (a.brightness === null || a.brightness === undefined) ? (a.on ? 100 : 0) : a.brightness
    hb.setBrightness(a, Model.clampBrightness(base + delta))
  }

  // ----------------------------------------------------------- confirmation

  function askSecurity(accessory, target) {
    if (!accessory || accessory.kind !== "security") return
    if (!Model.isSafeUniqueId(accessory.uniqueId)) {
      hb.note("That accessory has an id Homebridge will not accept back")
      return
    }
    if (!Model.isSafeSecurityTarget(target)) return
    if (Model.securityChosen(accessory) === target) {
      hb.note(accessory.name + " is already " + Model.securityLabel(target))
      return
    }
    confirmId = String(accessory.uniqueId)
    confirmTarget = target
    confirmSubject = accessory
    // Cancel first: the other button changes whether a house is locked.
    confirmDialog.selectedIndex = 0
  }

  function cancelConfirm() {
    confirmId = ""
    confirmTarget = -1
    confirmSubject = null
  }

  function acceptConfirm() {
    var id = confirmId
    var target = confirmTarget
    cancelConfirm()
    if (!Model.isSafeSecurityTarget(target)) return
    // Resolved against the list as it stands now, by the id the question was
    // asked about. If that accessory has gone in the meantime there is nothing
    // to set; the one outcome that must not happen is arming or disarming
    // whatever has since moved into its place.
    var live = Model.accessoryById(hb.status, id)
    if (!live) { hb.note("That accessory is no longer there"); return }
    hb.setSecurity(live, target)
  }

  // ------------------------------------------------------------------ rows

  property var rowRegistry: ({})
  function registerRow(index, item) { rowRegistry[index] = item }

  function scrollCursorIntoView() {
    var nav = selectedNav()
    if (!nav) return
    var target = rowRegistry[nav.index]
    if (!panelFlick || !target) return
    Qt.callLater(function() {
      if (!target) return
      var margin = Style.space(6)
      var point = target.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + target.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  // Presentation of state, per kind. A filled dot means "this one is doing
  // something": a light is on, the house is armed, a door is open.
  function rowActive(a) {
    if (!a) return false
    if (a.kind === "security") return Model.isArmed(a)
    if (a.kind === "sensor") return Model.sensorActive(a)
    return Model.isOn(a)
  }

  function rowUrgent(a) {
    return Model.isAlarming(a) || Model.sensorAlerts(a)
  }

  // Without these the bar allocates zero width, the widget never appears, and
  // nothing is logged — which looks exactly like a plugin that failed to load.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    securityModeIndex = -1
    cancelConfirm()
    if (panelFlick) panelFlick.contentY = 0
    hb.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Service {
    id: hb
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { hb.refresh(); return "ok" }
    function status(): string { return hb.headline }
    function level(): string { return hb.level }
    function on(): string { return String(hb.status.totals ? hb.status.totals.on : 0) }
    // Read-only on purpose. Arming from a script would skip the confirmation
    // that is the whole reason this plugin is allowed near a security system.
    function security(): string {
      var s = Model.securitySystem(hb.status)
      return s ? Model.stateText(s) : "none"
    }
  }

  TextMetrics {
    id: countMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.bar.iconFont
    text: hb.barText
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.iconSlot + (root.countVisible ? countMetrics.width + Style.space(3) : 0)
    iconComponent: Component {
      Item {
        Row {
          anchors.centerIn: parent
          spacing: Style.space(3)

          HomeIcon {
            anchors.verticalCenter: parent.verticalCenter
            iconSize: Style.space(12)
            color: root.barIconColor
            doorColor: root.bar ? root.bar.background : Color.background
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.countVisible
            text: hb.barText
            textFormat: Text.PlainText
            color: root.barIconColor
            font.family: root.fontFamily
            font.pixelSize: Style.bar.iconFont
            renderType: Text.NativeRendering
          }
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) hb.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(
      headerColumn.implicitHeight + column.implicitHeight + footerColumn.implicitHeight + Style.space(34),
      Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (root.confirming) return
        if (!root.cursorActive) { root.cursorActive = true; root.ensureSecurityModeIndex(); return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: {
        if (root.confirming) return
        root.cursorActive = true
        root.activateSelected()
      }
      onCloseRequested: {
        if (root.confirming) { root.cancelConfirm(); return }
        root.close()
      }
      onTabRequested: function(direction) { if (!root.confirming) root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.confirming) return
        if (t === "r") hb.refresh()
        else if (t === "t" || t === " ") { root.cursorActive = true; root.activateSelected() }
        else if (t === "l") hb.signIn()
        else if (t === "e") hb.openConfig()
        else if (t === "-" || t === "_" || t === "[") root.moveCursor(-1, 0)
        else if (t === "=" || t === "+" || t === "]") root.moveCursor(1, 0)
      }

      Column {
        id: headerColumn
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(10)

        PanelHero {
          id: hero
          width: parent.width
          title: "Homebridge"
          meta: Model.plainForShared(hb.headline)
          foreground: root.heroColor
          fontFamily: root.fontFamily
          iconComponent: Component {
            HomeIcon {
              iconSize: Style.font.display
              color: root.heroColor
              doorColor: root.bar ? root.bar.background : Color.background
            }
          }
        }

        Text {
          visible: hb.actionStatus !== ""
          width: parent.width
          text: hb.actionStatus
          textFormat: Text.PlainText
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }

      Flickable {
        id: panelFlick
        anchors.top: headerColumn.bottom
        anchors.topMargin: Style.space(12)
        anchors.bottom: footerColumn.top
        anchors.bottomMargin: Style.space(10)
        anchors.left: parent.left
        anchors.right: parent.right
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(4)

          Text {
            visible: !hb.configured && hb.everLoaded
            width: parent.width
            text: "Not signed in yet. Press l to sign in — a terminal opens and asks "
                  + "for your Homebridge URL, username and password. Use a dedicated "
                  + "non-admin Homebridge user if you can."
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: hb.configured && hb.everLoaded && (root.rows || []).length === 0 && hb.level !== "critical"
            width: parent.width
            text: "Nothing to show. This lists what Homebridge bridges that can be "
                  + "switched (lights, switches, outlets, fans), a security system, "
                  + "and sensors worth reading — contact, motion, smoke, leak."
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.rows

            Column {
              id: rowWrapper
              required property var modelData
              required property int index
              width: column.width
              spacing: Style.space(4)

              // The read-only half gets introduced, so it is clear at a glance
              // why nothing below here responds to a click.
              PanelSeparator {
                visible: rowWrapper.index === root.firstSensorIndex && rowWrapper.index > 0
                width: parent.width
                foreground: root.foreground
              }

              PanelSectionHeader {
                visible: rowWrapper.index === root.firstSensorIndex
                text: "SENSORS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              AccessoryRow {
                width: parent.width
                accessory: rowWrapper.modelData
                accessoryIndex: rowWrapper.index
              }
            }
          }
        }
      }

      Column {
        id: footerColumn
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.space(4)

        PanelSeparator { foreground: root.foreground }

        Text {
          width: parent.width
          text: "space toggle or set · ←/→ mode and brightness · r refresh · l sign in · e edit config"
          textFormat: Text.PlainText
          color: Qt.darker(root.dim, 1.15)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        z: 10
        opened: root.confirming
        focus: root.confirming
        message: root.confirmMessage
        confirmText: root.confirmButtonText
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.cancelConfirm()
        onConfirmed: root.acceptConfirm()
        Keys.onPressed: function(event) {
          if (confirmDialog.handleKey(event)) event.accepted = true
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  component AccessoryRow: CursorSurface {
    id: accessoryRow
    property var accessory: null
    property int accessoryIndex: -1

    readonly property string kind: accessory ? String(accessory.kind) : ""
    readonly property bool actionable: Model.isActionable(accessory)
    readonly property bool active: root.rowActive(accessory)
    readonly property bool alarming: root.rowUrgent(accessory)
    readonly property bool selected: root.rowHasCursor(accessoryIndex)
    readonly property var badgeList: Model.badges(accessory)

    readonly property string subtitle: {
      var parts = []
      if (accessory && accessory.type) parts.push(accessory.type)
      for (var i = 0; i < badgeList.length; i++) parts.push(badgeList[i])
      return parts.join(" · ")
    }

    // A sensor row never lights up under the cursor, because the cursor never
    // lands on one.
    hasCursor: accessoryRow.selected
    foreground: root.foreground
    implicitHeight: rowContent.implicitHeight + Style.space(14)

    onAccessoryIndexChanged: if (accessoryIndex >= 0) root.registerRow(accessoryIndex, accessoryRow)

    Column {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(6)

      // Name + state. For a switch this whole region toggles; for a security
      // system it only selects, because the modes below are the action; for a
      // sensor it does nothing at all.
      Item {
        width: parent.width
        implicitHeight: Math.max(nameCol.implicitHeight, stateText.implicitHeight)

        MouseArea {
          anchors.fill: parent
          enabled: accessoryRow.actionable
          hoverEnabled: true
          cursorShape: accessoryRow.kind === "switch" ? Qt.PointingHandCursor : Qt.ArrowCursor
          acceptedButtons: Qt.LeftButton
          onEntered: root.selectRow(accessoryRow.accessoryIndex)
          onClicked: if (accessoryRow.kind === "switch") hb.toggle(accessoryRow.accessory)
        }

        Row {
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.space(9)

          // State at a glance.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(8)
            height: Style.space(8)
            radius: width / 2
            color: accessoryRow.alarming ? root.urgent
                 : accessoryRow.active ? root.foreground
                 : "transparent"
            border.width: accessoryRow.active || accessoryRow.alarming ? 0 : Math.max(1, Style.space(1))
            border.color: root.dim
          }

          Column {
            id: nameCol
            width: parent.width - Style.space(8) - Style.space(9) - stateText.width - Style.space(9)
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: accessoryRow.accessory ? accessoryRow.accessory.name : ""
              textFormat: Text.PlainText
              color: accessoryRow.active || accessoryRow.alarming
                ? root.foreground : Qt.darker(root.foreground, 1.2)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              visible: text !== ""
              width: parent.width
              text: accessoryRow.subtitle
              textFormat: Text.PlainText
              // A sensor asking for a battery is the one thing on this panel a
              // person would want to be told without having to look for it.
              color: accessoryRow.badgeList.length > 0 ? root.notice : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Text {
            id: stateText
            anchors.verticalCenter: parent.verticalCenter
            text: Model.stateText(accessoryRow.accessory, hb.temperatureUnit)
            textFormat: Text.PlainText
            color: accessoryRow.alarming ? root.urgent
                 : accessoryRow.active ? root.foreground
                 : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }

      // The security system's modes, and only the ones it says it has. Pressing
      // one asks first — see askSecurity.
      ButtonGroup {
        id: modeGroup
        visible: accessoryRow.kind === "security" && options.length > 0
        options: {
          var modes = Model.securityModes(accessoryRow.accessory)
          var out = []
          for (var i = 0; i < modes.length; i++) {
            out.push({ value: String(modes[i].value), label: modes[i].label })
          }
          return out
        }
        value: String(Model.securityChosen(accessoryRow.accessory))
        // The panel owns the keyboard; this group is driven by cursorIndex and
        // never given Tab focus of its own.
        focusable: false
        cursorIndex: accessoryRow.selected ? root.securityModeIndex : -1
        foreground: root.foreground
        background: root.bar ? root.bar.background : Color.background
        fontFamily: root.fontFamily
        fontSize: Style.font.bodySmall
        onChanged: function(value) {
          root.selectRow(accessoryRow.accessoryIndex)
          root.askSecurity(accessoryRow.accessory, parseInt(value, 10))
        }
        onHovered: function(index, isHovered) {
          if (!isHovered) return
          root.selectRow(accessoryRow.accessoryIndex)
          root.securityModeIndex = index
        }
      }

      // Brightness rail, only for dimmable lights. Its own MouseArea, so
      // dragging it never reads as a toggle. The value is committed on release
      // (and on a click) rather than streamed, so a drag is one request.
      Item {
        visible: accessoryRow.kind === "switch" && accessoryRow.accessory
                 && accessoryRow.accessory.dimmable === true
        width: parent.width
        height: Style.space(14)

        property int liveValue: {
          if (dragArea.dragging) return dragArea.pendingValue
          var b = accessoryRow.accessory ? accessoryRow.accessory.brightness : null
          return (b === null || b === undefined) ? (accessoryRow.active ? 100 : 0) : b
        }

        Rectangle {
          id: rail
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width
          height: Style.space(4)
          radius: height / 2
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

          Rectangle {
            width: parent.width * Math.max(0, Math.min(100, parent.parent.liveValue)) / 100
            height: parent.height
            radius: height / 2
            color: accessoryRow.active ? root.foreground : root.dim
            opacity: 0.85
          }
        }

        MouseArea {
          id: dragArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          preventStealing: true
          property bool dragging: false
          property int pendingValue: 0

          function valueAt(x) {
            var w = rail.width
            if (w <= 0) return 0
            return Model.clampBrightness(Math.round((x / w) * 100))
          }
          onPressed: function(mouse) {
            root.selectRow(accessoryRow.accessoryIndex)
            dragging = true
            pendingValue = valueAt(mouse.x)
          }
          onPositionChanged: function(mouse) { if (dragging) pendingValue = valueAt(mouse.x) }
          onReleased: {
            if (dragging) { dragging = false; hb.setBrightness(accessoryRow.accessory, pendingValue) }
          }
          onCanceled: dragging = false
        }
      }
    }
  }
}
