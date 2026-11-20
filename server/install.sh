#!/usr/bin/env bash
# Last Seen — Evolution API server in one command.
#
#   ./install.sh                 # start everything, create the account, show the QR code
#   ./install.sh "Work phone"    # same, with another account (Evolution instance) name
#
# Run it again any time: it keeps your secrets and only adds what's missing.
set -euo pipefail
cd "$(dirname "$0")"

INSTANCE="${1:-my-phone}"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required ($2)"; }

need docker "https://docs.docker.com/engine/install/"
need curl "your package manager"
need python3 "your package manager"
docker compose version >/dev/null 2>&1 || die "the Docker Compose plugin is required"

random() { python3 -c 'import secrets; print(secrets.token_hex(24))'; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1]))" "$1"; }

# ---- secrets: generated once, kept in .env
[[ -f .env ]] || cp .env.example .env
for key in EVOLUTION_API_KEY POSTGRES_PASSWORD RABBITMQ_PASSWORD DESKTOP_AMQP_PASSWORD; do
  if ! grep -qE "^$key=.+" .env; then
    value=$(random)
    if grep -qE "^$key=" .env; then sed -i "s|^$key=.*|$key=$value|" .env; else echo "$key=$value" >>.env; fi
  fi
done
chmod 600 .env
set -a; . ./.env; set +a

profile=()
[[ -n "${EVOLUTION_DOMAIN:-}" ]] && profile=(--profile https)

say "Starting Evolution API, Postgres, Redis and RabbitMQ"
docker compose "${profile[@]}" up -d

API="http://127.0.0.1:${EVOLUTION_PORT:-8080}"
say "Waiting for the API on $API"
for _ in $(seq 1 90); do
  curl -fsS "$API/" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS "$API/" >/dev/null || die "the API did not come up: docker compose logs evolution"

# ---- the desktop's own RabbitMQ user: may only read its lastseen.* queues
say "Creating the RabbitMQ user for your desktop"
rmq() { docker compose exec -T rabbitmq rabbitmqctl "$@" >/dev/null; }
rmq add_user lastseen "$DESKTOP_AMQP_PASSWORD" 2>/dev/null || rmq change_password lastseen "$DESKTOP_AMQP_PASSWORD"
rmq set_permissions -p / lastseen '^lastseen\..*' '^(lastseen\..*|evolution)$' '^(lastseen\..*|evolution)$'

# ---- the WhatsApp account
call() { curl -fsS -H "apikey: $EVOLUTION_API_KEY" -H "Content-Type: application/json" "$@"; }
enc=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$INSTANCE")
if call "$API/instance/fetchInstances?instanceName=$enc" 2>/dev/null | grep -q '"name"'; then
  say "Account \"$INSTANCE\" already exists"
else
  say "Creating account \"$INSTANCE\""
  call -X POST "$API/instance/create" \
    -d "{\"instanceName\": \"$INSTANCE\", \"integration\": \"WHATSAPP-BAILEYS\", \"qrcode\": true}" >/dev/null
fi
token=$(call "$API/instance/fetchInstances?instanceName=$enc" | json 'd[0]["token"]')
state=$(call "$API/instance/connectionState/$enc" | json 'd.get("instance", d).get("state", "")')

if [[ "$state" != "open" ]]; then
  say "Link your phone: WhatsApp > Settings > Linked devices > Link a device"
  qr=$(call "$API/instance/connect/$enc")
  code=$(printf '%s' "$qr" | json 'd.get("code", "")')
  if command -v qrencode >/dev/null && [[ -n "$code" ]]; then
    qrencode -t ansiutf8 "$code"
  else
    printf '%s' "$qr" | json 'd.get("base64", "")' | sed 's/^data:image\/png;base64,//' | base64 -d >qr.png 2>/dev/null \
      && echo "QR code saved to $(pwd)/qr.png (install qrencode to see it here)"
  fi
  echo "The code changes every ~40 s: run ./install.sh \"$INSTANCE\" again for a fresh one,"
  echo "or open the manager at ${SERVER_URL%/}/manager (API key below)."
fi

host=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.urlparse(sys.argv[1]).hostname or "localhost")' "$SERVER_URL")
cat <<EOF

$(printf '\033[1;32m')Server ready.$(printf '\033[0m') On your Omarchy desktop, run the plugin's setup and paste these:

  Evolution URL   $SERVER_URL
  Account         $INSTANCE
  Account token   $token
  RabbitMQ URI    amqp://lastseen:$DESKTOP_AMQP_PASSWORD@$host:${AMQP_PORT:-5672}/   (optional, for instant updates)

  Setup command   ~/.config/omarchy/plugins/meliani.lastseen/scripts/setup.sh

Manager UI: ${SERVER_URL%/}/manager — log in with the API key stored in $(pwd)/.env
EOF
