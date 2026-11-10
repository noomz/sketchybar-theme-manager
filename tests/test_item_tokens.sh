#!/usr/bin/env bash

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

BUNDLE="$REPO_ROOT/bundles/items/tokens"
PLUGIN="$BUNDLE/plugin.sh"
TAB=$(printf '\t')

# nf-md-counter U+F01BC (bash 3.2 printf has no \U).
COUNTER=$(printf '\363\260\206\274')

# A fake aub: logs its argv, then prints $AUB_JSON or fails as $AUB_MODE says.
FAKE_BIN="$SANDBOX/tokens-bin"
mkdir -p "$FAKE_BIN"
AUB="$SANDBOX/aub"
cat >"$AUB" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$AUB_LOG"
case ${AUB_MODE:-ok} in
  fail) exit 1 ;;
  empty) exit 0 ;;
esac
printf '%s\n' "$AUB_JSON"
EOF
chmod 755 "$AUB"
# The plugin must never call sketchybar: this one leaves a trace if it does.
cat >"$FAKE_BIN/sketchybar" <<'EOF'
#!/bin/sh
printf 'sketchybar %s\n' "$*" >>"$AUB_LOG"
EOF
chmod 755 "$FAKE_BIN/sketchybar"

NOW=1793007200 # 2026-10-26T09:33:20Z
# The sample time is each provider's `asOf` (the poll that produced it). The
# top-level `asOf` is when aub ran — always "now" — and must be ignored.
CALLED=2026-10-26T09:33:20Z
ASOF=2026-10-26T09:30:00Z
ASOF_EPOCH=1793007000
OLDER=2026-10-26T09:20:00Z

OUT=""
AUB_CALLS=""
# run_plugin <json> [VAR=value...] — the plugin's stdout in OUT.
run_plugin() {
  local json="$1"
  shift
  rm -f "$SANDBOX/aub.log"
  OUT=$(env -i HOME="$HOME" PATH="$FAKE_BIN:/bin" AUB_LOG="$SANDBOX/aub.log" AUB_JSON="$json" \
    NAME=stm.tokens SENDER=routine STM_AUB="$AUB" STM_NOW="$NOW" "$@" /bin/sh "$PLUGIN" 2>/dev/null)
  AUB_CALLS=$(cat "$SANDBOX/aub.log" 2>/dev/null || true)
}

lines() {
  printf '%s\n' "$@"
}

# The real shape: claude and codex have counts (codex polled earlier), grok
# has none but a newer poll, gemini null and no snapshot.
REAL='{"asOf":"'$CALLED'","totals":{"costUSD":"4.20"},"providers":[
{"id":"claude","displayName":"Claude Code","status":"ok","asOf":"'$ASOF'","tokensToday":252705875},
{"id":"codex","displayName":"Codex","status":"ok","asOf":"'$OLDER'","tokensToday":25840},
{"id":"grok","displayName":"Grok","status":"ok","asOf":"'$CALLED'"},
{"id":"gemini","displayName":"Gemini","status":"unauthenticated","tokensToday":null}]}'

it "plugin: records for the real shape; total sums only providers with a count (I.tok, V100)"
run_plugin "$REAL"
assert_eq "$(lines "state${TAB}ok" "asof${TAB}$ASOF_EPOCH${TAB}0" "total${TAB}252731715" \
  "prov${TAB}claude${TAB}Claude Code${TAB}252705875" "prov${TAB}codex${TAB}Codex${TAB}25840")" "$OUT" "records"
assert_eq "usage --json" "$AUB_CALLS" "one aub call, argv fixed, never sketchybar"
done_it

it "plugin: no provider with a count → nodata (V101)"
run_plugin '{"asOf":"'$CALLED'","providers":[{"id":"grok","displayName":"Grok","asOf":"'$ASOF'"},{"id":"gemini","tokensToday":null}]}'
assert_eq "state${TAB}nodata" "$OUT" "no counts"
run_plugin '{"asOf":"'$CALLED'","providers":[]}'
assert_eq "state${TAB}nodata" "$OUT" "no providers"
done_it

it "plugin: aub missing, failing, empty or unparsable (V101)"
run_plugin "$REAL" STM_AUB="$SANDBOX/no-such-aub"
assert_eq "state${TAB}missing" "$OUT" "missing"
assert_eq "" "$AUB_CALLS" "nothing run"
for mode in fail empty; do
  run_plugin "$REAL" AUB_MODE=$mode
  assert_eq "state${TAB}nodata" "$OUT" "$mode"
done
for json in 'not json' '[]' '{"providers":{}}' '"x"' '{"asOf":"x"}'; do
  run_plugin "$json"
  assert_eq "state${TAB}nodata" "$OUT" "json [$json]"
done
done_it

it "plugin: sample time = newest provider asOf; stale after 15 minutes, future or bad untrusted (V101)"
run_plugin "$REAL" STM_NOW=$((ASOF_EPOCH + 900))
assert_contains "$OUT" "asof${TAB}$ASOF_EPOCH${TAB}0"
run_plugin "$REAL" STM_NOW=$((ASOF_EPOCH + 901))
assert_contains "$OUT" "asof${TAB}$ASOF_EPOCH${TAB}1"
# Only the older provider's time is in the past: the newer one is too far
# ahead and dropped, so the older one decides.
run_plugin "$REAL" STM_NOW=$((ASOF_EPOCH - 301))
assert_contains "$OUT" "asof${TAB}$((ASOF_EPOCH - 600))${TAB}0"
# Every provider time present but untrusted → no time, stale.
run_plugin "${REAL//$ASOF/2026-10-26 09:30}" STM_NOW=$((ASOF_EPOCH - 901))
assert_contains "$OUT" "asof${TAB}${TAB}1"
run_plugin "${REAL//$OLDER/x}" STM_NOW=$((ASOF_EPOCH - 301))
assert_contains "$OUT" "asof${TAB}${TAB}1"
assert_contains "$OUT" "total${TAB}252731715"
# A fresh top-level asOf never hides an old sample.
run_plugin '{"asOf":"'$CALLED'","providers":[{"id":"claude","asOf":"'$OLDER'","tokensToday":5}]}' \
  STM_NOW=$((ASOF_EPOCH + 301))
assert_contains "$OUT" "asof${TAB}$((ASOF_EPOCH - 600))${TAB}1"
# A newer time on a provider without a count, a dropped id or a duplicate id
# is not the sample time.
run_plugin '{"asOf":"'$CALLED'","providers":[{"id":"claude","asOf":"'$OLDER'","tokensToday":5},
{"id":"grok","asOf":"'$ASOF'"},{"id":"Bad Id","asOf":"'$ASOF'","tokensToday":1},
{"id":"claude","asOf":"'$ASOF'","tokensToday":9}]}'
assert_contains "$OUT" "asof${TAB}$((ASOF_EPOCH - 600))${TAB}0"
done_it

it "plugin: older aub (no provider asOf) → total only, time unknown, never stale (V101)"
run_plugin '{"asOf":"2020-01-01T00:00:00Z","providers":[{"id":"claude","tokensToday":5},{"id":"codex","asOf":null,"tokensToday":2}]}'
assert_eq "$(lines "state${TAB}ok" "asof${TAB}${TAB}0" "total${TAB}7" \
  "prov${TAB}claude${TAB}claude${TAB}5" "prov${TAB}codex${TAB}codex${TAB}2")" "$OUT" "records"
done_it

it "plugin: hostile JSON — non-integer counts dropped, names cleaned, ids checked, first id wins (V100)"
# shellcheck disable=SC2016 # the $(rm) is hostile text that must stay literal
run_plugin '{"asOf":"'$CALLED'","providers":[
{"id":"a","displayName":"A","tokensToday":1.5},
{"id":"b","displayName":"B","tokensToday":-3},
{"id":"c","displayName":"C","tokensToday":"12x"},
{"id":"d","displayName":"D","tokensToday":1e300},
{"id":"e","displayName":"E","tokensToday":true},
{"id":"f","displayName":"Evil\tName\nprov\tx\tX\t999","tokensToday":"7"},
{"id":"Bad Id","displayName":"Z","tokensToday":5},
{"id":"g\u0007","displayName":"‮G\u0000;$(rm)","tokensToday":9},
{"id":"f","displayName":"dup","tokensToday":100},
{"id":"h","tokensToday":10000000000000000}]}'
assert_eq "$(lines "state${TAB}ok" "asof${TAB}${TAB}0" "total${TAB}16" \
  "prov${TAB}f${TAB}EvilNameprovxX99${TAB}7" "prov${TAB}g${TAB}G(rm)${TAB}9")" "$OUT" "only f and g"
done_it

it "plugin: a hung aub is killed after about 3 s (V48 via I.tok)"
cat >"$SANDBOX/aub-hang" <<'EOF'
#!/bin/sh
exec /bin/sleep 29.4917
EOF
chmod 755 "$SANDBOX/aub-hang"
start=$(date +%s)
run_plugin "$REAL" STM_AUB="$SANDBOX/aub-hang"
took=$(($(date +%s) - start))
assert_eq "state${TAB}nodata" "$OUT" "hang → nodata"
[ "$took" -le 6 ] || _note_fail "took ${took}s"
if pgrep -f "sleep 29.4917" >/dev/null 2>&1; then
  _note_fail "hung aub left running"
  pkill -f "sleep 29.4917" 2>/dev/null || true
fi
done_it

it "lint and install item:tokens; option values checked (V4, I.tok)"
STM_ROOT="$REPO_ROOT" run_stm --porcelain lint item:tokens
assert_status 0
assert_eq "ok	item:tokens" "$STM_OUT"
D="$SANDBOX/cfg"
make_lua_config "$D"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install item:tokens
assert_status 0
assert_files_equal "$PLUGIN" "$D/plugins/stm/tokens.sh"
assert_eq "-rwxr-xr-x" "$(stat -f %Sp "$D/plugins/stm/tokens.sh")" "plugin mode"
loader=$(cat "$D/items_generated.lua")
for opt in '["shape"] = "split"' '["scale"] = "500m"' '["pulse"] = "1m"' '["priority"] = "low"' \
  'update_freq = 60,' 'events = { "system_woke" },' 'position = "right"'; do
  assert_contains "$loader" "$opt"
done
printf '[item.tokens]\nscale = "1b"\npulse = "off"\nshape = "pill"\n' >"$D/stm.config.toml"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload --force install item:tokens
assert_status 0
loader=$(cat "$D/items_generated.lua")
for opt in '["scale"] = "1b"' '["pulse"] = "off"' '["shape"] = "pill"'; do
  assert_contains "$loader" "$opt"
done
for bad in 'scale = "2b"' 'scale = "500000000"' 'pulse = "10m"' 'pulse = "on"' 'shape = "round"'; do
  printf '[item.tokens]\n%s\n' "$bad" >"$D/stm.config.toml"
  STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload --force install item:tokens
  assert_ne 0 "$STM_STATUS" "$bad refused"
done
done_it

LUA_BIN=$(command -v lua 2>/dev/null || true)
if [ -n "$LUA_BIN" ]; then
  mkdir -p "$SANDBOX/lua"
  # probe.lua <item.lua> <shape> <position> <options "k=v k=v"> <replies file>
  # The replies file holds plugin.sh outputs, one per run, split by `%%`
  # lines; \t stands for TAB. The first answers the load-time run; each later
  # one answers a `routine` event. A reply `TABLE` stands for JSON SbarLua
  # parsed into a table.
  cat >"$SANDBOX/lua/probe.lua" <<'EOF'
local item_lua, shape, position, options_s, replies_file = ...
local function dump(v)
  if type(v) ~= "table" then
    return tostring(v)
  end
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = tostring(k) .. "=" .. dump(v[k])
  end
  return "{" .. table.concat(parts, " ") .. "}"
end
local replies = {}
local f = assert(io.open(replies_file))
local text = f:read("a")
f:close()
for block in (text .. "%%\n"):gmatch("(.-)%%%%\n") do
  replies[#replies + 1] = (block:gsub("\\t", "\t"):gsub("\\n", "\n"))
end
local handlers = {}
local sbar = {}
function sbar.add(kind, name, a)
  print(kind .. " " .. name .. " " .. dump(a))
  return {
    subscribe = function(_, events, fn)
      if type(events) ~= "table" then events = { events } end
      print("subscribe " .. name .. " " .. table.concat(events, " "))
      for _, ev in ipairs(events) do handlers[name .. " " .. ev] = fn end
    end,
    set = function(_, props) print("set " .. name .. " " .. dump(props)) end,
  }
end
function sbar.query(name)
  print("query " .. name)
  return { label = { font = "Hack Nerd Font:Bold:13.00", padding_left = 6, padding_right = 6 },
    icon = { font = "Hack Nerd Font:Bold:17.00", padding_left = 4, padding_right = 4 } }
end
function sbar.animate(curve, frames, fn)
  print("animate " .. curve .. " " .. frames)
  fn()
  print("animate end")
end
local n = 0
function sbar.exec(cmd, done)
  print("exec " .. cmd)
  n = n + 1
  local r = replies[n]
  if r == "TABLE\n" then r = { state = "ok" } end
  print("reply " .. n)
  if done then done(r, 0) end
end
local options = { shape = shape, scale = "500m", pulse = "1m", priority = "low" }
for k, v in options_s:gmatch("([%w_]+)=(%w+)") do
  options[k] = v
end
local opts = { name = "stm.tokens", position = position, update_freq = 60,
  plugin_dir = "/p", events = { "system_woke" }, options = options }
dofile(item_lua)(sbar, opts, { green = 0xff00ff00, yellow = 0xffffff00, red = 0xffff0000, grey = 0xff808080,
  white = 0xffffffff, black = 0xff000000, bg1 = 21, popup_bg = 31, popup_border = 32 })
-- PROBE_FORMS=a,b,...: compact events after the load-time run, before the rest.
for form in (os.getenv("PROBE_FORMS") or ""):gmatch("[^,]+") do
  print("form " .. form)
  handlers["stm.tokens stm_compact"]({ SENDER = "stm_compact", STM_FORM_TOKENS = form ~= "-" and form or nil })
end
-- PROBE_CLICK=<item name>: a click on it after the forms.
local click = os.getenv("PROBE_CLICK")
if click then
  print("click " .. click)
  handlers[click .. " mouse.clicked"]({ SENDER = "mouse.clicked" })
end
for i = 2, #replies do
  handlers["stm.tokens routine"]({ SENDER = "routine" })
end
EOF
  # probe <shape> <position> <options> <reply>... — every line the stub prints.
  probe() {
    local shape="$1" position="$2" options="$3"
    shift 3
    local r="$SANDBOX/lua/replies"
    : >"$r"
    local first=1
    for reply in "$@"; do
      [ "$first" = 1 ] || printf '%%%%\n' >>"$r"
      printf '%s\n' "$reply" >>"$r"
      first=0
    done
    "$LUA_BIN" "$SANDBOX/lua/probe.lua" "$BUNDLE/item.lua" "$shape" "$position" "$options" "$r" 2>&1
  }
  # ok <asof> <stale> <total> [<id>=<tokens>...] — a plugin reply.
  ok() {
    local asof="$1" stale="$2" total="$3" p s
    shift 3
    s="state\\tok
asof\\t$asof\\t$stale
total\\t$total"
    for p in "$@"; do
      s="$s
prov\\t${p%%=*}\\t${p%%=*}\\t${p#*=}"
    done
    printf '%s' "$s"
  }
  # labels_of <total>... — the bar label after each sample.
  labels_of() {
    local args=() t
    for t in "$@"; do
      args+=("$(ok 1000 0 "$t" "claude=$t")")
    done
    probe plain right "" "${args[@]}" | sed -n 's/^set stm.tokens {label={string=\([^ ]*\) .*/\1/p' | tr '\n' ' '
  }
  # paints_of <shape> <reply>... — the colours painted, in order.
  paints_of() {
    local shape="$1"
    shift
    probe "$shape" right "pulse=off" "$@" | sed -n 's/^set stm.tokens.icon {background={color=\([0-9]*\)}}$/\1/p; s/^set stm.tokens {icon={color=\([0-9]*\)}}$/\1/p' | tr '\n' ' '
  }
  pulses_of() {
    local opts="$1"
    shift
    probe split right "$opts" "$@" | grep -c '^animate sin 20$' || true
  }

  it "item.lua: names, icon nf-md-counter, split sub-item left of the label, popup rows (V10, V33, I.tok)"
  out=$(probe split right "" "state\\tmissing")
  assert_eq "item stm.tokens item stm.tokens.icon item stm.tokens.row.head item stm.tokens.row.0 item stm.tokens.row.1 item stm.tokens.row.2 item stm.tokens.row.3 item stm.tokens.row.4 item stm.tokens.row.5 item stm.tokens.row.6 item stm.tokens.row.7 item stm.tokens.row.rate " \
    "$(printf '%s\n' "$out" | awk '$1 == "item" { print $1 " " $2 }' | tr '\n' ' ')" "split right"
  assert_contains "$out" "item stm.tokens.icon {background={color=$((0xff808080)) drawing=true} icon={color=$((0xff000000)) string=$COUNTER} label={drawing=false} position=right}"
  assert_contains "$out" "item stm.tokens {background={color=21 drawing=true padding_left=0} icon={drawing=false} label={string=--} popup={align=right background={border_color=32 border_width=2 color=31 corner_radius=12}} position=right update_freq=60 updates=true}"
  assert_contains "$out" "subscribe stm.tokens routine forced system_woke"
  assert_contains "$out" "exec NAME='stm.tokens' SENDER='forced' '/p/tokens.sh'"
  out=$(probe split left "" "state\\tmissing")
  assert_eq "item stm.tokens.icon item stm.tokens " \
    "$(printf '%s\n' "$out" | awk '$1 == "item" && $2 !~ /row/ { print $1 " " $2 }' | tr '\n' ' ')" "split left"
  out=$(probe pill right "" "state\\tmissing")
  assert_contains "$out" "item stm.tokens {background={color=21 drawing=true} icon={color=$((0xff808080)) string=$COUNTER}"
  assert_not_contains "$out" "stm.tokens.icon"
  assert_contains "$(probe plain right "" "state\\tmissing")" "item stm.tokens {icon={color=$((0xff808080)) string=$COUNTER} label={string=--} popup="
  done_it

  it "item.lua: label compact K/M/B, rounding steps up a unit, width from the font (V46, I.tok)"
  assert_eq "0 999 1.0K 25.8K 999.9K 1.0M 255.7M 999.9M 1.0B 1.2B 999.9B 999B+ 999B+ " \
    "$(labels_of 0 999 1000 25840 999949 999950 255705875 999949999 999950000 1234567890 999949999999 999950000000 5000000000000)"
  assert_contains "$(probe plain right "" "$(ok 1000 0 25840 claude=25840)")" \
    "set stm.tokens {label={string=25.8K width=52}}"
  done_it

  it "item.lua: heat blend green → yellow → red by scale; states grey (I.tok)"
  # green 0xff00ff00, yellow 0xffffff00, red 0xffff0000; scale 500m.
  assert_eq "$((0xff00ff00)) $((0xff80ff00)) $((0xffffff00)) $((0xffff8000)) $((0xffff0000)) $((0xffff0000)) " \
    "$(paints_of split "$(ok 1 0 0 a=0)" "$(ok 2 0 125000000 a=125000000)" "$(ok 3 0 250000000 a=250000000)" \
      "$(ok 4 0 375000000 a=375000000)" "$(ok 5 0 500000000 a=500000000)" "$(ok 6 0 900000000 a=900000000)")" \
    "split: the blend on the sub-item"
  assert_contains "$(probe plain right "scale=1b" "$(ok 1 0 500000000 a=500000000)")" "set stm.tokens {icon={color=$((0xffffff00))}}"
  assert_contains "$(probe pill right "scale=100m" "$(ok 1 0 50000000 a=50000000)")" "set stm.tokens {icon={color=$((0xffffff00))}}"
  out=$(probe split right "" "$(ok 1 1 250000000 a=250000000)")
  assert_contains "$out" "set stm.tokens {label={string=250.0M width="
  assert_eq "$((0xff808080)) " "$(paints_of split "$(ok 1 1 250000000 a=250000000)")" "stale: grey, value kept"
  assert_contains "$out" "set stm.tokens.row.head {label={string=250.0M · as of"
  assert_contains "$out" " · stale}}"
  assert_contains "$(probe split right "" "state\\tmissing")" "set stm.tokens {label={string=no aub width="
  out=$(probe split right "" "state\\tnodata")
  assert_contains "$out" "set stm.tokens {label={string=-- width="
  assert_contains "$out" "set stm.tokens.row.head {label={string=no token counts yet}}"
  done_it

  it "item.lua: hostile or malformed replies are dropped or read as nodata (V100)"
  for reply in "TABLE" "" "garbage" "state\\tok" "state\\tok\\nasof\\t1\\t0\\ntotal\\t5" \
    "state\\tok\\nasof\\t1\\t0\\ntotal\\t1.5\\nprov\\ta\\tA\\t1" "state\\tevil\\nprov\\ta\\tA\\t1"; do
    assert_contains "$(probe plain right "" "$reply")" "set stm.tokens {label={string=-- width=" "reply [$reply]"
  done
  out=$(probe plain right "" "state\\tok\\nasof\\t1\\t0\\ntotal\\t5\\nprov\\ta\\tA\\t5\\nprov\\tb\\tB\\t1e9\\nprov\\tc\\tC\\t-3\\nprov\\ta\\tdup\\t7")
  assert_contains "$out" "set stm.tokens.row.0 {drawing=true icon={string=A} label={string=5}}"
  assert_contains "$out" "set stm.tokens.row.1 {drawing=false}"
  done_it

  it "item.lua: popup rows most tokens first, the rest hidden, rate row (I.tok)"
  out=$(probe split right "" "$(ok 1000 0 252731715 codex=25840 claude=252705875 x=25840)" \
    "$(ok 1060 0 253731715 codex=25840 claude=253705875 x=25840)")
  assert_contains "$out" "set stm.tokens.row.0 {drawing=true icon={string=claude} label={string=252.7M}}"
  assert_contains "$out" "set stm.tokens.row.1 {drawing=true icon={string=codex} label={string=25.8K}}"
  assert_contains "$out" "set stm.tokens.row.2 {drawing=true icon={string=x} label={string=25.8K}}"
  assert_contains "$out" "set stm.tokens.row.3 {drawing=false}"
  assert_contains "$out" "set stm.tokens.row.rate {label={string=--}}"
  assert_contains "$out" "set stm.tokens.row.rate {label={string=1.0M/min}}"
  assert_contains "$out" "set stm.tokens.row.head {icon={width=195}}"
  assert_contains "$out" "item stm.tokens.row.rate {icon={color=$((0xff808080)) string=rate} label={color=$((0xffffffff)) string=--} position=popup.stm.tokens}"
  done_it

  it "item.lua: burst pulse — rate between samples vs the threshold (V102, V103)"
  # 1M tokens over one minute = 1M/min; the default threshold is 1m.
  a=$(ok 1000 0 1000000 claude=1000000)
  b=$(ok 1060 0 2000000 claude=2000000)
  assert_eq 0 "$(pulses_of "" "$a")" "first sample: no rate, no pulse"
  assert_eq 1 "$(pulses_of "" "$a" "$b")" "1M/min ≥ 1m: one pulse"
  assert_eq 1 "$(pulses_of "" "$a" "$b" "$b" "$b")" "asOf unchanged: no recompute, no second pulse"
  assert_eq 0 "$(pulses_of "" "$a" "$(ok 1060 0 1999999 claude=1999999)")" "just under"
  assert_eq 0 "$(pulses_of "pulse=off" "$a" "$b")" "pulse off never"
  assert_eq 1 "$(pulses_of "pulse=250k" "$a" "$(ok 1240 0 2000000 claude=2000000)")" "250k/min over 4 minutes"
  assert_eq 0 "$(pulses_of "pulse=5m" "$a" "$b")" "5m threshold"
  assert_eq 0 "$(pulses_of "" "$a" "$(ok 1060 0 10 claude=10)")" "midnight reset: rate 0"
  assert_eq 0 "$(pulses_of "" "$(ok 1000 0 1000000 claude=1000000 codex=5)" \
    "$(ok 1060 0 4000001 claude=4000000 codex=1)")" "one count went down, the rest up 3M/min: whole rate 0"
  assert_contains "$(probe split right "" "$a" "$(ok 1060 0 10 claude=10)")" "set stm.tokens.row.rate {label={string=0/min}}"
  assert_eq 0 "$(pulses_of "" "$a" "$(ok 1060 0 6000000 claude=1000000 grok=5000000)")" \
    "provider null → number not counted"
  assert_eq 0 "$(pulses_of "" "$a" "$(ok 1060 1 2000000 claude=2000000)")" "stale: no pulse"
  assert_eq 0 "$(pulses_of "" "$a" "$(ok 940 0 9000000 claude=9000000)")" "asOf went back: no rate"
  # An older reply (a slow run answering late) is dropped whole: no redraw,
  # no new baseline, so the newest sample coming back is not a second burst.
  out=$(probe split right "" "$a" "$b" "$a" "$b")
  assert_eq 1 "$(printf '%s\n' "$out" | grep -c '^animate sin 20$')" "older reply between: one pulse"
  assert_eq "1.0M 2.0M 2.0M " \
    "$(printf '%s\n' "$out" | sed -n 's/^set stm.tokens {label={string=\([^ ]*\) .*/\1/p' | tr '\n' ' ')" \
    "older reply never shows its total"
  assert_not_contains "$(probe split right "" "$a" "$(ok 940 0 9000000 claude=9000000)")" "string=9.0M"
  # Older aub (no sample time): the total and heat, but no rate, no pulse,
  # no time in the head.
  out=$(probe split right "" "$(ok "" 0 1000000 claude=1000000)" "$(ok "" 0 9000000 claude=9000000)")
  assert_eq 0 "$(printf '%s\n' "$out" | grep -c '^animate sin 20$')" "no time: no pulse"
  assert_contains "$out" "set stm.tokens {label={string=9.0M width="
  assert_contains "$out" "set stm.tokens.row.head {label={string=9.0M}}"
  assert_not_contains "$out" "as of"
  assert_not_contains "$out" "/min"
  assert_eq 0 "$(pulses_of "" "$a" "state\\tnodata" "$a")" "nodata between, same asOf after: no pulse"
  assert_eq 1 "$(pulses_of "" "$a" "state\\tnodata" "$b")" "nodata between, then a new asOf: pulse"
  out=$(probe split right "" "$a" "$(ok 1060 0 3000000 claude=3000000)")
  assert_contains "$out" "set stm.tokens.row.rate {label={string=2.0M/min}}"
  # The pulse: out halfway to white and back, chained in one animation.
  # 2M of 500m blends green a little toward yellow: 0xff02ff00.
  hot=$((0xff02ff00))
  bright=$((0xff81ff80))
  assert_contains "$(probe split right "" "$a" "$b")" "animate sin 20
set stm.tokens.icon {background={color=$bright}}
set stm.tokens.icon {background={color=$hot}}
animate end"
  assert_contains "$(probe plain right "" "$a" "$b")" "animate sin 20
set stm.tokens {icon={color=$bright}}
set stm.tokens {icon={color=$hot}}
animate end"
  assert_eq 0 "$(PROBE_FORMS=hidden pulses_of "" "$a" "$b")" "hidden: no pulse"
  done_it

  it "item.lua: compact forms; hidden draws nothing, closes the popup and never pulses (I.form)"
  # split icon form keeps the main item drawn at zero width: it hosts the
  # popup, and SketchyBar draws no popup for a hidden item.
  out=$(PROBE_FORMS=icon,hidden,full,bogus probe split right "" "$(ok 1 0 5 a=5)")
  assert_contains "$out" "form icon
set stm.tokens.icon {drawing=true}
set stm.tokens {background={drawing=false} drawing=true label={drawing=false} width=0}
form hidden
set stm.tokens.icon {drawing=false}
set stm.tokens {drawing=false}
set stm.tokens {popup={drawing=false}}
form full
set stm.tokens.icon {drawing=true}
set stm.tokens {background={drawing=true} drawing=true label={drawing=true} width=dynamic}
form bogus"
  out=$(PROBE_FORMS=icon PROBE_CLICK=stm.tokens.icon probe split right "" "$(ok 1 0 5 a=5)")
  assert_contains "$out" "click stm.tokens.icon
set stm.tokens {popup={drawing=toggle}}"
  assert_not_contains "$out" "set stm.tokens {drawing=false}"
  out=$(PROBE_FORMS=icon probe plain right "" "$(ok 1 0 5 a=5)")
  assert_contains "$out" "set stm.tokens {drawing=true label={drawing=false}}"
  done_it
elif [ -n "${CI:-}" ]; then
  it "lua is available to run item.lua"
  _note_fail "lua not found; CI must run item.lua"
  done_it
else
  printf '# note: lua not found, item.lua not run\n'
fi

finish
