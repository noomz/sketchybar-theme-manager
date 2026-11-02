-- stm.expand — expander. Installed by `stm install item:expand`; stm owns
-- this file and replaces it on `install --force`, so do not edit it.
--
-- A click flips a Lua-local on|off and fires `stm_expand` with STM_EXPAND.
-- Nothing else is set or written: items that should hide subscribe in the
-- user's own file. Colours come only from `colors` (the active palette).
return function(sbar, opts, colors)
  local o = opts.options
  local state = "off"
  local glyphs = {
    off = "\u{F084E}", -- nf-md-arrow-expand-horizontal
    on = "\u{F084C}", -- nf-md-arrow-collapse-horizontal
  }

  local props = {
    position = opts.position,
    icon = { string = glyphs.off, color = colors.white },
    label = { drawing = false },
  }
  if o.shape == "pill" then
    props.background = { drawing = true, color = colors.bg1 }
  end

  sbar.add("event", "stm_expand")
  local item = sbar.add("item", opts.name, props)
  item:subscribe("mouse.clicked", function()
    state = (state == "off") and "on" or "off"
    item:set({ icon = { string = glyphs[state] } })
    sbar.trigger("stm_expand", { STM_EXPAND = state })
  end)
end
