-- The entrypoint of the fixture. The items have no name, so SbarLua gives
-- them a generated one.
sbar = require("sketchybar")

sbar.add("item", {
	position = "left",
	label = { string = "first" },
})

sbar.add("item", {
	position = "left",
	label = { string = "second" },
})
