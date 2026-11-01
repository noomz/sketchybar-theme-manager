#!/usr/bin/env bash
# stm menubar — opt-in config, read-only status, and dry-run plans (T5).
# Every external surface is a stub: the bar, the screen query and the
# preference store. Nothing here may write a preference or move the bar.
# shellcheck source=tests/helpers.sh
. "$(dirname -- "$0")/helpers.sh"

setup_sandbox

MB="$SANDBOX/mb"
STATE_DIR="$XDG_STATE_HOME/stm"
STATE="$STATE_DIR/menubar.state"
CFG="$SANDBOX/stm.config.toml"
export MB

# The bar stub is stateful. $MB/disp holds one display per line,
#   arrangement-id uuid x y w h auto
# in CoreGraphics coordinates, where "auto" is SketchyBar's own clearance on
# that display. $MB/yoff holds the runtime y_offset and $MB/pos the position.
# One item, logo, is drawn on every display at auto + y_offset below its top.
# Every call is logged so a test can prove that nothing mutated the bar.
cat >"$SANDBOX/bin/sketchybar" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$MB/sketchybar.log"
[ -f "$MB/bar-down" ] && exit 1
case "$1" in
  --bar)
    shift
    for a in "$@"; do
      case "$a" in
        y_offset=*) [ -f "$MB/bar-ignore" ] || printf '%s\n' "${a#y_offset=}" >"$MB/yoff" ;;
      esac
    done
    exit 0
    ;;
  --query) : ;;
  *) exit 0 ;;
esac
yoff=$(cat "$MB/yoff")
while [ "$#" -gt 0 ]; do
  [ "$1" = "--query" ] || exit 1
  case "$2" in
    bar)
      printf '{\n\t"position": "%s",\n\t"topmost": "off",\n\t"height": 34,\n\t"y_offset": %s,\n\t"items": [\n\t\t "logo"\n\t]\n}\n' \
        "$(cat "$MB/pos")" "$yoff"
      ;;
    displays)
      awk 'BEGIN { print "[" }
        { printf("%s\t{\n\t\t\"arrangement-id\":%s,\n\t\t\"UUID\":\"%s\",\n\t\t\"frame\":{\n\t\t\"x\":%s.0000,\n\t\t\"y\":%s.0000,\n\t\t\"w\":%s.0000,\n\t\t\"h\":%s.0000\n\t\t}\n\t}", (NR > 1 ? ",\n" : ""), $1, $2, $3, $4, $5, $6) }
        END { print "\n]" }' "$MB/disp"
      ;;
    stm.menubar) [ -f "$MB/hook" ] || exit 1; printf '{ "name": "stm.menubar" }\n' ;;
    logo)
      awk -v yo="$yoff" 'BEGIN { printf("{\n\t\"name\": \"logo\",\n\t\"bounding_rects\": {\n") }
        { printf("%s\t\t\"display-%s\": {\n\t\t\t\"origin\": [ %d.000000, %d.000000 ],\n\t\t\t\"size\": [ 45.000000, 34.000000 ]\n\t\t}", (NR > 1 ? ",\n" : ""), $1, $3 + 8, $4 + $7 + yo) }
        END { print "\n\t}\n}" }' "$MB/disp"
      ;;
    *) exit 1 ;;
  esac
  shift 2
done
exit 0
STUB
chmod 755 "$SANDBOX/bin/sketchybar"

# Screen stub: prints the fixture the JXA query would print, or fails.
cat >"$SANDBOX/bin/osascript-stub" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$MB/osascript.log"
[ -f "$MB/screens" ] || exit 1
cat "$MB/screens"
STUB
chmod 755 "$SANDBOX/bin/osascript-stub"
export STM_OSASCRIPT="$SANDBOX/bin/osascript-stub"

# Preference stub: one file per key holds "1" or "0" ("string:x" for a key of
# another type). Writes change the files. Faults: $MB/defaults-fail-<key>
# makes a write to that key fail; $MB/defaults-ignore makes writes succeed
# without effect; $MB/on-write runs after every write.
cat >"$SANDBOX/bin/defaults-stub" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$MB/defaults.log"
[ -f "$MB/defaults-down" ] && exit 1
case "$1" in
  read-type | read) : ;;
  write | delete)
    printf '%s\n' "$*" >>"$MB/defaults-writes.log"
    [ -f "$MB/defaults-fail-$3" ] && exit 1
    if [ ! -f "$MB/defaults-ignore" ]; then
      if [ "$1" = delete ]; then
        rm -f "$MB/prefs/$3"
      elif [ "$5" = true ]; then
        printf '1\n' >"$MB/prefs/$3"
      else
        printf '0\n' >"$MB/prefs/$3"
      fi
    fi
    [ -x "$MB/on-write" ] && "$MB/on-write" "$3"
    exit 0
    ;;
  *) exit 1 ;;
esac
[ "$2" = "-g" ] || exit 1
f="$MB/prefs/$3"
if [ ! -f "$f" ]; then
  printf "Error: Could not find key '%s' in domain 'kCFPreferencesAnyApplication'.\n" "$3" >&2
  exit 1
fi
v=$(cat "$f")
if [ "$1" = "read-type" ]; then
  case "$v" in
    string:*) printf 'Type is string\n' ;;
    *) printf 'Type is boolean\n' ;;
  esac
else
  printf '%s\n' "${v#string:}"
fi
STUB
chmod 755 "$SANDBOX/bin/defaults-stub"
export STM_DEFAULTS="$SANDBOX/bin/defaults-stub"

NOTCH_UUID=37D8832A-2D66-02CA-B9F7-8F30A301B230

# mb_fixture [position] [y_offset] — one built-in notched display (SketchyBar
# clears 31 points, the menu needs 34) hosting a bar with one item, both menu
# preferences absent, no state.
mb_fixture() {
  rm -rf "$MB" "$STATE_DIR" "$CFG"
  mkdir -p "$MB/prefs"
  : >"$MB/sketchybar.log"
  : >"$MB/defaults.log"
  : >"$STM_FETCH_LOG"
  : >"$STM_POST_LOG"
  printf '%s\n' "${1:-top}" >"$MB/pos"
  printf '%s\n' "${2:-0}" >"$MB/yoff"
  printf '1 %s 0 0 1728 1117 31\n' "$NOTCH_UUID" >"$MB/disp"
  printf '0 1728 1117 32 771.5 956.5 34\n' >"$MB/screens"
}

# pref <key> — the stub's current value, as stm reports it.
pref() {
  if [ -f "$MB/prefs/$1" ]; then
    case "$(cat "$MB/prefs/$1")" in 1) echo bool:true ;; 0) echo bool:false ;; *) echo other ;; esac
  else
    echo absent
  fi
}

mb_config() {
  printf '[menu_bar]\n%s\n' "$1" >"$CFG"
}

# assert_no_writes — no preference write, no bar mutation, no state, offline.
assert_no_writes() {
  assert_file_absent "$MB/defaults-writes.log" "no preference write"
  local mutations
  mutations=$(grep -v '^--query' "$MB/sketchybar.log" || true)
  assert_eq "" "$mutations" "no mutating sketchybar call"
  assert_file_absent "$STATE_DIR" "no state directory created"
  assert_eq "" "$(cat "$STM_FETCH_LOG")" "no fetch"
  assert_eq "" "$(cat "$STM_POST_LOG")" "no post"
}

# write_state <applied pref> <y_offset applied> [extra line] — a valid state
# file in which stm applied fullscreen-only and an offset of <y>.
write_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  {
    printf 'version=1\nphase=active\ngeneration=3\n'
    printf 'targets=37D8832A-2D66-02CA-B9F7-8F30A301B230\n'
    printf 'pref._HIHideMenuBar.original=absent\n'
    printf 'pref._HIHideMenuBar.applied=%s\n' "$1"
    printf 'pref._HIHideMenuBar.owner=applied\n'
    printf 'pref.AppleMenuBarVisibleInFullscreen.original=bool:true\n'
    printf 'pref.AppleMenuBarVisibleInFullscreen.applied=%s\n' "$1"
    printf 'pref.AppleMenuBarVisibleInFullscreen.owner=applied\n'
    printf 'bar.y_offset.original=0\n'
    printf 'bar.y_offset.applied=%s\n' "$2"
    printf 'bar.y_offset.owner=applied\n'
    [ -z "${3:-}" ] || printf '%s\n' "$3"
  } >"$STATE"
  chmod 600 "$STATE"
}

# ---------------------------------------------------------------------------
# Default off (V1)
# ---------------------------------------------------------------------------

it "no config: status reports smart_notch off and touches nothing"
mb_fixture
run_stm menubar status --porcelain
assert_status 0
assert_contains "$STM_OUT" "smart_notch	off"
assert_contains "$STM_OUT" "pref._HIHideMenuBar	absent"
assert_contains "$STM_OUT" "target.1	confirmed-notch"
assert_contains "$STM_OUT" "hook	missing"
assert_contains "$STM_OUT" "state	none"
assert_no_writes
done_it

it "no config: refresh is a no-op even without --dry-run"
mb_fixture
run_stm menubar refresh
assert_status 0
assert_contains "$STM_OUT" "nothing to do"
assert_no_writes
done_it

it "smart_notch off: refresh and restore write nothing"
mb_fixture
mb_config 'smart_notch = "off"'
run_stm --config "$CFG" menubar refresh
assert_status 0
run_stm --config "$CFG" menubar restore
assert_status 0
assert_contains "$STM_OUT" "nothing to restore"
assert_no_writes
done_it

# ---------------------------------------------------------------------------
# Invalid config
# ---------------------------------------------------------------------------

for bad in 'smart_notch = "yes"' 'smart_notch = on' 'smart_notch = true' \
  'smartnotch = "on"' 'smart_notch = "on" # ok
smart_notch = "off"'; do
  it "invalid [menu_bar] is a config error: $(printf '%s' "$bad" | head -n 1)"
  mb_fixture
  mb_config "$bad"
  run_stm --config "$CFG" menubar refresh --dry-run
  assert_status 2
  assert_contains "$STM_ERR" "[menu_bar]"
  assert_no_writes
  done_it
done

it "duplicate [menu_bar] tables are a config error"
mb_fixture
printf '[menu_bar]\nsmart_notch = "on"\n[menu_bar]\nsmart_notch = "off"\n' >"$CFG"
run_stm --config "$CFG" menubar status
assert_status 2
assert_no_writes
done_it

it "comments and a trailing comment are accepted"
mb_fixture
printf '# mine\n[menu_bar]\n# opt in\nsmart_notch = "on" # notch\n' >"$CFG"
run_stm --config "$CFG" menubar status --porcelain
assert_status 0
assert_contains "$STM_OUT" "smart_notch	on"
done_it

# ---------------------------------------------------------------------------
# A palette cannot control the menu bar
# ---------------------------------------------------------------------------

it "a palette with [menu_bar] fails lint and does not enable the feature"
mb_fixture
mkdir -p "$SANDBOX/palettes"
cat >"$SANDBOX/palettes/evil.toml" <<'TOML'
name = "evil"
slug = "evil"
[colors]
bar_bg = "0xff000000"
[menu_bar]
smart_notch = "on"
TOML
run_stm lint "$SANDBOX/palettes/evil.toml"
assert_ne 0 "$STM_STATUS" "lint rejects [menu_bar] in a palette"
run_stm --palette-dir "$SANDBOX/palettes" menubar status --porcelain
assert_status 0
assert_contains "$STM_OUT" "smart_notch	off"
assert_no_writes
done_it

# ---------------------------------------------------------------------------
# Dry run (V11) and the plan
# ---------------------------------------------------------------------------

it "dry run on a notched top bar reports the preference plan and writes nothing"
mb_fixture
mb_config 'smart_notch = "on"'
run_stm --config "$CFG" menubar refresh --dry-run
assert_status 0
assert_contains "$STM_OUT" "would set _HIHideMenuBar to bool:false (now absent)"
assert_contains "$STM_OUT" "would set AppleMenuBarVisibleInFullscreen to bool:false (now absent)"
assert_contains "$STM_OUT" "y_offset"
assert_no_writes
done_it

it "dry run skips keys that already hold the target value"
mb_fixture
mb_config 'smart_notch = "on"'
printf '0\n' >"$MB/prefs/_HIHideMenuBar"
printf '0\n' >"$MB/prefs/AppleMenuBarVisibleInFullscreen"
run_stm --config "$CFG" menubar refresh --dry-run
assert_status 0
assert_not_contains "$STM_OUT" "would set"
assert_no_writes
done_it

it "without --dry-run the plan is applied and verified (V2)"
mb_fixture
mb_config 'smart_notch = "on"'
run_stm --config "$CFG" menubar refresh
assert_status 0
assert_eq bool:false "$(pref _HIHideMenuBar)" "_HIHideMenuBar applied"
assert_eq bool:false "$(pref AppleMenuBarVisibleInFullscreen)" "fullscreen key applied"
assert_eq 3 "$(cat "$MB/yoff")" "offset raised to the measured 34-point clearance"
assert_contains "$STM_OUT" "set y_offset to 3 (base 0 + 3)"
assert_file_contains "$STATE" "phase=active"
assert_file_contains "$STATE" "pref._HIHideMenuBar.original=absent"
assert_file_contains "$STATE" "pref._HIHideMenuBar.owner=applied"
assert_file_contains "$STATE" "bar.y_offset.applied=3"
assert_eq 600 "$(stat -f %Lp "$STATE")" "state file mode"
assert_eq 700 "$(stat -f %Lp "$STATE_DIR")" "state dir mode"
assert_file_absent "$STATE_DIR/menubar.lock" "lock released"
done_it

it "bottom bars are out of scope: no preference plan"
mb_fixture bottom
mb_config 'smart_notch = "on"'
run_stm --config "$CFG" menubar refresh --dry-run
assert_status 0
assert_not_contains "$STM_OUT" "would set"
assert_contains "$STM_OUT" "nothing to do"
assert_no_writes
done_it

it "a confirmed no-notch display needs nothing"
mb_fixture
mb_config 'smart_notch = "on"'
printf '0 1728 1117 0 - - 24\n' >"$MB/screens"
run_stm --config "$CFG" menubar refresh --dry-run
assert_status 0
assert_contains "$STM_OUT" "nothing to do"
run_stm --config "$CFG" menubar status --porcelain
assert_contains "$STM_OUT" "target.1	confirmed-no-notch"
assert_no_writes
done_it

# ---------------------------------------------------------------------------
# Unknown is not "no notch" (V3, V10)
# ---------------------------------------------------------------------------

it "failed screen query: notch unknown, no plan, warning"
mb_fixture
mb_config 'smart_notch = "on"'
rm -f "$MB/screens"
run_stm --config "$CFG" menubar refresh --dry-run
assert_status 0
assert_contains "$STM_ERR" "unknown"
assert_not_contains "$STM_OUT" "would"
run_stm --config "$CFG" menubar status --porcelain
assert_contains "$STM_OUT" "target.1	unknown"
assert_no_writes
done_it

it "unknown geometry never restores owned values"
mb_fixture
mb_config 'smart_notch = "on"'
rm -f "$MB/screens"
write_state bool:false 3
printf '0\n' >"$MB/prefs/_HIHideMenuBar"
printf '0\n' >"$MB/prefs/AppleMenuBarVisibleInFullscreen"
run_stm --config "$CFG" menubar refresh --dry-run
assert_status 0
assert_not_contains "$STM_OUT" "would restore"
assert_file_absent "$MB/defaults-writes.log"
done_it

it "bar unreachable: targets unknown, no plan"
mb_fixture
mb_config 'smart_notch = "on"'
touch "$MB/bar-down"
run_stm --config "$CFG" menubar status --porcelain
assert_status 0
assert_contains "$STM_OUT" "bar.position	unknown"
assert_contains "$STM_OUT" "targets	unknown"
run_stm --config "$CFG" menubar refresh --dry-run
assert_not_contains "$STM_OUT" "would"
done_it

it "a non-boolean preference is unsupported and blocks the plan"
mb_fixture
mb_config 'smart_notch = "on"'
printf 'string:x\n' >"$MB/prefs/_HIHideMenuBar"
run_stm --config "$CFG" menubar refresh --dry-run
assert_status 0
assert_contains "$STM_ERR" "unsupported"
assert_not_contains "$STM_OUT" "would set"
assert_no_writes
done_it

# ---------------------------------------------------------------------------
# State: closed schema, safe path, restore plan
# ---------------------------------------------------------------------------

it "restore --dry-run plans the owned values that still match"
mb_fixture
write_state bool:false 3
printf '0\n' >"$MB/prefs/_HIHideMenuBar"
printf '0\n' >"$MB/prefs/AppleMenuBarVisibleInFullscreen"
printf '3\n' >"$MB/yoff"
cp "$STATE" "$SANDBOX/state.before"
run_stm menubar restore --dry-run
assert_status 0
assert_contains "$STM_OUT" "would restore _HIHideMenuBar to absent"
assert_contains "$STM_OUT" "would restore AppleMenuBarVisibleInFullscreen to bool:true"
assert_contains "$STM_OUT" "would restore y_offset to 0"
assert_files_equal "$SANDBOX/state.before" "$STATE" "dry run leaves state untouched"
assert_file_absent "$MB/defaults-writes.log"
done_it

it "restore --dry-run leaves values the user changed (conflict)"
mb_fixture
write_state bool:false 3
printf '1\n' >"$MB/prefs/_HIHideMenuBar"
printf '0\n' >"$MB/prefs/AppleMenuBarVisibleInFullscreen"
run_stm menubar restore --dry-run
assert_status 0
assert_contains "$STM_OUT" "conflict: _HIHideMenuBar is now bool:true"
assert_not_contains "$STM_OUT" "would restore _HIHideMenuBar"
assert_contains "$STM_OUT" "would restore AppleMenuBarVisibleInFullscreen"
assert_contains "$STM_OUT" "y_offset is already back at 0"
done_it

it "config off with owned values plans a restore"
mb_fixture
mb_config 'smart_notch = "off"'
write_state bool:false 0
printf '0\n' >"$MB/prefs/_HIHideMenuBar"
printf '0\n' >"$MB/prefs/AppleMenuBarVisibleInFullscreen"
run_stm --config "$CFG" menubar refresh --dry-run
assert_status 0
assert_contains "$STM_OUT" "would restore _HIHideMenuBar to absent"
done_it

it "state with an unknown key is refused and kept"
mb_fixture
# shellcheck disable=SC2016  # the hostile line must stay literal
write_state bool:false 3 'shell=$(rm -rf /)'
cp "$STATE" "$SANDBOX/state.before"
run_stm menubar restore --dry-run
assert_status 2
assert_contains "$STM_ERR" "menubar.state"
assert_files_equal "$SANDBOX/state.before" "$STATE" "invalid state kept for recovery"
run_stm menubar status --porcelain
assert_status 2
assert_contains "$STM_OUT" "state	invalid"
done_it

for bad in 'version=2' 'phase=whatever' 'generation=-1' 'bar.y_offset.applied=3; rm' \
  'pref._HIHideMenuBar.owner=mine' 'targets=../../x'; do
  it "state value is validated: $bad"
  mb_fixture
  write_state bool:false 3
  key=${bad%%=*}
  grep -v "^$key=" "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  printf '%s\n' "$bad" >>"$STATE"
  chmod 600 "$STATE"
  run_stm menubar restore --dry-run
  assert_status 2
  done_it
done

it "state missing a required key is refused"
mb_fixture
write_state bool:false 3
grep -v '^bar.y_offset.owner=' "$STATE" >"$STATE.tmp" && mv "$STATE.tmp" "$STATE"
run_stm menubar restore --dry-run
assert_status 2
done_it

it "symlinked state file is refused"
mb_fixture
write_state bool:false 3
mv "$STATE" "$SANDBOX/real.state"
ln -s "$SANDBOX/real.state" "$STATE"
run_stm menubar restore --dry-run
assert_status 2
assert_contains "$STM_ERR" "symlink"
done_it

it "symlinked state directory is refused"
mb_fixture
mkdir -p "$SANDBOX/elsewhere" "$XDG_STATE_HOME"
ln -s "$SANDBOX/elsewhere" "$STATE_DIR"
run_stm menubar status
assert_status 2
assert_contains "$STM_ERR" "symlink"
done_it

it "group-writable state file is refused"
mb_fixture
write_state bool:false 3
chmod 664 "$STATE"
run_stm menubar restore --dry-run
assert_status 2
done_it

it "hook item presence is reported"
mb_fixture
touch "$MB/hook"
run_stm menubar status --porcelain
assert_contains "$STM_OUT" "hook	loaded"
done_it


# ---------------------------------------------------------------------------
# T6: apply, ownership and recovery
# ---------------------------------------------------------------------------

# applied — a fixture in which stm has already applied fullscreen-only and
# raised the offset to 3.
applied() {
  mb_fixture
  mb_config 'smart_notch = "on"'
  run_stm --config "$CFG" menubar refresh
  assert_status 0 "setup refresh"
}

it "a second refresh changes nothing and keeps the first originals (V5)"
applied
cp "$STATE" "$SANDBOX/state.before"
before=$(wc -l <"$MB/defaults-writes.log")
run_stm --config "$CFG" menubar refresh
assert_status 0
assert_eq "$before" "$(wc -l <"$MB/defaults-writes.log")" "no further preference write"
assert_eq 3 "$(cat "$MB/yoff")" "offset not compounded"
assert_file_contains "$STATE" "pref._HIHideMenuBar.original=absent"
assert_not_contains "$(/usr/bin/grep -v '^--query' "$MB/sketchybar.log" | tail -n +2)" "y_offset" "no second offset write"
done_it

it "after a reload resets the offset, refresh re-baselines instead of compounding (V5, V8)"
applied
printf '0\n' >"$MB/yoff"
run_stm --config "$CFG" menubar refresh
assert_status 0
assert_eq 3 "$(cat "$MB/yoff")" "back to base 0 + 3, not 6"
assert_file_contains "$STATE" "bar.y_offset.original=0"
done_it

it "a new user base offset becomes the base; stm adds only what is still needed (V8)"
applied
printf '10\n' >"$MB/yoff"
run_stm --config "$CFG" menubar refresh
assert_status 0
assert_eq 10 "$(cat "$MB/yoff")" "10 already clears the menu"
assert_file_contains "$STATE" "bar.y_offset.owner=unchanged"
done_it

it "a preference the user changed is not overwritten (V4)"
applied
printf '1\n' >"$MB/prefs/_HIHideMenuBar"
: >"$MB/defaults-writes.log"
run_stm --config "$CFG" menubar refresh
assert_status 0
assert_contains "$STM_ERR" "_HIHideMenuBar was changed after stm set it"
assert_eq bool:true "$(pref _HIHideMenuBar)" "user value kept"
assert_eq "" "$(cat "$MB/defaults-writes.log")" "no preference write"
assert_file_contains "$STATE" "pref._HIHideMenuBar.owner=conflict"
assert_file_contains "$STATE" "phase=conflict"
run_stm --config "$CFG" menubar refresh
assert_eq "" "$(cat "$MB/defaults-writes.log")" "still no write on the next event"
done_it

it "restore hands back every owned value and drops the state (V9)"
applied
run_stm --config "$CFG" menubar restore
assert_status 0
assert_eq absent "$(pref _HIHideMenuBar)"
assert_eq absent "$(pref AppleMenuBarVisibleInFullscreen)"
assert_eq 0 "$(cat "$MB/yoff")"
assert_file_absent "$STATE" "state removed once nothing is owned"
done_it

it "restore keeps a user change and restores the rest (V4)"
applied
printf '1\n' >"$MB/prefs/_HIHideMenuBar"
run_stm --config "$CFG" menubar restore
assert_status 0
assert_eq bool:true "$(pref _HIHideMenuBar)" "user value kept"
assert_eq absent "$(pref AppleMenuBarVisibleInFullscreen)" "owned value restored"
assert_file_absent "$STATE"
done_it

it "turning the config off restores on the next refresh (V9)"
applied
mb_config 'smart_notch = "off"'
run_stm --config "$CFG" menubar refresh
assert_status 0
assert_eq absent "$(pref _HIHideMenuBar)"
assert_eq 0 "$(cat "$MB/yoff")"
assert_file_absent "$STATE"
done_it

it "a confirmed no-notch arrangement restores; an unknown one does not (V3)"
applied
rm -f "$MB/screens"
run_stm --config "$CFG" menubar refresh
assert_status 0
assert_eq bool:false "$(pref _HIHideMenuBar)" "unknown keeps stm's value"
printf '0 1728 1117 0 - - 24\n' >"$MB/screens"
run_stm --config "$CFG" menubar refresh
assert_status 0
assert_eq absent "$(pref _HIHideMenuBar)" "no notch hands it back"
assert_file_absent "$STATE"
done_it

it "moving the bar to the bottom hands back what stm owns"
applied
printf 'bottom\n' >"$MB/pos"
run_stm --config "$CFG" menubar refresh
assert_status 0
assert_eq absent "$(pref AppleMenuBarVisibleInFullscreen)"
assert_eq 0 "$(cat "$MB/yoff")"
done_it

it "a failed write rolls back this run's earlier writes and keeps recovery state (V6)"
mb_fixture
mb_config 'smart_notch = "on"'
touch "$MB/defaults-fail-AppleMenuBarVisibleInFullscreen"
run_stm --config "$CFG" menubar refresh
assert_ne 0 "$STM_STATUS"
assert_contains "$STM_ERR" "could not write AppleMenuBarVisibleInFullscreen"
assert_eq absent "$(pref _HIHideMenuBar)" "earlier write rolled back"
assert_eq 0 "$(cat "$MB/yoff")" "offset never touched"
assert_file_contains "$STATE" "phase=recovery-required"
assert_file_absent "$STATE_DIR/menubar.lock" "lock released after failure"
rm -f "$MB/defaults-fail-AppleMenuBarVisibleInFullscreen"
run_stm --config "$CFG" menubar restore
assert_status 0
assert_file_absent "$STATE" "restore resolves the uncertain write"
done_it

it "a write that does not take effect is reported, not trusted (V2, V6)"
mb_fixture
mb_config 'smart_notch = "on"'
touch "$MB/defaults-ignore"
run_stm --config "$CFG" menubar refresh
assert_ne 0 "$STM_STATUS"
assert_contains "$STM_ERR" "reads absent after writing bool:false"
assert_file_contains "$STATE" "phase=recovery-required"
done_it

it "an offset the bar ignores fails and rolls the preferences back (V2, V6)"
mb_fixture
mb_config 'smart_notch = "on"'
touch "$MB/bar-ignore"
run_stm --config "$CFG" menubar refresh
assert_ne 0 "$STM_STATUS"
assert_contains "$STM_ERR" "y_offset reads 0 after writing 3"
assert_eq absent "$(pref _HIHideMenuBar)"
assert_eq absent "$(pref AppleMenuBarVisibleInFullscreen)"
done_it

it "no write happens when the state cannot be saved (V6)"
mb_fixture
mb_config 'smart_notch = "on"'
mkdir -p "$XDG_STATE_HOME"
chmod 500 "$XDG_STATE_HOME"
run_stm --config "$CFG" menubar refresh
chmod 700 "$XDG_STATE_HOME"
assert_ne 0 "$STM_STATUS"
assert_file_absent "$MB/defaults-writes.log" "nothing written before the journal"
assert_eq 0 "$(cat "$MB/yoff")"
done_it

it "a crash between write and verification is settled by the current value (V5, V9)"
mb_fixture
mb_config 'smart_notch = "on"'
write_state bool:false 3
sed -i '' 's/^pref._HIHideMenuBar.owner=applied$/pref._HIHideMenuBar.owner=uncertain/; s/^phase=active$/phase=applying/' "$STATE"
printf '0\n' >"$MB/prefs/_HIHideMenuBar"
printf '0\n' >"$MB/prefs/AppleMenuBarVisibleInFullscreen"
printf '3\n' >"$MB/yoff"
run_stm --config "$CFG" menubar refresh
assert_status 0
assert_file_contains "$STATE" "pref._HIHideMenuBar.owner=applied"
assert_file_contains "$STATE" "phase=active"
done_it

it "a run that finds a live lock marks dirty and leaves (V7)"
mb_fixture
mb_config 'smart_notch = "on"'
sleep 30 &
holder=$!
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
printf '%s\t%s\n' "$holder" "$(ps -o lstart= -p "$holder" | awk '{ $1 = $1; print }')" >"$STATE_DIR/menubar.lock"
run_stm --config "$CFG" menubar refresh
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
assert_status 0
assert_contains "$STM_OUT" "in progress"
assert_file_exists "$STATE_DIR/menubar.dirty" "dirty mark for the holder"
assert_file_absent "$MB/defaults-writes.log" "no write without the lock"
done_it

it "a stale lock is reported and never removed automatically (V7)"
mb_fixture
mb_config 'smart_notch = "on"'
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
printf '999999\tThu Jan  1 00:00:00 1970\n' >"$STATE_DIR/menubar.lock"
run_stm --config "$CFG" menubar refresh
assert_status 2
assert_contains "$STM_ERR" "stale lock"
assert_file_exists "$STATE_DIR/menubar.lock" "lock kept"
assert_file_absent "$MB/defaults-writes.log"
run_stm --config "$CFG" menubar status --porcelain
assert_contains "$STM_OUT" "lock	stale"
assert_contains "$STM_OUT" "lock.path	$STATE_DIR/menubar.lock"
done_it

it "an event during a run gets its own cycle with the newest observation (V7)"
mb_fixture
mb_config 'smart_notch = "on"'
cat >"$MB/on-write" <<HOOK
#!/bin/sh
[ -f "$MB/once" ] && exit 0
touch "$MB/once" "$STATE_DIR/menubar.dirty"
printf '0 1728 1117 0 - - 24\n' >"$MB/screens"
HOOK
chmod 755 "$MB/on-write"
run_stm --config "$CFG" menubar refresh
assert_status 0
assert_eq absent "$(pref _HIHideMenuBar)" "second cycle saw no notch and handed back"
assert_file_absent "$STATE_DIR/menubar.dirty"
assert_file_absent "$STATE_DIR/menubar.lock"
assert_file_absent "$STATE"
done_it

it "user config files are never written (V8)"
mb_fixture
mkdir -p "$SANDBOX/sbdir"
printf '[menu_bar]\nsmart_notch = "on"\n' >"$SANDBOX/sbdir/stm.config.toml"
printf 'sketchybar --bar y_offset=0\n' >"$SANDBOX/sbdir/sketchybarrc"
before=$(cd "$SANDBOX/sbdir" && cksum stm.config.toml sketchybarrc)
run_stm --dir "$SANDBOX/sbdir" menubar refresh
assert_status 0
assert_eq "$before" "$(cd "$SANDBOX/sbdir" && cksum stm.config.toml sketchybarrc)"
assert_eq "sketchybarrc stm.config.toml" "$(cd "$SANDBOX/sbdir" && echo *)" "no new file in the config dir"
done_it

it "mixed displays: any notched target keeps fullscreen-only; offset is the maximum need (V12)"
mb_fixture
mb_config 'smart_notch = "on"'
printf '1 %s 0 0 1728 1117 31\n2 0B2C 1728 0 1440 900 0\n' "$NOTCH_UUID" >"$MB/disp"
printf '0 1728 1117 32 771.5 956.5 34\n1728 1440 900 0 - - 30\n' >"$MB/screens"
run_stm --config "$CFG" menubar refresh
assert_status 0
assert_eq bool:false "$(pref AppleMenuBarVisibleInFullscreen)"
assert_eq 30 "$(cat "$MB/yoff")" "secondary needs 30, more than the notch's 3"
done_it

# ---------------------------------------------------------------------------
# CLI surface
# ---------------------------------------------------------------------------

it "unknown or missing subcommand is a usage error"
mb_fixture
run_stm menubar
assert_status 64
run_stm menubar enable
assert_status 64
assert_no_writes
done_it

it "help lists the menubar command"
run_stm help
assert_contains "$STM_OUT" "menubar status"
done_it

finish
