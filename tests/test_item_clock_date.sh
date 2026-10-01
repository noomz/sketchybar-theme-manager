#!/usr/bin/env bash
#
# bundles/items/clock and bundles/items/date (#19). Both are item.lua only: the
# label comes from os.date in the bar's own Lua. Runs each item.lua under Lua
# with a fake `sbar`, a frozen clock and traps on every way to start a process.
# Never touches the real bar.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

ITEMS="$REPO_ROOT/bundles/items"

# Glyphs (bash 3.2 printf has no \U): nf-fa-clock_o, nf-oct-calendar.
CLOCK=$(printf '\357\200\227')
CAL=$(printf '\357\221\225')

it "clock and date ship item.lua only, no plugin (V39, I.clk, I.date)"
for b in clock date; do
  assert_eq 'files = ["item.lua"]' "$(grep '^files' "$ITEMS/$b/item.toml")" "$b files"
  assert_file_absent "$ITEMS/$b/plugin.sh"
  STM_ROOT="$REPO_ROOT" run_stm --porcelain lint "item:$b"
  assert_status 0
done
done_it

it "manifests: defaults, colours, refresh (I.clk, I.date, V39)"
# manifest_line <bundle> <section or ""> <key> — the key's line in that section.
manifest_line() {
  awk -v sec="$2" -v key="$3" '
    /^\[/ { cur = $0; next }
    (sec == "" ? cur == "" : cur == "[options." sec "]") && $1 == key' "$ITEMS/$1/item.toml"
}
assert_eq 'colors = ["yellow", "bg1", "black"]' "$(manifest_line clock "" colors)" "clock colours"
assert_eq 'colors = ["blue", "bg1", "black"]' "$(manifest_line date "" colors)" "date colours"
assert_eq 'update_freq = 1' "$(manifest_line clock "" update_freq)" "clock refresh"
assert_eq 'update_freq = 60' "$(manifest_line date "" update_freq)" "date refresh"
for b in clock date; do
  assert_eq 'default = "split"' "$(manifest_line "$b" shape default)" "$b shape default"
  assert_eq 'events = ["system_woke"]' "$(manifest_line "$b" "" events)" "$b events"
done
assert_eq 'default = "24"' "$(manifest_line clock hours default)" "hours default"
assert_eq 'default = "off"' "$(manifest_line clock seconds default)" "seconds default"
assert_eq 'default = "iso"' "$(manifest_line date format default)" "format default"
done_it

it "install item:clock and item:date: item.lua and loader only, options reach the loader (V5, V39, I.fs, I.cfg)"
D="$SANDBOX/cfg"
make_lua_config "$D"
printf '[item.clock]\nhours = "12"\nseconds = "on"\n\n[item.date]\nformat = "short"\n' >"$D/stm.config.toml"
for b in clock date; do
  STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install "item:$b"
  assert_status 0
  assert_files_equal "$ITEMS/$b/item.lua" "$D/items/stm/$b.lua"
done
assert_file_absent "$D/plugins"
loader=$(cat "$D/items_generated.lua")
# block_of <bundle> — that item's stm_item(...) block in the loader.
block_of() {
  printf '%s\n' "$loader" | awk -v n="$1" '$0 == "stm_item(\"" n "\", {" { s = 1 } s; s && $0 == "})" { exit }'
}
for opt in '["hours"] = "12"' '["seconds"] = "on"' '["shape"] = "split"' 'update_freq = 1,'; do
  assert_contains "$(block_of clock)" "$opt"
done
for opt in '["format"] = "short"' '["shape"] = "split"' 'update_freq = 60,'; do
  assert_contains "$(block_of date)" "$opt"
done
printf '[item.clock]\nhours = "13"\n' >"$D/stm.config.toml"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install --force item:clock
assert_status 1
assert_contains "$STM_ERR" "hours"
assert_eq "$loader" "$(cat "$D/items_generated.lua")" "a bad option leaves the loader as it was"
done_it

LUA_BIN=$(command -v lua 2>/dev/null || true)
if [ -n "$LUA_BIN" ]; then
  mkdir -p "$SANDBOX/lua"
  cat >"$SANDBOX/lua/probe.lua" <<'EOF'
-- Runs item.lua with the given name, position and options (key=value...), on
-- a clock frozen at 2026-10-01 14:05:09. Prints each item it adds, in order,
-- with its props flattened (keys sorted), and the events it subscribes to.
-- Then ticks the subscription: once as is, then 1s, 60s and (a wake) a day later,
-- printing each `set` the item makes. Any process start prints `fork`.
local item_lua, name, position = ...
local options = {}
for i = 4, select("#", ...) do
  local k, v = select(i, ...):match("^([^=]+)=(.*)$")
  options[k] = v
end
local function dump(v)
  if type(v) ~= "table" then
    return tostring(v)
  end
  local keys = {}
  for k in pairs(v) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = k .. "=" .. dump(v[k])
  end
  return "{" .. table.concat(parts, " ") .. "}"
end
local now = os.time({ year = 2026, month = 10, day = 1, hour = 14, min = 5, sec = 9 })
local real_date = os.date
os.date = function(f, t) return real_date(f, t or now) end
os.execute = function() print("fork") end
io.popen = function() print("fork") end
local callback
local sbar = {}
function sbar.add(kind, n, props)
  print(kind .. " " .. n .. " " .. dump(props))
  return {
    subscribe = function(_, events, fn)
      print("subscribe " .. table.concat(events, " "))
      callback = fn
    end,
    set = function(_, props) print("set " .. n .. " " .. dump(props)) end,
  }
end
function sbar.exec() print("fork") end
local opts = { name = "stm." .. name, position = position, update_freq = 7,
  plugin_dir = "/p", events = { "system_woke" }, options = options }
dofile(item_lua)(sbar, opts, { yellow = 2, blue = 4, bg1 = 21, black = 22 })
print("tick")
callback({ SENDER = "routine" })
now = now + 1
print("tick +1s")
callback({ SENDER = "routine" })
now = now + 60
print("tick +61s")
callback({ SENDER = "routine" })
now = now + 86400
print("tick +1d")
callback({ SENDER = "system_woke" })
EOF
  # probe <bundle> <position> [key=value...] — everything the probe prints.
  probe() {
    local b="$1"
    shift
    TZ=UTC "$LUA_BIN" "$SANDBOX/lua/probe.lua" "$ITEMS/$b/item.lua" "$b" "$@" 2>&1
  }
  # items_of <bundle> <position> [key=value...] — just the items it adds.
  items_of() {
    probe "$@" | grep '^item '
  }
  # label_of <bundle> [key=value...] — the plain item's initial label.
  label_of() {
    local b="$1"
    shift
    items_of "$b" right shape=plain "$@" | sed -n 's/.* label={string=\(.*\)} position=.*/\1/p'
  }

  it "clock label: hours 24|12, seconds off|on (I.clk)"
  assert_eq "14:05" "$(label_of clock hours=24 seconds=off)" "24h"
  assert_eq "14:05:09" "$(label_of clock hours=24 seconds=on)" "24h + seconds"
  assert_eq "02:05 PM" "$(label_of clock hours=12 seconds=off)" "12h"
  assert_eq "02:05:09 PM" "$(label_of clock hours=12 seconds=on)" "12h + seconds"
  done_it

  it "date label: format iso|short (I.date)"
  assert_eq "2026-10-01" "$(label_of date format=iso)" "iso"
  assert_eq "Thu 01 Oct" "$(label_of date format=short)" "short"
  done_it

  # Each bundle: name | accent colour | glyph | the options besides shape.
  for c in "clock:2:$CLOCK:hours=24 seconds=off:14:05" "date:4:$CAL:format=iso:2026-10-01"; do
    b=${c%%:*}
    rest=${c#*:}
    accent=${rest%%:*}
    rest=${rest#*:}
    glyph=${rest%%:*}
    rest=${rest#*:}
    # shellcheck disable=SC2086 # word-split the option list on purpose
    set -- ${rest%%:*}
    label=${rest#*:}
    freq=7

    it "$b plain and pill: one item, accent on the icon, pill on bg1 (V32, V39, V14)"
    assert_eq "item stm.$b {icon={color=$accent string=$glyph} label={string=$label} position=right update_freq=$freq}" \
      "$(items_of "$b" right shape=plain "$@")" "plain"
    assert_eq "item stm.$b {background={color=21 drawing=true} icon={color=$accent string=$glyph} label={string=$label} position=left update_freq=$freq}" \
      "$(items_of "$b" left shape=pill "$@")" "pill"
    done_it

    it "$b split: icon sub-item on the accent, left of the label at every position (V32, V33, V10)"
    main="item stm.$b {background={color=21 drawing=true padding_left=0} icon={drawing=false} label={string=$label} position=POS update_freq=$freq}"
    sub="item stm.$b.icon {background={color=$accent drawing=true} icon={color=22 string=$glyph} label={drawing=false} position=POS}"
    assert_eq "${main//POS/right}
${sub//POS/right}" "$(items_of "$b" right shape=split "$@")" "split right"
    for pos in left center; do
      assert_eq "${sub//POS/$pos}
${main//POS/$pos}" "$(items_of "$b" "$pos" shape=split "$@")" "split $pos"
    done
    done_it

    it "$b subscribes routine, forced and the manifest events, and never starts a process (V39)"
    out=$(probe "$b" right shape=split "$@")
    assert_contains "$out" "subscribe routine forced system_woke"
    assert_not_contains "$out" "fork"
    done_it
  done

  it "clock sets its label only when the text changes (V39)"
  # Seconds off: the +1s tick stays in 14:05, the +61s tick reaches 14:06.
  assert_eq "tick
tick +1s
tick +61s
set stm.clock {label={string=14:06}}
tick +1d" "$(probe clock right shape=split hours=24 seconds=off | sed -n '/^tick$/,$p')" \
    "seconds off"
  # Seconds on: every tick that moves the clock sets the label.
  assert_eq "tick
tick +1s
set stm.clock {label={string=14:05:10}}
tick +61s
set stm.clock {label={string=14:06:10}}
tick +1d" "$(probe clock right shape=pill hours=24 seconds=on | sed -n '/^tick$/,$p')" \
    "seconds on"
  done_it

  it "date sets its label only when the day changes (V39)"
  assert_eq "tick
tick +1s
tick +61s
tick +1d
set stm.date {label={string=2026-10-02}}" "$(probe date right shape=split format=iso | sed -n '/^tick$/,$p')" \
    "next day"
  done_it
elif [ -n "${CI:-}" ]; then
  it "lua is available to run item.lua"
  _note_fail "lua not found; CI must run item.lua"
  done_it
else
  printf '# note: lua not found, item.lua not run\n'
fi

finish
