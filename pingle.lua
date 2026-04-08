---------------------------------------------------------------------------------
--                                                   .---.                     --
--  _________   _...._      .--.   _..._             |   |      __.....__      --
--  \        |.'      '-.   |__| .'     '.   .--./)  |   |  .-''         '.    --
--   \        .'```'.    '. .--..   .-.   . /.''\\   |   | /     .-''"'-.  `.  --
--    \      |       \     \|  ||  '   '  || |  | |  |   |/     /________\   \ --
--     |     |        |    ||  ||  |   |  | \`-' /   |   ||                  | --
--     |      \      /    . |  ||  |   |  | /("'`    |   |\    .-------------' --
--     |     |\`'-.-'   .'  |  ||  |   |  | \ '---.  |   | \    '-.____...---. --
--     |     | '-....-'`    |__||  |   |  |  /'""'.\ |   |  `.             .'  --
--    .'     '.                 |  |   |  | ||     ||'---'    `''-...... -'    --
--  '-----------'               |  |   |  | \'. __//                           --
--                              '--'   '--'  `'---'                            --
--  _              ______           _   _                                      --
-- | |             |  _  \         | | | |                                     --
-- | |__  _   _    | | | |_   _ ___| |_| | ___ _   _                           --
-- | '_ \| | | |   | | | | | | / __| __| |/ _ \ | | |                          --
-- | |_) | |_| |   | |/ /| |_| \__ \ |_| |  __/ |_| |                          --
-- |_.__/ \__, |   |___/  \__,_|___/\__|_|\___|\__, |                          --
--         __/ |                                __/ |                          --
--        |___/                                |___/                           --
--                                                                             --
---------------------------------------------------------------------------------
---------------------------------------------------------------------------------

local pingle = {}

-------------------------
-- PINGLE CONFIGURATION --
-------------------------

-- (Figura limit: 1024 B/s, 32 pings/s)
pingle.bytesPerSecondBudget = 768
pingle.pingsPerSecondBudget = 28
pingle.bufferFlushPerSecond = 3
pingle.maxChunkPayload = 240
pingle.maxQueueRecords = 256
pingle.maxTableDepth = 32
pingle.maxTablePairs = 48
pingle.maxStringLen = 8000
pingle.idleSyncedRefreshPerSecond = 0.5
pingle.idleSyncedRefreshBatchSize = 2
-- When host calls synced.set, run onReceive after the local value update. Without this, host
-- echo often applies the same value you just set (oldVal == val) so applyIncomingPayload skips onReceive.
pingle.syncedFireOnHostSet = true

local PROTO_VERSION = 1
local OP_SYNCED = 1
local OP_EVENT = 2
local OP_DICT_STR = 0xFE
local OP_REF_ID = 0xFD
local CHUNK_MAGIC_1 = 0xCE
local CHUNK_MAGIC_2 = 0x50
local SINGLE_MAGIC_1 = 0xCE
local SINGLE_MAGIC_2 = 0x51

local hasPack = (type(string.pack) == "function" and type(string.unpack) == "function")

----------------------
-- LOCAL UTILITIES  --
----------------------

local function isHost() return host:isHost() end -- Is host shortcut.
local function assertHost(depth) if not isHost() then error("pingle: only the host may send network data", depth or 2) end end

local function logDebug(msg) if pingle.debug then print("[pingle] " .. tostring(msg)) end end

local function deepEqual(a, b, visited)
  if a == b then return true end
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return false end

  visited = visited or {}
  local cached = visited[a]
  if cached and cached == b then return true end
  visited[a] = b

  for k, v in pairs(a) do
    if not deepEqual(v, b[k], visited) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

-- Forward declarations for nested calls
local encodeValue
local decodeValue

--------------------
-- VARINT HELPERS --
--------------------

-- Raw byte encoding
local function writeU8(n) return string.char(n % 256) end

-- Raw byte decoding
local function readU8(s, pos)
  if pos > #s then return nil, pos end
  return string.byte(s, pos, pos), pos + 1
end

-- Unsigned varint encoding
local function writeVarintUnsigned(n)
  n = math.floor(math.abs(n))
  local parts = {}

  repeat
    local byte = n % 128
    n = math.floor(n / 128)
    if n ~= 0 then byte = byte + 128 end

    parts[#parts + 1] = string.char(byte)
  until n == 0

  return table.concat(parts)
end

-- Unsigned varint decoding
local function readVarintUnsigned(byteString, position)
  local result = 0
  local placeMultiplier = 1

  while position <= #byteString do
    local byteValue = string.byte(byteString, position, position)
    position = position + 1

    result = result + (byteValue % 128) * placeMultiplier
    if byteValue < 128 then return result, position end

    placeMultiplier = placeMultiplier * 128
    if placeMultiplier > 1e20 then return nil, position end
  end

  return nil, position
end

-- ZigZag integer encoding
local function writeZigzag(signedInteger)
  signedInteger = math.floor(signedInteger + 0)
  local zigzagEncoded

  if signedInteger >= 0 then zigzagEncoded = signedInteger * 2
  else zigzagEncoded = -signedInteger * 2 - 1 end

  return writeVarintUnsigned(zigzagEncoded)
end

-- ZigZag integer decoding
local function readZigzag(byteString, position)
  local zigzagEncoded, nextPosition = readVarintUnsigned(byteString, position)

  if zigzagEncoded == nil then return nil, nextPosition end
  if zigzagEncoded % 2 == 0 then return zigzagEncoded / 2, nextPosition end

  return -(zigzagEncoded + 1) / 2, nextPosition
end

-- String encoding
local function writeStringRaw(str)
  local len = #str
  return writeVarintUnsigned(len) .. str
end

-- String decoding
local function readStringRaw(s, pos)
  local len, p2 = readVarintUnsigned(s, pos)

  if len == nil then return nil, p2 end
  if p2 + len - 1 > #s then return nil, p2 end

  return string.sub(s, p2, p2 + len - 1), p2 + len
end

-------------------------
-- VALUE SERIALIZATION --
-------------------------

encodeValue = function(value, depth)
  depth = depth or 0
  if depth > pingle.maxTableDepth then return writeU8(0) end
  if value == nil then return writeU8(0) end

  local valueType = type(value)

  -- bool
  if valueType == "boolean" then return writeU8(1) .. writeU8(value and 1 or 0) end

  -- number
  if valueType == "number" then
    local integerValue = math.floor(value)

    -- number (integer format)
    if integerValue == value and integerValue >= -2147483648 and integerValue <= 2147483647 then
      return writeU8(2) .. writeZigzag(integerValue)
    end

    -- number (float format)
    if hasPack then return writeU8(3) .. string.pack("<d", value) end
    return writeU8(4) .. writeStringRaw(tostring(value))
  end

  -- string
  if valueType == "string" then
    if #value > pingle.maxStringLen then value = string.sub(value, 1, pingle.maxStringLen) end
    return writeU8(5) .. writeStringRaw(value)
  end

  -- table
  if valueType == "table" then
    local tablePairCount = 0
    for _ in pairs(value) do
      tablePairCount = tablePairCount + 1
      if tablePairCount > pingle.maxTablePairs then break end
    end

    local encodedPairCount = 0
    local parts = { writeU8(6), writeVarintUnsigned(math.min(tablePairCount, pingle.maxTablePairs)) }
    
    for key, tableValue in pairs(value) do
      if encodedPairCount >= pingle.maxTablePairs then break end

      parts[#parts + 1] = encodeValue(key, depth + 1)
      parts[#parts + 1] = encodeValue(tableValue, depth + 1)

      encodedPairCount = encodedPairCount + 1
    end

    return table.concat(parts)
  end

  return writeU8(0)
end

decodeValue = function(byteString, position, depth)
  depth = depth or 0
  if depth > pingle.maxTableDepth then return nil, position end

  local valueTag, nextPosition = readU8(byteString, position)

  -- nil
  if valueTag == nil then return nil, nextPosition end
  if valueTag == 0 then return nil, nextPosition end

  -- bool
  if valueTag == 1 then
    local booleanByte, afterBooleanPosition = readU8(byteString, nextPosition)
    return booleanByte ~= 0, afterBooleanPosition
  end

  -- number (integer format)
  if valueTag == 2 then return readZigzag(byteString, nextPosition) end

  -- number (float format)
  if valueTag == 3 then
    if not hasPack or nextPosition + 8 - 1 > #byteString then return nil, nextPosition end
    local doubleValue = string.unpack("<d", byteString, nextPosition)
    return doubleValue, nextPosition + 8
  end

  -- string 
  if valueTag == 4 then return readStringRaw(byteString, nextPosition) end
  if valueTag == 5 then return readStringRaw(byteString, nextPosition) end

  -- table
  if valueTag == 6 then
    local tablePairCount, tableStartPosition = readVarintUnsigned(byteString, nextPosition)
    if tablePairCount == nil then return nil, tableStartPosition end

    local decodedTable = {}
    local cursorPosition = tableStartPosition

    for _ = 1, tablePairCount do
      local tableKey, afterKeyPosition = decodeValue(byteString, cursorPosition, depth + 1)
      local tableValue, afterValuePosition = decodeValue(byteString, afterKeyPosition, depth + 1)
      if tableKey ~= nil then decodedTable[tableKey] = tableValue end

      cursorPosition = afterValuePosition
    end

    return decodedTable, cursorPosition
  end

  return nil, nextPosition
end

----------------------
-- INTERNAL RUNTIME --
----------------------

local state = {
  synced = {},
  eventHandlers = {},
  eventListeners = {},
  dictSend = {},
  dictSendNext = 1,
  dictRecv = {},
  dictRecvNext = 1,
  outgoing = {},
  outgoingMap = {},
  chunkAssembly = {},
  flushAccum = 0,
  budgetWindowAccum = 0,
  bytesSentThisSecond = 0,
  pingsSentThisSecond = 0,
  immediateQueue = {},
  msgSeq = 0,
  idleRefreshAccum = 0,
  idleRefreshCursor = 1,
}

-------------------------
-- INTERNAL STATE LOGIC --
-------------------------

-- Advance the budget window
local function advanceBudgetWindow(dt)
  state.budgetWindowAccum = state.budgetWindowAccum + (dt or 0.05)
  while state.budgetWindowAccum >= 1.0 do
    state.budgetWindowAccum = state.budgetWindowAccum - 1.0
    state.bytesSentThisSecond = 0
    state.pingsSentThisSecond = 0
  end
end

-- Get or assign a dictionary ID for a value name
local function dictGetOrAssignSend(valueName)
  local dictionaryId = state.dictSend[valueName]
  if dictionaryId then return dictionaryId, false end
  dictionaryId = state.dictSendNext

  state.dictSendNext = state.dictSendNext + 1
  state.dictSend[valueName] = dictionaryId

  return dictionaryId, true
end

local function encodeKey(keyName)
  -- Always include full key mapping in each record so receivers that joined later
  -- can decode keys without relying on prior dictionary state.
  local dictionaryId = state.dictSend[keyName]
  if not dictionaryId then
    dictionaryId, _ = dictGetOrAssignSend(keyName)
  end
  return writeU8(OP_DICT_STR) .. writeVarintUnsigned(dictionaryId) .. writeStringRaw(keyName)
end

local function decodeKey(byteString, position)
  local opCode, nextPosition = readU8(byteString, position)

  if opCode == OP_DICT_STR then
    local dictionaryId, afterIdPosition = readVarintUnsigned(byteString, nextPosition)
    local decodedKeyName, afterKeyPosition = readStringRaw(byteString, afterIdPosition)
    if decodedKeyName == nil then return nil, afterKeyPosition end

    state.dictRecv[dictionaryId] = decodedKeyName
    if dictionaryId >= state.dictRecvNext then state.dictRecvNext = dictionaryId + 1 end

    return decodedKeyName, afterKeyPosition
  end

  if opCode == OP_REF_ID then
    local dictionaryId, afterIdPosition = readVarintUnsigned(byteString, nextPosition)
    local decodedKeyName = state.dictRecv[dictionaryId]

    if not decodedKeyName then logDebug("unknown dict id " .. tostring(dictionaryId)) end

    return decodedKeyName, afterIdPosition
  end

  return nil, nextPosition
end

------------------------
-- PAYLOAD BUILD/APPLY --
------------------------

local function buildRecordPayload()
  local parts = { writeU8(PROTO_VERSION) }
  local merged = {}

  for i = 1, #state.outgoing do merged[#merged + 1] = state.outgoing[i] end
  state.outgoing = {}
  state.outgoingMap = {}

  -- Build the data into the payload
  for _, rec in ipairs(merged) do
    if rec.kind == "sync" then -- Synced value

      parts[#parts + 1] = writeU8(OP_SYNCED)
      parts[#parts + 1] = encodeKey(rec.key)
      parts[#parts + 1] = encodeValue(rec.value)
      
    elseif rec.kind == "event" then -- Synced Event

      parts[#parts + 1] = writeU8(OP_EVENT)
      parts[#parts + 1] = encodeKey(rec.name)
      parts[#parts + 1] = encodeValue(rec.data or {})

    end
  end

  return table.concat(parts)
end

------------------------
-- TRANSPORT / BUDGET --
------------------------

local function applyIncomingPayload(payload)
  local pos = 1

  -- Check the protocol version
  local ver, pos2 = readU8(payload, pos)
  if ver == nil or ver ~= PROTO_VERSION then
    logDebug("bad protocol version")
    return
  end

  -- Apply the payload
  pos = pos2
  while pos <= #payload do
    local op, pos3 = readU8(payload, pos)
    if op == nil then break end
    pos = pos3

    -- Synced value
    if op == OP_SYNCED then
      local keyStr, pos4 = decodeKey(payload, pos)
      if keyStr == nil then break end

      -- Decode the value and move on
      pos = pos4
      local val, pos5 = decodeValue(payload, pos)
      pos = pos5

      -- Get the entry and update it
      local entry = state.synced[keyStr]
      if entry then

        local oldVal = entry.value
        entry.value = val

        -- Call onReceive when the applied value differs (network / other clients). Host echo of a
        -- value you just set in synced.set usually matches oldVal; host can use syncedFireOnHostSet.
        local changed = not deepEqual(oldVal, val)
        if entry.onReceive and changed then
          local ok, err = pcall(entry.onReceive, val, keyStr)
          if not ok then logDebug("synced onReceive error: " .. tostring(err)) end -- "is not ok" is really funny lmao...
        end

      else
        -- Key unknown here: no synced.define() ran on this client for this key (or load order lost the entry).
        -- Value is stored but onReceive cannot run without a callback; set Pingle.debug to see this hint.
        logDebug('synced recv: no local define() for key "' .. tostring(keyStr) .. "\"; install callback by requiring the same init as the host")
        state.synced[keyStr] = { value = val, onReceive = nil }
      end

    -- Synced Event
    elseif op == OP_EVENT then
      local name, p4 = decodeKey(payload, pos)
      if name == nil then break end

      -- Decode the data and move on
      pos = p4
      local data, p5 = decodeValue(payload, pos)
      pos = p5

      -- Ensure the data is a table
      if type(data) ~= "table" then data = {} end

      -- Get the handler and call it (if it exists)
      local handler = state.eventHandlers[name]
      if handler then
        local ok, err = pcall(handler, data)
        if not ok then logDebug("event handler error: " .. tostring(err)) end
      end

      -- Get the listeners and call them (if they exist)
      local list = state.eventListeners[name]
      if list then
        for _, fn in ipairs(list) do
          local ok, err = pcall(fn, data)
          if not ok then logDebug("event listener error: " .. tostring(err)) end -- "is not ok" is back again... still funny lmao...
        end
      end

    else
      -- Log the error if the operation is unknown
      logDebug("unknown op " .. tostring(op))
      break
    end

  end
end

-- Try to consume the budget for the given number of bytes and pings
local function tryConsumeBudget(bytes, pingCount)
  if state.bytesSentThisSecond + bytes > pingle.bytesPerSecondBudget then return false end
  if state.pingsSentThisSecond + pingCount > pingle.pingsPerSecondBudget then return false end

  state.bytesSentThisSecond = state.bytesSentThisSecond + bytes
  state.pingsSentThisSecond = state.pingsSentThisSecond + pingCount

  return true
end

-- Chunk and send the data according to the max chunk payload
local function chunkAndSend(data)
  local frames = {}

  
  if #data <= pingle.maxChunkPayload then
    -- If the data is less than the max chunk payload, send it as a single frame
    frames[1] = string.char(SINGLE_MAGIC_1, SINGLE_MAGIC_2) .. data
  else
    -- If the data is greater than the max chunk payload, chunk it
    state.msgSeq = (state.msgSeq + 1) % 65536

    local totalChunks = math.ceil(#data / pingle.maxChunkPayload)
    for chunkIndex = 1, totalChunks do
      local start = (chunkIndex - 1) * pingle.maxChunkPayload + 1
      local endPosition = math.min(start + pingle.maxChunkPayload - 1, #data)

      local chunk = string.sub(data, start, endPosition)

      -- Build the header
      local header = string.char(
        CHUNK_MAGIC_1,
        CHUNK_MAGIC_2,
        math.floor(state.msgSeq / 256) % 256,
        state.msgSeq % 256,
        chunkIndex - 1,
        totalChunks - 1
      )

      frames[#frames + 1] = header .. chunk
    end
  end

  local totalBytes = 0
  for i = 1, #frames do
    totalBytes = totalBytes + #frames[i]
  end

  -- Try to consume the budget
  if not tryConsumeBudget(totalBytes, #frames) then
    logDebug("rate limit: deferring buffered send")
    return false
  end

  -- Check if the pings module is loaded
  if not pings or not pings.pingle_buffer then
    return false
  end

  -- Send the frames to the pings module
  for i = 1, #frames do
    pings.pingle_buffer(frames[i])
  end
  return true
end

--------------------------
-- CHUNK RECEIVE / PINGS --
--------------------------

local function handleChunkedPayload(payloadString)
  if #payloadString < 2 then return end

  local magicByte1, magicByte2 = string.byte(payloadString, 1, 2)

  -- If the magic bytes are correct, send the payload as a single frame
  if magicByte1 == SINGLE_MAGIC_1 and magicByte2 == SINGLE_MAGIC_2 then
    applyIncomingPayload(string.sub(payloadString, 3))
    return
  end

  -- If the magic bytes are not correct, or the payload is less than 8 bytes, send the payload as a single frame
  if magicByte1 ~= CHUNK_MAGIC_1 or magicByte2 ~= CHUNK_MAGIC_2 or #payloadString < 8 then
    applyIncomingPayload(payloadString) return 
  end

  -- By this point, the payload is a chunked payload and we need to reassemble it.
  -- Get the sequence ID, chunk index, total chunks (-1), chunk body, assembly key, and chunk assembly state.
  -- then check if the chunk index is valid and if the chunk body is valid.

  local sequenceId = string.byte(payloadString, 3) * 256 + string.byte(payloadString, 4)
  local chunkIndex = string.byte(payloadString, 5)
  local totalChunksMinusOne = string.byte(payloadString, 6)
  local chunkBody = string.sub(payloadString, 7)
  local assemblyKey = tostring(sequenceId)
  local chunkAssemblyState = state.chunkAssembly[assemblyKey]

  -- If the chunk assembly state is not valid, create a new one
  if not chunkAssemblyState or chunkAssemblyState.total ~= totalChunksMinusOne then
    chunkAssemblyState = { total = totalChunksMinusOne, parts = {}, got = 0 }
    state.chunkAssembly[assemblyKey] = chunkAssemblyState
  end

  -- If the chunk index is not valid, add the chunk body to the chunk assembly state
  if not chunkAssemblyState.parts[chunkIndex] then
    chunkAssemblyState.parts[chunkIndex] = chunkBody
    chunkAssemblyState.got = chunkAssemblyState.got + 1
  end

  -- If the chunk assembly state is complete, assemble the parts and apply the payload
  if chunkAssemblyState.got == totalChunksMinusOne + 1 then
    local assembledParts = {}
    for i = 0, totalChunksMinusOne do
      assembledParts[#assembledParts + 1] = chunkAssemblyState.parts[i] or ""
    end

    -- Clear the chunk assembly state and apply the payload
    state.chunkAssembly[assemblyKey] = nil
    applyIncomingPayload(table.concat(assembledParts))
  end
end

-- Handle the buffered payload
function pings.pingle_buffer(payload)
  if type(payload) ~= "string" then return end
  handleChunkedPayload(payload)
end

-- Handle the immediate payload
function pings.pingle_immediate(packed)
  if type(packed) ~= "string" then return end

  local name, pos = readStringRaw(packed, 1)
  if name == nil then return end

  local data, _ = decodeValue(packed, pos)
  if type(data) ~= "table" then data = {} end

  local handler = state.eventHandlers[name]
  if handler then pcall(handler, data) end

  local list = state.eventListeners[name]
  if list then for _, fn in ipairs(list) do pcall(fn, data) end end
end

-------------------
-- SEND QUEUING  --
-------------------

-- Pack the immediate payload
local function packImmediate(name, data)
  return writeStringRaw(name) .. encodeValue(data or {})
end

-- Flush the buffered payload
local function flushBuffered()
  if not isHost() then return end
  if #state.outgoing == 0 then return end

  -- Build the payload and send it
  local payload = buildRecordPayload()
  if #payload <= 1 then return end

  chunkAndSend(payload)
end

local function queueRecord(rec)
  -- Get the coalesce key
  local coalesceKey = nil
  if rec.kind == "sync" then coalesceKey = "s:" .. rec.key
  elseif rec.kind == "event" then coalesceKey = "e:" .. rec.name end

  -- If the coalesce key is valid and the outgoing map contains the key, update the record
  if coalesceKey and state.outgoingMap[coalesceKey] then
    local idx = state.outgoingMap[coalesceKey]
    state.outgoing[idx] = rec
    return
  end

  -- If the outgoing queue is full, drop the oldest record
  if #state.outgoing >= pingle.maxQueueRecords then
    logDebug("queue full: dropping oldest")

    table.remove(state.outgoing, 1)
    state.outgoingMap = {}

    for index, record in ipairs(state.outgoing) do
      if record.kind == "sync" then state.outgoingMap["s:" .. record.key] = index
      elseif record.kind == "event" then state.outgoingMap["e:" .. record.name] = index end
    end
  end

  -- Add the record to the outgoing queue
  state.outgoing[#state.outgoing + 1] = rec
  if coalesceKey then state.outgoingMap[coalesceKey] = #state.outgoing end
end

-- Queue the synced values for idle refresh
local function queueIdleSyncedRefresh(maxCount)
  if maxCount <= 0 then return end

  local syncedKeys = {}
  for keyName in pairs(state.synced) do syncedKeys[#syncedKeys + 1] = keyName end

  local totalKeys = #syncedKeys
  if totalKeys == 0 then return end
  if state.idleRefreshCursor > totalKeys then state.idleRefreshCursor = 1 end

  -- Queue the synced values
  local queuedCount = 0
  while queuedCount < maxCount do
    local keyName = syncedKeys[state.idleRefreshCursor]
    if not keyName then break end

    local syncedEntry = state.synced[keyName]
    if syncedEntry then
      queueRecord({ kind = "sync", key = keyName, value = syncedEntry.value })
      queuedCount = queuedCount + 1
    end

    state.idleRefreshCursor = state.idleRefreshCursor + 1
    if state.idleRefreshCursor > totalKeys then state.idleRefreshCursor = 1 end
    if totalKeys <= queuedCount then break end
  end
end

-------------------
-- PUBLIC TICKING --
-------------------

function pingle._tick(dt)
  dt = dt or 0.05

  advanceBudgetWindow(dt)
  state.flushAccum = state.flushAccum + dt
  local interval = 1 / pingle.bufferFlushPerSecond

  -- Idle synced refresh\
  if isHost() and #state.outgoing == 0 and #state.immediateQueue == 0 then
    state.idleRefreshAccum = state.idleRefreshAccum + dt
    if pingle.idleSyncedRefreshPerSecond > 0 then
      local refreshInterval = 1 / pingle.idleSyncedRefreshPerSecond

      if state.idleRefreshAccum >= refreshInterval then
        state.idleRefreshAccum = state.idleRefreshAccum - refreshInterval
        queueIdleSyncedRefresh(pingle.idleSyncedRefreshBatchSize)
      end
    end
  else
    state.idleRefreshAccum = 0
  end

  -- Flush the buffered payload
  while state.flushAccum >= interval do
    state.flushAccum = state.flushAccum - interval
    flushBuffered()
  end

  -- Flush the immediate payload
  if #state.immediateQueue > 0 and isHost() then
    local packed = table.remove(state.immediateQueue, 1)

    if packed and tryConsumeBudget(#packed, 1) then
      if pings and pings.pingle_immediate then pings.pingle_immediate(packed) end
    else
      if packed then table.insert(state.immediateQueue, 1, packed) end
    end
  end
end

--------------------
-- SYNCED VALUE API --
--------------------

pingle.synced = {}

-- Define a synced value
function pingle.synced.define(key, initialValue, onReceive)
  assert(type(key) == "string", "pingle.synced.define: key must be a string")
  local existing = state.synced[key]
  if existing then
    -- Preserve a value that may have already arrived from network before define() runs.
    existing.onReceive = onReceive
    return
  end

  state.synced[key] = { value = initialValue, onReceive = onReceive }
end

-- Get a synced value
function pingle.synced.get(key)
  local syncedEntry = state.synced[key]
  return syncedEntry and syncedEntry.value or nil
end

-- Set a synced value
function pingle.synced.set(key, value)
  assert(type(key) == "string", "pingle.synced.set: key must be a string")
  assertHost(2)

  local syncedEntry = state.synced[key]
  if not syncedEntry then
    state.synced[key] = { value = value, onReceive = nil }
    syncedEntry = state.synced[key]
  else
    if deepEqual(syncedEntry.value, value) then return end
    syncedEntry.value = value
  end

  queueRecord({ kind = "sync", key = key, value = value })

  if pingle.syncedFireOnHostSet and syncedEntry.onReceive then
    local ok, err = pcall(syncedEntry.onReceive, value, key)
    if not ok then logDebug("synced onReceive error: " .. tostring(err)) end
  end
end

----------------
-- EVENT API  --
----------------

pingle.event = {}

-- Register an event handler
function pingle.event.register(name, handler)
  assert(type(name) == "string", "pingle.event.register: name must be a string")
  assert(type(handler) == "function", "pingle.event.register: handler must be a function")
  
  state.eventHandlers[name] = handler
end

-- Listen for an event
function pingle.event.listen(name, listener)
  assert(type(name) == "string", "pingle.event.listen: name must be a string")
  assert(type(listener) == "function", "pingle.event.listen: listener must be a function")
  
  if not state.eventListeners[name] then state.eventListeners[name] = {} end
  table.insert(state.eventListeners[name], listener)
end

-- Emit an event
function pingle.event.emit(name, dataTable)
  assert(type(name) == "string", "pingle.event.emit: name must be a string")
  assert(type(dataTable) == "table" or dataTable == nil, "pingle.event.emit: data must be a table")
  assertHost(2)

  queueRecord({ kind = "event", name = name, data = dataTable or {} })
end

--------------------
-- IMMEDIATE API  --
--------------------

pingle.immediate = {}

---Returns whether this instance is the avatar host (only the host can send pings).
pingle.isHost = isHost

-- Send an immediate payload
function pingle.immediate.send(name, data)
  assert(type(name) == "string", "pingle.immediate.send: name must be a string")
  assert(type(data) == "table" or data == nil, "pingle.immediate.send: data must be a table")
  assertHost(2)

  local packed = packImmediate(name, data or {})
  if #packed > pingle.maxStringLen then error("pingle.immediate.send: payload too large", 2) end
  table.insert(state.immediateQueue, packed)
end

-----------
-- SETUP --
-----------
events.TICK:register(function() pingle._tick(0.05) end)

return pingle