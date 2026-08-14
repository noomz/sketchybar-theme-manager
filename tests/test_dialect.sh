#!/usr/bin/env bash
# The nested Lua dialect, and `stm doctor`.
#
# The nested dialect exists because real configs (NoamFav/sketchybar) do
# `return generated` wholesale rather than merging into their own defaults. If
# stm writes a flat table there, colors.popup.bg and colors.with_alpha become
# nil and the bar breaks at load. These tests hold that line.

# shellcheck source=tests/helpers.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

make_nested_config() {
  local dir="$1"
  mkdir -p "$dir"
  cp "$FIXTURES_DIR/lua-nested/colors.lua" "$dir/colors.lua"
  cp "$FIXTURES_DIR/lua-nested/items.lua" "$dir/items.lua"
}

N="$SANDBOX/nested"
make_nested_config "$N"
F="$SANDBOX/flat"
make_lua_config "$F"

# --- detection -------------------------------------------------------------

it "detects the nested dialect from the user's own colors.lua"
run_stm --dir "$N" --no-reload -v apply tokyo-night
assert_status 0
assert_contains "$STM_ERR" "lua dialect: nested"
assert_file_contains "$N/colors_generated.lua" "-- dialect: nested"
done_it

it "detects the flat dialect when there are no sub-tables"
run_stm --dir "$F" --no-reload -v apply tokyo-night
assert_status 0
assert_contains "$STM_ERR" "lua dialect: flat"
assert_file_contains "$F/colors_generated.lua" "-- dialect: flat"
done_it

it "--lua-dialect overrides detection in both directions"
a="$SANDBOX/force-flat"
make_nested_config "$a"
run_stm --dir "$a" --no-reload --lua-dialect flat apply tokyo-night
assert_status 0
assert_file_contains "$a/colors_generated.lua" "-- dialect: flat"
assert_file_not_contains "$a/colors_generated.lua" "with_alpha"

b="$SANDBOX/force-nested"
make_lua_config "$b"
run_stm --dir "$b" --no-reload --lua-dialect nested apply tokyo-night
assert_status 0
assert_file_contains "$b/colors_generated.lua" "-- dialect: nested"
assert_file_contains "$b/colors_generated.lua" "with_alpha = with_alpha,"
done_it

it "rejects an unknown --lua-dialect"
run_stm --dir "$N" --no-reload --lua-dialect perl apply tokyo-night
assert_status 64
assert_contains "$STM_ERR" "--lua-dialect must be"
done_it

it "STM_LUA_DIALECT is honoured"
c="$SANDBOX/env-dialect"
make_lua_config "$c"
STM_LUA_DIALECT=nested run_stm --dir "$c" --no-reload apply tokyo-night
assert_status 0
assert_file_contains "$c/colors_generated.lua" "-- dialect: nested"
done_it

it "an item definition named bar/popup does not trigger nested detection"
# tests/fixtures/lua-config/init.lua has `bar = { color = ... }`, which is a
# SketchyBar item, not a palette. Only colors.lua decides the dialect.
d="$SANDBOX/itemtrap"
make_lua_config "$d"
assert_file_contains "$d/init.lua" "bar = {" "the fixture must still contain the trap"
run_stm --dir "$d" --no-reload -v apply nord
assert_status 0
assert_contains "$STM_ERR" "lua dialect: flat"
done_it

# --- nested output shape ----------------------------------------------------

it "nested output lifts bar/popup into sub-tables"
gen="$N/colors_generated.lua"
assert_file_contains "$gen" "  bar = {"
assert_file_contains "$gen" "    bg = 0x001a1b26,"
assert_file_contains "$gen" "    border = 0xff292e42,"
assert_file_contains "$gen" "  popup = {"
assert_file_contains "$gen" "    bg = 0xc01f2335,"
# The flat spellings must NOT also appear, or both shapes would be present.
assert_file_not_contains "$gen" "  bar_bg ="
assert_file_not_contains "$gen" "  popup_border ="
done_it

it "nested output emits transparent"
assert_file_contains "$N/colors_generated.lua" "transparent = 0x00000000,"
done_it

it "every palette gets transparent even without declaring it"
run_stm preview --porcelain gruvbox
assert_status 0
assert_contains "$STM_OUT" "transparent	0x00000000"
done_it

it "a palette may override transparent"
p="$SANDBOX/tp"
mkdir -p "$p"
sed 's/^slug = .*/slug = "tinted"/;s/^name = .*/name = "Tinted"/;s/^variant_label = .*/variant_label = "Tinted"/' \
  "$REPO_ROOT/palettes/nord.toml" >"$p/tinted.toml"
printf 'transparent = "0x11223344"\n' >>"$p/tinted.toml"
run_stm preview --palette-dir "$p" --porcelain tinted
assert_status 0
assert_contains "$STM_OUT" "transparent	0x11223344"
done_it

# --- the whole point: it must actually load ---------------------------------

it "the nested output satisfies a config that returns it wholesale"
if command -v lua >/dev/null 2>&1; then
  run_stm --dir "$N" --no-reload -q apply nord
  out=$(cd "$N" && lua -e '
    local c = require("colors")
    assert(type(c) == "table")
    for _, k in ipairs({"black","white","red","green","blue","yellow","orange",
                        "magenta","grey","bg1","bg2","transparent"}) do
      assert(type(c[k]) == "number", "missing " .. k)
    end
    assert(type(c.bar) == "table" and type(c.bar.bg) == "number", "bar.bg")
    assert(type(c.popup) == "table" and type(c.popup.border) == "number", "popup.border")
    assert(type(c.with_alpha) == "function", "with_alpha")
    local v = c.with_alpha(c.white, 0.6)
    assert(v == ((c.white & 0x00ffffff) | (math.floor(0.6 * 255.0) << 24)), "with_alpha math")
    io.write(string.format("%08x %08x", c.popup.bg, c.bar.border))
  ' 2>&1)
  assert_eq "c03b4252 ff434c5e" "$out" "nord popup.bg / bar.border via require('colors')"
else
  printf '# skipped: lua not installed\n'
fi
done_it

it "a consumer module that uses the nested shape still loads"
if command -v lua >/dev/null 2>&1; then
  out=$(cd "$N" && lua -e '
    local i = require("items")
    assert(type(i.popup_bg) == "number", "popup_bg")
    assert(type(i.faded) == "number", "faded")
    io.write("consumer ok")
  ' 2>&1)
  assert_eq "consumer ok" "$out"
else
  printf '# skipped: lua not installed\n'
fi
done_it

it "with_alpha comes from stm, never from the palette"
# A palette cannot contribute Lua: the only function in the output is stm's own
# constant, and no palette text appears outside a comment or a hex literal.
gen="$N/colors_generated.lua"
assert_eq 1 "$(grep -c 'local with_alpha = function' "$gen" | tr -d ' ')"
bad=$(grep -v '^--' "$gen" | grep -cE 'os\.|io\.|require|load|dofile|execute' || true)
assert_eq 0 "$bad" "the generated module must not reference any Lua library"
done_it

# --- doctor -----------------------------------------------------------------

it "doctor reports format, dialect and full coverage on a nested config"
run_stm --dir "$N" doctor tokyo-night
assert_status 0
assert_contains "$STM_OUT" "format           lua (detected)"
assert_contains "$STM_OUT" "lua dialect      nested"
assert_contains "$STM_OUT" "used but missing         (none)"
assert_contains "$STM_OUT" "OK"
done_it

it "doctor folds colors.popup.bg back to the canonical key"
run_stm --dir "$N" doctor tokyo-night
assert_contains "$STM_OUT" "popup_bg"
assert_not_contains "$STM_OUT" "with_alpha"
done_it

it "doctor flags keys the config needs but the palette lacks"
d="$SANDBOX/gap"
mkdir -p "$d"
printf 'local colors = require("colors")\nreturn { a = colors.chartreuse, b = colors.black }\n' >"$d/colors.lua"
run_stm --dir "$d" doctor tokyo-night
assert_status 1
assert_contains "$STM_OUT" "USED BUT MISSING"
assert_contains "$STM_OUT" "chartreuse"
assert_contains "$STM_OUT" "PROBLEMS FOUND"
done_it

it "doctor works on a bash config"
b="$SANDBOX/doc-bash"
make_bash_config "$b"
run_stm --dir "$b" doctor tokyo-night
assert_status 0
assert_contains "$STM_OUT" "format           bash (detected)"
assert_contains "$STM_OUT" "OK"
done_it

it "an unmanaged bash variable is informational, not a failure"
# The fixture has ACCENT and LONGHEX, which no palette provides. In a shell
# config those keep their literal values, so this must not fail the check.
run_stm --dir "$b" doctor tokyo-night
assert_status 0
assert_contains "$STM_OUT" "not managed by stm"
assert_contains "$STM_OUT" "accent"
assert_not_contains "$STM_OUT" "USED BUT MISSING"
done_it

it "the same gap in a Lua config IS a failure"
# There the key resolves to nil and the bar breaks, so the severity differs.
l="$SANDBOX/doc-lua-gap"
mkdir -p "$l"
printf 'local colors = require("colors")\nreturn { a = colors.accent }\n' >"$l/colors.lua"
run_stm --dir "$l" doctor tokyo-night
assert_status 1
assert_contains "$STM_OUT" "USED BUT MISSING"
assert_contains "$STM_OUT" "break the bar"
done_it

it "doctor writes nothing"
d="$SANDBOX/doc-ro"
make_lua_config "$d"
before=$(find "$d" -type f | sort)
run_stm --dir "$d" doctor tokyo-night
assert_eq "$before" "$(find "$d" -type f | sort)" "doctor must be read-only"
done_it

it "doctor fails cleanly on a missing config dir"
run_stm --dir "$SANDBOX/nope" doctor
assert_status 2
assert_contains "$STM_OUT" "does not exist"
done_it

# --- the bundled palette set ------------------------------------------------

it "ships eight palettes including frappe"
run_stm list --porcelain
assert_status 0
for t in tokyo-night catppuccin-mocha catppuccin-macchiato catppuccin-frappe \
  catppuccin-latte nord gruvbox rose-pine; do
  assert_contains "$STM_OUT" "$t" "missing bundled palette $t"
done
assert_eq 8 "$(printf '%s\n' "$STM_OUT" | wc -l | tr -d ' ')"
done_it

it "every palette carries the bash Catppuccin dialect keys"
for slug in tokyo-night catppuccin-mocha catppuccin-frappe nord gruvbox rose-pine; do
  run_stm preview --porcelain "$slug"
  assert_status 0 "$slug should parse"
  for k in rosewater mauve peach text subtext1 overlay0 surface0 base mantle crust; do
    assert_contains "$STM_OUT" "$k	0x" "$slug is missing dialect key $k"
  done
done
done_it

finish
