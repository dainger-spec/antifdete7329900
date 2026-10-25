#!/bin/bash
# Install the PrivacyBrowser in-VM agent as a per-user LaunchAgent.
#
# Run this INSIDE the macOS VM (e.g. over SSH from the controller). It:
#   1. copies pbagent.py into ~/.pbagent/
#   2. writes ~/Library/LaunchAgents/com.privacybrowser.agent.plist
#   3. (re)loads the LaunchAgent so the agent starts now and at every login
#
# The agent binds to 127.0.0.1 only; reach it from the host through an SSH
# tunnel (the controller sets one up). The bearer token is printed once, on
# the last line, as  PB_AGENT_TOKEN=<token>  so a caller can capture it.
#
# Usage (inside the VM):
#   ./install.sh [--port 8777] [--backend mac] [--token <token>]
#
# Re-running rotates nothing unless you pass a new --token; it reinstalls the
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
if [[ ! -f "$SRC_DIR/pbagent.py" ]]; then
  echo "pbagent.py not found next to install.sh" >&2
  exit 1
fi

if [[ -z "$TOKEN" ]]; then
  TOKEN="$("$PYTHON" -c 'import secrets; print(secrets.token_urlsafe(32))')"
fi

AGENT_HOME="$HOME/.pbagent"
mkdir -p "$AGENT_HOME"
install -m 0644 "$SRC_DIR/pbagent.py" "$AGENT_HOME/pbagent.py"

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
launchctl bootout "gui/$UID_NUM/com.privacybrowser.agent" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl enable "gui/$UID_NUM/com.privacybrowser.agent"

echo "Installed. Agent listening on 127.0.0.1:$PORT inside the VM (backend=$BACKEND)." >&2
echo "Log: $AGENT_HOME/agent.log" >&2
# Last line, machine-readable, so the controller can capture it.
echo "PB_AGENT_TOKEN=$TOKEN"
