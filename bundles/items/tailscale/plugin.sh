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
#   STM_TS_SHAPE                        plain | pill | split
# Colours are never hard-coded here: they follow the palette.
#
# STM_TAILSCALE overrides the CLI lookup (tests, unusual installs). Stock
# tools are called by absolute path, so only jq, tailscale and sketchybar come
# from PATH; jq is optional (plutil fallback).

NAME=${NAME:-stm.tailscale}
TIMEOUT_SECS=3 # `tailscale status` gets this much wall clock, then it is killed
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
# `timeout`, so the CLI runs in the background and a watchdog kills it after
# TIMEOUT_SECS of wall clock. One long sleep, not a loop of short ones: each
# /bin/sleep costs a fork, and on a loaded machine 30 x 0.1s ran ~7s (B5).
# The watchdog kills its own sleep when stopped, so nothing is left running.
# Returns 2 on timeout, else 0 (the JSON decides the state).
run_status() {
  "$1" status --json >"$WORK/status.json" 2>/dev/null &
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
  kill "$dog" 2>/dev/null
  wait "$dog" 2>/dev/null
  [ -f "$WORK/timed-out" ] && return 2
  return 0
}

# Both parsers emit the same records:
#   state<TAB>Running    self_ip<TAB>100.x    self_name<TAB>mac
#   exit_ip<TAB>100.y (or empty)    peer<TAB>1|0<TAB>name<TAB>100.z
# A node's name is the first label of its DNSName (the MagicDNS name the
# Tailscale app shows); iOS and Android report HostName "localhost". HostName
# is used only when DNSName is empty. Peers set their own HostName, so control
# characters are dropped: a tab or newline would forge a record.
parse_jq() {
  jq -r '
    def clean: gsub("[[:cntrl:]]"; "");
    def name: ((.DNSName // "") | clean | sub("\\..*$"; "")) as $d |
      if $d != "" then $d else (.HostName // "" | clean) end;
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

# node_name <key path> — DNSName's first label, else HostName; control
# characters dropped as in parse_jq.
node_name() {
  n=$(px "$1.DNSName" | /usr/bin/tr -d '[:cntrl:]')
  n=${n%%.*}
  [ -n "$n" ] || n=$(px "$1.HostName" | /usr/bin/tr -d '[:cntrl:]')
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
    if [ "${STM_TS_IP:-on}" = on ] && [ -n "$(field self_ip)" ]; then
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
# neither, fall back to the TS text icon. The lookup costs SketchyBar calls and
# an image reload, so its answer (the id, or "none") is cached, and looked up
# again only on forced (reload, --update) and system_woke, or without a valid
# cache. The image persists on the item between runs.
icon_mode=${STM_TS_ICON:-text}
app_icon=""
# split draws the icon on its own sub-item (item.lua); everything else draws
# it on the item itself. plain and pill send the same updates.
shape=${STM_TS_SHAPE:-plain}
icon_item=$NAME
[ "$shape" = split ] && icon_item="$NAME.icon"
if [ "$icon_mode" = app ]; then
  cache="${TMPDIR:-/tmp}/stm-tailscale-icon.$NAME"
  cached=$(/bin/cat "$cache" 2>/dev/null)
  case "${SENDER:-}" in forced | system_woke) cached="" ;; esac
  case "$cached" in
    io.tailscale.ipn.macsys | io.tailscale.ipn.macos) app_icon=$cached ;;
    none) ;;
    *)
      for id in io.tailscale.ipn.macsys io.tailscale.ipn.macos; do
        if sketchybar --set "$icon_item" icon.background.image="app.$id" >/dev/null 2>&1; then
          app_icon=$id
          break
        fi
      done
      if tmp=$(/usr/bin/mktemp "$cache.XXXXXX" 2>/dev/null); then
        printf '%s\n' "${app_icon:-none}" >"$tmp"
        /bin/mv -f "$tmp" "$cache" 2>/dev/null || /bin/rm -f "$tmp"
      fi
      ;;
  esac
fi

# The icon's updates first, then the label's --set goes in front of them.
set --
if [ -n "$app_icon" ]; then
  set -- icon= icon.background.drawing=on
elif [ "$icon_mode" = app ]; then
  set -- icon=TS icon.background.drawing=off
fi
if [ "$shape" = split ]; then
  # The state colour is the sub-item's background; its icon stays black and
  # an app image draws over the colour. Nothing to set -> no --set at all.
  [ -n "$color" ] && set -- "$@" background.color="$color"
  [ $# -gt 0 ] && set -- --set "$icon_item" "$@"
  # No label text: hide the label part's bg1 too, so only the icon part shows.
  if [ -n "$label" ]; then
    set -- background.drawing=on "$@"
  else
    set -- background.drawing=off "$@"
  fi
elif [ -n "$color" ]; then
  # The app image is never tinted, so in app mode the state colour always
  # goes on the label, resolved or not: a fallback run must not leave the
  # colour of an earlier resolved run there.
  [ "$icon_mode" = app ] && set -- "$@" label.color="$color"
  [ -z "$app_icon" ] && set -- "$@" icon.color="$color"
fi
if [ -n "$label" ]; then
  set -- --set "$NAME" label.drawing=on label="$label" "$@"
else
  set -- --set "$NAME" label.drawing=off "$@"
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
    self_label=$(field self_name)
    self_ip=$(field self_ip)
    self_label="${self_label:+$self_label  }${self_ip:+$self_ip  }(this device)"
    dot=$STM_GREEN
    set -- "$@" --add item "$NAME.row.self" "popup.$NAME" \
      --set "$NAME.row.self" icon="●" label="$self_label"
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
