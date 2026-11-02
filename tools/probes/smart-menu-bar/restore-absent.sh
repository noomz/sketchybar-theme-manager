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
restore_keys() {
  result=0
  for k in _HIHideMenuBar AppleMenuBarVisibleInFullscreen; do
    /usr/bin/defaults delete NSGlobalDomain "$k" >/dev/null 2>&1 || :
    if /usr/bin/defaults read NSGlobalDomain "$k" >/dev/null 2>&1; then result=1; fi
  done
  return "$result"
}
finish() {
  status=$?
  trap - EXIT HUP INT TERM
  if ! restore_keys; then status=1; fi
  exit "$status"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
printf 'direct-desktop-only\n'
/usr/bin/defaults write NSGlobalDomain AppleMenuBarVisibleInFullscreen -bool true
/usr/bin/defaults write NSGlobalDomain _HIHideMenuBar -bool true
for k in _HIHideMenuBar AppleMenuBarVisibleInFullscreen; do
  /usr/bin/defaults read-type NSGlobalDomain "$k"
done
"$D/fullscreen" >"$D/restore-before.jsonl"
/bin/cat "$D/restore-before.jsonl"
/usr/bin/grep '"phase":"desktop-before"' "$D/restore-before.jsonl" | /usr/bin/grep -q '"menuVisible":false'
/usr/bin/grep '"phase":"fullscreen"' "$D/restore-before.jsonl" | /usr/bin/grep -q '"menuVisible":true'
printf 'delete-to-original-absent\n'
restore_keys
"$D/fullscreen" >"$D/restore-after.jsonl"
/bin/cat "$D/restore-after.jsonl"
/usr/bin/grep '"phase":"desktop-before"' "$D/restore-after.jsonl" | /usr/bin/grep -q '"menuVisible":true'
/usr/bin/grep '"phase":"fullscreen"' "$D/restore-after.jsonl" | /usr/bin/grep -q '"menuVisible":false'
/usr/bin/grep '"phase":"desktop-after"' "$D/restore-after.jsonl" | /usr/bin/grep -q '"menuVisible":true'
printf 'restore_absence_pass=1\n'
