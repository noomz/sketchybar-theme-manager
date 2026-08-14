#!/usr/bin/env bash
# The Bash writer: in-place value swap in colors.sh.
#
# This is the destructive path, so most of these tests are about what must NOT
# change.

# shellcheck source=tests/helpers.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

D="$SANDBOX/cfg"
make_bash_config "$D"
CS="$D/colors.sh"
ORIG="$FIXTURES_DIR/bash-config/colors.sh"

it "applies a theme"
run_stm --dir "$D" --no-reload apply tokyo-night
assert_status 0
assert_contains "$STM_OUT" "Applied Tokyo Night (tokyo-night)"
done_it

it "swaps every palette value"
assert_file_contains "$CS" "export BLACK=0xff1a1b26"
assert_file_contains "$CS" "export GREEN=0xff9ece6a"
assert_file_contains "$CS" "export BAR_BG=0x001a1b26"
assert_file_contains "$CS" "export POPUP_BORDER=0xff565f89"
assert_file_not_contains "$CS" "0xff181926" "old BLACK should be gone"
done_it

it "preserves trailing comments"
assert_file_contains "$CS" "export RED=0xfff7768e            # accent red"
done_it

it "preserves indentation"
assert_file_contains "$CS" "  export BG2=0xff24283b          # indented on purpose"
done_it

it "preserves quoting style"
assert_file_contains "$CS" 'export BLUE="0xff7aa2f7"'
done_it

it "leaves unrelated variables untouched"
assert_file_contains "$CS" "export ACCENT=0xffb7bdf8"
assert_file_contains "$CS" "export TRANSPARENT=0x00000000"
assert_file_contains "$CS" 'export ICON_FONT="Hack Nerd Font:Bold:16.0"'
assert_file_contains "$CS" "export BAR_HEIGHT=40"
done_it

it "does not half-rewrite a 10-digit hex literal"
assert_file_contains "$CS" "export LONGHEX=0xff11223344" \
  "a value longer than 8 hex digits must be left byte-identical"
assert_file_not_contains "$CS" "0xff1a1b2644"
done_it

it "does not touch a lower-case variable name"
assert_file_contains "$CS" "export black=0xdeadbeef"
done_it

it "rewrites every occurrence of a repeated variable"
assert_eq 2 "$(grep -c '^export WHITE=0xffc0caf5' "$CS" | tr -d ' ')" \
  "both WHITE assignments should be updated"
done_it

it "keeps the shebang first"
assert_eq "#!/usr/bin/env bash" "$(head -n 1 "$CS")"
done_it

it "inserts exactly one stm header, after the shebang"
assert_eq 1 "$(grep -c '^# stm-theme:' "$CS" | tr -d ' ')"
assert_eq 1 "$(grep -c '^# stm-name:' "$CS" | tr -d ' ')"
assert_eq "# stm-theme: tokyo-night" "$(sed -n '2p' "$CS")"
assert_eq "# stm-name: Tokyo Night" "$(sed -n '3p' "$CS")"
done_it

it "writes a one-time backup of the pristine original"
assert_file_exists "$CS.stm-backup"
assert_files_equal "$ORIG" "$CS.stm-backup" "the backup must be the untouched original"
done_it

it "the rewritten file is still valid shell"
out=$("$STM_BASH" -c ". '$CS'; printf '%s %s %s %s' \"\$BLACK\" \"\$BLUE\" \"\$LONGHEX\" \"\$BAR_HEIGHT\"" 2>&1)
assert_eq "0xff1a1b26 0xff7aa2f7 0xff11223344 40" "$out"
done_it

it "is byte-for-byte idempotent"
cp "$CS" "$SANDBOX/pass1.sh"
run_stm --dir "$D" --no-reload -q apply tokyo-night
assert_status 0
assert_files_equal "$SANDBOX/pass1.sh" "$CS" "re-applying the same theme must change nothing"
assert_eq 1 "$(grep -c '^# stm-theme:' "$CS" | tr -d ' ')" "the header must not accumulate"
done_it

it "does not overwrite an existing backup when switching themes"
run_stm --dir "$D" --no-reload -q apply nord
assert_status 0
assert_files_equal "$ORIG" "$CS.stm-backup" "the backup must still hold the pristine original"
assert_file_contains "$CS" "export BLACK=0xff2e3440"
assert_eq "# stm-theme: nord" "$(sed -n '2p' "$CS")"
done_it

it "--append-missing adds keys absent from the file"
d="$SANDBOX/partial"
mkdir -p "$d"
printf '#!/usr/bin/env bash\nexport BLACK=0xff000000\nexport WHITE=0xffffffff\n' >"$d/colors.sh"
run_stm --dir "$d" --no-reload --append-missing apply tokyo-night
assert_status 0
assert_file_contains "$d/colors.sh" "export BLACK=0xff1a1b26"
assert_file_contains "$d/colors.sh" "export POPUP_BORDER=0xff565f89"
assert_file_contains "$d/colors.sh" "added by stm"
done_it

it "without --append-missing, absent keys stay absent"
d="$SANDBOX/partial2"
mkdir -p "$d"
printf '#!/usr/bin/env bash\nexport BLACK=0xff000000\n' >"$d/colors.sh"
run_stm --dir "$d" --no-reload apply tokyo-night
assert_status 0
assert_file_contains "$d/colors.sh" "export BLACK=0xff1a1b26"
assert_file_not_contains "$d/colors.sh" "POPUP_BORDER"
done_it

it "swaps values in a CRLF file and keeps the line endings"
d="$SANDBOX/crlf"
mkdir -p "$d"
printf '#!/bin/bash\r\nexport BLACK=0xff000000\r\nexport WHITE="0xffffffff"\r\nexport LONGHEX=0xff11223344\r\n' >"$d/colors.sh"
run_stm --dir "$d" --no-reload apply nord
assert_status 0
assert_eq "export BLACK=0xff2e3440" "$(sed -n '4p' "$d/colors.sh" | tr -d '\r')"
assert_eq 'export WHITE="0xffd8dee9"' "$(sed -n '5p' "$d/colors.sh" | tr -d '\r')"
assert_eq "export LONGHEX=0xff11223344" "$(sed -n '6p' "$d/colors.sh" | tr -d '\r')"
assert_eq 4 "$(tr -cd '\r' <"$d/colors.sh" | wc -c | tr -d ' ')" \
  "every original CRLF must survive (4 data lines; the 2 header lines are LF)"
done_it

it "follows a symlinked target instead of replacing the symlink"
# stow-style dotfiles: colors.sh in the config dir is a link into a repo.
real="$SANDBOX/dotfiles"
link="$SANDBOX/linked"
mkdir -p "$real" "$link"
cp "$ORIG" "$real/colors.sh"
ln -s "$real/colors.sh" "$link/colors.sh"
run_stm --dir "$link" --no-reload apply nord
assert_status 0
if [ ! -L "$link/colors.sh" ]; then
  _note_fail "the symlink must be preserved, not replaced with a regular file"
fi
assert_file_contains "$real/colors.sh" "export BLACK=0xff2e3440" "the real file should be updated"
assert_file_exists "$real/colors.sh.stm-backup" "the backup belongs next to the real file"
done_it

it "refuses a symlink pointing at a non-regular file"
d="$SANDBOX/devnull"
mkdir -p "$d"
cp "$FIXTURES_DIR/lua-config/colors.lua" "$d/colors.lua"
ln -s /dev/null "$d/colors_generated.lua"
run_stm --dir "$d" --no-reload apply nord
assert_status 2
assert_contains "$STM_ERR" "non-regular file"
done_it

it "--dry-run writes nothing"
d="$SANDBOX/dry"
make_bash_config "$d"
run_stm --dir "$d" --dry-run apply gruvbox
assert_status 0
assert_contains "$STM_OUT" "would apply"
assert_files_equal "$ORIG" "$d/colors.sh"
assert_file_absent "$d/colors.sh.stm-backup"
assert_file_absent "$d/.stm-state"
done_it

it "leaves no temp files behind"
leftovers=$(find "$D" -name '.stm-tmp.*' 2>/dev/null | wc -l | tr -d ' ')
assert_eq 0 "$leftovers"
done_it

finish
