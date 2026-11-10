#!/usr/bin/env bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title ECNU VPN Switcher
# @raycast.mode fullOutput

# Optional parameters:
# @raycast.icon 🎓
# @raycast.packageName ECNU VPN
# @raycast.description Connect ECNU aTrust using Keychain, or stop its container.
# @raycast.needsConfirmation false

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VPN_DIR="${ECNU_VPN_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"
VPN_SCRIPT="$VPN_DIR/atrust-vpn.sh"

if /bin/bash "$VPN_SCRIPT" status >/dev/null 2>&1; then
  exec /bin/bash "$VPN_SCRIPT" down
else
  exec /bin/bash "$VPN_SCRIPT" up
fi
