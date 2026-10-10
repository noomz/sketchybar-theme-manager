-- stm.compact — compact mode. Installed by `stm install item:compact`; stm
-- owns this file and replaces it on `install --force`, so do not edit it.
--
-- plugin.sh measures the bar and sends one `stm_compact` event with the form
-- each item should draw; every item draws its own form. This item is only the
-- » chevron, shown while an item is hidden, with a popup row per hidden item.
-- With the option mode = "page" it adds the ‹ › arrows instead (see below).
-- Colours come only from `colors` (the active palette).
return function(sbar, opts, colors)
  local popup = type(colors.popup) == "table" and colors.popup or {}

  local function quote(s)
    return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
  end

  -- <name>:<priority>:<forms> per item with forms, from the generator
  -- (validated manifest and option values); plugin.sh checks them again.
  local mode = (opts.options or {}).mode == "page" and "page" or "shrink"
  local env = "STM_COMPACT_UNITS=" .. quote(table.concat(opts.compact_units or {}, ","))
  if mode == "page" then
    -- plugin.sh colours the arrows: white, or grey at the end of the list.
    local function hex(c)
      return type(c) == "number" and string.format("0x%08x", c) or ""
    end
    env = "STM_WHITE=" .. quote(hex(colors.white)) .. " STM_GREY=" .. quote(hex(colors.grey)) .. " " .. env
  end
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

  local function run(e, action)
    local sender = (e and e.SENDER) or "forced"
    sbar.exec(string.format("STM_CMP_MODE=%s STM_CMP_ACTION=%s %s NAME=%s SENDER=%s %s",
      quote(mode), quote(action or ""), env, quote(opts.name), quote(sender), plugin))
  end

  -- page mode (#31): ‹ › slide the window of items the bar shows, one item a
  -- click. plugin.sh moves both to the right end of the bar, ‹ left of ›, so
  -- a step never moves them from under the pointer; it shows them while an
  -- item is out of the window and greys the one at its end. The » chevron
  -- stays hidden in this mode.
  if mode == "page" then
    for _, a in ipairs({ { "next", "›" }, { "prev", "‹" } }) do
      local arrow = sbar.add("item", opts.name .. "." .. a[1], {
        position = "right",
        drawing = false,
        icon = { string = a[2], color = colors.white },
        label = { drawing = false },
        background = { drawing = true, color = colors.bg1 },
      })
      arrow:subscribe("mouse.clicked", function(e)
        run(e, a[1])
      end)
    end
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
