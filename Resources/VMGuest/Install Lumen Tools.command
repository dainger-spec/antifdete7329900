#!/bin/sh
# Opened from "My Shared Files" in the virtual machine's Finder, once, after macOS's own first-run
# setup: makes this machine the base of Lumen's virtual-machine profiles (install.sh says what that is).
cd "$(dirname "$0")" || exit 1
exec /bin/sh ./install.sh
