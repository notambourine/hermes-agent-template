# Hermes Agent — Railway Template

Deploy [Hermes Agent](https://github.com/NousResearch/hermes-agent) on [Railway](https://railway.app), fronted by a [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) with [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/policies/access/) for identity-based auth on the admin dashboard.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/hermes-agent-ai?referralCode=QXdhdr&utm_medium=integration&utm_source=template&utm_campaign=generic)

> Hermes Agent is an autonomous AI agent by [Nous Research](https://nousresearch.com/) that lives on your server, connects to your messaging channels (Telegram, Discord, Slack, etc.), and gets more capable the longer it runs.

## Features

- **Admin Dashboard** — dark-themed UI to configure providers, channels, tools, and manage the gateway
- **One-Page Setup** — provider dropdown, checkbox-based channel/tool toggles — no config files to edit
- **Gateway Management** — start, stop, restart the Hermes gateway from the browser
- **Live Status** — stat cards for gateway state, uptime, model, and pending pairing requests
- **Live Logs** — streaming gateway log viewer
- **User Pairing** — approve or deny users who message your bot, revoke access anytime
- **Cloudflare Access auth** — identity-bound (Google/GitHub/email magic-link), no public IP, no basic-auth password to manage
- **Release-tracking Hermes** — each Railway build resolves the latest Hermes release tag via the GitHub API and rebuilds when a new one is cut (override with `HERMES_REF=<tag>` to pin)

## Getting Started

### 1. LLM provider key (free)

1. Register at [OpenRouter](https://openrouter.ai/) and create an API key.
2. Pick a model from the [free tier list](https://openrouter.ai/models?order=pricing-low-to-high) (e.g. `google/gemma-3-1b-it:free`).

### 2. Telegram bot (fastest channel)

1. Message [@BotFather](https://t.me/BotFather) on Telegram, send `/newbot`, copy the **Bot Token**.
2. Find your Telegram user ID via [@userinfobot](https://t.me/userinfobot).

### 3. Cloudflare Tunnel + Access

You need a Cloudflare account with a domain on Cloudflare's nameservers (free tier is fine). All steps happen in the [Zero Trust dashboard](https://one.dash.cloudflare.com/).

1. **Create a tunnel.** Networks → Tunnels → Create tunnel → Cloudflared. Name it (e.g. `hermes-railway`). Copy the **token** Cloudflare hands you (`eyJhIjoi...`, ~200 chars). This is your `TUNNEL_TOKEN`.
2. **Add a public hostname** to the tunnel. Public Hostname tab → Add. Pick a subdomain (e.g. `hermes.yourdomain.com`). Service: `HTTP` `localhost:9119`. Expand **Additional application settings → HTTP Settings** and set **HTTP Host Header** to `localhost:9119` — the Hermes dashboard checks the `Host:` header against its loopback bind, and Cloudflare passes the browser's Host through unmodified by default; without this override you'll hit `{"detail":"Invalid Host header..."}` after auth.
3. **Protect it with Access.** Access → Applications → Add application → Self-hosted. Set the application URL to your subdomain. Add a policy: e.g. *Allow* if email matches `you@yourdomain.com`. Save.

That's the one-time setup. The tunnel + hostname + Access policy all live on Cloudflare's side — Railway redeploys reconnect to the same tunnel transparently.

### 4. Deploy to Railway

1. Click **Deploy on Railway** above.
2. Set environment variable **`TUNNEL_TOKEN`** to the value from step 3.1.
3. Attach a **volume** mounted at `/data` (persists Hermes config, sessions, memory, cron schedules).
4. Wait for the build to finish. The container connects to Cloudflare automatically — no Railway public domain needed (don't enable one).

### 5. Configure in the Admin Dashboard

1. Open `https://hermes.yourdomain.com`. Cloudflare Access prompts you to authenticate. After you're in, the Hermes dashboard loads.
2. **LLM Provider** — paste your OpenRouter key, enter the model name.
3. **Messaging Channel** — paste your Telegram bot token.
4. **Save & Start.** The gateway boots and your bot goes live.

### 6. Start chatting

Message your Telegram bot. New users appear under **Users** in the dashboard — click **Approve** and they're paired.

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `TUNNEL_TOKEN` | yes | Cloudflare Tunnel token from the Zero Trust dashboard. The container will refuse to start without it. |

LLM provider keys, channel tokens, tool API keys, and gateway settings are managed through the admin dashboard (which writes them to `/data/.hermes/.env`). See [`.env.example`](./.env.example) for the full set of optional knobs.

## Supported Providers

OpenRouter, DeepSeek, DashScope, GLM / Z.AI, Kimi, MiniMax, HuggingFace

## Supported Channels

Telegram, Discord, Slack, WhatsApp, Email, Mattermost, Matrix

## Supported Tool Integrations

Parallel (search), Firecrawl (scraping), Tavily (search), FAL (image gen), Browserbase, GitHub, OpenAI Voice (Whisper/TTS), Honcho (memory)

## Architecture

```
                     ┌──────────────────────┐
  user browser ─►   │  Cloudflare Access    │  identity check
                     │  (Google/GitHub/email)│
                     └──────────┬───────────┘
                                │ authorized request
                                ▼
                     ┌──────────────────────┐
                     │  Cloudflare Tunnel   │
                     └──────────┬───────────┘
                                │ outbound-only connection
  ┌─────────────────────────────┼─────────────────────────────┐
  │  Railway Container          ▼                             │
  │  ┌─────────────┐   ┌─────────────────┐   ┌─────────────┐  │
  │  │ cloudflared │──►│ hermes dashboard│   │   hermes    │  │
  │  │             │   │  127.0.0.1:9119 │   │   gateway   │  │
  │  └─────────────┘   └─────────────────┘   └─────────────┘  │
  │                          (loopback)         (foreground)  │
  └───────────────────────────────────────────────────────────┘
                       /data volume (persisted)
```

The container has **no public listener**. cloudflared makes an outbound connection to Cloudflare's edge; inbound traffic is delivered through that connection to the dashboard on loopback. Hermes' built-in loopback-only WS defenses are satisfied naturally — no reverse-proxy header gymnastics, no basic-auth shim.

Config persists in `/data/.hermes/`: `.env` (provider/channel secrets), `config.yaml` (gateway config), `sessions/`, `memories/`, `cron/`, etc.

## Cron jobs

Use Hermes' built-in scheduler with `no_agent=True` for shell scripts that should run without LLM invocation (zero token cost). See [NousResearch/hermes-agent#19709](https://github.com/NousResearch/hermes-agent/pull/19709). Scheduler state lives at `/data/.hermes/cron/` and persists across redeploys via the Railway volume.

## Running Locally

For local dev there's no need for a tunnel — just run Hermes directly:

```bash
pip install hermes-agent
hermes dashboard
```

Or build and run the container with a tunnel token of your own:

```bash
docker build -t hermes-agent .
docker run --rm -it -e TUNNEL_TOKEN=eyJhIjoi... -v hermes-data:/data hermes-agent
```

## Credits

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) by [Nous Research](https://nousresearch.com/)
