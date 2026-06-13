#!/usr/bin/env bash
# ============================================================================
#  mac-ai-stack — interactive installer
#  Walks you through setting up:
#    1) LiteLLM rotation proxy + OpenClaw  (optional)
#    2) Mattermost -> Email bridge bot      (optional)
#  All secrets go into your macOS Keychain. Nothing is written in plaintext.
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PY=""

c_bold(){ printf "\033[1m%s\033[0m\n" "$1"; }
c_ok(){ printf "  \033[32m✓\033[0m %s\n" "$1"; }
c_warn(){ printf "  \033[33m!\033[0m %s\n" "$1"; }
ask(){ local p="$1" v; read -rp "  $p: " v; printf '%s' "$v"; }
ask_secret(){ local p="$1" v; read -rsp "  $p (hidden): " v; echo >&2; printf '%s' "$v"; }
kc_set(){ security add-generic-password -a "$USER" -s "$1" -w "$2" -U 2>/dev/null; }

c_bold "=== mac-ai-stack installer ==="
echo

# ---- Prereqs ----------------------------------------------------------------
c_bold "1. Checking prerequisites"
command -v brew >/dev/null || { c_warn "Homebrew not found — install from https://brew.sh first"; exit 1; }
c_ok "Homebrew present"
if [ -x /usr/local/bin/python3.12 ]; then PY=/usr/local/bin/python3.12
elif [ -x /opt/homebrew/bin/python3.12 ]; then PY=/opt/homebrew/bin/python3.12
else
  c_warn "Python 3.12 not found — installing via Homebrew"
  brew install python@3.12
  PY="$(command -v python3.12)"
fi
c_ok "Python 3.12: $PY"
echo

# ---- Choose components ------------------------------------------------------
c_bold "2. What do you want to install?"
echo "   [1] Mattermost -> Email bot only"
echo "   [2] OpenClaw + LiteLLM rotation only"
echo "   [3] Both"
CHOICE="$(ask 'Choose 1/2/3')"
echo

# ============================================================================
# OpenClaw + LiteLLM
# ============================================================================
if [ "$CHOICE" = "2" ] || [ "$CHOICE" = "3" ]; then
  c_bold "3. OpenClaw + LiteLLM rotation"
  STACK="$HOME/.openclaw-stack"; mkdir -p "$STACK"

  c_warn "Get API keys first (free tiers available):"
  echo "      Groq:   https://console.groq.com/keys"
  echo "      Gemini: https://aistudio.google.com/apikey"
  GROQ="$(ask_secret 'Paste Groq API key')";   [ -n "$GROQ" ] && kc_set MACSTACK_GROQ "$GROQ" && c_ok "Groq key -> Keychain"
  GEM="$(ask_secret 'Paste Gemini API key')";  [ -n "$GEM" ]  && kc_set MACSTACK_GEMINI "$GEM" && c_ok "Gemini key -> Keychain"
  MASTER="sk-local-$(openssl rand -hex 20)"; kc_set MACSTACK_LITELLM_MASTER "$MASTER"; c_ok "LiteLLM master key generated"

  c_warn "Installing LiteLLM (pipx on Python 3.12)..."
  command -v pipx >/dev/null || brew install pipx
  pipx install 'litellm[proxy]' --python "$PY" --force >/dev/null 2>&1 || \
    "$PY" -m pip install --break-system-packages 'litellm[proxy]' >/dev/null 2>&1
  LITELLM="$(command -v litellm || echo "$HOME/.local/bin/litellm")"
  c_ok "LiteLLM: $LITELLM"

  # config (two-tier Groq -> Gemini; add Anthropic yourself if you have credits)
  cat > "$STACK/litellm.yaml" <<'YAML'
model_list:
  - model_name: tier-groq
    litellm_params: { model: groq/llama-3.3-70b-versatile, api_key: os.environ/GROQ_API_KEY }
  - model_name: tier-gemini
    litellm_params: { model: gemini/gemini-2.5-flash, api_key: os.environ/GEMINI_API_KEY }
router_settings:
  fallbacks:
    - tier-groq: ["tier-gemini"]
    - tier-gemini: ["tier-groq"]
  allowed_fails: 1
  cooldown_time: 60
litellm_settings:
  drop_params: true
  fallbacks_on_status_codes: [400,429,500,502,503,529]
YAML
  chmod 600 "$STACK/litellm.yaml"

  cat > "$STACK/run-litellm.sh" <<EOF
#!/usr/bin/env bash
set -e
kc(){ security find-generic-password -a "$USER" -s "\$1" -w 2>/dev/null; }
export GROQ_API_KEY="\$(kc MACSTACK_GROQ)"
export GEMINI_API_KEY="\$(kc MACSTACK_GEMINI)"
export LITELLM_MASTER_KEY="\$(kc MACSTACK_LITELLM_MASTER)"
exec "$LITELLM" --config "$STACK/litellm.yaml" --port 4000
EOF
  chmod 700 "$STACK/run-litellm.sh"

  PLIST="$HOME/Library/LaunchAgents/com.macstack.litellm.plist"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.macstack.litellm</string>
<key>ProgramArguments</key><array><string>$STACK/run-litellm.sh</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>StandardOutPath</key><string>$STACK/litellm.out.log</string>
<key>StandardErrorPath</key><string>$STACK/litellm.err.log</string>
</dict></plist>
EOF
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  sleep 8
  M="$(security find-generic-password -a "$USER" -s MACSTACK_LITELLM_MASTER -w)"
  if curl -s --max-time 20 http://127.0.0.1:4000/v1/chat/completions \
      -H "Authorization: Bearer $M" -H 'Content-Type: application/json' \
      -d '{"model":"tier-groq","messages":[{"role":"user","content":"ok"}],"max_tokens":5}' | grep -q '"content"'; then
    c_ok "LiteLLM proxy answering on :4000 (tier-groq)"
  else
    c_warn "Proxy not answering yet — check $STACK/litellm.err.log"
  fi
  echo
  c_warn "Now run:  openclaw onboard --install-daemon"
  echo "      Provider: LiteLLM | Base URL: http://127.0.0.1:4000/v1"
  echo "      API key: (run) security find-generic-password -a \"\$USER\" -s MACSTACK_LITELLM_MASTER -w"
  echo "      Model: tier-groq"
  echo "      After onboarding: openclaw config set agents.defaults.model.primary litellm/tier-groq"
  echo
fi

# ============================================================================
# Mattermost -> Email bot
# ============================================================================
if [ "$CHOICE" = "1" ] || [ "$CHOICE" = "3" ]; then
  c_bold "4. Mattermost -> Email bot"
  VDIR="$HOME/.mmbot"; mkdir -p "$VDIR"
  cp "$ROOT/viktor/mm_listener.py" "$VDIR/mm_listener.py"

  "$PY" -c "import websocket, requests" 2>/dev/null || \
    "$PY" -m pip install --break-system-packages websocket-client requests >/dev/null 2>&1
  c_ok "Python deps ready"

  MM_URL="$(ask 'Mattermost URL [http://127.0.0.1:8065]')"; MM_URL="${MM_URL:-http://127.0.0.1:8065}"
  SENDER="$(ask 'Sender email address (the From: address)')"
  SMTP_SRV="$(ask 'SMTP server [smtp.gmail.com]')"; SMTP_SRV="${SMTP_SRV:-smtp.gmail.com}"
  SMTP_PRT="$(ask 'SMTP port [587]')"; SMTP_PRT="${SMTP_PRT:-587}"

  c_warn "Bot token: Mattermost > Integrations > Bot Accounts > (your bot) > Create Token"
  BTOK="$(ask_secret 'Paste Mattermost bot token')"; [ -n "$BTOK" ] && kc_set MMBOT_TOKEN "$BTOK" && c_ok "Bot token -> Keychain"

  c_warn "SMTP/app password (for Gmail: myaccount.google.com/apppasswords, needs 2FA on)"
  SPW_RAW="$(ask_secret 'Paste SMTP/app password')"
  SPW="$(printf '%s' "$SPW_RAW" | tr -d '[:space:]')"   # strip spaces (Gmail shows them)
  # verify before storing
  if [ -n "$SPW" ] && [ -n "$SENDER" ]; then
    if MMBOT_TEST_PW="$SPW" "$PY" - "$SENDER" "$SMTP_SRV" "$SMTP_PRT" <<'PYT'
import os,sys,smtplib
try:
    s=smtplib.SMTP(sys.argv[2],int(sys.argv[3]),timeout=15); s.starttls()
    s.login(sys.argv[1],os.environ["MMBOT_TEST_PW"]); s.quit(); print("OK")
except Exception as e: print("FAIL",e); sys.exit(1)
PYT
    then kc_set MMBOT_SMTP_PASSWORD "$SPW"; c_ok "SMTP password verified + stored"
    else c_warn "SMTP login failed — check 2FA + app password. Stored anyway? NO."; fi
  fi

  echo
  c_bold "   Email signature (optional — press Enter to skip any field)"
  SIG_NAME="$(ask 'Signature name (e.g. Jane Doe)')"
  SIG_HANDLE="$(ask 'Handle/parenthetical (e.g. your username)')"
  SIG_WORDMARK="$(ask 'Big wordmark text (e.g. YOURBRAND)')"
  SIG_TAGLINE="$(ask 'Tagline (e.g. Systems Architect)')"
  SIG_ACCENT="$(ask 'Accent color hex [#ff6a00]')"; SIG_ACCENT="${SIG_ACCENT:-#ff6a00}"

  PLIST="$HOME/Library/LaunchAgents/com.macstack.mmbot.plist"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.macstack.mmbot</string>
<key>ProgramArguments</key><array><string>$PY</string><string>$VDIR/mm_listener.py</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>EnvironmentVariables</key><dict>
  <key>MMBOT_MM_URL</key><string>$MM_URL</string>
  <key>MMBOT_SENDER_EMAIL</key><string>$SENDER</string>
  <key>MMBOT_SMTP_SERVER</key><string>$SMTP_SRV</string>
  <key>MMBOT_SMTP_PORT</key><string>$SMTP_PRT</string>
  <key>MMBOT_SIG_NAME</key><string>$SIG_NAME</string>
  <key>MMBOT_SIG_HANDLE</key><string>$SIG_HANDLE</string>
  <key>MMBOT_SIG_WORDMARK</key><string>$SIG_WORDMARK</string>
  <key>MMBOT_SIG_TAGLINE</key><string>$SIG_TAGLINE</string>
  <key>MMBOT_SIG_ACCENT</key><string>$SIG_ACCENT</string>
</dict>
<key>StandardOutPath</key><string>$VDIR/listener_out.log</string>
<key>StandardErrorPath</key><string>$VDIR/listener_err.log</string>
</dict></plist>
EOF
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"
  sleep 3
  c_ok "Bot service installed + started"
  echo
  c_warn "Test it: DM your bot (or post in a channel it's in):"
  echo "      To: $SENDER Hello from the bot"
  echo "      Watch: tail -f $VDIR/listener_out.log"
  echo "      (For channel triggers, the bot must be a member: /invite @yourbot)"
fi

echo
c_bold "Done. Secrets are in your macOS Keychain; services run via launchd."
