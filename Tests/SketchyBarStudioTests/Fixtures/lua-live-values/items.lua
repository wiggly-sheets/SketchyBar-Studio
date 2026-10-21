-- The file of the fixture. The script of the item moves the item to the
-- right of the bar, so the value of the script has to win over the value
-- of the config.
sbar.add("item", "clock", {
	position = "left",
	label = { string = "resolved" },
	update_freq = 1,
	script = "sketchybar --set clock position=right",
})
