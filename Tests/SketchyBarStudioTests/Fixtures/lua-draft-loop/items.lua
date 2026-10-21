-- The file of the fixture. The first item is declared in a loop, so the
-- calls of the file do not line up with the declarations of the file.
for index = 1, 2 do
	sbar.add("item", "looped", {
		position = "left",
		label = { string = "loop" },
	})
end

sbar.add("item", "last", {
	position = "right",
	label = { string = "last" },
})
