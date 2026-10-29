#!/bin/bash
# Redraws every workspace pill and the front app from one AeroSpace snapshot.
source "$CONFIG_DIR/theme.sh"
honor_reduce_motion

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
                       background.drawing=off click_script="aerospace workspace $ws")
  for ((i = 0; i < MAX_APPS; i++)); do
    add+=(--add item "ws.$ws.a$i" left
          --set "ws.$ws.a$i" drawing=off width=0 background.drawing=on
                             background.image.scale=$ICON_SCALE click_script="aerospace workspace $ws")
  done
  add+=(--add item "ws.$ws.end" left --set "ws.$ws.end" width=0
        --add bracket "ws.$ws.pill" "${members[@]}"
        --set "ws.$ws.pill" background.color=$CLEAR background.height=22 background.corner_radius=8)
done
if [ ${#add[@]} -gt 0 ]; then
  for item in "${order[@]}"; do add+=(--move "$item" before mode); done
  $SB "${add[@]}"
fi

now=()    # images, visibility, text: cannot animate
sizes=()  # widths
colors=()
collapsing=()

for ws in $workspaces; do
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
    sizes+=(--set "ws.$ws" label.padding_right=$NUM_GAP --set "ws.$ws.end" width=$PILL_END)
  else
    sizes+=(--set "ws.$ws" label.padding_right=8 --set "ws.$ws.end" width=0)
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
      now+=(--set "$item" drawing=on background.image="app.${apps[$i]}")
      sizes+=(--set "$item" width=$APP_SLOT background.image.scale=$ICON_SCALE)
    elif [ ${#SIZE_ANIM[@]} -eq 0 ]; then
      now+=(--set "$item" drawing=off width=0)
    else
      sizes+=(--set "$item" width=0 background.image.scale=0)
      collapsing+=("$item")
    fi
  done
done

if [ -n "$front_id" ]; then
  now+=(--set front.icon drawing=on background.image="app.$front_id" --set front label="$front_name")
else
  now+=(--set front.icon drawing=off --set front label="Desktop")
fi

$SB "${now[@]}"
$SB "${SIZE_ANIM[@]}" "${sizes[@]}"
$SB "${COLOR_ANIM[@]}" "${colors[@]}"

# A width-0 item still widens its pill by 2 pt, so hide each one once it has finished
# collapsing. One that a newer switch is growing again has width above 0 and stays.
[ ${#collapsing[@]} -gt 0 ] && {
  sleep 0.3
  for item in "${collapsing[@]}"; do
    [ "$($SB --query "$item" | jq '.geometry.width')" = 0 ] && $SB --set "$item" drawing=off
  done
} &
