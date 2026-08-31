import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus popup for a Homebridge server. One row per controllable
// accessory: its name, what it is, and whether it is on. Click a row to toggle
// it; drag the rail on a dimmable light to set its brightness. Toggling your own
// lights is instant and unconfirmed — the panel reports, and acts, on your home.
Panel {
  id: root
  moduleName: "ianswope.homebridge"
  ipcTarget: "ianswope.homebridge"
  manageIpc: false

  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var items: hb.accessories
  readonly property bool countVisible: hb.showCount && hb.barCountText !== ""

  // Only an unreachable server recolours the bar icon; an accessory being off is
  // the normal resting state, not a fault.
  readonly property color barIconColor: hb.level === "critical" ? urgent : barForeground
  readonly property color heroColor: hb.level === "critical" ? urgent : foreground

  function accessoryAt(i) {
    var list = hb.accessories || []
    return (i >= 0 && i < list.length) ? list[i] : null
  }

  function selectedAccessory() {
    if (items.length === 0) return null
    return items[Math.max(0, Math.min(selectedIndex, items.length - 1))]
  }

  function ensureCursor() {
    if (items.length === 0) { selectedIndex = 0; return }
    selectedIndex = Math.max(0, Math.min(selectedIndex, items.length - 1))
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    selectedIndex = Math.max(0, Math.min(items.length - 1, selectedIndex + dy))
    scrollCursorIntoView()
  }

  function toggleSelected() {
    var a = selectedAccessory()
    if (a) hb.toggle(a)
  }

  function nudgeSelectedBrightness(delta) {
    var a = selectedAccessory()
    if (!a || !a.dimmable) return
    var base = (a.brightness === null || a.brightness === undefined) ? (a.on ? 100 : 0) : a.brightness
    hb.setBrightness(a, Model.clampBrightness(base + delta))
  }

  property var rowRegistry: ({})
  function registerRow(index, item) { rowRegistry[index] = item }

  function scrollCursorIntoView() {
    var target = rowRegistry[selectedIndex]
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

  // Without these the bar allocates zero width, the widget never appears, and
  // nothing is logged — which looks exactly like a plugin that failed to load.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
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
  }

  TextMetrics {
    id: countMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.bar.iconFont
    text: hb.barCountText
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
            text: hb.barCountText
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
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(
      headerColumn.implicitHeight + column.implicitHeight + footerColumn.implicitHeight + Style.space(34),
      Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dx, dy)
        else if (dx !== 0) root.nudgeSelectedBrightness(dx > 0 ? 10 : -10)
      }
      onActivateRequested: { root.cursorActive = true; root.toggleSelected() }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r") hb.refresh()
        else if (t === "t" || t === " ") root.toggleSelected()
        else if (t === "l") hb.signIn()
        else if (t === "e") hb.openConfig()
        else if (t === "-" || t === "_" || t === "[") root.nudgeSelectedBrightness(-10)
        else if (t === "=" || t === "+" || t === "]") root.nudgeSelectedBrightness(10)
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
            visible: hb.configured && hb.everLoaded && (hb.accessories || []).length === 0 && hb.level !== "critical"
            width: parent.width
            text: "No controllable accessories. This shows anything Homebridge "
                  + "bridges with a switchable On — lights, switches, outlets, fans."
            textFormat: Text.PlainText
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: hb.accessories
            AccessoryRow {
              required property var modelData
              required property int index
              width: column.width
              accessory: modelData
              accessoryIndex: index
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
          text: "space toggle · ←/→ or -/+ brightness · r refresh · l sign in · e edit config"
          textFormat: Text.PlainText
          color: Qt.darker(root.dim, 1.15)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  component AccessoryRow: CursorSurface {
    id: accessoryRow
    property var accessory: null
    property int accessoryIndex: -1

    readonly property bool isOn: Model.isOn(accessory)
    readonly property bool dimmable: !!accessory && accessory.dimmable === true

    hasCursor: root.cursorActive && root.selectedIndex === accessoryIndex
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

      // Name + state. This region toggles; the slider below has its own handler.
      Item {
        width: parent.width
        implicitHeight: Math.max(nameCol.implicitHeight, stateText.implicitHeight)

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          acceptedButtons: Qt.LeftButton
          onEntered: { root.cursorActive = true; root.selectedIndex = accessoryRow.accessoryIndex }
          onClicked: hb.toggle(accessoryRow.accessory)
        }

        Row {
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.space(9)

          // On/off at a glance.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(8)
            height: Style.space(8)
            radius: width / 2
            color: accessoryRow.isOn ? root.foreground : "transparent"
            border.width: accessoryRow.isOn ? 0 : Math.max(1, Style.space(1))
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
              color: accessoryRow.isOn ? root.foreground : Qt.darker(root.foreground, 1.2)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              visible: text !== ""
              width: parent.width
              text: accessoryRow.accessory ? accessoryRow.accessory.type : ""
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Text {
            id: stateText
            anchors.verticalCenter: parent.verticalCenter
            text: Model.stateText(accessoryRow.accessory)
            textFormat: Text.PlainText
            color: accessoryRow.isOn ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }

      // Brightness rail, only for dimmable lights. Its own MouseArea, so
      // dragging it never reads as a toggle. The value is committed on release
      // (and on a click) rather than streamed, so a drag is one request.
      Item {
        visible: accessoryRow.dimmable
        width: parent.width
        height: Style.space(14)

        property int liveValue: {
          if (dragArea.dragging) return dragArea.pendingValue
          var b = accessoryRow.accessory ? accessoryRow.accessory.brightness : null
          return (b === null || b === undefined) ? (accessoryRow.isOn ? 100 : 0) : b
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
            color: accessoryRow.isOn ? root.foreground : root.dim
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
            root.cursorActive = true
            root.selectedIndex = accessoryRow.accessoryIndex
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
