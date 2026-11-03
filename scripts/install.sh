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
# LaunchServices can still refuse a bundle it just saw replaced (-600); one retry is enough.
open "$app" 2>/dev/null || { sleep 1; open "$app"; }
echo "Opened: $app"
