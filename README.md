# mac-ai-stack

Self-hosted AI tooling for macOS, built around your own API keys and your own Mattermost.
Two independent pieces you can install together or separately:

1. **OpenClaw + LiteLLM rotation** — a local AI-agent gateway fronted by a LiteLLM proxy that rotates across providers (Groq → Gemini, with easy room for more). Runs on `localhost`, secrets in Keychain, persists via `launchd`.
2. **Mattermost → Email bot** — a small websocket bot that watches your Mattermost DMs and channels for a `To: <email>` message and sends it as a clean HTML email (with a configurable signature), then confirms in-thread.

Everything personal — API keys, email address, bot token, SMTP password, signature — is collected from **you** at install time and stored in the **macOS Keychain**. Nothing is hardcoded; there are no secrets in this repository.

## Requirements

- macOS (Intel or Apple Silicon)
- [Homebrew](https://brew.sh)
- Python 3.12 (the installer offers to install it)
- For the email bot: a running Mattermost server and a bot account
- For OpenClaw: a [Groq](https://console.groq.com/keys) and/or [Gemini](https://aistudio.google.com/apikey) API key (both have free tiers)

## Install

```bash
git clone <this-repo-url> mac-ai-stack
cd mac-ai-stack
chmod +x setup.sh
./setup.sh
```

The installer walks you through each piece interactively. Secret prompts are hidden and pipe straight into your Keychain.

## Mattermost → Email bot usage

Once installed, message your bot (DM) or post in a channel it belongs to:

```
To: someone@example.com Subject goes here
Body line one.
Body line two.
```

- Line 1: `To: <email>` followed by the **subject**.
- Line 2 onward: the **email body**.
- A signature (if you configured one) is appended automatically.

For channel triggers, the bot must be a member of the channel: `/invite @yourbot`.

### Configuration (set by the installer, stored in the launchd plist)

| Variable | Meaning |
|---|---|
| `MMBOT_MM_URL` | Mattermost base URL, e.g. `http://127.0.0.1:8065` |
| `MMBOT_SENDER_EMAIL` | the `From:` address |
| `MMBOT_SMTP_SERVER` / `MMBOT_SMTP_PORT` | SMTP relay (default Gmail) |
| `MMBOT_SIG_NAME` / `MMBOT_SIG_HANDLE` | signature name + parenthetical |
| `MMBOT_SIG_WORDMARK` / `MMBOT_SIG_TAGLINE` | big wordmark + tagline |
| `MMBOT_SIG_ACCENT` | accent color hex |

Secrets (`MMBOT_TOKEN`, `MMBOT_SMTP_PASSWORD`) live in Keychain, not the plist.

## OpenClaw notes

After the LiteLLM proxy is verified, finish OpenClaw onboarding:

```
openclaw onboard --install-daemon
# Provider: LiteLLM | Base URL: http://127.0.0.1:4000/v1
# API key: security find-generic-password -a "$USER" -s MACSTACK_LITELLM_MASTER -w
# Model: tier-groq
openclaw config set agents.defaults.model.primary litellm/tier-groq
```

## Security

- No secrets in this repo. All credentials are collected at install and stored in the macOS Keychain.
- The bot reads secrets from Keychain at runtime via `security find-generic-password`.
- Gmail SMTP requires 2-Step Verification + an [app password](https://myaccount.google.com/apppasswords).
- Services bind to `localhost` by default. Don't expose them to the internet without adding auth/hardening.

## License

MIT — see [LICENSE](LICENSE).
