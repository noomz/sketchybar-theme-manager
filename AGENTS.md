# AGENTS.md

Operating rules for AI agents (and humans) working in this repo.

`stm` is a single bash script that switches [SketchyBar](https://github.com/FelixKratz/SketchyBar) colour themes on macOS. It reads a language-neutral TOML palette and writes a Lua module (`colors_generated.lua`), an in-place value swap into `colors.sh`, or a `config-examples/<slug>.sh` snippet (the `config-sh` format — `config.sh` itself is never edited). It writes into users' **live bar configs** — a bug here breaks someone's menu bar, so the constraints below are load-bearing, not stylistic.

## Repo layout

```
bin/stm                          # the whole product: one bash file (~4k lines), bash 3.2
palettes/*.toml                  # bundled themes (8); filename must equal slug
tests/                           # plain-bash suite (no bats); run via tests/run.sh
tests/test_*.sh                  # one file per area, sources tests/helpers.sh
tests/fixtures/                  # good + hostile fixtures (tests/fixtures/bad/ = malicious palettes)
Formula/sketchybar-theme-manager.rb   # Homebrew formula
install.sh                       # POSIX sh installer (linted with `sh -n`)
README.md                        # user docs — authoritative for commands/flags/behaviour
CONTRIBUTING.md                  # contributor rules — read before touching bin/stm
.github/workflows/ci.yml         # shellcheck + tests on bash 3.2 and 5 + palette validation
```

Version lives in `STM_VERSION` near the top of `bin/stm`.

## Commands

```sh
# Run the tool from the checkout (STM_ROOT points at bundled palettes):
STM_ROOT="$PWD" bin/stm list
STM_ROOT="$PWD" bin/stm preview tokyo-night
STM_ROOT="$PWD" bin/stm doctor
STM_ROOT="$PWD" bin/stm lint palettes/nord.toml
# install <spec> / uninstall|remove <slug>; --allow-host <host>; fetch failures exit 5
STM_ROOT="$PWD" bin/stm install --dry-run alice/themes/palettes/nord.toml

# Tests — always run both bash versions before finishing work:
tests/run.sh                                        # /bin/bash (3.2 on macOS, the floor)
STM_BASH="$(brew --prefix)/bin/bash" tests/run.sh   # bash 5.x
tests/run.sh test_toml.sh                           # a single file

# Lint — must produce ZERO output:
shellcheck -s bash bin/stm tests/*.sh
shellcheck -s sh install.sh
sh -n install.sh

# Palette validation (what CI does):
STM_ROOT="$PWD" bin/stm preview --porcelain <slug>
STM_ROOT="$PWD" bin/stm lint --porcelain <slug>
```

## Hard constraints (do not violate)

1. **bash 3.2 floor.** macOS ships bash 3.2.57 as `/bin/bash`. No `declare -A`, no `mapfile`/`readarray`, no `${v^^}`/`${v,,}`, no `[[ -v ]]`, no `local -n`, no globstar.
2. **BSD userland only.** No `sed -i` without an argument, no `grep -P`, no `readlink -f`, no `sort -V`, no `date -d`. Assume macOS (BWK) `awk`: no `gensub`, no ERE interval `{n}`, and no newline inside an `awk -v` value — pass multi-line expansions through files.
3. **Zero dependencies.** Only tools on a stock macOS install. If a fix needs something else, it doesn't go in.
4. **`LC_ALL=C` stays forced** (top of `bin/stm`). Glob ranges like `[!a-z0-9._-]` match uppercase under UTF-8 locales and silently defeat validation. Don't unset it locally.
5. **Atomic writes.** Always write a temp file in the destination directory, then `mv` into place (`commit_tmp`). Never leave a user file half-written. `assert_writable_target` guards the target — keep using it.
6. **`shellcheck` must be silent.** If a warning is genuinely wrong, add a targeted `# shellcheck disable=SCxxxx` with a comment explaining why.
7. **`bin/stm` stays one file.**

## Trust model — the core security design

**A palette is untrusted data. A template is trusted code.**

- Palettes are downloaded from the internet. They are parsed by awk only — **never `eval`'d, never `source`d**. Every key and value is validated against an allowlist before reaching generated output.
- The only things a palette may contribute to generated code: `^0x[0-9a-f]{8}$` colour literals, allowlisted layout enums (`top`/`bottom`, `on`/`off`, `left`/`right`/`center`), small integers, and ASCII labels in comments.
- **Never make generated output depend on palette content.** If you're tempted to let a palette carry a function, snippet, or "escape hatch" field — stop. That converts "install a theme" into "run a stranger's Lua/shell". Route such needs through the user's own template instead.
- `STM_WITH_ALPHA` and `STM_ADOPT_WRAPPER` are fixed trusted constants in `bin/stm`. Keep them constant.
- `stm` never installs a template from a palette. A palette may arrive over the network (`stm install`). It is still untrusted data: parsed by awk, never `eval`'d, never `source`d. The only commands that may make an outbound request are `install`, `search`, `login`, `logout`, `publish`, and `update`. `--allow-host <host>` may widen the HTTPS host allowlist for `install` only (still HTTPS-only). Everything else is offline: `apply`, `preview`, `list`, `doctor`, `verify`, `adopt`, `backup`, `restore`, `import`, `export`, `add`, `lint`, `uninstall`, `remove`. Tests stub `STM_FETCH` and must not talk to the internet. `stm lint` is the install/publish gate.
- A palette that fails allowlist validation is a hard error. Import and adopt scrape may *skip* a line (non-hex colour, unknown layout key, function position) and say so — that skip is the design. Never skip a *colour* the writer is about to emit, and never emit a half-substituted template.

## Behaviour invariants (tests pin these)

- `apply` **never touches `colors.lua`** (Lua configs get a new `colors_generated.lua`; `colors.sh` gets value-line swaps only — indentation, quoting, `export`-or-not, trailing comments, and non-palette variables survive byte-for-byte). After adopt it also must not touch `colors_user.lua`. `stm adopt` is the only command allowed to rename `colors.lua`, and at most once.
- stm **never edits item files**, `init.lua`, plugins, or `sketchybarrc`; layout is a generated overlay (`layout_generated.lua` / `layout.sh`).
- Lua dialect detection reads `colors.lua` and, after adopt, `colors_user.lua`. Never scan other `.lua` files (item definitions contain `bar = {...}` and false-positive). Flat/nested mapping lives in `STM_NESTED_MAP`.
- `colors.sh` writer: only literal `0x...` values matching a palette key are rewritten; reference lines like `export X=$SURFACE0` are left alone. First edit saves `colors.sh.stm-backup` once, never overwritten.
- Refuses to guess when both Lua and `colors.sh` exist (asks for `--format`). Detected format is kept — a shell bar stays a shell bar. `[output]` may not point at `colors.lua`, `colors_user.lua`, `.stm-state`, `.stm-manifest`, `stm.config.toml`, or `.stm-backups`.
- `verify` checksums every file stm does not own; keep the manifest logic consistent with what apply writes.
- Exit codes are documented: 0 ok, 1 bad palette, 2 config/format unresolved, 3 theme not found, 4 refuse-overwrite, 5 network/fetch, 64 usage error. Don't change them without updating README.

## Adopt

`stm adopt [slug]` (default slug `mine`) is the command that makes an existing bar themeable. It is also the easiest way to wreck one. Locked:

- **Snapshot first.** `backup --all pre-adopt` (or `pre-adopt-N` if that name exists). `--force` replaces `pre-adopt`. Later apply uses `--no-backup`; that snapshot is the undo (`stm restore pre-adopt`).
- **Lua wrap, do not parse.** If `colors.lua` already `require`s `colors_generated`, leave it. Else rename the real file to `colors_user.lua` (follow a symlink; keep the symlink pointing at `colors.lua`) and write `STM_ADOPT_WRAPPER` as the new `colors.lua`. Never insert a `pcall` into hand-written Lua. Never nest `colors_user_user`. `--force` may replace an existing `colors_user.lua`; without it, refuse the wrap (palette + snapshot still happen) and print the wrapper for paste.
- **Bash / `sketchybarrc` stay shell.** No wrap. No rc → SbarLua rewrite. `colors.sh` is already the apply target. `config-sh`: do not edit `config.sh`.
- **Layout scrape is conservative and data-only.** `--bar` / `--add item` / `sbar.bar` / `sbar.add` into `[layout]` / `[items]` using the same allowlist as the palette parser. Skip `color` / `border_color`, unknown keys, computed values, and function/ternary positions. First declaration wins. If nothing matches, omit the sections and say so.
- A hostile or unreadable `colors.lua` still gets a snapshot. Wrap is refused. No half-written wrapper.

## Testing rules

- Every new behaviour gets a test. Every bug fix gets a failing regression test **first**.
- Pattern: file sources `tests/helpers.sh`, calls `setup_sandbox`, groups assertions as `it "..."` … `done_it`, ends with `finish`. Use `run_stm` for invocations, `assert_*` for checks.
- **Never write a test that touches a real path.** Sandboxes redirect `HOME` / `XDG_*` into `mktemp -d` and **unset** `SKETCHYBAR_CONFIG_DIR` (so stm falls through to `$HOME/.config/sketchybar` inside the sandbox). `setup_sandbox` hard-fails if `HOME` didn't move.
- New writer behaviour for `colors.sh` → add the hazard to `tests/fixtures/bash-config/colors.sh` (it's deliberately full of traps: 10-digit hex, lowercase vars, duplicate keys, odd indentation, mixed quoting).
- New validation rule → add the hostile fixture that trips it to `tests/fixtures/bad/`.
- Test `bin/stm` via `run_stm` (which uses `$STM_BASH`) so the 3.2/5.x split both exercise the same code.

## Palettes

- Filename must equal `slug` (CI enforces). Slug: `[a-z0-9][a-z0-9._-]*`.
- All 15 colour keys required: `black white red green blue yellow orange magenta grey bg1 bg2 bar_bg bar_border popup_bg popup_border`. `transparent` auto-added if absent. Extras allowed.
- Values `0xAARRGGBB` (alpha first) or `#RRGGBB` (opaque). `#rgb` / `#aarrggbb` refused.
- `name`/`variant_label` ASCII only (letters, digits, space, `. _ ( ) + -`) — they land in generated comments. `Rose Pine`, not `Rosé Pine`.
- Use **upstream published values**; cite upstream slot names in a header comment (see `palettes/nord.toml`); note any substitution.
- Bundled palettes also carry the lowercase Catppuccin 26-colour bash-dialect keys (`rosewater`, `surface0`, `crust`, … — see the `# --- bash dialect` section of `palettes/nord.toml`). Match that exact key set when adding a palette.

## Housekeeping

- New flag or command → update `stm help` text **and** README in the same change.
- Don't commit runtime artifacts (already gitignored): `.stm-state`, `colors_generated.lua`, `*.stm-backup`, `*.stm-tmp.*`. Also leave `layout_generated.lua`, `layout.sh`, `.stm-manifest`, and `.stm-backups/` out of commits — they are live outputs.
- `.omc/`, `.claude/`, and `.pi/` are agent-tool scratch state — ignore, don't edit, don't commit.
- Pre-merge gate (the PR checklist in CONTRIBUTING.md): both test runs pass, both shellcheck runs silent, `sh -n install.sh` passes, all bundled palettes validate, name/slug match, `stm doctor` shows full coverage, `stm verify` clean after an apply in a populated config dir.
- README.md is the user-facing spec: if behaviour changes, README is stale — fix it in the same commit.
