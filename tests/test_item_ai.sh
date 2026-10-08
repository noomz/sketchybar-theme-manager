#!/usr/bin/env bash
# stm.ai: AI provider quota use from the Agents Usage Bar cache, one bar
# segment per provider (#26, #27).

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

# Plugin PATH: our fakes plus /bin.
FAKE_BIN="$SANDBOX/ai-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/sketchybar" <<'EOF'
#!/bin/sh
printf 'call\n' >>"$SB_LOG.calls"
printf '%s\n' "$@" >>"$SB_LOG"
EOF

# Fake aub: logs its argv, then prints $AUB_JSON unless $AUB_MODE says not to.
# The odd hang duration, unique per test run, makes it findable with pgrep
# without catching another suite's hang (B14).
HANG_SECS=29.$$
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

# run_plugin <json file> [VAR=value...] — one run with a clean env, every
# provider `auto`, every segment measured at CW 7.93 + 12.
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
    STM_AI_SHAPE=split STM_AI_CLAUDE=auto STM_AI_CODEX=auto STM_AI_GEMINI=auto STM_AI_GROK=auto \
    STM_AI_OPENROUTER=auto \
    STM_AI_CW_CLAUDE=7.93 STM_AI_PAD_CLAUDE=12 STM_AI_CW_CODEX=7.93 STM_AI_PAD_CODEX=12 \
    STM_AI_CW_GEMINI=7.93 STM_AI_PAD_GEMINI=12 STM_AI_CW_GROK=7.93 STM_AI_PAD_GROK=12 \
    STM_AI_CW_OPENROUTER=7.93 STM_AI_PAD_OPENROUTER=12 \
    "$@" /bin/sh "$PLUGIN" >/dev/null 2>&1
  SB=$(cat "$SB_LOG" 2>/dev/null || true)
  SB_CALLS=$(grep -c . "$SB_LOG.calls" 2>/dev/null || true)
  AUB_ARGS=$(cat "$SB_LOG.aub" 2>/dev/null || true)
  OPENED=$(cat "$SB_LOG.open" 2>/dev/null || true)
}

# seg <item> — the properties every `--set <item>` sent, one per line.
seg() {
  printf '%s\n' "$SB" | awk -v n="$1" '$0 == "--set" { getline t; on = (t == n); next } on { print }'
}

# shown <segment> <label> <label colour> <width> — the main item of a shown
# split segment (no windows lines).
shown() {
  lines drawing=on "label=$2" "label.color=$3" "label.width=$4"
}

hidden() {
  lines drawing=off popup.drawing=off
}

lines() {
  printf '%s\n' "$@"
}

# mk_json <file> <provider> <window name> <utilization> [asOf] — one provider
# with one top-level window.
mk_json() {
  printf '{"asOf":"%s","totals":{"costUSD":"12.5","tokens":999},"providers":[{"id":"%s","status":"ok","costTodayUSD":null,"balanceUSD":null,"quota":null,"accounts":[],"quotaWindows":[{"name":"%s","utilization":%s,"resetsAt":"2026-10-08T10:00:00Z"}]}]}\n' \
    "${5-2026-10-08T05:49:39Z}" "$2" "$3" "$4" >"$1"
}

J="$SANDBOX/one.json"

it "one segment per provider: auto metric, tag colour, gemini without data hidden (V53, V54)"
run_plugin "$FIXTURE"
assert_eq "$(shown claude " 79% 7d" "$WHITE" 68)" "$(seg stm.ai.claude)" "claude worst"
assert_eq "$(lines drawing=on "background.color=$YELLOW")" "$(seg stm.ai.claude.icon)" "claude tag on the band"
assert_eq "$(shown codex " 14% wk" "$WHITE" 68)" "$(seg stm.ai.codex)" "codex worst, weekly suffix wk"
assert_eq "$(lines drawing=on "background.color=$GREEN")" "$(seg stm.ai.codex.icon)" "codex band"
assert_eq "$(hidden)" "$(seg stm.ai.gemini)" "gemini signed out, auto: hidden"
assert_eq "drawing=off" "$(seg stm.ai.gemini.icon)" "gemini tag hidden"
assert_eq "" "$(seg stm.ai.gemini.row.head)" "hidden segment: no popup rows set"
assert_eq "$(shown grok " 41%" "$WHITE" 44)" "$(seg stm.ai.grok)" "grok billing, no suffix"
assert_eq "$(shown openrouter "\$5.95" "$WHITE" 52)" "$(seg stm.ai.openrouter)" "openrouter balance"
assert_eq "$(lines drawing=on "background.color=$RED")" "$(seg stm.ai.openrouter.icon)" "openrouter tag: quota band"
assert_eq "" "$(seg stm.ai)" "driver untouched"
assert_eq "" "$(seg stm.ai.ollama-cloud)" "ollama-cloud has no segment"
assert_eq "usage --json" "$AUB_ARGS" "one fixed aub call (V48)"
assert_eq 1 "$SB_CALLS" "one sketchybar call (V56)"
done_it

it "metric per provider and value (V53)"
while read -r var value item label width tag; do
  run_plugin "$FIXTURE" "$var=$value"
  assert_eq "$(shown x "${label//_/ }" "$WHITE" "$width")" "$(seg "$item")" "$var=$value"
  assert_eq "$(lines drawing=on "background.color=${!tag}")" "$(seg "$item.icon")" "$var=$value tag"
done <<'EOF'
STM_AI_CLAUDE worst stm.ai.claude _79%_7d 68 YELLOW
STM_AI_CLAUDE 5h stm.ai.claude _41%_5h 68 YELLOW
STM_AI_CLAUDE 7d stm.ai.claude _79%_7d 68 YELLOW
STM_AI_CLAUDE sonnet stm.ai.claude _12%_7d-s 84 YELLOW
STM_AI_CLAUDE opus stm.ai.claude _62%_7d-o 84 YELLOW
STM_AI_CLAUDE cost stm.ai.claude $164 44 YELLOW
STM_AI_CODEX worst stm.ai.codex _14%_wk 68 GREEN
STM_AI_CODEX 5h stm.ai.codex __3%_5h 68 GREEN
STM_AI_CODEX weekly stm.ai.codex _14%_wk 68 GREEN
STM_AI_CODEX cost stm.ai.codex $0.09 52 GREEN
STM_AI_GROK billing stm.ai.grok _41% 44 GREEN
STM_AI_OPENROUTER balance stm.ai.openrouter $5.95 52 RED
STM_AI_OPENROUTER quota stm.ai.openrouter _96% 44 RED
EOF
done_it

it "gemini with per-model windows; cost / balance without a pct is white (V53, V54)"
printf '{"asOf":"2026-10-08T05:49:39Z","providers":[{"id":"gemini","status":"ok","accounts":[],"quotaWindows":[{"name":"gemini-2.5-pro","utilization":0.62},{"name":"gemini-2.5-flash","utilization":0.2}]},{"id":"claude","status":"ok","costTodayUSD":"3.5"},{"id":"openrouter","status":"ok","balanceUSD":"12"}]}' >"$J"
run_plugin "$J"
assert_eq "$(shown x " 62%" "$WHITE" 44)" "$(seg stm.ai.gemini)" "gemini worst model, no suffix"
assert_eq "$(lines drawing=on "background.color=$YELLOW")" "$(seg stm.ai.gemini.icon)" "gemini band"
assert_eq "$(hidden)" "$(seg stm.ai.claude)" "claude auto, no window: hidden"
assert_eq "$(shown x "\$12.00" "$WHITE" 60)" "$(seg stm.ai.openrouter)" "balance, no fraction"
assert_eq "$(lines drawing=on "background.color=$WHITE")" "$(seg stm.ai.openrouter.icon)" "no pct: white tag"
run_plugin "$J" STM_AI_CLAUDE=cost
assert_eq "$(shown x "\$3.50" "$WHITE" 52)" "$(seg stm.ai.claude)" "claude cost"
assert_eq "$(lines drawing=on "background.color=$WHITE")" "$(seg stm.ai.claude.icon)" "cost w/o pct: white tag"
done_it

it "explicit metric always shown: sign in, -- when not usable (V54)"
run_plugin "$FIXTURE" STM_AI_GEMINI=worst
assert_eq "$(shown x "sign in" "$GREY" 68)" "$(seg stm.ai.gemini)" "gemini signed out"
assert_eq "$(lines drawing=on "background.color=$GREY")" "$(seg stm.ai.gemini.icon)" "sign in: grey tag"
mk_json "$J" claude 7d 0.5
run_plugin "$J" STM_AI_CODEX=weekly STM_AI_GROK=billing STM_AI_CLAUDE=sonnet
assert_eq "$(shown x -- "$GREY" 28)" "$(seg stm.ai.codex)" "codex absent: --"
assert_eq "$(shown x -- "$GREY" 28)" "$(seg stm.ai.grok)" "grok absent: --"
assert_eq "$(shown x -- "$GREY" 28)" "$(seg stm.ai.claude)" "claude no sonnet window: --"
assert_eq "$(lines drawing=on "background.color=$GREY")" "$(seg stm.ai.claude.icon)" "--: grey tag"
assert_eq "$(hidden)" "$(seg stm.ai.openrouter)" "openrouter auto, absent: hidden"
printf '{"asOf":"2026-10-08T05:49:39Z","providers":[{"id":"codex","status":"notRunning"}]}' >"$J"
run_plugin "$J" STM_AI_CODEX=worst
assert_eq "$(shown x -- "$GREY" 28)" "$(seg stm.ai.codex)" "not running: --"
done_it

it "key off: no segment set, all off: no aub run (V54, V56)"
run_plugin "$FIXTURE" STM_AI_CLAUDE=off STM_AI_GROK=off
assert_eq "" "$(seg stm.ai.claude)" "claude off"
assert_eq "" "$(seg stm.ai.claude.row.head)" "claude off: no popup"
assert_eq "" "$(seg stm.ai.grok)" "grok off"
assert_contains "$(seg stm.ai.codex)" "label= 14% wk"
run_plugin "$FIXTURE" STM_AI_CLAUDE=off STM_AI_CODEX=off STM_AI_GEMINI=off STM_AI_GROK=off STM_AI_OPENROUTER=off
assert_eq "" "$AUB_ARGS" "every key off: no aub"
assert_eq "" "$SB" "every key off: nothing to set"
run_plugin "$FIXTURE" STM_AI_CLAUDE=evil STM_AI_CODEX=off STM_AI_GEMINI=off STM_AI_GROK=off STM_AI_OPENROUTER=off
assert_eq "" "$AUB_ARGS" "a value outside the manifest counts as off"
done_it

it "aub absent: no aub on the first enabled segment only (V54, V55)"
run_plugin "$FIXTURE" STM_AUB="$SANDBOX/no-such-aub"
assert_eq "$(shown x "no aub" "$GREY" 60)" "$(seg stm.ai.claude)" "first segment"
assert_eq "$(lines drawing=on "background.color=$GREY")" "$(seg stm.ai.claude.icon)" "grey tag"
for p in codex gemini grok openrouter; do
  assert_eq "$(hidden)" "$(seg "stm.ai.$p")" "$p hidden"
done
assert_eq "" "$AUB_ARGS" "nothing run"
assert_eq "$(lines icon=aub "label=aub not found")" "$(seg stm.ai.claude.row.head)" "head"
assert_contains "$(seg stm.ai.claude.row.0)" "label=install Agents Usage Bar, then run aub install"
assert_eq "label=Get Agents Usage Bar" "$(seg stm.ai.claude.row.foot)" "foot"
run_plugin "$FIXTURE" STM_AUB="$SANDBOX/no-such-aub" STM_AI_CLAUDE=off STM_AI_CODEX=off
assert_eq "$(shown x "no aub" "$GREY" 60)" "$(seg stm.ai.gemini)" "first enabled is gemini"
assert_eq "$(hidden)" "$(seg stm.ai.grok)" "grok hidden"
done_it

it "no data: aub fails, hangs, prints garbage; first enabled segment only (V48, V54)"
for mode in fail garbage empty; do
  run_plugin "$FIXTURE" AUB_MODE=$mode STM_AI_CLAUDE=off
  assert_eq "$(shown x -- "$GREY" 28)" "$(seg stm.ai.codex)" "aub $mode"
  assert_eq "$(lines drawing=on "background.color=$GREY")" "$(seg stm.ai.codex.icon)" "aub $mode: grey"
  assert_eq "$(hidden)" "$(seg stm.ai.grok)" "aub $mode: rest hidden"
  assert_contains "$(seg stm.ai.codex.row.head)" "label=no cached usage yet"
  assert_contains "$(seg stm.ai.codex.row.0)" "label=open the app to start polling"
  assert_contains "$(seg stm.ai.codex.row.1)" "drawing=off"
  assert_eq "label=Open Agents Usage Bar" "$(seg stm.ai.codex.row.foot)" "foot"
done
start=$(date +%s)
run_plugin "$FIXTURE" AUB_MODE=hang
elapsed=$(($(date +%s) - start))
assert_eq "label=--" "$(seg stm.ai.claude | sed -n 2p)" "hang"
[ "$elapsed" -le 6 ] || _note_fail "hang took ${elapsed}s, want <= 6"
sleep 0.5
if pgrep -f "sleep $HANG_SECS\$" >/dev/null; then
  pkill -f "sleep $HANG_SECS\$"
  _note_fail "hung aub left running"
fi
done_it

it "hostile JSON shapes: wrong types skipped, caps, first id wins (V49, B11)"
grok() {
  printf '{"id":"grok","status":"ok","accounts":[],"quotaWindows":%s}' "$1"
}
doc() {
  printf '{"asOf":"2026-10-08T05:49:39Z","totals":{"costUSD":"1","tokens":1},"providers":%s}' "$1" >"$J"
}
W60='[{"name":"billing","utilization":0.6}]'
# case_of <what> <providers JSON> <expected grok label>
case_of() {
  doc "$2"
  run_plugin "$J" STM_AI_GROK=billing
  assert_eq "label=$3" "$(seg stm.ai.grok | sed -n 2p)" "$1"
}
case_of "non-object provider skipped" "[\"x\",$(grok "$W60")]" " 60%"
case_of "non-object window skipped" "[$(grok '[1,{"name":"billing","utilization":0.6}]')]" " 60%"
case_of "array utilization skipped" "[$(grok '[{"name":"billing","utilization":[1,2]}]')]" "--"
case_of "exponent utilization skipped" "[$(grok '[{"name":"billing","utilization":1e-7}]')]" "--"
case_of "first provider per id wins" \
  "[$(grok '[{"name":"billing","utilization":0.3}]'),$(grok '[{"name":"billing","utilization":0.9}]')]" " 30%"
many=$(i=0; printf '['; while [ $i -lt 39 ]; do printf '{"name":"billing","utilization":0.1},'; i=$((i + 1)); done
  printf '{"name":"billing","utilization":0.99}]')
case_of "only 32 windows read" "[$(grok "$many")]" " 10%"
far=$(i=0; printf '['; while [ $i -lt 40 ]; do printf '{"id":"evil%d"},' $i; i=$((i + 1)); done; grok "$W60"; printf ']')
case_of "only 32 providers read" "$far" "--"
doc "[{\"id\":\"claude\",\"status\":\"ok\",\"accounts\":\"zz\",\"quotaWindows\":[{\"name\":\"7d\",\"utilization\":0.6}]}]"
run_plugin "$J"
assert_eq "label= 60% 7d" "$(seg stm.ai.claude | sed -n 2p)" "accounts not an array: top level used"
printf '{"providers":{"a":%s}}' "$(grok "$W60")" >"$J"
run_plugin "$J"
assert_eq "label=--" "$(seg stm.ai.claude | sed -n 2p)" "providers an object: no data"
assert_contains "$(seg stm.ai.claude.row.head)" "label=no cached usage yet"
printf '[]' >"$J"
run_plugin "$J"
assert_eq "label=--" "$(seg stm.ai.claude | sed -n 2p)" "top level an array: no data"
printf '{"asOf":"2026-10-08T05:49:39Z","providers":[{"id":"claude","status":"ok","costTodayUSD":[1],"tokensToday":[1],"accounts":[{"name":["x"],"quotaWindows":%s},{"name":7,"quotaWindows":%s}]}]}' \
  '[{"name":"7d","utilization":0.6}]' '[{"name":"7d","utilization":0.6}]' >"$J"
run_plugin "$J"
assert_contains "$(seg stm.ai.claude.row.0)" "icon=account 1"
assert_contains "$(seg stm.ai.claude.row.2)" "icon=account 2"
assert_eq "$(lines icon=today "label=as of 05:49")" "$(seg stm.ai.claude.row.head)" "bad cost + tokens omitted"
done_it

it "bands at 49/50/79/80, clamp, rounding (V50)"
while read -r util label color; do
  mk_json "$J" grok billing "$util"
  run_plugin "$J"
  assert_eq "label=${label//_/ }" "$(seg stm.ai.grok | sed -n 2p)" "util $util"
  assert_eq "background.color=${!color}" "$(seg stm.ai.grok.icon | sed -n 2p)" "util $util band"
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

it "worst suffix map, codex secondary = wk (V51, V53)"
while read -r prov name label; do
  mk_json "$J" "$prov" "$name" 0.5
  run_plugin "$J"
  assert_eq "label=${label//_/ }" "$(seg "stm.ai.$prov" | sed -n 2p)" "$prov window $name"
done <<'EOF'
claude 5h _50%_5h
claude 7d _50%_7d
claude 7d-opus _50%_7d
claude 7d-sonnet _50%_7d
claude other _50%
codex primary _50%_5h
codex secondary _50%_wk
gemini 2.5-pro _50%
gemini 5h _50%
gemini 7d _50%
gemini primary _50%
gemini secondary _50%
EOF
done_it

it "stale after 900 s: every shown segment keeps its value, grey (V50, V54)"
mk_json "$J" grok billing 0.9
run_plugin "$J" STM_NOW=$((ASOF + 900))
assert_eq "$(shown x " 90%" "$WHITE" 44)" "$(seg stm.ai.grok)" "900 s: fresh"
assert_eq "background.color=$RED" "$(seg stm.ai.grok.icon | sed -n 2p)" "900 s: band"
run_plugin "$J" STM_NOW=$((ASOF + 901))
assert_eq "$(shown x " 90%" "$GREY" 44)" "$(seg stm.ai.grok)" "901 s: stale"
assert_eq "background.color=$GREY" "$(seg stm.ai.grok.icon | sed -n 2p)" "901 s: grey"
assert_eq "$(lines icon=today "label=stale · as of 05:49")" "$(seg stm.ai.grok.row.head)" "stale head"
run_plugin "$FIXTURE" STM_NOW=$((ASOF + 901))
for p in claude codex grok openrouter; do
  assert_eq "label.color=$GREY" "$(seg "stm.ai.$p" | sed -n 3p)" "$p stale"
done
assert_eq "$(hidden)" "$(seg stm.ai.gemini)" "stale: gemini still hidden"
for bad in yesterday "2026-10-08 05:49:39" "2026-13-08T05:49:39Z" "2026-10-08T05:49:39+07:00" \
  "2026-10-08T05:49:39" "1969-12-31T23:59:59Z" ""; do
  mk_json "$J" grok billing 0.9 "$bad"
  run_plugin "$J"
  assert_eq "label.color=$GREY" "$(seg stm.ai.grok | sed -n 3p)" "asOf [$bad]: stale"
done
mk_json "$J" grok billing 0.9 "2026-10-08T05:49:39.250Z"
run_plugin "$J"
assert_eq "label.color=$WHITE" "$(seg stm.ai.grok | sed -n 3p)" "fractional seconds: fresh"
mk_json "$J" grok billing 0.9
run_plugin "$J" STM_NOW=$((ASOF - 300))
assert_eq "label.color=$WHITE" "$(seg stm.ai.grok | sed -n 3p)" "asOf 300 s ahead: fresh"
run_plugin "$J" STM_NOW=$((ASOF - 301))
assert_eq "label.color=$GREY" "$(seg stm.ai.grok | sed -n 3p)" "asOf 301 s ahead: stale"
done_it

it "cost and balance format bounds (V53)"
while read -r var key amount label; do
  if [ "$key" = costTodayUSD ]; then p=claude; else p=openrouter; fi
  printf '{"asOf":"2026-10-08T05:49:39Z","providers":[{"id":"%s","status":"ok","%s":"%s"}]}' "$p" "$key" "$amount" >"$J"
  run_plugin "$J" "$var"
  assert_eq "label=$label" "$(seg "stm.ai.$p" | sed -n 2p)" "$key $amount"
done <<'EOF'
STM_AI_CLAUDE=cost costTodayUSD 9.99 $9.99
STM_AI_CLAUDE=cost costTodayUSD 10 $10
STM_AI_CLAUDE=cost costTodayUSD 999.99 $1000
STM_AI_CLAUDE=cost costTodayUSD 9999.4 $9999
STM_AI_CLAUDE=cost costTodayUSD 10000 $10k
STM_AI_CLAUDE=cost costTodayUSD 12345.6 $12k
STM_AI_OPENROUTER=balance balanceUSD 9.99 $9.99
STM_AI_OPENROUTER=balance balanceUSD 999.99 $999.99
STM_AI_OPENROUTER=balance balanceUSD 1000 $1000
STM_AI_OPENROUTER=balance balanceUSD 10000 $10k
STM_AI_OPENROUTER=balance balanceUSD 1;rm --
EOF
done_it

it "windows metric: 5h over 7d (codex wk), falls back to one line (V51, V53)"
run_plugin "$FIXTURE" STM_AI_CLAUDE=windows
assert_eq "$(lines drawing=on icon.drawing=on "icon=5h  41%" "icon.color=$GREEN" "label=7d  79%" \
  "label.color=$YELLOW" label.y_offset=-5 label.width=68)" "$(seg stm.ai.claude)" "claude windows"
assert_eq "$(lines drawing=on "background.color=$YELLOW")" "$(seg stm.ai.claude.icon)" "split tag"
run_plugin "$FIXTURE" STM_AI_CODEX=windows
assert_eq "$(lines drawing=on icon.drawing=on "icon=5h   3%" "icon.color=$GREEN" "label=wk  14%" \
  "label.color=$GREEN" label.y_offset=-5 label.width=68)" "$(seg stm.ai.codex)" "codex lines 5h wk"
run_plugin "$FIXTURE" STM_AI_CLAUDE=windows STM_AI_SHAPE=plain
assert_eq "$(lines drawing=on "icon.color=$YELLOW")" "$(seg stm.ai.claude.icon)" "plain: tag colour on .icon"
run_plugin "$FIXTURE" STM_AI_CLAUDE=windows STM_AI_SHAPE=pill
assert_eq "drawing=on" "$(seg stm.ai.claude.pill)" "pill bracket shown"
assert_eq "" "$(seg stm.ai.codex.pill)" "no bracket outside windows"
mk_json "$J" claude 7d 0.6
run_plugin "$J" STM_AI_CLAUDE=windows
assert_eq "$(lines drawing=on icon.drawing=on "icon=5h  --" "icon.color=$GREY" "label=7d  60%" \
  "label.color=$YELLOW" label.y_offset=-5 label.width=68)" "$(seg stm.ai.claude)" "absent 5h"
run_plugin "$J" STM_AI_CLAUDE=windows STM_NOW=$((ASOF + 901))
assert_eq "$(lines drawing=on icon.drawing=on "icon=5h  --" "icon.color=$GREY" "label=7d  60%" \
  "label.color=$GREY" label.y_offset=-5 label.width=68)" "$(seg stm.ai.claude)" "stale lines grey"
mk_json "$J" claude other 0.6
run_plugin "$J" STM_AI_CLAUDE=windows
assert_eq "$(lines drawing=on icon.drawing=off "label= 60%" "label.color=$WHITE" label.y_offset=0 label.width=44)" \
  "$(seg stm.ai.claude)" "no 5h/7d: one line"
printf '{"asOf":"2026-10-08T05:49:39Z","providers":[{"id":"claude","status":"ok","accounts":[],"quotaWindows":[{"name":"7d","utilization":0.2},{"name":"7d-opus","utilization":0.9},{"name":"5h-x","utilization":0.9}]}]}' >"$J"
run_plugin "$J" STM_AI_CLAUDE=windows
assert_eq "$(lines drawing=on icon.drawing=on "icon=5h  --" "icon.color=$GREY" "label=7d  20%" \
  "label.color=$GREEN" label.y_offset=-5 label.width=68)" "$(seg stm.ai.claude)" "lines: exact 5h / 7d only (B15)"
run_plugin "$FIXTURE" STM_AI_CLAUDE=windows AUB_MODE=fail
assert_eq "$(lines drawing=on icon.drawing=off label=-- "label.color=$GREY" label.y_offset=0 label.width=28)" \
  "$(seg stm.ai.claude)" "no data"
run_plugin "$FIXTURE" STM_AI_CLAUDE=windows STM_AI_SHAPE=pill AUB_MODE=fail STM_AI_CODEX=windows
assert_eq "$(lines drawing=off popup.drawing=off)" "$(seg stm.ai.codex)" "hidden windows segment"
assert_eq "drawing=off" "$(seg stm.ai.codex.icon)" "hidden .icon"
assert_eq "drawing=off" "$(seg stm.ai.codex.pill)" "hidden bracket"
done_it

it "shape decides where the tag colour goes (V32, V53)"
for shape in plain pill; do
  run_plugin "$FIXTURE" STM_AI_SHAPE=$shape
  assert_eq "$(lines drawing=on "label= 79% 7d" "label.color=$WHITE" label.width=68 "icon.color=$YELLOW")" \
    "$(seg stm.ai.claude)" "$shape"
  assert_eq "" "$(seg stm.ai.claude.icon)" "$shape: no icon sub-item"
  assert_eq "$(hidden)" "$(seg stm.ai.gemini)" "$shape: hidden, no .icon"
done
done_it

it "popups per segment: head, accounts, windows, no limit (V55)"
run_plugin "$FIXTURE"
# rows <segment> — compare each `name|label|label colour|name colour` line.
rows() {
  local n=0 name label color icolor
  while IFS='|' read -r name label color icolor; do
    assert_eq "$(lines drawing=on "icon=$name" "icon.color=${!icolor}" "label=$label" \
      "label.color=${!color}")" "$(seg "stm.ai.$1.row.$n")" "$1 row $n"
    n=$((n + 1))
  done
  while [ $n -lt 12 ]; do
    assert_eq "drawing=off" "$(seg "stm.ai.$1.row.$n")" "$1 row $n unused"
    n=$((n + 1))
  done
  assert_eq "label=Open Agents Usage Bar" "$(seg "stm.ai.$1.row.foot")" "$1 foot"
}
assert_eq "$(lines icon=today "label=\$163.71 · 101.0M tok · as of 05:49")" "$(seg stm.ai.claude.row.head)" "claude head"
rows claude <<'EOF'
default|no limit|GREY|GREY
personal|$96.72|WHITE|WHITE
  5h|████▏░░░░░  41%  ↻ 4h 9m|GREEN|WHITE
  7d|███████▉░░  79%  ↻ 1d 8h|YELLOW|WHITE
  7d-sonnet|█▎░░░░░░░░  12%  ↻ 1d 8h|GREEN|WHITE
  7d-opus|██████▎░░░  62%  ↻ 1d 8h|YELLOW|WHITE
work|$66.99|WHITE|WHITE
  5h|▌░░░░░░░░░   5%  ↻ 4h 9m|GREEN|WHITE
  7d|███▎░░░░░░  33%  ↻ 2d 8h|GREEN|WHITE
EOF
assert_eq "$(lines icon=today "label=\$0.09 · 1.0M tok · as of 05:49")" "$(seg stm.ai.codex.row.head)" "codex head"
rows codex <<'EOF'
plus||WHITE|WHITE
  5h|▎░░░░░░░░░   3%  ↻ 4h 9m|GREEN|WHITE
  weekly|█▍░░░░░░░░  14%  ↻ 4d 18h|GREEN|WHITE
team||WHITE|WHITE
  5h|▎░░░░░░░░░   2%  ↻ 4h 9m|GREEN|WHITE
  weekly|▎░░░░░░░░░   3%  ↻ 4d 18h|GREEN|WHITE
EOF
assert_eq "$(lines icon=today "label=as of 05:49")" "$(seg stm.ai.grok.row.head)" "grok head: nothing to omit"
rows grok <<'EOF'
billing|████▏░░░░░  41%  ↻ 3d 22h  41 / 100|GREEN|WHITE
EOF
assert_eq "$(lines icon=today "label=\$0.27 · as of 05:49")" "$(seg stm.ai.openrouter.row.head)" "openrouter head"
rows openrouter <<'EOF'
credits|█████████▋  96%  $5.95 left|RED|WHITE
limit|$160.00|WHITE|WHITE
EOF
run_plugin "$FIXTURE" STM_AI_GEMINI=worst
rows gemini <<'EOF'
Gemini|sign in|GREY|GREY
EOF
printf '{"asOf":"2026-10-08T05:49:39Z","providers":[{"id":"claude","status":"ok","accounts":[{"name":"home","quotaWindows":[]}],"quotaWindows":[{"name":"7d","utilization":0.6}]}]}' >"$J"
run_plugin "$J"
assert_eq "label= 60% 7d" "$(seg stm.ai.claude | sed -n 2p)" "no account windows: top level counts"
rows claude <<'EOF'
home|no limit|GREY|GREY
7d|██████░░░░  60%|YELLOW|WHITE
EOF
done_it

it "popup: gemini models, status words, +N more, reset format (V55)"
printf '{"asOf":"2026-10-08T05:49:39Z","providers":[{"id":"gemini","status":"ok","accounts":[],"quotaWindows":[{"name":"gemini-2.5-pro\\t\\u00e9","utilization":0.62},{"name":"\\u0e07","utilization":0.2}]}]}' >"$J"
run_plugin "$J"
assert_eq "$(lines drawing=on "icon=gemini-2.5-pro" "icon.color=$WHITE" "label=██████▎░░░  62%" \
  "label.color=$YELLOW")" "$(seg stm.ai.gemini.row.0)" "model name cleaned"
assert_contains "$(seg stm.ai.gemini.row.1)" "icon=model 2"
printf '{"asOf":"2026-10-08T05:49:39Z","providers":[%s]}' \
  '{"id":"claude","status":"notRunning"},{"id":"codex","status":"error"},{"id":"gemini","status":"stale"},{"id":"grok","status":"disabled"},{"id":"openrouter","status":"weird"}' >"$J"
run_plugin "$J" STM_AI_CLAUDE=worst STM_AI_CODEX=worst STM_AI_GEMINI=worst STM_AI_GROK=billing STM_AI_OPENROUTER=balance
for row in "claude|Claude|not running" "codex|Codex|error" "gemini|Gemini|stale"; do
  p=${row%%|*}
  rest=${row#*|}
  assert_eq "$(lines drawing=on "icon=${rest%%|*}" "icon.color=$GREY" "label=${rest#*|}" "label.color=$GREY")" \
    "$(seg "stm.ai.$p.row.0")" "status $row"
done
assert_eq "drawing=off" "$(seg stm.ai.grok.row.0)" "disabled: no row"
assert_eq "drawing=off" "$(seg stm.ai.openrouter.row.0)" "unknown status: no row"
mk_json "$J" grok billing 0.5
run_plugin "$J" STM_NOW=$((1791453600 - 15320))
assert_contains "$(seg stm.ai.grok.row.0)" "↻ 4h 15m"
run_plugin "$J" STM_NOW=$((1791453600 - 300))
assert_contains "$(seg stm.ai.grok.row.0)" "↻ 5m"
run_plugin "$J" STM_NOW=1791453600
assert_not_contains "$(seg stm.ai.grok.row.0)" "↻"
{
  printf '{"asOf":"2026-10-08T05:49:39Z","providers":[{"id":"claude","status":"ok","quotaWindows":[],"accounts":['
  i=1
  while [ $i -le 7 ]; do
    [ $i -gt 1 ] && printf ','
    printf '{"name":"a%d","quotaWindows":[{"name":"5h","utilization":0.1}]}' $i
    i=$((i + 1))
  done
  printf ']}]}'
} >"$J"
run_plugin "$J"
assert_contains "$(seg stm.ai.claude.row.10)" "icon=a6"
assert_eq "$(lines drawing=on "icon=" "icon.color=$WHITE" "label=+3 more" "label.color=$GREY")" \
  "$(seg stm.ai.claude.row.11)" "+N more"
done_it

it "untrusted JSON: names cleaned, bad numbers skipped, unknown ids ignored (V49)"
{
  printf '{"asOf":"2026-10-08T05:49:39Z","totals":{"costUSD":"1;rm -rf","tokens":"x"},"providers":['
  printf '{"id":"evil","status":"ok","quotaWindows":[{"name":"7d","utilization":0.99}],"accounts":[]},'
  printf '{"id":"claude","status":"ok","costTodayUSD":"9e9","tokensToday":"x","quotaWindows":[],"accounts":['
  # shellcheck disable=SC2016 # a literal $(x): the name must arrive unexpanded
  printf '{"name":"w\\u00f6rk\\tA\\nB;rm $(x)","costTodayUSD":"1.5","quotaWindows":[{"name":"7d","utilization":0.6,"resetsAt":"bad"}]},'
  printf '{"name":"abcdefghijklmnopqrstuvwxyz","quotaWindows":[{"name":"5h","utilization":"0.2"}]},'
  printf '{"name":"\\u0007","quotaWindows":[{"name":"5h","utilization":0.95}]},'
  printf '{"name":"num","quotaWindows":[{"name":"5h","utilization":"lots"},{"name":"7d","utilization":-0.5}]}'
  printf ']}]}'
} >"$J"
run_plugin "$J"
assert_eq "label= 95% 5h" "$(seg stm.ai.claude | sed -n 2p)" "evil id ignored; a nameless account still counts (B12)"
assert_eq "$(lines drawing=on "icon=wrkABrm x" "icon.color=$WHITE" "label=\$1.50" "label.color=$WHITE")" \
  "$(seg stm.ai.claude.row.0)" "name cleaned"
assert_eq "$(lines drawing=on "icon=  7d" "icon.color=$WHITE" "label=██████░░░░  60%" "label.color=$YELLOW")" \
  "$(seg stm.ai.claude.row.1)" "bad reset dropped"
assert_contains "$(seg stm.ai.claude.row.2)" "icon=abcdefghijklmnop
icon.color"
assert_contains "$(seg stm.ai.claude.row.4)" "icon=account 3"
assert_eq "$(lines drawing=on "icon=num" "icon.color=$GREY" "label=no limit" "label.color=$GREY")" \
  "$(seg stm.ai.claude.row.6)" "bad numbers: no window"
assert_eq "$(lines icon=today "label=as of 05:49")" "$(seg stm.ai.claude.row.head)" "bad cost and tokens"
printf '{"asOf":"2026-10-08T05:49:39Z","providers":[{"id":"claude","status":"ok","accounts":[{"name":"\\u0e07\\u0e32\\u0e19","quotaWindows":[{"name":"7d","utilization":0.95}]},{"name":"home","quotaWindows":[{"name":"7d","utilization":0.3}]}]}]}' >"$J"
run_plugin "$J"
assert_eq "label= 95% 7d" "$(seg stm.ai.claude | sed -n 2p)" "a Thai-named account is not hidden (B12)"
assert_contains "$(seg stm.ai.claude.row.0)" "icon=account 1"
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
  /bin/sh "$PLUGIN" >/dev/null 2>&1
assert_contains "$(cat "$SB_LOG" 2>/dev/null)" "label= 79% 7d" "no TMPDIR: per-user temp dir; unset keys = auto"
done_it

it "foot row opens the app, or its download page when aub is absent (V52)"
run_plugin "$FIXTURE" SENDER=mouse.clicked STM_AI_ACTION=open
assert_eq "-b app.agents-usage-bar" "$OPENED" "open app"
run_plugin "$FIXTURE" SENDER=mouse.clicked STM_AI_ACTION=open STM_AUB="$SANDBOX/no-such-aub"
assert_eq "https://github.com/noomz/agents_usage_bar" "$OPENED" "download page"
run_plugin "$FIXTURE" STM_AI_ACTION=evil
assert_eq "" "$OPENED" "unknown action: nothing opened"
done_it

it "label width per segment: pad + ceil(chars x CW); unknown font sends none (V46, V53)"
run_plugin "$FIXTURE" STM_AI_CW_CLAUDE= STM_AI_PAD_CLAUDE= STM_AI_CW_CODEX=10 STM_AI_PAD_CODEX=4
assert_eq "$(lines drawing=on "label= 79% 7d" "label.color=$WHITE")" "$(seg stm.ai.claude)" "no width without a font size"
assert_contains "$(seg stm.ai.codex)" "label.width=74"
run_plugin "$FIXTURE" STM_AI_CW_CLAUDE='8;x' STM_AI_PAD_CLAUDE=12
assert_eq "$(lines drawing=on "label= 79% 7d" "label.color=$WHITE")" "$(seg stm.ai.claude)" "no width from a bad CW"
done_it

it "a palette without a colour sends no empty colour (V14)"
run_plugin "$FIXTURE" STM_YELLOW= STM_WHITE=
assert_eq "$(lines drawing=on "label= 79% 7d" label.width=68)" "$(seg stm.ai.claude)" "no white"
assert_eq "drawing=on" "$(seg stm.ai.claude.icon)" "no yellow"
assert_eq "$(lines drawing=on "icon=  7d" "label=███████▉░░  79%  ↻ 1d 8h")" \
  "$(seg stm.ai.claude.row.3)" "row without colours"
done_it

it "lint and install item:ai (V4, V9, I.fs, I.cfg)"
STM_ROOT="$REPO_ROOT" run_stm --porcelain lint item:ai
assert_status 0
assert_eq "ok	item:ai" "$STM_OUT"
assert_file_contains "$BUNDLE/item.toml" 'version = "0.2.0"'
D="$SANDBOX/cfg"
make_lua_config "$D"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install item:ai
assert_status 0
assert_files_equal "$PLUGIN" "$D/plugins/stm/ai.sh"
loader=$(cat "$D/items_generated.lua")
for opt in '["shape"] = "split"' '["claude"] = "auto"' '["codex"] = "auto"' '["gemini"] = "auto"' \
  '["grok"] = "auto"' '["openrouter"] = "auto"' 'update_freq = 60,' 'events = { "system_woke" },' \
  'position = "right"'; do
  assert_contains "$loader" "$opt"
done
assert_not_contains "$loader" '["view"]'
assert_not_contains "$loader" '["provider"]'
printf '[item.ai]\nclaude = "windows"\ngrok = "off"\n' >"$D/stm.config.toml"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload --force install item:ai
assert_status 0
loader=$(cat "$D/items_generated.lua")
assert_contains "$loader" '["claude"] = "windows"'
assert_contains "$loader" '["grok"] = "off"'
for bad in 'gemini = "cost"' 'view = "worst"' 'grok = "worst"'; do
  printf '[item.ai]\n%s\n' "$bad" >"$D/stm.config.toml"
  STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload --force install item:ai
  assert_ne 0 "$STM_STATUS" "$bad refused"
done
done_it

LUA_BIN=$(command -v lua 2>/dev/null || true)
if [ -n "$LUA_BIN" ]; then
  mkdir -p "$SANDBOX/lua"
  cat >"$SANDBOX/lua/probe.lua" <<'EOF'
local shape, position, query, metrics, item_lua = ...
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
local options = { shape = shape, claude = "auto", codex = "auto", gemini = "auto", grok = "auto", openrouter = "auto" }
for k, v in metrics:gmatch("(%w+)=(%w+)") do
  options[k] = v
end
local opts = { name = "stm.ai", position = position, update_freq = 60,
  plugin_dir = "/p", events = { "system_woke" }, options = options }
dofile(item_lua)(sbar, opts, { green = 1, yellow = 2, red = 3, grey = 0xff445566, white = 5, black = 6,
  bg1 = 21, popup_bg = 31, popup_border = 32 })
local function fire(key, sender)
  if handlers[key] then
    handlers[key]({ SENDER = sender })
  end
end
fire("stm.ai routine", "routine")
fire("stm.ai.claude.row.foot mouse.clicked", "mouse.clicked")
fire("stm.ai.claude mouse.clicked", "mouse.clicked")
fire("stm.ai.claude.icon mouse.clicked", "mouse.clicked")
fire("stm.ai.claude mouse.exited.global", "mouse.exited.global")
EOF
  # probe <shape> <position> [metrics "p=v p=v"] [query ok|none|late]
  probe() {
    "$LUA_BIN" "$SANDBOX/lua/probe.lua" "$1" "$2" "${4:-ok}" "${3:-}" "$BUNDLE/item.lua" 2>&1
  }
  names_of() {
    probe "$@" | awk '$1 == "item" || $1 == "bracket" { print $1 " " $2 }' | grep -v '\.row\.' | tr '\n' ' '
  }
  line_of() {
    probe "$1" "$2" "$3" | grep -E "^(item|bracket) $4 "
  }

  it "item.lua: driver, segments left to right in fixed order, .icon left of main (V10, V33, I.ais)"
  assert_eq "item stm.ai item stm.ai.claude item stm.ai.codex item stm.ai.gemini item stm.ai.grok item stm.ai.openrouter " \
    "$(names_of plain left)" "plain left"
  assert_eq "item stm.ai item stm.ai.openrouter item stm.ai.grok item stm.ai.gemini item stm.ai.codex item stm.ai.claude " \
    "$(names_of pill right)" "pill right: added in reverse"
  assert_eq "item stm.ai item stm.ai.claude.icon item stm.ai.claude item stm.ai.codex.icon item stm.ai.codex item stm.ai.gemini.icon item stm.ai.gemini item stm.ai.grok.icon item stm.ai.grok item stm.ai.openrouter.icon item stm.ai.openrouter " \
    "$(names_of split center)" "split center"
  assert_eq "item stm.ai item stm.ai.openrouter item stm.ai.openrouter.icon item stm.ai.grok item stm.ai.grok.icon item stm.ai.codex item stm.ai.codex.icon item stm.ai.claude item stm.ai.claude.icon " \
    "$(names_of split right "gemini=off")" "split right, gemini off"
  assert_eq "item stm.ai item stm.ai.codex item stm.ai.claude item stm.ai.claude.icon bracket stm.ai.claude.pill " \
    "$(names_of pill right "claude=windows gemini=off grok=off openrouter=off")" "windows pill right"
  assert_eq "item stm.ai " "$(names_of split left "claude=off codex=off gemini=off grok=off openrouter=off")" "all off: driver only"
  done_it

  it "item.lua: driver hidden with updates, segments carry tags (V42, V32, V14, I.ais)"
  drv=$(line_of split right "" stm.ai)
  assert_contains "$drv" "drawing=false"
  assert_contains "$drv" "updates=true"
  assert_contains "$drv" "update_freq=60"
  for t in claude:CL codex:CX gemini:GE grok:GK openrouter:OR; do
    assert_contains "$(line_of plain right "" "stm.ai.${t%%:*}")" "icon={color=$((0xff445566)) string=${t#*:}}"
    assert_contains "$(line_of split right "" "stm.ai.${t%%:*}.icon")" \
      "background={color=$((0xff445566)) drawing=true} icon={color=6 string=${t#*:}} label={drawing=false}"
  done
  assert_not_contains "$(line_of plain right "" stm.ai.claude)" "updates"
  main=$(line_of split right "" stm.ai.grok)
  assert_contains "$main" "background={color=21 drawing=true padding_left=0}"
  assert_contains "$main" "icon={drawing=false}"
  assert_contains "$main" "popup={align=right background={border_color=32 border_width=2 color=31 corner_radius=12}}"
  assert_contains "$(line_of pill right "" stm.ai.grok)" "background={color=21 drawing=true}"
  assert_contains "$(line_of split left "" stm.ai.grok)" "popup={align=left"
  win=$(line_of plain right "codex=windows" stm.ai.codex)
  assert_contains "$win" "icon={drawing=false padding_left=0 padding_right=0 width=0 y_offset=6} label={padding_left=0 string=--}"
  assert_contains "$(line_of plain right "codex=windows" stm.ai.codex.icon)" "icon={color=$((0xff445566)) string=CX} label={drawing=false}"
  assert_contains "$(line_of pill right "codex=windows" stm.ai.codex.pill)" \
    "{1=stm.ai.codex.icon 2=stm.ai.codex} {background={color=21 drawing=true}}"
  assert_not_contains "$(line_of pill right "codex=windows" stm.ai.codex)" "item stm.ai.codex {background="
  done_it

  it "item.lua: popup rows per segment, none for off (V10, V55)"
  out=$(probe split right "grok=off")
  for p in claude codex gemini openrouter; do
    rows=$(printf '%s\n' "$out" | awk -v p="stm.ai.$p.row." '$1 == "item" && index($2, p) == 1 { print $2 }' | tr '\n' ' ')
    assert_eq "stm.ai.$p.row.head stm.ai.$p.row.0 stm.ai.$p.row.1 stm.ai.$p.row.2 stm.ai.$p.row.3 stm.ai.$p.row.4 stm.ai.$p.row.5 stm.ai.$p.row.6 stm.ai.$p.row.7 stm.ai.$p.row.8 stm.ai.$p.row.9 stm.ai.$p.row.10 stm.ai.$p.row.11 stm.ai.$p.row.foot " \
      "$rows" "$p rows"
    assert_contains "$(printf '%s\n' "$out" | grep "^item stm.ai.$p.row.head ")" "position=popup.stm.ai.$p"
  done
  assert_not_contains "$out" "stm.ai.grok"
  done_it

  it "item.lua runs plugin.sh with options, colours and per-segment metrics (V14, V46, V56)"
  out=$(probe split right "codex=windows gemini=off")
  env="exec STM_GREEN='0x00000001' STM_YELLOW='0x00000002' STM_RED='0x00000003' STM_GREY='0xff445566' STM_WHITE='0x00000005' STM_AI_SHAPE='split' STM_AI_CLAUDE='auto' STM_AI_CODEX='windows' STM_AI_GEMINI='off' STM_AI_GROK='auto' STM_AI_OPENROUTER='auto'"
  m="STM_AI_CW_CLAUDE='7.93' STM_AI_PAD_CLAUDE='12' STM_AI_CW_CODEX='6.10' STM_AI_PAD_CODEX='12' STM_AI_CW_GROK='7.93' STM_AI_PAD_GROK='12' STM_AI_CW_OPENROUTER='7.93' STM_AI_PAD_OPENROUTER='12'"
  assert_eq "$env $m STM_AI_ACTION='' NAME='stm.ai' SENDER='forced' '/p/ai.sh'
$env $m STM_AI_ACTION='' NAME='stm.ai' SENDER='routine' '/p/ai.sh'
$env $m STM_AI_ACTION='open' NAME='stm.ai' SENDER='mouse.clicked' '/p/ai.sh'" \
    "$(printf '%s\n' "$out" | grep '^exec ')" "runs"
  assert_contains "$out" "subscribe stm.ai routine forced system_woke"
  assert_contains "$out" "subscribe stm.ai.claude mouse.clicked"
  assert_contains "$out" "subscribe stm.ai.claude mouse.exited.global"
  assert_contains "$out" "subscribe stm.ai.claude.icon mouse.clicked"
  assert_eq 2 "$(printf '%s\n' "$out" | grep -c '^set stm.ai.claude {popup={drawing=toggle}}$')" "main + .icon toggle own popup"
  assert_contains "$out" "set stm.ai.claude {popup={drawing=false}}"
  assert_not_contains "$out" "subscribe stm.ai mouse"
  assert_contains "$out" "set stm.ai.codex {icon={font=Hack Nerd Font:Bold:10.0} label={font=Hack Nerd Font:Bold:10.0}}"
  assert_not_contains "$(printf '%s\n' "$out" | grep '^set stm.ai.claude ')" "font="
  none=$(probe split right "" none)
  assert_contains "$none" "STM_AI_CW_CLAUDE='' STM_AI_PAD_CLAUDE=''"
  late=$(probe split right "" late)
  assert_contains "$(printf '%s\n' "$late" | grep '^exec ' | tail -1)" "STM_AI_CW_CLAUDE='7.93'"
  done_it

  it "item.lua sizes each popup's name column from its rows' icon font (V55, B13)"
  out=$(probe split right)
  for p in claude openrouter; do
    assert_contains "$out" "query stm.ai.$p.row.head"
    for r in head 0 11; do
      assert_eq 1 "$(printf '%s\n' "$out" | grep -c "^set stm.ai.$p.row.$r {icon={width=195}}$")" "$p row $r: 4+4 + ceil(18 x 17 x 0.61)"
    done
  done
  assert_not_contains "$(probe split right "" none)" "width=195"
  done_it
elif [ -n "${CI:-}" ]; then
  it "lua is available to run item.lua"
  _note_fail "lua not found; CI must run item.lua"
  done_it
else
  printf '# note: lua not found, item.lua not run\n'
fi

finish
