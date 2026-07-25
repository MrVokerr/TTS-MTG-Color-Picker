-- UGD → Purple (companion to Seat Color Picker)
-- Only SteamID STEAM_ID may use this button.
-- Left-click:
--   1) Swap Custom Table image to MAT_IMAGE_URL (remembers Pie's original URL)
--   2) Engine-seat swap to Purple (via Seat Color Picker)
-- Right-click:
--   1) Restore previous table image
--   2) Revert engine seat to remembered original color
--
-- Works on the official Custom Table (Tables.setCustomURL). Paste a hosted
-- 9500x5600 mat PNG URL into MAT_IMAGE_URL. Requires Seat Color Picker on table.

local STEAM_ID = '76561198025584387'
local TARGET = 'Purple'
local PICKER_NAME = 'Seat Color Picker'

-- Hosted on this repo (replace assets/mat.png + push to update).
local MAT_IMAGE_URL =
  'https://raw.githubusercontent.com/MrVokerr/TTS-MTG-Color-Picker/master/assets/mat.png'

local NON_SEATS = { Grey = true, Black = true }
local savedTableUrl = nil

local function isSeatColor(color)
  if not color or NON_SEATS[color] then return false end
  return true
end

local function findPicker()
  for _, obj in ipairs(getAllObjects()) do
    if obj ~= self and obj.getName() == PICKER_NAME then
      return obj
    end
  end
  return nil
end

local function updateSave()
  self.script_state = JSON.encode({ savedTableUrl = savedTableUrl })
end

local function loadSave(data)
  savedTableUrl = nil
  if not data or data == '' then return end
  local ok, decoded = pcall(JSON.decode, data)
  if ok and type(decoded) == 'table' and type(decoded.savedTableUrl) == 'string' then
    savedTableUrl = decoded.savedTableUrl
  end
end

local function applyMatImage(player)
  if type(MAT_IMAGE_URL) ~= 'string' or MAT_IMAGE_URL == '' then
    player.broadcast('Set MAT_IMAGE_URL in UGD-PURPLE.lua to your hosted mat PNG.', {1, 0.5, 0.3})
    return false
  end
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
    click_function = 'clickUgdPurple',
    function_owner = self,
    label = 'Purple',
    tooltip = 'UGD PURPLE NOW.\nRight-click to restore original seat.',
    position = { 0, 0.15, 0 },
    rotation = { 0, 180, 0 },
    width = 600,
    height = 600,
    font_size = 140,
    color = { 0.35, 0.12, 0.45, 0.95 },
    font_color = { 1, 1, 1 },
  })
end

function clickUgdPurple(obj, color, alt)
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
  if not picker then
    player.broadcast('Seat Color Picker must be on the table.', {1, 0.5, 0.3})
    return
  end

  if alt then
    restoreMatImage(player)
    picker.call('forceEngineRevertSteam', { steam_id = STEAM_ID })
  else
    applyMatImage(player)
    picker.call('forceEngineSwapSteam', { steam_id = STEAM_ID, target = TARGET })
  end
end

function onSave()
  return JSON.encode({ savedTableUrl = savedTableUrl })
end

function onLoad(data)
  loadSave(data)
  self.setName('UGD → Purple')
  self.setDescription(
    'Authorized SteamID only.\n'..
    'Left-click: load mat image onto official Custom Table + Purple seat.\n'..
    'Right-click: restore previous table image + original seat.\n'..
    'Set MAT_IMAGE_URL. Requires Seat Color Picker.'
  )
  showButton()
end
