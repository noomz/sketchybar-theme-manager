#!/bin/sh
# stm.battery plugin. Installed by `stm install item:battery` (#19).
#
# item.lua runs this with:
#   NAME, SENDER                  the SketchyBar item and event
#   STM_GREEN STM_YELLOW STM_RED  palette colours as 0xAARRGGBB (may be empty)
#   STM_BAT_SHAPE                 plain | pill | split
# Colours are never hard-coded here: they follow the palette.
#
# STM_PMSET overrides /usr/bin/pmset (tests).

NAME=${NAME:-stm.battery}
shape=${STM_BAT_SHAPE:-split}

batt=$("${STM_PMSET:-/usr/bin/pmset}" -g batt 2>/dev/null)
# The Mac's own battery only: a UPS is listed too, on its own line.
pct=$(printf '%s\n' "$batt" |
  /usr/bin/awk '/InternalBattery/ && match($0, /[0-9]+%/) { print substr($0, RSTART, RLENGTH - 1); exit }')

# No battery (a desktop Mac, with or without a UPS): hide the item rather than show a stale level.
if [ -z "$pct" ]; then
  set -- --set "$NAME" drawing=off
  [ "$shape" = split ] && set -- "$@" --set "$NAME.icon" drawing=off
  sketchybar "$@"
  exit 0
fi

# nf-md battery glyphs by level; a bolt (nf-fa-bolt) on AC power.
if [ "$pct" -ge 90 ]; then
  glyph="󰂎"
elif [ "$pct" -ge 60 ]; then
  glyph="󰂑"
elif [ "$pct" -ge 30 ]; then
  glyph="󰂓"
elif [ "$pct" -ge 10 ]; then
  glyph="󰂖"
else
  glyph="󰂗"
fi

# State colour: green on AC power; on battery, yellow at 30% and red at 15%.
color=$STM_GREEN
case "$batt" in
  *"AC Power"*) glyph="" ;;
  *)
    if [ "$pct" -le 15 ]; then
      color=$STM_RED
    elif [ "$pct" -le 30 ]; then
      color=$STM_YELLOW
    fi
    ;;
esac

# split: the icon and its state colour live on the icon sub-item (item.lua
# keeps that icon black); otherwise the colour goes on the icon itself.
if [ "$shape" = split ]; then
  set -- --set "$NAME" drawing=on label="$pct%" --set "$NAME.icon" drawing=on icon="$glyph"
  [ -n "$color" ] && set -- "$@" background.color="$color"
else
  set -- --set "$NAME" drawing=on icon="$glyph" label="$pct%"
  [ -n "$color" ] && set -- "$@" icon.color="$color"
fi
sketchybar "$@"
