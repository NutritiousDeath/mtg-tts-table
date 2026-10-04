--[[
  trackers.lua
  Life, poison and commander damage for every seat, plus loss checks, shown
  on a clickable tracker tile in front of each player's playmat.

  The tile (facing its player, readable by everyone around the table):
      (drop)  [-]   ( heart: 40 )   [+]   (crown)(crown)
                                          (crown)(crown)
      - Life number: click +1, right-click -1. -/+: click 1, right-click 5.
      - Green drop: poison, click +1, right-click -1.
      - Crowns: commander damage from each opposing commander, tinted in that
        seat's color, count on the crown: click +1, right-click -1.
      Icons are images drawn on the tile with invisible buttons over them.
  When a loss is flagged the tile shows Confirm / Dismiss; when a player is
  out it shows an Undo button.

  Data (GameState players):
    life, poison
    commanderDamage["<seat>|<commander name>"] = damage taken from that commander
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

-- Every opposing commander a seat can take damage from:
-- list of { key = "<seat>|<name>", seat, name }.
local function opposingCommanders(color)
  local list = {}
  for _, other in ipairs(TableSetup.activeSeats()) do
    if other ~= color then
      local op = player(other)
      for _, name in ipairs(op and op.commanderNames or {}) do
        table.insert(list, { key = other .. "|" .. name, seat = other, name = name })
      end
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
      return COMMANDER_LETHAL .. " commander damage from " .. (key:match("|(.+)$") or key)
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
  log(byColor, color .. " commander damage from " .. (key:match("|(.+)$") or key) .. " "
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
-- Each tile is a locked block mostly sunk into the table (so it looks flat)
-- with buttons on top. Buttons use the block's local space, so the block is
-- kept at scale 1 and the visible tile outline comes from the playmat lines.
---------------------------------------------------------------------------

local TILE_SINK = 0.45    -- block center sits this far below the surface
local BUTTON_Y = 0.52     -- local height of buttons (just above the surface)
-- Rows in the tile's local depth. With the tile turned to the seat's angle
-- and buttons turned 180, local -z is toward the player (the bottom of the
-- text). If the rows ever appear swapped in TTS, swap these two numbers.
local LIFE_ROW_Z = 0.5
local COUNTER_ROW_Z = -1.4

local function tiles()
  GameState.data.table = GameState.data.table or {}
  GameState.data.table.trackerTiles = GameState.data.table.trackerTiles or {}
  return GameState.data.table.trackerTiles
end

local function tileFor(color)
  local guid = tiles()[color]
  return guid and getObjectFromGUID(guid) or nil
end

-- Create (or re-place) each active seat's tile; remove tiles of seats that
-- left the layout, and the old life numbers from version 0.17.
function Trackers.ensureTableDisplay()
  local t = GameState.data.table or {}
  for _, guid in pairs(t.lifeLabels or {}) do
    local old = getObjectFromGUID(guid)
    if old then
      old.destruct()
    end
  end
  t.lifeLabels = nil

  for color, guid in pairs(tiles()) do
    if not TableSetup.isActive(color) then
      local obj = getObjectFromGUID(guid)
      if obj then
        obj.destruct()
      end
      tiles()[color] = nil
    end
  end

  for _, color in ipairs(TableSetup.activeSeats()) do
    local r = TableSetup.region(color, "tracker")
    local s = TableSetup.seat(color)
    local pos = { r.center.x, TableSetup.SURFACE_TOP - TILE_SINK, r.center.z }
    -- Same facing as the mat labels, which read correctly from the seat.
    local rot = { 0, s.angle, 0 }
    local tile = tileFor(color)
    if tile then
      tile.setPosition(pos)
      tile.setRotation(rot)
      Trackers.render(color)
    else
      spawnObject({
        type = "BlockSquare",
        position = pos,
        rotation = rot,
        scale = { 1, 1, 1 },
        callback_function = function(obj)
          obj.setLock(true)
          obj.setName(color .. " tracker")
          obj.setColorTint(PANEL)
          obj.addTag("Tracker")
          tiles()[color] = obj.getGUID()
          Trackers.render(color)
        end,
      })
    end
  end
end

-- Register a click handler under a global name (buttons call functions by name).
local function handler(name, fn)
  _G[name] = function(obj, playerColor, altClick)
    fn(playerColor, altClick)
  end
  return name
end

local function button(tile, params)
  params.function_owner = Global
  params.position = { params.x or 0, BUTTON_Y, params.z or 0 }
  params.x, params.z = nil, nil
  params.rotation = { 0, 180, 0 }
  params.font_color = params.font_color or INK
  params.color = params.color or PANEL
  tile.createButton(params)
end

-- Icons drawn on the tile (decals), from the repo's assets/icons folder.
local ICON_BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/icons/"
local CLEAR = { 0, 0, 0, 0 }   -- invisible button background (icon shows through)

-- Tile layout in local units (tile is 14 wide x 4.8 deep; -z is toward the player).
local HEART = { x = 0, z = 0, size = 4.2 }
local MINUS_X, PLUS_X = -3.1, 3.1
local POISON_SLOT = { x = -5.0, z = 0 }
local CROWN_SLOTS = {
  { x = 4.8, z = 0.85 }, { x = 6.25, z = 0.85 }, { x = 4.8, z = -0.85 }, { x = 6.25, z = -0.85 },
  { x = -6.4, z = 0.85 }, { x = -6.4, z = -0.85 },
}
local ICON_SIZE = 1.4

local function decal(name, file, x, z, size)
  return {
    name = name,
    url = ICON_BASE .. file,
    position = { x, BUTTON_Y - 0.015, z },
    -- Flat, upright for the seat (same orientation as the mat labels).
    rotation = { 90, 0, 0 },
    scale = { size, size, 1 },
  }
end

-- Redraw one seat's tile from its current values.
function Trackers.render(color)
  local tile = tileFor(color)
  local p = player(color)
  if tile == nil or p == nil then
    return
  end
  tile.clearButtons()
  local tint = SEAT_TINT[color] or INK
  local key = "trk_" .. color .. "_"
  local decals = {}

  if p.eliminated then
    tile.setDecals({})
    button(tile, { label = "OUT", click_function = handler(key .. "noop", function() end),
      width = 1600, height = 700, font_size = 520, font_color = WARN, z = 0.5 })
    button(tile, { label = "Undo: back in game", tooltip = "Misclicked? Bring this player back.",
      click_function = handler(key .. "revive", function(pc) Trackers.revive(color, pc) end),
      width = 2200, height = 360, font_size = 200, z = -1.4 })
    return
  end

  -- Heart with the life total inside.
  table.insert(decals, decal("heart", "tracker_heart.png", HEART.x, HEART.z, HEART.size))
  button(tile, { label = tostring(p.life), tooltip = "Life: click +1, right-click -1",
    click_function = handler(key .. "life", function(pc, alt) Trackers.changeLife(color, alt and -1 or 1, pc) end),
    width = 1500, height = 1300, font_size = 620, color = CLEAR,
    font_color = p.lossFlag and WARN or INK, x = HEART.x, z = HEART.z + 0.15 })
  button(tile, { label = "-", tooltip = "Life -1 (right-click: -5)",
    click_function = handler(key .. "minus", function(pc, alt) Trackers.changeLife(color, alt and -5 or -1, pc) end),
    width = 520, height = 520, font_size = 480, font_color = tint, x = MINUS_X, z = HEART.z })
  button(tile, { label = "+", tooltip = "Life +1 (right-click: +5)",
    click_function = handler(key .. "plus", function(pc, alt) Trackers.changeLife(color, alt and 5 or 1, pc) end),
    width = 520, height = 520, font_size = 480, font_color = tint, x = PLUS_X, z = HEART.z })

  if p.lossFlag then
    -- Loss waiting for a decision: show Confirm / Dismiss under the heart
    -- instead of the counters.
    tile.setDecals(decals)
    button(tile, { label = "Confirm loss", tooltip = p.lossFlag,
      click_function = handler(key .. "confirm", function(pc) Trackers.confirmLoss(color, pc) end),
      width = 1300, height = 330, font_size = 190, font_color = WARN, x = -4.2, z = -1.9 })
    button(tile, { label = "Dismiss", tooltip = "Not a loss (e.g. a replacement effect applies)",
      click_function = handler(key .. "dismiss", function(pc) Trackers.dismissLoss(color, pc) end),
      width = 1000, height = 330, font_size = 190, x = 4.5, z = -1.9 })
    return
  end

  -- Poison: green drop with the count on it.
  table.insert(decals, decal("poison", "tracker_poison.png", POISON_SLOT.x, POISON_SLOT.z, ICON_SIZE))
  button(tile, { label = tostring(p.poison), tooltip = "Poison: click +1, right-click -1",
    click_function = handler(key .. "poison", function(pc, alt) Trackers.changePoison(color, alt and -1 or 1, pc) end),
    width = 700, height = 700, font_size = 300, color = CLEAR, x = POISON_SLOT.x, z = POISON_SLOT.z - 0.15 })

  -- Commander damage: a crown in each opposing seat's color, count on top.
  for i, c in ipairs(opposingCommanders(color)) do
    local slot = CROWN_SLOTS[i]
    if slot then
      local dmg = p.commanderDamage[c.key] or 0
      table.insert(decals, decal("crown" .. i, "tracker_crown_" .. c.seat .. ".png", slot.x, slot.z, ICON_SIZE))
      button(tile, { label = tostring(dmg),
        tooltip = "Commander damage from " .. c.name .. " (" .. c.seat .. "): click +1, right-click -1",
        click_function = handler(key .. "cmd" .. i,
          function(pc, alt) Trackers.changeCommanderDamage(color, c.key, alt and -1 or 1, pc) end),
        width = 700, height = 700, font_size = 280, color = CLEAR,
        font_color = dmg >= COMMANDER_LETHAL - 5 and WARN or INK, x = slot.x, z = slot.z - 0.1 })
    end
  end
  tile.setDecals(decals)
end

function Trackers.renderAll()
  for _, color in ipairs(TableSetup.activeSeats()) do
    Trackers.render(color)
  end
end
