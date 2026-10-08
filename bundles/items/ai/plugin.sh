#!/bin/sh
# stm.ai plugin. Installed by `stm install item:ai` (#26, #27).
#
# item.lua runs this from the hidden driver item with:
#   NAME, SENDER                 the driver item and event; the segments are
#                                NAME.<provider>
#   STM_GREEN STM_YELLOW STM_RED STM_GREY STM_WHITE
#                                palette colours as 0xAARRGGBB (may be empty)
#   STM_AI_SHAPE                 plain | pill | split
#   STM_AI_ICON                  tag | image
#   STM_AI_ICON_DIR              <config dir>/icons/ai (image: the user's own
#                                <provider>.png files), or empty
#   STM_AI_CLAUDE STM_AI_CODEX STM_AI_GEMINI STM_AI_GROK STM_AI_OPENROUTER
#                                each provider's metric, auto or off
#   STM_AI_CW_<P> STM_AI_PAD_<P> each segment's label character width and
#                                paddings (empty until the bar has told
#                                item.lua its font)
#   STM_AI_ACTION                open (a popup's last row was clicked) or empty
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

# The enabled segments, left to right, as <provider>:<metric>:<auto 1|0>.
# An unset key is the manifest default (auto); a value outside the manifest
# values is off.
enabled=""
for p in claude codex gemini grok openrouter; do
  case $p in
    claude) v=${STM_AI_CLAUDE-auto} auto=worst ;;
    codex) v=${STM_AI_CODEX-auto} auto=worst ;;
    gemini) v=${STM_AI_GEMINI-auto} auto=worst ;;
    grok) v=${STM_AI_GROK-auto} auto=billing ;;
    *) v=${STM_AI_OPENROUTER-auto} auto=balance ;;
  esac
  case "$p:$v" in
    *:auto) enabled="$enabled $p:$auto:1" ;;
    claude:worst | claude:5h | claude:7d | claude:sonnet | claude:opus | claude:windows | claude:cost | \
      codex:worst | codex:5h | codex:weekly | codex:windows | codex:cost | gemini:worst | grok:billing | \
      openrouter:balance | openrouter:quota)
      enabled="$enabled $p:$v:0"
      ;;
  esac
done
[ -n "$enabled" ] || exit 0

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
#   asof <iso>
#   prov <i> <id> <status> <cost> <balance> <fraction> <tokens> <limit> <used>
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
  var out = ["asof\t" + text(doc.asOf)];
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
    out.push(["prov", i, id, text(p.status), value(p.costTodayUSD), value(p.balanceUSD), value(quota.fraction),
      value(p.tokensToday), value(quota.limit), value(quota.used)].join("\t"));
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

# summarise — the records in, what to draw out (fields split by 0x1F), per
# enabled segment in bar order:
#   asof <epoch> <stale 0|1>                                   (once, first)
#   seg <p> <shown 0|1> <label> <tag band> <label band> [<top> <band> <bottom> <band>]
#   head <p> <cost> <tokens>
#   row <name> <label> <label band> <name band>
#   end <p>
# Only known provider ids with status ok count, a provider's windows come from
# its accounts when any has some (the top level repeats them), and every
# value is checked before it reaches a label.
summarise() {
  /usr/bin/awk -F'\t' -v now="$now" -v want="$enabled" -v rows="$ROWS" \
    -v stale_secs="$STALE_SECS" -v ahead_secs="$AHEAD_SECS" '
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
    function suffix(n, id) {
      if (id != "claude" && id != "codex") return ""
      if (n == "5h" || n == "primary") return "5h"
      if (n == "secondary") return id == "codex" ? "wk" : "7d"
      if (n ~ /^7d/) return "7d"
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
    # usd: cents below <cents> dollars, then whole dollars, then thousands.
    function usd(s, cents, n) {
      if (s + 0 < cents) return sprintf("$%.2f", s)
      n = int(s + 0.5)
      return n >= 10000 ? "$" int(n / 1000) "k" : "$" n
    }
    function amount(s) { return s == int(s) ? int(s) : sprintf("%.2f", s) }
    function tok(n) {
      if (n < 1000) return n
      if (n < 1000000) return sprintf("%.1fK", n / 1000)
      if (n < 1000000000) return sprintf("%.1fM", n / 1000000)
      if (n < 1000000000000) return sprintf("%.1fB", n / 1000000000)
      return "999B+"
    }
    function pctlabel(p, s) { return sprintf("%3d%%", p) (s != "" ? " " s : "") }
    # line: a popup row for one window.
    function line(p, reset, r) {
      r = until(reset)
      return bar(p) " " sprintf("%3d%%", p) (r != "" ? "  ↻ " r : "")
    }
    function wrow(id, n, k, s) {
      if (id == "codex" && n == "primary") return "5h"
      if (id == "codex" && n == "secondary") return "weekly"
      s = clean(n)
      if (s != "") return s
      return (id == "gemini" ? "model " : "window ") k
    }
    # best: the highest pct of the window named <n> over the groups in G.
    function best(n, i, g, k, b) {
      b = ""
      for (i = 1; i <= ng; i++) {
        g = G[i]
        for (k = 1; k <= nwin[g]; k++)
          if (WN[g, k] == n && (b == "" || WP[g, k] > b)) b = WP[g, k]
      }
      return b
    }
    function addrow(name, label, lb, nb) {
      nrow++; RN[nrow] = name; RL[nrow] = label; RB[nrow] = lb; RNB[nrow] = nb
    }
    BEGIN {
      US = sprintf("%c", 31)
      split("▏ ▎ ▍ ▌ ▋ ▊ ▉", PART, " ")
      norder = split("claude codex gemini grok openrouter ollama-cloud", ORDER, " ")
      split("Claude Codex Gemini Grok OpenRouter", DISP, " ")
      for (k = 1; k <= norder; k++) { KNOWN[ORDER[k]] = k; DISPLAY[ORDER[k]] = DISP[k] }
      WORD["unauthenticated"] = "sign in"; WORD["notRunning"] = "not running"
      WORD["stale"] = "stale"; WORD["error"] = "error"
      # The metrics that name one window: its name and its bar suffix.
      split("claude 5h 5h 5h claude 7d 7d 7d claude sonnet 7d-sonnet 7d-s claude opus 7d-opus 7d-o " \
        "codex 5h primary 5h codex weekly secondary wk grok billing billing -", M, " ")
      for (k = 1; k in M; k += 4) { WNAME[M[k], M[k + 1]] = M[k + 2]; WSUF[M[k], M[k + 1]] = M[k + 3] == "-" ? "" : M[k + 3] }
    }
    $1 == "asof" { asof = epoch($2) }
    $1 == "prov" {
      if (!($3 in KNOWN) || ($3 in idx)) next
      idx[$3] = $2; id_of[$2] = $3
      status[$3] = $4; pcost[$3] = money($5); pbal[$3] = money($6); pfrac[$3] = pct($7)
      ptok[$3] = $8 ~ /^[0-9]+$/ ? $8 : ""; plim[$3] = money($9); pused[$3] = money($10)
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
      k = ++nwin[g]; WN[g, k] = $4; WP[g, k] = p; WR[g, k] = epoch($6)
      if (!(g in gpct) || p > gpct[g]) { gpct[g] = p; gwin[g] = $4 }
      if (($4 == "5h" || $4 == "primary") && (!(g in g5) || p > g5[g])) g5[g] = p
      if (($4 == "7d" || $4 == "secondary") && (!(g in g7) || p > g7[g])) g7[g] = p
    }
    END {
      stale = (asof == "" || now - asof > stale_secs || asof - now > ahead_secs) ? 1 : 0
      print "asof" US asof US stale
      nw = split(want, W, " ")
      for (w = 1; w <= nw; w++) {
        split(W[w], f, ":"); id = f[1]; m = f[2]; auto = f[3] == 1
        ng = 0; nrow = 0; toplevel = 0; worst = ""; i = ""
        if (id in idx) {
          i = idx[id]
          for (a = 1; a <= nacct[i]; a++) {
            g = i SUBSEP acct[i, a]
            if (nwin[g]) G[++ng] = g
          }
          toplevel = !ng && nwin[i SUBSEP "-"]
          if (toplevel) G[++ng] = i SUBSEP "-"
          for (n = 1; n <= ng; n++) if (worst == "" || gpct[G[n]] > gpct[worst]) worst = G[n]
        }
        ok = (id in idx) && status[id] == "ok"

        value = ""
        if (m == "worst" || m == "windows") {
          if (worst != "") value = pctlabel(gpct[worst], suffix(gwin[worst], id))
        } else if (m == "cost") {
          if (pcost[id] != "") value = usd(pcost[id], 10)
        } else if (m == "balance") {
          if (pbal[id] != "") value = usd(pbal[id], 1000)
        } else if (m == "quota") {
          if (pfrac[id] != "") value = pctlabel(pfrac[id], "")
        } else if ((id, m) in WNAME) {
          b = best(WNAME[id, m])
          if (b != "") value = pctlabel(b, WSUF[id, m])
        }
        tagp = id == "openrouter" ? pfrac[id] : worst != "" ? gpct[worst] : ""

        top = topb = bot = botb = ""
        if (ok && value != "") {
          shown = 1; label = value
          if (stale) { tb = "grey"; lb = "grey" }
          else { tb = tagp != "" ? band(tagp) : "white"; lb = "white" }
          if (m == "windows" && ((worst in g5) || (worst in g7))) {
            top = "5h " ((worst in g5) ? sprintf("%3d%%", g5[worst]) : " --")
            topb = (worst in g5) && !stale ? band(g5[worst]) : "grey"
            bot = (id == "codex" ? "wk " : "7d ") ((worst in g7) ? sprintf("%3d%%", g7[worst]) : " --")
            botb = (worst in g7) && !stale ? band(g7[worst]) : "grey"
          }
        } else if (auto) {
          shown = 0; label = tb = lb = ""
        } else {
          shown = 1; tb = lb = "grey"
          label = (id in idx) && status[id] == "unauthenticated" ? "sign in" : "--"
        }
        print "seg" US id US shown US label US tb US lb US top US topb US bot US botb
        print "head" US id US (pcost[id] != "" ? sprintf("$%.2f", pcost[id]) : "") US \
          (ptok[id] != "" ? tok(ptok[id]) " tok" : "")

        if (!(id in idx)) {
        } else if (status[id] != "ok") {
          if (status[id] in WORD) addrow(DISPLAY[id], WORD[status[id]], "grey", "grey")
        } else {
          for (a = 1; a <= nacct[i]; a++) {
            g = i SUBSEP acct[i, a]
            if (!nwin[g]) { addrow(aname[g], "no limit", "grey", "grey"); continue }
            addrow(aname[g], acost[g] != "" ? sprintf("$%.2f", acost[g]) : "", "white", "white")
            for (k = 1; k <= nwin[g]; k++)
              addrow("  " wrow(id, WN[g, k], k), line(WP[g, k], WR[g, k]), band(WP[g, k]), "white")
          }
          if (toplevel) {
            g = i SUBSEP "-"
            for (k = 1; k <= nwin[g]; k++) {
              l = line(WP[g, k], WR[g, k])
              if (id == "grok" && WN[g, k] == "billing" && pused[id] != "" && plim[id] != "")
                l = l "  " amount(pused[id]) " / " amount(plim[id])
              addrow(wrow(id, WN[g, k], k), l, band(WP[g, k]), "white")
            }
          }
          if (id == "openrouter") {
            if (pfrac[id] != "")
              addrow("credits", bar(pfrac[id]) " " sprintf("%3d%%", pfrac[id]) \
                (pbal[id] != "" ? sprintf("  $%.2f left", pbal[id]) : ""), band(pfrac[id]), "white")
            else if (pbal[id] != "")
              addrow("credits", sprintf("$%.2f left", pbal[id]), "white", "white")
            if (plim[id] != "") addrow("limit", sprintf("$%.2f", plim[id]), "white", "white")
          }
        }
        if (nrow > rows) {
          hidden = nrow - (rows - 1)
          nrow = rows - 1
          addrow("", "+" hidden " more", "grey", "white")
        }
        for (n = 1; n <= nrow; n++) print "row" US RN[n] US RL[n] US RB[n] US RNB[n]
        print "end" US id
      }
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

# Everything sent to sketchybar, one argument per line (no value holds a
# newline), for one call at the end.
emit() {
  printf '%s\n' "$@" >>"$WORK/args"
}

# segment <p> — make <p> the segment the next show / hide / popup acts on.
segment() {
  p=$1
  seg=$NAME.$p
  for x in $enabled; do
    case $x in "$p":*)
      metric=${x#*:}
      metric=${metric%%:*}
      ;;
    esac
  done
  case $p in
    claude) cw=${STM_AI_CW_CLAUDE:-} pad=${STM_AI_PAD_CLAUDE:-} ;;
    codex) cw=${STM_AI_CW_CODEX:-} pad=${STM_AI_PAD_CODEX:-} ;;
    gemini) cw=${STM_AI_CW_GEMINI:-} pad=${STM_AI_PAD_GEMINI:-} ;;
    grok) cw=${STM_AI_CW_GROK:-} pad=${STM_AI_PAD_GROK:-} ;;
    *) cw=${STM_AI_CW_OPENROUTER:-} pad=${STM_AI_PAD_OPENROUTER:-} ;;
  esac
  windows=0
  [ "$metric" = windows ] && windows=1
  icon_item=0
  [ "${STM_AI_SHAPE:-}" = split ] || [ "$windows" = 1 ] && icon_item=1
  pill=0
  [ "${STM_AI_SHAPE:-}" = pill ] && [ "$windows" = 1 ] && pill=1
  # The item whose icon holds the tag, and the image found for it (icon=image).
  target=$seg
  [ "$icon_item" = 1 ] && target=$seg.icon
  case $p in
    claude) tag=CL ;;
    codex) tag=CX ;;
    gemini) tag=GE ;;
    grok) tag=GK ;;
    *) tag=OR ;;
  esac
  img=""
  for x in $icons; do
    case $x in "$p":*)
      img=${x#*:}
      break
      ;;
    esac
  done
  [ "$img" = none ] && img=""
  return 0
}

# icon_set — icon=image: the image found for the segment, or its tag. An
# image is loaded only on a probing run; it persists on the item.
icon_set() {
  [ "${STM_AI_ICON:-}" = image ] || return 0
  if [ -z "$img" ]; then
    emit --set "$target" "icon=$tag" icon.background.drawing=off
  else
    emit --set "$target" icon= icon.background.drawing=on
    # 40x40 px -> 20 pt; an app's image was loaded by its probe.
    [ "$probing" = 1 ] && [ "$img" = file ] &&
      emit "icon.background.image=$icon_dir/$p.png" icon.background.image.scale=0.5
  fi
  return 0
}

# show <label> <tag band> <label band> [<top> <band> <bottom> <band>] — the
# segment drawn: the windows metric stacks <top> over <bottom> when it has
# them; the tag colour goes on the split tag's background, on the tag that
# the windows metric moves to <segment>.icon, or on the segment's own tag.
# An image is never tinted: on plain and pill its tag colour goes on the
# label; the windows lines keep their own colours.
show() {
  emit --set "$seg" drawing=on
  text=$1
  measured=$1
  label_color=$(color_of "$3")
  tag_color=$(color_of "$2")
  [ -n "$img" ] && [ -n "$tag_color" ] && [ "$windows" = 0 ] && [ "${STM_AI_SHAPE:-}" != split ] &&
    label_color=$tag_color
  if [ "$windows" = 1 ]; then
    if [ -n "${4:-}" ]; then
      emit icon.drawing=on "icon=$4"
      c=$(color_of "$5")
      [ -n "$c" ] && emit "icon.color=$c"
      text=$6
      label_color=$(color_of "$7")
      measured=$6
      [ ${#4} -gt ${#6} ] && measured=$4
    else
      emit icon.drawing=off
    fi
  fi
  emit "label=$text"
  [ -n "$label_color" ] && emit "label.color=$label_color"
  if [ "$windows" = 1 ]; then
    if [ -n "${4:-}" ]; then
      emit label.y_offset=-5
    else
      emit label.y_offset=0
    fi
  fi
  # label.width is the whole label, paddings included.
  case "$cw:$pad" in
    *[!0-9.:]* | :* | *:) ;;
    *)
      emit "label.width=$(/usr/bin/awk -v n=${#measured} -v cw="$cw" -v pad="$pad" \
        'BEGIN { w = n * cw; i = int(w); if (i < w) i++; print pad + i }')"
      ;;
  esac
  if [ "${STM_AI_SHAPE:-}" = split ]; then
    emit --set "$seg.icon" drawing=on
    [ -n "$tag_color" ] && emit "background.color=$tag_color"
  elif [ "$windows" = 1 ]; then
    emit --set "$seg.icon" drawing=on
    [ -n "$tag_color" ] && [ -z "$img" ] && emit "icon.color=$tag_color"
  elif [ -n "$tag_color" ] && [ -z "$img" ]; then
    emit "icon.color=$tag_color"
  fi
  [ "$pill" = 1 ] && emit --set "$seg.pill" drawing=on
  icon_set
}

hide() {
  emit --set "$seg" drawing=off popup.drawing=off
  [ "$icon_item" = 1 ] && emit --set "$seg.icon" drawing=off
  [ "$pill" = 1 ] && emit --set "$seg.pill" drawing=off
  icon_set
}

# popup_end — hide the unused rows from row $n on; set the foot.
popup_end() {
  while [ "$n" -lt "$ROWS" ]; do
    emit --set "$seg.row.$n" drawing=off
    n=$((n + 1))
  done
  emit --set "$seg.row.foot" "label=$foot"
}

# app_ids <p> — into $ids, the bundle ids whose app icon stands for <p>.
app_ids() {
  case $1 in
    claude) ids=com.anthropic.claudefordesktop ;;
    codex) ids="com.openai.codex com.openai.chat" ;;
    *) ids="" ;;
  esac
}

# icon_ok <p> <answer> — a cached answer this plugin could have written.
icon_ok() {
  case $1 in claude | codex | gemini | grok | openrouter) ;; *) return 1 ;; esac
  case $2 in
    file | none) return 0 ;;
    app.*)
      app_ids "$1"
      for id in $ids; do
        [ "$2" = "app.$id" ] && return 0
      done
      ;;
  esac
  return 1
}

# icon=image: per segment, the user's <icon dir>/<p>.png (that exact name, a
# regular file, never a symlink), else the installed app's icon, else the
# tag. SketchyBar exits non-zero when it cannot resolve a bundle id, so each
# app is probed with a --set of its own, which also loads its image. The
# answers (file, app.<id> or none per segment) are cached in the per-user
# temp dir and looked for again only on forced (reload, --update) and
# system_woke, or without a valid cache.
icons=""
probing=0
icon_dir=""
if [ "${STM_AI_ICON:-}" = image ]; then
  case ${STM_AI_ICON_DIR:-} in
    *[[:cntrl:]]*) ;;
    /*) icon_dir=$STM_AI_ICON_DIR ;;
  esac
  cache=""
  [ -n "$tmp" ] && cache="$tmp/stm-ai-icon.$NAME"
  case ${SENDER:-} in
    forced | system_woke) ;;
    *)
      if [ -n "$cache" ] && [ -f "$cache" ]; then
        while read -r cp cv rest; do
          [ -z "$rest" ] && icon_ok "$cp" "$cv" && icons="$icons $cp:$cv"
        done <"$cache"
      fi
      # Valid only with an answer for every enabled segment.
      for e in $enabled; do
        case "$icons " in *" ${e%%:*}:"*) ;; *) icons="" ;; esac
      done
      ;;
  esac
  if [ -z "$icons" ]; then
    probing=1
    for e in $enabled; do
      segment "${e%%:*}"
      v=none
      if [ -n "$icon_dir" ]; then
        for f in "$icon_dir"/*; do
          if [ "$f" = "$icon_dir/$p.png" ] && [ -f "$f" ] && [ ! -L "$f" ]; then
            v="file"
            break
          fi
        done
      fi
      if [ "$v" = none ]; then
        app_ids "$p"
        for id in $ids; do
          if sketchybar --set "$target" "icon.background.image=app.$id" icon.background.image.scale=0.625 \
            >/dev/null 2>&1; then
            v=app.$id
            break
          fi
        done
      fi
      icons="$icons $p:$v"
    done
    if [ -n "$cache" ] && c=$(/usr/bin/mktemp "$cache.XXXXXX" 2>/dev/null); then
      for x in $icons; do
        printf '%s %s\n' "${x%%:*}" "${x#*:}"
      done >"$c"
      /bin/mv -f "$c" "$cache" 2>/dev/null || /bin/rm -f "$c"
    fi
  fi
fi

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

# state: missing (no aub), fail (aub gave nothing usable), else ok.
: >"$WORK/args"
state=missing
if [ -n "$aub" ]; then
  state=fail
  if run_aub "$aub" && [ -s "$WORK/out.json" ]; then
    parse >"$WORK/rec" && summarise >"$WORK/sum" && state=ok
  fi
fi

foot="Open Agents Usage Bar"
if [ "$state" = ok ]; then
  # One segment after another, in bar order: its bar text, then its popup.
  while IFS="$US" read -r kind a b c d e f g h i; do
    case $kind in
      asof)
        stale=$b
        hhmm=""
        [ -n "$a" ] && hhmm=$(/bin/date -r "$a" +%H:%M 2>/dev/null)
        ;;
      seg)
        segment "$a"
        shown=$b
        if [ "$shown" = 1 ]; then
          show "$c" "$d" "$e" "$f" "$g" "$h" "$i"
        else
          hide
        fi
        ;;
      head)
        [ "$shown" = 1 ] || continue
        head=$b
        [ -n "$c" ] && head="${head:+$head · }$c"
        when=""
        [ -n "$hhmm" ] && when="as of $hhmm"
        [ "$stale" = 1 ] && when="stale${when:+ · $when}"
        [ -n "$when" ] && head="${head:+$head · }$when"
        emit --set "$seg.row.head" icon=today "label=$head"
        n=0
        ;;
      row)
        [ "$shown" = 1 ] || continue
        emit --set "$seg.row.$n" drawing=on "icon=$a"
        c2=$(color_of "$d")
        [ -n "$c2" ] && emit "icon.color=$c2"
        emit "label=$b"
        c2=$(color_of "$c")
        [ -n "$c2" ] && emit "label.color=$c2"
        n=$((n + 1))
        ;;
      end)
        [ "$shown" = 1 ] && popup_end
        ;;
    esac
  done <"$WORK/sum"
else
  # No usable data: say so on the first enabled segment only, with the popup
  # telling how to fix it, and hide the rest.
  if [ "$state" = missing ]; then
    label="no aub"
    head="aub not found"
    hint="install Agents Usage Bar, then run aub install"
    foot="Get Agents Usage Bar"
  else
    label=--
    head="no cached usage yet"
    hint="open the app to start polling"
  fi
  first=1
  for e in $enabled; do
    segment "${e%%:*}"
    if [ "$first" = 1 ]; then
      show "$label" grey grey
      emit --set "$seg.row.head" icon=aub "label=$head" --set "$seg.row.0" drawing=on icon= "label=$hint"
      [ -n "${STM_GREY:-}" ] && emit "label.color=$STM_GREY"
      n=1
      popup_end
      first=0
    else
      hide
    fi
  done
fi

set --
while IFS= read -r arg; do
  set -- "$@" "$arg"
done <"$WORK/args"
sketchybar "$@"
