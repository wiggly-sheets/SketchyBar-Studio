-- The entrypoint of the fixture. The config declares one item of every
-- type the daemon supports, so the tests can read what the preview does
-- with each of them.
sbar = require("sketchybar")

sbar.add("item", "clock", {
	position = "right",
	label = { string = "10:00" },
})

sbar.add("graph", "cpu", 42, {
	position = "right",
	label = { string = "cpu" },
})

sbar.add("slider", "volume", 30, {
	position = "right",
})

sbar.add("space", "spacer", {
	position = "left",
})

sbar.add("alias", "menu", {
	position = "left",
})

sbar.add("bracket", "group", { "clock", "cpu" }, {
	position = "right",
})

sbar.add("event", "lock", "com.apple.screenIsLocked")
