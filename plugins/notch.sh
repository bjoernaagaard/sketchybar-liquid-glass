#!/bin/bash
# Every display shows three pills. SketchyBar leaves room for the camera housing only when it knows
# the notch width, and it applies the width only on a display that has a notch.
source "$CONFIG_DIR/theme.sh"
$SB --bar notch_width="$("$CONFIG_DIR/plugins/.popup-helper" notch | jq '.width // 0')"
