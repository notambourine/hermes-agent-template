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

# `hermes gateway` writes /data/.hermes/gateway.pid on start but does not
# remove it on SIGTERM. Because /data is a persistent volume, the file
# survives container restarts (including the Restart Gateway button, which
# trips `wait -n` and respawns the whole container) and causes every
# subsequent boot to exit with "ERROR gateway.run: PID file race lost to
# another gateway instance". No hermes process can be running at this
# point — we're pre-exec in a fresh container — so removing it is safe.
rm -f /data/.hermes/gateway.pid

: "${TUNNEL_TOKEN:?TUNNEL_TOKEN must be set — see README for Cloudflare Tunnel setup}"

# Hermes itself defaults this to false; for a public template we flip it.
# Set HERMES_REDACT_SECRETS=false in Railway Variables to opt back in to verbatim logs for debugging.
export HERMES_REDACT_SECRETS="${HERMES_REDACT_SECRETS:-true}"

# Surface the running Hermes version in Railway deploy logs (the image bakes
# a pinned release; this is the runtime ground truth).
echo "Hermes version: $(hermes --version 2>&1 | head -1)"

# Three siblings under tini -g. wait -n exits on any child death so Railway
# restarts the container if any of them dies (cloudflared losing its tunnel,
# the dashboard crashing, or the gateway exiting all trigger a fresh boot).
# NOTE: --tui was removed from `hermes dashboard` in 0.16 (hermes-agent#38591);
# passing it crash-loops the container on unrecognized-argument exit.
cloudflared tunnel --no-autoupdate run --token "$TUNNEL_TOKEN" &
hermes dashboard --host 127.0.0.1 --port 9119 --no-open &
hermes gateway run --replace &

wait -n
exit $?
