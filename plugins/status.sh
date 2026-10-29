#!/bin/bash
if [ "$NAME" = media ]; then
  case "$SENDER" in
    mouse.entered) "$CONFIG_DIR/plugins/popup.sh" media-hover ;;
    mouse.exited)  "$CONFIG_DIR/plugins/popup.sh" media-hover-end ;;
  esac
fi
case "$SENDER" in
  mouse.entered|mouse.exited) exec "$CONFIG_DIR/plugins/hover.sh" ;;
esac
source "$CONFIG_DIR/theme.sh"

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
    # The resident helper pushes MEDIA, TITLE, and ARTIST from its media-control stream.
    [ "$SENDER" = media_state ] || exit 0
    if [ "$MEDIA" = unavailable ]; then
      # SF Pro music.note U+10046A, verified in SF-Pro.ttf as glyph 15101.
      $SB --set media icon=$'\xf4\x80\x91\xaa' icon.color=$TEXT3 label="Media unavailable"
      exit 0
    fi
    if [ -z "$TITLE" ]; then label="Not playing"
    elif [ -z "$ARTIST" ]; then label=$TITLE
    else label="$TITLE · $ARTIST"; fi
    # SF Pro pause.fill U+100286 and play.fill U+100284, verified in SF-Pro.ttf.
    if [ "$MEDIA" = playing ]; then icon=$'\xf4\x80\x8a\x86'; color=$TEXT
    else icon=$'\xf4\x80\x8a\x84'; color=$TEXT2; fi
    $SB "${COLOR_ANIM[@]}" --set media icon="$icon" icon.color=$color label="$label"
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
