#!/usr/bin/env bash
#
# bundles/items/net (#19). Runs plugin.sh as SketchyBar would, against a fake
# `scutil` (canned State:/Network/Global/IPv4), a fake `ipconfig` (canned
# `getsummary` and `getifaddr`) and a fake `sketchybar` that logs its argv one
# per line; then runs item.lua under Lua with a fake `sbar`. Never touches the
# real network tools or the real bar.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

BUNDLE="$REPO_ROOT/bundles/items/net"
PLUGIN="$BUNDLE/plugin.sh"
SB_LOG="$SANDBOX/sketchybar.argv"

# Distinct palette colours so every colour names its source.
MAGENTA=0xffaa00aa
RED=0xffaa0000

# Glyphs (bash 3.2 printf has no \U): nf-fa-wifi, nf-md-ethernet, nf-md-vpn,
# nf-md-lan, nf-md-wifi_off.
WIFI=$(printf '\357\207\253')
ETH=$(printf '\363\260\210\200')
VPN=$(printf '\363\260\226\202')
LAN=$(printf '\363\260\214\230')
OFF=$(printf '\363\260\226\252')

FAKE_BIN="$SANDBOX/net-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/sketchybar" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >>"$SB_LOG"
EOF
# Fake scutil: prints $SCUTIL_OUT for the one query the plugin may make.
cat >"$SANDBOX/scutil" <<'EOF'
#!/bin/sh
printf 'scutil\n' >>"$SB_LOG.calls"
[ "$(cat)" = "show State:/Network/Global/IPv4
show State:/Network/Global/IPv6" ] || exit 64
printf '%s\n' "$SCUTIL_OUT"
EOF
# Fake ipconfig: `getsummary <if>` prints $SUMMARY_OUT; anything else fails.
# Fake ifconfig: `ifconfig <if>` prints $IFCONFIG_OUT. Calls are logged.
cat >"$SANDBOX/ipconfig" <<'EOF'
#!/bin/sh
printf 'ipconfig %s\n' "$*" >>"$SB_LOG.calls"
[ "$1" = getsummary ] || exit 64
printf '%s\n' "$SUMMARY_OUT"
EOF
cat >"$SANDBOX/ifconfig" <<'EOF'
#!/bin/sh
printf 'ifconfig %s\n' "$*" >>"$SB_LOG.calls"
printf '%s\n' "$IFCONFIG_OUT"
EOF
chmod 755 "$FAKE_BIN/sketchybar" "$SANDBOX/scutil" "$SANDBOX/ipconfig" "$SANDBOX/ifconfig"

NO_KEY="  No such key"
# global <if> — a State:/Network/Global/IPv4 (or IPv6) entry with that primary.
global() {
  printf '<dictionary> {\n  PrimaryInterface : %s\n  PrimaryService : 9EC1BB50-1699-4A15-9ED0-D3E6919E9EC4\n  Router : 10.0.0.1\n}' "$1"
}
# primary <if> — scutil's answer to both queries on a dual-stack link.
primary() {
  printf '%s\n%s' "$(global "$1")" "$(global "$1")"
}
OFFLINE=$(printf '%s\n%s' "$NO_KEY" "$NO_KEY")
# summary <type> — `ipconfig getsummary <if>` for an interface of that type.
summary() {
  printf '<dictionary> {\n  Hashed-BSSID : 00:00:00:00:00:00\n  InterfaceType : %s\n  LinkStatusActive : TRUE\n  SSID : <redacted>\n}' "$1"
}
# Real getsummary for an interface ipconfig knows no type for (en1, ap1, …).
NO_TYPE=$(printf '<dictionary> {\n  LinkStatusActive : FALSE\n}')
# inet <addr> — `ifconfig <if>` with that IPv4 address (after an IPv6 one).
inet() {
  printf 'en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tinet6 fe80::1%%en0 prefixlen 64 secured scopeid 0xb\n\tinet %s netmask 0xffffff00 broadcast 10.0.0.255\n\tinet 10.9.9.9 netmask 0xffffff00\n\tstatus: active' "$1"
}

# run_plugin <scutil out> <getsummary out> <ifconfig out> [VAR=value...] —
# argv sketchybar got lands in $SB, the tool calls made in $CALLS.
SB=""
CALLS=""
run_plugin() {
  local s="$1" g="$2" a="$3"
  shift 3
  rm -f "$SB_LOG" "$SB_LOG.calls"
  env -i HOME="$HOME" TMPDIR="$SANDBOX" PATH="$FAKE_BIN:/bin" SB_LOG="$SB_LOG" \
    NAME=stm.net SENDER=routine STM_SCUTIL="$SANDBOX/scutil" STM_IPCONFIG="$SANDBOX/ipconfig" \
    STM_IFCONFIG="$SANDBOX/ifconfig" SCUTIL_OUT="$s" SUMMARY_OUT="$g" IFCONFIG_OUT="$a" \
    STM_MAGENTA=$MAGENTA STM_RED=$RED "$@" /bin/sh "$PLUGIN" >/dev/null 2>&1
  SB=$(cat "$SB_LOG" 2>/dev/null || true)
  CALLS=$(cat "$SB_LOG.calls" 2>/dev/null || true)
}

argv_of() {
  printf '%s\n' "$@"
}

it "type label and glyph by interface; magenta online (I.net, V40)"
run_plugin "$(primary en0)" "$(summary WiFi)" "" STM_NET_SHAPE=plain
assert_eq "$(argv_of --set stm.net "icon=$WIFI" label=Wi-Fi icon.color=$MAGENTA)" "$SB" "Wi-Fi"
assert_eq "$(argv_of scutil 'ipconfig getsummary en0')" "$CALLS" "Wi-Fi calls"
run_plugin "$(primary en7)" "$(summary Ethernet)" "" STM_NET_SHAPE=plain
assert_eq "$(argv_of --set stm.net "icon=$ETH" label=Ethernet icon.color=$MAGENTA)" "$SB" "Ethernet"
run_plugin "$(primary bridge0)" "$(summary Bridge)" "" STM_NET_SHAPE=plain
assert_eq "$(argv_of --set stm.net "icon=$LAN" label=bridge0 icon.color=$MAGENTA)" "$SB" "other type"
run_plugin "$(primary en1)" "$NO_TYPE" "" STM_NET_SHAPE=plain
assert_eq "$(argv_of --set stm.net "icon=$LAN" label=en1 icon.color=$MAGENTA)" "$SB" "no type"
done_it

it "VPN tunnels need no getsummary (I.net)"
for dev in utun4 ipsec0 ppp0; do
  run_plugin "$(primary "$dev")" "$(summary WiFi)" "" STM_NET_SHAPE=plain
  assert_eq "$(argv_of --set stm.net "icon=$VPN" label=VPN icon.color=$MAGENTA)" "$SB" "$dev"
  assert_eq scutil "$CALLS" "$dev calls"
done
done_it

it "IPv6 primary when there is no IPv4 one; IPv4 wins when both (I.net)"
run_plugin "$(printf '%s\n%s' "$NO_KEY" "$(global en0)")" "$(summary WiFi)" "" STM_NET_SHAPE=plain
assert_eq "$(argv_of --set stm.net "icon=$WIFI" label=Wi-Fi icon.color=$MAGENTA)" "$SB" "IPv6 only"
run_plugin "$(printf '%s\n%s' "$(global en0)" "$(global utun3)")" "$(summary WiFi)" "" STM_NET_SHAPE=plain
assert_eq "$(argv_of --set stm.net "icon=$WIFI" label=Wi-Fi icon.color=$MAGENTA)" "$SB" "IPv4 first"
done_it

it "offline: wifi-off glyph, red (I.net, V40)"
run_plugin "$OFFLINE" "$(summary WiFi)" "" STM_NET_SHAPE=plain
assert_eq "$(argv_of --set stm.net "icon=$OFF" label=offline icon.color=$RED)" "$SB" "no primary"
assert_eq scutil "$CALLS" "offline calls"
run_plugin "" "" "" STM_NET_SHAPE=plain
assert_eq "$(argv_of --set stm.net "icon=$OFF" label=offline icon.color=$RED)" "$SB" "scutil printed nothing"
done_it

it "a malformed interface name is offline and never reaches a tool, in any locale (V40, B8)"
# EN0, then non-ASCII letters (e-acute, A-ring) that UTF-8 globs call a-z.
for dev in 'en0;touch x' 'EN0' '../en0' '-h' '0en' "$(printf '\303\2510')" "$(printf 'en\303\205')"; do
  for loc in C en_US.UTF-8; do
    run_plugin "$(primary "$dev")" "$(summary WiFi)" "$(inet 10.0.0.2)" STM_NET_SHAPE=plain STM_NET_LABEL=ip \
      LANG="$loc" LC_ALL="$loc"
    assert_eq "$(argv_of --set stm.net "icon=$OFF" label=offline icon.color=$RED)" "$SB" "$dev ($loc)"
    assert_eq scutil "$CALLS" "$dev calls ($loc)"
  done
done
done_it

it "label ip: the interface's first IPv4 address, else the type (I.net, V40)"
run_plugin "$(primary en0)" "$(summary WiFi)" "$(inet 10.251.149.138)" STM_NET_SHAPE=plain STM_NET_LABEL=ip
assert_eq "$(argv_of --set stm.net "icon=$WIFI" label=10.251.149.138 icon.color=$MAGENTA)" "$SB" "ip"
assert_eq "$(argv_of scutil 'ipconfig getsummary en0' 'ifconfig en0')" "$CALLS" "ip calls"
run_plugin "$(primary utun4)" "" "$(inet 100.64.0.1)" STM_NET_SHAPE=plain STM_NET_LABEL=ip
assert_eq "$(argv_of --set stm.net "icon=$VPN" label=100.64.0.1 icon.color=$MAGENTA)" "$SB" "VPN ip"
assert_eq "$(argv_of scutil 'ifconfig utun4')" "$CALLS" "VPN ip calls"
run_plugin "$(primary en0)" "$(summary WiFi)" "en0: flags=0<> mtu 1500" STM_NET_SHAPE=plain STM_NET_LABEL=ip
assert_eq "$(argv_of --set stm.net "icon=$WIFI" label=Wi-Fi icon.color=$MAGENTA)" "$SB" "no address"
run_plugin "$(primary en0)" "$(summary WiFi)" "$(inet '1.2.3.4;x')" STM_NET_SHAPE=plain STM_NET_LABEL=ip
assert_eq "$(argv_of --set stm.net "icon=$WIFI" label=Wi-Fi icon.color=$MAGENTA)" "$SB" "not an address"
run_plugin "$OFFLINE" "" "$(inet 10.0.0.2)" STM_NET_SHAPE=plain STM_NET_LABEL=ip
assert_eq "$(argv_of --set stm.net "icon=$OFF" label=offline icon.color=$RED)" "$SB" "offline"
assert_eq scutil "$CALLS" "offline ip calls"
done_it

it "pill sends what plain sends (V32)"
run_plugin "$(primary en0)" "$(summary WiFi)" "" STM_NET_SHAPE=plain
plain=$SB
run_plugin "$(primary en0)" "$(summary WiFi)" "" STM_NET_SHAPE=pill
assert_eq "$plain" "$SB" "pill argv"
done_it

it "split: glyph and state colour on the icon sub-item (V32, V40, V10)"
run_plugin "$(primary en0)" "$(summary WiFi)" "" STM_NET_SHAPE=split
assert_eq "$(argv_of --set stm.net label=Wi-Fi --set stm.net.icon "icon=$WIFI" background.color=$MAGENTA)" \
  "$SB" "split online"
run_plugin "$OFFLINE" "" "" STM_NET_SHAPE=split
assert_eq "$(argv_of --set stm.net label=offline --set stm.net.icon "icon=$OFF" background.color=$RED)" \
  "$SB" "split offline"
# split is the manifest default.
assert_eq 'default = "split"' "$(awk '/^\[options\.shape\]/ { s = 1; next } /^\[/ { s = 0 } s && /^default/' \
  "$BUNDLE/item.toml")" "manifest shape default"
done_it

it "a palette without the state colour sends no empty colour (V14)"
run_plugin "$OFFLINE" "" "" STM_NET_SHAPE=plain STM_RED=
assert_eq "$(argv_of --set stm.net "icon=$OFF" label=offline)" "$SB" "plain"
run_plugin "$(primary en0)" "$(summary WiFi)" "" STM_NET_SHAPE=split STM_MAGENTA=
assert_eq "$(argv_of --set stm.net label=Wi-Fi --set stm.net.icon "icon=$WIFI")" "$SB" "split"
done_it

it "lint and install item:net: the label option reaches the loader (V4, V9, I.fs, I.cfg)"
STM_ROOT="$REPO_ROOT" run_stm --porcelain lint item:net
assert_status 0
D="$SANDBOX/cfg"
make_lua_config "$D"
printf '[item.net]\nlabel = "ip"\n' >"$D/stm.config.toml"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install item:net
assert_status 0
assert_files_equal "$PLUGIN" "$D/plugins/stm/net.sh"
assert_eq "-rwxr-xr-x" "$(stat -f %Sp "$D/plugins/stm/net.sh")" "plugin mode"
loader=$(cat "$D/items_generated.lua")
for opt in '["label"] = "ip"' '["shape"] = "split"' 'update_freq = 10,' 'events = { "wifi_change", "system_woke" },'; do
  assert_contains "$loader" "$opt"
done
done_it

LUA_BIN=$(command -v lua 2>/dev/null || true)
if [ -n "$LUA_BIN" ]; then
  mkdir -p "$SANDBOX/lua"
  cat >"$SANDBOX/lua/probe.lua" <<'EOF'
-- Runs item.lua with one shape, position and label option; prints each item
-- it adds, in order, with its props flattened (keys sorted), the events it
-- subscribes to, then the plugin command.
local shape, position, label, item_lua = ...
local function dump(v)
  if type(v) ~= "table" then
    return tostring(v)
  end
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = k .. "=" .. dump(v[k])
  end
  return "{" .. table.concat(parts, " ") .. "}"
end
local sbar = {}
function sbar.add(kind, name, props)
  print(kind .. " " .. name .. " " .. dump(props))
  return {
    subscribe = function(_, events) print("subscribe " .. table.concat(events, " ")) end,
    set = function() end,
  }
end
function sbar.exec(cmd) print("exec " .. cmd) end
local opts = { name = "stm.net", position = position, update_freq = 10,
  plugin_dir = "/p", events = { "wifi_change", "system_woke" }, options = { shape = shape, label = label } }
dofile(item_lua)(sbar, opts, { magenta = 1, red = 3, bg1 = 21, black = 22 })
EOF
  items_of() {
    "$LUA_BIN" "$SANDBOX/lua/probe.lua" "$1" "$2" type "$BUNDLE/item.lua" 2>&1 | grep '^item '
  }
  # icon_props <colour> — the initial icon table, flattened.
  icon_props() {
    printf 'icon={color=%s string=%s}' "$1" "$WIFI"
  }

  it "item.lua plain and pill: one item, pill on bg1 (V32, V14)"
  assert_eq "item stm.net {$(icon_props 1) label={string=--} position=right update_freq=10}" \
    "$(items_of plain right)" "plain"
  assert_eq "item stm.net {background={color=21 drawing=true} $(icon_props 1) label={string=--} position=left update_freq=10}" \
    "$(items_of pill left)" "pill"
  done_it

  it "item.lua split: icon sub-item left of the label at every position (V32, V33, V10)"
  main() {
    printf 'item stm.net {background={color=21 drawing=true padding_left=0} icon={drawing=false} label={string=--} position=%s update_freq=10}' "$1"
  }
  sub() {
    printf 'item stm.net.icon {background={color=1 drawing=true} %s label={drawing=false} position=%s}' \
      "$(icon_props 22)" "$1"
  }
  assert_eq "$(main right)
$(sub right)" "$(items_of split right)" "split right"
  for pos in left center; do
    assert_eq "$(sub "$pos")
$(main "$pos")" "$(items_of split "$pos")" "split $pos"
  done
  done_it

  it "item.lua hands plugin.sh its palette colours and options, subscribes the manifest events (I.bundle, V14)"
  out=$("$LUA_BIN" "$SANDBOX/lua/probe.lua" pill right ip "$BUNDLE/item.lua" 2>&1)
  assert_contains "$out" "subscribe routine forced wifi_change system_woke"
  assert_contains "$out" "exec STM_MAGENTA='0x00000001' STM_RED='0x00000003' STM_NET_SHAPE='pill' STM_NET_LABEL='ip' NAME='stm.net' SENDER='forced' '/p/net.sh'"
  done_it
elif [ -n "${CI:-}" ]; then
  it "lua is available to run item.lua"
  _note_fail "lua not found; CI must run item.lua"
  done_it
else
  printf '# note: lua not found, item.lua not run\n'
fi

finish
