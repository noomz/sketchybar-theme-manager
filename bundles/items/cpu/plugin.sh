#!/bin/sh
# stm.cpu plugin. Installed by `stm install item:cpu` (#21).
#
# item.lua runs this with:
#   NAME, SENDER                 the SketchyBar item and event
#   STM_GREEN STM_YELLOW STM_ORANGE STM_RED STM_GREY
#                                palette colours as 0xAARRGGBB (may be empty)
#   STM_CPU_CW STM_CPU_PAD       label character width and paddings (empty
#                                until the bar has told item.lua its font)
#
# STM_IOSTAT overrides /usr/sbin/iostat (tests).

LC_ALL=C
export LC_ALL

NAME=${NAME:-stm.cpu}

# Of iostat's two samples a second apart, the first averages since boot and
# the last covers that second.
sample=$("${STM_IOSTAT:-/usr/sbin/iostat}" -n0 -c 2 -w 1 2>/dev/null |
  /usr/bin/awk '{ last = $0 } END {
    if (split(last, f, " ") < 3 || f[1] !~ /^[0-9]+$/ || f[2] !~ /^[0-9]+$/) exit
    load = f[1] + f[2]
    if (load > 100) load = 100
    n = split("30 60 80", below, " ")
    split("green yellow orange red", band, " ")
    for (i = 1; i <= n && load >= below[i] + 0; i++) ;
    printf "%d %s %.2f\n", load, band[i], load / 100
  }')
read -r pct band value <<EOF
$sample
EOF

case $band in
  green) color=$STM_GREEN ;;
  yellow) color=$STM_YELLOW ;;
  orange) color=$STM_ORANGE ;;
  red) color=$STM_RED ;;
  *) color=$STM_GREY pct="" ;;
esac
label=${pct:+$pct%}
label=${label:---}

# label.width is the whole label, paddings included.
width=""
case "$STM_CPU_CW:$STM_CPU_PAD" in
  *[!0-9.:]* | :* | *:) ;;
  *) width=$(/usr/bin/awk -v n=${#label} -v cw="$STM_CPU_CW" -v pad="$STM_CPU_PAD" \
    'BEGIN { w = n * cw; i = int(w); if (i < w) i++; print pad + i }') ;;
esac

set -- --set "$NAME" label="$label"
[ -n "$width" ] && set -- "$@" label.width="$width"
[ -n "$color" ] && set -- "$@" graph.color="$color" graph.fill_color="0x40${color#0x??}"
[ -n "$pct" ] && set -- --push "$NAME" "$value" "$@"
sketchybar "$@"
