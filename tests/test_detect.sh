#!/usr/bin/env bash
# Config-format auto-detection.

# shellcheck source=tests/helpers.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

it "detects a Lua config"
d="$SANDBOX/lua"
make_lua_config "$d"
run_stm --dir "$d" --no-reload apply tokyo-night
assert_status 0
assert_file_exists "$d/colors_generated.lua" "the Lua writer should have run"
assert_file_absent "$d/colors.sh"
done_it

it "detects a Bash config"
d="$SANDBOX/bash"
make_bash_config "$d"
run_stm --dir "$d" --no-reload apply tokyo-night
assert_status 0
assert_file_absent "$d/colors_generated.lua" "the Bash writer should have run instead"
assert_file_contains "$d/colors.sh" "0xff1a1b26"
done_it

it "detects Lua from a bare .lua file with no colors.lua"
d="$SANDBOX/bare-lua"
mkdir -p "$d"
printf 'return {}\n' >"$d/init.lua"
run_stm --dir "$d" --no-reload apply tokyo-night
assert_status 0
assert_file_exists "$d/colors_generated.lua"
done_it

it "refuses to guess when both formats are present"
d="$SANDBOX/both"
make_both_config "$d"
run_stm --dir "$d" --no-reload apply tokyo-night
assert_status 2
assert_contains "$STM_ERR" "ambiguous"
assert_file_absent "$d/colors_generated.lua" "nothing should be written when the format is ambiguous"
assert_files_equal "$FIXTURES_DIR/bash-config/colors.sh" "$d/colors.sh" "colors.sh must be untouched"
done_it

it "--format resolves an ambiguous directory (lua)"
d="$SANDBOX/both-lua"
make_both_config "$d"
run_stm --dir "$d" --no-reload --format lua apply tokyo-night
assert_status 0
assert_file_exists "$d/colors_generated.lua"
assert_files_equal "$FIXTURES_DIR/bash-config/colors.sh" "$d/colors.sh" "colors.sh must be untouched"
done_it

it "--format resolves an ambiguous directory (bash)"
d="$SANDBOX/both-bash"
make_both_config "$d"
run_stm --dir "$d" --no-reload --format bash apply tokyo-night
assert_status 0
assert_file_absent "$d/colors_generated.lua"
assert_file_contains "$d/colors.sh" "0xff1a1b26"
done_it

it "errors when no format can be detected"
d="$SANDBOX/empty"
mkdir -p "$d"
run_stm --dir "$d" --no-reload apply tokyo-night
assert_status 2
assert_contains "$STM_ERR" "could not detect"
done_it

it "errors when the config dir does not exist"
run_stm --dir "$SANDBOX/nope" --no-reload apply tokyo-night
assert_status 2
assert_contains "$STM_ERR" "does not exist"
done_it

it "rejects an unknown --format value"
d="$SANDBOX/lua2"
make_lua_config "$d"
run_stm --dir "$d" --no-reload --format perl apply tokyo-night
assert_status 64
assert_contains "$STM_ERR" "--format must be lua, bash or config-sh"
done_it

it "STM_FORMAT is honoured"
d="$SANDBOX/both-env"
make_both_config "$d"
STM_FORMAT=lua run_stm --dir "$d" --no-reload apply tokyo-night
assert_status 0
assert_file_exists "$d/colors_generated.lua"
done_it

it "SKETCHYBAR_CONFIG_DIR is honoured"
d="$SANDBOX/env-dir"
make_lua_config "$d"
SKETCHYBAR_CONFIG_DIR="$d" run_stm --no-reload apply tokyo-night
assert_status 0
assert_file_exists "$d/colors_generated.lua"
done_it

it "--dir beats SKETCHYBAR_CONFIG_DIR"
a="$SANDBOX/prec-a"
b="$SANDBOX/prec-b"
make_lua_config "$a"
make_lua_config "$b"
SKETCHYBAR_CONFIG_DIR="$a" run_stm --dir "$b" --no-reload apply tokyo-night
assert_status 0
assert_file_exists "$b/colors_generated.lua"
assert_file_absent "$a/colors_generated.lua" "--dir should win"
done_it

finish
