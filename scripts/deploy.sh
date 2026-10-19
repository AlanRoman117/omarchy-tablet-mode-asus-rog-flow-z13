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
FILES=(manifest.json Widget.qml bin systemd packaging README.md LICENSE)

omarchy-plugin-validate "$REPO" >/dev/null 2>&1 || { omarchy-plugin-validate "$REPO"; exit 1; }

mkdir -p "$DEST"
# The shell hot-reloads a plugin's bin/ and data, but not an already-loaded Widget.qml.
widget_before=$(sha256sum "$DEST/Widget.qml" 2>/dev/null | cut -d' ' -f1)
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

if [[ $(sha256sum "$DEST/Widget.qml" | cut -d' ' -f1) != "$widget_before" ]] && command -v omarchy >/dev/null; then
  # The copy just set off a burst of plugin hot-reloads. Restarting the shell in the middle
  # of it crashed Quickshell 0.3.1 once (SIGSEGV creating an object during exit, 2026-10-06),
  # so let the burst finish first.
  sleep 3
  omarchy restart shell >/dev/null 2>&1 && echo "Widget.qml changed: restarted the Omarchy shell to load it"
fi

# Keep an installed unit in step with the template, then restart a running service.
if [[ -f $UNIT_FILE ]]; then
  # The path goes into sed's replacement and the unit, as `tablet-mode enable` also requires.
  [[ $DEST =~ ^[A-Za-z0-9._/+-]+$ ]] || { echo "Unsupported characters in $DEST; unit not updated" >&2; exit 1; }
  sed "s|@BIN@|$DEST/bin/tablet-mode|g" "$DEST/systemd/$UNIT" >"$UNIT_FILE.tmp" && mv -f "$UNIT_FILE.tmp" "$UNIT_FILE"
  systemctl --user daemon-reload
  systemctl --user try-restart "$UNIT" && echo "Restarted $UNIT (if it was running)"
fi
