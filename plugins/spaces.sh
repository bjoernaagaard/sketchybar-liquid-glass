#!/bin/bash
# Redraws every workspace pill and the front app from one AeroSpace snapshot.
source "$CONFIG_DIR/theme.sh"

# The resident helper coordinates workspace and media updates.
if [ "${1:-}" != --snapshot ]; then
  exec "$CONFIG_DIR/plugins/.popup-helper" workspace-update "${SPACES_RETRY:-0}"
fi

focused=$(aerospace list-workspaces --focused)
windows=$(aerospace list-windows --all --format '%{workspace}|%{app-bundle-id}')
IFS='|' read -r front_id front_name < <(aerospace list-windows --focused --format '%{app-bundle-id}|%{app-name}' 2>/dev/null)
workspaces=$(aerospace list-workspaces --all 2>/dev/null)
mode=$(aerospace list-modes --current 2>/dev/null)

# AeroSpace may send no event when it starts after the bar, so one chain asks again every 2 s
# for up to a minute. The directory marks a running chain, so other events don't start more.
pending="${TMPDIR:-/tmp}/sketchybar-spaces-retry"
retry=${2:-0}
if [ -n "$workspaces" ]; then
  rmdir "$pending" 2>/dev/null
elif [ "$retry" -gt 0 ] || mkdir "$pending" 2>/dev/null; then
  if [ "$retry" -lt 30 ]; then (sleep 2; $SB --trigger aerospace_focus_change SPACES_RETRY=$((retry + 1))) >/dev/null 2>&1 &
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
fi

# Collect images, visibility, text, and sizes for the helper to publish together.
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

if [ -z "$mode" ] || [ "$mode" = main ]; then now+=(--set mode drawing=off)
else now+=(--set mode drawing=on label="$mode"); fi

if [ -n "$front_id" ]; then
  now+=(--set front.icon drawing=on background.image="app.$front_id" --set front label="$front_name")
else
  now+=(--set front.icon drawing=off --set front label="Desktop")
fi

# Reject a snapshot if the workspace list, windows, focus, or front app changed while it was built.
current_focused=$(aerospace list-workspaces --focused)
current_windows=$(aerospace list-windows --all --format '%{workspace}|%{app-bundle-id}')
current_workspaces=$(aerospace list-workspaces --all 2>/dev/null)
current_mode=$(aerospace list-modes --current 2>/dev/null)
IFS='|' read -r current_id current_name < <(aerospace list-windows --focused --format '%{app-bundle-id}|%{app-name}' 2>/dev/null)
[ "$focused" = "$current_focused" ] && [ "$windows" = "$current_windows" ] && [ "$workspaces" = "$current_workspaces" ] && [ "$mode" = "$current_mode" ] &&
  [ "$front_id" = "$current_id" ] && [ "$front_name" = "$current_name" ] || exit 75

# Return commands to the resident helper, which combines them with the media layout.
json_array() { jq -cn '$ARGS.positional' --args -- "$@"; }
jq -cn --argjson add "$(json_array "${add[@]}")" --argjson now "$(json_array "${now[@]}")" \
  --argjson animation "$(json_array "${COLOR_ANIM[@]}" "${grow[@]}" "${colors[@]}")" \
  --argjson colorAnimation "$(json_array "${COLOR_ANIM[@]}")" \
  --argjson bar "$bar" '{add: $add, now: $now, animation: $animation, colorAnimation: $colorAnimation, items: $bar.items}'
