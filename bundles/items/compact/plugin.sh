#!/bin/sh
# stm.compact plugin. Installed by `stm install item:compact` (#30).
#
# item.lua runs this with:
#   NAME, SENDER        the SketchyBar item (stm.compact) and event
#   STM_COMPACT_UNITS   <name>:<priority>:<forms>,... one per installed item
#                       that draws compact forms (a "unit")
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
# STM_OSASCRIPT overrides /usr/bin/osascript (tests).

LC_ALL=C
export LC_ALL

NAME=${NAME:-stm.compact}
[ "$NAME" = stm.compact ] || exit 0

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

sketchybar --query bar >"$WORK/bar" 2>/dev/null
sketchybar --query displays >"$WORK/displays" 2>/dev/null

# Every bar item but popup rows and this item's own, in one query call. A name
# is only ever an argv word here.
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

[ -n "$cache" ] && [ -f "$cache" ] && /bin/cat "$cache" >"$WORK/cache" 2>/dev/null
[ -n "$state" ] && [ -f "$state" ] && /bin/cat "$state" >"$WORK/state" 2>/dev/null
: >>"$WORK/cache"
: >>"$WORK/state"

# Output, one record per line: `T <arg>` trigger argv, `S <arg>` set / move
# argv, `C <row>` widths cache, `X <row>` state. Nothing when the bar, its
# displays or its items could not be read.
# shellcheck disable=SC2016  # awk source
/usr/bin/awk -v name="$NAME" -v sender="$SENDER" -v work="$WORK" '
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

FILENAME != curf { curf = FILENAME; kind = substr(FILENAME, length(work) + 2); dep = 0 }
kind == "units" { un[++nu] = $1; upri[$1] = $2; uforms[$1] = $3 " " $4 " " $5; sub(/ +$/, "", uforms[$1])
  for (i = 3; i <= NF; i++) has[$1, $i] = 1; isu[$1] = 1; next }
kind == "cache" {
  if (NF == 3 && ($1 in isu) && ($1 SUBSEP $2) in has && $3 ~ /^[0-9]+$/ && length($3) <= 4 && $3 >= 1 && $3 <= 4000)
    cw[$1, $2] = $3 + 0
  next
}
kind == "state" {
  if ($1 == "form" && NF == 3 && ($2 in isu) && ($3 == "hidden" || ($2 SUBSEP $3) in has)) last[$2] = $3
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
  if (nidx == 0 || ndisp == 0) exit
  forced = (sender == "forced")
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

  # icon drops the label: a cached icon width as wide as full was measured
  # before the unit redrew.
  for (i = 1; i <= nu; i++) {
    u = un[i]
    if (((u SUBSEP "icon") in cw) && ((u SUBSEP "full") in cw) && cw[u, "icon"] >= cw[u, "full"]) delete cw[u, "icon"]
  }

  # Rightmost first: right items are laid out right to left by index.
  m = 0
  for (i = 1; i <= nu; i++) {
    u = un[i]
    if (!present[u]) continue
    for (k = m; k > 0 && uidx[ord[k]] > uidx[u]; k--) ord[k + 1] = ord[k]
    ord[k + 1] = u; m++
  }

  for (i = 1; i <= nu; i++) {
    u = un[i]
    # A reload (forced) draws every unit full again.
    cur0[u] = (forced || !(u in last) || upri[u] == "pin") ? "full" : last[u]
    form[u] = cur0[u]
    absent[u] = present[u] && cur0[u] != "hidden" && mw[u] <= 0
  }

  # Right after a trigger the widths may still be those of the old forms: keep the
  # forms sent until a run has passed with none sent.
  split("short icon hidden", FD, " "); split("low normal high", PD, " ")
  if (psent && !forced) {
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
    if (forced || psent || !present[u] || mw[u] <= 0) continue
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
  for (k = 1; k <= m; k++) if (form[ord[k]] == "hidden" && nh < 16) { hid = hid (nh ? "," : "") ord[k]; row[nh++] = ord[k] }
  if (hid == "") hid = "-"

  for (i = 1; i <= nu; i++) print "X form " un[i] " " form[un[i]]
  print "X freq " freq
  print "X calm " calm
  print "X hid " hid
  print "X sent " sent

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

  # Keep the chevron just left of the last stm unit on the right.
  if (lastname != "" && (name in idx)) {
    mv = idx[name] < lastidx
    for (k = 1; k <= nrt; k++) if (idx[rights[k]] > lastidx && idx[rights[k]] < idx[name]) mv = 1
    if (mv) { print "S --move"; print "S " name; print "S after"; print "S " lastname }
  }
}' "$WORK/units" "$WORK/cache" "$WORK/state" "$WORK/screens" "$WORK/bar" "$WORK/displays" "$WORK/items" >"$WORK/out"

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
