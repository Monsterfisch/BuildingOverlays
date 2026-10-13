--[[
  A small PNG reader for the button pictures: zlib inflate (stored, fixed and dynamic
  Huffman blocks), the five scanline filters, and colour types 0, 2, 3, 4 and 6 at 1, 2, 4,
  8 or 16 bits. Interlaced pictures are refused. Runs once at start-up, so it favours being
  short over being fast.

  png.decode(bytes) -> width, height, pixels where pixels[i] = { r, g, b, a } (0..255),
  row by row from the top left, i counting from 1. Raises an error with a readable message.
]]

local png = {}

local LENGTH_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
  67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LENGTH_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4,
  5, 5, 5, 5, 0 }
local DISTANCE_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385,
  513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DISTANCE_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10,
  10, 11, 11, 12, 12, 13, 13 }
local CODE_LENGTH_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- Canonical Huffman table from code lengths (index 0 .. n-1), as in zlib's puff.c.
local function huffman(lengths, n)
  local counts = {}
  for length = 0, 15 do counts[length] = 0 end
  for symbol = 0, n - 1 do
    local length = lengths[symbol] or 0
    counts[length] = counts[length] + 1
  end
  counts[0] = 0
  local offsets = { [1] = 0 }
  for length = 1, 14 do offsets[length + 1] = offsets[length] + counts[length] end
  local symbols = {}
  for symbol = 0, n - 1 do
    local length = lengths[symbol] or 0
    if length ~= 0 then
      symbols[offsets[length]] = symbol
      offsets[length] = offsets[length] + 1
    end
  end
  return { counts = counts, symbols = symbols }
end

local FIXED_LITERALS, FIXED_DISTANCES
do
  local lengths = {}
  for symbol = 0, 143 do lengths[symbol] = 8 end
  for symbol = 144, 255 do lengths[symbol] = 9 end
  for symbol = 256, 279 do lengths[symbol] = 7 end
  for symbol = 280, 287 do lengths[symbol] = 8 end
  FIXED_LITERALS = huffman(lengths, 288)
  local distances = {}
  for symbol = 0, 29 do distances[symbol] = 5 end
  FIXED_DISTANCES = huffman(distances, 30)
end

---Inflates a raw deflate stream that starts at `position` in `data`; returns a table of bytes.
local function inflate(data, position)
  local out, outLength = {}, 0
  local bitBuffer, bitCount = 0, 0

  local function bits(n)
    while bitCount < n do
      local byte = data:byte(position)
      if byte == nil then error("the picture data ends too early") end
      position = position + 1
      bitBuffer = bitBuffer | (byte << bitCount)
      bitCount = bitCount + 8
    end
    local value = bitBuffer & ((1 << n) - 1)
    bitBuffer = bitBuffer >> n
    bitCount = bitCount - n
    return value
  end

  local function decode(table)
    local code, first, index = 0, 0, 0
    for length = 1, 15 do
      code = code | bits(1)
      local count = table.counts[length]
      if code - count < first then return table.symbols[index + (code - first)] end
      index = index + count
      first = (first + count) << 1
      code = code << 1
    end
    error("the picture data is damaged")
  end

  local function codes(literals, distances)
    while true do
      local symbol = decode(literals)
      if symbol < 256 then
        outLength = outLength + 1
        out[outLength] = symbol
      elseif symbol == 256 then
        return
      else
        symbol = symbol - 257
        if symbol >= 29 then error("the picture data is damaged") end
        local length = LENGTH_BASE[symbol + 1] + bits(LENGTH_EXTRA[symbol + 1])
        local distanceSymbol = decode(distances)
        if distanceSymbol >= 30 then error("the picture data is damaged") end
        local distance = DISTANCE_BASE[distanceSymbol + 1] + bits(DISTANCE_EXTRA[distanceSymbol + 1])
        if distance > outLength then error("the picture data is damaged") end
        for _ = 1, length do
          outLength = outLength + 1
          out[outLength] = out[outLength - distance]
        end
      end
    end
  end

  repeat
    local last = bits(1)
    local kind = bits(2)
    if kind == 0 then
      bitBuffer, bitCount = 0, 0
      local length = data:byte(position) | (data:byte(position + 1) << 8)
      position = position + 4
      for k = 0, length - 1 do
        outLength = outLength + 1
        out[outLength] = data:byte(position + k)
      end
      position = position + length
    elseif kind == 1 then
      codes(FIXED_LITERALS, FIXED_DISTANCES)
    elseif kind == 2 then
      local literalCount = bits(5) + 257
      local distanceCount = bits(5) + 1
      local codeLengthCount = bits(4) + 4
      local lengths = {}
      for k = 1, 19 do lengths[CODE_LENGTH_ORDER[k]] = 0 end
      for k = 1, codeLengthCount do lengths[CODE_LENGTH_ORDER[k]] = bits(3) end
      local lengthCodes = huffman(lengths, 19)
      local all, index = {}, 0
      while index < literalCount + distanceCount do
        local symbol = decode(lengthCodes)
        if symbol < 16 then
          all[index] = symbol
          index = index + 1
        else
          local value, times = 0, 0
          if symbol == 16 then
            if index == 0 then error("the picture data is damaged") end
            value, times = all[index - 1], 3 + bits(2)
          elseif symbol == 17 then
            times = 3 + bits(3)
          else
            times = 11 + bits(7)
          end
          for _ = 1, times do
            all[index] = value
            index = index + 1
          end
        end
      end
      local literalLengths, distanceLengths = {}, {}
      for k = 0, literalCount - 1 do literalLengths[k] = all[k] end
      for k = 0, distanceCount - 1 do distanceLengths[k] = all[literalCount + k] end
      codes(huffman(literalLengths, literalCount), huffman(distanceLengths, distanceCount))
    else
      error("the picture data is damaged")
    end
  until last == 1
  return out
end

local function u32(data, position)
  local a, b, c, d = data:byte(position, position + 3)
  return ((a << 24) | (b << 16) | (c << 8) | d)
end

local CHANNELS = { [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 }

function png.decode(data)
  if data:sub(1, 8) ~= "\137PNG\r\n\26\n" then error("this is not a PNG file") end
  local position = 9
  local width, height, depth, colourType, interlace
  local palette, transparency, compressed = {}, nil, {}
  while position + 8 <= #data do
    local length = u32(data, position)
    local kind = data:sub(position + 4, position + 7)
    local body = position + 8
    if kind == "IHDR" then
      width, height = u32(data, body), u32(data, body + 4)
      depth, colourType = data:byte(body + 8), data:byte(body + 9)
      interlace = data:byte(body + 12)
    elseif kind == "PLTE" then
      for k = 0, length // 3 - 1 do
        palette[k] = { data:byte(body + k * 3, body + k * 3 + 2) }
      end
    elseif kind == "tRNS" then
      transparency = data:sub(body, body + length - 1)
    elseif kind == "IDAT" then
      compressed[#compressed + 1] = data:sub(body, body + length - 1)
    elseif kind == "IEND" then
      break
    end
    position = body + length + 4
  end
  if width == nil then error("the PNG file has no header") end
  if interlace ~= 0 then error("interlaced PNG files are not supported, save it without interlacing") end
  local channels = CHANNELS[colourType]
  if channels == nil then error("unknown PNG colour type " .. tostring(colourType)) end
  if width < 1 or height < 1 or width > 256 or height > 256 then
    error("the picture must be between 1x1 and 256x256 pixels")
  end

  local stream = table.concat(compressed)
  local raw = inflate(stream, 3) -- skip the two byte zlib header

  local bitsPerPixel = channels * depth
  local bytesPerPixel = math.max(1, bitsPerPixel // 8)
  local stride = (width * bitsPerPixel + 7) // 8
  local rows, previous = {}, {}
  for k = 1, stride do previous[k] = 0 end
  local cursor = 1
  for row = 1, height do
    local filter = raw[cursor]
    if filter == nil then error("the picture data ends too early") end
    cursor = cursor + 1
    local line = {}
    for k = 1, stride do
      local x = raw[cursor + k - 1] or 0
      local a = k > bytesPerPixel and line[k - bytesPerPixel] or 0
      local b = previous[k]
      local c = k > bytesPerPixel and previous[k - bytesPerPixel] or 0
      if filter == 1 then
        x = x + a
      elseif filter == 2 then
        x = x + b
      elseif filter == 3 then
        x = x + (a + b) // 2
      elseif filter == 4 then
        local p = a + b - c
        local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
        if pa <= pb and pa <= pc then x = x + a elseif pb <= pc then x = x + b else x = x + c end
      end
      line[k] = x & 0xFF
    end
    cursor = cursor + stride
    rows[row] = line
    previous = line
  end

  local function sample(line, index)
    -- index: 0-based sample number within the row
    if depth == 8 then return line[index + 1] end
    if depth == 16 then return line[index * 2 + 1] end
    local perByte = 8 // depth
    local byte = line[index // perByte + 1]
    local shift = 8 - depth * (index % perByte + 1)
    return (byte >> shift) & ((1 << depth) - 1)
  end
  local maxValue = (1 << math.min(depth, 8)) - 1
  local function scale(value)
    if depth >= 8 then return value end
    return value * 255 // maxValue
  end

  local transparentKey = nil
  if transparency ~= nil and (colourType == 0 or colourType == 2) then
    local function word(k) return (transparency:byte(k) << 8) | transparency:byte(k + 1) end
    if colourType == 0 then
      transparentKey = { word(1) }
    else
      transparentKey = { word(1), word(3), word(5) }
    end
  end

  local pixels = {}
  local n = 0
  for row = 1, height do
    local line = rows[row]
    for column = 0, width - 1 do
      local r, g, b, a
      if colourType == 3 then
        local index = sample(line, column)
        local entry = palette[index] or { 0, 0, 0 }
        r, g, b = entry[1], entry[2], entry[3]
        a = transparency and transparency:byte(index + 1) or 255
      elseif colourType == 0 or colourType == 4 then
        local raw0 = sample(line, column * channels)
        r = scale(raw0)
        g, b = r, r
        a = colourType == 4 and scale(sample(line, column * channels + 1)) or 255
        if transparentKey and raw0 == (depth == 16 and transparentKey[1] >> 8 or transparentKey[1]) then a = 0 end
      else
        r = sample(line, column * channels)
        g = sample(line, column * channels + 1)
        b = sample(line, column * channels + 2)
        a = colourType == 6 and sample(line, column * channels + 3) or 255
        if transparentKey and depth == 8 and r == transparentKey[1] and g == transparentKey[2]
          and b == transparentKey[3] then
          a = 0
        end
      end
      n = n + 1
      pixels[n] = { r, g, b, a }
    end
  end
  return width, height, pixels
end

return png
