-- A module that the item module requires: the chain of the requires.
local settings = require("settings")

sbar.add("item", "extra", {
	position = "left",
	label = { string = "extra" },
	background = { color = settings.colour },
})
