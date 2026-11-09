#!/usr/bin/env bash
#
# shellcheck disable=SC2016
# Payload strings (`$(...)`) must reach stm unexpanded.
#
# Remote item bundles (#17, epic #15): `stm install
# item:[host/]owner/repo@<sha>/<dir> --trust` and `stm update [item:<name>]`.
# Items are code: every remote install is pinned to a full commit SHA, printed
# in full, and written only with --trust. Never hits the live network: a stub
# serves $STUB_ROOT/<url without https://> and logs every URL it is asked for.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

D="$SANDBOX/cfg"
make_lua_config "$D"
ITEM_LEDGER="$XDG_CONFIG_HOME/stm/items"
PAL_LEDGER="$XDG_CONFIG_HOME/stm/installed"
USER_PAL="$D/palettes"
PWN="$SANDBOX/pwned"

# Fake release root: bundled palettes from the repo, one bundled item `ok`.
ROOT="$SANDBOX/root"
BUNDLES="$ROOT/bundles/items"
mkdir -p "$BUNDLES"
ln -s "$REPO_ROOT/palettes" "$ROOT/palettes"
cp -R "$FIXTURES_DIR/items/ok" "$BUNDLES/ok"
export STM_ROOT="$ROOT"

SHA1=0123456789abcdef0123456789abcdef01234567
SHA2=fedcba9876543210fedcba9876543210fedcba98
GH_BASE="raw.githubusercontent.com/alice/bar/$SHA1/widgets/clockx"
SPEC="item:alice/bar@$SHA1/widgets/clockx"
SOURCE="github.com/alice/bar/widgets/clockx"

STUB_ROOT="$SANDBOX/net"
export STUB_ROOT
cat >"$SANDBOX/bin/remote-fetch" <<'STUB'
#!/bin/sh
printf '%s\t%s\n' "$1" "$2" >> "${STM_FETCH_LOG:-/dev/null}"
if [ -n "${STUB_REDIRECT:-}" ]; then
  printf '%s\n' "$STUB_REDIRECT" >"$2"
  exit 23
fi
p="$STUB_ROOT/${1#https://}"
[ -f "$p" ] || exit 22
cp "$p" "$2"
# STUB_HOOK runs once the URL ending in STUB_HOOK_URL is served: it changes
# local state between stm's checks and its commit, as a racing process would.
if [ -n "${STUB_HOOK:-}" ]; then
  case "$1" in
    *"$STUB_HOOK_URL") sh -c "$STUB_HOOK" ;;
  esac
fi
STUB
chmod 755 "$SANDBOX/bin/remote-fetch"
export STM_FETCH="$SANDBOX/bin/remote-fetch"

# make_bundle <dir> <name> [marker] — the ok fixture as <name>, its item.lua
# carrying a marker line so a review or a diff can be told apart.
make_bundle() {
  local dir="$1" name="$2" marker="${3:-v1}"
  rm -rf "$dir"
  mkdir -p "$dir"
  sed "s/^name = \"ok\"/name = \"$name\"/" "$FIXTURES_DIR/items/ok/item.toml" >"$dir/item.toml"
  {
    printf -- '-- marker %s\n' "$marker"
    cat "$FIXTURES_DIR/items/ok/item.lua"
  } >"$dir/item.lua"
  cp "$FIXTURES_DIR/items/ok/plugin.sh" "$dir/plugin.sh"
}

# serve_bundle <url-base> <dir> — publish every file of <dir> under <url-base>.
serve_bundle() {
  local base="$1" dir="$2" f
  rm -rf "${STUB_ROOT:?}/$base"
  mkdir -p "$STUB_ROOT/$base"
  for f in "$dir"/*; do
    cp "$f" "$STUB_ROOT/$base/${f##*/}"
  done
}

# tree_of <dir> — the item tree hash, computed here independently.
tree_of() {
  local dir="$1" f
  for f in item.toml item.lua plugin.sh; do
    [ -f "$dir/$f" ] || continue
    printf '%s  %s\n' "$(shasum -a 256 "$dir/$f" | awk '{print $1}')" "$f"
  done | shasum -a 256 | awk '{print $1}'
}

reset_fetch_log() { : >"$STM_FETCH_LOG"; }
fetch_log() { cat "$STM_FETCH_LOG" 2>/dev/null || true; }
fetch_count() { awk 'END { print NR }' "$STM_FETCH_LOG"; }

snapshot() {
  {
    find "$D" "$XDG_CONFIG_HOME" ! -type f -print
    find "$D" "$XDG_CONFIG_HOME" -type f -exec cksum {} +
  } | LC_ALL=C sort
}

clean_install() {
  rm -rf "$D/items" "$D/plugins" "$D/items_generated.lua" "$ITEM_LEDGER"
}

SRC="$SANDBOX/src/clockx"
make_bundle "$SRC" clockx v1
serve_bundle "$GH_BASE" "$SRC"

# --- grammar -------------------------------------------------------------------

# assert_refused <spec> <needle> — install fails, names the defect, never
# fetches, writes nothing and never reaches the palette parsers.
assert_refused() {
  local spec="$1" needle="$2" before
  before=$(snapshot)
  reset_fetch_log
  run_stm --dir "$D" --no-reload install "$spec" --trust
  assert_ne 0 "$STM_STATUS" "install $spec must fail"
  assert_contains "$STM_ERR" "$needle" "install $spec must name the defect"
  assert_not_contains "$STM_ERR" "install spec" "install $spec leaked into the palette spec parser"
  assert_eq "" "$(fetch_log)" "install $spec must not fetch"
  assert_eq "$before" "$(snapshot)" "install $spec must write nothing"
}

it "grammar: refuses refs that are not a full commit SHA"
assert_refused "item:alice/bar@main/widgets/clockx" "40"
assert_refused "item:alice/bar@v1.0.0/widgets/clockx" "40"
assert_refused "item:alice/bar@0123456/widgets/clockx" "40"
assert_refused "item:alice/bar@${SHA1}0/widgets/clockx" "40"
assert_refused "item:alice/bar@0123456789abcdef0123456789abcdef0123456g/widgets/clockx" "40"
assert_refused "item:alice/bar/widgets/clockx" "@"
assert_refused "item:alice/bar@$SHA1@$SHA2/clockx" "@"
done_it

it "grammar: refuses bad hosts, .git, subgroups and missing parts"
assert_refused "item:example.com/alice/bar@$SHA1/clockx" "host"
assert_refused "item:raw.githubusercontent.com/alice/bar@$SHA1/clockx" "host"
assert_refused "item:gitlab.com/group/sub/bar@$SHA1/clockx" "item:"
assert_refused "item:alice/bar.git@$SHA1/clockx" ".git"
assert_refused "item:alice@$SHA1/clockx" "item:"
assert_refused "item:alice/bar@$SHA1" "bundle"
assert_refused "item:alice/bar@$SHA1/" "item:"
assert_refused "item:-alice/bar@$SHA1/clockx" "owner"
assert_refused "item:alice/.bar@$SHA1/clockx" "repo"
done_it

it "grammar: refuses unsafe bundle paths"
assert_refused "item:alice/bar@$SHA1/widgets/../clockx" "item:"
assert_refused "item:alice/bar@$SHA1/./clockx" "item:"
assert_refused "item:alice/bar@$SHA1/widgets//clockx" "item:"
assert_refused "item:alice/bar@$SHA1/widgets/%2e%2e/clockx" "item:"
assert_refused "item:alice/bar@$SHA1/widgets/clock x" "item:"
assert_refused "item:alice/bar@$SHA1/widgets/$(printf 'a\033b')/clockx" "item:"
assert_refused "item:alice/bar@$SHA1/widgets/Clockx" "item name"
assert_refused "item:alice/bar@$SHA1/widgets/abcdefghijklmnopqrstuvwxyz0123" "too long"
assert_refused 'item:alice/bar@'"$SHA1"'/$(touch '"$PWN"')/clockx' "item:"
assert_file_absent "$PWN" "no command substitution may have executed"
done_it

it "grammar: a remote item may not take a bundled name, even uninstalled"
assert_refused "item:alice/bar@$SHA1/widgets/ok" "bundled"
done_it

it "--allow-host is refused for remote items"
before=$(snapshot)
reset_fetch_log
run_stm --dir "$D" --no-reload --allow-host example.com install "$SPEC" --trust
assert_ne 0 "$STM_STATUS"
assert_contains "$STM_ERR" "--allow-host"
assert_eq "" "$(fetch_log)"
assert_eq "$before" "$(snapshot)"
done_it

it "--trust is refused on every other command"
before=$(snapshot)
reset_fetch_log
run_stm --dir "$D" --no-reload install item:ok --trust
assert_eq 64 "$STM_STATUS" "bundled install --trust"
assert_contains "$STM_ERR" "--trust"
run_stm --dir "$D" --no-reload install alice/themes/palettes/nord.toml --trust
assert_eq 64 "$STM_STATUS" "palette install --trust"
run_stm --dir "$D" --no-reload apply nord --trust
assert_eq 64 "$STM_STATUS" "apply --trust"
run_stm --dir "$D" --no-reload update --trust
assert_eq 64 "$STM_STATUS" "update --trust"
assert_eq "" "$(fetch_log)"
assert_eq "$before" "$(snapshot)"
done_it

# --- review ------------------------------------------------------------------

it "without --trust: prints every file, source, SHA and tree, then refuses (exit 4)"
clean_install
before=$(snapshot)
reset_fetch_log
run_stm --dir "$D" --no-reload install "$SPEC"
assert_eq 4 "$STM_STATUS" "no --trust must refuse with EX_EXISTS"
assert_contains "$STM_OUT" "$SOURCE"
assert_contains "$STM_OUT" "$SHA1"
assert_contains "$STM_OUT" "$(tree_of "$SRC")"
assert_contains "$STM_OUT" "==> item.toml"
assert_contains "$STM_OUT" "==> item.lua"
assert_contains "$STM_OUT" "==> plugin.sh"
assert_contains "$STM_OUT" "-- marker v1"
assert_contains "$STM_OUT" 'name = "clockx"'
assert_contains "$STM_OUT" "#!/bin/sh"
assert_contains "$STM_ERR" "--trust"
assert_eq "$before" "$(snapshot)" "nothing written without --trust"
done_it

it "--quiet does not hide the review"
run_stm --dir "$D" --no-reload --quiet install "$SPEC"
assert_eq 4 "$STM_STATUS"
assert_contains "$STM_OUT" "-- marker v1"
done_it

it "--dry-run prints the review, exits 0 and writes nothing"
before=$(snapshot)
run_stm --dir "$D" --no-reload --dry-run install "$SPEC"
assert_eq 0 "$STM_STATUS"
assert_contains "$STM_OUT" "-- marker v1"
assert_contains "$STM_OUT" "would install"
assert_eq "$before" "$(snapshot)"
done_it

# --- per-host URLs -----------------------------------------------------------

it "URLs: GitHub raw at the SHA, manifest first, then exactly its files"
reset_fetch_log
run_stm --dir "$D" --no-reload --dry-run install "$SPEC"
assert_eq 0 "$STM_STATUS"
expected=$(printf 'https://%s/%s\n' "$GH_BASE" item.toml "$GH_BASE" item.lua "$GH_BASE" plugin.sh)
assert_eq "$expected" "$(awk -F'\t' '{ print $1 }' "$STM_FETCH_LOG")"
done_it

it "URLs: explicit github.com, gitlab.com and codeberg.org"
serve_bundle "gitlab.com/alice/bar/-/raw/$SHA1/widgets/clockx" "$SRC"
serve_bundle "codeberg.org/alice/bar/raw/commit/$SHA1/widgets/clockx" "$SRC"
for c in \
  "github.com/alice/bar@$SHA1/widgets/clockx|https://$GH_BASE/item.toml" \
  "gitlab.com/alice/bar@$SHA1/widgets/clockx|https://gitlab.com/alice/bar/-/raw/$SHA1/widgets/clockx/item.toml" \
  "codeberg.org/alice/bar@$SHA1/widgets/clockx|https://codeberg.org/alice/bar/raw/commit/$SHA1/widgets/clockx/item.toml" \
  "GitLab.com/alice/bar@$(printf '%s' "$SHA1" | tr 'a-f' 'A-F')/widgets/clockx|https://gitlab.com/alice/bar/-/raw/$SHA1/widgets/clockx/item.toml"; do
  reset_fetch_log
  run_stm --dir "$D" --no-reload --dry-run install "item:${c%%|*}"
  assert_eq 0 "$STM_STATUS" "${c%%|*}: $STM_ERR"
  assert_eq "${c#*|}" "$(awk -F'\t' 'NR==1 { print $1 }' "$STM_FETCH_LOG")" "${c%%|*}"
done
done_it

it "a manifest without plugin.sh fetches no plugin.sh"
NOPLUG="$SANDBOX/src/noplug"
make_bundle "$NOPLUG" noplug
sed 's/^files = .*/files = ["item.lua"]/' "$NOPLUG/item.toml" >"$NOPLUG/t" && mv "$NOPLUG/t" "$NOPLUG/item.toml"
rm -f "$NOPLUG/plugin.sh"
serve_bundle "raw.githubusercontent.com/alice/bar/$SHA1/noplug" "$NOPLUG"
reset_fetch_log
run_stm --dir "$D" --no-reload --dry-run install "item:alice/bar@$SHA1/noplug"
assert_eq 0 "$STM_STATUS" "$STM_ERR"
assert_eq 2 "$(fetch_count)"
assert_not_contains "$(fetch_log)" "plugin.sh"
done_it

# --- hostile fetches ---------------------------------------------------------

# assert_fetch_refused <needle> — install --trust fails, writes nothing, and
# the hostile bytes never reach stdout.
assert_fetch_refused() {
  local needle="$1" before
  clean_install
  before=$(snapshot)
  reset_fetch_log
  run_stm --dir "$D" --no-reload install "$SPEC" --trust
  assert_ne 0 "$STM_STATUS" "must refuse ($needle)"
  assert_contains "$STM_ERR" "$needle"
  assert_not_contains "$STM_OUT" "==> item.lua" "nothing printed before every file passed"
  assert_eq "$before" "$(snapshot)" "nothing written ($needle)"
}

it "a 3xx is refused for items, never followed"
export STUB_REDIRECT="https://raw.githubusercontent.com/evil/x/$SHA1/clockx/item.toml"
assert_fetch_refused "redirect"
assert_eq 5 "$STM_STATUS"
assert_eq 1 "$(fetch_count)" "the redirect target must never be fetched"
unset STUB_REDIRECT
done_it

it "a missing file is not found (exit 3), no fallback guessed"
rm -f "$STUB_ROOT/$GH_BASE/plugin.sh"
assert_fetch_refused "not found"
assert_eq 3 "$STM_STATUS"
assert_eq 3 "$(fetch_count)"
serve_bundle "$GH_BASE" "$SRC"
done_it

it "size cap: a file over 64 KiB is refused"
awk 'BEGIN { for (i = 0; i < 1100; i++) printf("-- padding line %050d\n", i) }' >>"$STUB_ROOT/$GH_BASE/item.lua"
assert_fetch_refused "too large"
serve_bundle "$GH_BASE" "$SRC"
done_it

it "control bytes: ESC, CR, NUL, DEL and C1 are refused before printing"
for bytes in '\033[2J' 'x\ry' '\000' '\177' '\302\233'; do
  # shellcheck disable=SC2059  # the escapes are the point
  printf "$bytes\n" >>"$STUB_ROOT/$GH_BASE/item.lua"
  assert_fetch_refused "control"
  serve_bundle "$GH_BASE" "$SRC"
done
# shellcheck disable=SC2059
printf 'name = "clockx" # \342\200\256\n' >"$SANDBOX/bidi" && cat "$SANDBOX/bidi" >>"$STUB_ROOT/$GH_BASE/item.lua"
assert_fetch_refused "control"
serve_bundle "$GH_BASE" "$SRC"
done_it

it "glyphs (UTF-8) and a shebang are allowed"
printf -- '-- icon \357\200\227\n' >>"$SRC/item.lua"
serve_bundle "$GH_BASE" "$SRC"
run_stm --dir "$D" --no-reload --dry-run install "$SPEC"
assert_eq 0 "$STM_STATUS" "$STM_ERR"
make_bundle "$SRC" clockx v1
serve_bundle "$GH_BASE" "$SRC"
done_it

it "a manifest name that differs from the bundle dir is refused"
sed 's/^name = .*/name = "other"/' "$SRC/item.toml" >"$STUB_ROOT/$GH_BASE/item.toml"
assert_fetch_refused "does not match"
serve_bundle "$GH_BASE" "$SRC"
done_it

it "a manifest listing an unknown file is refused before any file fetch"
sed 's/^files = .*/files = ["item.lua", "evil.sh"]/' "$SRC/item.toml" >"$STUB_ROOT/$GH_BASE/item.toml"
assert_fetch_refused "unknown files entry"
assert_eq 1 "$(fetch_count)"
serve_bundle "$GH_BASE" "$SRC"
done_it

# --- install -----------------------------------------------------------------

it "--trust installs exactly the reviewed bytes, the manifest and a ledger row"
clean_install
reset_fetch_log
run_stm --dir "$D" --no-reload install "$SPEC" --trust
assert_eq 0 "$STM_STATUS" "$STM_ERR"
assert_contains "$STM_OUT" "-- marker v1"
assert_files_equal "$SRC/item.lua" "$D/items/stm/clockx.lua"
assert_files_equal "$SRC/item.toml" "$D/items/stm/clockx.toml"
assert_files_equal "$SRC/plugin.sh" "$D/plugins/stm/clockx.sh"
assert_eq 755 "$(stat -f %Lp "$D/plugins/stm/clockx.sh")" "plugin mode"
assert_eq 644 "$(stat -f %Lp "$D/items/stm/clockx.lua")" "item mode"
row=$(awk -F'\t' '$1=="clockx" { print $2 "|" $3 "|" $4 }' "$ITEM_LEDGER")
assert_eq "$SOURCE|$(tree_of "$SRC")|$SHA1" "$row"
assert_contains "$(cat "$D/items_generated.lua")" 'stm_item("clockx"'
done_it

it "same source without --force is refused before any fetch"
before=$(snapshot)
reset_fetch_log
run_stm --dir "$D" --no-reload install "$SPEC" --trust
assert_eq 4 "$STM_STATUS"
assert_contains "$STM_ERR" "--force"
assert_eq "" "$(fetch_log)"
assert_eq "$before" "$(snapshot)"
done_it

it "a different source with the same name is refused even with --force"
before=$(snapshot)
reset_fetch_log
run_stm --dir "$D" --no-reload --force install "item:bob/bar@$SHA1/clockx" --trust
assert_eq 4 "$STM_STATUS"
assert_contains "$STM_ERR" "$SOURCE"
assert_contains "$STM_ERR" "uninstall"
assert_eq "" "$(fetch_log)"
assert_eq "$before" "$(snapshot)"
done_it

it "a bundled install over a remote row is refused even with --force"
mkdir -p "$BUNDLES/clockx"
cp "$SRC"/* "$BUNDLES/clockx/"
before=$(snapshot)
run_stm --dir "$D" --no-reload --force install item:clockx
assert_eq 4 "$STM_STATUS"
assert_contains "$STM_ERR" "uninstall"
assert_eq "$before" "$(snapshot)"
rm -rf "$BUNDLES/clockx"
done_it

it "apply renders the remote item from its installed manifest, offline"
mkdir -p "$D"
printf '[item.clockx]\nlabel = "off"\n' >"$D/stm.config.toml"
rm -rf "${STUB_ROOT:?}/raw.githubusercontent.com"
reset_fetch_log
run_stm --dir "$D" --no-reload apply nord
assert_eq 0 "$STM_STATUS" "$STM_ERR"
assert_eq "" "$(fetch_log)" "apply must stay offline"
assert_not_contains "$STM_ERR" "warning"
gen=$(cat "$D/items_generated.lua")
assert_contains "$gen" 'stm_item("clockx"'
assert_contains "$gen" '["label"] = "off"'
printf '[item.clockx]\nlabel = "bogus"\n' >"$D/stm.config.toml"
run_stm --dir "$D" --no-reload apply nord
assert_ne 0 "$STM_STATUS" "option checked against the installed manifest"
rm -f "$D/stm.config.toml"
serve_bundle "$GH_BASE" "$SRC"
done_it

it "doctor: remote item ok, its manifest is not a stray, offline"
reset_fetch_log
run_stm --dir "$D" doctor
assert_contains "$STM_OUT" "clockx"
assert_contains "$(printf '%s\n' "$STM_OUT" | grep clockx)" "ok"
assert_contains "$(printf '%s\n' "$STM_OUT" | grep clockx)" "$SOURCE"
assert_not_contains "$STM_OUT" "stray"
assert_eq "" "$(fetch_log)"
printf -- '-- local edit\n' >>"$D/items/stm/clockx.lua"
run_stm --dir "$D" doctor
assert_contains "$(printf '%s\n' "$STM_OUT" | grep clockx)" "differ"
cp "$SRC/item.lua" "$D/items/stm/clockx.lua"
printf 'x\n' >"$D/items/stm/stray.toml"
run_stm --dir "$D" doctor
assert_contains "$STM_OUT" "items/stm/stray.toml"
rm -f "$D/items/stm/stray.toml"
done_it

it "backup includes the installed manifest"
run_stm --dir "$D" --no-reload backup remote-1
assert_eq 0 "$STM_STATUS" "$STM_ERR"
assert_file_exists "$D/.stm-backups/remote-1/items/stm/clockx.toml"
done_it

it "same source --force --trust: shows a diff, replaces, drops an omitted plugin"
SRC2="$SANDBOX/src/clockx2"
make_bundle "$SRC2" clockx v2
sed 's/^files = .*/files = ["item.lua"]/' "$SRC2/item.toml" >"$SRC2/t" && mv "$SRC2/t" "$SRC2/item.toml"
rm -f "$SRC2/plugin.sh"
GH_BASE2="raw.githubusercontent.com/alice/bar/$SHA2/widgets/clockx"
serve_bundle "$GH_BASE2" "$SRC2"
run_stm --dir "$D" --no-reload --force install "item:alice/bar@$SHA2/widgets/clockx"
assert_eq 4 "$STM_STATUS" "--force is not trust"
assert_contains "$STM_OUT" "-- marker v1"
assert_contains "$STM_OUT" "+-- marker v2"
assert_file_exists "$D/plugins/stm/clockx.sh"
run_stm --dir "$D" --no-reload --force install "item:alice/bar@$SHA2/widgets/clockx" --trust
assert_eq 0 "$STM_STATUS" "$STM_ERR"
assert_contains "$STM_OUT" "+-- marker v2"
assert_files_equal "$SRC2/item.lua" "$D/items/stm/clockx.lua"
assert_file_absent "$D/plugins/stm/clockx.sh" "the old plugin goes when the manifest omits it"
row=$(awk -F'\t' '$1=="clockx" { print $2 "|" $3 "|" $4 }' "$ITEM_LEDGER")
assert_eq "$SOURCE|$(tree_of "$SRC2")|$SHA2" "$row"
done_it

it "a symlinked stm dir is refused before any fetch"
clean_install
mkdir -p "$D/items" "$SANDBOX/elsewhere"
ln -s "$SANDBOX/elsewhere" "$D/items/stm"
reset_fetch_log
run_stm --dir "$D" --no-reload install "$SPEC" --trust
assert_ne 0 "$STM_STATUS"
assert_contains "$STM_ERR" "symlink"
assert_eq "" "$(fetch_log)"
assert_eq "" "$(ls "$SANDBOX/elsewhere")"
rm -rf "$D/items"
done_it

it "a symlinked destination file is refused, nothing replaced"
clean_install
mkdir -p "$D/items/stm"
printf 'keep\n' >"$SANDBOX/target.lua"
ln -s "$SANDBOX/target.lua" "$D/items/stm/clockx.toml"
run_stm --dir "$D" --no-reload install "$SPEC" --trust
assert_ne 0 "$STM_STATUS"
assert_contains "$STM_ERR" "symlink"
assert_eq "keep" "$(cat "$SANDBOX/target.lua")"
assert_file_absent "$D/items/stm/clockx.lua"
assert_file_absent "$ITEM_LEDGER"
rm -rf "$D/items"
done_it

it "uninstall removes the item, its manifest, plugin and ledger row"
clean_install
run_stm --dir "$D" --no-reload install "$SPEC" --trust
assert_eq 0 "$STM_STATUS" "$STM_ERR"
reset_fetch_log
run_stm --dir "$D" --no-reload uninstall item:clockx
assert_eq 0 "$STM_STATUS" "$STM_ERR"
assert_file_absent "$D/items/stm/clockx.lua"
assert_file_absent "$D/items/stm/clockx.toml"
assert_file_absent "$D/plugins/stm/clockx.sh"
assert_file_absent "$ITEM_LEDGER"
assert_not_contains "$(cat "$D/items_generated.lua")" "clockx"
assert_eq "" "$(fetch_log)"
done_it

# --- update ------------------------------------------------------------------

it "update item: same tree is unchanged, exit 0, nothing written"
clean_install
run_stm --dir "$D" --no-reload install "$SPEC" --trust
before=$(snapshot)
reset_fetch_log
run_stm --dir "$D" --no-reload update item:clockx
assert_eq 0 "$STM_STATUS" "$STM_ERR"
assert_contains "$STM_OUT" "unchanged"
assert_contains "$(fetch_log)" "https://$GH_BASE/item.toml"
assert_eq "$before" "$(snapshot)"
done_it

it "update item: a changed tree at the recorded SHA is printed and refused"
printf -- '-- swapped under the same sha\n' >>"$STUB_ROOT/$GH_BASE/item.lua"
before=$(snapshot)
run_stm --dir "$D" --no-reload update item:clockx
assert_ne 0 "$STM_STATUS"
assert_contains "$STM_OUT" "swapped under the same sha"
assert_contains "$STM_ERR" "$SOURCE"
assert_eq "$before" "$(snapshot)"
serve_bundle "$GH_BASE" "$SRC"
done_it

it "update item:<name>: bundled rows are skipped with the reinstall hint"
run_stm --dir "$D" --no-reload install item:ok
assert_eq 0 "$STM_STATUS" "$STM_ERR"
reset_fetch_log
run_stm --dir "$D" --no-reload update item:ok
assert_eq 0 "$STM_STATUS" "$STM_ERR"
assert_contains "$STM_OUT$STM_ERR" "install item:ok --force"
assert_eq "" "$(fetch_log)"
run_stm --dir "$D" --no-reload update item:nope
assert_eq 3 "$STM_STATUS"
done_it

it "update palettes: refresh an untouched file, ledger hash follows"
clean_install
NORD_URL="raw.githubusercontent.com/alice/themes/HEAD/palettes/nord.toml"
mkdir -p "$STUB_ROOT/raw.githubusercontent.com/alice/themes/HEAD/palettes"
cp "$REPO_ROOT/palettes/nord.toml" "$STUB_ROOT/$NORD_URL"
run_stm --dir "$D" --no-reload install alice/themes/palettes/nord.toml
assert_eq 0 "$STM_STATUS" "$STM_ERR"
printf '# upstream v2\n' >>"$STUB_ROOT/$NORD_URL"
state_before=$(cat "$D/.stm-state" 2>/dev/null || true)
reset_reload_log
run_stm --dir "$D" --no-reload update
assert_eq 0 "$STM_STATUS" "$STM_ERR"
assert_files_equal "$STUB_ROOT/$NORD_URL" "$USER_PAL/nord.toml"
assert_eq "$(shasum -a 256 "$USER_PAL/nord.toml" | awk '{print $1}')" \
  "$(awk -F'\t' '$1=="nord" { print $3 }' "$PAL_LEDGER")"
assert_eq "https://$NORD_URL" "$(awk -F'\t' '$1=="nord" { print $2 }' "$PAL_LEDGER")"
assert_eq 0 "$(reload_count)" "update never reloads"
assert_eq "$state_before" "$(cat "$D/.stm-state" 2>/dev/null || true)" "update never applies"
done_it

it "update palettes: a locally edited file is left alone and reported"
printf '# my edit\n' >>"$USER_PAL/nord.toml"
cp "$USER_PAL/nord.toml" "$SANDBOX/nord.mine"
printf '# upstream v3\n' >>"$STUB_ROOT/$NORD_URL"
led=$(cat "$PAL_LEDGER")
run_stm --dir "$D" --no-reload update
assert_eq 0 "$STM_STATUS" "$STM_ERR"
assert_contains "$STM_OUT$STM_ERR" "nord"
assert_contains "$STM_OUT$STM_ERR" "local"
assert_files_equal "$SANDBOX/nord.mine" "$USER_PAL/nord.toml"
assert_eq "$led" "$(cat "$PAL_LEDGER")"
run_stm --dir "$D" --no-reload uninstall nord
done_it

it "update palettes: a pinned commit URL whose bytes changed is an integrity error"
GRU_URL="raw.githubusercontent.com/alice/themes/$SHA1/palettes/gruvbox.toml"
mkdir -p "$STUB_ROOT/raw.githubusercontent.com/alice/themes/$SHA1/palettes"
cp "$REPO_ROOT/palettes/gruvbox.toml" "$STUB_ROOT/$GRU_URL"
run_stm --dir "$D" --no-reload install "alice/themes@$SHA1/palettes/gruvbox.toml"
assert_eq 0 "$STM_STATUS" "$STM_ERR"
run_stm --dir "$D" --no-reload update
assert_eq 0 "$STM_STATUS" "unchanged pinned palette: $STM_ERR"
printf '# swapped\n' >>"$STUB_ROOT/$GRU_URL"
before=$(snapshot)
run_stm --dir "$D" --no-reload update
assert_eq 1 "$STM_STATUS"
assert_contains "$STM_ERR" "integrity"
assert_eq "$before" "$(snapshot)"
done_it

it "update palettes: a custom-host row is skipped with a note, never fetched"
mkdir -p "$(dirname "$PAL_LEDGER")"
cp "$REPO_ROOT/palettes/nord.toml" "$USER_PAL/nord.toml"
printf 'nord\thttps://themes.example.org/nord.toml\t%s\tHEAD\t2026-01-01T00:00:00Z\n' \
  "$(shasum -a 256 "$USER_PAL/nord.toml" | awk '{print $1}')" >>"$PAL_LEDGER"
cp "$REPO_ROOT/palettes/gruvbox.toml" "$STUB_ROOT/$GRU_URL"
reset_fetch_log
run_stm --dir "$D" --no-reload update
assert_eq 0 "$STM_STATUS" "$STM_ERR"
assert_contains "$STM_OUT$STM_ERR" "themes.example.org"
assert_not_contains "$(fetch_log)" "example.org"
done_it

it "update: a hostile ledger row never reaches a URL"
clean_install
mkdir -p "$(dirname "$ITEM_LEDGER")"
printf 'clockx\tgithub.com/alice/bar/../x/clockx\t%s\t%s\t2026-01-01T00:00:00Z\n' "$(tree_of "$SRC")" "$SHA1" >"$ITEM_LEDGER"
reset_fetch_log
run_stm --dir "$D" --no-reload update item:clockx
assert_ne 0 "$STM_STATUS"
assert_eq "" "$(fetch_log)"
clean_install
done_it

it "update rejects a non-item argument"
run_stm --dir "$D" --no-reload update nord
assert_eq 64 "$STM_STATUS"
done_it

# --- review fixes (PR #46) ---------------------------------------------------

ESC=$(printf '\033')
PAL_LEDGER_DIR=$(dirname "$PAL_LEDGER")

# race_install <hook> — fresh remote install whose fetch of plugin.sh (the
# last file) runs <hook>: a process swapping an stm dir after the preflight.
race_install() {
  clean_install
  rm -rf "$PWN"
  mkdir -p "$PWN"
  STUB_HOOK_URL="$GH_BASE/plugin.sh" STUB_HOOK="$1" \
    run_stm --dir "$D" --no-reload install "$SPEC" --trust
}

assert_race_refused() {
  assert_eq 2 "$STM_STATUS" "a dir swapped for a symlink mid-install must be refused: $STM_ERR"
  assert_contains "$STM_ERR" "symlink"
  assert_eq "" "$(find "$PWN" -type f)" "nothing may be written through the symlink"
  assert_file_absent "$ITEM_LEDGER"
  rm -rf "$D/items" "$D/plugins"
}

it "items/stm swapped for a symlink during the fetch: refused, nothing written outside"
race_install "mkdir -p '$D/items' && ln -s '$PWN' '$D/items/stm'"
assert_race_refused
done_it

it "plugins/stm swapped for a symlink during the fetch: refused, nothing written outside"
race_install "mkdir -p '$D/plugins' && ln -s '$PWN' '$D/plugins/stm'"
assert_race_refused
done_it

it "items/ swapped for a symlink during the fetch: refused, nothing written outside"
race_install "mkdir -p '$PWN/stm' && ln -s '$PWN' '$D/items'"
assert_race_refused
done_it

# install_nord — nord installed from a moving (HEAD) URL, then upstream moves.
install_nord() {
  clean_install
  rm -f "$PAL_LEDGER" "$USER_PAL/nord.toml"
  cp "$REPO_ROOT/palettes/nord.toml" "$STUB_ROOT/$NORD_URL"
  run_stm --dir "$D" --no-reload install alice/themes/palettes/nord.toml
  assert_eq 0 "$STM_STATUS" "$STM_ERR"
  printf '# upstream moved\n' >>"$STUB_ROOT/$NORD_URL"
  cp "$USER_PAL/nord.toml" "$SANDBOX/nord.before"
}

it "update --dry-run: reports the palette that would change, writes nothing"
install_nord
before=$(snapshot)
run_stm --dir "$D" --no-reload --dry-run update
assert_eq 0 "$STM_STATUS" "$STM_ERR"
assert_contains "$STM_OUT" "nord: would update"
assert_eq "$before" "$(snapshot)" "dry run must write nothing"
done_it

it "update: an unwritable ledger dir leaves the palette and ledger as they were"
install_nord
led=$(cat "$PAL_LEDGER")
chmod 555 "$PAL_LEDGER_DIR"
run_stm --dir "$D" --no-reload update
chmod 755 "$PAL_LEDGER_DIR"
assert_ne 0 "$STM_STATUS" "a ledger that cannot be written must fail the update"
assert_files_equal "$SANDBOX/nord.before" "$USER_PAL/nord.toml"
assert_eq "$led" "$(cat "$PAL_LEDGER")"
done_it

it "update: a failed ledger commit puts the previous palette bytes back"
install_nord
led=$(cat "$PAL_LEDGER")
chflags uchg "$PAL_LEDGER"
run_stm --dir "$D" --no-reload update
chflags -R nouchg "$PAL_LEDGER_DIR"
rm -f "$PAL_LEDGER_DIR"/.stm-tmp.* "$USER_PAL"/.stm-tmp.*
assert_eq 2 "$STM_STATUS" "a failed ledger commit must fail the update: $STM_ERR"
assert_contains "$STM_ERR" "put back"
assert_files_equal "$SANDBOX/nord.before" "$USER_PAL/nord.toml"
assert_eq "$led" "$(cat "$PAL_LEDGER")"
done_it

it "update: a palette edited while its refresh was fetched is left alone"
install_nord
led=$(cat "$PAL_LEDGER")
STUB_HOOK_URL="$NORD_URL" STUB_HOOK="printf '# edited mid-update\n' >>'$USER_PAL/nord.toml'" \
  run_stm --dir "$D" --no-reload update
assert_eq 0 "$STM_STATUS" "$STM_ERR"
assert_contains "$STM_ERR" "local edits"
assert_contains "$(cat "$USER_PAL/nord.toml")" "# edited mid-update"
assert_not_contains "$(cat "$USER_PAL/nord.toml")" "# upstream moved"
assert_eq "$led" "$(cat "$PAL_LEDGER")"
run_stm --dir "$D" --no-reload uninstall nord
done_it

it "byte gate: raw C1 and other bytes that are not UTF-8 are refused"
for bytes in 'x\233y' '\237' '\300\233' '\377'; do
  # shellcheck disable=SC2059  # the escapes are the point
  printf -- "-- $bytes\n" >>"$STUB_ROOT/$GH_BASE/item.lua"
  assert_fetch_refused "control"
  serve_bundle "$GH_BASE" "$SRC"
done
done_it

it "byte gate: Thai and emoji text in item.lua are allowed"
clean_install
printf -- '-- label \340\270\252\340\270\247\340\270\261\340\270\252\340\270\224\340\270\265 \360\237\214\231\n' >>"$SRC/item.lua"
serve_bundle "$GH_BASE" "$SRC"
run_stm --dir "$D" --no-reload --dry-run install "$SPEC"
assert_eq 0 "$STM_STATUS" "$STM_ERR"
make_bundle "$SRC" clockx v1
serve_bundle "$GH_BASE" "$SRC"
done_it

it "replace review: installed bytes that fail the gate are not printed"
clean_install
serve_bundle "$GH_BASE" "$SRC"
serve_bundle "$GH_BASE2" "$SRC2"
run_stm --dir "$D" --no-reload install "$SPEC" --trust
assert_eq 0 "$STM_STATUS" "$STM_ERR"
printf -- '-- \033[2J tampered\n' >>"$D/items/stm/clockx.lua"
run_stm --dir "$D" --no-reload --force install "item:alice/bar@$SHA2/widgets/clockx"
assert_eq 4 "$STM_STATUS" "$STM_ERR"
assert_not_contains "$STM_OUT$STM_ERR" "$ESC" "installed ESC bytes reached the terminal"
assert_contains "$STM_OUT" "installed/item.lua: not shown"
assert_contains "$STM_OUT" "-- marker v2" "the fetched side is still reviewed in full"
done_it

# hostile_row <col> <value> — the clockx ledger row with one field replaced.
hostile_row() {
  awk -F'\t' -v OFS='\t' -v c="$1" -v v="$2" '$1=="clockx" { $c = v } { print }' \
    "$SANDBOX/ledger.good" >"$ITEM_LEDGER"
}

it "a ledger row with control bytes is never echoed (doctor, update, install, apply)"
clean_install
run_stm --dir "$D" --no-reload install "$SPEC" --trust
assert_eq 0 "$STM_STATUS" "$STM_ERR"
cp "$ITEM_LEDGER" "$SANDBOX/ledger.good"
for spec in "2|$SOURCE${ESC}[2J" "4|${ESC}[2J" "1|clockx${ESC}[2J"; do
  hostile_row "${spec%%|*}" "${spec#*|}"
  run_stm --dir "$D" doctor
  assert_not_contains "$STM_OUT$STM_ERR" "$ESC" "doctor echoed a hostile ledger field (col ${spec%%|*})"
  assert_contains "$STM_OUT" "invalid ledger row"
  assert_ne 0 "$STM_STATUS" "doctor must fail on an invalid ledger row"
  reset_fetch_log
  run_stm --dir "$D" --no-reload update
  assert_not_contains "$STM_OUT$STM_ERR" "$ESC" "update echoed a hostile ledger field (col ${spec%%|*})"
  assert_ne 0 "$STM_STATUS" "update must fail on an invalid ledger row"
  assert_eq "" "$(fetch_log)" "an invalid ledger row must never be fetched"
  run_stm --dir "$D" --no-reload --force install "$SPEC" --trust
  assert_not_contains "$STM_OUT$STM_ERR" "$ESC" "install echoed a hostile ledger field (col ${spec%%|*})"
  run_stm --dir "$D" --no-reload apply nord
  assert_not_contains "$STM_OUT$STM_ERR" "$ESC" "apply echoed a hostile ledger field (col ${spec%%|*})"
done
hostile_row 2 "bundled"
awk -F'\t' -v OFS='\t' -v v="${ESC}[2J" '$1=="clockx" { $4 = v } { print }' "$ITEM_LEDGER" >"$SANDBOX/l" && mv "$SANDBOX/l" "$ITEM_LEDGER"
run_stm --dir "$D" doctor
assert_not_contains "$STM_OUT$STM_ERR" "$ESC" "doctor echoed a bundled row's hostile ref"
assert_contains "$STM_OUT" "invalid ledger row"
cp "$SANDBOX/ledger.good" "$ITEM_LEDGER"
run_stm --dir "$D" --no-reload uninstall item:clockx
assert_eq 0 "$STM_STATUS" "$STM_ERR"
done_it

finish
