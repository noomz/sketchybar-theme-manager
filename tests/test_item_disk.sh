#!/usr/bin/env bash
#
# bundles/items/disk (#21). Runs plugin.sh as SketchyBar would, against a
# fake `df` (canned output) and a fake `sketchybar` that logs its argv one
# per line; then runs item.lua under Lua with a fake `sbar`. Never touches
# the real df or the real bar.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

BUNDLE="$REPO_ROOT/bundles/items/disk"
PLUGIN="$BUNDLE/plugin.sh"
SB_LOG="$SANDBOX/sketchybar.argv"

# Distinct palette colours so every colour names its source.
GREEN=0xff11aa22
YELLOW=0xffcccc00
RED=0xffaa0000
GREY=0xff808080

# nf-md-harddisk (bash 3.2 printf has no \U).
DISK=$(printf '\363\260\213\212')

FAKE_BIN="$SANDBOX/disk-bin"
DATA="$SANDBOX/Data"
mkdir -p "$FAKE_BIN" "$DATA"
cat >"$FAKE_BIN/sketchybar" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >>"$SB_LOG"
EOF
# Fake df: prints $DF_OUT; every call is logged with its argv.
cat >"$SANDBOX/df" <<'EOF'
#!/bin/sh
printf 'df %s\n' "$*" >>"$SB_LOG.calls"
printf '%s\n' "$DF_OUT"
EOF
chmod 755 "$FAKE_BIN/sketchybar" "$SANDBOX/df"

# used <capacity> — `df -k <vol>` at that capacity (%iused 0%).
used() {
  printf 'Filesystem   1024-blocks      Used Available Capacity  iused      ifree %%iused  Mounted on\n/dev/disk3s5   971350180 627337944 305637736    %s 10606218 3056377360    0%%   /System/Volumes/Data' "$1"
}

SB=""
CALLS=""
# run_plugin <df out> [VAR=value...] — argv sketchybar got lands in $SB, the
# tool calls made in $CALLS.
run_plugin() {
  local out="$1"
  shift
  rm -f "$SB_LOG" "$SB_LOG.calls"
  env -i HOME="$HOME" PATH="$FAKE_BIN:/bin" SB_LOG="$SB_LOG" \
    NAME=stm.disk SENDER=routine STM_DF="$SANDBOX/df" STM_DATA_VOLUME="$DATA" DF_OUT="$out" \
    STM_GREEN=$GREEN STM_YELLOW=$YELLOW STM_RED=$RED STM_GREY=$GREY \
    STM_DISK_CW=7.93 STM_DISK_PAD=12 "$@" /bin/sh "$PLUGIN" >/dev/null 2>&1
  SB=$(cat "$SB_LOG" 2>/dev/null || true)
  CALLS=$(cat "$SB_LOG.calls" 2>/dev/null || true)
}

argv_of() {
  printf '%s\n' "$@"
}

it "capacity coloured by band on the icon, plain and pill (I.disk, V45, V32)"
while read -r cap width color; do
  for shape in plain pill; do
    run_plugin "$(used "$cap")" STM_DISK_SHAPE=$shape
    assert_eq "$(argv_of --set stm.disk "label=$cap" "label.width=$width" "icon.color=${!color}")" \
      "$SB" "$cap $shape"
  done
done <<'EOF'
0% 28 GREEN
79% 36 GREEN
80% 36 YELLOW
89% 36 YELLOW
90% 36 RED
100% 44 RED
EOF
assert_eq "df -k $DATA" "$CALLS" "one df, on the Data volume"
done_it

it "split: state colour on the icon sub-item (V32, V10)"
run_plugin "$(used 85%)" STM_DISK_SHAPE=split
assert_eq "$(argv_of --set stm.disk label=85% label.width=36 --set stm.disk.icon "background.color=$YELLOW")" \
  "$SB" "split"
run_plugin "garbage" STM_DISK_SHAPE=split
assert_eq "$(argv_of --set stm.disk label=-- label.width=28 --set stm.disk.icon "background.color=$GREY")" \
  "$SB" "split unknown"
done_it

it "no Data volume: df /, as before macOS 10.15 (I.disk)"
run_plugin "$(used 42%)" STM_DISK_SHAPE=plain STM_DATA_VOLUME="$SANDBOX/no-such-volume"
assert_eq "$(argv_of --set stm.disk label=42% label.width=36 "icon.color=$GREEN")" "$SB" "/"
assert_eq "df -k /" "$CALLS" "df on /"
done_it

it "malformed or missing df output: --, grey (V44)"
for out in "" garbage "$(used 101%)" "$(used x%)" "$(used 5)" "$(printf 'Filesystem Capacity\n/dev/x -3%% /')"; do
  run_plugin "$out" STM_DISK_SHAPE=plain
  assert_eq "$(argv_of --set stm.disk label=-- label.width=28 "icon.color=$GREY")" "$SB" "output [$out]"
done
run_plugin "$(used 42%)" STM_DISK_SHAPE=plain STM_DF="$SANDBOX/no-such-df"
assert_eq "$(argv_of --set stm.disk label=-- label.width=28 "icon.color=$GREY")" "$SB" "df absent"
done_it

it "label width: unknown font sends none; a palette without the colour sends none (V46, V14)"
run_plugin "$(used 42%)" STM_DISK_SHAPE=plain STM_DISK_CW= STM_DISK_PAD=
assert_eq "$(argv_of --set stm.disk label=42% "icon.color=$GREEN")" "$SB" "no width"
run_plugin "$(used 42%)" STM_DISK_SHAPE=split STM_GREEN=
assert_eq "$(argv_of --set stm.disk label=42% label.width=36)" "$SB" "no green"
done_it

it "lint and install item:disk (V4, I.fs, I.cfg)"
STM_ROOT="$REPO_ROOT" run_stm --porcelain lint item:disk
assert_status 0
assert_eq "ok	item:disk" "$STM_OUT"
D="$SANDBOX/cfg"
make_lua_config "$D"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install item:disk
assert_status 0
assert_files_equal "$PLUGIN" "$D/plugins/stm/disk.sh"
assert_eq "-rwxr-xr-x" "$(stat -f %Sp "$D/plugins/stm/disk.sh")" "plugin mode"
loader=$(cat "$D/items_generated.lua")
for opt in '["shape"] = "split"' 'update_freq = 60,' 'events = { "system_woke" },' 'position = "right"'; do
  assert_contains "$loader" "$opt"
done
done_it

LUA_BIN=$(command -v lua 2>/dev/null || true)
if [ -n "$LUA_BIN" ]; then
  mkdir -p "$SANDBOX/lua"
  cat >"$SANDBOX/lua/probe.lua" <<'EOF'
-- Runs item.lua with one shape and position; prints each item it adds, in
-- order, with its props flattened (keys sorted), each query, the events it
-- subscribes to and each plugin command.
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
  return {
    subscribe = function(_, events) print("subscribe " .. table.concat(events, " ")) end,
    set = function() end,
  }
end
function sbar.query(name)
  print("query " .. name)
  return { label = { font = "Hack Nerd Font:Bold:13.00", padding_left = 6, padding_right = 6 } }
end
function sbar.exec(cmd) print("exec " .. cmd) end
local opts = { name = "stm.disk", position = position, update_freq = 60,
  plugin_dir = "/p", events = { "system_woke" }, options = { shape = shape } }
dofile(item_lua)(sbar, opts, { green = 1, yellow = 2, red = 3, grey = 4, bg1 = 21, black = 22 })
EOF
  items_of() {
    "$LUA_BIN" "$SANDBOX/lua/probe.lua" "$1" "$2" "$BUNDLE/item.lua" 2>&1 | grep '^item '
  }

  it "item.lua plain and pill: one item, grey until plugin.sh reads df (V32, V14)"
  assert_eq "item stm.disk {icon={color=4 string=$DISK} label={string=--} position=right update_freq=60}" \
    "$(items_of plain right)" "plain"
  assert_eq "item stm.disk {background={color=21 drawing=true} icon={color=4 string=$DISK} label={string=--} position=left update_freq=60}" \
    "$(items_of pill left)" "pill"
  done_it

  it "item.lua split: icon sub-item left of the label at every position (V32, V33, V10)"
  main() {
    printf 'item stm.disk {background={color=21 drawing=true padding_left=0} icon={drawing=false} label={string=--} position=%s update_freq=60}' "$1"
  }
  sub() {
    printf 'item stm.disk.icon {background={color=4 drawing=true} icon={color=22 string=%s} label={drawing=false} position=%s}' \
      "$DISK" "$1"
  }
  assert_eq "$(main right)
$(sub right)" "$(items_of split right)" "split right"
  for pos in left center; do
    assert_eq "$(sub "$pos")
$(main "$pos")" "$(items_of split "$pos")" "split $pos"
  done
  done_it

  it "item.lua hands plugin.sh its colours, shape and label metrics (I.bundle, V14, V46)"
  out=$("$LUA_BIN" "$SANDBOX/lua/probe.lua" pill right "$BUNDLE/item.lua" 2>&1)
  assert_contains "$out" "subscribe routine forced system_woke"
  assert_contains "$out" "query stm.disk"
  assert_contains "$out" "exec STM_GREEN='0x00000001' STM_YELLOW='0x00000002' STM_RED='0x00000003' STM_GREY='0x00000004' STM_DISK_SHAPE='pill' STM_DISK_CW='7.93' STM_DISK_PAD='12' NAME='stm.disk' SENDER='forced' '/p/disk.sh'"
  done_it
elif [ -n "${CI:-}" ]; then
  it "lua is available to run item.lua"
  _note_fail "lua not found; CI must run item.lua"
  done_it
else
  printf '# note: lua not found, item.lua not run\n'
fi

finish
