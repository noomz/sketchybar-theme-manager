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

# --- the bundles shipped in this repo -------------------------------------

it "every bundled item passes lint item:"
n=0
for b in "$REPO_ROOT"/bundles/items/*/; do
  [ -d "$b" ] || continue
  n=$((n + 1))
  name=$(basename "$b")
  STM_ROOT="$REPO_ROOT" run_stm --dir "$D" lint "item:$name"
  assert_status 0 "bundled item:$name must lint clean"
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
  printf '[item.tailscale]\nclick = "app"\n' >"$L/stm.config.toml"
  STM_ROOT="$REPO_ROOT" run_stm --dir "$L" --no-reload install item:tailscale
  assert_status 0
  mkdir -p "$SANDBOX/lua"
  cat >"$SANDBOX/lua/sketchybar.lua" <<'EOF'
local sbar = {}
function sbar.add(kind, name, props)
  print("add " .. kind .. " " .. name .. " " .. tostring(props.position) .. " " .. tostring(props.update_freq))
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
  assert_contains "$lua_out" "STM_GREEN='0xffa6da95'"
  assert_not_contains "$lua_out" "stm: item"
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

finish
