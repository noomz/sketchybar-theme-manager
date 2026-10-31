#!/bin/sh
set -eu
LC_ALL=C
export LC_ALL
case "$(/usr/sbin/sysctl -n hw.model 2>/dev/null)" in
  VirtualMac*) ;;
  *) printf '%s\n' 'Refusing preference probe outside a VirtualMac guest' >&2; exit 1 ;;
esac
D=$1
[ -d "$D" ] || exit 1
[ "$(/usr/bin/osascript "$D/menu-mode.applescript")" = 'In Full Screen Only' ] || {
  printf '%s\n' 'Probe requires the original fullscreen-only GUI baseline' >&2
  exit 1
}
/usr/bin/defaults read NSGlobalDomain >/dev/null
for k in _HIHideMenuBar AppleMenuBarVisibleInFullscreen; do
  [ ! -e "$D/$k.type" ] || {
    printf '%s\n' 'Refusing to replace an existing snapshot' >&2
    exit 1
  }
  if /usr/bin/defaults read NSGlobalDomain "$k" >"$D/$k.value" 2>"$D/$k.error"; then
    printf 'Probe requires an initially absent key: %s\n' "$k" >&2
    exit 1
  fi
  /usr/bin/grep -F "Could not find key '$k'" "$D/$k.error" >/dev/null || exit 1
  printf '%s\n' absent >"$D/$k.type"
done
/usr/bin/sw_vers >"$D/environment.txt"
printf 'snapshot=%s\n' "$D"
