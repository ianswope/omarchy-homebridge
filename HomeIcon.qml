import QtQuick
import QtQuick.Shapes
import qs.Commons

// A house. Deliberately not the Homebridge mark — this ships in a public
// marketplace and a plugin nobody at Homebridge has seen should not wear their
// badge. The bar draws this near 12px, so it is one solid roof over one solid
// body rather than an outlined glyph, which turns to mush at that size.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  readonly property real roofHeight: iconSize * 0.42
  readonly property real bodyHeight: iconSize * 0.40
  readonly property real bodyWidth: iconSize * 0.66
  readonly property real roofWidth: iconSize * 0.86

  Item {
    id: stack
    width: parent.width
    height: root.roofHeight + root.bodyHeight
    anchors.centerIn: parent

    // Roof.
    Shape {
      id: roof
      width: root.roofWidth
      height: root.roofHeight
      x: (stack.width - width) / 2
      y: 0
      antialiasing: true
      layer.enabled: true
      layer.samples: 4

      ShapePath {
        fillColor: root.color
        strokeWidth: 0
        startX: roof.width / 2
        startY: 0
        PathLine { x: roof.width; y: roof.height }
        PathLine { x: 0; y: roof.height }
        PathLine { x: roof.width / 2; y: 0 }
      }
    }

    // Body, with a doorway punched out so the shape still reads as a house at
    // the smallest sizes rather than as a plain block under a triangle.
    Rectangle {
      width: root.bodyWidth
      height: root.bodyHeight
      x: (stack.width - width) / 2
      y: root.roofHeight
      color: root.color
      antialiasing: true

      Rectangle {
        width: parent.width * 0.28
        height: parent.height * 0.62
        radius: Math.max(1, width * 0.18)
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        // A hole in the house: the bar background shows through. The panel sets
        // this to the surface behind the icon.
        color: root.doorColor
      }
    }
  }

  // The colour the doorway punches through to. The bar has no single background
  // token the plugin can rely on, so the panel passes the real one in; this
  // falls back to the shell background.
  property color doorColor: Color.background
}
