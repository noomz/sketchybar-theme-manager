-- stm.battery — battery level and charging state. Installed by
-- `stm install item:battery`; stm owns this file and replaces it on
-- `install --force`, so do not edit it.
--
-- Colours come only from `colors` (the active palette), so `stm apply <theme>`
-- recolours the item on reload. plugin.sh reads pmset and sets the glyph,
-- the level and the state colour.
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

  local env = table.concat({
    "STM_GREEN=" .. quote(hex(colors.green)),
    "STM_YELLOW=" .. quote(hex(colors.yellow)),
    "STM_RED=" .. quote(hex(colors.red)),
    "STM_BAT_SHAPE=" .. quote(o.shape),
  }, " ")
  local plugin = quote(opts.plugin_dir .. "/battery.sh")

  local icon = { string = "\u{F008E}", color = colors.green }
  local props = {
    position = opts.position,
    update_freq = opts.update_freq,
    icon = icon,
    label = { string = "--%" },
  }

  -- shape: plain draws no background. pill puts the item on bg1. split moves
  -- the icon onto its own sub-item, <name>.icon, whose background plugin.sh
  -- sets to the state colour; the icon on it is black and the label stays on
  -- bg1. The sub-item sits left of the label at every position, and right
  -- items are laid out right to left, so on the right the label goes in first.
  local sub
  if o.shape == "pill" then
    props.background = { drawing = true, color = colors.bg1 }
  elseif o.shape == "split" then
    icon.color = colors.black
    sub = {
      position = opts.position,
      icon = icon,
      label = { drawing = false },
      background = { drawing = true, color = colors.green },
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

  local function run(e)
    local sender = (e and e.SENDER) or "forced"
    sbar.exec(string.format("%s NAME=%s SENDER=%s %s", env, quote(opts.name), quote(sender), plugin))
  end

  local events = { "routine", "forced" }
  for _, ev in ipairs(opts.events or {}) do
    events[#events + 1] = ev
  end
  item:subscribe(events, run)
  run()
end
