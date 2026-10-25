#!/bin/bash
source "$CONFIG_DIR/theme.sh"
case "$SENDER" in
  mouse.entered) $SB "${COLOR_ANIM[@]}" --set "$NAME" background.color=$HOVER ;;
  mouse.exited)  $SB "${COLOR_ANIM[@]}" --set "$NAME" background.color=$CLEAR ;;
  *) exit 1 ;;
esac
