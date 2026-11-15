# sketchybar-liquid-glass

A SketchyBar configuration for macOS 26 that draws the bar as glass islands around the notch, with workspace pills for AeroSpace and native popups for volume, network, Bluetooth, Tailscale, media, calendar and system load.

```text
[ mode | workspaces | front app ][ media  prev play next  volume ] (notch) [ cpu memory  tailscale network bluetooth  battery clock ]
```

The shell scripts lay out and update the bar items, and a Swift helper draws the glass behind them and opens the popups.

```text
sketchybarrc          creates the items and builds the helper
theme.sh              colors, sizes and motion settings
plugins/
├── status.sh         renders bar items from state events
├── spaces.sh         workspace pills from AeroSpace
├── popup.sh          builds and runs the Swift helper
└── popup/*.swift     glass, popups and system state readers
```

## Requirements

- macOS 26 and the Xcode command line tools, which compile the helper with `swiftc` on the first start.
- [SketchyBar](https://github.com/FelixKratz/SketchyBar) and the SF Pro font from [Apple](https://developer.apple.com/fonts/).
- [AeroSpace](https://github.com/nikitabobko/AeroSpace) for the workspace pills.
- [media-control](https://github.com/ungive/media-control) for the media island, and the Homebrew `tailscale` formula for the Tailscale popup. The bar runs without them and shows an error in the matching popup.

## Install

First, clone the repository to the path SketchyBar reads.

```sh
git clone https://github.com/bjoernaagaard/sketchybar-liquid-glass.git ~/.config/sketchybar
```

Second, add these callbacks to `~/.config/aerospace/aerospace.toml` so the workspace pills follow AeroSpace.

```toml
exec-on-workspace-change = ["/bin/bash", "-c", "sketchybar --trigger aerospace_workspace_change FOCUSED_WORKSPACE=$AEROSPACE_FOCUSED_WORKSPACE"]
on-focus-changed = ["exec-and-forget sketchybar --trigger aerospace_focus_change"]
on-mode-changed = ["exec-and-forget sketchybar --trigger aerospace_mode_change"]
```

Third, start the bar with `brew services start sketchybar`. The clock popup asks for Calendar access the first time you open it.

## Changing the bar

Colors, sizes and spring settings live in `theme.sh`. [AGENTS.md](AGENTS.md) has the rules for code changes and the steps to check a change on the running bar.
