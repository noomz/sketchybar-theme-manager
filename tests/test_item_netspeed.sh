#!/usr/bin/env bash

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

BUNDLE="$REPO_ROOT/bundles/items/netspeed"
PLUGIN="$BUNDLE/plugin.sh"
SB_LOG="$SANDBOX/sketchybar.argv"

# bash 3.2 printf has no \U: the arrows, nf-md-swap_vertical, nf-md-download,
# nf-md-upload.
UP=$(printf '\342\206\221')
DOWN=$(printf '\342\206\223')
SWAP=$(printf '\363\260\233\263')
DL=$(printf '\363\260\207\232')
UL=$(printf '\363\260\225\222')

FAKE_BIN="$SANDBOX/ns-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/sketchybar" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >>"$SB_LOG"
EOF
cat >"$SANDBOX/scutil" <<'EOF'
#!/bin/sh
printf 'scutil\n' >>"$SB_LOG.calls"
[ "$(cat)" = "show State:/Network/Global/IPv4
show State:/Network/Global/IPv6" ] || exit 64
printf '%s\n' "$SCUTIL_OUT"
EOF
cat >"$SANDBOX/netstat" <<'EOF'
#!/bin/sh
printf 'netstat %s\n' "$*" >>"$SB_LOG.calls"
if [ -f "$SB_LOG.second" ]; then
  printf '%s\n' "$NETSTAT_AFTER"
else
  : >"$SB_LOG.second"
  printf '%s\n' "$NETSTAT_BEFORE"
fi
EOF
cat >"$SANDBOX/sleep" <<'EOF'
#!/bin/sh
printf 'sleep %s\n' "$*" >>"$SB_LOG.calls"
EOF
chmod 755 "$FAKE_BIN/sketchybar" "$SANDBOX/scutil" "$SANDBOX/netstat" "$SANDBOX/sleep"

primary() {
  printf '<dictionary> {\n  PrimaryInterface : %s\n}\n<dictionary> {\n  PrimaryInterface : %s\n}' "$1" "$1"
}
OFFLINE=$(printf '  No such key\n  No such key')
link() {
  printf 'Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll\n'
  printf '%-5s 1500  <Link#14>   02:00:00:00:00:00 47977465     0 %s 22638185     0 %s     0\n' "$1" "$2" "$3"
  printf '%-5s 1500  192.168.101   192.168.101.55  47977465     - 99999999999 22638185     - 99999999999     -' "$1"
}
tunnel() {
  printf 'Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll\n'
  printf '%-5s 1280  <Link#23>                       497640     0 %s   514379     0 %s     0\n' "$1" "$2" "$3"
  printf '%-5s 1280  100.105.87.87 100.105.87.87     497640     -  234807962   514379     -   56252168     -' "$1"
}

SB_ARGV=""
TOOL_CALLS=""
run_plugin() {
  local s="$1" b="$2" a="$3"
  shift 3
  rm -f "$SB_LOG" "$SB_LOG.calls" "$SB_LOG.second"
  env -i HOME="$HOME" PATH="$FAKE_BIN:/bin" SB_LOG="$SB_LOG" \
    NAME=stm.netspeed SENDER=routine STM_SCUTIL="$SANDBOX/scutil" STM_NETSTAT="$SANDBOX/netstat" \
    STM_SLEEP="$SANDBOX/sleep" SCUTIL_OUT="$s" NETSTAT_BEFORE="$b" NETSTAT_AFTER="$a" \
    STM_NS_VIEW=separate STM_NS_CW=6.10 STM_NS_PAD=6 "$@" /bin/sh "$PLUGIN" >/dev/null 2>&1
  SB_ARGV=$(cat "$SB_LOG" 2>/dev/null || true)
  TOOL_CALLS=$(cat "$SB_LOG.calls" 2>/dev/null || true)
}

argv_of() {
  printf '%s\n' "$@"
}

separate() {
  argv_of --push stm.netspeed "$1" --push stm.netspeed.up "$2" \
    --set stm.netspeed "label=$3" "label.width=$4" --set stm.netspeed.up "label=$5" "label.width=$6"
}

it "rates over one second, from the <Link#> row; one scutil, two netstat, one sleep (I.ns, V44)"
run_plugin "$(primary en0)" "$(link en0 50376381282 16272668862)" "$(link en0 50376437282 16272671862)"
assert_eq "$(separate 0.594 0.435 56K 25 3K 19)" "$SB_ARGV" "56000 down, 3000 up"
assert_eq "$(argv_of scutil 'netstat -ibn -I en0' 'sleep 1' 'netstat -ibn -I en0')" "$TOOL_CALLS" "calls"
done_it

it "a tunnel row has no Address column: counters are read from the right (I.ns)"
run_plugin "$(primary utun4)" "$(tunnel utun4 234807962 56252168)" "$(tunnel utun4 234808961 56252177)"
assert_eq "$(separate 0.375 0.125 999B 31 9B 19)" "$SB_ARGV" "utun4"
done_it

it "units in base 1000, at most four characters; graph log scale capped at 1 (I.ns)"
while read -r bytes level text width; do
  run_plugin "$(primary en0)" "$(link en0 1000 0)" "$(link en0 $((1000 + bytes)) 0)"
  assert_eq "$(separate "$level" 0.000 "$text" "$width" 0B 19)" "$SB_ARGV" "$bytes bytes"
done <<'EOF'
0 0.000 0B 19
999 0.375 999B 31
1000 0.375 1K 19
999999 0.750 999K 31
1000000 0.750 1M 19
99999999 1.000 99M 25
999999999 1.000 999M 31
1000000000 1.000 1G 19
12345678901 1.000 12G 25
EOF
done_it

it "a counter that went back or is missing is -- and 0, per direction (V44)"
run_plugin "$(primary en0)" "$(link en0 5000 9000)" "$(link en0 4000 9999)"
assert_eq "$(separate 0.000 0.375 -- 19 999B 31)" "$SB_ARGV" "download counter reset"
run_plugin "$(primary en0)" "$(link en0 5000 9000)" "$(link en0 5999 x)"
assert_eq "$(separate 0.375 0.000 999B 31 -- 19)" "$SB_ARGV" "upload counter not a number"
run_plugin "$(primary en0)" "$(link en0 5000 9000)" "Name Mtu Network"
assert_eq "$(separate 0.000 0.000 -- 19 -- 19)" "$SB_ARGV" "no <Link#> row the second time"
run_plugin "$(primary en0)" "" "" STM_NETSTAT="$SANDBOX/no-such-netstat"
assert_eq "$(separate 0.000 0.000 -- 19 -- 19)" "$SB_ARGV" "netstat absent"
done_it

it "offline or a malformed interface name: no netstat, no sleep, -- (V40, V44)"
run_plugin "$OFFLINE" "$(link en0 1 1)" "$(link en0 9 9)"
assert_eq "$(separate 0.000 0.000 -- 19 -- 19)" "$SB_ARGV" "offline"
assert_eq scutil "$TOOL_CALLS" "offline calls"
for dev in 'en0;touch x' 'EN0' '../en0' '-h' "$(printf '\303\2510')"; do
  for loc in C en_US.UTF-8; do
    run_plugin "$(primary "$dev")" "$(link en0 1 1)" "$(link en0 9 9)" LANG="$loc" LC_ALL="$loc"
    assert_eq "$(separate 0.000 0.000 -- 19 -- 19)" "$SB_ARGV" "$dev ($loc)"
    assert_eq scutil "$TOOL_CALLS" "$dev calls ($loc)"
  done
done
done_it

it "unified: both rates on the stacked text item, as wide as the longer line (V47, V46)"
run_plugin "$(primary en0)" "$(link en0 0 0)" "$(link en0 1000 999999)" STM_NS_VIEW=unified
assert_eq "$(argv_of --push stm.netspeed 0.375 --push stm.netspeed.up 0.750 \
  --set stm.netspeed.rates "icon=${UP}999K" "label=${DOWN}1K" label.width=37)" "$SB_ARGV" "unified"
run_plugin "$OFFLINE" "" "" STM_NS_VIEW=unified STM_NS_CW= STM_NS_PAD=
assert_eq "$(argv_of --push stm.netspeed 0.000 --push stm.netspeed.up 0.000 \
  --set stm.netspeed.rates "icon=${UP}--" "label=${DOWN}--")" "$SB_ARGV" "offline, no font yet"
done_it

it "lint and install item:netspeed; shape offers plain and pill only (V4, V32, I.fs, I.cfg)"
STM_ROOT="$REPO_ROOT" run_stm --porcelain lint item:netspeed
assert_status 0
assert_eq "ok	item:netspeed" "$STM_OUT"
D="$SANDBOX/cfg"
make_lua_config "$D"
printf '[item.netspeed]\nview = "separate"\n' >"$D/stm.config.toml"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install item:netspeed
assert_status 0
assert_files_equal "$PLUGIN" "$D/plugins/stm/netspeed.sh"
assert_eq "-rwxr-xr-x" "$(stat -f %Sp "$D/plugins/stm/netspeed.sh")" "plugin mode"
loader=$(cat "$D/items_generated.lua")
for opt in '["shape"] = "pill"' '["view"] = "separate"' 'update_freq = 2,' \
  'events = { "system_woke", "wifi_change" },' 'position = "right"'; do
  assert_contains "$loader" "$opt"
done
printf '[item.netspeed]\nshape = "split"\n' >"$D/stm.config.toml"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install --force item:netspeed
assert_ne 0 "$STM_STATUS" "split is not a netspeed shape"
done_it

LUA_BIN=$(command -v lua 2>/dev/null || true)
if [ -n "$LUA_BIN" ]; then
  mkdir -p "$SANDBOX/lua"
  cat >"$SANDBOX/lua/probe.lua" <<'EOF'
local shape, view, position, size, item_lua = ...
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
  if kind == "bracket" then
    print(kind .. " " .. name .. " " .. table.concat(a, ",") .. " " .. dump(b))
  elseif type(a) == "table" then
    print(kind .. " " .. name .. " " .. dump(a))
  else
    print(kind .. " " .. name .. " " .. tostring(a) .. " " .. dump(b))
  end
  return {
    name = name,
    subscribe = function(_, events, fn)
      print("subscribe " .. name .. " " .. table.concat(events, " "))
      handler = fn
    end,
    set = function(_, props) print("set " .. name .. " " .. dump(props)) end,
  }
end
function sbar.query(name)
  print("query " .. name)
  local pl = 6
  if name == "stm.netspeed.rates" then
    pl = 0
  end
  return { label = { font = "Hack Nerd Font:Bold:" .. size, padding_left = pl, padding_right = 5 } }
end
function sbar.exec(cmd) print("exec " .. cmd) end
local opts = { name = "stm.netspeed", position = position, update_freq = 2,
  plugin_dir = "/p", events = { "system_woke", "wifi_change" }, options = { shape = shape, view = view } }
dofile(item_lua)(sbar, opts, { blue = 0xff336699, magenta = 0x80aa00aa, bg1 = 21 })
handler({ SENDER = "routine" })
EOF
  probe() {
    "$LUA_BIN" "$SANDBOX/lua/probe.lua" "$1" "$2" "$3" "${4:-13.00}" "$BUNDLE/item.lua" 2>&1
  }
  names_of() {
    probe "$@" | awk '$1 == "item" || $1 == "graph" || $1 == "bracket" { print $1, $2 }'
  }
  line_of() {
    local n="$1"
    shift
    probe "$@" | awk -v n="$n" '($1 == "item" || $1 == "graph" || $1 == "bracket") && $2 == n'
  }
  BLUE=4281558681
  BLUE_SOFT=1077110425
  MAGENTA=2158624938
  MAGENTA_SOFT=1084883114

  it "item.lua unified: icon + download graph, upload graph, rates; same order left to right everywhere (V47, V10)"
  assert_eq "item stm.netspeed.rates
graph stm.netspeed.up
graph stm.netspeed
bracket stm.netspeed.pill" "$(names_of pill unified right)" "right: reverse add order, then the pill"
  for pos in left center; do
    assert_eq "graph stm.netspeed
graph stm.netspeed.up
item stm.netspeed.rates
bracket stm.netspeed.pill" "$(names_of pill unified "$pos")" "$pos"
  done
  assert_eq "item stm.netspeed.rates
graph stm.netspeed.up
graph stm.netspeed" "$(names_of plain unified right)" "plain: no bracket"
  done_it

  it "item.lua unified: upload graph overlaid on the download graph (V47)"
  assert_eq "graph stm.netspeed 30 {background={color=0 drawing=true padding_right=-30} graph={color=$BLUE fill_color=$BLUE_SOFT line_width=1.0} icon={color=$BLUE string=$SWAP} label={drawing=false} position=right update_freq=2}" \
    "$(line_of stm.netspeed pill unified right)" "download"
  assert_eq "graph stm.netspeed.up 30 {background={color=0 drawing=true padding_left=0} graph={color=$MAGENTA fill_color=0 line_width=1.5} icon={drawing=false} label={drawing=false} position=right}" \
    "$(line_of stm.netspeed.up pill unified right)" "upload"
  assert_eq "item stm.netspeed.rates {background={color=0 drawing=true} icon={color=$MAGENTA padding_left=0 padding_right=0 string=${UP}-- width=0 y_offset=6} label={color=$BLUE padding_left=0 string=${DOWN}-- y_offset=-5} position=left}" \
    "$(line_of stm.netspeed.rates plain unified left)" "rates"
  assert_eq "bracket stm.netspeed.pill stm.netspeed,stm.netspeed.up,stm.netspeed.rates {background={color=21 drawing=true}}" \
    "$(line_of stm.netspeed.pill pill unified right)" "pill"
  done_it

  it "item.lua unified: rates in the label font 3pt smaller, measured on the rates item (V47, V46)"
  out=$(probe pill unified right 13.00)
  assert_eq "query stm.netspeed.rates
set stm.netspeed.rates {icon={font=Hack Nerd Font:Bold:10.0} label={font=Hack Nerd Font:Bold:10.0}}
exec STM_NS_VIEW='unified' STM_NS_CW='6.10' STM_NS_PAD='5' NAME='stm.netspeed' SENDER='forced' '/p/netspeed.sh'
exec STM_NS_VIEW='unified' STM_NS_CW='6.10' STM_NS_PAD='5' NAME='stm.netspeed' SENDER='routine' '/p/netspeed.sh'" \
    "$(printf '%s\n' "$out" | grep -E '^(query|set|exec) ')" "13pt -> 10pt, once"
  assert_contains "$out" "subscribe stm.netspeed routine forced system_woke wifi_change"
  assert_contains "$(probe pill unified right 10.00)" "label={font=Hack Nerd Font:Bold:8.0}" "8pt at least"
  done_it

  it "item.lua separate: download left of upload, each its own pill (V47, V10)"
  assert_eq "graph stm.netspeed.up
graph stm.netspeed" "$(names_of pill separate right)" "right"
  assert_eq "graph stm.netspeed
graph stm.netspeed.up" "$(names_of pill separate left)" "left"
  assert_eq "graph stm.netspeed 30 {background={color=21 drawing=true} graph={color=$BLUE fill_color=$BLUE_SOFT line_width=1.0} icon={color=$BLUE string=$DL} label={string=--} position=left update_freq=2}" \
    "$(line_of stm.netspeed pill separate left)" "download pill"
  assert_eq "graph stm.netspeed.up 30 {graph={color=$MAGENTA fill_color=$MAGENTA_SOFT line_width=1.0} icon={color=$MAGENTA string=$UL} label={string=--} position=left}" \
    "$(line_of stm.netspeed.up plain separate left)" "upload plain"
  out=$(probe plain separate right)
  assert_contains "$out" "query stm.netspeed"
  assert_not_contains "$out" "set stm.netspeed" "separate keeps the label font"
  assert_contains "$out" "exec STM_NS_VIEW='separate' STM_NS_CW='7.93' STM_NS_PAD='11' NAME='stm.netspeed' SENDER='forced'"
  done_it
elif [ -n "${CI:-}" ]; then
  it "lua is available to run item.lua"
  _note_fail "lua not found; CI must run item.lua"
  done_it
else
  printf '# note: lua not found, item.lua not run\n'
fi

finish
