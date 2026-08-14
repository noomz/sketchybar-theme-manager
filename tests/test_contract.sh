#!/usr/bin/env bash
# The v0.2 configuration contract: #rrggbb input, `base =` inheritance,
# [extras], and the [output] / [mapping] / [notes] config sections.

# shellcheck source=tests/helpers.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

P="$SANDBOX/pal"
mkdir -p "$P"
D="$SANDBOX/cfg"
make_lua_config "$D"

# write_config <file> <body...> — a stm.config.toml pointing at the sandbox.
write_config() {
  local f="$1"
  shift
  {
    printf 'sketchybar_dir = "%s"\n' "$D"
    printf 'format = "lua"\n'
    printf '%s\n' "$@"
  } >"$f"
}

# --- #rrggbb ---------------------------------------------------------------

it "accepts #rrggbb and normalises it to 0xff + rgb"
sed 's/^slug = .*/slug = "hexin"/;s/^name = .*/name = "Hex In"/;s/^variant_label = .*/variant_label = "Hex In"/;s|^black = .*|black = "#1a1b26"|' \
  "$REPO_ROOT/palettes/tokyo-night.toml" >"$P/hexin.toml"
run_stm preview --palette-dir "$P" --porcelain hexin
assert_status 0
assert_contains "$STM_OUT" "black	0xff1a1b26"
done_it

it "rejects the ambiguous and lossy hex forms"
reject_hex() {
  local v="$1" frag="$2"
  sed "s|^black = .*|black = \"$v\"|;s/^slug = .*/slug = \"badhex\"/" "$P/hexin.toml" >"$P/badhex.toml"
  run_stm preview --palette-dir "$P" --porcelain badhex
  assert_ne 0 "$STM_STATUS" "\"$v\" should be rejected"
  assert_contains "$STM_ERR" "$frag" "message for \"$v\""
}
reject_hex '#1a1' "3-digit"
reject_hex '#ff1a1b26' "use 0xAARRGGBB for alpha"
reject_hex '#gggggg' "want 0xAARRGGBB or #RRGGBB"
reject_hex '0x1a1b26' "want 0xAARRGGBB or #RRGGBB"
done_it

it "normalises upper-case #RRGGBB too"
sed 's|^black = .*|black = "#1A1B26"|;s/^slug = .*/slug = "upperhex"/' "$P/hexin.toml" >"$P/upperhex.toml"
run_stm preview --palette-dir "$P" --porcelain upperhex
assert_status 0
assert_contains "$STM_OUT" "black	0xff1a1b26"
done_it

# --- base inheritance -------------------------------------------------------

make_child() {
  local slug="$1" base="$2"
  shift 2
  {
    printf 'name = "%s"\n' "$slug"
    printf 'slug = "%s"\n' "$slug"
    printf 'variant_label = "%s"\n' "$slug"
    [ -n "$base" ] && printf 'base = "%s"\n' "$base"
    printf '\n[colors]\n'
    printf '%s\n' "$@"
  } >"$P/$slug.toml"
}

it "a child inherits every key its base defines"
make_child child gruvbox 'red = "#ff0000"'
run_stm preview --palette-dir "$P" --porcelain child
assert_status 0
assert_contains "$STM_OUT" "red	0xffff0000" "the child's own value wins"
assert_contains "$STM_OUT" "black	0xff282828" "inherited from gruvbox"
assert_contains "$STM_OUT" "surface0	0xff3c3836" "dialect keys inherit too"
done_it

it "a two-level chain resolves base-first"
make_child grandchild child 'blue = "#0000ff"'
run_stm preview --palette-dir "$P" --porcelain grandchild
assert_status 0
assert_contains "$STM_OUT" "blue	0xff0000ff" "own"
assert_contains "$STM_OUT" "red	0xffff0000" "from the middle link"
assert_contains "$STM_OUT" "black	0xff282828" "from the root"
done_it

it "required keys are checked on the merged set, not the child alone"
# The child declares one colour; it is only valid because its base supplies
# the rest.
run_stm preview --palette-dir "$P" --porcelain child
assert_status 0
for k in black white red green blue yellow orange magenta grey \
  bg1 bg2 bar_bg bar_border popup_bg popup_border; do
  assert_contains "$STM_OUT" "$k	0x" "merged set is missing $k"
done
done_it

it "a palette with no base still needs every required key"
make_child orphan "" 'red = "#ff0000"'
run_stm preview --palette-dir "$P" --porcelain orphan
assert_status 1
assert_contains "$STM_ERR" "missing required colour key"
done_it

it "detects a circular base chain"
make_child loop-a loop-b 'red = "#ff0000"'
make_child loop-b loop-a 'red = "#ff0000"'
run_stm preview --palette-dir "$P" --porcelain loop-a
assert_status 1
assert_contains "$STM_ERR" "circular base chain"
assert_contains "$STM_ERR" "loop-a"
done_it

it "refuses a palette that inherits from itself"
make_child selfie selfie 'red = "#ff0000"'
run_stm preview --palette-dir "$P" --porcelain selfie
assert_status 1
assert_contains "$STM_ERR" "cannot inherit from itself"
done_it

it "rejects a base that is a path"
make_child trav "../../etc/passwd" 'red = "#ff0000"'
run_stm preview --palette-dir "$P" --porcelain trav
assert_status 1
assert_contains "$STM_ERR" "invalid base"
done_it

it "reports a base that does not exist"
make_child nobase no-such-palette 'red = "#ff0000"'
run_stm preview --palette-dir "$P" --porcelain nobase
assert_status 3
assert_contains "$STM_ERR" "inherits from"
done_it

it "stops a base chain that is too deep"
prev=""
i=0
while [ "$i" -lt 12 ]; do
  make_child "deep$i" "$prev" 'red = "#ff0000"'
  prev="deep$i"
  i=$((i + 1))
done
run_stm preview --palette-dir "$P" --porcelain deep11
assert_status 1
assert_contains "$STM_ERR" "deeper than"
done_it

# --- extras ------------------------------------------------------------------

it "[extras] keys reach the output like any other colour"
{
  sed 's/^slug = .*/slug = "withextras"/;s/^name = .*/name = "With Extras"/;s/^variant_label = .*/variant_label = "With Extras"/' \
    "$REPO_ROOT/palettes/nord.toml"
  printf '\n[extras]\nmy_accent = "#00ff00"\n'
} >"$P/withextras.toml"
run_stm preview --palette-dir "$P" --porcelain withextras
assert_status 0
assert_contains "$STM_OUT" "my_accent	0xff00ff00"
done_it

it "a key defined in both [colors] and [extras] is an error"
{
  printf 'name = "Dup"\nslug = "dupsec"\nvariant_label = "Dup"\n\n[colors]\n'
  printf 'black = "#000000"\n'
  printf '\n[extras]\nblack = "#111111"\n'
} >"$P/dupsec.toml"
run_stm preview --palette-dir "$P" --porcelain dupsec
assert_status 1
assert_contains "$STM_ERR" "duplicate colour key"
done_it

it "rejects a table that is neither [colors] nor [extras]"
printf 'name = "Odd"\nslug = "oddsec"\nvariant_label = "Odd"\n\n[palette]\nblack = "#000000"\n' >"$P/oddsec.toml"
run_stm preview --palette-dir "$P" --porcelain oddsec
assert_status 1
assert_contains "$STM_ERR" "unsupported table"
done_it

# --- [output] ----------------------------------------------------------------

it "[output] renames the destination file"
cfg="$SANDBOX/out.toml"
write_config "$cfg" '' '[output]' 'lua = "theme_colors.lua"'
run_stm --config "$cfg" --no-reload apply nord
assert_status 0
assert_file_exists "$D/theme_colors.lua"
assert_contains "$STM_OUT" "theme_colors.lua"
done_it

it "[output] refuses anything that is not a bare filename"
reject_output() {
  local v="$1" frag="$2"
  cfg="$SANDBOX/badout.toml"
  write_config "$cfg" '' '[output]' "lua = \"$v\""
  run_stm --config "$cfg" --no-reload apply nord
  assert_status 2 "[output] lua = \"$v\" should be refused"
  assert_contains "$STM_ERR" "$frag" "message for \"$v\""
}
reject_output "../evil.lua" "bare filename"
reject_output "/etc/passwd" "bare filename"
reject_output "sub/dir.lua" "bare filename"
reject_output ".stm-state" "may not start with a dot"
reject_output 'a;id.lua' "invalid characters"
# shellcheck disable=SC2016  # the literal $( must reach the config file unexpanded
reject_output '$(id).lua' "invalid characters"
done_it

it "[output] may not target the user's own colors.lua"
cfg="$SANDBOX/ownfile.toml"
write_config "$cfg" '' '[output]' 'lua = "colors.lua"'
run_stm --config "$cfg" --no-reload apply nord
assert_status 2
assert_contains "$STM_ERR" "stm must not own that file"
assert_files_equal "$FIXTURES_DIR/lua-config/colors.lua" "$D/colors.lua"
done_it

# --- [mapping] ---------------------------------------------------------------

it "[mapping] aliases one key name to another"
cfg="$SANDBOX/map.toml"
write_config "$cfg" '' '[mapping]' 'gray = "grey"'
run_stm --config "$cfg" --no-reload -q apply tokyo-night
assert_status 0
assert_file_contains "$D/colors_generated.lua" "gray = 0xff565f89,"
assert_file_contains "$D/colors_generated.lua" "grey = 0xff565f89," "the canonical key survives too"
done_it

it "[mapping] pins a key to a literal colour"
cfg="$SANDBOX/maplit.toml"
write_config "$cfg" '' '[mapping]' 'brand = "#ff0000"' 'brand2 = "0xccabcdef"'
run_stm --config "$cfg" --no-reload -q apply tokyo-night
assert_status 0
assert_file_contains "$D/colors_generated.lua" "brand = 0xffff0000,"
assert_file_contains "$D/colors_generated.lua" "brand2 = 0xccabcdef,"
done_it

it "[mapping] may override a palette key"
cfg="$SANDBOX/mapover.toml"
write_config "$cfg" '' '[mapping]' 'black = "#ffffff"'
run_stm --config "$cfg" --no-reload -q apply tokyo-night
assert_status 0
assert_file_contains "$D/colors_generated.lua" "black = 0xffffffff,"
assert_file_not_contains "$D/colors_generated.lua" "black = 0xff1a1b26,"
done_it

it "[mapping] fails loudly on an unresolvable right-hand side"
cfg="$SANDBOX/mapbad.toml"
write_config "$cfg" '' '[mapping]' 'foo = "no_such_key"'
run_stm --config "$cfg" --no-reload apply nord
assert_status 2
assert_contains "$STM_ERR" "no colour named"
done_it

it "[mapping] rejects a malformed literal"
cfg="$SANDBOX/maplitbad.toml"
write_config "$cfg" '' '[mapping]' 'foo = "0xzz"'
run_stm --config "$cfg" --no-reload apply nord
assert_status 2
assert_contains "$STM_ERR" "not a valid colour"
done_it

it "[mapping] rejects an invalid left-hand name"
cfg="$SANDBOX/mapkeybad.toml"
write_config "$cfg" '' '[mapping]' 'Foo_Bar = "grey"'
run_stm --config "$cfg" --no-reload apply nord
assert_status 2
assert_contains "$STM_ERR" "invalid key"
done_it

it "[mapping] reaches the bash writer too"
b="$SANDBOX/mapbash"
make_bash_config "$b"
cfg="$SANDBOX/mapbash.toml"
{
  printf 'sketchybar_dir = "%s"\n' "$b"
  printf 'format = "bash"\n\n'
  printf '[mapping]\naccent = "#00ff00"\n'
} >"$cfg"
run_stm --config "$cfg" --no-reload -q apply nord
assert_status 0
assert_file_contains "$b/colors.sh" "export ACCENT=0xff00ff00" \
  "a mapped key should swap the matching shell variable"
done_it

# --- [notes] -----------------------------------------------------------------

it "[notes] surfaces a per-theme note on apply --verbose"
cfg="$SANDBOX/notes.toml"
write_config "$cfg" '' '[notes]' 'tokyo-night = "Matches Ghostty TokyoNight Night"'
run_stm --config "$cfg" --no-reload apply tokyo-night
assert_status 0
assert_contains "$STM_OUT" "note: Matches Ghostty TokyoNight Night"
done_it

it "a theme with no note prints none"
run_stm --config "$cfg" --no-reload apply nord
assert_status 0
assert_not_contains "$STM_OUT" "note:"
done_it

# --- config parsing ----------------------------------------------------------

it "root keys are still read when sections follow them"
cfg="$SANDBOX/rootafter.toml"
write_config "$cfg" 'default_theme = "nord"' '' '[output]' 'lua = "x.lua"'
run_stm --config "$cfg" --no-reload -v apply nord
assert_status 0
assert_contains "$STM_ERR" "sketchybar dir: $D" "root keys must survive the section-aware reader"
done_it

it "an unknown section is ignored, not fatal"
cfg="$SANDBOX/unknown.toml"
write_config "$cfg" '' '[future_feature]' 'whatever = "yes"'
run_stm --config "$cfg" --no-reload -q apply nord
assert_status 0
done_it

finish
