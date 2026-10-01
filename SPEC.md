# SPEC — item bundles (epic #15): step 1 (#16), step 1b theme-driven items (#19)

## §G goal

stm install bundled SketchyBar item bundles via `stm install item:<name>`. first bundle = `tailscale` status item. theme switch recolour item. no item code cross network in step 1.

step 1b (#19): theme drive item *shape* via data. palette may set `[item.<name>]` option values (enum, checked vs bundled manifest); item code still only from stm release. shape = per-item option `plain|pill|split` (c|a|b). ship bundled `kanagawa-wave` palette. port author's split items (battery, calendar, net, spotify) to bundles so theme can reshape them.

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
- C10 step 1b: palette `[item.<name>]` = enum strings only. never code, path, install, fetch. C2 hold.
- C11 no global `[style]` section. shape + any geometry = per-item manifest option.
- C12 ported bundles generic: no personal path, no hard-coded hex, stock macOS only. user own items/plugins untouched (C4); user delete own copy by hand.
- C13 bundled palettes stay colour-only: no `[layout]` `[items]` `[item.<name>]`. theme shape live in user palette via `base =`.
- C14 step 1b commits + PR mention `#19` + epic #15.

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
  - option value per key: `stm.config.toml [item.<name>]` > palette `[item.<name>]` (after `base =` merge) > manifest `default`
- I.palopt palette table `[item.<name>]`, `key = "value"` strings. eg `[item.tailscale]` `shape = "pill"`
- I.shape manifest `[options.shape]` values ⊆ `plain|pill|split`. plain = c `<ic> <text>` no bg; pill = a `[ <ic> <text> ]`; split = b `[<ic>] [<text>]`
- I.kw `palettes/kanagawa-wave.toml`, slug `kanagawa-wave`, name `Kanagawa Wave`. source rebelot/kanagawa.nvim wave palette
- I.port bundles `battery` `calendar` `net` `spotify` ? data source + options fixed per task at build (read author plugins first)
- I.fs
  - `$RESOLVED_DIR/items/stm/<name>.lua`
  - `$RESOLVED_DIR/plugins/stm/<name>.sh` (0755)
  - `$RESOLVED_DIR/items_generated.lua` ("DO NOT EDIT" header)
  - ledger `${XDG_CONFIG_HOME:-~/.config}/stm/items` TSV `name  source  tree-sha256  ref  iso8601`; bundled → `source=bundled`, `ref=<STM_VERSION>`
- I.wire user add once: `require("items_generated")`
- I.ts CLI lookup: `$STM_TAILSCALE` if set (override, no fallback) → `/usr/local/bin/tailscale` → `/Applications/Tailscale.app/Contents/MacOS/Tailscale` → `/opt/homebrew/bin/tailscale` → `tailscale` on PATH. `status --json` fields: `BackendState`, `Self.TailscaleIPs/.DNSName/.HostName`, `Peer{}.DNSName/.HostName/.Online/.TailscaleIPs`, `ExitNodeStatus` (optional)
- I.tsopt tailscale options: `exit_node` `peers` `ip` ∈ `on|off` (default all `on`); `click` ∈ `popup|app` (default `popup`); `icon` ∈ `text|nerd|app` (default `text`); `shape` ∈ `plain|pill|split` (default `plain`)

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
- V10 SketchyBar item name always `stm.<name>`. only other names: split icon sub-item `stm.<name>.icon` (V33), popup rows `stm.<name>.row.*`.
- V11 uninstall remove only files under `items/stm/` + `plugins/stm/` + ledger row. refuse symlink / path outside. regen loader.
- V12 `items_generated.lua`, `items/stm/`, `plugins/stm/` excluded from `.stm-manifest` baseline + `verify` drift; included in owned backup.
- V13 `apply` regen `items_generated.lua` from ledger + config; stay offline; no ledger → no loader change.
- V14 `plugin.sh` + `item.lua` never hard-code hex. colours only from `colors` table (palette keys).
- V15 `tailscale status --json` bounded ~3s wall clock (bg job + watchdog `sleep 3` then kill; never count short sleeps — fork cost stretch them). hang → treat as unknown: grey icon, label `timeout`.
- V16 absent `ExitNodeStatus` ok. no CLI found → grey icon, label `not installed`, popup say same.
- V17 state→colour: Running=`green`, Starting|NeedsLogin=`yellow`, Stopped=`red`, not installed|unknown=`grey`.
- V18 `doctor` warn missing `require("items_generated")` only when ≥1 item installed.
- V19 palette ledger `~/.config/stm/installed` untouched by item commands.
- V20 `tests/run.sh` green bash 3.2 + 5. shellcheck silent incl `bundles/items/*/plugin.sh`.
- V21 bundled item dir resolve only: `$STM_ROOT/bundles/items` → `script_dir/../bundles/items` → `script_dir/../share/stm/bundles/items` (script_dir symlink-resolved). no absolute brew prefix probe (brew share link may be symlink? → V4 refuse).
- V22 `lint item:<name>` write nothing: config dir, item ledger, palette ledger byte-identical. valid → exit 0.
- V23 `doctor` key coverage ! skip stm-owned item code: `items/stm/`, `items_generated.lua`, `.stm-backups/`. item colour need checked only via manifest `colors` (V4).
- V24 tailscale peer name = first label of `Peer{}.DNSName` (MagicDNS name, as Tailscale app show). `HostName` only when `DNSName` empty. iOS report `HostName` = `localhost`. control chars (tab, newline…) stripped from `DNSName` + `HostName` before use → peer-set name never forge record / row. jq + plutil paths same.
- V25 tailscale `icon`: `text` → `TS`; `nerd` → nf-md-dots_grid U+F15FC (Nerd Fonts lack Tailscale brand glyph); `app` → `icon.background.image` = `app.<id>` (icon slot size to image; item `background.image` draw behind label), id = first of `io.tailscale.ipn.macsys`, `io.tailscale.ipn.macos` sketchybar resolve; none → `TS` text. image never tinted → `app` mode state colour (V17) always on `label.color` (resolved or fallback; fallback add `icon.color` too) → no stale label colour. `app` icon: `icon.background.color` = 0 (transparent, no palette colour → no pill from user defaults), `icon.background.image.scale` = 0.625 (32pt app image → 20pt). probe only when `SENDER` ∈ `forced|system_woke` or no valid cache; cache `${TMPDIR:-/tmp}/stm-tailscale-icon.<NAME>` = resolved id | `none`, written `mktemp` + `mv`, other content → probe. no image file shipped (V4 files set; trademark).
- V26 tailscale peer count include self: Running → label `online/total` = peers + this device (self always online). popup row `<NAME>.row.self` after exit row, before peers: `<self name>  <self ip>  (this device)`, green dot. self name same rule as V24 (`Self.DNSName` first label, else `HostName`). self never in peer rows, never counted twice. row + bar label join only non-empty parts (no name / no IP → no double gap). jq + plutil same.
- V27 palette `[item.<name>]` header: `<name>` ! match `[a-z][a-z0-9_-]*`; key ! `[a-z][a-z0-9_]*`; value ! `[a-z0-9][a-z0-9_-]{0,31}`. other dotted header | dup header | bad key/value → palette invalid (parse fail, same as bad `[layout]`).
- V28 palette option reach generated Lua only when value ∈ installed bundled item manifest `values`. unknown key | value ∉ `values` → stderr warning (palette slug + item + key), option ignored, fall through, `apply` exit 0. (≠ V9: config = user own → hard error; palette = foreign, may target other item version.)
- V29 option precedence per key: config > palette (`base =` merged, child win per key) > manifest `default`. loader bytes = f(ledger, config, active palette) — same whether written by `install`, `uninstall` or `apply`.
- V30 palette `[item.<name>]` never install | uninstall | fetch item. named item not installed → `apply` stderr once per item, exit 0, no extra write: bundled → `note: item:<name> not installed (stm install item:<name>)`; not bundled → `note: item:<name> is not a bundled item; the theme's options for it are ignored` (never suggest install).
- V31 `export` emit merged `[item.<name>]` tables; `add` | `import` round-trip byte-stable.
- V32 manifest `shape` values ⊄ `plain|pill|split` → V4 hard error. semantics fixed all bundles: plain = no item bg; pill = one item, `background.color` = `bg1`; split = `stm.<name>.icon` (icon only, bg = accent|state colour, icon colour `black`) + `stm.<name>` (label only, bg `bg1`). colours only palette keys (V14); manifest `colors` ∋ every key used.
- V33 split: icon sub-item visually left of label every position (`right` → add main then icon; `left|center` → icon then main). popup + click on main; icon sub-item `click_script` = main.
- V34 tailscale `shape` default `plain` → render identical to 0.6.0. pill: text|nerd → `icon.color` = state colour (V17); app → V25 rule (state on `label.color`). split: icon sub-item bg = state colour; app image draw over it.
- V35 bundled palettes colour-only (C13); CI fail if any carry `[layout]` `[items]` `[item.<name>]`. `kanagawa-wave` key set ⊇ `tokyo-night.toml` key set (canonical + bash 26-name + semantic); `stm lint` pass.
- V36 record transforms on colour data (`apply_mapping`, `apply_alpha`) key + rewrite only `color`/`extra` rows. every other record (`meta` `layout` `item` `itemopt`) pass byte-identical, any field count. item / option named like colour never replace colour.

## §T tasks

| id | status | task | cites |
|----|--------|------|-------|
| T1 | x | `tests/fixtures/bad-items/*` + `tests/test_items.sh` skeleton (red) | V3,V4 |
| T2 | x | awk manifest parser + validator, closed field set; bundled lookup; reachable via `stm lint item:<name>` | V1,V3,V4,V21,V22,I.bundle,I.cli |
| T3 | x | `bundles/items/tailscale/` item.toml + item.lua + plugin.sh | I.ts,I.tsopt,V14,V15,V16,V17 |
| T4 | x | plugin tests: fake `tailscale` (Running, Running+exit node, Stopped, NeedsLogin, Starting, hang, absent) + fake `sketchybar` log; jq + plutil paths | V15,V16,V17 |
| T5 | x | `item:` routing in `cmd_install`/`cmd_uninstall` before spec parse | V1,V2,V3 |
| T6 | x | install write path + ledger `stm/items` | V5,V6,V7,V8,V19,I.fs |
| T7 | x | `items_generated.lua` writer + `[item.<name>]` read + slot/default position | V9,V10,I.cfg |
| T8 | x | `apply` hook: regen loader + reload | V13 |
| T9 | x | `uninstall item:` | V11 |
| T10 | x | manifest / backup / verify exclusion lists (`bin/stm` ~3006, 3929, 4037, 5111) | V12 |
| T11 | x | `doctor`: installed items, version drift, wiring (`lua_file_is_wired`), CLI note | V18,V23,I.wire |
| T12 | x | `stm help`, README Items section, rewrite trust paras (README ~446, AGENTS.md ~68-76, CONTRIBUTING.md) | C2,I.cli |
| T13 | x | CI: `stm lint item:<name>` every bundled item, shellcheck plugins | V20,V22 |
| T14 | x | real-bar smoke: install, wire, `stm apply gruvbox`, switch theme → recolour | V10,V17 |
| T15 | x | Formula + `install.sh` ship `bundles/items/` (known files only) to `share/stm/bundles/items` | C3,V21 |
| T16 | x | tailscale peer name from `DNSName` first label, fallback `HostName`; fixture iOS peer `HostName=localhost`; jq + plutil | V24,I.ts |
| T17 | x | tailscale `icon` option (`text` `nerd` `app`; manifest + item.lua + plugin.sh + tests + README) | V25,V17,V14,I.tsopt |
| T18 | x | tailscale count self in `online/total` + popup self row `(this device)`; fixtures + jq/plutil tests + README | V26,V24,I.ts |
| T19 | x | tailscale review fixes: app-mode `label.color` always, strip control chars, non-empty label join, probe cache, transparent icon bg + scale; sparse-self fixture, Lua text/nerd/app test, generic fixture name | V24,V25,V26,V14 |
| T20 | x | tailscale `status` bound by watchdog `sleep 3` not tick loop; CI bash 3.2 hang test green | V15 |
| T21 | x | `palettes/kanagawa-wave.toml` (cite upstream) + tests: bundled count 8→9 (`test_cli.sh:175`), dialect/backup/verify loops, README theme list | V35,I.kw |
| T22 | x | red tests: palette `[item.<name>]` fixtures good + bad (header, key, value, other dotted, dup) | V27 |
| T23 | x | palette parser: `[item.<name>]` header → `itemopt` records; `base =` merge child win per key | V27,V29 |
| T24 | x | loader: palette opts into `STM_ITEM_OPTIONS_AWK` between config + default; warn + ignore bad | V28,V29,V9 |
| T25 | x | `apply` note for palette-named uninstalled items | V30 |
| T26 | x | `export` emit `[item.<name>]`; round-trip test | V31 |
| T27 | x | manifest lint: `shape` values ⊆ vocab; CI bundled palettes colour-only check | V32,V35,V4 |
| T28 | . | tailscale `shape`: manifest (+ `bg1` `black` colours) + item.lua + plugin.sh; tests plain = 0.6.0, pill, split left/right order, app+split | V32,V33,V34,V10,V14,I.tsopt |
| T29 | . | README: palette item options, shape vocab, precedence; trust paras AGENTS.md + CONTRIBUTING.md | C10,C13,I.palopt,I.shape |
| T30 | . | real-bar smoke: user palette `base = "kanagawa-wave"` + `[item.tailscale] shape = "pill"`; switch gruvbox → plain | V29,V34 |
| T31 | . | bundle `battery` (`shape` default `split`) ? source author `plugins/power.sh` | C12,V32,I.port |
| T32 | . | bundle `calendar` (`shape` default `split`) ? date + clock = 1 or 2 items | C12,V32,I.port |
| T33 | . | bundle `net` (`shape` default `split`) ? | C12,V32,I.port |
| T34 | . | bundle `spotify` ? popup + cover art; maybe drop | C12,V32,I.port |
| T35 | . | Formula + `install.sh` ship new bundles (known files only) | C3,V21 |

## §B bugs

| id | date | cause | fix |
|----|------|-------|-----|
| B1 | 2026-09-30 | `config_used_keys` scan every `*.lua` under config dir incl `items/stm/` + `.stm-backups/` → tailscale `item.lua` probe `colors.popup` → false `USED BUT MISSING popup`, doctor exit 1 | V23 |
| B2 | 2026-09-30 | tailscale plugin read `Peer{}.HostName`; iOS peer report `localhost` → popup show `localhost`, app show `iphone171` (`DNSName` first label) | V24 |
| B3 | 2026-09-30 | tailscale `icon=app` fallback set `icon.color` only; prior resolved run left `label.color` = old state → red `TS` beside green `stopped` | V25 |
| B4 | 2026-09-30 | tailscale parsers emit TAB/newline records; peer `HostName` w/ `\n` + `\t` forge extra online peer row + inflate count (display spoof) | V24 |
| B5 | 2026-09-30 | tailscale hang bound = 30 x `/bin/sleep 0.1` loop; fork cost on loaded CI runner stretch ~3s → 7s, hang test fail (bash 3.2 job) | V15 |
| B6 | 2026-09-30 | `apply_mapping` final awk keyed every non-meta record by `$2` (3 fields) → any `stm.config.toml` present: 4-field `itemopt` rows lose value + collapse per item (palette options → warning, default); also pre-existing: palette `[items] red = "left"` replace colour `red` after required-key check | V36 |
