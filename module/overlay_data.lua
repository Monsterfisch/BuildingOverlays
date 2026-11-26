-- Parse the literal table used by packs and earlier calibration files.
-- Never run code from an overlay data file.
local data = {}
local MAX_BYTES = 1024 * 1024
local MAX_ENTRIES = 8192
local ORDER = { "name", "label", "game", "building", "picture", "entrance", "units", "gate", "x", "y" }
local fields = {}
for _, key in ipairs(ORDER) do fields[key] = true end

local function parse(text)
  local position = 1
  local function take(pattern)
    while true do
      local _, whitespace = text:find("^%s+", position)
      if whitespace then position = whitespace + 1 end
      if text:sub(position, position + 1) ~= "--" then break end
      position = (text:find("[\r\n]", position + 2) or #text) + 1
    end
    local first, last = text:find("^" .. pattern, position)
    if first == nil then return nil end
    position = last + 1
    return text:sub(first, last)
  end

  local function quoted(quote)
    local pieces = {}
    local escapes = { ["\n"] = "\n", n = "\n", r = "\r", t = "\t", ['\\'] = "\\", ['"'] = '"', ["'"] = "'" }
    while position <= #text do
      local char = text:sub(position, position)
      position = position + 1
      if char == quote then return table.concat(pieces) end
      if char == "\\" then
        local digits = text:match("^%d%d?%d?", position)
        if digits then
          char = string.char(tonumber(digits))
          position = position + #digits
        else
          char = assert(escapes[text:sub(position, position)], "invalid string escape")
          position = position + 1
        end
      end
      pieces[#pieces + 1] = char
    end
    error("unterminated string")
  end

  assert(take("return%f[^%w_]") and take("{"), "expected a returned list")
  local entries = {}
  while not take("}") do
    assert(#entries < MAX_ENTRIES and take("{"), "expected an overlay record")
    local entry = {}
    while not take("}") do
      local key = take("[%a_][%w_]*")
      assert(fields[key] and entry[key] == nil and take("="), "invalid overlay field")
      local quote = take([=[["']]=])
      if quote then
        entry[key] = quoted(quote)
      else
        entry[key] = assert(math.tointeger(tonumber(take("[+-]?%d+") or "")), "expected an integer or string")
      end
      if not take("[,;]") then
        assert(take("}"), "expected end of overlay record")
        break
      end
    end
    entries[#entries + 1] = entry
    if not take("[,;]") then
      assert(take("}"), "expected end of overlay list")
      break
    end
  end
  assert(not take("."), "unexpected data after overlay list")
  return entries
end

local store

---Opens `name` in this module's UCP user data folder, as io.open does.
local function userOpen(name, mode)
  store = store or userdata.interface()
  if store == nil then return nil, "the user data folder is not ready" end
  local ok, file, err = pcall(store.open, store, name, mode)
  if not ok then return nil, file end
  return file, err
end

function data.read(path, open)
  local file, err = (open or io.open)(path, "rb")
  if file == nil then return nil, err end
  local text = file:read(MAX_BYTES + 1)
  file:close()
  if text == nil or #text > MAX_BYTES then return nil, "invalid overlay file size" end
  local ok, entries = pcall(parse, text)
  if not ok then return nil, entries end
  return entries, tonumber(text:match("^%-%- generation: (%d+)\n")) or 0
end

---One entry as a line of an overlays.lua list.
function data.format(entry)
  local parts = {}
  for _, key in ipairs(ORDER) do
    local value = entry[key]
    if value ~= nil then
      parts[#parts + 1] = string.format(type(value) == "string" and "%s = %q" or "%s = %d", key, value)
    end
  end
  return "  { " .. table.concat(parts, ", ") .. " },"
end

---The name a source's calibration was saved under in the ucp folder: "module", or the plugin's
---folder name.
local function calibrationName(folder)
  if folder == nil then return "module" end
  return folder:match("plugins/([^/]+)/") or folder:gsub("/$", ""):match("([^/]+)$") or "plugin"
end

---The file name of `folder`'s calibration in the user data folder: "_module" (a plugin's name has
---no "_"), or the plugin's name without its version, so a plugin update keeps it.
local function userName(folder)
  if folder == nil then return "_module" end
  return (calibrationName(folder):gsub("%-%d+%.%d+%.%d+$", ""):gsub("[^%w.~-]", "-"):gsub("%.%.+", "."))
end

local function slots(prefix, open)
  local first, firstSeq = data.read(prefix .. "-a.lua", open)
  local second, secondSeq = data.read(prefix .. "-b.lua", open)
  firstSeq = first and firstSeq or -1
  secondSeq = second and secondSeq or -1
  if firstSeq >= secondSeq then return first, firstSeq, prefix .. "-b.lua" end
  return second, secondSeq, prefix .. "-a.lua"
end

---The calibration saved for the overlays from `folder` (nil: the module's own) in the user data
---folder. Else, read only: the one in the game's ucp folder or the first readable `...` path,
---with true as second result.
function data.readCalibration(folder, ...)
  local entries = slots(userName(folder), userOpen)
  if entries ~= nil then return entries, false end
  local name = calibrationName(folder)
  if folder ~= nil and name == "module" then return nil, false end -- the module's own files
  local legacy = "ucp/building-overlays-" .. name:gsub("[^%w_.-]", "_")
  entries = slots(legacy)
  for _, path in ipairs({ legacy .. ".lua", ... }) do
    entries = entries or data.read(path)
  end
  return entries, entries ~= nil
end

function data.saveCalibration(folder, lines)
  local _, sequence, target = slots(userName(folder), userOpen)
  local contents = "-- generation: " .. (sequence + 1) .. "\n" .. table.concat(lines, "\n") .. "\n"
  if #contents > MAX_BYTES then return nil, "overlay data exceeds the size limit" end
  local file, err = userOpen(target, "wb")
  if not file then return nil, err end
  local written, writeError = file:write(contents)
  local closed, closeError = file:close()
  if not written or not closed then return nil, writeError or closeError end
  local entries, storedSequence = data.read(target, userOpen)
  if not entries or storedSequence ~= sequence + 1 then return nil, "cannot verify " .. target end
  return target
end

return data
