#!/bin/bash
SB="$CONFIG_DIR/bin/sketchybar-next"
FONT="SF Pro"

TEXT=0xebffffff
TEXT2=0x9effffff
TEXT3=0x57ffffff
PILL=0x21ffffff
HOVER=0x12ffffff
CLEAR=0x00ffffff
BAR_COLOR=0xe61e2023
BAR_EDGE=0x1fffffff

# macOS Reduce Motion: sizes jump, colors still fade
[ "$(defaults read com.apple.universalaccess reduceMotion 2>/dev/null)" = 1 ] && REDUCE_MOTION=1 || REDUCE_MOTION=0
SIZE_ANIM=(--animate tanh 12)
[ "$REDUCE_MOTION" = 1 ] && SIZE_ANIM=()
COLOR_ANIM=(--animate tanh 10)

# Layout. An item with an explicit width ignores its padding, so every gap below is a width.
# App icon artwork fills about 80% of its canvas: scale 0.64 draws 16 pt of visible icon.
ICON_SCALE=0.64
APP_SLOT=20      # 16 pt icon centered, so 2 pt on each side and 4 pt between icons
NUM_GAP=4        # number to first icon: 4 + 2 = 6 pt
PILL_END=6       # last icon to pill edge: 2 + 6 = 8 pt, the same as pill edge to number
MAX_APPS=4
