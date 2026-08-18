#!/usr/bin/env bash
#
# shellcheck disable=SC2016
# Payload strings (`$(...)`, backticks, `\x`) must reach stm unexpanded.
#
# stm lint: bytes gate + allowlist parse + slug rules + capability scan +
# generate-and-grep. Writes nothing to the user bar.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091  # helpers.sh is the shared suite; not always passed as input
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

BAD="$FIXTURES_DIR/bad"
D="$SANDBOX/cfg"
make_lua_config "$D"

# copy_nord <dest> <slug> — a valid palette filed under dest.
copy_nord() {
  local dest="$1" slug="$2"
  sed "s/^slug = .*/slug = \"$slug\"/;s/^name = .*/name = \"$slug\"/;s/^variant_label = .*/variant_label = \"$slug\"/" \
    "$REPO_ROOT/palettes/nord.toml" >"$dest"
}

# snapshot_cfg — list of regular files in the sandbox config dir.
snapshot_cfg() {
  find "$D" -type f 2>/dev/null | sort
}

# --- usage / resolve -------------------------------------------------------

it "lint with no arguments is a usage error"
run_stm lint
assert_status 64
done_it

it "lint of a missing slug exits 3"
run_stm lint missing-slug
assert_status 3
assert_contains "$STM_ERR" "theme not found"
done_it

it "lint of a bundled slug exits 0"
run_stm --dir "$D" lint nord
assert_status 0
done_it

it "lint of a bundled palette file exits 0"
run_stm --dir "$D" lint "$REPO_ROOT/palettes/nord.toml"
assert_status 0
done_it

it "porcelain success is ok<TAB>slug"
run_stm --dir "$D" --porcelain lint nord
assert_status 0
assert_eq "$(printf 'ok\tnord')" "$STM_OUT"
done_it

it "-q suppresses the ok line"
run_stm --dir "$D" -q lint nord
assert_status 0
assert_eq "" "$STM_OUT"
done_it

it "lint writes nothing into the sandbox config dir"
# shellcheck disable=SC2012
before=$(ls -1 "$D" | sort)
run_stm --dir "$D" lint nord
assert_status 0
# shellcheck disable=SC2012
assert_eq "$before" "$(ls -1 "$D" | sort)" "lint must not create files in the config dir"
assert_file_absent "$D/colors_generated.lua"
assert_file_absent "$D/colors.sh"
assert_file_absent "$D/palettes/nord.toml"
assert_file_absent "$HOME/.config/sketchybar/colors_generated.lua"
done_it

# --- hostile corpus --------------------------------------------------------

it "every fixtures/bad palette is refused and writes nothing"
before=$(snapshot_cfg)
for f in "$BAD"/*.toml; do
  [ -f "$f" ] || continue
  run_stm --dir "$D" lint "$f"
  assert_status 1 "lint $(basename "$f") should exit 1"
  assert_file_absent "$D/colors_generated.lua" "lint $(basename "$f") must not write colors_generated.lua"
  assert_file_absent "$D/colors.sh" "lint $(basename "$f") must not write colors.sh"
done
assert_eq "$before" "$(snapshot_cfg)" "lint of a bad palette must not touch the config dir"
done_it

# --- bytes gate ------------------------------------------------------------

it "a shebang payload is refused even if the parser would skip it"
run_stm --dir "$D" lint "$BAD/shebang.toml"
assert_status 1
assert_contains "$STM_ERR" "shebang"
assert_file_absent "$D/colors_generated.lua"
done_it

it "a NUL byte is refused even if it might confuse the parser"
nul="$SANDBOX/nul.toml"
copy_nord "$nul" "nul"
printf '\0' >>"$nul"
run_stm --dir "$D" lint "$nul"
assert_status 1
assert_contains "$STM_ERR" "NUL"
assert_file_absent "$D/colors_generated.lua"
done_it

it "a file larger than 64 KiB is refused"
huge="$SANDBOX/huge.toml"
copy_nord "$huge" "huge"
{
  printf '# '
  dd if=/dev/zero bs=1024 count=70 2>/dev/null | tr '\0' 'x'
  printf '\n'
} >>"$huge"
run_stm --dir "$D" lint "$huge"
assert_status 1
assert_contains "$STM_ERR" "too large"
assert_file_absent "$D/colors_generated.lua"
done_it

# --- capability scan -------------------------------------------------------

it "capability scan refuses a file that would also fail parse and names the line"
run_stm --dir "$D" lint "$BAD/backtick.toml"
assert_status 1
assert_contains "$STM_ERR" "line "
run_stm --dir "$D" lint "$BAD/cmd-injection.toml"
assert_status 1
assert_contains "$STM_ERR" "line "
done_it

it "comment-only os.execute is refused and the line is named"
run_stm --dir "$D" lint "$BAD/comment-os-execute.toml"
assert_status 1
assert_contains "$STM_ERR" "line 1"
assert_contains "$STM_ERR" "os.execute"
assert_file_absent "$D/colors_generated.lua"
done_it

it "comment-only capability tokens are refused and the line is named"
# Each of these would parse today (the parser strips # comments).
# Token on line 1 so the diagnostic can be checked exactly.
for spec in \
  'eval|# eval pwn' \
  'source|# source /tmp/pwn' \
  'cmdsub|# $(touch /tmp/stm-pwn)' \
  'backtick|# `touch /tmp/stm-pwn`' \
  'hexescape|# \\x41' \
  'function|# function pwn()' \
  'require|# require("os")'
do
  slug=${spec%%|*}
  comment=${spec#*|}
  dest="$SANDBOX/${slug}.toml"
  {
    printf '%s\n' "$comment"
    copy_nord /dev/stdout "$slug"
  } >"$dest"
  run_stm --dir "$D" lint "$dest"
  assert_status 1 "comment-only $slug should be refused"
  assert_contains "$STM_ERR" "line 1" "comment-only $slug should name the line"
done
assert_file_absent "$D/colors_generated.lua"
done_it

# --- slug rules ------------------------------------------------------------

it "a file whose declared slug disagrees with its basename is refused"
mismatch="$SANDBOX/other.toml"
copy_nord "$mismatch" "nord"
run_stm --dir "$D" lint "$mismatch"
assert_status 1
assert_contains "$STM_ERR" "declares slug"
assert_file_absent "$D/colors_generated.lua"
done_it

it "an invalid declared slug is refused"
badslug="$SANDBOX/badslug.toml"
copy_nord "$badslug" "Bad Slug"
run_stm --dir "$D" lint "$badslug"
assert_status 1
assert_file_absent "$D/colors_generated.lua"
done_it

# --- generate-and-grep -----------------------------------------------------

it "generate-and-grep is belt-and-braces: the parser already forbids a non-hex colour"
# stm_parse_palette only ever emits 0x[0-9a-f]{8} for colours. A palette that
# survives parse cannot break the hex-only generated shape. lint still runs
# the writers into a private temp dir and greps the result (nord above passed).
run_stm --dir "$D" lint "$BAD/cmd-injection.toml"
assert_status 1
run_stm --dir "$D" lint "$BAD/lua-injection.toml"
assert_status 1
assert_file_absent "$D/colors_generated.lua"
done_it

it "a palette with layout still lints and writes no overlay"
lp="$SANDBOX/layout-pal"
mkdir -p "$lp"
{
  copy_nord /dev/stdout "with-layout"
  printf '\n[layout]\nposition = "top"\nheight = "32"\n'
} >"$lp/with-layout.toml"
run_stm --dir "$D" lint "$lp/with-layout.toml"
assert_status 0
assert_file_absent "$D/layout_generated.lua"
assert_file_absent "$D/layout.sh"
assert_file_absent "$D/colors_generated.lua"
done_it

# --- apply / preview stay off the lint writer path -------------------------

it "preview does not leave lint temp artifacts in the config dir"
p="$SANDBOX/preview-lint"
make_lua_config "$p"
# shellcheck disable=SC2012
before=$(ls -1 "$p" | sort)
run_stm --dir "$p" preview nord
assert_status 0
# shellcheck disable=SC2012
assert_eq "$before" "$(ls -1 "$p" | sort)" "preview must not create files"
assert_eq 0 "$(find "$p" \( -name '.stm-list.*' -o -name '.stm-blk.*' \) | wc -l | tr -d ' ')" \
  "preview must not leave lint temp dirs in the config dir"
assert_file_absent "$p/colors_generated.lua"
done_it

it "apply still writes only what it already writes"
a="$SANDBOX/apply-lint"
make_lua_config "$a"
run_stm --dir "$a" --no-reload -q apply nord
assert_status 0
assert_file_exists "$a/colors_generated.lua"
assert_file_exists "$a/.stm-state"
assert_file_absent "$a/colors.sh"
assert_eq 0 "$(find "$a" \( -name '.stm-list.*' -o -name '.stm-blk.*' \) | wc -l | tr -d ' ')" \
  "apply must not leave lint temp dirs in the config dir"
done_it

finish
