#!/usr/bin/env python3
"""Last Seen — backend of the Omarchy bar plugin for WhatsApp through Evolution API.

One long-running process per account (started by Service.qml). It talks to a
self-hosted Evolution API over REST, optionally listens to Evolution's RabbitMQ
event stream for instant updates (it polls otherwise), keeps names and avatars
cached, and speaks JSON lines with the shell:

  stdin, one command per line:
    {"op": "refresh"} {"op": "visible", "open": bool}
    {"op": "open", "jid": J} {"op": "close"} {"op": "more"}
    {"op": "send", "jid": J, "text": T, "quotedId": ID|""}
    {"op": "play", "id": ID} {"op": "view", "id": ID}
    {"op": "download", "id": ID} {"op": "fetch", "id": ID}
    {"op": "profile", "jid": J} {"op": "rename", "jid": J, "name": N}
    {"op": "react", "id": ID, "emoji": E} {"op": "edit", "id": ID, "text": T}
    {"op": "delete", "id": ID} {"op": "typing", "jid": J}
    {"op": "unread", "jid": J} {"op": "block", "jid": J, "block": bool}
    {"op": "leave", "jid": J} {"op": "invite", "jid": J}
    {"op": "newChat", "number": N} {"op": "pick"} {"op": "pasteImage"}
    {"op": "sendFile", "jid": J, "path": P, "caption": T, "quotedId": ID|""}
  stdout, one event per line:
    status, chats, messages, media, avatar, playing, incoming, sent, error,
    profile, invite, opened, staged, done

Usage: backend.py <instance> [--exchange NAME] [--country CODE]
       backend.py demo          (fake data, no server: for trying it out)
       backend.py --self-test

Secrets come from the desktop keyring through secret-tool, never from argv or
the environment (see scripts/setup.sh):
  service=lastseen key=url             https://evolution.example.com
  service=lastseen key=<slug>-token    the instance's API token ("My phone" -> my-phone-token)
  service=lastseen key=amqp-uri        optional: amqps://user:pass@host/vhost for instant push
"""
import base64
import hashlib
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

HOME = os.path.expanduser("~")
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME", HOME + "/.local/state"), "lastseen")
CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME", HOME + "/.cache"), "lastseen")
KEYRING_SERVICE = "lastseen"
MEDIA_DIR = os.path.join(CACHE_DIR, "media")
AVATAR_DIR = os.path.join(CACHE_DIR, "avatars")
DOWNLOAD_DIR = os.path.join(HOME, "Downloads", "WhatsApp")
QUEUE_PREFIX = "lastseen"     # one queue per account: two backends on one queue would split its events
EXCHANGE = "evolution"        # Evolution's RABBITMQ_EXCHANGE_NAME; --exchange overrides
COUNTRY = ""                  # calling code for local numbers ("06…" -> "2126…"); --country sets it
POLL_OPEN = 8                 # seconds between refreshes without RabbitMQ, panel open
POLL_CLOSED = 30              # … and closed (unread badge, notifications)
ROUTING_KEYS = ("messages.upsert", "messages.update", "connection.update", "presence.update")

PAGE = 60   # Evolution returns some messages twice, so a page shows ~half that
MAX_PAGE = 400
MAX_TEXT = 4000
MAX_THUMB = 120_000          # base64 chars of an embedded jpegThumbnail
MAX_MEDIA = 120 * 1024 * 1024
MAX_AVATAR = 1024 * 1024
MAX_UPLOAD = 64 * 1024 * 1024
PIC_LOOKUP_TTL = 86400       # re-ask WhatsApp for a lid's picture at most daily
EDIT_WINDOW = 15 * 60        # WhatsApp lets you edit your messages for 15 minutes
STAGE_DIR = os.path.join(CACHE_DIR, "outgoing")
PRESENCE_QUEUE_SUFFIX = ".presence.update"   # Evolution's per-instance queue
PRESENCE_KEEPALIVE = 240
MEDIA_BUDGET = 3 * 1024 ** 3                 # saved media kept on disk, oldest dropped first
PREFETCH_MAX = 32 * 1024 * 1024              # files saved on arrival up to this size
RECORD_MAX = 600                             # seconds of voice note
AVATAR_TTL = 3 * 86400
DIRECTORY_EVERY = 30 * 60
AVATAR_HOST = "https://pps.whatsapp.net/"
SELF_NAMES = {"você", "you", "vous", "tú", "tu"}
BASE64_RE = re.compile(r"^[A-Za-z0-9+/=\s]+$")
STATUS_RANK = {"ERROR": 0, "PENDING": 1, "SERVER_ACK": 2, "DELIVERY_ACK": 3, "READ": 4, "PLAYED": 5}
WRAPPERS = ("ephemeralMessage", "viewOnceMessage", "viewOnceMessageV2",
            "viewOnceMessageV2Extension", "documentWithCaptionMessage")


# --------------------------------------------------------------------- output

_out_lock = threading.Lock()


def emit(kind, **fields):
    line = json.dumps({"type": kind, **fields})
    with _out_lock:
        try:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            os._exit(0)


def log(msg):
    print(f"lastseen backend: {msg}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------- pure logic

def secret(key):
    out = subprocess.run(["secret-tool", "lookup", "service", KEYRING_SERVICE, "key", key],
                         capture_output=True, text=True, timeout=10)
    if out.returncode != 0 or not out.stdout.strip():
        raise NotConfigured(key)
    return out.stdout.strip()


class NotConfigured(RuntimeError):
    """A keyring secret is missing: run scripts/setup.sh."""


def has_secret(key):
    try:
        secret(key)
        return True
    except (NotConfigured, OSError, subprocess.SubprocessError):
        return False


def one_line(text, limit=200):
    text = " ".join(str(text or "").split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def valid_push(name, me=""):
    """A profile name worth showing: Evolution sometimes stores the account's
    own name ("Você", or the account's profile name) on history-synced incoming messages."""
    name = str(name or "").strip()
    if not name or name.lower() in SELF_NAMES or (me and name == me):
        return ""
    if not re.search(r"[^\W\d_]", name):
        return ""
    return name[:80]


def format_phone(jid):
    digits = str(jid or "").split("@")[0]
    if not jid.endswith("@s.whatsapp.net") or not digits.isdigit():
        return ""
    if digits.startswith("212") and len(digits) == 12:
        d = digits
        return f"+212 {d[3]} {d[4:6]} {d[6:8]} {d[8:10]} {d[10:12]}"
    return "+" + digits


def unwrap(message):
    view_once = False
    for _ in range(4):
        if not isinstance(message, dict):
            return {}
        for wrapper in WRAPPERS:
            inner = message.get(wrapper)
            if isinstance(inner, dict) and isinstance(inner.get("message"), dict):
                view_once = view_once or wrapper.startswith("viewOnce")
                message = inner["message"]
                break
        else:
            break
    return dict(message, _viewOnce=True) if view_once and isinstance(message, dict) else message


def safe_thumb(value):
    if isinstance(value, str) and 0 < len(value) <= MAX_THUMB and BASE64_RE.match(value):
        return value.replace("\n", "").replace(" ", "")
    return ""


def file_length(value):
    if isinstance(value, dict):
        return int(value.get("low") or 0)
    try:
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def context_of(message):
    for value in message.values():
        if isinstance(value, dict) and isinstance(value.get("contextInfo"), dict):
            return value["contextInfo"]
    return {}


def parse(message):
    """A WhatsApp `message` payload (already unwrapped) -> a display dict with a
    `kind`, or None when there is nothing to show (protocol/system payloads)."""
    if not isinstance(message, dict) or not message:
        return None
    for key, media in (("imageMessage", "image"), ("videoMessage", "video"), ("audioMessage", "audio")):
        inner = message.get(key)
        if isinstance(inner, dict) and (inner.get("viewOnce") or message.get("_viewOnce")):
            # WhatsApp strips view-once media (no url, no key) before it reaches linked devices.
            return {"kind": "viewOnce", "media": media, "text": ""}
    if "conversation" in message:
        return {"kind": "text", "text": str(message["conversation"])[:MAX_TEXT]}
    ext = message.get("extendedTextMessage")
    if isinstance(ext, dict):
        return {"kind": "text", "text": str(ext.get("text") or "")[:MAX_TEXT]}
    image = message.get("imageMessage")
    if isinstance(image, dict):
        return {"kind": "image", "text": str(image.get("caption") or "")[:MAX_TEXT],
                "thumb": safe_thumb(image.get("jpegThumbnail")),
                "width": int(image.get("width") or 0), "height": int(image.get("height") or 0)}
    video = message.get("videoMessage")
    if isinstance(video, dict):
        return {"kind": "video", "text": str(video.get("caption") or "")[:MAX_TEXT],
                "thumb": safe_thumb(video.get("jpegThumbnail")),
                "seconds": int(video.get("seconds") or 0),
                "width": int(video.get("width") or 0), "height": int(video.get("height") or 0)}
    audio = message.get("audioMessage")
    if isinstance(audio, dict):
        return {"kind": "audio", "text": "", "seconds": int(audio.get("seconds") or 0),
                "voice": bool(audio.get("ptt"))}
    doc = message.get("documentMessage")
    if isinstance(doc, dict):
        return {"kind": "document", "text": str(doc.get("caption") or "")[:MAX_TEXT],
                "fileName": os.path.basename(str(doc.get("fileName") or doc.get("title") or "file"))[:200],
                "size": file_length(doc.get("fileLength")),
                "thumb": safe_thumb(doc.get("jpegThumbnail"))}
    sticker = message.get("stickerMessage")
    if isinstance(sticker, dict):
        return {"kind": "sticker", "text": ""}
    for key in ("locationMessage", "liveLocationMessage"):
        loc = message.get(key)
        if isinstance(loc, dict):
            return {"kind": "location", "text": one_line(loc.get("name") or loc.get("address") or "", 120),
                    "lat": float(loc.get("degreesLatitude") or 0), "lng": float(loc.get("degreesLongitude") or 0)}
    contact = message.get("contactMessage")
    if isinstance(contact, dict):
        return {"kind": "contact", "text": one_line(contact.get("displayName"), 80)}
    contacts = message.get("contactsArrayMessage")
    if isinstance(contacts, dict):
        return {"kind": "contact", "text": one_line(contacts.get("displayName"), 80)}
    for key in ("pollCreationMessage", "pollCreationMessageV2", "pollCreationMessageV3"):
        poll = message.get(key)
        if isinstance(poll, dict):
            options = [one_line(o.get("optionName"), 80) for o in poll.get("options") or [] if isinstance(o, dict)]
            return {"kind": "poll", "text": one_line(poll.get("name"), 200), "options": options[:12]}
    if "reactionMessage" in message:
        return {"kind": "reaction"}
    ignorable = {"_viewOnce", "protocolMessage", "senderKeyDistributionMessage", "messageContextInfo",
                 "pollUpdateMessage", "keepInChatMessage", "pinInChatMessage", "editedMessage"}
    meaningful = [k for k in message if k not in ignorable]
    if not meaningful:
        return None
    return {"kind": "unsupported", "text": meaningful[0]}


def is_deleted(record):
    key = record.get("key") or {}
    return bool(key.get("deleted")) or any((u or {}).get("status") == "DELETED" for u in record.get("MessageUpdate") or [])


def sender_jid(record):
    """Who sent a group message. Evolution 2.3.7 often stores no participant
    and puts the sender's lid number in pushName instead."""
    key = record.get("key") or {}
    participant = str(key.get("participant") or key.get("participantAlt") or "")
    if participant:
        return participant
    push = str(record.get("pushName") or "")
    return push + "@lid" if push.isdigit() and len(push) > 6 else ""


def own_lid(groups):
    """fetchAllGroups lists only the groups you are in, so the one
    participant found in nearly all of them is you."""
    lists = [{str(p.get("id") or "") for p in g.get("participants") or []} for g in groups if g.get("participants")]
    if len(lists) < 3:
        return ""
    counts = {}
    for members in lists:
        for jid in members:
            counts[jid] = counts.get(jid, 0) + 1
    jid, n = max(counts.items(), key=lambda kv: kv[1])
    return jid if jid.endswith("@lid") and n >= 0.8 * len(lists) else ""


def slug(instance):
    """'My phone' -> 'my-phone': the account's keyring key, queue and state file."""
    return re.sub(r"[^a-z0-9]+", "-", str(instance).lower()).strip("-") or "default"


def picture_id(url):
    """The file id inside a pps.whatsapp.net picture URL. It is the same for
    one person under their phone and their @lid address."""
    m = re.search(r"/(\d+_\d+_\d+)_n\.(?:jpg|jpeg|png)", str(url or ""))
    return m.group(1) if m else ""


def phone_digits(text):
    """A typed phone number as WhatsApp digits: '+33 6 12 34 56 78' -> 33612345678;
    with --country 212, the local '06 12 34 56 78' -> 212612345678."""
    digits = re.sub(r"\D", "", str(text or ""))
    if str(text or "").strip().startswith("00"):
        digits = digits[2:]
    elif COUNTRY and digits.startswith("0") and not digits.startswith("00"):
        digits = COUNTRY + digits[1:]         # a local number
    return digits if 8 <= len(digits) <= 15 else ""


def media_type(mime):
    head = str(mime or "").split("/")[0]
    return head if head in ("image", "video", "audio") else "document"


def preview(parsed):
    """Compact form for the chat list, quotes and notifications."""
    if not parsed:
        return {"kind": "none", "text": ""}
    out = {"kind": parsed["kind"], "text": one_line(parsed.get("text", ""), 160)}
    if parsed.get("media"):
        out["media"] = parsed["media"]
    return out


def status_of(record, known=""):
    """Best delivery status of one of your messages. `known` is the best one
    seen live (messages.update), which Evolution never writes back into the
    chat list's copy of the last message."""
    best = record.get("status") if isinstance(record.get("status"), str) else ""
    if STATUS_RANK.get(known, -1) > STATUS_RANK.get(best, -1):
        best = known
    for update in record.get("MessageUpdate") or []:
        status = update.get("status") if isinstance(update, dict) else ""
        if STATUS_RANK.get(status, -1) > STATUS_RANK.get(best, -1):
            best = status
    return {"ERROR": "error", "PENDING": "pending", "SERVER_ACK": "sent", "DELIVERY_ACK": "delivered",
            "READ": "read", "PLAYED": "read"}.get(best, "sent")


def collect_reactions(records):
    """reactionMessage rows -> {targetId: [{emoji, count, mine}]}; the latest
    reaction of each sender wins and an empty one removes theirs."""
    latest = {}
    for rec in sorted(records, key=lambda r: int(r.get("messageTimestamp") or 0)):
        reaction = unwrap(rec.get("message")).get("reactionMessage")
        if not isinstance(reaction, dict):
            continue
        target = (reaction.get("key") or {}).get("id")
        key = rec.get("key") or {}
        sender = "me" if key.get("fromMe") else (key.get("participant") or key.get("remoteJid") or "?")
        if target:
            latest[(target, sender)] = str(reaction.get("text") or "")
    out = {}
    for (target, sender), emoji in latest.items():
        if not emoji:
            continue
        bucket = out.setdefault(target, {})
        entry = bucket.setdefault(emoji, {"emoji": emoji, "count": 0, "mine": False})
        entry["count"] += 1
        entry["mine"] = entry["mine"] or sender == "me"
    return {target: list(b.values()) for target, b in out.items()}


def media_error_code(error):
    text = str(error)
    if "Failed to fetch stream" in text or " 404 " in text or " 410 " in text or "no media" in text:
        return "mediaExpired"
    return "mediaFailed"


# ----------------------------------------------------------------- REST client

class ApiError(RuntimeError):
    pass


class Evolution:
    def __init__(self, instance):
        self.instance = instance
        self.base = secret("url").rstrip("/")
        self.token = secret(f"{slug(instance)}-token")

    def call(self, method, route, body=None, query=None, timeout=25, limit=16 * 1024 * 1024, scoped=True):
        url = f"{self.base}/{route}" + (f"/{urllib.parse.quote(self.instance)}" if scoped else "")
        if query:
            url += "?" + urllib.parse.urlencode(query)
        data = None if method == "GET" else json.dumps(body or {}).encode()
        request = urllib.request.Request(url, data=data, method=method, headers={
            "apikey": self.token,
            "Content-Type": "application/json",
            # Cloudflare in front of Evolution blocks urllib's own User-Agent (error 1010).
            "User-Agent": "curl/8.0",
        })
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                raw = response.read(limit + 1)
        except urllib.error.HTTPError as e:
            raise ApiError(f"{route} {e.code} {e.read(600).decode(errors='replace')}") from None
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            raise ApiError(f"{route} unreachable: {e}") from None
        if len(raw) > limit:
            raise ApiError(f"{route} response too large")
        return json.loads(raw.decode() or "null")

    def media(self, message_id):
        result = self.call("POST", "chat/getBase64FromMediaMessage",
                           {"message": {"key": {"id": message_id}}, "convertToMp4": False},
                           timeout=120, limit=MAX_MEDIA)
        data = (result or {}).get("base64") or ""
        if not data:
            raise ApiError("no media returned")
        name = os.path.basename(str((result or {}).get("fileName") or message_id))
        return base64.b64decode(data), name, str((result or {}).get("mimetype") or "")


# ------------------------------------------------------------------ directory

class Directory:
    """Who is who. Persisted, because Evolution 2.3.7 only learns WhatsApp's
    @lid <-> phone mapping piecemeal (group member lists, the odd message
    carrying remoteJidAlt): every mapping we ever see is kept."""

    def __init__(self, path=""):
        self.path = path
        self.lock = threading.Lock()
        self.names = {}      # phone jid -> contact name (Evolution's synced contacts)
        self.push = {}       # any jid -> profile name seen on incoming messages
        self.lid2pn = {}     # lid jid -> phone jid
        self.subjects = {}   # group jid -> subject
        self.avatars = {}    # jid -> https avatar url (current, not persisted)
        self.local = {}      # jid -> name the user gave (wins over everything)
        self.pics = {}       # picture file id -> phone jid
        self.looked = {}     # lid jid -> epoch of the last picture lookup
        self.links = {}      # lid jid -> phone jid the user said is the same person
        self.me = ""
        self.my_jids = set()
        self.dirty = False

    def load(self):
        if not self.path:
            return
        try:
            with open(self.path) as f:
                data = json.load(f)
        except (OSError, ValueError):
            return
        for field in ("names", "push", "lid2pn", "subjects", "local", "links"):
            if isinstance(data.get(field), dict):
                setattr(self, field, {str(k): str(v) for k, v in data[field].items()})
        # Names saved before the letter rule ("." , "+212…") are dropped.
        self.names = {k: v for k, v in self.names.items() if valid_push(v)}
        self.push = {k: v for k, v in self.push.items() if valid_push(v)}
        self.me = str(data.get("me") or "")
        self.my_jids |= {str(j) for j in data.get("myJids") or [] if isinstance(j, str)}
        if isinstance(data.get("looked"), dict):
            self.looked = {str(k): float(v) for k, v in data["looked"].items() if isinstance(v, (int, float))}

    def save(self):
        with self.lock:
            if not self.dirty or not self.path:
                return
            payload = {"names": self.names, "push": self.push, "lid2pn": self.lid2pn,
                       "subjects": self.subjects, "local": self.local, "looked": self.looked, "links": self.links, "me": self.me,
                       "myJids": sorted(self.my_jids)}
            self.dirty = False
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, self.path)

    def _set(self, table, key, value):
        if key and value and table.get(key) != value:
            table[key] = value
            self.dirty = True

    def map_lid(self, a, b):
        with self.lock:
            for lid, pn in ((a, b), (b, a)):
                if str(lid).endswith("@lid") and str(pn).endswith("@s.whatsapp.net"):
                    self._set(self.lid2pn, lid, pn)

    def learn_push(self, jid, name):
        name = valid_push(name, self.me)
        if jid and name and not jid.endswith("@g.us") and jid not in self.my_jids:
            with self.lock:
                self._set(self.push, jid, name)

    def learn_record(self, record):
        key = record.get("key") or {}
        self.map_lid(key.get("remoteJid"), key.get("remoteJidAlt"))
        self.map_lid(key.get("participant"), key.get("participantAlt"))
        if not key.get("fromMe"):
            sender = sender_jid(record) if str(key.get("remoteJid") or "").endswith("@g.us") else key.get("remoteJid")
            self.learn_push(sender, record.get("pushName"))

    def set_avatar(self, jid, url):
        if isinstance(url, str) and url.startswith(AVATAR_HOST):
            with self.lock:
                self.avatars[jid] = url
                pid = picture_id(url)
                if pid and jid.endswith("@s.whatsapp.net"):
                    self.pics[pid] = jid
            if jid.endswith("@lid") and pid:
                self.map_lid(jid, self.pics.get(pid, ""))

    def rename(self, jid, name):
        name = " ".join(str(name or "").split())[:80]
        with self.lock:
            if name:
                self._set(self.local, jid, name)
            elif self.local.pop(jid, None) is not None:
                self.dirty = True

    def phone_jid(self, jid):
        if jid.endswith("@s.whatsapp.net"):
            return jid
        with self.lock:
            return self.links.get(jid) or self.lid2pn.get(jid, "")

    def link(self, lid, pn):
        with self.lock:
            if pn:
                self._set(self.links, lid, pn)
            elif self.links.pop(lid, None) is not None:
                self.dirty = True

    def name(self, jid):
        if not jid:
            return ""
        with self.lock:
            if jid.endswith("@g.us"):
                return self.subjects.get(jid, "")
            pn = jid if jid.endswith("@s.whatsapp.net") else (self.links.get(jid) or self.lid2pn.get(jid, ""))
            lid = next((l for l, p in list(self.lid2pn.items()) + list(self.links.items()) if p == jid), "") if jid.endswith("@s.whatsapp.net") and not self.local.get(jid) else ""
            return (self.local.get(jid) or (self.local.get(pn) if pn else "") or (self.local.get(lid) if lid else "")
                    or (self.names.get(pn) if pn else "") or self.push.get(jid, "") or (self.push.get(pn, "") if pn else ""))

    def phone(self, jid):
        return format_phone(self.phone_jid(jid))

    def is_me(self, jid):
        return bool(jid) and (jid in self.my_jids or self.phone_jid(jid) in self.my_jids)

    def mentions(self, parsed, message):
        """'@10000000000004' in a message -> '@Alex'; and whether it names you."""
        jids = [str(j) for j in context_of(message).get("mentionedJid") or [] if isinstance(j, str)][:50]
        if not parsed or not jids:
            return False
        text, me = str(parsed.get("text") or ""), False
        for jid in jids:
            me = me or self.is_me(jid)
            label = (self.me or "you") if self.is_me(jid) else (self.name(jid) or self.phone(jid))
            if label:
                text = text.replace("@" + jid.split("@")[0], "@" + label)
        parsed["text"] = text
        return me


# --------------------------------------------------------------------- backend

class Backend:
    def __init__(self, instance):
        self.instance = instance
        self.api = Evolution(instance)
        self.slug = slug(instance)
        self.queue = f"{QUEUE_PREFIX}.{self.slug}"
        self.directory = Directory(os.path.join(STATE_DIR, f"directory-{self.slug}.json"))
        self.live = False            # RabbitMQ connected; polling otherwise
        self.last_poll = 0.0
        self.seen_last = None        # chat jid -> newest message id, to spot new ones when polling
        self.commands = queue.Queue()
        self.media_jobs = queue.Queue()
        self.avatar_jobs = queue.Queue()
        self.avatar_queued = set()
        self.lock = threading.Lock()
        self.open_jid = ""
        self.limit = PAGE
        self.panel_open = False
        self.dirty_chats = True
        self.dirty_messages = False
        self.mark_read = False
        self.last_chats = 0.0
        self.last_messages = 0.0
        self.aliases = {}            # shown chat jid -> every Evolution jid of that person
        self.keys = {}               # message id -> key, for quoting, reacting, editing
        self.last_keys = {}          # chat jid -> key of its newest message (mark unread)
        self.typing_at = {}          # chat jid -> when "typing…" was last sent
        self.chat_ids = []           # every chat jid, for lid picture lookups
        self.prefetch_jobs = queue.Queue()
        self.statuses = {}           # your message id -> best delivery status seen (ERROR…PLAYED)
        self.auto_download = True
        self.appear_online = False   # off: never "available", never "typing…"/"recording…"
        self.presence_target = ""    # chat we are "online" in (WhatsApp sends presence only then)
        self.presence_lock = threading.Lock()
        self.recorder = None         # ffmpeg recording a voice note
        self.record_path = ""
        self.record_jid = ""
        self.player = None
        self.player_id = ""

    # ---- lifecycle

    def run(self):
        for d in (STATE_DIR, MEDIA_DIR, AVATAR_DIR):
            os.makedirs(d, exist_ok=True)
        self.directory.load()
        emit("status", connection="unknown", listener=False)
        for target in (self.worker, self.media_worker, self.avatar_worker, self.directory_worker,
                       self.amqp_worker, self.lookup_worker, self.prefetch_worker, self.presence_worker):
            threading.Thread(target=target, daemon=True).start()
        def leave(*_):
            # Never leave the account "online" behind: the phone would stop notifying.
            with self.presence_lock:
                target = self.presence_target
            if target:
                try:
                    self.api.call("POST", "chat/sendPresence", {"number": self.directory.phone_jid(target) or target,
                                                                "presence": "unavailable", "delay": 100}, timeout=8)
                except ApiError:
                    pass
            if self.recorder:
                self.recorder.kill()
            os._exit(0)
        import signal
        signal.signal(signal.SIGTERM, leave)
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                command = json.loads(line)
            except ValueError:
                continue
            if isinstance(command, dict):
                op = command.get("op")
                if op in ("play", "view", "download", "fetch"):
                    self.media_jobs.put(command)
                elif op in ("pick", "pasteImage", "typing", "recordStart", "recordStop"):
                    # Waiting on a dialog or WhatsApp's typing delay must not hold the worker.
                    threading.Thread(target=self.side_command, args=(command,), daemon=True).start()
                else:
                    self.commands.put(command)
        leave()     # the shell went away (stdin closed)

    # ---- chats and messages (one thread, so REST calls never overlap)

    def worker(self):
        self.refresh_status()
        while True:
            try:
                self.handle(self.commands.get(timeout=0.25))
            except queue.Empty:
                pass
            except Exception as e:  # noqa: BLE001 - keep the loop alive, report to the shell
                emit("error", code="api", detail=one_line(e, 300))
            now = time.monotonic()
            with self.lock:
                if not self.live and now - self.last_poll > (POLL_OPEN if self.panel_open else POLL_CLOSED):
                    self.last_poll = now
                    self.dirty_chats = True
                    self.dirty_messages = bool(self.open_jid)
                want_chats = self.dirty_chats and now - self.last_chats > (1.0 if self.panel_open else 5.0)
                want_messages = self.dirty_messages and self.open_jid and now - self.last_messages > 0.5
            try:
                if want_messages:
                    self.refresh_messages()
                if want_chats:
                    self.refresh_chats()
            except Exception as e:  # noqa: BLE001
                emit("error", code="api", detail=one_line(e, 300))
                with self.lock:
                    self.last_chats = self.last_messages = now + 5

    def handle(self, command):
        op = command.get("op")
        if op == "refresh":
            self.refresh_status()
            with self.lock:
                self.dirty_chats = True
                self.dirty_messages = bool(self.open_jid)
                self.last_chats = 0
        elif op == "visible":
            with self.lock:
                self.panel_open = bool(command.get("open"))
                if self.panel_open:
                    self.dirty_chats = True
                    self.last_chats = 0
            self.update_presence()
        elif op == "open":
            jid = str(command.get("jid") or "")
            with self.lock:
                self.open_jid = jid
                self.limit = PAGE
                self.mark_read = True
                self.keys = {}
            self.update_presence()
            self.refresh_messages()
        elif op == "close":
            with self.lock:
                self.open_jid = ""
                self.dirty_messages = False
            self.update_presence()
        elif op == "more":
            with self.lock:
                self.limit = min(self.limit + PAGE, MAX_PAGE)
            self.refresh_messages()
        elif op == "send":
            self.send(str(command.get("jid") or ""), str(command.get("text") or ""), str(command.get("quotedId") or ""))
        elif op == "sendFile":
            self.send_file(str(command.get("jid") or ""), str(command.get("path") or ""),
                           str(command.get("caption") or ""), str(command.get("quotedId") or ""))
        elif op == "profile":
            self.profile(str(command.get("jid") or ""))
        elif op == "rename":
            jid = str(command.get("jid") or "")
            self.directory.rename(jid, command.get("name"))
            self.directory.save()
            self.touch_chats()
            self.profile(jid)
        elif op == "react":
            self.react(str(command.get("id") or ""), str(command.get("emoji") or ""))
        elif op == "edit":
            self.edit(str(command.get("id") or ""), str(command.get("text") or ""))
        elif op == "delete":
            self.delete(str(command.get("id") or ""))
        elif op == "unread":
            self.mark_unread(str(command.get("jid") or ""))
        elif op == "block":
            self.block(str(command.get("jid") or ""), bool(command.get("block")))
        elif op == "leave":
            self.leave(str(command.get("jid") or ""))
        elif op == "invite":
            self.invite(str(command.get("jid") or ""))
        elif op == "newChat":
            self.new_chat(str(command.get("number") or ""))
        elif op == "link":
            self.link_number(str(command.get("jid") or ""), str(command.get("number") or ""))
        elif op == "config":
            self.auto_download = command.get("autoDownload") is not False
            self.appear_online = command.get("appearOnline") is True
            self.update_presence()

    def refresh_status(self):
        try:
            data = self.api.call("GET", "instance/connectionState")
            state = (data or {}).get("instance", data) or {}
            emit("status", connection=str(state.get("state") or "unknown"))
        except ApiError as e:
            emit("status", connection="unreachable")
            log(e)

    def refresh_chats(self):
        with self.lock:
            self.dirty_chats = False
            self.last_chats = time.monotonic()
            open_jid = self.open_jid
        rows = self.api.call("POST", "chat/findChats", {}) or []
        d = self.directory
        chats = []
        for row in rows if isinstance(rows, list) else []:
            jid = str(row.get("remoteJid") or "")
            if not jid or jid.endswith("@broadcast") or jid.endswith("@newsletter"):
                continue
            is_group = jid.endswith("@g.us")
            if is_group:
                if row.get("pushName"):
                    with d.lock:
                        d.subjects.setdefault(jid, str(row["pushName"])[:120])
            else:
                d.learn_push(jid, row.get("pushName"))
            d.set_avatar(jid, row.get("profilePicUrl"))
            last = row.get("lastMessage") or {}
            if isinstance(last, dict) and last.get("key"):
                d.learn_record(last)
            key = last.get("key") or {}
            if key.get("id"):
                self.last_keys[jid] = {"id": key.get("id"), "remoteJid": jid, "fromMe": bool(key.get("fromMe"))}
            last_message = unwrap(last.get("message"))
            parsed = parse(last_message)
            mentions_me = d.mentions(parsed, last_message)
            sender = ""
            if is_group and not key.get("fromMe"):
                participant = sender_jid(last)
                sender = d.name(participant) or valid_push(last.get("pushName"), d.me) or d.phone(participant)
            chats.append({
                "jid": jid,
                "name": d.name(jid),
                "phone": d.phone(jid),
                "group": is_group,
                "avatar": self.avatar_path(jid),
                "unread": 0 if self.is_open(jid, open_jid) else int(row.get("unreadCount") or 0),
                "ts": int(last.get("messageTimestamp") or 0) or self.iso_ts(row.get("updatedAt")),
                "preview": dict(preview(parsed), deleted=is_deleted(last)),
                "fromMe": bool(key.get("fromMe")),
                "sender": sender,
                "status": self.last_status(last) if key.get("fromMe") else "",
            })
        if not self.live:
            self.spot_new(rows if isinstance(rows, list) else [])
        self.chat_ids = [c["jid"] for c in chats]
        chats = self.merge_aliases(chats)
        emit("chats", chats=chats)
        for c in chats:
            if not c["avatar"]:
                self.queue_avatar(c["jid"])
        self.directory.save()

    def spot_new(self, rows):
        """Without RabbitMQ, new messages are found by comparing each chat's
        newest message with the previous poll; they notify like pushed ones."""
        latest = {}
        for row in rows:
            last = row.get("lastMessage") or {}
            key = last.get("key") or {} if isinstance(last, dict) else {}
            if key.get("id"):
                latest[str(row.get("remoteJid") or "")] = (str(key["id"]), last)
        previous, self.seen_last = self.seen_last, {jid: mid for jid, (mid, _) in latest.items()}
        if previous is None:
            return                     # first look: everything is old news
        for jid, (mid, last) in latest.items():
            if previous.get(jid) != mid:
                self.on_record(last)

    def note_status(self, msg_id, status):
        if msg_id and STATUS_RANK.get(status, -1) > STATUS_RANK.get(self.statuses.get(msg_id, ""), -1):
            if len(self.statuses) > 5000:
                self.statuses.clear()
            self.statuses[msg_id] = status

    def last_status(self, last):
        """The chat list's last message carries the status it had when stored
        (often PENDING forever): use what we saw live, else ask once."""
        msg_id = str((last.get("key") or {}).get("id") or "")
        status = status_of(last, self.statuses.get(msg_id, ""))
        if status in ("pending", "sent") and msg_id and msg_id not in self.statuses:
            self.statuses[msg_id] = ""          # ask at most once per id
            try:
                raw = self.api.call("POST", "chat/findMessages", {"where": {"key": {"id": msg_id}}, "page": 1, "offset": 1})
                wrapped = (raw or {}).get("messages")
                rows = wrapped if isinstance(wrapped, list) else (wrapped or {}).get("records", []) if isinstance(wrapped, dict) else []
                for row in rows[:1]:
                    best = status_of(row)
                    raw_best = {v: k for k, v in {"ERROR": "error", "PENDING": "pending", "SERVER_ACK": "sent",
                                                  "DELIVERY_ACK": "delivered", "READ": "read"}.items()}.get(best, "")
                    self.note_status(msg_id, raw_best)
                    status = best
            except ApiError as e:
                log(f"status {msg_id}: {e}")
        return status

    def merge_aliases(self, chats):
        """WhatsApp addresses one person both by phone and by @lid, and
        Evolution keeps a chat per address: show one, newest first, holding
        both histories."""
        by_person, order = {}, []
        for chat in chats:
            person = "" if chat["group"] else self.directory.phone_jid(chat["jid"])
            person = person or chat["jid"]
            if person not in by_person:
                by_person[person] = []
                order.append(person)
            by_person[person].append(chat)
        merged, aliases = [], {}
        for person in order:
            group = sorted(by_person[person], key=lambda c: c["ts"], reverse=True)
            head = dict(group[0])
            head["unread"] = sum(c["unread"] for c in group)
            head["name"] = next((c["name"] for c in group if c["name"]), "")
            head["avatar"] = next((c["avatar"] for c in group if c["avatar"]), "")
            aliases[head["jid"]] = [c["jid"] for c in group]
            merged.append(head)
        merged.sort(key=lambda c: c["ts"], reverse=True)
        self.aliases = aliases
        return merged

    def is_open(self, jid, open_jid):
        return bool(open_jid) and jid in self.aliases.get(open_jid, [open_jid])

    @staticmethod
    def iso_ts(value):
        try:
            return int(time.mktime(time.strptime(str(value)[:19], "%Y-%m-%dT%H:%M:%S")) - time.timezone)
        except (ValueError, OverflowError):
            return 0

    def refresh_messages(self):
        with self.lock:
            jid, limit, mark = self.open_jid, self.limit, self.mark_read
            self.dirty_messages = False
            self.mark_read = False
            self.last_messages = time.monotonic()
        if not jid:
            return
        records, total, fetched = [], 0, 0
        for alias in self.aliases.get(jid, [jid]):
            raw = self.api.call("POST", "chat/findMessages",
                                {"where": {"key": {"remoteJid": alias}}, "page": 1, "offset": limit})
            wrapped = (raw or {}).get("messages")
            rows = wrapped if isinstance(wrapped, list) else (wrapped or {}).get("records", []) if isinstance(wrapped, dict) else []
            rows = [r for r in rows if isinstance(r, dict)]
            records += rows
            fetched += len(rows)
            total += int(wrapped.get("total") or 0) if isinstance(wrapped, dict) else len(rows)
        # Evolution stores some messages twice (history sync + live).
        seen, unique = set(), []
        for rec in records:
            rid = (rec.get("key") or {}).get("id")
            if rid and rid in seen:
                continue
            seen.add(rid)
            unique.append(rec)
        records = unique
        d = self.directory
        reactions = collect_reactions(records)
        messages, unread_keys = [], []
        for rec in records:
            d.learn_record(rec)
            key = rec.get("key") or {}
            message = unwrap(rec.get("message"))
            parsed = parse(message)
            if not parsed or parsed["kind"] == "reaction":
                continue

            msg_id = str(key.get("id") or "")
            from_me = bool(key.get("fromMe"))
            participant = sender_jid(rec)
            self.keys[msg_id] = {"id": msg_id, "remoteJid": key.get("remoteJid"), "fromMe": from_me}
            if key.get("participant"):
                self.keys[msg_id]["participant"] = key["participant"]
            sender = ""
            if jid.endswith("@g.us") and not from_me:
                sender = d.name(participant) or valid_push(rec.get("pushName"), d.me) or d.phone(participant)
            quoted = context_of(message).get("quotedMessage") or ((rec.get("contextInfo") or {}).get("quotedMessage"))
            quoted_parsed = parse(unwrap(quoted)) if isinstance(quoted, dict) else None
            item = {
                "id": msg_id, "fromMe": from_me, "ts": int(rec.get("messageTimestamp") or 0),
                "sender": sender, "senderJid": participant,
                "status": status_of(rec, self.statuses.get(msg_id, "")) if from_me else "",
                "reactions": reactions.get(msg_id, []),
                "quote": preview(quoted_parsed) if quoted_parsed else None,
                "media": self.media_path(msg_id),
                "deleted": is_deleted(rec),
                "edited": bool(rec.get("MessageUpdate") and any((u or {}).get("status") == "EDITED" for u in rec.get("MessageUpdate") or [])),
            }
            item["mentionsMe"] = d.mentions(parsed, message)
            item.update(parsed)
            item["editable"] = (from_me and item.get("kind") == "text"
                                and time.time() - item["ts"] < EDIT_WINDOW)
            messages.append(item)
            if not from_me and msg_id not in {k["id"] for k in unread_keys}:
                unread_keys.append({"id": msg_id, "remoteJid": key.get("remoteJid"), "fromMe": False})
        messages.sort(key=lambda m: m["ts"], reverse=True)
        with self.lock:
            if jid != self.open_jid:
                return
        emit("messages", jid=jid, name=d.name(jid), phone=d.phone(jid), group=jid.endswith("@g.us"),
             avatar=self.avatar_path(jid), messages=messages, more=total > fetched and limit < MAX_PAGE)
        if mark and unread_keys:
            try:
                self.api.call("POST", "chat/markMessageAsRead", {"readMessages": unread_keys[:30]})
            except ApiError as e:
                log(e)
            with self.lock:
                self.dirty_chats = True

    def send(self, jid, text, quoted_id):
        text = text.strip()[:MAX_TEXT]
        if not jid or not text:
            return
        body = {"number": jid, "text": text}
        if quoted_id and quoted_id in self.keys:
            body["quoted"] = {"key": self.keys[quoted_id]}
        try:
            self.api.call("POST", "message/sendText", body, timeout=40)
        except ApiError:
            phone = self.directory.phone_jid(jid)
            if not phone or phone == jid:
                raise
            body["number"] = phone
            self.api.call("POST", "message/sendText", body, timeout=40)
        emit("sent", jid=jid)
        with self.lock:
            self.dirty_messages = jid == self.open_jid
            self.dirty_chats = True
            self.last_messages = 0

    # ---- actions

    def send_file(self, jid, path, caption, quoted_id):
        real = os.path.realpath(path)
        if not jid or not os.path.isfile(real):
            raise ApiError("file not found")
        size = os.path.getsize(real)
        if size > MAX_UPLOAD:
            emit("error", code="tooLarge", detail=str(size))
            return
        import mimetypes
        mime = mimetypes.guess_type(real)[0] or "application/octet-stream"
        kind = media_type(mime)
        with open(real, "rb") as f:
            data = base64.b64encode(f.read()).decode()
        number = self.directory.phone_jid(jid) or jid
        if kind == "audio":
            body = {"number": number, "audio": data}
            route = "message/sendWhatsAppAudio"
        else:
            body = {"number": number, "mediatype": kind, "mimetype": mime, "media": data,
                    "fileName": os.path.basename(real), "caption": caption.strip()[:MAX_TEXT]}
            route = "message/sendMedia"
        if quoted_id and quoted_id in self.keys:
            body["quoted"] = {"key": self.keys[quoted_id]}
        self.api.call("POST", route, body, timeout=180, limit=1024 * 1024)
        if real.startswith(os.path.realpath(STAGE_DIR) + os.sep):
            try:
                os.remove(real)
            except OSError:
                pass
        emit("sent", jid=jid)
        self.touch_chats()

    def side_command(self, command):
        op = command.get("op")
        try:
            if op == "pick":
                out = subprocess.run(["omarchy-file-select", "--title", "WhatsApp"],
                                     capture_output=True, text=True, timeout=650)
                path = out.stdout.strip().splitlines()[0] if out.returncode == 0 and out.stdout.strip() else ""
                if path and os.path.isfile(path):
                    self.stage(path)
                else:
                    emit("staged", path="")
            elif op == "pasteImage":
                types = subprocess.run(["wl-paste", "--list-types"], capture_output=True, text=True, timeout=5).stdout.split()
                mime = next((t for t in ("image/png", "image/jpeg", "image/webp") if t in types), "")
                if not mime:
                    emit("staged", path="", clipboard=False)
                    return
                data = subprocess.run(["wl-paste", "--type", mime], capture_output=True, timeout=15).stdout
                if not data or len(data) > MAX_UPLOAD:
                    return
                os.makedirs(STAGE_DIR, exist_ok=True)
                path = os.path.join(STAGE_DIR, f"clipboard-{int(time.time())}.{mime.split('/')[1]}")
                with open(path, "wb") as f:
                    f.write(data)
                self.stage(path)
            elif op == "recordStart":
                self.record_start(str(command.get("jid") or ""))
            elif op == "recordStop":
                self.record_stop(bool(command.get("send")))
            elif op == "typing":
                if not self.appear_online:
                    return
                jid = str(command.get("jid") or "")
                now = time.monotonic()
                if not jid or now - self.typing_at.get(jid, 0) < 8:
                    return
                self.typing_at[jid] = now
                number = self.directory.phone_jid(jid) or jid
                self.api.call("POST", "chat/sendPresence", {"number": number, "presence": "composing", "delay": 4000}, timeout=20)
        except Exception as e:  # noqa: BLE001 - presence and pickers are best-effort
            log(f"{op}: {e}")

    def stage(self, path):
        import mimetypes
        mime = mimetypes.guess_type(path)[0] or ""
        emit("staged", path=path, name=os.path.basename(path), size=os.path.getsize(path),
             kind=media_type(mime), image=mime.startswith("image/"))

    def key_of(self, msg_id):
        key = self.keys.get(msg_id)
        if not key:
            raise ApiError("message not in the open chat")
        return key

    def react(self, msg_id, emoji):
        self.api.call("POST", "message/sendReaction", {"key": self.key_of(msg_id), "reaction": emoji[:16]})
        self.touch_chats()

    def edit(self, msg_id, text):
        key, text = self.key_of(msg_id), text.strip()[:MAX_TEXT]
        if not key.get("fromMe") or not text:
            return
        self.api.call("POST", "chat/updateMessage", {"number": self.directory.phone_jid(key["remoteJid"]) or key["remoteJid"],
                                                     "key": key, "text": text})
        emit("sent", jid=self.open_jid)
        self.touch_chats()

    def delete(self, msg_id):
        key = dict(self.key_of(msg_id))
        if not key.get("fromMe"):
            return
        self.api.call("DELETE", "chat/deleteMessageForEveryone", key)
        self.touch_chats()

    def mark_unread(self, jid):
        for alias in self.aliases.get(jid, [jid]):
            key = self.last_keys.get(alias)
            if key:
                self.api.call("POST", "chat/markChatUnread", {"lastMessage": {"key": key}, "chat": alias})
        emit("done", op="unread", jid=jid)
        self.touch_chats()

    def block(self, jid, block):
        number = self.directory.phone_jid(jid) or jid
        self.api.call("POST", "chat/updateBlockStatus",
                      {"number": number, "status": "block" if block else "unblock"})
        emit("done", op="block" if block else "unblock", jid=jid)

    def leave(self, jid):
        if not jid.endswith("@g.us"):
            return
        self.api.call("DELETE", "group/leaveGroup", query={"groupJid": jid})
        emit("done", op="leave", jid=jid)
        self.touch_chats()

    def invite(self, jid):
        data = self.api.call("GET", "group/inviteCode", query={"groupJid": jid}) or {}
        url = str(data.get("inviteUrl") or "")
        if url.startswith("https://chat.whatsapp.com/"):
            emit("invite", jid=jid, url=url)

    def link_number(self, jid, number):
        """The user says this @lid chat is the person behind `number`
        (empty: undo). Both chats then show as one."""
        if not jid.endswith("@lid"):
            return
        if number:
            digits = phone_digits(number)
            if not digits:
                emit("error", code="badNumber", detail="")
                return
            rows = self.api.call("POST", "chat/whatsappNumbers", {"numbers": [digits]}) or []
            row = rows[0] if isinstance(rows, list) and rows else {}
            if not row.get("exists"):
                emit("error", code="notOnWhatsApp", detail=format_phone(digits + "@s.whatsapp.net"))
                return
            self.directory.link(jid, str(row.get("jid") or digits + "@s.whatsapp.net"))
        else:
            self.directory.link(jid, "")
        self.directory.save()
        emit("done", op="link" if number else "unlink", jid=jid)
        with self.lock:
            self.dirty_chats = True
            self.last_chats = 0
        self.profile(jid)

    def new_chat(self, number):
        digits = phone_digits(number)
        if not digits:
            emit("error", code="badNumber", detail="")
            return
        rows = self.api.call("POST", "chat/whatsappNumbers", {"numbers": [digits]}) or []
        row = rows[0] if isinstance(rows, list) and rows else {}
        if not row.get("exists"):
            emit("error", code="notOnWhatsApp", detail=format_phone(digits + "@s.whatsapp.net"))
            return
        emit("opened", jid=str(row.get("jid") or digits + "@s.whatsapp.net"))

    def profile(self, jid):
        if not jid:
            return
        d = self.directory
        out = {"jid": jid, "group": jid.endswith("@g.us"), "name": d.name(jid), "phone": d.phone(jid),
               "localName": d.local.get(jid, ""), "avatar": self.avatar_path(jid)}
        if out["group"]:
            info = self.api.call("GET", "group/findGroupInfos", query={"groupJid": jid}, timeout=40) or {}
            me = d.my_jids
            members = []
            for p in info.get("participants") or []:
                pid = str(p.get("id") or "")
                d.map_lid(pid, p.get("phoneNumber") or p.get("jid"))
                members.append({"jid": pid, "name": d.name(pid), "phone": d.phone(pid),
                                "admin": str(p.get("admin") or ""), "me": pid in me or (p.get("phoneNumber") in me),
                                "avatar": self.avatar_path(pid)})
            members.sort(key=lambda m: (not m["me"], m["admin"] == "", m["name"] == "", (m["name"] or m["phone"]).lower()))
            out.update({
                "name": str(info.get("subject") or out["name"]),
                "about": str(info.get("desc") or "")[:2000],
                "created": int(info.get("creation") or 0),
                "owner": d.name(str(info.get("owner") or "")) or d.phone(str(info.get("owner") or "")),
                "size": int(info.get("size") or len(members)),
                "announce": bool(info.get("announce")), "restrict": bool(info.get("restrict")),
                "members": members[:400],
                "admin": any(m["me"] and m["admin"] for m in members),
            })
        else:
            number = d.phone_jid(jid) or jid
            info = self.api.call("POST", "chat/fetchProfile", {"number": number}, timeout=30) or {}
            status = info.get("status") or {}
            out["about"] = str((status.get("status") if isinstance(status, dict) else status) or "").strip()[:700]
            set_at = str(status.get("setAt") or "") if isinstance(status, dict) else ""
            out["aboutSince"] = 0 if set_at.startswith("1970") else self.iso_ts(set_at)
            if info.get("name") and not out["name"]:
                out["name"] = valid_push(info["name"], d.me)
            d.set_avatar(jid, info.get("picture"))
            self.queue_avatar(jid)
            if not out["phone"]:
                out["phone"] = d.phone(jid)
            out["lid"] = jid.split("@")[0] if jid.endswith("@lid") else ""
            # The @lid the user linked to this person, so the profile can offer "unlink".
            out["linkedLid"] = jid if jid in d.links else next((l for l, p in d.links.items() if p == jid), "")
            if info.get("isBusiness"):
                biz = self.api.call("POST", "chat/fetchBusinessProfile", {"number": number}, timeout=30) or {}
                sites = biz.get("website") or []
                out["business"] = {
                    "description": str(biz.get("description") or "")[:1000],
                    "category": str(biz.get("category") or "")[:120],
                    "email": str(biz.get("email") or "")[:200],
                    "address": str(biz.get("address") or "")[:300],
                    "websites": [str(w)[:200] for w in (sites if isinstance(sites, list) else [sites]) if str(w).startswith(("http://", "https://"))][:3],
                }
        emit("profile", profile=out)

    def lookup_worker(self):
        """Ask WhatsApp for the picture of each @lid chat with no known phone
        (at most daily per chat): the picture's file id matches the same
        person's picture under their phone number in the synced contacts."""
        time.sleep(20)
        while True:
            d = self.directory
            for jid in list(self.chat_ids):
                if not jid.endswith("@lid") or d.phone_jid(jid):
                    continue
                with d.lock:
                    if time.time() - d.looked.get(jid, 0) < PIC_LOOKUP_TTL:
                        continue
                    d.looked[jid] = time.time()
                    d.dirty = True
                try:
                    data = self.api.call("POST", "chat/fetchProfilePictureUrl", {"number": jid}) or {}
                    d.set_avatar(jid, data.get("profilePictureUrl"))
                    self.queue_avatar(jid)
                    if d.phone_jid(jid):
                        self.touch_chats()
                except ApiError as e:
                    log(f"lookup {jid}: {e}")
                time.sleep(2)
            d.save()
            time.sleep(600)

    # ---- presence: WhatsApp tells us who is online/typing only while we are
    # online ourselves, so like WhatsApp Web we are "available" exactly while a
    # chat is open in the visible panel, and "unavailable" otherwise.

    def update_presence(self):
        with self.lock:
            target = self.open_jid if self.panel_open and self.appear_online else ""
        threading.Thread(target=self.apply_presence, args=(target,), daemon=True).start()

    def apply_presence(self, target, keepalive=False):
        with self.presence_lock:
            previous = self.presence_target
            if target == previous and not keepalive:
                return
            self.presence_target = target
            try:
                if target:
                    number = self.directory.phone_jid(target) or target
                    self.api.call("POST", "chat/sendPresence", {"number": number, "presence": "available", "delay": 100}, timeout=20)
                    if not keepalive:
                        emit("presence", jid=target, state="", who="", lastSeen=0)
                elif previous:
                    number = self.directory.phone_jid(previous) or previous
                    self.api.call("POST", "chat/sendPresence", {"number": number, "presence": "unavailable", "delay": 100}, timeout=20)
            except ApiError as e:
                log(f"presence: {e}")

    def presence_worker(self):
        # A crash or restart may have left the account "available", which
        # keeps WhatsApp from notifying the phone: start from unavailable.
        for _ in range(60):
            own = next((j for j in self.directory.my_jids if j.endswith("@s.whatsapp.net")), "")
            if own:
                try:
                    self.api.call("POST", "chat/sendPresence", {"number": own, "presence": "unavailable", "delay": 100}, timeout=20)
                except ApiError as e:
                    log(f"presence reset: {e}")
                break
            time.sleep(5)
        while True:
            time.sleep(PRESENCE_KEEPALIVE)
            with self.presence_lock:
                target = self.presence_target
            if target:
                self.apply_presence(target, keepalive=True)

    def on_presence(self, body):
        envelope = json.loads(body)
        if envelope.get("instance") != self.instance:
            return
        data = envelope.get("data") or {}
        chat = str(data.get("id") or "")
        with self.lock:
            open_jid = self.open_jid
        if not chat or not self.is_open(chat, open_jid):
            return
        group = open_jid.endswith("@g.us")
        for who, info in (data.get("presences") or {}).items():
            if not isinstance(info, dict):
                continue
            if who in self.directory.my_jids:
                continue
            state = str(info.get("lastKnownPresence") or "")
            if state not in ("available", "unavailable", "composing", "recording", "paused"):
                continue
            name = ""
            if group:
                name = self.directory.name(who) or self.directory.phone(who)
                if state in ("available", "unavailable"):
                    continue          # group headers show activity, not who is online
            emit("presence", jid=open_jid, state=state, who=name, lastSeen=int(info.get("lastSeen") or 0))

    # ---- voice notes

    def record_start(self, jid):
        self.record_stop(False)
        if not jid or not shutil.which("ffmpeg"):
            emit("error", code="noRecorder", detail="ffmpeg")
            return
        os.makedirs(STAGE_DIR, exist_ok=True)
        # Raw first: the loudness is evened out when recording stops.
        path = os.path.join(STAGE_DIR, f"voice-{int(time.time())}.wav")
        self.recorder = subprocess.Popen(
            ["ffmpeg", "-loglevel", "error", "-f", "pulse", "-i", "default", "-ac", "1", "-ar", "48000",
             "-c:a", "pcm_s16le", "-t", str(RECORD_MAX), "-y", path],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.record_path, self.record_jid = path, jid
        emit("recording", state="recording", started=time.time(), micVolume=mic_volume())
        recorder = self.recorder

        def keep_saying_recording():
            number = self.directory.phone_jid(jid) or jid
            while self.recorder is recorder and recorder.poll() is None:
                try:
                    if self.appear_online:
                        self.api.call("POST", "chat/sendPresence", {"number": number, "presence": "recording", "delay": 3000}, timeout=20)
                except ApiError:
                    pass
                time.sleep(5)
            if self.recorder is recorder:      # stopped by the time limit, not by the user
                self.record_stop(True)
        threading.Thread(target=keep_saying_recording, daemon=True).start()

    def record_stop(self, send):
        recorder, path, jid = self.recorder, self.record_path, self.record_jid
        self.recorder, self.record_path, self.record_jid = None, "", ""
        if not recorder:
            return
        try:
            recorder.stdin.write(b"q")        # ffmpeg finishes the file cleanly on "q"
            recorder.stdin.close()
            recorder.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            recorder.kill()
        emit("recording", state="idle")
        ok = send and os.path.exists(path) and os.path.getsize(path) > 48000   # under ~0.5 s: dropped
        voice = path[:-4] + ".ogg"
        try:
            if ok:
                # Even out the loudness (a mic set low records far too quietly), then Opus like WhatsApp.
                subprocess.run(["ffmpeg", "-loglevel", "error", "-i", path,
                                "-af", "atrim=start=0.15,asetpts=PTS-STARTPTS,highpass=f=80,loudnorm=I=-16:TP=-1.5:LRA=11",
                                "-ar", "48000", "-ac", "1", "-c:a", "libopus", "-b:a", "32k", "-application", "voip",
                                "-y", voice], check=True, timeout=120,
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                with open(voice, "rb") as f:
                    audio = base64.b64encode(f.read()).decode()
                number = self.directory.phone_jid(jid) or jid
                self.api.call("POST", "message/sendWhatsAppAudio", {"number": number, "audio": audio}, timeout=120, limit=1024 * 1024)
                emit("sent", jid=jid)
                self.touch_chats()
        except (ApiError, subprocess.SubprocessError, OSError) as e:
            emit("error", code="api", detail=one_line(e, 300))
        finally:
            for leftover in (path, voice):
                try:
                    os.remove(leftover)
                except OSError:
                    pass

    # ---- saved media: files are kept on arrival, so photos and voice notes
    # stay viewable after the sender deletes them or WhatsApp drops them.

    def prefetch(self, record):
        if not self.auto_download:
            return
        message = unwrap(record.get("message"))
        parsed = parse(message)
        if not parsed or parsed["kind"] not in ("image", "video", "audio", "document", "sticker"):
            return
        size = 0
        for key in ("imageMessage", "videoMessage", "audioMessage", "documentMessage", "stickerMessage"):
            if isinstance(message.get(key), dict):
                size = file_length(message[key].get("fileLength"))
        if size > PREFETCH_MAX:
            return
        msg_id = str((record.get("key") or {}).get("id") or "")
        if msg_id and not self.media_path(msg_id):
            self.prefetch_jobs.put(msg_id)

    def prefetch_worker(self):
        last_prune = 0.0
        while True:
            msg_id = self.prefetch_jobs.get()
            if not re.fullmatch(r"[A-Za-z0-9_-]{4,80}", msg_id) or self.media_path(msg_id):
                continue
            try:
                path = self.cached_media(msg_id)
                emit("media", id=msg_id, state="done", path=path)
            except Exception as e:  # noqa: BLE001 - best effort, the bubble still offers a manual download
                log(f"prefetch {msg_id}: {e}")
            if time.time() - last_prune > 3600:
                last_prune = time.time()
                prune_media()

    # ---- media

    def media_path(self, msg_id):
        if not msg_id:
            return ""
        try:
            for name in os.listdir(MEDIA_DIR):
                if name.split(".", 1)[0] == msg_id:
                    return os.path.join(MEDIA_DIR, name)
        except OSError:
            pass
        return ""

    def cached_media(self, msg_id):
        path = self.media_path(msg_id)
        if path:
            return path
        content, name, _mime = self.api.media(msg_id)
        ext = os.path.splitext(name)[1][:10] or ".bin"
        path = os.path.join(MEDIA_DIR, msg_id + ext)
        with open(path, "wb") as f:
            f.write(content)
        return path

    def media_worker(self):
        while True:
            job = self.media_jobs.get()
            op, msg_id = job.get("op"), str(job.get("id") or "")
            if not re.fullmatch(r"[A-Za-z0-9_-]{4,80}", msg_id):
                continue
            try:
                if op == "play":
                    self.toggle_play(msg_id)
                    continue
                emit("media", id=msg_id, state="loading")
                if op == "download":
                    path = self.download(msg_id)
                    detached(["xdg-open", path])
                else:
                    path = self.cached_media(msg_id)
                    if op == "view":
                        detached(["xdg-open", path])
                emit("media", id=msg_id, state="done", path=path)
            except Exception as e:  # noqa: BLE001 - surfaced per message in the UI
                log(f"{op} {msg_id}: {e}")
                emit("media", id=msg_id, state="failed", code=media_error_code(e))

    def download(self, msg_id):
        content, name, _mime = self.api.media(msg_id)
        os.makedirs(DOWNLOAD_DIR, exist_ok=True)
        name = re.sub(r"[\x00-\x1f/\\]", "_", name).strip(". ") or msg_id
        path = os.path.join(DOWNLOAD_DIR, name)
        if os.path.exists(path) and os.path.getsize(path) == len(content):
            return path
        base, ext = os.path.splitext(path)
        n = 1
        while os.path.exists(path):
            path = f"{base} ({n}){ext}"
            n += 1
        with open(path, "wb") as f:
            f.write(content)
        return path

    def toggle_play(self, msg_id):
        same = self.player_id == msg_id
        self.stop_player()
        if same:
            return
        if not shutil.which("mpv"):
            emit("error", code="noPlayer", detail="mpv")
            return
        emit("media", id=msg_id, state="loading")
        path = self.cached_media(msg_id)
        emit("media", id=msg_id, state="done", path=path)
        video = os.path.splitext(path)[1].lower() in (".mp4", ".mkv", ".webm", ".mov", ".3gp")
        args = ["mpv", "--really-quiet", "--force-window=yes" if video else "--no-video", path]
        self.player = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, start_new_session=True)
        self.player_id = msg_id
        emit("playing", id=msg_id)
        player = self.player

        def wait():
            player.wait()
            if self.player is player:
                self.player, self.player_id = None, ""
                emit("playing", id="")
        threading.Thread(target=wait, daemon=True).start()

    def stop_player(self):
        if self.player and self.player.poll() is None:
            self.player.terminate()
        self.player, self.player_id = None, ""
        emit("playing", id="")

    # ---- avatars (local files, so the shell never loads remote images)

    def avatar_file(self, jid):
        return os.path.join(AVATAR_DIR, hashlib.sha1(jid.encode()).hexdigest() + ".jpg")

    def avatar_path(self, jid):
        path = self.avatar_file(jid)
        return path if os.path.exists(path) else ""

    def queue_avatar(self, jid):
        with self.directory.lock:
            url = self.directory.avatars.get(jid)
        path = self.avatar_file(jid)
        fresh = os.path.exists(path) and time.time() - os.path.getmtime(path) < AVATAR_TTL
        if url and not fresh and jid not in self.avatar_queued:
            self.avatar_queued.add(jid)
            self.avatar_jobs.put((jid, url))

    def avatar_worker(self):
        while True:
            jid, url = self.avatar_jobs.get()
            try:
                request = urllib.request.Request(url, headers={"User-Agent": "curl/8.0"})
                with urllib.request.urlopen(request, timeout=20) as response:
                    if not str(response.headers.get("Content-Type", "")).startswith("image/"):
                        continue
                    data = response.read(MAX_AVATAR + 1)
                if len(data) > MAX_AVATAR:
                    continue
                path = self.avatar_file(jid)
                with open(path + ".tmp", "wb") as f:
                    f.write(data)
                os.replace(path + ".tmp", path)
                emit("avatar", jid=jid, path=path)
            except (urllib.error.URLError, OSError, ValueError) as e:
                log(f"avatar {jid}: {e}")

    # ---- names: contacts, own profile, group members

    def directory_worker(self):
        while True:
            d = self.directory
            try:
                me = self.api.call("GET", "instance/fetchInstances", query={"instanceName": self.instance}, scoped=False) or []
                if me and isinstance(me, list):
                    owner = str(me[0].get("ownerJid") or "")
                    with d.lock:
                        d.me = str(me[0].get("profileName") or "")
                        if owner:
                            d.my_jids.add(owner)
                    d.set_avatar(owner, me[0].get("profilePicUrl"))
                    self.queue_avatar(owner)
                    emit("account", name=d.me, phone=format_phone(owner), jid=owner, avatar=self.avatar_path(owner))
                contacts = self.api.call("POST", "chat/findContacts", {}, timeout=60) or []
                with d.lock:
                    for c in contacts if isinstance(contacts, list) else []:
                        jid, name = str(c.get("remoteJid") or ""), c.get("pushName")
                        name = valid_push(name)
                        if jid.endswith("@s.whatsapp.net") and name and jid not in d.my_jids:
                            d._set(d.names, jid, name)
                for c in contacts if isinstance(contacts, list) else []:
                    d.set_avatar(str(c.get("remoteJid") or ""), c.get("profilePicUrl"))
                    if str(c.get("remoteJid") or "").endswith("@lid"):
                        d.learn_push(c["remoteJid"], c.get("pushName"))
                self.touch_chats()
                groups = self.api.call("GET", "group/fetchAllGroups", query={"getParticipants": "true"}, timeout=120) or []
                own = own_lid(groups if isinstance(groups, list) else [])
                if own:
                    with d.lock:
                        if own not in d.my_jids:
                            d.my_jids.add(own)
                            d.dirty = True
                    for jid in list(d.my_jids):
                        d.map_lid(own, jid)
                for g in groups if isinstance(groups, list) else []:
                    gid = str(g.get("id") or "")
                    with d.lock:
                        d._set(d.subjects, gid, str(g.get("subject") or "")[:120])
                    d.set_avatar(gid, g.get("pictureUrl"))
                    for p in g.get("participants") or []:
                        d.map_lid(p.get("id"), p.get("phoneNumber") or p.get("jid"))
                        d.map_lid(p.get("lid"), p.get("id"))
                self.touch_chats()
                d.save()
            except Exception as e:  # noqa: BLE001 - names are best-effort; retry next round
                log(f"directory: {e}")
            time.sleep(DIRECTORY_EVERY)

    def touch_chats(self):
        with self.lock:
            self.dirty_chats = True
            self.dirty_messages = bool(self.open_jid)

    # ---- live events

    def amqp_worker(self):
        if not has_secret("amqp-uri"):
            emit("status", listener=False)       # no RabbitMQ configured: polling, which is fine
            return
        try:
            import pika
        except ImportError:
            emit("status", listener=False)
            emit("error", code="noPika", detail="python-pika")
            return
        backoff = 2
        while True:
            try:
                params = pika.URLParameters(secret("amqp-uri"))
                params.heartbeat = 30
                connection = pika.BlockingConnection(params)
                channel = connection.channel()
                channel.queue_declare(queue=self.queue, durable=True, arguments={"x-queue-type": "classic"})
                for key in ROUTING_KEYS:
                    channel.queue_bind(queue=self.queue, exchange=EXCHANGE, routing_key=key)
                # Whatever piled up while the shell was off is stale: REST is
                # re-read on start anyway.
                channel.queue_purge(self.queue)
                channel.basic_qos(prefetch_count=100)

                def on_message(ch, method, _props, body):
                    try:
                        self.on_event(method.routing_key, body)
                    except Exception as e:  # noqa: BLE001 - one bad event must not stop the stream
                        log(f"event: {e}")
                    ch.basic_ack(method.delivery_tag)
                channel.basic_consume(self.queue, on_message)

                # Presence also comes on the global exchange (bound above). An
                # instance with its own RabbitMQ config publishes it to its own
                # queue instead; read it too when we may. Optional either way.
                try:
                    presence = connection.channel()
                    presence_queue = self.instance + PRESENCE_QUEUE_SUFFIX
                    presence.queue_purge(presence_queue)

                    def on_presence(_ch, _method, _props, body):
                        try:
                            self.on_presence(body)
                        except Exception as e:  # noqa: BLE001
                            log(f"presence event: {e}")
                    presence.basic_consume(presence_queue, on_presence, auto_ack=True)
                except Exception as e:  # noqa: BLE001
                    log(f"presence queue unavailable: {e}")
                emit("status", listener=True)
                self.live = True
                backoff = 2
                while True:
                    connection.process_data_events(time_limit=30)
            except Exception as e:  # noqa: BLE001 - reconnect with backoff
                log(f"amqp: {e}")
                self.live = False
                emit("status", listener=False)
                time.sleep(backoff)
                backoff = min(backoff * 2, 60)

    def on_event(self, routing_key, body):
        if routing_key == "presence.update":       # global mode (RABBITMQ_EVENTS_PRESENCE_UPDATE=true)
            self.on_presence(body)
            return
        envelope = json.loads(body)
        if envelope.get("instance") != self.instance:
            return
        data = envelope.get("data")
        if routing_key == "connection.update":
            state = (data or {}).get("state") if isinstance(data, dict) else ""
            emit("status", connection=str(state or "unknown"))
            return
        records = data if isinstance(data, list) else [data]
        with self.lock:
            open_jid = self.open_jid
        for rec in records:
            if not isinstance(rec, dict):
                continue
            if routing_key == "messages.update":
                jid = str(rec.get("remoteJid") or "")
                if rec.get("fromMe") and rec.get("keyId"):
                    self.note_status(str(rec["keyId"]), str(rec.get("status") or ""))
                if rec.get("status") == "DELETED" and rec.get("keyId") and self.auto_download:
                    # Save the file before it can disappear; text is kept by Evolution.
                    self.prefetch_jobs.put(str(rec["keyId"]))
                with self.lock:
                    self.dirty_chats = True
                    if jid and self.is_open(jid, open_jid):
                        self.dirty_messages = True
                continue
            self.on_record(rec)

    def on_record(self, rec, fresh_for=120):
        """A new message, pushed by RabbitMQ or spotted by polling."""
        with self.lock:
            open_jid = self.open_jid
        self.directory.learn_record(rec)
        self.prefetch(rec)
        key = rec.get("key") or {}
        jid = str(key.get("remoteJid") or "")
        with self.lock:
            self.dirty_chats = True
            if self.is_open(jid, open_jid):
                self.dirty_messages = True
                self.mark_read = self.mark_read or not key.get("fromMe")
        message = unwrap(rec.get("message"))
        parsed = parse(message)
        mentions_me = self.directory.mentions(parsed, message)
        fresh = time.time() - int(rec.get("messageTimestamp") or 0) < max(fresh_for, POLL_CLOSED * 3)
        if key.get("fromMe") or not fresh or not parsed or parsed["kind"] in ("reaction", "unsupported"):
            return
        participant = sender_jid(rec)
        group = jid.endswith("@g.us")
        sender = ""
        if group:
            sender = self.directory.name(participant) or valid_push(rec.get("pushName"), self.directory.me) or self.directory.phone(participant)
        name = self.directory.name(jid) or (valid_push(rec.get("pushName"), self.directory.me) if not group else "") or self.directory.phone(jid)
        emit("incoming", jid=jid, name=name, group=group, sender=sender, mentionsMe=mentions_me,
             preview=preview(parsed), avatar=self.avatar_path(jid))


def mic_volume():
    """Volume (%) of the default microphone, -1 when unknown."""
    try:
        out = subprocess.run(["pactl", "get-source-volume", "@DEFAULT_SOURCE@"],
                             capture_output=True, text=True, timeout=3).stdout
        values = [int(v) for v in re.findall(r"(\d+)%", out)]
        return min(values) if values else -1
    except (OSError, subprocess.SubprocessError, ValueError):
        return -1


def prune_media(budget=MEDIA_BUDGET):
    """Keep saved media under the budget, dropping the oldest files first."""
    try:
        files = [os.path.join(MEDIA_DIR, n) for n in os.listdir(MEDIA_DIR)]
        files = [(os.path.getmtime(f), os.path.getsize(f), f) for f in files if os.path.isfile(f)]
    except OSError:
        return
    total = sum(size for _, size, _ in files)
    for _, size, path in sorted(files):
        if total <= budget:
            break
        try:
            os.remove(path)
            total -= size
        except OSError:
            pass


def detached(args):
    subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)


# ------------------------------------------------------------------ self-test

def self_test():
    assert valid_push("Alex", "Sam") == "Alex"
    assert valid_push("Sam", "Sam") == ""
    assert valid_push("Você") == ""
    assert valid_push(".") == "" and valid_push("10000000000002") == ""
    assert format_phone("212600000001@s.whatsapp.net") == "+212 6 00 00 00 01"
    assert format_phone("33612345678@s.whatsapp.net") == "+33612345678"
    assert format_phone("10000000000001@lid") == ""
    assert unwrap({"ephemeralMessage": {"message": {"conversation": "hi"}}}) == {"conversation": "hi"}
    assert parse({"conversation": "a\nb"})["text"] == "a\nb"
    assert parse({"messageContextInfo": {}}) is None
    assert parse({"protocolMessage": {}, "messageContextInfo": {}}) is None
    assert parse({"imageMessage": {"caption": "c", "jpegThumbnail": "/9j/AA=="}})["thumb"] == "/9j/AA=="
    assert parse({"imageMessage": {"jpegThumbnail": "<img src=x>"}})["thumb"] == ""
    assert parse({"documentMessage": {"fileName": "../../etc/passwd", "fileLength": {"low": 5}}})["fileName"] == "passwd"
    assert parse({"fooMessage": {}})["kind"] == "unsupported"
    assert preview(parse({"conversation": "  a\n\n b "}))["text"] == "a b"
    assert status_of({"status": "SERVER_ACK", "MessageUpdate": [{"status": "READ"}, {"status": "DELIVERY_ACK"}]}) == "read"
    rows = [
        {"key": {"fromMe": False, "remoteJid": "g", "participant": "a"}, "messageTimestamp": 1,
         "message": {"reactionMessage": {"key": {"id": "M"}, "text": "😂"}}},
        {"key": {"fromMe": True, "remoteJid": "g"}, "messageTimestamp": 2,
         "message": {"reactionMessage": {"key": {"id": "M"}, "text": "😂"}}},
        {"key": {"fromMe": False, "remoteJid": "g", "participant": "b"}, "messageTimestamp": 3,
         "message": {"reactionMessage": {"key": {"id": "M"}, "text": "👍"}}},
        {"key": {"fromMe": False, "remoteJid": "g", "participant": "b"}, "messageTimestamp": 4,
         "message": {"reactionMessage": {"key": {"id": "M"}, "text": ""}}},
    ]
    assert collect_reactions(rows) == {"M": [{"emoji": "😂", "count": 2, "mine": True}]}
    d = Directory()
    d.me = "Sam"
    d.names["212600000001@s.whatsapp.net"] = "Alex"
    d.map_lid("10000000000001@lid", "212600000001@s.whatsapp.net")
    assert d.name("10000000000001@lid") == "Alex"
    assert d.phone("10000000000001@lid") == "+212 6 00 00 00 01"
    d.learn_record({"key": {"fromMe": False, "remoteJid": "9@lid"}, "pushName": "Sam"})
    assert d.name("9@lid") == ""
    d.learn_record({"key": {"fromMe": False, "remoteJid": "9@lid"}, "pushName": "Sara"})
    assert d.name("9@lid") == "Sara"
    assert media_error_code(ApiError("chat/getBase64FromMediaMessage 400 Failed to fetch stream")) == "mediaExpired"
    assert sender_jid({"key": {"participant": "1@lid"}}) == "1@lid"
    assert sender_jid({"key": {}, "pushName": "10000000000003"}) == "10000000000003@lid"
    assert sender_jid({"key": {}, "pushName": "Sara"}) == ""
    assert picture_id("https://pps.whatsapp.net/v/t61.24694-24/111111111_2222222222222222_3333333333333333333_n.jpg?ccb=1") == "111111111_2222222222222222_3333333333333333333"
    global COUNTRY
    COUNTRY = "212"
    assert phone_digits("06 00 00 00 01") == "212600000001"
    COUNTRY = ""
    assert phone_digits("06 00 00 00 01") == "0600000001"
    assert phone_digits("+33 6 12 34 56 78") == "33612345678" and phone_digits("0033612345678") == "33612345678"
    assert phone_digits("hello") == ""
    assert media_type("image/png") == "image" and media_type("application/pdf") == "document"
    d2 = Directory()
    d2.set_avatar("212600000000@s.whatsapp.net", "https://pps.whatsapp.net/v/x/1_2_3_n.jpg?a")
    d2.set_avatar("55@lid", "https://pps.whatsapp.net/v/x/1_2_3_n.jpg?b")
    assert d2.phone_jid("55@lid") == "212600000000@s.whatsapp.net"
    d2.rename("55@lid", "  Ali  B ")
    assert d2.name("55@lid") == "Ali B" and d2.name("212600000000@s.whatsapp.net") == "Ali B"
    d2.rename("55@lid", "")
    assert d2.name("55@lid") == ""
    g = [{"participants": [{"id": "1@lid"}, {"id": f"{i}0@lid"}]} for i in range(5)]
    assert own_lid(g) == "1@lid" and own_lid(g[:2]) == ""
    assert is_deleted({"key": {"deleted": True}}) and is_deleted({"MessageUpdate": [{"status": "DELETED"}]})
    assert not is_deleted({"key": {}, "MessageUpdate": [{"status": "READ"}]})
    assert parse(unwrap({"viewOnceMessageV2": {"message": {"imageMessage": {}}}}))["kind"] == "viewOnce"
    assert parse({"audioMessage": {"viewOnce": True}}) == {"kind": "viewOnce", "media": "audio", "text": ""}
    assert parse({"imageMessage": {"caption": "x"}})["kind"] == "image"
    assert preview(parse({"videoMessage": {"viewOnce": True}}))["media"] == "video"
    d3 = Directory()
    d3.my_jids = {"1@lid", "2126@s.whatsapp.net"}
    d3.names["2127@s.whatsapp.net"] = "Sara"
    msg = {"extendedTextMessage": {"text": "hi @2127 and @1", "contextInfo": {"mentionedJid": ["2127@s.whatsapp.net", "1@lid"]}}}
    pm = parse(msg)
    assert d3.mentions(pm, msg) is True and pm["text"] == "hi @Sara and @you"
    assert status_of({"status": "PENDING"}, "READ") == "read"
    assert status_of({"status": "DELIVERY_ACK"}, "SERVER_ACK") == "delivered"
    d4 = Directory()
    d4.names["2125@s.whatsapp.net"] = "Help Desk"
    d4.link("9@lid", "2125@s.whatsapp.net")
    assert d4.phone_jid("9@lid") == "2125@s.whatsapp.net" and d4.name("9@lid") == "Help Desk"
    d4.link("9@lid", "")
    assert d4.phone_jid("9@lid") == ""
    assert slug("My phone") == "my-phone" and slug("Work 2") == "work-2"
    print("self-test ok")


def main(argv):
    global EXCHANGE, COUNTRY
    if argv == ["--self-test"]:
        self_test()
        return
    args, options = [], {}
    it = iter(argv)
    for arg in it:
        if arg in ("--exchange", "--country"):
            options[arg] = next(it, "")
        else:
            args.append(arg)
    if len(args) != 1:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    EXCHANGE = options.get("--exchange") or EXCHANGE
    COUNTRY = re.sub(r"\D", "", options.get("--country") or "")
    if args[0].strip().lower() == "demo":
        from demo import Demo
        Demo().run()
        return
    try:
        backend = Backend(args[0])
    except NotConfigured as e:
        # Say what is missing once, then idle (the shell would restart us in a loop).
        emit("status", connection="notConfigured", listener=False)
        emit("error", code="notConfigured", detail=str(e))
        for _ in sys.stdin:
            pass
        return
    backend.run()


if __name__ == "__main__":
    main(sys.argv[1:])
