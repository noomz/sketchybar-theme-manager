#!/usr/bin/env bash
#
# bundles/items/expand (#31). item.lua only: a click fires stm_expand with
# STM_EXPAND on|off. Runs item.lua under Lua with a fake sbar and traps on
# every way to start a process or write a file. Never touches the real bar.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

ITEMS="$REPO_ROOT/bundles/items"
BUNDLE="$ITEMS/expand"

# Glyphs (bash 3.2 printf has no \U): nf-md-arrow-expand/collapse-horizontal.
OFF=$(printf '\363\260\241\216')
ON=$(printf '\363\260\241\214')

it "expand ships item.lua only, no plugin, no compact field (I.exp, V70)"
assert_eq 'files = ["item.lua"]' "$(grep '^files' "$BUNDLE/item.toml")"
assert_file_absent "$BUNDLE/plugin.sh"
assert_eq "" "$(grep '^compact' "$BUNDLE/item.toml")"
STM_ROOT="$REPO_ROOT" run_stm --porcelain lint item:expand
assert_status 0
done_it

it "manifest: left, plain|pill, white+bg1, no events (I.exp, V4, V32)"
assert_eq 'name = "expand"' "$(grep '^name' "$BUNDLE/item.toml")"
assert_eq 'version = "0.1.0"' "$(grep '^version' "$BUNDLE/item.toml")"
assert_eq 'default_position = "left"' "$(grep '^default_position' "$BUNDLE/item.toml")"
assert_eq 'colors = ["white", "bg1"]' "$(grep '^colors' "$BUNDLE/item.toml")"
assert_eq "" "$(grep '^events' "$BUNDLE/item.toml")"
assert_eq "" "$(grep '^update_freq' "$BUNDLE/item.toml")"
assert_eq 'values = ["plain", "pill"]' "$(grep -A 1 '^\[options.shape\]' "$BUNDLE/item.toml" | tail -n 1)"
assert_eq 'default = "plain"' "$(grep -A 2 '^\[options.shape\]' "$BUNDLE/item.toml" | tail -n 1)"
done_it

it "install item:expand: item.lua and loader only; split refused (V5, V9, V10, I.fs)"
D="$SANDBOX/cfg"
make_lua_config "$D"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install item:expand
assert_status 0
assert_files_equal "$BUNDLE/item.lua" "$D/items/stm/expand.lua"
assert_file_absent "$D/plugins/stm/expand.sh"
loader=$(cat "$D/items_generated.lua")
assert_contains "$loader" 'stm_item("expand"'
assert_contains "$loader" 'name = "stm.expand"'
assert_contains "$loader" 'position = "left"'
assert_contains "$loader" '["shape"] = "plain"'
assert_not_contains "$loader" 'update_freq'
printf '[item.expand]\nshape = "pill"\n' >"$D/stm.config.toml"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install --force item:expand
assert_status 0
loader=$(cat "$D/items_generated.lua")
assert_contains "$loader" '["shape"] = "pill"'
printf '[item.expand]\nshape = "split"\n' >"$D/stm.config.toml"
STM_ROOT="$REPO_ROOT" run_stm --dir "$D" --no-reload install --force item:expand
assert_status 1
assert_contains "$STM_ERR" "shape"
assert_eq "$loader" "$(cat "$D/items_generated.lua")" "a bad shape leaves the loader as it was"
done_it

LUA_BIN=$(command -v lua 2>/dev/null || true)
if [ -n "$LUA_BIN" ]; then
  mkdir -p "$SANDBOX/lua"
  cat >"$SANDBOX/lua/probe.lua" <<'EOF'
-- Runs item.lua with a shape. Prints each add, then two clicks. Any process
-- start or file write prints `fork`.
local item_lua, shape = ...
local function dump(v)
  if type(v) ~= "table" then return tostring(v) end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. dump(v[k]) end
  return "{" .. table.concat(parts, " ") .. "}"
end
os.execute = function() print("fork") end
io.popen = function() print("fork") end
io.open = function() print("fork") end
local clicks = {}
local sbar = {}
function sbar.add(kind, n, props)
  print("add " .. kind .. " " .. n .. " " .. dump(props))
  return {
    subscribe = function(_, events, fn)
      if type(events) == "string" then events = { events } end
      print("subscribe " .. n .. " " .. table.concat(events, " "))
      for _, e in ipairs(events) do
        if e == "mouse.clicked" then clicks[n] = fn end
      end
    end,
    set = function(_, p) print("set " .. n .. " " .. dump(p)) end,
  }
end
function sbar.exec() print("fork") end
function sbar.trigger(name, env)
  print("trigger " .. name .. " " .. dump(env))
end
dofile(item_lua)(sbar, { name = "stm.expand", position = "left", plugin_dir = "/p",
  events = {}, options = { shape = shape } }, { white = 1, bg1 = 2 })
print("loaded")
if clicks["stm.expand"] then
  clicks["stm.expand"]({ SENDER = "mouse.clicked" })
  print("clicked1")
  clicks["stm.expand"]({ SENDER = "mouse.clicked" })
  print("clicked2")
end
EOF
  probe() {
    "$LUA_BIN" "$SANDBOX/lua/probe.lua" "$BUNDLE/item.lua" "$1" 2>&1
  }

  it "lua: load off + no trigger; click on then off; only own name set (V10, V70, I.exp)"
  out=$(probe plain)
  assert_eq "" "$(printf '%s\n' "$out" | grep fork)" "no fork, no file"
  assert_contains "$out" "add event stm_expand"
  assert_contains "$out" "add item stm.expand {icon={color=1 string=$OFF} label={drawing=false} position=left}"
  assert_contains "$out" "subscribe stm.expand mouse.clicked"
  loaded=$(printf '%s\n' "$out" | sed -n '1,/^loaded$/p')
  assert_not_contains "$loaded" "trigger"
  assert_not_contains "$loaded" "set "
  click=$(printf '%s\n' "$out" | sed -n '/^loaded$/,$p' | grep -v '^loaded$')
  assert_eq "set stm.expand {icon={string=$ON}}
trigger stm_expand {STM_EXPAND=on}
clicked1
set stm.expand {icon={string=$OFF}}
trigger stm_expand {STM_EXPAND=off}
clicked2" "$click"
  assert_eq "" "$(printf '%s\n' "$out" | grep '^set ' | grep -v '^set stm.expand ')"
  assert_eq 0 "$(grep -cE '0x[0-9a-fA-F]{6,8}' "$BUNDLE/item.lua")" "no hex literal in item.lua"
  done_it

  it "lua shapes: plain has no background; pill is bg1 (I.exp, V32, V14)"
  plain=$(probe plain)
  pill=$(probe pill)
  assert_contains "$plain" "add item stm.expand {icon={color=1 string=$OFF} label={drawing=false} position=left}"
  assert_not_contains "$plain" "background="
  assert_contains "$pill" "add item stm.expand {background={color=2 drawing=true} icon={color=1 string=$OFF} label={drawing=false} position=left}"
  done_it
else
  printf '# SKIP item.lua probe: no lua\n'
fi

it "README Items expand: experimental, event only, no-notch gain, spaces.lua snippet (I.exp, C19)"
r=$(cat "$REPO_ROOT/README.md")
# shellcheck disable=SC2016  # table cell is literal backticks, not command subst
row='| `expand` |'
assert_contains "$r" "$row"
assert_contains "$r" 'experimental'
assert_contains "$r" 'stm install item:expand'
assert_contains "$r" 'STM_EXPAND'
assert_contains "$r" 'spaces.lua'
assert_contains "$r" 'spaces_expand_hold'
assert_contains "$r" 'updates = true'
assert_contains "$r" 'stm never hides another item'
assert_contains "$r" 'display with no notch'
done_it

finish
