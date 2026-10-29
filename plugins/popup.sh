#!/bin/bash
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/sketchybar}"
source "$CONFIG_DIR/theme.sh"
PLUGIN_DIR="$CONFIG_DIR/plugins"
HELPER="$PLUGIN_DIR/.popup-helper"

if [ "$1" = build ]; then
  [ ! -x "$HELPER" ] || "$HELPER" stop
  if [ ! -x "$HELPER" ] || [ "$PLUGIN_DIR/popup.swift" -nt "$HELPER" ] || [ "$PLUGIN_DIR/popup-info.plist" -nt "$HELPER" ] || [ "$PLUGIN_DIR/popup.sh" -nt "$HELPER" ]; then
    trap 'rm -f "$PLUGIN_DIR/.popup-build"' EXIT
    # Swift 6 includes three Approachable Concurrency features; enable the other two.
    # This is an AppKit app module, so UI and model state default to the main actor.
    /usr/bin/xcrun swiftc -O -swift-version 6 -strict-concurrency=complete \
      -default-isolation MainActor \
      -enable-upcoming-feature NonisolatedNonsendingByDefault \
      -enable-upcoming-feature InferIsolatedConformances \
      "$PLUGIN_DIR/popup.swift" -o "$PLUGIN_DIR/.popup-build" \
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$PLUGIN_DIR/popup-info.plist" || exit 1
    mv "$PLUGIN_DIR/.popup-build" "$HELPER"
  fi
  exit 0
fi

# Right click on volume toggles mute instead of opening the popup.
[ "$1" = volume ] && [ "$BUTTON" = right ] && exec "$HELPER" mute-toggle

export CONFIG_DIR TEXT TEXT2 TEXT3 BAR_COLOR BAR_EDGE ISLAND_COLOR WARN CRIT
export POPUP_RADIUS POPUP_WIDTH POPUP_GAP POPUP_PADDING POPUP_ROW CALENDAR_TODAY_SIZE
export ISLAND_WING ISLAND_RADIUS ISLAND_RESPONSE
export SB="$(command -v "$SB")"
# macOS pgrep excludes ancestors by default. A bar click runs under SketchyBar.
export POPUP_BAR_PID="$(/usr/bin/pgrep -a -x -u "$UID" sketchybar)"
"$HELPER" "${1:-$NAME}" </dev/null >/dev/null 2>&1 &
