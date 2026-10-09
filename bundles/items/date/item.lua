-- stm.date — the date. Installed by `stm install item:date`; stm owns this
-- file and replaces it on `install --force`, so do not edit it.
--
-- The label comes from os.date, here in the bar's own Lua: no plugin, no
-- process per tick. Colours come only from `colors` (the active palette), so
-- `stm apply <theme>` recolours the item on reload.
return function(sbar, opts, colors)
  local o = opts.options

  -- os.date formats, picked by the (validated) option; never built from it.
  -- The compact `short` form shows the day of the month alone.
  local formats = { iso = "%Y-%m-%d", short = "%a %d %b", compact = "%d" }
  local format = formats[o.format]
  local label = os.date(format)

  local icon = { string = "\u{F455}", color = colors.blue }
  local props = {
    position = opts.position,
    update_freq = opts.update_freq,
    -- compact mode may hide the item; a hidden item gets no events unless it
    -- asks for them (SketchyBar's default is when_shown).
    updates = true,
    icon = icon,
    label = { string = label },
  }

  -- shape: plain draws no background. pill puts the item on bg1. split moves
  -- the icon onto its own sub-item, <name>.icon, on blue with the icon in
  -- black; the label stays on bg1. The sub-item sits left of the label at
  -- every position, and right items are laid out right to left, so on the
  -- right the label goes in first.
  local sub
  if o.shape == "pill" then
    props.background = { drawing = true, color = colors.bg1 }
  elseif o.shape == "split" then
    icon.color = colors.black
    sub = {
      position = opts.position,
      icon = icon,
      label = { drawing = false },
      background = { drawing = true, color = colors.blue },
    }
    props.icon = { drawing = false }
    props.background = { drawing = true, color = colors.bg1, padding_left = 0 }
  end

  local icon_item
  if sub and opts.position ~= "right" then
    icon_item = sbar.add("item", opts.name .. ".icon", sub)
  end
  local item = sbar.add("item", opts.name, props)
  if sub and opts.position == "right" then
    icon_item = sbar.add("item", opts.name .. ".icon", sub)
  end

  -- compact mode (item:compact) sends the `stm_compact` event with
  -- STM_FORM_DATE: full | short (day of the month) | icon | hidden. Anything
  -- else is full.
  local forms = { full = true, short = true, icon = true, hidden = true }
  local form = "full"
  local key = "STM_FORM_" .. opts.name:gsub("^stm%.", ""):gsub("[.-]", "_"):upper()

  local function draw_form()
    local shown = form ~= "hidden"
    if icon_item then
      icon_item:set({ drawing = shown })
      item:set({ drawing = shown and form ~= "icon" })
    else
      item:set({ drawing = shown, label = { drawing = form ~= "icon" } })
    end
  end

  -- Redraw only when the day changes.
  local function update()
    local s = os.date(form == "short" and formats.compact or format)
    if s ~= label then
      label = s
      item:set({ label = { string = s } })
    end
  end

  local events = { "routine", "forced" }
  for _, ev in ipairs(opts.events or {}) do
    events[#events + 1] = ev
  end
  item:subscribe(events, update)

  sbar.add("event", "stm_compact")
  item:subscribe("stm_compact", function(env)
    local f = env and env[key]
    if not forms[f] then
      f = "full"
    end
    if f ~= form then
      form = f
      draw_form()
      update()
    end
  end)
end
