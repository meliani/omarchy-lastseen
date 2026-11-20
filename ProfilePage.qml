import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Contact or group details: picture, number, about, business card, members,
// invite link, local name, and the chat actions (unread, block, leave).
Item {
  id: page

  property var service: null
  property var chat: null                 // the open chat (name/avatar until the profile loads)
  property var tr: function(key) { return key }
  property var fmt: function(date, pattern) { return "" }
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  signal openChat(string jid)
  property alias renameField: renameField

  readonly property var profile: service && service.profile && chat && service.profile.jid === chat.jid ? service.profile : null
  readonly property bool group: chat ? chat.group === true : false
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color accent: Commons.Color.accent
  readonly property string shownName: profile && profile.name ? profile.name : Model.title(chat, tr)
  readonly property string shownPhone: (profile && profile.phone) || (chat ? chat.phone : "") || ""

  // Destructive actions take two clicks; the first one arms them for 4 s.
  property string armed: ""
  property bool blocked: false
  function arm(op, action) {
    if (armed === op) { armed = ""; action() } else { armed = op; disarm.restart() }
  }
  Timer { id: disarm; interval: 4000; onTriggered: page.armed = "" }

  onChatChanged: { armed = ""; blocked = false; renameField.text = "" }

  component Section: Column {
    property string label: ""
    width: parent ? parent.width : 0
    spacing: Style.space(4)
    Text {
      visible: parent.label !== ""
      textFormat: Text.PlainText
      text: parent.label
      color: page.accent
      font.family: page.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  component ActionButton: Rectangle {
    id: action
    property string icon: ""
    property string label: ""
    property bool danger: false
    property bool armedState: false
    signal clicked()
    width: parent ? parent.width : 0
    height: actionRow.implicitHeight + Style.space(14)
    radius: Style.cornerRadius
    color: armedState ? Qt.alpha(Commons.Color.urgent, 0.25)
      : actionArea.containsMouse ? Qt.alpha(page.foreground, 0.12) : Qt.alpha(page.foreground, 0.05)

    RowLayout {
      id: actionRow
      anchors.verticalCenter: parent.verticalCenter
      x: Style.space(12)
      width: parent.width - Style.space(24)
      spacing: Style.space(10)
      Text {
        textFormat: Text.PlainText
        text: action.icon
        color: action.danger ? Commons.Color.urgent : page.foreground
        font.family: page.fontFamily
        font.pixelSize: Style.font.icon
      }
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: action.armedState ? page.tr("confirmAgain") : action.label
        color: action.danger ? Commons.Color.urgent : page.foreground
        font.family: page.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }
    }

    MouseArea {
      id: actionArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: action.clicked()
    }
  }

  ScrollView {
    id: scroll
    anchors.fill: parent
    clip: true
    contentWidth: availableWidth
    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

    Column {
      width: scroll.availableWidth
      spacing: Style.space(14)

      // ---- identity
      Column {
        width: parent.width
        spacing: Style.space(6)
        topPadding: Style.space(6)

        Avatar {
          anchors.horizontalCenter: parent.horizontalCenter
          size: Style.space(104)
          name: page.chat ? (page.chat.name || "") : ""
          source: page.chat ? ((page.service && page.service.avatars[page.chat.jid]) || (page.profile && page.profile.avatar) || page.chat.avatar || "") : ""
          group: page.group
          foreground: page.foreground
          fontFamily: page.fontFamily
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: page.shownName
          color: page.foreground
          font.family: page.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          wrapMode: Text.Wrap
        }

        Row {
          visible: page.shownPhone !== ""
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(6)
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: page.shownPhone
            color: page.dim
            font.family: page.fontFamily
            font.pixelSize: Style.font.body
          }
          PanelActionButton {
            iconText: Model.glyph("copy")
            tooltipText: page.tr("copyNumber")
            foreground: page.foreground
            fontFamily: page.fontFamily
            onClicked: Quickshell.execDetached(["wl-copy", "--", page.shownPhone.replace(/ /g, "")])
          }
        }

        Text {
          visible: !page.group && page.shownPhone === "" && page.profile !== null
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: page.tr("hiddenNumber")
          color: page.dim
          font.family: page.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        Text {
          visible: page.group && page.profile !== null
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: page.profile ? page.tr("membersCount").arg(page.profile.size || 0) : ""
          color: page.dim
          font.family: page.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      Text {
        visible: page.service !== null && page.service.profileLoading && page.profile === null
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: page.tr("loading")
        color: page.dim
        font.family: page.fontFamily
        font.pixelSize: Style.font.body
      }

      // ---- about / description
      Section {
        visible: page.profile !== null && (page.profile.about || "") !== ""
        label: page.group ? page.tr("description") : page.tr("about")
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: page.profile ? (page.profile.about || "") : ""
          color: page.foreground
          font.family: page.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.Wrap
        }
        Text {
          visible: page.profile !== null && ((page.profile.aboutSince || 0) > 0 || (page.profile.created || 0) > 0)
          width: parent.width
          textFormat: Text.PlainText
          text: {
            if (!page.profile) return ""
            if (page.group && page.profile.created) {
              var created = page.fmt(new Date(page.profile.created * 1000), "d MMMM yyyy")
              return page.profile.owner ? page.tr("createdBy").arg(created).arg(page.profile.owner) : page.tr("createdOn").arg(created)
            }
            return page.profile.aboutSince ? page.fmt(new Date(page.profile.aboutSince * 1000), "d MMMM yyyy") : ""
          }
          color: page.dim
          font.family: page.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // ---- business card
      Section {
        visible: page.profile !== null && page.profile.business !== undefined && page.profile.business !== null
        label: page.tr("business")
        Repeater {
          model: {
            var b = page.profile && page.profile.business ? page.profile.business : null
            if (!b) return []
            var rows = []
            if (b.category) rows.push({ icon: "business", text: b.category, url: "" })
            if (b.description) rows.push({ icon: "info", text: b.description, url: "" })
            if (b.address) rows.push({ icon: "place", text: b.address, url: "" })
            if (b.email) rows.push({ icon: "email", text: b.email, url: "mailto:" + b.email })
            for (var i = 0; i < (b.websites || []).length; i++) rows.push({ icon: "web", text: b.websites[i], url: b.websites[i] })
            return rows
          }
          RowLayout {
            required property var modelData
            width: parent.width
            spacing: Style.space(8)
            Text {
              Layout.alignment: Qt.AlignTop
              textFormat: Text.PlainText
              text: Model.glyph(modelData.icon)
              color: page.dim
              font.family: page.fontFamily
              font.pixelSize: Style.font.icon
            }
            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: modelData.text
              color: modelData.url ? page.accent : page.foreground
              font.family: page.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.underline: modelData.url !== "" && linkArea.containsMouse
              wrapMode: Text.Wrap
              MouseArea {
                id: linkArea
                anchors.fill: parent
                enabled: modelData.url !== ""
                hoverEnabled: true
                cursorShape: modelData.url ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: Qt.openUrlExternally(modelData.url)
              }
            }
          }
        }
      }

      // ---- name on this computer (contacts only)
      Section {
        visible: !page.group
        label: page.tr("localName")
        RowLayout {
          width: parent.width
          spacing: Style.space(6)
          TextField {
            id: renameField
            Layout.fillWidth: true
            foreground: page.foreground
            placeholderText: page.profile && page.profile.localName ? page.profile.localName : page.tr("localNameHint")
            onAccepted: { page.service.rename(page.chat.jid, text); text = "" }
          }
          PanelActionButton {
            iconText: Model.glyph("rename")
            tooltipText: page.tr("save")
            foreground: page.foreground
            fontFamily: page.fontFamily
            enabled: renameField.text.trim() !== ""
            onClicked: { page.service.rename(page.chat.jid, renameField.text); renameField.text = "" }
          }
          PanelActionButton {
            visible: page.profile !== null && (page.profile.localName || "") !== ""
            iconText: Model.glyph("close")
            tooltipText: page.tr("clearName")
            foreground: page.foreground
            fontFamily: page.fontFamily
            onClicked: page.service.rename(page.chat.jid, "")
          }
        }
      }

      // ---- same person as a phone number (WhatsApp hid it)
      Section {
        visible: !page.group && page.profile !== null && page.chat !== null
          && page.chat.jid.indexOf("@lid") !== -1 && page.shownPhone === ""
        label: page.tr("samePerson")
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: page.tr("samePersonHint")
          color: page.dim
          font.family: page.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
        RowLayout {
          width: parent.width
          spacing: Style.space(6)
          TextField {
            id: linkField
            Layout.fillWidth: true
            foreground: page.foreground
            placeholderText: page.tr("phonePlaceholder")
            onAccepted: if (text.trim() !== "") { page.service.linkNumber(page.chat.jid, text); text = "" }
          }
          PanelActionButton {
            iconText: Model.glyph("link")
            tooltipText: page.tr("linkNumber")
            foreground: page.foreground
            fontFamily: page.fontFamily
            enabled: linkField.text.trim() !== ""
            onClicked: { page.service.linkNumber(page.chat.jid, linkField.text); linkField.text = "" }
          }
        }
      }

      // ---- group invite link
      Section {
        visible: page.group && page.profile !== null && page.profile.admin === true
        label: page.tr("inviteLink")
        ActionButton {
          icon: Model.glyph("link")
          label: page.service && page.service.inviteUrl ? page.service.inviteUrl : page.tr("showInviteLink")
          onClicked: {
            if (page.service.inviteUrl) Quickshell.execDetached(["wl-copy", "--", page.service.inviteUrl])
            else page.service.invite(page.chat.jid)
          }
        }
      }

      // ---- members
      Section {
        visible: page.group && page.profile !== null && (page.profile.members || []).length > 0
        label: page.profile ? page.tr("membersCount").arg((page.profile.members || []).length) : ""

        Repeater {
          model: page.profile && page.group ? (page.profile.members || []) : []
          Rectangle {
            required property var modelData
            width: parent.width
            height: Style.space(44)
            radius: Style.cornerRadius
            color: memberArea.containsMouse && !modelData.me ? Qt.alpha(page.foreground, 0.08) : "transparent"

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(4)
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(10)
              Avatar {
                size: Style.space(32)
                name: modelData.me ? page.tr("you") : (modelData.name || "")
                source: (page.service && page.service.avatars[modelData.jid]) || modelData.avatar || ""
                foreground: page.foreground
                fontFamily: page.fontFamily
              }
              ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: modelData.me ? page.tr("you") : (modelData.name || modelData.phone || page.tr("unknownContact"))
                  color: modelData.name || modelData.phone || modelData.me ? page.foreground : page.dim
                  font.family: page.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.italic: !modelData.name && !modelData.phone && !modelData.me
                  elide: Text.ElideRight
                }
                Text {
                  visible: modelData.name !== "" && modelData.phone !== "" && !modelData.me
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: modelData.phone
                  color: page.dim
                  font.family: page.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
              Rectangle {
                visible: modelData.admin !== ""
                implicitWidth: adminText.implicitWidth + Style.space(12)
                implicitHeight: adminText.implicitHeight + Style.space(4)
                radius: height / 2
                color: Qt.alpha(Model.BRAND, 0.2)
                Text {
                  id: adminText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: page.tr(modelData.admin === "superadmin" ? "owner" : "admin")
                  color: page.foreground
                  font.family: page.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            MouseArea {
              id: memberArea
              anchors.fill: parent
              enabled: !modelData.me
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: page.openChat(modelData.jid)
            }
          }
        }
      }

      // ---- actions
      Section {
        visible: page.chat !== null
        label: page.tr("actions")

        ActionButton {
          visible: page.profile !== null && (page.profile.linkedLid || "") !== ""
          icon: Model.glyph("link")
          label: page.tr("unlinkNumber")
          onClicked: page.service.linkNumber(page.profile.linkedLid, "")
        }
        ActionButton {
          icon: Model.glyph("unread")
          label: page.tr("markUnread")
          onClicked: page.service.markUnread(page.chat.jid)
        }
        ActionButton {
          visible: !page.group
          icon: Model.glyph("block")
          label: page.blocked ? page.tr("unblock") : page.tr("block")
          danger: !page.blocked
          armedState: page.armed === "block"
          onClicked: {
            if (page.blocked) { page.service.block(page.chat.jid, false); page.blocked = false }
            else page.arm("block", function() { page.service.block(page.chat.jid, true); page.blocked = true })
          }
        }
        ActionButton {
          visible: page.group
          icon: Model.glyph("leave")
          label: page.tr("leaveGroup")
          danger: true
          armedState: page.armed === "leave"
          onClicked: page.arm("leave", function() { page.service.leave(page.chat.jid) })
        }
      }

      Item { width: 1; height: Style.space(6) }
    }
  }
}
