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

# The bar stub answers queries from fixture files and logs every call, so a
# test can prove that no mutating command (--bar, --set, --add, --reload) ran.
cat >"$SANDBOX/bin/sketchybar" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$MB/sketchybar.log"
[ -f "$MB/bar-down" ] && exit 1
case "$1" in
  --query) : ;;
  *) exit 0 ;;
esac
while [ "$#" -gt 0 ]; do
  [ "$1" = "--query" ] || exit 1
  case "$2" in
    bar) cat "$MB/bar.json" ;;
    displays) cat "$MB/displays.json" ;;
    stm.menubar) [ -f "$MB/hook" ] || exit 1; printf '{ "name": "stm.menubar" }\n' ;;
    *) [ -f "$MB/item.$2.json" ] || exit 1; cat "$MB/item.$2.json" ;;
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

# Preference stub: one file per key holds its value ("1", "0", or "string:x").
cat >"$SANDBOX/bin/defaults-stub" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$MB/defaults.log"
[ -f "$MB/defaults-down" ] && exit 1
case "$1" in
  read-type | read) : ;;
  *) printf '%s\n' "$*" >>"$MB/defaults-writes.log"; exit 0 ;;
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

# mb_fixture [position] [y_offset] — one built-in notched display hosting a top
# bar with one visible item, both menu preferences absent, no state.
mb_fixture() {
  local position="${1:-top}" offset="${2:-0}"
  rm -rf "$MB" "$STATE_DIR" "$CFG"
  mkdir -p "$MB/prefs"
  : >"$MB/sketchybar.log"
  : >"$MB/defaults.log"
  : >"$STM_FETCH_LOG"
  : >"$STM_POST_LOG"
  printf '{\n\t"position": "%s",\n\t"topmost": "off",\n\t"height": 34,\n\t"y_offset": %s,\n\t"items": [\n\t\t "logo"\n\t]\n}\n' \
    "$position" "$offset" >"$MB/bar.json"
  cat >"$MB/displays.json" <<'JSON'
[
	{
		"arrangement-id":1,
		"DirectDisplayID":1,
		"UUID":"37D8832A-2D66-02CA-B9F7-8F30A301B230",
		"frame":{
		"x":0.0000,
		"y":0.0000,
		"w":1728.0000,
		"h":1117.0000
		}
	}
]
JSON
  printf '{\n\t"name": "logo",\n\t"bounding_rects": {\n\t\t"display-1": {\n\t\t\t"origin": [ 8.000000, 31.000000 ],\n\t\t\t"size": [ 45.000000, 34.000000 ]\n\t\t}\n\t}\n}\n' \
    >"$MB/item.logo.json"
  printf '0 1728 1117 32 771.5 956.5\n' >"$MB/screens"
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

it "without --dry-run a plan that needs writes is refused, not half-applied"
mb_fixture
mb_config 'smart_notch = "on"'
run_stm --config "$CFG" menubar refresh
assert_ne 0 "$STM_STATUS"
assert_contains "$STM_ERR" "--dry-run"
assert_no_writes
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
printf '0 1728 1117 0 - -\n' >"$MB/screens"
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
sed -i '' 's/"y_offset": 0/"y_offset": 3/' "$MB/bar.json"
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
assert_contains "$STM_OUT" "conflict: y_offset is now 0"
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
