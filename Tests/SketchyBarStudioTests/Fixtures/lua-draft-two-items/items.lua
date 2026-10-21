-- The file of the fixture. It declares two items, so the draft of the
-- second one can be told from the draft of the first one.
sbar.add("item", "one", {
	position = "left",
	label = { string = "one" },
})

sbar.add("item", "two", {
	position = "right",
	label = { string = "two" },
})
