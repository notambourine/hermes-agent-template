#!/bin/bash
set -euo pipefail

mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/pairing \
         /data/.hermes/hooks /data/.hermes/image_cache /data/.hermes/audio_cache \
         /data/.hermes/workspace /data/.hermes/profiles

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi
[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

# Multi-profile ready by default. With gateway.multiplex_profiles on, the single
# gateway this container runs serves EVERY profile under /data/.hermes/profiles/<name>/
# — each with its own bot tokens, .env, sessions, and memory — through /p/<name>/
# URL prefixes, while the default profile is untouched (agent:main namespace, bare
# /webhooks). Create and configure additional agents from the dashboard's profile
# switcher; no shell access needed.
#
# config.yaml is the ONLY control surface for this key: no HERMES_* env var maps to
# it (gateway/config.py reads multiplex_profiles only from config.yaml) and the
# dashboard exposes no toggle. Without this line a profile created in the dashboard
# would exist on disk but the lone gateway would silently never serve it
# (multiplex_profiles defaults false -> profiles_to_serve() returns only the active
# profile). We assert it from a Railway-overridable variable each boot so that
# variable stays the source of truth: set HERMES_MULTIPLEX_PROFILES=false to run one
# profile per Railway service instead. A removed/renamed CLI verb in a future Hermes
# bump warns rather than crash-loops the container (cf. the 0.16 --tui lesson).
if [ "${HERMES_MULTIPLEX_PROFILES:-true}" = "true" ]; then
  hermes config set gateway.multiplex_profiles true \
    || echo "WARN: could not enable gateway.multiplex_profiles — verify the 'hermes config set' CLI surface in this release." >&2
else
  hermes config set gateway.multiplex_profiles false || true
fi

# `hermes gateway` writes /data/.hermes/gateway.pid on start but does not
# remove it on SIGTERM. Because /data is a persistent volume, the file
# survives container restarts (including the Restart Gateway button, which
# trips `wait -n` and respawns the whole container) and causes every
# subsequent boot to exit with "ERROR gateway.run: PID file race lost to
# another gateway instance". No hermes process can be running at this
# point — we're pre-exec in a fresh container — so removing it is safe.
rm -f /data/.hermes/gateway.pid

# Fail fast on missing dashboard credentials. Binding non-loopback without
# --insecure engages Hermes' fail-closed auth gate: with no provider
# configured the dashboard would start but lock everyone out, which reads
# as "site broken" instead of "variable missing".
: "${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:?set in Railway Variables — dashboard login username}"
if [ -z "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH:-}" ] && [ -z "${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-}" ]; then
  echo "ERROR: set HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH (preferred) or" >&2
  echo "       HERMES_DASHBOARD_BASIC_AUTH_PASSWORD in Railway Variables." >&2
  exit 1
fi
if [ -z "${HERMES_DASHBOARD_BASIC_AUTH_SECRET:-}" ]; then
  echo "WARN: HERMES_DASHBOARD_BASIC_AUTH_SECRET unset — dashboard logins won't survive container restarts." >&2
fi

# Hermes itself defaults this to false; for a public template we flip it.
# Set HERMES_REDACT_SECRETS=false in Railway Variables to opt back in to verbatim logs for debugging.
export HERMES_REDACT_SECRETS="${HERMES_REDACT_SECRETS:-true}"

# Surface the running Hermes version in Railway deploy logs (the image bakes
# whichever release was latest at build time; this is the runtime ground truth).
echo "Hermes version: $(hermes --version 2>&1 | head -1)"

# Two siblings under tini -g. wait -n exits on any child death so Railway
# restarts the container if either dies.
#
# Dashboard binds 0.0.0.0:$PORT (Railway injects PORT for the public domain).
# Non-loopback WITHOUT --insecure engages the gated auth mode: login page,
# scrypt-verified credentials, per-IP rate limit (10/min), HMAC session
# cookies, and uvicorn proxy_headers=True so Secure cookies and WS origin
# checks work behind Railway's TLS-terminating edge.
# NOTE: --tui was removed from `hermes dashboard` in 0.16 (hermes-agent#38591).
hermes dashboard --host 0.0.0.0 --port "${PORT:-9119}" --no-open &
hermes gateway run --replace &

wait -n
exit $?
