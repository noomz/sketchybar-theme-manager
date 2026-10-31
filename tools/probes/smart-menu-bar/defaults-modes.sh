#!/bin/sh
set -eu
case "$(/usr/sbin/sysctl -n hw.model 2>/dev/null)" in
  VirtualMac*) ;;
  *) printf "%s\n" "Refusing preference probe outside a VirtualMac guest" >&2; exit 1 ;;
esac
D=$1
for k in _HIHideMenuBar AppleMenuBarVisibleInFullscreen; do
  [ "$(/bin/cat "$D/$k.type")" = absent ] || exit 1
  if /usr/bin/defaults read NSGlobalDomain "$k" >/dev/null 2>&1; then exit 1; fi
done
restore() {
  trap - EXIT HUP INT TERM
  result=0
  /usr/bin/osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || :
  /usr/bin/open 'x-apple.systempreferences:com.apple.ControlCenter-Settings.extension'
  /bin/sleep 2
  /usr/bin/osascript "$D/menu-mode.applescript" 'In Full Screen Only' || result=1
  for k in _HIHideMenuBar AppleMenuBarVisibleInFullscreen; do
    /usr/bin/defaults delete NSGlobalDomain "$k" >/dev/null 2>&1 || :
    if /usr/bin/defaults read NSGlobalDomain "$k" >/dev/null 2>&1; then result=1; fi
  done
  "$D/measure"
  printf 'restore_result=%s\n' "$result"
  return "$result"
}
finish() {
  status=$?
  trap - EXIT HUP INT TERM
  if ! restore; then status=1; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
sample() {
  printf '\n%s\n' "$1"
  /bin/date -u +%Y-%m-%dT%H:%M:%SZ
  /usr/bin/osascript "$D/menu-mode.applescript"
  for k in _HIHideMenuBar AppleMenuBarVisibleInFullscreen; do
    printf '%s=' "$k"
    /usr/bin/defaults read NSGlobalDomain "$k" 2>/dev/null || printf 'absent\n'
  done
  "$D/measure"
}
/usr/bin/osascript "$D/menu-mode.applescript" Always
/bin/sleep 1
sample ui-always
/usr/bin/defaults write NSGlobalDomain AppleMenuBarVisibleInFullscreen -bool false
/usr/bin/defaults write NSGlobalDomain _HIHideMenuBar -bool false
sample direct-false-false-first-sample
/bin/sleep 5
sample direct-after-5-second-wait
/bin/sleep 10
sample direct-after-10-more-second-wait
/usr/bin/osascript -e 'tell application "System Settings" to quit'
/usr/bin/open 'x-apple.systempreferences:com.apple.ControlCenter-Settings.extension'
/bin/sleep 2
sample direct-after-settings-relaunch
/usr/bin/osascript "$D/menu-mode.applescript" Always
/bin/sleep 1
sample ui-always-again
/usr/bin/osascript "$D/menu-mode.applescript" 'In Full Screen Only'
/bin/sleep 1
sample ui-fullscreen-only-again
