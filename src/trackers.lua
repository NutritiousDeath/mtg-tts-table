--[[
  trackers.lua
  Life, poison and commander damage for every seat, plus loss checks, shown
  on a clickable tracker tile in front of each player's playmat.

  The tile (facing its player, readable by everyone around the table):
                                          (crown)   <- opponent 1
      (drop)  [-]   ( heart: 40 )   [+]   (crown)   <- opponent 2
                                          (crown)   <- opponent 3
      Crown order per seat (CROWN_ORDER): Blue: White, Red, Green;
      White: Blue, Green, Red; Red: Blue, Green, White; Green: Blue, White, Red.
      (a partner commander adds a second crown on its opponent's row)
      - Life number: click +1, right-click -1. -/+: click 1, right-click 5.
      - Green drop: poison, click +1, right-click -1.
      - Crowns: commander damage from each opposing commander, tinted in that
        seat's color, count on the crown: click +1, right-click -1.
      The tile is one image per seat (tools/make_tracker_art.py), numbers are
      outlined invisible buttons over it.
  When a loss is flagged the tile shows Confirm / Dismiss; when a player is
  out it shows an Undo button.

  Data (GameState players):
    life, poison
    commanderDamage["<seat>|<slot>"] = damage taken from that seat's commander
      (slot 1 = their commander, 2 = a partner)
    commanderNames = names of the seat's own commander(s), set on import
    eliminated, lossFlag (reason waiting to be confirmed),
    lossDismissed (reason the players dismissed, so it isn't re-flagged)

  Rules applied:
    - Commander damage also reduces life (it's combat damage).
    - Loss checks: 0 or less life, 10+ poison, or 21+ damage from a single
      commander. The table flags it; players confirm or dismiss. It never
      eliminates anyone on its own.
  Every change is logged to chat with who made it.
--]]

Trackers = {}

local POISON_LETHAL = 10
local COMMANDER_LETHAL = 21

-- Button tints per seat (also used for commander damage counters).
local SEAT_TINT = {
  White = { 0.78, 0.80, 0.86 },
  Red = { 0.86, 0.33, 0.33 },
  Green = { 0.32, 0.76, 0.42 },
  Blue = { 0.32, 0.58, 0.95 },
}
local PANEL = { 0.09, 0.11, 0.15 }
local INK = { 0.92, 0.95, 1 }
local WARN = { 1, 0.42, 0.42 }

---------------------------------------------------------------------------
-- Data helpers
---------------------------------------------------------------------------

local function player(color)
  local p = GameState.player(color)
  if p then
    p.commanderDamage = p.commanderDamage or {}
    p.commanderNames = p.commanderNames or {}
  end
  return p
end

-- Top-to-bottom order of the commander damage crowns on each seat's tracker
-- (each crown is the color of the opponent whose commander it tracks).
local CROWN_ORDER = {
  Blue = { "White", "Red", "Green" },
  White = { "Blue", "Green", "Red" },
  Red = { "Blue", "Green", "White" },
  Green = { "Blue", "White", "Red" },
}

-- Opponents of a seat in crown order (seats not in the layout are skipped).
local function opponentsInOrder(color)
  local list = {}
  for _, other in ipairs(CROWN_ORDER[color] or TableSetup.activeSeats()) do
    if other ~= color and TableSetup.isActive(other) then
      table.insert(list, other)
    end
  end
  return list
end

-- Commander damage is keyed by the opponent's seat and commander slot:
-- "<seat>|1" for their commander, "<seat>|2" for a partner. That way every
-- opponent always has a crown, even before they've imported a deck.

-- Display name for a damage key: the commander's name once known.
local function commanderLabel(key)
  local seat, slot = key:match("^(%a+)|(%d+)$")
  if seat == nil then
    return key
  end
  local op = player(seat)
  local name = op and op.commanderNames[tonumber(slot)]
  return name or (seat .. "'s commander")
end

-- Every opposing commander a seat can take damage from, in crown order:
-- list of { key, seat, name }. One per opponent, two if they have partners.
local function opposingCommanders(color)
  local list = {}
  for _, other in ipairs(opponentsInOrder(color)) do
    local op = player(other)
    local count = math.max(1, #(op and op.commanderNames or {}))
    for slot = 1, count do
      local key = other .. "|" .. slot
      table.insert(list, { key = key, seat = other, name = commanderLabel(key) })
    end
  end
  return list
end

---------------------------------------------------------------------------
-- Loss checks
---------------------------------------------------------------------------

local function lossReason(p)
  if p.life <= 0 then
    return "0 life"
  end
  if p.poison >= POISON_LETHAL then
    return POISON_LETHAL .. " poison"
  end
  for key, dmg in pairs(p.commanderDamage) do
    if dmg >= COMMANDER_LETHAL then
      return COMMANDER_LETHAL .. " commander damage from " .. commanderLabel(key)
    end
  end
  return nil
end

local function checkLoss(color)
  local p = player(color)
  if p == nil or p.eliminated then
    return
  end
  local reason = lossReason(p)
  if reason == nil then
    p.lossFlag, p.lossDismissed = nil, nil
  elseif reason ~= p.lossFlag and reason ~= p.lossDismissed then
    p.lossFlag = reason
    broadcastToAll(color .. " has " .. reason .. "! Confirm or dismiss on their tracker.", WARN)
  end
end

---------------------------------------------------------------------------
-- Changing values (every change goes through here)
---------------------------------------------------------------------------

local function log(byColor, msg)
  printToAll("MTG > " .. msg .. (byColor and (" (by " .. byColor .. ")") or ""), { 0.75, 0.8, 0.9 })
end

function Trackers.changeLife(color, delta, byColor)
  local p = player(color)
  if p == nil or delta == 0 then
    return
  end
  local before = p.life
  p.life = p.life + delta
  log(byColor, color .. " life " .. before .. " -> " .. p.life)
  checkLoss(color)
  Trackers.render(color)
end

function Trackers.changePoison(color, delta, byColor)
  local p = player(color)
  if p == nil then
    return
  end
  local before = p.poison
  p.poison = math.max(0, p.poison + delta)
  if p.poison == before then
    return
  end
  log(byColor, color .. " poison " .. before .. " -> " .. p.poison)
  checkLoss(color)
  Trackers.render(color)
end

-- Commander damage also reduces (or, when undone, restores) life.
function Trackers.changeCommanderDamage(color, key, delta, byColor)
  local p = player(color)
  if p == nil then
    return
  end
  local before = p.commanderDamage[key] or 0
  local after = math.max(0, before + delta)
  local applied = after - before
  if applied == 0 then
    return
  end
  p.commanderDamage[key] = after
  p.life = p.life - applied
  log(byColor, color .. " commander damage from " .. commanderLabel(key) .. " "
    .. before .. " -> " .. after .. ", life " .. (p.life + applied) .. " -> " .. p.life)
  checkLoss(color)
  Trackers.render(color)
end

function Trackers.confirmLoss(color, byColor)
  local p = player(color)
  if p == nil or p.lossFlag == nil then
    return
  end
  p.eliminated = true
  broadcastToAll(color .. " is out of the game (" .. p.lossFlag .. ").", WARN)
  p.lossFlag = nil
  Trackers.render(color)
end

function Trackers.dismissLoss(color, byColor)
  local p = player(color)
  if p == nil or p.lossFlag == nil then
    return
  end
  log(byColor, color .. "'s loss check dismissed (" .. p.lossFlag .. ")")
  p.lossDismissed = p.lossFlag
  p.lossFlag = nil
  Trackers.render(color)
end

-- Bring an eliminated player back (misclick safety).
function Trackers.revive(color, byColor)
  local p = player(color)
  if p == nil or not p.eliminated then
    return
  end
  p.eliminated = false
  log(byColor, color .. " is back in the game")
  Trackers.render(color)
end

---------------------------------------------------------------------------
-- Tracker tiles
-- Each seat's tile is a custom token whose image is the whole tracker (plate,
-- heart, poison drop, -/+ rings and that seat's crowns, in its crown order),
-- built by tools/make_tracker_art.py. Numbers are invisible buttons on top,
-- outlined by drawing the number 8 times in black, nudged in each direction,
-- under the white one. (Drawing the icons as decals instead hid button text.)
---------------------------------------------------------------------------

local ICON_BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/icons/"
-- Bump when the tracker images change, so TTS downloads them again instead
-- of showing its cached copy.
local ICON_VERSION = "?v=4"

-- Tile size on the table (same as the "tracker" playmat area) and the image
-- layout, in table units: x to the player's right, z toward the player.
-- Must match tools/make_tracker_art.py.
local TILE_W = 14
local HEART = { x = 0, z = 0 }
local POISON_NUMBER_DZ = 0.18     -- the drop's dark center sits a little below its middle
local POISON_SLOT = { x = -5.0, z = 0 }
local PLUS_MINUS_X = 3.1
local CROWN_X = { 4.7, 6.15 }     -- column 2 = a partner commander (no art; drawn as a chip)
local CROWN_ROWS = { [1] = { 0 }, [2] = { -0.75, 0.75 }, [3] = { -1.45, 0, 1.45 } }

local BUTTON_Y = 0.12             -- just above the token's surface (local units)
local OUTLINE_PER_FONT = 0.00008  -- outline offset (table units) per point of font size
local BLACK = { 0, 0, 0 }
local HOVER = { 1, 1, 1, 0.06 }
local INVISIBLE = { 0, 0, 0, 0 }

local function tiles()
  GameState.data.table = GameState.data.table or {}
  GameState.data.table.trackerTiles = GameState.data.table.trackerTiles or {}
  return GameState.data.table.trackerTiles
end

local function tileFor(color)
  local guid = tiles()[color]
  return guid and getObjectFromGUID(guid) or nil
end

local function imageFor(color)
  return ICON_BASE .. "tracker_bg_" .. TableSetup.layout() .. "_" .. color .. ".png" .. ICON_VERSION
end

-- The token has loaded its image: size it to the tracker area, then draw.
local function tileReady(color, obj)
  local b = obj.getBoundsNormalized()
  local w = b and b.size and b.size.x or 0
  if w < 0.05 then
    -- Image not measured yet; try again shortly.
    Wait.time(function() if not obj.isDestroyed() then tileReady(color, obj) end end, 0.5)
    return
  end
  local k = TILE_W / (w / obj.getScale().x)
  obj.setScale({ k, 1, k })
  local r = TableSetup.region(color, "tracker")
  local thick = obj.getBoundsNormalized().size.y
  obj.setPosition({ r.center.x, TableSetup.SURFACE_TOP + thick / 2 + 0.01, r.center.z })
  obj.setLock(true)
  Trackers.render(color)
end

-- Spawn every active seat's tile fresh (old tiles, including the block
-- tiles from earlier versions, are removed first).
function Trackers.ensureTableDisplay()
  local t = GameState.data.table or {}
  for _, guid in pairs(t.lifeLabels or {}) do
    local old = getObjectFromGUID(guid)
    if old then
      old.destruct()
    end
  end
  t.lifeLabels = nil

  for _, obj in ipairs(getObjectsWithTag("Tracker")) do
    obj.destruct()
  end
  for color, guid in pairs(tiles()) do
    local obj = getObjectFromGUID(guid)
    if obj then
      obj.destruct()
    end
    tiles()[color] = nil
  end

  for _, color in ipairs(TableSetup.activeSeats()) do
    local r = TableSetup.region(color, "tracker")
    local s = TableSetup.seat(color)
    local obj = spawnObject({
      type = "Custom_Token",
      position = { r.center.x, TableSetup.SURFACE_TOP + 0.5, r.center.z },
      -- Same facing as cards at this seat: upright for its player.
      rotation = { 0, s.yaw, 0 },
      scale = { 1, 1, 1 },
      sound = false,
      callback_function = function(o)
        o.setName(color .. " tracker")
        o.addTag("Tracker")
        o.setLock(true)
        o.interactable = true
        tiles()[color] = o.getGUID()
        Wait.condition(function() tileReady(color, o) end,
          function() return o.isDestroyed() or not o.loading_custom end, 10,
          function() tileReady(color, o) end)
      end,
    })
    obj.setCustomObject({ image = imageFor(color), thickness = 0.1, merge_distance = 5, stackable = false })
  end
end

-- Register a click handler under a global name (buttons call functions by name).
local function handler(name, fn)
  _G[name] = function(obj, playerColor, altClick)
    fn(playerColor, altClick)
  end
  return name
end
function trk_noop() end

-- A button at a spot in table units on the tile (x right, z toward player).
-- Positions and sizes are corrected for the tile's scale, so sizes mean the
-- same as on an unscaled object.
local function button(tile, params, x, z)
  local k = tile.getScale().x
  params.function_owner = Global
  params.position = { x / k, BUTTON_Y, z / k }
  params.rotation = { 0, 0, 0 }
  params.scale = { 1 / k, 1, 1 / k }
  params.font_color = params.font_color or INK
  params.color = params.color or PANEL
  tile.createButton(params)
end

-- A number with a black outline: 8 black copies around it, then the real
-- (clickable) button on top. Only the top one has a click area.
local function outlined(tile, label, x, z, fontSize, fontColor, click, tip, w, h)
  local d = fontSize * OUTLINE_PER_FONT
  for _, o in ipairs({ { -1, -1 }, { 0, -1 }, { 1, -1 }, { -1, 0 }, { 1, 0 }, { -1, 1 }, { 0, 1 }, { 1, 1 } }) do
    button(tile, { label = label, click_function = "trk_noop", width = 0, height = 0,
      font_size = fontSize, font_color = BLACK, color = INVISIBLE }, x + o[1] * d, z + o[2] * d)
  end
  button(tile, { label = label, click_function = click, tooltip = tip, width = w, height = h,
    font_size = fontSize, font_color = fontColor, color = INVISIBLE, hover_color = HOVER }, x, z)
end

-- Redraw one seat's tile from its current values.
function Trackers.render(color)
  local tile = tileFor(color)
  local p = player(color)
  if tile == nil or p == nil or tile.loading_custom then
    return
  end
  tile.clearButtons()
  local tint = SEAT_TINT[color] or INK
  local key = "trk_" .. color .. "_"

  if p.eliminated then
    outlined(tile, "OUT", HEART.x, HEART.z, 650, WARN, "trk_noop", "Out of the game", 0, 0)
    button(tile, { label = "Undo: back in game", tooltip = "Misclicked? Bring this player back.",
      click_function = handler(key .. "revive", function(pc) Trackers.revive(color, pc) end),
      width = 1600, height = 300, font_size = 180 }, 0, 1.9)
    return
  end

  -- Life in the heart, with -/+ in the rings beside it.
  outlined(tile, tostring(p.life), HEART.x, HEART.z, 650, p.lossFlag and WARN or INK,
    handler(key .. "life", function(pc, alt) Trackers.changeLife(color, alt and -1 or 1, pc) end),
    "Life: click +1, right-click -1", 1400, 1000)
  outlined(tile, "-", -PLUS_MINUS_X, 0, 420, tint,
    handler(key .. "minus", function(pc, alt) Trackers.changeLife(color, alt and -5 or -1, pc) end),
    "Life -1 (right-click: -5)", 440, 440)
  outlined(tile, "+", PLUS_MINUS_X, 0, 420, tint,
    handler(key .. "plus", function(pc, alt) Trackers.changeLife(color, alt and 5 or 1, pc) end),
    "Life +1 (right-click: +5)", 440, 440)

  if p.lossFlag then
    -- Loss waiting for a decision: Confirm / Dismiss along the bottom edge.
    button(tile, { label = "Confirm loss", tooltip = p.lossFlag,
      click_function = handler(key .. "confirm", function(pc) Trackers.confirmLoss(color, pc) end),
      width = 1100, height = 280, font_size = 170, font_color = WARN }, -4.2, 1.9)
    button(tile, { label = "Dismiss", tooltip = "Not a loss (e.g. a replacement effect applies)",
      click_function = handler(key .. "dismiss", function(pc) Trackers.dismissLoss(color, pc) end),
      width = 900, height = 280, font_size = 170 }, 4.2, 1.9)
    return
  end

  -- Poison on the drop.
  outlined(tile, tostring(p.poison), POISON_SLOT.x, POISON_SLOT.z + POISON_NUMBER_DZ, 300,
    p.poison >= POISON_LETHAL - 3 and WARN or INK,
    handler(key .. "poison", function(pc, alt) Trackers.changePoison(color, alt and -1 or 1, pc) end),
    "Poison: click +1, right-click -1", 700, 700)

  -- Commander damage: one crown per opponent (row), in this seat's crown
  -- order; a partner commander gets a chip in the second column.
  local list = opposingCommanders(color)
  local rowOf, colInRow, seats = {}, {}, 0
  for _, c in ipairs(list) do
    if rowOf[c.seat] == nil then
      seats = seats + 1
      rowOf[c.seat] = seats
    end
  end
  local rowsZ = CROWN_ROWS[seats] or CROWN_ROWS[3]
  for i, c in ipairs(list) do
    colInRow[c.seat] = (colInRow[c.seat] or 0) + 1
    local col, z = colInRow[c.seat], rowsZ[rowOf[c.seat]]
    if z and CROWN_X[col] then
      local dmg = p.commanderDamage[c.key] or 0
      local tip = "Commander damage from " .. c.name .. " (" .. c.seat .. "): click +1, right-click -1"
      local click = handler(key .. "cmd" .. i,
        function(pc, alt) Trackers.changeCommanderDamage(color, c.key, alt and -1 or 1, pc) end)
      local fontColor = dmg >= COMMANDER_LETHAL - 5 and WARN or INK
      if col == 1 then
        outlined(tile, tostring(dmg), CROWN_X[1], z, 280, fontColor, click, tip, 640, 560)
      else
        local t = SEAT_TINT[c.seat] or INK
        button(tile, { label = tostring(dmg), tooltip = tip, click_function = click,
          width = 380, height = 320, font_size = 230, font_color = BLACK,
          color = { t[1], t[2], t[3], 0.9 } }, CROWN_X[2], z)
      end
    end
  end
end

-- Debug (!trackers): every tracker tile on the table.
function Trackers.report()
  local registered = {}
  for color, guid in pairs(tiles()) do
    registered[guid] = color
  end
  local found = getObjectsWithTag("Tracker")
  print("MTG > Tracker tiles on the table: " .. #found)
  for _, obj in ipairs(found) do
    local p = obj.getPosition()
    local buttons = obj.getButtons() or {}
    local labels = {}
    for i, b in ipairs(buttons) do
      if i <= 4 then table.insert(labels, "'" .. tostring(b.label) .. "'") end
    end
    print(string.format("   %s [%s] %s at (%.1f, %.2f, %.1f), %d buttons: %s",
      obj.getName(), obj.getGUID(), registered[obj.getGUID()] and "registered" or "NOT registered",
      p.x, p.y, p.z, #buttons, table.concat(labels, " ")))
  end
end

function Trackers.renderAll()
  for _, color in ipairs(TableSetup.activeSeats()) do
    Trackers.render(color)
  end
end
