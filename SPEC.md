# SPEC — item bundles, step 1 (#16, epic #15)

## §G goal

stm install bundled SketchyBar item bundles via `stm install item:<name>`. first bundle = `tailscale` status item. theme switch recolour item. no item code cross network in step 1.

## §C constraints

- C1 `bin/stm` stay one file. bash 3.2 compat. `shellcheck -s bash` silent.
- C2 palettes stay untrusted data. items = code. item code enter only via `item:` path, never palette path, never portal catalog.
- C3 step 1 = bundled only. source = `bundles/items/<name>/` in stm release.
- C4 stm never edit user files (`items/init.lua`, user items, `plugins/`, `sketchybarrc`, `colors.lua`). write only stm-owned `items/stm/`, `plugins/stm/`, `items_generated.lua`, ledger.
- C5 Lua dialect only v1. manifest declare `dialects`; other format refused.
- C6 regression test first (AGENTS.md). tests use `setup_sandbox` + `run_stm`. never touch real SketchyBar path. tests stub `STM_FETCH`.
- C7 no new hard runtime dep. `jq` optional; fallback `/usr/bin/plutil`. no `timeout` binary (macOS lack it).
- C8 `stm.config.toml` parser string-only → one key per option, no arrays.
- C9 commits + PR mention `#16`.

## §I interfaces

- I.cli
  - `stm install item:<name> [--force]`
  - `stm uninstall item:<name>` (alias `remove`)
  - `stm apply` → also regen `items_generated.lua`
  - `stm doctor` → item checks
  - `stm lint item:<name>` → validate bundled bundle only (manifest + files). offline. write nothing
  - `stm help` → lists `item:` forms
- I.bundle `bundles/items/<name>/`
  - `item.toml` closed fields: `name` `version` `dialects` `files` `colors` `default_position` `update_freq` `events` `[options.<key>]` (`values`, `default`)
  - `item.lua` → `return function(sbar, opts, colors)`
    - `opts = { name = "stm.<name>", position, plugin_dir (abs, validated), update_freq, events = {…}, options = { <key> = "<value>" } }`. `update_freq` + `events` from manifest. `options` nested → option key never collide w/ reserved field
    - `colors` = user `colors` module, flat or nested dialect (`popup_bg` | `popup.bg`)
  - `plugin.sh` → run via `sbar.exec` from `item.lua` callbacks (`routine` `forced` + manifest `events`). env prefix: `NAME` `SENDER`, colours (`0xAARRGGBB` from `colors`), options
- I.cfg
  - `[item.<name>]` in `stm.config.toml`: one string key per option
  - position: palette `[items] stm.<name> = "<pos>"` slot, else manifest `default_position`
- I.fs
  - `$RESOLVED_DIR/items/stm/<name>.lua`
  - `$RESOLVED_DIR/plugins/stm/<name>.sh` (0755)
  - `$RESOLVED_DIR/items_generated.lua` ("DO NOT EDIT" header)
  - ledger `${XDG_CONFIG_HOME:-~/.config}/stm/items` TSV `name  source  tree-sha256  ref  iso8601`; bundled → `source=bundled`, `ref=<STM_VERSION>`
- I.wire user add once: `require("items_generated")`
- I.ts CLI lookup: `$STM_TAILSCALE` if set (override, no fallback) → `/usr/local/bin/tailscale` → `/Applications/Tailscale.app/Contents/MacOS/Tailscale` → `/opt/homebrew/bin/tailscale` → `tailscale` on PATH. `status --json` fields: `BackendState`, `Self.TailscaleIPs`, `Peer{}.HostName/.Online/.TailscaleIPs`, `ExitNodeStatus` (optional)
- I.tsopt tailscale options: `exit_node` `peers` `ip` ∈ `on|off` (default all `on`); `click` ∈ `popup|app` (default `popup`)

## §V invariants

- V1 every `item:` command → zero `STM_FETCH` calls.
- V2 `item:` spec routed in `cmd_install`/`cmd_uninstall` before `stm_parse_install_spec`. palette spec never yield item files.
- V3 `item:<name>` name ! match `[a-z][a-z0-9_-]*` + exist under bundled `bundles/items/`. contain `/` `@` `..` `:` or scheme → hard error, nothing written.
- V4 manifest closed set. unknown field | manifest `name` ≠ bundle dir name | `dialects` value ∉ `lua|bash|config-sh` | colour ∉ `STM_REQUIRED_KEYS` | option `default` ∉ `values` | `files` entry w/ `/` `..` abs path | `files` ∌ `item.lua` or entry ∉ `item.lua|plugin.sh` | `default_position` ∉ `left|right|center` | file missing | symlink | non-regular → hard error, nothing written, exit ≠ 0.
- V5 install touch only: `items/stm/<name>.lua`, `plugins/stm/<name>.sh`, `items_generated.lua`, ledger row. every other file in config dir byte-identical.
- V6 all writes `mktemp_in` + `commit_tmp`. fail mid-install → prior state intact.
- V7 `RESOLVED_FORMAT != lua` | manifest `dialects` ∌ `lua` → refuse, nothing written.
- V8 ledger row exists w/o `--force` → `EX_EXISTS`, nothing written.
- V9 `[item.<name>]` value ∉ manifest `values` → hard error. unknown option key → hard error. generated Lua hold only validated enum values as string literals.
- V10 SketchyBar item name always `stm.<name>`.
- V11 uninstall remove only files under `items/stm/` + `plugins/stm/` + ledger row. refuse symlink / path outside. regen loader.
- V12 `items_generated.lua`, `items/stm/`, `plugins/stm/` excluded from `.stm-manifest` baseline + `verify` drift; included in owned backup.
- V13 `apply` regen `items_generated.lua` from ledger + config; stay offline; no ledger → no loader change.
- V14 `plugin.sh` + `item.lua` never hard-code hex. colours only from `colors` table (palette keys).
- V15 `tailscale status --json` bounded ~3s (bg job + kill). hang → treat as unknown: grey icon, label `timeout`?
- V16 absent `ExitNodeStatus` ok. no CLI found → grey icon, label `not installed`, popup say same.
- V17 state→colour: Running=`green`, Starting|NeedsLogin=`yellow`, Stopped=`red`, not installed|unknown=`grey`.
- V18 `doctor` warn missing `require("items_generated")` only when ≥1 item installed.
- V19 palette ledger `~/.config/stm/installed` untouched by item commands.
- V20 `tests/run.sh` green bash 3.2 + 5. shellcheck silent incl `bundles/items/*/plugin.sh`.
- V21 bundled item dir resolve only: `$STM_ROOT/bundles/items` → `script_dir/../bundles/items` → `script_dir/../share/stm/bundles/items` (script_dir symlink-resolved). no absolute brew prefix probe (brew share link may be symlink? → V4 refuse).
- V22 `lint item:<name>` write nothing: config dir, item ledger, palette ledger byte-identical. valid → exit 0.

## §T tasks

| id | status | task | cites |
|----|--------|------|-------|
| T1 | x | `tests/fixtures/bad-items/*` + `tests/test_items.sh` skeleton (red) | V3,V4 |
| T2 | x | awk manifest parser + validator, closed field set; bundled lookup; reachable via `stm lint item:<name>` | V1,V3,V4,V21,V22,I.bundle,I.cli |
| T3 | x | `bundles/items/tailscale/` item.toml + item.lua + plugin.sh | I.ts,I.tsopt,V14,V15,V16,V17 |
| T4 | . | plugin tests: fake `tailscale` (Running, Running+exit node, Stopped, NeedsLogin, Starting, hang, absent) + fake `sketchybar` log; jq + plutil paths | V15,V16,V17 |
| T5 | . | `item:` routing in `cmd_install`/`cmd_uninstall` before spec parse | V1,V2,V3 |
| T6 | . | install write path + ledger `stm/items` | V5,V6,V7,V8,V19,I.fs |
| T7 | . | `items_generated.lua` writer + `[item.<name>]` read + slot/default position | V9,V10,I.cfg |
| T8 | . | `apply` hook: regen loader + reload | V13 |
| T9 | . | `uninstall item:` | V11 |
| T10 | . | manifest / backup / verify exclusion lists (`bin/stm` ~3006, 3929, 4037, 5111) | V12 |
| T11 | . | `doctor`: installed items, version drift, wiring (`lua_file_is_wired`), CLI note | V18,I.wire |
| T12 | . | `stm help`, README Items section, rewrite trust paras (README ~446, AGENTS.md ~68-76, CONTRIBUTING.md) | C2,I.cli |
| T13 | . | CI: `stm lint item:<name>` every bundled item, shellcheck plugins | V20,V22 |
| T14 | . | real-bar smoke: install, wire, `stm apply gruvbox`, switch theme → recolour | V10,V17 |
| T15 | . | Formula + `install.sh` ship `bundles/items/` (known files only) to `share/stm/bundles/items` | C3,V21 |

## §B bugs

| id | date | cause | fix |
|----|------|-------|-----|
