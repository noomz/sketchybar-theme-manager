#!/usr/bin/env bash
#
# bundles/items/battery (#19). Runs plugin.sh as SketchyBar would, against a
# fake `pmset` (canned `pmset -g batt` output) and a fake `sketchybar` that logs
# its argv one per line; then runs item.lua under Lua with a fake `sbar`.
# Never touches the real pmset or the real bar.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

BUNDLE="$REPO_ROOT/bundles/items/battery"
PLUGIN="$BUNDLE/plugin.sh"
SB_LOG="$SANDBOX/sketchybar.argv"

# Distinct palette colours so every colour names its source.
GREEN=0xff00aa00
YELLOW=0xffaaaa00
RED=0xffaa0000

# Glyphs (bash 3.2 printf has no \U): nf-md battery levels, nf-fa-bolt.
G90=$(printf '\363\260\202\216')
G60=$(printf '\363\260\202\221')
G30=$(printf '\363\260\202\223')
G10=$(printf '\363\260\202\226')
G0=$(printf '\363\260\202\227')
BOLT=$(printf '\357\203\247')

FAKE_BIN="$SANDBOX/bat-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/sketchybar" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >>"$SB_LOG"
EOF
# Fake pmset: `-g batt` prints $PMSET_OUT; anything else is a usage error.
# Each call is counted in $SB_LOG.pmset.
cat >"$SANDBOX/pmset" <<'EOF'
#!/bin/sh
printf 'call\n' >>"$SB_LOG.pmset"
[ "$1 $2" = "-g batt" ] || exit 64
printf '%s' "$PMSET_OUT"
EOF
chmod 755 "$FAKE_BIN/sketchybar" "$SANDBOX/pmset"

# pmset_batt <percent> <source> — `pmset -g batt` as a laptop prints it.
pmset_batt() {
  printf "Now drawing from '%s'\n -InternalBattery-0 (id=4653155)\t%s%%; discharging; 4:12 remaining present: true\n" \
    "$2" "$1"
}
DESKTOP=$(printf "Now drawing from 'AC Power'\n")
# Real `pmset -g batt` shapes beyond plain discharging.
NOT_CHARGING=$(printf "Now drawing from 'AC Power'\n -InternalBattery-0 (id=4653155)\t80%%; AC attached; not charging present: true\n")
CHARGED=$(printf "Now drawing from 'AC Power'\n -InternalBattery-0 (id=4653155)\t100%%; charged; 0:00 remaining present: true\n")
# A UPS line before the internal battery: the Mac's own battery wins.
LAPTOP_UPS=$(printf "Now drawing from 'Battery Power'\n -CP1500 (id=123)\t40%%; discharging; (no estimate)\n -InternalBattery-0 (id=4653155)\t20%%; discharging; 1:02 remaining present: true\n")
# A desktop on a UPS has no battery of its own.
DESKTOP_UPS=$(printf "Now drawing from 'UPS Power'\n -CP1500 (id=123)\t40%%; discharging; (no estimate)\n")

# run_plugin <pmset output> [VAR=value...] — argv sketchybar got lands in $SB.
SB=""
run_plugin() {
  local out="$1"
  shift
  rm -f "$SB_LOG" "$SB_LOG.pmset"
  env -i HOME="$HOME" TMPDIR="$SANDBOX" PATH="$FAKE_BIN:/bin" SB_LOG="$SB_LOG" \
    NAME=stm.battery SENDER=routine STM_PMSET="$SANDBOX/pmset" PMSET_OUT="$out" \
    STM_GREEN=$GREEN STM_YELLOW=$YELLOW STM_RED=$RED \
    "$@" /bin/sh "$PLUGIN" >/dev/null 2>&1
  SB=$(cat "$SB_LOG" 2>/dev/null || true)
  # I.bat: one pmset call per run; one sketchybar call carries every update.
  assert_eq call "$(cat "$SB_LOG.pmset" 2>/dev/null)" "pmset calls per run"
}

argv_of() {
  printf '%s\n' "$@"
}

it "glyph by level, state colour by level on battery (I.bat, V38)"
# percent | glyph | colour (on battery power)
for c in "100:$G90:$GREEN" "90:$G90:$GREEN" "89:$G60:$GREEN" "60:$G60:$GREEN" \
  "59:$G30:$GREEN" "31:$G30:$GREEN" "30:$G30:$YELLOW" "29:$G10:$YELLOW" \
  "16:$G10:$YELLOW" "15:$G10:$RED" "10:$G10:$RED" "9:$G0:$RED" "0:$G0:$RED"; do
  pct=${c%%:*}
  rest=${c#*:}
  run_plugin "$(pmset_batt "$pct" 'Battery Power')" STM_BAT_SHAPE=plain
  assert_eq "$(argv_of --set stm.battery drawing=on "icon=${rest%%:*}" "label=$pct%" \
    "icon.color=${rest#*:}")" "$SB" "$pct% on battery"
done
done_it

it "AC power: bolt and green at any level (I.bat, V38)"
run_plugin "$(pmset_batt 12 'AC Power')" STM_BAT_SHAPE=pill
assert_eq "$(argv_of --set stm.battery drawing=on "icon=$BOLT" label=12% icon.color=$GREEN)" \
  "$SB" "charging argv"
done_it

it "real pmset shapes: not charging, charged, laptop + UPS (I.bat, V38)"
run_plugin "$NOT_CHARGING" STM_BAT_SHAPE=plain
assert_eq "$(argv_of --set stm.battery drawing=on "icon=$BOLT" label=80% icon.color=$GREEN)" "$SB" "not charging"
run_plugin "$CHARGED" STM_BAT_SHAPE=plain
assert_eq "$(argv_of --set stm.battery drawing=on "icon=$BOLT" label=100% icon.color=$GREEN)" "$SB" "charged"
run_plugin "$LAPTOP_UPS" STM_BAT_SHAPE=plain
assert_eq "$(argv_of --set stm.battery drawing=on "icon=$G10" label=20% icon.color=$YELLOW)" "$SB" "laptop + UPS"
done_it

it "pill sends what plain sends (V32)"
run_plugin "$(pmset_batt 25 'Battery Power')" STM_BAT_SHAPE=plain
plain=$SB
run_plugin "$(pmset_batt 25 'Battery Power')" STM_BAT_SHAPE=pill
assert_eq "$plain" "$SB" "pill argv"
done_it

it "split: glyph and state colour on the icon sub-item (V32, V38, V10)"
run_plugin "$(pmset_batt 14 'Battery Power')" STM_BAT_SHAPE=split
assert_eq "$(argv_of --set stm.battery drawing=on label=14% \
  --set stm.battery.icon drawing=on "icon=$G10" background.color=$RED)" "$SB" "split argv"
run_plugin "$(pmset_batt 64 'AC Power')" STM_BAT_SHAPE=split
assert_eq "$(argv_of --set stm.battery drawing=on label=64% \
  --set stm.battery.icon drawing=on "icon=$BOLT" background.color=$GREEN)" "$SB" "split on AC"
# split is the manifest default.
assert_eq 'default = "split"' "$(awk '/^\[options\.shape\]/ { s = 1; next } /^\[/ { s = 0 } s && /^default/' \
  "$BUNDLE/item.toml")" "manifest shape default"
done_it

it "no battery: the item (and split icon sub-item) hides (V38)"
run_plugin "$DESKTOP" STM_BAT_SHAPE=split
assert_eq "$(argv_of --set stm.battery drawing=off --set stm.battery.icon drawing=off)" "$SB" "split"
run_plugin "$DESKTOP" STM_BAT_SHAPE=pill
assert_eq "$(argv_of --set stm.battery drawing=off)" "$SB" "pill"
run_plugin "" STM_BAT_SHAPE=plain
assert_eq "$(argv_of --set stm.battery drawing=off)" "$SB" "pmset failed"
run_plugin "$DESKTOP_UPS" STM_BAT_SHAPE=plain
assert_eq "$(argv_of --set stm.battery drawing=off)" "$SB" "desktop on a UPS"
done_it

it "a palette without the state colour sends no empty colour (V14)"
run_plugin "$(pmset_batt 50 'Battery Power')" STM_BAT_SHAPE=plain STM_GREEN=
assert_eq "$(argv_of --set stm.battery drawing=on "icon=$G30" label=50%)" "$SB" "plain"
run_plugin "$(pmset_batt 50 'Battery Power')" STM_BAT_SHAPE=split STM_GREEN=
assert_eq "$(argv_of --set stm.battery drawing=on label=50% \
  --set stm.battery.icon drawing=on "icon=$G30")" "$SB" "split"
done_it

LUA_BIN=$(command -v lua 2>/dev/null || true)
if [ -n "$LUA_BIN" ]; then
  mkdir -p "$SANDBOX/lua"
  cat >"$SANDBOX/lua/probe.lua" <<'EOF'
-- Runs item.lua with one shape and position; prints each item it adds, in
-- order, with its props flattened (keys sorted), then the plugin command.
local shape, position, item_lua = ...
local function dump(v)
  if type(v) ~= "table" then
    return tostring(v)
  end
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = k .. "=" .. dump(v[k])
  end
  return "{" .. table.concat(parts, " ") .. "}"
end
local sbar = {}
function sbar.add(kind, name, props)
  print(kind .. " " .. name .. " " .. dump(props))
  return { subscribe = function() end, set = function() end }
end
function sbar.exec(cmd) print("exec " .. cmd) end
local opts = { name = "stm.battery", position = position, update_freq = 120,
  plugin_dir = "/p", events = { "power_source_change" }, options = { shape = shape } }
dofile(item_lua)(sbar, opts, { green = 1, yellow = 2, red = 3, bg1 = 21, black = 22 })
EOF
  items_of() {
    "$LUA_BIN" "$SANDBOX/lua/probe.lua" "$1" "$2" "$BUNDLE/item.lua" 2>&1 | grep -v '^exec '
  }
  # icon_props <colour> — the initial icon table, flattened.
  icon_props() {
    printf 'icon={color=%s string=%s}' "$1" "$G90"
  }

  it "item.lua plain and pill: one item, pill on bg1 (V32, V14)"
  assert_eq "item stm.battery {$(icon_props 1) label={string=--%} position=right update_freq=120}" \
    "$(items_of plain right)" "plain"
  assert_eq "item stm.battery {background={color=21 drawing=true} $(icon_props 1) label={string=--%} position=left update_freq=120}" \
    "$(items_of pill left)" "pill"
  done_it

  it "item.lua split: icon sub-item left of the label at every position (V32, V33, V10)"
  main() {
    printf 'item stm.battery {background={color=21 drawing=true padding_left=0} icon={drawing=false} label={string=--%%} position=%s update_freq=120}' "$1"
  }
  sub() {
    printf 'item stm.battery.icon {background={color=1 drawing=true} %s label={drawing=false} position=%s}' \
      "$(icon_props 22)" "$1"
  }
  assert_eq "$(main right)
$(sub right)" "$(items_of split right)" "split right"
  for pos in left center; do
    assert_eq "$(sub "$pos")
$(main "$pos")" "$(items_of split "$pos")" "split $pos"
  done
  done_it

  it "item.lua hands plugin.sh its palette colours and shape (I.bundle, V14)"
  out=$("$LUA_BIN" "$SANDBOX/lua/probe.lua" pill right "$BUNDLE/item.lua" 2>&1)
  assert_contains "$out" "exec STM_GREEN='0x00000001' STM_YELLOW='0x00000002' STM_RED='0x00000003' STM_BAT_SHAPE='pill' NAME='stm.battery' SENDER='forced' '/p/battery.sh'"
  done_it
elif [ -n "${CI:-}" ]; then
  it "lua is available to run item.lua"
  _note_fail "lua not found; CI must run item.lua"
  done_it
else
  printf '# note: lua not found, item.lua not run\n'
fi

finish
