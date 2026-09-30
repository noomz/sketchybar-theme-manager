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

# assert_item_rejected <name> <needle> — install item:<name> fails, names the
# defect, writes nothing and never fetches.
assert_item_rejected() {
  local name="$1" needle="$2" before
  before=$(snapshot)
  reset_fetch_log
  run_stm --dir "$D" --no-reload install "item:$name"
  assert_ne 0 "$STM_STATUS" "install item:$name must fail"
  assert_contains "$STM_ERR" "$needle" "install item:$name must name the defect"
  # V2: item: never reaches the palette spec / theme-name parsers.
  assert_not_contains "$STM_ERR" "install spec" "item:$name leaked into the palette spec parser"
  assert_not_contains "$STM_ERR" "theme name" "item:$name leaked into the palette name check"
  assert_eq "$before" "$(snapshot)" "install item:$name must write nothing"
  assert_eq "" "$(fetch_log)" "install item:$name must not call STM_FETCH"
}

ship_ok_as ok

# --- V3: item name shape, bundled-only -------------------------------------

it "rejects item names that are not a bare bundled name"
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
  'ok;touch '"$PWN" \
  '$(touch '"$PWN"')' \
  '`touch '"$PWN"'`'
 do
  assert_item_rejected "$n" "item"
done
assert_file_absent "$PWN" "no command substitution may have executed"
done_it

it "rejects an item that is not bundled"
assert_item_rejected nope "nope"
done_it

it "ignores item bundles outside the stm release"
mkdir -p "$D/bundles/items" "$XDG_CONFIG_HOME/stm/bundles/items"
cp -R "$OK_BUNDLE" "$D/bundles/items/local"
cp -R "$OK_BUNDLE" "$XDG_CONFIG_HOME/stm/bundles/items/local"
assert_item_rejected local "local"
rm -rf "$D/bundles" "$XDG_CONFIG_HOME/stm/bundles"
done_it

# --- V4: closed manifest, bundle files -------------------------------------

it "rejects hostile manifests and writes nothing"
# `../plugin.sh` must be refused for the `..`, not because it is missing.
cp "$OK_BUNDLE/plugin.sh" "$BUNDLES/plugin.sh"
for c in \
  'unknown-field:homepage' \
  'unknown-section:hooks' \
  'unknown-option-key:bogus' \
  'color-not-required:rosewater' \
  'default-not-in-values:menu' \
  'files-slash:sub/plugin.sh' \
  'files-dotdot:../plugin.sh' \
  'files-absolute:/etc/hosts' \
  'file-missing:extra.sh'
 do
  name=${c%%:*}
  ship_bundle "$BAD_ITEMS/$name" "$name"
  assert_item_rejected "$name" "${c#*:}"
done
rm -f "$BUNDLES/plugin.sh"
done_it

it "rejects a bundle file that is a symlink"
printf '#!/bin/sh\ntouch %s\n' "$PWN" >"$SANDBOX/outside.sh"
ship_ok_as file-symlink
rm "$BUNDLES/file-symlink/plugin.sh"
ln -s "$SANDBOX/outside.sh" "$BUNDLES/file-symlink/plugin.sh"
assert_item_rejected file-symlink "plugin.sh"
done_it

it "rejects a bundle file that is not a regular file"
ship_ok_as file-not-regular
rm "$BUNDLES/file-not-regular/plugin.sh"
mkdir "$BUNDLES/file-not-regular/plugin.sh"
cp "$OK_BUNDLE/plugin.sh" "$BUNDLES/file-not-regular/plugin.sh/plugin.sh"
assert_item_rejected file-not-regular "plugin.sh"
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
