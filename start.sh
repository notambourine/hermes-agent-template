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

# Clear ALL stale single-instance gateway state from the previous container.
#
# The dashboard's "Restart Gateway" button runs `hermes gateway restart`, which
# SIGTERMs the running gateway. That gateway is start.sh's `wait -n` child, so its
# death ends PID 1 and Railway restarts the whole container — which is fine and
# Railway-aligned (let the platform supervise; we don't hand-roll one). The
# problem was the NEXT boot crash-looping with "PID file race lost to another
# gateway instance": `hermes gateway` writes state under HERMES_HOME on the /data
# volume and does NOT clean it on SIGTERM/SIGKILL, so the survivors persist across
# the restart. Clearing only gateway.pid wasn't enough — gateway/status.py's
# get_running_pid() falls back to gateway_state.json when the pid file is absent,
# so a hard-killed container leaves that file claiming "running" and the fresh
# gateway loses the race. Clear the whole set (paths from gateway/status.py):
#   gateway.pid                  PID file
#   gateway.lock                 runtime mutual-exclusion lock (fcntl auto-releases
#                                on death, but remove the file for tidiness)
#   gateway_state.json           persisted runtime status — the real culprit
#   .gateway-takeover.json       --replace handoff marker
#   .gateway-planned-stop.json   planned-stop marker
# We're pre-exec in a fresh container — no hermes process can be running — so every
# one of these is stale by definition and safe to remove. (Multiplex serves all
# profiles from this one gateway, so its state is here at HERMES_HOME, not per
# profile.)
rm -f /data/.hermes/gateway.pid \
      /data/.hermes/gateway.lock \
      /data/.hermes/gateway_state.json \
      /data/.hermes/.gateway-takeover.json \
      /data/.hermes/.gateway-planned-stop.json

# ── Import read-only skills from the /opt/hermes-skills image layer ────────────
# The Dockerfile clones github.com/notambourine/hermes-skills to /opt/hermes-skills.
# We register its skills/ dir as an EXTERNAL (read-only) discovery root so the
# agent can use those skills; we never create cron jobs here. A skill that wants a
# recurring job ships its own install reference and the agent runs `hermes cron
# create` on request (see the hermes-skills README) — cron creation belongs in a
# real turn, not container boot.
#
# config.yaml's `skills.external_dirs` is owned by this template: agent/skill_utils.py
# get_external_skills_dirs() reads it as a YAML LIST, so we must store a real list.
# `hermes config set` only coerces bool/int/float (config.py set_config_value); a
# JSON list literal would be stored as a string, so we rewrite the key with pyyaml
# (a hard Hermes dependency). Hermes auto-skips the volume's own skills dir, so this
# only ADDS the repo root — user-/dashboard-authored skills on /data are untouched.
# Idempotent each boot; never writes the repo back. A failure warns rather than
# crash-looping the container.
if [ -d /opt/hermes-skills/skills ]; then
  python3 - <<'PY' || echo "WARN: could not register skills.external_dirs — repo skills will not load." >&2
import yaml, pathlib
cfg_path = pathlib.Path("/data/.hermes/config.yaml")
cfg = yaml.safe_load(cfg_path.read_text()) if cfg_path.exists() else {}
if not isinstance(cfg, dict):
    cfg = {}
cfg.setdefault("skills", {})
# Template-owned: assert exactly this one external root each boot (idempotent).
cfg["skills"]["external_dirs"] = ["/opt/hermes-skills/skills"]
cfg_path.write_text(yaml.safe_dump(cfg, sort_keys=False))
PY
fi

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
# a pinned release; this is the runtime ground truth).
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
