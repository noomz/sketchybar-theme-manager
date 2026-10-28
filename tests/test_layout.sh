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
reject item-defaults         "a palette [item_defaults] table"      "unsupported table"
reject layout-lua-injection  "a hostile [layout] value"             "invalid layout value"
reject item-path             "a path-like item name"                ""
reject item-slot-invalid     "an item slot that is not left/right/center" "invalid item slot"
reject item-compact-pinned   "an [items] slot for stm.compact (V63)"  "fixed position"
reject item-compact-row      "an [items] slot for a stm.compact row (V63)" "fixed position"
reject layout-negative       "a negative bar height"                "invalid layout value"
reject itemopt-bad-name       "an [item.<name>] header with a bad name" "unsupported table"
reject itemopt-bad-key        "an upper-case [item.<name>] key"      "invalid item option key"
reject itemopt-lua-injection  "a hostile [item.<name>] value"        "invalid item option value"
reject itemopt-long-value     "an [item.<name>] value over 32 chars" "invalid item option value"
reject itemopt-dup-table      "a duplicate [item.<name>] table"      "duplicate [item.tailscale] table"
reject itemopt-dup-key        "a duplicate [item.<name>] key"        "duplicate item option"
reject itemopt-nested         "a nested [item.<name>.x] table"       "unsupported table"
reject dotted-table           "a dotted table other than [item.<name>]" "unsupported table"
reject itemopt-empty-value    "an empty [item.<name>] value"         "invalid item option value"
reject itemopt-dotted-key     "a dotted key inside [item.<name>]"    "invalid item option key"
reject itemopt-long-name      "an [item.<name>] name over 32 chars"  "too long"

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
assert_file_not_contains "$L" "  item = {" "no idef: omit the item table"
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
assert_not_contains "$STM_OUT" "[item."
done_it

# --- [item.<name>] option values (#19) --------------------------------------

it "a palette may carry [item.<name>] option values (V27, I.palopt)"
make_layout_palette "$P" shaped '[item.tailscale]' 'shape = "pill"' 'icon = "nerd"' \
  '' '[item.my-clock_2]' 'style = "a-b_c"'
run_stm --palette-dir "$P" lint shaped
assert_status 0
run_stm --palette-dir "$P" preview --porcelain shaped
assert_status 0
bad=$(printf '%s\n' "$STM_OUT" | awk -F'\t' 'NF != 2 { n++ } END { print n+0 }')
assert_eq 0 "$bad" "porcelain must stay key<TAB>value colour rows"
done_it

it "export emits [item.<name>] tables (V31)"
run_stm --palette-dir "$P" export shaped
assert_status 0
assert_contains "$STM_OUT" "[item.tailscale]"
assert_contains "$STM_OUT" 'shape = "pill"'
assert_contains "$STM_OUT" 'icon = "nerd"'
assert_contains "$STM_OUT" "[item.my-clock_2]"
assert_contains "$STM_OUT" 'style = "a-b_c"'
done_it

it "export -> add -> export is byte-stable with [item.<name>] (V31)"
P2="$SANDBOX/pal2"
mkdir -p "$P2"
run_stm --palette-dir "$P" --out "$SANDBOX/shaped.toml" export shaped
assert_status 0
run_stm --palette-dir "$P2" add shaped "$SANDBOX/shaped.toml"
assert_status 0
run_stm --palette-dir "$P2" export shaped
assert_status 0
assert_eq "$(cat "$SANDBOX/shaped.toml")" "$STM_OUT" "second export must match the first"
done_it

it "base = merges [item.<name>] per key, child wins (V29)"
make_layout_palette "$P" shape-parent '[item.tailscale]' 'shape = "split"' 'icon = "nerd"' \
  '' '[item.clock]' 'shape = "plain"'
printf '%s\n' 'name = "shape-child"' 'slug = "shape-child"' 'base = "shape-parent"' '' \
  '[colors]' 'red = "0xffff0000"' '' '[item.tailscale]' 'shape = "pill"' >"$P/shape-child.toml"
run_stm --palette-dir "$P" export shape-child
assert_status 0
ts=$(printf '%s\n' "$STM_OUT" | awk '/^\[/ { sec = $0; next } sec == "[item.tailscale]" && NF' | sort | tr '\n' ' ')
assert_eq 'icon = "nerd" shape = "pill" ' "$ts" "child shape wins, parent icon inherited"
assert_contains "$STM_OUT" "[item.clock]"
assert_contains "$STM_OUT" 'shape = "plain"'
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

# --- stm.config.toml [layout] / [item_defaults] ----------------------------
# Bar chrome belongs in the user's config so a colour-only theme switch keeps
# blur and corners. Palettes must not grow a second opacity system or [style].

chrome_cfg() {
  local dir="$1" cfg="$2"
  {
    printf 'sketchybar_dir = "%s"\n' "$dir"
    printf 'format = "lua"\n'
    printf '\n[alpha]\nbar_bg = "60"\n'
    printf '\n[layout]\nblur_radius = "30"\ncorner_radius = "12"\n'
    printf '\n[item_defaults]\ncorner_radius = "5"\n'
  } >"$cfg"
}

G="$SANDBOX/chrome"
make_lua_config "$G"
GCFG="$SANDBOX/chrome.toml"
chrome_cfg "$G" "$GCFG"

it "config [layout] + [item_defaults] write an overlay on a colour-only apply"
run_stm --config "$GCFG" --dir "$G" --no-reload apply nord
assert_status 0
assert_file_exists "$G/layout_generated.lua"
L="$G/layout_generated.lua"
assert_file_contains "$L" "blur_radius = 30"
assert_file_contains "$L" "corner_radius = 12"
assert_file_contains "$L" "  item = {"
assert_file_contains "$L" "    corner_radius = 5,"
assert_file_not_contains "$L" "blur_radius = \"30\"" "integers must be unquoted"
in_bar=$(awk '/^  bar = [{]/,/^  [}],/ { if (index($0, "corner_radius = 5")) print "yes" }' "$L")
assert_eq "" "$in_bar" "item.corner_radius must not live inside bar = {}"
done_it

it "a colour-only theme switch keeps config chrome"
run_stm --config "$GCFG" --dir "$G" --no-reload apply catppuccin-mocha
assert_status 0
L="$G/layout_generated.lua"
assert_file_contains "$L" "-- theme: catppuccin-mocha"
assert_file_contains "$L" "blur_radius = 30"
assert_file_contains "$L" "corner_radius = 12"
assert_file_contains "$L" "    corner_radius = 5,"
assert_file_contains "$G/colors_generated.lua" "-- theme: catppuccin-mocha"
done_it

it "palette [layout] height plus config blur_radius both appear; config blur wins"
make_layout_palette "$P" bothblur '[layout]' 'height = "32"' 'blur_radius = "99"'
B="$SANDBOX/bothblur"
make_lua_config "$B"
BCFG="$SANDBOX/bothblur.toml"
chrome_cfg "$B" "$BCFG"
run_stm --config "$BCFG" --dir "$B" --palette-dir "$P" --no-reload apply bothblur
assert_status 0
L="$B/layout_generated.lua"
assert_file_contains "$L" "height = 32" "palette height stays"
assert_file_contains "$L" "blur_radius = 30" "config blur wins"
assert_file_not_contains "$L" "blur_radius = 99"
done_it

it "preview of a colour-only theme shows config layout"
run_stm --config "$GCFG" preview nord
assert_status 0
assert_contains "$STM_OUT" "blur_radius"
assert_contains "$STM_OUT" "30"
assert_contains "$STM_OUT" "corner_radius"
assert_contains "$STM_OUT" "12"
done_it

it "doctor accepts config [layout] / [item_defaults]"
run_stm --config "$GCFG" --dir "$G" doctor nord
assert_status 0
done_it

it "--reset-layout rebuilds from config chrome"
run_stm --config "$GCFG" --dir "$G" --no-reload --reset-layout -q apply nord
assert_status 0
assert_file_exists "$G/layout_generated.lua" "config [layout] must bring the overlay back"
assert_file_contains "$G/layout_generated.lua" "blur_radius = 30"
done_it

it "bash apply exports ITEM_DEFAULT_CORNER_RADIUS"
b="$SANDBOX/chrome-bash"
make_bash_config "$b"
bcfg="$SANDBOX/chrome-bash.toml"
{
  printf 'sketchybar_dir = "%s"\n' "$b"
  printf 'format = "bash"\n'
  printf '\n[layout]\nblur_radius = "30"\ncorner_radius = "12"\n'
  printf '\n[item_defaults]\ncorner_radius = "5"\n'
} >"$bcfg"
run_stm --config "$bcfg" --dir "$b" --no-reload apply nord
assert_status 0
assert_file_exists "$b/layout.sh"
assert_file_contains "$b/layout.sh" "BAR_BLUR_RADIUS=30"
assert_file_contains "$b/layout.sh" "BAR_CORNER_RADIUS=12"
assert_file_contains "$b/layout.sh" "ITEM_DEFAULT_CORNER_RADIUS=5"
done_it

reject_cfg() {
  local desc="$1" body="$2" frag="$3"
  it "rejects config $desc"
  d="$SANDBOX/cfg-rej"
  make_lua_config "$d"
  bad="$SANDBOX/cfg-rej.toml"
  {
    printf 'sketchybar_dir = "%s"\n' "$d"
    printf 'format = "lua"\n'
    printf '%s\n' "$body"
  } >"$bad"
  run_stm --config "$bad" --dir "$d" --no-reload apply nord
  assert_status 2 "$desc should exit 2"
  assert_contains "$STM_ERR" "$frag"
  done_it
}

reject_cfg "unknown [layout] key" $'[layout]\nwidget_gap = "8"' "[layout]"
reject_cfg "hostile [layout] value" $'[layout]\nblur_radius = "30); os.execute(1)"' "[layout]"
reject_cfg "[item_defaults] foo" $'[item_defaults]\nfoo = "1"' "[item_defaults]"
reject_cfg "[item_defaults] corner_radius = \"-1\"" $'[item_defaults]\ncorner_radius = "-1"' "[item_defaults]"

it "colour-only apply without config layout leaves an existing overlay tagged with the previous theme"
keep="$SANDBOX/keep-overlay"
make_lua_config "$keep"
run_stm --dir "$keep" --palette-dir "$P" --no-reload -q apply compact
assert_file_exists "$keep/layout_generated.lua"
run_stm --dir "$keep" --no-reload -q apply nord
assert_status 0
assert_file_exists "$keep/layout_generated.lua"
assert_file_contains "$keep/layout_generated.lua" "-- theme: compact"
assert_file_contains "$keep/colors_generated.lua" "-- theme: nord"
done_it

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
