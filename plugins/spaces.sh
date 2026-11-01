#!/bin/bash
# Redraws every workspace pill and the front app from one AeroSpace snapshot.
source "$CONFIG_DIR/theme.sh"

focused=${FOCUSED_WORKSPACE:-$(aerospace list-workspaces --focused)}
windows=$(aerospace list-windows --all --format '%{workspace}|%{app-bundle-id}')
IFS='|' read -r front_id front_name < <(aerospace list-windows --focused --format '%{app-bundle-id}|%{app-name}' 2>/dev/null)
workspaces=$(aerospace list-workspaces --all 2>/dev/null)

# AeroSpace may send no event when it starts after the bar, so one chain asks again every 2 s
# for up to a minute. The directory marks a running chain, so other events don't start more.
pending="${TMPDIR:-/tmp}/sketchybar-spaces-retry"
retry=${SPACES_RETRY:-0}
if [ -n "$workspaces" ]; then
  rmdir "$pending" 2>/dev/null
elif [ -n "${SPACES_RETRY:-}" ] || mkdir "$pending" 2>/dev/null; then
  if [ "$retry" -lt 30 ]; then (sleep 2; $SB --trigger aerospace_focus_change SPACES_RETRY=$((retry + 1))) &
  else rmdir "$pending" 2>/dev/null; fi
fi

# The bar does not wait for AeroSpace. The first snapshot after it answers builds any missing pill,
# then moves every pill before mode in AeroSpace's order. A pill whose workspace is gone is removed.
bar=$($SB --query bar)
add=()
if [ -n "$workspaces" ]; then
  for item in $(jq -r '.items[] | select(test("^ws\\.[^.]+$"))' <<< "$bar"); do
    case " $(echo $workspaces) " in *" ${item#ws.} "*) ;; *) add+=(--remove "/^ws\\.${item#ws.}\\./" --remove "$item") ;; esac
  done
fi
order=()
for ws in $workspaces; do
  case "$ws" in *[!a-zA-Z0-9_-]*|'') continue ;; esac
  members=("ws.$ws")
  for ((i = 0; i < MAX_APPS; i++)); do members+=("ws.$ws.a$i"); done
  members+=("ws.$ws.end")
  # Only the first pill goes without a 2 pt gap before it, whichever workspace is first now.
  gap=()
  if [ ${#order[@]} = 0 ]; then
    [[ $bar == *"\"ws.$ws.gap\""* ]] && add+=(--remove "ws.$ws.gap")
  else
    gap=("ws.$ws.gap")
    [[ $bar == *"\"ws.$ws.gap\""* ]] || add+=(--add item "$gap" left --set "$gap" width=2)
  fi
  order+=("${gap[@]}" "${members[@]}" "ws.$ws.pill")
  [[ $bar == *"\"ws.$ws\""* ]] && continue
  add+=(--add item "ws.$ws" left
        --set "ws.$ws" label="$ws" label.color=$TEXT3 label.padding_left=8 label.padding_right=8
                       background.drawing=off script="$CONFIG_DIR/plugins/hover.sh" click_script="aerospace workspace $ws"
        --subscribe "ws.$ws" mouse.entered mouse.exited)
  for ((i = 0; i < MAX_APPS; i++)); do
    add+=(--add item "ws.$ws.a$i" left
          --set "ws.$ws.a$i" drawing=off width=0 background.drawing=on
                             background.image.scale=$ICON_SCALE script="$CONFIG_DIR/plugins/hover.sh" click_script="aerospace workspace $ws"
          --subscribe "ws.$ws.a$i" mouse.entered mouse.exited)
  done
  add+=(--add item "ws.$ws.end" left --set "ws.$ws.end" width=0
        --add bracket "ws.$ws.pill" "${members[@]}"
        --set "ws.$ws.pill" background.color=$CLEAR background.height=22 background.corner_radius=8)
done
if [ ${#add[@]} -gt 0 ]; then
  for item in "${order[@]}"; do add+=(--move "$item" before mode); done
  $SB "${add[@]}"
fi

# Images, visibility, text and sizes change at once; the helper's springs move the glass to the new sizes.
now=()
grow=()    # icons that were hidden: they start small and grow
reduce_motion=
colors=()

# One query names the icons of the focused workspace that are drawn now. Only the others grow in.
focused_icons=()
for ((i = 0; i < MAX_APPS; i++)); do focused_icons+=(--query "ws.$focused.a$i"); done
shown=" $($SB "${focused_icons[@]}" 2>/dev/null | jq -rs 'map(select(.geometry.drawing == "on") | .name) | join(" ")') "

for ws in $workspaces; do
  case "$ws" in *[!a-zA-Z0-9_-]*|'') continue ;; esac
  apps=()
  while IFS='|' read -r window_ws id; do
    [ "$window_ws" = "$ws" ] && [ -n "$id" ] || continue
    duplicate=0
    for app in "${apps[@]}"; do [ "$app" = "$id" ] && duplicate=1 && break; done
    [ "$duplicate" = 0 ] && apps+=("$id")
    [ ${#apps[@]} -ge "$MAX_APPS" ] && break
  done <<< "$windows"
  n=${#apps[@]}

  if [ "$ws" = "$focused" ] && [ "$n" -gt 0 ]; then
    now+=(--set "ws.$ws" label.padding_right=$NUM_GAP --set "ws.$ws.end" width=$PILL_END)
  else
    now+=(--set "ws.$ws" label.padding_right=8 --set "ws.$ws.end" width=0)
  fi
  if [ "$ws" = "$focused" ]; then
    colors+=(--set "ws.$ws" label.color=$TEXT --set "ws.$ws.pill" background.color=$PILL)
  else
    [ "$n" -gt 0 ] && c=$TEXT2 || c=$TEXT3
    colors+=(--set "ws.$ws" label.color=$c --set "ws.$ws.pill" background.color=$CLEAR)
  fi

  for ((i = 0; i < MAX_APPS; i++)); do
    item="ws.$ws.a$i"
    if [ "$i" -ge "$n" ]; then
      now+=(--set "$item" drawing=off width=0)
    elif [ "$ws" = "$focused" ]; then
      now+=(--set "$item" drawing=on width=$APP_SLOT background.image="app.${apps[$i]}")
      case "$shown" in
        *" $item "*) ;;
        *)
          # Under Reduce Motion a new icon appears at full size. Reading the setting launches a process,
          # so only a switch that shows a new icon reads it.
          [ -n "$reduce_motion" ] || reduce_motion=$(defaults read com.apple.universalaccess reduceMotion 2>/dev/null || echo 0)
          if [ "$reduce_motion" = 1 ]; then now+=(background.image.scale=$ICON_SCALE)
          else now+=(background.image.scale=$ICON_SCALE_START); grow+=(--set "$item" background.image.scale=$ICON_SCALE); fi ;;
      esac
    else
      now+=(--set "$item" drawing=off width=0)
    fi
  done
done

if [ -n "$front_id" ]; then
  now+=(--set front.icon drawing=on background.image="app.$front_id" --set front label="$front_name")
else
  now+=(--set front.icon drawing=off --set front label="Desktop")
fi

$SB "${now[@]}"
$SB "${COLOR_ANIM[@]}" "${grow[@]}" "${colors[@]}"
[ ! -x "$CONFIG_DIR/plugins/.popup-helper" ] || "$CONFIG_DIR/plugins/.popup-helper" geometry
