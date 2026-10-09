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
  local reason = lossReason(p) or p.lossForced
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
  if Triggers and Triggers.onLife then
    Triggers.onLife(color, delta)
  end
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

-- A card says this player loses the game ("each player with exactly 13
-- life"): flagged for the players to confirm or dismiss on the tracker.
function Trackers.flagLoss(color, reason)
  local p = player(color)
  if p == nil or p.eliminated then
    return
  end
  p.lossForced = reason
  p.lossFlag = reason
  p.lossDismissed = nil
  broadcastToAll(color .. " has " .. reason .. "! Confirm or dismiss on their tracker.", WARN)
  Trackers.render(color)
end

function Trackers.confirmLoss(color, byColor)
  local p = player(color)
  if p == nil or p.lossFlag == nil then
    return
  end
  p.eliminated = true
  broadcastToAll(color .. " is out of the game (" .. p.lossFlag .. ").", WARN)
  if p.contract then
    broadcastToAll(color .. " had a contract counter: " .. tostring(p.contract) .. " creates a token that's a copy of each artifact and creature " .. color .. " controlled (by hand).", { 1, 0.75, 0.3 })
  end
  p.lossFlag = nil
  p.lossForced = nil
  Trackers.render(color)
  -- Last player standing: the game is over; save the log.
  local left = {}
  for _, c in ipairs(TableSetup.activeSeats()) do
    local q = player(c)
    if q and not q.eliminated then
      table.insert(left, c)
    end
  end
  if #left <= 1 and GameLog then
    GameLog.add("GAME", "========== GAME OVER ========== winner: " .. tostring(left[1]))
    GameLog.snapshot("game over")
    GameLog.write()
  end
end

function Trackers.dismissLoss(color, byColor)
  local p = player(color)
  if p == nil or p.lossFlag == nil then
    return
  end
  log(byColor, color .. "'s loss check dismissed (" .. p.lossFlag .. ")")
  p.lossDismissed = p.lossFlag
  p.lossFlag = nil
  p.lossForced = nil
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
local SOLID_TEXT_ALPHA = 100

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

-- An image tile has loaded: size it to its area (width w), lay it on the
-- table there, then draw its buttons.
local function tileReady(obj, color, regionName, width, draw)
  local b = obj.getBoundsNormalized()
  local w = b and b.size and b.size.x or 0
  if w < 0.05 then
    -- Image not measured yet; try again shortly.
    Wait.time(function() if not obj.isDestroyed() then tileReady(obj, color, regionName, width, draw) end end, 0.5)
    return
  end
  local k = width / (w / obj.getScale().x)
  obj.setScale({ k, 1, k })
  local r = TableSetup.region(color, regionName)
  local thick = obj.getBoundsNormalized().size.y
  obj.setPosition({ r.center.x, TableSetup.SURFACE_TOP + thick / 2 + 0.01, r.center.z })
  obj.setLock(true)
  draw()
  -- Draw again once the tile has settled, in case the first pass came too early.
  Wait.time(draw, 1)
end

-- Spawn an image tile (custom token) for a seat's area.
local function spawnTile(color, regionName, name, url, width, register, draw, tag)
  local r = TableSetup.region(color, regionName)
  local s = TableSetup.seat(color)
  local obj = spawnObject({
    type = "Custom_Token",
    position = { r.center.x, TableSetup.SURFACE_TOP + 0.5, r.center.z },
    -- Same facing as cards at this seat: upright for its player.
    rotation = { 0, s.yaw, 0 },
    scale = { 1, 1, 1 },
    sound = false,
    callback_function = function(o)
      o.setName(name)
      o.addTag(tag or "Tracker")
      o.setLock(true)
      o.interactable = true
      register(o.getGUID())
      Wait.condition(function() tileReady(o, color, regionName, width, draw) end,
        function() return o.isDestroyed() or not o.loading_custom end, 10,
        function() tileReady(o, color, regionName, width, draw) end)
    end,
  })
  obj.setCustomObject({ image = url, thickness = 0.1, merge_distance = 5, stackable = false })
end

-- Commander tax tiles: one above each command zone ("<Color>|1", "<Color>|2").
local TAX_W = 4.2
local TAX_NUMBER_DZ = 0.25   -- the number window sits a little below the title

local function taxTiles()
  GameState.data.table = GameState.data.table or {}
  GameState.data.table.taxTiles = GameState.data.table.taxTiles or {}
  return GameState.data.table.taxTiles
end

-- Make the table's image tiles match what's wanted, keeping tiles that are
-- already there. Spawning a custom token makes TTS rebuild it from its image,
-- which was most of the load time when every tile was respawned on every
-- load; a tile that still exists with the same image is just put back in
-- place and redrawn. A changed image (art version bump) or a seat that's no
-- longer playing (!layout) still gets its tile replaced / removed.
--   tag    the tag these tiles carry (strays with it are removed)
--   groups list of { registry = { key = guid }, wanted = { list of
--          { key, color, region, name, url, width, draw } } }; a group with
--          wanted = nil is left as is (its tiles are only protected from the
--          stray sweep)
function Trackers.syncTiles(tag, groups)
  local keep = {}
  for _, g in ipairs(groups) do
    local want = {}
    for _, w in ipairs(g.wanted or {}) do
      want[w.key] = w
    end
    for key, guid in pairs(g.registry) do
      local obj = guid ~= "spawning" and getObjectFromGUID(guid) or nil
      local co = obj and obj.getCustomObject()
      local w = want[key]
      if obj and (g.wanted == nil or (w and co and co.image == w.url)) then
        keep[guid] = true
      else
        if obj then
          obj.destruct()
        end
        g.registry[key] = nil
      end
    end
  end
  for _, obj in ipairs(getObjectsWithTag(tag)) do
    if not keep[obj.getGUID()] then
      obj.destruct()
    end
  end
  for _, g in ipairs(groups) do
    for _, w in ipairs(g.wanted or {}) do
      local guid = g.registry[w.key]
      local obj = guid and getObjectFromGUID(guid)
      if obj then
        tileReady(obj, w.color, w.region, w.width, w.draw)
      else
        local registry = g.registry
        spawnTile(w.color, w.region, w.name, w.url, w.width,
          function(newGuid) registry[w.key] = newGuid end, w.draw, tag)
      end
    end
  end
end

-- Every active seat's tracker tile and two commander tax tiles.
function Trackers.ensureTableDisplay()
  local t = GameState.data.table or {}
  for _, guid in pairs(t.lifeLabels or {}) do
    local old = getObjectFromGUID(guid)
    if old then
      old.destruct()
    end
  end
  t.lifeLabels = nil

  -- Partner chips stay, except ones for a seat that's no longer playing.
  local chipReg = GameState.data.table.partnerChips or {}
  GameState.data.table.partnerChips = chipReg
  for id, guid in pairs(chipReg) do
    local owner, opp = tostring(id):match("^(%a+)|(%a+)|")
    if not (owner and opp and TableSetup.isActive(owner) and TableSetup.isActive(opp)) then
      local obj = guid ~= "spawning" and getObjectFromGUID(guid) or nil
      if obj then
        obj.destruct()
      end
      chipReg[id] = nil
    end
  end
  local trackers, taxes = {}, {}
  for _, color in ipairs(TableSetup.activeSeats()) do
    table.insert(trackers, { key = color, color = color, region = "tracker", name = color .. " tracker",
      url = imageFor(color), width = TILE_W, draw = function() Trackers.render(color) end })
    for slot = 1, 2 do
      table.insert(taxes, { key = color .. "|" .. slot, color = color, region = "tax" .. slot,
        name = color .. " commander tax " .. slot, url = ICON_BASE .. "tax_" .. color .. ".png" .. ICON_VERSION,
        width = TAX_W, draw = function() Trackers.renderTax(color, slot) end })
    end
  end
  Trackers.syncTiles("Tracker", {
    { registry = tiles(), wanted = trackers },
    { registry = taxTiles(), wanted = taxes },
    -- Partner chips are kept; Trackers.render adds / removes them as needed.
    { registry = GameState.data.table.partnerChips },
  })
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
  -- TTS fades a button's text along with a fully see-through background.
  -- A text alpha far above 1 keeps the text solid (found by testing; the
  -- other scripted MTG table uses the same trick).
  if (params.color[4] or 1) == 0 then
    local f = params.font_color
    params.font_color = { f[1], f[2], f[3], SOLID_TEXT_ALPHA }
  end
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
  if tile == nil or p == nil then
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
  local usedChips = {}
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
        -- Partner / background: its own small crown tile beside the first.
        usedChips[color .. "|" .. c.key] = true
        Trackers.partnerChip(color, c.key, c.seat, CROWN_X[2], z, function(chip)
          outlined(chip, tostring(dmg), 0, 0, 240, fontColor, click, tip, 600, 600)
        end)
      end
    end
  end
  Trackers.dropUnusedChips(color, usedChips)
end

---------------------------------------------------------------------------
-- Partner crown chips: a small crown tile on a tracker for an opponent's
-- second commander (partner or background), with its own damage number.
---------------------------------------------------------------------------

local CHIP_W = 1.3

local function chips()
  GameState.data.table = GameState.data.table or {}
  GameState.data.table.partnerChips = GameState.data.table.partnerChips or {}
  return GameState.data.table.partnerChips
end

function Trackers.partnerChip(color, key, oppSeat, x, z, draw)
  local id = color .. "|" .. key
  local guid = chips()[id]
  if guid == "spawning" then
    return
  end
  local chip = guid and getObjectFromGUID(guid)
  if chip and not chip.loading_custom then
    chip.clearButtons()
    draw(chip)
    return
  end
  if chip then
    return   -- still loading; it draws itself when ready
  end
  local r = TableSetup.region(color, "tracker")
  local s = TableSetup.seat(color)
  -- Tile coordinates: x to the player's right, z toward the player.
  local px = r.center.x + s.right.x * x - s.inward.x * z
  local pz = r.center.z + s.right.z * x - s.inward.z * z
  chips()[id] = "spawning"
  local obj = spawnObject({
    type = "Custom_Token",
    position = { px, TableSetup.SURFACE_TOP + 0.6, pz },
    rotation = { 0, s.yaw, 0 },
    sound = false,
    callback_function = function(o)
      o.setName(oppSeat .. " partner commander damage")
      o.addTag("Tracker")
      o.setLock(true)
      chips()[id] = o.getGUID()
      Wait.condition(function()
        local b = o.getBoundsNormalized()
        local k = CHIP_W / math.max(0.05, b.size.x / o.getScale().x)
        o.setScale({ k, 1, k })
        o.setPosition({ px, TableSetup.SURFACE_TOP + 0.2 + o.getBoundsNormalized().size.y / 2, pz })
        Trackers.render(color)
      end, function() return o.isDestroyed() or not o.loading_custom end, 10)
    end,
  })
  obj.setCustomObject({ image = ICON_BASE .. "tracker_crownchip_" .. oppSeat .. ".png" .. ICON_VERSION,
    thickness = 0.1, merge_distance = 5, stackable = false })
end

function Trackers.dropUnusedChips(color, used)
  for id, guid in pairs(chips()) do
    if id:sub(1, #color + 1) == color .. "|" and not used[id] then
      local obj = getObjectFromGUID(guid)
      if obj then
        obj.destruct()
      end
      chips()[id] = nil
    end
  end
end

---------------------------------------------------------------------------
-- Commander tax
-- Each command zone has its own tax (commander tax is per commander):
-- +2 every time that commander is cast from the command zone. The table adds
-- it automatically when the commander goes from its command zone onto the
-- battlefield; click the tile for +2 / right-click for -2 to correct it.
---------------------------------------------------------------------------

local function taxOf(p)
  p.commanderTax = p.commanderTax or { 0, 0 }
  p.commanderTax[1] = p.commanderTax[1] or 0
  p.commanderTax[2] = p.commanderTax[2] or 0
  return p.commanderTax
end

function Trackers.renderTax(color, slot)
  local guid = taxTiles()[color .. "|" .. slot]
  local tile = guid and getObjectFromGUID(guid)
  local p = player(color)
  if tile == nil or p == nil then
    return
  end
  tile.clearButtons()
  local tax = taxOf(p)[slot]
  local role = (p.commanderRoles and p.commanderRoles[slot]) or (slot == 1 and "COMMANDER" or "PARTNER")
  local name = p.commanderNames[slot] or (slot == 1 and "your commander" or "your partner / background")
  -- Which commander this tax belongs to (shown once a deck is imported).
  if p.commanderNames[slot] then
    outlined(tile, role, 0, -0.1, 110, { 0.35, 0.94, 1 }, "trk_noop", name, 0, 0)
  end
  outlined(tile, tostring(tax), 0, TAX_NUMBER_DZ + 0.12, 360, INK,
    handler("trk_" .. color .. "_tax" .. slot,
      function(pc, alt) Trackers.changeTax(color, slot, alt and -2 or 2, pc) end),
    "Commander tax for " .. name .. " (" .. role:lower() .. "): click +2, right-click -2", 900, 520)
end

function Trackers.changeTax(color, slot, delta, byColor, reason)
  local p = player(color)
  if p == nil then
    return
  end
  local tax = taxOf(p)
  local before = tax[slot]
  tax[slot] = math.max(0, before + delta)
  if tax[slot] == before then
    return
  end
  local name = p.commanderNames[slot] or (color .. "'s " .. (slot == 1 and "commander" or "partner"))
  log(byColor, name .. " commander tax " .. before .. " -> " .. tax[slot] .. (reason and (" (" .. reason .. ")") or ""))
  Trackers.renderTax(color, slot)
end

-- A commander went from its command zone onto the battlefield: it was cast
-- (as far as the table can tell), so its tax goes up by 2.
Events.on("cardMoved", function(d)
  if d.card == nil or d.from == nil or d.to == nil then
    return
  end
  if d.from.region ~= "command" or (d.to.region ~= "battlefield" and d.to.region ~= "lands") then
    return
  end
  local guid = d.card.getGUID()
  for _, color in ipairs(TableSetup.activeSeats()) do
    local p = player(color)
    for slot, g in pairs(p and p.commanders or {}) do
      if g == guid then
        Trackers.changeTax(color, math.min(slot, 2), 2, nil, "cast from the command zone; right-click the tax to undo")
        return
      end
    end
  end
end)

-- Shared with other modules (actions.lua) that put image tiles on the table.
Trackers.spawnTile = spawnTile
Trackers.tileButton = button

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
      if i <= 12 and b.width and b.width > 0 then table.insert(labels, "'" .. tostring(b.label) .. "'") end
    end
    local sc = obj.getScale()
    local b = obj.getBoundsNormalized()
    print(string.format("   %s [%s] %s type %s at (%.1f, %.2f, %.1f) scale %.2f thick %.2f loading %s, %d buttons: %s",
      obj.getName(), obj.getGUID(), registered[obj.getGUID()] and "registered" or "NOT registered",
      tostring(obj.type), p.x, p.y, p.z, sc.x, b and b.size.y or -1, tostring(obj.loading_custom),
      #buttons, table.concat(labels, " ")))
  end
end

function Trackers.renderAll()
  for _, color in ipairs(TableSetup.activeSeats()) do
    Trackers.render(color)
    Trackers.renderTax(color, 1)
    Trackers.renderTax(color, 2)
  end
end
