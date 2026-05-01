#!/bin/bash
set -euo pipefail

# Required: tini delivers SIGTERM here, we forward to the gateway via `exec`.

mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/pairing \
         /data/.hermes/hooks /data/.hermes/image_cache /data/.hermes/audio_cache \
         /data/.hermes/workspace

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi
[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

# `hermes gateway run --replace` (added upstream) supersedes the manual
# stale-PID cleanup the old server.py needed.

: "${ADMIN_USERNAME:?ADMIN_USERNAME must be set}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD must be set}"
: "${PORT:=8080}"

# bcrypt hash so plaintext never lands on disk
ADMIN_PASSWORD_HASH="$(caddy hash-password --plaintext "$ADMIN_PASSWORD")"
export ADMIN_USERNAME ADMIN_PASSWORD_HASH PORT

# Caddy's own envsubst-equivalent is `{$VAR}` in Caddyfile syntax, so we
# can hand it the template directly.
cp /app/Caddyfile.tmpl /tmp/Caddyfile

# Native dashboard on loopback — Caddy fronts it with basic auth at the edge.
hermes dashboard --host 127.0.0.1 --port 9119 --no-open --tui &

caddy run --config /tmp/Caddyfile --adapter caddyfile &

# Foreground: tini → start.sh → exec → hermes gateway. SIGTERM reaches the
# gateway directly so its own shutdown handlers run.
exec hermes gateway run --replace
