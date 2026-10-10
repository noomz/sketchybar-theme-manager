#!/usr/bin/env bash
#
# bundles/items/compact (#30). Runs plugin.sh as SketchyBar would, against a
# fake `sketchybar` (canned --query answers, every other argv logged) and a
# fake `osascript` (canned NSScreen lines); then item.lua under Lua with a
# fake `sbar`. Never touches the real bar.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

BUNDLE="$REPO_ROOT/bundles/items/compact"
PLUGIN="$BUNDLE/plugin.sh"
FIX="$SANDBOX/fix"
SB_LOG="$SANDBOX/sketchybar.argv"
TMPD="$SANDBOX/tmp"
mkdir -p "$FIX" "$TMPD" "$SANDBOX/bin"

# Fake sketchybar: --query bar | displays | <item>... answered from $FIX
# (bar, displays, item.<name>); the call logged to $SB_LOG.queries. Any other
# call logs its argv, one word per line, then `--`.
cat >"$SANDBOX/bin/sketchybar" <<'EOF'
#!/bin/sh
if [ "$1" = --query ]; then
  printf 'query %s\n' "$*" >>"$SB_LOG.queries"
  case "$2" in
    bar | displays) [ -f "$FIX/$2" ] && cat "$FIX/$2" ;;
    *)
      while [ "$#" -gt 1 ]; do
        [ -f "$FIX/item.$2" ] && cat "$FIX/item.$2"
        shift 2
      done
      ;;
  esac
  exit 0
fi
printf '%s\n' "$@" -- >>"$SB_LOG"
EOF
# Fake osascript: logs the call, prints $OSA_OUT; $OSA_FAIL = exit 1.
cat >"$SANDBOX/osascript" <<'EOF'
#!/bin/sh
printf 'osascript %s %s\n' "$1" "$2" >>"$SB_LOG.queries"
[ -z "$OSA_FAIL" ] || exit 1
printf '%s\n' "$OSA_OUT"
EOF
chmod 755 "$SANDBOX/bin/sketchybar" "$SANDBOX/osascript"

UNITS="a:high:full short icon,b:normal:full icon,c:low:full short"

# bar <item>... — `sketchybar --query bar` as 2.24 prints it (trimmed).
bar() {
  printf '{\n\t"position": "top",\n\t"margin": 20,\n\t"padding_left": 4,\n\t"padding_right": 2,\n\t"y_offset": 6,\n\t"items": [\n'
  printf '\t\t "%s",\n' "$@" | sed '$ s/,$//'
  printf '\t]\n}\n'
}
# displays "<id> <x> <w> <h>"... — `sketchybar --query displays`.
displays() {
  local d first=1
  printf '[\n'
  for d in "$@"; do
    # shellcheck disable=SC2086  # "<id> <x> <w> <h>" split on purpose
    set -- $d
    [ "$first" = 1 ] || printf ',\n'
    first=0
    printf '\t{\n\t\t"arrangement-id":%s,\n\t\t"DirectDisplayID":%s,\n\t\t"UUID":"X",\n\t\t"frame":{\n\t\t"x":%s.0000,\n\t\t"y":0.0000,\n\t\t"w":%s.0000,\n\t\t"h":%s.0000\n\t\t}\n\t}' "$1" "$1" "$2" "$3" "$4"
  done
  printf '\n]\n'
}
# item <name> <position> <drawing> <type> ["<display> <x> <w>"...] — one
# `sketchybar --query <name>` answer into $FIX (geometry first, as 2.24).
item() {
  local n="$1" pos="$2" dr="$3" ty="$4" r first=1
  shift 4
  {
    printf '{\n\t"name": "%s",\n\t"type": "%s",\n\t"geometry": {\n\t\t"drawing": "%s",\n\t\t"position": "%s",\n\t\t"padding_left": 4,\n\t\t"background": {\n\t\t\t"drawing": "on",\n\t\t\t"image": {\n\t\t\t\t"value": "(null)"\n\t\t\t}\n\t\t}\n\t},\n\t"icon": {\n\t\t"value": "x",\n\t\t"drawing": "on"\n\t},\n\t"bounding_rects": {\n' "$n" "$ty" "$dr" "$pos"
    for r in "$@"; do
      # shellcheck disable=SC2086  # "<display> <x> <w>" split on purpose
      set -- $r
      [ "$first" = 1 ] || printf ',\n'
      first=0
      printf '\t\t"display-%s": {\n\t\t\t"origin": [ %s, 35.000000 ],\n\t\t\t"size": [ %s, 34.000000 ]\n\t\t}' "$1" "$2" "$3"
    done
    printf '\n\t}\n}\n'
  } >"$FIX/item.$n"
}

NOTCH="0 1728 1117 956.5"
# scene <a> <b> <b.icon> <c> <vpn> — one 1728 display; right items laid out
# right to left (stm.a rightmost) at those widths. Room: 1728 - 20 - 2 -
# (956.5 + 8) - vpn = 741.5 - vpn.
scene() {
  rm -f "$FIX"/item.*
  bar logo stm.a stm.b stm.b.icon stm.c stm.compact vpn stm.compact.row.0 stm.a.row.0 >"$FIX/bar"
  displays "1 0 1728 1117" >"$FIX/displays"
  item logo left on item "1 20 40"
  item stm.a right on item "1 1400.000000 $1.000000"
  item stm.b right on item "1 1200 $2"
  item stm.b.icon right on item "1 1170 $3"
  item stm.c right on item "1 900 $4"
  item vpn right on item "1 700 $5"
  # popup rows and the chevron are never queried: these would count.
  item stm.compact right on item "1 600 999"
  item stm.a.row.0 popup on item "1 600 999"
}

# run_plugin [VAR=value...] — argv sketchybar got in $SB, queries in $QUERIES.
SB=""
QUERIES=""
run_plugin() {
  rm -f "$SB_LOG" "$SB_LOG.queries"
  env -i HOME="$HOME" TMPDIR="$TMPD" PATH="$SANDBOX/bin:/bin:/usr/bin" SB_LOG="$SB_LOG" FIX="$FIX" \
    NAME=stm.compact SENDER=routine STM_OSASCRIPT="$SANDBOX/osascript" OSA_OUT="$NOTCH" \
    STM_COMPACT_UNITS="$UNITS" "$@" /bin/sh "$PLUGIN" >/dev/null 2>&1
  SB=$(cat "$SB_LOG" 2>/dev/null || true)
  QUERIES=$(cat "$SB_LOG.queries" 2>/dev/null || true)
}
fresh() {
  rm -f "$TMPD"/stm-compact.*
}
# trigger_of <a> <b> <c> — the argv of a stm_compact trigger with those forms.
trigger_of() {
  printf '%s\n' --trigger stm_compact "STM_FORM_A=$1" "STM_FORM_B=$2" "STM_FORM_C=$3" --
}
# triggers — every logged trigger call, argv one per line.
triggers() {
  printf '%s\n' "$SB" | awk '$0 == "--trigger" { on = 1 } on { print } $0 == "--" { on = 0 }'
}

it "lint, manifest: position right, display + wake events, mode shrink|page, grey (I.cmp, I.pg, V4)"
STM_ROOT="$REPO_ROOT" run_stm --porcelain lint item:compact
assert_status 0
assert_eq 'version = "0.2.0"' "$(grep '^version' "$BUNDLE/item.toml")"
assert_eq 'default_position = "right"' "$(grep '^default_position' "$BUNDLE/item.toml")"
assert_eq 'events = ["display_change", "system_woke"]' "$(grep '^events' "$BUNDLE/item.toml")"
assert_eq 'update_freq = 30' "$(grep '^update_freq' "$BUNDLE/item.toml")"
assert_contains "$(grep '^colors' "$BUNDLE/item.toml")" '"grey"'
assert_eq '[options.mode]' "$(grep '^\[options' "$BUNDLE/item.toml")"
assert_eq '[options.mode]
values = ["shrink", "page"]
default = "shrink"' "$(grep -A 2 '^\[options\.mode\]' "$BUNDLE/item.toml")"
done_it

it "install: mode is shrink unless the config says page; a value outside shrink|page is refused (V9, I.pg)"
D="$SANDBOX/cfg"
make_lua_config "$D"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install item:compact
assert_status 0
assert_contains "$(cat "$D/items_generated.lua" 2>/dev/null || true)" '["mode"] = "shrink"'
printf '[item.compact]\nmode = "page"\n' >"$D/stm.config.toml"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install --force item:compact
assert_status 0
loader=$(cat "$D/items_generated.lua" 2>/dev/null || true)
assert_contains "$loader" '["mode"] = "page"'
printf '[item.compact]\nmode = "tabs"\n' >"$D/stm.config.toml"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install --force item:compact
assert_status 1
assert_contains "$STM_ERR" '"tabs"'
assert_eq "$loader" "$(cat "$D/items_generated.lua" 2>/dev/null || true)" "a bad mode leaves the loader as it was"
done_it

it "1728 notch: low steps to short first, then high; b has no short (V58)"
fresh
scene 300 200 30 250 100
run_plugin
assert_eq "$(trigger_of short full short)" "$(triggers)"
# Every unit's width cached for the form it was measured in.
assert_eq "a full 300
b full 230
c full 250" "$(cat "$TMPD/stm-compact.widths")"
done_it

it "same widths + room: the same forms, run twice (V58 determinism)"
fresh
run_plugin
one=$(triggers)
fresh
run_plugin
assert_eq "$one" "$(triggers)"
done_it

it "run budget: one query each for bar, displays, all items; one osascript; rows never queried (V64)"
assert_eq "query --query bar
query --query displays
query --query logo --query stm.a --query stm.b --query stm.b.icon --query stm.c --query vpn
osascript -l JavaScript" "$QUERIES"
done_it

it "no trigger when every form is what was last sent (after its one repeat); widths measured again (V60, V61)"
scene 150 200 30 125 100
run_plugin
assert_eq "$(trigger_of short full short)" "$(triggers)" "the one repeat"
run_plugin
assert_eq "" "$(triggers)"
run_plugin
assert_eq "" "$(triggers)"
assert_contains "$(cat "$TMPD/stm-compact.widths")" "a short 150"
assert_contains "$(cat "$TMPD/stm-compact.widths")" "c short 125"
done_it

it "a missed trigger heals: one repeat, widths cached only a run after the last trigger (V60, V61, B20)"
fresh
scene 300 200 30 250 100
run_plugin
assert_eq "$(trigger_of short full short)" "$(triggers)" "change"
# The units missed it: still full. The repeat re-sends; nothing cached.
run_plugin
assert_eq "$(trigger_of short full short)" "$(triggers)" "one repeat"
assert_not_contains "$(cat "$TMPD/stm-compact.widths")" "a short"
assert_not_contains "$(cat "$TMPD/stm-compact.widths")" "c short"
scene 150 200 30 125 100
run_plugin
assert_eq "" "$(triggers)" "no second repeat"
assert_not_contains "$(cat "$TMPD/stm-compact.widths")" "a short" "the run after a trigger caches nothing"
run_plugin
assert_eq "" "$(triggers)"
assert_contains "$(cat "$TMPD/stm-compact.widths")" "a short 150"
assert_contains "$(cat "$TMPD/stm-compact.widths")" "c short 125"
done_it

it "displays disagree on a unit's width: not cached, unsettled (V61, B20)"
fresh
printf 'form a full\nform b full\nform c full\nfreq 30\ncalm 5\nhid -\nsent 0\n' >"$TMPD/stm-compact.state"
displays "1 0 2560 1440" "2 -2560 2560 1440" >"$FIX/displays"
item logo left on item "1 20 40" "2 -2540 40"
item stm.a right on item "1 2200 300" "2 -360 250"
item stm.b right on item "1 2000 200" "2 -560 200"
item stm.b.icon right on item "1 1970 30" "2 -590 30"
item stm.c right on item "1 1700 250" "2 -860 250"
item vpn right on item "1 1500 100" "2 -1060 100"
run_plugin OSA_OUT="$(printf '0 2560 1440 -\n-2560 2560 1440 -')"
assert_not_contains "$(cat "$TMPD/stm-compact.widths")" "a full"
assert_contains "$(cat "$TMPD/stm-compact.widths")" "b full 230"
assert_contains "$(cat "$TMPD/stm-compact.state")" "calm 0"
done_it

it "an icon row as wide as full is dropped on read (B20)"
fresh
printf 'a full 300\na icon 300\nb full 230\nb icon 230\n' >"$TMPD/stm-compact.widths"
printf 'form a full\nform b full\nform c full\nfreq 30\ncalm 5\nhid -\nsent 0\n' >"$TMPD/stm-compact.state"
scene 300 200 30 250 100
run_plugin
assert_not_contains "$(cat "$TMPD/stm-compact.widths")" "a icon"
assert_not_contains "$(cat "$TMPD/stm-compact.widths")" "b icon"
# b icon at the guess (24), not 230: still short short + full b fits.
assert_eq "$(trigger_of short full short)" "$(triggers)"
done_it

it "only stm.compact* is ever set or moved (V60)"
assert_eq "" "$(printf '%s\n' "$SB" | awk 'prev == "--set" || prev == "--move" { print } { prev = $0 }' | grep -v '^stm\.compact\(\.row\.[0-9]*\)\{0,1\}$')"
done_it

it "settle: 2 s while widths move, 30 s after two calm runs (V61)"
fresh
scene 150 200 30 125 100
printf 'a full 300\na short 150\nb full 230\nc full 250\nc short 125\n' >"$TMPD/stm-compact.widths"
printf 'form a short\nform b full\nform c short\nfreq 2\ncalm 0\nhid -\nsent 0\n' >"$TMPD/stm-compact.state"
run_plugin
assert_contains "$(cat "$TMPD/stm-compact.state")" "freq 2"
assert_contains "$(cat "$TMPD/stm-compact.state")" "calm 1"
assert_eq "" "$(printf '%s\n' "$SB" | grep update_freq)" "no --set while the rate stays"
run_plugin
assert_contains "$(cat "$TMPD/stm-compact.state")" "freq 30"
assert_contains "$SB" "update_freq=30"
run_plugin
assert_eq "" "$SB" "calm: nothing sent at all"
# A width that moves unsettles it again.
scene 160 200 30 125 100
run_plugin
assert_contains "$(cat "$TMPD/stm-compact.state")" "calm 0"
assert_contains "$SB" "update_freq=2"
done_it

it "hysteresis: grow back only with 24 to spare, at a cached width (V59)"
# c short measures 240, full cached 250: one step up costs 10.
fresh
printf 'a full 300\na short 150\nb full 230\nc full 250\n' >"$TMPD/stm-compact.widths"
printf 'form a short\nform b full\nform c short\nfreq 30\ncalm 5\nhid -\n' >"$TMPD/stm-compact.state"
# need = 150 + 230 + 240 + 3 * 8 = 644; room = 741.5 - vpn.
scene 150 200 30 240 87.5 # room 654 = need + 10
run_plugin
assert_eq "" "$(triggers)" "Σ + 10: no step up"
printf 'form a short\nform b full\nform c short\nfreq 30\ncalm 5\nhid -\n' >"$TMPD/stm-compact.state"
scene 150 200 30 240 57.5 # room 684 = need + 40
run_plugin
assert_eq "$(trigger_of short full full)" "$(triggers)" "Σ + 40: c back to full, a stays"
done_it

it "grow skips a wider form never measured, to the next one cached (V59, B21)"
fresh
# a went full -> icon: its short was never drawn, so never measured.
printf 'a full 300\na icon 24\nb full 230\nc full 250\n' >"$TMPD/stm-compact.widths"
printf 'form a icon\nform b full\nform c full\nfreq 30\ncalm 5\nhid -\nsent 0\n' >"$TMPD/stm-compact.state"
scene 24 200 30 250 100
displays "1 0 2560 1440" >"$FIX/displays"
run_plugin OSA_OUT="0 2560 1440 -"
assert_eq "$(trigger_of full full full)" "$(triggers)"
done_it

it "no cached width for the wider form: no step up (V59)"
fresh
printf 'form a short\nform b full\nform c short\nfreq 30\ncalm 5\nhid -\n' >"$TMPD/stm-compact.state"
scene 150 200 30 125 0 # plenty of room
run_plugin
assert_eq "" "$(triggers)"
done_it

it "other right items count against the room (V58 foreign)"
fresh
scene 300 200 30 250 300
run_plugin
assert_eq "$(trigger_of short icon short)" "$(triggers)"
done_it

it "hidden: chevron shown, a row per hidden unit, moved beside the last unit (V58, V63, V65)"
fresh
scene 300 200 30 250 600
run_plugin
assert_eq "$(trigger_of icon icon hidden)" "$(triggers)"
assert_contains "$SB" "$(printf '%s\n' --set stm.compact drawing=on update_freq=2 --set stm.compact.row.0 label=c drawing=on --set stm.compact.row.1 drawing=off)"
# vpn sits between stm.c and the chevron: move it after stm.c.
bar logo stm.a stm.b stm.b.icon stm.c vpn stm.compact >"$FIX/bar"
fresh
run_plugin
assert_contains "$SB" "$(printf '%s\n' --move stm.compact after stm.c --)"
assert_contains "$(cat "$TMPD/stm-compact.state")" "hid c"
done_it

it "chevron already beside the last unit: no move (V63)"
fresh
scene 300 200 30 250 600
run_plugin
assert_not_contains "$SB" "--move"
done_it

it "pin never leaves full (V58)"
fresh
scene 300 200 30 250 600
run_plugin STM_COMPACT_UNITS="a:pin:full short icon,b:normal:full icon,c:low:full short"
# b hides too: a at full alone leaves no room for b's icon.
assert_eq "$(trigger_of full hidden hidden)" "$(triggers)"
done_it

it "no notch, 2560 wide: room from the left items, everything full, nothing sent (V58)"
fresh
scene 300 200 30 250 100
displays "1 0 2560 1440" >"$FIX/displays"
run_plugin OSA_OUT="0 2560 1440 -"
assert_eq "" "$(triggers)"
done_it

it "rects are global: a display not at x 0 measures its left items from its own edge (V58, B19)"
fresh
scene 300 200 30 250 100
# A 1478 external left of the main one, no notch: left items end at local 900.
displays "1 0 2560 1440" "3 -1478 1478 900" >"$FIX/displays"
item logo left on item "3 -1458 878"
item stm.a right on item "3 -500 300"
item stm.b right on item "3 -720 200"
item stm.b.icon right on item "3 -750 30"
item stm.c right on item "3 -1010 250"
item vpn right on item "3 -1110 100"
# room = 1478 - 22 - (900 + 8) - 100 = 448
run_plugin OSA_OUT="$(printf '0 2560 1440 -\n-1478 1478 900 -')"
assert_eq "$(trigger_of short icon short)" "$(triggers)"
done_it

it "two displays: the tightest wins (V58)"
fresh
scene 300 200 30 250 100
displays "1 0 2560 1440" "2 -1728 1728 1117" >"$FIX/displays"
# the same items on both displays, at the same widths
item stm.a right on item "1 2200 300" "2 1400 300"
item stm.b right on item "1 2000 200" "2 1200 200"
item stm.b.icon right on item "1 1970 30" "2 1170 30"
item stm.c right on item "1 1700 250" "2 900 250"
item vpn right on item "1 1500 100" "2 700 100"
run_plugin OSA_OUT="$(printf '0 2560 1440 -\n-1728 1728 1117 -771.5')"
assert_eq "$(trigger_of short full short)" "$(triggers)"
done_it

it "lid closed: the built-in is gone from displays and rects, external decides (V58)"
fresh
displays "1 0 2560 1440" >"$FIX/displays"
item stm.a right on item "1 2200 300"
item stm.b right on item "1 2000 200"
item stm.b.icon right on item "1 1970 30"
item stm.c right on item "1 1700 250"
item vpn right on item "1 1500 100"
run_plugin OSA_OUT="0 2560 1440 -"
assert_eq "" "$(triggers)"
done_it

it "JXA fails or answers junk: no notch, left items rule (V62)"
fresh
scene 300 200 30 250 100
run_plugin OSA_FAIL=1
assert_eq "" "$(triggers)"
fresh
run_plugin OSA_OUT="$(printf '0 1728 1117 abc\nnotch\n0 1728 1117 956.5 9')"
assert_eq "" "$(triggers)"
done_it

it "empty or bad query: nothing sent, nothing written (V62)"
for b in "" "garbage" "{"; do
  fresh
  scene 300 200 30 250 100
  printf '%s' "$b" >"$FIX/bar"
  run_plugin
  assert_eq "" "$SB" "bar [$b]: nothing sent"
  assert_file_absent "$TMPD/stm-compact.state"
done
fresh
scene 300 200 30 250 100
: >"$FIX/displays"
run_plugin
assert_eq "" "$SB" "no displays: nothing sent"
done_it

it "cache rows checked on read: unknown unit or form, out of range, junk dropped (I.cmp)"
fresh
printf 'zz full 10\na tiny 10\na full 99999\na full 0\nb full -3\nb full abc\nc full 12 x\nc\n\na short 77\n' >"$TMPD/stm-compact.widths"
scene 300 200 30 250 100
run_plugin
assert_eq "a full 300
a short 77
b full 230
c full 250" "$(cat "$TMPD/stm-compact.widths")"
# a short is 77 (cached), not 150 (half of full): still short is enough.
assert_eq "$(trigger_of short full short)" "$(triggers)"
done_it

it "state rows checked on read; a bad form is full (I.cmp)"
fresh
printf 'form a bogus\nform b short\nform zz icon\nfreq 7\ncalm x\nhid a;b\n' >"$TMPD/stm-compact.state"
scene 300 200 30 250 100
run_plugin
assert_eq "$(trigger_of short full short)" "$(triggers)"
done_it

it "forced (bar reload): units are full again, trigger + chevron sent, no width cached (V60, V61)"
fresh
scene 300 200 30 250 100
run_plugin
scene 150 200 30 125 100
run_plugin
before=$(cat "$TMPD/stm-compact.widths")
# After a reload every unit is full again: the bar measures full widths.
scene 300 200 30 250 100
run_plugin SENDER=forced
assert_eq "$(trigger_of short full short)" "$(triggers)"
assert_contains "$SB" "$(printf '%s\n' --set stm.compact drawing=off popup.drawing=off update_freq=2)"
assert_eq "$before" "$(cat "$TMPD/stm-compact.widths")"
done_it

it "units checked again in the plugin; none valid: no query at all (I.cmp)"
fresh
run_plugin STM_COMPACT_UNITS="Bad:high:full,x:urgent:full,y:low:short,compact:low:full,z:low:full icon short"
assert_eq "" "$QUERIES"
assert_eq "" "$SB"
done_it

it "a unit with no right item (not added, or centred) is left out (V58)"
fresh
scene 300 200 30 250 100
run_plugin STM_COMPACT_UNITS="$UNITS,d:low:full icon"
assert_contains "$(triggers)" "STM_FORM_D=full"
assert_eq "$(trigger_of short full short | sed '$d')" "$(triggers | grep -v STM_FORM_D | sed '$d')"
done_it

it "a unit drawing nothing of its own (not playing) is left as it is (V58)"
fresh
scene 300 200 30 250 100
scene 300 200 30 250 250
item stm.c right off item
run_plugin
# c takes no room and keeps its form: a to short is enough.
assert_eq "$(trigger_of short full full)" "$(triggers)"
done_it

# --- page mode (#31) -------------------------------------------------------
# Units stay full; the bar shows the window of them that fits, from the
# rightmost leftward, and the rest are hidden. Cost of a unit = its cached
# full width + 8; the arrows take 2 * 24 + 8 = 56 while a unit is out.

# page_seed [<cache row>...] — a settled bar with every unit full and those
# widths cached (default: a 300, b 230, c 250, as `scene 300 200 30 250`).
page_seed() {
  fresh
  [ "$#" -gt 0 ] || set -- "a full 300" "b full 230" "c full 250"
  printf '%s\n' "$@" >"$TMPD/stm-compact.widths"
  printf 'form a full\nform b full\nform c full\nfreq 30\ncalm 5\nhid -\nsent 0\n' >"$TMPD/stm-compact.state"
}
page() {
  run_plugin STM_CMP_MODE=page "$@"
}

it "page, 1728 notch: the window that fits stays full, the rest hidden (V66)"
page_seed
scene 300 200 30 250 100 # room 641.5: all three need 804; with arrows 585.5
page
assert_eq "$(trigger_of full full hidden)" "$(triggers)"
page_seed
scene 300 200 30 250 300 # room 441.5, with arrows 385.5: a 308, a + b 546
page
assert_eq "$(trigger_of full hidden hidden)" "$(triggers)"
done_it

it "page never sends short or icon, also from forms shrink left behind (V66)"
assert_not_contains "$SB" "=short"
assert_not_contains "$SB" "=icon"
page_seed
printf 'form a short\nform b icon\nform c short\nfreq 30\ncalm 5\nhid -\nsent 0\n' >"$TMPD/stm-compact.state"
scene 150 200 30 125 300
page
assert_eq "$(trigger_of full hidden hidden)" "$(triggers)"
done_it

it "page, no notch, 2560 wide: every unit fits, all full, no arrows (V66)"
page_seed
scene 300 200 30 250 100
displays "1 0 2560 1440" >"$FIX/displays"
page OSA_OUT="0 2560 1440 -"
assert_eq "" "$(triggers)"
assert_not_contains "$SB" "drawing=on"
# Units shrink left short go back to full.
page_seed
printf 'form a short\nform b full\nform c short\nfreq 30\ncalm 5\nhid -\nsent 0\n' >"$TMPD/stm-compact.state"
scene 150 200 30 125 100
displays "1 0 2560 1440" >"$FIX/displays"
page OSA_OUT="0 2560 1440 -"
assert_eq "$(trigger_of full full full)" "$(triggers)"
assert_not_contains "$SB" "drawing=on"
done_it

it "page: pin is always full, its width off the room first (V66)"
page_seed
scene 300 200 30 250 300
# room 441.5 - a 308 = 133.5: b and c page; b is in though wider than that.
page STM_COMPACT_UNITS="a:pin:full short icon,b:normal:full icon,c:low:full short"
assert_eq "$(trigger_of full full hidden)" "$(triggers)"
done_it

it "page: a unit wider than the room is still shown, the window is never empty (V66)"
page_seed
scene 300 200 30 250 600 # room 141.5
page
assert_eq "$(trigger_of full hidden hidden)" "$(triggers)"
done_it

it "page: a unit that draws nothing costs nothing, not even its gap (V66)"
page_seed "a full 300" "c full 250"
scene 300 200 30 250 170 # room 571.5: a + c need 566
item stm.b right off item
item stm.b.icon right off item
page
assert_eq "" "$(triggers)"
assert_not_contains "$SB" "drawing=on"
done_it

it "page: a width not cached yet costs nothing; fitted once it is (V66, V61)"
page_seed "a full 300" "c full 250"
scene 300 200 30 250 170 # room 571.5; b is drawn at 230, not cached
page
assert_eq "" "$(triggers)" "b uncached: 566 fits"
assert_contains "$(cat "$TMPD/stm-compact.widths")" "b full 230"
# Now a + b + c need 804; with arrows 515.5 holds a alone (a + b 546).
page
assert_eq "$(trigger_of full hidden hidden)" "$(triggers)"
done_it

it "page: same widths + room + offset: the same forms, run twice (V66 determinism)"
page_seed
scene 300 200 30 250 100
page
one=$(triggers)
page_seed
page
assert_eq "$one" "$(triggers)"
assert_eq "$(trigger_of full full hidden)" "$one"
done_it

it "mode shrink, unset or not a mode: step 1f argv; page + budget rows ignored (V69, V68)"
for mode in shrink "" bogus PAGE; do
  page_seed
  printf 'page 3\nbudget 500\n' >>"$TMPD/stm-compact.state"
  scene 300 200 30 250 100
  run_plugin STM_CMP_MODE="$mode"
  assert_eq "$(trigger_of short full short)" "$(triggers)" "mode [$mode]"
done
done_it

# page_bar <right item>... — the scene's bar with those items after stm.c.
page_bar() {
  bar logo stm.a stm.b stm.b.icon stm.c "$@" stm.a.row.0 >"$FIX/bar"
}

it "page: arrows kept left of the chevron, next then prev, own names only (V63, I.pg)"
page_seed
scene 300 200 30 250 100
page_bar vpn stm.compact stm.compact.row.0 stm.compact.next stm.compact.prev
page
assert_contains "$SB" "$(printf '%s\n' --move stm.compact after stm.c --move stm.compact.next after stm.compact --move stm.compact.prev after stm.compact.next --)"
assert_eq 3 "$(printf '%s\n' "$SB" | grep -c '^--move$')"
# prev before next: the arrows would read › ‹.
page_seed
page_bar stm.compact stm.compact.prev stm.compact.next vpn
page
assert_contains "$SB" "$(printf '%s\n' --move stm.compact after stm.c --move stm.compact.next after stm.compact --move stm.compact.prev after stm.compact.next --)"
# a foreign item between the arrows
page_seed
page_bar stm.compact stm.compact.next vpn stm.compact.prev
page
assert_eq 3 "$(printf '%s\n' "$SB" | grep -c '^--move$')"
assert_not_contains "$SB" "$(printf '%s\n' --move vpn)"
done_it

it "page: arrows already in place: no move; shrink never moves them (V63, V69)"
page_seed
scene 300 200 30 250 100
page_bar stm.compact stm.compact.row.0 stm.compact.next stm.compact.prev vpn
page
assert_not_contains "$SB" "--move"
# shrink: the arrows are not its items (a bar still holding them from page).
page_seed
page_bar stm.compact stm.compact.prev stm.compact.next vpn
run_plugin
assert_not_contains "$SB" "--move"
page_seed
page_bar vpn stm.compact stm.compact.next stm.compact.prev
run_plugin
assert_eq "$(printf '%s\n' --move stm.compact after stm.c)" "$(printf '%s\n' "$SB" | grep -A 3 '^--move$')"
done_it

LUA_BIN=$(command -v lua 2>/dev/null || true)
if [ -n "$LUA_BIN" ]; then
  cat >"$SANDBOX/probe.lua" <<'EOF'
local item_lua, mode = ...
local function dump(v)
  if type(v) ~= "table" then return tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. dump(v[k]) end
  return "{" .. table.concat(parts, " ") .. "}"
end
local handlers, clicks = {}, {}
local sbar = {}
function sbar.add(kind, n, props)
  print("add " .. kind .. " " .. n .. " " .. dump(props))
  return {
    subscribe = function(_, events, fn)
      if type(events) == "string" then events = { events } end
      print("subscribe " .. table.concat(events, " "))
      for _, e in ipairs(events) do
        if e == "mouse.clicked" then clicks[n] = fn else handlers[e] = fn end
      end
    end,
    set = function(_, p) print("set " .. n .. " " .. dump(p)) end,
  }
end
function sbar.exec(cmd) print("exec " .. cmd) end
dofile(item_lua)(sbar, { name = "stm.compact", position = "left", update_freq = 30, plugin_dir = "/p/plugins/stm",
  events = { "display_change", "system_woke" }, compact_units = { "ai:normal:full short icon", "clock:pin:full short" },
  options = { mode = mode } }, { white = 1, grey = 5, bg1 = 2, popup_bg = 3, popup_border = 4 })
handlers["mouse.exited.global"]({})
handlers["display_change"]({ SENDER = "display_change" })
for _, n in ipairs({ "stm.compact.prev", "stm.compact.next" }) do
  if clicks[n] then clicks[n]({ SENDER = "mouse.clicked" }) end
end
EOF
  it "item.lua: event, chevron pinned right + hidden + updates, 16 rows, units to the plugin (I.cmp, V42, V63, V65)"
  out=$("$LUA_BIN" "$SANDBOX/probe.lua" "$BUNDLE/item.lua" shrink 2>&1)
  assert_contains "$out" "add event stm_compact"
  assert_contains "$out" "add item stm.compact {background={color=2 drawing=true} click_script=sketchybar --set 'stm.compact' popup.drawing=toggle drawing=false icon={color=1 string=»} label={drawing=false} popup={align=right background={border_color=4 border_width=1 color=3 corner_radius=6}} position=right update_freq=30 updates=true}"
  assert_contains "$out" "add item stm.compact.row.0 {drawing=false icon={drawing=false} label={color=1 string=} position=popup.stm.compact}"
  assert_contains "$out" "add item stm.compact.row.15 "
  assert_not_contains "$out" "stm.compact.row.16"
  assert_contains "$out" "subscribe routine forced display_change system_woke"
  assert_contains "$out" "set stm.compact {popup={drawing=false}}"
  assert_contains "$out" "exec STM_CMP_MODE='shrink' STM_CMP_ACTION='' STM_COMPACT_UNITS='ai:normal:full short icon,clock:pin:full short' NAME='stm.compact' SENDER='forced' '/p/plugins/stm/compact.sh'"
  assert_contains "$out" "SENDER='display_change'"
  done_it

  it "item.lua shrink, no mode or a bad one: no arrows, only stm.compact + its rows (V10, I.pg)"
  for m in shrink "" tabs; do
    o=$("$LUA_BIN" "$SANDBOX/probe.lua" "$BUNDLE/item.lua" "$m" 2>&1)
    assert_eq "$out" "$o" "mode [$m]"
  done
  assert_not_contains "$out" "stm.compact.prev"
  assert_not_contains "$out" "stm.compact.next"
  assert_not_contains "$out" "STM_CMP_MODE='page'"
  assert_eq "" "$(printf '%s\n' "$out" | grep '^add item ' | grep -v -e '^add item stm\.compact {' -e '^add item stm\.compact\.row\.[0-9]* {')"
  done_it

  it "item.lua page: arrows next then prev on the right, hidden, palette colours; chevron off (V10, V14, V63, V67, I.pg)"
  out=$("$LUA_BIN" "$SANDBOX/probe.lua" "$BUNDLE/item.lua" page 2>&1)
  assert_eq "add item stm.compact.next {background={color=2 drawing=true} drawing=false icon={color=1 string=›} label={drawing=false} position=right}
add item stm.compact.prev {background={color=2 drawing=true} drawing=false icon={color=1 string=‹} label={drawing=false} position=right}" \
    "$(printf '%s\n' "$out" | grep -e '^add item stm\.compact\.next ' -e '^add item stm\.compact\.prev ')"
  assert_contains "$out" "add item stm.compact {background={color=2 drawing=true} click_script=sketchybar --set 'stm.compact' popup.drawing=toggle drawing=false "
  assert_eq "" "$(printf '%s\n' "$out" | grep '^add item ' | grep -v -e '^add item stm\.compact {' -e '^add item stm\.compact\.row\.[0-9]* {' -e '^add item stm\.compact\.next {' -e '^add item stm\.compact\.prev {')"
  assert_eq 0 "$(grep -cE '0x[0-9a-fA-F]{6,8}' "$BUNDLE/item.lua")" "no hex literal in item.lua"
  done_it

  it "item.lua page: a click runs the plugin as stm.compact with the action, the mode and the arrow colours (I.pg, V14)"
  units="STM_COMPACT_UNITS='ai:normal:full short icon,clock:pin:full short' NAME='stm.compact'"
  pre="STM_WHITE='0x00000001' STM_GREY='0x00000005' $units"
  assert_contains "$out" "exec STM_CMP_MODE='page' STM_CMP_ACTION='' $pre SENDER='forced' '/p/plugins/stm/compact.sh'"
  assert_contains "$out" "exec STM_CMP_MODE='page' STM_CMP_ACTION='' $pre SENDER='display_change' '/p/plugins/stm/compact.sh'"
  assert_eq "exec STM_CMP_MODE='page' STM_CMP_ACTION='prev' $pre SENDER='mouse.clicked' '/p/plugins/stm/compact.sh'
exec STM_CMP_MODE='page' STM_CMP_ACTION='next' $pre SENDER='mouse.clicked' '/p/plugins/stm/compact.sh'" \
    "$(printf '%s\n' "$out" | grep "SENDER='mouse.clicked'")"
  done_it
else
  printf '# SKIP item.lua probe: no lua\n'
fi

it "shellcheck: plugin.sh (V20)"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -s sh "$PLUGIN"
  assert_eq 0 "$?"
fi
done_it

finish
