#!/bin/sh
# T7 guest-only end-to-end check of `stm menubar` and item:menubar against
# real macOS preferences, a real SketchyBar, real display events (DeskPad) and
# real native fullscreen. Only the notch observation is synthetic (see
# t7-osascript.sh); a physical-notch run belongs to the host test.
#
# Usage (in the guest): t7.sh <dir>
#   <dir>/stm       repo copy: bin/ bundles/ palettes/
#   <dir>/osascript t7-osascript.sh
#   <dir>/measure   compiled measure.swift
#   <dir>/fullscreen compiled fullscreen.swift
# Prints `assert_<name>=pass|fail` lines and exits nonzero on any failure or
# when cleanup cannot restore the original (absent) preferences.
set -u
case "$(/usr/sbin/sysctl -n hw.model 2>/dev/null)" in
  VirtualMac*) ;;
  *) printf '%s\n' 'Refusing T7 probe outside a VirtualMac guest' >&2; exit 1 ;;
esac

D=${1:?probe dir}
SB=/opt/homebrew/bin/sketchybar
DESKPAD=/Users/admin/stm-deskpad.NGlula/DeskPad.app/Contents/MacOS/DeskPad
S=$HOME/.local/state/stm
KEYS="_HIHideMenuBar AppleMenuBarVisibleInFullscreen"
FAILS=0
pid=""
deskpid=""

for f in "$D/stm/bin/stm" "$D/osascript" "$D/measure" "$D/fullscreen" "$SB" "$DESKPAD"; do
  [ -x "$f" ] || { printf 'missing %s\n' "$f" >&2; exit 1; }
done
if /usr/bin/pgrep -x sketchybar >/dev/null || /usr/bin/pgrep -x DeskPad >/dev/null; then
  printf '%s\n' 'Refusing: sketchybar or DeskPad already running' >&2
  exit 1
fi
for k in $KEYS; do
  if /usr/bin/defaults read -g "$k" >/dev/null 2>&1; then
    printf 'Refusing: %s is set; this probe restores only an absent baseline\n' "$k" >&2
    exit 1
  fi
done
[ ! -e "$S" ] || { printf 'Refusing: %s exists\n' "$S" >&2; exit 1; }

# XDG_CONFIG_HOME keeps the item ledger ($XDG_CONFIG_HOME/stm/items) inside
# the probe dir, away from the guest's own configs. The menu-bar state stays
# at its real per-user path on purpose.
# stm and the hook call `sketchybar` by name, as under the brew service
# (whose PATH starts with the Homebrew prefix); the guest has a stale
# /usr/local/bin/sketchybar symlink.
PATH="/opt/homebrew/bin:$PATH"
export PATH T7_DIR="$D" STM_ROOT="$D/stm" STM_OSASCRIPT="$D/osascript" XDG_CONFIG_HOME="$D/xdg"

cleanup() {
  rc=$?
  trap - EXIT HUP INT TERM
  [ -z "$deskpid" ] || { kill "$deskpid" 2>/dev/null; wait "$deskpid" 2>/dev/null; }
  [ -z "$pid" ] || { kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }
  result=0
  for k in $KEYS; do
    /usr/bin/defaults delete -g "$k" >/dev/null 2>&1
    if /usr/bin/defaults read -g "$k" >/dev/null 2>&1; then result=1; fi
  done
  /bin/rm -rf "$S"
  [ ! -e "$S" ] || result=1
  printf '\ncase=cleanup\n'
  "$D/measure"
  printf 'restore_result=%s\nfails=%s\n' "$result" "$FAILS"
  [ "$result" -eq 0 ] && [ "$FAILS" -eq 0 ] && [ "$rc" -eq 0 ] || exit 1
  exit 0
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# --- helpers ---------------------------------------------------------------

ck() {
  name=$1
  shift
  if "$@"; then
    printf 'assert_%s=pass\n' "$name"
  else
    printf 'assert_%s=fail\n' "$name"
    FAILS=$((FAILS + 1))
  fi
}
eq() { [ "$1" = "$2" ] || { printf '  want %s, got %s\n' "$2" "$1"; return 1; }; }
pref() {
  t=$(/usr/bin/defaults read-type -g "$1" 2>/dev/null) || { echo absent; return; }
  case "$t" in "Type is boolean") ;; *) echo "other:$t"; return ;; esac
  case "$(/usr/bin/defaults read -g "$1")" in 1) echo bool:true ;; 0) echo bool:false ;; *) echo other ;; esac
}
yoff() { "$SB" --query bar | /usr/bin/awk -F: '/"y_offset"/ { gsub(/[ ,]/, "", $2); print $2; exit }'; }
# Top edge of the probe item on the primary display, in points below its top.
ptop() {
  "$SB" --query t7.probe | /usr/bin/awk '
    /"display-1"/ { on = 1 }
    on && /"origin"/ { s = $0; sub(/^[^[]*\[/, "", s); split(s, a, ","); printf("%.0f\n", a[2]); exit }'
}
sget() { /usr/bin/awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$S/menubar.state" 2>/dev/null; }
nostate() { [ ! -e "$S/menubar.state" ]; }
# clear_all <n> — stm status lists n targets and on each one the bar starts
# at or below the native-menu clearance (V2, V12, V14).
clear_all() {
  "$D/stm/bin/stm" --dir "$D/sb" menubar status --porcelain | /usr/bin/awk -F'\t' -v want="$1" '
    $1 ~ /^target\.[0-9]+\.clearance$/ { split($1, k, "."); c[k[2]] = $2 }
    $1 ~ /^target\.[0-9]+\.bar_top$/ { split($1, k, "."); t[k[2]] = $2 }
    END {
      for (d in c) { n++; if (c[d] == "-" || t[d] == "-" || t[d] + 0 < c[d] + 0) bad = 1 }
      exit (bad || n != want)
    }'
}
menu_visible() { "$D/measure" | /usr/bin/grep -q "\"menuVisible\":$1"; }
cfg() {
  case "$1" in
    none) /bin/rm -f "$D/sb/stm.config.toml" ;;
    *) printf '[menu_bar]\nsmart_notch = "%s"\n' "$1" >"$D/sb/stm.config.toml" ;;
  esac
}
notch() { printf '%s\n' "$1" >"$D/notch"; }
stm() { "$D/stm/bin/stm" --dir "$D/sb" "$@"; }
hooks() { /usr/bin/awk '/^end / { n++ } END { print n + 0 }' "$D/hook.log"; }
# Wait until no stm run is active and the hook count stopped moving.
idle() {
  n=0
  last=x
  while [ "$n" -lt 60 ]; do
    /bin/sleep 0.5
    cur=$(hooks)
    if ! /usr/bin/pgrep -f "$D/stm-hook" >/dev/null && [ ! -e "$S/menubar.lock" ] && [ "$cur" = "$last" ]; then
      return 0
    fi
    last=$cur
    n=$((n + 1))
  done
  printf '  idle timeout\n'
  return 1
}
# Wait for at least $1 more finished hook runs than now, then for idle.
hook_wait() {
  want=$(($(hooks) + $1))
  n=0
  while [ "$(hooks)" -lt "$want" ] && [ "$n" -lt 60 ]; do /bin/sleep 0.5; n=$((n + 1)); done
  [ "$(hooks)" -ge "$want" ] || printf '  hook wait timeout (want %s, have %s)\n' "$want" "$(hooks)"
  idle
}
start_bar() {
  "$SB" -c "$D/sb/sketchybarrc" >>"$D/server.log" 2>&1 &
  pid=$!
}
stop_bar() {
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  pid=""
}
reload() { "$SB" --reload; }
snap() {
  printf '\ncase=%s\n' "$1"
  for k in $KEYS; do printf '%s=%s\n' "$k" "$(pref "$k")"; done
  printf 'y_offset=%s probe_top=%s hooks=%s\n' "$(yoff)" "$(ptop)" "$(hooks)"
  printf 'state_begin\n'
  /bin/cat "$S/menubar.state" 2>/dev/null || printf 'none\n'
  printf 'state_end\nstatus_begin\n'
  stm menubar status 2>&1
  printf 'status_end\n'
  "$D/measure"
}

# --- config ----------------------------------------------------------------

/bin/rm -rf "$D/sb" "$D/xdg" "$D/server.log" "$D/state.s5"
mkdir -p "$D/sb"
cat >"$D/sb/sketchybarrc" <<'LUA'
#!/opt/homebrew/opt/lua@5.4/bin/lua
local home = os.getenv("HOME")
local config = os.getenv("CONFIG_DIR")
package.cpath = package.cpath .. ";" .. home .. "/.local/share/sketchybar_lua/?.so"
package.path = config .. "/?.lua;" .. package.path
sbar = require("sketchybar")
sbar.begin_config()
require("init")
sbar.end_config()
sbar.event_loop()
LUA
chmod 755 "$D/sb/sketchybarrc"
cat >"$D/sb/colors.lua" <<'LUA'
return { bar_bg = 0xff202020, bar_border = 0xff404040, bg1 = 0xff303030 }
LUA
cat >"$D/sb/init.lua" <<'LUA'
local colors = require("colors")
sbar.bar({ height = 34, position = "top", y_offset = 0, notch_offset = 0,
  display = "all", topmost = "off", color = colors.bar_bg })
sbar.add("item", "t7.probe", { position = "left", label = { string = "t7 probe" } })
require("items_generated")
LUA
# The hook runs stm through this logger so every event and its result is
# recorded. The real plugin finds it through STM_BIN.
cat >"$D/stm-hook" <<SH
#!/bin/sh
printf 'begin sender=%s argv=%s\n' "\${SENDER-}" "\$*" >>"$D/hook.log"
"$D/stm/bin/stm" "\$@" >>"$D/hook.log" 2>&1
printf 'end rc=%s\n' "\$?" >>"$D/hook.log"
SH
chmod 755 "$D/stm-hook"
export STM_BIN="$D/stm-hook"
: >"$D/hook.log"
notch off
cfg none

printf 'probe_dir=%s\n' "$D"
/usr/bin/sw_vers
"$SB" --version

printf '\ncase=install\n'
stm --no-reload install item:menubar
ck install_hook [ -x "$D/sb/plugins/stm/menubar.sh" ]

# --- S1 off: zero writes (V1) ------------------------------------------------
start_bar
hook_wait 1
snap s1-off
ck s1_prefs_absent eq "$(pref _HIHideMenuBar) $(pref AppleMenuBarVisibleInFullscreen)" "absent absent"
ck s1_no_state nostate
ck s1_yoff eq "$(yoff)" 0
ck s1_hook_ran /usr/bin/grep -q '^begin sender=forced' "$D/hook.log"
ck s1_status_hook_loaded sh -c "'$D/stm/bin/stm' --dir '$D/sb' menubar status --porcelain | /usr/bin/grep -q '^hook.loaded$'"
BASE_TOP=$(ptop)
printf 'base_probe_top=%s\n' "$BASE_TOP"

# --- S2 on, real (no notch) geometry: nothing to do (V3) -------------------------
cfg on
reload
hook_wait 1
snap s2-on-no-notch
ck s2_prefs_absent eq "$(pref _HIHideMenuBar) $(pref AppleMenuBarVisibleInFullscreen)" "absent absent"
ck s2_no_state nostate
ck s2_yoff eq "$(yoff)" 0
ck s2_says_no_notch sh -c "'$D/stm/bin/stm' --dir '$D/sb' menubar status 2>&1 | /usr/bin/grep -q 'confirmed-no-notch'"

# --- S3 on, notched primary: apply and verify (V2, V5) --------------------------
notch on
reload
hook_wait 1
snap s3-apply
ck s3_prefs_false eq "$(pref _HIHideMenuBar) $(pref AppleMenuBarVisibleInFullscreen)" "bool:false bool:false"
ck s3_phase_active eq "$(sget phase)" active
ck s3_originals_absent eq "$(sget pref._HIHideMenuBar.original) $(sget pref.AppleMenuBarVisibleInFullscreen.original)" "absent absent"
ck s3_bar_below_notch [ "$(ptop)" -ge 32 ]
ck s3_clear clear_all 1
ck s3_offset_owned eq "$(sget bar.y_offset.owner)" applied
ck s3_menu_visible menu_visible true
Y1=$(yoff)
printf 'y1=%s\n' "$Y1"

# --- S4 repeated events do not compound (V5, V7) --------------------------------
stm menubar refresh
stm menubar refresh
"$SB" --trigger system_woke
"$SB" --trigger display_change
idle
# a burst of hook runs at once must converge
burst=""
for _ in 1 2 3 4 5; do
  STM_CONFIG_DIR="$D/sb" SENDER=burst sh "$D/sb/plugins/stm/menubar.sh" &
  burst="$burst $!"
done
# Not a bare `wait`: that would also wait for the bar.
# shellcheck disable=SC2086  # PID list
wait $burst
idle
snap s4-repeat
ck s4_yoff_same eq "$(yoff)" "$Y1"
ck s4_originals_kept eq "$(sget pref._HIHideMenuBar.original) $(sget bar.y_offset.original)" "absent 0"
ck s4_no_lock_left [ ! -e "$S/menubar.lock" ]
ck s4_no_dirty_left [ ! -e "$S/menubar.dirty" ]

# --- S5 dry run writes nothing (V11) --------------------------------------------
# Baseline right before the dry runs: every real refresh bumps generation.
cp "$S/menubar.state" "$D/state.s5"
cfg off
stm menubar refresh --dry-run
stm menubar restore --dry-run
ck s5_state_same cmp -s "$S/menubar.state" "$D/state.s5"
ck s5_prefs_same eq "$(pref _HIHideMenuBar) $(pref AppleMenuBarVisibleInFullscreen)" "bool:false bool:false"
ck s5_yoff_same eq "$(yoff)" "$Y1"
cfg on

# --- S6 bar restart: fresh process, same result (V5) ----------------------------
stop_bar
ck s6_prefs_survive eq "$(pref _HIHideMenuBar) $(pref AppleMenuBarVisibleInFullscreen)" "bool:false bool:false"
start_bar
hook_wait 1
snap s6-restart
ck s6_yoff_same eq "$(yoff)" "$Y1"
ck s6_originals_kept eq "$(sget pref._HIHideMenuBar.original) $(sget bar.y_offset.original)" "absent 0"
ck s6_bar_below_notch [ "$(ptop)" -ge 32 ]

# --- S7 native fullscreen: menu hidden there, desktop unchanged after -----------
before=$(hooks)
"$D/fullscreen" >"$D/fullscreen.jsonl"
/bin/cat "$D/fullscreen.jsonl"
idle
printf 'fullscreen_hook_runs=%s\n' "$(($(hooks) - before))"
snap s7-fullscreen
ck s7_desktop_menu /usr/bin/grep -q '"menuVisible":true.*"phase":"desktop-before"' "$D/fullscreen.jsonl"
ck s7_fullscreen_menu_hidden /usr/bin/grep -q '"fullScreen":true,"menuVisible":false.*"phase":"fullscreen"' "$D/fullscreen.jsonl"
ck s7_yoff_same eq "$(yoff)" "$Y1"
ck s7_phase_active eq "$(sget phase)" active

# --- S8 hotplug: second display, maximum clearance, then back (V12) -------------
before=$(hooks)
"$DESKPAD" >"$D/deskpad.log" 2>&1 &
deskpid=$!
hook_wait 1
snap s8-plugged
printf 'plug_hook_runs=%s\n' "$(($(hooks) - before))"
ck s8_two_targets sh -c "'$D/stm/bin/stm' --dir '$D/sb' menubar status --porcelain | /usr/bin/awk '/^target\.[0-9]+\t/ { n++ } END { exit n != 2 }'"
ck s8_yoff_not_lower [ "$(yoff)" -ge "$Y1" ]
# Every hosting display, the secondary included, starts below its menu (V2,
# V12, V14): bar_top >= clearance for each target.
ck s8_clear_every_display clear_all 2
ck s8_phase_active eq "$(sget phase)" active
Y2=$(yoff)
printf 'y2=%s\n' "$Y2"
before=$(hooks)
kill "$deskpid"
wait "$deskpid" 2>/dev/null
deskpid=""
hook_wait 1
snap s8-unplugged
printf 'unplug_hook_runs=%s\n' "$(($(hooks) - before))"
ck s8_yoff_back eq "$(yoff)" "$Y1"
ck s8_originals_kept eq "$(sget pref._HIHideMenuBar.original) $(sget bar.y_offset.original)" "absent 0"

# --- S9 user changes a preference after stm set it (V4) ------------------------
/usr/bin/defaults write -g _HIHideMenuBar -bool true
stm menubar refresh >"$D/s9.out" 2>&1
printf 's9_rc=%s\n' "$?"
/bin/cat "$D/s9.out"
reload
hook_wait 1
snap s9-conflict
ck s9_user_value_kept eq "$(pref _HIHideMenuBar)" bool:true
ck s9_conflict_reported /usr/bin/grep -q 'changed after stm set it' "$D/s9.out"
ck s9_phase_conflict eq "$(sget phase)" conflict
cfg off
stm menubar refresh
snap s9-disabled
ck s9_user_value_still eq "$(pref _HIHideMenuBar)" bool:true
ck s9_owned_restored eq "$(pref AppleMenuBarVisibleInFullscreen)" absent
ck s9_yoff_restored eq "$(yoff)" 0
ck s9_no_state nostate
/usr/bin/defaults delete -g _HIHideMenuBar

# --- S10 disable through the hook (V9) -----------------------------------------
cfg on
reload
hook_wait 1
ck s10_applied eq "$(sget phase)" active
cfg off
reload
hook_wait 1
snap s10-disabled
ck s10_prefs_absent eq "$(pref _HIHideMenuBar) $(pref AppleMenuBarVisibleInFullscreen)" "absent absent"
ck s10_yoff eq "$(yoff)" 0
ck s10_no_state nostate

# --- S11 restore command while config is still on (V9) --------------------------
cfg on
reload
hook_wait 1
ck s11_applied eq "$(sget phase)" active
stm menubar restore >"$D/s11.out" 2>&1
printf 's11_rc=%s\n' "$?"
/bin/cat "$D/s11.out"
snap s11-restored
ck s11_prefs_absent eq "$(pref _HIHideMenuBar) $(pref AppleMenuBarVisibleInFullscreen)" "absent absent"
ck s11_yoff eq "$(yoff)" 0
ck s11_no_state nostate
ck s11_warns_on /usr/bin/grep -qi 'next refresh' "$D/s11.out"
cfg off

# --- S12 stale lock is refused, never removed (design: lock) ---------------------
# Config on with the notch present, so refresh has writes to make and needs
# the lock; a run with nothing to write never takes it.
cfg on
mkdir -p "$S"
printf '99999\tThu Jan  1 00:00:00 1970\n' >"$S/menubar.lock"
stm menubar refresh >"$D/s12.out" 2>&1
s12rc=$?
/bin/cat "$D/s12.out"
stm menubar status >"$D/s12.status" 2>&1
/bin/cat "$D/s12.status"
ck s12_refused [ "$s12rc" -ne 0 ]
ck s12_names_lock /usr/bin/grep -q 'menubar.lock' "$D/s12.out"
ck s12_lock_kept [ -e "$S/menubar.lock" ]
ck s12_status_names_lock /usr/bin/grep -q 'menubar.lock' "$D/s12.status"
ck s12_no_write eq "$(pref _HIHideMenuBar) $(pref AppleMenuBarVisibleInFullscreen)" "absent absent"
/bin/rm -f "$S/menubar.lock"
cfg off

# --- S13 baseline Always: restore puts true back --------------------------------
/usr/bin/defaults write -g _HIHideMenuBar -bool true
cfg on
stop_bar
start_bar
hook_wait 1
snap s13-apply
ck s13_original_true eq "$(sget pref._HIHideMenuBar.original)" bool:true
ck s13_prefs_false eq "$(pref _HIHideMenuBar) $(pref AppleMenuBarVisibleInFullscreen)" "bool:false bool:false"
ck s13_menu_visible menu_visible true
ck s13_bar_below_notch [ "$(ptop)" -ge 32 ]
reload
hook_wait 1
snap s13-reload
ck s13_reload_below_notch [ "$(ptop)" -ge 32 ]
cfg off
reload
hook_wait 1
snap s13-restored
ck s13_restored eq "$(pref _HIHideMenuBar) $(pref AppleMenuBarVisibleInFullscreen)" "bool:true absent"
ck s13_menu_hidden menu_visible false
ck s13_no_state nostate
/usr/bin/defaults delete -g _HIHideMenuBar

# --- S14 bottom bar is never managed -------------------------------------------
cfg on
"$SB" --bar position=bottom
stm menubar refresh >"$D/s14.out" 2>&1
/bin/cat "$D/s14.out"
snap s14-bottom
ck s14_prefs_absent eq "$(pref _HIHideMenuBar) $(pref AppleMenuBarVisibleInFullscreen)" "absent absent"
ck s14_no_state nostate
cfg off

printf '\nhook_log_begin\n'
/bin/cat "$D/hook.log"
printf 'hook_log_end\n'
