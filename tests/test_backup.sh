#!/usr/bin/env bash
# stm backup / restore / backups, auto snapshot on apply, --all whole-dir copy.

# shellcheck source=tests/helpers.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

D="$SANDBOX/cfg"
make_lua_config "$D"

# --- owned backup / restore -------------------------------------------------

it "backup with a name snapshots stm-owned files"
run_stm --dir "$D" --no-reload -q apply nord
run_stm --dir "$D" backup before-switch
assert_status 0
assert_file_exists "$D/.stm-backups/before-switch/manifest.toml"
assert_file_exists "$D/.stm-backups/before-switch/colors_generated.lua"
assert_file_exists "$D/.stm-backups/before-switch/.stm-state"
assert_file_contains "$D/.stm-backups/before-switch/manifest.toml" 'scope = "owned"'
done_it

it "backup does not copy user files"
assert_file_absent "$D/.stm-backups/before-switch/colors.lua"
assert_file_absent "$D/.stm-backups/before-switch/init.lua"
done_it

it "restore named snapshot puts colours and state back"
run_stm --dir "$D" --no-reload -q apply gruvbox
assert_file_contains "$D/colors_generated.lua" "-- theme: gruvbox"
run_stm --dir "$D" --no-reload restore before-switch
assert_status 0
assert_file_contains "$D/colors_generated.lua" "-- theme: nord"
run_stm --dir "$D" current
assert_eq "nord" "$STM_OUT"
done_it

it "backups lists the named snapshot"
run_stm --dir "$D" backups
assert_status 0
assert_contains "$STM_OUT" "before-switch"
done_it

it "backups --porcelain is name created scope slug"
run_stm --dir "$D" backups --porcelain
assert_status 0
assert_contains "$STM_OUT" "before-switch"
printf '%s\n' "$STM_OUT" | grep -q $'before-switch\t' || _note_fail "porcelain should be tab-separated"
assert_contains "$STM_OUT" "owned"
assert_contains "$STM_OUT" "nord"
done_it

# --- name validation --------------------------------------------------------

it "restore refuses a traversal name"
run_stm --dir "$D" restore '../etc/passwd'
assert_ne 0 "$STM_STATUS"
assert_contains "$STM_ERR" "invalid"
done_it

it "restore refuses an absolute path as a name"
run_stm --dir "$D" restore /tmp/stm-pwn
assert_ne 0 "$STM_STATUS"
done_it

it "backup refuses an over-long name"
long=$(awk 'BEGIN { for (i = 0; i < 200; i++) printf("a") }')
run_stm --dir "$D" backup "$long"
assert_ne 0 "$STM_STATUS"
assert_contains "$STM_ERR" "too long"
done_it

it "restore of a missing snapshot exits 3"
run_stm --dir "$D" restore no-such-snap
assert_status 3
done_it

# --- auto snapshot on apply -------------------------------------------------

it "apply writes an owned auto snapshot"
b="$SANDBOX/auto"
make_lua_config "$b"
run_stm --dir "$b" --no-reload -q apply nord
n=$(find "$b/.stm-backups" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
if [ "$n" -lt 1 ]; then
  _note_fail "expected at least one auto snapshot after apply, got $n"
fi
# auto names look like 20260817T120000Z
auto=$(find "$b/.stm-backups" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | grep -E '^[0-9]{8}T[0-9]{6}Z' | head -n 1)
assert_ne "" "$auto" "auto snapshot should be a UTC timestamp"
assert_file_contains "$b/.stm-backups/$auto/manifest.toml" 'scope = "owned"'
done_it

it "the sixth auto snapshot prunes to five; named snapshots survive"
c="$SANDBOX/prune"
make_lua_config "$c"
run_stm --dir "$c" --no-reload -q apply nord
run_stm --dir "$c" backup keep-me
for t in gruvbox rose-pine tokyo-night catppuccin-mocha catppuccin-latte catppuccin-frappe; do
  run_stm --dir "$c" --no-reload -q apply "$t"
  assert_status 0 "apply $t"
done
autos=$(find "$c/.stm-backups" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | grep -cE '^[0-9]{8}T[0-9]{6}Z' | tr -d ' ')
assert_eq 5 "$autos" "auto snapshots should be capped at five"
assert_file_exists "$c/.stm-backups/keep-me/manifest.toml" "named snapshots must survive prune"
done_it

it "restore with no name restores the newest auto snapshot"
d2="$SANDBOX/latest"
make_lua_config "$d2"
run_stm --dir "$d2" --no-reload -q apply nord
run_stm --dir "$d2" --no-reload -q apply gruvbox
run_stm --dir "$d2" --no-reload restore
assert_status 0
assert_file_contains "$d2/colors_generated.lua" "-- theme: nord"
done_it

it "--no-backup skips the auto snapshot"
nb="$SANDBOX/nobak"
make_lua_config "$nb"
run_stm --dir "$nb" --no-reload --no-backup -q apply nord
assert_status 0
assert_file_absent "$nb/.stm-backups"
done_it

it "dry-run apply does not snapshot"
dr="$SANDBOX/dry"
make_lua_config "$dr"
run_stm --dir "$dr" --dry-run apply nord
assert_status 0
assert_file_absent "$dr/.stm-backups"
assert_file_absent "$dr/colors_generated.lua"
done_it

# --- --all ------------------------------------------------------------------

it "backup --all copies the whole config except .stm-backups and .git"
all="$SANDBOX/all"
make_lua_config "$all"
mkdir -p "$all/items" "$all/plugins" "$all/.git/objects"
printf 'return { "space" }\n' >"$all/items/spaces.lua"
printf '#!/bin/sh\necho clock\n' >"$all/plugins/clock.sh"
printf 'junk\n' >"$all/.git/objects/deadbeef"
run_stm --dir "$all" --no-reload -q apply nord
run_stm --dir "$all" backup --all working
assert_status 0
assert_file_contains "$all/.stm-backups/working/manifest.toml" 'scope = "all"'
assert_file_exists "$all/.stm-backups/working/tree/items/spaces.lua"
assert_file_exists "$all/.stm-backups/working/tree/plugins/clock.sh"
assert_file_exists "$all/.stm-backups/working/tree/colors.lua"
assert_file_absent "$all/.stm-backups/working/tree/.git/objects/deadbeef"
assert_file_absent "$all/.stm-backups/working/tree/.stm-backups/working/manifest.toml"
done_it

it "restore of an --all snapshot puts user files back"
printf 'TAMPERED\n' >"$all/items/spaces.lua"
rm -f "$all/plugins/clock.sh"
run_stm --dir "$all" --no-reload restore working
assert_status 0
assert_file_contains "$all/items/spaces.lua" 'return { "space" }'
assert_file_exists "$all/plugins/clock.sh"
assert_file_exists "$all/.stm-backups/working/manifest.toml" "the catalogue must survive restore"
done_it

it "backup --all skips a symlink that points outside the config dir"
esc="$SANDBOX/esc"
make_lua_config "$esc"
outside="$SANDBOX/outside-secret"
printf 'SECRET\n' >"$outside"
ln -s "$outside" "$esc/leak"
run_stm --dir "$esc" backup --all safe
assert_status 0
assert_file_absent "$esc/.stm-backups/safe/tree/leak"
assert_file_exists "$outside" "the outside file must not be consumed"
done_it

it "a relative symlink that stays inside is copied"
inn="$SANDBOX/inn"
make_lua_config "$inn"
printf 'inside\n' >"$inn/real.sh"
ln -s real.sh "$inn/link.sh"
run_stm --dir "$inn" backup --all inner
assert_status 0
assert_file_exists "$inn/.stm-backups/inner/tree/link.sh"
[ -L "$inn/.stm-backups/inner/tree/link.sh" ] || _note_fail "in-tree symlink should be stored as a symlink"
done_it

# --- verify / help ----------------------------------------------------------

it "verify ignores .stm-backups"
v="$SANDBOX/ver"
make_lua_config "$v"
run_stm --dir "$v" --no-reload -q apply nord
run_stm --dir "$v" backup keep
run_stm --dir "$v" verify
assert_status 0
assert_file_not_contains "$v/.stm-manifest" ".stm-backups"
done_it

it "help lists backup, restore and backups"
run_stm help
assert_status 0
assert_contains "$STM_OUT" "  backup"
assert_contains "$STM_OUT" "  restore"
assert_contains "$STM_OUT" "  backups"
done_it

finish
