-- The entrypoint of the fixture.
sbar = require("sketchybar")

sbar.begin_config()
require("dangerous")
require("items")
sbar.end_config()
