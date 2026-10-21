import Foundation

/// The SbarLua shim of the preview.
///
/// The shim is the Lua module the config gets when it calls
/// `require("sketchybar")`. It reproduces the API of the real SbarLua
/// module (`src/sketchybar.c` of <https://github.com/felixkratz/SbarLua>)
/// and it records what the config declares. Nothing is sent to a daemon:
/// every side effect is recorded and never executed.
///
/// The rules it reproduces, and where they come from:
///
/// * The name of an item without a name is `item_<N>`, with N counting the
///   items without a name in load order (`generate_uid`, `src/sketchybar.c`
///   of SbarLua). The counter of the upstream is the counter of the
///   process, so it starts at zero and every module of the config shares
///   it: the first name of the upstream is `item_0`.
/// * The daemon supports the types `item`, `alias`, `space`, `event`,
///   `slider`, `graph` and `bracket` (`add`, `src/sketchybar.c` of
///   SbarLua). An add of another type, and an add the daemon refuses,
///   create no item at all.
/// * The properties of a table become the property pairs of SbarLua: a
///   nested table becomes `prefix.key`, a boolean becomes `on` or `off`,
///   and a number under `color` or `border_color` becomes `0x%x`
///   (`parse_kv_table`, `src/parsing.c` of SbarLua).
/// * The properties of an item come from the last argument of the call,
///   and only when that argument is a table (`add`, `src/sketchybar.c` of
///   SbarLua), so the four argument form of a bracket keeps its members
///   out of the properties.
/// * Every item knows the file that declared it and the number of the
///   declaration inside that file. The sandbox tells the shim which file
///   it is loading, so the draft of a file can be put on the item that
///   the file declared.
///
/// The result is a JSON document, written by hand. Every property keeps
/// the Lua type of its value in the `type` field, and the text of the
/// value in the `value` field: the text is the text the daemon would
/// receive.
enum LuaSketchyBarShim {
    /// The Lua source of the shim.
    static let source: String = ##"""
    -- The SbarLua shim of the preview.
    --
    -- It records what the config declares. Nothing is executed: every side
    -- effect of the config is recorded and thrown away.

    local sbar = {}

    local items = {}
    local itemsByName = {}
    local defaultProperties = {}
    local barProperties = {}
    local warnings = {}
    local commands = {}
    local reads = {}
    local generatedNames = 0
    local itemIndexes = {}

    --- Adds a warning of the run.
    local function warn(message)
      warnings[#warnings + 1] = message
    end

    --- The file that is being loaded.
    ---
    --- The sandbox sets the global when it loads a module, so the shim
    --- knows which file every declaration comes from. The name of the file
    --- is the path of the file relative to the root of the config, the way
    --- the sidebar names it.
    local function currentFile()
      local file = _G.__CLUA_MODULE__
      if type(file) == "string" and file ~= "" then return file end
      return ""
    end

    --- The number of the next declaration of a file.
    ---
    --- The number counts every call of `sbar.add` of the file, so a call
    --- the shim refuses does not shift the calls that follow it. The parser
    --- of the app counts the calls of the file the same way, so the number
    --- and the file name the same declaration on both sides.
    local function nextIndex(file)
      local index = itemIndexes[file] or 0
      itemIndexes[file] = index + 1
      return index
    end

    --- The text of a number, the way Lua writes it.
    ---
    --- The daemon sends the value with `lua_tostring`, and the shim runs
    --- inside the interpreter, so `tostring` is that function: a float
    --- that looks like an integer keeps its ".0", and a float that needs
    --- more digits gets them.
    local function numberText(value)
      return tostring(value)
    end

    --- The colour of a number, the way SbarLua writes it: "0x%x" of the
    --- number as an unsigned 32 bit value.
    local function colorText(value)
      local number = math.floor(value) % 4294967296
      if number < 0 then number = number + 4294967296 end
      return string.format("0x%x", number)
    end

    --- The text of a value, the way the daemon receives it.
    local function valueText(leaf, value)
      local kind = type(value)
      if kind == "boolean" then
        return "boolean", value and "on" or "off"
      end
      if kind == "number" then
        if leaf == "color" or leaf == "border_color" then
          return "number", colorText(value)
        end
        return "number", numberText(value)
      end
      return "string", tostring(value)
    end

    --- The property pairs of a table, the way SbarLua flattens them.
    ---
    --- A nested table becomes "prefix.key". The keys are sorted, so the
    --- same table always produces the same pairs.
    local function flatten(source, prefix, out)
      local keys = {}
      for key in pairs(source) do
        keys[#keys + 1] = key
      end
      table.sort(keys, function(a, b)
        local kindA, kindB = type(a), type(b)
        if kindA ~= kindB then return kindA < kindB end
        if kindA == "number" or kindA == "string" then return a < b end
        return tostring(a) < tostring(b)
      end)

      for _, key in ipairs(keys) do
        local value = source[key]
        local name = tostring(key)
        local path = prefix and (prefix .. "." .. name) or name
        if type(value) == "table" then
          flatten(value, path, out)
        else
          local kind = type(value)
          if kind == "string" or kind == "number" or kind == "boolean" then
            local valueKind, text = valueText(name, value)
            out[#out + 1] = { key = path, type = valueKind, value = text }
          end
        end
      end

      return out
    end

    --- The JSON text of a string.
    local function jsonString(text)
      local out = '"'
      for index = 1, #text do
        local character = text:sub(index, index)
        local code = string.byte(character)
        if character == '"' then
          out = out .. '\\"'
        elseif character == "\\" then
          out = out .. "\\\\"
        elseif code == 10 then
          out = out .. "\\n"
        elseif code == 13 then
          out = out .. "\\r"
        elseif code == 9 then
          out = out .. "\\t"
        elseif code == 8 then
          out = out .. "\\b"
        elseif code == 12 then
          out = out .. "\\f"
        elseif code < 32 then
          out = out .. string.format("\\u%04x", code)
        else
          out = out .. character
        end
      end
      return out .. '"'
    end

    --- The JSON text of a property.
    local function jsonProperty(property)
      return '{"key":' .. jsonString(property.key)
        .. ',"type":' .. jsonString(property.type)
        .. ',"value":' .. jsonString(property.value) .. '}'
    end

    --- The JSON text of a list of properties.
    local function jsonProperties(properties)
      local parts = {}
      for _, property in ipairs(properties) do
        parts[#parts + 1] = jsonProperty(property)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end

    --- The nested table of the properties of an item, the way a query of
    --- SbarLua answers.
    local function nestedProperties(item)
      local result = {}
      for _, property in ipairs(item.properties) do
        local parts = {}
        for part in property.key:gmatch("[^%.]+") do
          parts[#parts + 1] = part
        end
        local target = result
        for index = 1, #parts - 1 do
          local part = parts[index]
          if type(target[part]) ~= "table" then target[part] = {} end
          target = target[part]
        end
        target[parts[#parts]] = property.value
      end
      return result
    end

    --- The item of an alias, or nil.
    local function itemOf(alias)
      return itemsByName[alias]
    end

    --- Adds the properties of a table to an item. The last value of a
    --- property wins, like every other property of SketchyBar.
    local function applyProperties(alias, source)
      local item = itemOf(alias)
      if not item then
        warn("The item '" .. tostring(alias) .. "' is set but never added, so the preview cannot show it.")
        return
      end
      local properties = flatten(source, nil, {})
      for _, property in ipairs(properties) do
        item.properties[#item.properties + 1] = property
      end
    end

    --- The name of an item, whether it is a string or an item object.
    local function nameOf(value)
      if type(value) == "table" then return value.name end
      return tostring(value)
    end

    --- The item types the daemon supports (`add`, `src/sketchybar.c` of
    --- SbarLua). An add of another type creates no item.
    local supportedTypes = {
      item = true,
      alias = true,
      space = true,
      event = true,
      slider = true,
      graph = true,
      bracket = true,
    }

    --- Adds an item.
    ---
    --- The forms are the forms of SbarLua: `add(type, name, table)`,
    --- `add(type, table)` without a name, `add(type, name, width, table)`
    --- for a graph and a slider, and `add(type, name, members, table)` for
    --- a bracket.
    ---
    --- The daemon refuses an add it cannot use and creates no item for it,
    --- so the shim refuses it too.
    local function add(itemType, ...)
      local count = select("#", ...)
      local arguments = { ... }

      -- The file and the number of the declaration. The number is taken
      -- before the shim looks at the call, so a call it refuses does not
      -- move the calls that follow it.
      local file = currentFile()
      local index = nextIndex(file)

      if count < 1 then
        warn("An item was added without a name, so SketchyBar creates no item for it.")
        return nil
      end

      -- The name of the item. The daemon names an item without a name
      -- `item_<N>`, and the counter is the counter of the process, so it
      -- starts at zero and every module of the config shares it.
      local alias
      local rest
      if type(arguments[1]) == "string" then
        alias = arguments[1]
        rest = {}
        for index = 2, count do rest[#rest + 1] = arguments[index] end
      else
        alias = "item_" .. generatedNames
        generatedNames = generatedNames + 1
        rest = arguments
      end

      if not supportedTypes[itemType] then
        warn("The item type '" .. tostring(itemType) .. "' is not supported by SketchyBar, so the preview cannot show it.")
        return nil
      end

      -- The type decides what the daemon wants after the name.
      local argument = nil
      if itemType == "graph" or itemType == "slider" then
        if type(rest[1]) ~= "number" then
          warn("A '" .. itemType .. "' item needs a width, so SketchyBar creates no item for it.")
          return nil
        end
        argument = numberText(rest[1])
        if itemType == "graph" and type(rest[2]) ~= "table" then
          warn("A 'graph' item needs a table of properties, so SketchyBar creates no item for it.")
          return nil
        end
      elseif itemType == "bracket" then
        if type(rest[1]) ~= "table" then
          warn("A 'bracket' item needs a table of members, so SketchyBar creates no item for it.")
          return nil
        end
        local names = {}
        for _, member in ipairs(rest[1]) do
          names[#names + 1] = tostring(member)
        end
        argument = table.concat(names, " ")
      elseif itemType == "event" then
        -- The daemon wants the name of the notification as a string, and
        -- it creates no event item without a name.
        if #rest == 1 and type(rest[1]) ~= "string" then
          warn("An 'event' item needs a name, so SketchyBar creates no item for it.")
          return nil
        end
        if rest[1] ~= nil then argument = tostring(rest[1]) end
      end

      -- The properties come from the last argument of the call, and only
      -- when that argument is a table.
      local properties = {}
      local last = arguments[count]
      if type(last) == "table" then
        properties = flatten(last, nil, {})
      end

      local item = {
        alias = alias,
        type = itemType,
        argument = argument,
        properties = properties,
        file = file,
        index = index,
      }
      items[#items + 1] = item
      itemsByName[alias] = item

      local object = { name = alias }
      function object:set(source)
        applyProperties(alias, source)
      end
      function object:subscribe(events, callback)
        commands[#commands + 1] = { kind = "subscribe", alias = alias, events = events }
      end
      function object:query()
        local found = itemOf(alias)
        if not found then return {} end
        return nestedProperties(found)
      end
      function object:push(values)
        commands[#commands + 1] = { kind = "push", alias = alias, values = values }
      end
      return object
    end

    --- Adds an item. The type is the first argument.
    sbar.add = function(itemType, ...)
      if type(itemType) ~= "string" then
        warn("An item was added without a type, so the preview cannot show it.")
        return nil
      end
      return add(itemType, ...)
    end

    --- Sets the properties of the default item.
    sbar.default = function(source)
      if type(source) ~= "table" then
        warn("The default item was set without a table, so the preview cannot show it.")
        return
      end
      local properties = flatten(source, nil, {})
      for _, property in ipairs(properties) do
        defaultProperties[#defaultProperties + 1] = property
      end
    end

    --- Sets the properties of the bar.
    sbar.bar = function(source)
      if type(source) ~= "table" then
        warn("The bar was set without a table, so the preview cannot show it.")
        return
      end
      local properties = flatten(source, nil, {})
      for _, property in ipairs(properties) do
        barProperties[#barProperties + 1] = property
      end
    end

    --- Sets the properties of an item.
    sbar.set = function(target, source)
      if type(source) ~= "table" then
        warn("An item was set without a table, so the preview cannot show it.")
        return
      end
      applyProperties(nameOf(target), source)
    end

    --- Runs a command. The command is recorded, never run.
    sbar.exec = function(command, callback)
      commands[#commands + 1] = { kind = "exec", command = command }
    end

    --- Runs a command later. The command is recorded, never run.
    sbar.delay = function(seconds, callback)
      commands[#commands + 1] = { kind = "delay", seconds = seconds }
    end

    --- The event loop of SketchyBar. It returns at once: the preview has
    --- no daemon to talk to.
    sbar.event_loop = function()
      commands[#commands + 1] = { kind = "event_loop" }
    end

    --- Turns the hotload of SketchyBar on or off.
    sbar.hotload = function(enabled)
      commands[#commands + 1] = { kind = "hotload", enabled = enabled and true or false }
    end

    --- Starts a transaction.
    sbar.begin_config = function()
      commands[#commands + 1] = { kind = "begin_config" }
    end

    --- Ends a transaction.
    sbar.end_config = function()
      commands[#commands + 1] = { kind = "end_config" }
    end

    --- Triggers an event.
    sbar.trigger = function(event, environment)
      commands[#commands + 1] = { kind = "trigger", event = event }
    end

    --- Animates the bar. The animation is recorded, never run.
    sbar.animate = function(interpolation, duration, callback)
      commands[#commands + 1] = { kind = "animate", interpolation = interpolation, duration = duration }
    end

    --- The state of an item.
    sbar.query = function(target)
      local found = itemOf(nameOf(target))
      if not found then return {} end
      return nestedProperties(found)
    end

    --- Pushes values to an item. The values are recorded, never sent.
    sbar.push = function(target, source)
      commands[#commands + 1] = { kind = "push", alias = nameOf(target) }
    end

    --- Removes an item. The removal is recorded, never sent.
    sbar.remove = function(target)
      commands[#commands + 1] = { kind = "remove", alias = nameOf(target) }
    end

    --- The name of the bar of SketchyBar.
    sbar.set_bar_name = function(name)
      commands[#commands + 1] = { kind = "set_bar_name", name = name }
    end

    --- The warnings of the run.
    sbar.warnings = warnings

    --- The files the config opened for reading. The sandbox fills the
    --- list, and the app names the files that lie outside the config root.
    sbar.reads = reads

    --- The JSON document of the run.
    sbar.result = function()
      local parts = {}
      local itemTexts = {}
      for _, item in ipairs(items) do
        itemTexts[#itemTexts + 1] = '{"alias":' .. jsonString(item.alias)
          .. ',"type":' .. jsonString(item.type)
          .. ',"argument":' .. (item.argument and jsonString(item.argument) or "null")
          .. ',"file":' .. jsonString(item.file)
          .. ',"index":' .. tostring(item.index)
          .. ',"properties":' .. jsonProperties(item.properties) .. '}'
      end
      parts[#parts + 1] = '"items":[' .. table.concat(itemTexts, ",") .. "]"
      parts[#parts + 1] = '"defaults":' .. jsonProperties(defaultProperties)
      parts[#parts + 1] = '"bar":' .. jsonProperties(barProperties)
      local warningTexts = {}
      for _, warning in ipairs(warnings) do
        warningTexts[#warningTexts + 1] = jsonString(warning)
      end
      parts[#parts + 1] = '"warnings":[' .. table.concat(warningTexts, ",") .. "]"
      local readTexts = {}
      for _, path in ipairs(reads) do
        readTexts[#readTexts + 1] = jsonString(path)
      end
      parts[#parts + 1] = '"reads":[' .. table.concat(readTexts, ",") .. "]"
      return "{" .. table.concat(parts, ",") .. "}"
    end

    return sbar
    """##
}
