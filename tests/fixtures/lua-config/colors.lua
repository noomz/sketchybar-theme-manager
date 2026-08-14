-- Fixture: a typical SbarLua colors.lua with a colors_generated.lua fallback.
-- This file is the user's DEFAULT theme. stm must never modify it.

local defaults = {
  black = 0xff181926,
  white = 0xffcad3f5,
  red = 0xffed8796,
  green = 0xffa6da95,
  blue = 0xff8aadf4,
  yellow = 0xffeed49f,
  orange = 0xfff5a97f,
  magenta = 0xffc6a0f6,
  grey = 0xff939ab7,
  bg1 = 0xff24273a,
  bg2 = 0xff363a4f,
  bar_bg = 0x0024273a,
  bar_border = 0xff494d64,
  popup_bg = 0xc024273a,
  popup_border = 0xff939ab7,
}

-- If stm has written a generated palette, prefer it; otherwise keep defaults.
local ok, generated = pcall(require, "colors_generated")
if ok and type(generated) == "table" then
  for k, v in pairs(generated) do
    defaults[k] = v
  end
end

return defaults
