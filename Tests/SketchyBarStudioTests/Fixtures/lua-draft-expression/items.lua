-- The file of the fixture. The colour of the icon is a number, so the
-- resolver reads it as the hex word of the number.
sbar.add("item", "clock", {
	position = "right",
	label = { string = "10:00" },
	icon = { color = 0xff00ff00 },
})
