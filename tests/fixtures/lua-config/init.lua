-- Fixture: minimal SbarLua entry point. Present only so format detection sees
-- more than one .lua file in the config dir.

local colors = require("colors")

return {
  bar = {
    color = colors.bar_bg,
    border_color = colors.bar_border,
  },
}
