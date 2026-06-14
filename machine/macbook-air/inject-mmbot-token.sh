#!/usr/bin/env bash
# ============================================================================
#  inject-mmbot-token.sh
#  Securely capture a new Mattermost bot token, VERIFY it against the API,
#  store it in macOS Keychain under MMBOT_TOKEN (the name mm_listener.py reads),
#  then restart the launchd service.
#
#  Nothing is written to disk in plaintext. Token is verified BEFORE storing,
#  so a bad paste never clobbers a working value.
# ============================================================================
set -uo pipefail

MM_URL="${MMBOT_MM_URL:-http://127.0.0.1:8065}"
KC_SERVICE="MMBOT_TOKEN"
PLIST="$HOME/Library/LaunchAgents/com.macstack.mmbot.plist"
LABEL="com.macstack.mmbot"
LISTENER="$HOME/.mmbot/mm_listener.py"

ok(){   printf "  \033[32m✓\033[0m %s\n" "$1"; }
warn(){ printf "  \033[33m!\033[0m %s\n" "$1"; }
err(){  printf "  \033[31m✗\033[0m %s\n" "$1"; }
bold(){ printf "\033[1m%s\033[0m\n" "$1"; }

bold "=== Mattermost bot token injector ==="
echo "  Target server: $MM_URL"
echo

# ---- 1. Capture token (hidden) ---------------------------------------------
read -rsp "  Paste the new bot token (hidden): " TOK; echo
TOK="$(printf '%s' "$TOK" | tr -d '[:space:]')"   # strip stray whitespace
if [ -z "$TOK" ]; then err "No token entered. Aborting."; exit 1; fi

# ---- 2. VERIFY before storing ----------------------------------------------
bold "Verifying token against $MM_URL/api/v4/users/me ..."
CODE="$(curl -s -o /tmp/mmbot_me.$$ -w '%{http_code}' \
  -H "Authorization: Bearer $TOK" "$MM_URL/api/v4/users/me" || echo 000)"

if [ "$CODE" != "200" ]; then
  err "Token rejected (HTTP $CODE). Nothing was stored."
  case "$CODE" in
    401) echo "      -> Token invalid/revoked, or the bot account is deactivated." ;;
    000) echo "      -> Could not reach $MM_URL. Is Mattermost running on this machine?" ;;
    *)   echo "      -> Unexpected response. Body:"; cat /tmp/mmbot_me.$$ 2>/dev/null ;;
  esac
  rm -f /tmp/mmbot_me.$$
  exit 1
fi

BOT_USER="$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("username","?"))' /tmp/mmbot_me.$$ 2>/dev/null || echo '?')"
rm -f /tmp/mmbot_me.$$
ok "Token valid — authenticated as bot user: $BOT_USER"

# ---- 3. Inject into Keychain (update-in-place) ------------------------------
security add-generic-password -a "$USER" -s "$KC_SERVICE" -w "$TOK" -U 2>/dev/null
# confirm round-trip
STORED="$(security find-generic-password -a "$USER" -s "$KC_SERVICE" -w 2>/dev/null)"
if [ "$STORED" = "$TOK" ]; then ok "Stored in Keychain under service '$KC_SERVICE'"
else err "Keychain write/readback mismatch. Aborting."; exit 1; fi
unset TOK STORED   # don't keep it in shell memory

# ---- 4. Restart the launchd service ----------------------------------------
bold "Restarting the bot service ..."
if [ -f "$PLIST" ]; then
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load   "$PLIST" 2>/dev/null && ok "Reloaded $LABEL via launchd"
else
  warn "No plist at $PLIST — the launchd service was never installed."
  echo "      Run the full installer to create it:  bash ~/mac-ai-stack/setup.sh  (choose option 1)"
  if [ -f "$LISTENER" ]; then
    echo "      Or test in the foreground right now with env loaded:"
    echo "        MMBOT_MM_URL=$MM_URL /opt/homebrew/bin/python3.12 $LISTENER"
  fi
fi

# ---- 5. Confirm it came up --------------------------------------------------
sleep 2
if ps aux | grep -q "[m]m_listener.py"; then
  ok "Listener process is running."
  echo
  echo "  Tail the log to watch it connect & handle a test DM:"
  echo "    tail -f ~/.mmbot/listener_out.log"
  echo "  Then DM your bot:  To: jensannasardo@gmail.com  test from bot"
else
  warn "Listener not running yet."
  echo "    Check errors:  tail -30 ~/.mmbot/listener_err.log"
fi

echo
bold "Done."
