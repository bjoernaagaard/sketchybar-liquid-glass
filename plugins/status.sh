#!/bin/bash
case "$SENDER" in
  mouse.entered|mouse.exited) exec "$CONFIG_DIR/plugins/hover.sh" ;;
esac
source "$CONFIG_DIR/theme.sh"
# Status updates can change widths and shift other anchors on the same side of the bar.
trap '[ ! -x "$CONFIG_DIR/plugins/.popup-helper" ] || "$CONFIG_DIR/plugins/.popup-helper" geometry' EXIT

case "$NAME" in
  mode)
    mode=$(aerospace list-modes --current)
    if [ -z "$mode" ] || [ "$mode" = main ]; then $SB --set mode drawing=off
    else $SB --set mode drawing=on label="$mode"; fi
    ;;

  clock)
    IFS='|' read -r day time < <(date '+%a %-d %b|%H:%M')
    $SB --set clock icon="$day" label="$time"
    ;;

  volume)
    [ "$SENDER" = mouse.scrolled ] && exec "$CONFIG_DIR/plugins/.popup-helper" volume-scroll "$SCROLL_DELTA"
    # The resident helper pushes VOLUME and MUTED. Other events leave the item as it is.
    [ "$SENDER" = volume_state ] || exit 0
    if [ "$VOLUME" = fixed ]; then
      $SB --set volume icon=$'\xf4\x80\x8a\xa9' label=""
      exit 0
    fi
    if [ "$MUTED" = true ] || [ "$VOLUME" -eq 0 ]; then icon=$'\xf4\x80\x8a\xa3'
    elif [ "$VOLUME" -lt 34 ]; then icon=$'\xf4\x80\x8a\xa5'
    elif [ "$VOLUME" -lt 67 ]; then icon=$'\xf4\x80\x8a\xa7'
    else icon=$'\xf4\x80\x8a\xa9'; fi
    $SB --set volume icon="$icon" label="${VOLUME}%"
    ;;

  battery)
    batt=$(pmset -g batt)
    if [[ $batt =~ ([0-9]+)% ]]; then pct=${BASH_REMATCH[1]}; else pct=; fi
    if [ -z "$pct" ]; then $SB --set battery drawing=off; exit 0; fi
    if [[ $batt == *'AC Power'* ]]; then icon=$'\xf4\x80\xa2\x8b'
    elif [ "$pct" -ge 88 ]; then icon=$'\xf4\x80\x9b\xa8'
    elif [ "$pct" -ge 63 ]; then icon=$'\xf4\x80\xba\xb8'
    elif [ "$pct" -ge 38 ]; then icon=$'\xf4\x80\xba\xb6'
    elif [ "$pct" -ge 13 ]; then icon=$'\xf4\x80\x9b\xa9'
    else icon=$'\xf4\x80\x9b\xaa'; fi
    $SB --set battery drawing=on icon="$icon" label="${pct}%"
    ;;

  media)
    # The resident helper pushes MEDIA, LABEL, and WIDTH. It fits the label to the media item, and the
    # item to the gap between the left island and the notch.
    [ "$SENDER" = media_state ] || exit 0
    # The media item shows a note, and media.toggle shows the play state.
    # SF Pro music.note U+10046A, verified in SF-Pro.ttf as glyph 15101.
    # SF Pro play.fill U+100284 and pause.fill U+100286, verified in SF-Pro.ttf as glyphs 14741 and 14783.
    # SF Pro backward.fill U+10028A and forward.fill U+10028C, verified in SF-Pro.ttf as glyphs 14831 and 14843.
    if [ "$MEDIA" = unavailable ]; then note=$TEXT3; toggle=$'\xf4\x80\x8a\x84'; toggle_color=$TEXT3; skip=$TEXT3
    elif [ "$MEDIA" = playing ]; then note=$TEXT2; toggle=$'\xf4\x80\x8a\x86'; toggle_color=$TEXT; skip=$TEXT2
    else note=$TEXT3; toggle=$'\xf4\x80\x8a\x84'; toggle_color=$TEXT2; skip=$TEXT2; fi
    honor_reduce_motion
    $SB "${COLOR_ANIM[@]}" --set media icon=$'\xf4\x80\x91\xaa' icon.color=$note \
                           --set media.toggle icon="$toggle" icon.color=$toggle_color \
                           --set media.prev icon=$'\xf4\x80\x8a\x8a' icon.color=$skip \
                           --set media.next icon=$'\xf4\x80\x8a\x8c' icon.color=$skip
    $SB "${SIZE_ANIM[@]}" --set media width="$WIDTH" label="$LABEL"
    ;;

  media.progress)
    # The plate has no footprint, so a new width moves nothing and needs no geometry call.
    trap - EXIT
    [ "$SENDER" = media_progress ] || exit 0
    # The helper pushes WIDTH: the plate's width in points, 0 when nothing is timed.
    if [ "$WIDTH" -lt 1 ]; then $SB --set media.progress drawing=off; exit 0; fi
    # Corners stay concentric with the island, and shrink to half the width while the plate is narrow.
    radius=$PROGRESS_RADIUS
    [ $((WIDTH / 2)) -ge "$radius" ] || radius=$((WIDTH / 2))
    $SB --set media.progress drawing=on label.width=$WIDTH padding_right=$((-(ISLAND_GAP + PROGRESS_INSET + WIDTH))) \
                             background.corner_radius=$radius
    ;;

  network)
    [ "$SENDER" = network_state ] || exit 0
    # SF Pro network: U+100906, verified in SF-Pro.ttf as glyph 14009.
    case "$KIND" in
      wifi) icon=$'\xf4\x80\x99\x87'; color=$TEXT2 ;;
      none) icon=$'\xf4\x80\xa4\x86'; color=$TEXT3 ;;
      *)    icon=$'\xf4\x80\xa4\x86'; color=$TEXT2 ;;
    esac
    $SB "${COLOR_ANIM[@]}" --set network icon="$icon" icon.color=$color
    ;;

  tailscale)
    [ "$SENDER" = tailscale_state ] || exit 0
    # SF Pro circle.grid.3x3.fill U+1001F9 and circle.grid.3x3 U+1001F8, both in SF-Pro.ttf.
    case "$KIND" in
      exit-node)   icon=$'\xf4\x80\x87\xb9'; color=$TEXT ;;
      running)     icon=$'\xf4\x80\x87\xb9'; color=$TEXT2 ;;
      stopped)     icon=$'\xf4\x80\x87\xb9'; color=$TEXT3 ;;
      login)       icon=$'\xf4\x80\x87\xb8'; color=$TEXT2 ;;
      *)           icon=$'\xf4\x80\x87\xb8'; color=$TEXT3 ;;
    esac
    $SB "${COLOR_ANIM[@]}" --set tailscale icon="$icon" icon.color=$color
    ;;

  system.cpu)
    # The labels have fixed cells, so a new sample moves nothing and needs no geometry call.
    trap - EXIT
    # The resident helper pushes CPU and MEM percents and a level for CPU, memory, and disk.
    [ "$SENDER" = system_state ] || exit 0
    tint() { case "$1" in crit) c=$CRIT ;; warn) c=$WARN ;; *) c=$TEXT2 ;; esac; }
    tint "$DISK_LEVEL"; icons=$c
    tint "$CPU_LEVEL"; cpu=$c
    tint "$MEM_LEVEL"; mem=$c
    # SF Pro cpu U+100AE5 and memorychip U+100AE6, verified in SF-Pro.ttf as glyphs 21391 and 21397.
    $SB "${COLOR_ANIM[@]}" --set system.cpu icon=$'\xf4\x80\xab\xa5' icon.color=$icons label="${CPU}%" label.color=$cpu \
                           --set system.memory icon=$'\xf4\x80\xab\xa6' icon.color=$icons label="${MEM}%" label.color=$mem
    ;;
esac
