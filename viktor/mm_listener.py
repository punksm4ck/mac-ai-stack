#!/usr/bin/env python3
"""
Mattermost -> Email bridge bot.

Listens to Mattermost (DMs to the bot AND channels it belongs to) over the
websocket API. When a message starts with:

    To: someone@example.com Subject line here
    Body line 1
    Body line 2 ...

...it sends that as an HTML email (with a plaintext fallback) via SMTP, then
replies in-thread to confirm. A configurable signature is appended to every
email.

ALL personal values come from macOS Keychain + environment variables — nothing
is hardcoded. Run setup.sh first to populate them.

Required Keychain entries (service names):
    MMBOT_TOKEN              - Mattermost bot access token
    MMBOT_SMTP_PASSWORD      - SMTP/app password for the sender address

Required environment (set by the launchd plist / setup.sh):
    MMBOT_MM_URL             - e.g. http://127.0.0.1:8065
    MMBOT_SMTP_SERVER        - e.g. smtp.gmail.com
    MMBOT_SMTP_PORT          - e.g. 587
    MMBOT_SENDER_EMAIL       - the From: address
    MMBOT_SIG_NAME           - signature display name      (optional)
    MMBOT_SIG_HANDLE         - signature handle/parenthetical (optional)
    MMBOT_SIG_WORDMARK       - big bold wordmark text       (optional)
    MMBOT_SIG_TAGLINE        - small tagline under wordmark  (optional)
    MMBOT_SIG_ACCENT         - hex accent color, e.g. #ff6a00 (optional)
"""
import json
import os
import re
import smtplib
import subprocess
import time
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from html import escape

import requests
import websocket

# --- Config from environment (with sane defaults) ---
MM_URL = os.environ.get("MMBOT_MM_URL", "http://127.0.0.1:8065").rstrip("/")
MM_HTTP = f"{MM_URL}/api/v4"
MM_WS = MM_URL.replace("http://", "ws://").replace("https://", "wss://") + "/api/v4/websocket"

SMTP_SERVER = os.environ.get("MMBOT_SMTP_SERVER", "smtp.gmail.com")
SMTP_PORT = int(os.environ.get("MMBOT_SMTP_PORT", "587"))
SENDER_EMAIL = os.environ.get("MMBOT_SENDER_EMAIL", "")

# --- Signature (all optional; omit env vars to disable parts) ---
SIG_NAME = os.environ.get("MMBOT_SIG_NAME", "")
SIG_HANDLE = os.environ.get("MMBOT_SIG_HANDLE", "")
SIG_WORDMARK = os.environ.get("MMBOT_SIG_WORDMARK", "")
SIG_TAGLINE = os.environ.get("MMBOT_SIG_TAGLINE", "")
SIG_ACCENT = os.environ.get("MMBOT_SIG_ACCENT", "#ff6a00")


def kc(service):
    """Read a secret from the macOS Keychain. Returns '' if not found."""
    try:
        user = subprocess.check_output(["whoami"]).decode().strip()
        return subprocess.check_output(
            ["security", "find-generic-password", "-a", user, "-s", service, "-w"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except Exception:
        return ""


BOT_TOKEN = kc("MMBOT_TOKEN")
APP_PASSWORD = kc("MMBOT_SMTP_PASSWORD")
HEADERS = {"Authorization": f"Bearer {BOT_TOKEN}"}
BOT_USER_ID = None

_MAILTO = re.compile(r"\[([^\]]+)\]\(mailto:[^)]+\)")
_LINK = re.compile(r"\[([^\]]+)\]\([^)]+\)")
_EMAIL = re.compile(r"To:\s*([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})", re.IGNORECASE)


def build_signature_html():
    if not (SIG_NAME or SIG_WORDMARK):
        return ""
    parts = ['<div style="margin-top:14px; font-family:Arial,Helvetica,sans-serif; color:#1a1a1a; line-height:1.4;">']
    if SIG_NAME:
        handle = f' <span style="color:#666666;">({escape(SIG_HANDLE)})</span>' if SIG_HANDLE else ""
        parts.append(f'<div style="margin-bottom:14px;">Regards,<br>{escape(SIG_NAME)}{handle}</div>')
    if SIG_WORDMARK:
        parts.append(f'<table cellpadding="0" cellspacing="0" border="0" style="border-top:2px solid {SIG_ACCENT}; padding-top:10px;"><tr><td style="text-align:center;">')
        parts.append(f'<div style="font-family:\'Arial Black\',Arial,sans-serif; font-weight:900; font-size:26px; letter-spacing:3px; color:#0d0d0d;">{escape(SIG_WORDMARK)}</div>')
        if SIG_TAGLINE:
            parts.append(f'<div style="font-family:Arial,sans-serif; font-size:12px; letter-spacing:4px; color:{SIG_ACCENT}; margin-top:2px;">{escape(SIG_TAGLINE)}</div>')
        parts.append('</td></tr></table>')
    parts.append('</div>')
    return "".join(parts)


def build_signature_text():
    lines = []
    if SIG_NAME:
        h = f" ({SIG_HANDLE})" if SIG_HANDLE else ""
        lines.append(f"\n\nRegards,\n{SIG_NAME}{h}")
    if SIG_WORDMARK:
        lines.append(f"\n\n{SIG_WORDMARK}")
        if SIG_TAGLINE:
            lines.append(f"\n{SIG_TAGLINE}")
    return "".join(lines) + "\n" if lines else ""


SIGNATURE_HTML = build_signature_html()
SIGNATURE_TEXT = build_signature_text()


def get_bot_user_id():
    r = requests.get(f"{MM_HTTP}/users/me", headers=HEADERS, timeout=10)
    r.raise_for_status()
    return r.json()["id"]


def send_email(target, body, subject="(no subject)"):
    if not APP_PASSWORD:
        print("FAILED: no SMTP password in Keychain (MMBOT_SMTP_PASSWORD)", flush=True)
        return False, "no SMTP password configured"
    if not SENDER_EMAIL:
        print("FAILED: MMBOT_SENDER_EMAIL not set", flush=True)
        return False, "sender email not configured"
    try:
        msg = MIMEMultipart("alternative")
        msg["Subject"] = subject
        msg["From"] = SENDER_EMAIL
        msg["To"] = target
        msg.attach(MIMEText(body + SIGNATURE_TEXT, "plain"))
        body_html = escape(body).replace("\n", "<br>")
        html = (
            '<div style="font-family:Arial,Helvetica,sans-serif; font-size:14px; '
            'color:#1a1a1a; line-height:1.5;">' + body_html + "</div>" + SIGNATURE_HTML
        )
        msg.attach(MIMEText(html, "html"))
        s = smtplib.SMTP(SMTP_SERVER, SMTP_PORT)
        s.starttls()
        s.login(SENDER_EMAIL, APP_PASSWORD)
        s.send_message(msg)
        s.quit()
        print(f"SUCCESS: sent to {target} | subject={subject!r}", flush=True)
        return True, "sent"
    except Exception as e:
        print(f"FAILED: SMTP error - {e}", flush=True)
        return False, str(e)


def post_reply(channel_id, text, root_id=None):
    payload = {"channel_id": channel_id, "message": text}
    if root_id:
        payload["root_id"] = root_id
    try:
        requests.post(f"{MM_HTTP}/posts", headers=HEADERS, json=payload, timeout=10)
    except Exception as e:
        print(f"reply failed: {e}", flush=True)


def handle_post(post, channel_id):
    if post.get("user_id") == BOT_USER_ID:
        return
    raw = post.get("message", "")
    text = _MAILTO.sub(lambda mm: mm.group(1), raw)
    text = _LINK.sub(lambda mm: mm.group(1), text)
    lines = text.splitlines()
    if not lines:
        return
    first = lines[0]
    m = _EMAIL.search(first)
    if not m:
        return
    target = m.group(1).strip().rstrip(".,;:/\\")
    subject = first[m.end():].strip() or "(no subject)"
    body = "\n".join(lines[1:]).strip() or subject
    ok, detail = send_email(target, body, subject)
    reply = f"\u2705 Email sent to {target}" if ok else f"\u26a0\ufe0f Email failed: {detail}"
    post_reply(channel_id, reply, root_id=post.get("id"))


def on_message(ws, message):
    try:
        data = json.loads(message)
    except Exception:
        return
    if data.get("event") != "posted":
        return
    post = json.loads(data["data"]["post"])
    handle_post(post, post.get("channel_id"))


def on_error(ws, error):
    print(f"WS error: {error}", flush=True)


def on_close(ws, *args):
    print("WS closed; will reconnect", flush=True)


def on_open(ws):
    ws.send(json.dumps({"seq": 1, "action": "authentication_challenge",
                        "data": {"token": BOT_TOKEN}}))
    print("WS connected + authenticated", flush=True)


def run():
    global BOT_USER_ID
    if not BOT_TOKEN:
        print("FATAL: no bot token in Keychain (MMBOT_TOKEN). Run setup.sh first.", flush=True)
        return
    BOT_USER_ID = get_bot_user_id()
    print(f"Bot user id: {BOT_USER_ID}", flush=True)
    while True:
        try:
            ws = websocket.WebSocketApp(
                MM_WS, on_open=on_open, on_message=on_message,
                on_error=on_error, on_close=on_close,
            )
            ws.run_forever(ping_interval=30, ping_timeout=10)
        except Exception as e:
            print(f"run_forever crashed: {e}", flush=True)
        time.sleep(5)


if __name__ == "__main__":
    run()
