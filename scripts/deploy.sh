#!/bin/bash

# Copies the plugin's runtime files from this repo into Omarchy's plugin folder.
# Tests, fixtures and dev notes stay in the repo. The shell hot-reloads the
# plugin on change, and the service is restarted if it's running.
#
# Usage: scripts/deploy.sh

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/alanroman117.tablet-mode"
UNIT="omarchy-tablet-mode.service"
UNIT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/$UNIT"
FILES=(manifest.json Widget.qml bin systemd README.md LICENSE)

omarchy-plugin-validate "$REPO" >/dev/null 2>&1 || { omarchy-plugin-validate "$REPO"; exit 1; }

mkdir -p "$DEST"
for item in "${FILES[@]}"; do
  rsync -a --delete "$REPO/$item" "$DEST/"
done
# Anything else in the plugin folder is left over from an older layout.
for path in "$DEST"/* "$DEST"/.[!.]*; do
  [[ -e $path ]] || continue
  name=$(basename "$path")
  [[ " ${FILES[*]} " == *" $name "* ]] || rm -rf "$path"
done
echo "Deployed to $DEST"

# Keep an installed unit in step with the template, then restart a running service.
if [[ -f $UNIT_FILE ]]; then
  sed "s|@BIN@|$DEST/bin/tablet-mode|g" "$DEST/systemd/$UNIT" >"$UNIT_FILE"
  systemctl --user daemon-reload
  systemctl --user try-restart "$UNIT" && echo "Restarted $UNIT (if it was running)"
fi
