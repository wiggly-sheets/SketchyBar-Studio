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
///   of SbarLua). The counter of the upstream starts at zero, so the first
///   name of the upstream is `item_0`; the preview counts from one, which
///   is the wording the app already uses ("item_1, item_2, ...").
/// * The properties of a table become the property pairs of SbarLua: a
///   nested table becomes `prefix.key`, a boolean becomes `on` or `off`,
///   and a number under `color` or `border_color` becomes `0x%x`
///   (`parse_kv_table`, `src/parsing.c` of SbarLua).
/// * The properties of an item come from the last table of the call, so
///   the four argument form of a bracket keeps its members out of the
///   properties (`add`, `src/sketchybar.c` of SbarLua).
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
    local generatedNames = 0

    --- Adds a warning of the run.
    local function warn(message)
      warnings[#warnings + 1] = message
    end

    --- The text of a number, the way Lua writes it.
    local function numberText(value)
      if type(value) ~= "number" then return tostring(value) end
      if math.type(value) == "integer" then
        return string.format("%d", value)
      end
      return string.format("%.14g", value)
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

    --- Adds an item.
    ---
    --- The forms are the forms of SbarLua: `add(type, name, table)`,
    --- `add(type, table)` without a name, `add(type, name, width, table)`
    --- for a graph, a slider and a ring, and `add(type, name, members,
    --- table)` for a bracket.
    local function add(itemType, ...)
      local count = select("#", ...)
      local arguments = { ... }
      local alias
      local first = 1

      if type(arguments[1]) == "string" then
        alias = arguments[1]
        first = 2
      else
        generatedNames = generatedNames + 1
        alias = "item_" .. generatedNames
      end

      local properties = {}
      for index = count, first, -1 do
        if type(arguments[index]) == "table" then
          properties = flatten(arguments[index], nil, {})
          break
        end
      end

      local argument = nil
      if itemType == "graph" or itemType == "slider" or itemType == "ring" then
        local width = arguments[first]
        if width ~= nil then argument = numberText(width) end
      elseif itemType == "bracket" then
        local members = arguments[first]
        if type(members) == "table" then
          local names = {}
          for _, member in ipairs(members) do
            names[#names + 1] = tostring(member)
          end
          argument = table.concat(names, " ")
        end
      elseif itemType == "event" then
        local notification = arguments[first]
        if notification ~= nil then argument = tostring(notification) end
      end

      local item = {
        alias = alias,
        type = itemType,
        argument = argument,
        properties = properties,
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

    --- The JSON document of the run.
    sbar.result = function()
      local parts = {}
      local itemTexts = {}
      for _, item in ipairs(items) do
        itemTexts[#itemTexts + 1] = '{"alias":' .. jsonString(item.alias)
          .. ',"type":' .. jsonString(item.type)
          .. ',"argument":' .. (item.argument and jsonString(item.argument) or "null")
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
      return "{" .. table.concat(parts, ",") .. "}"
    end

    return sbar
    """##
}
