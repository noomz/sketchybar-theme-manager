-- Fixture: the shape used by configs that return the generated table WHOLESALE
-- (as NoamFav/sketchybar does), with nested bar/popup sub-tables and a
-- with_alpha helper. If stm emits a flat table here, colors.popup.bg and
-- colors.with_alpha become nil and the bar breaks at load.
local ok, generated = pcall(require, "colors_generated")
if ok and generated then
	return generated
end

return {
	black = 0xff1a1b26,
	white = 0xffc0caf5,
	red = 0xfff7768e,
	green = 0xff9ece6a,
	blue = 0xff7aa2f7,
	yellow = 0xffe0af68,
	orange = 0xffff9e64,
	magenta = 0xffbb9af7,
	grey = 0xff565f89,
	transparent = 0x00000000,

	bar = {
		bg = 0x001a1b26,
		border = 0xff292e42,
	},
	popup = {
		bg = 0xc01f2335,
		border = 0xff565f89,
	},

	bg1 = 0xff1f2335,
	bg2 = 0xff24283b,

	with_alpha = function(color, alpha)
		if alpha > 1.0 or alpha < 0.0 then
			return color
		end
		return (color & 0x00ffffff) | (math.floor(alpha * 255.0) << 24)
	end,
}
