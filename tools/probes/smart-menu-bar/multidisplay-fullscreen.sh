#!/bin/sh
set -eu
LC_ALL=C
export LC_ALL
case "$(/usr/sbin/sysctl -n hw.model)" in
  VirtualMac*) ;;
  *) printf '%s\n' 'Refusing fullscreen probe outside VirtualMac' >&2; exit 1 ;;
esac
D=${1:?Provide fresh guest scratch directory}
DESKPAD=${2:?Provide disposable DeskPad executable}
SB=/opt/homebrew/bin/sketchybar
[ -x "$D/bar-fullscreen" ] && [ -x "$D/geometry" ] && [ -x "$DESKPAD" ] && [ -x "$SB" ] || exit 1
if /usr/bin/pgrep -x sketchybar >/dev/null || /usr/bin/pgrep -x DeskPad >/dev/null; then
  printf '%s\n' 'Refusing to replace an existing probe application' >&2
  exit 1
fi
for key in _HIHideMenuBar AppleMenuBarVisibleInFullscreen; do
  [ ! -e "$D/$key.before-error" ] || exit 1
  if /usr/bin/defaults read NSGlobalDomain "$key" >"$D/$key.before-value" 2>"$D/$key.before-error"; then
    printf 'Refusing untested present-key baseline: %s\n' "$key" >&2
    exit 1
  fi
  grep -F "Could not find key '$key'" "$D/$key.before-error" >/dev/null || exit 1
done
pid=
deskpid=
cleanup() {
  rc=$?
  trap - EXIT HUP INT TERM
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
  fi
  if [ -n "$deskpid" ]; then
    kill "$deskpid" 2>/dev/null || :
    wait "$deskpid" 2>/dev/null || :
  fi
  for key in _HIHideMenuBar AppleMenuBarVisibleInFullscreen; do
    if /usr/bin/defaults read NSGlobalDomain "$key" >"$D/$key.after-value" 2>"$D/$key.after-error"; then
      printf 'Preference baseline changed externally: %s\n' "$key" >&2
      rc=1
    elif ! grep -F "Could not find key '$key'" "$D/$key.after-error" >/dev/null; then
      rc=1
    fi
  done
  "$D/geometry" --all || rc=1
  printf 'cleanup_result=%s\n' "$rc"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'probe_dir=%s\n' "$D"
/usr/bin/sw_vers
"$D/geometry" --all
"$DESKPAD" >"$D/deskpad.log" 2>&1 &
deskpid=$!
sleep 5
cat >"$D/rc" <<'SH'
#!/bin/sh
/opt/homebrew/bin/sketchybar --bar height=34 position=top y_offset=30 notch_offset=0 \
  display=all topmost=off sticky=on show_in_fullscreen=off \
  --add item stm.transitions left --set stm.transitions label=probe
SH
chmod +x "$D/rc"
"$SB" -c "$D/rc" >"$D/server.log" 2>&1 &
pid=$!
sleep 2
"$SB" --query displays
for topmost in off on; do
  "$SB" --bar topmost="$topmost" y_offset=31
  "$SB" --bar y_offset=30
  for shown in off on; do
    "$SB" --bar show_in_fullscreen="$shown"
    sleep 1
    for screen in primary secondary; do
      label="$topmost-$shown-$screen"
      printf '\ncase=%s\n' "$label"
      if ! "$D/bar-fullscreen" "$screen" >"$D/fullscreen-$label.log" 2>&1; then
        cat "$D/fullscreen-$label.log"
        exit 1
      fi
      cat "$D/fullscreen-$label.log"
      grep '"phase":"desktop-before"' "$D/fullscreen-$label.log" | grep -q '"menuVisible":true'
      grep '"phase":"fullscreen"' "$D/fullscreen-$label.log" | grep -q '"menuVisible":false'
      grep '"phase":"desktop-after"' "$D/fullscreen-$label.log" | grep -q '"menuVisible":true'
      grep -q 'focus_restore_verified=true' "$D/fullscreen-$label.log"
      printf 'case_pass=%s\n' "$label"
    done
  done
done
kill "$deskpid"
wait "$deskpid" 2>/dev/null || :
deskpid=
sleep 3
for shown in off on; do
  "$SB" --bar show_in_fullscreen="$shown"
  sleep 1
  printf '\ncase=single-display-%s\n' "$shown"
  if ! "$D/bar-fullscreen" >"$D/single-$shown.log" 2>&1; then
    cat "$D/single-$shown.log"
    exit 1
  fi
  cat "$D/single-$shown.log"
  grep -q 'focus_restore_verified=true' "$D/single-$shown.log"
  printf 'case_pass=single-display-%s\n' "$shown"
done
printf '%s\n' server_log_begin
cat "$D/server.log"
printf '%s\n' server_log_end
