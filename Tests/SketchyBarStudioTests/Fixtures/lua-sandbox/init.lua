-- The entrypoint of the fixture. It reports the state of the sandbox and
-- it tries to write a file.
sbar = require("sketchybar")

local marker = os.getenv("SKETCHYBAR_STUDIO_MARKER")
if marker then
	local handle = io.open(marker, "w")
	if handle then
		handle:close()
	end
end

sbar.add("item", "sandbox", {
	position = "left",
	label = { string = "sandbox" },
	no_os_execute = os.execute == nil,
	no_os_exit = os.exit == nil,
	no_io_popen = io.popen == nil,
	no_dofile = dofile == nil,
	no_loadfile = loadfile == nil,
	no_load = load == nil,
	no_package_loadlib = package.loadlib == nil,
	no_debug = debug == nil,
	empty_cpath = package.cpath,
	no_c_searcher = package.searchers[3] == nil and package.searchers[4] == nil,
	path = package.path,
})
