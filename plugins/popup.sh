#!/bin/bash
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/sketchybar}"
source "$CONFIG_DIR/theme.sh"
PLUGIN_DIR="$CONFIG_DIR/plugins"
HELPER="$PLUGIN_DIR/.popup-helper"

if [ "$1" = build ]; then
  [ ! -x "$HELPER" ] || "$HELPER" stop
  if [ ! -x "$HELPER" ] || [ "$PLUGIN_DIR/popup.swift" -nt "$HELPER" ]; then
    trap 'rm -f "$PLUGIN_DIR/.popup-build"' EXIT
    /usr/bin/xcrun swiftc -O "$PLUGIN_DIR/popup.swift" -o "$PLUGIN_DIR/.popup-build" || exit 1
    mv "$PLUGIN_DIR/.popup-build" "$HELPER"
  fi
  exit 0
fi

export CONFIG_DIR TEXT TEXT2 TEXT3 BAR_COLOR BAR_EDGE
export POPUP_RADIUS POPUP_WIDTH POPUP_GAP POPUP_PADDING POPUP_ROW
export SB="$(command -v "$SB")"
export POPUP_BAR_PID="$(pgrep -x sketchybar)"
"$HELPER" "${1:-$NAME}" </dev/null >/dev/null 2>&1 &
