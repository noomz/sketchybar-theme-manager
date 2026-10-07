#!/bin/sh
# stm.mem plugin. Installed by `stm install item:mem` (#21).
#
# item.lua runs this with:
#   NAME, SENDER                 the SketchyBar item and event
#   STM_GREEN STM_YELLOW STM_RED STM_GREY
#                                palette colours as 0xAARRGGBB (may be empty)
#   STM_MEM_CW STM_MEM_PAD       label character width and paddings (empty
#                                until the bar has told item.lua its font)
#
# STM_MEMORY_PRESSURE and STM_SYSCTL override /usr/bin/memory_pressure and
# /usr/sbin/sysctl (tests).

LC_ALL=C
export LC_ALL

NAME=${NAME:-stm.mem}

used=$("${STM_MEMORY_PRESSURE:-/usr/bin/memory_pressure}" -Q 2>/dev/null |
  /usr/bin/awk '/free percentage: / {
    v = $0
    sub(/.*free percentage: /, "", v)
    if (v ~ /^[0-9]+%$/ && v + 0 <= 100) printf "%d %.2f\n", 100 - v, (100 - v) / 100
    exit
  }')
read -r pct value <<EOF
$used
EOF

# The kernel's own verdict on memory pressure: 1 normal, 2 warn, 4 critical.
case $("${STM_SYSCTL:-/usr/sbin/sysctl}" -n kern.memorystatus_vm_pressure_level 2>/dev/null) in
  1) color=$STM_GREEN ;;
  2) color=$STM_YELLOW ;;
  4) color=$STM_RED ;;
  *) color=$STM_GREY ;;
esac
label=${pct:+$pct%}
label=${label:---}

# label.width is the whole label, paddings included.
width=""
case "$STM_MEM_CW:$STM_MEM_PAD" in
  *[!0-9.:]* | :* | *:) ;;
  *) width=$(/usr/bin/awk -v n=${#label} -v cw="$STM_MEM_CW" -v pad="$STM_MEM_PAD" \
    'BEGIN { w = n * cw; i = int(w); if (i < w) i++; print pad + i }') ;;
esac

set -- --set "$NAME" label="$label"
[ -n "$width" ] && set -- "$@" label.width="$width"
[ -n "$color" ] && set -- "$@" graph.color="$color" graph.fill_color="0x40${color#0x??}"
[ -n "$pct" ] && set -- --push "$NAME" "$value" "$@"
sketchybar "$@"
