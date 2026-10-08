#!/usr/bin/env bash
# stm.ai: AI provider quota use from the Agents Usage Bar cache (#26).

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

BUNDLE="$REPO_ROOT/bundles/items/ai"
PLUGIN="$BUNDLE/plugin.sh"
FIXTURE="$REPO_ROOT/tests/fixtures/aub/usage.json"
SB_LOG="$SANDBOX/sketchybar.argv"

GREEN=0xff11aa22
YELLOW=0xffcccc00
RED=0xffaa0000
GREY=0xff808080
WHITE=0xffeeeeee

# The fixture's asOf, and a minute later.
ASOF=1791438579
NOW=$((ASOF + 60))

# nf-md-creation (bash 3.2 printf has no \U).
GLYPH=$(printf '\363\260\231\264')

# Plugin PATH: our fakes plus /bin.
FAKE_BIN="$SANDBOX/ai-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/sketchybar" <<'EOF'
#!/bin/sh
printf 'call\n' >>"$SB_LOG.calls"
printf '%s\n' "$@" >>"$SB_LOG"
EOF

# Fake aub: logs its argv, then prints $AUB_JSON unless $AUB_MODE says not to.
# The odd hang duration makes it findable with pgrep.
HANG_SECS=29.3713
cat >"$SANDBOX/aub" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"\$SB_LOG.aub"
case "\${AUB_MODE:-}" in
  fail) echo 'no cached data yet — run aub --live' >&2; exit 1 ;;
  hang) exec /bin/sleep $HANG_SECS ;;
  garbage) echo 'not json'; exit 0 ;;
  empty) exit 0 ;;
esac
exec /bin/cat "\$AUB_JSON"
EOF
cat >"$SANDBOX/open" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$SB_LOG.open"
EOF
chmod 755 "$FAKE_BIN/sketchybar" "$SANDBOX/aub" "$SANDBOX/open"

# run_plugin <json file> [VAR=value...] — one run with a clean env.
# sketchybar's argv lands in $SB (calls counted in $SB_CALLS), aub's in
# $AUB_ARGS, open's in $OPENED.
SB=""
SB_CALLS=0
AUB_ARGS=""
OPENED=""
run_plugin() {
  local json="$1"
  shift
  rm -f "$SB_LOG" "$SB_LOG.calls" "$SB_LOG.aub" "$SB_LOG.open"
  env -i HOME="$HOME" TMPDIR="$SANDBOX" TZ=UTC PATH="$FAKE_BIN:/bin" SB_LOG="$SB_LOG" \
    NAME=stm.ai SENDER=routine STM_AUB="$SANDBOX/aub" AUB_JSON="$json" \
    STM_NOW=$NOW STM_OPEN="$SANDBOX/open" \
    STM_GREEN=$GREEN STM_YELLOW=$YELLOW STM_RED=$RED STM_GREY=$GREY STM_WHITE=$WHITE \
    STM_AI_SHAPE=split STM_AI_VIEW=worst STM_AI_PROVIDER=all \
    STM_AI_CW=7.93 STM_AI_PAD=12 "$@" /bin/sh "$PLUGIN" >/dev/null 2>&1
  SB=$(cat "$SB_LOG" 2>/dev/null || true)
  SB_CALLS=$(grep -c . "$SB_LOG.calls" 2>/dev/null || true)
  AUB_ARGS=$(cat "$SB_LOG.aub" 2>/dev/null || true)
  OPENED=$(cat "$SB_LOG.open" 2>/dev/null || true)
}

# seg <item> — the properties one `--set <item>` sent, one per line.
seg() {
  printf '%s\n' "$SB" | awk -v n="$1" '$0 == "--set" { getline t; on = (t == n); next } on { print }'
}

lines() {
  printf '%s\n' "$@"
}

# mk_json <file> <window name> <utilization> [asOf] — one grok window.
mk_json() {
  printf '{"asOf":"%s","totals":{"costUSD":"12.5","tokens":999},"providers":[{"id":"grok","status":"ok","costTodayUSD":null,"balanceUSD":null,"quota":null,"accounts":[],"quotaWindows":[{"name":"%s","utilization":%s,"resetsAt":"2026-10-08T10:00:00Z"}]}]}\n' \
    "${4-2026-10-08T05:49:39Z}" "$2" "$3" >"$1"
}

J="$SANDBOX/one.json"

it "worst window across providers, banded on the icon (V50, V51)"
run_plugin "$FIXTURE"
assert_eq "$(lines "label= 79% 7d" "label.color=$WHITE" label.width=68)" "$(seg stm.ai)" "main"
assert_eq "background.color=$YELLOW" "$(seg stm.ai.icon)" "split icon on the band"
assert_eq "usage --json" "$AUB_ARGS" "one fixed aub call (V48)"
assert_eq 1 "$SB_CALLS" "one sketchybar call (V48)"
done_it

it "hostile JSON shapes: wrong types skipped, caps, first id wins (V49, B11)"
grok() {
  printf '{"id":"grok","status":"ok","accounts":[],"quotaWindows":%s}' "$1"
}
doc() {
  printf '{"asOf":"2026-10-08T05:49:39Z","totals":{"costUSD":"1","tokens":1},"providers":%s}' "$1" >"$J"
}
W60='[{"name":"7d","utilization":0.6}]'
# case <what> <providers JSON> <expected label>
case_of() {
  doc "$2"
  run_plugin "$J"
  assert_eq "label=$3" "$(seg stm.ai | head -1)" "$1"
}
case_of "non-object provider skipped" "[\"x\",$(grok "$W60")]" " 60% 7d"
case_of "non-object window skipped" "[$(grok '[1,{"name":"7d","utilization":0.6}]')]" " 60% 7d"
case_of "accounts not an array: top level used" \
  "[{\"id\":\"claude\",\"status\":\"ok\",\"accounts\":\"zz\",\"quotaWindows\":$W60}]" " 60% 7d"
case_of "array utilization skipped" "[$(grok '[{"name":"7d","utilization":[1,2]}]')]" "--"
case_of "exponent utilization skipped" "[$(grok '[{"name":"7d","utilization":1e-7}]')]" "--"
case_of "first provider per id wins" \
  "[$(grok '[{"name":"7d","utilization":0.3}]'),$(grok '[{"name":"7d","utilization":0.9}]')]" " 30% 7d"
many=$(i=0; printf '['; while [ $i -lt 39 ]; do printf '{"name":"7d","utilization":0.1},'; i=$((i + 1)); done
  printf '{"name":"7d","utilization":0.99}]')
case_of "only 32 windows read" "[$(grok "$many")]" " 10% 7d"
far=$(i=0; printf '['; while [ $i -lt 40 ]; do printf '{"id":"evil%d"},' $i; i=$((i + 1)); done; grok "$W60"; printf ']')
case_of "only 32 providers read" "$far" "--"
printf '{"providers":{"a":%s}}' "$(grok "$W60")" >"$J"
run_plugin "$J"
assert_eq "label=--" "$(seg stm.ai | head -1)" "providers an object: no data"
assert_contains "$(seg stm.ai.row.head)" "label=no cached usage yet"
printf '[]' >"$J"
run_plugin "$J"
assert_eq "label=--" "$(seg stm.ai | head -1)" "top level an array: no data"
printf '{"asOf":"2026-10-08T05:49:39Z","totals":{"costUSD":[1,2,3],"tokens":[1]},"providers":[{"id":"claude","status":"ok","accounts":[{"name":["x"],"quotaWindows":%s},{"name":7,"quotaWindows":%s}]}]}' \
  "$W60" "$W60" >"$J"
run_plugin "$J"
assert_contains "$(seg stm.ai.row.1)" "icon=  account 1"
assert_contains "$(seg stm.ai.row.2)" "icon=  account 2"
assert_contains "$(seg stm.ai.row.head)" "label=\$-- · -- tok"
done_it

it "provider option limits the bar value, not the popup (I.ai, V50)"
run_plugin "$FIXTURE"
popup_all=$(seg stm.ai.row.1)
while read -r prov label width color; do
  run_plugin "$FIXTURE" STM_AI_PROVIDER="$prov"
  assert_eq "$(lines "label=${label//_/ }" "label.color=${!color%%:*}" "label.width=$width")" \
    "$(seg stm.ai)" "provider $prov"
  assert_eq "$popup_all" "$(seg stm.ai.row.1)" "provider $prov: popup lists all"
done <<'EOF'
codex _14%_7d 68 WHITE
grok _41% 44 WHITE
gemini -- 28 GREY
EOF
run_plugin "$FIXTURE" STM_AI_PROVIDER=codex
assert_eq "background.color=$GREEN" "$(seg stm.ai.icon)" "codex band"
run_plugin "$FIXTURE" STM_AI_PROVIDER=gemini
assert_eq "background.color=$GREY" "$(seg stm.ai.icon)" "no window: grey"
done_it

it "bands at 49/50/79/80, clamp, rounding (V50)"
while read -r util label color; do
  mk_json "$J" billing "$util"
  run_plugin "$J"
  assert_eq "label=${label//_/ }" "$(seg stm.ai | head -1)" "util $util"
  assert_eq "background.color=${!color}" "$(seg stm.ai.icon)" "util $util band"
done <<'EOF'
0.49 _49% GREEN
0.50 _50% YELLOW
0.79 _79% YELLOW
0.80 _80% RED
1.7 100% RED
0 __0% GREEN
0.004 __0% GREEN
0.996 100% RED
EOF
done_it

it "window suffix map (V51)"
while read -r name label; do
  mk_json "$J" "$name" 0.5
  run_plugin "$J"
  assert_eq "label=${label//_/ }" "$(seg stm.ai | head -1)" "window $name"
done <<'EOF'
5h _50%_5h
7d _50%_7d
7d-opus _50%_7d
primary _50%_5h
secondary _50%_7d
billing _50%
2.5-pro _50%
EOF
done_it

it "stale after 900 s: value kept, all grey (V50)"
mk_json "$J" 7d 0.9
run_plugin "$J" STM_NOW=$((ASOF + 900))
assert_eq "$(lines "label= 90% 7d" "label.color=$WHITE" label.width=68)" "$(seg stm.ai)" "900 s: fresh"
assert_eq "background.color=$RED" "$(seg stm.ai.icon)" "900 s: band"
run_plugin "$J" STM_NOW=$((ASOF + 901))
assert_eq "$(lines "label= 90% 7d" "label.color=$GREY" label.width=68)" "$(seg stm.ai)" "901 s: stale"
assert_eq "background.color=$GREY" "$(seg stm.ai.icon)" "901 s: grey"
assert_contains "$(seg stm.ai.row.head)" "label=\$12.50 · 999 tok · stale · as of 05:49"
for bad in yesterday "2026-10-08 05:49:39" "2026-13-08T05:49:39Z" "2026-10-08T05:49:39+07:00" \
  "2026-10-08T05:49:39" "1969-12-31T23:59:59Z" ""; do
  mk_json "$J" 7d 0.9 "$bad"
  run_plugin "$J"
  assert_eq "label.color=$GREY" "$(seg stm.ai | sed -n 2p)" "asOf [$bad]: stale"
done
mk_json "$J" 7d 0.9 "2026-10-08T05:49:39.250Z"
run_plugin "$J"
assert_eq "label.color=$WHITE" "$(seg stm.ai | sed -n 2p)" "fractional seconds: fresh"
mk_json "$J" 7d 0.9
run_plugin "$J" STM_NOW=$((ASOF - 300))
assert_eq "label.color=$WHITE" "$(seg stm.ai | sed -n 2p)" "asOf 300 s ahead: fresh"
run_plugin "$J" STM_NOW=$((ASOF - 301))
assert_eq "label.color=$GREY" "$(seg stm.ai | sed -n 2p)" "asOf 301 s ahead: stale"
done_it

it "no data: aub fails, hangs, prints garbage, or has no window (V48)"
for mode in fail garbage empty; do
  run_plugin "$FIXTURE" AUB_MODE=$mode
  assert_eq "$(lines label=-- "label.color=$GREY" label.width=28)" "$(seg stm.ai)" "aub $mode"
  assert_eq "background.color=$GREY" "$(seg stm.ai.icon)" "aub $mode: grey"
  assert_contains "$(seg stm.ai.row.head)" "label=no cached usage yet"
  assert_contains "$(seg stm.ai.row.0)" "label=open the app to start polling"
  assert_contains "$(seg stm.ai.row.1)" "drawing=off"
  assert_contains "$(seg stm.ai.row.foot)" "label=Open Agents Usage Bar"
done
printf '{"asOf":"2026-10-08T05:49:39Z","providers":[{"id":"gemini","status":"unauthenticated","quotaWindows":[],"accounts":[]}]}' >"$J"
run_plugin "$J"
assert_eq "label=--" "$(seg stm.ai | head -1)" "no window"
start=$(date +%s)
run_plugin "$FIXTURE" AUB_MODE=hang
elapsed=$(($(date +%s) - start))
assert_eq "label=--" "$(seg stm.ai | head -1)" "hang"
[ "$elapsed" -le 6 ] || _note_fail "hang took ${elapsed}s, want <= 6"
sleep 0.5
if pgrep -f "sleep $HANG_SECS" >/dev/null; then
  pkill -f "sleep $HANG_SECS"
  _note_fail "hung aub left running"
fi
done_it

it "aub absent: no aub, grey, popup says how to get it (V48, V50, V52)"
run_plugin "$FIXTURE" STM_AUB="$SANDBOX/no-such-aub"
assert_eq "$(lines "label=no aub" "label.color=$GREY" label.width=60)" "$(seg stm.ai)" "label"
assert_eq "background.color=$GREY" "$(seg stm.ai.icon)" "grey"
assert_eq "" "$AUB_ARGS" "nothing run"
assert_contains "$(seg stm.ai.row.head)" "label=aub not found"
assert_contains "$(seg stm.ai.row.0)" "label=install Agents Usage Bar, then run aub install"
assert_contains "$(seg stm.ai.row.foot)" "label=Get Agents Usage Bar"
done_it

it "untrusted JSON: names cleaned, bad numbers skipped, unknown ids ignored (V49)"
{
  printf '{"asOf":"2026-10-08T05:49:39Z","totals":{"costUSD":"1;rm -rf","tokens":"x"},"providers":['
  printf '{"id":"evil","status":"ok","quotaWindows":[{"name":"7d","utilization":0.99}],"accounts":[]},'
  printf '{"id":"claude","status":"ok","costTodayUSD":"9e9","quotaWindows":[],"accounts":['
  # shellcheck disable=SC2016 # a literal $(x): the name must arrive unexpanded
  printf '{"name":"w\\u00f6rk\\tA\\nB;rm $(x)","costTodayUSD":"1.5","quotaWindows":[{"name":"7d","utilization":0.6,"resetsAt":"bad"}]},'
  printf '{"name":"abcdefghijklmnopqrstuvwxyz","quotaWindows":[{"name":"5h","utilization":"0.2"}]},'
  printf '{"name":"\\u0007","quotaWindows":[{"name":"5h","utilization":0.95}]},'
  printf '{"name":"num","quotaWindows":[{"name":"5h","utilization":"lots"},{"name":"7d","utilization":-0.5}]}'
  printf ']}]}'
} >"$J"
run_plugin "$J"
assert_eq "label= 95% 5h" "$(seg stm.ai | head -1)" "evil id ignored; a nameless account still counts (B12)"
assert_eq "$(lines drawing=on "icon=Claude" "icon.color=$WHITE" label= "label.color=$WHITE")" \
  "$(seg stm.ai.row.0)" "title row, bad cost dropped"
assert_eq "$(lines drawing=on "icon=  wrkABrm x" "icon.color=$WHITE" \
  "label=██████░░░░  60% 7d  \$1.50" "label.color=$YELLOW")" "$(seg stm.ai.row.1)" "name cleaned, bad reset dropped"
assert_contains "$(seg stm.ai.row.2)" "icon=  abcdefghijklmnop
icon.color"
assert_contains "$(seg stm.ai.row.3)" "icon=  account 3"
assert_contains "$(seg stm.ai.row.4)" "drawing=off"
assert_contains "$(seg stm.ai.row.head)" "label=\$-- · -- tok · as of 05:49"
printf '{"asOf":"2026-10-08T05:49:39Z","providers":[{"id":"claude","status":"ok","accounts":[{"name":"\\u0e07\\u0e32\\u0e19","quotaWindows":[{"name":"7d","utilization":0.95}]},{"name":"home","quotaWindows":[{"name":"7d","utilization":0.3}]}]}]}' >"$J"
run_plugin "$J"
assert_eq "label= 95% 7d" "$(seg stm.ai | head -1)" "a Thai-named account is not hidden (B12)"
assert_contains "$(seg stm.ai.row.1)" "icon=  account 1"
done_it

it "views: windows stacks 5h over 7d, falls back to one line; cost (V51)"
run_plugin "$FIXTURE" STM_AI_VIEW=windows
assert_eq "$(lines icon.drawing=on "icon=5h  41%" "icon.color=$GREEN" "label=7d  79%" "label.color=$YELLOW" \
  label.y_offset=-5 label.width=68)" "$(seg stm.ai)" "windows"
assert_eq "background.color=$YELLOW" "$(seg stm.ai.icon)" "windows split icon"
run_plugin "$FIXTURE" STM_AI_VIEW=windows STM_AI_SHAPE=plain
assert_eq "icon.color=$YELLOW" "$(seg stm.ai.icon)" "windows plain: glyph colour"
run_plugin "$FIXTURE" STM_AI_VIEW=windows STM_AI_PROVIDER=codex
assert_eq "$(lines icon.drawing=on "icon=5h   3%" "icon.color=$GREEN" "label=7d  14%" "label.color=$GREEN" \
  label.y_offset=-5 label.width=68)" "$(seg stm.ai)" "codex primary/secondary"
run_plugin "$FIXTURE" STM_AI_VIEW=windows STM_AI_PROVIDER=grok
assert_eq "$(lines icon.drawing=off "label= 41%" "label.color=$WHITE" label.y_offset=0 label.width=44)" \
  "$(seg stm.ai)" "no 5h/7d: one line"
mk_json "$J" 7d 0.6
run_plugin "$J" STM_AI_VIEW=windows
assert_eq "$(lines icon.drawing=on "icon=5h  --" "icon.color=$GREY" "label=7d  60%" "label.color=$YELLOW" \
  label.y_offset=-5 label.width=68)" "$(seg stm.ai)" "absent 5h"
run_plugin "$J" STM_AI_VIEW=windows STM_NOW=$((ASOF + 901))
assert_eq "$(lines icon.drawing=on "icon=5h  --" "icon.color=$GREY" "label=7d  60%" "label.color=$GREY" \
  label.y_offset=-5 label.width=68)" "$(seg stm.ai)" "stale lines grey"
run_plugin "$FIXTURE" STM_AI_VIEW=windows AUB_MODE=fail
assert_eq "$(lines icon.drawing=off label=-- "label.color=$GREY" label.y_offset=0 label.width=28)" \
  "$(seg stm.ai)" "no data"
run_plugin "$FIXTURE" STM_AI_VIEW=cost
assert_eq "$(lines "label=\$164" "label.color=$WHITE" label.width=44)" "$(seg stm.ai)" "cost"
assert_eq "background.color=$YELLOW" "$(seg stm.ai.icon)" "cost keeps the worst band"
printf '{"asOf":"2026-10-08T05:49:39Z","totals":{"costUSD":"12345.6","tokens":5},"providers":[]}' >"$J"
run_plugin "$J" STM_AI_VIEW=cost
assert_eq "label=\$12k" "$(seg stm.ai | head -1)" "cost >= 10000"
run_plugin "$FIXTURE" STM_AI_VIEW=cost AUB_MODE=fail
assert_eq "label=\$--" "$(seg stm.ai | head -1)" "cost no data"
printf '{"asOf":"2026-10-08T05:49:39Z","totals":{"costUSD":"12.5","tokens":1000000000000},"providers":[]}' >"$J"
run_plugin "$J" STM_AI_VIEW=cost
assert_eq "label=\$13" "$(seg stm.ai | head -1)" "cost shows with no window"
assert_contains "$(seg stm.ai.row.head)" "label=\$12.50 · 999B+ tok"
done_it

it "aub lookup order and the temp dir (I.aub, V48)"
H="$SANDBOX/home"
APP="$H/Applications/AgentsUsageBar.app/Contents/MacOS"
mkdir -p "$H/.local/bin" "$APP" "$SANDBOX/pathbin"
for f in "$H/.local/bin/aub" "$APP/AgentsUsageBar" "$SANDBOX/pathbin/aub"; do
  # shellcheck disable=SC2016 # the fake expands these when it runs
  printf '#!/bin/sh\nprintf "%%s\\n" "%s" >"$SB_LOG.which"\nexec /bin/cat "$AUB_JSON"\n' "$f" >"$f"
  chmod 755 "$f"
done
which_ran() {
  rm -f "$SB_LOG.which"
  run_plugin "$FIXTURE" STM_AUB= HOME="$H" PATH="$FAKE_BIN:$SANDBOX/pathbin:/bin"
  cat "$SB_LOG.which" 2>/dev/null || true
}
assert_eq "$H/.local/bin/aub" "$(which_ran)" "HOME/.local/bin first"
rm "$H/.local/bin/aub"
if [ ! -e /Applications/AgentsUsageBar.app ]; then
  assert_eq "$APP/AgentsUsageBar" "$(which_ran)" "then HOME/Applications"
  rm "$APP/AgentsUsageBar"
  assert_eq "$SANDBOX/pathbin/aub" "$(which_ran)" "then PATH"
fi
run_plugin "$FIXTURE"
run_plugin "$FIXTURE" AUB_MODE=fail
run_plugin "$FIXTURE" AUB_MODE=hang
assert_eq "" "$(ls -d "$SANDBOX"/stm-ai.* 2>/dev/null)" "temp dir removed after ok, fail and hang"
rm -f "$SB_LOG"
env -i HOME="$HOME" PATH="$FAKE_BIN:/bin" SB_LOG="$SB_LOG" STM_AUB="$SANDBOX/aub" AUB_JSON="$FIXTURE" \
  STM_AI_VIEW=worst /bin/sh "$PLUGIN" >/dev/null 2>&1
assert_contains "$(cat "$SB_LOG" 2>/dev/null)" "label= 79% 7d" "no TMPDIR: per-user temp dir"
done_it

it "shape decides where the state colour goes (V32, V50)"
for shape in plain pill; do
  run_plugin "$FIXTURE" STM_AI_SHAPE=$shape
  assert_eq "$(lines "label= 79% 7d" "label.color=$WHITE" label.width=68 "icon.color=$YELLOW")" \
    "$(seg stm.ai)" "$shape"
  assert_eq "" "$(seg stm.ai.icon)" "$shape: no icon sub-item"
done
done_it

it "popup rows: title, accounts, sign in, balance, reset, cost (V52)"
run_plugin "$FIXTURE"
assert_eq "$(lines icon=today "label=\$163.80 · 102.0M tok · as of 05:49")" "$(seg stm.ai.row.head)" "head"
  n=0
  while IFS='|' read -r name label color icolor; do
    assert_eq "$(lines drawing=on "icon=$name" "icon.color=${!icolor}" "label=$label" \
      "label.color=${!color}")" "$(seg stm.ai.row.$n)" "row $n"
    n=$((n + 1))
  done <<'EOF'
Claude|$163.71 spent|WHITE|WHITE
  personal|███████▉░░  79% 7d  ↻ 1d 8h  $96.72|YELLOW|WHITE
  work|███▎░░░░░░  33% 7d  ↻ 2d 8h  $66.99|GREEN|WHITE
Codex|$0.09 spent|WHITE|WHITE
  plus|█▍░░░░░░░░  14% 7d  ↻ 4d 18h|GREEN|WHITE
  team|▎░░░░░░░░░   3% 7d  ↻ 4d 18h|GREEN|WHITE
Gemini|sign in|GREY|GREY
Grok|████▏░░░░░  41%  ↻ 3d 22h|GREEN|WHITE
OpenRouter|█████████▋  96%  $5.95 left|RED|WHITE
EOF
  for n in 9 10 11; do
    assert_eq "drawing=off" "$(seg stm.ai.row.$n)" "row $n unused"
  done
  assert_eq "label=Open Agents Usage Bar" "$(seg stm.ai.row.foot)" "foot"
done_it

it "popup: status words, one-account provider, balance without a fraction (V52)"
printf '{"asOf":"2026-10-08T05:49:39Z","providers":[%s]}' \
  '{"id":"claude","status":"notRunning"},{"id":"codex","status":"error"},{"id":"gemini","status":"stale"},{"id":"grok","status":"disabled"},{"id":"openrouter","status":"unauthenticated"},{"id":"ollama-cloud","status":"weird"}' >"$J"
run_plugin "$J"
n=0
for row in "Claude|not running" "Codex|error" "Gemini|stale" "OpenRouter|sign in"; do
  assert_eq "$(lines drawing=on "icon=${row%%|*}" "icon.color=$GREY" "label=${row#*|}" "label.color=$GREY")" \
    "$(seg stm.ai.row.$n)" "status $row"
  n=$((n + 1))
done
assert_eq "drawing=off" "$(seg stm.ai.row.4)" "disabled and unknown statuses: no row"
printf '{"asOf":"2026-10-08T05:49:39Z","providers":[%s]}' \
  '{"id":"codex","status":"ok","costTodayUSD":"9","accounts":[{"name":"plus","costTodayUSD":"1.25","quotaWindows":[{"name":"primary","utilization":0.2}]}]},{"id":"openrouter","status":"ok","balanceUSD":"5"}' >"$J"
run_plugin "$J"
assert_eq "$(lines drawing=on "icon=Codex" "icon.color=$WHITE" "label=██░░░░░░░░  20% 5h  \$1.25" \
  "label.color=$GREEN")" "$(seg stm.ai.row.0)" "one account: provider name, account cost"
assert_eq "$(lines drawing=on "icon=OpenRouter" "icon.color=$WHITE" "label=\$5.00 left" \
  "label.color=$WHITE")" "$(seg stm.ai.row.1)" "balance without a fraction"
done_it

it "popup: reset format and more than 12 rows (V52)"
mk_json "$J" 5h 0.5
run_plugin "$J" STM_NOW=$((1791453600 - 15320))
assert_contains "$(seg stm.ai.row.0)" "↻ 4h 15m"
run_plugin "$J" STM_NOW=$((1791453600 - 300))
assert_contains "$(seg stm.ai.row.0)" "↻ 5m"
run_plugin "$J" STM_NOW=1791453600
assert_not_contains "$(seg stm.ai.row.0)" "↻"
{
  printf '{"asOf":"2026-10-08T05:49:39Z","providers":[{"id":"claude","status":"ok","quotaWindows":[],"accounts":['
  i=1
  while [ $i -le 14 ]; do
    [ $i -gt 1 ] && printf ','
    printf '{"name":"a%d","quotaWindows":[{"name":"5h","utilization":0.1}]}' $i
    i=$((i + 1))
  done
  printf ']}]}'
} >"$J"
run_plugin "$J"
assert_contains "$(seg stm.ai.row.10)" "icon=  a10"
assert_eq "$(lines drawing=on "icon=" "icon.color=$WHITE" "label=+4 more" "label.color=$GREY")" \
  "$(seg stm.ai.row.11)" "+N more"
done_it

it "foot row opens the app, or its download page when aub is absent (V52)"
run_plugin "$FIXTURE" SENDER=mouse.clicked STM_AI_ACTION=open
assert_eq "-b app.agents-usage-bar" "$OPENED" "open app"
run_plugin "$FIXTURE" SENDER=mouse.clicked STM_AI_ACTION=open STM_AUB="$SANDBOX/no-such-aub"
assert_eq "https://github.com/noomz/agents_usage_bar" "$OPENED" "download page"
run_plugin "$FIXTURE" STM_AI_ACTION=evil
assert_eq "" "$OPENED" "unknown action: nothing opened"
done_it

it "label width: pad + ceil(chars x CW); unknown font sends none (V46)"
run_plugin "$FIXTURE" STM_AI_CW= STM_AI_PAD=
assert_eq "$(lines "label= 79% 7d" "label.color=$WHITE")" "$(seg stm.ai)" "no width without a font size"
run_plugin "$FIXTURE" STM_AI_CW='8;x' STM_AI_PAD=12
assert_eq "$(lines "label= 79% 7d" "label.color=$WHITE")" "$(seg stm.ai)" "no width from a bad CW"
done_it

it "a palette without a colour sends no empty colour (V14)"
run_plugin "$FIXTURE" STM_YELLOW= STM_WHITE=
assert_eq "$(lines "label= 79% 7d" label.width=68)" "$(seg stm.ai)" "no white"
assert_eq "" "$(seg stm.ai.icon)" "no yellow"
assert_eq "$(lines drawing=on "icon=  personal" "label=███████▉░░  79% 7d  ↻ 1d 8h  \$96.72")" \
  "$(seg stm.ai.row.1)" "row without colours"
done_it

it "lint and install item:ai (V4, I.fs, I.cfg)"
STM_ROOT="$REPO_ROOT" run_stm --porcelain lint item:ai
assert_status 0
assert_eq "ok	item:ai" "$STM_OUT"
D="$SANDBOX/cfg"
make_lua_config "$D"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install item:ai
assert_status 0
assert_files_equal "$PLUGIN" "$D/plugins/stm/ai.sh"
loader=$(cat "$D/items_generated.lua")
for opt in '["shape"] = "split"' '["view"] = "worst"' '["provider"] = "all"' 'update_freq = 60,' \
  'events = { "system_woke" },' 'position = "right"'; do
  assert_contains "$loader" "$opt"
done
done_it

LUA_BIN=$(command -v lua 2>/dev/null || true)
if [ -n "$LUA_BIN" ]; then
  mkdir -p "$SANDBOX/lua"
  cat >"$SANDBOX/lua/probe.lua" <<'EOF'
local shape, view, position, query, item_lua = ...
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
local handlers, queries = {}, 0
local sbar = {}
function sbar.add(kind, name, a, b)
  if b ~= nil then
    print(kind .. " " .. name .. " " .. dump(a) .. " " .. dump(b))
  else
    print(kind .. " " .. name .. " " .. dump(a))
  end
  return {
    name = name,
    subscribe = function(_, events, fn)
      if type(events) ~= "table" then
        events = { events }
      end
      print("subscribe " .. name .. " " .. table.concat(events, " "))
      for _, ev in ipairs(events) do
        handlers[name .. " " .. ev] = fn
      end
    end,
    set = function(_, props) print("set " .. name .. " " .. dump(props)) end,
  }
end
function sbar.query(name)
  queries = queries + 1
  print("query " .. name)
  if query == "none" or (query == "late" and queries == 1) then
    return nil
  end
  return { label = { font = "Hack Nerd Font:Bold:13.00", padding_left = 6, padding_right = 6 },
    icon = { font = "Hack Nerd Font:Bold:17.00", padding_left = 4, padding_right = 4 } }
end
function sbar.exec(cmd) print("exec " .. cmd) end
local opts = { name = "stm.ai", position = position, update_freq = 60,
  plugin_dir = "/p", events = { "system_woke" }, options = { shape = shape, view = view, provider = "all" } }
dofile(item_lua)(sbar, opts, { green = 1, yellow = 2, red = 3, grey = 0xff445566, white = 5, black = 6,
  bg1 = 21, popup_bg = 31, popup_border = 32 })
handlers["stm.ai routine"]({ SENDER = "routine" })
handlers["stm.ai.row.foot mouse.clicked"]({ SENDER = "mouse.clicked" })
handlers["stm.ai mouse.clicked"]({ SENDER = "mouse.clicked" })
handlers["stm.ai mouse.exited.global"]({ SENDER = "mouse.exited.global" })
EOF
  probe() {
    "$LUA_BIN" "$SANDBOX/lua/probe.lua" "$1" "$2" "$3" "${4:-ok}" "$BUNDLE/item.lua" 2>&1
  }
  names_of() {
    probe "$1" "$2" "$3" | awk '$1 == "item" || $1 == "bracket" { print $1 " " $2 }' | grep -v '\.row\.'
  }
  line_of() {
    probe "$1" "$2" "$3" | grep -E "^(item|bracket) $4 "
  }

  it "item.lua names and order: icon sub-item left of the main item everywhere (V10, V33, V51)"
  assert_eq "item stm.ai" "$(names_of plain worst right)" "plain"
  assert_eq "item stm.ai" "$(names_of pill cost left)" "pill"
  assert_eq "item stm.ai
item stm.ai.icon" "$(names_of split worst right)" "split right"
  assert_eq "item stm.ai.icon
item stm.ai" "$(names_of split worst left)" "split left"
  assert_eq "item stm.ai
item stm.ai.icon" "$(names_of plain windows right)" "windows plain right"
  assert_eq "item stm.ai.icon
item stm.ai
bracket stm.ai.pill" "$(names_of pill windows center)" "windows pill center"
  rows=$(probe split worst right | awk '$1 == "item" && $2 ~ /\.row\./ { print $2 }' | tr '\n' ' ')
  assert_eq "stm.ai.row.head stm.ai.row.0 stm.ai.row.1 stm.ai.row.2 stm.ai.row.3 stm.ai.row.4 stm.ai.row.5 stm.ai.row.6 stm.ai.row.7 stm.ai.row.8 stm.ai.row.9 stm.ai.row.10 stm.ai.row.11 stm.ai.row.foot " \
    "$rows" "popup rows"
  done_it

  it "item.lua shapes: glyph, backgrounds, bracket members (V32, V51, V14)"
  assert_contains "$(line_of plain worst right stm.ai)" "icon={color=$((0xff445566)) string=$GLYPH}"
  assert_contains "$(line_of pill worst right stm.ai)" "background={color=21 drawing=true}"
  main=$(line_of split worst right stm.ai)
  assert_contains "$main" "background={color=21 drawing=true padding_left=0}"
  assert_contains "$main" "icon={drawing=false}"
  assert_contains "$(line_of split worst right stm.ai.icon)" \
    "background={color=$((0xff445566)) drawing=true} icon={color=6 string=$GLYPH} label={drawing=false}"
  assert_contains "$(line_of plain windows right stm.ai.icon)" "icon={color=$((0xff445566)) string=$GLYPH} label={drawing=false}"
  win=$(line_of plain windows right stm.ai)
  assert_contains "$win" "icon={drawing=false padding_left=0 padding_right=0 width=0 y_offset=6} label={padding_left=0 string=--}"
  sw=$(line_of split windows right stm.ai)
  assert_contains "$sw" "background={color=21 drawing=true padding_left=0}"
  assert_contains "$sw" "icon={drawing=false padding_left=0 padding_right=0 width=0 y_offset=6}"
  assert_contains "$(line_of split windows right stm.ai.icon)" "background={color=$((0xff445566)) drawing=true} icon={color=6 string=$GLYPH}"
  assert_eq "item stm.ai
item stm.ai.icon" "$(names_of split windows right)" "split windows right"
  assert_not_contains "$win" "item stm.ai {background="
  assert_contains "$(line_of pill windows right stm.ai.pill)" "{1=stm.ai.icon 2=stm.ai} {background={color=21 drawing=true}}"
  assert_contains "$(line_of split worst right stm.ai)" "popup={align=right background={border_color=32 border_width=2 color=31 corner_radius=12}}"
  assert_contains "$(line_of split worst left stm.ai)" "popup={align=left"
  done_it

  it "item.lua runs plugin.sh with its options, colours and metrics (V14, V46)"
  out=$(probe split worst right)
  env="exec STM_GREEN='0x00000001' STM_YELLOW='0x00000002' STM_RED='0x00000003' STM_GREY='0xff445566' STM_WHITE='0x00000005' STM_AI_SHAPE='split' STM_AI_VIEW='worst' STM_AI_PROVIDER='all'"
  assert_eq "$env STM_AI_CW='7.93' STM_AI_PAD='12' STM_AI_ACTION='' NAME='stm.ai' SENDER='forced' '/p/ai.sh'
$env STM_AI_CW='7.93' STM_AI_PAD='12' STM_AI_ACTION='' NAME='stm.ai' SENDER='routine' '/p/ai.sh'
$env STM_AI_CW='7.93' STM_AI_PAD='12' STM_AI_ACTION='open' NAME='stm.ai' SENDER='mouse.clicked' '/p/ai.sh'" \
    "$(printf '%s\n' "$out" | grep '^exec ')" "runs"
  assert_contains "$out" "subscribe stm.ai routine forced system_woke"
  assert_contains "$out" "subscribe stm.ai mouse.clicked"
  assert_contains "$out" "subscribe stm.ai mouse.exited.global"
  assert_contains "$out" "subscribe stm.ai.icon mouse.clicked"
  assert_contains "$out" "set stm.ai {popup={drawing=toggle}}"
  assert_contains "$out" "set stm.ai {popup={drawing=false}}"
  done_it

  it "item.lua sizes the popup name column from the rows' icon font (V52, B13)"
  out=$(probe split worst right)
  assert_contains "$out" "query stm.ai.row.head"
  for r in head 0 11; do
    assert_eq 1 "$(printf '%s\n' "$out" | grep -c "^set stm.ai.row.$r {icon={width=195}}$")" "row $r: 4+4 + ceil(18 x 17 x 0.61)"
  done
  assert_not_contains "$(probe split worst right none)" "width=195"
  done_it

  it "item.lua windows view: small font on the main item, metrics from it (V46, V51)"
  out=$(probe plain windows right)
  assert_contains "$out" "set stm.ai {icon={font=Hack Nerd Font:Bold:10.0} label={font=Hack Nerd Font:Bold:10.0}}"
  assert_contains "$out" "STM_AI_CW='6.10' STM_AI_PAD='12'"
  assert_not_contains "$(probe plain worst right)" "font="
  assert_not_contains "$(probe plain worst right none)" "STM_AI_CW='7"
  done_it
elif [ -n "${CI:-}" ]; then
  it "lua is available to run item.lua"
  _note_fail "lua not found; CI must run item.lua"
  done_it
else
  printf '# note: lua not found, item.lua not run\n'
fi

finish
