#!/usr/bin/env bash
# CLI surface: list, current, init, add, preview, help, reload behaviour.

# shellcheck source=tests/helpers.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

D="$SANDBOX/cfg"
make_lua_config "$D"

# --- help / version --------------------------------------------------------

it "help exits 0 and lists every command"
run_stm help
assert_status 0
for c in list apply current init add preview help; do
  assert_contains "$STM_OUT" "  $c" "usage should document '$c'"
done
done_it

it "-h and --help work"
run_stm -h
assert_status 0
run_stm --help
assert_status 0
done_it

it "no arguments prints usage to stderr and exits 64"
run_stm
assert_status 64
assert_contains "$STM_ERR" "USAGE"
assert_eq "" "$STM_OUT" "usage must go to stderr on the error path"
done_it

it "an unknown command exits 64"
run_stm frobnicate
assert_status 64
assert_contains "$STM_ERR" "unknown command: frobnicate"
done_it

it "an unknown option exits 64"
run_stm --wat list
assert_status 64
assert_contains "$STM_ERR" "unknown option: --wat"
done_it

it "an option missing its value exits 64"
run_stm apply tokyo-night --dir
assert_status 64
assert_contains "$STM_ERR" "--dir needs a value"
done_it

it "version prints the version"
run_stm version
assert_status 0
assert_contains "$STM_OUT" "stm 0."
run_stm -V
assert_status 0
assert_contains "$STM_OUT" "stm 0."
done_it

# --- list ------------------------------------------------------------------

it "list shows all 7 bundled themes"
run_stm --dir "$D" list
assert_status 0
for t in tokyo-night catppuccin-mocha catppuccin-macchiato catppuccin-latte nord gruvbox rose-pine; do
  assert_contains "$STM_OUT" "$t" "list should include $t"
done
done_it

it "list --porcelain is tab separated with 4 fields"
run_stm --dir "$D" list --porcelain
assert_status 0
bad=$(printf '%s\n' "$STM_OUT" | awk -F'\t' 'NF != 4 { n++ } END { print n+0 }')
assert_eq 0 "$bad" "every porcelain row should have 4 tab-separated fields"
assert_contains "$STM_OUT" "tokyo-night	Tokyo Night	bundled"
done_it

it "list marks the active theme"
run_stm --dir "$D" --no-reload -q apply nord
run_stm --dir "$D" list
assert_contains "$STM_OUT" "* nord"
run_stm --dir "$D" list --porcelain
assert_contains "$STM_OUT" "nord	Nord	bundled	1"
assert_contains "$STM_OUT" "tokyo-night	Tokyo Night	bundled	0"
done_it

it "a user palette shadows a bundled one of the same slug"
udir="$SANDBOX/upal"
mkdir -p "$udir"
sed 's/^name = .*/name = "My Nord"/' "$REPO_ROOT/palettes/nord.toml" >"$udir/nord.toml"
STM_PALETTE_DIR="$udir" run_stm --dir "$D" list --porcelain
assert_contains "$STM_OUT" "nord	My Nord	user"
assert_not_contains "$STM_OUT" "nord	Nord	bundled"
done_it

# --- current ---------------------------------------------------------------

it "current reports none before anything is applied"
d="$SANDBOX/fresh"
make_lua_config "$d"
run_stm --dir "$d" current
assert_status 1
assert_contains "$STM_OUT" "none"
done_it

it "current reports the applied slug"
run_stm --dir "$d" --no-reload -q apply gruvbox
run_stm --dir "$d" current
assert_status 0
assert_eq "gruvbox" "$STM_OUT"
done_it

it "current falls back to the generated file when the state file is gone"
rm -f "$d/.stm-state"
run_stm --dir "$d" current
assert_status 0
assert_eq "gruvbox" "$STM_OUT" "the -- theme: header should be the fallback source"
done_it

it "current falls back to the colors.sh header for bash configs"
b="$SANDBOX/cur-bash"
make_bash_config "$b"
run_stm --dir "$b" --no-reload -q apply rose-pine
rm -f "$b/.stm-state"
run_stm --dir "$b" current
assert_status 0
assert_eq "rose-pine" "$STM_OUT"
done_it

# --- preview ---------------------------------------------------------------

it "preview writes nothing"
p="$SANDBOX/preview"
make_lua_config "$p"
# shellcheck disable=SC2012  # sandbox dir, controlled names
before=$(ls -1 "$p" | sort)
run_stm --dir "$p" preview catppuccin-latte
assert_status 0
# shellcheck disable=SC2012  # sandbox dir, controlled names
assert_eq "$before" "$(ls -1 "$p" | sort)" "preview must not create files"
assert_contains "$STM_OUT" "Catppuccin Latte (catppuccin-latte)"
assert_contains "$STM_OUT" "0xffeff1f5"
done_it

it "preview --porcelain is key<TAB>value"
run_stm preview --porcelain nord
assert_status 0
bad=$(printf '%s\n' "$STM_OUT" | awk -F'\t' 'NF != 2 { n++ } END { print n+0 }')
assert_eq 0 "$bad"
assert_contains "$STM_OUT" "black	0xff2e3440"
done_it

it "preview of a missing theme exits 3"
run_stm preview no-such-theme
assert_status 3
assert_contains "$STM_ERR" "theme not found"
done_it

# --- init ------------------------------------------------------------------

it "init scaffolds palettes/ and stm.config.toml"
w="$SANDBOX/work"
mkdir -p "$w"
(cd "$w" && "$STM_BASH" "$STM_BIN" --dir "$D" init >"$SANDBOX/init.out" 2>&1)
assert_file_exists "$w/stm.config.toml"
assert_file_exists "$w/palettes/tokyo-night.toml"
assert_eq 7 "$(find "$w/palettes" -name '*.toml' | wc -l | tr -d ' ')" "all 7 palettes copied"
assert_file_contains "$w/stm.config.toml" "sketchybar_dir ="
assert_file_contains "$w/stm.config.toml" "default_theme ="
done_it

it "init prints the colors_generated.lua wiring snippet for lua configs"
assert_file_contains "$SANDBOX/init.out" 'pcall(require, "colors_generated")'
done_it

it "init is idempotent and never clobbers"
printf 'sketchybar_dir = "/custom"\n' >"$w/stm.config.toml"
printf 'MINE\n' >"$w/palettes/tokyo-night.toml"
(cd "$w" && "$STM_BASH" "$STM_BIN" --dir "$D" init >/dev/null 2>&1)
assert_eq 'sketchybar_dir = "/custom"' "$(cat "$w/stm.config.toml")" "existing config must be kept"
assert_eq "MINE" "$(cat "$w/palettes/tokyo-night.toml")" "existing palettes must be kept"
done_it

# --- add -------------------------------------------------------------------

it "add installs a palette into the user palette dir"
udir="$SANDBOX/addpal"
mkdir -p "$udir"
src="$SANDBOX/my-theme.toml"
sed 's/^slug = .*/slug = "my-theme"/;s/^name = .*/name = "My Theme"/;s/^variant_label = .*/variant_label = "My Theme"/' \
  "$REPO_ROOT/palettes/nord.toml" >"$src"
run_stm --palette-dir "$udir" add my-theme "$src"
assert_status 0
assert_file_exists "$udir/my-theme.toml"
done_it

it "add refuses to overwrite without --force"
run_stm --palette-dir "$udir" add my-theme "$src"
assert_status 4
assert_contains "$STM_ERR" "already exists"
done_it

it "add --force overwrites"
run_stm --palette-dir "$udir" --force add my-theme "$src"
assert_status 0
done_it

it "add rejects a slug that disagrees with the file"
run_stm --palette-dir "$udir" add other-name "$src"
assert_status 1
assert_contains "$STM_ERR" "declares slug"
done_it

it "add rejects an invalid palette"
run_stm --palette-dir "$udir" add missing-key "$FIXTURES_DIR/bad/missing-key.toml"
assert_status 1
assert_file_absent "$udir/missing-key.toml" "an invalid palette must not be installed"
done_it

it "an added palette can then be applied"
d2="$SANDBOX/added"
make_lua_config "$d2"
STM_PALETTE_DIR="$udir" run_stm --dir "$d2" --no-reload apply my-theme
assert_status 0
assert_file_contains "$d2/colors_generated.lua" "-- theme: my-theme"
assert_file_contains "$d2/colors_generated.lua" "black = 0xff2e3440,"
done_it

# --- reload ----------------------------------------------------------------

it "apply runs sketchybar --reload by default"
r="$SANDBOX/reload"
make_lua_config "$r"
reset_reload_log
run_stm --dir "$r" -q apply nord
assert_status 0
assert_eq 1 "$(reload_count)" "sketchybar --reload should have run once"
assert_contains "$(cat "$STM_TEST_RELOAD_LOG")" "--reload"
done_it

it "--no-reload skips it"
reset_reload_log
run_stm --dir "$r" --no-reload -q apply gruvbox
assert_status 0
assert_eq 0 "$(reload_count)" "--reload must not run"
done_it

it "--quiet suppresses normal output but not errors"
run_stm --dir "$r" --no-reload -q apply nord
assert_eq "" "$STM_OUT"
run_stm --dir "$r" --no-reload -q apply nope
assert_status 3
assert_ne "" "$STM_ERR" "errors must still be reported when quiet"
done_it

finish
