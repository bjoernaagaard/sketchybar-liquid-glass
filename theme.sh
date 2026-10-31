#!/bin/bash
SB=sketchybar
FONT="SF Pro"

TEXT=0xebffffff
TEXT2=0x9effffff
TEXT3=0x57ffffff
PILL=0x21ffffff
HOVER=0x12ffffff
# The media progress plate: white at low opacity, so it reads as glass and not as a hue.
PROGRESS=0x14ffffff
CLEAR=0x00ffffff
BAR_COLOR=0xe61e2023
BAR_EDGE=0x1fffffff
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

# The bar is clear and holds three pills: half.left, island.media, and half.right. The *.start and *.end
# items supply the 4 pt inner padding.
BAR_NOTCH=(color=$CLEAR border_width=0)
PILL_STYLE=(background.color=$BAR_COLOR background.border_color=$BAR_EDGE background.border_width=1
            background.corner_radius=12 background.height=30)

# A fixed cell for the volume label, so "100%" fits and the media island's fit stays stable. An explicit
# width ignores padding: "100%" in SF Pro Medium 13 measures 35.4 pt, plus the 8 pt label.padding_right.
VOLUME_LABEL_WIDTH=44

# The media island ends this far from the left island and from the notch.
ISLAND_GAP=5

# The media controls are fixed cells, so the fit stays stable. The widest glyph (backward.fill and forward.fill,
# SF Pro Medium 13) advances 19.1 pt.
MEDIA_CONTROL_WIDTH=28

# The progress plate sits PROGRESS_INSET inside the island, on every side. Its corners are concentric with
# the island's 12 pt corners, and shrink to half the width while the plate is narrower than two radii.
PROGRESS_INSET=2
PROGRESS_HEIGHT=26
PROGRESS_RADIUS=10

# Native popups share the bar material without blur or size animation.
POPUP_RADIUS=12
POPUP_WIDTH=280
POPUP_GAP=8
POPUP_PADDING=16
POPUP_ROW=32
CALENDAR_TODAY_SIZE=22
