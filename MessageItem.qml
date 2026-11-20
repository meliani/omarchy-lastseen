import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// One message in the thread, plus the day separator above it when it is the
// first of its day and the "load earlier" button above the oldest one.
Item {
  id: item

  property var message: ({})
  property var older: null            // the next older message, null for the oldest
  property var service: null          // Service.qml
  property bool group: false
  property real nowMs: Date.now()
  property var tr: function(key) { return key }
  property var fmt: function(date, pattern) { return "" }
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  signal replyRequested(var message)
  signal editRequested(var message)

  property bool picking: false        // emoji row open
  property bool deleteArmed: false
  Timer { id: disarm; interval: 4000; onTriggered: item.deleteArmed = false }

  readonly property bool mine: message.fromMe === true
  readonly property string kind: message.kind || "text"
  readonly property var mediaState: service && service.media[message.id] ? service.media[message.id] : null
  readonly property string mediaPath: message.media || (mediaState && mediaState.path ? mediaState.path : "")
  readonly property bool mediaFailed: mediaState !== null && mediaState.state === "failed"
  readonly property bool mediaLoading: mediaState !== null && mediaState.state === "loading"
  readonly property bool playing: service !== null && service.playingId === message.id && message.id !== ""
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color accent: Commons.Color.accent
  readonly property real maxBubble: Math.min(width * 0.8, Style.space(320))
  readonly property bool showDay: older === null || !Model.sameDay(message.ts, older.ts)
  // Same person within 5 minutes: stacked tight, name shown once.
  readonly property bool continues: !showDay && older !== null && older.fromMe === message.fromMe
    && (older.senderJid || "") === (message.senderJid || "") && message.ts - older.ts < 300
  property int unreadCount: 0          // >0 on the oldest unread message: draws the divider above it
  readonly property bool emoji: kind === "text" && !message.deleted && Model.emojiOnly(message.text)
  readonly property bool linked: kind === "text" && Model.hasLink(message.text)

  // Pictures and video thumbnails keep their aspect ratio inside 240 x 280.
  readonly property real mediaWidth: Math.min(Style.space(240), maxBubble - Style.space(12))
  readonly property real mediaHeight: {
    var w = Number(message.width || 0), h = Number(message.height || 0)
    var ratio = w > 0 && h > 0 ? h / w : 0.75
    return Math.max(Style.space(90), Math.min(Style.space(280), mediaWidth * ratio))
  }

  implicitHeight: column.implicitHeight + Style.space(4)

  Component.onCompleted: {
    if ((kind === "sticker" || (kind === "image" && !message.thumb)) && !message.media && service)
      service.fetch(message.id)
  }

  Column {
    id: column
    width: parent.width
    spacing: Style.space(4)

    Item {
      visible: older === null && service !== null && service.moreMessages
      width: parent.width
      height: visible ? moreButton.implicitHeight + Style.space(8) : 0

      Rectangle {
        id: moreButton
        anchors.centerIn: parent
        implicitWidth: moreText.implicitWidth + Style.space(20)
        implicitHeight: moreText.implicitHeight + Style.space(10)
        radius: height / 2
        color: moreArea.containsMouse ? Qt.alpha(item.foreground, 0.16) : Qt.alpha(item.foreground, 0.08)

        Text {
          id: moreText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: Model.glyph("more") + "  " + item.tr("loadEarlier")
          color: item.foreground
          font.family: item.fontFamily
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          id: moreArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: item.service.more()
        }
      }
    }

    Item {
      visible: item.showDay
      width: parent.width
      height: visible ? dayPill.implicitHeight + Style.space(10) : 0

      Rectangle {
        id: dayPill
        anchors.centerIn: parent
        implicitWidth: dayText.implicitWidth + Style.space(18)
        implicitHeight: dayText.implicitHeight + Style.space(6)
        radius: height / 2
        color: Qt.alpha(item.foreground, 0.08)

        Text {
          id: dayText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: item.message.ts ? Model.dayLabel(item.message.ts, item.nowMs, item.tr, item.fmt) : ""
          color: item.dim
          font.family: item.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Item {
      visible: item.unreadCount > 0
      width: parent.width
      height: visible ? unreadPill.implicitHeight + Style.space(12) : 0

      Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: 1
        color: Qt.alpha(Model.BRAND, 0.5)
      }
      Rectangle {
        id: unreadPill
        anchors.centerIn: parent
        implicitWidth: unreadText.implicitWidth + Style.space(18)
        implicitHeight: unreadText.implicitHeight + Style.space(6)
        radius: height / 2
        color: Commons.Color.popups.background
        border.width: 1
        border.color: Qt.alpha(Model.BRAND, 0.6)
        Text {
          id: unreadText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: item.tr("unreadMessages").replace("%1", item.unreadCount)
          color: Model.BRAND
          font.family: item.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }
    }

    Item { visible: !item.continues; width: 1; height: 0 }   // a new run gets the column's spacing

    Item {
      id: line
      width: parent.width
      height: bubble.height + (reactionRow.visible ? reactionRow.height - Style.space(4) : 0)

      HoverHandler { id: hover }

      Rectangle {
        id: bubble
        readonly property bool bare: item.kind === "sticker"
        x: item.mine ? parent.width - width - Style.space(8) : Style.space(8)
        width: Math.min(item.maxBubble, Math.max(bubbleBody.contentWidth, footer.implicitWidth, senderText.visible ? senderText.implicitWidth : 0) + Style.space(18))
        height: bubbleBody.implicitHeight + Style.space(14)
        radius: Style.cornerRadius + 2
        color: bare ? "transparent" : item.mine ? Qt.alpha(item.accent, 0.30) : Qt.alpha(item.foreground, 0.09)
        border.width: item.message.deleted === true || item.message.mentionsMe === true ? 1 : 0
        border.color: item.message.deleted === true ? Qt.alpha(Commons.Color.urgent, 0.6) : Qt.alpha(Model.BRAND, 0.8)

        Column {
          id: bubbleBody
          x: Style.space(9)
          y: Style.space(7)
          width: bubble.width - Style.space(18)
          spacing: Style.space(4)

          readonly property real contentWidth: {
            switch (item.kind) {
            case "text": return Math.min(textBody.implicitWidth, item.maxBubble)
            case "image": case "video": return item.mediaWidth
            case "sticker": return Style.space(130)
            case "audio": return Style.space(210)
            case "document": return Style.space(250)
            case "poll": return Math.max(Style.space(220), pollTitle.implicitWidth)
            default: return Math.max(Style.space(180), Math.min(otherText.implicitWidth + Style.space(30), item.maxBubble))
            }
          }

          Text {
            id: senderText
            visible: item.group && !item.mine && item.message.sender && !item.continues
            width: parent.width
            textFormat: Text.PlainText
            text: item.message.sender || ""
            color: item.accent
            font.family: item.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideRight
          }

          // Quoted message being replied to.
          Rectangle {
            visible: item.message.quote !== null && item.message.quote !== undefined
            width: parent.width
            height: visible ? quoteText.implicitHeight + Style.space(10) : 0
            radius: Style.cornerRadius
            color: Qt.alpha(item.foreground, 0.08)

            Rectangle { width: 3; height: parent.height; radius: 1; color: item.accent }

            Text {
              id: quoteText
              x: Style.space(10)
              y: Style.space(5)
              width: parent.width - Style.space(16)
              textFormat: Text.PlainText
              text: Model.previewText(item.message.quote, item.tr)
              color: item.dim
              font.family: item.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }
          }

          // -- text
          Text {
            id: textBody
            visible: item.kind === "text"
            width: parent.width
            // Links only: Model.linkify escapes everything else, so no markup from the message survives.
            textFormat: item.linked ? Text.StyledText : Text.PlainText
            text: item.linked ? Model.linkify(item.message.text) : (item.message.text || "")
            linkColor: "#53bdeb"
            color: item.foreground
            font.family: item.fontFamily
            font.pixelSize: item.emoji ? Math.round(Style.font.display * 1.6) : Style.font.body
            wrapMode: Text.Wrap
            onLinkActivated: function(link) { if (/^https?:\/\//i.test(link)) Qt.openUrlExternally(link) }
            HoverHandler { cursorShape: textBody.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor }
          }

          // -- image / video / sticker
          Item {
            visible: item.kind === "image" || item.kind === "video" || item.kind === "sticker"
            width: item.kind === "sticker" ? Style.space(130) : item.mediaWidth
            height: item.kind === "sticker" ? Style.space(130) : item.mediaHeight

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: Qt.alpha(item.foreground, 0.06)
              visible: picture.status !== Image.Ready && item.kind !== "sticker"
            }

            Image {
              id: picture
              anchors.fill: parent
              fillMode: item.kind === "sticker" ? Image.PreserveAspectFit : Image.PreserveAspectCrop
              asynchronous: true
              smooth: true
              source: item.kind !== "image" && item.kind !== "video" && item.kind !== "sticker" ? ""
                : item.mediaPath !== "" && item.kind !== "video" ? "file://" + item.mediaPath
                : item.message.thumb ? "data:image/jpeg;base64," + item.message.thumb : ""
            }

            Text {
              anchors.centerIn: parent
              visible: picture.status !== Image.Ready
              textFormat: Text.PlainText
              text: item.mediaFailed ? Model.glyph("imageOff") : item.mediaLoading ? Model.glyph("pending") : Model.glyph(item.kind === "video" ? "video" : "image")
              color: item.dim
              font.family: item.fontFamily
              font.pixelSize: Style.font.display
            }

            Rectangle {
              visible: item.kind === "video"
              anchors.centerIn: parent
              width: Style.space(48); height: width; radius: width / 2
              color: Qt.rgba(0, 0, 0, 0.55)

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: item.playing ? Model.glyph("stop") : item.mediaLoading ? Model.glyph("pending") : Model.glyph("play")
                color: "white"
                font.family: item.fontFamily
                font.pixelSize: Style.font.icon
              }
            }

            Rectangle {
              visible: item.kind === "video" && item.message.seconds > 0
              anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: Style.space(6)
              width: videoTime.implicitWidth + Style.space(10); height: videoTime.implicitHeight + Style.space(4)
              radius: height / 2
              color: Qt.rgba(0, 0, 0, 0.55)

              Text {
                id: videoTime
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: Model.duration(item.message.seconds)
                color: "white"
                font.family: item.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (item.kind === "video") item.service.play(item.message.id)
                else if (item.kind === "image") item.service.view(item.message.id)
              }
            }
          }

          // -- voice note / audio
          RowLayout {
            visible: item.kind === "audio"
            width: parent.width
            spacing: Style.space(10)

            Rectangle {
              Layout.preferredWidth: Style.space(34); Layout.preferredHeight: Style.space(34)
              radius: width / 2
              color: playArea.containsMouse ? Qt.alpha(item.foreground, 0.22) : Qt.alpha(item.foreground, 0.14)

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: item.playing ? Model.glyph("stop") : item.mediaLoading ? Model.glyph("pending") : Model.glyph("play")
                color: item.foreground
                font.family: item.fontFamily
                font.pixelSize: Style.font.icon
              }

              MouseArea {
                id: playArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: item.service.play(item.message.id)
              }
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: 0

              Text {
                textFormat: Text.PlainText
                text: Model.glyph("audio") + " " + item.tr(item.message.voice ? "voiceMessage" : "audio")
                color: item.foreground
                font.family: item.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                textFormat: Text.PlainText
                text: item.mediaFailed ? item.tr("mediaExpired") : Model.duration(item.message.seconds)
                color: item.mediaFailed ? Commons.Color.urgent : item.dim
                font.family: item.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // -- document
          Rectangle {
            visible: item.kind === "document"
            width: parent.width
            height: visible ? docRow.implicitHeight + Style.space(12) : 0
            radius: Style.cornerRadius
            color: docArea.containsMouse ? Qt.alpha(item.foreground, 0.14) : Qt.alpha(item.foreground, 0.07)

            RowLayout {
              id: docRow
              anchors.left: parent.left; anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: Model.glyph("document")
                color: item.foreground
                font.family: item.fontFamily
                font.pixelSize: Style.font.display
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: item.message.fileName || item.tr("document")
                  color: item.foreground
                  font.family: item.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideMiddle
                }

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: item.mediaFailed ? item.tr("mediaExpired")
                    : item.mediaLoading ? item.tr("downloading")
                    : [Model.fileSize(item.message.size), (item.message.fileName || "").split(".").pop().toUpperCase()].filter(function(s) { return s !== "" }).join(" · ")
                  color: item.mediaFailed ? Commons.Color.urgent : item.dim
                  font.family: item.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Text {
                textFormat: Text.PlainText
                text: item.mediaLoading ? Model.glyph("pending") : Model.glyph("download")
                color: item.dim
                font.family: item.fontFamily
                font.pixelSize: Style.font.icon
              }
            }

            MouseArea {
              id: docArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (!item.mediaLoading) item.service.download(item.message.id)
            }
          }

          // -- poll
          Column {
            visible: item.kind === "poll"
            width: parent.width
            spacing: Style.space(3)

            Text {
              id: pollTitle
              width: parent.width
              textFormat: Text.PlainText
              text: Model.glyph("poll") + "  " + (item.message.text || item.tr("poll"))
              color: item.foreground
              font.family: item.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              wrapMode: Text.Wrap
            }

            Repeater {
              model: item.kind === "poll" ? (item.message.options || []) : []
              Text {
                required property string modelData
                width: parent.width
                textFormat: Text.PlainText
                text: "○  " + modelData
                color: item.foreground
                font.family: item.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.Wrap
              }
            }
          }

          // -- location / contact / unsupported
          Text {
            id: otherText
            visible: item.kind === "location" || item.kind === "contact" || item.kind === "unsupported" || item.kind === "deleted" || item.kind === "viewOnce"
            width: parent.width
            textFormat: Text.PlainText
            text: {
              if (item.kind === "location") return Model.glyph("location") + "  " + (item.message.text || item.tr("location"))
              if (item.kind === "contact") return Model.glyph("contact") + "  " + (item.message.text || item.tr("contact"))
              if (item.kind === "deleted") return Model.glyph("deleted") + "  " + item.tr("messageDeleted")
              if (item.kind === "viewOnce") return Model.glyph("viewOnce") + "  "
                + item.tr(item.message.media === "video" ? "viewOnceVideo" : item.message.media === "audio" ? "viewOnceAudio" : "viewOncePhoto")
                + "\n" + item.tr("viewOnceHint")
              return item.tr("unsupported")
            }
            color: item.kind === "unsupported" || item.kind === "deleted" || item.kind === "viewOnce" ? item.dim : item.foreground
            font.family: item.fontFamily
            font.pixelSize: Style.font.body
            font.italic: item.kind === "unsupported" || item.kind === "deleted"
            font.underline: item.kind === "location" && locationArea.containsMouse
            wrapMode: Text.Wrap

            MouseArea {
              id: locationArea
              anchors.fill: parent
              enabled: item.kind === "location"
              hoverEnabled: true
              cursorShape: item.kind === "location" ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: {
                var url = Model.mapUrl(item.message.lat, item.message.lng)
                if (url !== "") Qt.openUrlExternally(url)
              }
            }
          }

          // Caption under media.
          Text {
            visible: item.kind !== "text" && item.kind !== "location" && item.kind !== "contact" && item.kind !== "poll" && item.kind !== "unsupported" && item.kind !== "deleted" && item.kind !== "viewOnce" && (item.message.text || "") !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: item.message.text || ""
            color: item.foreground
            font.family: item.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
          }

          Row {
            id: footer
            anchors.right: parent.right
            spacing: Style.space(4)

            Text {
              visible: item.message.deleted === true
              textFormat: Text.PlainText
              text: Model.glyph("deleted") + " " + item.tr(item.mine ? "deletedByYou" : "deletedBySender")
              color: Commons.Color.urgent
              font.family: item.fontFamily
              font.pixelSize: Style.font.caption
              font.italic: true
            }

            Text {
              visible: item.message.edited === true
              textFormat: Text.PlainText
              text: item.tr("edited")
              color: item.dim
              font.family: item.fontFamily
              font.pixelSize: Style.font.caption
              font.italic: true
            }

            Text {
              textFormat: Text.PlainText
              text: item.message.ts ? item.fmt(new Date(item.message.ts * 1000), "HH:mm") : ""
              color: item.dim
              font.family: item.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: item.mine
              textFormat: Text.PlainText
              text: Model.tick(item.message.status)
              color: item.message.status === "read" ? "#53bdeb" : item.message.status === "error" ? Commons.Color.urgent : item.dim
              font.family: item.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      Row {
        id: reactionRow
        visible: (item.message.reactions || []).length > 0
        anchors.top: bubble.bottom
        anchors.topMargin: -Style.space(6)
        x: item.mine ? bubble.x + bubble.width - width - Style.space(6) : bubble.x + Style.space(6)
        spacing: Style.space(2)

        Repeater {
          model: item.message.reactions || []
          Rectangle {
            required property var modelData
            width: reactionText.implicitWidth + Style.space(10)
            height: Style.space(20)
            radius: height / 2
            color: Commons.Color.popups.background
            border.width: 1
            border.color: modelData.mine ? item.accent : Qt.alpha(item.foreground, 0.2)

            Text {
              id: reactionText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: modelData.emoji + (modelData.count > 1 ? " " + modelData.count : "")
              color: item.foreground
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // Hover actions: a pill over the bubble's top corner, and the emoji row.
      Rectangle {
        id: actions
        z: 5
        visible: (hover.hovered || item.picking || item.deleteArmed) && item.kind !== "unsupported" && item.kind !== "deleted" && item.message.id !== ""
        y: Math.max(0, bubble.y - Style.space(12))
        x: item.mine ? Math.max(0, bubble.x - Style.space(6)) : Math.min(parent.width - width, bubble.x + bubble.width - width + Style.space(6))
        width: actionRow.implicitWidth + Style.space(8)
        height: actionRow.implicitHeight + Style.space(4)
        radius: height / 2
        color: Commons.Color.popups.background
        border.width: 1
        border.color: Qt.alpha(item.foreground, 0.15)

        Row {
          id: actionRow
          anchors.centerIn: parent
          spacing: 0

          Repeater {
            model: item.picking ? Model.REACTIONS : []
            Rectangle {
              required property string modelData
              width: Style.space(28); height: Style.space(28); radius: width / 2
              color: emojiArea.containsMouse ? Qt.alpha(item.foreground, 0.15) : "transparent"
              Text { anchors.centerIn: parent; textFormat: Text.PlainText; text: modelData; font.pixelSize: Style.font.body }
              MouseArea {
                id: emojiArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { item.service.react(item.message.id, modelData); item.picking = false }
              }
            }
          }

          PanelActionButton {
            iconText: item.picking ? Model.glyph("close") : Model.glyph("react")
            tooltipText: item.tr("react")
            foreground: item.foreground
            fontFamily: item.fontFamily
            onClicked: item.picking = !item.picking
          }
          PanelActionButton {
            visible: !item.picking
            iconText: Model.glyph("reply")
            tooltipText: item.tr("reply")
            foreground: item.foreground
            fontFamily: item.fontFamily
            onClicked: item.replyRequested(item.message)
          }
          PanelActionButton {
            visible: !item.picking && (item.message.text || "") !== ""
            iconText: Model.glyph("copy")
            tooltipText: item.tr("copy")
            foreground: item.foreground
            fontFamily: item.fontFamily
            onClicked: Quickshell.execDetached(["wl-copy", "--", item.message.text])
          }
          PanelActionButton {
            visible: !item.picking && item.message.editable === true && item.message.deleted !== true
            iconText: Model.glyph("edit")
            tooltipText: item.tr("edit")
            foreground: item.foreground
            fontFamily: item.fontFamily
            onClicked: item.editRequested(item.message)
          }
          PanelActionButton {
            visible: !item.picking && item.mine && item.message.deleted !== true
            iconText: Model.glyph("trash")
            tooltipText: item.deleteArmed ? item.tr("confirmAgain") : item.tr("deleteForEveryone")
            foreground: item.deleteArmed ? Commons.Color.urgent : item.foreground
            fontFamily: item.fontFamily
            onClicked: {
              if (item.deleteArmed) { item.deleteArmed = false; item.service.remove(item.message.id) }
              else { item.deleteArmed = true; disarm.restart() }
            }
          }
        }
      }
    }
  }
}
