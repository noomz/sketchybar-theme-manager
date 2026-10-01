-- stm.tailscale — Tailscale status item. Installed by `stm install item:tailscale`;
-- stm owns this file and replaces it on `install --force`, so do not edit it.
--
-- Colours come only from `colors` (the active palette), so `stm apply <theme>`
-- recolours the item on reload. plugin.sh does the polling and drawing.
return function(sbar, opts, colors)
  local o = opts.options
  local popup = type(colors.popup) == "table" and colors.popup or {}

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
    "STM_GREY=" .. quote(hex(colors.grey)),
    "STM_TS_EXIT_NODE=" .. quote(o.exit_node),
    "STM_TS_PEERS=" .. quote(o.peers),
    "STM_TS_IP=" .. quote(o.ip),
    "STM_TS_CLICK=" .. quote(o.click),
    "STM_TS_ICON=" .. quote(o.icon),
    "STM_TS_SHAPE=" .. quote(o.shape),
  }, " ")
  local plugin = quote(opts.plugin_dir .. "/tailscale.sh")

  local click_script
  if o.click == "app" then
    click_script = "open -a Tailscale"
  else
    click_script = "sketchybar --set " .. quote(opts.name) .. " popup.drawing=toggle"
  end

  -- icon=app: plugin.sh points icon.background.image at the Tailscale app and
  -- falls back to "TS" when SketchyBar cannot find it. The background is
  -- transparent (0, not a palette colour) so icon defaults draw no pill behind
  -- it, and the 32pt app image is drawn at 20pt. nerd: nf-md-dots_grid (Nerd
  -- Fonts have no Tailscale glyph).
  local icon = { string = "TS", color = colors.grey }
  if o.icon == "nerd" then
    icon.string = "\u{F15FC}"
  elseif o.icon == "app" then
    icon = { string = "", background = { drawing = true, color = 0, image = { scale = 0.625 } } }
  end

  local props = {
    position = opts.position,
    update_freq = opts.update_freq,
    icon = icon,
    label = { string = "tailscale" },
    click_script = click_script,
    popup = {
      align = "right",
      background = {
        color = colors.popup_bg or popup.bg,
        border_color = colors.popup_border or popup.border,
        border_width = 1,
        corner_radius = 6,
      },
    },
  }

  -- shape: plain draws no background (as 0.6.0 did). pill puts the item on
  -- bg1. split moves the icon onto its own sub-item, <name>.icon, whose
  -- background plugin.sh sets to the state colour; the icon on it is black and
  -- the label stays on bg1. The sub-item sits left of the label at every
  -- position, and right items are laid out right to left, so on the right the
  -- label item goes in first. Clicking either part does the same thing.
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
      click_script = click_script,
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
  item:subscribe("mouse.exited.global", function()
    item:set({ popup = { drawing = false } })
  end)
  run()
end
