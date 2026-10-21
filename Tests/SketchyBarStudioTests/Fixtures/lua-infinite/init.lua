-- The entrypoint of the fixture. The endless loop must abort with the
-- deadline of the sandbox.
sbar = require("sketchybar")

-- The debug library is gone, so this call fails. If it did not fail, the
-- endless loop below would never end.
pcall(function()
	require("debug").sethook()
end)

while true do
end
