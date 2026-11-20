// Pure helpers for the WhatsApp panel. QML passes its translator `t` and a
// date formatter `fmt(date, pattern)`; the node test passes stubs.

var GLYPH = {
  logo: 0xF1173, search: 0xF0349, back: 0xF004D, refresh: 0xF0450, send: 0xF048A,
  reply: 0xF045A, copy: 0xF018F, close: 0xF0156, play: 0xF040A, stop: 0xF04DB,
  document: 0xF0219, location: 0xF034E, contact: 0xF0004, group: 0xF0849, audio: 0xF036C,
  image: 0xF02E9, video: 0xF0567, sticker: 0xF0785, poll: 0xF041F, sent: 0xF012C,
  delivered: 0xF012D, pending: 0xF0150, download: 0xF01DA, alert: 0xF05D6,
  imageOff: 0xF11D1, more: 0xF0143, react: 0xF01F2, edit: 0xF03EB, trash: 0xF09E7,
  attach: 0xF03E2, block: 0xF12DF, leave: 0xF0343, unread: 0xF0B92,
  link: 0xF0339, info: 0xF02FD, phone: 0xF03F2, admin: 0xF088F, newChat: 0xF0653,
  web: 0xF059F, email: 0xF01F0, place: 0xF07D9, business: 0xF0814, rename: 0xF06BC,
  calendar: 0xF00ED, paste: 0xF0192, deleted: 0xF073A, viewOnce: 0xF0CA1, mic: 0xF036C, rec: 0xF044A
}

// Message text as StyledText: everything escaped, then only http(s) links
// turned into anchors. Nothing from the message can become markup.
function escapeHtml(text) {
  return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}

var URL_RE = /\b(https?:\/\/[^\s<>"]+|www\.[^\s<>"]+\.[a-z]{2,}[^\s<>"]*)/gi

function linkify(text) {
  var raw = String(text || "")
  var out = "", last = 0, m
  URL_RE.lastIndex = 0
  while ((m = URL_RE.exec(raw)) !== null) {
    var url = m[0].replace(/[.,;:!?)\]]+$/, "")
    out += escapeHtml(raw.slice(last, m.index))
    var href = /^https?:\/\//i.test(url) ? url : "https://" + url
    out += '<a href="' + escapeHtml(href) + '">' + escapeHtml(url) + "</a>"
    last = m.index + url.length
    URL_RE.lastIndex = last
  }
  out += escapeHtml(raw.slice(last))
  return out.replace(/\n/g, "<br>")
}

function hasLink(text) {
  URL_RE.lastIndex = 0
  return URL_RE.test(String(text || ""))
}

// One to three emoji and nothing else: shown large, like WhatsApp.
function emojiOnly(text) {
  var t = String(text || "").replace(/\s/g, "")
  if (t === "" || t.length > 24) return false
  var count = 0
  for (var i = 0; i < t.length; ) {
    var cp = t.codePointAt(i)
    i += cp > 0xFFFF ? 2 : 1
    if (cp === 0x200D || (cp >= 0xFE00 && cp <= 0xFE0F) || (cp >= 0x1F3FB && cp <= 0x1F3FF) || (cp >= 0xE0020 && cp <= 0xE007F)) continue
    if (cp < 0x2190 || (cp >= 0x3000 && cp < 0x1F000 && !(cp >= 0x2600 && cp <= 0x27BF))) return false
    if (!(cp >= 0x1F1E6 && cp <= 0x1F1FF)) count++
    else if (i < t.length && t.codePointAt(i) >= 0x1F1E6 && t.codePointAt(i) <= 0x1F1FF) { i += 2; count++ }
  }
  return count >= 1 && count <= 3
}

// Brand: a mint green of our own, and dark ink for text on it.
var BRAND = "#2fd59b"
var BRAND_INK = "#08241a"

var REACTIONS = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

// A query that is a phone number someone could be messaged on.
function phoneQuery(text) {
  var raw = String(text || "").trim()
  if (!/^[+0-9][0-9 ().-]*$/.test(raw)) return ""
  var digits = raw.replace(/[^0-9]/g, "")
  return digits.length >= 8 && digits.length <= 15 ? raw : ""
}

function glyph(name) {
  return GLYPH[name] ? String.fromCodePoint(GLYPH[name]) : ""
}

function initialOf(name) {
  var text = String(name || "")
  for (var i = 0; i < text.length; i++) {
    var ch = String.fromCodePoint(text.codePointAt(i))
    if (ch.toLowerCase() !== ch.toUpperCase() || /[0-9]/.test(ch)) return ch.toUpperCase()
  }
  return "#"
}

function title(chat, t) {
  if (!chat) return ""
  return chat.name || chat.phone || t("unknownContact")
}

function fold(text) {
  var value = String(text || "").toLowerCase()
  try { value = value.normalize("NFD").replace(/[̀-ͯ]/g, "") } catch (e) {}
  return value
}

function matches(chat, query, filter) {
  if (filter === "unread" && !(chat.unread > 0)) return false
  if (filter === "groups" && !chat.group) return false
  var q = fold(query).trim()
  if (q === "") return true
  var digits = q.replace(/[^0-9]/g, "")
  var haystack = fold([chat.name, chat.phone, chat.preview ? chat.preview.text : ""].join(" "))
  if (haystack.indexOf(q) !== -1) return true
  // "06 74…" (local) should find "+212 6 74…" (international).
  var local = digits.replace(/^0+/, "")
  return local.length >= 3 && String(chat.phone || "").replace(/[^0-9]/g, "").indexOf(local) !== -1
}

function filterChats(chats, query, filter) {
  var out = []
  for (var i = 0; i < chats.length; i++) if (matches(chats[i], query, filter)) out.push(chats[i])
  return out
}

function startOfDay(ms) {
  var d = new Date(ms)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

function daysAgo(ts, nowMs) {
  return Math.round((startOfDay(nowMs) - startOfDay(ts * 1000)) / 86400000)
}

function sameDay(a, b) {
  return startOfDay(a * 1000) === startOfDay(b * 1000)
}

// Chat list: 14:05 today, "Yesterday", a weekday this week, else a short date.
function chatTime(ts, nowMs, t, fmt) {
  if (!ts) return ""
  var days = daysAgo(ts, nowMs)
  var date = new Date(ts * 1000)
  if (days <= 0) return fmt(date, "HH:mm")
  if (days === 1) return t("yesterday")
  if (days < 7) return fmt(date, "ddd")
  return fmt(date, "dd/MM/yy")
}

function dayLabel(ts, nowMs, t, fmt) {
  var days = daysAgo(ts, nowMs)
  if (days <= 0) return t("today")
  if (days === 1) return t("yesterday")
  return fmt(new Date(ts * 1000), days < 7 ? "dddd" : "d MMMM yyyy")
}

function duration(seconds) {
  var s = Math.max(0, Math.round(Number(seconds) || 0))
  var m = Math.floor(s / 60)
  s = s % 60
  return m + ":" + (s < 10 ? "0" : "") + s
}

function fileSize(bytes) {
  var n = Number(bytes) || 0
  if (n <= 0) return ""
  if (n < 1000) return n + " B"
  if (n < 1000000) return Math.round(n / 1000) + " KB"
  return (n / 1000000).toFixed(1) + " MB"
}

// One line describing a message: its text, or a glyph + label for media.
function previewText(preview, t) {
  if (!preview) return ""
  var labels = {
    image: ["image", "photo"], video: ["video", "video"], audio: ["audio", "voiceMessage"],
    document: ["document", "document"], sticker: ["sticker", "sticker"], location: ["location", "location"],
    contact: ["contact", "contact"], poll: ["poll", "poll"], unsupported: ["alert", "unsupportedShort"],
    deleted: ["deleted", "messageDeleted"]
  }
  var mark = preview.deleted ? glyph("deleted") + " " : ""
  if (preview.kind === "viewOnce")
    return mark + glyph("viewOnce") + " " + t(preview.media === "video" ? "viewOnceVideo" : preview.media === "audio" ? "viewOnceAudio" : "viewOncePhoto")
  var entry = labels[preview.kind]
  if (!entry) return mark + (preview.text || "")
  return mark + glyph(entry[0]) + " " + (preview.text || t(entry[1]))
}

// Header line for the other side of the open chat, "" when nothing to say.
function presenceText(presence, group, t, fmt, nowMs) {
  if (!presence) return ""
  var who = presence.who ? presence.who + " " : ""
  if (presence.state === "composing") return group && who ? t("isTyping").replace("%1", presence.who) : t("typing")
  if (presence.state === "recording") return group && who ? t("isRecording").replace("%1", presence.who) : t("recordingAudio")
  if (group) return ""
  if (presence.state === "available") return t("online")
  if (presence.lastSeen > 0) {
    var seen = new Date(presence.lastSeen * 1000)
    var now = new Date(nowMs)
    var day = sameDay(presence.lastSeen, nowMs / 1000) ? t("today")
      : sameDay(presence.lastSeen, nowMs / 1000 - 86400) ? t("yesterday") : fmt(seen, "d MMM")
    return t("lastSeen").replace("%1", day).replace("%2", fmt(seen, "HH:mm"))
  }
  return ""
}

function tick(status) {
  if (status === "pending") return glyph("pending")
  if (status === "error") return glyph("alert")
  if (status === "delivered" || status === "read") return glyph("delivered")
  if (status === "sent") return glyph("sent")
  return ""
}

function mapUrl(lat, lng) {
  var la = Number(lat), lo = Number(lng)
  if (!isFinite(la) || !isFinite(lo)) return ""
  return "https://www.openstreetmap.org/?mlat=" + la + "&mlon=" + lo + "#map=17/" + la + "/" + lo
}

if (typeof module !== "undefined") {
  module.exports = {
    BRAND: BRAND, BRAND_INK: BRAND_INK,
    linkify: linkify, hasLink: hasLink, emojiOnly: emojiOnly, escapeHtml: escapeHtml, presenceText: presenceText, phoneQuery: phoneQuery, REACTIONS: REACTIONS,
    glyph: glyph, initialOf: initialOf, title: title, matches: matches, filterChats: filterChats,
    sameDay: sameDay, chatTime: chatTime, dayLabel: dayLabel, duration: duration,
    fileSize: fileSize, previewText: previewText, tick: tick, mapUrl: mapUrl
  }
}
