#!/bin/sh
# stm.disk plugin. Installed by `stm install item:disk` (#21).
#
# item.lua runs this with:
#   NAME, SENDER                     the SketchyBar item and event
#   STM_GREEN STM_YELLOW STM_RED STM_GREY
#                                    palette colours as 0xAARRGGBB (may be empty)
#   STM_DISK_SHAPE                   plain | pill | split
#   STM_DISK_CW STM_DISK_PAD         label character width and paddings (empty
#                                    until the bar has told item.lua its font)
#
# STM_DF overrides /bin/df and STM_DATA_VOLUME /System/Volumes/Data (tests).

LC_ALL=C
export LC_ALL

NAME=${NAME:-stm.disk}
shape=${STM_DISK_SHAPE:-split}

# The Data volume holds everything you write; / is the sealed system volume,
# and the only one before macOS 10.15.
vol=${STM_DATA_VOLUME:-/System/Volumes/Data}
[ -d "$vol" ] || vol=/

# The Capacity column, found by its header: %iused is a percentage too.
use=$("${STM_DF:-/bin/df}" -k "$vol" 2>/dev/null |
  /usr/bin/awk 'NR == 1 { for (f = 1; f <= NF; f++) if ($f == "Capacity") col = f; next }
    col && $col ~ /^[0-9]+%$/ { p = $col + 0; found = 1; exit }
    END {
      if (!found || p > 100) exit
      n = split("80 90", below, " ")
      split("green yellow red", band, " ")
      for (i = 1; i <= n && p >= below[i] + 0; i++) ;
      printf "%d %s\n", p, band[i]
    }')
read -r pct band <<EOF
$use
EOF

case $band in
  green) color=$STM_GREEN ;;
  yellow) color=$STM_YELLOW ;;
  red) color=$STM_RED ;;
  *) color=$STM_GREY pct="" ;;
esac
label=${pct:+$pct%}
label=${label:---}

# label.width is the whole label, paddings included.
width=""
case "$STM_DISK_CW:$STM_DISK_PAD" in
  *[!0-9.:]* | :* | *:) ;;
  *) width=$(/usr/bin/awk -v n=${#label} -v cw="$STM_DISK_CW" -v pad="$STM_DISK_PAD" \
    'BEGIN { w = n * cw; i = int(w); if (i < w) i++; print pad + i }') ;;
esac

set -- --set "$NAME" label="$label"
[ -n "$width" ] && set -- "$@" label.width="$width"
if [ "$shape" = split ]; then
  [ -n "$color" ] && set -- "$@" --set "$NAME.icon" background.color="$color"
else
  [ -n "$color" ] && set -- "$@" icon.color="$color"
fi
sketchybar "$@"
