#!/bin/sh
# T7 guest-only stand-in for STM_OSASCRIPT. It runs the real osascript, then,
# while "$T7_DIR/notch" reads "on", reports a synthetic camera housing on the
# first screen (the one with the menu bar): top safe-area inset 32 and a
# 185-point gap centred on the frame, as measured on the physical Mac16,5 in
# T3. Frame, width, height, the visible-frame gap and the menu-window depth
# (fields 1-3, 7, 8 of the V14 format) stay real, so stm still
# matches the screen to SketchyBar's display and measures the real menu.
out=$(/usr/bin/osascript "$@") || exit
if [ "$(/bin/cat "${T7_DIR:?}/notch" 2>/dev/null)" = on ]; then
  printf '%s\n' "$out" | /usr/bin/awk '
    NR == 1 && NF == 8 { cx = $1 + $2 / 2; $4 = 32; $5 = cx - 92.5; $6 = cx + 92.5 }
    { print }'
else
  printf '%s\n' "$out"
fi
