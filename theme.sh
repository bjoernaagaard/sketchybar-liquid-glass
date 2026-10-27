#!/bin/bash
SB=sketchybar
FONT="SF Pro"

TEXT=0xebffffff
TEXT2=0x9effffff
TEXT3=0x57ffffff
PILL=0x21ffffff
HOVER=0x12ffffff
CLEAR=0x00ffffff
BAR_COLOR=0xe61e2023
BAR_EDGE=0x1fffffff
ISLAND_COLOR=0xff000000

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

# Bar layouts. notch.sh picks one for the main display. A notched display gets a flush bar in
# the color of the camera housing, so the notch and the island that grows out of it read as one shape.
BAR_FLOAT=(height=30 margin=8 y_offset=8 corner_radius=12 color=$BAR_COLOR border_width=1 shadow=on padding_left=4 padding_right=4)
BAR_NOTCH=(margin=0 y_offset=0 corner_radius=0 color=$ISLAND_COLOR border_width=0 shadow=off padding_left=12 padding_right=12)

# Dynamic Island: wing width beside the notch, open corner radius, and spring response in seconds.
ISLAND_WING=36
ISLAND_RADIUS=20
ISLAND_RESPONSE=0.35

# Native popups share the bar material without blur or size animation.
POPUP_RADIUS=12
POPUP_WIDTH=280
POPUP_GAP=8
POPUP_PADDING=16
POPUP_ROW=32
CALENDAR_TODAY_SIZE=22
