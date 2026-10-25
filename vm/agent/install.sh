#!/bin/bash
# Install the PrivacyBrowser in-VM agent as a per-user LaunchAgent.
#
# Run this INSIDE the macOS VM (e.g. over SSH from the controller). It:
#   1. copies pbagent.py and binarycookies.py into ~/.pbagent/
#   2. writes ~/Library/LaunchAgents/com.privacybrowser.agent.plist
#   3. (re)loads the LaunchAgent so the agent starts now and at every login
#
# Install once: the LaunchAgent (RunAtLoad + KeepAlive) brings the agent back
# on its own at every login, so after a reboot — with the VM set to auto-login
# the admin user, as the Cirrus base image is — it is already running. The
# controller reuses an installed agent instead of reinstalling (it reads the
# token file below), so this script normally runs just once per VM.
#
# The agent binds to 127.0.0.1 only; reach it from the host through an SSH
# tunnel (the controller sets one up). The bearer token is saved to
# ~/.pbagent/token (so re-runs keep it) and printed on the last line as
# PB_AGENT_TOKEN=<token> so a caller can capture it.
#
# Usage (inside the VM):
#   ./install.sh [--port 8777] [--backend mac] [--token <token>]
#
# Re-running reuses the saved token (unless --token is given), reinstalls the
# current files and reloads the agent.

set -euo pipefail

PORT=8777
BACKEND=mac
TOKEN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)    PORT="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --token)   TOKEN="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$(command -v python3 || true)"
if [[ -z "$PYTHON" ]]; then
  echo "python3 not found in the VM" >&2
  exit 1
fi
for f in pbagent.py binarycookies.py; do
  if [[ ! -f "$SRC_DIR/$f" ]]; then
    echo "$f not found next to install.sh" >&2
    exit 1
  fi
done

AGENT_HOME="$HOME/.pbagent"
TOKEN_FILE="$AGENT_HOME/token"
mkdir -p "$AGENT_HOME"

# Keep the existing token on re-install unless a new one was passed explicitly,
# so a reused agent keeps answering with the same bearer token.
if [[ -z "$TOKEN" && -f "$TOKEN_FILE" ]]; then
  TOKEN="$(cat "$TOKEN_FILE")"
fi
if [[ -z "$TOKEN" ]]; then
  TOKEN="$("$PYTHON" -c 'import secrets; print(secrets.token_urlsafe(32))')"
fi
printf '%s' "$TOKEN" > "$TOKEN_FILE"
chmod 0600 "$TOKEN_FILE"

install -m 0644 "$SRC_DIR/pbagent.py" "$AGENT_HOME/pbagent.py"
install -m 0644 "$SRC_DIR/binarycookies.py" "$AGENT_HOME/binarycookies.py"

PLIST="$HOME/Library/LaunchAgents/com.privacybrowser.agent.plist"
mkdir -p "$HOME/Library/LaunchAgents"

sed -e "s|@PYTHON@|$PYTHON|g" \
    -e "s|@AGENT@|$AGENT_HOME/pbagent.py|g" \
    -e "s|@PORT@|$PORT|g" \
    -e "s|@BACKEND@|$BACKEND|g" \
    -e "s|@TOKEN@|$TOKEN|g" \
    -e "s|@HOME@|$HOME|g" \
    "$SRC_DIR/com.privacybrowser.agent.plist.template" > "$PLIST"
chmod 0600 "$PLIST"

# Reload: bootout any previous instance, then bootstrap into the GUI session.
UID_NUM="$(id -u)"
# Idempotent (re)load. Under `set -e` a failing bootstrap would abort before the
# token is printed, so tolerate it and fall back to a kickstart of the service
# that bootout should have removed.
launchctl bootout "gui/$UID_NUM/com.privacybrowser.agent" 2>/dev/null || true
if ! launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null; then
  launchctl kickstart -k "gui/$UID_NUM/com.privacybrowser.agent" 2>/dev/null || true
fi
launchctl enable "gui/$UID_NUM/com.privacybrowser.agent" 2>/dev/null || true

echo "Installed. Agent listening on 127.0.0.1:$PORT inside the VM (backend=$BACKEND)." >&2
echo "Log: $AGENT_HOME/agent.log" >&2
# Last line, machine-readable, so the controller can capture it.
echo "PB_AGENT_TOKEN=$TOKEN"
