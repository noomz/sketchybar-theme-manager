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
  /usr/bin/osascript -e 'tell application "System Settings" to activate' >/dev/null
  /usr/bin/osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || :
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
check_run() {
  label=$1
  desktop=$2
  fullscreen=$3
  printf '\ncase=%s\n' "$label"
  /usr/bin/osascript "$D/menu-mode.applescript"
  for k in _HIHideMenuBar AppleMenuBarVisibleInFullscreen; do
    printf '%s=' "$k"
    /usr/bin/defaults read NSGlobalDomain "$k" 2>/dev/null || printf 'absent\n'
  done
  "$D/fullscreen" >"$D/fullscreen-$label.jsonl"
  /bin/cat "$D/fullscreen-$label.jsonl"
  for phase in desktop-before desktop-after; do
    /usr/bin/grep '"phase":"'"$phase"'"' "$D/fullscreen-$label.jsonl" | /usr/bin/grep -q '"menuVisible":'"$desktop"
  done
  /usr/bin/grep '"phase":"fullscreen"' "$D/fullscreen-$label.jsonl" | /usr/bin/grep -q '"menuVisible":'"$fullscreen"
  /usr/bin/grep '"phase":"fullscreen"' "$D/fullscreen-$label.jsonl" | /usr/bin/grep -q '"fullScreen":true'
  printf 'case_pass=%s\n' "$label"
}
set_ui() {
  /usr/bin/osascript -e 'tell application "System Settings" to activate' >/dev/null
  /usr/bin/osascript "$D/menu-mode.applescript" "$1"
  /bin/sleep 1
}
set_ui Always
check_run always false false
set_ui 'On Desktop Only'
check_run desktop-only false true
set_ui Never
check_run never true true
set_ui 'In Full Screen Only'
check_run fullscreen-only true false
set_ui Never
/usr/bin/defaults write NSGlobalDomain AppleMenuBarVisibleInFullscreen -bool false
/usr/bin/defaults write NSGlobalDomain _HIHideMenuBar -bool false
check_run direct-fullscreen-only true false
