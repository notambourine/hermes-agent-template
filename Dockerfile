FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

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

# Track the latest Hermes RELEASE rather than a fixed pin. The ADD fetches the
# GitHub "latest release" metadata on every build; BuildKit only re-runs it — and
# the clone below, which reads the file — when the response changes, i.e. when a
# new release ships. That is what makes a Railway "Redeploy" actually pull new
# code: without this cache-bust the clone layer would be reused and you'd
# redeploy the same Hermes commit forever. Pin a specific tag/branch/SHA for a
# one-off build with --build-arg HERMES_REF=<ref> (empty default = resolve latest).
#
# KEY-DECISION 2026-06-26: reverted the v2026.6.19 pin + daily bump-PR
# (KEY-DECISION 2026-06-06) to latest-release tracking — the operator clicks
# Redeploy in Railway when they want the newest release. Eyes-open trade-off:
# there is no changelog gate before deploy, so a release that removes a CLI flag
# start.sh depends on (cf. 0.16 removing dashboard --tui) surfaces as a deploy-log
# crash-loop instead of a reviewable PR. start.sh's `|| echo WARN` guards soften
# but don't eliminate that. Tracking the latest *release* (not main) limits the
# blast radius to intentionally-cut versions.
ARG HERMES_REF=
ADD https://api.github.com/repos/NousResearch/hermes-agent/releases/latest /tmp/hermes-release.json

RUN HERMES_REF="${HERMES_REF:-$(jq -r .tag_name /tmp/hermes-release.json)}" && \
    echo "Building against Hermes ${HERMES_REF}" && \
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
