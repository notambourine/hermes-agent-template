#!/bin/bash
set -euo pipefail

mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/pairing \
         /data/.hermes/hooks /data/.hermes/image_cache /data/.hermes/audio_cache \
         /data/.hermes/workspace

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi
[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

: "${TUNNEL_TOKEN:?TUNNEL_TOKEN must be set — see README for Cloudflare Tunnel setup}"

# Three siblings under tini -g. wait -n exits on any child death so Railway
# restarts the container if any of them dies (cloudflared losing its tunnel,
# the dashboard crashing, or the gateway exiting all trigger a fresh boot).
cloudflared tunnel --no-autoupdate run --token "$TUNNEL_TOKEN" &
hermes dashboard --host 127.0.0.1 --port 9119 --no-open --tui &
hermes gateway run --replace &

wait -n
exit $?
