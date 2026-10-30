#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/scripts/package.sh" >/dev/null
app="$HOME/Applications/Gaisan.app"
# Quit the running copy and wait, so macOS doesn't refuse to open the new one.
if pkill -x Gaisan 2>/dev/null; then
  for _ in {1..50}; do pgrep -x Gaisan >/dev/null || break; sleep 0.1; done
fi
rm -rf "$app"
ditto "$root/dist/Gaisan.app" "$app"
open "$app"
echo "Opened: $app"
