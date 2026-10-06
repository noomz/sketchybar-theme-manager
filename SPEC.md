# SPEC — item bundles (epic #15): step 1 (#16), step 1b theme-driven items (#19), step 1c system stats items (#21)

## §G goal

stm install bundled SketchyBar item bundles via `stm install item:<name>`. first bundle = `tailscale` status item. theme switch recolour item. no item code cross network in step 1.

step 1b (#19): theme drive item *shape* via data. palette may set `[item.<name>]` option values (enum, checked vs bundled manifest); item code still only from stm release. shape = per-item option `plain|pill|split` (c|a|b). ship bundled `kanagawa-wave` palette. port author's split items (battery, calendar, net, spotify) to bundles so theme can reshape them.

step 1c (#21): bundle author's system stats items: `cpu` `mem` graphs, `disk` use, `netspeed` down/up rates + graphs. data from stock macOS tools only (no compiled event provider). label width stable (change only when char count change).

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
- C15 step 1c commits + PR mention `#21` + epic #15. no compiled helper, no new dep, no background provider process: data only from one plugin run per update.

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
- I.port bundles `battery` (→ I.bat) `clock` (→ I.clk) `date` (→ I.date) `net` (→ I.net) `spotify` (→ I.spot) data source + options fixed per task at build (read author plugins first). author `calendar.lua` = 2 split pieces → 2 bundles (one item each, V10)
- I.bat `battery`: data `/usr/bin/pmset -g batt` (one call/run) → `NN%` of `InternalBattery` line only (UPS line ignored; desktop + UPS = no battery) + `AC Power`. label `NN%`. glyph nf-md by %: 90-100 U+F008E, 60-89 U+F0091, 30-59 U+F0093, 10-29 U+F0096, 0-9 U+F0097; AC Power → U+F0E7. options `shape` ∈ `plain|pill|split` default `split`. events `power_source_change` `system_woke`, `update_freq` 120, `default_position` `right`
- I.clk `clock`: files `item.lua` only, label via Lua `os.date`. `hours` 24 → `%H:%M`, 12 → `%I:%M %p`; `seconds` on → `:%S` after `%M`. glyph nf-fa-clock_o U+F017, accent `yellow`. options `shape` ∈ `plain|pill|split` default `split`; `hours` ∈ `24|12` default `24`; `seconds` ∈ `off|on` default `off`. `update_freq` 1, events `system_woke`, `default_position` `right`
- I.date `date`: files `item.lua` only, label via Lua `os.date`. `format` iso → `%Y-%m-%d`, short → `%a %d %b`. glyph nf-oct-calendar U+F455, accent `blue`. options `shape` ∈ `plain|pill|split` default `split`; `format` ∈ `iso|short` default `iso`. `update_freq` 60, events `system_woke`, `default_position` `right`
- I.net `net`: SSID unreadable stock (macOS redact w/o Location Services) → show link, not SSID. primary if = first `PrimaryInterface` of one `/usr/sbin/scutil` run: `show State:/Network/Global/IPv4` then `…/IPv6` (IPv6-only link stay online; both absent → offline). split-tunnel VPN keep primary on physical if → show that link, not `VPN`. type: if `utun*|ipsec*|ppp*` → `VPN` nf-md-vpn U+F0582 (PPPoE also `VPN`, accepted); else `/usr/sbin/ipconfig getsummary <if>` `InterfaceType` `WiFi` → `Wi-Fi` nf-fa-wifi U+F1EB, `Ethernet` → `Ethernet` nf-md-ethernet U+F0200, other → `<if>` nf-md-lan U+F0318; offline → `offline` nf-md-wifi_off U+F05AA. options `shape` ∈ `plain|pill|split` default `split`; `label` ∈ `type|ip` default `type` (ip → first `inet` of `/sbin/ifconfig <if>` — `ipconfig getifaddr` fail on `utun*`; none → type label). events `wifi_change` `system_woke`, `update_freq` 10, `default_position` `right`
- I.spot `spotify`: names `stm.spotify` (+ `.icon` split), popup rows `stm.spotify.row.{cover,title,artist,album,shuffle,back,play,next,repeat,spacer,controls}` (`controls` = bracket). running check `/usr/bin/pgrep -xq -U <uid> Spotify` (this user only; not running → no osascript). every AppleScript start `if application id "com.spotify.client" is not running` → no-op (quit race: never launch) + `with timeout of 3 seconds`. data: one `/usr/bin/osascript` / update, `tell application id "com.spotify.client"` → `state␟name␟artist␟album␟artwork url␟shuffling␟repeating` (␟ = 0x1F, `character id 31`); `stopped` → state only. field = `missing value` → empty. state ∈ `playing|paused` + field count ≠ 7 (0x1F inside a field) → hide. visible when state ∈ `playing|paused`; else main (+ icon sub-item) `drawing=off` + `popup.drawing=off`. label `<name> - <artist>` (artist empty → album), `max_chars` 24 + `scroll_texts` on (longer text scroll, never grow into neighbours). popup: cover, title, artist, album rows; controls click → plugin `SENDER=mouse.clicked` `STM_SP_ACTION` ∈ `play|next|back|shuffle|repeat` → fixed AppleScript `playpause` | `next track` | `previous track` | `set shuffling to not shuffling` | `set repeating to not repeating`, then update. play row glyph: playing → pause, else play; shuffle/repeat `icon.highlight` = state. click main | icon sub-item → popup toggle; `mouse.exited.global` → popup off. trigger: item.lua `sbar.add("event", "stm_spotify_change", "com.spotify.client.PlaybackStateChanged")` + subscribe; manifest events `system_woke` `display_change`, `update_freq` 10 (catch quit). glyphs nf (SF Symbols need SF Pro font, C12): spotify nf-fa-spotify U+F1BC, shuffle nf-md-shuffle_variant U+F049D, back nf-md-skip_previous U+F04AE, play nf-md-play U+F040A, pause nf-md-pause U+F03E4, next nf-md-skip_next U+F04AD, repeat nf-md-repeat U+F0456. options `shape` ∈ `plain|pill|split` default `split`; `cover` ∈ `on|off` default `on`; `narrow` ∈ `right|center` default `right` (→ V43). `default_position` `center`
- I.cpu `cpu`: graph item (`sbar.add("graph", …, 30, …)`): icon nf-oct-cpu U+F4BC accent `orange` + graph + label `NN%`. data one `/usr/sbin/iostat -n0 -c 2 -w 1` / run (~1s): last line = 1s sample, load = `us` + `sy`, clamp 0..100. push `load/100`. graph colour = band (V45). options `shape` ∈ `plain|pill|split` default `split`. `update_freq` 2, events `system_woke`, `default_position` `right`
- I.mem `mem`: graph item width 30: icon nf-md-memory U+F035B accent `blue` + graph + label `NN%`. data `/usr/bin/memory_pressure -Q` `free percentage: NN%` → used = 100 − free; `/usr/sbin/sysctl -n kern.memorystatus_vm_pressure_level` → graph colour (V45). push `used/100`. options `shape` ∈ `plain|pill|split` default `split`. `update_freq` 5, events `system_woke`, `default_position` `right`
- I.disk `disk`: plain item, icon nf-md-harddisk U+F02CA + label `NN%`. data one `/bin/df -k /System/Volumes/Data` (path absent → `/`) → first `NN%` field (Capacity). state colour (V45) placement per V32. options `shape` ∈ `plain|pill|split` default `split`. `update_freq` 60, events `system_woke`, `default_position` `right`
- I.ns `netspeed`: primary if same as I.net (one `scutil`, V40 name check). rates = two `/usr/sbin/netstat -ibn -I <if>` snapshots around one `/bin/sleep 1`; `<Link#` row; counters from right (`$(NF-4)` Ibytes, `$(NF-1)` Obytes: `utun*` row has no Address column). label int + unit base 1000: `< 1000` → `NB`, `< 1e6` → `NK`, `< 1e9` → `NM`, else `NG` (≤ 4 chars). graph value = min(1, log10(bytes+1)/8). down `blue`, up `magenta`. options `shape` ∈ `plain|pill` default `pill`; `view` ∈ `unified|separate` default `unified` (→ V47). `update_freq` 2, events `system_woke` `wifi_change`, `default_position` `right`
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
- V10 SketchyBar item name always `stm.<name>`. only other names: split icon sub-item `stm.<name>.icon` (V33), popup rows `stm.<name>.row.*`, netspeed `stm.netspeed.up` `stm.netspeed.rates` `stm.netspeed.pill` (V47).
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
- V25 tailscale `icon`: `text` → `TS`; `nerd` → nf-md-dots_grid U+F15FC (Nerd Fonts lack Tailscale brand glyph); `app` → `icon.background.image` = `app.<id>` (icon slot size to image; item `background.image` draw behind label), id = first of `io.tailscale.ipn.macsys`, `io.tailscale.ipn.macos` sketchybar resolve; none → `TS` text. image never tinted → shape `plain|pill`: `app` mode state colour (V17) always on `label.color` (resolved or fallback; fallback add `icon.color` too) → no stale label colour. `app` icon: `icon.background.color` = 0 (transparent, no palette colour → no pill from user defaults), `icon.background.image.scale` = 0.625 (32pt app image → 20pt). probe only when `SENDER` ∈ `forced|system_woke` or no valid cache; cache `${TMPDIR:-/tmp}/stm-tailscale-icon.<NAME>` = resolved id | `none`, written `mktemp` + `mv`, other content → probe. no image file shipped (V4 files set; trademark).
- V26 tailscale peer count include self: Running → label `online/total` = peers + this device (self always online). popup row `<NAME>.row.self` after exit row, before peers: `<self name>  <self ip>  (this device)`, green dot. self name same rule as V24 (`Self.DNSName` first label, else `HostName`). self never in peer rows, never counted twice. row + bar label join only non-empty parts (no name / no IP → no double gap). jq + plutil same.
- V27 palette `[item.<name>]` header: `<name>` ! match `[a-z][a-z0-9_-]*`; key ! `[a-z][a-z0-9_]*`; value ! `[a-z0-9][a-z0-9_-]{0,31}`. other dotted header | dup header | bad key/value → palette invalid (parse fail, same as bad `[layout]`).
- V28 palette option reach generated Lua only when value ∈ installed bundled item manifest `values`. unknown key | value ∉ `values` → stderr warning (palette slug + item + key), option ignored, fall through, `apply` exit 0. (≠ V9: config = user own → hard error; palette = foreign, may target other item version.)
- V29 option precedence per key: config > palette (`base =` merged, child win per key) > manifest `default`. loader bytes = f(ledger, config, active palette) — same whether written by `install`, `uninstall` or `apply`.
- V30 palette `[item.<name>]` never install | uninstall | fetch item. named item not installed → `apply` stderr once per item, exit 0, no extra write: bundled → `note: item:<name> not installed (stm install item:<name>)`; not bundled → `note: item:<name> is not a bundled item; the theme's options for it are ignored` (never suggest install).
- V31 `export` emit merged `[item.<name>]` tables; `add` | `import` round-trip byte-stable.
- V32 manifest `shape` values ⊄ `plain|pill|split` → V4 hard error. semantics fixed all bundles: plain = no item bg; pill = one item, `background.color` = `bg1`; split = `stm.<name>.icon` (icon only, bg = accent|state colour, icon colour `black`) + `stm.<name>` (label only, bg `bg1`). colours only palette keys (V14); manifest `colors` ∋ every key used.
- V33 split: icon sub-item visually left of label every position (`right` → add main then icon; `left|center` → icon then main). popup + click on main; icon sub-item `click_script` = main.
- V34 tailscale `shape` default `plain` → render identical to 0.6.0. pill: text|nerd → `icon.color` = state colour (V17); app → V25 rule (state on `label.color`). split: state colour only on icon sub-item bg (no `label.color`, no `icon.color`; icon stay `black`); app image draw over it. label empty → main `background.drawing=off`, else `on` → only icon part show. main `background.padding_left` = 0 (gap = icon part `padding_right`, as author own split items).
- V35 bundled palettes colour-only (C13); CI fail if any carry `[layout]` `[items]` `[item.<name>]`. `kanagawa-wave` key set ⊇ `tokyo-night.toml` key set (canonical + bash 26-name + semantic); `stm lint` pass.
- V36 record transforms on colour data (`apply_mapping`, `apply_alpha`) key + rewrite only `color`/`extra` rows. every other record (`meta` `layout` `item` `itemopt`) pass byte-identical, any field count. item / option named like colour never replace colour.
- V37 palette w/ `base =` may carry zero colours (empty or absent `[colors]`); required keys checked on merged chain only. no `base` + no colours → still invalid (`no [colors] table found`).
- V38 battery state colour: AC Power → `green`; else % ≤ 15 → `red`, ≤ 30 → `yellow`, else `green`. colour on `icon.color` (plain|pill) or icon sub-item bg (split, V32). no `%` in pmset (no battery) → item + icon sub-item `drawing=off`; `%` present → `drawing=on`. manifest `colors` = `green yellow red bg1 black`.
- V39 clock + date: label from `os.date` inside `item.lua`; no `plugin.sh`, no `sbar.exec` / fork per tick. item `set` label only when string change (1s tick + seconds off → ≤ 1 redraw/min). `os.date` format only from fixed table keyed by validated option (V9) → option value never reach `os.date`. accent fixed (clock `yellow`, date `blue`), not state: plain|pill → `icon.color` = accent; split → icon sub-item bg = accent, icon `black` (V32). manifest `colors` = accent + `bg1 black`.
- V40 net state colour: online → `magenta`, offline → `red`; on `icon.color` (plain|pill) or icon sub-item bg (split, V32). `<if>` ! match `[a-z][a-z0-9]*` else offline (never reach argv / label unchecked); ip label ! match `[0-9.]+` else type label. plugin run `LC_ALL=C` → glob / awk classes byte-wise, never locale ranges (B8). one `scutil`, ≤ 1 `ipconfig`, ≤ 1 `ifconfig`, one `sketchybar` call / run. `STM_SCUTIL` `STM_IPCONFIG` `STM_IFCONFIG` override paths (tests). manifest `colors` = `magenta red bg1 black`.
- V41 spotify: cover fetched only when `cover` = `on` + artwork url ! match `https://i.scdn.co/image/` + `<id>` `[0-9a-f]{1,64}` → `/usr/bin/curl --proto =https --max-time 5 -fsS` into `<dir>/stm-spotify-cover.<NAME>.<id>`, `<dir>` = `${TMPDIR:-$(getconf DARWIN_USER_TEMP_DIR)}` (per-user; SketchyBar run w/o `TMPDIR`, never shared `/tmp`) (mktemp + mv; temp removed on exit); file regular + ! symlink → no fetch (dir per-user 0700 → only own files) (name = cache key, no url sidecar → no cross-run mismatch); after fetch other covers of `<NAME>` removed. `background.image` sent only when fetched this run | `SENDER` ∈ `forced|system_woke` (no reload of same image every tick). bad url | fetch fail | `cover=off` → cover row `drawing=off`, no curl. track fields: bytes 0x00-0x1E → space before split → no forged argv / row. action ∉ set → no action osascript. plugin `LC_ALL=C` (B8). plugin send no colour: colours fixed palette keys in item.lua — accent `magenta` (icon plain|pill; sub bg split), popup bg `popup_bg` | `popup.bg`, border `popup_border` | `popup.border`, controls bracket `green`, play button `red` + icon `white`, control icons `black`, highlight `white`. manifest `colors` = `magenta green red white black bg1 popup_bg popup_border`. `STM_PGREP` `STM_OSASCRIPT` `STM_CURL` override paths (tests).
- V42 item that may set own `drawing=off` (battery no battery, spotify not playing) ! main item `updates = true`: SketchyBar default `when_shown` deliver no routine / custom / system event to hidden item → never come back until reload (B9).
- V43 spotify narrow screen: configured position `center` + `narrow` = `right` + main display (`sketchybar --query displays`, `arrangement-id` 1) `w` < 1800 → main item `position=right` + `popup.align=right` + `--move <NAME> after <last of --query bar items>` (right laid out right → left by index → spotify leftmost of right items; last unknown | is own → no move); else `position=center` + `popup.align=center`. split: icon sub-item same position, then `--move <NAME>.icon` `after` main on right | `before` main on center → icon left of label (V33). sent only when main's queried position known + ≠ wanted (no reorder every tick; empty reply → no move). `SENDER=display_change` (fire on every active-display switch too) → placement only, no pgrep / osascript, only while main `drawing=on`. main display width rule every display bar show on (one item, one position). width unknown | configured position ≠ `center` | `narrow` = `center` → never move. only `stm.spotify*` names moved (V10).
- V44 cpu mem disk netspeed data: stock macOS tools only, no compiled helper / provider process / `killall`. per run: cpu one `iostat` (~1s); mem one `memory_pressure` + one `sysctl`; disk one `df`; netspeed one `scutil`, ≤ 2 `netstat`, ≤ 1 `sleep 1` (no if → no netstat, no sleep); one `sketchybar` call. `STM_IOSTAT` `STM_MEMORY_PRESSURE` `STM_SYSCTL` `STM_DF` `STM_DATA_VOLUME` `STM_SCUTIL` `STM_NETSTAT` `STM_SLEEP` override (tests). plugin `LC_ALL=C` (B8). tool output parsed by awk, only digits reach label / argv: cpu `us` `sy` ! `[0-9]+`; mem free ! `[0-9]+` ≤ 100; disk `[0-9]+%`; netstat counters ! `[0-9]+`. unreadable | absent tool → label `--`, no `--push` (cpu, mem), colour `grey` (cpu graph, mem graph via level, disk state). netspeed: no if | counter missing | counter went back → that rate 0 + label `--`.
- V45 colour bands (one table each, colours only palette keys V14): cpu load < 30 `green`, < 60 `yellow`, < 80 `orange`, else `red`; mem pressure level 1 `green`, 2 `yellow`, 4 `red`, other `grey`; disk use < 80 `green`, < 90 `yellow`, else `red`. graph line = band colour; graph fill = same palette value w/ alpha byte → `0x40` (derived, never literal). cpu accent `orange`, mem accent `blue` fixed (icon plain|pill, sub-item bg split, V32); disk state colour on `icon.color` (plain|pill) | sub-item bg (split). manifest `colors`: cpu `orange green yellow red grey bg1 black`; mem `blue green yellow red grey bg1 black`; disk `green yellow red grey bg1 black`; netspeed `blue magenta bg1`.
- V46 stable label: plugin set `label.width` w/ every label = pad + ceil(chars × CW). `label.width` = whole label incl both paddings (SketchyBar `text_get_length`). CW = label font size × 0.61; pad = `label.padding_left` + `label.padding_right`; both from `sbar.query(<item>).label` (`font` = `Family:Style:Size`) in item.lua, queried lazily on first run that answer (begin_config batch may hide new item), cached. no font size → no `label.width` sent (never guess). text left aligned. no hard-coded font family.
- V47 netspeed `view`: `unified` = `stm.netspeed` graph (icon nf-md-swap_vertical U+F06F3 `blue`, label off, down graph filled `blue`) + `stm.netspeed.up` graph (icon + label off, up line `magenta` 1.5, fill transparent `0`) overlaid on down graph via `stm.netspeed` `background.padding_right` = −30 (bg drawing on, colour `0`) + `.up` `background.padding_left` = 0 + `stm.netspeed.rates` text: icon slot `↑<up>` top (`icon.width` 0, `y_offset` +6, `magenta`), label `↓<down>` bottom (`y_offset` −5, `blue`, `padding_left` 0); both font = user label family:style at size − 3 (min 8); `label.width` per V46 on longer line. `separate` = `stm.netspeed` down (nf-md-download U+F01DA `blue` + graph + label) + `stm.netspeed.up` up (nf-md-upload U+F0552 `magenta` + graph + label), no `.rates`. visual left → right same every position: unified `netspeed` `.up` `.rates`; separate `netspeed` `.up` (`right` → add in reverse). shape: unified pill = bracket `stm.netspeed.pill` `bg1` over 3 items, plain = no bracket (members always bg colour `0`); separate pill = each item `bg1`, plain = no bg. plugin send no colour.

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
| T28 | x | tailscale `shape`: manifest (+ `bg1` `black` colours) + item.lua + plugin.sh; tests plain = 0.6.0, pill, split left/right order, app+split | V32,V33,V34,V10,V14,I.tsopt |
| T29 | x | README: palette item options, shape vocab, precedence; trust paras AGENTS.md + CONTRIBUTING.md | C10,C13,I.palopt,I.shape |
| T30 | x | real-bar smoke: user palette `base = "kanagawa-wave"` + `[item.tailscale] shape = "pill"`; switch gruvbox → plain | V29,V34 |
| T31 | x | bundle `battery` (`shape` default `split`) from author `plugins/power.sh`; tests plain/pill/split, levels, charging, no battery | C12,V32,V33,V38,I.bat |
| T32 | x | bundles `clock` + `date` (`shape` default `split`, item.lua only) from author `items/calendar.lua`; tests plain/pill/split order, hours, seconds, format, set only on change | C12,V32,V33,V39,I.clk,I.date,I.port |
| T33 | x | bundle `net` (`shape` default `split`) from author `items/net.lua`; fake scutil/ipconfig/ifconfig: Wi-Fi, Ethernet, VPN, other, no type, IPv6-only, offline, bad if name (UTF-8 locale), ip mode incl VPN; lint + install | C12,V32,V33,V40,I.net,I.port |
| T34 | x | bundle `spotify` (`shape` default `split`, popup + cover + controls) from author `items/spotify.lua`; fake pgrep/osascript/curl: not running, stopped, playing, paused, no artist, control chars, cover cache/bad url/fail/off, actions, 0x1F field, missing value; scripts compile (osacompile, Spotify.app only); Lua probe names + order + `updates`; lint + install; battery `updates = true` | C12,V10,V32,V33,V41,V42,I.spot,I.port |
| T35 | x | Formula + `install.sh` ship new bundles (known files only) | C3,V21 |
| T36 | x | README Items: every bundled item (battery clock date net spotify tailscale), options + data source + limits (SSID hidden, cover download); help text if it names items | I.bat,I.clk,I.date,I.net,I.spot,I.tsopt,C12 |
| T37 | x | spotify: label `max_chars` 24 + `scroll_texts`; `narrow` option → right on narrow main display (< 1800 pt), split icon kept left via `--move`; `display_change` event; tests: wide, narrow, leftmost of right items, split order, already placed, unknown width, empty reply, display_change visible/hidden, configured left, narrow=center; README `narrow` + scroll | V33,V43,V10,I.spot |
| T38 | x | SPEC step 1c (#21): §G §C §I.cpu .mem .disk .ns, V10 amend, V44-V47, §T | C15,V10,V44,V45,V46,V47 |
| T39 | x | bundle `cpu`; fake iostat: bands 29/30/59/60/79/80, us+sy > 100, malformed, absent; label width; shapes + split order; Lua probe add/query; lint + install | V32,V33,V44,V45,V46,I.cpu |
| T40 | x | bundle `mem`; fake memory_pressure + sysctl: levels 1/2/4/other, malformed, absent; label width; shapes; Lua probe; lint + install | V32,V33,V44,V45,V46,I.mem |
| T41 | x | bundle `disk`; fake df: bands 79/80/89/90, Data absent → `/`, malformed, absent; plain/pill/split colour placement; Lua probe; lint + install | V32,V33,V44,V45,V46,I.disk |
| T42 | . | bundle `netspeed`; fake scutil/netstat/sleep: en0, utun (no Address), units B/K/M/G bounds, counter reset, offline, bad if name; unified + separate argv; Lua probe names + add order right/left + overlay padding + bracket + small font; lint + install | V10,V40,V44,V46,V47,I.ns |
| T43 | . | ship: packaging test lists new bundles (Formula + install.sh already generic); README Items: cpu mem disk netspeed options + data source + limits | C3,V21,I.cpu,I.mem,I.disk,I.ns |

## §B bugs

| id | date | cause | fix |
|----|------|-------|-----|
| B1 | 2026-09-30 | `config_used_keys` scan every `*.lua` under config dir incl `items/stm/` + `.stm-backups/` → tailscale `item.lua` probe `colors.popup` → false `USED BUT MISSING popup`, doctor exit 1 | V23 |
| B2 | 2026-09-30 | tailscale plugin read `Peer{}.HostName`; iOS peer report `localhost` → popup show `localhost`, app show `iphone171` (`DNSName` first label) | V24 |
| B3 | 2026-09-30 | tailscale `icon=app` fallback set `icon.color` only; prior resolved run left `label.color` = old state → red `TS` beside green `stopped` | V25 |
| B4 | 2026-09-30 | tailscale parsers emit TAB/newline records; peer `HostName` w/ `\n` + `\t` forge extra online peer row + inflate count (display spoof) | V24 |
| B5 | 2026-09-30 | tailscale hang bound = 30 x `/bin/sleep 0.1` loop; fork cost on loaded CI runner stretch ~3s → 7s, hang test fail (bash 3.2 job) | V15 |
| B6 | 2026-09-30 | `apply_mapping` final awk keyed every non-meta record by `$2` (3 fields) → any `stm.config.toml` present: 4-field `itemopt` rows lose value + collapse per item (palette options → warning, default); also pre-existing: palette `[items] red = "left"` replace colour `red` after required-key check | V36 |
| B7 | 2026-10-01 | per-link palette parse `fail_end("no [colors] table found")` when ncolors=0 even w/ `base =` → shape-only child (`base = "kanagawa-wave"` + `[item.tailscale] shape = "pill"`, C13 route) refused; base-child tests all carried dummy colour | V37 |
| B8 | 2026-10-01 | net `plugin.sh` if-name check `[!a-z]` / `*[!a-z0-9]*` locale-dependent: SketchyBar inherit `LANG=*.UTF-8` → bash 3.2 `sh` accept `EN0` `é0` → V40 boundary hold only in C locale; tests ran `env -i` (C) → miss. found in review pre-commit | V40 |
| B9 | 2026-10-01 | spotify (pre-commit review) + battery (T31, shipped) set `drawing=off` on self, no `updates` → SketchyBar `when_shown` default stop routine / custom / system events to hidden item → spotify start hidden + never show; battery hidden after transient pmset fail stay hidden until reload. probes never checked `updates` | V42 |
| B10 | 2026-10-01 | spotify cover cache `${TMPDIR:-/tmp}`: live SketchyBar has no `TMPDIR` → shared `/tmp`, name predictable (public artwork id) → other local user pre-create file (`-s` accept, foreign image) or squat path (sticky `/tmp`, `mv` fail). tests always set `TMPDIR`. found in review pre-commit | V41 |
