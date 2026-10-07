-- stm.disk — how full the startup disk is. Installed by
-- `stm install item:disk`; stm owns this file and replaces it on
-- `install --force`, so do not edit it.
return function(sbar, opts, colors)
  local o = opts.options

  local function hex(c)
    if type(c) ~= "number" then
      return ""
    end
    return string.format("0x%08x", c)
  end

  local function quote(s)
    return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
  end

  local env = table.concat({
    "STM_GREEN=" .. quote(hex(colors.green)),
    "STM_YELLOW=" .. quote(hex(colors.yellow)),
    "STM_RED=" .. quote(hex(colors.red)),
    "STM_GREY=" .. quote(hex(colors.grey)),
    "STM_DISK_SHAPE=" .. quote(o.shape),
  }, " ")
  local plugin = quote(opts.plugin_dir .. "/disk.sh")

  local icon = { string = "\u{F02CA}", color = colors.grey }
  local props = {
    position = opts.position,
    update_freq = opts.update_freq,
    icon = icon,
    label = { string = "--" },
  }

  local sub
  if o.shape == "pill" then
    props.background = { drawing = true, color = colors.bg1 }
  elseif o.shape == "split" then
    icon.color = colors.black
    sub = {
      position = opts.position,
      icon = icon,
      label = { drawing = false },
      background = { drawing = true, color = colors.grey },
    }
    props.icon = { drawing = false }
    props.background = { drawing = true, color = colors.bg1, padding_left = 0 }
  end

  -- Right items are laid out right to left, so on the right the label goes in
  -- first.
  if sub and opts.position ~= "right" then
    sbar.add("item", opts.name .. ".icon", sub)
  end
  local item = sbar.add("item", opts.name, props)
  if sub and opts.position == "right" then
    sbar.add("item", opts.name .. ".icon", sub)
  end

  -- A config batching its setup (sbar.begin_config) has not sent this item
  -- yet when it loads, so ask again on later runs until the bar answers.
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
    return "STM_DISK_CW=" .. quote(m[1]) .. " STM_DISK_PAD=" .. quote(m[2])
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
