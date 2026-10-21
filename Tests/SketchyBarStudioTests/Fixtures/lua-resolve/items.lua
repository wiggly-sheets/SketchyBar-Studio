-- An item whose values come from the module: a computed value, a
-- concatenation and a colour.
local settings = require("settings")

sbar.add("item", "clock", {
	position = "right",
	icon = {
		string = "sf.clock",
		font = { family = settings.default, size = settings.size + 1 },
	},
	label = { string = "10:00 " .. settings.family },
	background = { color = settings.colour },
	drawing = true,
})
