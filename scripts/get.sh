#!/bin/bash
# Installs or updates Gaisan from the latest GitHub release, picking the build for this Mac's chip:
#   curl -fsSL https://raw.githubusercontent.com/bujosa/gaisan/main/scripts/get.sh | bash
# GAISAN_VERSION=0.1.0 picks a release. GAISAN_INSTALL_DIR picks the folder (default ~/Applications, or
# /Applications when Gaisan is already there).
set -euo pipefail

repo="bujosa/gaisan"
work=""

fail() {
  echo "gaisan: $*" >&2
  exit 1
}

main() {
  [ "$(uname -s)" = Darwin ] || fail "Gaisan runs on macOS only."
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$major" -ge 14 ] || fail "Gaisan needs macOS 14 or later. This Mac has $(sw_vers -productVersion)."

  # hw.optional.arm64 is 1 on Apple silicon, even from a Terminal running under Rosetta.
  local chip="intel"
  if [ "$(sysctl -in hw.optional.arm64)" = 1 ]; then chip="apple-silicon"; fi

  local version="${GAISAN_VERSION:-}"
  if [ -z "$version" ]; then
    local latest
    latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest")" ||
      fail "Can't reach GitHub."
    version="${latest##*/tag/v}"
  fi
  case "$version" in
    "" | */* | *:*) fail "Can't find the latest Gaisan release." ;;
  esac

  local zip="Gaisan-$version-macOS-$chip.zip"
  local url="https://github.com/$repo/releases/download/v$version/$zip"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  echo "Downloading Gaisan $version for $chip Macs…"
  curl -fL --progress-bar -o "$work/$zip" "$url" || fail "Can't download $url"
  curl -fsSL -o "$work/$zip.sha256" "$url.sha256" || fail "Can't download the checksum for $zip"
  (cd "$work" && shasum -a 256 -c "$zip.sha256" >/dev/null) || fail "$zip doesn't match its checksum."

  ditto -x -k "$work/$zip" "$work/app"
  codesign --verify --strict "$work/app/Gaisan.app" || fail "Gaisan.app's code signature is invalid."

  local dir="${GAISAN_INSTALL_DIR:-}"
  if [ -z "$dir" ]; then
    dir="$HOME/Applications"
    if [ -d /Applications/Gaisan.app ] && [ -w /Applications ]; then dir="/Applications"; fi
  fi
  mkdir -p "$dir"

  # Quit the running copy and wait, so macOS doesn't refuse to open the new one.
  if pkill -x Gaisan 2>/dev/null; then
    local tries=0
    while pgrep -x Gaisan >/dev/null && [ "$tries" -lt 50 ]; do
      sleep 0.1
      tries=$((tries + 1))
    done
  fi
  rm -rf "$dir/Gaisan.app"
  ditto "$work/app/Gaisan.app" "$dir/Gaisan.app"

  open "$dir/Gaisan.app" || fail "Installed $dir/Gaisan.app, but macOS couldn't open it. Open it from Finder."
  echo "Installed Gaisan $version in $dir. Look for today in the menu bar."
}

main "$@"
