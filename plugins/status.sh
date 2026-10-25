#!/bin/bash
"$CONFIG_DIR/plugins/hover.sh" && exit 0
source "$CONFIG_DIR/theme.sh"

case "$NAME" in
  clock)
    $SB --set clock icon="$(date '+%a %-d %b')" label="$(date '+%H:%M')"
    ;;

  volume)
    IFS='|' read -r vol muted < <("$CONFIG_DIR/plugins/.popup-helper" audio | jq -r '[(.volume // "fixed"), .muted] | join("|")')
    [ -n "$vol" ] || exit 1
    if [ "$vol" = fixed ]; then
      $SB --set volume icon=$'\xf4\x80\x8a\xa9' label=""
      exit 0
    fi
    if [ "$muted" = true ] || [ "$vol" -eq 0 ]; then icon=$'\xf4\x80\x8a\xa3'
    elif [ "$vol" -lt 34 ]; then icon=$'\xf4\x80\x8a\xa5'
    elif [ "$vol" -lt 67 ]; then icon=$'\xf4\x80\x8a\xa7'
    else icon=$'\xf4\x80\x8a\xa9'; fi
    $SB --set volume icon="$icon" label="${vol}%"
    ;;

  battery)
    batt=$(pmset -g batt)
    pct=$(printf '%s' "$batt" | grep -Eo '[0-9]+%' | head -1 | tr -d %)
    if [ -z "$pct" ]; then $SB --set battery drawing=off; exit 0; fi
    if printf '%s' "$batt" | grep -q 'AC Power'; then icon=$'\xf4\x80\xa2\x8b'
    elif [ "$pct" -ge 88 ]; then icon=$'\xf4\x80\x9b\xa8'
    elif [ "$pct" -ge 63 ]; then icon=$'\xf4\x80\xba\xb8'
    elif [ "$pct" -ge 38 ]; then icon=$'\xf4\x80\xba\xb6'
    elif [ "$pct" -ge 13 ]; then icon=$'\xf4\x80\x9b\xa9'
    else icon=$'\xf4\x80\x9b\xaa'; fi
    $SB --set battery drawing=on icon="$icon" label="${pct}%"
    ;;

  wifi)
    dev=$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline; print $2}')
    if [ -n "$(ipconfig getifaddr "$dev" 2>/dev/null)" ]; then
      $SB --set wifi icon=$'\xf4\x80\x99\x87' icon.color=$TEXT2
    else
      $SB --set wifi icon=$'\xf4\x80\x99\x88' icon.color=$TEXT3
    fi
    ;;
esac
