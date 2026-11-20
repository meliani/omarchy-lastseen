"""Demo account for Last Seen: fictional chats, no server, nothing sent anywhere.

Set the account name to `demo` (`omarchy bar set meliani.lastseen accounts demo`)
to try the plugin, take screenshots, or work on the UI without Evolution API.
`demo-work` is a second, business account: `accounts "demo, demo-work"` shows
the account switcher.
"""
import base64
import colorsys
import json
import os
import struct
import sys
import threading
import time
import zlib

CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "lastseen", "demo")
_lock = threading.Lock()


def emit(kind, **fields):
    with _lock:
        try:
            sys.stdout.write(json.dumps({"type": kind, **fields}) + "\n")
            sys.stdout.flush()
        except BrokenPipeError:      # the shell went away
            os._exit(0)


def png(width, height, pixel):
    """A tiny PNG encoder: enough for demo pictures without any image library."""
    rows = b"".join(b"\x00" + bytes(c for x in range(width) for c in pixel(x, y)) for y in range(height))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))


def gradient(hue_a, hue_b, width=96, height=96):
    def pixel(x, y):
        t = (x + y) / (width + height)
        r, g, b = colorsys.hsv_to_rgb(hue_a + (hue_b - hue_a) * t, 0.55, 0.95)
        return int(r * 255), int(g * 255), int(b * 255)
    return png(width, height, pixel)


def sunset(width=240, height=160):
    def pixel(x, y):
        t = y / height
        if y > height * 0.72:                     # dark hills
            return 40, 52, 70
        sun = ((x - width * 0.62) ** 2 + (y - height * 0.62) ** 2) ** 0.5 < height * 0.16
        if sun:
            return 255, 214, 120
        r, g, b = colorsys.hsv_to_rgb(0.95 - 0.12 * t, 0.55, 0.98 - 0.25 * t)
        return int(r * 255), int(g * 255), int(b * 255)
    return png(width, height, pixel)


def avatar(name, hue_a, hue_b):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name + ".png")
    if not os.path.exists(path):
        with open(path, "wb") as f:
            f.write(gradient(hue_a, hue_b))
    return path


class Demo:
    def __init__(self, variant="demo"):
        now = int(time.time())
        self.work = variant.startswith("demo-work")
        self.now = now
        self.open_jid = ""
        photo = base64.b64encode(sunset()).decode()
        self.avatars = {
            "maya@demo": avatar("maya", 0.55, 0.80),
            "design@demo": avatar("design", 0.08, 0.15),
            "jordan@demo": avatar("jordan", 0.30, 0.45),
        }
        self.chats = [
            {"jid": "maya@demo", "name": "Maya Chen", "phone": "+1 555 010 0142", "group": False, "unread": 2,
             "ts": now - 120, "preview": {"kind": "text", "text": "See you at 7! 🎉"}, "fromMe": False, "sender": "", "status": ""},
            {"jid": "design@demo", "name": "Design Team", "phone": "", "group": True, "unread": 5,
             "ts": now - 900, "preview": {"kind": "text", "text": "Shipped the new icons 🚀"}, "fromMe": False, "sender": "Leo", "status": ""},
            {"jid": "dad@demo", "name": "Dad", "phone": "+1 555 010 0177", "group": False, "unread": 0,
             "ts": now - 3600, "preview": {"kind": "audio", "text": ""}, "fromMe": True, "sender": "", "status": "read"},
            {"jid": "jordan@demo", "name": "Jordan Blake", "phone": "+1 555 010 0199", "group": False, "unread": 0,
             "ts": now - 7200, "preview": {"kind": "image", "text": "Golden hour 🌅"}, "fromMe": False, "sender": "", "status": ""},
            {"jid": "hike@demo", "name": "Weekend Hike", "phone": "", "group": True, "unread": 0,
             "ts": now - 86400, "preview": {"kind": "location", "text": "Trailhead parking"}, "fromMe": False, "sender": "Ana", "status": ""},
            {"jid": "unknown@demo", "name": "", "phone": "+1 555 010 0123", "group": False, "unread": 1,
             "ts": now - 90000, "preview": {"kind": "text", "text": "Is the apartment still available?"}, "fromMe": False, "sender": "", "status": ""},
        ]
        if self.work:
            self.avatars = {"lina@demo": avatar("lina", 0.02, 0.10), "ops@demo": avatar("ops", 0.48, 0.58)}
            self.chats = [
                {"jid": "lina@demo", "name": "Lina Ortiz", "phone": "+1 555 010 0161", "group": False, "unread": 3,
                 "ts": now - 240, "preview": {"kind": "document", "text": "Quote_Q4.pdf"}, "fromMe": False, "sender": "", "status": ""},
                {"jid": "ops@demo", "name": "Ops — Night Shift", "phone": "", "group": True, "unread": 4,
                 "ts": now - 1300, "preview": {"kind": "text", "text": "Server back up ✅"}, "fromMe": False, "sender": "Kai", "status": ""},
                {"jid": "order@demo", "name": "", "phone": "+1 555 010 0188", "group": False, "unread": 0,
                 "ts": now - 5400, "preview": {"kind": "text", "text": "Your order #4821 has shipped"}, "fromMe": True, "sender": "", "status": "delivered"},
                {"jid": "front@demo", "name": "Front Desk", "phone": "", "group": True, "unread": 0,
                 "ts": now - 90000, "preview": {"kind": "audio", "text": ""}, "fromMe": False, "sender": "Mia", "status": ""},
            ]
        for chat in self.chats:
            chat["avatar"] = self.avatars.get(chat["jid"], "")
        m = lambda i, **kw: dict({"id": f"demo{i}", "fromMe": False, "sender": "", "senderJid": "", "status": "",
                                   "reactions": [], "quote": None, "media": "", "deleted": False, "edited": False,
                                   "editable": False, "mentionsMe": False, "kind": "text", "text": ""}, **kw)
        self.messages = {"maya@demo": [
            m(1, ts=now - 86400 - 3000, text="Did you see the venue they picked?"),
            m(2, ts=now - 86400 - 2900, fromMe=True, status="read", text="Yes! https://example.com/the-loft looks amazing"),
            m(3, ts=now - 86400 - 2880, kind="image", thumb=photo, width=240, height=160, text="View from the roof last night",
              reactions=[{"emoji": "😍", "count": 2, "mine": True}]),
            m(4, ts=now - 1800, kind="audio", seconds=14, voice=True),
            m(5, ts=now - 1700, fromMe=True, status="read", text="Haha, I'll bring the playlist",
              quote={"kind": "audio", "text": ""}),
            m(6, ts=now - 600, text="Booked a table for 4", deleted=True),
            m(7, ts=now - 300, text="🎉"),
            m(8, ts=now - 120, text="See you at 7! 🎉", reactions=[{"emoji": "👍", "count": 1, "mine": True}]),
        ]}

    def chat(self, jid):
        return next((c for c in self.chats if c["jid"] == jid), None)

    def send_chats(self):
        emit("chats", chats=sorted(self.chats, key=lambda c: c["ts"], reverse=True))

    def send_messages(self, jid):
        chat = self.chat(jid) or {}
        items = sorted(self.messages.get(jid, []), key=lambda x: x["ts"], reverse=True)
        emit("messages", jid=jid, name=chat.get("name", ""), phone=chat.get("phone", ""), group=chat.get("group", False),
             avatar=chat.get("avatar", ""), messages=items, more=False)

    def run(self):
        emit("status", connection="open", listener=True)
        if self.work:
            emit("account", name="Rivera Studio", phone="+1 555 010 0200", jid="work@demo", avatar=avatar("studio", 0.12, 0.02))
        else:
            emit("account", name="Sam Rivera", phone="+1 555 010 0100", jid="me@demo", avatar=avatar("sam", 0.62, 0.70))
        self.send_chats()
        for line in sys.stdin:
            try:
                cmd = json.loads(line)
            except ValueError:
                continue
            op, jid = cmd.get("op"), str(cmd.get("jid") or "")
            if op == "open":
                self.open_jid = jid
                chat = self.chat(jid)
                if chat:
                    chat["unread"] = 0
                self.send_messages(jid)
                self.send_chats()
                if jid == "maya@demo":
                    emit("presence", jid=jid, state="composing", who="", lastSeen=0)
            elif op == "close":
                self.open_jid = ""
            elif op in ("refresh", "visible"):
                self.send_chats()
            elif op == "send" and self.chat(jid):
                text = str(cmd.get("text") or "")[:4000]
                now = int(time.time())
                self.messages.setdefault(jid, []).append({"id": f"sent{now}", "fromMe": True, "ts": now, "sender": "",
                    "senderJid": "", "status": "sent", "reactions": [], "quote": None, "media": "", "deleted": False,
                    "edited": False, "editable": True, "mentionsMe": False, "kind": "text", "text": text})
                chat = self.chat(jid)
                chat.update(ts=now, preview={"kind": "text", "text": text}, fromMe=True, status="sent")
                emit("sent", jid=jid)
                self.send_messages(jid)
                self.send_chats()
            elif op == "profile":
                chat = self.chat(jid) or {}
                emit("profile", profile={"jid": jid, "group": chat.get("group", False), "name": chat.get("name", ""),
                     "phone": chat.get("phone", ""), "localName": "", "avatar": chat.get("avatar", ""),
                     "about": "Coffee, film cameras and long walks.", "aboutSince": 0, "lid": "", "linkedLid": ""})
            elif op == "react":
                for items in self.messages.values():
                    for item in items:
                        if item["id"] == cmd.get("id"):
                            item["reactions"] = [{"emoji": cmd.get("emoji", "👍"), "count": 1, "mine": True}]
                if self.open_jid:
                    self.send_messages(self.open_jid)
            elif op in ("recordStart",):
                emit("recording", state="recording", started=time.time(), micVolume=-1)
            elif op in ("recordStop",):
                emit("recording", state="idle")
            elif op == "pick":
                emit("staged", path="")
