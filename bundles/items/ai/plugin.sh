#!/bin/sh
# stm.ai plugin. Installed by `stm install item:ai` (#26).
#
# item.lua runs this with:
#   NAME, SENDER                 the SketchyBar item and event
#   STM_GREEN STM_YELLOW STM_RED STM_GREY STM_WHITE
#                                palette colours as 0xAARRGGBB (may be empty)
#   STM_AI_SHAPE                 plain | pill | split
#   STM_AI_VIEW                  worst | windows | cost
#   STM_AI_PROVIDER              all | claude | codex | gemini | grok
#   STM_AI_CW STM_AI_PAD         label character width and paddings (empty
#                                until the bar has told item.lua its font)
#   STM_AI_ACTION                open (the popup's last row was clicked) or empty
#
# The numbers come from the Agents Usage Bar cache: `aub usage --json` reads
# it without touching the network. This plugin never calls a provider and
# never reads a token; it never runs `aub --live`.
#
# STM_AUB overrides the aub lookup, STM_NOW the clock (epoch seconds) and
# STM_OPEN /usr/bin/open (tests). Stock tools are called by absolute path, so
# only aub and sketchybar come from PATH.

LC_ALL=C
export LC_ALL

NAME=${NAME:-stm.ai}
TIMEOUT_SECS=3 # `aub usage` gets this much wall clock, then it is killed
ROWS=12
STALE_SECS=900
AHEAD_SECS=300 # an asOf this far in the future is not trusted
APP_ID=app.agents-usage-bar
APP_URL=https://github.com/noomz/agents_usage_bar
US=$(printf '\037')

# SketchyBar runs plugins without TMPDIR; the per-user temp dir is private.
tmp=${TMPDIR:-$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null)}
WORK=$(/usr/bin/mktemp -d "${tmp:-/tmp}/stm-ai.XXXXXX") || exit 0
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
# TIMEOUT_SECS of wall clock: one long sleep, never a loop of short ones (B5).
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
#   asof <iso>   total <usd>   tokens <n>
#   prov <i> <id> <status> <cost> <balance> <fraction>
#   acct <i> <a> <name> <cost>
#   win <i> <a or -> <name> <utilization> <resetsAt>
# Every value is typed first (a name must be a string, a number a number or a
# numeral) and kept to printable ASCII, so no value can carry a tab or newline
# and forge a record; summarise still checks each one. Unknown provider ids
# and all but the first provider per id are dropped here. Bad JSON makes
# osascript exit non-zero.
PARSE_JS='
function run(argv) {
  ObjC.import("Foundation");
  var raw = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  var doc = JSON.parse(ObjC.unwrap(raw));
  var known = { claude: 1, codex: 1, gemini: 1, grok: 1, openrouter: 1, "ollama-cloud": 1 };
  function obj(v) { return v !== null && typeof v === "object" && !Array.isArray(v); }
  function list(v) { return Array.isArray(v) ? v.slice(0, 32) : []; }
  function text(v) { return typeof v === "string" ? v.replace(/[^\x20-\x7e]/g, "") : ""; }
  function value(v) { return typeof v === "number" && isFinite(v) ? String(v) : text(v); }
  if (!obj(doc) || !Array.isArray(doc.providers)) throw new Error("not aub usage JSON");
  var totals = obj(doc.totals) ? doc.totals : {};
  var out = ["asof\t" + text(doc.asOf), "total\t" + value(totals.costUSD), "tokens\t" + value(totals.tokens)];
  var seen = {};
  function windows(ws, i, a) {
    list(ws).forEach(function (w) {
      if (obj(w)) out.push(["win", i, a, text(w.name), value(w.utilization), text(w.resetsAt)].join("\t"));
    });
  }
  list(doc.providers).forEach(function (p, i) {
    if (!obj(p)) return;
    var id = text(p.id);
    if (!known.hasOwnProperty(id) || seen[id]) return;
    seen[id] = 1;
    var quota = obj(p.quota) ? p.quota : {};
    out.push(["prov", i, id, text(p.status), value(p.costTodayUSD), value(p.balanceUSD), value(quota.fraction)].join("\t"));
    windows(p.quotaWindows, i, "-");
    list(p.accounts).forEach(function (acc, a) {
      if (!obj(acc)) return;
      out.push(["acct", i, a, text(acc.name), value(acc.costTodayUSD)].join("\t"));
      windows(acc.quotaWindows, i, a);
    });
  });
  return out.join("\n");
}'

parse() {
  /usr/bin/osascript -l JavaScript -e "$PARSE_JS" "$WORK/out.json" 2>/dev/null
}

# summarise — the records in, what to draw out (fields split by 0x1F):
#   state <green|yellow|red|stale|nodata>   label <text>
#   lines <top> <band> <bottom> <band>      (windows view, when it has them)
#   head <cost> <tokens> <asOf epoch> <stale 0|1>
#   row <name> <label> <label band> <name band>
# Only known provider ids with status ok count, a provider's windows come from
# its accounts when any has some (the top level repeats them), and every
# value is checked before it reaches a label.
summarise() {
  /usr/bin/awk -F'\t' -v now="$now" -v view="${STM_AI_VIEW:-worst}" -v want="${STM_AI_PROVIDER:-all}" \
    -v rows="$ROWS" -v stale_secs="$STALE_SECS" -v ahead_secs="$AHEAD_SECS" '
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
    function money(s) { return s ~ /^[0-9]+(\.[0-9]+)?$/ ? s : "" }
    function pct(s, p) {
      if (s !~ /^[0-9]+(\.[0-9]+)?$/) return ""
      p = int(s * 100 + 0.5)
      return p > 100 ? 100 : p
    }
    function clean(s) {
      gsub(/[^A-Za-z0-9 ._-]/, "", s)
      s = substr(s, 1, 16)
      gsub(/^ +| +$/, "", s)
      return s
    }
    function band(p) { return p >= 80 ? "red" : p >= 50 ? "yellow" : "green" }
    function suffix(n) {
      if (n == "5h" || n == "primary") return "5h"
      if (n ~ /^7d/ || n == "secondary") return "7d"
      return ""
    }
    function bar(p, e, full, s, i) {
      e = int(p * 80 / 100 + 0.5); full = int(e / 8); s = ""
      for (i = 0; i < full; i++) s = s "█"
      if (e % 8) { s = s PART[e % 8]; full++ }
      for (i = full; i < 10; i++) s = s "░"
      return s
    }
    function until(e, s, d, h, m) {
      if (e == "" || e - now <= 0) return ""
      s = e - now; d = int(s / 86400); h = int((s % 86400) / 3600); m = int((s % 3600) / 60)
      return d > 0 ? d "d " h "h" : h > 0 ? h "h " m "m" : m "m"
    }
    function dollars(s, n) {
      n = int(s + 0.5)
      return n >= 10000 ? "$" int(n / 1000) "k" : "$" n
    }
    function tok(n) {
      if (n == "") return "--"
      if (n < 1000) return n
      if (n < 1000000) return sprintf("%.1fK", n / 1000)
      if (n < 1000000000) return sprintf("%.1fM", n / 1000000)
      if (n < 1000000000000) return sprintf("%.1fB", n / 1000000000)
      return "999B+"
    }
    function out(a, b, c, d, e) { print a US b US c US d US e }
    # row: the line for one window group (the worst of its windows).
    function line(g, cost, p, s, r) {
      p = gpct[g]; s = suffix(gwin[g]); r = until(greset[g])
      return bar(p) " " sprintf("%3d%%", p) (s != "" ? " " s : "") (r != "" ? "  ↻ " r : "") \
        (cost != "" ? sprintf("  $%.2f", cost) : "")
    }
    function addrow(name, label, lb, nb) {
      nrow++; rname[nrow] = name; rlabel[nrow] = label; rband[nrow] = lb; rnb[nrow] = nb
    }
    BEGIN {
      US = sprintf("%c", 31)
      split("▏ ▎ ▍ ▌ ▋ ▊ ▉", PART, " ")
      norder = split("claude codex gemini grok openrouter ollama-cloud", ORDER, " ")
      split("Claude Codex Gemini Grok OpenRouter", DISP, " ")
      for (k = 1; k <= norder; k++) { KNOWN[ORDER[k]] = k; DISPLAY[ORDER[k]] = DISP[k] }
      DISPLAY["ollama-cloud"] = "Ollama Cloud"
      WORD["unauthenticated"] = "sign in"; WORD["notRunning"] = "not running"
      WORD["stale"] = "stale"; WORD["error"] = "error"
    }
    $1 == "asof" { asof = epoch($2) }
    $1 == "total" { total = money($2) }
    $1 == "tokens" { tokens = $2 ~ /^[0-9]+$/ ? $2 : "" }
    $1 == "prov" {
      if (!($3 in KNOWN) || ($3 in idx)) next
      idx[$3] = $2; id_of[$2] = $3
      status[$3] = $4; pcost[$3] = money($5); pbal[$3] = money($6); pfrac[$3] = pct($7)
    }
    $1 == "acct" {
      if (!($2 in id_of)) next
      g = $2 SUBSEP $3
      aname[g] = clean($4); acost[g] = money($5)
      if (aname[g] == "") aname[g] = "account " ($3 + 1)
      nacct[$2]++; acct[$2, nacct[$2]] = $3
    }
    $1 == "win" {
      if (!($2 in id_of)) next
      p = pct($5)
      if (p == "") next
      g = $2 SUBSEP $3
      nwin[g]++
      if (!(g in gpct) || p > gpct[g]) { gpct[g] = p; gwin[g] = $4; greset[g] = epoch($6) }
      if (suffix($4) == "5h" && (!(g in g5) || p > g5[g])) g5[g] = p
      if (suffix($4) == "7d" && (!(g in g7) || p > g7[g])) g7[g] = p
    }
    END {
      worst = ""
      for (k = 1; k <= norder; k++) {
        id = ORDER[k]
        if (!(id in idx)) continue
        i = idx[id]
        if (status[id] != "ok") {
          if (id in DISPLAY && status[id] in WORD) addrow(DISPLAY[id], WORD[status[id]], "grey", "grey")
          continue
        }
        ng = 0
        for (a = 1; a <= nacct[i]; a++) {
          g = i SUBSEP acct[i, a]
          if (nwin[g]) groups[++ng] = g
        }
        if (!ng && nwin[i SUBSEP "-"]) groups[++ng] = i SUBSEP "-"
        for (n = 1; n <= ng; n++) {
          g = groups[n]
          if ((want == "all" || want == id) && (worst == "" || gpct[g] > gpct[worst])) worst = g
        }
        if (ng >= 2) {
          addrow(DISPLAY[id], pcost[id] != "" ? sprintf("$%.2f spent", pcost[id]) : "", "white", "white")
          for (n = 1; n <= ng; n++) {
            g = groups[n]
            addrow("  " aname[g], line(g, acost[g]), band(gpct[g]), "white")
          }
        } else if (ng == 1) {
          g = groups[1]
          addrow(DISPLAY[id], line(g, g in aname ? acost[g] : pcost[id]), band(gpct[g]), "white")
        } else if (pbal[id] != "" && pfrac[id] != "") {
          addrow(DISPLAY[id], bar(pfrac[id]) " " sprintf("%3d%%", pfrac[id]) sprintf("  $%.2f left", pbal[id]),
            band(pfrac[id]), "white")
        } else if (pbal[id] != "") {
          addrow(DISPLAY[id], sprintf("$%.2f left", pbal[id]), "white", "white")
        }
      }

      stale = (asof == "" || now - asof > stale_secs || asof - now > ahead_secs) ? 1 : 0
      if (worst == "") state = "nodata"
      else if (stale) state = "stale"
      else state = band(gpct[worst])
      out("state", state)

      if (worst == "") label = "--"
      else label = sprintf("%3d%%", gpct[worst]) (suffix(gwin[worst]) != "" ? " " suffix(gwin[worst]) : "")
      if (view == "cost") label = total != "" ? dollars(total) : "$--"
      out("label", label)
      if (view == "windows" && worst != "" && (worst in g5 || worst in g7)) {
        b5 = worst in g5 && !stale ? band(g5[worst]) : "grey"
        b7 = worst in g7 && !stale ? band(g7[worst]) : "grey"
        out("lines", "5h " (worst in g5 ? sprintf("%3d%%", g5[worst]) : " --"), b5,
          "7d " (worst in g7 ? sprintf("%3d%%", g7[worst]) : " --"), b7)
      }

      out("head", total != "" ? sprintf("$%.2f", total) : "$--", tok(tokens), asof, stale)
      if (nrow > rows) {
        hidden = nrow - (rows - 1)
        nrow = rows - 1
        addrow("", "+" hidden " more", "grey", "white")
      }
      for (n = 1; n <= nrow; n++) out("row", rname[n], rlabel[n], rband[n], rnb[n])
    }
  ' "$WORK/rec"
}

color_of() {
  case $1 in
    green) printf '%s' "${STM_GREEN:-}" ;;
    yellow) printf '%s' "${STM_YELLOW:-}" ;;
    red) printf '%s' "${STM_RED:-}" ;;
    white) printf '%s' "${STM_WHITE:-}" ;;
    *) printf '%s' "${STM_GREY:-}" ;;
  esac
}

field() {
  /usr/bin/awk -F"$US" -v k="$1" -v n="${2:-2}" '$1 == k { print $n; exit }' "$WORK/sum"
}

aub=$(find_aub)

if [ "${STM_AI_ACTION:-}" = open ]; then
  if [ -n "$aub" ]; then
    "${STM_OPEN:-/usr/bin/open}" -b "$APP_ID" >/dev/null 2>&1
  else
    "${STM_OPEN:-/usr/bin/open}" "$APP_URL" >/dev/null 2>&1
  fi
fi

now=${STM_NOW:-$(/bin/date +%s)}
case $now in "" | *[!0-9]*) now=0 ;; esac

# state: missing (no aub), fail (aub gave nothing usable), else summarise's.
: >"$WORK/sum"
state=missing
if [ -n "$aub" ]; then
  state=fail
  if run_aub "$aub" && [ -s "$WORK/out.json" ]; then
    if parse >"$WORK/rec"; then
      summarise >"$WORK/sum"
      state=$(field state)
    fi
  fi
fi

case $state in
  missing) label="no aub" ;;
  fail) label=-- ;;
  *) label=$(field label) ;;
esac
[ "$state" = fail ] && [ "${STM_AI_VIEW:-}" = cost ] && label='$--'

case $state in
  green | yellow | red)
    state_color=$(color_of "$state")
    label_color=${STM_WHITE:-}
    ;;
  *)
    state_color=${STM_GREY:-}
    label_color=${STM_GREY:-}
    ;;
esac

set -- --set "$NAME"
text=$label
measured=$label
if [ "${STM_AI_VIEW:-}" = windows ]; then
  top=$(field lines 2)
  if [ -n "$top" ]; then
    text=$(field lines 4)
    set -- "$@" icon.drawing=on "icon=$top"
    c=$(color_of "$(field lines 3)")
    [ -n "$c" ] && set -- "$@" "icon.color=$c"
    label_color=$(color_of "$(field lines 5)")
    measured=$text
    [ ${#top} -gt ${#text} ] && measured=$top
  else
    set -- "$@" icon.drawing=off
  fi
fi
set -- "$@" "label=$text"
[ -n "$label_color" ] && set -- "$@" "label.color=$label_color"
if [ "${STM_AI_VIEW:-}" = windows ]; then
  if [ -n "$top" ]; then
    set -- "$@" label.y_offset=-5
  else
    set -- "$@" label.y_offset=0
  fi
fi

# label.width is the whole label, paddings included.
case "${STM_AI_CW:-}:${STM_AI_PAD:-}" in
  *[!0-9.:]* | :* | *:) ;;
  *)
    width=$(/usr/bin/awk -v n=${#measured} -v cw="$STM_AI_CW" -v pad="$STM_AI_PAD" \
      'BEGIN { w = n * cw; i = int(w); if (i < w) i++; print pad + i }')
    set -- "$@" "label.width=$width"
    ;;
esac

# The state colour: on the split icon's background, on the glyph that the
# windows view moves to <name>.icon, or on the main item's glyph.
if [ -n "$state_color" ]; then
  if [ "${STM_AI_SHAPE:-}" = split ]; then
    set -- "$@" --set "$NAME.icon" "background.color=$state_color"
  elif [ "${STM_AI_VIEW:-}" = windows ]; then
    set -- "$@" --set "$NAME.icon" "icon.color=$state_color"
  else
    set -- "$@" "icon.color=$state_color"
  fi
fi

# The popup.
n=0
foot="Open Agents Usage Bar"
case $state in
  missing | fail)
    if [ "$state" = missing ]; then
      head="aub not found"
      hint="install Agents Usage Bar, then run aub install"
      foot="Get Agents Usage Bar"
    else
      head="no cached usage yet"
      hint="open the app to start polling"
    fi
    set -- "$@" --set "$NAME.row.head" icon=aub "label=$head" --set "$NAME.row.0" drawing=on icon= "label=$hint"
    [ -n "${STM_GREY:-}" ] && set -- "$@" "label.color=$STM_GREY"
    n=1
    ;;
  *)
    head="$(field head 2) · $(field head 3) tok"
    [ "$(field head 5)" = 1 ] && head="$head · stale"
    asof=$(field head 4)
    [ -n "$asof" ] && head="$head · as of $(/bin/date -r "$asof" +%H:%M 2>/dev/null)"
    set -- "$@" --set "$NAME.row.head" icon=today "label=$head"
    while IFS="$US" read -r kind rname rlabel rband rnb; do
      [ "$kind" = row ] || continue
      set -- "$@" --set "$NAME.row.$n" drawing=on "icon=$rname"
      c=$(color_of "$rnb")
      [ -n "$c" ] && set -- "$@" "icon.color=$c"
      set -- "$@" "label=$rlabel"
      c=$(color_of "$rband")
      [ -n "$c" ] && set -- "$@" "label.color=$c"
      n=$((n + 1))
    done <"$WORK/sum"
    ;;
esac
while [ "$n" -lt "$ROWS" ]; do
  set -- "$@" --set "$NAME.row.$n" drawing=off
  n=$((n + 1))
done
set -- "$@" --set "$NAME.row.foot" "label=$foot"

sketchybar "$@"
