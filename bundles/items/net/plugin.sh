#!/bin/sh
# stm.net plugin. Installed by `stm install item:net` (#19).
#
# item.lua runs this with:
#   NAME, SENDER           the SketchyBar item and event
#   STM_MAGENTA STM_RED    palette colours as 0xAARRGGBB (may be empty)
#   STM_NET_SHAPE          plain | pill | split
#   STM_NET_LABEL          type | ip
# Colours are never hard-coded here: they follow the palette.
#
# macOS hides the Wi-Fi name (SSID) from processes without Location Services,
# so this shows the kind of link instead.
#
# STM_SCUTIL, STM_IPCONFIG and STM_IFCONFIG override /usr/sbin/scutil,
# /usr/sbin/ipconfig and /sbin/ifconfig (tests).

# Byte-wise character classes: SketchyBar may pass on a UTF-8 LANG, where
# [a-z] also matches upper-case and accented letters.
LC_ALL=C
export LC_ALL

NAME=${NAME:-stm.net}
shape=${STM_NET_SHAPE:-split}

# The interface carrying the default route, IPv4 first, then IPv6 (an
# IPv6-only link is still online); none means offline. A split-tunnel VPN
# leaves the route, and so this item, on the physical link.
dev=$(printf 'show State:/Network/Global/IPv4\nshow State:/Network/Global/IPv6\n' |
  "${STM_SCUTIL:-/usr/sbin/scutil}" 2>/dev/null |
  /usr/bin/awk -F' : ' '$1 ~ /^ *PrimaryInterface$/ { print $2; exit }')
# A BSD interface name only; anything else never reaches a tool or the bar.
case "$dev" in
  "" | [!a-z]* | *[!a-z0-9]*) dev="" ;;
esac

# Glyphs: nf-fa-wifi, nf-md-ethernet, nf-md-vpn, nf-md-lan, nf-md-wifi_off.
color=$STM_MAGENTA
case "$dev" in
  "")
    glyph="󰖪" label=offline color=$STM_RED
    ;;
  utun* | ipsec* | ppp*)
    glyph="󰖂" label=VPN
    ;;
  *)
    type=$("${STM_IPCONFIG:-/usr/sbin/ipconfig}" getsummary "$dev" 2>/dev/null |
      /usr/bin/awk -F' : ' '$1 ~ /^ *InterfaceType$/ { print $2; exit }')
    case "$type" in
      WiFi) glyph="" label=Wi-Fi ;;
      Ethernet) glyph="󰈀" label=Ethernet ;;
      *) glyph="󰌘" label=$dev ;;
    esac
    ;;
esac

# label ip: the interface's first IPv4 address, when it has one. ifconfig,
# not `ipconfig getifaddr`, which knows no VPN tunnel (utun*).
if [ "${STM_NET_LABEL:-type}" = ip ] && [ -n "$dev" ]; then
  ip=$("${STM_IFCONFIG:-/sbin/ifconfig}" "$dev" 2>/dev/null |
    /usr/bin/awk '$1 == "inet" { print $2; exit }')
  case "$ip" in
    "" | *[!0-9.]*) ;;
    *) label=$ip ;;
  esac
fi

# split: the glyph and its state colour live on the icon sub-item (item.lua
# keeps that icon black); otherwise the colour goes on the icon itself.
if [ "$shape" = split ]; then
  set -- --set "$NAME" label="$label" --set "$NAME.icon" icon="$glyph"
  [ -n "$color" ] && set -- "$@" background.color="$color"
else
  set -- --set "$NAME" icon="$glyph" label="$label"
  [ -n "$color" ] && set -- "$@" icon.color="$color"
fi
sketchybar "$@"
