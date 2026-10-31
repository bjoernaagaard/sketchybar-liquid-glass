#!/bin/bash
case "$SENDER" in
  mouse.entered|mouse.exited) ;;
  *) exit 1 ;;
esac
case "$NAME" in
  system.*)
    # Moving between the two halves of the system bracket runs one half's exit and the other's entry
    # at once. Each takes a lock, records its half, and colors the bracket from the halves still hovered.
    state="${TMPDIR:-/tmp}/sketchybar-hover"
    [ -n "$HOVER_LOCKED" ] || HOVER_LOCKED=1 exec /usr/bin/lockf -k "$state.lock" "$0"
    if [ "$SENDER" = mouse.entered ]; then action=hover; else action=hover-end; fi
    "$CONFIG_DIR/plugins/popup.sh" "$action" "$NAME"
    source "$CONFIG_DIR/theme.sh"
    if [ "$SENDER" = mouse.entered ]; then : > "$state.$NAME"; else rm -f "$state.$NAME"; fi
    color=$CLEAR
    for half in "$state".system.*; do [ -e "$half" ] && color=$HOVER; done
    exec $SB "${COLOR_ANIM[@]}" --set system background.color=$color ;;
esac
case "$NAME" in
  volume|network|tailscale|clock|media|front|front.icon|battery|mode|ws.*)
    if [ "$SENDER" = mouse.entered ]; then action=hover; else action=hover-end; fi
    "$CONFIG_DIR/plugins/popup.sh" "$action" "$NAME" ;;
esac
source "$CONFIG_DIR/theme.sh"
case "$SENDER" in
  mouse.entered) $SB "${COLOR_ANIM[@]}" --set "$NAME" background.color=$HOVER ;;
  mouse.exited)
    if [ "$NAME" = mode ]; then color=$PILL; else color=$CLEAR; fi
    $SB "${COLOR_ANIM[@]}" --set "$NAME" background.color=$color ;;
esac
