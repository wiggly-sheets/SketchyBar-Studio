-- A module that returns a literal table, and a local function that
-- returns a table.
local settings = {
	family = "Liga SFMono Nerd Font",
	size = 11,
	colour = 0xff112233,
}

local function font(style)
	return {
		family = settings.family,
		size = settings.size,
		style = style,
	}
end

sbar.default({
	updates = "when_shown",
	icon = { font = font("Regular") },
	label = { font = font("Bold") },
})

return {
	default = settings.family,
	family = settings.family,
	size = settings.size,
	colour = settings.colour,
}
