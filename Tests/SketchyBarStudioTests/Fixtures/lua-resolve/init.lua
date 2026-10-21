-- The entrypoint of the fixture.
sbar = require("sketchybar")

sbar.begin_config()
require("settings")
require("items")
require("extra")
sbar.end_config()
