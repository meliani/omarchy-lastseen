# Contributing to Last Seen

Thanks for helping. Bug reports, ideas, translations and pull requests are all welcome.

## Try your change without a server

The demo account needs no Evolution API and no phone, and shows every kind of message:

```bash
# work on a clone that Omarchy loads directly
git clone https://github.com/<you>/omarchy-lastseen ~/.config/omarchy/plugins/meliani.lastseen
omarchy bar put meliani.lastseen --section right
omarchy bar set meliani.lastseen accounts "demo, demo-work"   # two fictional accounts
```

After editing QML, run `omarchy restart shell` (or save twice: the shell reloads plugins on save).
Errors show up in `journalctl --user -f | grep -i lastseen`.

Handy from a terminal:

```bash
omarchy-shell meliani.lastseen open               # open the panel
omarchy-shell meliani.lastseen openChat maya@demo # open a chat
omarchy-shell meliani.lastseen state              # what the panel shows, as JSON
```

## Where things are

| File | What it does |
| --- | --- |
| `backend.py` | One process per account: Evolution API (REST), RabbitMQ, caches, media, voice recording. Speaks JSON lines on stdin/stdout. |
| `demo.py` | The demo account: fictional data, same protocol. |
| `Service.qml` | Runs one backend and holds its state for the panel. |
| `Panel.qml` | Bar icon, panel, chat list, conversation, account switcher, notifications. |
| `MessageItem.qml`, `ChatRow.qml`, `ProfilePage.qml`, `Avatar.qml` | The pieces of the panel. |
| `Model.js` | Pure display logic (times, previews, search, links, presence). |
| `i18n/*.json` | Strings, one file per language. |
| `server/` | Docker Compose kit for Evolution API. |
| `scripts/setup.sh` | Desktop setup: secrets in the keyring, dependencies, accounts. |

The command and event protocol between the panel and `backend.py` is listed at the top of `backend.py`.

## Before you open a pull request

```bash
python3 backend.py --self-test
node tests/model.test.js
omarchy plugin validate .
```

- Keep the plugin light: no new dependencies unless they save real code, nothing that runs a browser.
- Show message content with `textFormat: Text.PlainText` (or through `Model.linkify`, which escapes everything first). Never put text from a message into rich text.
- New behavior in `backend.py` or `Model.js` gets a check in `self_test()` or `tests/model.test.js`.
- New strings go in `i18n/en.json` (and `fr.json` if you can; otherwise English is used).
- Never commit real phone numbers, names or screenshots of real chats: use the demo account.

## Translations

Copy `i18n/en.json` to `i18n/<code>.json` with the Omarchy language code (`de`, `es`, `pt-BR`…) and translate the values. Missing keys fall back to English.

## Reporting a bug

Open an issue with your Omarchy version, Evolution API version, what you did, what you expected and the output of
`journalctl --user --since "10 min ago" | grep -i lastseen`. Remove tokens and phone numbers first.
Security problems: see [SECURITY.md](SECURITY.md) instead.
