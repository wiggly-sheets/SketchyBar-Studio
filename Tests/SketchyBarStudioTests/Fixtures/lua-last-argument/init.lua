-- The entrypoint of the fixture. The daemon reads the properties of the
-- last argument of the call, and only when that argument is a table, so
-- this item has no properties at all.
sbar = require("sketchybar")

sbar.add("item", "last", {
	position = "left",
	label = { string = "last" },
}, "not a table")
