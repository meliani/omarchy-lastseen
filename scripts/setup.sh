#!/usr/bin/env bash
# Last Seen — desktop setup: connect the bar to your Evolution API server.
#
# Asks for the server address, your account (Evolution instance) and its token,
# checks them, stores the secrets in your keyring (never in a file), installs
# what the plugin needs and turns the account on in the bar.
#
#   scripts/setup.sh            # interactive
#   scripts/setup.sh --remove   # forget every Last Seen secret on this machine
set -euo pipefail

PLUGIN=meliani.lastseen
SERVICE=lastseen

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'; }
store() { printf '%s' "$2" | secret-tool store --label="Last Seen: $1" service "$SERVICE" key "$1"; }

if [[ "${1:-}" == "--remove" ]]; then
  secret-tool clear service "$SERVICE" && say "Removed every Last Seen secret from the keyring."
  exit 0
fi

command -v secret-tool >/dev/null || die "secret-tool is missing (package libsecret)"
command -v jq >/dev/null || die "jq is missing (omarchy pkg add jq)"

ask() {   # ask "Question" [default] [--password]
  local value
  if command -v gum >/dev/null; then
    if [[ "${3:-}" == "--password" ]]; then value=$(gum input --password --placeholder "$1")
    else value=$(gum input --placeholder "$1" --value "${2:-}"); fi
  else
    if [[ "${3:-}" == "--password" ]]; then read -rsp "$1: " value; echo >&2
    else read -rp "$1${2:+ [$2]}: " value; value=${value:-${2:-}}; fi
  fi
  printf '%s' "$value"
}

echo "Last Seen connects to your own Evolution API server."
echo "No server yet? See server/ in the repository (one command with Docker)."
echo

current_url=$(secret-tool lookup service "$SERVICE" key url 2>/dev/null || true)
url=$(ask "Evolution API URL, e.g. https://evolution.example.com" "$current_url")
url=${url%/}
[[ "$url" =~ ^https?:// ]] || die "the URL must start with https:// or http://"

accounts=()
while :; do
  name=$(ask "Account to add (Evolution instance name), empty to finish" "")
  [[ -z "$name" ]] && break
  token=$(ask "API token of \"$name\" (the instance token)" "" --password)
  [[ -n "$token" ]] || die "a token is required"
  enc=$(jq -rn --arg v "$name" '$v | @uri')
  # The reply is JSON data; jq reads one field from it.
  reply=$(curl -fsS -H "apikey: $token" -H "User-Agent: curl/8.0" "$url/instance/connectionState/$enc" 2>/dev/null || true)
  state=$(jq -r '(.instance // .).state // empty' <<<"$reply" 2>/dev/null || true)
  [[ -n "$state" ]] || die "could not reach \"$name\" at $url with that token"
  store "$(slug "$name")-token" "$token"
  accounts+=("$name")
  say "\"$name\" is connected (WhatsApp state: $state)"
done
# Keep the accounts already set up on this machine (their token is in the keyring).
IFS=, read -ra existing <<<"$(omarchy bar get "$PLUGIN" accounts 2>/dev/null || true)"
kept=()
for old in "${existing[@]}"; do
  old=$(printf '%s' "$old" | sed -E 's/^ +| +$//g')
  [[ -z "$old" || " ${accounts[*]} " == *" $old "* ]] && continue
  if [[ "$old" == demo* ]] || secret-tool lookup service "$SERVICE" key "$(slug "$old")-token" >/dev/null 2>&1; then
    kept+=("$old")
  fi
done
accounts=("${kept[@]}" "${accounts[@]}")
(( ${#accounts[@]} )) || die "add at least one account"
store url "$url"

amqp=$(ask "RabbitMQ URI for instant updates (optional, Enter to skip: the plugin polls)" "" --password)
if [[ -n "$amqp" ]]; then
  [[ "$amqp" =~ ^amqps?:// ]] || die "the RabbitMQ URI must start with amqp:// or amqps://"
  store amqp-uri "$amqp"
fi

country=$(ask "Your country calling code, for local numbers like 06… (optional, e.g. 33, 212)" "")

# ---- what the plugin uses: notifications, clipboard, playback, recording, push
missing=()
for pair in notify-send:libnotify wl-copy:wl-clipboard mpv:mpv ffmpeg:ffmpeg; do
  command -v "${pair%%:*}" >/dev/null || missing+=("${pair#*:}")
done
pacman -Qq python-pika >/dev/null 2>&1 || missing+=(python-pika)
if (( ${#missing[@]} )); then
  say "Installing ${missing[*]} (Omarchy's package helper asks before changing anything)"
  omarchy pkg add "${missing[@]}" || echo "Install them later with: omarchy pkg add ${missing[*]}"
fi

# ---- turn it on
list=$(IFS=,; echo "${accounts[*]}")
omarchy plugin enable "$PLUGIN" >/dev/null 2>&1 || true
omarchy bar set "$PLUGIN" accounts "$list" >/dev/null
[[ -n "$country" ]] && omarchy bar set "$PLUGIN" countryCode "${country//[^0-9]/}" >/dev/null
say "Done. Click the Last Seen icon in your bar."
