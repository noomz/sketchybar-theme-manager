-- stm.spotify — now playing in Spotify, with a popup: cover, title, artist,
-- album and playback controls. Installed by `stm install item:spotify`; stm
-- owns this file and replaces it on `install --force`, so do not edit it.
--
-- Colours come only from `colors` (the active palette), so `stm apply <theme>`
-- recolours the item on reload. plugin.sh asks Spotify what is playing (when
-- Spotify posts a change, and every update_freq seconds) and fills in the
-- text, the glyphs and the cover.
return function(sbar, opts, colors)
  local o = opts.options
  local popup = type(colors.popup) == "table" and colors.popup or {}
  local name = opts.name
  local rows = "popup." .. name

  local function quote(s)
    return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
  end

  local env = table.concat({
    "STM_SP_SHAPE=" .. quote(o.shape),
    "STM_SP_COVER=" .. quote(o.cover),
  }, " ")
  local plugin = quote(opts.plugin_dir .. "/spotify.sh")

  local function run(e, action)
    local sender = (e and e.SENDER) or "forced"
    sbar.exec(string.format("%s STM_SP_ACTION=%s NAME=%s SENDER=%s %s",
      env, quote(action or ""), quote(name), quote(sender), plugin))
  end

  -- Spotify posts this distributed notification on every play, pause and
  -- track change, so the item follows it without polling every second.
  sbar.add("event", "stm_spotify_change", "com.spotify.client.PlaybackStateChanged")

  -- Hidden until plugin.sh finds something playing. A hidden item gets no
  -- events unless it asks for them (SketchyBar's default is when_shown).
  local icon = { string = "\u{F1BC}", color = colors.magenta }
  local props = {
    position = opts.position,
    update_freq = opts.update_freq,
    updates = true,
    drawing = false,
    icon = icon,
    popup = {
      align = "center",
      horizontal = true,
      height = 150,
      background = {
        color = colors.popup_bg or popup.bg,
        border_color = colors.popup_border or popup.border,
        border_width = 2,
        corner_radius = 12,
        padding_left = 8,
        padding_right = 8,
      },
    },
  }

  -- shape: plain draws no background. pill puts the item on bg1. split moves
  -- the icon onto its own sub-item, <name>.icon, on magenta with the icon in
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
      drawing = false,
      icon = icon,
      label = { drawing = false },
      background = { drawing = true, color = colors.magenta },
    }
    props.icon = { drawing = false }
    props.background = { drawing = true, color = colors.bg1, padding_left = 0 }
  end

  local icon_item
  if sub and opts.position ~= "right" then
    icon_item = sbar.add("item", name .. ".icon", sub)
  end
  local item = sbar.add("item", name, props)
  if sub and opts.position == "right" then
    icon_item = sbar.add("item", name .. ".icon", sub)
  end

  -- The popup: the cover on the left, then title, artist and album stacked
  -- over the controls.
  sbar.add("item", name .. ".row.cover", {
    position = rows,
    drawing = false,
    icon = { drawing = false },
    label = { drawing = false },
    padding_left = 12,
    padding_right = 10,
    background = { drawing = true, color = 0, image = { drawing = true, scale = 0.2 } },
  })
  local function text_row(row, y)
    sbar.add("item", name .. ".row." .. row, {
      position = rows,
      icon = { drawing = false },
      label = { max_chars = 20 },
      padding_left = 0,
      padding_right = 0,
      width = 0,
      y_offset = y,
    })
  end
  text_row("title", 55)
  text_row("artist", 30)
  text_row("album", 15)

  -- The controls run plugin.sh with their action, on a green bracket; play
  -- is a red button. shuffle and repeat light up (white) while on.
  local controls = {}
  local function control(action, glyph, extra)
    local props = {
      position = rows,
      y_offset = -45,
      icon = { string = glyph, color = colors.black, highlight_color = colors.white,
        padding_left = 5, padding_right = 5 },
      label = { drawing = false },
    }
    for k, v in pairs(extra or {}) do
      props[k] = v
    end
    local row = sbar.add("item", name .. ".row." .. action, props)
    row:subscribe("mouse.clicked", function(e)
      run(e, action)
    end)
    controls[#controls + 1] = name .. ".row." .. action
  end
  control("shuffle", "\u{F049D}")
  control("back", "\u{F04AE}")
  control("play", "\u{F040A}", {
    icon = { string = "\u{F040A}", color = colors.white, highlight_color = colors.white,
      padding_left = 4, padding_right = 5 },
    background = { drawing = true, color = colors.red, height = 40, corner_radius = 20 },
    width = 40,
    align = "center",
  })
  control("next", "\u{F04AD}")
  control("repeat", "\u{F0456}", {
    icon = { string = "\u{F0456}", color = colors.black, highlight_color = colors.white,
      padding_left = 5, padding_right = 10 },
  })
  sbar.add("item", name .. ".row.spacer", { position = rows, width = 5 })
  sbar.add("bracket", name .. ".row.controls", controls, {
    y_offset = -45,
    background = { drawing = true, color = colors.green, corner_radius = 11 },
  })

  local function toggle()
    item:set({ popup = { drawing = "toggle" } })
  end
  local events = { "routine", "forced", "stm_spotify_change" }
  for _, ev in ipairs(opts.events or {}) do
    events[#events + 1] = ev
  end
  item:subscribe(events, run)
  item:subscribe("mouse.clicked", toggle)
  item:subscribe("mouse.exited.global", function()
    item:set({ popup = { drawing = false } })
  end)
  if icon_item then
    icon_item:subscribe("mouse.clicked", toggle)
  end
  run()
end
