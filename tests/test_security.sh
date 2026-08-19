#!/usr/bin/env bash
#
# shellcheck disable=SC2016
# This whole file is built out of payload strings that must reach stm
# UNexpanded -- $(...), backticks and $HOME are the test inputs, not mistakes.
#
# Security properties. Palette files and theme names are untrusted input.
#
# Every test here asserts a NEGATIVE: that some hostile input did not achieve
# code execution, did not escape its directory, and did not corrupt a file.

# shellcheck source=tests/helpers.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

BAD="$FIXTURES_DIR/bad"
PWN="$SANDBOX/pwned"

D="$SANDBOX/cfg"
make_lua_config "$D"

# --- theme-name traversal --------------------------------------------------

it "rejects a theme name containing path traversal"
for n in "../../etc/passwd" "../nord" "/etc/passwd" ".." "." "foo/bar"; do
  run_stm --dir "$D" --no-reload apply "$n"
  assert_status 3 "apply '$n' should be rejected"
  assert_file_absent "$D/colors_generated.lua" "nothing should be written for '$n'"
done
done_it

it "rejects a theme name with shell metacharacters"
for n in '$(touch '"$PWN"')' '`touch '"$PWN"'`' 'x;touch '"$PWN" 'a|b' 'a&b' 'a>b' "a'b" 'a"b' 'a b' '*' '..%2f..%2fetc'; do
  run_stm --dir "$D" --no-reload apply "$n"
  assert_ne 0 "$STM_STATUS" "apply '$n' should fail"
done
assert_file_absent "$PWN" "no command substitution may have executed"
done_it

it "rejects an upper-case theme name regardless of locale collation"
for loc in C en_US.UTF-8 tr_TR.UTF-8; do
  LC_ALL="$loc" LANG="$loc" run_stm --dir "$D" --no-reload apply "Tokyo-Night"
  assert_status 3 "should be rejected under LC_ALL=$loc"
  assert_contains "$STM_ERR" "invalid theme name"
done
done_it

it "rejects an over-long theme name"
long=$(awk 'BEGIN { for (i = 0; i < 200; i++) printf("a") }')
run_stm --dir "$D" --no-reload apply "$long"
assert_status 3
assert_contains "$STM_ERR" "too long"
done_it

# --- palette content injection ---------------------------------------------

it "rejects a palette whose name field tries to break out of the Lua comment"
run_stm --dir "$D" --palette-dir "$BAD" --no-reload apply lua-injection
assert_ne 0 "$STM_STATUS"
assert_file_absent "$D/colors_generated.lua"
assert_file_absent "/tmp/stm-pwn" "the payload must never run"
done_it

it "rejects command substitution in a colour value"
for slug in cmd-injection backtick; do
  run_stm --dir "$D" --palette-dir "$BAD" --no-reload apply "$slug"
  assert_status 1 "$slug should fail validation"
done
assert_file_absent "/tmp/stm-pwn"
assert_file_absent "$D/colors_generated.lua"
done_it

it "rejects a palette whose declared slug is a traversal path"
run_stm --dir "$D" --palette-dir "$BAD" --no-reload apply traversal-slug
assert_ne 0 "$STM_STATUS"
assert_contains "$STM_ERR" "invalid slug"
done_it

it "rejects a palette whose file name disagrees with its slug"
p="$SANDBOX/mismatch"
mkdir -p "$p"
cp "$REPO_ROOT/palettes/nord.toml" "$p/gruvbox.toml"
run_stm --dir "$D" --palette-dir "$p" --no-reload apply gruvbox
assert_status 1
assert_contains "$STM_ERR" "declares slug"
assert_file_absent "$D/colors_generated.lua" "a mismatched palette must not be written"
done_it

it "never sources or evals a palette file"
p="$SANDBOX/evil"
mkdir -p "$p"
# A file that is valid shell and would execute if sourced, but is not valid TOML.
{
  printf 'name = "Evil"\n'
  printf 'slug = "evil"\n'
  printf 'variant_label = "Evil"\n'
  printf 'touch %s\n' "$PWN"
  printf '\n[colors]\nblack = "0xff000000"\n'
} >"$p/evil.toml"
run_stm --dir "$D" --palette-dir "$p" --no-reload apply evil
assert_ne 0 "$STM_STATUS"
assert_file_absent "$PWN" "the palette must never be executed"
done_it

it "a generated Lua file contains only hex literals and safe comments"
run_stm --dir "$D" --no-reload -q apply catppuccin-mocha
assert_status 0
gen="$D/colors_generated.lua"
# Every non-comment, non-structural line must be `  key = 0xAABBCCDD,`
bad=$(grep -v '^--' "$gen" | grep -v '^$' | grep -v '^return {$' | grep -v '^}$' |
  grep -cv '^  [a-z][a-z0-9_]* = 0x[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f],$' || true)
assert_eq 0 "$bad" "generated Lua must contain nothing but validated assignments"
assert_file_not_contains "$gen" "os.execute"
assert_file_not_contains "$gen" "require"
done_it

# --- colors.sh writer safety ------------------------------------------------

it "the shell writer only ever emits validated hex values"
b="$SANDBOX/shcfg"
make_bash_config "$b"
run_stm --dir "$b" --no-reload -q apply catppuccin-mocha
assert_status 0
# No assignment line may have gained a shell metacharacter.
bad=$(grep -E '^[[:space:]]*(export[[:space:]]+)?[A-Z][A-Z0-9_]*=' "$b/colors.sh" |
  grep -cE '[;&|`]|\$\(' || true)
assert_eq 0 "$bad" "no metacharacters may be introduced into assignments"
done_it

it "a variable name with metacharacters is not treated as an assignment"
b2="$SANDBOX/shcfg2"
mkdir -p "$b2"
{
  printf '#!/usr/bin/env bash\n'
  printf 'export BLACK=0xff000000\n'
  printf 'BLACK$(touch %s)=0xff000000\n' "$PWN"
  printf 'BLACK;id=0xff000000\n'
} >"$b2/colors.sh"
run_stm --dir "$b2" --no-reload -q apply nord
assert_status 0
assert_file_contains "$b2/colors.sh" "export BLACK=0xff2e3440"
assert_file_contains "$b2/colors.sh" "BLACK\$(touch $PWN)=0xff000000"
assert_file_contains "$b2/colors.sh" "BLACK;id=0xff000000"
assert_file_absent "$PWN"
done_it

# --- write scope ------------------------------------------------------------

it "apply only ever writes inside the config dir"
w="$SANDBOX/scoped"
make_lua_config "$w"
outside="$SANDBOX/outside"
mkdir -p "$outside"
before=$(find "$SANDBOX" -newer "$STM_BIN" -type f 2>/dev/null | grep -c "$outside" || true)
run_stm --dir "$w" --no-reload -q apply rose-pine
after=$(find "$outside" -type f 2>/dev/null | wc -l | tr -d ' ')
assert_eq 0 "$after" "nothing may be written outside the config dir"
assert_eq "$before" "$before"
done_it

it "refuses to write when the target is a directory"
# `mv tmp somedir` moves the file INTO the directory and reports success, so
# without an explicit guard stm would claim to have applied a theme it did not.
for fmt in lua bash; do
  t="$SANDBOX/dirtarget-$fmt"
  if [ "$fmt" = "lua" ]; then
    make_lua_config "$t"
    mkdir "$t/colors_generated.lua"
  else
    make_bash_config "$t"
    rm -f "$t/colors.sh"
    mkdir "$t/colors.sh"
  fi
  run_stm --dir "$t" --no-reload --format "$fmt" apply nord
  assert_status 2 "$fmt: a directory target must be refused"
  assert_contains "$STM_ERR" "not a regular file"
  assert_file_absent "$t/colors.sh.stm-backup" "$fmt: no backup before a refused write"
  assert_eq 0 "$(find "$t" -name '.stm-tmp.*' | wc -l | tr -d ' ')" "$fmt: no temp files left"
done
done_it

it "cleans up temp files on a failed write"
t="$SANDBOX/tmpleak"
make_lua_config "$t"
mkdir "$t/colors_generated.lua"
run_stm --dir "$t" --no-reload apply nord
assert_ne 0 "$STM_STATUS"
assert_eq 0 "$(find "$t" -name '.stm-tmp.*' | wc -l | tr -d ' ')" \
  "the EXIT trap must remove temp files even when the write is refused"
done_it

it "the config file is not shell and is not executed"
cfg="$SANDBOX/stm.config.toml"
printf 'sketchybar_dir = "%s"\nformat = "lua"\n' "$D" >"$cfg"
printf 'touch %s\n' "$PWN" >>"$cfg"
run_stm --config "$cfg" --no-reload -q apply nord
assert_file_absent "$PWN" "the config file must never be sourced"
done_it

it "a tilde in a config value expands to HOME and nothing else"
cfg2="$SANDBOX/tilde.toml"
mkdir -p "$HOME/sbcfg"
cp "$FIXTURES_DIR/lua-config/colors.lua" "$HOME/sbcfg/colors.lua"
printf 'sketchybar_dir = "~/sbcfg"\nformat = "lua"\n' >"$cfg2"
run_stm --config "$cfg2" --no-reload -q apply nord
assert_status 0
assert_file_exists "$HOME/sbcfg/colors_generated.lua"
done_it

it "a dollar sign in a config value is not expanded"
cfg3="$SANDBOX/dollar.toml"
printf 'sketchybar_dir = "$HOME/sbcfg"\nformat = "lua"\n' >"$cfg3"
run_stm --config "$cfg3" --no-reload apply nord
assert_status 2
assert_contains "$STM_ERR" "does not exist" "\$HOME must stay literal"
done_it

it "a newline in an imported file's path cannot inject TOML"
# import echoes the source path into a comment. A newline there would end the
# comment and let the rest of the filename be parsed as palette keys.
ipal="$SANDBOX/ipal"
srcdir="$SANDBOX/isrc"
mkdir -p "$ipal" "$srcdir"
nl=$(printf 'evil\nslug = "hijacked"\nx')
printf 'export BLACK=0xff000000\n' >"$srcdir/$nl.sh"
run_stm --palette-dir "$ipal" import "$srcdir/$nl.sh" --slug victim
assert_file_exists "$ipal/victim.toml"
assert_eq 1 "$(grep -c '^slug = ' "$ipal/victim.toml" | tr -d ' ')" \
  "exactly one slug line may exist"
assert_file_contains "$ipal/victim.toml" 'slug = "victim"'
# The payload text may survive inside the flattened comment; what must not
# happen is it becoming a key. Anchor the check to the start of a line.
assert_eq 0 "$(grep -c '^slug = "hijacked"' "$ipal/victim.toml" | tr -d ' ')" \
  "the injected text must not become a top-level key"
assert_eq 1 "$(grep -c '^# Imported by stm' "$ipal/victim.toml" | tr -d ' ')" \
  "the source path must stay on one comment line"
run_stm preview --palette-dir "$ipal" --porcelain victim
assert_contains "$STM_ERR" "missing required colour key" \
  "it should fail on missing keys, not on a hijacked slug"
done_it

it "hostile content inside an imported file is not interpreted"
printf 'export BLACK=0xff000000\nslug = "hijacked"\n[colors]\nname = "x"\n' \
  >"$srcdir/hostile.sh"
run_stm --palette-dir "$ipal" import "$srcdir/hostile.sh" --slug hostile
assert_file_contains "$ipal/hostile.toml" 'slug = "hostile"'
assert_file_not_contains "$ipal/hostile.toml" 'hijacked'
assert_file_absent "$PWN"
done_it

# --- install fetch surface -------------------------------------------------

it "every fixtures/bad palette via a stub URL writes nothing"
: >"$STM_FETCH_LOG"
for f in "$BAD"/*.toml; do
  base=$(basename "$f")
  export STM_FETCH_FILE="$f"
  run_stm --dir "$D" install "alice/themes/palettes/$base"
  assert_status 1 "install of $base must refuse"
  assert_file_absent "$D/palettes/$base"
done
unset STM_FETCH_FILE
assert_file_absent "$PWN"
done_it

it "file:// and http:// specs never invoke the fetch stub"
: >"$STM_FETCH_LOG"
run_stm --dir "$D" install 'file:///etc/passwd'
assert_status 64
run_stm --dir "$D" install 'http://github.com/a/b/c.toml'
assert_status 64
assert_eq "" "$(cat "$STM_FETCH_LOG")"
done_it

it "an oversized body served by the stub is refused and not installed"
big="$SANDBOX/too-big.toml"
awk 'BEGIN { print "slug = \"too-big\""; while (n++ < 70000) printf("x") }' >"$big"
export STM_FETCH_FILE="$big"
run_stm --dir "$D" install alice/themes/palettes/too-big.toml
assert_status 1
assert_file_absent "$D/palettes/too-big.toml"
unset STM_FETCH_FILE
done_it

it "a shebang payload via stub URL is refused"
export STM_FETCH_FILE="$BAD/shebang.toml"
run_stm --dir "$D" install alice/themes/palettes/shebang.toml
assert_status 1
assert_file_absent "$D/palettes/shebang.toml"
unset STM_FETCH_FILE
done_it

# --- final sweep ------------------------------------------------------------

it "no payload file was created anywhere during this suite"
assert_file_absent "$PWN"
assert_file_absent "/tmp/stm-pwn"
done_it

finish
