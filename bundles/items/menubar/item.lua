-- stm.menubar — asks stm to reconcile the menu bar when the displays change.
-- Installed by `stm install item:menubar`; stm owns this file and replaces it
-- on `install --force`, so do not edit it.
--
-- The item draws nothing and decides nothing: `stm menubar refresh` reads
-- [menu_bar] smart_notch from stm.config.toml and owns every write.
return function(sbar, opts)
  local function quote(s)
    return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
  end

  local config_dir = opts.plugin_dir:match("^(.+)/plugins/stm$") or ""
  local plugin = quote(opts.plugin_dir .. "/menubar.sh")

  local item = sbar.add("item", opts.name, {
    position = opts.position,
    drawing = false,
    -- A hidden item gets no events unless it asks for them.
    updates = true,
  })

  local function run(e)
    local sender = (e and e.SENDER) or "forced"
    sbar.exec(string.format("STM_CONFIG_DIR=%s SENDER=%s %s", quote(config_dir), quote(sender), plugin))
  end

  local events = { "forced" }
  for _, ev in ipairs(opts.events or {}) do
    events[#events + 1] = ev
  end
  item:subscribe(events, run)
  -- Every config load (startup, reload) reconciles once.
  run()
end
