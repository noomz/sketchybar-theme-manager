#!/usr/bin/env bash
# item:menubar — the hook that runs `stm menubar refresh` (SPEC smart-menu
# B6, V13). The bundle carries no policy; these tests pin its wiring.

# shellcheck source=tests/helpers.sh
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "$0")" && pwd)/helpers.sh"

setup_sandbox

BUNDLE="$REPO_ROOT/bundles/items/menubar"
PLUGIN="$BUNDLE/plugin.sh"
STM_LOG="$SANDBOX/stm.argv"

cat >"$SANDBOX/stm-stub" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$STM_LOG"
EOF
chmod 755 "$SANDBOX/stm-stub"
export STM_LOG

it "lint item:menubar passes"
run_stm lint item:menubar
assert_status 0
done_it

it "install item:menubar wires the hook without touching the layout overlay (V13)"
D="$SANDBOX/cfg"
make_lua_config "$D"
run_stm --dir "$D" --no-reload install item:menubar
assert_status 0
assert_file_exists "$D/plugins/stm/menubar.sh"
assert_file_contains "$D/items_generated.lua" 'name = "stm.menubar",'
assert_file_contains "$D/items_generated.lua" '"display_change",'
assert_file_contains "$D/items_generated.lua" '"system_woke"'
assert_file_absent "$D/layout_generated.lua" "no overlay written"
assert_file_absent "$D/layout.sh" "no overlay written"
done_it

it "plugin runs stm menubar refresh for the item's config dir"
: >"$STM_LOG"
STM_BIN="$SANDBOX/stm-stub" STM_CONFIG_DIR="/cfg dir" SENDER=display_change sh "$PLUGIN"
assert_eq 0 "$?"
assert_eq "--dir /cfg dir menubar refresh --quiet" "$(cat "$STM_LOG")"
done_it

it "plugin without a config dir lets stm resolve it"
: >"$STM_LOG"
STM_BIN="$SANDBOX/stm-stub" STM_CONFIG_DIR="" sh "$PLUGIN"
assert_eq "menubar refresh --quiet" "$(cat "$STM_LOG")"
done_it

it "plugin exits quietly when stm cannot be run"
out=$(STM_BIN="$SANDBOX/missing-stm" sh "$PLUGIN" 2>&1)
assert_eq 0 "$?"
assert_eq "" "$out"
done_it

LUA_BIN=$(command -v lua 2>/dev/null || true)
if [ -n "$LUA_BIN" ]; then
  it "item.lua adds a hidden item that reconciles at load, on display change and on wake"
  cat >"$SANDBOX/probe.lua" <<'EOF'
local item_lua = ...
local sbar = {}
function sbar.add(kind, name, props)
  print(string.format("add %s %s position=%s drawing=%s updates=%s", kind, name,
    tostring(props.position), tostring(props.drawing), tostring(props.updates)))
  return { subscribe = function(_, events) print("subscribe " .. table.concat(events, " ")) end }
end
function sbar.exec(cmd) print("exec " .. cmd) end
dofile(item_lua)(sbar, { name = "stm.menubar", position = "right", plugin_dir = "/cfg/plugins/stm",
  events = { "display_change", "system_woke" }, options = {} }, {})
EOF
  out=$("$LUA_BIN" "$SANDBOX/probe.lua" "$BUNDLE/item.lua" 2>&1)
  assert_contains "$out" "add item stm.menubar position=right drawing=false updates=true"
  assert_contains "$out" "subscribe forced display_change system_woke"
  assert_contains "$out" "exec STM_CONFIG_DIR='/cfg' SENDER='forced' '/cfg/plugins/stm/menubar.sh'"
  done_it
fi

finish
