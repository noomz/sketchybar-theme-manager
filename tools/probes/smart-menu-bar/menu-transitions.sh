#!/bin/sh
set -eu
LC_ALL=C
export LC_ALL
case "$(/usr/sbin/sysctl -n hw.model)" in
  VirtualMac*) ;;
  *) printf '%s\n' 'Refusing preference probe outside VirtualMac' >&2; exit 1 ;;
esac
D=${1:?Provide fresh guest scratch directory}
SB=/opt/homebrew/bin/sketchybar
[ -x "$D/geometry" ] && [ -x "$D/bar-fullscreen" ] && [ -x "$SB" ] || exit 1
if /usr/bin/pgrep -x sketchybar >/dev/null; then
  printf '%s\n' 'Refusing to replace an existing SketchyBar instance' >&2
  exit 1
fi
/usr/bin/defaults read NSGlobalDomain >/dev/null
for key in _HIHideMenuBar AppleMenuBarVisibleInFullscreen; do
  [ ! -e "$D/$key.type" ] || exit 1
  if /usr/bin/defaults read NSGlobalDomain "$key" >"$D/$key.value" 2>"$D/$key.error"; then
    printf 'Refusing present-key baseline: %s\n' "$key" >&2
    exit 1
  fi
  grep -F "Could not find key '$key'" "$D/$key.error" >/dev/null || exit 1
  printf '%s\n' absent >"$D/$key.type"
done
printf 'snapshot=%s\n' "$D"
/usr/bin/sw_vers
pid=
restore_keys() {
  result=0
  for key in _HIHideMenuBar AppleMenuBarVisibleInFullscreen; do
    /usr/bin/defaults delete NSGlobalDomain "$key" >/dev/null 2>&1 || :
    if /usr/bin/defaults read NSGlobalDomain "$key" >"$D/$key.restore-value" 2>"$D/$key.restore-error"; then
      result=1
    elif ! grep -F "Could not find key '$key'" "$D/$key.restore-error" >/dev/null; then
      result=1
    fi
  done
  return "$result"
}
cleanup() {
  rc=$?
  trap - EXIT HUP INT TERM
  if ! restore_keys; then rc=1; fi
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
  fi
  "$D/geometry" || rc=1
  printf 'cleanup_result=%s\n' "$rc"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cat >"$D/event.sh" <<'SH'
#!/bin/sh
printf 'sender=%s info=%s\n' "${SENDER-}" "${INFO-}" >> "$(dirname "$0")/events.log"
SH
chmod +x "$D/event.sh"
cat >"$D/rc" <<'SH'
#!/bin/sh
SB=/opt/homebrew/bin/sketchybar
D=$(dirname "$0")
"$SB" --bar height=34 position=top y_offset=0 notch_offset=0 display=all topmost=off \
  --add item stm.transitions left \
  --set stm.transitions label=probe updates=on script="$D/event.sh" \
  --subscribe stm.transitions display_change space_change system_woke
SH
chmod +x "$D/rc"
"$SB" -c "$D/rc" >"$D/server.log" 2>&1 &
pid=$!
sleep 2
sample() {
  printf '\ncase=%s\n' "$1"
  "$SB" --query bar
  "$SB" --query stm.transitions
  "$D/geometry" --all
}
set_mode() {
  case "$1" in
    always) desktop=true; fullscreen=false ;;
    desktop-only) desktop=true; fullscreen=true ;;
    never) desktop=false; fullscreen=true ;;
    fullscreen-only) desktop=false; fullscreen=false ;;
    *) exit 1 ;;
  esac
  /usr/bin/defaults write NSGlobalDomain AppleMenuBarVisibleInFullscreen -bool "$fullscreen"
  /usr/bin/defaults write NSGlobalDomain _HIHideMenuBar -bool "$desktop"
  sleep 2
}
for topmost in off on; do
  "$SB" --bar topmost="$topmost" y_offset=1
  "$SB" --bar y_offset=0
  sleep 1
  for mode in always never fullscreen-only desktop-only; do
    set_mode "$mode"
    sample "$topmost-$mode-before-resize"
    "$SB" --bar y_offset=1
    "$SB" --bar y_offset=0
    sleep 1
    sample "$topmost-$mode-after-resize"
    if [ "$topmost" = on ]; then "$SB" --bar y_offset=30; fi
    "$D/bar-fullscreen" >"$D/fullscreen-$topmost-$mode.log"
    cat "$D/fullscreen-$topmost-$mode.log"
    case "$mode" in
      always) desktop_visible=false; fullscreen_visible=false ;;
      desktop-only) desktop_visible=false; fullscreen_visible=true ;;
      never) desktop_visible=true; fullscreen_visible=true ;;
      fullscreen-only) desktop_visible=true; fullscreen_visible=false ;;
    esac
    for phase in desktop-before desktop-after; do
      grep '"phase":"'"$phase"'"' "$D/fullscreen-$topmost-$mode.log" | grep -q '"menuVisible":'"$desktop_visible"
    done
    grep '"phase":"fullscreen"' "$D/fullscreen-$topmost-$mode.log" | grep -q '"menuVisible":'"$fullscreen_visible"
    grep '"phase":"fullscreen"' "$D/fullscreen-$topmost-$mode.log" | grep -q '"fullScreen":true'
    grep -q 'focus_restore_verified=true' "$D/fullscreen-$topmost-$mode.log"
    printf 'case_pass=%s-%s\n' "$topmost" "$mode"
    "$SB" --bar y_offset=0
  done
done
set_mode fullscreen-only
"$SB" --bar show_in_fullscreen=on
for topmost in off on; do
  "$SB" --bar topmost="$topmost" y_offset=1
  if [ "$topmost" = on ]; then offset=30; else offset=0; fi
  "$SB" --bar y_offset="$offset"
  sleep 1
  printf '\ncase=fullscreen-enabled-%s\n' "$topmost"
  "$D/bar-fullscreen" >"$D/fullscreen-enabled-$topmost.log"
  cat "$D/fullscreen-enabled-$topmost.log"
  for phase in desktop-before desktop-after; do
    grep '"phase":"'"$phase"'"' "$D/fullscreen-enabled-$topmost.log" | grep -q '"menuVisible":true'
  done
  grep '"phase":"fullscreen"' "$D/fullscreen-enabled-$topmost.log" | grep -q '"menuVisible":false'
  grep -q 'focus_restore_verified=true' "$D/fullscreen-enabled-$topmost.log"
  printf 'case_pass=fullscreen-enabled-%s\n' "$topmost"
done
"$SB" --bar show_in_fullscreen=off
restore_keys
sleep 2
"$SB" --bar topmost=off y_offset=1
"$SB" --bar y_offset=0
"$D/bar-fullscreen" >"$D/fullscreen-restored.log"
cat "$D/fullscreen-restored.log"
for phase in desktop-before desktop-after; do
  grep '"phase":"'"$phase"'"' "$D/fullscreen-restored.log" | grep -q '"menuVisible":true'
done
grep '"phase":"fullscreen"' "$D/fullscreen-restored.log" | grep -q '"menuVisible":false'
grep '"phase":"fullscreen"' "$D/fullscreen-restored.log" | grep -q '"fullScreen":true'
grep -q 'focus_restore_verified=true' "$D/fullscreen-restored.log"
printf '%s\n' restore_behavior_pass=1 events_begin
cat "$D/events.log"
printf '%s\n' events_end server_log_begin
cat "$D/server.log"
printf '%s\n' server_log_end
