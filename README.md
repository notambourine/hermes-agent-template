# Hermes Agent — Railway Template

Deploy [Hermes Agent](https://github.com/NousResearch/hermes-agent) on [Railway](https://railway.app). The Hermes web dashboard is served directly on Railway's TLS edge, protected by Hermes' built-in gated auth (scrypt-verified login, rate-limited, HMAC session cookies) — no tunnel, no reverse proxy, no SSH needed to administer it.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/hermes-agent-ai?referralCode=QXdhdr&utm_medium=integration&utm_source=template&utm_campaign=generic)

> Hermes Agent is an autonomous AI agent by [Nous Research](https://nousresearch.com/) that lives on your server, connects to your messaging channels (Telegram, Discord, Slack, etc.), and gets more capable the longer it runs.

## Features

- **Full browser admin, zero shell access** — the Hermes dashboard (0.16+) administers everything remotely: messaging channels, MCP servers, webhooks, user pairing, credentials, memory provider, gateway start/stop/restart, logs, doctor/backup ops
- **Built-in gated auth** — username/password login with scrypt hashing, per-IP rate limiting, and HMAC-signed session cookies; engages automatically (fail-closed) on a public bind
- **Keys without prompts** — set provider/channel/tool keys as Railway Variables, or paste them into the dashboard (writes the persistent volume); no interactive CLI setup
- **Latest-release tracking, one-click upgrade** — the Dockerfile resolves and clones the newest Hermes release at build time; click **Redeploy** in Railway to pull it (a cache-bust ensures the rebuild actually fetches new code). Pin a specific release for a build with `--build-arg HERMES_REF=<tag>`.

## Getting Started

### 1. LLM provider key (free)

1. Register at [OpenRouter](https://openrouter.ai/) and create an API key.
2. Pick a model from the [free tier list](https://openrouter.ai/models?order=pricing-low-to-high) (e.g. `google/gemma-3-1b-it:free`).

### 2. Telegram bot (fastest channel)

1. Message [@BotFather](https://t.me/BotFather) on Telegram, send `/newbot`, copy the **Bot Token**.
2. Find your Telegram user ID via [@userinfobot](https://t.me/userinfobot).

### 3. Deploy to Railway

1. Click **Deploy on Railway** above.
2. Set the required **Variables**:
   - `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` — your dashboard login name
   - `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` — a long random string (or set `..._PASSWORD_HASH` with a precomputed scrypt hash; see [`.env.example`](./.env.example))
   - `HERMES_DASHBOARD_BASIC_AUTH_SECRET` — `openssl rand -base64 32`; keeps logins valid across redeploys
3. Attach a **volume** mounted at `/data` (persists Hermes config, sessions, memory, cron schedules).
4. **Generate a public domain** for the service (Settings → Networking). Railway terminates TLS and proxies to the dashboard.

### 4. Configure in the Admin Dashboard

1. Open your Railway domain. The Hermes login page loads — sign in with the credentials from step 3.
2. **Config / Env** — paste your OpenRouter key, set the model. (Or skip this and set `OPENROUTER_API_KEY` + `LLM_MODEL` as Railway Variables in step 3.)
3. **Channels** — configure Telegram with your bot token, enable it.
4. Start the gateway from the **System** page if it isn't already running.

### 5. Start chatting

Message your Telegram bot. New users appear in the dashboard's **Pairing** page — approve them and they're paired.

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | yes | Dashboard login username. The container refuses to start without it. |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` | yes* | Precomputed scrypt hash (preferred — no plaintext at rest). |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | yes* | Plaintext alternative; hashed in-memory at load. *One of the two. |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | recommended | Session-cookie signing key (`openssl rand -base64 32`). Unset = logins drop on every redeploy. |
| `HERMES_REDACT_SECRETS` | no | Defaults to `true` here; set `false` for verbatim logs while debugging. |
| `HERMES_MULTIPLEX_PROFILES` | no | Defaults to `true` here. The boot script writes it to `config.yaml` so the single gateway serves every profile (see [Running multiple agents](#running-multiple-agents)). Set `false` to run one profile per Railway service. |

Provider keys, channel tokens, and tool API keys can be set **either** as Railway Variables (process env) **or** via the dashboard (which writes `/data/.hermes/.env` on the volume). Precedence: the volume `.env` overrides a same-named Railway Variable — pick one home per key. See [`.env.example`](./.env.example) for the full set.

## Supported Providers

OpenRouter, DeepSeek, DashScope, GLM / Z.AI, Kimi, MiniMax, HuggingFace

## Supported Channels

Telegram, Discord, Slack, WhatsApp, Email, Mattermost, Matrix

## Supported Tool Integrations

Parallel (search), Firecrawl (scraping), Tavily (search), FAL (image gen), Browserbase, GitHub, OpenAI Voice (Whisper/TTS), Honcho (memory)

## Architecture

```
  user browser ──HTTPS──►  ┌──────────────────────┐
                           │  Railway edge (TLS)  │
                           └──────────┬───────────┘
                                      │ $PORT
  ┌───────────────────────────────────┼───────────────────────────┐
  │  Railway Container                ▼                           │
  │   ┌───────────────────────────────────────┐  ┌─────────────┐  │
  │   │ hermes dashboard 0.0.0.0:$PORT        │  │   hermes    │  │
  │   │ gated auth: login page, scrypt,       │  │   gateway   │  │
  │   │ per-IP rate limit, HMAC cookies       │  │ (foreground)│  │
  │   └───────────────────────────────────────┘  └─────────────┘  │
  └───────────────────────────────────────────────────────────────┘
                        /data volume (persisted)
```

Binding non-loopback **without** `--insecure` engages Hermes' fail-closed dashboard auth gate: every page and `/api/*` route requires a session, login attempts are rate-limited per client IP, and uvicorn's `proxy_headers` flips on automatically so `Secure` cookies and WebSocket origin checks work correctly behind Railway's TLS-terminating proxy.

Config persists in `/data/.hermes/`: `.env` (provider/channel secrets), `config.yaml` (gateway config), `sessions/`, `memories/`, `cron/`, etc.

## Upgrading Hermes

The image **tracks the latest Hermes release** — it is not pinned. At build time the Dockerfile fetches `releases/latest` from GitHub and clones that tag; the running version is logged at container boot (`Hermes version: ...` in Railway deploy logs). Upstream uses date-based git tags (`v2026.6.5`) carrying a semver package version (`0.17.0`).

**To upgrade, click Redeploy in Railway.** A redeploy rebuilds the image; the `ADD https://api.github.com/.../releases/latest` line re-fetches the release metadata and busts the clone layer's cache **only when a new release exists**, so you get the newest release without a code change. (Without that cache-bust, Docker would reuse the stale clone layer and redeploy the same commit — the cache-bust is what makes "just redeploy" work.)

> ⚠️ **No changelog gate.** Because there is no pin-bump PR, you don't review release notes before deploying. If a release removes a CLI flag `start.sh` uses (`hermes dashboard`, `hermes gateway run`) — as 0.16 did with `--tui` — the container can crash-loop on boot; watch the deploy log after a redeploy. To deploy a *specific* release instead of latest, build with `--build-arg HERMES_REF=<tag>` (or set it in Railway's build args). Skim the [release notes](https://github.com/NousResearch/hermes-agent/releases) before redeploying if you want the old gate back.

The `/data` volume (config, sessions, memories, cron state) is untouched by upgrades — only the baked-in Hermes code changes.

## Cron jobs

Use Hermes' built-in scheduler with `no_agent=True` for shell scripts that should run without LLM invocation (zero token cost). See [NousResearch/hermes-agent#19709](https://github.com/NousResearch/hermes-agent/pull/19709). Scheduler state lives at `/data/.hermes/cron/` and persists across redeploys via the Railway volume.

## Running multiple agents

This template enables **profile multiplexing** by default (`HERMES_MULTIPLEX_PROFILES=true`), so one Railway service can host several independent agents — each with its own bot tokens, `.env`, sessions, and memory — sharing the one container, volume, and domain. For a handful of low-traffic agents (e.g. one per client or channel) that's cheaper and simpler than standing up a separate service each.

**Add an agent — no shell needed.** From the dashboard, use the profile switcher → **New profile**. Give it a model, a SOUL/personality, and channels with their **own** bot token, then it's live. New profiles land under `/data/.hermes/profiles/<name>/` on the persistent volume, so they survive redeploys and Hermes upgrades.

How the single gateway routes once a profile exists:

- **Default profile** is untouched — `agent:main:…` session namespace, bare `POST /webhooks/<route>`. Existing setups keep working byte-for-byte.
- **Named profiles** are served at a prefix: `POST https://<your-domain>/p/<name>/webhooks/<route>`. (Polling channels like Telegram need no inbound URL; this matters for webhook channels like Slack/Discord.)

Two constraints the gateway enforces at startup, so know them before you split work across profiles:

- **Each profile needs a unique bot token per platform.** The gateway refuses to start if two profiles share the same `(platform, token)` pair — reusing one Telegram/Discord token across profiles is a hard error, not a silent race.
- **Only the default profile owns the shared HTTP listener.** A secondary profile that enables a port-binding platform (webhook server, API server) fails fast at boot — configure those on the default profile only.

**Isolation model:** profiles share one process and volume — soft isolation (separate credentials, namespaced sessions/memory), not hard process isolation. To run an **untrusted** or compliance-isolated tenant, deploy this template as a **separate Railway service** (set `HERMES_MULTIPLEX_PROFILES=false`) so it gets its own container, volume, and crash domain.

## Running Locally

For local dev there's no need for the auth gate — just run Hermes directly:

```bash
pip install hermes-agent
hermes dashboard
```

Or run the container the way Railway does:

```bash
docker build -t hermes-agent .
docker run --rm -it -p 9119:9119 \
  -e HERMES_DASHBOARD_BASIC_AUTH_USERNAME=admin \
  -e HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=dev-only \
  -v hermes-data:/data hermes-agent
```

## Credits

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) by [Nous Research](https://nousresearch.com/)
