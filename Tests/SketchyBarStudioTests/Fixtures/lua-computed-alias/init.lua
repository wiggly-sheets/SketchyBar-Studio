-- The entrypoint of the fixture. The name of every item is built by an
-- expression.
sbar = require("sketchybar")

for index = 1, 3 do
	sbar.add("item", "space." .. index, {
		position = "left",
		label = { string = "s" .. index },
	})
end
