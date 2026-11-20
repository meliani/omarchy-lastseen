import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// One conversation in the list: avatar, name, time, last message, unread.
CursorSurface {
  id: row

  property var chat: ({})
  property string avatarPath: ""
  property real nowMs: Date.now()
  property var tr: function(key) { return key }
  property var fmt: function(date, pattern) { return "" }
  property string fontFamily: Style.font.family
  readonly property bool unread: (chat.unread || 0) > 0
  readonly property color dim: Qt.darker(foreground, 1.5)

  signal activated()
  signal hoveredRow()

  implicitHeight: Style.space(58)

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: row.hoveredRow()
    onClicked: row.activated()
  }

  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(10)

    Avatar {
      Layout.alignment: Qt.AlignVCenter
      size: Style.space(40)
      name: row.chat.name || ""
      source: row.avatarPath
      group: row.chat.group === true
      foreground: row.foreground
      fontFamily: row.fontFamily
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      spacing: Style.space(2)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: Model.title(row.chat, row.tr)
          color: row.chat.name || row.chat.phone ? row.foreground : row.dim
          font.family: row.fontFamily
          font.pixelSize: Style.font.body
          font.weight: row.unread ? Font.Bold : Font.Normal
          font.italic: !row.chat.name && !row.chat.phone
          elide: Text.ElideRight
          maximumLineCount: 1
        }

        Text {
          textFormat: Text.PlainText
          text: Model.chatTime(row.chat.ts, row.nowMs, row.tr, row.fmt)
          color: row.unread ? Model.BRAND : row.dim
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(4)

        Text {
          visible: row.chat.fromMe === true && row.chat.status !== ""
          textFormat: Text.PlainText
          text: Model.tick(row.chat.status)
          color: row.chat.status === "read" ? "#53bdeb" : row.dim
          font.family: row.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: {
            var body = Model.previewText(row.chat.preview, row.tr)
            if (row.chat.fromMe === true) return row.tr("you") + ": " + body
            if (row.chat.group && row.chat.sender) return row.chat.sender + ": " + body
            return body
          }
          color: row.unread ? row.foreground : row.dim
          font.family: row.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
          maximumLineCount: 1
        }

        Rectangle {
          visible: row.unread
          Layout.alignment: Qt.AlignVCenter
          implicitWidth: Math.max(height, badge.implicitWidth + Style.space(10))
          implicitHeight: Style.space(18)
          radius: height / 2
          color: Model.BRAND

          Text {
            id: badge
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: row.chat.unread > 99 ? "99+" : String(row.chat.unread)
            color: Model.BRAND_INK
            font.family: row.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }
    }
  }
}
