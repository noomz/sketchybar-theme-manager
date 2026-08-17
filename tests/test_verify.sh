#!/usr/bin/env bash
# stm verify and the manifest, --backup-each, the config-sh dialect, and the
# doctor / --dry-run reporting added alongside them.

# shellcheck source=tests/helpers.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

# --- manifest / verify ------------------------------------------------------

D="$SANDBOX/cfg"
make_lua_config "$D"
mkdir -p "$D/plugins" "$D/items"
printf '#!/bin/sh\necho clock\n' >"$D/plugins/clock.sh"
printf 'return { "space" }\n' >"$D/items/spaces.lua"

it "apply records a manifest"
run_stm --dir "$D" --no-reload -q apply nord
assert_status 0
assert_file_exists "$D/.stm-manifest"
assert_file_contains "$D/.stm-manifest" "./plugins/clock.sh"
assert_file_contains "$D/.stm-manifest" "./items/spaces.lua"
done_it

it "the manifest excludes the files stm owns"
assert_file_not_contains "$D/.stm-manifest" "colors_generated.lua"
assert_file_not_contains "$D/.stm-manifest" ".stm-state"
assert_file_not_contains "$D/.stm-manifest" ".stm-manifest"
done_it

it "verify passes right after an apply"
run_stm --dir "$D" verify
assert_status 0
assert_contains "$STM_OUT" "OK"
assert_contains "$STM_OUT" "stm touched only what it owns"
done_it

it "switching themes does not disturb anything else"
run_stm --dir "$D" --no-reload -q apply gruvbox
run_stm --dir "$D" verify
assert_status 0
assert_contains "$STM_OUT" "OK"
done_it

it "verify reports a changed file"
printf 'echo tampered\n' >>"$D/plugins/clock.sh"
run_stm --dir "$D" verify
assert_status 1
assert_contains "$STM_OUT" "CHANGED"
assert_contains "$STM_OUT" "./plugins/clock.sh"
done_it

it "verify reports an added file"
run_stm --dir "$D" --no-reload -q apply nord
printf 'return {}\n' >"$D/items/new.lua"
run_stm --dir "$D" verify
assert_status 1
assert_contains "$STM_OUT" "ADDED"
assert_contains "$STM_OUT" "./items/new.lua"
done_it

it "verify reports a removed file"
run_stm --dir "$D" --no-reload -q apply nord
rm "$D/items/new.lua"
run_stm --dir "$D" verify
assert_status 1
assert_contains "$STM_OUT" "REMOVED"
done_it

it "re-applying re-baselines the manifest"
run_stm --dir "$D" --no-reload -q apply nord
run_stm --dir "$D" verify
assert_status 0
done_it

it "verify without a manifest says so"
d2="$SANDBOX/nomanifest"
make_lua_config "$d2"
run_stm --dir "$d2" verify
assert_status 2
assert_contains "$STM_ERR" "no manifest"
done_it

it "--no-manifest skips the baseline"
d3="$SANDBOX/skipmanifest"
make_lua_config "$d3"
run_stm --dir "$d3" --no-reload --no-manifest -q apply nord
assert_status 0
assert_file_absent "$d3/.stm-manifest"
done_it

it "the manifest does not descend into .git"
d4="$SANDBOX/withgit"
make_lua_config "$d4"
mkdir -p "$d4/.git/objects"
printf 'junk\n' >"$d4/.git/objects/deadbeef"
run_stm --dir "$d4" --no-reload -q apply nord
assert_file_not_contains "$d4/.stm-manifest" ".git"
done_it

it "verify is read-only"
before=$(find "$D" -type f | sort)
run_stm --dir "$D" verify
assert_eq "$before" "$(find "$D" -type f | sort)"
done_it

# --- backups ----------------------------------------------------------------

it "by default only the pristine backup is kept"
b="$SANDBOX/bak"
make_bash_config "$b"
run_stm --dir "$b" --no-reload -q apply nord
run_stm --dir "$b" --no-reload -q apply gruvbox
assert_file_exists "$b/colors.sh.stm-backup"
assert_eq 0 "$(find "$b" -name '*.stm-bak-*' | wc -l | tr -d ' ')" \
  "no rolling backups without --backup-each"
done_it

it "--backup-each keeps a rolling copy and prunes to five"
b2="$SANDBOX/bak2"
make_bash_config "$b2"
for t in nord gruvbox catppuccin-mocha rose-pine tokyo-night catppuccin-latte catppuccin-frappe; do
  run_stm --dir "$b2" --no-reload -q --backup-each apply "$t"
  assert_status 0 "apply $t"
done
assert_eq 5 "$(find "$b2" -name '*.stm-bak-*' | wc -l | tr -d ' ')" \
  "the rolling backups should be capped at five"
done_it

it "the pristine backup survives every rolling backup"
assert_files_equal "$FIXTURES_DIR/bash-config/colors.sh" "$b2/colors.sh.stm-backup"
done_it

# --- config-sh ---------------------------------------------------------------

it "detects the config-sh pattern"
c="$SANDBOX/csh"
mkdir -p "$c"
# shellcheck disable=SC2016  # $CONFIG_DIR stays literal in the generated file
printf '#!/usr/bin/env bash\nsource "$CONFIG_DIR/config-examples/theme.sh"\n' >"$c/config.sh"
run_stm --dir "$c" --no-reload -v apply nord
assert_status 0
assert_contains "$STM_ERR" "format: config-sh"
done_it

it "config-sh writes a per-theme snippet and nothing else"
assert_file_exists "$c/config-examples/nord.sh"
assert_file_not_contains "$c/config.sh" "stm-theme" "config.sh must not be edited"
assert_file_absent "$c/colors.sh"
assert_file_absent "$c/colors_generated.lua"
done_it

it "the snippet is valid shell with the right values"
out=$("$STM_BASH" -c ". '$c/config-examples/nord.sh'; printf '%s %s' \"\$BLACK\" \"\$SURFACE0\"" 2>&1)
assert_eq "0xff2e3440 0xff3b4252" "$out"
done_it

it "config-sh prints the source line to add"
assert_contains "$STM_OUT" "Source it from your config.sh"
assert_contains "$STM_OUT" "config-examples/nord.sh"
done_it

it "each theme gets its own snippet"
run_stm --dir "$c" --no-reload -q apply gruvbox
assert_file_exists "$c/config-examples/nord.sh"
assert_file_exists "$c/config-examples/gruvbox.sh"
done_it

it "config-sh tracks the current theme"
run_stm --dir "$c" current
assert_status 0
assert_eq "gruvbox" "$STM_OUT"
done_it

it "colors.sh wins over config.sh when both exist"
c2="$SANDBOX/csh2"
make_bash_config "$c2"
printf '#!/usr/bin/env bash\n' >"$c2/config.sh"
run_stm --dir "$c2" --no-reload -v apply nord
assert_status 0
assert_contains "$STM_ERR" "format: bash"
done_it

# --- dry-run diff ------------------------------------------------------------

it "--dry-run shows old -> new once a theme is applied"
d5="$SANDBOX/diff"
make_lua_config "$d5"
run_stm --dir "$d5" --no-reload -q apply tokyo-night
run_stm --dir "$d5" --dry-run apply nord
assert_status 0
assert_contains "$STM_OUT" "changes:"
assert_contains "$STM_OUT" "0xff1a1b26 -> 0xff2e3440"
done_it

it "--dry-run on a fresh config lists the colours instead"
d6="$SANDBOX/fresh"
make_lua_config "$d6"
run_stm --dir "$d6" --dry-run apply nord
assert_status 0
assert_contains "$STM_OUT" "colours:"
done_it

it "--dry-run still writes nothing"
assert_file_absent "$d6/colors_generated.lua"
assert_file_absent "$d6/.stm-manifest"
done_it

it "--dry-run diffs a bash config too"
b3="$SANDBOX/diffbash"
make_bash_config "$b3"
run_stm --dir "$b3" --no-reload -q apply tokyo-night
run_stm --dir "$b3" --dry-run apply gruvbox
assert_status 0
assert_contains "$STM_OUT" "changes:"
assert_contains "$STM_OUT" "->"
done_it

# --- doctor reporting --------------------------------------------------------

it "doctor lists mapping entries and flags unresolved ones"
d7="$SANDBOX/docmap"
make_lua_config "$d7"
cfg="$SANDBOX/docmap.toml"
printf 'sketchybar_dir = "%s"\nformat = "lua"\n\n[mapping]\ngray = "grey"\nbroken = "nope"\n' \
  "$d7" >"$cfg"
run_stm --config "$cfg" doctor tokyo-night
assert_status 1
assert_contains "$STM_OUT" "Mapping"
assert_contains "$STM_OUT" "gray"
assert_contains "$STM_OUT" "UNRESOLVED"
done_it

it "doctor does not abort on a bad mapping — it reports it"
assert_contains "$STM_OUT" "Key coverage" "doctor must reach the coverage section"
done_it

it "doctor validates templates"
mkdir -p "$d7/stm/templates"
printf 'ok = {{black}}\n' >"$d7/stm/templates/lua.tpl"
printf 'bad = {{nope_not_a_key}}\n' >"$d7/stm/templates/bash.tpl"
run_stm --dir "$d7" doctor tokyo-night
assert_status 1
assert_contains "$STM_OUT" "lua.tpl                  ok"
assert_contains "$STM_OUT" "bash.tpl                 INVALID"
done_it

it "prose mentioning colors.lua is not read as a colour key"
# tests/fixtures/lua-config/colors.lua opens with a comment naming colors.lua.
# Scanning without stripping comments reported a missing key called `lua`.
d8="$SANDBOX/prose"
make_lua_config "$d8"
run_stm --dir "$d8" doctor tokyo-night
assert_status 0
assert_not_contains "$STM_OUT" "USED BUT MISSING"
done_it

finish
