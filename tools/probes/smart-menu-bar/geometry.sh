#!/bin/sh
set -eu

case "$(/usr/sbin/sysctl -n hw.model)" in
  VirtualMac*) ;;
  *) printf '%s\n' 'Refusing geometry probe outside VirtualMac' >&2; exit 1 ;;
esac
SB=/opt/homebrew/bin/sketchybar
[ -x "$SB" ] || exit 1
if /usr/bin/pgrep -x sketchybar >/dev/null; then
  printf '%s\n' 'Refusing to replace an existing SketchyBar instance' >&2
  exit 1
fi
OBSERVER=${1:?Provide compiled geometry.swift observer}
[ -x "$OBSERVER" ] || exit 1
D=$(/usr/bin/mktemp -d /Users/admin/stm-geometry.XXXXXX)
printf 'probe_dir=%s\n' "$D"
pid=
cleanup() {
  rc=$?
  trap - EXIT HUP INT TERM
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$D/event.sh" <<'SH'
#!/bin/sh
printf 'sender=%s info=%s\n' "${SENDER-}" "${INFO-}" >> "$(dirname "$0")/events.log"
SH
chmod +x "$D/event.sh"
cat > "$D/rc" <<'SH'
#!/bin/sh
SB=/opt/homebrew/bin/sketchybar
D=$(dirname "$0")
printf '%s\n' config_load >> "$D/events.log"
"$SB" --bar height=34 position=top y_offset=0 notch_offset=0 display=all \
  --add item stm.geometry left \
  --set stm.geometry label=probe updates=on script="$D/event.sh" \
  --subscribe stm.geometry display_change system_woke
SH
chmod +x "$D/rc"
"$SB" -c "$D/rc" > "$D/server.log" 2>&1 &
pid=$!
sleep 2
sample() {
  printf '\ncase=%s\n' "$1"
  "$SB" --query bar
  "$SB" --query displays
  "$SB" --query stm.geometry
  "$OBSERVER"
  printf '%s\n' events_begin
  [ ! -f "$D/events.log" ] || cat "$D/events.log"
  printf '%s\n' events_end
}
sample top_zero
"$SB" --bar topmost=on
sleep 1
sample topmost_on
"$SB" --bar topmost=off
sleep 1
sample topmost_off
for value in 28 30; do
  "$SB" --bar y_offset="$value"
  sleep 1
  sample "top_y_$value"
done
"$SB" --bar y_offset=0 notch_offset=30
sleep 1
sample top_notch_30
"$SB" --bar notch_offset=0 position=bottom y_offset=30
sleep 1
sample bottom_y_30
"$SB" --bar position=top y_offset=0 display=main
sleep 1
sample target_main
"$SB" --bar display=1
sleep 1
sample target_1
"$SB" --bar display=all
sleep 1
sample target_all
"$SB" --reload
sleep 2
sample reload
printf '%s\n' server_log_begin
cat "$D/server.log"
printf '%s\n' server_log_end
