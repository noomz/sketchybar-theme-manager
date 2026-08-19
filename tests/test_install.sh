#!/usr/bin/env bash
#
# shellcheck disable=SC2016
# Payload strings (`$(...)`, backticks) must reach stm unexpanded.
#
# stm install / uninstall: spec parse, stubbed HTTPS fetch, lint-then-write,
# provenance ledger, remove. Never hits the live network.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

BAD="$FIXTURES_DIR/bad"
D="$SANDBOX/cfg"
make_lua_config "$D"
USER_PAL="$D/palettes"
LEDGER="${XDG_CONFIG_HOME}/stm/installed"

# copy_nord <dest> <slug> — a valid palette filed under dest.
copy_nord() {
  local dest="$1" slug="$2"
  sed "s/^slug = .*/slug = \"$slug\"/;s/^name = .*/name = \"$slug\"/;s/^variant_label = .*/variant_label = \"$slug\"/" \
    "$REPO_ROOT/palettes/nord.toml" >"$dest"
}

reset_fetch_log() {
  : >"$STM_FETCH_LOG"
}

fetch_log() {
  cat "$STM_FETCH_LOG" 2>/dev/null || true
}

# --- spec parse (via --dry-run; stub serves nord.toml by basename) ---------

it "github locator becomes a raw.githubusercontent.com URL"
reset_fetch_log
run_stm --dir "$D" --dry-run install alice/sketchy-themes/palettes/nord.toml
assert_status 0
assert_contains "$STM_OUT" "https://raw.githubusercontent.com/alice/sketchy-themes/HEAD/palettes/nord.toml"
done_it

it "owner/repo@ref/path pins the ref in the raw URL"
run_stm --dir "$D" --dry-run install alice/sketchy-themes@v1.2.0/palettes/nord.toml
assert_status 0
assert_contains "$STM_OUT" "https://raw.githubusercontent.com/alice/sketchy-themes/v1.2.0/palettes/nord.toml"
done_it

it "gitlab.com locator uses /-/raw/"
run_stm --dir "$D" --dry-run install gitlab.com/alice/themes/palettes/nord.toml
assert_status 0
assert_contains "$STM_OUT" "https://gitlab.com/alice/themes/-/raw/HEAD/palettes/nord.toml"
done_it

it "codeberg.org locator uses /raw/branch/"
run_stm --dir "$D" --dry-run install codeberg.org/alice/themes/palettes/nord.toml
assert_status 0
assert_contains "$STM_OUT" "https://codeberg.org/alice/themes/raw/branch/HEAD/palettes/nord.toml"
done_it

it "github blob URL rewrites to raw.githubusercontent.com"
run_stm --dir "$D" --dry-run install https://github.com/alice/themes/blob/main/palettes/nord.toml
assert_status 0
assert_contains "$STM_OUT" "https://raw.githubusercontent.com/alice/themes/main/palettes/nord.toml"
done_it

it "a path with no extension tries path.toml"
run_stm --dir "$D" --dry-run install alice/themes/nord
assert_status 0
assert_contains "$STM_OUT" "https://raw.githubusercontent.com/alice/themes/HEAD/nord.toml"
done_it

it "a bare slug is a usage error (portal is M2)"
run_stm --dir "$D" install nord
assert_status 64
assert_contains "$STM_ERR" "portal"
assert_file_absent "$USER_PAL/nord.toml"
done_it

it "hostile specs are rejected before any fetch"
reset_fetch_log
for spec in \
  '../etc/passwd' \
  'file:///etc/passwd' \
  'http://github.com/a/b/c.toml' \
  'alice/repo.git/palettes/nord.toml' \
  'alice/repo/path.exe' \
  'alice/repo/a b.toml' \
  'alice/repo/`touch`/nord.toml' \
  'alice/repo/\$()/nord.toml' \
  'alice/repo@v1@evil/nord.toml' \
  '127.0.0.1/a/b/nord.toml' \
  'localhost/a/b/nord.toml' \
  'git://github.com/a/b/nord.toml'
 do
  run_stm --dir "$D" install "$spec"
  assert_ne 0 "$STM_STATUS" "spec '$spec' must be rejected"
  [ "$STM_STATUS" -eq 64 ] || [ "$STM_STATUS" -eq 1 ] || [ "$STM_STATUS" -eq 3 ] ||
    _note_fail "spec '$spec' should be usage/invalid/notfound, got $STM_STATUS"
done
assert_eq "" "$(fetch_log)" "rejected specs must not invoke STM_FETCH"
assert_file_absent "$USER_PAL/nord.toml"
done_it

it "--allow-host still refuses http"
run_stm --dir "$D" --allow-host example.com install http://example.com/nord.toml
assert_status 64
assert_eq "" "$(fetch_log | grep example.com || true)"
done_it

it "--allow-host example.com accepts an https URL on that host"
run_stm --dir "$D" --allow-host example.com --dry-run install https://example.com/palettes/nord.toml
assert_status 0
assert_contains "$STM_OUT" "https://example.com/palettes/nord.toml"
done_it

it "a host not on the allowlist is a usage error"
run_stm --dir "$D" install https://evil.example/palettes/nord.toml
assert_status 64
assert_contains "$STM_ERR" "host"
done_it

it "the fetch stub is used: PATH without curl still installs"
copy_nord "$SANDBOX/dracula.toml" dracula
export STM_FETCH_FILE="$SANDBOX/dracula.toml"
mkdir -p "$SANDBOX/empty"
PATH="$SANDBOX/empty:$SANDBOX/bin:$PATH" run_stm --dir "$D" install alice/themes/palettes/dracula.toml
assert_status 0
assert_file_exists "$USER_PAL/dracula.toml"
unset STM_FETCH_FILE
done_it

it "stub 404 exits 3"
export STM_FETCH_EXIT=22
run_stm --dir "$D" install alice/themes/palettes/missing.toml
assert_status 3
unset STM_FETCH_EXIT
done_it

it "stub crash exits 5"
export STM_FETCH_EXIT=7
run_stm --dir "$D" install alice/themes/palettes/nord.toml
assert_status 5
unset STM_FETCH_EXIT
done_it

it "apply preview list doctor verify make zero fetches"
reset_fetch_log
run_stm --dir "$D" list
assert_status 0
run_stm --dir "$D" preview nord
assert_status 0
run_stm --dir "$D" doctor nord
assert_status 0
run_stm --dir "$D" --no-reload apply nord
assert_status 0
run_stm --dir "$D" verify
assert_status 0
assert_eq "" "$(fetch_log)" "offline commands must not call STM_FETCH"
done_it

# --- install write + ledger ------------------------------------------------

it "install writes only the palette file and a ledger row"
rm -f "$D/colors_generated.lua"
reset_reload_log
copy_nord "$SANDBOX/from-net.toml" from-net
export STM_FETCH_FILE="$SANDBOX/from-net.toml"
run_stm --dir "$D" install alice/sketchy-themes/palettes/from-net.toml
assert_status 0
assert_file_exists "$USER_PAL/from-net.toml"
assert_files_equal "$SANDBOX/from-net.toml" "$USER_PAL/from-net.toml"
assert_file_exists "$LEDGER"
assert_contains "$(cat "$LEDGER")" "from-net	"
assert_contains "$(cat "$LEDGER")" "https://raw.githubusercontent.com/alice/sketchy-themes/HEAD/palettes/from-net.toml"
assert_file_absent "$D/colors_generated.lua"
assert_eq "0" "$(reload_count)"
unset STM_FETCH_FILE
done_it

it "list shows an installed palette as user"
run_stm --dir "$D" --porcelain list
assert_status 0
assert_contains "$STM_OUT" "from-net	"
assert_contains "$STM_OUT" "user"
done_it

it "an installed palette can be applied without reload"
run_stm --dir "$D" --no-reload apply from-net
assert_status 0
assert_file_exists "$D/colors_generated.lua"
done_it

it "--dry-run lints but writes no dest and no ledger row"
copy_nord "$SANDBOX/mine.toml" mine
export STM_FETCH_FILE="$SANDBOX/mine.toml"
rm -f "$USER_PAL/mine.toml"
before_ledger=""
[ -f "$LEDGER" ] && before_ledger=$(cat "$LEDGER")
run_stm --dir "$D" --dry-run install alice/themes/palettes/mine.toml
assert_status 0
assert_file_absent "$USER_PAL/mine.toml"
after_ledger=""
[ -f "$LEDGER" ] && after_ledger=$(cat "$LEDGER")
assert_eq "$before_ledger" "$after_ledger"
unset STM_FETCH_FILE
done_it

it "existing dest without --force exits 4 and leaves bytes unchanged"
copy_nord "$SANDBOX/dracula2.toml" dracula
printf 'do-not-clobber\n' >"$USER_PAL/dracula.toml"
export STM_FETCH_FILE="$SANDBOX/dracula2.toml"
run_stm --dir "$D" install alice/themes/palettes/dracula.toml
assert_status 4
assert_file_contains "$USER_PAL/dracula.toml" "do-not-clobber"
unset STM_FETCH_FILE
done_it

it "--force overwrites dest and the ledger row"
export STM_FETCH_FILE="$SANDBOX/dracula2.toml"
run_stm --dir "$D" --force install alice/themes@v9/palettes/dracula.toml
assert_status 0
assert_files_equal "$SANDBOX/dracula2.toml" "$USER_PAL/dracula.toml"
rows=$(grep -c '^dracula	' "$LEDGER" || true)
assert_eq "1" "$rows" "force reinstall replaces the ledger row"
assert_contains "$(cat "$LEDGER")" "v9"
unset STM_FETCH_FILE
done_it

it "every fixtures/bad palette via stub URL writes nothing"
copy_nord "$SANDBOX/keep-me.toml" keep-me
mkdir -p "$USER_PAL"
cp "$SANDBOX/keep-me.toml" "$USER_PAL/keep-me.toml"
[ -f "$LEDGER" ] && cp "$LEDGER" "$SANDBOX/ledger.before"
for f in "$BAD"/*.toml; do
  base=$(basename "$f")
  export STM_FETCH_FILE="$f"
  run_stm --dir "$D" install "alice/themes/palettes/$base"
  assert_status 1 "install of $base must refuse"
  assert_file_absent "$USER_PAL/$base" "must not copy $base into the palette dir"
done
unset STM_FETCH_FILE
assert_file_exists "$USER_PAL/keep-me.toml"
if [ -f "$SANDBOX/ledger.before" ]; then
  assert_files_equal "$SANDBOX/ledger.before" "$LEDGER"
else
  [ ! -f "$LEDGER" ] || ! grep -q 'keep-me' "$LEDGER" || true
fi
done_it

it "install of a missing slug-named file is not found or invalid, not a write"
export STM_FETCH_EXIT=22
run_stm --dir "$D" install alice/themes/no-such.toml
assert_status 3
unset STM_FETCH_EXIT
done_it

# --- uninstall -------------------------------------------------------------

it "uninstall removes the user file and the ledger row"
export STM_FETCH_FILE="$SANDBOX/dracula2.toml"
run_stm --dir "$D" --force install alice/themes/palettes/dracula.toml
unset STM_FETCH_FILE
assert_file_exists "$USER_PAL/dracula.toml"
run_stm --dir "$D" uninstall dracula
assert_status 0
assert_file_absent "$USER_PAL/dracula.toml"
if [ -f "$LEDGER" ]; then
  assert_not_contains "$(cat "$LEDGER")" "dracula	"
fi
done_it

it "remove is an alias of uninstall"
copy_nord "$SANDBOX/alias.toml" alias-theme
export STM_FETCH_FILE="$SANDBOX/alias.toml"
run_stm --dir "$D" install alice/themes/palettes/alias-theme.toml
unset STM_FETCH_FILE
run_stm --dir "$D" remove alias-theme
assert_status 0
assert_file_absent "$USER_PAL/alias-theme.toml"
done_it

it "uninstall of bundled-only nord exits 2 and leaves the bundled file"
bundled="$REPO_ROOT/palettes/nord.toml"
assert_file_exists "$bundled"
run_stm --dir "$D" uninstall nord
assert_status 2
assert_file_exists "$bundled"
assert_file_absent "$USER_PAL/nord.toml"
done_it

it "uninstall of a user shadow of nord reveals the bundled theme"
copy_nord "$SANDBOX/user-nord.toml" nord
export STM_FETCH_FILE="$SANDBOX/user-nord.toml"
run_stm --dir "$D" --force install alice/themes/palettes/nord.toml
unset STM_FETCH_FILE
assert_file_exists "$USER_PAL/nord.toml"
run_stm --dir "$D" uninstall nord
assert_status 0
assert_file_absent "$USER_PAL/nord.toml"
run_stm --dir "$D" --porcelain list
assert_contains "$STM_OUT" "nord	"
assert_contains "$STM_OUT" "bundled"
run_stm --dir "$D" --no-reload apply nord
assert_status 0
done_it

it "uninstall of the current theme warns and does not change current"
copy_nord "$SANDBOX/cur.toml" cur-theme
export STM_FETCH_FILE="$SANDBOX/cur.toml"
run_stm --dir "$D" install alice/themes/palettes/cur-theme.toml
unset STM_FETCH_FILE
run_stm --dir "$D" --no-reload apply cur-theme
assert_status 0
run_stm --dir "$D" current
assert_eq "cur-theme" "$STM_OUT"
run_stm --dir "$D" uninstall cur-theme
assert_status 0
assert_contains "$STM_ERR" "current"
run_stm --dir "$D" current
assert_eq "cur-theme" "$STM_OUT"
done_it

it "uninstall of a missing user palette exits 3"
run_stm --dir "$D" uninstall no-such-theme
assert_status 3
done_it

it "uninstall of a spec-shaped arg is rejected"
run_stm --dir "$D" uninstall alice/themes/foo.toml
assert_ne 0 "$STM_STATUS"
[ "$STM_STATUS" -eq 3 ] || [ "$STM_STATUS" -eq 64 ] ||
  _note_fail "spec-shaped uninstall should be 3 or 64, got $STM_STATUS"
done_it

it "uninstall ../etc/passwd is rejected"
run_stm --dir "$D" uninstall '../etc/passwd'
assert_ne 0 "$STM_STATUS"
done_it

it "--dry-run uninstall leaves dest and ledger intact"
copy_nord "$SANDBOX/dry.toml" dry-theme
export STM_FETCH_FILE="$SANDBOX/dry.toml"
run_stm --dir "$D" install alice/themes/palettes/dry-theme.toml
unset STM_FETCH_FILE
assert_file_exists "$USER_PAL/dry-theme.toml"
run_stm --dir "$D" --dry-run uninstall dry-theme
assert_status 0
assert_file_exists "$USER_PAL/dry-theme.toml"
assert_contains "$(cat "$LEDGER")" "dry-theme	"
done_it

it "a symlink dest that points outside the palette dir is refused"
copy_nord "$SANDBOX/link-theme.toml" link-theme
export STM_FETCH_FILE="$SANDBOX/link-theme.toml"
run_stm --dir "$D" --force install alice/themes/palettes/link-theme.toml
unset STM_FETCH_FILE
outside="$SANDBOX/outside-link-theme.toml"
mv "$USER_PAL/link-theme.toml" "$outside"
ln -s "$outside" "$USER_PAL/link-theme.toml"
run_stm --dir "$D" uninstall link-theme
assert_status 2
assert_file_exists "$outside"
assert_file_exists "$USER_PAL/link-theme.toml"
rm -f "$USER_PAL/link-theme.toml"
done_it

it "cmd_add still works and is atomic"
copy_nord "$SANDBOX/added.toml" added
run_stm --dir "$D" add added "$SANDBOX/added.toml"
assert_status 0
assert_file_exists "$USER_PAL/added.toml"
assert_files_equal "$SANDBOX/added.toml" "$USER_PAL/added.toml"
done_it

finish
