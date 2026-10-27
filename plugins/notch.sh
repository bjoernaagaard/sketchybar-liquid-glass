#!/bin/bash
# The popup helper draws media as an island around the notch, so the media item hides there.
source "$CONFIG_DIR/theme.sh"
height=$("$CONFIG_DIR/plugins/.popup-helper" notch | jq -r '.height // empty')
if [ -n "$height" ]; then
  $SB --bar "${BAR_NOTCH[@]}" height="$height" --set media drawing=off
else
  $SB --bar "${BAR_FLOAT[@]}" --set media drawing=on
fi
