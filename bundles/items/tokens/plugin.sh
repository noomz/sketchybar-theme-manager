#!/bin/sh
# stm.tokens plugin. Installed by `stm install item:tokens` (#49).
#
# item.lua runs this with NAME and SENDER and reads what it prints; the
# plugin never calls sketchybar. One record per line, fields split by TAB:
#   state ok | nodata | missing        (always, first)
#   asof  <epoch> <stale 0|1>          (ok only)
#   total <tokens>                     (ok only)
#   prov  <id> <name> <tokens>         (ok only, one per provider with a count)
# missing: no aub. nodata: aub failed, its JSON is unusable, or no provider
# has a token count today.
#
# The numbers come from the Agents Usage Bar cache: `aub usage --json` reads
# it without touching the network. This plugin never calls a provider and
# never reads a token; it never runs `aub --live`.
#
# STM_AUB overrides the aub lookup and STM_NOW the clock (epoch seconds;
# tests). Stock tools are called by absolute path, so only aub comes from PATH.

LC_ALL=C
export LC_ALL

TIMEOUT_SECS=3 # `aub usage` gets this much wall clock, then it is killed
STALE_SECS=900
AHEAD_SECS=300 # an asOf this far in the future is not trusted

# SketchyBar runs plugins without TMPDIR; the per-user temp dir is private.
tmp=${TMPDIR:-$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null)}
WORK=$(/usr/bin/mktemp -d "${tmp:-/tmp}/stm-tokens.XXXXXX") || {
  printf 'state\tnodata\n'
  exit 0
}
trap '/bin/rm -rf "$WORK"' EXIT

# find_aub — print the aub CLI to use, or nothing. The app binary is the CLI
# too when its first argument is a subcommand.
find_aub() {
  if [ -n "${STM_AUB:-}" ]; then
    [ -f "$STM_AUB" ] && [ -x "$STM_AUB" ] && printf '%s\n' "$STM_AUB"
    return 0
  fi
  for c in "$HOME/.local/bin/aub" \
    /Applications/AgentsUsageBar.app/Contents/MacOS/AgentsUsageBar \
    "$HOME/Applications/AgentsUsageBar.app/Contents/MacOS/AgentsUsageBar"; do
    if [ -f "$c" ] && [ -x "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  command -v aub 2>/dev/null
  return 0
}

# run_aub <cli> — the cached usage JSON into $WORK/out.json. macOS has no
# `timeout`, so aub runs in the background and a watchdog kills it after
# TIMEOUT_SECS of wall clock: one long sleep, never a loop of short ones.
# Returns aub's status, or 2 on timeout.
run_aub() {
  "$1" usage --json >"$WORK/out.json" 2>/dev/null &
  pid=$!
  (
    trap 'kill "$s" 2>/dev/null; exit 0' TERM
    /bin/sleep "$TIMEOUT_SECS" &
    s=$!
    wait "$s"
    : >"$WORK/timed-out"
    kill "$pid" 2>/dev/null
    /bin/sleep 0.2
    kill -9 "$pid" 2>/dev/null
  ) &
  dog=$!
  wait "$pid" 2>/dev/null
  rc=$?
  kill "$dog" 2>/dev/null
  wait "$dog" 2>/dev/null
  [ -f "$WORK/timed-out" ] && return 2
  return "$rc"
}

# parse — the JSON in, tab-separated records out, from one stock process:
#   asof <iso>
#   prov <id> <name> <tokens>
# Strings are kept to printable ASCII, so no value can carry a tab or newline
# and forge a record; a count is a whole number (or a numeral string) or the
# provider is left out. summarise still checks each field. Bad JSON makes
# osascript exit non-zero.
PARSE_JS='
function run(argv) {
  ObjC.import("Foundation");
  var raw = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  var doc = JSON.parse(ObjC.unwrap(raw));
  function obj(v) { return v !== null && typeof v === "object" && !Array.isArray(v); }
  function text(v) { return typeof v === "string" ? v.replace(/[^\x20-\x7e]/g, "") : ""; }
  function count(v) {
    if (typeof v === "number") return Number.isSafeInteger(v) && v >= 0 ? String(v) : "";
    return typeof v === "string" && /^[0-9]+$/.test(v) ? v : "";
  }
  if (!obj(doc) || !Array.isArray(doc.providers)) throw new Error("not aub usage JSON");
  var out = ["asof\t" + text(doc.asOf)];
  doc.providers.slice(0, 32).forEach(function (p) {
    if (!obj(p)) return;
    var n = count(p.tokensToday);
    if (n !== "") out.push(["prov", text(p.id), text(p.displayName), n].join("\t"));
  });
  return out.join("\n");
}'

# summarise — the records in, the records item.lua reads out (see the top).
# The first provider per id wins; an id must be a lower-case slug; a name is
# cut to 16 safe characters and falls back to the id; a count has at most 15
# digits. No provider left → nodata.
summarise() {
  /usr/bin/awk -F'\t' -v now="$now" -v stale_secs="$STALE_SECS" -v ahead_secs="$AHEAD_SECS" '
    function epoch(s, y, m, d, hh, mm, ss, era, yoe, doy) {
      if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9](\.[0-9]+)?Z$/) return ""
      y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
      hh = substr(s, 12, 2) + 0; mm = substr(s, 15, 2) + 0; ss = substr(s, 18, 2) + 0
      if (y < 1970 || m < 1 || m > 12 || d < 1 || d > 31 || hh > 23 || mm > 59 || ss > 60) return ""
      if (m <= 2) y--
      era = int(y / 400); yoe = y - era * 400
      doy = int((153 * ((m + 9) % 12) + 2) / 5) + d - 1
      return (era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy - 719468) * 86400 + hh * 3600 + mm * 60 + ss
    }
    function clean(s) {
      gsub(/[^A-Za-z0-9 ._()+-]/, "", s)
      s = substr(s, 1, 16)
      gsub(/^ +| +$/, "", s)
      return s
    }
    $1 == "asof" && NF == 2 { asof = epoch($2) }
    $1 == "prov" && NF == 4 {
      if ($2 !~ /^[a-z0-9][a-z0-9._-]*$/ || length($2) > 32 || ($2 in seen)) next
      if ($4 !~ /^[0-9]+$/ || length($4) > 15) next
      seen[$2] = 1
      name = clean($3)
      if (name == "") name = $2
      n++; ids[n] = $2; names[n] = name; toks[n] = $4
      total += $4
    }
    END {
      if (!n) { print "state\tnodata"; exit }
      # An asOf from the future or unreadable is not trusted: no time, stale.
      if (asof == "" || asof - now > ahead_secs) { asof = ""; stale = 1 }
      else stale = now - asof > stale_secs ? 1 : 0
      print "state\tok"
      print "asof\t" asof "\t" stale
      printf "total\t%.0f\n", total
      for (i = 1; i <= n; i++) print "prov\t" ids[i] "\t" names[i] "\t" toks[i]
    }'
}

now=${STM_NOW:-$(/bin/date +%s)}
case $now in "" | *[!0-9]*) now=0 ;; esac

aub=$(find_aub)
if [ -z "$aub" ]; then
  printf 'state\tmissing\n'
  exit 0
fi
if run_aub "$aub" && [ -s "$WORK/out.json" ] &&
  /usr/bin/osascript -l JavaScript -e "$PARSE_JS" "$WORK/out.json" >"$WORK/rec" 2>/dev/null; then
  summarise <"$WORK/rec"
else
  printf 'state\tnodata\n'
fi
