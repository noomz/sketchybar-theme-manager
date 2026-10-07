#!/usr/bin/env bash
#
# bundles/items/mem (#21). Runs plugin.sh as SketchyBar would, against a fake
# `memory_pressure` and `sysctl` (canned output) and a fake `sketchybar`
# that logs its argv one per line; then runs item.lua under Lua with a fake
# `sbar`. Never touches the real tools or the real bar.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

BUNDLE="$REPO_ROOT/bundles/items/mem"
PLUGIN="$BUNDLE/plugin.sh"
SB_LOG="$SANDBOX/sketchybar.argv"

# Distinct palette colours so every colour names its source.
GREEN=0xff11aa22
YELLOW=0xffcccc00
RED=0xffaa0000
GREY=0xff808080

# nf-fa-memory, a RAM stick (bash 3.2 printf has no \U).
MEM=$(printf '\356\277\205')

FAKE_BIN="$SANDBOX/mem-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/sketchybar" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >>"$SB_LOG"
EOF
# Fakes print $MP_OUT and $SYSCTL_OUT; every call is logged with its argv.
cat >"$SANDBOX/memory_pressure" <<'EOF'
#!/bin/sh
printf 'memory_pressure %s\n' "$*" >>"$SB_LOG.calls"
printf '%s\n' "$MP_OUT"
EOF
cat >"$SANDBOX/sysctl" <<'EOF'
#!/bin/sh
printf 'sysctl %s\n' "$*" >>"$SB_LOG.calls"
printf '%s\n' "$SYSCTL_OUT"
EOF
chmod 755 "$FAKE_BIN/sketchybar" "$SANDBOX/memory_pressure" "$SANDBOX/sysctl"

# free <n> — `memory_pressure -Q` with that free percentage.
free() {
  printf 'The system has 38654705664 (2359296 pages with a page size of 16384).\nSystem-wide memory free percentage: %s' "$1"
}

SB=""
CALLS=""
# run_plugin <memory_pressure out> <sysctl out> [VAR=value...] — argv
# sketchybar got lands in $SB, the tool calls made in $CALLS.
run_plugin() {
  local m="$1" s="$2"
  shift 2
  rm -f "$SB_LOG" "$SB_LOG.calls"
  env -i HOME="$HOME" PATH="$FAKE_BIN:/bin" SB_LOG="$SB_LOG" \
    NAME=stm.mem SENDER=routine STM_MEMORY_PRESSURE="$SANDBOX/memory_pressure" STM_SYSCTL="$SANDBOX/sysctl" \
    MP_OUT="$m" SYSCTL_OUT="$s" STM_GREEN=$GREEN STM_YELLOW=$YELLOW STM_RED=$RED STM_GREY=$GREY \
    STM_MEM_CW=7.93 STM_MEM_PAD=12 "$@" /bin/sh "$PLUGIN" >/dev/null 2>&1
  SB=$(cat "$SB_LOG" 2>/dev/null || true)
  CALLS=$(cat "$SB_LOG.calls" 2>/dev/null || true)
}

argv_of() {
  printf '%s\n' "$@"
}

# fill <colour> — the same colour at alpha 0x40.
fill() {
  printf '0x40%s' "${1#0x??}"
}

it "in use = 100 - free; graph coloured by pressure level (I.mem, V45)"
while read -r out level used push width color; do
  run_plugin "$(free "$out")" "$level"
  assert_eq "$(argv_of --push stm.mem "$push" --set stm.mem "label=$used%" "label.width=$width" \
    "graph.color=${!color}" "graph.fill_color=$(fill "${!color}")")" "$SB" "free $out, level $level"
done <<'EOF'
53% 1 47 0.47 36 GREEN
100% 1 0 0.00 28 GREEN
91% 2 9 0.09 28 YELLOW
0% 4 100 1.00 44 RED
40% 0 60 0.60 36 GREY
40% 3 60 0.60 36 GREY
40% 8 60 0.60 36 GREY
40% 1x 60 0.60 36 GREY
EOF
assert_eq "$(argv_of 'memory_pressure -Q' 'sysctl -n kern.memorystatus_vm_pressure_level')" "$CALLS" \
  "one memory_pressure, one sysctl"
done_it

it "unreadable sysctl: grey (V44)"
run_plugin "$(free 53%)" ""
assert_eq "$(argv_of --push stm.mem 0.47 --set stm.mem label=47% label.width=36 \
  "graph.color=$GREY" "graph.fill_color=$(fill $GREY)")" "$SB" "empty"
run_plugin "$(free 53%)" 1 STM_SYSCTL="$SANDBOX/no-such-sysctl"
assert_eq "$(argv_of --push stm.mem 0.47 --set stm.mem label=47% label.width=36 \
  "graph.color=$GREY" "graph.fill_color=$(fill $GREY)")" "$SB" "absent"
done_it

it "malformed or missing memory_pressure output: --, nothing pushed, level colour kept (V44)"
for out in "" garbage "$(free 101%)" "$(free -3%)" "$(free 5x%)" "$(free '%')" "$(free '4 2%')"; do
  run_plugin "$out" 2
  assert_eq "$(argv_of --set stm.mem label=-- label.width=28 "graph.color=$YELLOW" \
    "graph.fill_color=$(fill $YELLOW)")" "$SB" "output [$out]"
done
run_plugin "$(free 53%)" 2 STM_MEMORY_PRESSURE="$SANDBOX/no-such-tool"
assert_eq "$(argv_of --set stm.mem label=-- label.width=28 "graph.color=$YELLOW" \
  "graph.fill_color=$(fill $YELLOW)")" "$SB" "memory_pressure absent"
done_it

it "label width: pad + ceil(chars x CW); unknown font sends none (V46)"
run_plugin "$(free 53%)" 1 STM_MEM_CW=8.54 STM_MEM_PAD=10
assert_eq "$(argv_of --push stm.mem 0.47 --set stm.mem label=47% label.width=36 \
  "graph.color=$GREEN" "graph.fill_color=$(fill $GREEN)")" "$SB" "3 chars at 14pt"
run_plugin "$(free 53%)" 1 STM_MEM_CW= STM_MEM_PAD=
assert_eq "$(argv_of --push stm.mem 0.47 --set stm.mem label=47% \
  "graph.color=$GREEN" "graph.fill_color=$(fill $GREEN)")" "$SB" "no width without a font size"
done_it

it "a palette without the level colour sends no empty colour (V14)"
run_plugin "$(free 53%)" 4 STM_RED=
assert_eq "$(argv_of --push stm.mem 0.47 --set stm.mem label=47% label.width=36)" "$SB" "no red"
done_it

it "lint and install item:mem (V4, I.fs, I.cfg)"
STM_ROOT="$REPO_ROOT" run_stm --porcelain lint item:mem
assert_status 0
assert_eq "ok	item:mem" "$STM_OUT"
D="$SANDBOX/cfg"
make_lua_config "$D"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install item:mem
assert_status 0
assert_files_equal "$PLUGIN" "$D/plugins/stm/mem.sh"
assert_eq "-rwxr-xr-x" "$(stat -f %Sp "$D/plugins/stm/mem.sh")" "plugin mode"
loader=$(cat "$D/items_generated.lua")
for opt in '["shape"] = "split"' 'update_freq = 5,' 'events = { "system_woke" },' 'position = "right"'; do
  assert_contains "$loader" "$opt"
done
done_it

LUA_BIN=$(command -v lua 2>/dev/null || true)
if [ -n "$LUA_BIN" ]; then
  mkdir -p "$SANDBOX/lua"
  cat >"$SANDBOX/lua/probe.lua" <<'EOF'
-- Runs item.lua with one shape and position; prints each item it adds, in
-- order, with its props flattened (keys sorted), each query, the events it
-- subscribes to and each plugin command. Then fires one routine event.
-- query: "ok" answers every query, "none" never.
local shape, position, query, item_lua = ...
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
local sbar, handler = {}, nil
function sbar.add(kind, name, a, b)
  if type(a) == "table" then
    print(kind .. " " .. name .. " " .. dump(a))
  else
    print(kind .. " " .. name .. " " .. tostring(a) .. " " .. dump(b))
  end
  return {
    name = name,
    subscribe = function(_, events, fn)
      print("subscribe " .. table.concat(events, " "))
      handler = fn
    end,
    set = function() end,
  }
end
function sbar.query(name)
  print("query " .. name)
  if query == "none" then
    return nil
  end
  return { label = { font = "Menlo:Regular:12.00", padding_left = 4, padding_right = 5 } }
end
function sbar.exec(cmd) print("exec " .. cmd) end
local opts = { name = "stm.mem", position = position, update_freq = 5,
  plugin_dir = "/p", events = { "system_woke" }, options = { shape = shape } }
dofile(item_lua)(sbar, opts, { blue = 0xff336699, green = 0x7f112233, yellow = 4, red = 5, grey = 0xff445566,
  bg1 = 21, black = 22 })
handler({ SENDER = "routine" })
EOF
  probe() {
    "$LUA_BIN" "$SANDBOX/lua/probe.lua" "$1" "$2" "$3" "$BUNDLE/item.lua" 2>&1
  }
  items_of() {
    probe "$1" "$2" ok | grep -E '^(item|graph) '
  }
  # The initial graph: grey line, grey at alpha 0x40 under it.
  GRAPH='graph={color=4282668390 fill_color=1078220134 line_width=1.0}'
  LABEL='label={string=--}'

  it "item.lua plain and pill: one graph item 30 wide, blue icon, pill on bg1 (I.mem, V32, V14)"
  assert_eq "graph stm.mem 30 {$GRAPH icon={color=4281558681 string=$MEM} $LABEL position=right update_freq=5}" \
    "$(items_of plain right)" "plain"
  assert_eq "graph stm.mem 30 {background={color=21 drawing=true} $GRAPH icon={color=4281558681 string=$MEM} $LABEL position=left update_freq=5}" \
    "$(items_of pill left)" "pill"
  done_it

  it "item.lua split: blue icon sub-item left of the graph at every position (V32, V33, V10)"
  main() {
    printf 'graph stm.mem 30 {background={color=21 drawing=true padding_left=0} %s icon={drawing=false} %s position=%s update_freq=5}' \
      "$GRAPH" "$LABEL" "$1"
  }
  sub() {
    printf 'item stm.mem.icon {background={color=4281558681 drawing=true} icon={color=22 string=%s} label={drawing=false} position=%s}' \
      "$MEM" "$1"
  }
  assert_eq "$(main right)
$(sub right)" "$(items_of split right)" "split right"
  for pos in left center; do
    assert_eq "$(sub "$pos")
$(main "$pos")" "$(items_of split "$pos")" "split $pos"
  done
  done_it

  it "item.lua hands plugin.sh its colours and the label metrics from its own query (V14, V46)"
  out=$(probe split right ok)
  assert_contains "$out" "subscribe routine forced system_woke"
  run="exec STM_GREEN='0x7f112233' STM_YELLOW='0x00000004' STM_RED='0x00000005' STM_GREY='0xff445566' STM_MEM_CW='7.32' STM_MEM_PAD='9' NAME='stm.mem'"
  assert_eq "query stm.mem
$run SENDER='forced' '/p/mem.sh'
$run SENDER='routine' '/p/mem.sh'" "$(printf '%s\n' "$out" | grep -E '^(query|exec) ')" "queried once, metrics on every run"
  assert_contains "$(probe plain right none)" "STM_MEM_CW='' STM_MEM_PAD=''" "no answer, no width"
  done_it
elif [ -n "${CI:-}" ]; then
  it "lua is available to run item.lua"
  _note_fail "lua not found; CI must run item.lua"
  done_it
else
  printf '# note: lua not found, item.lua not run\n'
fi

finish
