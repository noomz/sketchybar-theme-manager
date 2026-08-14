#!/usr/bin/env bash
# The Lua writer: colors_generated.lua, and the colors.lua fallback contract.

# shellcheck source=tests/helpers.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

D="$SANDBOX/cfg"
make_lua_config "$D"
GEN="$D/colors_generated.lua"

it "writes colors_generated.lua"
run_stm --dir "$D" --no-reload apply tokyo-night
assert_status 0
assert_file_exists "$GEN"
assert_contains "$STM_OUT" "Applied Tokyo Night (tokyo-night)"
done_it

it "never modifies colors.lua"
assert_files_equal "$FIXTURES_DIR/lua-config/colors.lua" "$D/colors.lua" \
  "colors.lua is the user's own file and must be left alone"
done_it

it "records the theme slug in the generated header"
assert_file_contains "$GEN" "-- theme: tokyo-night"
assert_file_contains "$GEN" "-- name: Tokyo Night"
assert_file_contains "$GEN" "DO NOT EDIT"
done_it

it "emits a Lua module returning a table"
assert_file_contains "$GEN" "return {"
assert_file_contains "$GEN" "}"
done_it

it "emits all 15 keys as unquoted Lua number literals"
required="black white red green blue yellow orange magenta grey bg1 bg2 bar_bg bar_border popup_bg popup_border"
for k in $required; do
  assert_file_contains "$GEN" "  $k = 0x" "missing key $k"
done
assert_file_not_contains "$GEN" '= "0x' "colour values must not be quoted strings"
done_it

it "emits the palette's actual values"
assert_file_contains "$GEN" "black = 0xff1a1b26,"
assert_file_contains "$GEN" "bar_bg = 0x001a1b26,"
assert_file_contains "$GEN" "popup_bg = 0xc01f2335,"
done_it

it "emits keys in sorted order"
keys=$(awk -F' *= *' '/^  [a-z]/ { print $1 }' "$GEN" | tr -d ' ')
sorted=$(printf '%s\n' "$keys" | sort)
assert_eq "$sorted" "$keys"
done_it

it "is idempotent apart from the timestamp"
cp "$GEN" "$SANDBOX/gen1.lua"
run_stm --dir "$D" --no-reload -q apply tokyo-night
assert_status 0
a=$(grep -v '^-- generated:' "$SANDBOX/gen1.lua")
b=$(grep -v '^-- generated:' "$GEN")
assert_eq "$a" "$b" "re-applying the same theme should be a no-op"
done_it

it "switching themes replaces the whole table"
run_stm --dir "$D" --no-reload -q apply nord
assert_status 0
assert_file_contains "$GEN" "black = 0xff2e3440,"
assert_file_not_contains "$GEN" "0xff1a1b26" "no colours from the previous theme should survive"
assert_file_contains "$GEN" "-- theme: nord"
assert_eq 1 "$(grep -c '^-- theme:' "$GEN" | tr -d ' ')" "exactly one theme header"
done_it

it "produces a file the real Lua interpreter can load"
if command -v lua >/dev/null 2>&1; then
  run_stm --dir "$D" --no-reload -q apply tokyo-night
  if (cd "$D" && lua -e '
        local c = require("colors_generated")
        assert(type(c) == "table", "not a table")
        assert(c.black == 0xff1a1b26, "black wrong")
        assert(c.bar_bg == 0x001a1b26, "bar_bg wrong")
      ' >/dev/null 2>&1); then
    :
  else
    _note_fail "lua could not load the generated module"
  fi
else
  # No interpreter available: fall back to a structural check.
  assert_file_contains "$GEN" "return {"
fi
done_it

it "the colors.lua fallback overlays the generated palette"
if command -v lua >/dev/null 2>&1; then
  run_stm --dir "$D" --no-reload -q apply nord
  out=$(cd "$D" && lua -e '
        local c = require("colors")
        io.write(string.format("%08x %08x", c.black, c.bar_border))
      ' 2>&1)
  assert_eq "ff2e3440 ff434c5e" "$out" "require('colors') should reflect the applied theme"
else
  printf '# skipped: lua not installed\n'
fi
done_it

it "colors.lua still works when the generated file is removed"
if command -v lua >/dev/null 2>&1; then
  rm -f "$GEN"
  out=$(cd "$D" && lua -e '
        local c = require("colors")
        io.write(string.format("%08x", c.black))
      ' 2>&1)
  assert_eq "ff181926" "$out" "the user's own defaults must survive deleting colors_generated.lua"
else
  printf '# skipped: lua not installed\n'
fi
done_it

it "--dry-run writes nothing"
d="$SANDBOX/dry"
make_lua_config "$d"
run_stm --dir "$d" --dry-run apply gruvbox
assert_status 0
assert_contains "$STM_OUT" "would apply"
assert_file_absent "$d/colors_generated.lua"
assert_file_absent "$d/.stm-state"
done_it

it "leaves no temp files behind"
leftovers=$(find "$D" -name '.stm-tmp.*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq 0 "$leftovers" "atomic-write temp files must be cleaned up"
done_it

finish
