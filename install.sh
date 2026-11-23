#!/bin/bash
# Installs or updates Islet (yetanothernotch) from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/Breanzy/yetanothernotch/main/install.sh | bash
#
# Uninstall (your settings, clipboard history and shelf files are kept):
#
#   curl -fsSL https://raw.githubusercontent.com/Breanzy/yetanothernotch/main/install.sh | bash -s -- --uninstall
set -euo pipefail

REPO="Breanzy/yetanothernotch"
APP="Islet.app"
URL="https://github.com/$REPO/releases/latest/download/Islet.zip"
DATA="$HOME/Library/Application Support/Islet"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Islet is a macOS app."
version="$(sw_vers -productVersion)"
(( ${version%%.*} >= 15 )) || fail "Islet needs macOS 15 Sequoia or later (this Mac has $version)."

# Find an existing copy (to update it in place), else pick /Applications or ~/Applications.
existing=""
for dir in /Applications "$HOME/Applications"; do
  [[ -d "$dir/$APP" ]] && existing="$dir" && break
done

quit_islet() {
  if pgrep -x Islet >/dev/null 2>&1; then
    step "Quitting the running Islet"
    pkill -x Islet || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Islet >/dev/null 2>&1 || break; sleep 0.3; done
  fi
}

if [[ "${1:-}" == "--uninstall" ]]; then
  quit_islet
  if [[ -n "$existing" ]]; then
    # To the Trash rather than deleted, in case you change your mind.
    trash="$HOME/.Trash/Islet $(date +%Y-%m-%d\ %H.%M.%S).app"
    mv "$existing/$APP" "$trash"
    step "Moved $existing/$APP to the Trash"
  else
    step "Islet isn't installed in /Applications or ~/Applications"
  fi
  echo
  bold "Islet is uninstalled."
  echo "Your settings, clipboard history and any files still on the shelf were kept in:"
  echo "  $DATA"
  echo "Open that folder's Shelf subfolder to get shelf files back, or delete the folder to remove everything."
  exit 0
fi

if [[ -n "$existing" ]]; then
  dest="$existing"
elif [[ -w /Applications ]]; then
  dest="/Applications"
else
  dest="$HOME/Applications"
  mkdir -p "$dest"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

step "Downloading the latest Islet"
curl -fL --progress-bar "$URL" -o "$tmp/Islet.zip" || fail "Couldn't download $URL"
ditto -x -k "$tmp/Islet.zip" "$tmp/unpacked" || fail "The download looks damaged; try again."
[[ -d "$tmp/unpacked/$APP" ]] || fail "The download didn't contain $APP."

quit_islet
step "Installing to $dest/$APP"
rm -rf "${dest:?}/$APP"
ditto "$tmp/unpacked/$APP" "$dest/$APP"
# Downloaded with curl, so macOS doesn't quarantine it; clear the flag anyway in case it was set.
xattr -dr com.apple.quarantine "$dest/$APP" 2>/dev/null || true

step "Opening Islet"
open "$dest/$APP"

echo
bold "Islet is installed. Move your pointer to the top-center of the screen to open it."
echo "No notch? It shows as a small pill in the middle of the menu bar."
echo "macOS will ask for permissions (Music/Spotify, Calendar, Camera) the first time you use each feature."
