FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

# Pinned Hermes release. A daily GitHub Action (.github/workflows/hermes-bump.yml)
# opens a draft PR when upstream cuts a new release — review the changelog, merge,
# Railway auto-deploys. Changing this value busts the clone layer's cache, so no
# remote-ADD revalidation trick is needed. Override per-build with
# --build-arg HERMES_REF=<tag|branch|SHA>.
# KEY-DECISION 2026-06-06: pin + bump-PR replaces resolve-latest-at-build-time —
# 0.16 removed the dashboard --tui flag and a blind rebuild would have crash-looped.
ARG HERMES_REF=v2026.6.19

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates git tini gnupg jq && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod a+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs gh && \
    rm -rf /var/lib/apt/lists/*

RUN echo "Building against Hermes ${HERMES_REF}" && \
    git clone --depth 1 --branch "${HERMES_REF}" https://github.com/NousResearch/hermes-agent.git /opt/hermes-agent && \
    cd /opt/hermes-agent && \
    uv pip install --system --no-cache -e ".[all]" && \
    cd /opt/hermes-agent/web && \
    npm install --silent && \
    npm run build && \
    cd /opt/hermes-agent/ui-tui && \
    npm install --silent --no-fund --no-audit --progress=false && \
    npm run build && \
    rm -rf /opt/hermes-agent/web /opt/hermes-agent/.git /root/.npm

# Bake the team-shared skills repo as a READ-ONLY image layer, separate from the
# Hermes build above so editing skills never busts the (expensive) Hermes
# clone+compile cache. start.sh registers /opt/hermes-skills/skills via
# config.yaml's `skills.external_dirs` — an extra discovery root that Hermes
# scans alongside the volume's $HERMES_HOME/skills. The volume is never written
# by this: repo skills stay immutable image content, while agent/dashboard-
# authored skills keep living on /data. Cron jobs are NOT created here — a skill
# that wants one ships an install reference and the agent runs `hermes cron
# create` on request (see the hermes-skills README).
# KEY-DECISION 2026-06-26: external_dirs (read-only) over copying into the volume
# so a redeploy can never clobber user-authored skills, and the repo stays the
# single source of truth — bump HERMES_SKILLS_REF to pin/roll skills independently.
# The repo (github.com/notambourine/hermes-skills) MUST exist and be pushed
# before a build succeeds; a missing/private repo fails the clone (and the build)
# loudly rather than silently shipping no skills.
ARG HERMES_SKILLS_REF=main
RUN git clone --depth 1 --branch "${HERMES_SKILLS_REF}" \
      https://github.com/notambourine/hermes-skills.git /opt/hermes-skills && \
    rm -rf /opt/hermes-skills/.git

RUN mkdir -p /data/.hermes /app

COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

ENV HOME=/data
ENV HERMES_HOME=/data/.hermes
# Mark the TUI bundle as prebuilt so the dashboard's Chat tab runs `node dist`
# directly instead of attempting an npm rebuild at runtime (which exits and
# surfaces as "Chat unavailable" over the PTY websocket). Same fix as the
# origin template's cb66d07.
ENV HERMES_TUI_DIR=/opt/hermes-agent/ui-tui

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/start.sh"]
