#!/bin/sh
set -eu
case "$(/usr/sbin/sysctl -n hw.model)" in
  VirtualMac*) ;;
  *) printf '%s\n' 'Refusing placement probe outside VirtualMac' >&2; exit 1 ;;
esac
SB=/opt/homebrew/bin/sketchybar
OBSERVER=${1:?Provide compiled geometry.swift observer}
CLICK=${2:?Provide compiled click.swift helper}
[ -x "$SB" ] && [ -x "$OBSERVER" ] && [ -x "$CLICK" ] || exit 1
if /usr/bin/pgrep -x sketchybar >/dev/null; then
  printf '%s\n' 'Refusing to replace an existing SketchyBar instance' >&2
  exit 1
fi
D=$(/usr/bin/mktemp -d /Users/admin/stm-placement.XXXXXX)
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
cat > "$D/click.sh" <<'SH'
#!/bin/sh
printf '%s\n' click >> "$(dirname "$0")/clicks.log"
SH
chmod +x "$D/click.sh"
cat > "$D/rc" <<'SH'
#!/bin/sh
SB=/opt/homebrew/bin/sketchybar
D=$(dirname "$0")
"$SB" --bar height=34 position=top y_offset=0 notch_offset=0 display=all \
  --add item stm.placement left \
  --set stm.placement label=probe click_script="$D/click.sh"
SH
chmod +x "$D/rc"
"$SB" -c "$D/rc" > "$D/server.log" 2>&1 &
pid=$!
sleep 2
sample() {
  printf '\ncase=%s\n' "$1"
  "$SB" --query bar
  "$SB" --query stm.placement
  "$OBSERVER" --all
}
click() {
  before=0
  if [ -f "$D/clicks.log" ]; then before=$(wc -l < "$D/clicks.log" | tr -d ' '); fi
  if "$CLICK"; then
    sleep 1
    after=0
    if [ -f "$D/clicks.log" ]; then after=$(wc -l < "$D/clicks.log" | tr -d ' '); fi
    printf 'click_deliveries=%s\n' "$((after - before))"
  else
    printf '%s\n' 'click_unverified=helper_failed'
    return 1
  fi
}
resize() {
  "$SB" --bar y_offset=1
  "$SB" --bar y_offset=0
  sleep 1
}
sample initial_off
click
"$SB" --bar topmost=on
sleep 1
sample on_before_resize
resize
sample on_after_resize
"$SB" --bar y_offset=30
sleep 1
sample on_y_30
click
"$SB" --bar y_offset=0
"$SB" --bar topmost=off
sleep 1
sample off_before_resize
resize
sample off_after_resize
click
printf '%s\n' server_log_begin
cat "$D/server.log"
printf '%s\n' server_log_end
