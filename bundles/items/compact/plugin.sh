#!/bin/sh
# stm.compact plugin. Installed by `stm install item:compact` (#30).
#
# item.lua runs this with:
#   NAME, SENDER        the SketchyBar item (stm.compact) and event
#   STM_COMPACT_UNITS   <name>:<priority>:<forms>,... one per installed item
#                       that draws compact forms (a "unit")
#   STM_CMP_MODE        shrink | page (anything else is shrink)
#   STM_CMP_ACTION      prev | next: a click on a page arrow (page mode only)
#   STM_WHITE, STM_GREY the page arrows' colours, 0xAARRGGBB (page mode only)
#
# One run: query the bar, its displays and every bar item (one call), read
# each screen's notch (one osascript), fit the units into the room the
# tightest display has, then send one `stm_compact` trigger when a form
# changed and one --set / --move batch on stm.compact* when the chevron
# changed. Every unit draws its own form; this never sets another item.
#
# Room per display: from the notch's right edge (else the end of the left
# items) + 8 to the bar's right edge, minus every other right item, 8 per
# shown unit and the chevron (24 + 8) while a unit is hidden. Units step down
# short, then icon, then hidden; within a step low priority first, then
# normal, then high, leftmost first; pin never leaves full. A unit steps back
# up only when it still fits with 24 to spare, at a width measured before.
#
# Widths are measured from bounding_rects and cached per form in the per-user
# temp dir (stm-compact.widths); the last forms sent and the refresh rate in
# stm-compact.state. Both are checked on read: a bad row is dropped. A
# trigger can land before a unit takes it (a reload, a display switch), so
# each change is sent once more on the next run, and widths are fitted and
# cached only when the run before sent nothing.
#
# page mode (#31): units are only full or hidden. The bar shows a window of
# them: from the unit `page` places in from the right end, leftward while
# their cached full widths + 8 each fit the room (the first is always in).
# pin units stay, their width off the room first; the ‹ › arrows take 2 * 24
# + 8 while a unit is out of the window. A unit that draws nothing or was
# never measured costs nothing. The window grows only with 24 to spare and
# shrinks at once. A click on an arrow moves the window one unit and on past
# units that cost nothing; the arrow with nothing more to show is grey and
# does nothing. A click run asks the bar nothing: it fits the cached widths
# into the room the last full run wrote (`budget`), in the order that run
# wrote the `form` rows (rightmost first). With no room or no width on file
# yet, the click is a full run.
#
# STM_OSASCRIPT overrides /usr/bin/osascript (tests).

LC_ALL=C
export LC_ALL

NAME=${NAME:-stm.compact}
[ "$NAME" = stm.compact ] || exit 0
mode=shrink
[ "$STM_CMP_MODE" = page ] && mode=page
act=""
if [ "$mode" = page ]; then
  case "$STM_CMP_ACTION" in
    prev | next) act=$STM_CMP_ACTION ;;
  esac
fi

tmp=${TMPDIR:-$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null)}
WORK=$(/usr/bin/mktemp -d "${tmp:-/tmp}/stm-compact.XXXXXX") || exit 0
trap '/bin/rm -rf "$WORK"' EXIT
cache=""
state=""
if [ -n "$tmp" ] && [ -d "$tmp" ]; then
  cache=${tmp%/}/stm-compact.widths
  state=${tmp%/}/stm-compact.state
fi

# Units, checked again here: name, priority, forms "full [short] [icon]".
printf '%s\n' "$STM_COMPACT_UNITS" | /usr/bin/tr ',' '\n' | /usr/bin/awk -F: '
  NF == 3 && $1 ~ /^[a-z][a-z0-9_-]*$/ && length($1) <= 30 && $1 != "compact" &&
  $2 ~ /^(pin|high|normal|low)$/ &&
  ($3 == "full" || $3 == "full short" || $3 == "full icon" || $3 == "full short icon") &&
  !seen[$1]++ { print $1, $2, $3 }' >"$WORK/units"
[ -s "$WORK/units" ] || exit 0

[ -n "$cache" ] && [ -f "$cache" ] && /bin/cat "$cache" >"$WORK/cache" 2>/dev/null
[ -n "$state" ] && [ -f "$state" ] && /bin/cat "$state" >"$WORK/state" 2>/dev/null
: >>"$WORK/cache"
: >>"$WORK/state"

# measure — the bar, its displays, its items and each screen's notch.
measure() {
  sketchybar --query bar >"$WORK/bar" 2>/dev/null
  sketchybar --query displays >"$WORK/displays" 2>/dev/null

  # Every bar item but popup rows and this item's own, in one query call. A
  # name is only ever an argv word here.
  set --
  while IFS= read -r n; do
    case "$n" in
      "$NAME" | "$NAME".* | stm.*.row.*) continue ;;
    esac
    set -- "$@" --query "$n"
  done <<EOF
$(/usr/bin/awk -F'"' '
  /"items"[ \t]*:/ { on = 1; next }
  on && /^[ \t]*\]/ { exit }
  on && NF == 3 && $2 != "" && $2 !~ /\\/ { print $2 }' "$WORK/bar")
EOF
  [ "$#" -gt 0 ] || exit 0
  sketchybar "$@" >"$WORK/items" 2>/dev/null

  # Each screen: frame x, width, height, and the x where the notch ends (the
  # top-right auxiliary area's left edge, in global coordinates), or "-".
  "${STM_OSASCRIPT:-/usr/bin/osascript}" -l JavaScript -e '
ObjC.import("AppKit");
var s = $.NSScreen.screens, out = [];
for (var i = 0; i < s.count; i++) {
  var c = s.objectAtIndex(i), f = c.frame, n = "-";
  if (c.auxiliaryTopRightArea !== undefined) {
    var r = c.auxiliaryTopRightArea;
    if (r.size.width > 0) n = r.origin.x;
  }
  out.push([f.origin.x, f.size.width, f.size.height, n].join(" "));
}
out.join("\n");' >"$WORK/screens" 2>/dev/null || : >"$WORK/screens"
}

# fit <fast> <file>... — the fit over those files, into $WORK/out. One record
# per line: `T <arg>` trigger argv, `S <arg>` set / move argv, `C <row>` widths
# cache, `X <row>` state. Nothing when the bar, its displays or its items
# could not be read, or a click had nothing to move. <fast> = 1: a click run
# over units, cache and state only; exit 3 when those are not enough.
fit() {
  fast=$1
  shift
  # shellcheck disable=SC2016  # awk source
  /usr/bin/awk -v name="$NAME" -v sender="$SENDER" -v work="$WORK" -v mode="$mode" \
    -v fast="$fast" -v act="$act" -v white="$STM_WHITE" -v grey="$STM_GREY" '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t,]+$/, "", s); return s }
function isnum(s) { return s ~ /^-?[0-9]+(\.[0-9]+)?$/ }
function rnd(x) { return int(x + 0.5) }
function abs(x) { return x < 0 ? -x : x }
function rank(f) { return f == "full" ? 0 : f == "short" ? 1 : f == "icon" ? 2 : 3 }

# SketchyBar pretty-prints one key per line; walk it with a key stack.
function walk(line,   key, rest) {
  line = trim(line)
  if (line == "") return
  if (match(line, /^"[^"]*"[ \t]*:/)) {
    key = substr(line, 2, index(substr(line, 2), "\"") - 1)
    rest = trim(substr(line, RLENGTH + 1))
    if (rest == "{" || rest == "[") { stk[++dep] = key; return }
    if (rest ~ /^\[.*\]$/) rest = trim(substr(rest, 2, length(rest) - 2))
    if (rest ~ /^".*"$/) rest = substr(rest, 2, length(rest) - 2)
    val(key, rest)
    return
  }
  if (line ~ /^[]}]/) {
    if (dep > 0) dep--
    if (dep == 0 && kind == "items") end_item()
    return
  }
  if (line ~ /^[[{]/) {
    stk[++dep] = ""
    if (dep == 1 && kind == "items") { iname = ""; itype = ""; idraw = ""; ipos = ""; nr = 0 }
    return
  }
  if (kind == "bar" && dep == 2 && stk[2] == "items" && line ~ /^".+"$/)
    idx[substr(line, 2, length(line) - 2)] = ++nidx
}

function val(key, v,   d) {
  if (kind == "bar" && dep == 1) {
    if (key == "margin" || key == "padding_left" || key == "padding_right") { if (isnum(v)) bar[key] = v }
    else if (key == "position") bar[key] = v
  } else if (kind == "displays" && dep == 2 && key == "arrangement-id") {
    did = v
  } else if (kind == "displays" && dep == 3 && stk[3] == "frame" && isnum(v) && did ~ /^[0-9]+$/) {
    frame[did, key] = v
    if (key == "w") ndisp++
  } else if (kind == "items" && dep == 1) {
    if (key == "name") iname = v
    else if (key == "type") itype = v
  } else if (kind == "items" && dep == 2 && stk[2] == "geometry") {
    if (key == "drawing") idraw = v
    else if (key == "position") ipos = v
  } else if (kind == "items" && dep == 3 && stk[2] == "bounding_rects" && stk[3] ~ /^display-[0-9]+$/) {
    d = substr(stk[3], 9)
    split(v, xy, /[ \t]*,[ \t]*/)
    if (!isnum(xy[1])) return
    if (key == "origin") { rx[d] = xy[1]; rd[++nr] = d }
    else if (key == "size") rw[d] = xy[1]
  }
}

function unit_of(n,   i, u) {
  for (i = 1; i <= nu; i++) {
    u = un[i]
    if (n == "stm." u || index(n, "stm." u ".") == 1) return u
  }
  return ""
}

# One queried item: keep drawn left / right items, never brackets.
function end_item(   k, d, u) {
  if (iname == "" || !(iname in idx)) return
  if (ipos == "right") {
    u = unit_of(iname)
    if (u != "") { present[u] = 1; if (!(u in uidx) || idx[iname] < uidx[u]) uidx[u] = idx[iname] }
    if (u != "" && idx[iname] > lastidx) { lastidx = idx[iname]; lastname = iname }
    if (u == "" && iname != name && index(iname, name ".") != 1) rights[++nrt] = iname
  }
  if (idraw != "on" || itype == "bracket" || (ipos != "left" && ipos != "right")) return
  for (k = 1; k <= nr; k++) {
    d = rd[k]
    if (!(d in rw) || !isnum(rw[d])) continue
    shows[d] = 1
    if (ipos == "left") {
      if (!(d in leftend) || rx[d] + rw[d] > leftend[d]) leftend[d] = rx[d] + rw[d]
    } else if (u != "") {
      mwd[u, d] += rw[d]
    } else if (iname != name && index(iname, name ".") != 1) {
      foreign[d] += rw[d]
    }
  }
  delete rx; delete rw
}

# Width of unit u in form f: measured (the form it is in), cached, or a
# guess (icon 24, short half of full); -1 = unknown.
function wid(u, f,   fw) {
  if (f == "hidden") return 0
  if (f == cur0[u] && mw[u] > 0) return mw[u]
  if ((u SUBSEP f) in cw) return cw[u, f]
  if (f == "icon") return 24
  if (f == "short") { fw = wid(u, "full"); return fw < 0 ? -1 : rnd(fw * 0.5) }
  return -1
}

function need(   i, u, s, w, hid) {
  s = 0; hid = 0
  for (i = 1; i <= nu; i++) {
    u = un[i]
    if (!present[u] || absent[u]) continue
    if (form[u] == "hidden") { hid = 1; continue }
    w = wid(u, form[u])
    s += (w < 0 ? 24 : w) + 8
  }
  return s + (hid ? 32 : 0)
}

# The nearest wider form of unit u with a cached width, or "": a form the
# unit skipped on the way down was never measured, so it is skipped going up.
function up_of(u,   n, fl, k) {
  n = split(uforms[u], fl, " ")
  for (k = n; k >= 1; k--) {
    if (rank(fl[k]) >= rank(form[u])) continue
    if ((u SUBSEP fl[k]) in cw) return fl[k]
  }
  return ""
}

# page mode. What unit u costs the window: its cached full width + its gap;
# nothing while it draws nothing or was never measured.
function pcost(u) { return (absent[u] || !((u SUBSEP "full") in cw)) ? 0 : cw[u, "full"] + 8 }

# The form last sent to unit u, as page mode knows forms: full or hidden.
function pform(u) { return ((u in last) && last[u] == "hidden") ? "hidden" : "full" }

# The last place of the window that starts o places in and has room b: the
# first unit is always in; a unit that costs nothing never ends the window.
function wend(o, b,   j, s, c) {
  s = pcost(P[o + 1])
  for (j = o + 2; j <= np; j++) {
    c = pcost(P[j])
    if (c > 0 && s + c > b) break
    s += c
  }
  return j - 1
}

# Is a unit that costs something right of the window that starts o places in?
function more(o,   j) {
  for (j = 1; j <= o; j++) if (pcost(P[j]) > 0) return 1
  return 0
}

FILENAME != curf { curf = FILENAME; kind = substr(FILENAME, length(work) + 2); dep = 0 }
kind == "units" { un[++nu] = $1; upri[$1] = $2; uforms[$1] = $3 " " $4 " " $5; sub(/ +$/, "", uforms[$1])
  for (i = 3; i <= NF; i++) has[$1, $i] = 1; isu[$1] = 1; next }
kind == "cache" {
  if (NF == 3 && ($1 in isu) && ($1 SUBSEP $2) in has && $3 ~ /^[0-9]+$/ && length($3) <= 4 && $3 >= 1 && $3 <= 4000)
    { cw[$1, $2] = $3 + 0; ncw++ }
  next
}
kind == "state" {
  if ($1 == "form" && NF == 3 && ($2 in isu) && ($3 == "hidden" || ($2 SUBSEP $3) in has)) {
    if (!($2 in last)) sord[++nso] = $2
    last[$2] = $3
  }
  else if ($1 == "page" && NF == 2 && $2 ~ /^[0-9]+$/ && length($2) <= 2 && $2 <= 63) spage = $2 + 0
  else if ($1 == "budget" && NF == 2 && $2 ~ /^[0-9]+$/ && length($2) <= 5 && $2 <= 10000) sbudget = $2 + 0
  else if ($1 == "freq" && NF == 2 && ($2 == "2" || $2 == "30")) sfreq = $2
  else if ($1 == "calm" && NF == 2 && $2 ~ /^[0-9]$/) calm = $2 + 0
  else if ($1 == "hid" && NF == 2 && $2 ~ /^[a-z0-9_,-]+$/) shid = $2
  else if ($1 == "sent" && NF == 2 && $2 ~ /^[012]$/) psent = $2 + 0
  next
}
kind == "screens" {
  if (NF == 4 && isnum($1) && isnum($2) && isnum($3) && (isnum($4) || $4 == "-")) {
    ns++; sx[ns] = $1; sw[ns] = $2; sh[ns] = $3; sn[ns] = $4
  }
  next
}
{ walk($0) }

END {
  forced = (sender == "forced")
  if (fast) {
    # A click: the room and the order of the units as the last full run
    # wrote them.
    if (mode != "page" || act == "" || sbudget == "" || !ncw || !nso) exit 3
    m = nso
    for (k = 1; k <= m; k++) { ord[k] = sord[k]; present[sord[k]] = 1 }
    avail = sbudget
  } else {
  if (nidx == 0 || ndisp == 0) exit
  if (!("margin" in bar)) bar["margin"] = 0
  if (!("padding_left" in bar)) bar["padding_left"] = 0
  if (!("padding_right" in bar)) bar["padding_right"] = 0

  avail = ""
  for (d in shows) {
    if (!((d SUBSEP "w") in frame)) continue
    W = frame[d, "w"]
    notch = 0
    for (k = 1; k <= ns; k++) {
      if (sn[k] == "-" || abs(sx[k] - frame[d, "x"]) >= 1 || abs(sw[k] - W) >= 1 || abs(sh[k] - frame[d, "h"]) >= 1) continue
      if (sn[k] - sx[k] > 0 && sn[k] - sx[k] < W) notch = sn[k] - sx[k]
    }
    # bounding_rects are in global coordinates: the left items end at
    # their right edge minus the x of the display.
    if (notch > 0 && bar["position"] != "bottom") start = notch + 8
    else start = (d in leftend ? leftend[d] - frame[d, "x"] : bar["margin"] + bar["padding_left"]) + 8
    a = W - bar["margin"] - bar["padding_right"] - start - foreign[d]
    if (avail == "" || a < avail) avail = a
    # Every display shows the same items: a unit measured differently on
    # two of them is mid-redraw.
    for (i = 1; i <= nu; i++) {
      u = un[i]
      if (mwd[u, d] > mw[u]) mw[u] = mwd[u, d]
      if (!(u in mwlo) || mwd[u, d] < mwlo[u]) mwlo[u] = mwd[u, d]
    }
  }
  if (avail == "") exit

  # Rightmost first: right items are laid out right to left by index.
  m = 0
  for (i = 1; i <= nu; i++) {
    u = un[i]
    if (!present[u]) continue
    for (k = m; k > 0 && uidx[ord[k]] > uidx[u]; k--) ord[k + 1] = ord[k]
    ord[k + 1] = u; m++
  }
  }

  # icon drops the label: a cached icon width as wide as full was measured
  # before the unit redrew.
  for (i = 1; i <= nu; i++) {
    u = un[i]
    if (((u SUBSEP "icon") in cw) && ((u SUBSEP "full") in cw) && cw[u, "icon"] >= cw[u, "full"]) delete cw[u, "icon"]
  }

  for (i = 1; i <= nu; i++) {
    u = un[i]
    # A reload (forced) draws every unit full again.
    cur0[u] = (forced || !(u in last) || upri[u] == "pin") ? "full" : last[u]
    form[u] = cur0[u]
    absent[u] = !fast && present[u] && cur0[u] != "hidden" && mw[u] <= 0
  }

  # Right after a trigger the widths may still be those of the old forms: keep the
  # forms sent until a run has passed with none sent.
  split("short icon hidden", FD, " "); split("low normal high", PD, " ")
  if (mode == "page") {
    room = int(avail)
    if (room < 0) room = 0
    if (room > 10000) room = 10000
    b = room; np = 0; tot = 0; wasall = 1
    for (k = 1; k <= m; k++) {
      u = ord[k]; form[u] = "full"
      if (upri[u] == "pin") { b -= pcost(u); continue }
      P[++np] = u; tot += pcost(u)
      if (pform(u) != "full") wasall = 0
    }
    # Every unit fits without the arrows: no paging. From a paged bar, only
    # with 24 to spare.
    paged = (np > 0 && tot + (wasall ? 0 : 24) > b)
    o = spage + 0; moved = 0
    if (paged) {
      b -= 56
      # omax: the first window that reaches the leftmost unit.
      for (omax = 0; omax < np - 1 && wend(omax, b) < np; omax++) ;
      if (o > omax) o = omax
      # One unit a click, and on past units that cost nothing: dropping or
      # adding one of those would show no change.
      if (act == "prev") {
        if (o < omax) { while (o < omax && pcost(P[o + 1]) == 0) o++; if (o < omax) o++; moved = 1 }
        else if (pform(P[np]) != "full") moved = 1
      } else if (act == "next" && more(o)) {
        o--; while (pcost(P[o + 1]) == 0) o--; moved = 1
      }
    }
    # A click on the arrow at its end: nothing sent, nothing written.
    if (fast && !moved) exit
    if (psent && !forced && !moved) {
      o = spage + 0
      for (j = 1; j <= np; j++) form[P[j]] = pform(P[j])
    } else if (paged) {
      e = wend(o, b)
      if (!moved) {
        # el: where the window last sent ends, from this offset.
        el = o
        for (j = o + 1; j <= np && pform(P[j]) == "full"; j++) el = j
        if (e > el) { e = wend(o, b - 24); if (e < el) e = el }
      }
      for (j = 1; j <= np; j++) form[P[j]] = (j > o && j <= e) ? "full" : "hidden"
    } else o = 0
  } else if (psent && !forced) {
  } else if (need() > avail) {
    for (a = 1; a <= 3; a++) for (p = 1; p <= 3; p++) for (k = m; k >= 1; k--) {
      if (need() <= avail) break
      u = ord[k]
      if (upri[u] != PD[p] || absent[u] || rank(form[u]) >= rank(FD[a])) continue
      if (FD[a] != "hidden" && !has[u, FD[a]]) continue
      form[u] = FD[a]
    }
  } else {
    split("hidden icon short", FU, " "); split("high normal low", PU, " ")
    do {
      grew = 0
      for (a = 1; a <= 3; a++) for (p = 1; p <= 3; p++) for (k = 1; k <= m; k++) {
        u = ord[k]
        if (form[u] != FU[a] || upri[u] != PU[p] || absent[u]) continue
        upf = up_of(u)
        if (upf == "") continue
        was = form[u]; form[u] = upf
        if (need() + 24 <= avail) grew = 1
        else form[u] = was
      }
    } while (grew)
  }

  # A trigger may land before a unit can take it (a reload, a display
  # switch): each change is sent once more on the next run.
  changed = forced
  for (i = 1; i <= nu; i++) {
    u = un[i]
    if (form[u] != ((u in last) ? last[u] : "full")) changed = 1
  }
  sent = changed ? 2 : (psent == 2 ? 1 : 0)
  if (sent) {
    for (i = 1; i <= nu; i++) {
      key = toupper(un[i]); gsub(/[.-]/, "_", key)
      print "T STM_FORM_" key "=" form[un[i]]
    }
  }

  # Cache the width of the form each unit is drawn in, only when the run
  # before sent no trigger (the units have had a run to redraw) and never on
  # a reload (the bar may still be filling in).
  unsettled = sent
  for (i = 1; i <= nu; i++) {
    u = un[i]
    if (forced || psent || !present[u]) continue
    if (mode == "page") {
      # Only full is drawn on purpose. A unit that draws nothing loses its
      # width: it costs the window nothing and a click steps past it.
      if (cur0[u] != "full") continue
      if (absent[u] && ((u SUBSEP "full") in cw)) { delete cw[u, "full"]; unsettled = 1 }
    }
    if (mw[u] <= 0) continue
    if (mw[u] - mwlo[u] > 1) { unsettled = 1; continue }
    w = rnd(mw[u])
    if (w < 1 || w > 4000) continue
    if (!((u SUBSEP cur0[u]) in cw) || cw[u, cur0[u]] != w) { unsettled = 1; cw[u, cur0[u]] = w }
  }
  for (i = 1; i <= nu; i++) {
    n = split(uforms[un[i]], fl, " ")
    for (k = 1; k <= n; k++) if ((un[i] SUBSEP fl[k]) in cw) print "C " un[i] " " fl[k] " " cw[un[i], fl[k]]
  }

  calm = unsettled ? 0 : calm + 1
  if (calm > 9) calm = 9
  freq = calm >= 2 ? 30 : 2

  hid = ""; nh = 0
  # page mode has no chevron: the arrows reach the hidden units.
  if (mode != "page")
    for (k = 1; k <= m; k++) if (form[ord[k]] == "hidden" && nh < 16) { hid = hid (nh ? "," : "") ord[k]; row[nh++] = ord[k] }
  if (hid == "") hid = "-"

  # page mode: the units on the right only, rightmost first; a click run
  # reads the page order from these rows.
  if (mode == "page") for (k = 1; k <= m; k++) print "X form " ord[k] " " form[ord[k]]
  else for (i = 1; i <= nu; i++) print "X form " un[i] " " form[un[i]]
  print "X freq " freq
  print "X calm " calm
  print "X hid " hid
  print "X sent " sent
  if (mode == "page") { print "X page " o; print "X budget " room }

  ns_ = 0
  if (forced || hid != shid) {
    set_[++ns_] = (nh ? "drawing=on" : "drawing=off")
    if (!nh) set_[++ns_] = "popup.drawing=off"
  }
  if (forced || freq "" != sfreq) set_[++ns_] = "update_freq=" freq
  if (ns_) { print "S --set"; print "S " name; for (k = 1; k <= ns_; k++) print "S " set_[k] }
  if (forced || hid != shid) {
    for (k = 0; k < 16; k++) {
      print "S --set"; print "S " name ".row." k
      if (k < nh) { print "S label=" row[k]; print "S drawing=on" }
      else print "S drawing=off"
    }
  }

  # The arrows: drawn while a unit is out of the window; grey when there is
  # nothing more that way (the leftmost unit shown; no unit right of the
  # window that costs something).
  if (mode == "page" && (fast || (((name ".prev") in idx) && ((name ".next") in idx))) &&
      (forced || changed || spage == "" || o != spage)) {
    aon = 0
    for (j = 1; j <= np; j++) if (form[P[j]] == "hidden") aon = 1
    acol["prev"] = (np == 0 || form[P[np]] == "full") ? grey : white
    acol["next"] = more(o) ? white : grey
    split("prev next", AR, " ")
    for (k = 1; k <= 2; k++) {
      print "S --set"; print "S " name "." AR[k]; print "S drawing=" (aon ? "on" : "off")
      if (aon && acol[AR[k]] ~ /^0x[0-9a-f]+$/ && length(acol[AR[k]]) == 10) print "S icon.color=" acol[AR[k]]
    }
  }

  # Keep the chevron just left of the last stm unit on the right; in page
  # mode the arrows left of it, next then prev (prev is the left one).
  nown = 0
  own[++nown] = name
  if (mode == "page" && ((name ".next") in idx) && ((name ".prev") in idx)) { own[++nown] = name ".next"; own[++nown] = name ".prev" }
  if (lastname != "" && (name in idx)) {
    mv = 0; at = lastidx
    for (k = 1; k <= nown; k++) { if (idx[own[k]] < at) mv = 1; at = idx[own[k]] }
    for (k = 1; k <= nrt; k++) if (idx[rights[k]] > lastidx && idx[rights[k]] < at) mv = 1
    if (mv) for (k = 1; k <= nown; k++) { print "S --move"; print "S " own[k]; print "S after"; print "S " (k == 1 ? lastname : own[k - 1]) }
  }
}' "$@" >"$WORK/out"
}

if [ -n "$act" ] && fit 1 "$WORK/units" "$WORK/cache" "$WORK/state"; then
  :
else
  measure
  fit 0 "$WORK/units" "$WORK/cache" "$WORK/state" "$WORK/screens" "$WORK/bar" "$WORK/displays" "$WORK/items"
fi

[ -s "$WORK/out" ] || exit 0

# save <tag> <file> — the <tag> records as <file>, replaced whole (mktemp +
# mv), only when they differ.
save() {
  [ -n "$2" ] || return 0
  /usr/bin/sed -n "s/^$1 //p" "$WORK/out" >"$WORK/save.$1"
  [ -f "$2" ] && /usr/bin/cmp -s "$WORK/save.$1" "$2" && return 0
  t=$(/usr/bin/mktemp "$2.XXXXXX" 2>/dev/null) || return 0
  if /bin/cat "$WORK/save.$1" >"$t" && /bin/mv -f "$t" "$2"; then :; else /bin/rm -f "$t"; fi
}
save C "$cache"
save X "$state"

# One trigger with every unit's form, then one batch on stm.compact*. Each
# record is one argv word.
set --
while IFS= read -r a; do
  [ -n "$a" ] && set -- "$@" "$a"
done <<EOF
$(/usr/bin/sed -n 's/^T //p' "$WORK/out")
EOF
[ "$#" -gt 0 ] && sketchybar --trigger stm_compact "$@"

set --
while IFS= read -r a; do
  [ -n "$a" ] && set -- "$@" "$a"
done <<EOF
$(/usr/bin/sed -n 's/^S //p' "$WORK/out")
EOF
[ "$#" -gt 0 ] && sketchybar "$@"
exit 0
