-- stm.tokens — how many tokens your AI tools used today, coloured green →
-- yellow → red as the day's total nears `scale`, with a short flash when the
-- rate since the last sample reaches `pulse`. Installed by
-- `stm install item:tokens`; stm owns this file and replaces it on
-- `install --force`, so do not edit it.
--
-- plugin.sh reads the Agents Usage Bar cache (`aub usage --json`) and prints
-- checked records; this file draws them. The previous sample lives here, in
-- the bar's long-lived Lua process: nothing is written to disk.
return function(sbar, opts, colors)
  local o = opts.options
  local name = opts.name
  local popup = type(colors.popup) == "table" and colors.popup or {}
  local ROWS = 8
  local MONO_ADVANCE = 0.61
  local NAME_CHARS = 18 -- a two-space indent and a 16-character name
  local PULSE_CURVE, PULSE_FRAMES = "sin", 20 -- out and back: 40 frames

  local function quote(s)
    return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
  end

  -- amount: "250k" → 250000, "1b" → 1e9; anything else nil.
  local function amount(s)
    local n, u = tostring(s or ""):match("^(%d+)([kmb])$")
    if not n then
      return nil
    end
    return tonumber(n) * ({ k = 1e3, m = 1e6, b = 1e9 })[u]
  end
  local scale = amount(o.scale) or 5e8
  local threshold = o.pulse ~= "off" and (amount(o.pulse) or 1e6) or nil

  -- compact: 999, 25.8K, 255.7M, 1.2B; a value that would round to 1000.0 of
  -- one unit is shown in the next; past 999.9B it is 999B+.
  local UNITS = { { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
  local function compact(n)
    n = math.floor(n)
    if n < 1000 then
      return string.format("%d", n)
    end
    if n >= 999.95e9 then
      return "999B+"
    end
    local i = n >= 1e9 and 1 or n >= 1e6 and 2 or 3
    if i > 1 and n / UNITS[i][1] >= 999.95 then
      i = i - 1
    end
    return string.format("%.1f%s", n / UNITS[i][1], UNITS[i][2])
  end

  -- mix: per channel (alpha, red, green, blue) from colour a to b by t.
  local SHIFTS = { 16777216, 65536, 256, 1 } -- 256^3 .. 256^0
  local function mix(a, b, t)
    local out = 0
    for _, s in ipairs(SHIFTS) do
      local ca, cb = math.floor(a / s) % 256, math.floor(b / s) % 256
      out = out + math.floor(ca + (cb - ca) * t + 0.5) * s
    end
    return math.floor(out)
  end

  -- heat: green at 0, yellow at half the scale, red at the scale and above.
  local function heat(total)
    local g, y, r = colors.green, colors.yellow, colors.red
    if type(g) ~= "number" or type(y) ~= "number" or type(r) ~= "number" then
      return colors.grey
    end
    local t = math.min(total / scale, 1)
    if t <= 0.5 then
      return mix(g, y, t / 0.5)
    end
    return mix(y, r, (t - 0.5) / 0.5)
  end

  -- rate_of: tokens per minute between two samples, over the providers with
  -- a count in both. A count that went down (the day rolled over) makes it
  -- 0; no shared provider or no time between them makes it unknown (nil).
  local function rate_of(prev, cur)
    if not prev or not prev.asof or not cur.asof or cur.asof <= prev.asof then
      return nil
    end
    local sum, shared = 0, false
    for id, n in pairs(cur.tokens) do
      local before = prev.tokens[id]
      if before then
        if n < before then
          return 0
        end
        sum, shared = sum + n - before, true
      end
    end
    if not shared then
      return nil
    end
    return sum / ((cur.asof - prev.asof) / 60)
  end

  -- pulses: one flash for a new sample whose rate reaches the threshold,
  -- only while the data is fresh.
  local function pulses(rate, limit, state)
    return limit ~= nil and rate ~= nil and state == "ok" and rate >= limit
  end

  -- parse: plugin.sh's records into a sample. Anything off the format is
  -- dropped; no `state` line, or a reply SbarLua turned into a table, is nodata.
  local function parse(out)
    local s = { state = "nodata", tokens = {}, provs = {} }
    if type(out) ~= "string" then
      return s
    end
    for line in out:gmatch("[^\n]+") do
      local f = {}
      for v in (line .. "\t"):gmatch("([^\t]*)\t") do
        f[#f + 1] = v
      end
      if f[1] == "state" and (f[2] == "ok" or f[2] == "nodata" or f[2] == "missing") and #f == 2 then
        s.state = f[2]
      elseif f[1] == "asof" and #f == 3 then
        s.asof = f[2]:match("^%d+$") and #f[2] <= 12 and tonumber(f[2]) or nil
        s.stale = f[3] ~= "0"
      elseif f[1] == "total" and #f == 2 and f[2]:match("^%d+$") and #f[2] <= 16 then
        s.total = tonumber(f[2])
      elseif f[1] == "prov" and #f == 4 and f[4]:match("^%d+$") and #f[4] <= 15 and not s.tokens[f[2]] then
        local n = tonumber(f[4])
        s.tokens[f[2]] = n
        s.provs[#s.provs + 1] = { id = f[2], name = f[3], tokens = n }
      end
    end
    if s.state == "ok" and (not s.total or #s.provs == 0) then
      s.state = "nodata"
    end
    if s.state == "ok" and s.stale then
      s.state = "stale"
    end
    return s
  end

  local icon = { string = "\u{F01BC}", color = colors.grey }
  local props = {
    position = opts.position,
    update_freq = opts.update_freq,
    -- compact mode may hide the item; a hidden item gets no events unless it
    -- asks for them (SketchyBar's default is when_shown).
    updates = true,
    icon = icon,
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
  local icon_item
  if sub and opts.position ~= "right" then
    icon_item = sbar.add("item", name .. ".icon", sub)
  end
  local item = sbar.add("item", name, props)
  if sub and opts.position == "right" then
    icon_item = sbar.add("item", name .. ".icon", sub)
  end

  -- The popup: a head row, one row per provider (most tokens first), the
  -- rate. Names sit in the rows' icon slots.
  local function row(id, extra)
    local p = { position = "popup." .. name, icon = { color = colors.white }, label = { color = colors.white } }
    for k, v in pairs(extra or {}) do
      p[k] = v
    end
    return sbar.add("item", name .. ".row." .. id, p)
  end
  local rows = { head = row("head", { icon = { string = "today", color = colors.grey } }) }
  for i = 0, ROWS - 1 do
    rows[i] = row(tostring(i), { drawing = false })
  end
  rows.rate = row("rate", { icon = { string = "rate", color = colors.grey }, label = { string = "--", color = colors.white } })

  -- A config batching its setup (sbar.begin_config) has not sent the items
  -- yet when it loads, so ask again on later runs until the bar answers.
  local metrics, name_width
  local function measure()
    if not metrics then
      local q = sbar.query(name)
      local label = type(q) == "table" and q.label
      local size = type(label) == "table" and tonumber(tostring(label.font):match(":([%d.]+)$"))
      if size then
        local pad = (tonumber(label.padding_left) or 0) + (tonumber(label.padding_right) or 0)
        metrics = { cw = tonumber(string.format("%.2f", size * MONO_ADVANCE)), pad = math.floor(pad) }
      end
    end
    if not name_width then
      local q = sbar.query(name .. ".row.head")
      local ic = type(q) == "table" and q.icon
      local size = type(ic) == "table" and tonumber(tostring(ic.font):match(":([%d.]+)$"))
      if size then
        local pad = (tonumber(ic.padding_left) or 0) + (tonumber(ic.padding_right) or 0)
        name_width = math.floor(pad) + math.ceil(NAME_CHARS * size * MONO_ADVANCE)
        rows.head:set({ icon = { width = name_width } })
        for i = 0, ROWS - 1 do
          rows[i]:set({ icon = { width = name_width } })
        end
        rows.rate:set({ icon = { width = name_width } })
      end
    end
  end

  -- compact mode (item:compact) sends the `stm_compact` event with
  -- STM_FORM_TOKENS: full | icon (no label) | hidden. Anything else is full.
  local forms = { full = true, icon = true, hidden = true }
  local form = "full"
  local key = "STM_FORM_" .. name:gsub("^stm%.", ""):gsub("[.-]", "_"):upper()

  local prev, rate
  local colour = colors.grey

  -- paint: the heat (or state) colour where the shape puts it.
  local function paint(c)
    if icon_item then
      icon_item:set({ background = { color = c } })
    else
      item:set({ icon = { color = c } })
    end
  end

  -- pulse: out to halfway to white and back. SketchyBar chains a second
  -- animation of the same property after the first, from its end value.
  local function pulse()
    if type(colour) ~= "number" or type(colors.white) ~= "number" then
      return
    end
    local bright, back = mix(colour, colors.white, 0.5), colour
    sbar.animate(PULSE_CURVE, PULSE_FRAMES, function()
      paint(bright)
      paint(back)
    end)
  end

  local function draw(s)
    local label, head
    if s.state == "missing" then
      label, head = "no aub", "aub not found"
    elseif s.state == "nodata" then
      label, head = "--", "no token counts yet"
    else
      label = compact(s.total)
      head = label
      if s.asof then
        head = head .. " · as of " .. os.date("%H:%M", s.asof)
      end
      if s.state == "stale" then
        head = head .. " · stale"
      end
    end
    colour = s.state == "ok" and heat(s.total) or colors.grey
    local text = { string = label }
    if metrics then
      text.width = metrics.pad + math.ceil(#label * metrics.cw)
    end
    item:set({ label = text })
    paint(colour)

    rows.head:set({ label = { string = head } })
    table.sort(s.provs, function(a, b)
      if a.tokens ~= b.tokens then
        return a.tokens > b.tokens
      end
      return a.id < b.id
    end)
    for i = 0, ROWS - 1 do
      local p = s.provs[i + 1]
      if p then
        rows[i]:set({ drawing = true, icon = { string = p.name }, label = { string = compact(p.tokens) } })
      else
        rows[i]:set({ drawing = false })
      end
    end
    local r = (s.state == "ok" or s.state == "stale") and rate
    rows.rate:set({ label = { string = r and compact(r) .. "/min" or "--" } })
  end

  -- sample: one plugin reply. The rate is worked out only when the data's
  -- time moves on; the first sample after a load has none. A reply older
  -- than the kept sample (a slow run answering late) is dropped whole.
  local function sample(out)
    local s = parse(out)
    if prev and s.asof and s.asof < prev.asof then
      return
    end
    local fresh = false
    if (s.state == "ok" or s.state == "stale") and s.asof and (not prev or s.asof ~= prev.asof) then
      rate = prev and rate_of(prev, s) or nil
      fresh = prev ~= nil
      prev = { asof = s.asof, tokens = s.tokens }
    end
    draw(s)
    if fresh and form ~= "hidden" and pulses(rate, threshold, s.state) then
      pulse()
    end
  end

  local plugin = quote(opts.plugin_dir .. "/tokens.sh")
  local function run(e)
    local sender = (e and e.SENDER) or "forced"
    measure()
    sbar.exec(string.format("NAME=%s SENDER=%s %s", quote(name), quote(sender), plugin), sample)
  end

  -- In the split icon form the main item stays drawn at zero width with
  -- nothing in it: it hosts the popup, and SketchyBar draws no popup for a
  -- hidden item.
  local function draw_form()
    local shown = form ~= "hidden"
    if icon_item then
      icon_item:set({ drawing = shown })
      if not shown then
        item:set({ drawing = false })
      else
        local full = form == "full"
        item:set({
          drawing = true,
          width = full and "dynamic" or 0,
          label = { drawing = full },
          background = { drawing = full },
        })
      end
    else
      item:set({ drawing = shown, label = { drawing = form == "full" } })
    end
    if not shown then
      item:set({ popup = { drawing = false } })
    end
  end

  local function toggle()
    item:set({ popup = { drawing = "toggle" } })
  end
  item:subscribe("mouse.clicked", toggle)
  item:subscribe("mouse.exited.global", function()
    item:set({ popup = { drawing = false } })
  end)
  if icon_item then
    icon_item:subscribe("mouse.clicked", toggle)
  end

  local events = { "routine", "forced" }
  for _, ev in ipairs(opts.events or {}) do
    events[#events + 1] = ev
  end
  item:subscribe(events, run)

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
