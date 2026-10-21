import Foundation
import CLua

/// Runs the Lua of a config in a sandbox and reads what it declares.
///
/// The runner resolves the values a parser cannot: a colour that comes
/// from a table, a font that a local function builds, a name that an
/// expression computes. It runs the Lua of the config in the app, with
/// the app's rights, and it never writes to the config.
///
/// The sandbox is a GUARD, NOT A SECURITY BOUNDARY. The rules below cut
/// the ways a config can reach the machine (a shell, a write, a C
/// module), and they keep a broken config from taking the app with it,
/// but a determined script can still find a way out of a Lua sandbox.
/// The config is the config of the user, so this is a guard against
/// accidents and not against an attacker.
enum LuaConfigRunner {
    /// The memory the sandbox may use. A run that needs more fails with a
    /// Lua error instead of taking the machine with it.
    static let memoryLimitBytes = 64 * 1024 * 1024

    /// The time one run may take. A run that needs longer fails with a
    /// Lua error instead of hanging the app.
    static let timeoutSeconds: Double = 2.0

    /// One property of the config, with the value the daemon would get.
    struct ResolvedProperty: Hashable {
        /// The key path of the property, such as `icon.font.size`.
        let key: String
        /// The Lua type of the value: `string`, `number` or `boolean`.
        let type: String
        /// The text of the value, the way the daemon receives it.
        let text: String
    }

    /// One item of the config.
    struct ResolvedItem: Hashable {
        /// The name of the item, such as `clock`.
        let alias: String
        /// The type of the item, such as `item` or `bracket`.
        let type: String
        /// The trailing argument of the add command: the width of a graph
        /// and of a slider, the diameter of a ring, the members of a
        /// bracket.
        let argument: String?
        /// The properties of the item, in the order of the load.
        let properties: [ResolvedProperty]
    }

    /// Everything a run resolved.
    struct ResolvedConfig: Hashable {
        /// The items of the bar, in the order they were added.
        let items: [ResolvedItem]
        /// The properties of the default item.
        let defaults: [ResolvedProperty]
        /// The properties of the bar.
        let bar: [ResolvedProperty]
        /// The problems of the run.
        let warnings: [String]
        /// The name of the file that was run, such as `init.lua`. The
        /// daemon runs the config file through the shell, so the file the
        /// preview runs is a guess, and the user has to know which file it
        /// was.
        let entrypoint: String
    }

    /// Why a run failed.
    enum Failure: Error, CustomStringConvertible {
        /// The state of Lua could not be created.
        case cannotStart
        /// The config failed.
        case failed(String)
        /// The config ran longer than the deadline.
        case timedOut(String)
        /// The result of the run could not be read.
        case unreadable(String)

        var description: String {
            switch self {
            case .cannotStart:
                return "the Lua interpreter could not start"
            case .failed(let message):
                return message
            case .timedOut(let message):
                return message
            case .unreadable(let message):
                return message
            }
        }
    }

    /// The file that starts the config.
    ///
    /// SketchyBar runs the config file through the shell
    /// (`exec_config_file`, `src/hotload.c`), so the kernel honours the
    /// shebang of the file: a `#!/usr/bin/env lua` `sketchybarrc` runs
    /// under Lua. The runner cannot run a shell script, so it runs the
    /// `sketchybarrc` when that file is Lua, and the `init.lua` of the
    /// config otherwise.
    ///
    /// It is nil when the config has no Lua entrypoint. A shell config
    /// cannot be resolved this way, and the parser path stays for it.
    static func entrypoint(in root: URL) -> URL? {
        let rc = root.appendingPathComponent("sketchybarrc")
        if let contents = try? String(contentsOf: rc, encoding: .utf8), LuaSourceDetection.isLua(contents) {
            return rc
        }

        let initFile = root.appendingPathComponent("init.lua")
        if FileManager.default.fileExists(atPath: initFile.path) {
            return initFile
        }

        return nil
    }

    /// Runs the config and reads what it declares.
    ///
    /// The run never writes: it reads the files of the config and it
    /// reads the files the config reads.
    static func resolve(configRoot root: URL, entrypoint: URL) throws -> ResolvedConfig {
        // The daemon runs the config with the directory of the config as
        // the working directory (`exec_config_file`, `src/hotload.c`), so
        // a relative path of the config means the same thing in the
        // preview as in the daemon.
        let workingDirectory = FileManager.default.currentDirectoryPath
        FileManager.default.changeCurrentDirectoryPath(root.path)
        defer { FileManager.default.changeCurrentDirectoryPath(workingDirectory) }

        guard let state = clua_create(memoryLimitBytes, timeoutSeconds) else {
            throw Failure.cannotStart
        }
        defer { clua_destroy(state) }

        var error = [CChar](repeating: 0, count: 4096)

        root.path.withCString { rootPointer in
            "CLUA_ROOT".withCString { namePointer in
                clua_set_global_string(state, namePointer, rootPointer)
            }
        }
        LuaSketchyBarShim.source.withCString { sourcePointer in
            "CLUA_SHIM".withCString { namePointer in
                clua_set_global_string(state, namePointer, sourcePointer)
            }
        }

        let sandbox = LuaConfigSandbox.source.withCString { sourcePointer in
            "=sandbox".withCString { chunkPointer in
                clua_run_string(state, sourcePointer, chunkPointer, &error, error.count)
            }
        }
        guard sandbox == 0 else {
            throw Failure.failed(message(of: error))
        }

        let run = entrypoint.path.withCString { pathPointer in
            "=config".withCString { chunkPointer in
                clua_run_file(state, pathPointer, chunkPointer, &error, error.count)
            }
        }
        guard run == 0 else {
            if clua_timed_out(state) != 0 {
                throw Failure.timedOut(message(of: error))
            }
            throw Failure.failed(message(of: error))
        }

        let finished = "__CLUA_RESULT__ = __CLUA_SHIM__.result()".withCString { sourcePointer in
            "=result".withCString { chunkPointer in
                clua_run_string(state, sourcePointer, chunkPointer, &error, error.count)
            }
        }
        guard finished == 0 else {
            throw Failure.failed(message(of: error))
        }

        guard let json = "__CLUA_RESULT__".withCString({ namePointer in
            clua_global_string(state, namePointer)
        }) else {
            throw Failure.unreadable("the Lua config produced no result")
        }

        return try decode(String(cString: json), configRoot: root, entrypoint: entrypoint)
    }

    /// The message of a failed run.
    private static func message(of error: [CChar]) -> String {
        let text = String(cString: error)
        return text.isEmpty ? "the Lua config failed" : text
    }

    /// Reads the JSON document of the shim.
    private static func decode(_ json: String, configRoot: URL, entrypoint: URL) throws -> ResolvedConfig {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let document = root as? [String: Any] else {
            throw Failure.unreadable("the result of the Lua config is not a JSON document")
        }

        let items = (document["items"] as? [[String: Any]] ?? []).map { entry -> ResolvedItem in
            ResolvedItem(
                alias: entry["alias"] as? String ?? "",
                type: entry["type"] as? String ?? "item",
                argument: entry["argument"] as? String,
                properties: properties(of: entry["properties"])
            )
        }

        var warnings = document["warnings"] as? [String] ?? []
        warnings += readWarnings(for: document["reads"] as? [String] ?? [], in: configRoot)

        return ResolvedConfig(
            items: items,
            defaults: properties(of: document["defaults"]),
            bar: properties(of: document["bar"]),
            warnings: warnings,
            entrypoint: entrypoint.lastPathComponent
        )
    }

    /// The warning of every file the config opened outside of the config
    /// root.
    ///
    /// The file is not refused: the daemon reads the same files with the
    /// same rights, and the config is the file of the user. The warning
    /// tells the user what the config read.
    private static func readWarnings(for paths: [String], in root: URL) -> [String] {
        var seen: Set<String> = []
        return paths.compactMap { path in
            guard !isInsideRoot(path, root: root) else { return nil }
            let absolute = absolutePath(of: path, in: root)
            guard seen.insert(absolute).inserted else { return nil }
            return "The config opened the file '\(absolute)' for reading, and the file is outside the config root."
        }
    }

    /// True when a path is inside the config root.
    ///
    /// The root can be a symlink into a dotfiles repository, and the config
    /// can use the other name of the same directory, so the real path of
    /// the file and the real path of the root count as well.
    private static func isInsideRoot(_ path: String, root: URL) -> Bool {
        let full = path.hasPrefix("/") ? path : root.path + "/" + path
        let file = URL(fileURLWithPath: full)
        let roots = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]
        let files = [file.standardizedFileURL.path, file.resolvingSymlinksInPath().path]
        return roots.contains { base in
            files.contains { $0 == base || $0.hasPrefix(base + "/") }
        }
    }

    /// The absolute path of a path of the config.
    ///
    /// The run works in the config root, so a relative path of the config
    /// starts there.
    private static func absolutePath(of path: String, in root: URL) -> String {
        let full = path.hasPrefix("/") ? path : root.path + "/" + path
        return URL(fileURLWithPath: full).standardizedFileURL.path
    }

    /// The properties of a JSON list.
    private static func properties(of value: Any?) -> [ResolvedProperty] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.map { entry in
            let type = entry["type"] as? String ?? "string"
            var text = entry["value"] as? String ?? ""
            if type == "boolean" {
                // SbarLua sends "on" and "off"; the app writes "true" and
                // "false", so the two paths say the same thing.
                text = SketchyBarBoolean.normalized(text) ?? text
            }
            return ResolvedProperty(key: entry["key"] as? String ?? "", type: type, text: text)
        }
    }
}

/// The sandbox of the Lua config resolver.
///
/// The rules live in Lua, because they are easier to read and to change
/// here than in C.
///
/// The rules are:
///
/// * the globals a config must not use are gone: `os.execute`, `os.exit`,
///   `os.remove`, `os.rename`, `io.popen`, `dofile`, `loadfile`, `load`
///   and `package.loadlib`;
/// * the `debug` library is gone, so the config cannot switch off the
///   deadline of the run, and `require("debug")` finds it neither;
/// * `package.cpath` is empty and the C searchers of `package` are gone,
///   so no C module can load — in particular the installed
///   `sketchybar.so` of SbarLua is never loaded;
/// * `package.path` holds the root of the config, so
///   `require("items.left.apple")` resolves inside the config;
/// * `io.open` only reads: every mode but `r` and `rb` is refused, and
///   `io.output`, `io.tmpfile` and `os.tmpname` cannot create a file;
/// * the `sketchybar` module is the shim of the app, never the real one;
/// * `require` fails softly: a module that errors is a warning and an
///   empty table, so the rest of the config still loads.
enum LuaConfigSandbox {
    /// The Lua source of the sandbox.
    static let source: String = ##"""
    -- The sandbox of the Lua config resolver.
    --
    -- THIS IS A GUARD, NOT A SECURITY BOUNDARY. See the Swift file for
    -- the whole story.

    local root = CLUA_ROOT

    -- The shim of the sketchybar module is ours. It is loaded before the
    -- loader of Lua is taken away.
    local shim = assert(load(CLUA_SHIM, "@sketchybar"))()

    -- The globals a config must not use are gone.
    os.execute = nil
    os.exit = nil
    os.remove = nil
    os.rename = nil
    io.popen = nil
    dofile = nil
    loadfile = nil
    load = nil
    package.loadlib = nil

    -- The debug library is gone: it could switch off the deadline hook.
    -- The library is in the loaded modules as well, so `require("debug")`
    -- must not find it either: the loader of Lua finds a module in
    -- `package.loaded` first.
    debug = nil
    package.loaded["debug"] = false
    package.preload["debug"] = nil

    -- No C module can load. The path is empty and the C searchers of the
    -- package are gone, so a module that appends to the path cannot load
    -- one either.
    package.cpath = ""
    package.searchers[3] = nil
    package.searchers[4] = nil

    -- The modules of the config are the only modules.
    package.path = root .. "/?.lua;" .. root .. "/?/init.lua"

    -- io.open only reads.
    local raw_open = io.open
    io.open = function(path, mode)
      if mode == nil then mode = "r" end
      if mode ~= "r" and mode ~= "rb" then
        return nil, "the preview only reads files"
      end
      shim.reads[#shim.reads + 1] = tostring(path)
      return raw_open(path, mode)
    end

    -- io.output with a file name would create the file, so only the file
    -- handle form works.
    local raw_output = io.output
    io.output = function(target)
      if target == nil then return raw_output() end
      if type(target) == "string" then
        return nil, "the preview only reads files"
      end
      return raw_output(target)
    end

    -- io.tmpfile creates a file, and os.tmpname may create one.
    io.tmpfile = nil
    os.tmpname = nil

    -- The sketchybar module is the shim.
    package.preload["sketchybar"] = function() return shim end
    package.loaded["sketchybar"] = shim
    _G.__CLUA_SHIM__ = shim

    -- A module that fails does not stop the config: it is a warning and
    -- an empty table. The deadline of the sandbox is the exception: it
    -- aborts the whole run, so it is never a soft failure.
    local timeoutMarker = "the Lua config ran for more than"
    local raw_require = require
    require = function(name)
      package.cpath = ""
      local ok, result = pcall(raw_require, name)
      if ok then return result end
      local message = tostring(result)
      if message:find(timeoutMarker, 1, true) then
        error(result, 0)
      end
      shim.warnings[#shim.warnings + 1] = "The module '" .. tostring(name)
        .. "' could not be loaded: " .. message
      return {}
    end
    """##
}
