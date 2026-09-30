#!/bin/sh
# stm.tailscale plugin. Installed by `stm install item:tailscale` (#16).
#
# item.lua runs this with:
#   NAME, SENDER                        the SketchyBar item and event
#   STM_GREEN STM_YELLOW STM_RED STM_GREY
#                                       palette colours as 0xAARRGGBB (may be empty)
#   STM_TS_EXIT_NODE STM_TS_PEERS STM_TS_IP   on | off  (label fields)
#   STM_TS_CLICK                        popup | app
#   STM_TS_ICON                         text | nerd | app
# Colours are never hard-coded here: they follow the palette.
#
# STM_TAILSCALE overrides the CLI lookup (tests, unusual installs). Stock
# tools are called by absolute path, so only jq, tailscale and sketchybar come
# from PATH; jq is optional (plutil fallback).

NAME=${NAME:-stm.tailscale}
TIMEOUT_TICKS=30 # x 0.1s: `tailscale status` gets ~3s, then it is killed
MAX_PEERS=20
tab=$(printf '\t')

WORK=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/stm-tailscale.XXXXXX") || exit 0
trap 'rm -rf "$WORK"' EXIT

# find_cli — print the tailscale CLI to use, or nothing.
find_cli() {
  if [ -n "${STM_TAILSCALE:-}" ]; then
    [ -x "$STM_TAILSCALE" ] && printf '%s\n' "$STM_TAILSCALE"
    return 0
  fi
  for c in /usr/local/bin/tailscale \
    /Applications/Tailscale.app/Contents/MacOS/Tailscale \
    /opt/homebrew/bin/tailscale; do
    if [ -x "$c" ]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  command -v tailscale 2>/dev/null
  return 0
}

# run_status <cli> — status JSON into $WORK/status.json. macOS has no
# `timeout`, so the CLI runs in the background and is killed after ~3s.
# Returns 2 on timeout, else 0 (the JSON decides the state).
run_status() {
  "$1" status --json >"$WORK/status.json" 2>/dev/null &
  pid=$!
  ticks=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge "$TIMEOUT_TICKS" ]; then
      kill "$pid" 2>/dev/null
      /bin/sleep 0.1
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 2
    fi
    /bin/sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid" 2>/dev/null
  return 0
}

# Both parsers emit the same records:
#   state<TAB>Running    self_ip<TAB>100.x    self_name<TAB>mac
#   exit_ip<TAB>100.y (or empty)    peer<TAB>1|0<TAB>name<TAB>100.z
# A node's name is the first label of its DNSName (the MagicDNS name the
# Tailscale app shows); iOS and Android report HostName "localhost". HostName
# is used only when DNSName is empty.
parse_jq() {
  jq -r '
    def name: ((.DNSName // "") | sub("\\..*$"; "")) as $d |
      if $d != "" then $d else (.HostName // "") end;
    "state\t" + (.BackendState // ""),
    "self_ip\t" + ((.Self.TailscaleIPs // [])[0] // ""),
    "self_name\t" + ((.Self // {}) | name),
    "exit_ip\t" + (((.ExitNodeStatus // {}).TailscaleIPs // [])[0] // "" | sub("/.*$"; "")),
    ((.Peer // {}) | to_entries[] | .value |
      "peer\t" + (if .Online then "1" else "0" end) + "\t" + name +
      "\t" + ((.TailscaleIPs // [])[0] // ""))
  ' "$WORK/status.json" 2>/dev/null
}

# plutil reads JSON with nulls fine as long as each extracted value is not one.
px() {
  /usr/bin/plutil -extract "$1" raw -o - "$WORK/status.json" 2>/dev/null
}

# node_name <key path> — DNSName's first label, else HostName.
node_name() {
  n=$(px "$1.DNSName")
  n=${n%%.*}
  [ -n "$n" ] || n=$(px "$1.HostName")
  printf '%s' "$n"
}

parse_plutil() {
  printf 'state\t%s\n' "$(px BackendState)"
  printf 'self_ip\t%s\n' "$(px Self.TailscaleIPs.0)"
  printf 'self_name\t%s\n' "$(node_name Self)"
  e=$(px ExitNodeStatus.TailscaleIPs.0)
  printf 'exit_ip\t%s\n' "${e%%/*}"
  px Peer >"$WORK/keys" || : >"$WORK/keys"
  while IFS= read -r k; do
    case "$k" in "" | *.*) continue ;; esac
    on=0
    [ "$(px "Peer.$k.Online")" = true ] && on=1
    printf 'peer\t%s\t%s\t%s\n' "$on" "$(node_name "Peer.$k")" "$(px "Peer.$k.TailscaleIPs.0")"
  done <"$WORK/keys"
}

field() {
  /usr/bin/awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$WORK/rec"
}

state=""
cli=$(find_cli)
if [ -z "$cli" ]; then
  state="not installed"
elif ! run_status "$cli" 2>/dev/null; then
  state="timeout"
else
  if command -v jq >/dev/null 2>&1; then
    parse_jq >"$WORK/rec"
  else
    parse_plutil >"$WORK/rec"
  fi
  state=$(field state)
fi
[ -f "$WORK/rec" ] || : >"$WORK/rec"

# Peers: online first, then by name.
/usr/bin/awk -F'\t' '$1 == "peer" { print $2 "\t" $3 "\t" $4 }' "$WORK/rec" |
  /usr/bin/sort -t "$tab" -k1,1r -k2,2 >"$WORK/peers"

color=$STM_GREY
case "$state" in
  Running)
    color=$STM_GREEN
    label=""
    exit_ip=$(field exit_ip)
    if [ "${STM_TS_EXIT_NODE:-on}" = on ] && [ -n "$exit_ip" ]; then
      exit_name=$(/usr/bin/awk -F'\t' -v ip="$exit_ip" '$3 == ip { print $2; exit }' "$WORK/peers")
      label="exit ${exit_name:-$exit_ip}"
    fi
    if [ "${STM_TS_PEERS:-on}" = on ]; then
      # Devices on the tailnet: the peers plus this one, which is online.
      online=$(/usr/bin/awk -F'\t' '$1 == "1"' "$WORK/peers" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
      total=$(/usr/bin/wc -l <"$WORK/peers" | /usr/bin/tr -d ' ')
      label="${label:+$label  }$((online + 1))/$((total + 1))"
    fi
    if [ "${STM_TS_IP:-on}" = on ]; then
      label="${label:+$label  }$(field self_ip)"
    fi
    ;;
  Starting) color=$STM_YELLOW label="starting" ;;
  NeedsLogin | NeedsMachineAuth) color=$STM_YELLOW label="needs login" ;;
  Stopped) color=$STM_RED label="stopped" ;;
  "not installed" | timeout) label=$state ;;
  *) label="unknown" ;;
esac

# icon=app: the Tailscale app's icon, standalone build first, then the App
# Store one. SketchyBar exits non-zero when it cannot resolve a bundle id; with
# neither, fall back to the TS text icon. The image is never tinted, so the
# state colour goes on the label instead.
app_icon=""
if [ "${STM_TS_ICON:-text}" = app ]; then
  for id in io.tailscale.ipn.macsys io.tailscale.ipn.macos; do
    if sketchybar --set "$NAME" icon.background.image="app.$id" >/dev/null 2>&1; then
      app_icon=$id
      break
    fi
  done
fi

set -- --set "$NAME"
if [ -n "$label" ]; then
  set -- "$@" label.drawing=on label="$label"
else
  set -- "$@" label.drawing=off
fi
if [ -n "$app_icon" ]; then
  set -- "$@" icon= icon.background.drawing=on
  [ -n "$color" ] && set -- "$@" label.color="$color"
else
  [ "${STM_TS_ICON:-text}" = app ] && set -- "$@" icon=TS icon.background.drawing=off
  [ -n "$color" ] && set -- "$@" icon.color="$color"
fi

# Popup rows: rebuilt on every run so they follow the palette and the tailnet.
if [ "${STM_TS_CLICK:-popup}" = popup ]; then
  re=$(printf '%s' "$NAME" | /usr/bin/sed 's/\./\\./g')
  set -- "$@" --remove "/$re\\.row\\..*/"
  if [ "$state" != Running ]; then
    set -- "$@" --add item "$NAME.row.0" "popup.$NAME" \
      --set "$NAME.row.0" icon.drawing=off label="tailscale: $label"
  else
    if [ -n "$(field exit_ip)" ]; then
      set -- "$@" --add item "$NAME.row.exit" "popup.$NAME" \
        --set "$NAME.row.exit" icon.drawing=off label="exit node: ${exit_name:-$(field exit_ip)}"
    fi
    self_name=$(field self_name)
    dot=$STM_GREEN
    set -- "$@" --add item "$NAME.row.self" "popup.$NAME" \
      --set "$NAME.row.self" icon="●" label="${self_name:+$self_name  }$(field self_ip)  (this device)"
    [ -n "$dot" ] && set -- "$@" icon.color="$dot"
    n=0
    while IFS="$tab" read -r on host ip; do
      [ "$n" -ge "$MAX_PEERS" ] && break
      n=$((n + 1))
      dot=$STM_GREY
      [ "$on" = 1 ] && dot=$STM_GREEN
      set -- "$@" --add item "$NAME.row.$n" "popup.$NAME" \
        --set "$NAME.row.$n" icon="●" label="$host  $ip"
      [ -n "$dot" ] && set -- "$@" icon.color="$dot"
    done <"$WORK/peers"
  fi
fi

sketchybar "$@"
