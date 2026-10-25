#!/bin/bash
# Redraws every workspace pill and the front app from one AeroSpace snapshot.
source "$CONFIG_DIR/theme.sh"

focused=${FOCUSED_WORKSPACE:-$(aerospace list-workspaces --focused)}
windows=$(aerospace list-windows --all --format '%{workspace}|%{app-bundle-id}')
IFS='|' read -r front_id front_name < <(aerospace list-windows --focused --format '%{app-bundle-id}|%{app-name}' 2>/dev/null)

now=()    # images, visibility, text: cannot animate
sizes=()  # widths
colors=()
collapsing=()

for ws in $(aerospace list-workspaces --all); do
  apps=()
  while IFS= read -r id; do [ -n "$id" ] && apps+=("$id"); done \
    < <(printf '%s\n' "$windows" | awk -F'|' -v w="$ws" '$1==w && !seen[$2]++ {print $2}' | head -n $MAX_APPS)
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

  for i in $(seq 0 $((MAX_APPS - 1))); do
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
