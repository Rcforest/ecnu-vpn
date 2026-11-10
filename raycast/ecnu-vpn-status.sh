#!/usr/bin/env bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title ECNU VPN Status
# @raycast.mode inline
# @raycast.refreshTime 5s

# Optional parameters:
# @raycast.icon 🎓
# @raycast.packageName ECNU VPN

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VPN_DIR="${ECNU_VPN_DIR:-$(cd -- "$SCRIPT_DIR/.." && pwd)}"

if output="$(/bin/bash "$VPN_DIR/atrust-vpn.sh" status 2>/dev/null)"; then
  printf '%s\n' "$output"
else
  echo "○ OFF  ECNU aTrust"
fi
