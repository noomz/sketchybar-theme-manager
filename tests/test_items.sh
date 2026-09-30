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

finish
