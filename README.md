# Hermes Agent — Railway Template

Deploy [Hermes Agent](https://github.com/NousResearch/hermes-agent) on [Railway](https://railway.app) with a web-based admin dashboard for configuration, gateway management, and user pairing.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/hermes-agent-ai?referralCode=QXdhdr&utm_medium=integration&utm_source=template&utm_campaign=generic)

> Hermes Agent is an autonomous AI agent by [Nous Research](https://nousresearch.com/) that lives on your server, connects to your messaging channels (Telegram, Discord, Slack, etc.), and gets more capable the longer it runs.

<!-- TODO: Add dashboard screenshot -->
<!-- ![Dashboard](docs/dashboard.png) -->

## Features

- **Admin Dashboard** — dark-themed UI to configure providers, channels, tools, and manage the gateway
- **One-Page Setup** — provider dropdown, checkbox-based channel/tool toggles — no config files to edit
- **Gateway Management** — start, stop, restart the Hermes gateway from the browser
- **Live Status** — stat cards for gateway state, uptime, model, and pending pairing requests
- **Live Logs** — streaming gateway log viewer
- **User Pairing** — approve or deny users who message your bot, revoke access anytime
- **Basic Auth** — password-protected admin panel
- **Reset Config** — one-click reset to start fresh

## Getting Started

The easiest way to get started:

### 1. Get an LLM Provider Key (free)

1. Register for free at [OpenRouter](https://openrouter.ai/)
2. Create an API key from your [OpenRouter dashboard](https://openrouter.ai/keys)
3. Pick a free model from the [model list sorted by price](https://openrouter.ai/models?order=pricing-low-to-high) (e.g. `google/gemma-3-1b-it:free`, `meta-llama/llama-3.1-8b-instruct:free`)

### 2. Set Up a Telegram Bot (fastest channel)

Hermes Agent interacts entirely through messaging channels — there is no chat UI like ChatGPT. Telegram is the quickest to set up:

1. Open Telegram and message [@BotFather](https://t.me/BotFather)
2. Send `/newbot`, follow the prompts, and copy the **Bot Token**
3. Send a message to your new bot — it will appear as a pairing request in the admin dashboard
4. To find your Telegram user ID, message [@userinfobot](https://t.me/userinfobot)

### 3. Deploy to Railway

1. Click the **Deploy on Railway** button above
2. Set the `ADMIN_PASSWORD` environment variable (or a random one will be generated on first boot and written to `/data/.hermes/.admin-password.txt`; the deploy log will show the path, not the password)
3. Attach a **volume** mounted at `/data` (persists config across redeploys)
4. Open your app URL — log in with username `admin` and your password

### 4. Configure in the Admin Dashboard

1. **LLM Provider** — select OpenRouter from the dropdown, paste your API key, enter the model name
2. **Messaging Channel** — check Telegram, paste the Bot Token from BotFather
3. Click **Save & Start** — the gateway will start and your bot goes live

### 5. Start Chatting

Message your Telegram bot. If you're a new user, a pairing request will appear in the admin dashboard under **Users** — click **Approve**, and you're in.

<!-- TODO: Add Telegram chat screenshot -->
<!-- ![Telegram Example](docs/telegram-example.png) -->

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8080` | Web server port (set automatically by Railway) |
| `ADMIN_USERNAME` | `admin` | Basic auth username |
| `ADMIN_PASSWORD` | *(auto-generated)* | Admin password — if unset, a random password is generated on first boot and written to `/data/.hermes/.admin-password.txt` (mode 0600). Deploy logs show only the path. Read it once via the Railway shell, then set this variable and redeploy. |

All other configuration (LLM provider, model, channels, tools) is managed through the admin dashboard.

## Supported Providers

OpenRouter, DeepSeek, DashScope, GLM / Z.AI, Kimi, MiniMax, HuggingFace

## Supported Channels

Telegram, Discord, Slack, WhatsApp, Email, Mattermost, Matrix

## Supported Tool Integrations

Parallel (search), Firecrawl (scraping), Tavily (search), FAL (image gen), Browserbase, GitHub, OpenAI Voice (Whisper/TTS), Honcho (memory)

## Cron Jobs

The container ships with [supercronic](https://github.com/aptible/supercronic) so you can run OS-level cron jobs alongside the agent. The crontab file lives on the persistent volume at `/data/crontab` and is re-read on every container boot — no separate "register cron" step, no jobs lost on redeploy.

### How it works

- `start.sh` sources `/data/.hermes/.env` (so cron jobs see the same secrets the gateway uses) and launches `supercronic -passthrough-logs /data/crontab` as a background sibling of the gateway.
- supercronic logs each invocation to stdout, which Railway captures alongside the gateway's logs.
- `/data/crontab` is created empty on first boot if it doesn't exist. Edit it via the Railway shell or any file-browser surface you've added.

### Crontab format

Standard 5-field cron syntax. Lines run as `/bin/sh -c '<command>'`, so use full paths and quote shell metacharacters.

```cron
# Check ShibariDev/shibari-study-partnerships dev branch every 15 min,
# alert Slack only on a status flip. State persists in /data so the
# "did this just break?" check survives redeploys.
*/15 * * * * /data/scripts/check-ci.sh
```

### Example: CI status flip → Slack webhook (zero LLM tokens)

`/data/scripts/check-ci.sh`:

```bash
#!/bin/bash
set -euo pipefail

STATE_FILE="/data/.shibari_ci_state.txt"
REPO="ShibariDev/shibari-study-partnerships"
BRANCH="dev"

SHA=$(curl -fsS -H "Authorization: token $SHIBARI_GITHUB_READONLY" \
  "https://api.github.com/repos/$REPO/commits/$BRANCH" | jq -r '.sha')
STATUS=$(curl -fsS -H "Authorization: token $SHIBARI_GITHUB_READONLY" \
  "https://api.github.com/repos/$REPO/commits/$SHA/status" | jq -r '.state')

LAST=$(cat "$STATE_FILE" 2>/dev/null || echo "success")

if [ "$STATUS" = "failure" ] && [ "$LAST" != "failure" ]; then
  curl -fsS -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\":rotating_light: $REPO@$BRANCH broke ($SHA)\"}" \
    "$SLACK_WEBHOOK_URL"
  echo failure > "$STATE_FILE"
elif [ "$STATUS" = "success" ] && [ "$LAST" = "failure" ]; then
  curl -fsS -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\":white_check_mark: $REPO@$BRANCH is green again\"}" \
    "$SLACK_WEBHOOK_URL"
  echo success > "$STATE_FILE"
fi
```

Make it executable (`chmod +x /data/scripts/check-ci.sh`) and add the cron line above. Set `SHIBARI_GITHUB_READONLY` and `SLACK_WEBHOOK_URL` in `/data/.hermes/.env` (the dashboard's env editor works) — `start.sh` exports them into supercronic's environment on boot.

### Why supercronic, not `cron`/`crond`

Stock cron daemonizes itself, drops the parent environment, and ships logs through syslog — none of which plays well with `tini` as PID 1 or Railway's stdout-based log pipeline. supercronic is a single static Go binary that runs in the foreground, inherits env from its parent, and writes to stdout. It's the standard container-cron idiom (Aptible, GitLab Runner, Heroku-style buildpacks all use it).

### Hermes-managed schedules vs OS-level cron

Hermes has its own scheduler at `/data/.hermes/cron/` for *agent* tasks — recurring LLM invocations that go through the gateway. Use that when you want an agent to think. Use `/data/crontab` (this section) when you want a shell script to run that explicitly *avoids* the gateway, e.g. status checks that should cost zero tokens unless they fire a notification.

## Architecture

```
Railway Container
├── Python Admin Server (Starlette + Uvicorn)
│   ├── /            — Admin dashboard (Basic Auth)
│   ├── /health      — Health check (no auth)
│   └── /api/*       — Config, status, logs, gateway, pairing
├── supercronic      — OS-level cron, reads /data/crontab
└── hermes gateway   — Managed as async subprocess
```

The admin server runs on `$PORT` and manages the Hermes gateway as a child process. Config is stored in `/data/.hermes/.env` and `/data/.hermes/config.yaml`. Gateway stdout/stderr is captured into a ring buffer and streamed to the Logs panel.

## Running Locally

```bash
docker build -t hermes-agent .
docker run --rm -it -p 8080:8080 -e PORT=8080 -e ADMIN_PASSWORD=changeme -v hermes-data:/data hermes-agent
```

Open `http://localhost:8080` and log in with `admin` / `changeme`.

## Credits

- [Hermes Agent](https://github.com/NousResearch/hermes-agent) by [Nous Research](https://nousresearch.com/)
- UI inspired by [OpenClaw](https://github.com/praveen-ks-2001/openclaw-railway) admin template
