-- VOKER → Purple (standalone)
-- SteamID-gated. No Seat Color Picker required.
-- Left-click: official Custom Table → purple-seat texture + engine seat Purple.
-- Right-click: restore previous table image + original seat color.
-- Texture is Pie's table art with ONLY the transparent seat recolored purple
-- (does not slap yellow/red/white COLORMTG onto the table).

local STEAM_ID = '76561197991782511'
local TARGET = 'Purple'
local LABEL = 'VOKER'

local MAT_IMAGE_URL =
  'https://cdn.jsdelivr.net/gh/MrVokerr/TTS-MTG-Color-Picker@master/assets/mat-purple-seat.png'

local ENGINE_COLORS = {
  'White','Brown','Red','Orange','Yellow','Green','Teal','Blue','Purple','Pink'
}
local NON_SEATS = { Grey = true, Black = true }
local REBIND_SKIP_TYPES = { Card = true, Deck = true }

local savedTableUrl = nil
local swaps = {} -- [originalSeat] = currentEngineColor

local function isSeatColor(color)
  if not color or NON_SEATS[color] then return false end
  return true
end

local function isEngineColor(color)
  for _, c in ipairs(ENGINE_COLORS) do
    if c == color then return true end
  end
  return false
end

local function encodeState()
  return JSON.encode({ savedTableUrl = savedTableUrl, swaps = swaps })
end

local function updateSave()
  self.script_state = encodeState()
end

local function loadSave(data)
  savedTableUrl = nil
  swaps = {}
  if not data or data == '' then return end
  local ok, decoded = pcall(JSON.decode, data)
  if not ok or type(decoded) ~= 'table' then return end
  if type(decoded.savedTableUrl) == 'string' then
    savedTableUrl = decoded.savedTableUrl
  end
  if type(decoded.swaps) == 'table' then
    for origin, current in pairs(decoded.swaps) do
      if type(origin) == 'string' and type(current) == 'string' and origin ~= current then
        swaps[origin] = current
      end
    end
  end
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

local function performSwap(fromColor, toColor)
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

local function applyMatImage(player)
  if not Tables or not Tables.setCustomURL or not Tables.getCustomURL then
    player.broadcast('Tables.setCustomURL is not available in this TTS build.', {1, 0.5, 0.3})
    return false
  end
  local current = Tables.getCustomURL()
  if current == nil then
    player.broadcast('Table is not a Custom Table — cannot swap the mat image.', {1, 0.5, 0.3})
    return false
  end
  if savedTableUrl == nil then
    savedTableUrl = current
    updateSave()
  end
  pcall(function()
    Tables.setCustomURL(MAT_IMAGE_URL)
  end)
  return true
end

local function restoreMatImage(player)
  if not Tables or not Tables.setCustomURL then return end
  if savedTableUrl == nil or savedTableUrl == '' then
    player.broadcast('No previous table image saved yet.', {0.8, 0.8, 0.8})
    return
  end
  pcall(function()
    Tables.setCustomURL(savedTableUrl)
  end)
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
    color = { 0.35, 0.12, 0.45, 0.95 },
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

  if alt then
    local origin = originOf(color)
    if not origin then
      player.broadcast('This seat is already its original color.', {0.8, 0.8, 0.8})
    else
      local ok, err = canSwapTo(color, origin)
      if not ok then
        player.broadcast(err, {1, 0.5, 0.3})
      else
        restoreMatImage(player)
        performSwap(color, origin)
        broadcastToAll('Seat reverted to '..origin..'.', {0.8, 0.8, 0.8})
      end
    end
    return
  end

  local ok, err = canSwapTo(color, TARGET)
  if not ok then
    player.broadcast(err, {1, 0.5, 0.3})
    return
  end
  applyMatImage(player)
  performSwap(color, TARGET)
  broadcastToAll(color..' → '..TARGET..' (chat/list + purple seat mat).', {0.69, 0.24, 0.81})
end

function onSave()
  return encodeState()
end

function onLoad(data)
  loadSave(data)
  self.setName(LABEL..' → Purple')
  self.setDescription(
    'Standalone — authorized SteamID only.\n'..
    'Left-click: purple one seat on the official table art + engine Purple.\n'..
    'Right-click: restore previous table image + original seat.\n'..
    'Does not load yellow/red/white COLORMTG onto the table.'
  )
  showButton()
end
