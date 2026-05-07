FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

ARG HERMES_REF=main

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

# cloudflared: terminates a Cloudflare Tunnel from inside the container.
# Connects outbound to Cloudflare's edge, forwards inbound traffic to the
# Hermes dashboard on 127.0.0.1:9119. Cloudflare Access handles auth.
RUN curl -fsSLo /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$(dpkg --print-architecture)" && \
    chmod +x /usr/local/bin/cloudflared

# Cache-bust the Hermes clone layer when ${HERMES_REF} advances upstream.
ADD https://api.github.com/repos/NousResearch/hermes-agent/commits/${HERMES_REF} /tmp/hermes-commit.json

RUN git clone --depth 1 --branch ${HERMES_REF} https://github.com/NousResearch/hermes-agent.git /opt/hermes-agent && \
    cd /opt/hermes-agent && \
    uv pip install --system --no-cache -e ".[all]" && \
    cd /opt/hermes-agent/web && \
    npm install --silent && \
    npm run build && \
    cd /opt/hermes-agent/ui-tui && \
    npm install --silent --no-fund --no-audit --progress=false && \
    npm run build && \
    rm -rf /opt/hermes-agent/web /opt/hermes-agent/.git /root/.npm /tmp/hermes-commit.json

RUN mkdir -p /data/.hermes /app

COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

ENV HOME=/data
ENV HERMES_HOME=/data/.hermes

ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/app/start.sh"]
