-- The entrypoint of the fixture. The daemon does not know the type
-- "ring", so it creates no item for it.
sbar = require("sketchybar")

sbar.add("ring", {
	position = "left",
	label = { string = "ring" },
})

sbar.add("item", "kept", {
	position = "left",
	label = { string = "kept" },
})
