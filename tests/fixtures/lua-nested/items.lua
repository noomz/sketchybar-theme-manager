-- Fixture: consumes the nested shape, so a flat generated table breaks it.
local colors = require("colors")

return {
	bar_color = colors.transparent,
	popup_bg = colors.popup.bg,
	popup_border = colors.popup.border,
	faded = colors.with_alpha(colors.white, 0.6),
}
