-- stm.ai — how much of your AI providers' quota is used: one bar segment per
-- provider, each with its own popup. Installed by `stm install item:ai`; stm
-- owns this file and replaces it on `install --force`, so do not edit it.
--
-- plugin.sh reads the Agents Usage Bar cache (`aub usage --json`); it never
-- talks to a provider and never reads a credential.
return function(sbar, opts, colors)
  local o = opts.options
  local name = opts.name
  local popup = type(colors.popup) == "table" and colors.popup or {}
  local ROWS = 12
  local MONO_ADVANCE = 0.61
  local LINES_SMALLER = 3
  local LINES_MIN_SIZE = 8
  local NAME_CHARS = 18 -- a two-space indent and a 16-character name
  -- Left to right on the bar at every position. A text tag, not a brand mark.
  local PROVIDERS = {
    { id = "claude", tag = "CL" },
    { id = "codex", tag = "CX" },
    { id = "gemini", tag = "GE" },
    { id = "grok", tag = "GK" },
    { id = "openrouter", tag = "OR" },
  }

  local function hex(c)
    if type(c) ~= "number" then
      return ""
    end
    return string.format("0x%08x", c)
  end

  local function quote(s)
    return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
  end

  -- icon=image: the user's own icons live in <config dir>/icons/ai, beside
  -- the plugins/stm folder stm installs into.
  local config_dir = opts.plugin_dir:match("^(.+)/plugins/stm$")
  local env = {
    "STM_GREEN=" .. quote(hex(colors.green)),
    "STM_YELLOW=" .. quote(hex(colors.yellow)),
    "STM_RED=" .. quote(hex(colors.red)),
    "STM_GREY=" .. quote(hex(colors.grey)),
    "STM_WHITE=" .. quote(hex(colors.white)),
    "STM_AI_SHAPE=" .. quote(o.shape),
    "STM_AI_ICON=" .. quote(o.icon),
    "STM_AI_ICON_DIR=" .. quote(config_dir and config_dir .. "/icons/ai" or ""),
  }
  -- accounts = split: SLOTS segments per provider, <segment>.<0-3>, hidden
  -- until plugin.sh fills one per account, as the popup rows are.
  local SLOTS = 4
  local split = o.accounts == "split"
  local segments = {}
  for _, p in ipairs(PROVIDERS) do
    env[#env + 1] = "STM_AI_" .. p.id:upper() .. "=" .. quote(o[p.id])
    if o[p.id] ~= "off" then
      for slot = 0, split and SLOTS - 1 or 0 do
        segments[#segments + 1] = {
          id = p.id,
          tag = p.tag,
          name = name .. "." .. p.id .. (split and "." .. slot or ""),
          windows = o[p.id] == "windows",
          slot = split and slot or nil,
        }
      end
    end
  end
  -- plugin.sh takes an unset label detail as its default, so only the others
  -- go.
  local details = {
    { "accounts", "merged" },
    { "account_label", "short" },
    { "percent", "used" },
    { "period", "on" },
    { "reset", "off" },
  }
  for _, d in ipairs(details) do
    if o[d[1]] and o[d[1]] ~= d[2] then
      env[#env + 1] = "STM_AI_" .. d[1]:upper() .. "=" .. quote(o[d[1]])
    end
  end
  env = table.concat(env, " ")
  local plugin = quote(opts.plugin_dir .. "/ai.sh")

  -- The driver: never drawn, but it gets every update (a hidden item would
  -- not) and runs plugin.sh once to set every segment.
  local driver = sbar.add("item", name, {
    position = opts.position,
    drawing = false,
    updates = true,
    update_freq = opts.update_freq,
  })

  local function add_segment(s)
    local props = {
      position = opts.position,
      icon = { string = s.tag, color = colors.grey },
      label = { string = "--" },
      popup = {
        align = opts.position == "right" and "right" or "left",
        background = {
          color = colors.popup_bg or popup.bg,
          border_color = colors.popup_border or popup.border,
          border_width = 2,
          corner_radius = 12,
        },
      },
    }
    -- The tag moves to <segment>.icon when split puts it on the state colour,
    -- and for the windows metric, where the segment's icon slot holds the top
    -- line (zero width, raised) over the label's bottom line.
    local sub
    if o.shape == "split" or s.windows then
      sub = {
        position = opts.position,
        icon = { string = s.tag, color = colors.grey },
        label = { drawing = false },
      }
      if o.shape == "split" then
        sub.icon.color = colors.black
        sub.background = { drawing = true, color = colors.grey }
      end
      if s.windows then
        -- The label starts where the zero-width icon slot does, so both
        -- lines line up.
        props.icon = { drawing = false, width = 0, padding_left = 0, padding_right = 0, y_offset = 6 }
        props.label.padding_left = 0
      else
        props.icon = { drawing = false }
      end
    end
    -- icon=image: plugin.sh draws the image as the tag's icon background
    -- and falls back to the tag. The background is transparent (0, not a
    -- palette colour) so icon defaults draw no pill behind it; 0.625 draws
    -- a 32 pt app image at 20 pt (plugin.sh sets 0.4, about 13 pt, for the
    -- user's file).
    -- SketchyBar places a background image at the icon's start plus the
    -- image's own padding, never the icon's, so without padding_left the
    -- image sits flush on the pill's edge.
    if o.icon == "image" then
      local tag_icon = sub and sub.icon or props.icon
      tag_icon.background = { drawing = false, color = 0, image = { scale = 0.625, padding_left = 6 } }
    end
    if o.shape == "split" then
      props.background = { drawing = true, color = colors.bg1, padding_left = 0 }
    elseif o.shape == "pill" and not s.windows then
      props.background = { drawing = true, color = colors.bg1 }
    end
    if s.slot then
      props.drawing = false
      if sub then
        sub.drawing = false
      end
    end

    -- Right items are laid out right to left, so on the right the segment
    -- goes in first and its tag still lands on its left.
    if sub and opts.position ~= "right" then
      s.icon_item = sbar.add("item", s.name .. ".icon", sub)
    end
    s.item = sbar.add("item", s.name, props)
    if sub and opts.position == "right" then
      s.icon_item = sbar.add("item", s.name .. ".icon", sub)
    end
    if s.windows and o.shape == "pill" then
      sbar.add("bracket", s.name .. ".pill", { s.name .. ".icon", s.name }, {
        background = { drawing = true, color = colors.bg1 },
      })
    end
  end

  local first, last, step = 1, #segments, 1
  if opts.position == "right" then
    first, last, step = #segments, 1, -1
  end
  for i = first, last, step do
    add_segment(segments[i])
  end

  -- The popup's names sit in the rows' icon slots, in the icon font, which
  -- may be larger than the label font: each popup's name column is sized
  -- from that font so the bars line up.
  local function measure_rows(s)
    if s.name_width then
      return
    end
    local q = sbar.query(s.name .. ".row.head")
    local icon = type(q) == "table" and q.icon
    local size = type(icon) == "table" and tonumber(tostring(icon.font):match(":([%d.]+)$"))
    if not size then
      return
    end
    local pad = (tonumber(icon.padding_left) or 0) + (tonumber(icon.padding_right) or 0)
    s.name_width = math.floor(pad) + math.ceil(NAME_CHARS * size * MONO_ADVANCE)
    for _, r in ipairs(s.rows) do
      r:set({ icon = { width = s.name_width } })
    end
  end

  -- A config batching its setup (sbar.begin_config) has not sent the
  -- segments yet when it loads, so ask again on later runs until the bar
  -- answers.
  local function measure_segment(s)
    if not s.metrics then
      local q = sbar.query(s.name)
      local label = type(q) == "table" and q.label
      local family, style, size
      if type(label) == "table" then
        family, style, size = tostring(label.font):match("^(.*):([^:]*):([%d.]+)$")
        size = tonumber(size)
      end
      if size then
        local pad = (tonumber(label.padding_left) or 0) + (tonumber(label.padding_right) or 0)
        if s.windows then
          size = math.max(LINES_MIN_SIZE, size - LINES_SMALLER)
          local font = string.format("%s:%s:%.1f", family, style, size)
          s.item:set({ icon = { font = font }, label = { font = font } })
        end
        s.metrics = { string.format("%.2f", size * MONO_ADVANCE), string.format("%d", math.floor(pad)) }
      end
    end
    measure_rows(s)
    local m = s.metrics or { "", "" }
    local P = s.id:upper()
    return "STM_AI_CW_" .. P .. "=" .. quote(m[1]) .. " STM_AI_PAD_" .. P .. "=" .. quote(m[2])
  end

  -- compact mode (item:compact) sends the `stm_compact` event with
  -- STM_FORM_AI: full | icon (the tags alone) | hidden, for every segment at
  -- once. Anything else is full. plugin.sh gets the form and sets `drawing`;
  -- a segment that carries its own tag has its label turned off here.
  local forms = { full = true, icon = true, hidden = true }
  local form = "full"
  local key = "STM_FORM_" .. name:gsub("^stm%.", ""):gsub("[.-]", "_"):upper()

  local function run(e, action)
    local sender = (e and e.SENDER) or "forced"
    local metrics = {}
    for _, s in ipairs(segments) do
      -- Every slot is measured for its own fonts; its provider's pair goes once.
      local m = measure_segment(s)
      if (s.slot or 0) == 0 then
        metrics[#metrics + 1] = m
      end
    end
    metrics[#metrics + 1] = "STM_AI_ACTION=" .. quote(action or "")
    sbar.exec(string.format("%s STM_FORM=%s %s NAME=%s SENDER=%s %s",
      env, quote(form), table.concat(metrics, " "), quote(name), quote(sender), plugin))
  end

  -- Each segment's popup: a totals line, up to ROWS account and window rows
  -- (plugin.sh fills them and hides the rest), and a row that opens Agents
  -- Usage Bar.
  local function add_rows(s)
    local position = "popup." .. s.name
    local function row(id, extra)
      local p = { position = position, icon = { color = colors.white }, label = { color = colors.white } }
      for k, v in pairs(extra or {}) do
        p[k] = v
      end
      return sbar.add("item", s.name .. ".row." .. id, p)
    end
    s.rows = { row("head", { icon = { string = "today", color = colors.grey } }) }
    for i = 0, ROWS - 1 do
      s.rows[#s.rows + 1] = row(tostring(i), { drawing = false })
    end
    local foot = row("foot", { icon = { drawing = false }, label = { string = "Open Agents Usage Bar", color = colors.white } })
    foot:subscribe("mouse.clicked", function(e)
      run(e, "open")
    end)

    -- mouse.exited.global fires only when the pointer leaves the bar, not
    -- when it moves to the next segment, so a click closes the others.
    local function toggle()
      for _, other in ipairs(segments) do
        other.item:set({ popup = { drawing = other == s and "toggle" or false } })
      end
    end
    s.item:subscribe("mouse.clicked", toggle)
    s.item:subscribe("mouse.exited.global", function()
      s.item:set({ popup = { drawing = false } })
    end)
    if s.icon_item then
      s.icon_item:subscribe("mouse.clicked", toggle)
    end
  end
  for _, s in ipairs(segments) do
    add_rows(s)
  end

  local events = { "routine", "forced" }
  for _, ev in ipairs(opts.events or {}) do
    events[#events + 1] = ev
  end
  driver:subscribe(events, run)

  sbar.add("event", "stm_compact")
  driver:subscribe("stm_compact", function(e)
    local f = e and e[key]
    if not forms[f] then
      f = "full"
    end
    if f ~= form then
      form = f
      for _, s in ipairs(segments) do
        if not s.icon_item then
          s.item:set({ label = { drawing = form == "full" } })
        end
      end
      run(e)
    end
  end)
  run()
end
