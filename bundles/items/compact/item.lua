-- stm.compact — compact mode. Installed by `stm install item:compact`; stm
-- owns this file and replaces it on `install --force`, so do not edit it.
--
-- plugin.sh measures the bar and sends one `stm_compact` event with the form
-- each item should draw; every item draws its own form. This item is only the
-- » chevron, shown while an item is hidden, with a popup row per hidden item.
-- Colours come only from `colors` (the active palette).
return function(sbar, opts, colors)
  local popup = type(colors.popup) == "table" and colors.popup or {}

  local function quote(s)
    return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
  end

  -- <name>:<priority>:<forms> per item with forms, from the generator
  -- (validated manifest and option values); plugin.sh checks them again.
  local env = "STM_COMPACT_UNITS=" .. quote(table.concat(opts.compact_units or {}, ","))
  local plugin = quote(opts.plugin_dir .. "/compact.sh")

  sbar.add("event", "stm_compact")

  -- Hidden until an item is hidden; plugin.sh shows it. A hidden item gets no
  -- events unless it asks for them (SketchyBar's default is when_shown).
  local item = sbar.add("item", opts.name, {
    position = "right",
    drawing = false,
    updates = true,
    update_freq = opts.update_freq,
    icon = { string = "»", color = colors.white },
    label = { drawing = false },
    background = { drawing = true, color = colors.bg1 },
    click_script = "sketchybar --set " .. quote(opts.name) .. " popup.drawing=toggle",
    popup = {
      align = "right",
      background = {
        color = colors.popup_bg or popup.bg,
        border_color = colors.popup_border or popup.border,
        border_width = 1,
        corner_radius = 6,
      },
    },
  })
  for i = 0, 15 do
    sbar.add("item", opts.name .. ".row." .. i, {
      position = "popup." .. opts.name,
      drawing = false,
      icon = { drawing = false },
      label = { string = "", color = colors.white },
    })
  end

  local function run(e)
    local sender = (e and e.SENDER) or "forced"
    sbar.exec(string.format("%s NAME=%s SENDER=%s %s", env, quote(opts.name), quote(sender), plugin))
  end

  local events = { "routine", "forced" }
  for _, ev in ipairs(opts.events or {}) do
    events[#events + 1] = ev
  end
  item:subscribe(events, run)
  item:subscribe("mouse.exited.global", function()
    item:set({ popup = { drawing = false } })
  end)
  run()
end
