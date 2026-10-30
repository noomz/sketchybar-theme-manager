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

  -- How the items are fitted, from the validated manifest and option values;
  -- anything the generator did not offer is shrink.
  local opt_mode = (opts.options or {}).mode
  local mode = (opt_mode == "page" or opt_mode == "groups") and opt_mode or "shrink"

  local function hex(c)
    return type(c) == "number" and string.format("0x%08x", c) or ""
  end

  local env = "STM_COMPACT_UNITS=" .. quote(table.concat(opts.compact_units or {}, ","))
  if mode == "groups" then
    -- <group>:<item>,<item> per group, from the generator (validated names).
    env = env .. " STM_COMPACT_GROUPS=" .. quote(table.concat(opts.groups or {}, ";"))
    env = env .. " STM_BG1=" .. quote(hex(colors.bg1))
  end
  if mode == "page" or mode == "groups" then
    -- plugin.sh colours the arrows / the inactive pills: white, or grey.
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

  -- groups mode (#35): one pill per group per display slot. A bar item's click
  -- event carries no display id, so each display gets its own pill per group
  -- and the display is the slot in the item's name; plugin.sh draws a pill only
  -- while its slot is a live display, and names the group in the click.
  -- Hidden until then; a group's items appear on the display that picked it.
  if mode == "groups" then
    for _, gspec in ipairs(opts.groups or {}) do
      local gname = tostring(gspec):match("^([a-z][a-z0-9_-]*):")
      if gname then
        for d = 1, 8 do
          local pill = sbar.add("item", opts.name .. "." .. gname .. "." .. d, {
            position = "right",
            drawing = false,
            icon = { drawing = false },
            label = { string = gname, color = colors.grey },
            background = { drawing = false },
          })
          pill:subscribe("mouse.clicked", function(e)
            run(e, "select:" .. gname .. ":" .. d)
          end)
        end
      end
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
