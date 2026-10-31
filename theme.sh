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
# Apple's dark-mode system yellow and red, for readings under strain.
WARN=0xffffd60a
CRIT=0xffff453a

SIZE_ANIM=(--animate tanh 12)
COLOR_ANIM=(--animate tanh 10)

# macOS Reduce Motion makes sizes jump while colors still fade. Reading it launches a process,
# so only a script that animates size calls this.
honor_reduce_motion() {
  if [ "$(defaults read com.apple.universalaccess reduceMotion 2>/dev/null)" = 1 ]; then SIZE_ANIM=(); fi
}

# Layout. An item with an explicit width ignores its padding, so every gap below is a width.
# App icon artwork fills about 80% of its canvas: scale 0.64 draws 16 pt of visible icon.
ICON_SCALE=0.64
APP_SLOT=20      # 16 pt icon centered, so 2 pt on each side and 4 pt between icons
NUM_GAP=4        # number to first icon: 4 + 2 = 6 pt
PILL_END=6       # last icon to pill edge: 2 + 6 = 8 pt, the same as pill edge to number
MAX_APPS=4

# Bar layouts. notch.sh picks one for the main display. On a notched display the bar is clear and
# its two halves become pills beside the camera housing, so the island can grow out of the notch
# between them. The half.*.start and half.*.end items supply the 4 pt inner padding in both layouts.
BAR_FLOAT=(color=$BAR_COLOR border_width=1)
BAR_NOTCH=(color=$CLEAR border_width=0)
PILL_STYLE=(background.color=$BAR_COLOR background.border_color=$BAR_EDGE background.border_width=1
            background.corner_radius=12 background.height=30)

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
