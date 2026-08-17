# Contributing

Thanks for helping out. This is a small project with a few hard rules, mostly
because `stm` writes to people's live SketchyBar configs and a bug there is
expensive for them.

## Adding a palette

The most useful contribution. Create `palettes/<slug>.toml`:

```toml
name = "My Theme"
slug = "my-theme"
variant_label = "My Theme"

[colors]
black = "0xff1a1b26"
white = "0xffc0caf5"
red = "0xfff7768e"
green = "0xff9ece6a"
blue = "0xff7aa2f7"
yellow = "0xffe0af68"
orange = "0xffff9e64"
magenta = "0xffbb9af7"
grey = "0xff565f89"
bg1 = "0xff1f2335"
bg2 = "0xff24283b"
bar_bg = "0x001a1b26"
bar_border = "0xff292e42"
popup_bg = "0xc01f2335"
popup_border = "0xff565f89"
```

Rules:

- **The file name must equal the `slug`.** CI enforces this.
- The slug is lower-case kebab-case: `[a-z0-9][a-z0-9._-]*`.
- All fifteen colour keys are required. Extra keys are allowed.
- Values are `0xAARRGGBB` — exactly eight hex digits, alpha first.
- `name` and `variant_label` are ASCII only: letters, digits, space, and
  `. _ ( ) + -`. They end up inside generated comments, which is why the charset
  is narrow. Write `Rose Pine`, not `Rosé Pine`.
- Use the **upstream published values** for a known theme. Put the upstream slot
  names in a comment at the top of the file (see `palettes/nord.toml`), so the
  mapping can be checked later.
- Note any substitution you had to make. Rosé Pine has no green, for instance,
  and `palettes/rose-pine.toml` says so.

Check it before opening a PR:

```sh
STM_ROOT="$PWD" bin/stm preview my-theme
```

## Changing `bin/stm`

`bin/stm` is one file and stays one file. Beyond that:

- **bash 3.2 compatible.** macOS ships bash 3.2.57 as `/bin/bash` and that is the
  floor. No associative arrays (`declare -A`), no `mapfile`/`readarray`, no
  `${v^^}` / `${v,,}`, no `[[ -v ]]`, no `local -n`, no `**` globstar.
- **BSD userland only.** No `sed -i` without an argument, no `grep -P`, no
  `readlink -f`, no `sort -V`, no `date -d`. Assume the macOS `awk`, which means
  no `gensub` and no reliance on ERE interval syntax (`{n}`).
- **Zero dependencies.** If a change needs a tool that isn't on a stock macOS
  install, it doesn't go in.
- **Never `eval` or `source` palette or config content.** Palettes are untrusted
  input downloaded from the internet. Parsing happens in awk, and every key and
  value is validated against an allowlist before it reaches generated output.
- **Writes are atomic.** Write to a temp file in the destination directory, then
  `mv` it into place. Never edit a user file in a way that can leave it half
  written.
- `shellcheck -s bash bin/stm tests/*.sh` and `shellcheck -s sh install.sh` must
  produce **no output**. If a warning is genuinely wrong, add a targeted
  `# shellcheck disable=SCxxxx` with a comment saying why.
- Keep `LC_ALL=C` in force. Glob ranges like `[!a-z0-9._-]` match upper-case
  letters under `en_US.UTF-8`, which silently defeats validation.

## Lua dialects

`stm` emits two shapes of `colors_generated.lua`:

- **flat** — one table of colour literals.
- **nested** — `bar`/`popup` sub-tables plus a `with_alpha` helper, for configs
  whose `colors.lua` does `return generated` wholesale and therefore needs the
  generated table to be the complete shape.

The mapping from canonical flat keys to nested fields lives in
`STM_NESTED_MAP`. The dialect is detected from sub-tables in the user's own
`colors.lua` only — never from other `.lua` files, because SketchyBar item
definitions legitimately contain things like `bar = { color = ... }` and would
false-positive.

`with_alpha` is emitted from `STM_WITH_ALPHA`, a fixed constant in `bin/stm`.
**Never make generated Lua depend on palette content.** Palettes are untrusted
downloads; the moment a palette can contribute code, installing a theme becomes
running a stranger's Lua. If a config needs a function stm does not emit, that
belongs in the user's own `colors.lua` / `colors_user.lua`. `apply` never
touches those files.

## Adopt and the Lua wrap

`stm adopt` is the **only** command allowed to rename `colors.lua`, and it
does so at most once:

1. If `colors.lua` already `require`s `colors_generated`, it is already wired
   — leave it alone.
2. Otherwise rename the real file to `colors_user.lua` (follow a symlink; keep
   the symlink pointing at `colors.lua`) and write stm's own overlay wrapper
   as the new `colors.lua`.

The wrapper is a **trusted constant** in `bin/stm` (`STM_ADOPT_WRAPPER`), not
palette content. After that one write, `colors.lua` is user-owned again: stm
never rewrites the wrapper. `colors_user.lua` is the user's original module.
`verify` still checksums both.

A `sketchybarrc` / shell bar stays shell. adopt does not rewrite rc → SbarLua.
Layout scrape is data only; item files are never edited.

## Templates and the trust boundary

The rule that shapes most of the design: **a palette is untrusted data, a
template is trusted code.**

A palette may be downloaded from anywhere, so the only thing it ever
contributes to generated output is a value already validated as
`^0x[0-9a-f]{8}$`, an allowlisted layout enum or small integer, an item slot
(`left` / `right` / `center`), plus ASCII labels that land in comments. A
template lives in the user's own config directory, is written by them, and may
contain arbitrary Lua or shell. `stm` must never install a template from a
palette, and must never fetch one.

If you are tempted to let palette content reach generated code — a function, a
snippet, an "escape hatch" field — don't. Route it through a template instead.

Optional `[layout]` and `[items]` tables are the same kind of data: enums and
small integers for bar chrome, and `left` / `right` / `center` for item slots.
They must never contain Lua, shell, or paths. `stm` writes a generated overlay
(`layout_generated.lua` / `layout.sh`); it never rewrites the user's item files.
`adopt` may scrape `--bar` / `--add item` / `sbar.bar` / `sbar.add` into those
tables using the same allowlist; it still never edits item scripts.

The template substituter treats only `{{identifier}}` as a placeholder.
`{{1,2},{3,4}}` is ordinary Lua and must survive untouched, so anything after
`{{` that is not a lower-case identifier is literal text. An unrecognised
identifier is a hard error: shipping a half-substituted config is worse than
failing.

Multi-line expansions are passed to awk through files, not `-v`. BWK awk (the
macOS awk) rejects a newline inside a `-v` value.

## Tests

New behaviour comes with a test. So does every bug fix — write the test that
fails first.

```sh
tests/run.sh                                        # bash 3.2
STM_BASH="$(brew --prefix)/bin/bash" tests/run.sh   # bash 5.x
tests/run.sh test_apply_bash.sh                     # one file
```

The suite is plain bash, no `bats`. Each `tests/test_*.sh` sources
`tests/helpers.sh`, calls `setup_sandbox`, and ends with `finish`. Assertions
are grouped between `it "..."` and `done_it`.

Every test runs inside a `mktemp -d` with `HOME`, `XDG_CONFIG_HOME` and friends
redirected into it, and a stub `sketchybar` first on `PATH`. `setup_sandbox`
hard-fails if `HOME` did not actually move. **Do not write a test that touches a
real path** — there is no reason to, and the guard exists because the cost of
getting it wrong is someone's config.

If you are changing the `colors.sh` writer, add your case to
`tests/fixtures/bash-config/colors.sh`. That fixture is deliberately full of
hazards (a 10-digit hex literal, a lower-case variable name, a duplicated key,
odd indentation, mixed quoting) and the tests assert that all of them survive
untouched.

Malformed and hostile palettes live in `tests/fixtures/bad/`. If you add a
validation rule, add the fixture that trips it.

## Pull request checklist

- [ ] `tests/run.sh` passes
- [ ] `STM_BASH="$(brew --prefix)/bin/bash" tests/run.sh` passes
- [ ] `shellcheck -s bash bin/stm tests/*.sh` is silent
- [ ] `shellcheck -s sh install.sh` is silent
- [ ] New behaviour has a test; bug fixes have a regression test
- [ ] `stm help` and `README.md` describe any new flag or command
- [ ] No new dependency
- [ ] Palette files: name matches slug, all 15 keys, upstream values cited
- [ ] `stm doctor` still reports full coverage on a representative config
- [ ] `stm verify` is clean after an apply on a config with other files in it

## Reporting a bug

Include the output of `stm version`, `bash --version`, `stm --verbose <your
command>`, and whether your config is Lua or Bash. If `stm` corrupted a file,
please say so first — that jumps the queue.
