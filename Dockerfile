FROM caddy:2-alpine AS caddy-bin

FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

ARG HERMES_REF=v2026.4.30
ARG SUPERCRONIC_VERSION=v0.2.45
ARG SUPERCRONIC_SHA256_AMD64=bb6da5af8d5547c9a5cbb4cf58d9f5541f0433df2188bfe4f1a54b04ad253db6
ARG SUPERCRONIC_SHA256_ARM64=c0f21174f7bb3c80a9b33567ba0cfbeb3e51e765fe9808267ba72a1ac88c3dba

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates git tini gnupg && \
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

# supercronic: container-native cron. Single static binary, reads a crontab
# file in the foreground, logs to stdout. Runs as a background sibling of
# the gateway in start.sh (see "Cron jobs" in README.md).
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) sha="$SUPERCRONIC_SHA256_AMD64"; asset="supercronic-linux-amd64" ;; \
      arm64) sha="$SUPERCRONIC_SHA256_ARM64"; asset="supercronic-linux-arm64" ;; \
      *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/${asset}"; \
    echo "${sha}  /usr/local/bin/supercronic" | sha256sum -c -; \
    chmod +x /usr/local/bin/supercronic

COPY --from=caddy-bin /usr/bin/caddy /usr/local/bin/caddy

RUN git clone --depth 1 --branch ${HERMES_REF} https://github.com/NousResearch/hermes-agent.git /opt/hermes-agent && \
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

COPY Caddyfile.tmpl /app/Caddyfile.tmpl
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

ENV HOME=/data
ENV HERMES_HOME=/data/.hermes

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/start.sh"]
