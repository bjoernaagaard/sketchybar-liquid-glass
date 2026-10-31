#!/bin/bash
# Every display shows three pills. SketchyBar leaves room for the camera housing only when it knows
# the notch width, and it applies the width only on a display that has a notch.
source "$CONFIG_DIR/theme.sh"
if [ "$SENDER" = appearance_state ]; then
  # The resident helper pushes TRANSPARENCY and CONTRAST from the accessibility display settings.
  if [ "$TRANSPARENCY" = reduced ]; then fill=$BAR_SOLID; else fill=$BAR_COLOR; fi
  if [ "$CONTRAST" = high ]; then edge=$BAR_EDGE_STRONG; else edge=$BAR_EDGE; fi
  pill=(background.color=$fill background.border_color=$edge)
  exec $SB "${COLOR_ANIM[@]}" --set half.left "${pill[@]}" --set island.media "${pill[@]}" --set half.right "${pill[@]}"
fi
$SB --bar notch_width="$("$CONFIG_DIR/plugins/.popup-helper" notch | jq '.width // 0')"
