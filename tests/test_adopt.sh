#!/usr/bin/env bash
# stm adopt: snapshot + import + scrape + Lua wrap + apply.

# shellcheck source=tests/helpers.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

P="$SANDBOX/pal"
mkdir -p "$P"

# ---------------------------------------------------------------------------
# Lua, no overlay
# ---------------------------------------------------------------------------

D="$SANDBOX/plain"
make_plain_lua_config "$D"
cp "$D/colors.lua" "$SANDBOX/plain-colors.lua.orig"

it "adopt creates a pre-adopt snapshot, palette, wrapper and colors_user.lua"
run_stm --dir "$D" --palette-dir "$P" --no-reload adopt
assert_status 0
assert_file_exists "$D/.stm-backups/pre-adopt/manifest.toml"
assert_file_contains "$D/.stm-backups/pre-adopt/manifest.toml" 'scope = "all"'
assert_file_exists "$P/mine.toml"
assert_file_exists "$D/colors_user.lua"
assert_file_exists "$D/colors.lua"
assert_file_contains "$D/colors.lua" 'require("colors_user")'
assert_file_contains "$D/colors.lua" 'pcall(require, "colors_generated")'
assert_files_equal "$SANDBOX/plain-colors.lua.orig" "$D/colors_user.lua"
assert_file_not_contains "$D/colors.lua" "0xff181926" "wrapper is not the original module"
assert_file_exists "$D/colors_generated.lua"
assert_file_exists "$D/.stm-state"
assert_contains "$STM_OUT" "pre-adopt"
assert_contains "$STM_OUT" "wired"
done_it

it "current reports the adopted slug"
run_stm --dir "$D" current
assert_status 0
assert_eq "mine" "$STM_OUT"
done_it

it "require(colors) returns the original table when no generated file exists"
if command -v lua >/dev/null 2>&1; then
  mv "$D/colors_generated.lua" "$SANDBOX/generated.aside"
  out=$(cd "$D" && lua -e '
        local c = require("colors")
        io.write(string.format("%08x", c.black))
      ' 2>&1)
  assert_eq "ff181926" "$out" "wrapper must fall back to colors_user.lua"
  mv "$SANDBOX/generated.aside" "$D/colors_generated.lua"
else
  printf '# skipped: lua not installed\n'
fi
done_it

it "apply nord overlays generated colours onto the required table"
run_stm --dir "$D" --no-reload apply nord
assert_status 0
assert_file_contains "$D/colors_generated.lua" "black = 0xff2e3440,"
assert_files_equal "$SANDBOX/plain-colors.lua.orig" "$D/colors_user.lua" \
  "apply must not edit colors_user.lua"
assert_files_equal "$FIXTURES_DIR/lua-plain/init.lua" "$D/init.lua" \
  "apply must not edit item/init files"
if command -v lua >/dev/null 2>&1; then
  out=$(cd "$D" && lua -e '
        package.loaded.colors = nil
        package.loaded.colors_user = nil
        package.loaded.colors_generated = nil
        local c = require("colors")
        io.write(string.format("%08x", c.black))
      ' 2>&1)
  assert_eq "ff2e3440" "$out" "require(colors) should reflect nord"
else
  printf '# skipped: lua not installed\n'
fi
done_it

it "second adopt is idempotent and does not nest colors_user_user"
cp "$D/colors.lua" "$SANDBOX/wrapper-after-first.lua"
cp "$D/colors_user.lua" "$SANDBOX/user-after-first.lua"
run_stm --dir "$D" --palette-dir "$P" --no-reload --force adopt
assert_status 0
assert_file_absent "$D/colors_user_user.lua"
assert_files_equal "$SANDBOX/user-after-first.lua" "$D/colors_user.lua"
assert_files_equal "$SANDBOX/wrapper-after-first.lua" "$D/colors.lua"
assert_contains "$STM_OUT" "already-wired"
assert_file_not_contains "$D/colors_user.lua" 'require("colors_user")'
done_it

R="$SANDBOX/restore-me"
make_plain_lua_config "$R"
it "restore pre-adopt puts the original colors.lua back"
run_stm --dir "$R" --palette-dir "$P" --no-reload --force adopt restore-me
assert_status 0
assert_file_exists "$R/colors_user.lua"
run_stm --dir "$R" --no-reload restore pre-adopt
assert_status 0
assert_files_equal "$FIXTURES_DIR/lua-plain/colors.lua" "$R/colors.lua"
assert_file_absent "$R/colors_user.lua"
assert_file_absent "$R/colors_generated.lua"
done_it

# ---------------------------------------------------------------------------
# Lua, already wired
# ---------------------------------------------------------------------------

W="$SANDBOX/wired"
make_lua_config "$W"
cp "$W/colors.lua" "$SANDBOX/wired-colors.lua.orig"

it "already-wired adopt snapshots, imports and applies but leaves colors.lua"
run_stm --dir "$W" --palette-dir "$P" --no-reload --force adopt already
assert_status 0
assert_file_exists "$W/.stm-backups/pre-adopt/manifest.toml"
assert_file_exists "$P/already.toml"
assert_files_equal "$SANDBOX/wired-colors.lua.orig" "$W/colors.lua"
assert_file_absent "$W/colors_user.lua"
assert_file_exists "$W/colors_generated.lua"
assert_contains "$STM_OUT" "already-wired"
done_it

# ---------------------------------------------------------------------------
# Missing canonical keys
# ---------------------------------------------------------------------------

M="$SANDBOX/partial"
mkdir -p "$M"
cat >"$M/colors.lua" <<'EOF'
return {
  black = 0xffff0000,
  mauve = 0xffcba6f7,
}
EOF

it "missing keys inherit tokyo-night and adopt exits 0; child values win"
run_stm --dir "$M" --palette-dir "$P" --no-reload adopt partial
assert_status 0
assert_file_contains "$P/partial.toml" 'base = "tokyo-night"'
assert_file_contains "$P/partial.toml" 'black = "0xffff0000"'
assert_file_contains "$P/partial.toml" 'mauve = "0xffcba6f7"'
assert_contains "$STM_OUT" 'base = "tokyo-night"'
run_stm --palette-dir "$P" preview --porcelain partial
assert_status 0
assert_contains "$STM_OUT" "black	0xffff0000" "child key wins"
assert_contains "$STM_OUT" "white	0xffc0caf5" "base supplies the rest"
done_it

# ---------------------------------------------------------------------------
# --dry-run / --no-wire
# ---------------------------------------------------------------------------

DRY="$SANDBOX/dry"
make_plain_lua_config "$DRY"
DP="$SANDBOX/drypal"
mkdir -p "$DP"

it "--dry-run writes nothing"
run_stm --dir "$DRY" --palette-dir "$DP" --dry-run adopt
assert_status 0
assert_contains "$STM_OUT" "would adopt"
assert_file_absent "$DP/mine.toml"
assert_file_absent "$DRY/.stm-backups/pre-adopt"
assert_file_absent "$DRY/colors_user.lua"
assert_file_absent "$DRY/colors_generated.lua"
assert_file_absent "$DRY/stm.config.toml"
assert_files_equal "$FIXTURES_DIR/lua-plain/colors.lua" "$DRY/colors.lua"
done_it

NW="$SANDBOX/nowire"
make_plain_lua_config "$NW"

it "--no-wire writes the palette and leaves colors.lua untouched"
run_stm --dir "$NW" --palette-dir "$P" --no-reload --no-wire adopt nowire
assert_status 0
assert_file_exists "$P/nowire.toml"
assert_files_equal "$FIXTURES_DIR/lua-plain/colors.lua" "$NW/colors.lua"
assert_file_absent "$NW/colors_user.lua"
assert_contains "$STM_OUT" "--no-wire"
done_it

# ---------------------------------------------------------------------------
# Bash
# ---------------------------------------------------------------------------

B="$SANDBOX/bash"
make_bash_config "$B"
# Give the scrape something to find; the stock fixture has height=40 and no items.
cat >"$B/sketchybarrc" <<'EOF'
#!/usr/bin/env bash
CONFIG_DIR="$HOME/.config/sketchybar"
source "$CONFIG_DIR/colors.sh"

sketchybar --bar height=32 position=top
sketchybar --add item clock right
sketchybar --update
EOF
cp "$B/sketchybarrc" "$SANDBOX/bash-rc.orig"
cp "$B/colors.sh" "$SANDBOX/bash-colors.orig"

it "bash adopt snapshots, imports and applies; sketchybarrc is untouched"
run_stm --dir "$B" --palette-dir "$P" --no-reload adopt frombash
assert_status 0
assert_file_exists "$B/.stm-backups/pre-adopt/manifest.toml"
assert_file_exists "$P/frombash.toml"
assert_file_contains "$P/frombash.toml" 'black = "0xff181926"'
assert_files_equal "$SANDBOX/bash-rc.orig" "$B/sketchybarrc"
assert_file_contains "$B/colors.sh" "stm-theme: frombash"
assert_file_contains "$B/colors.sh" "BLACK=0xff181926"
assert_file_absent "$B/colors_user.lua"
assert_file_contains "$P/frombash.toml" "[layout]"
assert_file_contains "$P/frombash.toml" 'height = "32"'
assert_file_contains "$P/frombash.toml" 'clock = "right"'
done_it

# ---------------------------------------------------------------------------
# Hostile / unreadable colors.lua
# ---------------------------------------------------------------------------

H="$SANDBOX/hostile"
mkdir -p "$H"
printf 'return {}\n' >"$H/init.lua"
mkdir "$H/colors.lua"

it "hostile colors.lua: snapshot exists, wrap refused, no half-written wrapper"
run_stm --dir "$H" --format lua --palette-dir "$P" --no-reload adopt hostile
assert_status 0
assert_file_exists "$H/.stm-backups/pre-adopt/manifest.toml"
assert_file_absent "$H/colors_user.lua"
[ -d "$H/colors.lua" ]
assert_eq 0 $? "colors.lua must still be the directory"
assert_contains "$STM_OUT" "not a regular file"
assert_contains "$STM_OUT" "Paste this as colors.lua"
done_it

# ---------------------------------------------------------------------------
# Layout scrape
# ---------------------------------------------------------------------------

L="$SANDBOX/layout"
make_plain_lua_config "$L"
cat >"$L/sketchybarrc" <<'EOF'
#!/usr/bin/env bash
sketchybar --bar height=32 position=top padding_left=8
sketchybar --add item clock right
sketchybar --add item apple left
sketchybar --add bracket ignored left
EOF
cat >"$L/items.lua" <<'EOF'
sbar.add("item", "spaces", { position = function() return "left" end })
sbar.add("item", "battery", { position = pos("battery", "right") })
sbar.add("item", "wifi", { position = "right" })
EOF

it "layout scrape takes bar tokens and item adds; function positions are skipped"
run_stm --dir "$L" --palette-dir "$P" --no-reload --force adopt scraped
assert_status 0
assert_file_contains "$P/scraped.toml" "[layout]"
assert_file_contains "$P/scraped.toml" 'height = "32"'
assert_file_contains "$P/scraped.toml" 'position = "top"'
assert_file_contains "$P/scraped.toml" 'padding_left = "8"'
assert_file_contains "$P/scraped.toml" "[items]"
assert_file_contains "$P/scraped.toml" 'clock = "right"'
assert_file_contains "$P/scraped.toml" 'apple = "left"'
assert_file_contains "$P/scraped.toml" 'wifi = "right"'
assert_file_not_contains "$P/scraped.toml" "spaces"
assert_file_not_contains "$P/scraped.toml" "battery"
assert_file_not_contains "$P/scraped.toml" "ignored"
assert_files_equal "$FIXTURES_DIR/lua-plain/init.lua" "$L/init.lua"
assert_contains "$STM_OUT" "pos("
done_it

it "help documents adopt"
run_stm help
assert_status 0
assert_contains "$STM_OUT" "adopt"
assert_contains "$STM_OUT" "--no-wire"
assert_contains "$STM_OUT" "--no-layout"
done_it

finish
