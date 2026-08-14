#!/usr/bin/env bash
# Palette parsing and validation.

# shellcheck source=tests/helpers.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox
BAD="$FIXTURES_DIR/bad"

# --- happy path ------------------------------------------------------------

it "parses a valid bundled palette"
run_stm preview --porcelain tokyo-night
assert_status 0
assert_contains "$STM_OUT" "black	0xff1a1b26"
assert_contains "$STM_OUT" "popup_border	0xff565f89"
# Palettes carry the 15 canonical keys plus transparent plus the bash dialect
# set, so assert the contract rather than a brittle exact count.
n=$(printf '%s\n' "$STM_OUT" | wc -l | tr -d ' ')
if [ "$n" -lt 16 ]; then
  _note_fail "expected at least 16 colour keys, got $n"
fi
assert_contains "$STM_OUT" "transparent	0x00000000"
done_it

it "emits colours sorted by key"
run_stm preview --porcelain tokyo-night
sorted=$(printf '%s\n' "$STM_OUT" | cut -f1 | sort)
actual=$(printf '%s\n' "$STM_OUT" | cut -f1)
assert_eq "$sorted" "$actual" "keys should already be sorted"
done_it

it "every bundled palette validates"
for f in "$REPO_ROOT"/palettes/*.toml; do
  slug=$(basename "$f" .toml)
  run_stm preview --porcelain "$slug"
  assert_status 0 "bundled palette $slug should validate"
done
done_it

it "every bundled palette defines all 15 required keys"
required="black white red green blue yellow orange magenta grey bg1 bg2 bar_bg bar_border popup_bg popup_border"
for f in "$REPO_ROOT"/palettes/*.toml; do
  slug=$(basename "$f" .toml)
  run_stm preview --porcelain "$slug"
  for k in $required; do
    assert_contains "$STM_OUT" "$k	0x" "$slug is missing key $k"
  done
done
done_it

# --- rejection cases -------------------------------------------------------

# reject <fixture-slug> <description> [expected-message-fragment]
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

reject missing-key        "a palette missing a required key"    "missing required colour key"
reject short-hex          "a 7-digit colour value"              "invalid colour value"
reject long-hex           "a 9-digit colour value"              "invalid colour value"
reject no-prefix          "a colour value with no 0x prefix"    "invalid colour value"
reject bad-hex            "non-hex characters in a colour"      "invalid colour value"
reject duplicate-key      "a duplicate colour key"              "duplicate colour key"
reject traversal-slug     "a slug containing path traversal"    "invalid slug"
reject unsupported-array  "a TOML array value"                  "unsupported or malformed line"
reject unsupported-table  "a nested TOML table"                 "unsupported table"
reject bad-key            "an invalid colour key name"          "unsupported or malformed line"
reject multiline-name     "an unterminated string"              "unsupported or malformed line"

it "reports the offending line number"
run_stm preview --palette-dir "$BAD" --porcelain short-hex
assert_contains "$STM_ERR" "line 6" "the error should name the bad line"
done_it

it "accepts extra colour keys beyond the required 15"
extra="$SANDBOX/extra"
mkdir -p "$extra"
cp "$REPO_ROOT/palettes/tokyo-night.toml" "$extra/extra-keys.toml"
sed 's/^slug = .*/slug = "extra-keys"/;s/^name = .*/name = "Extra Keys"/;s/^variant_label = .*/variant_label = "Extra Keys"/' \
  "$REPO_ROOT/palettes/tokyo-night.toml" >"$extra/extra-keys.toml"
printf 'my_accent = "0xffb7bdf8"\nmy_highlight = "0xff1abc9c"\n' >>"$extra/extra-keys.toml"
run_stm preview --palette-dir "$extra" --porcelain extra-keys
assert_status 0
assert_contains "$STM_OUT" "my_accent	0xffb7bdf8"
assert_contains "$STM_OUT" "my_highlight	0xff1abc9c"
done_it

it "normalises upper-case hex to lower case"
up="$SANDBOX/upper"
mkdir -p "$up"
sed 's/^slug = .*/slug = "upper-hex"/;s/^name = .*/name = "Upper Hex"/;s/^variant_label = .*/variant_label = "Upper Hex"/;s/^black = .*/black = "0xFF1A1B26"/' \
  "$REPO_ROOT/palettes/tokyo-night.toml" >"$up/upper-hex.toml"
run_stm preview --palette-dir "$up" --porcelain upper-hex
assert_status 0
assert_contains "$STM_OUT" "black	0xff1a1b26" "upper-case hex should be normalised"
done_it

it "tolerates CRLF line endings"
crlf="$SANDBOX/crlf"
mkdir -p "$crlf"
sed 's/^slug = .*/slug = "crlf"/;s/^name = .*/name = "Crlf"/;s/^variant_label = .*/variant_label = "Crlf"/' \
  "$REPO_ROOT/palettes/tokyo-night.toml" | awk '{ printf("%s\r\n", $0) }' >"$crlf/crlf.toml"
run_stm preview --palette-dir "$crlf" --porcelain crlf
assert_status 0
assert_contains "$STM_OUT" "black	0xff1a1b26"
done_it

finish
