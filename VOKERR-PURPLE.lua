-- VOKERR → Purple (standalone companion)
-- SteamID-gated. Uses the SAME engine-seat swap rules as seat-color-picker.lua
-- (hand-zone Technique J). Does NOT replace the Custom Table image (keeps the
-- table's normal 4/6/8 seats / art).
--
-- If Seat Color Picker is on the table: calls its forceEngineSwapSteam so mat
-- vectors + widgets use Color.Purple (0.627, 0.125, 0.941) exactly.
-- If not: still does the engine seat swap locally (chat/list/pointer).

local STEAM_ID = '76561197991782511'
local TARGET = 'Purple'
local LABEL = 'VOKERR'
local PICKER_NAME = 'Seat Color Picker'

-- Exact TTS player Purple (api.tabletopsimulator.com/player/colors)
local TTS_PURPLE = { r = 0.627, g = 0.125, b = 0.941 }

local ENGINE_COLORS = {
  'White','Brown','Red','Orange','Yellow','Green','Teal','Blue','Purple','Pink'
}
local NON_SEATS = { Grey = true, Black = true }
local REBIND_SKIP_TYPES = { Card = true, Deck = true }

local swaps = {} -- [originalSeat] = currentEngineColor

local function availableSeatList()
  local list = nil
  if Player.getAvailableColors then
    list = Player.getAvailableColors()
  end
  if type(list) ~= 'table' or #list == 0 then
    list = {
      'White','Brown','Red','Orange','Yellow','Green','Teal','Blue','Purple','Pink'
    }
  end
  local out = {}
  for _, c in ipairs(list) do
    if not NON_SEATS[c] then
      table.insert(out, c)
    end
  end
  return out
end

local function isSeatColor(color)
  if not color or NON_SEATS[color] then return false end
  for _, c in ipairs(availableSeatList()) do
    if c == color then return true end
  end
  -- After Technique J, current color may be Purple even if not in the
  -- original available list — still treat stock engine seats as valid.
  for _, c in ipairs(ENGINE_COLORS) do
    if c == color then return true end
  end
  return false
end

local function isEngineColor(color)
  for _, c in ipairs(ENGINE_COLORS) do
    if c == color then return true end
  end
  return false
end

local function encodeState()
  return JSON.encode({ swaps = swaps })
end

local function updateSave()
  self.script_state = encodeState()
end

local function loadSave(data)
  swaps = {}
  if not data or data == '' then return end
  local ok, decoded = pcall(JSON.decode, data)
  if not ok or type(decoded) ~= 'table' then return end
  if type(decoded.swaps) == 'table' then
    for origin, current in pairs(decoded.swaps) do
      if type(origin) == 'string' and type(current) == 'string' and origin ~= current then
        swaps[origin] = current
      end
    end
  end
end

local function findPicker()
  for _, obj in ipairs(getAllObjects()) do
    if obj ~= self and obj.getName() == PICKER_NAME then
      return obj
    end
  end
  return nil
end

local function seatHandZones(color)
  local out = {}
  local ok, zones = pcall(function() return Hands.getHands() end)
  if ok and type(zones) == 'table' then
    for _, z in ipairs(zones) do
      local okV, v = pcall(function() return z.getValue() end)
      if okV and v == color then
        table.insert(out, z)
      end
    end
  end
  return out
end

local function originOf(color)
  for origin, current in pairs(swaps) do
    if current == color then return origin end
  end
  return nil
end

local function aliasGlobalTables(fromColor, toColor)
  pcall(function()
    local dirs = Global.getTable('deckDirs')
    if type(dirs) == 'table' and dirs[fromColor] ~= nil and dirs[toColor] == nil then
      dirs[toColor] = dirs[fromColor]
      Global.setTable('deckDirs', dirs)
    end
  end)
  pcall(function()
    local data = Global.getTable('data')
    if type(data) == 'table' and data[fromColor] ~= nil and data[toColor] == nil then
      data[toColor] = data[fromColor]
      Global.setTable('data', data)
    end
  end)
end

local function swapSeatPrefix(text, fromColor, toColor)
  if not text or text == '' then return nil end
  if text == fromColor then return toColor end
  local rest = text:match('^'..fromColor..'([%s\n].*)$')
  if rest then return toColor..rest end
  return nil
end

local function rebindSeatWidgets(fromColor, toColor)
  for _, obj in ipairs(getAllObjects()) do
    if obj ~= self and not REBIND_SKIP_TYPES[obj.type] then
      local newDesc = swapSeatPrefix(obj.getDescription(), fromColor, toColor)
      local newName = swapSeatPrefix(obj.getName(), fromColor, toColor)
      if newDesc or newName then
        pcall(function()
          if newDesc then obj.setDescription(newDesc) end
          if newName then obj.setName(newName) end
          obj.reload()
        end)
      end
    end
  end
end

local function canSwapTo(fromColor, toColor)
  if fromColor == toColor then
    return false, 'You already are '..toColor..'.'
  end
  if not isEngineColor(toColor) then
    return false, toColor..' is not a TTS player color.'
  end
  -- Same gate as seat-color-picker: target must not already be a seated color.
  if #seatHandZones(toColor) > 0 then
    return false, toColor..' is already a seat on this table.'
  end
  local seated = false
  pcall(function() seated = Player[toColor] and Player[toColor].seated end)
  if seated then
    return false, toColor..' is occupied.'
  end
  if #seatHandZones(fromColor) == 0 then
    return false, 'No hand zone found for '..fromColor..'.'
  end
  return true
end

-- Local fallback (identical Technique J as the picker; no table-image rewrite).
local function performSwapLocal(fromColor, toColor)
  for _, zone in ipairs(seatHandZones(fromColor)) do
    pcall(function() zone.setValue(toColor) end)
  end
  aliasGlobalTables(fromColor, toColor)
  local origin = originOf(fromColor) or fromColor
  if toColor == origin then
    swaps[origin] = nil
  else
    swaps[origin] = toColor
  end
  updateSave()
  Wait.frames(function()
    pcall(function()
      if Player[fromColor] and Player[fromColor].seated then
        Player[fromColor].changeColor(toColor)
      end
    end)
    rebindSeatWidgets(fromColor, toColor)
  end, 2)
end

local function showButton()
  self.clearButtons()
  self.createButton({
    click_function = 'clickPurple',
    function_owner = self,
    label = 'Purple',
    tooltip = LABEL..' PURPLE NOW.\nRight-click to restore original seat.',
    position = { 0, 0.15, 0 },
    rotation = { 0, 180, 0 },
    width = 600,
    height = 600,
    font_size = 140,
    color = { TTS_PURPLE.r, TTS_PURPLE.g, TTS_PURPLE.b, 0.95 },
    font_color = { 1, 1, 1 },
  })
end

function clickPurple(obj, color, alt)
  local player = Player[color]
  if not player then return end

  if tostring(player.steam_id or '') ~= STEAM_ID then
    player.broadcast('Not authorized.', {1, 0.5, 0.3})
    return
  end

  if not isSeatColor(color) then
    player.broadcast('Sit at a player seat first.', {1, 0.5, 0.3})
    return
  end

  local picker = findPicker()

  if alt then
    if picker then
      picker.call('forceEngineRevertSteam', { steam_id = STEAM_ID })
      return
    end
    local origin = originOf(color)
    if not origin then
      player.broadcast('This seat is already its original color.', {0.8, 0.8, 0.8})
      return
    end
    local ok, err = canSwapTo(color, origin)
    if not ok then
      player.broadcast(err, {1, 0.5, 0.3})
      return
    end
    performSwapLocal(color, origin)
    broadcastToAll('Seat reverted to '..origin..'.', {0.8, 0.8, 0.8})
    return
  end

  -- Prefer picker: same mat vectors + Exact TTS Purple as the Purple button.
  if picker then
    picker.call('forceEngineSwapSteam', {
      steam_id = STEAM_ID,
      target = TARGET,
      skip_vectors = false,
    })
    return
  end

  local ok, err = canSwapTo(color, TARGET)
  if not ok then
    player.broadcast(err, {1, 0.5, 0.3})
    return
  end
  performSwapLocal(color, TARGET)
  broadcastToAll(
    color..' → '..TARGET..' (engine seat). Add Seat Color Picker for mat line-work.',
    { TTS_PURPLE.r, TTS_PURPLE.g, TTS_PURPLE.b }
  )
end

function onSave()
  return encodeState()
end

function onLoad(data)
  loadSave(data)
  self.setName(LABEL..' → Purple')
  self.setDescription(
    'Authorized SteamID only. Same engine-seat swap as Seat Color Picker.\n'..
    'Left-click: swap your seat to TTS Purple (does not rewrite table art).\n'..
    'Right-click: restore original seat.\n'..
    'With Seat Color Picker present: also paints mat/widgets in TTS Purple.'
  )
  showButton()
end
