#!/usr/bin/env bash
#
# bundles/items/spotify (#19). Runs plugin.sh as SketchyBar would, against a
# fake `pgrep` (is Spotify running), a fake `osascript` (canned AppleScript
# answer, every script logged), a fake `curl` (canned cover download) and a
# fake `sketchybar` that logs its argv one per line; then runs item.lua under
# Lua with a fake `sbar`. Never touches Spotify, the network or the real bar.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

BUNDLE="$REPO_ROOT/bundles/items/spotify"
PLUGIN="$BUNDLE/plugin.sh"
SB_LOG="$SANDBOX/sketchybar.argv"

# Glyphs (bash 3.2 printf has no \U): nf-fa-spotify, nf-md shuffle_variant,
# skip_previous, play, pause, skip_next, repeat.
SPOT=$(printf '\357\206\274')
SHUF=$(printf '\363\260\222\235')
BACK=$(printf '\363\260\222\256')
PLAY=$(printf '\363\260\220\212')
PAUSE=$(printf '\363\260\217\244')
NEXT=$(printf '\363\260\222\255')
REP=$(printf '\363\260\221\226')
US=$(printf '\037')

FAKE_BIN="$SANDBOX/sp-bin"
mkdir -p "$FAKE_BIN"
# Fake sketchybar: logs a command's argv; answers --query displays with
# $DISPLAYS_OUT and --query <item> with $ITEM_OUT, logging the query.
cat >"$FAKE_BIN/sketchybar" <<'EOF'
#!/bin/sh
if [ "$1" = --query ]; then
  printf 'query %s\n' "$2" >>"$SB_LOG.queries"
  case "$2" in
    displays) printf '%s\n' "$DISPLAYS_OUT" ;;
    bar) printf '%s\n' "$BAR_OUT" ;;
    *) printf '%s\n' "$ITEM_OUT" ;;
  esac
  exit 0
fi
printf '%s\n' "$@" >>"$SB_LOG"
EOF
# Fake pgrep: this user's Spotify runs when $SP_RUNNING = 1.
cat >"$SANDBOX/pgrep" <<'EOF'
#!/bin/sh
printf 'pgrep %s\n' "$*" >>"$SB_LOG.calls"
[ "$*" = "-xq -U $(id -u) Spotify" ] && [ "$SP_RUNNING" = 1 ]
EOF
# Fake osascript: logs the script's third line (the `tell`), keeps every
# script in $SCRIPTS (for the compile check); the status query prints $OSA_OUT.
cat >"$SANDBOX/osascript" <<'EOF'
#!/bin/sh
[ "$1" = -e ] || exit 64
printf 'osascript %s\n' "$(printf '%s\n' "$2" | sed -n 3p)" >>"$SB_LOG.calls"
printf '%s\n' "$2" >"$SCRIPTS/$$.applescript"
case "$2" in
  *"player state"*) printf '%s\n' "$OSA_OUT" ;;
esac
EOF
# Fake curl: logs its argv; writes $CURL_BODY to the -o file unless
# $CURL_FAIL is set.
cat >"$SANDBOX/curl" <<'EOF'
#!/bin/sh
printf 'curl %s\n' "$*" >>"$SB_LOG.calls"
[ -z "$CURL_FAIL" ] || exit 22
out=""
while [ "$#" -gt 0 ]; do
  [ "$1" = -o ] && out=$2
  shift
done
printf '%s' "$CURL_BODY" >"$out"
EOF
chmod 755 "$FAKE_BIN/sketchybar" "$SANDBOX/pgrep" "$SANDBOX/osascript" "$SANDBOX/curl"

COVER_ID=ab67616d0000b2736c049aedc67109692d9374b5
COVER_URL="https://i.scdn.co/image/$COVER_ID"
COVER_BASE="$SANDBOX/stm-spotify-cover.stm.spotify"
COVER_FILE="$COVER_BASE.$COVER_ID"
STATUS_LINE='osascript tell application id "com.spotify.client"'
PGREP_LINE="pgrep -xq -U $(id -u) Spotify"
SCRIPTS="$SANDBOX/scripts"
mkdir -p "$SCRIPTS"

# osa <state> <name> <artist> <album> <url> <shuffling> <repeating> — the
# status query's answer, fields joined by the unit separator.
osa() {
  local IFS="$US"
  printf '%s' "$*"
}

# run_plugin <running 0|1> <osascript out> [VAR=value...] — argv sketchybar
# got lands in $SB, the tool calls made in $CALLS.
SB=""
CALLS=""
run_plugin() {
  local r="$1" o="$2"
  shift 2
  rm -f "$SB_LOG" "$SB_LOG.calls" "$SB_LOG.queries"
  env -i HOME="$HOME" TMPDIR="$SANDBOX" PATH="$FAKE_BIN:/bin:/usr/bin" SB_LOG="$SB_LOG" \
    NAME=stm.spotify SENDER=routine STM_PGREP="$SANDBOX/pgrep" STM_OSASCRIPT="$SANDBOX/osascript" \
    STM_CURL="$SANDBOX/curl" SCRIPTS="$SCRIPTS" SP_RUNNING="$r" OSA_OUT="$o" CURL_BODY=jpeg STM_SP_SHAPE=split \
    STM_SP_COVER=on STM_SP_POSITION=center STM_SP_NARROW=right "$@" /bin/sh "$PLUGIN" >/dev/null 2>&1
  SB=$(cat "$SB_LOG" 2>/dev/null || true)
  CALLS=$(cat "$SB_LOG.calls" 2>/dev/null || true)
  QUERIES=$(cat "$SB_LOG.queries" 2>/dev/null || true)
}
QUERIES=""

# displays <main width> — `sketchybar --query displays` as 2.24 prints it
# (main display first, then a wide external).
displays() {
  printf '[\n\t{\n\t\t"arrangement-id":1,\n\t\t"DirectDisplayID":1,\n\t\t"UUID":"37D8832A-2D66-02CA-B9F7-8F30A301B230",\n\t\t"frame":{\n\t\t"x":0.0000,\n\t\t"y":0.0000,\n\t\t"w":%s.0000,\n\t\t"h":1117.0000\n\t\t}\n\t},\n\t{\n\t\t"arrangement-id":2,\n\t\t"DirectDisplayID":5,\n\t\t"UUID":"AB3887F4-7423-4DF4-8654-FC2B221D790A",\n\t\t"frame":{\n\t\t"x":-2560.0000,\n\t\t"y":0.0000,\n\t\t"w":2560.0000,\n\t\t"h":1440.0000\n\t\t}\n\t}\n]' "$1"
}
# BAR — `sketchybar --query bar`, trimmed: the items, in index order.
BAR=$(printf '{\n\t"position": "top",\n\t"items": [\n\t\t "logo",\n\t\t "stm.spotify",\n\t\t "stm.spotify.icon",\n\t\t "vpn",\n\t\t "stm.tailscale.row.2"\n\t]\n}')
# placed <position> [drawing] — `sketchybar --query stm.spotify`, trimmed
# (geometry first, as 2.24 prints it; later sections repeat "drawing").
placed() {
  printf '{\n\t"name": "stm.spotify",\n\t"type": "item",\n\t"geometry": {\n\t\t"drawing": "%s",\n\t\t"position": "%s",\n\t\t"associated_display_mask": 1,\n\t\t"background": {\n\t\t\t"drawing": "on"\n\t\t}\n\t}\n}' "${2:-on}" "$1"
}

argv_of() {
  printf '%s\n' "$@"
}

# shown <label> <title> <artist> <album> <play glyph> <shuffle> <repeat> <cover args...>
# — the split argv for a visible track.
shown() {
  local label="$1" title="$2" artist="$3" album="$4" play="$5" sh="$6" rp="$7"
  shift 7
  argv_of --set stm.spotify drawing=on "label=$label" --set stm.spotify.icon drawing=on \
    --set stm.spotify.row.title "label=$title" --set stm.spotify.row.artist "label=$artist" \
    --set stm.spotify.row.album "label=$album" --set stm.spotify.row.play "icon=$play" \
    --set stm.spotify.row.shuffle "icon.highlight=$sh" --set stm.spotify.row.repeat "icon.highlight=$rp" \
    --set stm.spotify.row.cover "$@"
}

HIDDEN_SPLIT=$(argv_of --set stm.spotify drawing=off popup.drawing=off --set stm.spotify.icon drawing=off)

it "not running: hidden, popup closed, Spotify never asked (I.spot)"
run_plugin 0 "$(osa playing T A L "$COVER_URL" false false)"
assert_eq "$HIDDEN_SPLIT" "$SB" "split"
assert_eq "$PGREP_LINE" "$CALLS" "only pgrep"
run_plugin 0 "" STM_SP_SHAPE=pill
assert_eq "$(argv_of --set stm.spotify drawing=off popup.drawing=off)" "$SB" "pill"
done_it

it "stopped or no answer: hidden (I.spot)"
run_plugin 1 stopped
assert_eq "$HIDDEN_SPLIT" "$SB" "stopped"
run_plugin 1 ""
assert_eq "$HIDDEN_SPLIT" "$SB" "osascript printed nothing"
done_it

it "playing: label, rows, pause glyph, highlights, cover fetched once (I.spot, V41)"
rm -f "$COVER_BASE".*
run_plugin 1 "$(osa playing 'Feathers' 'Novo Stella' 'Eternity Rain' "$COVER_URL" true false)"
assert_eq "$(shown 'Feathers - Novo Stella' Feathers 'Novo Stella' 'Eternity Rain' "$PAUSE" on off \
  drawing=on "background.image=$COVER_FILE")" "$SB" "playing argv"
assert_eq "$(argv_of "$PGREP_LINE" "$STATUS_LINE" \
  "curl --proto =https --max-time 5 -fsS -o $COVER_BASE.tmp.XXXX $COVER_URL")" \
  "$(printf '%s\n' "$CALLS" | sed "s|$COVER_BASE\.tmp\.[A-Za-z0-9]*|$COVER_BASE.tmp.XXXX|")" "calls"
assert_eq jpeg "$(cat "$COVER_FILE")" "cover file"
# Same track again: the cached cover, no download, no image reload.
run_plugin 1 "$(osa paused 'Feathers' 'Novo Stella' 'Eternity Rain' "$COVER_URL" false true)"
assert_eq "$(shown 'Feathers - Novo Stella' Feathers 'Novo Stella' 'Eternity Rain' "$PLAY" off on \
  drawing=on)" "$SB" "paused argv"
assert_not_contains "$CALLS" "curl"
# After a reload (forced) or a wake the bar needs the image again.
for sender in forced system_woke; do
  run_plugin 1 "$(osa paused T A L "$COVER_URL" false false)" SENDER=$sender
  assert_contains "$SB" "background.image=$COVER_FILE"
  assert_not_contains "$CALLS" "curl"
done
assert_eq "$COVER_FILE" "$(find "$SANDBOX" -maxdepth 1 -name 'stm-spotify-cover.*')" "one cover, no temp files"
done_it

it "a new track's cover replaces the old one, never another run's download (V41)"
NEW_URL="https://i.scdn.co/image/0123abcd"
printf 'partial' >"$COVER_BASE.tmp.other1"
run_plugin 1 "$(osa playing T A L "$NEW_URL" false false)" CURL_BODY=new
assert_eq partial "$(cat "$COVER_BASE.tmp.other1")" "a concurrent run's download survives"
rm -f "$COVER_BASE.tmp.other1"
assert_contains "$CALLS" "curl --proto =https --max-time 5 -fsS -o $COVER_BASE."
assert_contains "$SB" "background.image=$COVER_BASE.0123abcd"
assert_eq new "$(cat "$COVER_BASE.0123abcd")" "new cover"
assert_eq "$COVER_BASE.0123abcd" "$(find "$SANDBOX" -maxdepth 1 -name 'stm-spotify-cover.*')" "old cover removed"
done_it

it "cover cache: only a regular file of ours, in the per-user temp dir (V41, B10)"
# A symlink planted at the cover's path is not a cached cover: download, and
# the move replaces the link without writing through it.
rm -f "$COVER_BASE".*
printf 'theirs' >"$SANDBOX/elsewhere"
ln -s "$SANDBOX/elsewhere" "$COVER_FILE"
run_plugin 1 "$(osa playing T A L "$COVER_URL" false false)"
assert_contains "$CALLS" "curl"
assert_eq jpeg "$(cat "$COVER_FILE")" "downloaded over the link"
[ -L "$COVER_FILE" ] && _note_fail "the cover is still a symlink"
assert_eq theirs "$(cat "$SANDBOX/elsewhere")" "link target untouched"
# SketchyBar runs without TMPDIR: the cache goes to this user's own temp dir,
# never the shared /tmp. (The download fails, so nothing is left there.) Its
# own item name keeps it clear of a real bar's cover in that same dir.
rm -f "$SB_LOG.calls"
probe_name="stm.spotify-test$$"
env -i HOME="$HOME" PATH="$FAKE_BIN:/bin:/usr/bin" SB_LOG="$SB_LOG" NAME="$probe_name" SENDER=routine \
  STM_PGREP="$SANDBOX/pgrep" STM_OSASCRIPT="$SANDBOX/osascript" STM_CURL="$SANDBOX/curl" SCRIPTS="$SCRIPTS" \
  SP_RUNNING=1 OSA_OUT="$(osa playing T A L "$COVER_URL" false false)" CURL_FAIL=1 STM_SP_SHAPE=split \
  STM_SP_COVER=on /bin/sh "$PLUGIN" >/dev/null 2>&1
user_tmp=$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)
assert_contains "$(cat "$SB_LOG.calls")" "-o ${user_tmp}stm-spotify-cover.$probe_name.tmp."
assert_eq "" "$(find "$user_tmp" -maxdepth 1 -name "stm-spotify-cover.$probe_name*" 2>/dev/null)" "nothing left behind"
done_it

it "no artist: the album fills in; neither: the title alone (I.spot)"
run_plugin 1 "$(osa playing Podcast '' Show "$NEW_URL" false false)"
assert_contains "$SB" "label=Podcast - Show"
run_plugin 1 "$(osa playing Lone '' '' "$NEW_URL" false false)"
assert_eq "label=Lone" "$(printf '%s\n' "$SB" | sed -n 4p)" "title only"
done_it

it "control characters in track fields become spaces, never extra fields (V41)"
run_plugin 1 "$(osa playing "$(printf 'a\tb\nc')" "$(printf 'x\033y')" L "$NEW_URL" false false)"
assert_eq "$(shown 'a b c - x y' 'a b c' 'x y' L "$PAUSE" off off drawing=on)" \
  "$SB" "sanitised argv"
# A unit separator inside a field would shift every field after it: hide.
run_plugin 1 "$(osa playing "a${US}b" A L "$NEW_URL" false false)"
assert_eq "$HIDDEN_SPLIT" "$SB" "extra field"
# AppleScript's `missing value` (local files, podcasts) is no text.
run_plugin 1 "$(osa playing T 'missing value' 'missing value' 'missing value' false false)"
assert_eq "$(shown T T '' '' "$PAUSE" off off drawing=off)" "$SB" "missing value"
# UTF-8 text passes through untouched, in a UTF-8 locale too (B8).
run_plugin 1 "$(osa playing "$(printf 'Caf\303\251')" A L "$NEW_URL" false false)" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
assert_contains "$SB" "label=$(printf 'Caf\303\251') - A"
done_it

it "cover: bad url, failed download or cover=off draw no cover (V41)"
for url in "http://i.scdn.co/image/$COVER_ID" "https://evil.example/image/$COVER_ID" \
  "https://i.scdn.co/image/../x" "https://i.scdn.co/image/" "https://i.scdn.co/image/ABCDE0" \
  "https://i.scdn.co/image/$COVER_ID$COVER_ID" "https://i.scdn.co/image/1 -o /tmp/x"; do
  run_plugin 1 "$(osa playing T A L "$url" false false)"
  assert_eq "$(shown 'T - A' T A L "$PAUSE" off off drawing=off)" "$SB" "$url"
  assert_not_contains "$CALLS" "curl"
done
rm -f "$COVER_BASE".*
run_plugin 1 "$(osa playing T A L "$COVER_URL" false false)" CURL_FAIL=1
assert_eq "$(shown 'T - A' T A L "$PAUSE" off off drawing=off)" "$SB" "download failed"
assert_eq "" "$(find "$SANDBOX" -maxdepth 1 -name 'stm-spotify-cover.*')" "nothing left"
run_plugin 1 "$(osa playing T A L "$COVER_URL" false false)" STM_SP_COVER=off
assert_eq "$(shown 'T - A' T A L "$PAUSE" off off drawing=off)" "$SB" "cover=off"
assert_not_contains "$CALLS" "curl"
done_it

it "controls: a fixed AppleScript per action, then the update (I.spot, V41)"
for c in "play:playpause" "next:next track" "back:previous track" \
  "shuffle:set shuffling to not shuffling" "repeat:set repeating to not repeating"; do
  run_plugin 1 stopped SENDER=mouse.clicked STM_SP_ACTION="${c%%:*}"
  assert_eq "$(argv_of "$PGREP_LINE" \
    "osascript tell application id \"com.spotify.client\" to ${c#*:}" "$STATUS_LINE")" "$CALLS" "${c%%:*}"
done
# Every script first checks Spotify still runs (it may be quitting), so
# AppleScript never launches it; and gives up after 3 seconds.
for f in "$SCRIPTS"/*.applescript; do
  assert_eq 'if application id "com.spotify.client" is not running then return ""
with timeout of 3 seconds' "$(sed -n 1,2p "$f")" "$(sed -n 3p "$f")"
done
for a in '' bogus 'play; quit' PLAY; do
  run_plugin 1 stopped SENDER=mouse.clicked STM_SP_ACTION="$a"
  assert_eq "$(argv_of "$PGREP_LINE" "$STATUS_LINE")" "$CALLS" "action '$a'"
done
# Not running: a click never starts Spotify.
run_plugin 0 "" SENDER=mouse.clicked STM_SP_ACTION=play
assert_eq "$PGREP_LINE" "$CALLS" "not running"
# A routine update carrying an action runs none.
run_plugin 1 stopped STM_SP_ACTION=next
assert_eq "$(argv_of "$PGREP_LINE" "$STATUS_LINE")" "$CALLS" "routine"
done_it

it "every AppleScript compiles against Spotify's dictionary (I.spot)"
if [ -d /Applications/Spotify.app ] && [ -x /usr/bin/osacompile ]; then
  n=0
  for f in "$SCRIPTS"/*.applescript; do
    n=$((n + 1))
    /usr/bin/osacompile -o "$SANDBOX/compiled.scpt" "$f" 2>"$SANDBOX/osacompile.err" ||
      _note_fail "$(sed -n 3p "$f") does not compile" "$(cat "$SANDBOX/osacompile.err")"
  done
  [ "$n" -ge 6 ] || _note_fail "expected the status query and five controls, got $n scripts"
else
  printf '# note: Spotify.app not installed, AppleScript not compiled\n'
fi
done_it

it "plain and pill: no icon sub-item to set (V32)"
run_plugin 1 "$(osa playing T A L "$COVER_URL" false false)" STM_SP_SHAPE=pill STM_SP_COVER=off
assert_not_contains "$SB" "stm.spotify.icon"
assert_eq "$(argv_of --set stm.spotify drawing=on 'label=T - A')" "$(printf '%s\n' "$SB" | sed -n 1,4p)" "pill head"
done_it

it "narrow main display: right of centre, popup aligned right; wide: centred (V43, V33)"
PLAYING=$(osa playing T A L "$COVER_URL" false false)
VISIBLE=$(shown 'T - A' T A L "$PAUSE" off off drawing=off)
# Narrow (a 16-inch laptop), still centred: move, leftmost of the right
# items (after the bar's last item), icon sub-item kept left of the label.
run_plugin 1 "$PLAYING" STM_SP_COVER=off DISPLAYS_OUT="$(displays 1728)" ITEM_OUT="$(placed center)" BAR_OUT="$BAR"
assert_eq "$VISIBLE
$(argv_of --set stm.spotify position=right popup.align=right --move stm.spotify after stm.tailscale.row.2 \
  --set stm.spotify.icon position=right --move stm.spotify.icon after stm.spotify)" "$SB" "narrow, split"
assert_eq "query displays
query stm.spotify
query bar" "$QUERIES" "queries"
# The bar's last item unknown, or already ours: no reorder of the main item.
for last in "" "stm.spotify" "stm.spotify.icon"; do
  bar=$(printf '{\n\t"items": [\n\t\t "logo"%s\n\t]\n}' "${last:+,
		 \"$last\"}")
  [ -n "$last" ] || bar=""
  run_plugin 1 "$PLAYING" STM_SP_COVER=off DISPLAYS_OUT="$(displays 1728)" ITEM_OUT="$(placed center)" BAR_OUT="$bar"
  assert_eq "$VISIBLE
$(argv_of --set stm.spotify position=right popup.align=right \
    --set stm.spotify.icon position=right --move stm.spotify.icon after stm.spotify)" "$SB" "last item '$last'"
done
# Already right: nothing to move.
run_plugin 1 "$PLAYING" STM_SP_COVER=off DISPLAYS_OUT="$(displays 1728)" ITEM_OUT="$(placed right)"
assert_eq "$VISIBLE" "$SB" "narrow, already right"
# Wide, left right before (an external became main): back to the centre.
run_plugin 1 "$PLAYING" STM_SP_COVER=off DISPLAYS_OUT="$(displays 2560)" ITEM_OUT="$(placed right)"
assert_eq "$VISIBLE
$(argv_of --set stm.spotify position=center popup.align=center --set stm.spotify.icon position=center \
  --move stm.spotify.icon before stm.spotify)" "$SB" "wide, back to centre"
run_plugin 1 "$PLAYING" STM_SP_COVER=off DISPLAYS_OUT="$(displays 2560)" ITEM_OUT="$(placed center)"
assert_eq "$VISIBLE" "$SB" "wide, centred"
# 1799 is narrow, 1800 is not.
run_plugin 1 "$PLAYING" STM_SP_COVER=off DISPLAYS_OUT="$(displays 1799)" ITEM_OUT="$(placed center)"
assert_contains "$SB" "position=right"
run_plugin 1 "$PLAYING" STM_SP_COVER=off DISPLAYS_OUT="$(displays 1800)" ITEM_OUT="$(placed center)"
assert_eq "$VISIBLE" "$SB" "1800 is wide"
# pill: no icon sub-item to move.
run_plugin 1 "$PLAYING" STM_SP_COVER=off DISPLAYS_OUT="$(displays 1512)" ITEM_OUT="$(placed center)" \
  STM_SP_SHAPE=pill BAR_OUT="$BAR"
assert_eq "$(argv_of --set stm.spotify position=right popup.align=right --move stm.spotify after stm.tailscale.row.2)" \
  "$(printf '%s\n' "$SB" | tail -n 8)" "narrow, pill"
assert_not_contains "$SB" "stm.spotify.icon"
done_it

it "display_change: placement only, and only while shown (V43)"
run_plugin 1 "$PLAYING" SENDER=display_change DISPLAYS_OUT="$(displays 1728)" ITEM_OUT="$(placed center)" BAR_OUT="$BAR"
assert_eq "$(argv_of --set stm.spotify position=right popup.align=right --move stm.spotify after stm.tailscale.row.2 \
  --set stm.spotify.icon position=right --move stm.spotify.icon after stm.spotify)" "$SB" "shown, narrow"
assert_eq "" "$CALLS" "no pgrep, no osascript"
run_plugin 1 "$PLAYING" SENDER=display_change DISPLAYS_OUT="$(displays 1728)" ITEM_OUT="$(placed right)"
assert_eq "" "$SB" "already placed"
run_plugin 1 "$PLAYING" SENDER=display_change DISPLAYS_OUT="$(displays 1728)" ITEM_OUT="$(placed center off)"
assert_eq "" "$SB" "hidden"
assert_eq "" "$CALLS" "hidden: no pgrep, no osascript"
run_plugin 1 "$PLAYING" SENDER=display_change DISPLAYS_OUT="$(displays 1728)" STM_SP_POSITION=left
assert_eq "" "$SB$CALLS$QUERIES" "configured left: nothing at all"
done_it

it "never moves when the width is unknown, the position is yours, or narrow = center (V43)"
for d in "" "garbage" "$(displays abc)"; do
  run_plugin 1 "$PLAYING" STM_SP_COVER=off DISPLAYS_OUT="$d" ITEM_OUT="$(placed center)"
  assert_eq "$VISIBLE" "$SB" "displays '$d'"
  assert_eq "query displays" "$QUERIES" "no item query"
done
# The bar did not say where the item is: no move (not one every tick).
run_plugin 1 "$PLAYING" STM_SP_COVER=off DISPLAYS_OUT="$(displays 1728)" ITEM_OUT=""
assert_eq "$VISIBLE" "$SB" "empty item reply"
run_plugin 1 "$PLAYING" STM_SP_COVER=off DISPLAYS_OUT="$(displays 1728)" ITEM_OUT="$(placed left)" STM_SP_POSITION=left
assert_eq "$VISIBLE" "$SB" "configured left"
assert_eq "" "$QUERIES" "configured left: no queries"
run_plugin 1 "$PLAYING" STM_SP_COVER=off DISPLAYS_OUT="$(displays 1728)" ITEM_OUT="$(placed center)" STM_SP_NARROW=center
assert_eq "$VISIBLE" "$SB" "narrow = center"
assert_eq "" "$QUERIES" "narrow = center: no queries"
# Hidden: nothing to place.
run_plugin 0 "" DISPLAYS_OUT="$(displays 1728)" ITEM_OUT="$(placed center)"
assert_eq "$HIDDEN_SPLIT" "$SB" "hidden"
assert_eq "" "$QUERIES" "hidden: no queries"
done_it

LUA_BIN=$(command -v lua 2>/dev/null || true)
if [ -n "$LUA_BIN" ]; then
  mkdir -p "$SANDBOX/lua"
  cat >"$SANDBOX/lua/probe.lua" <<'EOF'
-- Runs item.lua with one shape and position and a flat or nested colours
-- module; prints everything it adds, in order (props flattened, keys
-- sorted), what each item subscribes to, then the plugin commands run. With
-- `click`, clicks each control and the main item.
local shape, position, dialect, item_lua, click = ...
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
    parts[#parts + 1] = k .. "=" .. dump(v[k])
  end
  return "{" .. table.concat(parts, " ") .. "}"
end
local handlers = {}
local sbar = {}
function sbar.add(kind, name, a, b)
  print(kind .. " " .. name .. " " .. dump(a) .. (b and (" " .. dump(b)) or ""))
  return {
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
function sbar.exec(cmd) print("exec " .. cmd) end
local opts = { name = "stm.spotify", position = position, update_freq = 10,
  plugin_dir = "/p", events = { "system_woke", "display_change" },
  options = { shape = shape, cover = "on", narrow = "right" } }
local colors = { magenta = 1, green = 2, red = 3, white = 4, black = 5, bg1 = 21 }
if dialect == "nested" then
  colors.popup = { bg = 31, border = 32 }
else
  colors.popup_bg, colors.popup_border = 31, 32
end
dofile(item_lua)(sbar, opts, colors)
if click then
  for _, c in ipairs({ "shuffle", "back", "play", "next", "repeat" }) do
    handlers["stm.spotify.row." .. c .. " mouse.clicked"]({ SENDER = "mouse.clicked" })
  end
  handlers["stm.spotify mouse.clicked"]({ SENDER = "mouse.clicked" })
  handlers["stm.spotify mouse.exited.global"]({ SENDER = "mouse.exited.global" })
  if handlers["stm.spotify.icon mouse.clicked"] then
    handlers["stm.spotify.icon mouse.clicked"]({ SENDER = "mouse.clicked" })
  end
end
EOF
  probe() {
    "$LUA_BIN" "$SANDBOX/lua/probe.lua" "$1" "$2" "${3:-flat}" "$BUNDLE/item.lua" ${4:+"$4"} 2>&1
  }
  # line_of <name> <probe args...> — the line that adds <name>.
  line_of() {
    local n="$1"
    shift
    probe "$@" | awk -v n="$n" '($1 == "item" || $1 == "bracket" || $1 == "event") && $2 == n'
  }

  it "item.lua names: stm.spotify, its icon sub-item, popup rows only (V10, V33, I.spot)"
  rows="item stm.spotify.row.cover
item stm.spotify.row.title
item stm.spotify.row.artist
item stm.spotify.row.album
item stm.spotify.row.shuffle
item stm.spotify.row.back
item stm.spotify.row.play
item stm.spotify.row.next
item stm.spotify.row.repeat
item stm.spotify.row.spacer
bracket stm.spotify.row.controls"
  names() {
    probe "$@" | awk '$1 == "item" || $1 == "bracket" || $1 == "event" { print $1, $2 }'
  }
  assert_eq "event stm_spotify_change
item stm.spotify
item stm.spotify.icon
$rows" "$(names split right)" "split right"
  for pos in left center; do
    assert_eq "event stm_spotify_change
item stm.spotify.icon
item stm.spotify
$rows" "$(names split "$pos")" "split $pos"
  done
  assert_eq "event stm_spotify_change
item stm.spotify
$rows" "$(names pill center)" "pill"
  assert_eq "event stm_spotify_change com.spotify.client.PlaybackStateChanged" \
    "$(line_of stm_spotify_change split center)" "notification event"
  done_it

  it "item.lua shapes: accent on the icon, pill on bg1, split sub-item on magenta (V32, V14)"
  assert_contains "$(line_of stm.spotify plain center)" "icon={color=1 string=$SPOT}"
  assert_not_contains "$(line_of stm.spotify plain center)" "background={color=21"
  assert_contains "$(line_of stm.spotify pill center)" "background={color=21 drawing=true}"
  main=$(line_of stm.spotify split center)
  assert_contains "$main" "background={color=21 drawing=true padding_left=0}"
  assert_contains "$main" "icon={drawing=false}"
  assert_eq "item stm.spotify.icon {background={color=1 drawing=true} drawing=false icon={color=5 string=$SPOT} label={drawing=false} position=center}" \
    "$(line_of stm.spotify.icon split center)" "icon sub-item"
  assert_contains "$main" "} drawing=false icon={drawing=false} label={max_chars=24} popup="
  # Hidden items get no events unless they ask for them (V42, B9).
  for shape in plain pill split; do
    assert_contains "$(line_of stm.spotify "$shape" center)" " update_freq=10 updates=true}"
    # A long title scrolls inside 24 characters instead of growing (V43).
    assert_contains "$(line_of stm.spotify "$shape" center)" " label={max_chars=24} "
    assert_contains "$(line_of stm.spotify "$shape" center)" " scroll_texts=true "
  done
  done_it

  it "item.lua popup and controls take palette colours, flat or nested (V41, V14, I.bundle)"
  for d in flat nested; do
    assert_contains "$(line_of stm.spotify split center "$d")" "background={border_color=32 border_width=2 color=31 corner_radius=12 padding_left=8 padding_right=8}"
  done
  assert_contains "$(line_of stm.spotify.row.controls split center)" "background={color=2 corner_radius=11 drawing=true}"
  play=$(line_of stm.spotify.row.play split center)
  assert_contains "$play" "background={color=3 corner_radius=20 drawing=true height=40}"
  assert_contains "$play" "icon={color=4 highlight_color=4 padding_left=4 padding_right=5 string=$PLAY}"
  for c in "shuffle:$SHUF" "back:$BACK" "next:$NEXT" "repeat:$REP"; do
    assert_contains "$(line_of "stm.spotify.row.${c%%:*}" split center)" "color=5 highlight_color=4"
    assert_contains "$(line_of "stm.spotify.row.${c%%:*}" split center)" "string=${c#*:}}"
  done
  done_it

  it "item.lua subscribes the change event and runs the plugin per click (I.spot, V33)"
  out=$(probe split center flat click)
  assert_contains "$out" "subscribe stm.spotify routine forced stm_spotify_change system_woke display_change"
  env="STM_SP_SHAPE='split' STM_SP_COVER='on' STM_SP_NARROW='right' STM_SP_POSITION='center'"
  assert_contains "$out" "exec $env STM_SP_ACTION='' NAME='stm.spotify' SENDER='forced' '/p/spotify.sh'"
  for a in shuffle back play next repeat; do
    assert_contains "$out" "exec $env STM_SP_ACTION='$a' NAME='stm.spotify' SENDER='mouse.clicked' '/p/spotify.sh'"
  done
  assert_eq "set stm.spotify {popup={drawing=toggle}}
set stm.spotify {popup={drawing=false}}
set stm.spotify {popup={drawing=toggle}}" "$(printf '%s\n' "$out" | grep '^set ')" "popup toggles"
  done_it
elif [ -n "${CI:-}" ]; then
  it "lua is available to run item.lua"
  _note_fail "lua not found; CI must run item.lua"
  done_it
else
  printf '# note: lua not found, item.lua not run\n'
fi

it "lint and install item:spotify: the options reach the loader (V4, V9, I.fs, I.cfg)"
STM_ROOT="$REPO_ROOT" run_stm --porcelain lint item:spotify
assert_status 0
D="$SANDBOX/cfg"
make_lua_config "$D"
printf '[item.spotify]\ncover = "off"\n' >"$D/stm.config.toml"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install item:spotify
assert_status 0
assert_files_equal "$PLUGIN" "$D/plugins/stm/spotify.sh"
loader=$(cat "$D/items_generated.lua")
for opt in '["cover"] = "off"' '["shape"] = "split"' '["narrow"] = "right"' 'position = "center",' \
  'update_freq = 10,' 'events = { "system_woke", "display_change" },'; do
  assert_contains "$loader" "$opt"
done
done_it

finish
