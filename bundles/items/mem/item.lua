-- stm.mem — memory use as a graph and a percentage. Installed by
-- `stm install item:mem`; stm owns this file and replaces it on
-- `install --force`, so do not edit it.
--
-- Colours come only from `colors` (the active palette), so `stm apply <theme>`
-- recolours the item on reload. plugin.sh reads memory_pressure, pushes the
-- share in use onto the graph and colours the graph by the kernel's memory
-- pressure level.
return function(sbar, opts, colors)
  local o = opts.options

  -- 0xAARRGGBB for plugin.sh, or "" when this config lacks the colour.
  local function hex(c)
    if type(c) ~= "number" then
      return ""
    end
    return string.format("0x%08x", c)
  end

  local function quote(s)
    return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
  end

  -- The colour at alpha 0x40, for the area under the graph line.
  local function soft(c)
    if type(c) ~= "number" then
      return nil
    end
    return (c & ((1 << 24) - 1)) | (0x40 << 24)
  end

  local env = table.concat({
    "STM_GREEN=" .. quote(hex(colors.green)),
    "STM_YELLOW=" .. quote(hex(colors.yellow)),
    "STM_RED=" .. quote(hex(colors.red)),
    "STM_GREY=" .. quote(hex(colors.grey)),
  }, " ")
  local plugin = quote(opts.plugin_dir .. "/mem.sh")

  local icon = { string = "\u{EFC5}", color = colors.blue }
  local props = {
    position = opts.position,
    update_freq = opts.update_freq,
    icon = icon,
    label = { string = "--" },
    graph = { color = colors.grey, fill_color = soft(colors.grey), line_width = 1.0 },
  }

  -- shape: plain draws no background. pill puts the item on bg1. split moves
  -- the icon onto its own sub-item, <name>.icon, on blue with the icon in
  -- black; the graph and label stay on bg1. The sub-item sits left of the
  -- rest at every position, and right items are laid out right to left, so
  -- on the right the graph goes in first.
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

  if sub and opts.position ~= "right" then
    sbar.add("item", opts.name .. ".icon", sub)
  end
  local item = sbar.add("graph", opts.name, 30, props)
  if sub and opts.position == "right" then
    sbar.add("item", opts.name .. ".icon", sub)
  end

  -- plugin.sh sizes the label from the font the bar actually uses. A config
  -- batching its setup (sbar.begin_config) has not sent this item yet when
  -- it loads, so ask again on later runs until the bar answers.
  local metrics
  local function measure()
    if not metrics then
      local q = sbar.query(opts.name)
      local label = type(q) == "table" and q.label
      local size = type(label) == "table" and tonumber(tostring(label.font):match(":([%d.]+)$"))
      if size then
        local pad = (tonumber(label.padding_left) or 0) + (tonumber(label.padding_right) or 0)
        metrics = { string.format("%.2f", size * 0.61), string.format("%d", math.floor(pad)) }
      end
    end
    local m = metrics or { "", "" }
    return "STM_MEM_CW=" .. quote(m[1]) .. " STM_MEM_PAD=" .. quote(m[2])
  end

  local function run(e)
    local sender = (e and e.SENDER) or "forced"
    sbar.exec(string.format("%s %s NAME=%s SENDER=%s %s", env, measure(), quote(opts.name), quote(sender), plugin))
  end

  local events = { "routine", "forced" }
  for _, ev in ipairs(opts.events or {}) do
    events[#events + 1] = ev
  end
  item:subscribe(events, run)
  run()
end
