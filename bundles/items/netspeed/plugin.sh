#!/bin/sh
# stm.netspeed plugin. Installed by `stm install item:netspeed` (#21).
#
# item.lua runs this with:
#   NAME, SENDER             the SketchyBar item and event
#   STM_NS_VIEW              unified | separate
#   STM_NS_CW STM_NS_PAD     label character width and paddings (empty until
#                            the bar has told item.lua its font)
#
# STM_SCUTIL, STM_NETSTAT and STM_SLEEP override /usr/sbin/scutil,
# /usr/sbin/netstat and /bin/sleep (tests).

# Byte-wise character classes: SketchyBar may pass on a UTF-8 LANG, where
# [a-z] also matches upper-case and accented letters.
LC_ALL=C
export LC_ALL

NAME=${NAME:-stm.netspeed}
view=${STM_NS_VIEW:-unified}

dev=$(printf 'show State:/Network/Global/IPv4\nshow State:/Network/Global/IPv6\n' |
  "${STM_SCUTIL:-/usr/sbin/scutil}" 2>/dev/null |
  /usr/bin/awk -F' : ' '$1 ~ /^ *PrimaryInterface$/ { print $2; exit }')
case "$dev" in
  "" | [!a-z]* | *[!a-z0-9]*) dev="" ;;
esac

# "<Ibytes> <Obytes>" from the interface's <Link#> row, counted from the
# right: a tunnel's row (utun*) has no Address column.
counters() {
  "${STM_NETSTAT:-/usr/sbin/netstat}" -ibn -I "$dev" 2>/dev/null |
    /usr/bin/awk '$3 ~ /^<Link#/ { print $(NF - 4), $(NF - 1); exit }'
}
before=""
after=""
if [ -n "$dev" ]; then
  before=$(counters)
  "${STM_SLEEP:-/bin/sleep}" 1
  after=$(counters)
fi

rates=$(/usr/bin/awk -v before="$before" -v after="$after" '
  function rate(was, now) {
    if (was !~ /^[0-9]+$/ || now !~ /^[0-9]+$/ || now + 0 < was + 0) return -1
    return now - was
  }
  function level(r,   v) {
    if (r < 0) return 0
    v = log(r + 1) / log(10) / 8
    return v > 1 ? 1 : v
  }
  function text(r,   i) {
    if (r < 0) return "--"
    for (i = 1; i <= n && r >= below[i] + 0; i++) ;
    return int(r / per[i]) unit[i]
  }
  BEGIN {
    n = split("1000 1000000 1000000000", below, " ")
    split("1 1000 1000000 1000000000", per, " ")
    split("B K M G", unit, " ")
    split(before, was, " ")
    split(after, now, " ")
    down = rate(was[1], now[1])
    up = rate(was[2], now[2])
    printf "%.3f %.3f %s %s\n", level(down), level(up), text(down), text(up)
  }')
read -r down_level up_level down up <<EOF
$rates
EOF

# label.width is the whole label, paddings included.
width() {
  case "$STM_NS_CW:$STM_NS_PAD" in
    *[!0-9.:]* | :* | *:) ;;
    *) /usr/bin/awk -v n="$1" -v cw="$STM_NS_CW" -v pad="$STM_NS_PAD" \
      'BEGIN { w = n * cw; i = int(w); if (i < w) i++; print pad + i }' ;;
  esac
}

set -- --push "$NAME" "$down_level" --push "$NAME.up" "$up_level"
if [ "$view" = separate ]; then
  set -- "$@" --set "$NAME" label="$down"
  w=$(width ${#down})
  [ -n "$w" ] && set -- "$@" label.width="$w"
  set -- "$@" --set "$NAME.up" label="$up"
  w=$(width ${#up})
  [ -n "$w" ] && set -- "$@" label.width="$w"
else
  n=${#down}
  [ ${#up} -gt "$n" ] && n=${#up}
  set -- "$@" --set "$NAME.rates" icon="↑$up" label="↓$down"
  w=$(width $((n + 1)))
  [ -n "$w" ] && set -- "$@" label.width="$w"
fi
sketchybar "$@"
