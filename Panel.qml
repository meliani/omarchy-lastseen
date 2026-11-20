import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "meliani.lastseen"
  ipcTarget: "meliani.lastseen"
  manageIpc: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool inChat: wa.activeJid !== ""

  property string query: ""
  property string filter: "all"
  property int selected: 0
  property var replyTo: null
  property var editing: null          // own message being edited
  property bool profileOpen: false
  property string notice: ""
  property real nowMs: Date.now()
  readonly property string phoneQuery: Model.phoneQuery(query)
  readonly property string presenceLine: inChat ? Model.presenceText(wa.presence, wa.activeChat ? wa.activeChat.group === true : false, tr, fmt, nowMs) : ""
  readonly property var visibleChats: Model.filterChats(wa.chats, query, filter)

  readonly property bool notifyEnabled: wa.setting("notifications", true) !== false
  readonly property bool notifyGroups: wa.setting("notifyGroups", false) === true

  // Items inside the lazily built panel content, null until it first opens.
  readonly property Item ui: panel.loadedContent
  function focusField(compose) {
    if (!ui) return
    if (profileOpen) ui.profilePage.renameField.forceActiveFocus()
    else (compose ? ui.composeField : ui.searchField).forceActiveFocus()
  }

  function tr(key) { return strings.t(key) }
  function fmt(date, pattern) { return Qt.locale(Commons.I18n.formatLocale).toString(date, pattern) }
  function avatarFor(chat) { return chat ? (wa.avatars[chat.jid] || chat.avatar || "") : "" }

  function openSelected() {
    if (selected >= 0 && selected < visibleChats.length) openChat(visibleChats[selected].jid)
  }

  property var drafts: ({})    // jid -> unsent text, kept while switching chats
  function saveDraft() {
    if (ui && wa.activeJid !== "" && !editing) drafts[wa.instanceName + "|" + wa.activeJid] = ui.composeField.text
  }

  function openChat(jid) {
    saveDraft()
    replyTo = null
    editing = null
    profileOpen = false
    wa.clearStaged()
    delete notices[wa.instanceName + "|" + jid]
    if (ui) ui.composeField.text = drafts[wa.instanceName + "|" + jid] || ""
    wa.openChat(jid)
    Qt.callLater(function() { root.focusField(true) })
  }

  function backToList() {
    saveDraft()
    wa.closeChat()
    replyTo = null
    editing = null
    profileOpen = false
    wa.clearStaged()
    Qt.callLater(function() { root.focusField(false) })
  }

  function moveSelection(dy) {
    if (inChat || visibleChats.length === 0) return
    selected = Math.max(0, Math.min(visibleChats.length - 1, selected + dy))
    if (ui) ui.chatList.positionViewAtIndex(selected, ListView.Contain)
  }

  function send() {
    if (!ui || profileOpen) return
    var text = ui.composeField.text
    if (editing) {
      if (wa.edit(editing.id, text)) { ui.composeField.text = ""; editing = null }
    } else if (wa.staged) {
      if (wa.sendFile(text, replyTo ? replyTo.id : "")) { ui.composeField.text = ""; replyTo = null }
    } else if (wa.sendText(text, replyTo ? replyTo.id : "")) {
      ui.composeField.text = ""
      delete drafts[wa.instanceName + "|" + wa.activeJid]
      replyTo = null
    }
  }

  function startEdit(message) {
    replyTo = null
    editing = message
    if (ui) { ui.composeField.text = message.text || ""; ui.composeField.forceActiveFocus() }
  }

  function showProfile() {
    if (!inChat) return
    profileOpen = true
    wa.loadProfile(wa.activeJid)
    Qt.callLater(function() { root.focusField(false) })
  }

  function flash(text) { notice = text; noticeTimer.restart() }

  // Esc peels one layer at a time.
  function goBack() {
    if (wa.recording) wa.recordStop(false)
    else if (editing) { editing = null; if (ui) ui.composeField.text = "" }
    else if (wa.staged) wa.clearStaged()
    else if (replyTo) replyTo = null
    else if (profileOpen) profileOpen = false
    else if (inChat) backToList()
    else if (query !== "") query = ""
    else close()
  }

  onQueryChanged: selected = 0
  onFilterChanged: selected = 0

  onOpenedChanged: {
    wa.setVisible(opened)
    nowMs = Date.now()
    if (opened) {
      Qt.callLater(function() { root.focusField(root.inChat) })
    } else {
      wa.closeChat()
      replyTo = null
      editing = null
      profileOpen = false
    }
  }

  Timer { id: noticeTimer; interval: 3500; onTriggered: root.notice = "" }

  // ---- accounts: one Service (and backend) per Evolution instance, so every
  // account keeps its unread count and notifications; the panel shows one.
  readonly property var accounts: {
    var raw = String(primarySetting("accounts", ""))
    var list = []
    raw.split(",").forEach(function(name) {
      name = name.trim()
      if (name !== "" && list.indexOf(name) === -1) list.push(name)
    })
    return list.length ? list : [""]      // "": not set up yet, the panel shows how
  }
  function primarySetting(key, fallback) {
    var v = root.settings ? root.settings[key] : undefined
    return v === undefined || v === null || v === "" ? fallback : v
  }
  property int current: 0
  property var extraServices: []
  readonly property var services: [firstAccount].concat(extraServices)
  readonly property var wa: services[Math.min(current, services.length - 1)] || firstAccount
  readonly property bool setupNeeded: wa.instanceName === "" || wa.connection === "notConfigured"
  readonly property string setupScript: decodeURIComponent(String(Qt.resolvedUrl("scripts/setup.sh")).replace(/^file:\/\//, ""))
  readonly property int unreadAll: {
    var total = 0
    for (var i = 0; i < services.length; i++) total += services[i].unreadTotal
    return total
  }

  function accountLabel(service) {
    return service.account && service.account.name ? service.account.name : service.instanceName
  }

  function switchAccount(index) {
    if (index < 0 || index >= services.length || index === current) return
    saveDraft()
    wa.closeChat()
    wa.setVisible(false)
    replyTo = null; editing = null; profileOpen = false; query = ""; selected = 0
    current = index
    wa.setVisible(opened)
    Qt.callLater(function() { root.focusField(false) })
  }

  function serviceSent(service) { if (service === wa) Qt.callLater(function() { root.focusField(true) }) }
  function serviceOpened(service, jid) { if (service === wa) { root.query = ""; root.openChat(jid) } }
  function serviceDone(service, op, jid) {
    if (service !== wa) return
    if (op === "leave") root.backToList()
    root.flash(root.tr("done_" + op))
  }

  Service {
    id: firstAccount
    settings: root.settings
    instanceName: root.accounts[0]
    onSent: root.serviceSent(firstAccount)
    onIncoming: function(event) { root.notify(event, firstAccount) }
    onOpened: function(jid) { root.serviceOpened(firstAccount, jid) }
    onDone: function(op, jid) { root.serviceDone(firstAccount, op, jid) }
  }

  Repeater {
    id: moreAccounts
    model: root.accounts.slice(1)
    delegate: Service {
      id: account
      required property string modelData
      settings: root.settings
      instanceName: modelData
      onSent: root.serviceSent(account)
      onIncoming: function(event) { root.notify(event, account) }
      onOpened: function(jid) { root.serviceOpened(account, jid) }
      onDone: function(op, jid) { root.serviceDone(account, op, jid) }
    }
    onItemAdded: root.collectAccounts()
    onItemRemoved: Qt.callLater(root.collectAccounts)
  }
  function collectAccounts() {
    var list = []
    for (var i = 0; i < moreAccounts.count; i++) if (moreAccounts.itemAt(i)) list.push(moreAccounts.itemAt(i))
    extraServices = list
    if (current >= services.length) current = 0
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // A desktop notification for a new message, unless it is on screen already.
  // Clicking it ("open") opens that chat.
  // One notification per chat, replaced as messages arrive ("Sara (3)").
  // Group messages notify only when enabled, or when they mention you.
  property var notices: ({})   // jid -> {id, count}
  function notify(event, service) {
    if (!notifyEnabled || (event.group && !notifyGroups && !event.mentionsMe)) return
    if (root.opened && service === wa && wa.activeJid === event.jid) return
    var key = service.instanceName + "|" + event.jid
    var entry = notices[key] || { id: 0, count: 0 }
    entry.count += 1
    notices[key] = entry
    var title = (event.name || tr("unknownContact")) + (entry.count > 1 ? " (" + entry.count + ")" : "")
      + (services.length > 1 ? " · " + accountLabel(service) : "")
    var body = Model.previewText(event.preview, tr)
    if (event.group && event.sender) body = event.sender + ": " + body
    if (event.mentionsMe) body = "@ " + body
    var args = ["notify-send", "-a", "Last Seen", "-p", "-A", "open=" + tr("open")]
    if (entry.id > 0) args.push("-r", String(entry.id))
    if (event.avatar) args.push("-i", event.avatar)
    args.push("--", title, body)
    notifier.createObject(root, { command: args, jid: event.jid, key: key, account: services.indexOf(service) })
  }

  Component {
    id: notifier
    Process {
      property string jid: ""
      property string key: ""
      property int account: 0
      running: true
      stdout: SplitParser {
        onRead: function(line) {
          var text = String(line).trim()
          if (/^[0-9]+$/.test(text)) { if (root.notices[key]) root.notices[key].id = Number(text) }
          else if (text === "open") { root.open(); root.switchAccount(account); root.openChat(jid) }
        }
      }
      onExited: destroy()
    }
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { wa.refresh(); return "ok" }
    function openChat(jid: string): void { root.open(); root.openChat(jid) }
    function profile(jid: string): void { root.open(); root.openChat(jid); root.showProfile() }
    function link(jid: string, number: string): string { wa.linkNumber(jid, number); return "ok" }
    function account(name: string): string {
      for (var i = 0; i < root.services.length; i++)
        if (root.services[i].instanceName === name) { root.open(); root.switchAccount(i); return "ok" }
      return "unknown account"
    }
    function state(): string {
      return JSON.stringify({ opened: root.opened, active: wa.activeJid, chats: wa.chats.length, messages: wa.messages.length, connection: wa.connection, listening: wa.listening })
    }
  }

  Timer {
    interval: 60000
    repeat: true
    running: root.opened
    onTriggered: root.nowMs = Date.now()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.glyph("logo")
    labelText: root.unreadAll > 0 ? (root.unreadAll > 99 ? "99+" : String(root.unreadAll)) : ""
    active: root.unreadAll > 0
    opacity: wa.connection === "open" ? 1 : 0.55
    tooltipText: wa.connection !== "open" && wa.connection !== "unknown" ? root.tr("disconnected")
      : root.unreadAll > 0 ? strings.t("unreadTooltip").arg(root.unreadAll) : "Last Seen"
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) wa.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(Style.space(640), Style.space(640))

    content: PanelKeyCatcher {
      id: keys
      property alias searchField: searchField
      property alias composeField: composeField
      property alias chatList: chatList
      property alias profilePage: profilePage
      anchors.fill: parent
      implicitHeight: Style.space(640)
      onMoveRequested: function(dx, dy) {
        if (root.inChat && !root.profileOpen && dy < 0 && composeField.text === "" && !root.editing) {
          for (var i = 0; i < wa.messages.length; i++) {
            if (wa.messages[i].fromMe && wa.messages[i].editable && !wa.messages[i].deleted) { root.startEdit(wa.messages[i]); return }
          }
        }
        root.moveSelection(dy)
      }
      onActivateRequested: if (!root.inChat) root.openSelected()
      onCloseRequested: root.goBack()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        var field = root.profileOpen ? profilePage.renameField : root.inChat ? composeField : searchField
        field.forceActiveFocus()
        field.insert(field.cursorPosition, text)
      }

      ColumnLayout {
        anchors.fill: parent
        spacing: Style.space(8)

        // ---- header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)

          PanelActionButton {
            visible: root.inChat
            iconText: Model.glyph("back")
            tooltipText: root.tr("back")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.profileOpen ? (root.profileOpen = false) : root.backToList()
          }

          Avatar {
            visible: root.inChat && !root.profileOpen
            size: Style.space(38)
            name: wa.activeChat ? (wa.activeChat.name || "") : ""
            source: root.avatarFor(wa.activeChat)
            group: wa.activeChat ? wa.activeChat.group === true : false
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: !root.inChat
            textFormat: Text.PlainText
            text: Model.glyph("logo")
            color: Model.BRAND
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            HoverHandler {
              enabled: root.inChat && !root.profileOpen
              cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
              enabled: root.inChat && !root.profileOpen
              onTapped: root.showProfile()
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.profileOpen ? root.tr(wa.activeChat && wa.activeChat.group ? "groupInfo" : "contactInfo")
                : root.inChat ? Model.title(wa.activeChat, root.tr) : "Last Seen"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: {
                if (wa.connection !== "open" && wa.connection !== "unknown") return root.tr("disconnected")
                if (root.profileOpen) return Model.title(wa.activeChat, root.tr)
                if (root.inChat) {
                  if (root.presenceLine !== "") return root.presenceLine
                  var first = wa.activeChat && wa.activeChat.group ? root.tr("group") : (wa.activeChat && wa.activeChat.name ? wa.activeChat.phone : "")
                  return [first, root.tr("tapForInfo")].filter(function(part) { return part !== "" }).join(" · ")
                }
                var who = [root.accountLabel(wa), wa.account.phone].filter(function(p) { return p !== "" }).join(" · ")
                return who
              }
              color: wa.connection !== "open" && wa.connection !== "unknown" ? Commons.Color.urgent
                : root.inChat && !root.profileOpen && root.presenceLine !== "" && wa.presence.state !== "unavailable" ? Model.BRAND : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          PanelActionButton {
            visible: root.inChat && !root.profileOpen
            iconText: Model.glyph("info")
            tooltipText: root.tr(wa.activeChat && wa.activeChat.group ? "groupInfo" : "contactInfo")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.showProfile()
          }

          PanelActionButton {
            visible: !root.inChat
            iconText: Model.glyph("refresh")
            tooltipText: root.tr("refresh")
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: wa.refresh()
          }
        }

        // ---- error banner
        Rectangle {
          visible: wa.lastError !== null && !root.setupNeeded
          Layout.fillWidth: true
          Layout.preferredHeight: visible ? errorRow.implicitHeight + Style.space(10) : 0
          radius: Style.cornerRadius
          color: Qt.alpha(Commons.Color.urgent, 0.15)

          RowLayout {
            id: errorRow
            anchors.fill: parent
            anchors.margins: Style.space(5)
            anchors.leftMargin: Style.space(10)

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: {
                if (!wa.lastError) return ""
                var known = ["mediaExpired", "mediaFailed", "noPlayer", "noPika", "tooLarge", "badNumber", "notOnWhatsApp", "noRecorder"]
                return known.indexOf(wa.lastError.code) !== -1 ? root.tr(wa.lastError.code).replace("%1", wa.lastError.detail) : root.tr("apiError") + " " + wa.lastError.detail
              }
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.Wrap
              maximumLineCount: 3
              elide: Text.ElideRight
            }

            PanelActionButton {
              iconText: Model.glyph("close")
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: wa.lastError = null
            }
          }
        }

        Rectangle {
          visible: root.notice !== ""
          Layout.fillWidth: true
          Layout.preferredHeight: visible ? noticeText.implicitHeight + Style.space(10) : 0
          radius: Style.cornerRadius
          color: Qt.alpha(Model.BRAND, 0.18)
          Text {
            id: noticeText
            anchors.verticalCenter: parent.verticalCenter
            x: Style.space(10)
            width: parent.width - Style.space(20)
            textFormat: Text.PlainText
            text: root.notice
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        StackLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          currentIndex: root.setupNeeded ? 3 : root.inChat ? (root.profileOpen ? 2 : 1) : 0

          // ---- chat list
          ColumnLayout {
            spacing: Style.space(8)

            // Account switcher: one chip per WhatsApp account, with its unread count.
            Flow {
              visible: root.services.length > 1
              Layout.fillWidth: true
              spacing: Style.space(6)

              Repeater {
                model: root.services
                Rectangle {
                  id: chip
                  required property var modelData
                  required property int index
                  readonly property bool current: index === root.current
                  width: chipRow.implicitWidth + Style.space(16)
                  height: chipRow.implicitHeight + Style.space(8)
                  radius: height / 2
                  color: current ? Qt.alpha(Model.BRAND, 0.22) : accountArea.containsMouse ? Qt.alpha(root.foreground, 0.12) : Qt.alpha(root.foreground, 0.05)
                  border.width: current ? 1 : 0
                  border.color: Qt.alpha(Model.BRAND, 0.6)

                  Row {
                    id: chipRow
                    anchors.centerIn: parent
                    spacing: Style.space(6)
                    Avatar {
                      anchors.verticalCenter: parent.verticalCenter
                      size: Style.space(20)
                      name: root.accountLabel(chip.modelData)
                      source: chip.modelData.account.avatar || ""
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: root.accountLabel(chip.modelData)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: chip.current
                    }
                    Rectangle {
                      visible: chip.modelData.unreadTotal > 0
                      anchors.verticalCenter: parent.verticalCenter
                      width: Math.max(height, countText.implicitWidth + Style.space(8))
                      height: Style.space(16)
                      radius: height / 2
                      color: Model.BRAND
                      Text {
                        id: countText
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: chip.modelData.unreadTotal > 99 ? "99+" : String(chip.modelData.unreadTotal)
                        color: Model.BRAND_INK
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                  }

                  MouseArea {
                    id: accountArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.switchAccount(chip.index)
                  }
                }
              }
            }

            TextField {
              id: searchField
              Layout.fillWidth: true
              foreground: root.foreground
              placeholderText: Model.glyph("search") + "  " + root.tr("search")
              text: root.query
              onTextChanged: root.query = text
              onAccepted: {
                if (root.visibleChats.length === 0 && root.phoneQuery !== "") wa.newChat(root.phoneQuery)
                else root.openSelected()
              }
            }

            // "Message +212 …": start a chat with a number not in the list.
            Rectangle {
              visible: root.phoneQuery !== ""
              Layout.fillWidth: true
              Layout.preferredHeight: visible ? newChatRow.implicitHeight + Style.space(14) : 0
              radius: Style.cornerRadius
              color: newChatArea.containsMouse ? Qt.alpha(Model.BRAND, 0.25) : Qt.alpha(Model.BRAND, 0.12)
              RowLayout {
                id: newChatRow
                anchors.verticalCenter: parent.verticalCenter
                x: Style.space(12)
                width: parent.width - Style.space(24)
                spacing: Style.space(10)
                Text {
                  textFormat: Text.PlainText
                  text: Model.glyph("newChat")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: root.tr("messageNumber").arg(root.phoneQuery)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
              }
              MouseArea {
                id: newChatArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: wa.newChat(root.phoneQuery)
              }
            }

            Row {
              spacing: Style.space(6)

              Repeater {
                model: ["all", "unread", "groups"]
                Rectangle {
                  required property string modelData
                  readonly property bool current: root.filter === modelData
                  width: chipText.implicitWidth + Style.space(20)
                  height: chipText.implicitHeight + Style.space(8)
                  radius: height / 2
                  color: current ? Qt.alpha(Model.BRAND, 0.25) : chipArea.containsMouse ? Qt.alpha(root.foreground, 0.12) : Qt.alpha(root.foreground, 0.06)

                  Text {
                    id: chipText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: root.tr(modelData)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: parent.current
                  }

                  MouseArea {
                    id: chipArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.filter = modelData
                  }
                }
              }
            }

            ListView {
              id: chatList
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              model: root.visibleChats
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              delegate: ChatRow {
                required property var modelData
                required property int index
                width: chatList.width
                chat: modelData
                avatarPath: root.avatarFor(modelData)
                hasCursor: index === root.selected
                foreground: root.foreground
                fontFamily: root.fontFamily
                nowMs: root.nowMs
                tr: root.tr
                fmt: root.fmt
                onHoveredRow: root.selected = index
                onActivated: root.openChat(modelData.jid)
              }

              Text {
                anchors.centerIn: parent
                visible: chatList.count === 0
                textFormat: Text.PlainText
                text: !wa.chatsLoaded ? root.tr("loading") : root.query !== "" || root.filter !== "all" ? root.tr("noMatches") : root.tr("noChats")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }

          // ---- conversation
          ColumnLayout {
            spacing: Style.space(6)

            ListView {
              id: thread
              Layout.fillWidth: true
              Layout.fillHeight: true
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              verticalLayoutDirection: ListView.BottomToTop
              spacing: Style.space(2)
              model: wa.messages
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              // Newest message sits at the bottom (index 0): when it is out of
              // view, a button jumps back to it.
              readonly property bool atNewest: count === 0 || indexAt(width / 2, contentY + height - Style.space(4)) <= 0
              onCountChanged: if (atNewest) positionViewAtBeginning()

              Rectangle {
                parent: thread
                visible: !thread.atNewest
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: Style.space(10)
                width: Style.space(36); height: width; radius: width / 2
                color: Commons.Color.popups.background
                border.width: 1
                border.color: Qt.alpha(root.foreground, 0.2)
                z: 10
                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: String.fromCodePoint(0xF0045)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: thread.positionViewAtBeginning()
                }
              }

              delegate: MessageItem {
                required property var modelData
                required property int index
                width: thread.width
                message: modelData
                older: index + 1 < wa.messages.length ? wa.messages[index + 1] : null
                unreadCount: wa.unreadAtOpen > 0 && index === Math.min(wa.unreadAtOpen, wa.messages.length) - 1 ? wa.unreadAtOpen : 0
                service: wa
                group: wa.activeChat ? wa.activeChat.group === true : false
                nowMs: root.nowMs
                tr: root.tr
                fmt: root.fmt
                foreground: root.foreground
                fontFamily: root.fontFamily
                onReplyRequested: function(message) {
                  root.editing = null
                  root.replyTo = message
                  composeField.forceActiveFocus()
                }
                onEditRequested: function(message) { root.startEdit(message) }
              }

              Text {
                anchors.centerIn: parent
                visible: thread.count === 0
                textFormat: Text.PlainText
                text: wa.messagesLoading ? root.tr("loading") : root.tr("noMessages")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            // Attachment waiting to be sent; the text field becomes its caption.
            Rectangle {
              visible: wa.staged !== null || wa.picking
              Layout.fillWidth: true
              Layout.preferredHeight: visible ? stagedRow.implicitHeight + Style.space(10) : 0
              radius: Style.cornerRadius
              color: Qt.alpha(root.foreground, 0.07)

              RowLayout {
                id: stagedRow
                anchors.fill: parent
                anchors.margins: Style.space(5)
                anchors.leftMargin: Style.space(10)
                spacing: Style.space(10)

                Image {
                  visible: wa.staged !== null && wa.staged.image
                  Layout.preferredWidth: Style.space(48)
                  Layout.preferredHeight: Style.space(48)
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  sourceSize.width: 96
                  source: wa.staged && wa.staged.image ? "file://" + wa.staged.path : ""
                }
                Text {
                  visible: !(wa.staged !== null && wa.staged.image)
                  textFormat: Text.PlainText
                  text: wa.picking ? Model.glyph("pending") : Model.glyph(wa.staged ? (wa.staged.kind === "document" ? "document" : wa.staged.kind) : "document")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: wa.picking ? root.tr("choosingFile") : (wa.staged ? wa.staged.name : "")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideMiddle
                  }
                  Text {
                    visible: wa.staged !== null
                    textFormat: Text.PlainText
                    text: wa.staged ? Model.fileSize(wa.staged.size) + " · " + root.tr("addCaption") : ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                PanelActionButton {
                  iconText: Model.glyph("close")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: wa.clearStaged()
                }
              }
            }

            // Editing one of your messages.
            Rectangle {
              visible: root.editing !== null
              Layout.fillWidth: true
              Layout.preferredHeight: visible ? editRow.implicitHeight + Style.space(10) : 0
              radius: Style.cornerRadius
              color: Qt.alpha(Commons.Color.accent, 0.12)

              RowLayout {
                id: editRow
                anchors.fill: parent
                anchors.margins: Style.space(5)
                anchors.leftMargin: Style.space(10)
                Text {
                  textFormat: Text.PlainText
                  text: Model.glyph("edit")
                  color: Commons.Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: root.tr("editingMessage")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                PanelActionButton {
                  iconText: Model.glyph("close")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: { root.editing = null; composeField.text = "" }
                }
              }
            }

            // Reply preview above the compose field.
            Rectangle {
              visible: root.replyTo !== null
              Layout.fillWidth: true
              Layout.preferredHeight: visible ? replyRow.implicitHeight + Style.space(10) : 0
              radius: Style.cornerRadius
              color: Qt.alpha(root.foreground, 0.07)

              Rectangle { width: 3; height: parent.height; radius: 1; color: Commons.Color.accent }

              RowLayout {
                id: replyRow
                anchors.fill: parent
                anchors.margins: Style.space(5)
                anchors.leftMargin: Style.space(12)

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0

                  Text {
                    textFormat: Text.PlainText
                    text: root.replyTo ? (root.replyTo.fromMe ? root.tr("you") : (root.replyTo.sender || Model.title(wa.activeChat, root.tr))) : ""
                    color: Commons.Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: root.replyTo ? Model.previewText({ kind: root.replyTo.kind, text: root.replyTo.text }, root.tr) : ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    maximumLineCount: 1
                  }
                }

                PanelActionButton {
                  iconText: Model.glyph("close")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.replyTo = null
                }
              }
            }

            // Recording a voice note replaces the compose row.
            Rectangle {
              visible: wa.recording
              Layout.fillWidth: true
              Layout.preferredHeight: visible ? recordRow.implicitHeight + Style.space(12) : 0
              radius: Style.cornerRadius
              color: Qt.alpha(Commons.Color.urgent, 0.12)

              Timer {
                interval: 500
                repeat: true
                running: wa.recording
                onTriggered: recordTime.seconds = Math.max(0, Math.floor(Date.now() / 1000 - wa.recordingStarted))
                onRunningChanged: recordTime.seconds = 0
              }

              RowLayout {
                id: recordRow
                anchors.verticalCenter: parent.verticalCenter
                x: Style.space(10)
                width: parent.width - Style.space(20)
                spacing: Style.space(10)

                Rectangle {
                  width: Style.space(10); height: width; radius: width / 2
                  color: Commons.Color.urgent
                  SequentialAnimation on opacity {
                    running: wa.recording
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.25; duration: Style.duration(600) }
                    NumberAnimation { to: 1; duration: Style.duration(600) }
                  }
                }
                Text {
                  id: recordTime
                  property int seconds: 0
                  textFormat: Text.PlainText
                  text: Model.duration(seconds)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: wa.micVolume >= 0 && wa.micVolume < 40 ? root.tr("micLow").replace("%1", wa.micVolume) : root.tr("recordingHint")
                  color: wa.micVolume >= 0 && wa.micVolume < 40 ? Commons.Color.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
                PanelActionButton {
                  iconText: Model.glyph("trash")
                  tooltipText: root.tr("cancel")
                  foreground: Commons.Color.urgent
                  fontFamily: root.fontFamily
                  onClicked: wa.recordStop(false)
                }
                PanelActionButton {
                  iconText: Model.glyph("send")
                  tooltipText: root.tr("send")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: wa.recordStop(true)
                }
              }
            }

            RowLayout {
              visible: !wa.recording
              Layout.fillWidth: true
              spacing: Style.space(8)

              PanelActionButton {
                visible: root.editing === null
                iconText: Model.glyph("attach")
                tooltipText: root.tr("attach")
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !wa.sending && !wa.picking
                onClicked: wa.pick()
              }

              TextField {
                id: composeField
                Layout.fillWidth: true
                foreground: root.foreground
                placeholderText: wa.sending ? root.tr("sending")
                  : wa.staged ? root.tr("captionPlaceholder") : root.tr("messagePlaceholder")
                enabled: !wa.sending && !root.profileOpen
                onAccepted: if (!root.profileOpen) root.send()
                onTextChanged: if (text !== "" && root.editing === null) wa.typing()
                // Ctrl+V with an image on the clipboard stages it as an attachment.
                Keys.onPressed: function(event) {
                  if (event.matches(StandardKey.Paste) && root.editing === null) wa.pasteImage()
                }
              }

              PanelActionButton {
                readonly property bool voice: composeField.text.trim() === "" && wa.staged === null && root.editing === null
                iconText: voice ? Model.glyph("mic") : Model.glyph(root.editing ? "sent" : "send")
                tooltipText: voice ? root.tr("recordVoice") : root.tr(root.editing ? "save" : "send")
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !wa.sending
                onClicked: voice ? wa.recordStart() : root.send()
              }
            }
          }

          // ---- contact / group info
          ProfilePage {
            id: profilePage
            service: wa
            chat: wa.activeChat
            tr: root.tr
            fmt: root.fmt
            foreground: root.foreground
            fontFamily: root.fontFamily
            onOpenChat: function(jid) { root.openChat(jid) }
          }

          // ---- first run: nothing to connect to yet
          ColumnLayout {
            spacing: Style.space(12)

            Item { Layout.fillHeight: true }

            Text {
              Layout.alignment: Qt.AlignHCenter
              textFormat: Text.PlainText
              text: Model.glyph("logo")
              color: Model.BRAND
              font.family: root.fontFamily
              font.pixelSize: Math.round(Style.font.display * 2.4)
            }
            Text {
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: root.tr("setupTitle")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              wrapMode: Text.Wrap
            }
            Text {
              Layout.fillWidth: true
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: wa.connection === "notConfigured" && wa.lastError
                ? root.tr("setupMissing").replace("%1", wa.lastError.detail) : root.tr("setupBody")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: commandRow.implicitHeight + Style.space(14)
              radius: Style.cornerRadius
              color: Qt.alpha(root.foreground, 0.07)
              RowLayout {
                id: commandRow
                anchors.verticalCenter: parent.verticalCenter
                x: Style.space(10)
                width: parent.width - Style.space(20)
                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: root.setupScript.replace(Quickshell.env("HOME"), "~")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideLeft
                }
                PanelActionButton {
                  iconText: Model.glyph("copy")
                  tooltipText: root.tr("copy")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: { Quickshell.execDetached(["wl-copy", "--", root.setupScript]); root.flash(root.tr("copied")) }
                }
              }
            }

            Row {
              Layout.alignment: Qt.AlignHCenter
              spacing: Style.space(8)
              Repeater {
                model: [
                  { label: root.tr("tryDemo"), action: "demo" },
                  { label: root.tr("serverGuide"), action: "guide" }
                ]
                Rectangle {
                  required property var modelData
                  width: setupText.implicitWidth + Style.space(24)
                  height: setupText.implicitHeight + Style.space(12)
                  radius: height / 2
                  color: setupArea.containsMouse ? Qt.alpha(Model.BRAND, 0.3) : Qt.alpha(Model.BRAND, 0.16)
                  Text {
                    id: setupText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: modelData.label
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                  MouseArea {
                    id: setupArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      if (modelData.action === "demo") Quickshell.execDetached(["omarchy", "bar", "set", root.moduleName, "accounts", "demo"])
                      else Qt.openUrlExternally("https://github.com/meliani/omarchy-lastseen#1-run-evolution-api")
                    }
                  }
                }
              }
            }

            Item { Layout.fillHeight: true }
          }
        }
      }
    }
  }
}
