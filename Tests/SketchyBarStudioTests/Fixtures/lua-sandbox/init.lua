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

-- io.output with a file name would create the file, so it must fail.
local outputRefused = nil
if marker then
	local output = io.output(marker)
	outputRefused = output == nil
end

-- The debug library must be out of reach: it could switch off the
-- deadline of the run.
local debugReachable = false
pcall(function()
	local module = require("debug")
	debugReachable = module.sethook ~= nil
end)

-- The escape itself. The call must fail.
pcall(function()
	require("debug").sethook()
end)

-- A file outside of the config root is read, and the app warns about it.
local outside = os.getenv("SKETCHYBAR_STUDIO_OUTSIDE")
if outside then
	local handle = io.open(outside, "r")
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
	no_debug_module = package.loaded["debug"] == false and package.preload["debug"] == nil,
	no_debug_reachable = not debugReachable,
	no_io_output = outputRefused,
	no_io_tmpfile = io.tmpfile == nil,
	no_os_tmpname = os.tmpname == nil,
	empty_cpath = package.cpath,
	no_c_searcher = package.searchers[3] == nil and package.searchers[4] == nil,
	path = package.path,
})
