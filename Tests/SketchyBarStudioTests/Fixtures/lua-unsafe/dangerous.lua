-- A module that runs a shell command. The sandbox has no os.execute, so
-- the module fails, the require fails softly, and the rest of the config
-- still loads.
os.execute("touch " .. os.getenv("SKETCHYBAR_STUDIO_MARKER"))

return { loaded = true }
