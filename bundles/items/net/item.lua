-- stm.net — the network link: Wi-Fi, Ethernet, VPN or offline. Installed by
-- `stm install item:net`; stm owns this file and replaces it on
-- `install --force`, so do not edit it.
--
-- Colours come only from `colors` (the active palette), so `stm apply <theme>`
-- recolours the item on reload. plugin.sh reads the primary interface and
-- sets the glyph, the label and the state colour.
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
    "STM_MAGENTA=" .. quote(hex(colors.magenta)),
    "STM_RED=" .. quote(hex(colors.red)),
    "STM_NET_SHAPE=" .. quote(o.shape),
    "STM_NET_LABEL=" .. quote(o.label),
  }, " ")
  local plugin = quote(opts.plugin_dir .. "/net.sh")

  local icon = { string = "\u{F1EB}", color = colors.magenta }
  local props = {
    position = opts.position,
    update_freq = opts.update_freq,
    -- compact mode may hide the item; a hidden item gets no events unless it
    -- asks for them (SketchyBar's default is when_shown).
    updates = true,
    icon = icon,
    label = { string = "--" },
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
      background = { drawing = true, color = colors.magenta },
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

  local function run(e)
    local sender = (e and e.SENDER) or "forced"
    sbar.exec(string.format("%s NAME=%s SENDER=%s %s", env, quote(opts.name), quote(sender), plugin))
  end

  local events = { "routine", "forced" }
  for _, ev in ipairs(opts.events or {}) do
    events[#events + 1] = ev
  end
  item:subscribe(events, run)
  -- compact mode (item:compact) sends the `stm_compact` event with
  -- STM_FORM_NET: full | icon (no label) | hidden. Anything else is full.
  local forms = { full = true, icon = true, hidden = true }
  local form = "full"
  local key = "STM_FORM_" .. opts.name:gsub("^stm%.", ""):gsub("[.-]", "_"):upper()
  local function draw_form()
    local shown = form ~= "hidden"
    if icon_item then
      icon_item:set({ drawing = shown })
      item:set({ drawing = shown and form == "full" })
    else
      item:set({ drawing = shown, label = { drawing = form == "full" } })
    end
  end

  sbar.add("event", "stm_compact")
  item:subscribe("stm_compact", function(e)
    local f = e and e[key]
    if not forms[f] then
      f = "full"
    end
    if f ~= form then
      form = f
      draw_form()
    end
  end)
  run()
end
