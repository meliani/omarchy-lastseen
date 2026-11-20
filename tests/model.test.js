const assert = require("assert")
const M = require("../Model.js")
const t = k => k
const fmt = (d, p) => p
const now = new Date(2026, 10, 19, 23, 0).getTime()
const ts = (y, mo, d, h) => Math.floor(new Date(y, mo, d, h).getTime() / 1000)

assert.strictEqual(M.initialOf("  alex"), "A")
assert.strictEqual(M.initialOf("✨ Hiba"), "H")
assert.strictEqual(M.initialOf("+212 6"), "2")
assert.strictEqual(M.initialOf(""), "#")
assert.strictEqual(M.title({ name: "", phone: "+212 6" }, t), "+212 6")
assert.strictEqual(M.title({ name: "", phone: "" }, t), "unknownContact")

const chats = [
  { name: "Élodie", phone: "+33 6", unread: 2, group: false, preview: { text: "salut" } },
  { name: "PFE 2026", phone: "", unread: 0, group: true, preview: { text: "forms" } },
  { name: "", phone: "+212 6 00 00 01 23", unread: 0, group: false, preview: { text: "" } },
]
assert.deepStrictEqual(M.filterChats(chats, "elodie", "all").length, 1)
assert.deepStrictEqual(M.filterChats(chats, "", "unread").map(c => c.name), ["Élodie"])
assert.deepStrictEqual(M.filterChats(chats, "", "groups").map(c => c.name), ["PFE 2026"])
assert.strictEqual(M.filterChats(chats, "060000012", "all").length, 1)
assert.strictEqual(M.filterChats(chats, "FORMS", "all").length, 1)

assert.strictEqual(M.chatTime(ts(2026, 10, 19, 14), now, t, fmt), "HH:mm")
assert.strictEqual(M.chatTime(ts(2026, 10, 18, 14), now, t, fmt), "yesterday")
assert.strictEqual(M.chatTime(ts(2026, 10, 15, 14), now, t, fmt), "ddd")
assert.strictEqual(M.chatTime(ts(2026, 9, 1, 14), now, t, fmt), "dd/MM/yy")
assert.strictEqual(M.dayLabel(ts(2026, 10, 19, 1), now, t, fmt), "today")
assert.ok(M.sameDay(ts(2026, 10, 19, 1), ts(2026, 10, 19, 22)))
assert.ok(!M.sameDay(ts(2026, 10, 18, 23), ts(2026, 10, 19, 0)))

assert.strictEqual(M.duration(71), "1:11")
assert.strictEqual(M.fileSize(50176), "50 KB")
assert.strictEqual(M.fileSize(2020787), "2.0 MB")
assert.ok(M.previewText({ kind: "image", text: "" }, t).endsWith(" photo"))
assert.strictEqual(M.previewText({ kind: "text", text: "hi" }, t), "hi")
assert.strictEqual(M.tick("read"), M.glyph("delivered"))
assert.strictEqual(M.mapUrl("x", 1), "")
console.log("model tests ok")
assert.strictEqual(M.phoneQuery("06 74 06 41 66"), "06 74 06 41 66")
assert.strictEqual(M.phoneQuery("+33 6 12"), "")
assert.strictEqual(M.phoneQuery("Alex"), "")
console.log("phone query ok")
{
  const t = k => ({ typing: "typing…", isTyping: "%1 is typing…", online: "online", lastSeen: "last seen %1 at %2", today: "today",
    yesterday: "yesterday", viewOncePhoto: "View-once photo", photo: "Photo", recordingAudio: "recording…", isRecording: "%1 is recording…" })[k] || k
  const fmt = (d, p) => p === "HH:mm" ? "14:05" : "3 Nov"
  const now = Date.UTC(2026, 10, 20, 12, 0, 0)
  assert.strictEqual(M.presenceText({ state: "composing", who: "" }, false, t, fmt, now), "typing…")
  assert.strictEqual(M.presenceText({ state: "composing", who: "Sara" }, true, t, fmt, now), "Sara is typing…")
  assert.strictEqual(M.presenceText({ state: "available" }, false, t, fmt, now), "online")
  assert.strictEqual(M.presenceText({ state: "available" }, true, t, fmt, now), "")
  assert.strictEqual(M.presenceText({ state: "unavailable", lastSeen: now / 1000 - 60 }, false, t, fmt, now), "last seen today at 14:05")
  assert.ok(M.previewText({ kind: "viewOnce", media: "image" }, t).endsWith("View-once photo"))
  assert.ok(M.previewText({ kind: "text", text: "hi", deleted: true }, t).endsWith(" hi"))
  console.log("presence ok")
}
{
  const L = M.linkify("see https://a.com/x?y=1&z=2, ok\n<img src=x> www.b.ma", "#5af")
  assert.ok(L.includes('<a href="https://a.com/x?y=1&amp;z=2">https://a.com/x?y=1&amp;z=2</a>, ok<br>'), L)
  assert.ok(L.includes("&lt;img src=x&gt;") && !L.includes("<img"), L)
  assert.ok(L.includes('<a href="https://www.b.ma"'), L)
  assert.ok(!M.linkify('"><a href="javascript:x">', "#fff").includes('<a href="javascript'))
  assert.ok(M.linkify("javascript:alert(1)", "#fff").indexOf("<a") === -1)
  assert.ok(M.hasLink("go to www.x.com") && !M.hasLink("no link here"))
  assert.ok(M.emojiOnly("😂") && M.emojiOnly("👍🏽 ❤️") && M.emojiOnly("🇲🇦"))
  assert.ok(!M.emojiOnly("ok 😂") && !M.emojiOnly("😂😂😂😂") && !M.emojiOnly("") && !M.emojiOnly("123"))
  console.log("links/emoji ok")
}
