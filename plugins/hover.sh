#!/bin/bash
source "$CONFIG_DIR/theme.sh"
case "$SENDER" in
  mouse.entered) $SB --animate tanh 6 --set "$NAME" background.color=$HOVER ;;
  mouse.exited)  $SB --animate tanh 10 --set "$NAME" background.color=$CLEAR ;;
  *) exit 1 ;;
esac
