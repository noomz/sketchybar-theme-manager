#!/usr/bin/env bash
# Optional [layout] / [items] palette sections, generated overlay, inheritance.

# shellcheck source=tests/helpers.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

P="$SANDBOX/pal"
mkdir -p "$P"
D="$SANDBOX/cfg"
make_lua_config "$D"

# make_layout_palette <dir> <slug> [extra-toml]
make_layout_palette() {
  local dir="$1" slug="$2"
  shift 2
  mkdir -p "$dir"
  {
    sed "s/^slug = .*/slug = \"$slug\"/;s/^name = .*/name = \"$slug\"/;s/^variant_label = .*/variant_label = \"$slug\"/" \
      "$REPO_ROOT/palettes/nord.toml"
    printf '\n'
    if [ "$#" -gt 0 ]; then
      printf '%s\n' "$@"
    else
      cat <<'EOF'
[layout]
position = "top"
height = "32"
padding_left = "8"
sticky = "on"

[items]
apple = "left"
spaces = "left"
clock = "right"
battery = "right"
EOF
    fi
  } >"$dir/$slug.toml"
}

# --- parse / preview --------------------------------------------------------

it "preview of a colour-only bundled theme is unchanged"
run_stm preview --porcelain nord
assert_status 0
assert_contains "$STM_OUT" "black	0xff2e3440"
assert_not_contains "$STM_OUT" "position"
assert_not_contains "$STM_OUT" "clock"
done_it

it "human preview prints layout and item slots"
make_layout_palette "$P" compact
run_stm --palette-dir "$P" preview compact
assert_status 0
assert_contains "$STM_OUT" "position"
assert_contains "$STM_OUT" "top"
assert_contains "$STM_OUT" "height"
assert_contains "$STM_OUT" "32"
assert_contains "$STM_OUT" "clock"
assert_contains "$STM_OUT" "right"
done_it

it "preview --porcelain stays colours only"
run_stm --palette-dir "$P" preview --porcelain compact
assert_status 0
assert_contains "$STM_OUT" "black	0xff2e3440"
bad=$(printf '%s\n' "$STM_OUT" | awk -F'\t' 'NF != 2 { n++ } END { print n+0 }')
assert_eq 0 "$bad" "porcelain must stay key<TAB>value colour rows"
assert_not_contains "$STM_OUT" "position"
done_it

# --- rejection --------------------------------------------------------------

BAD="$FIXTURES_DIR/bad"

reject() {
  local slug="$1" desc="$2" frag="${3:-}"
  it "rejects $desc"
  run_stm preview --palette-dir "$BAD" --porcelain "$slug"
  assert_ne 0 "$STM_STATUS" "$slug should have been rejected"
  if [ -n "$frag" ]; then
    assert_contains "$STM_ERR" "$frag"
  fi
  done_it
}

reject bad-layout-key        "an unknown [layout] key"              "unsupported layout key"
reject layout-lua-injection  "a hostile [layout] value"             "invalid layout value"
reject item-path             "a path-like item name"                ""
reject item-slot-invalid     "an item slot that is not left/right/center" "invalid item slot"
reject layout-negative       "a negative bar height"                "invalid layout value"

it "a rejected layout palette writes nothing"
d="$SANDBOX/rej"
make_lua_config "$d"
run_stm --dir "$d" --palette-dir "$BAD" --no-reload apply layout-lua-injection
assert_ne 0 "$STM_STATUS"
assert_file_absent "$d/colors_generated.lua"
assert_file_absent "$d/layout_generated.lua"
done_it

# --- apply overlay ----------------------------------------------------------

it "apply writes layout_generated.lua next to colours"
run_stm --dir "$D" --palette-dir "$P" --no-reload apply compact
assert_status 0
assert_file_exists "$D/colors_generated.lua"
assert_file_exists "$D/layout_generated.lua"
done_it

it "never modifies colors.lua or init.lua"
assert_files_equal "$FIXTURES_DIR/lua-config/colors.lua" "$D/colors.lua"
assert_files_equal "$FIXTURES_DIR/lua-config/init.lua" "$D/init.lua"
done_it

it "layout_generated.lua is a module with bar, items, position_of"
L="$D/layout_generated.lua"
assert_file_contains "$L" "DO NOT EDIT"
assert_file_contains "$L" "-- theme: compact"
assert_file_contains "$L" "position = \"top\""
assert_file_contains "$L" "height = 32"
assert_file_not_contains "$L" "height = \"32\"" "integers must be unquoted"
assert_file_contains "$L" 'name = "clock"'
assert_file_contains "$L" "position = \"right\""
assert_file_contains "$L" "clock = \"right\""
done_it

it "a colour-only apply leaves an existing layout file"
run_stm --dir "$D" --no-reload -q apply nord
assert_status 0
assert_file_exists "$D/layout_generated.lua" "colour-only apply must not remove layout"
assert_file_contains "$D/layout_generated.lua" "-- theme: compact"
assert_file_contains "$D/colors_generated.lua" "-- theme: nord"
done_it

it "--reset-layout deletes the generated layout file"
run_stm --dir "$D" --no-reload --reset-layout -q apply nord
assert_status 0
assert_file_absent "$D/layout_generated.lua"
assert_file_exists "$D/colors_generated.lua"
done_it

# --- inheritance ------------------------------------------------------------

it "a child overrides layout keys and inherits the rest"
cat >"$P/child-h.toml" <<'EOF'
name = "child-h"
slug = "child-h"
variant_label = "child-h"
base = "compact"

[colors]
red = "#ff0000"

[layout]
height = "40"
EOF
run_stm --palette-dir "$P" preview child-h
assert_status 0
assert_contains "$STM_OUT" "40"
assert_contains "$STM_OUT" "top" "position inherits from compact"
assert_contains "$STM_OUT" "clock" "items inherit when the child has no [items]"
done_it

it "a child [items] table replaces the parent's items"
cat >"$P/child-i.toml" <<'EOF'
name = "child-i"
slug = "child-i"
variant_label = "child-i"
base = "compact"

[colors]
red = "#ff0000"

[items]
only = "center"
EOF
run_stm --palette-dir "$P" preview child-i
assert_status 0
assert_contains "$STM_OUT" "only"
assert_contains "$STM_OUT" "center"
assert_not_contains "$STM_OUT" "clock"
assert_contains "$STM_OUT" "top" "layout keys still inherit"
done_it

# --- bash writer ------------------------------------------------------------

it "bash apply writes layout.sh and leaves sketchybarrc alone"
b="$SANDBOX/bash"
make_bash_config "$b"
run_stm --dir "$b" --palette-dir "$P" --no-reload apply compact
assert_status 0
assert_file_exists "$b/layout.sh"
assert_file_contains "$b/layout.sh" "BAR_POSITION=top"
assert_file_contains "$b/layout.sh" "BAR_HEIGHT=32"
assert_file_contains "$b/layout.sh" "ITEM_CLOCK=right"
assert_file_contains "$b/layout.sh" "ITEM_ORDER_LEFT="
assert_files_equal "$FIXTURES_DIR/bash-config/sketchybarrc" "$b/sketchybarrc"
done_it

# --- export -----------------------------------------------------------------

it "export includes [layout] and [items]"
run_stm --palette-dir "$P" export compact
assert_status 0
assert_contains "$STM_OUT" "[layout]"
assert_contains "$STM_OUT" "position = \"top\""
assert_contains "$STM_OUT" "height = \"32\""
assert_contains "$STM_OUT" "[items]"
assert_contains "$STM_OUT" "clock = \"right\""
done_it

it "export of a bundled theme has no layout sections"
run_stm export nord
assert_status 0
assert_not_contains "$STM_OUT" "[layout]"
assert_not_contains "$STM_OUT" "[items]"
done_it

# --- templates --------------------------------------------------------------

it "expands {{layout_lua}} and {{bar_position}}"
TPL="$D/stm/templates"
mkdir -p "$TPL"
printf -- '-- pos={{bar_position}}\n{{layout_lua}}\n{{items_lua}}\n' >"$TPL/lua.tpl"
run_stm --dir "$D" --palette-dir "$P" --no-reload -q apply compact
assert_status 0
assert_file_contains "$D/colors_generated.lua" "-- pos=top"
assert_file_contains "$D/colors_generated.lua" "height = 32"
assert_file_contains "$D/colors_generated.lua" 'name = "clock"'
done_it

# --- verify -----------------------------------------------------------------

it "verify ignores layout_generated.lua"
# drop the template so apply uses the built-in writer again
rm -rf "$D/stm"
run_stm --dir "$D" --palette-dir "$P" --no-reload -q apply compact
run_stm --dir "$D" verify
assert_status 0
assert_file_not_contains "$D/.stm-manifest" "layout_generated.lua"
done_it

# --- init -------------------------------------------------------------------

it "init mentions the layout overlay"
w="$SANDBOX/initw"
mkdir -p "$w"
(cd "$w" && "$STM_BASH" "$STM_BIN" --dir "$D" --format lua init >"$SANDBOX/init-layout.out" 2>&1)
assert_file_contains "$SANDBOX/init-layout.out" "layout_generated"
done_it

# --- lua load ---------------------------------------------------------------

it "layout_generated.lua loads in a real Lua interpreter"
if command -v lua >/dev/null 2>&1; then
  run_stm --dir "$D" --palette-dir "$P" --no-reload -q apply compact
  if (cd "$D" && lua -e '
        local l = require("layout_generated")
        assert(type(l) == "table", "not a table")
        assert(l.bar.position == "top", "position")
        assert(l.bar.height == 32, "height must be a number")
        assert(l.position_of.clock == "right", "position_of")
        assert(l.items[1].name == "apple", "item order")
      '); then
    :
  else
    _note_fail "lua rejected layout_generated.lua"
  fi
else
  printf '# skip: no lua interpreter\n'
fi
done_it

finish
