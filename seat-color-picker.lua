-- Seat Color Picker (drop-in)
-- Paste onto any token/tile and import onto the 4p / 6p / 8p Oops tables.
-- Click → SV grid + hue + hex; Apply retints that seat's board widgets and
-- redraws the seat's playmat line-work as vector loops in the chosen color.
-- Until Apply, the token does not tint widgets or draw overlays.
-- Engine seat swap (stock TTS palette only) recolors chat / player list by
-- re-valuing the seat's hand zone and rebinding seat-coupled widgets at
-- runtime. No other Lua *files* are edited; everything is done live from
-- this one object (Global tables aliased via setTable, widgets renamed +
-- reload()ed).
--
-- Event-driven re-apply (turn / connect / drop) restores chrome after
-- widgets reset themselves — no repeating sticky interval.

local SV_COLS, SV_ROWS = 16, 12
local HUE_STEPS = 36
local PREVIEW_DEBOUNCE = 0.12
local NON_SEATS = { Grey = true }

-- Stock TTS player palette — the only values a hand zone (and therefore
-- chat / player-list color) can take. Grey/Black excluded (spectator/GM).
local ENGINE_COLORS = {
  'White','Brown','Red','Orange','Yellow','Green','Teal','Blue','Purple','Pink'
}

------------------------------------------------------------------------
-- Playmat line-work overlay (vector loops)
------------------------------------------------------------------------
-- Shapes traced from a reference crop of one seat's region on the table
-- texture: {x0, y0, x1, y1, cornerRadius} in image pixels.
-- 4p/8p crop is 1024x505; 6p crop is 1024x783 (see ref_6p_seat_mat.png).
-- Zone auto-align still uses deck/GY anchors; only the traced art differs.
local MAT_4P = {
  imgW = 1024, imgH = 505,
  shapes = {
    { 9,   11,  1014, 500, 12 }, -- outer border
    { 13,  342, 868,  497, 10 }, -- hand row
    { 878, 172, 1003, 490, 10 }, -- right column
    { 913, 201, 968,  273, 8 },  -- icon box 1 (exile / top)
    { 913, 297, 968,  369, 8 },  -- icon box 2 (deck / library)  ← zone anchor
    { 913, 393, 968,  465, 8 },  -- icon box 3 (graveyard)       ← zone anchor
    { 884, 55,  938,  129, 8 },  -- top-right box A
    { 943, 55,  997,  129, 8 },  -- top-right box B
  },
  deckIdx = 5, gyIdx = 6,
}
local MAT_6P = {
  imgW = 1024, imgH = 783,
  shapes = {
    { 8,   8,   1015, 775, 14 }, -- outer border
    { 8,   554, 875,  775, 10 }, -- hand row
    { 876, 8,   1015, 775, 10 }, -- right column
    { 905, 152, 988,  263, 8 },  -- icon box 1 (commander)
    { 905, 285, 988,  396, 8 },  -- icon box 2 (partner / 2nd cmd)
    { 890, 425, 1003, 506, 8 },  -- icon box 3 (exile) — wider frame
    { 905, 521, 988,  632, 8 },  -- icon box 4 (deck / library)  ← zone anchor
    { 905, 647, 988,  758, 8 },  -- icon box 5 (graveyard)       ← zone anchor
  },
  deckIdx = 7, gyIdx = 8,
}

-- Fine pads on top of zone auto-align (calibrate panel). Hand-math fields
-- below are fallback only when library/graveyard zones are missing.
local matCal = {
  scale = 1.0,           -- multiply zone-derived scale
  offsetRight = 0.0,     -- nudge along zone right
  offsetFwd = 0.0,       -- nudge along deck←gy column
  flipX = false,         -- mirror left/right
  flipZ = false,         -- mirror along column (swap deck/gy direction)
  borderY = 0.98,
  lineThickness = 0.4,
  arcSteps = 3,
  -- Fallback (Art Playmat enabler math) if zones unavailable:
  centerFwd = 19.07,
  centerRight = 0.7,
  worldW = 44.0,
  worldH = 20.7,
  rot180 = false,
}
-- local CAL_STEP = 0.1
-- local CAL_STEP_FINE = 0.01 -- borderY / lineThickness (calibration UI disabled)

-- Objects whose mesh tint encodes seat identity for other scripts — do not paint.
-- Highlight mats cover the whole seat battlefield; leave turn glow alone.
local SKIP_NAME = {
  ['turn skipper'] = true,
}

local seatColors = {} -- [seat] = {r,g,b}  (only seats with a custom cosmetic)
local swaps = {}      -- [originalSeat] = currentEngineColor (engine swaps)
local sessions = {}   -- [playerColor] = { seat, h, s, v, baseline }
local uiOwner = nil   -- whose panel is currently visible
local previewWait = nil
local lastBorderSig = nil

------------------------------------------------------------------------
-- Seats (4 / 6 / 8)
------------------------------------------------------------------------

local function availableSeatList()
  local list = nil
  if Player.getAvailableColors then
    list = Player.getAvailableColors()
  end
  if type(list) ~= 'table' or #list == 0 then
    list = Color.list or {
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
  for _, c in ipairs(Color.list or {}) do
    if c == color and not NON_SEATS[c] then return true end
  end
  return false
end

-- Pick 6p vs 4p/8p traced art from seat count (zones still auto-scale).
local function activeMatLayout()
  if #availableSeatList() == 6 then return MAT_6P end
  return MAT_4P
end

local function matShapes()
  return activeMatLayout().shapes
end

local function matImgSize()
  local m = activeMatLayout()
  return m.imgW, m.imgH
end

local function matAnchors()
  local m = activeMatLayout()
  return m.shapes[m.deckIdx], m.shapes[m.gyIdx]
end

------------------------------------------------------------------------
-- Color math
------------------------------------------------------------------------

local function clamp01(x)
  if x < 0 then return 0 end
  if x > 1 then return 1 end
  return x
end

function hsvToRgb(h, s, v)
  h = (h % 360 + 360) % 360
  s = clamp01(s)
  v = clamp01(v)
  local c = v * s
  local x = c * (1 - math.abs((h / 60) % 2 - 1))
  local m = v - c
  local r, g, b = 0, 0, 0
  if h < 60 then r, g, b = c, x, 0
  elseif h < 120 then r, g, b = x, c, 0
  elseif h < 180 then r, g, b = 0, c, x
  elseif h < 240 then r, g, b = 0, x, c
  elseif h < 300 then r, g, b = x, 0, c
  else r, g, b = c, 0, x end
  return r + m, g + m, b + m
end

function rgbToHsv(r, g, b)
  r, g, b = clamp01(r), clamp01(g), clamp01(b)
  local maxc = math.max(r, g, b)
  local minc = math.min(r, g, b)
  local d = maxc - minc
  local h = 0
  if d > 1e-6 then
    if maxc == r then h = 60 * (((g - b) / d) % 6)
    elseif maxc == g then h = 60 * ((b - r) / d + 2)
    else h = 60 * ((r - g) / d + 4) end
  end
  if h < 0 then h = h + 360 end
  local s = (maxc <= 1e-6) and 0 or (d / maxc)
  return h, s, maxc
end

function rgbToHex(r, g, b)
  local function byte(x)
    return math.floor(clamp01(x) * 255 + 0.5)
  end
  return string.format('#%02X%02X%02X', byte(r), byte(g), byte(b))
end

function hexToRgb(hex)
  if not hex or hex == '' then return nil end
  hex = hex:gsub('%s+', ''):gsub('^#', '')
  if #hex == 3 then
    hex = hex:sub(1,1)..hex:sub(1,1)..hex:sub(2,2)..hex:sub(2,2)..hex:sub(3,3)..hex:sub(3,3)
  end
  if not hex:match('^%x%x%x%x%x%x$') then return nil end
  local n = tonumber(hex, 16)
  local r = math.floor(n / 65536) % 256
  local g = math.floor(n / 256) % 256
  local b = n % 256
  return r / 255, g / 255, b / 255
end

local function defaultSeatRgb(seat)
  local c = Color.fromString(seat)
  if type(c) == 'table' then
    return c.r or c[1] or 1, c.g or c[2] or 1, c.b or c[3] or 1
  end
  local rgb = stringColorToRGB(seat)
  if rgb then return rgb.r, rgb.g, rgb.b end
  return 1, 1, 1
end

local function getSeatRgb(seat)
  local stored = seatColors[seat]
  if stored then return stored.r, stored.g, stored.b end
  return defaultSeatRgb(seat)
end

local function buttonColors(hex)
  return hex..'|'..hex..'|'..hex..'|#666666'
end

local function unpackRgb(fc)
  if not fc then return 0, 0, 0, 1 end
  return fc.r or fc[1] or 0, fc.g or fc[2] or 0, fc.b or fc[3] or 0, fc.a or fc[4] or 1
end

-- Seat-chrome fonts (timer digits, commander zone value).
-- Skip black outlines and white life-digit labels.
local function fontLooksSeatChrome(fc)
  local r, g, b, a = unpackRgb(fc)
  if a < 0.02 then return false end
  if (r + g + b) < 0.35 then return false end
  if r > 0.9 and g > 0.9 and b > 0.9 then return false end
  return true
end

local function setFontChrome(obj, r, g, b)
  local buttons = obj.getButtons()
  if not buttons then return end
  for _, btn in ipairs(buttons) do
    if fontLooksSeatChrome(btn.font_color) then
      local _, _, _, a = unpackRgb(btn.font_color)
      local fc = { r = r, g = g, b = b, a = a }
      local idx = btn.index
      if idx == nil then idx = 0 end
      pcall(function()
        obj.editButton({ index = idx, font_color = fc })
      end)
    end
  end
end

------------------------------------------------------------------------
-- Persist
------------------------------------------------------------------------

local function encodeSeats()
  return JSON.encode({ seats = seatColors, swaps = swaps })
end

local function updateSave()
  -- script_state helps when the object enters a container mid-game.
  self.script_state = encodeSeats()
end

-- Official persistence path (save / autosave / rewind). onLoad receives this string.
function onSave()
  return encodeSeats()
end

local function loadSave(data)
  seatColors = {}
  swaps = {}
  if not data or data == '' then return end
  local ok, decoded = pcall(JSON.decode, data)
  if not ok or type(decoded) ~= 'table' then return end
  local src = decoded.seats or decoded
  for seat, rgb in pairs(src) do
    if type(seat) == 'string' and not NON_SEATS[seat] and type(rgb) == 'table' then
      local r = tonumber(rgb.r) or tonumber(rgb[1])
      local g = tonumber(rgb.g) or tonumber(rgb[2])
      local b = tonumber(rgb.b) or tonumber(rgb[3])
      if r and g and b then
        seatColors[seat] = { r = r, g = g, b = b }
      end
    end
  end
  if type(decoded.swaps) == 'table' then
    for origin, current in pairs(decoded.swaps) do
      if type(origin) == 'string' and type(current) == 'string' and origin ~= current then
        swaps[origin] = current
      end
    end
  end
end

------------------------------------------------------------------------
-- Object matching (whitelist by nickname)
------------------------------------------------------------------------

local function objectSeat(obj)
  local desc = obj.getDescription() or ''
  -- Description may be "White" or "White something"
  local descSeat = desc:match('^(%S+)')
  if descSeat and isSeatColor(descSeat) then return descSeat end
  local name = obj.getName() or ''
  local prefix = name:match('^(%S+)')
  if prefix and isSeatColor(prefix) then return prefix end
  return nil
end

local function widgetKind(obj)
  local n = (obj.getName() or ''):lower()
  if n == '' then return nil end
  if SKIP_NAME[n] or n:find('turn skipper') then return nil end
  if n:find('mana') then return nil end
  -- Hand counts are handled by fixHandCountDisplays (single label only).
  if n:find('hand counter') then return nil end
  -- Full-seat battlefield plate used for turn glow — do not tint.
  if n:find('highlight') and n:find('mat') then return nil end
  if n:find('life') and n:find('tracker') then return 'tint' end
  if n:find('commander') and n:find('damage') then return 'tint' end
  if n:find('rhystic') then return 'tint' end
  if n:find('commander') and n:find('zone') then return 'font' end
  if n:find('timer') then return 'font_and_tint' end
  return nil
end

-- Oops: "Hand Counter Self" faces the seated player; the plain Hand Counter
-- faces outward. Prefer Self so "N cards" reads upright from your seat.
local function blankButton(obj, idx)
  pcall(function()
    obj.editButton({
      index = idx,
      label = '',
      font_size = 0,
      font_color = { 0, 0, 0, 0 },
      width = 0,
      height = 0,
    })
  end)
end

local function blankAllButtons(obj)
  local buttons = obj.getButtons()
  if not buttons then return end
  for _, btn in ipairs(buttons) do
    blankButton(obj, btn.index or 0)
  end
end

local function isHandCounterName(n)
  return (n:find('hand counter') or n:find('handcount') or n:find('hand_count'))
    and not n:find('screen')
end

local function tintHandButtons(obj, rgb)
  if not rgb then return end
  local buttons = obj.getButtons()
  if not buttons then return end
  for _, btn in ipairs(buttons) do
    local label = (btn.label or ''):lower()
    if label:find('card') or fontLooksSeatChrome(btn.font_color) then
      pcall(function()
        obj.editButton({
          index = btn.index or 0,
          font_color = { r = rgb.r, g = rgb.g, b = rgb.b, a = 1 },
        })
      end)
    end
  end
end

local function fixHandCountDisplays(seat, rgb)
  local outward, selves = {}, {}
  for _, obj in ipairs(getAllObjects()) do
    local n = (obj.getName() or ''):lower()
    if isHandCounterName(n) and objectSeat(obj) == seat then
      if n:find('self') then
        table.insert(selves, obj)
      else
        table.insert(outward, obj)
      end
    end
  end

  -- Hide outward-facing counters (away from the seated player).
  for _, obj in ipairs(outward) do
    pcall(function() obj.setInvisible(true) end)
    blankAllButtons(obj)
  end

  if #selves > 0 then
    for i, obj in ipairs(selves) do
      if i == 1 then
        pcall(function() obj.setInvisible(false) end)
        tintHandButtons(obj, rgb)
      else
        pcall(function() obj.setInvisible(true) end)
        blankAllButtons(obj)
      end
    end
    return
  end

  -- No Self object: keep one counter, prefer the flipped / higher-index button
  -- (usually the face toward the player).
  for i, obj in ipairs(outward) do
    if i > 1 then
      pcall(function() obj.setInvisible(true) end)
      blankAllButtons(obj)
    else
      pcall(function() obj.setInvisible(false) end)
      local buttons = obj.getButtons()
      if not buttons or #buttons == 0 then return end
      local keepIdx = nil
      for _, btn in ipairs(buttons) do
        local idx = btn.index or 0
        local rot = btn.rotation
        local rx = rot and (tonumber(rot.x or rot[1]) or 0) or 0
        local rz = rot and (tonumber(rot.z or rot[3]) or 0) or 0
        local function near180(a)
          a = math.abs(a % 360)
          if a > 180 then a = 360 - a end
          return math.abs(a - 180) < 45
        end
        if near180(rx) or near180(rz) then
          keepIdx = idx
          break
        end
        if keepIdx == nil or idx > keepIdx then
          keepIdx = idx
        end
      end
      for _, btn in ipairs(buttons) do
        local idx = btn.index or 0
        if idx == keepIdx then
          if rgb then
            pcall(function()
              obj.editButton({
                index = idx,
                font_color = { r = rgb.r, g = rgb.g, b = rgb.b, a = 1 },
              })
            end)
          end
        else
          blankButton(obj, idx)
        end
      end
    end
  end
end

local function restoreHandCountDisplays(seat)
  for _, obj in ipairs(getAllObjects()) do
    local n = (obj.getName() or ''):lower()
    if isHandCounterName(n) and objectSeat(obj) == seat then
      pcall(function() obj.setInvisible(false) end)
    end
  end
end

------------------------------------------------------------------------
-- Playmat line-work overlay
-- Primary: align image deck/GY boxes to Global data[seat].libraryZone and
-- .graveyard (same zones other table scripts use). Auto-fits 4p/6p/8p.
-- Fallback: Art Playmat enabler hand-math if those zones are missing.
------------------------------------------------------------------------

local function seatDeckDir(seat)
  local ok, dirs = pcall(function() return Global.getTable('deckDirs') end)
  if not ok or type(dirs) ~= 'table' then return 1 end
  if type(dirs[seat]) == 'number' then
    return dirs[seat]
  end
  -- After an engine swap, dirs may still be keyed by the origin seat.
  for origin, current in pairs(swaps) do
    if current == seat and type(dirs[origin]) == 'number' then
      return dirs[origin]
    end
  end
  return 1
end

local function boxCenter(b)
  return (b[1] + b[3]) * 0.5, (b[2] + b[4]) * 0.5
end

local function xzDist(a, b)
  local dx = (a.x or 0) - (b.x or 0)
  local dz = (a.z or 0) - (b.z or 0)
  return math.sqrt(dx * dx + dz * dz)
end

-- Global.data may store live objects or GUID strings depending on table/load.
local function coerceObject(ref)
  if ref == nil then return nil end
  if type(ref) == 'string' then
    return getObjectFromGUID(ref)
  end
  local ok = pcall(function() return ref.getPosition() end)
  if ok then return ref end
  if type(ref) == 'table' and type(ref.guid) == 'string' then
    return getObjectFromGUID(ref.guid)
  end
  return nil
end

local LIB_KEYS = { 'libraryZone', 'library', 'deckZone', 'deck', 'libZone' }
local GY_KEYS  = { 'graveyard', 'graveyardZone', 'gyZone', 'gy', 'grave' }

local function entryLibGy(entry)
  if type(entry) ~= 'table' then return nil end
  local lib, gy
  for _, k in ipairs(LIB_KEYS) do
    lib = coerceObject(entry[k])
    if lib then break end
  end
  for _, k in ipairs(GY_KEYS) do
    gy = coerceObject(entry[k])
    if gy then break end
  end
  if lib and gy then return lib, gy end
  return nil
end

local function seatHandTransform(seat)
  local okP, player = pcall(function() return Player[seat] end)
  if not okP or not player then return nil end
  local ok, hand = pcall(function() return player.getHandTransform(1) end)
  if not ok or not hand or not hand.position then return nil end
  return hand
end

-- Pick library + GY by physical proximity to this seat's hand — never trust
-- data[seat] alone. Shared/aliased Global.data entries otherwise pin every
-- seat's overlay onto White (or whichever entry was assigned last).
local function resolveSeatLibGy(seat)
  local hand = seatHandTransform(seat)
  local handPos = hand and hand.position
  local ok, data = pcall(function() return Global.getTable('data') end)
  if not ok or type(data) ~= 'table' then data = nil end

  local bestLib, bestGy, bestDist = nil, nil, 1e9

  local function consider(lib, gy)
    if not lib or not gy then return end
    local okL, lp = pcall(function() return lib.getPosition() end)
    local okG, gp = pcall(function() return gy.getPosition() end)
    if not okL or not okG or not lp or not gp then return end
    -- Prefer the pair nearest this seat's hand; fall back to mid-pair origin.
    local dist
    if handPos then
      dist = math.min(xzDist(lp, handPos), xzDist(gp, handPos))
    else
      dist = xzDist(lp, gp) -- degenerate: still need some ranking
    end
    if dist < bestDist then
      bestDist = dist
      bestLib, bestGy = lib, gy
    end
  end

  if data then
    -- Prefer the entry keyed for this seat / swap origin when it is nearby.
    local preferred = { data[seat] }
    for origin, current in pairs(swaps) do
      if current == seat then table.insert(preferred, data[origin]) end
      if origin == seat then table.insert(preferred, data[origin]) end
    end
    for _, entry in ipairs(preferred) do
      local lib, gy = entryLibGy(entry)
      if lib and gy then
        local okL, lp = pcall(function() return lib.getPosition() end)
        if okL and lp and handPos and xzDist(lp, handPos) < 42 then
          return lib, gy
        end
      end
    end
    -- Otherwise: any seat's zone pair that physically sits at this hand.
    for _, entry in pairs(data) do
      local lib, gy = entryLibGy(entry)
      consider(lib, gy)
    end
  end

  if bestLib and bestGy and (not handPos or bestDist < 42) then
    return bestLib, bestGy
  end

  -- Last resort: scripting triggers near the hand on the side column.
  if hand and handPos then
    local right, forward = hand.right, hand.forward
    local col = {}
    for _, obj in ipairs(getAllObjects()) do
      if obj.type == 'ScriptingTrigger' then
        local okP, pos = pcall(function() return obj.getPosition() end)
        if okP and pos then
          local dx = pos.x - handPos.x
          local dz = pos.z - handPos.z
          local alongR = dx * (right.x or 0) + dz * (right.z or 0)
          local alongF = dx * (forward.x or 0) + dz * (forward.z or 0)
          -- Side strip: forward of hand, out toward the deck column.
          if alongF > 4 and alongF < 40 and math.abs(alongR) > 8 and math.abs(alongR) < 35 then
            table.insert(col, { obj = obj, f = alongF, r = alongR })
          end
        end
      end
    end
    if #col >= 2 then
      table.sort(col, function(a, b) return a.f > b.f end)
      -- Deck is farther from the hand than graveyard on the printed mat.
      return col[1].obj, col[2].obj
    end
  end

  return nil
end

-- Shape art has the deck/GY strip on the image RIGHT (+X). Force world
-- +right to point from the seat's mat toward that column (outboard), so
-- left-strip seats (Red/Blue) and right-strip seats (White/Yellow) both map
-- without a separate flipX heuristic (deckDirs is not strip-side).
local function orientStripRightAxis(seat, colX, colZ, rightX, rightZ, wDeck, wGy)
  local hand = seatHandTransform(seat)
  if hand and hand.position and hand.forward and wDeck and wGy then
    local aimX = hand.position.x + (hand.forward.x or 0) * 12
    local aimZ = hand.position.z + (hand.forward.z or 0) * 12
    local midX = (wDeck.x + wGy.x) * 0.5
    local midZ = (wDeck.z + wGy.z) * 0.5
    local outX, outZ = midX - aimX, midZ - aimZ
    if rightX * outX + rightZ * outZ < 0 then
      rightX, rightZ = -rightX, -rightZ
    end
    return rightX, rightZ
  end
  -- No hand: keep a consistent perpendicular (does not use deckDirs).
  return rightX, rightZ
end

-- Map image pixels from libraryZone + graveyard world positions.
local function seatPixelToWorldFromZones(seat)
  local lib, gyObj = resolveSeatLibGy(seat)
  if not lib or not gyObj then return nil end
  local okD, wDeck = pcall(function() return lib.getPosition() end)
  local okG, wGy = pcall(function() return gyObj.getPosition() end)
  if not okD or not okG or not wDeck or not wGy then return nil end

  local anchorDeck, anchorGy = matAnchors()
  local idx, idy = boxCenter(anchorDeck)
  local igx, igy = boxCenter(anchorGy)
  local iDx, iDy = idx - igx, idy - igy
  local iLen = math.sqrt(iDx * iDx + iDy * iDy)
  local wDx, wDz = wDeck.x - wGy.x, wDeck.z - wGy.z
  local wLen = math.sqrt(wDx * wDx + wDz * wDz)
  if iLen < 1e-3 or wLen < 1e-3 then return nil end

  local scale = (wLen / iLen) * (matCal.scale or 1)
  -- Column axis: graveyard → deck (image “up” the side strip).
  local colX, colZ = wDx / wLen, wDz / wLen

  -- Right axis: prefer the library zone’s right; else perpendicular in XZ.
  local rightX, rightZ = colZ, -colX
  local okR, rVec = pcall(function() return lib.getTransformRight() end)
  if okR and rVec then
    local rx, rz = rVec.x or 0, rVec.z or 0
    local rLen = math.sqrt(rx * rx + rz * rz)
    if rLen > 1e-3 then
      rightX, rightZ = rx / rLen, rz / rLen
      if math.abs(rightX * colX + rightZ * colZ) > 0.9 then
        rightX, rightZ = colZ, -colX
      end
    end
  end
  rightX, rightZ = orientStripRightAxis(seat, colX, colZ, rightX, rightZ, wDeck, wGy)

  local sx = matCal.flipX and -1 or 1
  local sy = matCal.flipZ and -1 or 1
  local ox = matCal.offsetRight or 0
  local oz = matCal.offsetFwd or 0

  return function(px, py)
    local dpx = (px - igx) * scale * sx
    local dpy = (py - igy) * scale * sy
    -- +image X → +right; +image Y (down) → opposite column (away from deck).
    return Vector(
      wGy.x + rightX * (dpx + ox) + colX * (-dpy + oz),
      matCal.borderY,
      wGy.z + rightZ * (dpx + ox) + colZ * (-dpy + oz)
    )
  end
end

-- Fallback: Art Playmat enabler placement from hand transform.
local function seatPixelToWorldFromHand(seat)
  local hand = seatHandTransform(seat)
  if not hand then return nil end

  local deckDir = seatDeckDir(seat)
  local right = hand.right
  local forward = hand.forward
  local base = hand.position
    + right * (matCal.centerRight * deckDir + matCal.offsetRight)
    + forward * (matCal.centerFwd + matCal.offsetFwd)

  local halfW = 0.5 * matCal.worldW * matCal.scale
  local halfH = 0.5 * matCal.worldH * matCal.scale
  local sx = matCal.flipX and -1 or 1
  local sz = matCal.flipZ and -1 or 1
  if matCal.rot180 then
    sx, sz = -sx, -sz
  end

  local imgW, imgH = matImgSize()
  return function(px, py)
    local u = (px / imgW) - 0.5
    local v = (py / imgH) - 0.5
    local dx = u * 2 * halfW * sx
    local dz = v * 2 * halfH * sz
    return Vector(
      base.x + right.x * dx + forward.x * dz,
      matCal.borderY,
      base.z + right.z * dx + forward.z * dz
    )
  end
end

local function seatPixelToWorld(seat)
  return seatPixelToWorldFromZones(seat) or seatPixelToWorldFromHand(seat)
end

-- Clockwise rounded-rect outline in image pixels, converted through toWorld.
local function roundedRectPoints(x0, y0, x1, y1, rad, toWorld)
  local pts = {}
  local steps = math.max(1, math.floor(matCal.arcSteps + 0.5))
  local function arc(cx, cy, fromDeg, toDeg)
    for i = 0, steps do
      local t = math.rad(fromDeg + (toDeg - fromDeg) * (i / steps))
      table.insert(pts, toWorld(cx + rad * math.cos(t), cy + rad * math.sin(t)))
    end
  end
  -- Image y grows downward; angles in image space.
  arc(x0 + rad, y0 + rad, 180, 270) -- top-left
  arc(x1 - rad, y0 + rad, 270, 360) -- top-right
  arc(x1 - rad, y1 - rad, 0, 90)    -- bottom-right
  arc(x0 + rad, y1 - rad, 90, 180)  -- bottom-left
  -- TTS vector lines have no loop flag; close by repeating the first point.
  table.insert(pts, pts[1])
  return pts
end

local function borderSignature()
  local parts = {}
  for seat, rgb in pairs(seatColors) do
    table.insert(parts, string.format('%s:%.3f,%.3f,%.3f', seat, rgb.r, rgb.g, rgb.b))
  end
  table.sort(parts)
  -- Include cal so live edits always redraw even if seat color is unchanged.
  local m = activeMatLayout()
  table.insert(parts, string.format('mat:%dx%d:%d', m.imgW, m.imgH, #m.shapes))
  table.insert(parts, string.format(
    'cal:%.2f,%.2f,%.2f,%.2f,%s,%s,%s,%.3f,%.3f,%d,%.2f,%.2f,%.2f',
    matCal.centerFwd, matCal.centerRight, matCal.worldW, matCal.worldH,
    matCal.rot180 and '1' or '0', matCal.flipX and '1' or '0', matCal.flipZ and '1' or '0',
    matCal.borderY, matCal.lineThickness, matCal.arcSteps,
    matCal.scale, matCal.offsetRight, matCal.offsetFwd
  ))
  return table.concat(parts, ';')
end

local function isOurLine(line)
  local t = tonumber(line.thickness) or 0
  -- Match current thickness; also clear older sentinels if thickness was nudged.
  return math.abs(t - matCal.lineThickness) < 1e-4
    or math.abs(t - 0.173) < 1e-4
    or math.abs(t - 0.4) < 1e-4
end

function rebuildSeatBorders(force)
  local sig = borderSignature()
  if not force and sig == lastBorderSig then return end

  local kept = {}
  local ok, existing = pcall(function() return Global.getVectorLines() end)
  if ok and type(existing) == 'table' then
    for _, line in ipairs(existing) do
      if not isOurLine(line) then
        table.insert(kept, line)
      end
    end
  end

  local shapes = matShapes()
  for seat, rgb in pairs(seatColors) do
    local toWorld = seatPixelToWorld(seat)
    if toWorld then
      for _, shape in ipairs(shapes) do
        table.insert(kept, {
          points = roundedRectPoints(shape[1], shape[2], shape[3], shape[4], shape[5], toWorld),
          color = { rgb.r, rgb.g, rgb.b },
          thickness = matCal.lineThickness,
        })
      end
    end
  end

  pcall(function() Global.setVectorLines(kept) end)
  lastBorderSig = sig
end

local function paintObject(obj, seat, r, g, b)
  local kind = widgetKind(obj)
  if not kind then return end

  local objSeat = objectSeat(obj)
  if objSeat ~= seat then return end

  if kind == 'tint' then
    obj.setColorTint({ r, g, b })
  elseif kind == 'font' then
    setFontChrome(obj, r, g, b)
  elseif kind == 'font_and_tint' then
    obj.setColorTint({ r, g, b })
    setFontChrome(obj, r, g, b)
  end
end

-- restoreStock: when true and no custom tint, paint stock seat RGB once
-- (Reset / cancel-preview). When false, leave widgets alone — used on load
-- and engine-swap so the token does nothing until Apply.
function applySeatCosmetics(seat, restoreStock)
  if not seat or NON_SEATS[seat] then return end
  local custom = seatColors[seat]
  if custom then
    local r, g, b = custom.r, custom.g, custom.b
    for _, obj in ipairs(getAllObjects()) do
      paintObject(obj, seat, r, g, b)
    end
    fixHandCountDisplays(seat, { r = r, g = g, b = b })
  elseif restoreStock then
    local r, g, b = defaultSeatRgb(seat)
    for _, obj in ipairs(getAllObjects()) do
      paintObject(obj, seat, r, g, b)
    end
    restoreHandCountDisplays(seat)
  end
  rebuildSeatBorders()
end

function applyAllSeatCosmetics()
  -- Re-apply only seats that opted in via Apply (or live preview).
  for seat, _ in pairs(seatColors) do
    applySeatCosmetics(seat)
  end
  if not next(seatColors) then
    rebuildSeatBorders()
  end
end

-- One-shot delayed re-apply after events (no repeating sticky interval).
local function scheduleReapply(delays)
  delays = delays or { 0.05, 0.25, 0.75 }
  for _, d in ipairs(delays) do
    Wait.time(applyAllSeatCosmetics, d)
  end
end

------------------------------------------------------------------------
-- Engine seat swap (real chat / player-list color, stock palette only)
--
-- TTS seats are defined by hand zones: re-valuing a seat's hand zone to an
-- unused stock color makes that color a real seat, and chat name / player
-- list / pointer follow it. Everything below keeps the table's scripts
-- working afterwards WITHOUT editing any file:
--   * Global's `data` / `deckDirs` tables get the new color aliased in via
--     Global.getTable/setTable (old keys stay, so old lookups still work).
--   * Seat-coupled widgets (hand counters etc.) are rebound live: their
--     Description/Name seat prefix is rewritten and the object reload()ed,
--     which kills the stale per-second Wait loops that would otherwise spam
--     "Object reference not set to an instance of an object".
------------------------------------------------------------------------

local function isEngineColor(color)
  for _, c in ipairs(ENGINE_COLORS) do
    if c == color then return true end
  end
  return false
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

-- Rewrite the leading seat word of a string ("White foo" -> "Pink foo").
local function swapSeatPrefix(text, fromColor, toColor)
  if not text or text == '' then return nil end
  if text == fromColor then return toColor end
  local rest = text:match('^'..fromColor..'([%s\n].*)$')
  if rest then return toColor..rest end
  return nil
end

-- Never rename cards/decks: MTG card names can start with a color word
-- ("White Knight" must not become "Pink Knight").
local REBIND_SKIP_TYPES = { Card = true, Deck = true }

local function rebindSeatWidgets(fromColor, toColor)
  for _, obj in ipairs(getAllObjects()) do
    if obj ~= self and not REBIND_SKIP_TYPES[obj.type] then
      local newDesc = swapSeatPrefix(obj.getDescription(), fromColor, toColor)
      local newName = swapSeatPrefix(obj.getName(), fromColor, toColor)
      if newDesc or newName then
        pcall(function()
          if newDesc then obj.setDescription(newDesc) end
          if newName then obj.setName(newName) end
          -- reload() rebuilds the script context so Player[<Description>]
          -- bindings and Wait loops re-run against the new color.
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
  -- Engine palette pick also paints mat line-work + widgets in that color.
  seatColors[fromColor] = nil
  if toColor == origin then
    swaps[origin] = nil
    seatColors[toColor] = nil
  else
    swaps[origin] = toColor
    local r, g, b = defaultSeatRgb(toColor)
    seatColors[toColor] = { r = r, g = g, b = b }
  end
  updateSave()
  -- Give the engine a couple frames to register the new seat before moving
  -- the player onto it and re-running widget scripts against it.
  Wait.frames(function()
    pcall(function()
      if Player[fromColor] and Player[fromColor].seated then
        Player[fromColor].changeColor(toColor)
      end
    end)
    rebindSeatWidgets(fromColor, toColor)
    lastBorderSig = nil
    applySeatCosmetics(fromColor, true)
    applySeatCosmetics(toColor)
    scheduleReapply({ 0.5, 1.5, 3 })
  end, 2)
end

-- After save / load / rewind: zone values and widget descriptions persist in
-- the save, but Global's onload rebuilds `data` / `deckDirs` with the stock
-- seat keys only — re-apply our aliases once Global has settled.
local function reapplySwapAliases()
  for origin, current in pairs(swaps) do
    if #seatHandZones(current) > 0 then
      aliasGlobalTables(origin, current)
    end
  end
end

------------------------------------------------------------------------
-- Screen UI (Global HUD — same approach as rikrassen importer)
------------------------------------------------------------------------

local function uiFn(name)
  -- Route Global UI events to this object's script: "guid/functionName"
  return self.getGUID() .. '/' .. name
end

local function buildSvGridNode()
  local children = {}
  for row = 0, SV_ROWS - 1 do
    for col = 0, SV_COLS - 1 do
      table.insert(children, {
        tag = 'Button',
        attributes = {
          id = string.format('sv_%d_%d', row, col),
          onClick = uiFn('onSvClick'),
          colors = '#808080|#808080|#808080|#666666',
        },
      })
    end
  end
  return {
    tag = 'GridLayout',
    attributes = {
      id = 'svGrid',
      cellSize = '18 15',
      spacing = '1 1',
      constraint = 'FixedColumnCount',
      constraintCount = tostring(SV_COLS),
      preferredWidth = tostring(SV_COLS * 19),
      preferredHeight = tostring(SV_ROWS * 16),
    },
    children = children,
  }
end

local function buildHueStripNode()
  local children = {}
  for i = 0, HUE_STEPS - 1 do
    local h = (i / HUE_STEPS) * 360
    local r, g, b = hsvToRgb(h, 1, 1)
    local hex = rgbToHex(r, g, b)
    table.insert(children, {
      tag = 'Button',
      attributes = {
        id = string.format('hue_%d', i),
        onClick = uiFn('onHueStripClick'),
        colors = buttonColors(hex),
      },
    })
  end
  return {
    tag = 'HorizontalLayout',
    attributes = {
      id = 'hueStrip',
      preferredHeight = '22',
      spacing = '0',
      childForceExpandWidth = 'true',
      childForceExpandHeight = 'true',
    },
    children = children,
  }
end

--[[ Calibration UI disabled
local function formatCalNum(key, v)
  if key == 'arcSteps' then
    return string.format('%d', math.floor(v + 0.5))
  end
  if key == 'borderY' or key == 'lineThickness' then
    return string.format('%.3f', v)
  end
  return string.format('%.2f', v)
end

local CAL_NUM_KEYS = {
  { key = 'scale',         label = 'scale' },
  { key = 'offsetRight',   label = 'offsetRight' },
  { key = 'offsetFwd',     label = 'offsetFwd' },
  { key = 'borderY',       label = 'borderY' },
  { key = 'lineThickness', label = 'lineThick' },
  { key = 'arcSteps',      label = 'arcSteps' },
  -- Fallback hand-math (only if deck/GY zones missing):
  { key = 'centerFwd',     label = 'fb centerFwd' },
  { key = 'centerRight',   label = 'fb centerRight' },
  { key = 'worldW',        label = 'fb worldW' },
  { key = 'worldH',        label = 'fb worldH' },
}

local CAL_BOOL_KEYS = {
  { key = 'flipX',  label = 'flipX' },
  { key = 'flipZ',  label = 'flipZ' },
  { key = 'rot180', label = 'rot180 (fallback)' },
}

local function buildCalNudgeRow(key, label)
  return {
    tag = 'HorizontalLayout',
    attributes = {
      preferredHeight = '28',
      spacing = '4',
      childForceExpandWidth = 'false',
      childForceExpandHeight = 'true',
    },
    children = {
      {
        tag = 'Text',
        attributes = {
          preferredWidth = '100',
          fontSize = '12',
          color = '#CCCCCC',
          alignment = 'MiddleLeft',
          raycastTarget = 'false',
        },
        value = label,
      },
      {
        tag = 'Text',
        attributes = {
          id = 'calVal_'..key,
          preferredWidth = '70',
          fontSize = '13',
          color = '#FFFFFF',
          alignment = 'MiddleRight',
          raycastTarget = 'false',
        },
        value = formatCalNum(key, matCal[key]),
      },
      {
        tag = 'Button',
        attributes = {
          id = 'calDec_'..key,
          onClick = uiFn('onCalNudge'),
          preferredWidth = '44',
          preferredHeight = '28',
          fontSize = '18',
        },
        value = '-',
      },
      {
        tag = 'Button',
        attributes = {
          id = 'calInc_'..key,
          onClick = uiFn('onCalNudge'),
          preferredWidth = '44',
          preferredHeight = '28',
          fontSize = '18',
        },
        value = '+',
      },
    },
  }
end

local function buildCalBoolRow(key, label)
  return {
    tag = 'HorizontalLayout',
    attributes = {
      preferredHeight = '28',
      spacing = '4',
      childForceExpandWidth = 'false',
      childForceExpandHeight = 'true',
    },
    children = {
      {
        tag = 'Text',
        attributes = {
          preferredWidth = '100',
          fontSize = '12',
          color = '#CCCCCC',
          alignment = 'MiddleLeft',
          raycastTarget = 'false',
        },
        value = label,
      },
      {
        tag = 'Button',
        attributes = {
          id = 'calBool_'..key,
          onClick = uiFn('onCalToggle'),
          preferredWidth = '140',
          preferredHeight = '28',
          fontSize = '12',
        },
        value = matCal[key] and (key..'=true') or (key..'=false'),
      },
    },
  }
end

local function buildCalPanelNode()
  local rows = {
    {
      tag = 'HorizontalLayout',
      attributes = { preferredHeight = '28', childForceExpandWidth = 'false' },
      children = {
        {
          tag = 'Text',
          attributes = { fontSize = '16', preferredWidth = '220' },
          value = 'Mat calibrate',
        },
        {
          tag = 'Button',
          attributes = {
            id = 'btnCalClose',
            onClick = uiFn('onCloseCal'),
            preferredWidth = '32',
            preferredHeight = '28',
          },
          value = 'X',
        },
      },
    },
    {
      tag = 'Text',
      attributes = { fontSize = '11', color = '#888888' },
      value = 'Auto-aligns to library + graveyard zones. Pads below are optional.',
    },
  }
  for _, row in ipairs(CAL_NUM_KEYS) do
    table.insert(rows, buildCalNudgeRow(row.key, row.label))
  end
  for _, row in ipairs(CAL_BOOL_KEYS) do
    table.insert(rows, buildCalBoolRow(row.key, row.label))
  end
  table.insert(rows, {
    tag = 'Button',
    attributes = {
      id = 'btnCalPrint',
      onClick = uiFn('onCalPrint'),
      preferredHeight = '32',
      fontSize = '13',
    },
    value = 'Print values to chat',
  })
  return {
    tag = 'Panel',
    attributes = {
      id = 'seatColorCalRoot',
      active = 'false',
      width = '320',
      height = '520',
      rectAlignment = 'MiddleRight',
      offsetXY = '-20 0',
      color = 'rgba(0.08,0.08,0.08,0.96)',
      padding = '12',
      showAnimation = 'FadeIn',
      hideAnimation = 'FadeOut',
      allowDragging = 'true',
      returnToOriginalPositionWhenReleased = 'false',
    },
    children = {
      {
        tag = 'VerticalLayout',
        attributes = { spacing = '4', childForceExpandHeight = 'false' },
        children = rows,
      },
    },
  }
end

local function refreshCalUi()
  for _, row in ipairs(CAL_NUM_KEYS) do
    pcall(function()
      UI.setAttribute('calVal_'..row.key, 'text', formatCalNum(row.key, matCal[row.key]))
    end)
  end
  for _, row in ipairs(CAL_BOOL_KEYS) do
    local v = matCal[row.key] and (row.key..'=true') or (row.key..'=false')
    pcall(function()
      UI.setAttribute('calBool_'..row.key, 'text', v)
    end)
  end
end

local function ensureCalPreview(player)
  -- Need at least one seat color so loops are visible while calibrating.
  local seat = player and player.color
  if not seat or NON_SEATS[seat] then return end
  if not seatColors[seat] then
    local r, g, b = defaultSeatRgb(seat)
    seatColors[seat] = { r = r, g = g, b = b }
  end
end

local function applyCalLive(player)
  ensureCalPreview(player)
  lastBorderSig = nil
  rebuildSeatBorders(true)
  refreshCalUi()
end

]]

local function buildEngineColorNode()
  local buttons = {}
  for _, c in ipairs(ENGINE_COLORS) do
    local r, g, b = defaultSeatRgb(c)
    local hex = rgbToHex(r, g, b)
    local textHex = (r + g + b) > 1.6 and '#222222' or '#FFFFFF'
    table.insert(buttons, {
      tag = 'Button',
      attributes = {
        id = 'engine_'..c,
        onClick = uiFn('onEngineSwap'),
        colors = buttonColors(hex),
        textColor = textHex,
        fontSize = '10',
      },
      value = c,
    })
  end
  return {
    tag = 'VerticalLayout',
    attributes = { spacing = '4', childForceExpandHeight = 'false' },
    children = {
      {
        tag = 'Text',
        attributes = { fontSize = '11', color = '#888888' },
        value = 'Optional: engine seat (chat & player list). Also tints the mat; hex Apply above still works alone.',
      },
      {
        tag = 'GridLayout',
        attributes = {
          cellSize = '62 24',
          spacing = '2 2',
          constraint = 'FixedColumnCount',
          constraintCount = '5',
          preferredHeight = '52',
        },
        children = buttons,
      },
      {
        tag = 'Button',
        attributes = {
          id = 'btnEngineRevert',
          onClick = uiFn('onEngineRevert'),
          preferredHeight = '26',
          fontSize = '12',
        },
        value = 'Revert to original seat',
      },
      --[[ Calibration UI disabled
      {
        tag = 'Button',
        attributes = {
          id = 'btnOpenCal',
          onClick = uiFn('onOpenCal'),
          preferredHeight = '28',
          fontSize = '12',
          colors = '#3A3A2A|#4A4A3A|#2A2A1A|#555555',
        },
        value = 'Calibrate mat…',
      },
      ]]
    },
  }
end

local function buildPickerPanelNode()
  return {
    tag = 'Panel',
    attributes = {
      id = 'seatColorPickerRoot',
      active = 'false',
      width = '360',
      height = '640',
      rectAlignment = 'MiddleCenter',
      offsetXY = '0 20',
      color = 'rgba(0.08,0.08,0.08,0.96)',
      padding = '14',
      showAnimation = 'FadeIn',
      hideAnimation = 'FadeOut',
      allowDragging = 'true',
      returnToOriginalPositionWhenReleased = 'false',
    },
    children = {
      {
        tag = 'Defaults',
        children = {
          { tag = 'Text', attributes = { color = '#EEEEEE', fontSize = '16' } },
          {
            tag = 'Button',
            attributes = {
              fontSize = '14',
              colors = '#2A2A2A|#3A3A3A|#1A1A1A|#555555',
              textColor = '#FFFFFF',
            },
          },
          {
            tag = 'InputField',
            attributes = {
              fontSize = '16',
              colors = '#1A1A1A|#1A1A1A|#111111|#333333',
              textColor = '#FFFFFF',
            },
          },
        },
      },
      {
        tag = 'VerticalLayout',
        attributes = { spacing = '8', childForceExpandHeight = 'false' },
        children = {
          {
            tag = 'HorizontalLayout',
            attributes = { preferredHeight = '28', childForceExpandWidth = 'false' },
            children = {
              {
                tag = 'Text',
                attributes = { fontSize = '18', preferredWidth = '300' },
                value = 'Seat Color',
              },
              {
                tag = 'Button',
                attributes = {
                  id = 'btnClose',
                  onClick = uiFn('onClosePicker'),
                  preferredWidth = '32',
                  preferredHeight = '28',
                  textColor = '#CCCCCC',
                  colors = '#333333|#444444|#222222|#555555',
                },
                value = 'X',
              },
            },
          },
          {
            tag = 'Text',
            attributes = { id = 'seatLabel', fontSize = '13', color = '#AAAAAA' },
            value = 'Seat: —',
          },
          buildSvGridNode(),
          {
            tag = 'Text',
            attributes = { fontSize = '11', color = '#888888' },
            value = 'Hue',
          },
          buildHueStripNode(),
          {
            tag = 'Slider',
            attributes = {
              id = 'hueSlider',
              minValue = '0',
              maxValue = '360',
              value = '210',
              preferredHeight = '24',
              onValueChanged = uiFn('onHueChanged'),
              wholeNumbers = 'true',
              colors = 'rgba(0,0,0,0)|rgba(0,0,0,0)|rgba(0,0,0,0)|rgba(0,0,0,0)',
              backgroundColor = 'rgba(0,0,0,0)',
              fillColor = 'rgba(0,0,0,0)',
              handleColor = '#FFFFFF',
            },
          },
          {
            tag = 'HorizontalLayout',
            attributes = {
              preferredHeight = '36',
              spacing = '8',
              childForceExpandWidth = 'false',
            },
            children = {
              {
                tag = 'InputField',
                attributes = {
                  id = 'hexInput',
                  text = '#2974A3',
                  characterLimit = '7',
                  preferredWidth = '150',
                  onEndEdit = uiFn('onHexEdit'),
                },
              },
              {
                tag = 'Panel',
                attributes = {
                  id = 'swatch',
                  preferredWidth = '48',
                  preferredHeight = '36',
                  color = '#2974A3',
                  raycastTarget = 'false',
                },
              },
              {
                tag = 'Button',
                attributes = {
                  id = 'btnCopy',
                  onClick = uiFn('onCopyHex'),
                  preferredWidth = '64',
                  preferredHeight = '36',
                },
                value = 'Copy',
              },
            },
          },
          {
            tag = 'HorizontalLayout',
            attributes = { preferredHeight = '40', spacing = '8' },
            children = {
              {
                tag = 'Button',
                attributes = {
                  id = 'btnReset',
                  onClick = uiFn('onResetColor'),
                  preferredHeight = '40',
                },
                value = 'Reset',
              },
              {
                tag = 'Button',
                attributes = {
                  id = 'btnApply',
                  onClick = uiFn('onApplyColor'),
                  preferredHeight = '40',
                  colors = '#2974A3|#3A8AB8|#1F5A7A|#555555',
                  textColor = '#FFFFFF',
                },
                value = 'Apply',
              },
            },
          },
          buildEngineColorNode(),
        },
      },
    },
  }
end

local function removePickerFromUiTable(ui)
  if type(ui) ~= 'table' then return {} end
  local out = {}
  for _, node in ipairs(ui) do
    local id = node.attributes and node.attributes.id
    if id ~= 'seatColorPickerRoot' and id ~= 'seatColorCalRoot' then
      table.insert(out, node)
    end
  end
  return out
end

local function installScreenUi()
  local ok, ui = pcall(function() return UI.getXmlTable() end)
  if not ok or type(ui) ~= 'table' then
    ui = {}
  end
  ui = removePickerFromUiTable(ui)
  table.insert(ui, buildPickerPanelNode())
  -- table.insert(ui, buildCalPanelNode())  -- calibration UI disabled
  UI.setXmlTable(ui)
end

local function whenUiReady(fn)
  Wait.condition(
    fn,
    function()
      return not UI.loading
    end,
    5,
    fn
  )
end

------------------------------------------------------------------------
-- Open button (3D) — hidden while screen picker is open
------------------------------------------------------------------------

local function showOpenButton()
  self.clearButtons()
  self.createButton({
    click_function = 'clickOpenPicker',
    function_owner = self,
    label = 'Color',
    tooltip = 'Open seat color picker\nRight-click to reset',
    position = { 0, 0.15, 0 },
    -- TTS docs default for upright labels on table objects.
    rotation = { 0, 180, 0 },
    width = 600,
    height = 600,
    font_size = 150,
    color = { 0.12, 0.12, 0.12, 0.95 },
    font_color = { 1, 1, 1 },
  })
end

local function hideOpenButton()
  self.clearButtons()
end

------------------------------------------------------------------------
-- UI sync / sessions (per seated player)
------------------------------------------------------------------------

local function getSession(player)
  if not player then return nil end
  return sessions[player.color]
end

local function sessionRgb(sess)
  if not sess then return 0.16, 0.45, 0.64 end
  return hsvToRgb(sess.h, sess.s, sess.v)
end

local function refreshSvGrid(sess)
  if not sess or uiOwner ~= sess.seat then return end
  for row = 0, SV_ROWS - 1 do
    for col = 0, SV_COLS - 1 do
      local s = (SV_COLS <= 1) and 0 or (col / (SV_COLS - 1))
      local v = (SV_ROWS <= 1) and 1 or (1 - row / (SV_ROWS - 1))
      local r, g, b = hsvToRgb(sess.h, s, v)
      local hex = rgbToHex(r, g, b)
      local id = string.format('sv_%d_%d', row, col)
      UI.setAttribute(id, 'colors', buttonColors(hex))
    end
  end
end

local function refreshHueHandle(sess)
  if not sess or uiOwner ~= sess.seat then return end
  local r, g, b = hsvToRgb(sess.h, 1, 1)
  local hex = rgbToHex(r, g, b)
  UI.setAttribute('hueSlider', 'handleColor', hex)
  UI.setAttribute('hueSlider', 'value', tostring(math.floor(sess.h + 0.5) % 360))
end

local function refreshPreview(sess)
  if not sess or uiOwner ~= sess.seat then return end
  local r, g, b = sessionRgb(sess)
  local hex = rgbToHex(r, g, b)
  UI.setAttribute('hexInput', 'text', hex)
  UI.setAttribute('swatch', 'color', hex)
  UI.setAttribute('seatLabel', 'text', 'Seat: '..sess.seat)
  refreshHueHandle(sess)
end

local function syncUiFromSession(sess)
  refreshSvGrid(sess)
  refreshPreview(sess)
end

local function stopPreviewWait()
  if previewWait then
    Wait.stop(previewWait)
    previewWait = nil
  end
end

local function scheduleLivePreview(sess)
  stopPreviewWait()
  if not sess then return end
  previewWait = Wait.time(function()
    previewWait = nil
    local r, g, b = sessionRgb(sess)
    seatColors[sess.seat] = { r = r, g = g, b = b }
    applySeatCosmetics(sess.seat)
  end, PREVIEW_DEBOUNCE)
end

local function restoreSeatBaseline(sess)
  if not sess then return end
  if sess.baseline then
    seatColors[sess.seat] = {
      r = sess.baseline.r, g = sess.baseline.g, b = sess.baseline.b
    }
    applySeatCosmetics(sess.seat)
  else
    seatColors[sess.seat] = nil
    applySeatCosmetics(sess.seat, true)
  end
end

local function openPicker(player)
  local seat = player.color
  if not isSeatColor(seat) then
    local seats = table.concat(availableSeatList(), ', ')
    player.broadcast('Sit at a player seat to change color. Available: '..seats, {1, 0.5, 0.3})
    return
  end
  if uiOwner and uiOwner ~= seat and sessions[uiOwner] then
    stopPreviewWait()
    restoreSeatBaseline(sessions[uiOwner])
    sessions[uiOwner] = nil
  end
  local r, g, b = getSeatRgb(seat)
  local h, s, v = rgbToHsv(r, g, b)
  local baseline = nil
  if seatColors[seat] then
    baseline = { r = seatColors[seat].r, g = seatColors[seat].g, b = seatColors[seat].b }
  end
  sessions[seat] = { seat = seat, h = h, s = s, v = v, baseline = baseline }
  uiOwner = seat
  hideOpenButton()
  whenUiReady(function()
    if UI.getAttribute('seatColorPickerRoot', 'id') == nil then
      installScreenUi()
    end
    whenUiReady(function()
      UI.setAttribute('seatColorPickerRoot', 'visibility', seat)
      UI.show('seatColorPickerRoot')
      syncUiFromSession(sessions[seat])
    end)
  end)
end

local function hidePickerPanel()
  pcall(function()
    UI.hide('seatColorPickerRoot')
  end)
  showOpenButton()
end

local function closePicker(player)
  local seat = player and player.color or uiOwner
  local sess = seat and sessions[seat]
  stopPreviewWait()
  if sess and not sess.applied then
    restoreSeatBaseline(sess)
  end
  if seat then sessions[seat] = nil end
  if uiOwner == seat then
    uiOwner = nil
    hidePickerPanel()
  end
end

------------------------------------------------------------------------
-- UI callbacks
------------------------------------------------------------------------

function onSvClick(player, value, id)
  local sess = getSession(player)
  if not sess then return end
  local row, col = id:match('sv_(%d+)_(%d+)')
  row, col = tonumber(row), tonumber(col)
  if not row or not col then return end
  sess.s = (SV_COLS <= 1) and 0 or (col / (SV_COLS - 1))
  sess.v = (SV_ROWS <= 1) and 1 or (1 - row / (SV_ROWS - 1))
  refreshPreview(sess)
  scheduleLivePreview(sess)
end

function onHueStripClick(player, value, id)
  local sess = getSession(player)
  if not sess then return end
  local idx = id:match('hue_(%d+)')
  idx = tonumber(idx)
  if not idx then return end
  sess.h = (idx / HUE_STEPS) * 360
  refreshSvGrid(sess)
  refreshPreview(sess)
  scheduleLivePreview(sess)
end

function onHueChanged(player, value, id)
  local sess = getSession(player)
  if not sess then return end
  sess.h = tonumber(value) or sess.h
  if sess.h >= 360 then sess.h = 0 end
  refreshSvGrid(sess)
  refreshPreview(sess)
  scheduleLivePreview(sess)
end

function onHexEdit(player, value, id)
  local sess = getSession(player)
  if not sess then return end
  local r, g, b = hexToRgb(value)
  if not r then
    player.broadcast('Invalid hex. Use #RRGGBB.', {1, 0.4, 0.3})
    refreshPreview(sess)
    return
  end
  local h, s, v = rgbToHsv(r, g, b)
  sess.h, sess.s, sess.v = h, s, v
  syncUiFromSession(sess)
  scheduleLivePreview(sess)
end

function onCopyHex(player, value, id)
  local sess = getSession(player)
  if not sess then return end
  local r, g, b = sessionRgb(sess)
  local hex = rgbToHex(r, g, b)
  player.print('Seat color hex: '..hex, { r, g, b })
  player.broadcast('Copied '..hex..' to chat (TTS has no system clipboard).', {0.7, 0.9, 1})
end

function onResetColor(player, value, id)
  local sess = getSession(player)
  if not sess then return end
  local hadCustom = seatColors[sess.seat] ~= nil or sess.baseline ~= nil
  seatColors[sess.seat] = nil
  sess.baseline = nil
  sess.applied = true
  updateSave()
  local r, g, b = defaultSeatRgb(sess.seat)
  local h, s, v = rgbToHsv(r, g, b)
  sess.h, sess.s, sess.v = h, s, v
  lastBorderSig = nil
  applySeatCosmetics(sess.seat, hadCustom)
  scheduleReapply()
  syncUiFromSession(sess)
  player.broadcast('Cleared custom tint for '..sess.seat..' (stock board).', {0.8, 0.8, 0.8})
end

function onApplyColor(player, value, id)
  local sess = getSession(player)
  if not sess then return end
  stopPreviewWait()
  local r, g, b = sessionRgb(sess)
  seatColors[sess.seat] = { r = r, g = g, b = b }
  sess.baseline = { r = r, g = g, b = b }
  sess.applied = true
  updateSave()
  applySeatCosmetics(sess.seat)
  scheduleReapply()
  local hex = rgbToHex(r, g, b)
  player.broadcast('Applied '..hex..' to '..sess.seat..' mat & widgets (engine seat unchanged).', { r, g, b })
  sessions[sess.seat] = nil
  uiOwner = nil
  hidePickerPanel()
end

function onClosePicker(player, value, id)
  closePicker(player)
end

function onEngineSwap(player, value, id)
  local target = id and id:match('^engine_(%a+)$')
  if not target then return end
  local seat = player.color
  if not isSeatColor(seat) then
    player.broadcast('Sit at a player seat to change engine color.', {1, 0.5, 0.3})
    return
  end
  local ok, err = canSwapTo(seat, target)
  if not ok then
    player.broadcast(err, {1, 0.5, 0.3})
    return
  end
  -- Close first: the session and panel visibility are keyed to the old color.
  closePicker(player)
  performSwap(seat, target)
  local r, g, b = defaultSeatRgb(target)
  broadcastToAll(seat..' → '..target..' (chat/list + mat). Use Apply anytime for a custom mat color.', { r, g, b })
end

function onEngineRevert(player, value, id)
  local seat = player.color
  local origin = originOf(seat)
  if not origin then
    player.broadcast('This seat is already its original color.', {0.8, 0.8, 0.8})
    return
  end
  local ok, err = canSwapTo(seat, origin)
  if not ok then
    player.broadcast(err, {1, 0.5, 0.3})
    return
  end
  closePicker(player)
  performSwap(seat, origin)
  broadcastToAll('Seat reverted to '..origin..'.', {0.8, 0.8, 0.8})
end

-- External trigger (e.g. UGD-PURPLE object): swap a SteamID's seat like the
-- engine palette buttons. params = { steam_id = '...', target = 'Purple' }
local function playerBySteamId(steamId)
  if not steamId or steamId == '' then return nil end
  local sid = tostring(steamId)
  for _, p in ipairs(Player.getPlayers()) do
    if p and tostring(p.steam_id or '') == sid then
      return p
    end
  end
  return nil
end

function forceEngineSwapSteam(params)
  params = params or {}
  local steamId = params.steam_id
  local target = params.target or 'Purple'
  local player = playerBySteamId(steamId)
  if not player then return end
  local seat = player.color
  if not isSeatColor(seat) then
    player.broadcast('Sit at a player seat to change engine color.', {1, 0.5, 0.3})
    return
  end
  if seat == target then
    player.broadcast('You already are '..target..'.', {0.8, 0.8, 0.8})
    return
  end
  local ok, err = canSwapTo(seat, target)
  if not ok then
    player.broadcast(err, {1, 0.5, 0.3})
    return
  end
  if uiOwner == seat then
    closePicker(player)
  end
  performSwap(seat, target)
  local r, g, b = defaultSeatRgb(target)
  broadcastToAll(seat..' → '..target..' (chat/list + mat). Use Apply anytime for a custom mat color.', { r, g, b })
end

function forceEngineRevertSteam(params)
  params = params or {}
  local player = playerBySteamId(params.steam_id)
  if not player then return end
  local seat = player.color
  if not isSeatColor(seat) then
    player.broadcast('Sit at a player seat to revert engine color.', {1, 0.5, 0.3})
    return
  end
  local origin = originOf(seat)
  if not origin then
    player.broadcast('This seat is already its original color.', {0.8, 0.8, 0.8})
    return
  end
  local ok, err = canSwapTo(seat, origin)
  if not ok then
    player.broadcast(err, {1, 0.5, 0.3})
    return
  end
  if uiOwner == seat then
    closePicker(player)
  end
  performSwap(seat, origin)
  broadcastToAll('Seat reverted to '..origin..'.', {0.8, 0.8, 0.8})
end

--[[ Calibration UI disabled
function onOpenCal(player, value, id)
  ensureCalPreview(player)
  rebuildSeatBorders(true)
  local mode = seatPixelToWorldFromZones(player.color) and 'deck/GY zones' or 'hand fallback'
  player.broadcast('Mat align mode: '..mode, {0.7, 0.9, 1})
  whenUiReady(function()
    if UI.getAttribute('seatColorCalRoot', 'id') == nil then
      installScreenUi()
    end
    whenUiReady(function()
      UI.setAttribute('seatColorCalRoot', 'visibility', player.color)
      UI.show('seatColorCalRoot')
      refreshCalUi()
    end)
  end)
end

function onCloseCal(player, value, id)
  pcall(function() UI.hide('seatColorCalRoot') end)
end

function onCalNudge(player, value, id)
  -- TTS Button onClick often passes value=-1; the element id carries the key.
  -- Lua patterns have no | alternation — match Dec/Inc separately.
  local dir, key
  if type(id) == 'string' then
    key = id:match('^calDec_(%w+)$')
    if key then
      dir = '-'
    else
      key = id:match('^calInc_(%w+)$')
      if key then dir = '+' end
    end
  end
  if not key or matCal[key] == nil then
    player.broadcast('Cal nudge failed (value='..tostring(value)..' id='..tostring(id)..')', {1, 0.4, 0.3})
    return
  end
  local step = CAL_STEP
  if key == 'borderY' or key == 'lineThickness' then
    step = CAL_STEP_FINE
  elseif key == 'arcSteps' then
    step = 1
  end
  if dir == '-' then step = -step end
  if key == 'arcSteps' then
    matCal[key] = math.max(1, math.floor(matCal[key] + step + 0.5))
  else
    matCal[key] = math.floor((matCal[key] + step) * 1000 + 0.5) / 1000
  end
  applyCalLive(player)
  player.broadcast(key..' = '..formatCalNum(key, matCal[key]), {0.7, 0.9, 1})
end

function onCalToggle(player, value, id)
  local key = type(id) == 'string' and id:match('^calBool_(%w+)$') or nil
  if not key or matCal[key] == nil then
    player.broadcast('Cal toggle failed (value='..tostring(value)..' id='..tostring(id)..')', {1, 0.4, 0.3})
    return
  end
  matCal[key] = not matCal[key]
  applyCalLive(player)
  player.broadcast(key..' = '..tostring(matCal[key]), {0.7, 0.9, 1})
end

function onCalPrint(player, value, id)
  local lines = {
    '-- Paste into seat-color-picker.lua matCal = { ... }',
    string.format('  centerFwd = %.2f,', matCal.centerFwd),
    string.format('  centerRight = %.2f,', matCal.centerRight),
    string.format('  worldW = %.2f,', matCal.worldW),
    string.format('  worldH = %.2f,', matCal.worldH),
    string.format('  rot180 = %s,', tostring(matCal.rot180)),
    string.format('  flipX = %s,', tostring(matCal.flipX)),
    string.format('  flipZ = %s,', tostring(matCal.flipZ)),
    string.format('  borderY = %.3f,', matCal.borderY),
    string.format('  lineThickness = %.3f,', matCal.lineThickness),
    string.format('  arcSteps = %d,', math.floor(matCal.arcSteps + 0.5)),
    string.format('  scale = %.2f,', matCal.scale),
    string.format('  offsetRight = %.2f,', matCal.offsetRight),
    string.format('  offsetFwd = %.2f,', matCal.offsetFwd),
  }
  for _, line in ipairs(lines) do
    player.print(line, {0.7, 0.9, 1})
  end
  player.broadcast('Calibration values printed to chat.', {0.7, 0.9, 1})
end

]]

function clickOpenPicker(obj, color, alt)
  local player = Player[color]
  if not player then return end
  if alt then
    if not isSeatColor(color) then
      player.broadcast('Sit at a player seat to reset color.', {1, 0.5, 0.3})
      return
    end
    local hadCustom = seatColors[color] ~= nil
    if sessions[color] then
      hadCustom = hadCustom or sessions[color].baseline ~= nil
      sessions[color].applied = true
      sessions[color] = nil
      if uiOwner == color then
        uiOwner = nil
        hidePickerPanel()
      end
    end
    seatColors[color] = nil
    updateSave()
    lastBorderSig = nil
    applySeatCosmetics(color, hadCustom)
    scheduleReapply()
    if not uiOwner then
      showOpenButton()
    end
    player.broadcast('Cleared custom tint for '..color..' (stock board).', {0.8, 0.8, 0.8})
    return
  end
  openPicker(player)
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

function onLoad(data)
  self.setName('Seat Color Picker')
  self.setDescription(
    'Click: open on-screen color UI. Right-click: clear your seat tint.\n'..
    'Apply: custom mat tint. Engine seat buttons: chat/list + mat in that color.\n'..
    'Nothing is drawn until you Apply or pick an engine seat color.'
  )
  loadSave(data)
  -- Drop any leftover object-attached UI from older script versions.
  pcall(function() self.UI.setXml('') end)
  showOpenButton()
  whenUiReady(function()
    installScreenUi()
  end)
  -- Global rebuilds `data` / `deckDirs` with stock seat keys on every load;
  -- restore our engine-swap aliases once it has settled (retry a few times).
  if next(swaps) then
    for _, d in ipairs({ 1, 3, 6 }) do
      Wait.time(reapplySwapAliases, d)
    end
  end
  Wait.time(function()
    -- Force once: our vector loops persist in the save; resync with state.
    rebuildSeatBorders(true)
    applyAllSeatCosmetics()
    if next(seatColors) then
      end
  end, 1)
  scheduleReapply({ 1.5, 4 })
end

function onPlayerTurn(player)
  -- Widgets may reset seat chrome on turn change; re-apply after a short delay.
  scheduleReapply({ 0.05, 0.2, 0.6 })
end

function onPlayerChangeColor(player)
  scheduleReapply({ 0.3, 1, 2 })
end

function onPlayerConnect(player)
  scheduleReapply({ 0.5, 1.5, 3 })
end

function onObjectDrop(player_color, obj)
  if not obj or not next(seatColors) then return end
  local n = (obj.getName() or ''):lower()
  if n:find('rhystic') or (n:find('commander') and n:find('damage')) then
    scheduleReapply({ 0.05, 0.3 })
  end
end

function onObjectSpawn(obj)
  if not obj or not next(seatColors) then return end
  local kind = widgetKind(obj)
  if kind then
    scheduleReapply({ 0.2, 1 })
  end
end
