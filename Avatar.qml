import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

// A contact's picture in a circle, or their initial (a group glyph for groups
// with no picture). `source` is a local file the backend cached.
Item {
  id: avatar

  property string name: ""
  property string source: ""
  property bool group: false
  property real size: Style.space(36)
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  readonly property bool pictured: picture.status === Image.Ready

  implicitWidth: size
  implicitHeight: size

  Rectangle {
    anchors.fill: parent
    radius: width / 2
    visible: !avatar.pictured
    color: Qt.alpha(avatar.foreground, 0.14)

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: avatar.group ? Model.glyph("group") : avatar.name === "" ? Model.glyph("contact") : Model.initialOf(avatar.name)
      color: avatar.foreground
      font.family: avatar.fontFamily
      font.pixelSize: Math.round(avatar.size * (avatar.group || avatar.name === "" ? 0.5 : 0.42))
      font.weight: Font.DemiBold
    }
  }

  Image {
    id: picture
    anchors.fill: parent
    visible: false
    source: avatar.source === "" ? "" : "file://" + avatar.source
    sourceSize.width: Math.ceil(avatar.size * 2)
    sourceSize.height: Math.ceil(avatar.size * 2)
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    smooth: true
  }

  Item {
    id: disc
    anchors.fill: parent
    visible: false
    layer.enabled: true

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: "black"
    }
  }

  MultiEffect {
    anchors.fill: parent
    visible: avatar.pictured
    source: picture
    maskEnabled: true
    maskSource: disc
    maskThresholdMin: 0.5
    maskSpreadAtMin: 1.0
  }
}
