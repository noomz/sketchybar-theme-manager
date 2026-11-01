#!/bin/sh
# stm.menubar plugin. Installed by `stm install item:menubar`.
#
# item.lua runs this with:
#   STM_CONFIG_DIR   the SketchyBar config dir the item was installed into
#   SENDER           the SketchyBar event
#
# It only asks stm to reconcile; stm reads the config and owns every
# decision and write. STM_BIN overrides the lookup of stm (tests).

LC_ALL=C
export LC_ALL

stm=${STM_BIN:-}
if [ -z "$stm" ]; then
  stm=$(command -v stm 2>/dev/null) || stm=""
  for c in /opt/homebrew/bin/stm /usr/local/bin/stm "${HOME:-}/.local/bin/stm"; do
    [ -n "$stm" ] && break
    [ -x "$c" ] && stm=$c
  done
fi
# Without stm there is nothing to reconcile; `stm menubar status` reports it.
[ -n "$stm" ] && [ -x "$stm" ] || exit 0

set -- menubar refresh --quiet
[ -n "${STM_CONFIG_DIR:-}" ] && set -- --dir "$STM_CONFIG_DIR" "$@"
exec "$stm" "$@"
