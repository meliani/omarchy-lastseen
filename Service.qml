import QtQuick
import Quickshell
import Quickshell.Io

// State for the WhatsApp panel, fed by backend.py over JSON lines. The view
// only calls the functions below; it never talks to Evolution itself.
Item {
  id: root

  property var settings: ({})
  property string instanceName: ""             // the Evolution instance this account is
  property bool active: false                   // the account the panel is showing
  // Who this account is, from the backend: {name, phone, jid, avatar}.
  property var account: ({ name: "", phone: "", jid: "", avatar: "" })
  // backend.py sits beside this file, wherever the plugin is installed.
  readonly property string backendPath: decodeURIComponent(String(Qt.resolvedUrl("backend.py")).replace(/^file:\/\//, ""))
  readonly property var backendArgs: {
    var args = []
    var exchange = String(setting("amqpExchange", "")).trim()
    var country = String(setting("countryCode", "")).replace(/[^0-9]/g, "")
    if (exchange !== "") args.push("--exchange", exchange)
    if (country !== "") args.push("--country", country)
    return args
  }

  property string connection: "unknown"
  property bool listening: false
  property var chats: []
  property bool chatsLoaded: false

  property string activeJid: ""
  property var activeChat: null
  property var messages: []
  property bool moreMessages: false
  property bool messagesLoading: false
  property bool sending: false

  property var media: ({})       // message id -> {state, path, code}
  property var avatars: ({})     // jid -> local file path
  property string playingId: ""
  property var lastError: null   // {code, detail}

  property var profile: null     // last profile the backend sent, for the profile page
  property bool profileLoading: false
  property string inviteUrl: ""
  property var staged: null      // attachment waiting to be sent {path, name, size, kind, image}
  property bool picking: false
  property string notice: ""     // short confirmation ("Marked as unread")

  property var presence: ({ state: "", who: "", lastSeen: 0 })  // the open chat's other side
  property bool recording: false
  property int micVolume: -1        // % of the default mic while recording
  property int unreadAtOpen: 0     // for the "N unread messages" divider
  property real recordingStarted: 0

  signal incoming(var event)
  signal sent()
  signal opened(string jid)      // a new chat the backend found for a typed number
  signal done(string op, string jid)

  readonly property int unreadTotal: {
    var total = 0
    for (var i = 0; i < chats.length; i++) total += Number(chats[i].unread || 0)
    return total
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null || value === "" ? fallback : value
  }

  function command(payload) {
    if (backend.running) backend.write(JSON.stringify(payload) + "\n")
  }

  function refresh() { command({ op: "refresh" }) }
  property bool panelVisible: false
  function setVisible(open) { panelVisible = open; command({ op: "visible", open: open }) }
  function more() { messagesLoading = true; command({ op: "more" }) }
  // Ids the user clicked: only their failures raise the banner; background
  // thumbnail fetches fail quietly (the bubble shows it).
  property var asked: ({})
  function ask(op, id) { asked[id] = true; command({ op: op, id: id }) }
  function play(id) { ask("play", id) }
  function view(id) { ask("view", id) }
  function download(id) { ask("download", id) }

  // Images without an embedded thumbnail (and stickers) are fetched once.
  function fetch(id) {
    if (!id || media[id]) return
    setMedia(id, { state: "loading" })
    command({ op: "fetch", id: id })
  }

  function openChat(jid) {
    var chat = null
    for (var i = 0; i < chats.length; i++) if (chats[i].jid === jid) chat = chats[i]
    if (recording && jid !== activeJid) recordStop(false)
    presence = { state: "", who: "", lastSeen: 0 }
    unreadAtOpen = chat ? Number(chat.unread || 0) : 0
    activeJid = jid
    activeChat = chat || { jid: jid, name: "", phone: "", group: jid.indexOf("@g.us") !== -1, avatar: "" }
    messages = []
    moreMessages = false
    messagesLoading = true
    command({ op: "open", jid: jid })
  }

  function closeChat() {
    if (activeJid === "") return
    recordStop(false)
    presence = { state: "", who: "", lastSeen: 0 }
    activeJid = ""
    activeChat = null
    messages = []
    command({ op: "close" })
  }

  function sendText(text, quotedId) {
    var trimmed = String(text || "").trim()
    if (trimmed === "" || activeJid === "" || sending) return false
    sending = true
    command({ op: "send", jid: activeJid, text: trimmed, quotedId: quotedId || "" })
    return true
  }

  function sendFile(caption, quotedId) {
    if (!staged || activeJid === "" || sending) return false
    sending = true
    command({ op: "sendFile", jid: activeJid, path: staged.path, caption: String(caption || ""), quotedId: quotedId || "" })
    staged = null
    return true
  }
  function pick() { picking = true; command({ op: "pick" }) }
  function pasteImage() { command({ op: "pasteImage" }) }
  function clearStaged() { staged = null }

  function loadProfile(jid) {
    if (!profile || profile.jid !== jid) profile = null
    profileLoading = true
    inviteUrl = ""
    command({ op: "profile", jid: jid })
  }
  function rename(jid, name) { command({ op: "rename", jid: jid, name: String(name || "") }) }
  function react(id, emoji) { command({ op: "react", id: id, emoji: emoji }) }
  function edit(id, text) {
    if (String(text || "").trim() === "" || sending) return false
    sending = true
    command({ op: "edit", id: id, text: String(text) })
    return true
  }
  function remove(id) { command({ op: "delete", id: id }) }
  function typing() { if (activeJid !== "") command({ op: "typing", jid: activeJid }) }
  function markUnread(jid) { command({ op: "unread", jid: jid }) }
  function block(jid, on) { command({ op: "block", jid: jid, block: on }) }
  function leave(jid) { command({ op: "leave", jid: jid }) }
  function invite(jid) { command({ op: "invite", jid: jid }) }
  function linkNumber(jid, number) { command({ op: "link", jid: jid, number: String(number || "") }) }
  function newChat(number) { command({ op: "newChat", number: String(number || "") }) }
  function recordStart() { if (activeJid !== "") { recording = true; recordingStarted = Date.now() / 1000; command({ op: "recordStart", jid: activeJid }) } }
  function recordStop(send) { if (recording) { recording = false; command({ op: "recordStop", send: send === true }) } }
  function sendConfig() {
    command({ op: "config", autoDownload: setting("autoDownload", true) !== false, appearOnline: setting("appearOnline", false) === true })
  }
  readonly property bool appearOnline: setting("appearOnline", false) === true
  onAppearOnlineChanged: sendConfig()

  function setMedia(id, value) {
    var copy = Object.assign({}, media)
    copy[id] = value
    media = copy
  }

  function handle(event) {
    switch (event.type) {
    case "status":
      if (event.connection !== undefined) connection = event.connection
      if (event.listener !== undefined) listening = event.listener
      break
    case "chats":
      chats = event.chats || []
      chatsLoaded = true
      for (var i = 0; i < chats.length; i++) if (chats[i].jid === activeJid) activeChat = chats[i]
      break
    case "messages":
      if (event.jid !== activeJid) break
      messages = event.messages || []
      moreMessages = event.more === true
      messagesLoading = false
      if (activeChat && (!activeChat.name || !activeChat.avatar)) {
        activeChat = Object.assign({}, activeChat, {
          name: activeChat.name || event.name || "",
          phone: activeChat.phone || event.phone || "",
          avatar: activeChat.avatar || event.avatar || ""
        })
      }
      break
    case "media":
      setMedia(event.id, { state: event.state, path: event.path || "", code: event.code || "" })
      if (event.state === "failed" && asked[event.id]) lastError = { code: event.code || "mediaFailed", detail: "" }
      if (event.state !== "loading") delete asked[event.id]
      break
    case "account":
      account = { name: event.name || "", phone: event.phone || "", jid: event.jid || "", avatar: event.avatar || account.avatar }
      break
    case "avatar":
      if (event.jid === account.jid) account = Object.assign({}, account, { avatar: event.path })
      var copy = Object.assign({}, avatars)
      copy[event.jid] = event.path
      avatars = copy
      break
    case "playing":
      playingId = event.id || ""
      break
    case "sent":
      sending = false
      sent()
      break
    case "incoming":
      incoming(event)
      break
    case "profile":
      profile = event.profile || null
      profileLoading = false
      break
    case "invite":
      if (profile && event.jid === profile.jid) inviteUrl = event.url || ""
      break
    case "staged":
      picking = false
      if (event.path) staged = { path: event.path, name: event.name || "", size: event.size || 0, kind: event.kind || "document", image: event.image === true }
      break
    case "opened":
      opened(event.jid)
      break
    case "done":
      done(event.op, event.jid)
      break
    case "presence":
      if (event.jid === activeJid) {
        presence = { state: event.state || "", who: event.who || "", lastSeen: event.lastSeen || presence.lastSeen || 0 }
        presenceClear.restart()
      }
      break
    case "recording":
      recording = event.state === "recording"
      if (event.started) recordingStarted = event.started
      if (event.micVolume !== undefined) micVolume = event.micVolume
      break
    case "error":
      sending = false
      messagesLoading = false
      profileLoading = false
      picking = false
      lastError = { code: event.code || "api", detail: event.detail || "" }
      break
    }
  }

  Process {
    id: backend
    command: ["python3", "-u", root.backendPath, root.instanceName].concat(root.backendArgs)
    stdinEnabled: true
    // After a restart, tell the new backend what the panel is showing.
    onRunningChanged: if (running) Qt.callLater(function() {
      root.sendConfig()
      if (root.panelVisible) root.command({ op: "visible", open: true })
      if (root.activeJid !== "") root.command({ op: "open", jid: root.activeJid })
    })
    stdout: SplitParser {
      onRead: function(line) {
        var event
        try { event = JSON.parse(line) } catch (e) { return }
        if (event && typeof event === "object") root.handle(event)
      }
    }
    stderr: SplitParser {
      onRead: function(line) { console.warn(String(line).slice(0, 400)) }
    }
    onExited: {
      root.listening = false
      root.connection = "unknown"
      root.sending = false
      restart.interval = Math.min(restart.interval * 2, 60000)
      restart.start()
    }
  }

  // The backend restarts itself only if something killed it; back off so a
  // broken setup (missing secret, no python-pika) doesn't spin.
  Timer {
    id: restart
    interval: 2500
    onTriggered: backend.running = true
  }

  Timer {
    interval: 120000
    running: backend.running
    repeat: true
    onTriggered: restart.interval = 2500
  }

  // "typing…" that never got its "paused" fades after a while.
  Timer {
    id: presenceClear
    interval: 25000
    onTriggered: if (root.presence.state === "composing" || root.presence.state === "recording")
      root.presence = { state: "paused", who: "", lastSeen: root.presence.lastSeen }
  }

  property bool started: false
  Component.onCompleted: { started = true; if (instanceName !== "") backend.running = true }
  // A renamed account restarts its backend (the old one exits on stdin close).
  onInstanceNameChanged: if (started) {
    backend.running = false
    chats = []; chatsLoaded = false; closeChat()
    if (instanceName !== "") Qt.callLater(function() { backend.running = true })
  }
}
