FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

# Pinned Hermes release. A daily GitHub Action (.github/workflows/hermes-bump.yml)
# opens a draft PR when upstream cuts a new release — review the changelog, merge,
# Railway auto-deploys. Changing this value busts the clone layer's cache, so no
# remote-ADD revalidation trick is needed. Override per-build with
# --build-arg HERMES_REF=<tag|branch|SHA>.
# KEY-DECISION 2026-06-06: pin + bump-PR replaces resolve-latest-at-build-time —
# 0.16 removed the dashboard --tui flag and a blind rebuild would have crash-looped.
ARG HERMES_REF=v2026.7.1

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

# NOTE: the team-shared skills repo (github.com/notambourine/hermes-skills) is
# NOT baked into the image. start.sh clones it into the /data volume at boot and
# refreshes it on every restart, so a push to hermes-skills reaches the agent
# WITHOUT an image rebuild, and the `update-ntb-skills` skill can `git pull` it
# mid-session. A baked layer would be immutable (no in-place pull) and would
# freeze skills at image-build time. `git` is already installed above.
# KEY-DECISION 2026-06-26: runtime clone into /data over a build-time image layer
# so new/changed skills auto-update on restart (and on-demand via a skill) with
# no template rebuild; the hermes-skills repo stays the single source of truth.
# Defaults for the runtime clone (override via Railway Variables):
ENV HERMES_SKILLS_REPO=https://github.com/notambourine/hermes-skills.git
ENV HERMES_SKILLS_REF=main
ENV HERMES_SKILLS_DIR=/data/.hermes/external-skills

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
