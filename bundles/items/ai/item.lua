-- stm.ai — how much of your AI providers' quota is used, with a popup per
-- provider and account. Installed by `stm install item:ai`; stm owns this
-- file and replaces it on `install --force`, so do not edit it.
--
-- plugin.sh reads the Agents Usage Bar cache (`aub usage --json`); it never
-- talks to a provider and never reads a credential.
return function(sbar, opts, colors)
  local o = opts.options
  local name = opts.name
  local popup = type(colors.popup) == "table" and colors.popup or {}
  local GLYPH = "\u{F0674}"
  local ROWS = 12
  local MONO_ADVANCE = 0.61
  local LINES_SMALLER = 3
  local LINES_MIN_SIZE = 8
  local NAME_CHARS = 18 -- a two-space indent and a 16-character name
  local windows = o.view == "windows"

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
    "STM_WHITE=" .. quote(hex(colors.white)),
    "STM_AI_SHAPE=" .. quote(o.shape),
    "STM_AI_VIEW=" .. quote(o.view),
    "STM_AI_PROVIDER=" .. quote(o.provider),
  }, " ")
  local plugin = quote(opts.plugin_dir .. "/ai.sh")

  local props = {
    position = opts.position,
    update_freq = opts.update_freq,
    icon = { string = GLYPH, color = colors.grey },
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

  -- The glyph moves to <name>.icon when split puts it on the state colour,
  -- and in the windows view, where the main item's icon slot holds the top
  -- line (zero width, raised) over the label's bottom line.
  local sub
  if o.shape == "split" or windows then
    sub = {
      position = opts.position,
      icon = { string = GLYPH, color = colors.grey },
      label = { drawing = false },
    }
    if o.shape == "split" then
      sub.icon.color = colors.black
      sub.background = { drawing = true, color = colors.grey }
    end
    if windows then
      -- The label starts where the zero-width icon slot does, so both lines
      -- line up.
      props.icon = { drawing = false, width = 0, padding_left = 0, padding_right = 0, y_offset = 6 }
      props.label.padding_left = 0
    else
      props.icon = { drawing = false }
    end
  end
  if o.shape == "split" then
    props.background = { drawing = true, color = colors.bg1, padding_left = 0 }
  elseif o.shape == "pill" and not windows then
    props.background = { drawing = true, color = colors.bg1 }
  end

  -- Right items are laid out right to left, so on the right the main item
  -- goes in first and the glyph still lands on its left.
  local icon_item
  if sub and opts.position ~= "right" then
    icon_item = sbar.add("item", name .. ".icon", sub)
  end
  local item = sbar.add("item", name, props)
  if sub and opts.position == "right" then
    icon_item = sbar.add("item", name .. ".icon", sub)
  end
  if windows and o.shape == "pill" then
    sbar.add("bracket", name .. ".pill", { name .. ".icon", name }, {
      background = { drawing = true, color = colors.bg1 },
    })
  end

  -- The popup's names sit in the rows' icon slots, in the icon font, which
  -- may be larger than the label font: the name column is sized from that
  -- font so the bars line up.
  local name_rows = {}
  local name_width
  local function measure_rows()
    if name_width then
      return
    end
    local q = sbar.query(name .. ".row.head")
    local icon = type(q) == "table" and q.icon
    local size = type(icon) == "table" and tonumber(tostring(icon.font):match(":([%d.]+)$"))
    if not size then
      return
    end
    local pad = (tonumber(icon.padding_left) or 0) + (tonumber(icon.padding_right) or 0)
    name_width = math.floor(pad) + math.ceil(NAME_CHARS * size * MONO_ADVANCE)
    for _, r in ipairs(name_rows) do
      r:set({ icon = { width = name_width } })
    end
  end

  -- A config batching its setup (sbar.begin_config) has not sent this item
  -- yet when it loads, so ask again on later runs until the bar answers.
  local metrics
  local function measure()
    if not metrics then
      local q = sbar.query(name)
      local label = type(q) == "table" and q.label
      local family, style, size
      if type(label) == "table" then
        family, style, size = tostring(label.font):match("^(.*):([^:]*):([%d.]+)$")
        size = tonumber(size)
      end
      if size then
        local pad = (tonumber(label.padding_left) or 0) + (tonumber(label.padding_right) or 0)
        if windows then
          size = math.max(LINES_MIN_SIZE, size - LINES_SMALLER)
          local font = string.format("%s:%s:%.1f", family, style, size)
          item:set({ icon = { font = font }, label = { font = font } })
        end
        metrics = { string.format("%.2f", size * MONO_ADVANCE), string.format("%d", math.floor(pad)) }
      end
    end
    measure_rows()
    local m = metrics or { "", "" }
    return "STM_AI_CW=" .. quote(m[1]) .. " STM_AI_PAD=" .. quote(m[2])
  end

  local function run(e, action)
    local sender = (e and e.SENDER) or "forced"
    sbar.exec(string.format("%s %s STM_AI_ACTION=%s NAME=%s SENDER=%s %s",
      env, measure(), quote(action or ""), quote(name), quote(sender), plugin))
  end

  -- The popup: a totals line, up to ROWS provider and account rows (plugin.sh
  -- fills them and hides the rest), and a row that opens Agents Usage Bar.
  local rows = "popup." .. name
  local function row(id, extra)
    local p = { position = rows, icon = { color = colors.white }, label = { color = colors.white } }
    for k, v in pairs(extra or {}) do
      p[k] = v
    end
    return sbar.add("item", name .. ".row." .. id, p)
  end
  name_rows[1] = row("head", { icon = { string = "today", color = colors.grey } })
  for i = 0, ROWS - 1 do
    name_rows[#name_rows + 1] = row(tostring(i), { drawing = false })
  end
  local foot = row("foot", { icon = { drawing = false }, label = { string = "Open Agents Usage Bar", color = colors.white } })
  foot:subscribe("mouse.clicked", function(e)
    run(e, "open")
  end)

  local function toggle()
    item:set({ popup = { drawing = "toggle" } })
  end
  local events = { "routine", "forced" }
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
