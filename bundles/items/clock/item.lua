-- stm.clock — the time. Installed by `stm install item:clock`; stm owns this
-- file and replaces it on `install --force`, so do not edit it.
--
-- The label comes from os.date, here in the bar's own Lua: no plugin, no
-- process per tick. Colours come only from `colors` (the active palette), so
-- `stm apply <theme>` recolours the item on reload.
return function(sbar, opts, colors)
  local o = opts.options

  -- os.date formats, picked by the (validated) options; never built from them.
  local formats = {
    ["24"] = { off = "%H:%M", on = "%H:%M:%S" },
    ["12"] = { off = "%I:%M %p", on = "%I:%M:%S %p" },
  }
  local format = formats[o.hours][o.seconds]
  local label = os.date(format)

  local icon = { string = "\u{F017}", color = colors.yellow }
  local props = {
    position = opts.position,
    update_freq = opts.update_freq,
    icon = icon,
    label = { string = label },
  }

  -- shape: plain draws no background. pill puts the item on bg1. split moves
  -- the icon onto its own sub-item, <name>.icon, on yellow with the icon in
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
      background = { drawing = true, color = colors.yellow },
    }
    props.icon = { drawing = false }
    props.background = { drawing = true, color = colors.bg1, padding_left = 0 }
  end

  if sub and opts.position ~= "right" then
    sbar.add("item", opts.name .. ".icon", sub)
  end
  local item = sbar.add("item", opts.name, props)
  if sub and opts.position == "right" then
    sbar.add("item", opts.name .. ".icon", sub)
  end

  -- The tick is every second; redraw only when the text changes.
  local function update()
    local s = os.date(format)
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
end
