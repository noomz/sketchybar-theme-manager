#!/usr/bin/env bash
#
# shellcheck disable=SC2016
# Payload strings (`$(...)`, backticks) must reach stm unexpanded.
#
# stm install item:<name> — bundled item bundles (#16). Items are code: they
# come only from the stm release's bundles/items/, never from a palette, the
# catalog or the network. Never hits the live network.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

D="$SANDBOX/cfg"
make_lua_config "$D"
ITEM_LEDGER="$XDG_CONFIG_HOME/stm/items"
PWN="$SANDBOX/pwned"

# Fake release root: bundled palettes from the repo, item bundles per test.
ROOT="$SANDBOX/root"
BUNDLES="$ROOT/bundles/items"
mkdir -p "$BUNDLES"
ln -s "$REPO_ROOT/palettes" "$ROOT/palettes"
export STM_ROOT="$ROOT"

OK_BUNDLE="$FIXTURES_DIR/items/ok"
BAD_ITEMS="$FIXTURES_DIR/bad-items"

# ship_bundle <src-dir> <name> — release <src-dir> as bundles/items/<name>.
ship_bundle() {
  rm -rf "${BUNDLES:?}/$2"
  cp -R "$1" "$BUNDLES/$2"
}

# ship_ok_as <name> — the valid baseline bundle, renamed to <name>.
ship_ok_as() {
  ship_bundle "$OK_BUNDLE" "$1"
  sed "s/^name = \"ok\"/name = \"$1\"/" "$OK_BUNDLE/item.toml" >"$BUNDLES/$1/item.toml"
}

reset_fetch_log() {
  : >"$STM_FETCH_LOG"
}

fetch_log() {
  cat "$STM_FETCH_LOG" 2>/dev/null || true
}

# snapshot — every path and file checksum under the config dir and stm state.
snapshot() {
  {
    find "$D" "$XDG_CONFIG_HOME" ! -type f -print
    find "$D" "$XDG_CONFIG_HOME" -type f -exec cksum {} +
  } | LC_ALL=C sort
}

# assert_item_rejected <verb> <name> <needle> — `stm <verb> item:<name>` fails,
# names the defect, never reaches a palette parser, writes nothing and never
# fetches.
assert_item_rejected() {
  local verb="$1" name="$2" needle="$3" before
  before=$(snapshot)
  reset_fetch_log
  run_stm --dir "$D" --no-reload "$verb" "item:$name"
  assert_ne 0 "$STM_STATUS" "$verb item:$name must fail"
  assert_contains "$STM_ERR" "$needle" "$verb item:$name must name the defect"
  # V2: item: never reaches the palette spec / theme-name parsers.
  assert_not_contains "$STM_ERR" "install spec" "$verb item:$name leaked into the palette spec parser"
  assert_not_contains "$STM_ERR" "theme name" "$verb item:$name leaked into the palette name check"
  assert_eq "$before" "$(snapshot)" "$verb item:$name must write nothing"
  assert_eq "" "$(fetch_log)" "$verb item:$name must not call STM_FETCH"
}

# check_bad_names <verb> — V3: only a bare bundled name is accepted.
check_bad_names() {
  local verb="$1" n
  for n in \
    '' \
    '../ok' \
    'ok/../ok' \
    'a/b' \
    'ok@abc123' \
    'https://example.com/ok' \
    'file:///etc/passwd' \
    'ok:x' \
    '..' \
    'Ok' \
    '1ok' \
    '-ok' \
    'abcdefghijklmnopqrstuvwxyz0123' \
    'ok;touch '"$PWN" \
    '$(touch '"$PWN"')' \
    '`touch '"$PWN"'`'
   do
    assert_item_rejected "$verb" "$n" "item"
  done
  assert_file_absent "$PWN" "no command substitution may have executed"
}

# check_unbundled <verb> — V3/V21: a name must exist in the release's bundles.
check_unbundled() {
  local verb="$1"
  assert_item_rejected "$verb" nope "nope"
  mkdir -p "$D/bundles/items" "$XDG_CONFIG_HOME/stm/bundles/items"
  cp -R "$OK_BUNDLE" "$D/bundles/items/local"
  cp -R "$OK_BUNDLE" "$XDG_CONFIG_HOME/stm/bundles/items/local"
  assert_item_rejected "$verb" local "local"
  rm -rf "$D/bundles" "$XDG_CONFIG_HOME/stm/bundles"
}

# check_bad_manifests <verb> — V4: one fixture per rule, each names its defect.
check_bad_manifests() {
  local verb="$1" c name
  for c in \
    'unknown-field:homepage' \
    'unknown-section:hooks' \
    'unknown-option-key:bogus' \
    'name-mismatch:other' \
    'dialect-unknown:python' \
    'color-not-required:rosewater' \
    'default-not-in-values:menu' \
    'shape-not-in-vocab:invalid shape "round"' \
    'position-invalid:top' \
    'files-slash:sub/plugin.sh' \
    'files-dotdot:../plugin.sh' \
    'files-absolute:/etc/hosts' \
    'files-unknown:extra.sh' \
    'file-missing:plugin.sh'
   do
    name=${c%%:*}
    ship_bundle "$BAD_ITEMS/$name" "$name"
    assert_item_rejected "$verb" "$name" "${c#*:}"
  done
}

# check_bad_files <verb> — V4: bundle files must be regular, never symlinks.
check_bad_files() {
  local verb="$1"
  assert_item_rejected "$verb" file-symlink "plugin.sh"
  assert_item_rejected "$verb" toml-symlink "item.toml"
  assert_item_rejected "$verb" dir-symlink "symlink"
  assert_item_rejected "$verb" file-not-regular "plugin.sh"
}

ship_ok_as ok

# `../plugin.sh` must be refused for the `..`, not because it is missing.
cp "$OK_BUNDLE/plugin.sh" "$BUNDLES/plugin.sh"

printf '#!/bin/sh\ntouch %s\n' "$PWN" >"$SANDBOX/outside.sh"
ship_ok_as file-symlink
rm "$BUNDLES/file-symlink/plugin.sh"
ln -s "$SANDBOX/outside.sh" "$BUNDLES/file-symlink/plugin.sh"
ship_ok_as toml-symlink
mv "$BUNDLES/toml-symlink/item.toml" "$SANDBOX/outside.toml"
ln -s "$SANDBOX/outside.toml" "$BUNDLES/toml-symlink/item.toml"
ship_ok_as dir-target
mv "$BUNDLES/dir-target" "$SANDBOX/dir-symlink"
sed 's/^name = .*/name = "dir-symlink"/' "$OK_BUNDLE/item.toml" >"$SANDBOX/dir-symlink/item.toml"
ln -s "$SANDBOX/dir-symlink" "$BUNDLES/dir-symlink"
ship_ok_as file-not-regular
rm "$BUNDLES/file-not-regular/plugin.sh"
mkdir "$BUNDLES/file-not-regular/plugin.sh"
cp "$OK_BUNDLE/plugin.sh" "$BUNDLES/file-not-regular/plugin.sh/plugin.sh"

# --- lint item: -- the manifest gate, offline and write-free ---------------

it "lint item: accepts the valid baseline bundle and writes nothing"
before=$(snapshot)
reset_fetch_log
run_stm --dir "$D" lint item:ok
assert_status 0
# shellcheck disable=SC2153  # STM_OUT is set by run_stm (helpers.sh), not a typo of STM_ROOT
assert_contains "$STM_OUT" "ok item:ok"
run_stm --dir "$D" --porcelain lint item:ok
assert_status 0
assert_eq "ok	item:ok" "$STM_OUT"
assert_eq "$before" "$(snapshot)" "lint item: must write nothing"
assert_eq "" "$(fetch_log)" "lint item: must not call STM_FETCH"
done_it

it "lint item: rejects names that are not a bare bundled name"
check_bad_names lint
done_it

it "lint item: rejects items that are not in the stm release"
check_unbundled lint
done_it

it "lint item: rejects hostile manifests"
check_bad_manifests lint
done_it

it "lint item: rejects symlinked and non-regular bundle files"
check_bad_files lint
done_it

it "lint item: accepts every option value shape the manifest allows"
ship_ok_as shapes
cat >"$BUNDLES/shapes/item.toml" <<'EOF'
# comment
name = "shapes"   # trailing comment
version = "1.20.3"
dialects = ["lua", "bash", "config-sh"]
files = ["item.lua"]
colors = []
default_position = "center"
events = ["system_woke", "wifi_change",]

[options.click]
default = "app"
values = ["popup", "app"]

[options.ip]
values = ["on", "off"]
default = "off"
EOF
run_stm --dir "$D" lint item:shapes
assert_status 0
done_it

it "lint item: accepts a shape option offering a subset of plain|pill|split (V32)"
ship_ok_as shaped
cat >>"$BUNDLES/shaped/item.toml" <<'EOF'

[options.shape]
values = ["split", "pill"]
default = "split"
EOF
run_stm --dir "$D" lint item:shaped
assert_status 0
done_it

# --- the bundles shipped in this repo -------------------------------------

it "every bundled item passes lint item:, offline and write-free (V22)"
n=0
for b in "$REPO_ROOT"/bundles/items/*/; do
  [ -d "$b" ] || continue
  n=$((n + 1))
  name=$(basename "$b")
  before=$(snapshot)
  reset_fetch_log
  STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --porcelain lint "item:$name"
  assert_status 0 "bundled item:$name must lint clean"
  assert_eq "ok	item:$name" "$STM_OUT"
  assert_eq "$before" "$(snapshot)" "lint item:$name must write nothing"
  assert_eq "" "$(fetch_log)" "lint item:$name must not call STM_FETCH"
done
[ "$n" -gt 0 ] || _note_fail "no bundled items found under bundles/items/"
done_it

it "bundled item code never hard-codes a colour (V14)"
hits=$(grep -nE '0x[0-9A-Fa-f]{6,8}|#[0-9A-Fa-f]{6}([^0-9A-Za-z]|$)' \
  "$REPO_ROOT"/bundles/items/*/item.lua "$REPO_ROOT"/bundles/items/*/plugin.sh 2>/dev/null)
assert_eq "" "$hits" "colours must come from the palette via colors / env"
done_it

# --- install item: -- same gate, reached through install ------------------

it "install item: rejects names that are not a bare bundled name"
check_bad_names install
done_it

it "install item: rejects items that are not in the stm release"
check_unbundled install
done_it

it "install item: rejects hostile manifests"
check_bad_manifests install
done_it

it "install item: rejects symlinked and non-regular bundle files"
check_bad_files install
done_it

it "install item:<palette slug> never falls through to a palette install (V2)"
assert_item_rejected install tokyo-night "tokyo-night"
done_it

it "uninstall item: rejects names that are not a bare bundled name"
check_bad_names uninstall
done_it

# --- positive control: the baseline every bad case differs from ------------

it "installs the valid baseline bundle"
reset_fetch_log
run_stm --dir "$D" --no-reload install item:ok
assert_status 0
assert_file_exists "$D/items/stm/ok.lua"
assert_file_exists "$D/plugins/stm/ok.sh"
assert_file_contains "$ITEM_LEDGER" "ok	bundled	"
assert_eq "" "$(fetch_log)" "install item:ok must not call STM_FETCH"
done_it

# --- install item: write path ----------------------------------------------

# reset_items — no item installed: stm-owned item paths and the ledger gone.
reset_items() {
  chmod -R u+w "$D/items" "$D/plugins" 2>/dev/null
  rm -rf "$D/items" "$D/plugins" "$D/items_generated.lua" "$ITEM_LEDGER"
}

# changed_paths <before> <after> — paths whose snapshot line differs.
changed_paths() {
  { printf '%s\n' "$1"; printf '%s\n' "$2"; } | LC_ALL=C sort | uniq -u |
    awk '{ print $NF }' | LC_ALL=C sort -u
}

# tmp_leftovers — any stm temp file left behind anywhere we write.
tmp_leftovers() {
  find "$D" "$XDG_CONFIG_HOME" -name '.stm-tmp.*' 2>/dev/null
}

PALETTE_LEDGER="$XDG_CONFIG_HOME/stm/installed"

it "install item: writes only its item, plugin, loader and ledger row (V5, V19)"
reset_items
mkdir -p "$XDG_CONFIG_HOME/stm"
printf 'nord\thttps://example.com/nord.toml\t%064d\tmain\t2026-01-01T00:00:00Z\n' 0 >"$PALETTE_LEDGER"
palette_ledger_before=$(cksum <"$PALETTE_LEDGER")
before=$(snapshot)
run_stm --dir "$D" --no-reload install item:ok
assert_status 0
expected=$(printf '%s\n' "$D/items" "$D/items/stm" "$D/items/stm/ok.lua" \
  "$D/plugins" "$D/plugins/stm" "$D/plugins/stm/ok.sh" "$D/items_generated.lua" \
  "$ITEM_LEDGER" | LC_ALL=C sort)
assert_eq "$expected" "$(changed_paths "$before" "$(snapshot)")" "install item:ok touched other paths"
assert_eq "$palette_ledger_before" "$(cksum <"$PALETTE_LEDGER")" "palette ledger must be untouched"
assert_eq "" "$(tmp_leftovers)" "no temp files may be left behind"
done_it

it "install item: copies the bundle files, plugin executable (I.fs)"
assert_files_equal "$BUNDLES/ok/item.lua" "$D/items/stm/ok.lua"
assert_files_equal "$BUNDLES/ok/plugin.sh" "$D/plugins/stm/ok.sh"
assert_eq "-rwxr-xr-x" "$(stat -f %Sp "$D/plugins/stm/ok.sh")" "plugin mode"
assert_eq "-rw-r--r--" "$(stat -f %Sp "$D/items/stm/ok.lua")" "item mode"
stm_version=$(awk -F'"' '/^STM_VERSION=/ { print $2; exit }' "$STM_BIN")
row=$(cat "$ITEM_LEDGER")
case "$row" in
  "ok	bundled	"*"	$stm_version	"????-??-??T??:??:??Z) : ;;
  *) _note_fail "ledger row shape: name bundled sha ref iso8601" "row: $row" ;;
esac
sha=$(printf '%s\n' "$row" | awk -F'\t' '{ print $3 }')
case "$sha" in
  *[!0-9a-f]* | "") _note_fail "tree sha is not hex: $sha" ;;
  *) assert_eq 64 "${#sha}" "tree sha length" ;;
esac
done_it

it "install item: already installed without --force is EX_EXISTS, writes nothing (V8)"
before=$(snapshot)
run_stm --dir "$D" --no-reload install item:ok
assert_status 4
assert_contains "$STM_ERR" "--force"
assert_eq "$before" "$(snapshot)" "refused reinstall must write nothing"
done_it

it "install item: --force replaces files and the ledger row, never duplicates it (V8)"
old_sha=$(awk -F'\t' '{ print $3 }' "$ITEM_LEDGER")
printf -- '-- changed\n' >>"$BUNDLES/ok/item.lua"
run_stm --dir "$D" --no-reload --force install item:ok
assert_status 0
assert_files_equal "$BUNDLES/ok/item.lua" "$D/items/stm/ok.lua"
assert_eq 1 "$(grep -c '^ok	' "$ITEM_LEDGER")" "one ledger row per item"
assert_ne "$old_sha" "$(awk -F'\t' '{ print $3 }' "$ITEM_LEDGER")" "bundle change must change the tree sha"
done_it

it "install item: failure mid-install leaves the prior install intact (V6)"
ship_ok_as ok
run_stm --dir "$D" --no-reload --force install item:ok
assert_status 0
printf -- '-- newer\n' >>"$BUNDLES/ok/item.lua"
chmod 555 "$D/plugins/stm"
before=$(snapshot)
run_stm --dir "$D" --no-reload --force install item:ok
chmod 755 "$D/plugins/stm"
assert_ne 0 "$STM_STATUS" "install must fail when plugins/stm is read-only"
assert_eq "$before" "$(snapshot)" "a failed install must leave every file as it was"
assert_eq "" "$(tmp_leftovers)" "no temp files may be left behind"
ship_ok_as ok
done_it

it "install item: refuses a non-Lua config or a bundle without the lua dialect (V7)"
B="$SANDBOX/bashcfg"
make_bash_config "$B"
reset_items
before=$(snapshot)
bash_before=$(find "$B" -exec cksum {} + 2>/dev/null | LC_ALL=C sort)
run_stm --dir "$B" --no-reload install item:ok
assert_ne 0 "$STM_STATUS" "item install into a bash config must fail"
assert_contains "$STM_ERR" "lua"
assert_eq "$bash_before" "$(find "$B" -exec cksum {} + 2>/dev/null | LC_ALL=C sort)" "bash config must be untouched"
assert_eq "$before" "$(snapshot)" "nothing written"
ship_ok_as nolua
sed 's/^dialects = .*/dialects = ["bash"]/' "$BUNDLES/nolua/item.toml" >"$SANDBOX/nolua.toml"
mv "$SANDBOX/nolua.toml" "$BUNDLES/nolua/item.toml"
run_stm --dir "$D" --no-reload install item:nolua
assert_ne 0 "$STM_STATUS" "a bundle without the lua dialect must be refused"
assert_contains "$STM_ERR" "lua"
assert_eq "$before" "$(snapshot)" "nothing written"
done_it

it "install item: refuses a symlinked items/stm, writes nothing through it"
reset_items
mkdir -p "$D/items" "$SANDBOX/elsewhere"
ln -s "$SANDBOX/elsewhere" "$D/items/stm"
before=$(snapshot)
run_stm --dir "$D" --no-reload install item:ok
assert_ne 0 "$STM_STATUS" "symlinked items/stm must be refused"
assert_contains "$STM_ERR" "symlink"
assert_eq "" "$(ls -A "$SANDBOX/elsewhere")" "nothing may be written through the symlink"
assert_eq "$before" "$(snapshot)" "nothing written"
reset_items
done_it

it "install item: --dry-run reports and writes nothing"
before=$(snapshot)
run_stm --dir "$D" --no-reload --dry-run install item:ok
assert_status 0
assert_contains "$STM_OUT$STM_ERR" "would install item:ok"
assert_eq "$before" "$(snapshot)" "--dry-run must write nothing"
done_it

# --- items_generated.lua: options, position, name --------------------------

LOADER="$D/items_generated.lua"
CFG="$D/stm.config.toml"
D_ABS=$(cd -- "$D" && pwd)

it "install item: writes items_generated.lua with the item's opts (V10, I.bundle)"
reset_items
rm -f "$CFG"
run_stm --dir "$D" --no-reload install item:ok
assert_status 0
assert_file_contains "$LOADER" "DO NOT EDIT"
assert_file_contains "$LOADER" 'require("items_generated")'
assert_file_contains "$LOADER" "local dir = \"$D_ABS\""
assert_file_contains "$LOADER" 'stm_item("ok", {'
assert_file_contains "$LOADER" 'name = "stm.ok",'
assert_file_contains "$LOADER" 'position = "right",'
assert_file_contains "$LOADER" 'plugin_dir = dir .. "/plugins/stm",'
assert_file_contains "$LOADER" 'update_freq = 30,'
assert_file_contains "$LOADER" 'events = { "system_woke" },'
assert_file_contains "$LOADER" '["label"] = "on",'
done_it

it "install item: [item.<name>] options reach the loader (I.cfg)"
printf '[item.ok]\nlabel = "off"\n' >"$CFG"
run_stm --dir "$D" --no-reload --force install item:ok
assert_status 0
assert_file_contains "$LOADER" '["label"] = "off",'
assert_file_not_contains "$LOADER" '["label"] = "on",'
done_it

it "install item: bad [item.<name>] values or keys are hard errors, nothing written (V9)"
for bad in \
  'label = "maybe"' \
  'label = "on; os.execute(1)"' \
  'label = "$(touch '"$PWN"')"' \
  'colour = "on"'
do
  printf '[item.ok]\n%s\n' "$bad" >"$CFG"
  before=$(snapshot)
  run_stm --dir "$D" --no-reload --force install item:ok
  assert_ne 0 "$STM_STATUS" "[item.ok] $bad must fail"
  assert_contains "$STM_ERR" "item.ok"
  assert_eq "$before" "$(snapshot)" "[item.ok] $bad must write nothing"
done
assert_file_absent "$PWN" "no config value may execute"
assert_file_not_contains "$LOADER" "os.execute"
rm -f "$CFG"
done_it

it "install item: --dry-run still rejects bad [item.<name>] options (V9)"
printf '[item.ok]\nlabel = "maybe"\n' >"$CFG"
run_stm --dir "$D" --no-reload --force --dry-run install item:ok
assert_ne 0 "$STM_STATUS" "--dry-run must validate options"
rm -f "$CFG"
done_it

it "install item: palette [items] slot beats the manifest default_position (I.cfg)"
P="$SANDBOX/pal"
mkdir -p "$P"
{
  sed 's/^slug = .*/slug = "slotted"/;s/^name = .*/name = "slotted"/' "$REPO_ROOT/palettes/nord.toml"
  printf '\n[items]\nstm.ok = "left"\n'
} >"$P/slotted.toml"
run_stm --dir "$D" --palette-dir "$P" --no-reload apply slotted
assert_status 0
run_stm --dir "$D" --palette-dir "$P" --no-reload --force install item:ok
assert_status 0
assert_file_contains "$LOADER" 'position = "left",'
done_it

it "install item: refuses a config dir path that cannot be a Lua string"
W="$SANDBOX/we\"ird"
make_lua_config "$W"
run_stm --dir "$W" --no-reload --force install item:ok
assert_ne 0 "$STM_STATUS" "a config dir containing \" must be refused"
assert_contains "$STM_ERR" "quote"
assert_file_absent "$W/items_generated.lua"
assert_file_absent "$W/items/stm/ok.lua"
done_it

# The loader and the real tailscale item.lua, run under Lua with a fake
# `sketchybar` module: the opts shape reaches the item end to end.
LUA_BIN=$(command -v lua 2>/dev/null || true)
if [ -n "$LUA_BIN" ]; then
  it "items_generated.lua runs under Lua and hands tailscale its opts (V10, I.bundle)"
  L="$SANDBOX/luacfg"
  make_lua_config "$L"
  L_ABS=$(cd -- "$L" && pwd)
  printf '[item.tailscale]\nclick = "app"\nicon = "nerd"\nshape = "split"\n' >"$L/stm.config.toml"
  STM_ROOT="$REPO_ROOT" run_stm --dir "$L" --no-reload install item:tailscale
  assert_status 0
  mkdir -p "$SANDBOX/lua"
  cat >"$SANDBOX/lua/sketchybar.lua" <<'EOF'
local sbar = {}
function sbar.add(kind, name, props)
  print("add " .. kind .. " " .. name .. " " .. tostring(props.position) .. " " .. tostring(props.update_freq))
  print("icon " .. tostring(props.icon.string))
  return { subscribe = function() end, set = function() end }
end
function sbar.exec(cmd) print("exec " .. cmd) end
return sbar
EOF
  lua_out=$(cd -- "$L" && "$LUA_BIN" -e "package.path = '$SANDBOX/lua/?.lua;./?.lua;' .. package.path" \
    -e 'require("items_generated")' 2>&1)
  assert_contains "$lua_out" "add item stm.tailscale right 30"
  assert_contains "$lua_out" "'$L_ABS/plugins/stm/tailscale.sh'"
  assert_contains "$lua_out" "STM_TS_CLICK='app'"
  assert_contains "$lua_out" "STM_TS_ICON='nerd'"
  assert_contains "$lua_out" "STM_TS_SHAPE='split'"
  assert_contains "$lua_out" "add item stm.tailscale.icon right nil"
  # nf-md-dots_grid, U+F15FC (V25).
  assert_contains "$lua_out" "icon $(printf '\363\261\227\274')"
  assert_contains "$lua_out" "STM_GREEN='0xffa6da95'"
  assert_not_contains "$lua_out" "stm: item"
  done_it

  it "tailscale item.lua sets the initial icon for text, nerd and app (V25, V14)"
  cat >"$SANDBOX/lua/icon_probe.lua" <<'EOF'
-- Runs item.lua with one icon mode and prints the icon it creates.
local mode, item_lua = ...
local sbar = {}
function sbar.add(_, _, props)
  local i, bg = props.icon, props.icon.background or {}
  print(string.format("string=%s color=%s bg.drawing=%s bg.color=%s scale=%s",
    i.string, tostring(i.color), tostring(bg.drawing), tostring(bg.color),
    tostring(bg.image and bg.image.scale)))
  return { subscribe = function() end, set = function() end }
end
function sbar.exec() end
local opts = { name = "stm.tailscale", position = "right", update_freq = 30,
  plugin_dir = "/p", events = {},
  options = { exit_node = "on", peers = "on", ip = "on", click = "popup", icon = mode } }
dofile(item_lua)(sbar, opts, { grey = 7, green = 1 })
EOF
  ITEM_LUA="$REPO_ROOT/bundles/items/tailscale/item.lua"
  icon_of() {
    "$LUA_BIN" "$SANDBOX/lua/icon_probe.lua" "$1" "$ITEM_LUA" 2>&1
  }
  assert_eq "string=TS color=7 bg.drawing=nil bg.color=nil scale=nil" "$(icon_of text)" "text icon"
  assert_eq "string=$(printf '\363\261\227\274') color=7 bg.drawing=nil bg.color=nil scale=nil" \
    "$(icon_of nerd)" "nerd icon"
  # Transparent background (no pill from the user's icon defaults), 32pt app
  # image drawn at 20pt.
  assert_eq "string= color=nil bg.drawing=true bg.color=0 scale=0.625" "$(icon_of app)" "app icon"
  done_it

  cat >"$SANDBOX/lua/shape_probe.lua" <<'EOF'
-- Runs item.lua with one shape, icon mode and position; prints each item it
-- adds, in order, with its props flattened (keys sorted).
local shape, icon, position, item_lua = ...
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
  return { subscribe = function() end, set = function() end }
end
function sbar.exec() end
local opts = { name = "stm.tailscale", position = position, update_freq = 30,
  plugin_dir = "/p", events = {},
  options = { exit_node = "on", peers = "on", ip = "on", click = "popup", icon = icon, shape = shape } }
dofile(item_lua)(sbar, opts, { grey = 7, green = 1, bg1 = 21, black = 22, popup_bg = 31, popup_border = 32 })
EOF
  # shape_of <shape> <icon> <position> — the items item.lua adds, one per line.
  shape_of() {
    "$LUA_BIN" "$SANDBOX/lua/shape_probe.lua" "$1" "$2" "$3" "$ITEM_LUA" 2>&1
  }
  TS_CLICK="click_script=sketchybar --set 'stm.tailscale' popup.drawing=toggle"
  TS_POPUP="popup={align=right background={border_color=32 border_width=1 color=31 corner_radius=6}}"
  TS_APP_ICON="background={color=0 drawing=true image={scale=0.625}}"

  it "tailscale shape=plain adds exactly what 0.6.0 did (V34)"
  # Captured from the 0.6.0 item.lua: no background, one item.
  assert_eq "item stm.tailscale {$TS_CLICK icon={color=7 string=TS} label={string=tailscale} $TS_POPUP position=right update_freq=30}" \
    "$(shape_of plain text right)" "plain text"
  assert_eq "item stm.tailscale {$TS_CLICK icon={$TS_APP_ICON string=} label={string=tailscale} $TS_POPUP position=right update_freq=30}" \
    "$(shape_of plain app right)" "plain app"
  done_it

  it "tailscale shape=pill: one item on a bg1 background (V32, V34, V14)"
  assert_eq "item stm.tailscale {background={color=21 drawing=true} $TS_CLICK icon={color=7 string=TS} label={string=tailscale} $TS_POPUP position=right update_freq=30}" \
    "$(shape_of pill text right)" "pill text"
  assert_eq "item stm.tailscale {background={color=21 drawing=true} $TS_CLICK icon={$TS_APP_ICON string=} label={string=tailscale} $TS_POPUP position=left update_freq=30}" \
    "$(shape_of pill app left)" "pill app"
  done_it

  it "tailscale shape=split: icon sub-item left of the label item at every position (V32, V33, V10)"
  ts_main() {
    printf 'item stm.tailscale {background={color=21 drawing=true padding_left=0} %s icon={drawing=false} label={string=tailscale} %s position=%s update_freq=30}' \
      "$TS_CLICK" "$TS_POPUP" "$1"
  }
  ts_icon() {
    printf 'item stm.tailscale.icon {background={color=7 drawing=true} %s icon={%s} label={drawing=false} position=%s}' \
      "$TS_CLICK" "$2" "$1"
  }
  # Right items are laid out right to left: the label item goes in first.
  assert_eq "$(ts_main right)
$(ts_icon right 'color=22 string=TS')" "$(shape_of split text right)" "split right"
  for pos in left center; do
    assert_eq "$(ts_icon "$pos" 'color=22 string=TS')
$(ts_main "$pos")" "$(shape_of split text "$pos")" "split $pos"
  done
  assert_eq "$(ts_icon left "color=22 string=$(printf '\363\261\227\274')")
$(ts_main left)" "$(shape_of split nerd left)" "split nerd"
  # app: the image sits on the state-coloured sub-item background.
  assert_eq "$(ts_main right)
$(ts_icon right "$TS_APP_ICON color=22 string=")" "$(shape_of split app right)" "split app"
  done_it
elif [ -n "${CI:-}" ]; then
  it "lua is available to run items_generated.lua"
  _note_fail "lua not found; CI must run the loader end to end"
  done_it
else
  printf '# note: lua not found, items_generated.lua not run end to end\n'
fi

# --- apply: regenerate items_generated.lua ---------------------------------

# A sketchybar stub that keeps the loader as it was at reload time.
RB="$SANDBOX/bin-reload"
mkdir -p "$RB"
cat >"$RB/sketchybar" <<EOF
#!/bin/sh
cp "$LOADER" "$SANDBOX/at-reload.lua" 2>/dev/null
printf '%s\n' "\$*" >>"\$STM_TEST_RELOAD_LOG"
EOF
chmod 755 "$RB/sketchybar"

it "apply regenerates items_generated.lua for the new palette, before reload, offline (V13)"
reset_items
rm -f "$CFG" "$SANDBOX/at-reload.lua"
run_stm --dir "$D" --palette-dir "$P" --no-reload apply nord
assert_status 0
run_stm --dir "$D" --palette-dir "$P" --no-reload install item:ok
assert_status 0
assert_file_contains "$LOADER" 'position = "right",'
reset_fetch_log
PATH="$RB:$PATH" run_stm --dir "$D" --palette-dir "$P" apply slotted
assert_status 0
assert_file_contains "$LOADER" 'position = "left",'
assert_file_contains "$SANDBOX/at-reload.lua" 'position = "left",'
assert_eq "" "$(fetch_log)" "apply must not call STM_FETCH"
run_stm --dir "$D" --palette-dir "$P" --no-reload apply nord
assert_status 0
assert_file_contains "$LOADER" 'position = "right",'
done_it

it "apply picks up [item.<name>] changes"
printf '[item.ok]\nlabel = "off"\n' >"$CFG"
run_stm --dir "$D" --palette-dir "$P" --no-reload apply nord
assert_status 0
assert_file_contains "$LOADER" '["label"] = "off",'
rm -f "$CFG"
done_it

it "apply with a bad [item.<name>] option fails before writing anything (V9, V13)"
printf '[item.ok]\nlabel = "maybe"\n' >"$CFG"
before=$(snapshot)
run_stm --dir "$D" --palette-dir "$P" --no-reload apply slotted
assert_ne 0 "$STM_STATUS" "apply must fail on a bad item option"
assert_contains "$STM_ERR" "item.ok"
assert_eq "$before" "$(snapshot)" "a refused apply must write nothing"
rm -f "$CFG"
done_it

it "apply --dry-run mentions the loader and writes nothing"
before=$(snapshot)
run_stm --dir "$D" --palette-dir "$P" --no-reload --dry-run apply slotted
assert_status 0
assert_contains "$STM_OUT$STM_ERR" "items_generated.lua"
assert_eq "$before" "$(snapshot)" "--dry-run must write nothing"
done_it

# --- palette [item.<name>] options (#19) ------------------------------------

# opt_palette <slug> <toml-line>... — nord plus the given lines, in $P.
opt_palette() {
  local slug="$1"
  shift
  {
    sed "s/^slug = .*/slug = \"$slug\"/;s/^name = .*/name = \"$slug\"/" "$REPO_ROOT/palettes/nord.toml"
    printf '\n'
    printf '%s\n' "$@"
  } >"$P/$slug.toml"
}

it "palette [item.<name>] value beats the manifest default; a theme without it resets (V29)"
opt_palette optoff '[item.ok]' 'label = "off"'
run_stm --dir "$D" --palette-dir "$P" --no-reload apply optoff
assert_status 0
assert_file_contains "$LOADER" '["label"] = "off",'
run_stm --dir "$D" --palette-dir "$P" --no-reload apply nord
assert_status 0
assert_file_contains "$LOADER" '["label"] = "on",'
done_it

it "a base child with only item options, no colours of its own, applies (V37, B7)"
# The C13 route: bundled palettes are colour-only, so a theme that reshapes
# items is a user palette inheriting one. It needs no [colors] at all.
for colours in '[colors]' ''; do
  printf 'name = "Shape Only"\nslug = "shapeonly"\nbase = "nord"\n\n%s\n\n[item.ok]\nlabel = "off"\n' \
    "$colours" >"$P/shapeonly.toml"
  run_stm --dir "$D" --palette-dir "$P" lint shapeonly
  assert_status 0
  # The path form: the entry `install` and `publish` lint through.
  run_stm --dir "$D" --palette-dir "$P" lint "$P/shapeonly.toml"
  assert_status 0
  run_stm --dir "$D" --palette-dir "$P" --no-reload apply shapeonly
  assert_status 0
  assert_file_contains "$LOADER" '["label"] = "off",'
  assert_file_contains "$D/colors_generated.lua" "  red = 0xffbf616a,"
done
run_stm --dir "$D" --palette-dir "$P" --no-reload apply nord
assert_status 0
before=$(snapshot)
# Without a base there is nothing to inherit: still no palette.
for colours in '[colors]' ''; do
  printf 'name = "Bare"\nslug = "bare"\n\n%s\n\n[item.ok]\nlabel = "off"\n' "$colours" >"$P/bare.toml"
  for verb in lint apply; do
    run_stm --dir "$D" --palette-dir "$P" --no-reload "$verb" bare
    assert_ne 0 "$STM_STATUS" "$verb: no colours and no base must fail"
    assert_contains "$STM_ERR" "no [colors] table found"
  done
done
# A base that cannot be found leaves a colourless child nothing to inherit.
printf 'name = "Lost"\nslug = "lost"\nbase = "no-such-palette"\n\n[item.ok]\nlabel = "off"\n' >"$P/lost.toml"
run_stm --dir "$D" --palette-dir "$P" --no-reload apply lost
assert_eq 3 "$STM_STATUS" "missing base is EX_NOTFOUND"
assert_contains "$STM_ERR" "inherits from"
assert_eq "$before" "$(snapshot)" "a refused palette must write nothing"
rm -f "$P/bare.toml" "$P/lost.toml"
done_it

it "stm.config.toml [item.<name>] beats the palette (V29, I.cfg)"
printf '[item.ok]\nlabel = "on"\n' >"$CFG"
run_stm --dir "$D" --palette-dir "$P" --no-reload apply optoff
assert_status 0
assert_file_contains "$LOADER" '["label"] = "on",'
rm -f "$CFG"
done_it

it "install, apply and uninstall write the same loader for the same state (V29)"
run_stm --dir "$D" --palette-dir "$P" --no-reload apply optoff
assert_status 0
by_apply=$(cat "$LOADER")
run_stm --dir "$D" --palette-dir "$P" --no-reload --force install item:ok
assert_status 0
assert_eq "$by_apply" "$(cat "$LOADER")" "install must render the active theme's options"
ship_ok_as two
run_stm --dir "$D" --palette-dir "$P" --no-reload install item:two
assert_status 0
run_stm --dir "$D" --palette-dir "$P" --no-reload uninstall item:two
assert_status 0
assert_eq "$by_apply" "$(cat "$LOADER")" "uninstall must render the active theme's options"
rm -rf "${BUNDLES:?}/two"
done_it

it "palette options survive a stm.config.toml without [item.<name>] (V29, V36, B6)"
printf '[alpha]\nbar_bg = "60"\n' >"$CFG"
opt_palette optboth '[item.ok]' 'label = "off"'
run_stm --dir "$D" --palette-dir "$P" --no-reload apply optboth
assert_status 0
assert_file_contains "$LOADER" '["label"] = "off",'
assert_not_contains "$STM_ERR" "ignoring"
by_apply=$(cat "$LOADER")
run_stm --dir "$D" --palette-dir "$P" --no-reload --force install item:ok
assert_status 0
assert_eq "$by_apply" "$(cat "$LOADER")" "install and apply must agree with a config present"
rm -f "$CFG"
done_it

it "an [items] slot or [item.<name>] table named like a colour never drops it (V36, B6)"
printf '[alpha]\nbar_bg = "60"\n' >"$CFG"
opt_palette optred '[items]' 'red = "left"' '' '[item.red]' 'x = "y"' '' '[item.green]' 'x = "y"'
run_stm --dir "$D" --palette-dir "$P" --no-reload apply optred
assert_status 0
assert_file_contains "$D/colors_generated.lua" "  red = 0xffbf616a,"
assert_file_contains "$D/colors_generated.lua" "  green = 0xffa3be8c,"
rm -f "$CFG"
done_it

it "a bad palette option warns, is ignored, and apply still succeeds (V28)"
for bad in 'label = "maybe"' 'colour = "on"'; do
  opt_palette optbad '[item.ok]' "$bad"
  run_stm --dir "$D" --palette-dir "$P" --no-reload apply optbad
  assert_status 0 "palette $bad must not fail apply"
  assert_contains "$STM_ERR" "warning: theme optbad: ignoring [item.ok]"
  assert_file_contains "$LOADER" '["label"] = "on",'
  assert_file_not_contains "$LOADER" "maybe"
  assert_file_not_contains "$LOADER" "colour"
done
done_it

it "palette options for an item not installed: a note, nothing installed, offline (V30)"
ship_ok_as spare
opt_palette optghost '[item.spare]' 'label = "off"' '' '[item.ghost]' 'shape = "pill"' \
  '' '[item.ok]' 'label = "off"'
reset_fetch_log
run_stm --dir "$D" --palette-dir "$P" --no-reload apply optghost
assert_status 0
assert_contains "$STM_ERR" "note: item:spare not installed (stm install item:spare)"
assert_eq 1 "$(printf '%s\n' "$STM_ERR" | awk '/item:spare not installed/ { n++ } END { print n+0 }')" "one note per item"
assert_contains "$STM_ERR" "note: item:ghost is not a bundled item; the theme's options for it are ignored"
assert_not_contains "$STM_ERR" "stm install item:ghost"
assert_not_contains "$STM_ERR" "item:ok not installed"
assert_file_absent "$D/items/stm/spare.lua"
assert_not_contains "$(cat "$ITEM_LEDGER")" "spare"
rm -rf "${BUNDLES:?}/spare"
assert_file_absent "$D/items/stm/ghost.lua"
assert_not_contains "$(cat "$ITEM_LEDGER")" "ghost"
assert_eq "" "$(fetch_log)" "apply must not call STM_FETCH"
done_it

it "apply with no items installed leaves items_generated.lua alone (V13)"
reset_items
printf -- '-- hand-made\n' >"$LOADER"
loader_before=$(cksum <"$LOADER")
run_stm --dir "$D" --palette-dir "$P" --no-reload apply slotted
assert_status 0
assert_eq "$loader_before" "$(cksum <"$LOADER")" "no ledger: loader must not change"
rm -f "$LOADER"
run_stm --dir "$D" --palette-dir "$P" --no-reload apply nord
assert_status 0
assert_file_absent "$LOADER" "no ledger: apply must not create a loader"
done_it

it "apply never creates a loader in a config that has none"
run_stm --dir "$D" --palette-dir "$P" --no-reload install item:ok
assert_status 0
O="$SANDBOX/othercfg"
make_lua_config "$O"
run_stm --dir "$O" --palette-dir "$P" --no-reload apply slotted
assert_status 0
assert_file_absent "$O/items_generated.lua" "apply must not write a loader for items this config lacks"
done_it

# --- uninstall item: --------------------------------------------------------

it "uninstall item: removes only its files and ledger row, keeps other items (V11, V19)"
reset_items
ship_ok_as two
run_stm --dir "$D" --no-reload install item:ok
assert_status 0
run_stm --dir "$D" --no-reload install item:two
assert_status 0
mkdir -p "$XDG_CONFIG_HOME/stm"
printf 'nord\thttps://example.com/nord.toml\t%064d\tmain\t2026-01-01T00:00:00Z\n' 0 >"$PALETTE_LEDGER"
before=$(snapshot)
reset_fetch_log
run_stm --dir "$D" --no-reload uninstall item:ok
assert_status 0
expected=$(printf '%s\n' "$D/items/stm/ok.lua" "$D/plugins/stm/ok.sh" "$LOADER" "$ITEM_LEDGER" | LC_ALL=C sort)
assert_eq "$expected" "$(changed_paths "$before" "$(snapshot)")" "uninstall item:ok touched other paths"
assert_file_absent "$D/items/stm/ok.lua"
assert_file_absent "$D/plugins/stm/ok.sh"
assert_file_exists "$D/items/stm/two.lua"
assert_file_not_contains "$ITEM_LEDGER" "ok	"
assert_file_contains "$ITEM_LEDGER" "two	bundled	"
assert_file_not_contains "$LOADER" 'stm_item("ok"'
assert_file_contains "$LOADER" 'stm_item("two"'
assert_eq "" "$(fetch_log)" "uninstall item: must not call STM_FETCH"
assert_eq "" "$(tmp_leftovers)" "no temp files may be left behind"
done_it

it "uninstall item: not installed is EX_NOTFOUND, writes nothing"
before=$(snapshot)
run_stm --dir "$D" --no-reload uninstall item:ok
assert_status 3
assert_contains "$STM_ERR" "not installed"
assert_eq "$before" "$(snapshot)" "nothing written"
done_it

it "uninstall item: the last item drops the ledger, keeps a loader that still loads"
run_stm --dir "$D" --no-reload remove item:two
assert_status 0
assert_file_absent "$ITEM_LEDGER" "an empty item ledger is removed"
assert_file_exists "$LOADER" "require(\"items_generated\") must keep working"
assert_file_not_contains "$LOADER" 'stm_item("'
if [ -n "$LUA_BIN" ]; then
  lua_out=$(cd -- "$D" && "$LUA_BIN" -e "package.path = '$SANDBOX/lua/?.lua;./?.lua;' .. package.path" \
    -e 'require("items_generated")' 2>&1)
  assert_eq "" "$lua_out" "an empty loader must load cleanly"
fi
done_it

# uninstall_refused <needle> — uninstall item:ok fails naming <needle> and
# writes nothing. The snapshot does not follow symlinks: callers check targets.
uninstall_refused() {
  local before
  before=$(snapshot)
  run_stm --dir "$D" --no-reload uninstall item:ok
  assert_ne 0 "$STM_STATUS" "uninstall item:ok must be refused"
  assert_contains "$STM_ERR" "$1"
  assert_eq "$before" "$(snapshot)" "a refused uninstall must write nothing"
}

it "uninstall item: refuses a symlinked item file, leaves its target alone (V11)"
run_stm --dir "$D" --no-reload install item:ok
assert_status 0
printf 'keep me\n' >"$SANDBOX/outside.lua"
rm "$D/items/stm/ok.lua"
ln -s "$SANDBOX/outside.lua" "$D/items/stm/ok.lua"
uninstall_refused "symlink"
assert_eq "keep me" "$(cat "$SANDBOX/outside.lua")" "symlink target must survive"
done_it

it "uninstall item: refuses a symlinked plugins/stm and a non-regular target (V11)"
run_stm --dir "$D" --no-reload --force install item:ok
assert_status 0
mv "$D/plugins/stm" "$SANDBOX/plugins-elsewhere"
ln -s "$SANDBOX/plugins-elsewhere" "$D/plugins/stm"
uninstall_refused "symlink"
assert_file_exists "$SANDBOX/plugins-elsewhere/ok.sh" "nothing removed through the symlink"
rm "$D/plugins/stm"
mv "$SANDBOX/plugins-elsewhere" "$D/plugins/stm"
rm "$D/plugins/stm/ok.sh"
mkdir "$D/plugins/stm/ok.sh"
uninstall_refused "not a regular file"
rmdir "$D/plugins/stm/ok.sh"
done_it

it "uninstall item: --dry-run reports and writes nothing"
before=$(snapshot)
run_stm --dir "$D" --no-reload --dry-run uninstall item:ok
assert_status 0
assert_contains "$STM_OUT$STM_ERR" "would remove"
assert_eq "$before" "$(snapshot)" "--dry-run must write nothing"
done_it

it "uninstall item: works for an item no longer in the stm release"
rm -rf "${BUNDLES:?}/ok"
run_stm --dir "$D" --no-reload uninstall item:ok
assert_status 0
assert_file_absent "$D/items/stm/ok.lua"
assert_file_absent "$ITEM_LEDGER"
ship_ok_as ok
done_it

# --- manifest / verify / backup ---------------------------------------------

it "item files and the loader stay out of the manifest baseline and verify (V12)"
reset_items
mkdir -p "$D/items"
printf 'return {}\n' >"$D/items/clock.lua"
run_stm --dir "$D" --palette-dir "$P" --no-reload install item:ok
assert_status 0
run_stm --dir "$D" --palette-dir "$P" --no-reload apply nord
assert_status 0
assert_file_not_contains "$D/.stm-manifest" "items/stm/"
assert_file_not_contains "$D/.stm-manifest" "plugins/stm/"
assert_file_not_contains "$D/.stm-manifest" "items_generated.lua"
assert_file_contains "$D/.stm-manifest" "./items/clock.lua"
ship_ok_as two
run_stm --dir "$D" --no-reload install item:two
assert_status 0
printf -- '-- newer\n' >>"$BUNDLES/ok/item.lua"
run_stm --dir "$D" --no-reload --force install item:ok
assert_status 0
run_stm --dir "$D" --no-reload uninstall item:two
assert_status 0
run_stm --dir "$D" verify
assert_status 0
assert_contains "$STM_OUT" "items_generated.lua items/stm/ plugins/stm/"
# Control: the user's own item file is still watched.
printf -- '-- edited\n' >>"$D/items/clock.lua"
run_stm --dir "$D" verify
assert_status 1
assert_contains "$STM_OUT" "items/clock.lua"
done_it

it "owned backup holds the loader and item files; restore brings them back (V12)"
run_stm --dir "$D" --no-reload backup itemsnap
assert_status 0
files=$(cat "$D/.stm-backups/itemsnap/files.list")
assert_contains "$files" "items_generated.lua"
assert_contains "$files" "items/stm/ok.lua"
assert_contains "$files" "plugins/stm/ok.sh"
assert_not_contains "$files" "items/clock.lua"
cp "$D/items_generated.lua" "$SANDBOX/loader.before"
run_stm --dir "$D" --no-reload uninstall item:ok
assert_status 0
run_stm --dir "$D" --no-reload restore itemsnap
assert_status 0
assert_files_equal "$BUNDLES/ok/item.lua" "$D/items/stm/ok.lua"
assert_files_equal "$BUNDLES/ok/plugin.sh" "$D/plugins/stm/ok.sh"
assert_eq "-rwxr-xr-x" "$(stat -f %Sp "$D/plugins/stm/ok.sh")" "restored plugin mode"
assert_files_equal "$SANDBOX/loader.before" "$D/items_generated.lua"
done_it

it "restore never writes through a symlinked plugins/stm"
mv "$D/plugins/stm" "$SANDBOX/plugins-away"
rm "$SANDBOX/plugins-away/ok.sh"
ln -s "$SANDBOX/plugins-away" "$D/plugins/stm"
run_stm --dir "$D" --no-reload restore itemsnap
assert_contains "$STM_ERR" "symlink"
assert_file_absent "$SANDBOX/plugins-away/ok.sh" "restore wrote through a symlinked plugins/stm"
rm "$D/plugins/stm"
mv "$SANDBOX/plugins-away" "$D/plugins/stm"
done_it

it "[output] may not target items_generated.lua"
printf '[output]\nlua = "items_generated.lua"\n' >"$CFG"
before=$(snapshot)
run_stm --dir "$D" --palette-dir "$P" --no-reload apply nord
assert_status 2
assert_contains "$STM_ERR" "items_generated.lua"
assert_eq "$before" "$(snapshot)" "nothing written"
rm -f "$CFG"
done_it

# --- doctor ------------------------------------------------------------------

# Fresh config + empty ledger for the doctor cases.
DC="$SANDBOX/doccfg"
make_lua_config "$DC"
rm -f "$ITEM_LEDGER"
printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/tailscale"
chmod 755 "$SANDBOX/tailscale"

it "doctor: no items installed, no Items section and no wiring warning (V18)"
run_stm --dir "$DC" doctor
assert_status 0
assert_not_contains "$STM_OUT" "Items"
assert_not_contains "$STM_OUT" "items_generated"
done_it

it "doctor: key coverage ignores stm item code and backups (V23, B1)"
STM_ROOT="$REPO_ROOT" run_stm --dir "$DC" --no-reload install item:tailscale
assert_status 0
run_stm --dir "$DC" --no-reload backup withitems
assert_status 0
printf 'require("items_generated")\n' >>"$DC/init.lua"
STM_TAILSCALE="$SANDBOX/tailscale" STM_ROOT="$REPO_ROOT" run_stm --dir "$DC" doctor
assert_status 0
assert_not_contains "$STM_OUT" "USED BUT MISSING"
assert_not_contains "$STM_OUT" "popup "
done_it

it "doctor: lists installed items, loader and wiring; tailscale CLI note (V18, I.ts)"
assert_contains "$STM_OUT" "Items"
assert_contains "$STM_OUT" "tailscale"
assert_contains "$STM_OUT" "0.2.0"
assert_contains "$STM_OUT" "init.lua"
assert_contains "$STM_OUT" "$SANDBOX/tailscale"
STM_TAILSCALE="$SANDBOX/no-such-cli" STM_ROOT="$REPO_ROOT" run_stm --dir "$DC" doctor
assert_status 0
assert_contains "$STM_OUT" "not found"
done_it

it "doctor: installed item without require(\"items_generated\") is a problem (V18)"
make_lua_config "$DC"
STM_TAILSCALE="$SANDBOX/tailscale" STM_ROOT="$REPO_ROOT" run_stm --dir "$DC" doctor
assert_status 1
assert_contains "$STM_OUT" "NOT WIRED"
assert_contains "$STM_OUT" 'require("items_generated")'
printf 'require("items_generated")\n' >>"$DC/init.lua"
done_it

it "doctor: bundle changed since install -> update available, still OK"
T_ROOT="$SANDBOX/troot"
mkdir -p "$T_ROOT/bundles/items"
cp -R "$REPO_ROOT/bundles/items/tailscale" "$T_ROOT/bundles/items/tailscale"
ln -s "$REPO_ROOT/palettes" "$T_ROOT/palettes"
printf -- '-- newer\n' >>"$T_ROOT/bundles/items/tailscale/item.lua"
STM_TAILSCALE="$SANDBOX/tailscale" STM_ROOT="$T_ROOT" run_stm --dir "$DC" doctor
assert_status 0
assert_contains "$STM_OUT" "update available"
assert_contains "$STM_OUT" "install --force item:tailscale"
done_it

it "doctor: installed item no longer bundled is reported, still OK"
rm -rf "$T_ROOT/bundles/items/tailscale"
STM_TAILSCALE="$SANDBOX/tailscale" STM_ROOT="$T_ROOT" run_stm --dir "$DC" doctor
assert_status 0
assert_contains "$STM_OUT" "no longer bundled"
done_it

it "doctor: ledger row without files, or files without a row, is a problem"
mv "$DC/items/stm/tailscale.lua" "$SANDBOX/ts.lua.away"
STM_TAILSCALE="$SANDBOX/tailscale" STM_ROOT="$REPO_ROOT" run_stm --dir "$DC" doctor
assert_status 1
assert_contains "$STM_OUT" "MISSING"
assert_contains "$STM_OUT" "items/stm/tailscale.lua"
mv "$SANDBOX/ts.lua.away" "$DC/items/stm/tailscale.lua"
printf 'return function() end\n' >"$DC/items/stm/stray.lua"
STM_TAILSCALE="$SANDBOX/tailscale" STM_ROOT="$REPO_ROOT" run_stm --dir "$DC" doctor
assert_status 1
assert_contains "$STM_OUT" "items/stm/stray.lua"
assert_contains "$STM_OUT" "not in the item ledger"
rm -f "$DC/items/stm/stray.lua"
done_it

it "help lists the item: forms (I.cli)"
run_stm help
assert_status 0
assert_contains "$STM_OUT" "install item:<name>"
assert_contains "$STM_OUT" "uninstall item:<name>"
assert_contains "$STM_OUT" "lint item:<name>"
done_it

finish
