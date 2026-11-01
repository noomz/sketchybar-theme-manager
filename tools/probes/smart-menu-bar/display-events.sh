#!/bin/sh
set -eu
case "$(/usr/sbin/sysctl -n hw.model)" in
  VirtualMac*) ;;
  *) printf '%s\n' 'Refusing display probe outside VirtualMac' >&2; exit 1 ;;
esac
SB=/opt/homebrew/bin/sketchybar
OBSERVER=${1:?Provide compiled geometry.swift observer}
DESKPAD=${2:?Provide disposable DeskPad executable}
FOCUS=${3:?Provide compiled focus.swift helper}
REARRANGE=${4:?Provide compiled rearrange.swift helper}
[ -x "$SB" ] && [ -x "$OBSERVER" ] && [ -x "$DESKPAD" ] && [ -x "$FOCUS" ] && [ -x "$REARRANGE" ] || exit 1
if /usr/bin/pgrep -x sketchybar >/dev/null || /usr/bin/pgrep -x DeskPad >/dev/null; then
  printf '%s\n' 'Refusing to replace an existing probe application' >&2
  exit 1
fi
D=$(/usr/bin/mktemp -d /Users/admin/stm-display-events.XXXXXX)
printf 'probe_dir=%s\n' "$D"
pid=
deskpid=
cleanup() {
  rc=$?
  trap - EXIT HUP INT TERM
  if [ -f "$D/topology.json" ]; then
    if ! "$REARRANGE" restore "$D/topology.json"; then
      printf 'Topology recovery failed; inspect %s before further display changes\n' "$D/topology.json" >&2
      rc=1
      # Keep DeskPad alive so the saved display still exists for recovery.
      deskpid=
    fi
  fi
  if [ -n "$deskpid" ]; then
    kill "$deskpid" 2>/dev/null || :
    wait "$deskpid" 2>/dev/null || :
  fi
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
cat > "$D/events.sh" <<'SH'
#!/bin/sh
printf 'sender=%s info=%s\n' "${SENDER-}" "${INFO-}" >> "$(dirname "$0")/events.log"
SH
chmod +x "$D/events.sh"
cat > "$D/rc" <<'SH'
#!/bin/sh
SB=/opt/homebrew/bin/sketchybar
D=$(dirname "$0")
"$SB" --bar height=34 position=top y_offset=30 display=all \
  --add item stm.events left \
  --set stm.events label=probe updates=on script="$D/events.sh" \
  --subscribe stm.events display_change system_woke
SH
chmod +x "$D/rc"
"$SB" -c "$D/rc" > "$D/server.log" 2>&1 &
pid=$!
sleep 2
sample() {
  printf '\ncase=%s\n' "$1"
  "$SB" --query displays
  "$SB" --query stm.events
  "$OBSERVER" --all
  printf '%s\n' events_begin
  [ ! -f "$D/events.log" ] || cat "$D/events.log"
  printf '%s\n' events_end
}
sample before_add
"$DESKPAD" > "$D/deskpad.log" 2>&1 &
deskpid=$!
sleep 5
sample after_add
"$REARRANGE" snapshot "$D/topology.json"
events_before=$(grep -c '^sender=display_change ' "$D/events.log" || :)
"$REARRANGE" move "$D/topology.json"
sample after_rearrange
events_after=$(grep -c '^sender=display_change ' "$D/events.log" || :)
[ "$events_after" -gt "$events_before" ] || { printf '%s\n' 'No display_change event after rearrangement' >&2; exit 1; }
printf 'rearrange_events=%s\n' "$((events_after - events_before))"
"$REARRANGE" restore "$D/topology.json"
sample after_restore
events_restored=$(grep -c '^sender=display_change ' "$D/events.log" || :)
[ "$events_restored" -gt "$events_after" ] || { printf '%s\n' 'No display_change event after restoration' >&2; exit 1; }
printf 'restore_events=%s\n' "$((events_restored - events_after))"
# Restoration was verified before removing the recovery snapshot from the trap.
mv "$D/topology.json" "$D/topology-restored.json"
"$SB" --bar y_offset=0
sleep 1
sample all_zero
"$SB" --bar y_offset=30
sleep 1
sample all_thirty
printf '%s\n' focus_begin
"$FOCUS"
sleep 1
printf '%s\n' focus_end
sample after_focus
"$SB" --bar display=main
sleep 1
sample target_main
"$SB" --bar display=2
sleep 1
sample target_secondary
"$SB" --bar y_offset=0
sleep 1
sample secondary_zero
"$SB" --bar y_offset=30
sleep 1
sample secondary_thirty
"$SB" --bar display=all
sleep 1
sample target_all
kill "$deskpid"
wait "$deskpid" 2>/dev/null || :
deskpid=
sleep 3
sample after_remove
"$DESKPAD" >> "$D/deskpad.log" 2>&1 &
deskpid=$!
sleep 5
sample after_reconnect
kill "$deskpid"
wait "$deskpid" 2>/dev/null || :
deskpid=
sleep 3
sample after_final_remove
printf '%s\n' server_log_begin
cat "$D/server.log"
printf '%s\n' server_log_end
printf '%s\n' deskpad_log_begin
cat "$D/deskpad.log"
printf '%s\n' deskpad_log_end
