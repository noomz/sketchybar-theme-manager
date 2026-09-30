#!/usr/bin/env bash
#
# bundles/items/tailscale/plugin.sh (#16). Runs the plugin as SketchyBar would,
# against a fake `tailscale` (status JSON fixtures, a hang, no CLI) and a fake
# `sketchybar` that logs its argv one per line. Every state runs through both
# parsers — jq and the /usr/bin/plutil fallback — which must agree.
# Never touches the real tailscale CLI or the real bar.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

PLUGIN="$REPO_ROOT/bundles/items/tailscale/plugin.sh"
TS_FIX="$FIXTURES_DIR/tailscale"
SB_LOG="$SANDBOX/sketchybar.argv"

# Distinct palette colours so every icon.color names its source.
GREEN=0xff00aa00
YELLOW=0xffaaaa00
RED=0xffaa0000
GREY=0xff777777

# Plugin PATH: our fakes plus /bin (rm, sleep). No /usr/bin, so no stray jq.
FAKE_BIN="$SANDBOX/ts-bin"
JQ_BIN="$SANDBOX/ts-jq"
mkdir -p "$FAKE_BIN" "$JQ_BIN"

# An `--set ... icon.background.image=app.<id>` call is the plugin asking
# whether an app icon resolves: logged to $SB_LOG.probe, and like SketchyBar it
# exits 1 unless <id> is in $SB_APPS. Any other call is the plugin's update.
cat >"$FAKE_BIN/sketchybar" <<'EOF'
#!/bin/sh
for a; do
  case "$a" in
    icon.background.image=app.*)
      id=${a#icon.background.image=app.}
      printf '%s\n' "$id" >>"$SB_LOG.probe"
      case " ${SB_APPS:-} " in *" $id "*) exit 0 ;; esac
      exit 1
      ;;
  esac
done
printf '%s\n' "$@" >"$SB_LOG"
EOF

# Fake CLI: `status --json` prints $TS_JSON; anything else is a usage error.
cat >"$SANDBOX/tailscale" <<'EOF'
#!/bin/sh
[ "$1 $2" = "status --json" ] || exit 64
exec /bin/cat "$TS_JSON"
EOF

# A CLI that never answers. The odd duration makes it findable with pgrep.
HANG_SECS=29.4817
cat >"$SANDBOX/tailscale-hang" <<EOF
#!/bin/sh
exec /bin/sleep $HANG_SECS
EOF
chmod 755 "$FAKE_BIN/sketchybar" "$SANDBOX/tailscale" "$SANDBOX/tailscale-hang"

PARSERS="plutil"
jq_path=$(command -v jq 2>/dev/null || true)
[ -x /usr/bin/jq ] && jq_path=/usr/bin/jq
if [ -n "$jq_path" ]; then
  ln -s "$jq_path" "$JQ_BIN/jq"
  PARSERS="jq plutil"
elif [ -n "${CI:-}" ]; then
  it "jq is available for the jq parser path"
  _note_fail "jq not found; CI must cover both parsers"
  done_it
else
  printf '# note: jq not found, only the plutil parser is covered\n'
fi

# run_plugin <parser> <cli> [VAR=value...] — one plugin run with a clean env.
# The argv sketchybar received lands in $SB, one arg per line.
# The app ids it probed land in $PROBES, one per line. The icon=app lookup
# cache is cleared first unless KEEP_ICON_CACHE is set.
SB=""
PROBES=""
ICON_CACHE="$SANDBOX/stm-tailscale-icon.stm.tailscale"
run_plugin() {
  local parser="$1" cli="$2" path="$FAKE_BIN:/bin"
  shift 2
  [ "$parser" = jq ] && path="$JQ_BIN:$path"
  rm -f "$SB_LOG" "$SB_LOG.probe"
  [ -n "${KEEP_ICON_CACHE:-}" ] || rm -f "$ICON_CACHE"
  env -i HOME="$HOME" TMPDIR="$SANDBOX" PATH="$path" SB_LOG="$SB_LOG" \
    NAME=stm.tailscale SENDER=routine STM_TAILSCALE="$cli" \
    STM_GREEN=$GREEN STM_YELLOW=$YELLOW STM_RED=$RED STM_GREY=$GREY \
    "$@" /bin/sh "$PLUGIN" >/dev/null 2>&1
  SB=$(cat "$SB_LOG" 2>/dev/null || true)
  PROBES=$(cat "$SB_LOG.probe" 2>/dev/null || true)
}

# run_state <parser> <fixture> [VAR=value...]
run_state() {
  local parser="$1" fixture="$2"
  shift 2
  run_plugin "$parser" "$SANDBOX/tailscale" TS_JSON="$TS_FIX/$fixture.json" "$@"
}

# sb_has <arg...> — each arg was passed to sketchybar verbatim.
sb_has() {
  local a
  for a in "$@"; do
    printf '%s\n' "$SB" | grep -Fxq -- "$a" || _note_fail "sketchybar missing arg: $a" "argv:" "$SB"
  done
}

sb_lacks() {
  local a
  for a in "$@"; do
    printf '%s\n' "$SB" | grep -Fxq -- "$a" && _note_fail "sketchybar got unexpected arg: $a" "argv:" "$SB"
  done
  return 0
}

# argv_of <line...> — expected argv in the log's one-per-line shape.
argv_of() {
  printf '%s\n' "$@"
}

ROWS_RE='/stm\.tailscale\.row\..*/'

for P in $PARSERS; do

  it "[$P] Running: green icon, devices online/total, own IP, popup (V17, V16, V26)"
  run_state "$P" running
  # This device counts and gets its own row (HostName: no Self.DNSName here).
  # Then online peers first, then by name; offline peers grey.
  expected=$(argv_of \
    --set stm.tailscale label.drawing=on 'label=3/4  100.64.0.1' icon.color=$GREEN \
    --remove "$ROWS_RE" \
    --add item stm.tailscale.row.self popup.stm.tailscale \
    --set stm.tailscale.row.self icon=● 'label=mac  100.64.0.1  (this device)' icon.color=$GREEN \
    --add item stm.tailscale.row.1 popup.stm.tailscale \
    --set stm.tailscale.row.1 icon=● 'label=bravo  100.64.0.4' icon.color=$GREEN \
    --add item stm.tailscale.row.2 popup.stm.tailscale \
    --set stm.tailscale.row.2 icon=● 'label=laptop  100.64.0.2' icon.color=$GREEN \
    --add item stm.tailscale.row.3 popup.stm.tailscale \
    --set stm.tailscale.row.3 icon=● 'label=archive  100.64.0.3' icon.color=$GREY)
  assert_eq "$expected" "$SB" "Running argv"
  sb_lacks stm.tailscale.row.exit
  done_it

  it "[$P] Running + exit node: label and popup name the exit node"
  run_state "$P" exit-node
  sb_has 'label=exit bravo  3/4  100.64.0.1' icon.color=$GREEN \
    stm.tailscale.row.exit 'label=exit node: bravo'
  done_it

  it "[$P] peer name is the MagicDNS name, HostName only without DNSName (V24)"
  # iOS and Android report HostName "localhost"; the Tailscale app shows the
  # first label of DNSName.
  run_state "$P" mobile
  expected=$(argv_of \
    --set stm.tailscale label.drawing=on 'label=exit pixel7  3/5  100.64.0.1' icon.color=$GREEN \
    --remove "$ROWS_RE" \
    --add item stm.tailscale.row.exit popup.stm.tailscale \
    --set stm.tailscale.row.exit icon.drawing=off 'label=exit node: pixel7' \
    --add item stm.tailscale.row.self popup.stm.tailscale \
    --set stm.tailscale.row.self icon=● 'label=mac  100.64.0.1  (this device)' icon.color=$GREEN \
    --add item stm.tailscale.row.1 popup.stm.tailscale \
    --set stm.tailscale.row.1 icon=● 'label=iphone171  100.64.0.2' icon.color=$GREEN \
    --add item stm.tailscale.row.2 popup.stm.tailscale \
    --set stm.tailscale.row.2 icon=● 'label=pixel7  100.64.0.3' icon.color=$GREEN \
    --add item stm.tailscale.row.3 popup.stm.tailscale \
    --set stm.tailscale.row.3 icon=● 'label=nodns  100.64.0.5' icon.color=$GREY \
    --add item stm.tailscale.row.4 popup.stm.tailscale \
    --set stm.tailscale.row.4 icon=● 'label=oldbox  100.64.0.4' icon.color=$GREY)
  assert_eq "$expected" "$SB" "mobile argv"
  sb_lacks 'label=localhost  100.64.0.2' "label=Alex's MacBook Pro  100.64.0.1  (this device)"
  done_it

  it "[$P] Starting: yellow, label starting (V17)"
  run_state "$P" starting
  sb_has label=starting icon.color=$YELLOW 'label=tailscale: starting'
  sb_lacks stm.tailscale.row.1
  done_it

  it "[$P] NeedsLogin: yellow, label needs login, null Peer/IPs tolerated (V17)"
  run_state "$P" needs-login
  sb_has 'label=needs login' icon.color=$YELLOW 'label=tailscale: needs login'
  done_it

  it "[$P] Stopped: red, label stopped (V17)"
  run_state "$P" stopped
  sb_has label=stopped icon.color=$RED 'label=tailscale: stopped'
  done_it

  it "[$P] label fields off, click=app: bare icon, no popup rows (I.tsopt)"
  run_state "$P" exit-node STM_TS_EXIT_NODE=off STM_TS_PEERS=off STM_TS_IP=off STM_TS_CLICK=app
  assert_eq "$(argv_of --set stm.tailscale label.drawing=off icon.color=$GREEN)" "$SB" "all-off argv"
  run_state "$P" exit-node STM_TS_PEERS=off
  sb_has 'label=exit bravo  100.64.0.1'
  done_it

  it "[$P] icon=app: app icon from the standalone build, state colour on the label (V25, V17)"
  run_state "$P" stopped STM_TS_ICON=app SB_APPS="io.tailscale.ipn.macsys io.tailscale.ipn.macos"
  assert_eq "io.tailscale.ipn.macsys" "$PROBES" "probe order"
  sb_has label=stopped icon= icon.background.drawing=on label.color=$RED
  sb_lacks icon.color=$RED icon=TS
  done_it

  it "[$P] icon=app: App Store build when the standalone one is missing (V25)"
  run_state "$P" running STM_TS_ICON=app SB_APPS="io.tailscale.ipn.macos"
  assert_eq "$(argv_of io.tailscale.ipn.macsys io.tailscale.ipn.macos)" "$PROBES" "probe order"
  # The item's own --set, up to the popup rows (whose dots keep icon.color).
  expected=$(argv_of --set stm.tailscale label.drawing=on 'label=3/4  100.64.0.1' \
    icon= icon.background.drawing=on label.color=$GREEN --remove)
  assert_eq "$expected" "$(printf '%s\n' "$SB" | head -n 8)" "app icon argv"
  done_it

  it "[$P] icon=app, no Tailscale app: TS text icon, state colour on icon and label (V25, B3)"
  run_state "$P" starting STM_TS_ICON=app
  assert_eq "$(argv_of io.tailscale.ipn.macsys io.tailscale.ipn.macos)" "$PROBES" "probe order"
  # label.color too: a run that did resolve the app icon left it coloured.
  sb_has icon=TS icon.background.drawing=off label.color=$YELLOW icon.color=$YELLOW
  sb_lacks icon.background.drawing=on
  done_it

  it "[$P] icon=app, all label fields off: bare app icon (V25)"
  run_state "$P" running STM_TS_ICON=app SB_APPS=io.tailscale.ipn.macsys \
    STM_TS_EXIT_NODE=off STM_TS_PEERS=off STM_TS_IP=off STM_TS_CLICK=app
  assert_eq "$(argv_of --set stm.tailscale label.drawing=off icon= icon.background.drawing=on \
    label.color=$GREEN)" "$SB" "bare app icon argv"
  done_it

  it "[$P] no Self, no own IP: count still includes this device, no stray gaps (V26)"
  run_state "$P" self-sparse
  expected=$(argv_of \
    --set stm.tailscale label.drawing=on label=2/2 icon.color=$GREEN \
    --remove "$ROWS_RE" \
    --add item stm.tailscale.row.self popup.stm.tailscale \
    --set stm.tailscale.row.self icon=● 'label=(this device)' icon.color=$GREEN \
    --add item stm.tailscale.row.1 popup.stm.tailscale \
    --set stm.tailscale.row.1 icon=● 'label=laptop  100.64.0.2' icon.color=$GREEN)
  assert_eq "$expected" "$SB" "self-sparse argv"
  done_it

  it "[$P] empty green palette colour: rows drawn without icon.color (V14, V26)"
  run_state "$P" self-sparse STM_GREEN=
  sb_has stm.tailscale.row.self 'label=(this device)' 'label=laptop  100.64.0.2'
  printf '%s\n' "$SB" | grep -q '^icon\.color=$' && _note_fail "empty icon.color passed" "argv:" "$SB"
  sb_lacks icon.color=$GREEN
  done_it

  it "[$P] control characters in names cannot forge peer rows (V24, B4)"
  run_state "$P" spoof
  expected=$(argv_of \
    --set stm.tailscale label.drawing=on 'label=1/2  100.64.0.1' icon.color=$GREEN \
    --remove "$ROWS_RE" \
    --add item stm.tailscale.row.self popup.stm.tailscale \
    --set stm.tailscale.row.self icon=● 'label=mac  100.64.0.1  (this device)' icon.color=$GREEN \
    --add item stm.tailscale.row.1 popup.stm.tailscale \
    --set stm.tailscale.row.1 icon=● 'label=xpeer1evil6.6.6.6  100.64.0.2' icon.color=$GREY)
  assert_eq "$expected" "$SB" "spoof argv"
  done_it

  it "[$P] icon=text|nerd: no app probe, icon string left to item.lua (V25)"
  for mode in text nerd; do
    run_state "$P" stopped STM_TS_ICON=$mode SB_APPS="io.tailscale.ipn.macsys"
    assert_eq "" "$PROBES" "no probe for $mode"
    sb_has icon.color=$RED
    sb_lacks icon=TS icon= label.color=$RED icon.background.drawing=on
  done
  done_it

done

it "icon=app lookup cached between routine runs, redone on forced / system_woke (V25)"
run_state plutil running STM_TS_ICON=app SB_APPS=io.tailscale.ipn.macsys
assert_eq io.tailscale.ipn.macsys "$(cat "$ICON_CACHE" 2>/dev/null)" "cache after lookup"
# Routine run: the cached id is used as is, even though the app is now gone.
KEEP_ICON_CACHE=1 run_state plutil running STM_TS_ICON=app
assert_eq "" "$PROBES" "routine run with cache probes nothing"
sb_has icon.background.drawing=on label.color=$GREEN
# forced (a reload, `sketchybar --update`) looks again and caches the miss.
KEEP_ICON_CACHE=1 run_state plutil running STM_TS_ICON=app SENDER=forced
assert_eq "$(argv_of io.tailscale.ipn.macsys io.tailscale.ipn.macos)" "$PROBES" "forced probes"
assert_eq none "$(cat "$ICON_CACHE" 2>/dev/null)" "cache after miss"
KEEP_ICON_CACHE=1 run_state plutil running STM_TS_ICON=app SB_APPS=io.tailscale.ipn.macsys
assert_eq "" "$PROBES" "cached miss probes nothing"
sb_has icon=TS icon.background.drawing=off
KEEP_ICON_CACHE=1 run_state plutil running STM_TS_ICON=app SB_APPS=io.tailscale.ipn.macos SENDER=system_woke
assert_eq "$(argv_of io.tailscale.ipn.macsys io.tailscale.ipn.macos)" "$PROBES" "wake probes"
assert_eq io.tailscale.ipn.macos "$(cat "$ICON_CACHE" 2>/dev/null)" "cache after wake"
# Anything else in the cache is ignored and looked up again.
printf 'app.evil\n' >"$ICON_CACHE"
KEEP_ICON_CACHE=1 run_state plutil running STM_TS_ICON=app SB_APPS=io.tailscale.ipn.macsys
assert_eq io.tailscale.ipn.macsys "$PROBES" "bad cache probes"
sb_lacks icon.background.image=app.app.evil
done_it

it "icon=text: no lookup, no cache file (V25)"
run_state plutil running STM_TS_ICON=text SENDER=forced
assert_file_absent "$ICON_CACHE"
done_it

it "no tailscale CLI: grey, label and popup say not installed, no fallback (V16, I.ts)"
run_plugin plutil "$SANDBOX/no-such-tailscale"
sb_has 'label=not installed' icon.color=$GREY 'label=tailscale: not installed'
# $STM_TAILSCALE set but not executable: still no fallback to other paths.
cp "$SANDBOX/tailscale" "$SANDBOX/tailscale-noexec"
chmod 644 "$SANDBOX/tailscale-noexec"
run_plugin plutil "$SANDBOX/tailscale-noexec" TS_JSON="$TS_FIX/running.json"
sb_has 'label=not installed' icon.color=$GREY
done_it

it "hung tailscale status: killed after ~3s, grey, label timeout (V15)"
start=$SECONDS
run_plugin plutil "$SANDBOX/tailscale-hang"
elapsed=$((SECONDS - start))
[ "$elapsed" -le 6 ] || _note_fail "plugin took ${elapsed}s with a hung CLI (bound ~3s)"
sb_has label=timeout icon.color=$GREY 'label=tailscale: timeout'
if pgrep -f "sleep $HANG_SECS" >/dev/null 2>&1; then
  _note_fail "hung tailscale process was left running"
  pkill -f "sleep $HANG_SECS" 2>/dev/null
fi
done_it

it "garbage status output: grey, label unknown (V17)"
printf 'not json\n' >"$SANDBOX/garbage.json"
for P in $PARSERS; do
  run_plugin "$P" "$SANDBOX/tailscale" TS_JSON="$SANDBOX/garbage.json"
  sb_has label=unknown icon.color=$GREY
done
done_it

finish
