#!/bin/bash
# The popup helper draws media as an island around the notch, so the media item hides there.
source "$CONFIG_DIR/theme.sh"
if [ -n "$("$CONFIG_DIR/plugins/.popup-helper" notch | jq -r '.height // empty')" ]; then
  $SB --bar "${BAR_NOTCH[@]}" --set media drawing=off --set half.left background.drawing=on --set half.right background.drawing=on
else
  $SB --bar "${BAR_FLOAT[@]}" --set media drawing=on --set half.left background.drawing=off --set half.right background.drawing=off
fi
