#!/usr/bin/env bash
# Output templates, and the import/export round trip.

# shellcheck source=tests/helpers.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

D="$SANDBOX/cfg"
make_lua_config "$D"
TPL="$D/stm/templates"
mkdir -p "$TPL"
GEN="$D/colors_generated.lua"

# --- substitution -----------------------------------------------------------

it "substitutes metadata and single keys"
printf -- '-- {{name}} / {{slug}} / {{variant_label}}\nreturn { black = {{black}}, grey = {{grey}} }\n' >"$TPL/lua.tpl"
run_stm --dir "$D" --no-reload apply tokyo-night
assert_status 0
assert_file_contains "$GEN" "-- Tokyo Night / tokyo-night / Tokyo Night"
assert_file_contains "$GEN" "return { black = 0xff1a1b26, grey = 0xff565f89 }"
done_it

it "a template replaces the built-in writer entirely"
assert_file_not_contains "$GEN" "DO NOT EDIT" "the built-in header must not appear"
done_it

it "expands the multi-line blocks"
printf 'return {\n{{colors_lua}}\n}\n' >"$TPL/lua.tpl"
run_stm --dir "$D" --no-reload -q apply nord
assert_status 0
assert_file_contains "$GEN" "  black = 0xff2e3440,"
assert_file_contains "$GEN" "  white = 0xffd8dee9,"
n=$(grep -c '^  [a-z_]* = 0x' "$GEN" | tr -d ' ')
if [ "$n" -lt 16 ]; then
  _note_fail "expected the whole palette, got $n lines"
fi
done_it

it "expands {{children_lua}} into bar/popup sub-tables"
printf 'return {\n{{children_lua}}\n}\n' >"$TPL/lua.tpl"
run_stm --dir "$D" --no-reload -q apply tokyo-night
assert_file_contains "$GEN" "  bar = {"
assert_file_contains "$GEN" "    bg = 0x001a1b26,"
assert_file_contains "$GEN" "  popup = {"
assert_file_contains "$GEN" "    border = 0xff565f89,"
done_it

it "expands {{with_alpha}} from stm's own constant"
printf '{{with_alpha}}\nreturn { with_alpha = with_alpha }\n' >"$TPL/lua.tpl"
run_stm --dir "$D" --no-reload -q apply nord
assert_file_contains "$GEN" "local with_alpha = function(color, alpha)"
assert_file_contains "$GEN" "math.floor(alpha * 255.0)"
done_it

it "expands only the extras into {{extras_lua}}"
p="$SANDBOX/pal"
mkdir -p "$p"
{
  sed 's/^slug = .*/slug = "wx"/;s/^name = .*/name = "Wx"/;s/^variant_label = .*/variant_label = "Wx"/' \
    "$REPO_ROOT/palettes/nord.toml"
  printf '\n[extras]\nmy_accent = "#00ff00"\n'
} >"$p/wx.toml"
printf 'return {\n{{extras_lua}}\n}\n' >"$TPL/lua.tpl"
run_stm --dir "$D" --palette-dir "$p" --no-reload -q apply wx
assert_status 0
assert_file_contains "$GEN" "  my_accent = 0xff00ff00,"
assert_file_not_contains "$GEN" "black" "extras_lua must not include ordinary colours"
done_it

# --- the {{ ambiguity -------------------------------------------------------

it "leaves a genuine Lua nested constructor alone"
# {{1,2},{3,4}} is real Lua. Treating every {{ as a placeholder would corrupt it.
printf 'return { t = {{1,2},{3,4}}, b = {{black}} }\n' >"$TPL/lua.tpl"
run_stm --dir "$D" --no-reload -q apply tokyo-night
assert_status 0
assert_file_contains "$GEN" "t = {{1,2},{3,4}}"
assert_file_contains "$GEN" "b = 0xff1a1b26"
done_it

it "{{{{ escapes to a literal {{"
printf -- '-- {{{{not_a_placeholder}}\n return { b = {{black}} }\n' >"$TPL/lua.tpl"
run_stm --dir "$D" --no-reload -q apply tokyo-night
assert_status 0
assert_file_contains "$GEN" "-- {{not_a_placeholder}}"
done_it

it "an unknown placeholder is a hard error and writes nothing"
rm -f "$GEN"
printf 'return { x = {{no_such_key}} }\n' >"$TPL/lua.tpl"
run_stm --dir "$D" --no-reload apply nord
assert_ne 0 "$STM_STATUS"
assert_contains "$STM_ERR" "unknown placeholder {{no_such_key}}"
assert_file_absent "$GEN" "a failed render must not leave a file behind"
done_it

it "an unterminated {{ is literal text, not an error"
printf 'return { s = "{{ unterminated", b = {{black}} }\n' >"$TPL/lua.tpl"
run_stm --dir "$D" --no-reload -q apply tokyo-night
assert_status 0
assert_file_contains "$GEN" '{{ unterminated'
done_it

it "renders a template with CRLF line endings"
printf 'return { b = {{black}} }\r\n' >"$TPL/lua.tpl"
run_stm --dir "$D" --no-reload -q apply tokyo-night
assert_status 0
assert_file_contains "$GEN" "return { b = 0xff1a1b26 }"
done_it

# --- security ----------------------------------------------------------------

it "a template is never executed, only substituted"
# shellcheck disable=SC2016  # the payloads must reach the template unexpanded
printf 'x = {{black}}\n$(touch %s/pwn1)\n`touch %s/pwn2`\n' "$SANDBOX" "$SANDBOX" >"$TPL/lua.tpl"
run_stm --dir "$D" --no-reload -q apply nord
assert_status 0
assert_file_absent "$SANDBOX/pwn1"
assert_file_absent "$SANDBOX/pwn2"
assert_file_contains "$GEN" 'touch' "the text should be copied through verbatim"
done_it

it "palette values reaching a template are still validated hex"
printf '{{black}} {{white}} {{bar_bg}}\n' >"$TPL/lua.tpl"
run_stm --dir "$D" --no-reload -q apply catppuccin-latte
assert_status 0
bad=$(tr ' ' '\n' <"$GEN" | grep -v '^$' |
  grep -cv '^0x[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$' || true)
assert_eq 0 "$bad" "every substituted value must be an 8-digit hex literal"
done_it

# --- template_dir ------------------------------------------------------------

it "[output] template_dir relocates the template"
mkdir -p "$D/mytpl"
printf 'ok = {{black}}\n' >"$D/mytpl/lua.tpl"
rm -f "$TPL/lua.tpl"
cfg="$SANDBOX/tpl.toml"
{
  printf 'sketchybar_dir = "%s"\n' "$D"
  printf 'format = "lua"\n\n[output]\ntemplate_dir = "mytpl"\n'
} >"$cfg"
run_stm --config "$cfg" --no-reload -q apply nord
assert_status 0
assert_file_contains "$GEN" "ok = 0xff2e3440"
done_it

it "with no template the built-in writer runs"
rm -f "$D/mytpl/lua.tpl"
run_stm --dir "$D" --no-reload -q apply nord
assert_status 0
assert_file_contains "$GEN" "DO NOT EDIT"
done_it

# --- bash templates ----------------------------------------------------------

it "renders a bash template"
b="$SANDBOX/bcfg"
make_bash_config "$b"
mkdir -p "$b/stm/templates"
# shellcheck disable=SC2016  # $SURFACE0 stays literal: it is a reference line
printf '#!/usr/bin/env bash\n# {{name}}\n{{colors_bash}}\nexport ITEM_BG_COLOR=$SURFACE0\n' \
  >"$b/stm/templates/bash.tpl"
run_stm --dir "$b" --no-reload -q apply catppuccin-mocha
assert_status 0
assert_file_contains "$b/colors.sh" "export BLACK=0xff1e1e2e"
assert_file_contains "$b/colors.sh" "export SURFACE0=0xff313244"
out=$("$STM_BASH" -c ". '$b/colors.sh'; printf '%s %s' \"\$BASE\" \"\$ITEM_BG_COLOR\"" 2>&1)
assert_eq "0xff1e1e2e 0xff313244" "$out" "the rendered file must still be valid shell"
done_it

# --- export ------------------------------------------------------------------

it "export prints canonical TOML"
run_stm export nord
assert_status 0
assert_contains "$STM_OUT" 'slug = "nord"'
assert_contains "$STM_OUT" "[colors]"
assert_contains "$STM_OUT" 'black = "0xff2e3440"'
done_it

it "export --out writes to a file"
run_stm export gruvbox --out "$SANDBOX/gruvbox.toml"
assert_status 0
assert_file_exists "$SANDBOX/gruvbox.toml"
assert_file_contains "$SANDBOX/gruvbox.toml" 'slug = "gruvbox"'
done_it

it "an exported palette re-imports to the identical colour set"
out="$SANDBOX/exp"
mkdir -p "$out"
for slug in tokyo-night nord gruvbox catppuccin-latte rose-pine; do
  run_stm export "$slug" --out "$out/$slug.toml"
  assert_status 0 "export $slug"
  run_stm preview --porcelain "$slug"
  a="$STM_OUT"
  run_stm preview --palette-dir "$out" --porcelain "$slug"
  assert_eq "$a" "$STM_OUT" "$slug should round-trip identically"
done
done_it

it "export includes an [extras] section when there is one"
run_stm export wx --palette-dir "$p" --out "$SANDBOX/wx.toml"
assert_status 0
assert_file_contains "$SANDBOX/wx.toml" "[extras]"
assert_file_contains "$SANDBOX/wx.toml" 'my_accent = "0xff00ff00"'
done_it

# --- import ------------------------------------------------------------------

it "imports a nested Lua colours module"
ip="$SANDBOX/imported"
mkdir -p "$ip"
run_stm --palette-dir "$ip" import "$FIXTURES_DIR/lua-nested/colors.lua" --slug fromlua
assert_status 0
assert_file_exists "$ip/fromlua.toml"
assert_file_contains "$ip/fromlua.toml" 'black = "0xff1a1b26"'
assert_file_contains "$ip/fromlua.toml" 'bar_bg = "0x001a1b26"' "nested keys should flatten"
assert_file_contains "$ip/fromlua.toml" 'popup_border = "0xff565f89"'
assert_contains "$STM_OUT" "Ready: stm apply fromlua"
done_it

it "import skips a Lua function and says so"
assert_contains "$STM_OUT" "Could not import"
assert_contains "$STM_OUT" "with_alpha"
assert_file_not_contains "$ip/fromlua.toml" "with_alpha" \
  "a function must never end up in a palette"
done_it

it "an imported palette applies cleanly"
d2="$SANDBOX/applyimported"
make_lua_config "$d2"
run_stm --dir "$d2" --palette-dir "$ip" --no-reload apply fromlua
assert_status 0
assert_file_contains "$d2/colors_generated.lua" "black = 0xff1a1b26,"
done_it

it "imports a colors.sh and resolves its reference lines"
run_stm --palette-dir "$ip" import "$FIXTURES_DIR/bash-config/colors.sh" --slug frombash
assert_status 0
assert_file_contains "$ip/frombash.toml" 'black = "0xff181926"'
assert_file_contains "$ip/frombash.toml" 'accent = "0xffb7bdf8"'
done_it

it "import refuses to overwrite without --force"
run_stm --palette-dir "$ip" import "$FIXTURES_DIR/bash-config/colors.sh" --slug frombash
assert_status 4
assert_contains "$STM_ERR" "already exists"
done_it

it "import --force overwrites"
run_stm --palette-dir "$ip" --force import "$FIXTURES_DIR/bash-config/colors.sh" --slug frombash
assert_status 0
done_it

it "import reports missing canonical keys and exits non-zero"
partial="$SANDBOX/partial.sh"
printf 'export MAUVE=0xffcba6f7\nexport CRUST=0xff11111b\n' >"$partial"
run_stm --palette-dir "$ip" import "$partial" --slug partialtheme
assert_status 1
assert_contains "$STM_OUT" "Missing required key(s)"
assert_contains "$STM_OUT" "--base"
assert_not_contains "$STM_OUT" "Ready: stm apply"
done_it

it "import --base makes such a palette immediately applyable"
run_stm --palette-dir "$ip" --force import "$partial" --slug partialtheme --base tokyo-night
assert_status 0
assert_contains "$STM_OUT" "Ready: stm apply partialtheme"
assert_file_contains "$ip/partialtheme.toml" 'base = "tokyo-night"'
run_stm preview --palette-dir "$ip" --porcelain partialtheme
assert_status 0
assert_contains "$STM_OUT" "mauve	0xffcba6f7" "the imported value wins"
assert_contains "$STM_OUT" "black	0xff1a1b26" "the base supplies the rest"
done_it

it "import rejects a file whose format it cannot tell"
printf 'nothing here\n' >"$SANDBOX/mystery.txt"
run_stm --palette-dir "$ip" import "$SANDBOX/mystery.txt" --slug mystery
assert_status 64
assert_contains "$STM_ERR" "cannot tell the format"
done_it

it "import errors when a file has no colours at all"
printf 'export NOT_A_COLOUR="hello"\n' >"$SANDBOX/empty.sh"
run_stm --palette-dir "$ip" import "$SANDBOX/empty.sh" --slug emptytheme
assert_status 1
assert_contains "$STM_ERR" "no colour definitions"
done_it

it "import validates the slug it is given"
run_stm --palette-dir "$ip" import "$FIXTURES_DIR/bash-config/colors.sh" --slug "../../etc/passwd"
assert_status 3
assert_contains "$STM_ERR" "invalid theme name"
done_it

finish
