#!/bin/sh
# stm.spotify plugin. Installed by `stm install item:spotify` (#19).
#
# item.lua runs this with:
#   NAME, SENDER     the SketchyBar item and event
#   STM_SP_SHAPE     plain | pill | split
#   STM_SP_COVER     on | off
#   STM_SP_NARROW    right | center | always: where to sit on a narrow main
#                    display; always = on the right on every display
#   STM_SP_POSITION  the item's configured position
#   STM_SP_ACTION    play | next | back | shuffle | repeat, on a control's click
# Colours live in item.lua; this sets the text, glyphs, visibility and cover.
#
# STM_PGREP, STM_OSASCRIPT and STM_CURL override /usr/bin/pgrep,
# /usr/bin/osascript and /usr/bin/curl (tests).

# Byte-wise character classes, whatever LANG SketchyBar passes on.
LC_ALL=C
export LC_ALL

NAME=${NAME:-stm.spotify}
shape=${STM_SP_SHAPE:-split}
osascript=${STM_OSASCRIPT:-/usr/bin/osascript}

# hide — nothing playing: hide the item and close its popup.
hide() {
  set -- --set "$NAME" drawing=off popup.drawing=off
  [ "$shape" = split ] && set -- "$@" --set "$NAME.icon" drawing=off
  sketchybar "$@"
  exit 0
}

# place — sets $move to the commands that put the item where it belongs, or
# to nothing; $drawing to whether the bar shows it. A centred item on a narrow
# main display (a laptop screen) runs into the right items: move it to their
# left end, popup aligned right, and back to the centre on a wide one. Only from
# the centre, and only when the bar has it elsewhere, so a tick never
# reorders the bar. The main display decides for every display the bar is on;
# with narrow = always the item goes right whatever the width.
place() {
  move="" drawing=""
  [ "${STM_SP_POSITION:-center}" = center ] || return 0
  case "${STM_SP_NARROW:-right}" in
    always) want=right ;;
    right)
      w=$(sketchybar --query displays 2>/dev/null | /usr/bin/awk '
        /"arrangement-id"/ { id = $0; gsub(/[^0-9]/, "", id) }
        /"w"/ && id == "1" { sub(/^[^:]*: */, ""); sub(/[.,].*$/, ""); print; exit }')
      case "$w" in
        "" | *[!0-9]*) return 0 ;;
      esac
      if [ "$w" -lt 1800 ]; then want=right; else want=center; fi
      ;;
    *) return 0 ;;
  esac
  # The first "drawing" and "position" are the item's own (geometry).
  state=$(sketchybar --query "$NAME" 2>/dev/null | /usr/bin/awk -F'"' '
    $2 == "drawing" && d == "" { d = $4 }
    $2 == "position" && p == "" { p = $4 }
    END { print d " " p }')
  drawing=${state% *}
  now=${state#* }
  [ -n "$now" ] && [ "$now" != "$want" ] || return 0
  move="--set $NAME position=$want popup.align=$want"
  # On the right, leftmost of the right items: they are laid out right to
  # left by index, so after the bar's last item. Its name goes in $move as one
  # word, so only a plain one.
  if [ "$want" = right ]; then
    last=$(sketchybar --query bar 2>/dev/null | /usr/bin/awk -F'"' '
      /"items"/ { on = 1; next }
      on && /\]/ { exit }
      on { last = $2 }
      END { print last }')
    case "$last" in
      "" | "$NAME" | "$NAME.icon" | *[!A-Za-z0-9._-]*) ;;
      *) move="$move --move $NAME after $last" ;;
    esac
  fi
  # The icon sub-item stays left of the label: right items are laid out
  # right to left, so on the right it goes after the label.
  if [ "$shape" = split ]; then
    [ "$want" = right ] && where=after || where=before
    move="$move --set $NAME.icon position=$want --move $NAME.icon $where $NAME"
  fi
}

# A display change (also every switch of the active display): only placement,
# and only while the item is shown; nothing to ask Spotify.
if [ "$SENDER" = display_change ]; then
  set -f
  place
  # shellcheck disable=SC2086 # $move is words without spaces or globs (set -f)
  [ "$drawing" = on ] && [ -n "$move" ] && sketchybar $move
  exit 0
fi

# Ask Spotify nothing unless this user's Spotify runs: AppleScript would
# launch it.
"${STM_PGREP:-/usr/bin/pgrep}" -xq -U "$(/usr/bin/id -u)" Spotify || hide

# Every script checks again first (Spotify may be quitting: it posts a change
# as it goes), and gives up after 3 seconds rather than hang the plugin.
head='if application id "com.spotify.client" is not running then return ""
with timeout of 3 seconds'

# A control's click: a fixed command per action, never built from input.
if [ "$SENDER" = mouse.clicked ]; then
  case "$STM_SP_ACTION" in
    play) cmd="playpause" ;;
    next) cmd="next track" ;;
    back) cmd="previous track" ;;
    shuffle) cmd="set shuffling to not shuffling" ;;
    repeat) cmd="set repeating to not repeating" ;;
    *) cmd="" ;;
  esac
  [ -n "$cmd" ] && "$osascript" -e "$head
tell application id \"com.spotify.client\" to $cmd
end timeout" >/dev/null 2>&1
fi

# One AppleScript call; the fields come joined by the unit separator (0x1F).
raw=$("$osascript" -e "$head"'
tell application id "com.spotify.client"
set s to player state as text
if s is "stopped" then return s
set t to current track
set u to character id 31
return s & u & (name of t) & u & (artist of t) & u & (album of t) & u & (artwork url of t) & u & (shuffling as text) & u & (repeating as text)
end tell
end timeout' 2>/dev/null)
# Other control characters (tab, newline, escape...) become spaces, so a
# track name can never add a field, an argument or a line.
raw=$(printf '%s' "$raw" | /usr/bin/tr '\000-\036' ' ')

set -f
IFS=$(printf '\037')
# shellcheck disable=SC2086 # split on the unit separator on purpose
set -- $raw
IFS=' 	
'
# Seven fields, or a separator inside one has shifted the rest.
case "$1" in
  playing | paused) [ "$#" -eq 7 ] || hide ;;
  *) hide ;;
esac
# AppleScript joins a missing field (a local file's cover, a podcast's
# album) as the text "missing value".
for f in "$2" "$3" "$4" "$5"; do
  [ "$f" = "missing value" ] && f=""
  set -- "$@" "$f"
done
state=$1 shuffling=$6 repeating=$7
shift 7
track=$1 artist=$2 album=$3 url=$4

label=$track
sub=${artist:-$album}
[ -n "$sub" ] && label="$label - $sub"

# nf-md pause while playing, play otherwise.
if [ "$state" = playing ]; then
  play="󰏤"
else
  play="󰐊"
fi
[ "$shuffling" = true ] && shuffle=on || shuffle=off
[ "$repeating" = true ] && rep=on || rep=off

# fetch_cover <url> <file> — download to a temp file and move it into place;
# any failure leaves no file.
fetch_cover() {
  tmp=$(/usr/bin/mktemp "$base.tmp.XXXXXX") || return 1
  trap '/bin/rm -f "$tmp"' EXIT INT TERM
  if "${STM_CURL:-/usr/bin/curl}" --proto =https --max-time 5 -fsS -o "$tmp" "$1" 2>/dev/null &&
    [ -s "$tmp" ] && /bin/mv -f "$tmp" "$2"; then
    return 0
  fi
  /bin/rm -f "$tmp"
  return 1
}

# The cover: Spotify's own image host only, an id of hex digits. The file is
# named by the id, so the name is the cache key; only a regular file (the dir is ours)
# counts. It lives in this user's own temp dir: SketchyBar runs without
# TMPDIR, and the shared /tmp would let anyone plant a file by that name. The
# image goes to the bar when it is new, or when the bar may have lost it
# (reload, wake).
cover=off
image=""
base=${TMPDIR:-$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)}
base=${base%/}/stm-spotify-cover.$NAME
if [ "${STM_SP_COVER:-on}" = on ]; then
  case "$url" in
    https://i.scdn.co/image/*) id=${url#https://i.scdn.co/image/} ;;
    *) id="" ;;
  esac
  case "$id" in
    "" | *[!0-9a-f]*) ;;
    *)
      file=$base.$id
      if [ "${#id}" -gt 64 ]; then
        :
      elif [ -f "$file" ] && [ ! -L "$file" ] && [ -s "$file" ]; then
        cover=on
        case "$SENDER" in
          forced | system_woke) image=$file ;;
        esac
      elif fetch_cover "$url" "$file"; then
        cover=on
        image=$file
        # Older covers of this item: no longer needed.
        set +f
        for old in "$base".*; do
          case "$old" in
            "$file" | "$base".tmp.*) ;;
            *) /bin/rm -f "$old" ;;
          esac
        done
        set -f
      fi
      ;;
  esac
fi

set -- --set "$NAME" drawing=on label="$label"
[ "$shape" = split ] && set -- "$@" --set "$NAME.icon" drawing=on
set -- "$@" --set "$NAME.row.title" label="$track" \
  --set "$NAME.row.artist" label="$artist" \
  --set "$NAME.row.album" label="$album" \
  --set "$NAME.row.play" icon="$play" \
  --set "$NAME.row.shuffle" icon.highlight="$shuffle" \
  --set "$NAME.row.repeat" icon.highlight="$rep"
if [ -n "$image" ]; then
  set -- "$@" --set "$NAME.row.cover" drawing=on background.image="$image"
elif [ "$cover" = on ]; then
  set -- "$@" --set "$NAME.row.cover" drawing=on
else
  set -- "$@" --set "$NAME.row.cover" drawing=off
fi
place

# shellcheck disable=SC2086 # $move is words without spaces or globs (set -f)
set -- "$@" $move
sketchybar "$@"
