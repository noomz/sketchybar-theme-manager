#!/usr/bin/env bash
#
# bundles/items/cpu (#21). Runs plugin.sh as SketchyBar would, against a fake
# `iostat` (canned output) and a fake `sketchybar` that logs its argv one per
# line; then runs item.lua under Lua with a fake `sbar`. Never touches the
# real iostat or the real bar.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

BUNDLE="$REPO_ROOT/bundles/items/cpu"
PLUGIN="$BUNDLE/plugin.sh"
SB_LOG="$SANDBOX/sketchybar.argv"

# Distinct palette colours so every colour names its source.
GREEN=0xff11aa22
YELLOW=0xffcccc00
ORANGE=0xffee7700
RED=0xffaa0000
GREY=0xff808080

# nf-oct-cpu (bash 3.2 printf has no \U).
CPU=$(printf '\357\222\274')

FAKE_BIN="$SANDBOX/cpu-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/sketchybar" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >>"$SB_LOG"
EOF
# Fake iostat: prints $IOSTAT_OUT; every call is logged with its argv.
cat >"$SANDBOX/iostat" <<'EOF'
#!/bin/sh
printf 'iostat %s\n' "$*" >>"$SB_LOG.calls"
printf '%s\n' "$IOSTAT_OUT"
EOF
chmod 755 "$FAKE_BIN/sketchybar" "$SANDBOX/iostat"

# sample <us> <sy> — `iostat -n0 -c 2 -w 1`: the boot average, then the
# one-second sample the load comes from.
sample() {
  printf '      cpu    load average\n us sy id   1m   5m   15m\n  3  2 95  6.04 6.01 6.64\n %2s %2s %2s  5.79 5.96 6.62' \
    "$1" "$2" 50
}

SB=""
CALLS=""
# run_plugin <iostat out> [VAR=value...] — argv sketchybar got lands in $SB,
# the tool calls made in $CALLS.
run_plugin() {
  local out="$1"
  shift
  rm -f "$SB_LOG" "$SB_LOG.calls"
  env -i HOME="$HOME" PATH="$FAKE_BIN:/bin" SB_LOG="$SB_LOG" \
    NAME=stm.cpu SENDER=routine STM_IOSTAT="$SANDBOX/iostat" IOSTAT_OUT="$out" \
    STM_GREEN=$GREEN STM_YELLOW=$YELLOW STM_ORANGE=$ORANGE STM_RED=$RED STM_GREY=$GREY \
    STM_CPU_CW=7.93 STM_CPU_PAD=12 "$@" /bin/sh "$PLUGIN" >/dev/null 2>&1
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

it "load = us + sy of the last sample; graph coloured by band (I.cpu, V45)"
# load push width colour: every band edge.
while read -r us sy load push width color; do
  run_plugin "$(sample "$us" "$sy")"
  assert_eq "$(argv_of --push stm.cpu "$push" --set stm.cpu "label=$load%" "label.width=$width" \
    "graph.color=${!color}" "graph.fill_color=$(fill "${!color}")")" "$SB" "load $load"
done <<'EOF'
0 0 0 0.00 28 GREEN
20 9 29 0.29 36 GREEN
20 10 30 0.30 36 YELLOW
50 9 59 0.59 36 YELLOW
50 10 60 0.60 36 ORANGE
70 9 79 0.79 36 ORANGE
70 10 80 0.80 36 RED
90 10 100 1.00 44 RED
EOF
assert_eq "iostat -n0 -c 2 -w 1" "$CALLS" "one iostat run, two samples a second apart"
done_it

it "a load over 100 is clamped (V44)"
run_plugin "$(sample 80 40)"
assert_eq "$(argv_of --push stm.cpu 1.00 --set stm.cpu label=100% label.width=44 \
  "graph.color=$RED" "graph.fill_color=$(fill $RED)")" "$SB" "120 -> 100"
done_it

it "malformed or missing iostat output: --, grey, nothing pushed (V44)"
for out in "" "garbage" "$(sample x 2)" "$(sample 3 -1)" "$(printf '%s\n 7' "$(sample 1 1)")" \
  "$(printf '%s\n 1;x 2 3' "$(sample 1 1)")"; do
  run_plugin "$out"
  assert_eq "$(argv_of --set stm.cpu label=-- label.width=28 "graph.color=$GREY" \
    "graph.fill_color=$(fill $GREY)")" "$SB" "output [$out]"
done
run_plugin "$(sample 20 10)" STM_IOSTAT="$SANDBOX/no-such-iostat"
assert_eq "$(argv_of --set stm.cpu label=-- label.width=28 "graph.color=$GREY" \
  "graph.fill_color=$(fill $GREY)")" "$SB" "iostat absent"
done_it

it "label width: pad + ceil(chars x CW); unknown font sends none (V46)"
run_plugin "$(sample 3 2)" STM_CPU_CW=8.54 STM_CPU_PAD=10
assert_eq "$(argv_of --push stm.cpu 0.05 --set stm.cpu label=5% label.width=28 \
  "graph.color=$GREEN" "graph.fill_color=$(fill $GREEN)")" "$SB" "2 chars at 14pt"
run_plugin "$(sample 3 2)" STM_CPU_CW= STM_CPU_PAD=
assert_eq "$(argv_of --push stm.cpu 0.05 --set stm.cpu label=5% \
  "graph.color=$GREEN" "graph.fill_color=$(fill $GREEN)")" "$SB" "no width without a font size"
run_plugin "$(sample 3 2)" STM_CPU_CW='8;x' STM_CPU_PAD=12
assert_eq "$(argv_of --push stm.cpu 0.05 --set stm.cpu label=5% \
  "graph.color=$GREEN" "graph.fill_color=$(fill $GREEN)")" "$SB" "no width from a bad CW"
done_it

it "a palette without the band colour sends no empty colour (V14)"
run_plugin "$(sample 20 20)" STM_YELLOW=
assert_eq "$(argv_of --push stm.cpu 0.40 --set stm.cpu label=40% label.width=36)" "$SB" "no yellow"
done_it

it "lint and install item:cpu (V4, I.fs, I.cfg)"
STM_ROOT="$REPO_ROOT" run_stm --porcelain lint item:cpu
assert_status 0
assert_eq "ok	item:cpu" "$STM_OUT"
D="$SANDBOX/cfg"
make_lua_config "$D"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install item:cpu
assert_status 0
assert_files_equal "$PLUGIN" "$D/plugins/stm/cpu.sh"
assert_eq "-rwxr-xr-x" "$(stat -f %Sp "$D/plugins/stm/cpu.sh")" "plugin mode"
loader=$(cat "$D/items_generated.lua")
for opt in '["shape"] = "split"' 'update_freq = 2,' 'events = { "system_woke" },' 'position = "right"'; do
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
-- query: "ok" answers every query, "late" only from the second on, "none"
-- never.
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
local sbar, handler, queries = {}, nil, 0
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
  queries = queries + 1
  print("query " .. name)
  if query == "none" or (query == "late" and queries == 1) then
    return nil
  end
  return { label = { font = "Hack Nerd Font:Bold:13.00", padding_left = 6, padding_right = 6 } }
end
function sbar.exec(cmd) print("exec " .. cmd) end
local opts = { name = "stm.cpu", position = position, update_freq = 2,
  plugin_dir = "/p", events = { "system_woke" }, options = { shape = shape } }
dofile(item_lua)(sbar, opts, { orange = 0xff336699, green = 0x7f112233, yellow = 4, red = 5, grey = 0xff445566,
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

  it "item.lua plain and pill: one graph item 30 wide, orange icon, pill on bg1 (I.cpu, V32, V14)"
  assert_eq "graph stm.cpu 30 {$GRAPH icon={color=4281558681 string=$CPU} $LABEL position=right update_freq=2}" \
    "$(items_of plain right)" "plain"
  assert_eq "graph stm.cpu 30 {background={color=21 drawing=true} $GRAPH icon={color=4281558681 string=$CPU} $LABEL position=left update_freq=2}" \
    "$(items_of pill left)" "pill"
  done_it

  it "item.lua split: orange icon sub-item left of the graph at every position (V32, V33, V10)"
  main() {
    printf 'graph stm.cpu 30 {background={color=21 drawing=true padding_left=0} %s icon={drawing=false} %s position=%s update_freq=2}' \
      "$GRAPH" "$LABEL" "$1"
  }
  sub() {
    printf 'item stm.cpu.icon {background={color=4281558681 drawing=true} icon={color=22 string=%s} label={drawing=false} position=%s}' \
      "$CPU" "$1"
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
  run="exec STM_GREEN='0x7f112233' STM_YELLOW='0x00000004' STM_ORANGE='0xff336699' STM_RED='0x00000005' STM_GREY='0xff445566' STM_CPU_CW='7.93' STM_CPU_PAD='12' NAME='stm.cpu'"
  assert_eq "query stm.cpu
$run SENDER='forced' '/p/cpu.sh'
$run SENDER='routine' '/p/cpu.sh'" "$(printf '%s\n' "$out" | grep -E '^(query|exec) ')" "queried once, metrics on every run"
  done_it

  it "item.lua asks again until the bar answers, and never guesses a width (V46)"
  late="exec STM_GREEN='0x7f112233' STM_YELLOW='0x00000004' STM_ORANGE='0xff336699' STM_RED='0x00000005' STM_GREY='0xff445566'"
  assert_eq "query stm.cpu
$late STM_CPU_CW='' STM_CPU_PAD='' NAME='stm.cpu' SENDER='forced' '/p/cpu.sh'
query stm.cpu
$late STM_CPU_CW='7.93' STM_CPU_PAD='12' NAME='stm.cpu' SENDER='routine' '/p/cpu.sh'" \
    "$(probe plain right late | grep -E '^(query|exec) ')" "late answer"
  assert_not_contains "$(probe plain right none)" "STM_CPU_CW='7" "no answer, no width"
  done_it
elif [ -n "${CI:-}" ]; then
  it "lua is available to run item.lua"
  _note_fail "lua not found; CI must run item.lua"
  done_it
else
  printf '# note: lua not found, item.lua not run\n'
fi

finish
