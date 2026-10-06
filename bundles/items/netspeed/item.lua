-- stm.netspeed — download and upload rates of the network link, as graphs
-- and numbers. Installed by `stm install item:netspeed`; stm owns this file
-- and replaces it on `install --force`, so do not edit it.
--
-- Colours come only from `colors` (the active palette), so `stm apply <theme>`
-- recolours the item on reload: download is blue, upload magenta. plugin.sh
-- samples the interface's byte counters a second apart, pushes both rates
-- onto the graphs and writes the labels.
return function(sbar, opts, colors)
  local o = opts.options
  local name = opts.name
  local GRAPH_WIDTH = 30

  local function quote(s)
    return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
  end

  -- The colour at alpha 0x40, for the area under a graph line.
  local function soft(c)
    if type(c) ~= "number" then
      return nil
    end
    return (c & ((1 << 24) - 1)) | (0x40 << 24)
  end

  local plugin = quote(opts.plugin_dir .. "/netspeed.sh")

  -- add(list) adds { name, kind, props } entries so they read left to right
  -- at every position: right items are laid out right to left, so on the
  -- right the last one goes in first.
  local function add(list)
    local first, last, step = 1, #list, 1
    if opts.position == "right" then
      first, last, step = #list, 1, -1
    end
    local added = {}
    for i = first, last, step do
      local e = list[i]
      if e.kind == "graph" then
        added[e.name] = sbar.add("graph", e.name, GRAPH_WIDTH, e.props)
      else
        added[e.name] = sbar.add("item", e.name, e.props)
      end
    end
    return added
  end

  local measured, small
  local items
  if o.view == "separate" then
    -- Two items, download left of upload, each with its own icon, graph and
    -- label; pill puts each on bg1.
    local function rate(icon, color, extra)
      local props = {
        position = opts.position,
        icon = { string = icon, color = color },
        label = { string = "--" },
        graph = { color = color, fill_color = soft(color), line_width = 1.0 },
      }
      if o.shape == "pill" then
        props.background = { drawing = true, color = colors.bg1 }
      end
      for k, v in pairs(extra or {}) do
        props[k] = v
      end
      return props
    end
    items = add({
      { name = name, kind = "graph", props = rate("\u{F01DA}", colors.blue, { update_freq = opts.update_freq }) },
      { name = name .. ".up", kind = "graph", props = rate("\u{F0552}", colors.magenta) },
    })
    measured = name
  else
    -- One pill of three items: the icon and the download graph; the upload
    -- line drawn over that same graph (the download item's right padding of
    -- minus the graph width pulls the next item back over it); then both
    -- rates stacked in one text item, upload on top in its zero-width icon
    -- slot, download below in its label. The members' own backgrounds are
    -- transparent; pill draws bg1 behind all three with a bracket.
    items = add({
      { name = name, kind = "graph", props = {
        position = opts.position,
        update_freq = opts.update_freq,
        icon = { string = "\u{F06F3}", color = colors.blue },
        label = { drawing = false },
        graph = { color = colors.blue, fill_color = soft(colors.blue), line_width = 1.0 },
        background = { drawing = true, color = 0, padding_right = -GRAPH_WIDTH },
      } },
      { name = name .. ".up", kind = "graph", props = {
        position = opts.position,
        icon = { drawing = false },
        label = { drawing = false },
        graph = { color = colors.magenta, fill_color = 0, line_width = 1.5 },
        background = { drawing = true, color = 0, padding_left = 0 },
      } },
      { name = name .. ".rates", kind = "item", props = {
        position = opts.position,
        icon = { string = "\u{2191}--", color = colors.magenta, width = 0, padding_left = 0, padding_right = 0, y_offset = 6 },
        label = { string = "\u{2193}--", color = colors.blue, padding_left = 0, y_offset = -5 },
        background = { drawing = true, color = 0 },
      } },
    })
    if o.shape == "pill" then
      sbar.add("bracket", name .. ".pill", { name, name .. ".up", name .. ".rates" }, {
        background = { drawing = true, color = colors.bg1 },
      })
    end
    measured = name .. ".rates"
    small = items[measured]
  end

  -- plugin.sh sizes the label from the font the bar actually uses. A config
  -- batching its setup (sbar.begin_config) has not sent these items yet when
  -- it loads, so ask again on later runs until the bar answers. The stacked
  -- rates use the label font 3 points smaller (8 at least), so two lines fit
  -- the bar.
  local metrics
  local function measure()
    if not metrics then
      local q = sbar.query(measured)
      local label = type(q) == "table" and q.label
      local family, style, size
      if type(label) == "table" then
        family, style, size = tostring(label.font):match("^(.*):([^:]*):([%d.]+)$")
        size = tonumber(size)
      end
      if size then
        local pad = (tonumber(label.padding_left) or 0) + (tonumber(label.padding_right) or 0)
        if small then
          size = math.max(8, size - 3)
          local font = string.format("%s:%s:%.1f", family, style, size)
          small:set({ icon = { font = font }, label = { font = font } })
        end
        metrics = { string.format("%.2f", size * 0.61), string.format("%d", math.floor(pad)) }
      end
    end
    local m = metrics or { "", "" }
    return "STM_NS_CW=" .. quote(m[1]) .. " STM_NS_PAD=" .. quote(m[2])
  end

  local function run(e)
    local sender = (e and e.SENDER) or "forced"
    sbar.exec(string.format("STM_NS_VIEW=%s %s NAME=%s SENDER=%s %s",
      quote(o.view), measure(), quote(name), quote(sender), plugin))
  end

  local events = { "routine", "forced" }
  for _, ev in ipairs(opts.events or {}) do
    events[#events + 1] = ev
  end
  items[name]:subscribe(events, run)
  run()
end
