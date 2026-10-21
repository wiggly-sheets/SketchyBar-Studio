-- The entrypoint of the fixture. The text of a number is the text Lua
-- writes for it.
sbar = require("sketchybar")

sbar.add("item", "numbers", {
	position = "left",
	label = { string = "numbers" },
	integer = 12,
	float = 12.0,
	third = 1 / 3,
})
