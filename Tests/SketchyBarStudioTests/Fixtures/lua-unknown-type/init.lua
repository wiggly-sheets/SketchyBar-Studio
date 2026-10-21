-- The entrypoint of the fixture. The type "widget" is not one of the
-- types the daemon supports, so no item is created for it.
sbar = require("sketchybar")

sbar.add("widget", "unknown", {
	position = "left",
	label = { string = "unknown" },
})

sbar.add("item", "kept", {
	position = "left",
	label = { string = "kept" },
})
