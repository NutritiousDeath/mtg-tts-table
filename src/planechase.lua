--[[
  planechase.lua
  Planechase for the table. A stone treasure chest (the table frame's stone)
  sits in the empty corner between White and Blue. Its lid has two buttons:

    UNPACK   shuffle the planar deck (all planes and Phenomena) into the
             middle of the table, turn the first plane face up and put the
             planar die out beside the chest
    PACK UP  put the planar deck, the plane and the die away

  UNPACK also lays out the PLANAR LIBRARY and PLANAR GRAVE mats west of the
  stack mat (the plane sits between them) and the dice tower east of it. A
  plane you planeswalk away from goes face up on the grave; when the library
  runs out, the grave is shuffled into a new library.

  Roll the planar die down the tower (drop it in the top, or right-click it >
  Roll, or !planechase roll): it rides down inside while the tower's lights run
  in the roller's colour, and rolls out of the dragon on the roller's side; the
  result counts when it settles on the dragon's tongue. The table watches it: the first roll each turn is free, every extra
  roll costs one more mana than the last; a planeswalk or chaos result is
  carried out by itself. Right-click the plane card > Planeswalk for effects
  that say "planeswalk".

  The table does the rest: the old plane goes to the planar grave and the
  next card turns face up; "When you planeswalk to ..." and
  "Whenever chaos ensues ..." abilities go on the stack; a Phenomenon
  triggers and then you planeswalk away from it by itself; Chaotic Aether
  turns blank rolls into chaos until a player planeswalks away from a plane.
  The planes' always-on abilities (static ones and "At the beginning of ...")
  are printed in the chat when a plane turns up: players apply those.

  Chat: !planechase  (help), !planechase unpack | pack | roll | walk | turn
        ("turn" swaps which way the plane cards face, if they read upside down)

  Plane pictures: Scryfall's planar images are sideways (turned 90 degrees
  inside the picture), which makes TTS's zoom show them sideways. Upright
  copies go in assets/planechase/cards (tools/rotate_planes.html makes them).
  UNPACK checks for them: with them the cards are landscape and zoom upright;
  without them the sideways pictures are used (they still read right on the
  table, just not in the zoom).

  Cards come from planechase_data.lua (tools/make_planechase_data.py).
--]]

Planechase = {}

local BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/planechase/"
local STONE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/table/stone.png?v=3"
local VERSION = "?v=1"
local DIE_IMAGE = "https://i.imgur.com/ptrUeHV.jpg"

local CHEST = { x = 38, z = -38, yaw = 135 }       -- between White (south) and Blue (east)
-- Two-Headed Giant: the corners are seats' battlefields, so the chest goes at the east end of the
-- open band down the middle of the table (between the two teams).
local CHEST_2HG = { x = 46, z = 0, yaw = 90 }

local function chestSpot()
  if TableSetup.layout and TableSetup.layout() == "twohg" then
    return CHEST_2HG
  end
  return CHEST
end
-- West of the stack mat, north to south: the planar library and the planar grave on their mats, the plane
-- between them. A mat's card area is MAT_OFF south of the mat's middle (tools/make_planar_mats.py).
local MAT_OFF = 0.46
local MAT_W = 5.4
local LIB_MAT = { x = -8.5, z = 5.3 }
local GRAVE_MAT = { x = -8.5, z = -4.6 }
local DECK_AT = { x = -8.5, z = LIB_MAT.z - MAT_OFF }
local PLANE_AT = { x = -8.5, z = 0.1 }
local GRAVE_AT = { x = -8.5, z = GRAVE_MAT.z - MAT_OFF }
-- East of the stack mat: the dice tower (assets/planechase/mtg_dicetower.unity3d, built by
-- tools/unity/MTGDiceTowerBuilder.cs). TOWER is the middle of the round tower. Inside are two spiral slides wound
-- round a column: spiral A comes out of a stone dragon's mouth to the north, spiral B out of a second dragon to
-- the south. There's one planar die: it goes down the side nearest whoever rolls it (SIDE_OF) and comes out of
-- that side's dragon; both dragons breathe fire.
local TOWER = { x = 8.5, z = 0 }
local TOWER_URL = BASE .. "mtg_dicetower.unity3d?v=14"
local TOWER_TOP = 19.8          -- where a die is dropped in (through the deck's hole), above the table
local HEADS = {
  -- Offsets from TOWER: the dragon's x, which way it faces (z), and the hole its spiral is dropped in by.
  A = { x = -1.85, dir = 1, dropX = -1.97, dropZ = 0.72 },
  B = { x = 1.85, dir = -1, dropX = 1.97, dropZ = -0.72 },
}
local REST_ALONG = 11.0         -- how far out along its dragon's tongue a die rests
local DIE_EDGE = 1.0            -- the planar dice are sized to this (they have to fit the dragons' throats)
-- The dragon each seat's rolls come out of (the one facing / nearest them).
local SIDE_OF = { White = "B", Blue = "B", Green = "A", Red = "A" }
-- Effects: looping 0-4 idle and 5-9 rolling in a colour (0 = cyan, then White, Red, Green, Blue);
-- trigger 0-4 the dragons breathe in that colour, 5 chaos (purple), 6 planeswalk (blue-white).
local TOWER_IDX = { White = 1, Red = 2, Green = 3, Blue = 4 }
local TOWER_ROLLING = 5
local TOWER_CHAOS, TOWER_WALK = 5, 6
local towerRolling = false
local CARD_SCALE_UPRIGHT, CARD_SCALE_SIDEWAYS = 1.4, 1.6
local YAW_UPRIGHT, YAW_SIDEWAYS = 180, 270   -- upright landscape pictures / sideways Scryfall ones
local ID_BASE = 31000
local INFO, GOOD, WARN = { 0.75, 0.8, 0.9 }, { 0.3, 1, 0.6 }, { 1, 0.6, 0.2 }
local CYAN = { 0.35, 0.95, 1 }

local byName = {}
local busy = false
local putDie   -- defined below

local function data()
  local d = GameState.data
  d.planechase = d.planechase or {}
  return d.planechase
end

local function upright()
  return data().upright == true
end

local function yaw()
  return ((upright() and YAW_UPRIGHT or YAW_SIDEWAYS) + (data().flip and 180 or 0)) % 360
end

local function cardScale()
  return upright() and CARD_SCALE_UPRIGHT or CARD_SCALE_SIDEWAYS
end

local function slug(name)
  local s2 = tostring(name):lower():gsub("[^a-z0-9]+", "-"):gsub("^%-", ""):gsub("%-$", "")
  return s2
end

local CARDS_VERSION = "?v=1"

local function faceUrl(c)
  if upright() then
    return BASE .. "cards/" .. slug(c.n) .. ".jpg" .. CARDS_VERSION
  end
  -- Scryfall blocks TTS's image downloader: go through the relay like the importer.
  local host = (Importer and Importer.relayHost and Importer.relayHost() ~= "" and Importer.relayHost()) or "img.klrmngr.com"
  return (c.u:gsub("cards%.scryfall%.io", host))
end

local function backUrl()
  if upright() then
    return BASE .. "back.png" .. "?v=2"
  end
  return PLANECHASE_BACK
end

local function say(msg, color)
  printToAll("MTG > PLANECHASE: " .. msg, color or INFO)
end

local function spotOf(p)
  return { x = p.x, y = TableSetup.SURFACE_TOP + 0.5, z = p.z }
end

local function dist(obj, p)
  local o = obj.getPosition()
  return math.abs(o.x - p.x) + math.abs(o.z - p.z)
end

-- Planar cards and piles on the table: the deck is whatever sits at the
-- deck spot, the plane is the face-up card at the plane spot.
local function nearest(at, kind)
  local best, bestD = nil, 3
  for _, o in ipairs(getObjectsWithTag("PlanarCard")) do
    if not o.isDestroyed() and (kind == nil or o.type == kind or (kind == "pile" and (o.type == "Deck" or o.type == "Card"))) then
      local d = dist(o, at)
      if d < bestD then
        best, bestD = o, d
      end
    end
  end
  return best
end

local function findDeck()
  return nearest(DECK_AT, "pile")
end

local function findPlane()
  local o = nearest(PLANE_AT, "Card")
  return o
end

local function findGrave()
  return nearest(GRAVE_AT, "pile")
end

local function entryOf(obj)
  return obj and byName[obj.getName()] or nil
end

---------------------------------------------------------------------------
-- The cards
---------------------------------------------------------------------------

local function buildIndex()
  byName = {}
  for _, c in ipairs(PLANECHASE_CARDS or {}) do
    byName[c.n] = c
  end
end

local function cardData(c, i)
  local id = ID_BASE + i
  return {
    Name = "Card",
    Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = yaw(), rotZ = 180, scaleX = 1, scaleY = 1, scaleZ = 1 },
    Nickname = c.n,
    Description = c.o,
    GMNotes = JSON.encode({ planar = true, name = c.n, type = c.t }),
    CardID = id * 100,
    CustomDeck = {
      [tostring(id)] = { FaceURL = faceUrl(c), BackURL = backUrl(), NumWidth = 1, NumHeight = 1,
        BackIsHidden = true, UniqueBack = false, Type = 0 },
    },
    Tags = { "PlanarCard" },
  }
end

-- A deck's data, whether the object is a deck or a lone card.
local function asDeckData(obj)
  local d = obj.getData()
  if obj.type == "Deck" then
    return d
  end
  return { Name = "Deck", Transform = d.Transform, Nickname = "Planar Deck", DeckIDs = { d.CardID },
    CustomDeck = d.CustomDeck, ContainedObjects = { d }, Tags = { "PlanarCard" } }
end

local function finishDeck(o, name)
  if o and not o.isDestroyed() then
    o.setName(name or "Planar Deck")
    o.setScale({ cardScale(), 1, cardScale() })
    o.addTag("PlanarCard")
  end
end

-- Put a card on the bottom of the planar deck (one rebuild).
local function putBottom(deckObj, card, cb, name)
  local d = asDeckData(deckObj)
  local cd = card.getData()
  table.insert(d.ContainedObjects, cd)
  table.insert(d.DeckIDs, cd.CardID)
  for k, v in pairs(cd.CustomDeck or {}) do
    d.CustomDeck[k] = v
  end
  local pos, rot = deckObj.getPosition(), deckObj.getRotation()
  card.destruct()
  deckObj.destruct()
  spawnObjectData({ data = d, position = pos, rotation = rot,
    callback_function = function(o)
      finishDeck(o, name)
      if cb then cb(o) end
    end })
end

-- Take the top card and lay it face up on the plane spot.
local function planeMenu(card)
  pcall(function()
    card.clearContextMenu()
    card.addContextMenuItem("Planeswalk", function(color) Planechase.planeswalk(color) end)
  end)
end

local function turnTop(deckObj, cb)
  local function taken(card)
    card.setScale({ cardScale(), 1, cardScale() })
    card.addTag("PlanarCard")
    planeMenu(card)
    -- Make sure it rests on the table.
    Wait.time(function()
      if not card.isDestroyed() then
        pcall(function()
          card.use_gravity = true
          card.setLock(false)
        end)
      end
    end, 0.4)
    if cb then cb(card) end
  end
  if deckObj.type == "Deck" then
    deckObj.takeObject({ position = spotOf(PLANE_AT), rotation = { 0, yaw(), 0 }, smooth = false,
      callback_function = taken })
  else
    deckObj.setPosition(spotOf(PLANE_AT))
    deckObj.setRotation({ 0, yaw(), 0 })
    taken(deckObj)
  end
end

---------------------------------------------------------------------------
-- What a plane says
---------------------------------------------------------------------------

local function lines(text)
  local out = {}
  for line in tostring(text or ""):gmatch("[^\n]+") do
    table.insert(out, line)
  end
  return out
end

local function afterComma(line)
  local clean = Triggers and Triggers.stripReminder and Triggers.stripReminder(line) or line
  return clean:match("^[^,]+,%s*(.+)$")
end

-- The chaos ability of a plane card ("Whenever chaos ensues, ...").
local function chaosOf(card)
  local e = entryOf(card)
  for _, l in ipairs(lines(e and e.o)) do
    if l:lower():find("^whenever chaos ensues") then
      return afterComma(l)
    end
  end
  return nil
end

-- Lines of a plane card that the table puts on the stack itself (chaos, planeswalking to / away, rolling):
-- left out of what the trigger reader watches for (triggers.lua treats the face-up plane as a permanent).
local HANDLED = { "^whenever chaos ensues", "^when you planeswalk to", "^whenever you planeswalk to", "^when you encounter",
  "^when you planeswalk away from", "^whenever you planeswalk away from", "^whenever you roll the planar die",
  "^whenever you roll a blank on the planar die" }

-- The face-up plane (not a Phenomenon), or nil.
function Planechase.currentPlane()
  local p = findPlane()
  if p == nil or p.isDestroyed() or p.is_face_down then
    return nil
  end
  local e = entryOf(p)
  if e == nil or e.t == "Phenomenon" then
    return nil
  end
  return p
end

-- A plane's rules text for the trigger reader: everything except the lines handled here.
function Planechase.triggerText(name)
  if next(byName) == nil then
    buildIndex()
  end
  local e = byName and byName[name]
  if e == nil then
    return ""
  end
  local keep = {}
  for _, l in ipairs(lines(e.o)) do
    local low = l:lower()
    local handled = false
    for _, pat in ipairs(HANDLED) do
      handled = handled or low:find(pat) ~= nil
    end
    if not handled then
      table.insert(keep, l)
    end
  end
  return table.concat(keep, "\n")
end

-- The plane's own lines that start with one of these (for the plane in play).
local function linesStarting(card, heads)
  local out = {}
  local e = entryOf(card)
  for _, l in ipairs(lines(e and e.o)) do
    local low = l:lower()
    for _, h in ipairs(heads) do
      if low:find(h) then
        table.insert(out, l)
      end
    end
  end
  return out
end

local function activeSeat(fallback)
  local t = GameState.data.turn
  return (t and t.activeSeat) or fallback or "White"
end

local function push(seat, name, text, planar)
  if Stack and text and text ~= "" then
    Stack.pushAbility(seat, name, text, nil, { trigger = true, planar = planar })
  end
end

-- A plane or Phenomenon has just turned face up.
local function arrived(card, color, started)
  local e = entryOf(card)
  local name = card.getName()
  if e == nil then
    say("a card turned up that isn't in the list: " .. name, WARN)
    return
  end
  local seat = activeSeat(color)
  if e.t == "Phenomenon" then
    say(color .. " encounters the Phenomenon " .. name .. ".", CYAN)
  else
    say(color .. (started and " starts on " or " planeswalks to ") .. name .. ".", CYAN)
  end
  for _, l in ipairs(lines(e.o)) do
    printToAll("      " .. l, INFO)
  end
  if started then
    return
  end
  for _, l in ipairs(lines(e.o)) do
    local low = l:lower()
    if low:find("^when you planeswalk to") or low:find("^whenever you planeswalk to") then
      push(seat, name, afterComma(l))
    elseif low:find("^when you encounter") then
      push(seat, name, afterComma(l))
      if name == "Chaotic Aether" then
        data().aether = true
        say("Chaotic Aether: blank rolls count as chaos until a player planeswalks away from a plane.", WARN)
      end
    end
  end
  if e.t == "Phenomenon" then
    -- Planeswalk away again once its ability is done.
    Wait.condition(function()
      local now = findPlane()
      if now and now.getName() == name then
        say("planeswalking away from " .. name .. ".", INFO)
        Planechase.planeswalk(color, true)
      end
    end, function() return Stack.isEmpty() end, 300)
  end
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local removeExtras, ensureExtras   -- the mats and the dice tower (below)

local function clearTable()
  if removeExtras then
    removeExtras()
  end
  for _, o in ipairs(getObjectsWithTag("PlanarCard")) do
    if not o.isDestroyed() then
      o.destruct()
    end
  end
  for _, tag in ipairs({ "PlanarDie", "PlanarDieTwin" }) do
    for _, o in ipairs(getObjectsWithTag(tag)) do
      if not o.isDestroyed() then
        o.destruct()
      end
    end
  end
end

function Planechase.build(color)
  if busy then
    return
  end
  if findDeck() or findPlane() or findGrave() then
    broadcastToColor("The planar deck is already out. Click PACK UP first to put it away.", color, WARN)
    return
  end
  buildIndex()
  local st = data()
  if not st.probed then
    -- Are the upright pictures on GitHub yet?
    busy = true
    local probe = BASE .. "cards/" .. slug((PLANECHASE_CARDS[1] or {}).n) .. ".jpg" .. CARDS_VERSION
    WebRequest.get(probe, function(req)
      busy = false
      st.upright = (not req.is_error) and #tostring(req.text or "") > 2000
      st.probed = true
      say(st.upright and "upright plane pictures found." or "no upright plane pictures yet: using Scryfall's sideways ones (zoom shows them sideways).", INFO)
      Planechase.build(color)
    end)
    return
  end
  local list = {}
  for _, c in ipairs(PLANECHASE_CARDS or {}) do
    if (c.g ~= "who" or st.noWho ~= true) and (c.t ~= "Phenomenon" or st.noPhenomena ~= true) then
      table.insert(list, c)
    end
  end
  if #list < 10 then
    broadcastToColor("A planar deck needs at least 10 cards.", color, WARN)
    return
  end
  for i = #list, 2, -1 do
    local j = math.random(i)
    list[i], list[j] = list[j], list[i]
  end
  -- The first plane is the first plane card: Phenomena above it go to the bottom.
  local first
  for i, c in ipairs(list) do
    if c.t == "Plane" then
      first = i
      break
    end
  end
  for _ = 1, (first or 1) - 1 do
    table.insert(list, table.remove(list, 1))
  end
  local deck = { Name = "Deck", Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = yaw(), rotZ = 180,
      scaleX = cardScale(), scaleY = 1, scaleZ = cardScale() },
    Nickname = "Planar Deck", DeckIDs = {}, CustomDeck = {}, ContainedObjects = {}, Tags = { "PlanarCard" } }
  for i, c in ipairs(list) do
    local cd = cardData(c, i)
    table.insert(deck.DeckIDs, cd.CardID)
    for k, v in pairs(cd.CustomDeck) do
      deck.CustomDeck[k] = v
    end
    table.insert(deck.ContainedObjects, cd)
  end
  busy = true
  Wait.time(function() busy = false end, 20)
  ensureExtras()
  say("shuffling " .. #list .. " planes and Phenomena into the planar deck...")
  spawnObjectData({ data = deck, position = spotOf(DECK_AT), rotation = { 0, yaw(), 180 },
    callback_function = function(o)
      finishDeck(o)
      Wait.time(function()
        turnTop(o, function(card)
          busy = false
          st.aether = false
          arrived(card, color, true)
          putDie()
        end)
      end, 0.8)
    end })
end

-- The plane being left goes face up onto the planar grave (on top); the next card comes off the planar
-- library. When the library is empty, the grave is shuffled into a new library first.
local function toGrave(card, cb)
  pcall(function() card.clearContextMenu() end)
  local grave = findGrave()
  if grave then
    -- A face-up pile shows its last card, so the newest plane goes at the end.
    putBottom(grave, card, cb, "Planar Grave")
    return
  end
  card.setPosition(spotOf(GRAVE_AT))
  card.setRotation({ 0, yaw(), 0 })
  Wait.time(function() if cb then cb(card) end end, 0.3)
end

local function reshuffle(cb)
  local grave = findGrave()
  if grave == nil then
    cb(nil)
    return
  end
  say("the planar library is empty: the planar grave is shuffled into a new planar library.", CYAN)
  grave.setPosition(spotOf(DECK_AT))
  grave.setRotation({ 0, yaw(), 180 })
  if grave.type == "Deck" then
    pcall(function() grave.shuffle() end)
    finishDeck(grave, "Planar Deck")
  end
  Wait.time(function() cb(grave) end, 0.6)
end

function Planechase.planeswalk(color, quiet)
  if busy and not quiet then
    return
  end
  local deck, plane = findDeck(), findPlane()
  if deck == nil and plane == nil and findGrave() == nil then
    broadcastToColor("No planar deck yet: click UNPACK on the Planechase chest.", color, WARN)
    return
  end
  busy = true
  Wait.time(function() busy = false end, 20)
  local st = data()
  local function reveal(d)
    if d == nil then
      busy = false
      broadcastToColor("The planar deck is empty.", color, WARN)
      return
    end
    turnTop(d, function(card)
      busy = false
      arrived(card, color, false)
    end)
  end
  local function goNext()
    local d = findDeck()
    if d then
      reveal(d)
    else
      reshuffle(reveal)
    end
  end
  if plane then
    local e = entryOf(plane)
    -- "When you planeswalk away from ~, ..." goes on the stack.
    for _, l in ipairs(linesStarting(plane, { "^when you planeswalk away from", "^whenever you planeswalk away from" })) do
      push(activeSeat(color), plane.getName(), afterComma(l))
    end
    if e and e.t == "Plane" and st.aether then
      st.aether = false
      say("Chaotic Aether ends.", INFO)
    end
    toGrave(plane, function()
      Wait.time(goNext, 0.5)
    end)
  else
    goNext()
  end
end

local function dieValueText(v, aether)
  if v == 1 then
    return "PLANESWALK"
  elseif v == 6 then
    return "CHAOS"
  elseif aether then
    return "CHAOS (blank, because of Chaotic Aether)"
  end
  return "blank"
end

local function findTagged(tag)
  for _, o in ipairs(getObjectsWithTag(tag)) do
    if not o.isDestroyed() then
      return o
    end
  end
  return nil
end

-- There are two planar dice, one on each dragon's tongue. Either can be picked up and rolled; the other
-- one rolls down the other side of the tower with it.
local function planarDice()
  local out = {}
  for _, tag in ipairs({ "PlanarDie", "PlanarDieTwin" }) do
    for _, o in ipairs(getObjectsWithTag(tag)) do
      if not o.isDestroyed() then
        table.insert(out, o)
      end
    end
  end
  return out
end

local function findDie()
  return planarDice()[1]
end

-- The other planar die (not `die`).
local function findTwin(die)
  for _, o in ipairs(planarDice()) do
    if o ~= die then
      return o
    end
  end
  return nil
end

-- Where a die rests on a dragon's tongue.
local function restSpot(h)
  local hd = HEADS[h]
  return { TOWER.x + hd.x, TableSetup.SURFACE_TOP + 2.2, TOWER.z + hd.dir * REST_ALONG }
end

-- Make a die DIE_EDGE across (whatever size the custom die model comes in).
local function sizeDie(o)
  Wait.condition(function()
    pcall(function()
      local b = o.getBoundsNormalized()
      local w = b and b.size and b.size.x or 0
      if w > 0.05 then
        local k = DIE_EDGE / (w / o.getScale().x)
        o.setScale({ k, k, k })
      end
    end)
    -- Slippery, a little bouncy: it tumbles down the ramps instead of sticking.
    pcall(function()
      o.static_friction = 0.15
      o.dynamic_friction = 0.1
      o.bounciness = 0.35
    end)
  end, function() return o.isDestroyed() or not o.loading_custom end, 10)
end

local function spawnDie(tag, name, at, cb)
  spawnObjectData({
    data = {
      Name = "Custom_Dice",
      Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 0, rotZ = 0, scaleX = 1, scaleY = 1, scaleZ = 1 },
      Nickname = name,
      Description = "Drop it in the top of the dice tower (or right-click > Roll): the other die rolls down the other "
        .. "side with it, and chaos or planeswalk happens by itself. First roll each turn is free, then 1, 2, 3 mana...",
      ColorDiffuse = { r = 1, g = 1, b = 1 },
      CustomImage = { ImageURL = DIE_IMAGE, ImageSecondaryURL = "", ImageScalar = 1, WidthScale = 0,
        CustomDice = { Type = 1 } },
      Tags = { tag },
    },
    position = at,
    callback_function = function(o)
      o.addTag(tag)
      sizeDie(o)
      if cb then cb(o) end
    end,
  })
end

-- The planar die on dragon A's tongue and its twin on dragon B's.
-- Both dice the same: an older twin couldn't be picked up.
local function fixDice()
  local dice = planarDice()
  for _, o in ipairs(dice) do
    if o.hasTag("PlanarDieTwin") then
      o.removeTag("PlanarDieTwin")
      o.addTag("PlanarDie")
      o.setName("Planar Die")
    end
    o.interactable = true
    sizeDie(o)
  end
  return dice
end
Planechase.fixDice = fixDice

-- One planar die (an older table had two: the extra one goes).
putDie = function(cb)
  local dice = fixDice()
  for i = 2, #dice do
    dice[i].destruct()
  end
  if #dice == 0 then
    local t = GameState.data.turn
    spawnDie("PlanarDie", "Planar Die", restSpot(SIDE_OF[t and t.activeSeat or ""] or "B"), cb)
  elseif cb then
    cb(dice[1])
  end
end

---------------------------------------------------------------------------
-- The mats and the dice tower (out while the planar deck is out)
---------------------------------------------------------------------------

local function sizeTile(o, width)
  Wait.condition(function()
    local b = o.getBoundsNormalized()
    local w = b and b.size and b.size.x or 0
    if w > 0.05 then
      local k = width / (w / o.getScale().x)
      o.setScale({ k, 1, k })
    end
    o.setLock(true)
  end, function() return o.isDestroyed() or not o.loading_custom end, 10, function() o.setLock(true) end)
end

local function ensureMat(name, file, at)
  local img = BASE .. file .. VERSION
  for _, o in ipairs(getObjectsWithTag("PlanarMat")) do
    local co = o.getCustomObject()
    if not o.isDestroyed() and o.getName() == name then
      if co and co.image == img then
        o.setLock(true)
        o.setPosition({ at.x, TableSetup.SURFACE_TOP + 0.05, at.z })
        return
      end
      o.destruct()
    end
  end
  local obj = spawnObject({
    type = "Custom_Token",
    position = { at.x, TableSetup.SURFACE_TOP + 0.05, at.z },
    rotation = { 0, 180, 0 },
    sound = false,
    callback_function = function(o)
      o.setName(name)
      o.addTag("PlanarMat")
      sizeTile(o, MAT_W)
    end,
  })
  obj.setCustomObject({ image = img, thickness = 0.05, merge_distance = 0, stackable = false })
end

local function towerObj()
  for _, o in ipairs(getObjectsWithTag("DiceTower")) do
    if not o.isDestroyed() then
      return o
    end
  end
  return nil
end

local function towerReady(o)
  return o ~= nil and not o.isDestroyed() and not o.loading_custom and o.AssetBundle ~= nil
end

-- The tower's lines in a seat's colour (cyan before the game). Fires.set calls this on every turn change.
local moving = false

-- Put the planar die on the active player's dragon's tongue (lifted over the tower), ready for their roll.
local function dieToSide(color)
  local side = SIDE_OF[color]
  local die = findDie()
  if side == nil or die == nil or die.isDestroyed() or towerRolling or moving or die.held_by_color then
    return
  end
  local p = die.getPosition()
  local hd = HEADS[side]
  local a = (p.z - TOWER.z) * hd.dir
  if math.abs(p.x - (TOWER.x + hd.x)) < 1.3 and a > 7.0 and a < 12.6 then
    return   -- already there
  end
  moving = true
  local dest = restSpot(side)
  die.setLock(true)
  die.setPositionSmooth({ (p.x + dest[1]) / 2, TableSetup.SURFACE_TOP + 23, (p.z + dest[3]) / 2 }, false, false)
  Wait.time(function()
    if not die.isDestroyed() then
      die.setPositionSmooth(dest, false, false)
    end
    Wait.time(function()
      moving = false
      if not die.isDestroyed() then
        die.setLock(false)
      end
    end, 1.0)
  end, 0.9)
end

-- The tower's lines and the dragons' eyes in a seat's colour (purple / cyan before the game), and the die moved
-- to that seat's dragon. Fires.set calls this on every turn change.
function Planechase.towerColor(color)
  local o = towerObj()
  if towerReady(o) and not towerRolling then
    pcall(function() o.AssetBundle.playLoopingEffect(TOWER_IDX[color] or 0) end)
  end
  if o and not towerRolling then
    pcall(dieToSide, color)
  end
end

local function towerLoop(idx)
  local o = towerObj()
  if towerReady(o) then
    pcall(function() o.AssetBundle.playLoopingEffect(idx) end)
  end
end

local function towerFlash(idx)
  local o = towerObj()
  if towerReady(o) then
    pcall(function() o.AssetBundle.playTriggerEffect(idx) end)
  end
end

local function ensureTower()
  local pos = { TOWER.x, TableSetup.SURFACE_TOP + 0.01, TOWER.z }
  for _, o in ipairs(getObjectsWithTag("DiceTower")) do
    local co = o.getCustomObject()
    if not o.isDestroyed() and co and co.assetbundle == TOWER_URL then
      o.setLock(true)
      o.setPosition(pos)
      o.setRotation({ 0, 0, 0 })
      return
    end
    o.destruct()
  end
  local obj = spawnObject({
    type = "Custom_AssetBundle",
    position = pos,
    rotation = { 0, 0, 0 },
    sound = false,
    callback_function = function(o)
      o.setLock(true)
      o.setPosition(pos)
      o.setName("Dice Tower")
      o.setDescription("Drop the planar die in the top (or right-click it > Roll): one die tumbles down each side and "
        .. "out of a dragon's mouth.\n\nDragon head: \"Dragon Head | Retopologized version\" by gozdemrl "
        .. "(sketchfab.com/gozdemrl), CC-BY-4.0.")
      o.addTag("DiceTower")
      Wait.condition(function()
        Planechase.towerColor(Fires and Fires.current and Fires.current() or nil)
      end, function() return towerReady(o) or o.isDestroyed() end, 20)
    end,
  })
  obj.setCustomObject({ assetbundle = TOWER_URL, type = 0 })
end

ensureExtras = function()
  ensureMat("Planar Library", "planar_library.png", LIB_MAT)
  ensureMat("Planar Grave", "planar_grave.png", GRAVE_MAT)
  ensureTower()
end

removeExtras = function()
  for _, tag in ipairs({ "PlanarMat", "DiceTower" }) do
    for _, o in ipairs(getObjectsWithTag(tag)) do
      if not o.isDestroyed() then
        o.destruct()
      end
    end
  end
end

-- How far out along dragon h's tongue a position is (negative = behind the head).
local function along(p, h)
  return (p.z - TOWER.z) * HEADS[h].dir
end

-- Is the die resting on dragon h's tongue (anywhere you can see it, in the open mouth)?
local function onTongue(die, h)
  local p = die.getPosition()
  local a = along(p, h)
  return math.abs(p.x - (TOWER.x + HEADS[h].x)) < 1.1 and a > 7.2 and a < 12.4 and p.y < TableSetup.SURFACE_TOP + 3.4
end

-- Drop a die in the top of chute h, spinning.
local function dropIn(die, h)
  local hd = HEADS[h]
  pcall(function() die.setLock(false) end)
  die.setPosition({ TOWER.x + hd.dropX + (math.random() - 0.5) * 0.4, TableSetup.SURFACE_TOP + TOWER_TOP,
    TOWER.z + hd.dropZ + (math.random() - 0.5) * 0.4 })
  die.setRotation({ math.random(0, 359), math.random(0, 359), math.random(0, 359) })
  die.setVelocity({ 0, -2, 0 })
  die.setAngularVelocity({ math.random(-12, 12), math.random(-12, 12), math.random(-12, 12) })
end

-- Which chute's top a position is over (nil if neither).
local function chuteAt(p)
  local dx, dz = p.x - TOWER.x, p.z - TOWER.z
  if dx * dx + dz * dz > 4.6 * 4.6 or p.y < TableSetup.SURFACE_TOP + 12 then
    return nil
  end
  return dx < 0 and "A" or "B"
end

local towerRoll   -- defined after onRolled
local roll = nil  -- the roll going down the tower: { r = result, done = primary settled, ... }

local rollBy, rolling = nil, false

-- The planar die was rolled (by hand or by !planechase roll).
-- viaTower: the die was dropped down the tower; its result counts once it lands in the tray.
function Planechase.onRolled(die, color, viaTower)
  if die == nil or die.isDestroyed() or not die.hasTag("PlanarDie") or rolling then
    return
  end
  -- Rolled in place (right-click > Roll, or shaken) with the tower out: send it down the tower instead.
  if not viaTower and towerObj() then
    if die.held_by_color then
      return   -- shaken in hand: it counts when it's dropped in the top of the tower
    end
    towerRoll(die, rollBy or color or "White", false)
    rollBy = nil
    return
  end
  color = rollBy or color or "White"
  rollBy = nil
  local st = data()
  local plane = findPlane()
  if plane == nil then
    broadcastToColor("No plane in play: UNPACK the Planechase chest first.", color, WARN)
    return
  end
  local t = GameState.data.turn
  if GameState.data.started and not GameState.solo() and t then
    local problem
    local step = Turns and Turns.STEPS and Turns.STEPS[t.stepIndex or 1]
    if not Turns.isActiveSeat(color) then
      problem = "Only the active player (" .. tostring(t.activeSeat) .. ") rolls the planar die, on their turn."
    elseif step and step.id ~= "main1" and step.id ~= "main2" then
      problem = "Roll the planar die in a main phase, when the stack is empty."
    elseif not Stack.isEmpty() then
      problem = "The stack isn't empty: roll after it resolves."
    end
    if problem then
      say(color .. " rolled the planar die, but it doesn't count. " .. problem, WARN)
      return
    end
  end
  local turn = (t and t.number) or 0
  st.rolls = st.rolls or {}
  if st.rolls.turn ~= turn or st.rolls.seat ~= color then
    st.rolls = { turn = turn, seat = color, n = 0 }
  end
  local cost = st.rolls.n
  st.rolls.n = st.rolls.n + 1
  rolling = true
  local tok = viaTower and roll or nil     -- the roll down the tower this belongs to (its result, when it's done)
  Wait.time(function() rolling = false end, viaTower and 30 or 15)
  say(color .. " rolls the planar die" .. (cost == 0 and " (first roll this turn: free)." or (": pay " .. cost .. " mana for this roll.")), CYAN)
  Wait.condition(function()
    rolling = false
    if die.isDestroyed() then
      return
    end
    local v = (tok and tok.r) or die.getValue()
    say(color .. " rolled: " .. dieValueText(v, st.aether), v == 1 and GOOD or (v == 6 and CYAN or INFO))
    local chaos = v == 6 or (st.aether and v ~= 1)
    -- "Whenever you roll the planar die, ..." / "Whenever you roll a blank, ..." (the plane's own triggers).
    for _, l in ipairs(linesStarting(plane, { "^whenever you roll the planar die" })) do
      push(activeSeat(color), plane.getName(), afterComma(l))
    end
    if v ~= 1 and v ~= 6 then
      for _, l in ipairs(linesStarting(plane, { "^whenever you roll a blank on the planar die" })) do
        push(activeSeat(color), plane.getName(), afterComma(l))
      end
    end
    if v == 1 then
      -- The planeswalker symbol: "Planeswalk" goes on the stack (the ring round the stack mat burns blue-white);
      -- when everyone passes it resolves and the next plane turns face up (stack.lua).
      push(activeSeat(color), "Planeswalk", "Planeswalk: " .. plane.getName() .. " leaves and the next plane turns face up.", "walk")
    elseif chaos then
      local text = chaosOf(plane)
      if text then
        push(activeSeat(color), plane.getName(), text, "chaos")
      else
        say(plane.getName() .. " has no chaos ability.", INFO)
      end
    end
  end, function()
    if tok then
      return die.isDestroyed() or tok.done
    end
    return die.isDestroyed() or (die.resting and not die.spawning)
  end, viaTower and 28 or 10, function()
    rolling = false
  end)
end

-- Turn a resting die so face r is up, as a last little hop (it's lifted a touch, turned, and dropped).
local function showFace(die, r, cb)
  local ok, v = pcall(function() return die.getValue() end)
  if ok and tonumber(v) == r then
    cb()
    return
  end
  local target
  pcall(function()
    for _, rv in ipairs(die.getRotationValues() or {}) do
      if tonumber(rv.value) == r then
        target = rv.rotation
      end
    end
  end)
  if target == nil then
    pcall(function() die.setValue(r) end)
    cb()
    return
  end
  local p = die.getPosition()
  local yaw = die.getRotation().y
  die.setLock(true)
  die.setPositionSmooth({ p.x, p.y + 0.55, p.z }, false, true)
  die.setRotationSmooth({ target.x, yaw + math.random(-40, 40), target.z }, false, true)
  Wait.time(function()
    if die.isDestroyed() then
      return cb()
    end
    die.setLock(false)
    Wait.condition(cb, function() return die.isDestroyed() or (die.resting and not die.spawning) end, 3, cb)
  end, 0.4)
end

-- The rotation that shows face r on top (nil if the die can't say).
local function faceRotation(die, r)
  local rot
  pcall(function()
    for _, rv in ipairs(die.getRotationValues() or {}) do
      if tonumber(rv.value) == r then
        rot = rv.rotation
      end
    end
  end)
  return rot
end

-- Last resort: carry a die onto its dragon's tongue, showing face r.
local function rescue(die, h, r, cb)
  if die.isDestroyed() then
    return cb()
  end
  local rot = faceRotation(die, r)
  die.setLock(true)
  die.setPositionSmooth(restSpot(h), false, false)
  if rot then
    die.setRotationSmooth({ rot.x, math.random(0, 359), rot.z }, false, false)
  end
  Wait.time(function()
    if not die.isDestroyed() then
      die.setLock(false)
      if not rot then
        pcall(function() die.setValue(r) end)
      end
    end
    cb()
  end, 1.0)
end

-- How long a die takes to ride down inside the tower (about two runs of the tower's lights down its bands).
local INSIDE_SECS = 3.5
local OUT_ALONG = 8.4           -- where a die is let go, rolling out over the back of the dragon's tongue

-- The way down inside the tower, as points (x, y, z) from the middle of the tower on the table, for side A (side B
-- is the same turned round). It follows the spiral slide in MTGDiceTowerBuilder.cs: round once from the hole at the
-- top (angle 520 degrees) down to the west side, out along the exit ramp and down the dragon's throat.
local PATH_A
do
  local Ey, Pitch, ride, lift = 7.63, 1.4, 2.3, 0.55
  PATH_A = {}
  local a0, a1, n = math.rad(520), math.pi, 40
  for i = 0, n do
    local a = a0 + (a1 - a0) * i / n
    table.insert(PATH_A, { ride * math.cos(a), Ey + Pitch * (a - math.pi) + lift, ride * math.sin(a) })
  end
  table.insert(PATH_A, { -1.85, 4.6, 2.9 })   -- through the wall into the back of the dragon's head, unseen
  table.insert(PATH_A, { -1.85, 1.62 + lift, 7.0 })
  table.insert(PATH_A, { -1.85, 1.44 + lift, OUT_ALONG })   -- on the tongue
end

-- Ride a die down the path for side h over `secs`, tumbling as it goes, then call cb. (It's locked while it rides:
-- the inside is never simulated, because TTS's dice settle too readily to slide down a ramp reliably.)
local function ride(die, h, secs, cb)
  local flip = HEADS[h].dir    -- side B is side A turned round
  local pts, lens, total = {}, { 0 }, 0
  for i, p in ipairs(PATH_A) do
    pts[i] = { TOWER.x + p[1] * flip, TableSetup.SURFACE_TOP + p[2], TOWER.z + p[3] * flip }
    if i > 1 then
      local q = pts[i - 1]
      total = total + math.sqrt((pts[i][1] - q[1]) ^ 2 + (pts[i][2] - q[2]) ^ 2 + (pts[i][3] - q[3]) ^ 2)
      lens[i] = total
    end
  end
  die.setLock(true)
  local r0 = die.getRotation()
  local rot = { r0.x, r0.y, r0.z }
  local spin = { math.random(8, 12), math.random(-4, 4), math.random(6, 10) }
  local frames = math.max(1, math.floor(secs * 60))
  local f = 0
  local function step()
    if die.isDestroyed() then
      return cb()
    end
    f = f + 1
    -- Quick down the spiral, slowing to a gentle roll by the time it comes out onto the tongue.
    local p = math.min(1, f / frames)
    local d = total * (1 - (1 - p) ^ 1.6)
    local k = 2
    while k < #pts and lens[k] < d do
      k = k + 1
    end
    local a, b = pts[k - 1], pts[k]
    local seg = lens[k] - lens[k - 1]
    local t = seg > 0 and (d - lens[k - 1]) / seg or 1
    die.setPosition({ a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t })
    local k2 = 2 * (1 - p) + 0.15
    rot = { rot[1] + spin[1] * k2, rot[2] + spin[2] * k2, rot[3] + spin[3] * k2 }
    die.setRotation(rot)
    if f >= frames then
      return cb()
    end
    Wait.frames(step, 1)
  end
  step()
end

-- One die's trip: it drops in at the top (real physics), rides down the spiral inside, and rolls out of its
-- dragon's mouth onto the tongue (real physics again for the last gentle roll). Whatever face it settles on is the
-- roll: done(value) once it's still. (If it ever ends up off the tongue it's carried back there, on a random face.)
local function journey(die, h, token, done)
  local finished = false
  local function finish(v)
    if not finished then
      finished = true
      done(v)
    end
  end
  local function value()
    local ok, v = pcall(function() return tonumber(die.getValue()) end)
    return ok and v or math.random(6)
  end
  local function carry()
    local v = math.random(6)
    rescue(die, h, v, function() finish(v) end)
  end
  local hd = HEADS[h]
  dropIn(die, h)
  local function inside()
    if roll ~= token or die.isDestroyed() then
      return finish(value())
    end
    ride(die, h, INSIDE_SECS, function()
      if roll ~= token or die.isDestroyed() then
        return finish(value())
      end
      die.setLock(false)
      Wait.frames(function()
        if die.isDestroyed() then
          return
        end
        -- Let go rolling gently forward along the tongue (turning over the way it's moving).
        die.setVelocity({ 0, 0, 1.3 * hd.dir })
        die.setAngularVelocity({ 5 * hd.dir, 0, math.random(-1, 1) })
        Wait.time(function()
          -- Really still (not just a pause mid-tumble): resting, barely moving, and still so a moment later.
          local function still()
            if die.isDestroyed() then
              return true
            end
            local ok, v = pcall(function() return die.getVelocity() end)
            local ok2, w = pcall(function() return die.getAngularVelocity() end)
            local slow = ok and ok2 and v and w and (math.abs(v.x) + math.abs(v.y) + math.abs(v.z)) < 0.05
              and (math.abs(w.x) + math.abs(w.y) + math.abs(w.z)) < 0.05
            return die.resting and not die.spawning and (slow or not ok)
          end
          Wait.condition(function()
            if finished then
              return
            end
            Wait.time(function()
              if finished then
                return
              end
              if not still() then
                -- It moved again: wait for it to settle properly.
                return Wait.condition(function()
                  if not finished then
                    if onTongue(die, h) then finish(value()) else carry() end
                  end
                end, still, 5, function() if not finished then carry() end end)
              end
              if onTongue(die, h) then
                finish(value())
              else
                carry()
              end
            end, 0.4)
          end, function()
            return finished or still()
          end, 6, function()
            if not finished then
              carry()
            end
          end)
        end, 0.4)
      end, 1)
    end)
  end
  -- It has dropped in once it's down past the top of the battlements (or after a moment, whatever happens).
  Wait.condition(inside, function()
    return die.isDestroyed() or roll ~= token or die.getPosition().y < TableSetup.SURFACE_TOP + 18.4
  end, 1.2, inside)
end

-- A roll down the tower: the die goes in, the tower's lines run in the roller's colour while it rides down inside,
-- it rolls out of the dragon on the roller's side, and once it settles both dragons breathe fire in the result's
-- colour (the roller's colour on a blank, purple for chaos, blue-white for planeswalk). The face it lands on is the
-- roll: nothing is forced.
towerRoll = function(die, color, byHand, chute)
  if rolling or roll ~= nil then
    return
  end
  local st = data()
  local token = { r = nil, done = false }
  roll = token
  local idx = TOWER_IDX[color] or 0
  towerLoop(TOWER_ROLLING + idx)
  towerRolling = true
  -- It comes out of the dragon nearest whoever rolled it (or, for a colour with no seat side, the side it was
  -- dropped over / sitting on).
  local hp = SIDE_OF[color] or chute or ((die.getPosition().z - TOWER.z) * HEADS.A.dir >= 0 and "A" or "B")
  local function go()
    journey(die, hp, token, function(v)
      token.r = v
      token.done = true
      if roll ~= token then
        return
      end
      roll = nil
      towerRolling = false
      Planechase.towerColor(Fires and Fires.current and Fires.current() or nil)
      -- The dragons roar in the result's colour.
      towerFlash((v == 1 and TOWER_WALK) or ((v == 6 or st.aether) and TOWER_CHAOS) or idx)
    end)
    Wait.time(function() Planechase.onRolled(die, color, true) end, 0.4)
    -- Never leave the tower stuck mid-roll.
    Wait.time(function()
      if roll == token then
        token.r = token.r or (function() local ok, v = pcall(function() return tonumber(die.getValue()) end) return ok and v or 2 end)()
        token.done = true
        roll = nil
        towerRolling = false
        Planechase.towerColor(Fires and Fires.current and Fires.current() or nil)
      end
    end, 20)
  end
  go()
end

-- A player let go of the planar die over the top of the tower: that's a roll (it comes out on their side).
function Planechase.onDrop(color, obj)
  if obj == nil or not obj.hasTag or not obj.hasTag("PlanarDie") or towerObj() == nil then
    return
  end
  local h = chuteAt(obj.getPosition())
  if h then
    towerRoll(obj, color, false, h)
  end
end

-- !planechase roll: throw the die for the player.
function Planechase.roll(color)
  local die = findDie()
  if die == nil then
    broadcastToColor("No planar die out: UNPACK the Planechase chest first.", color, WARN)
    return
  end
  if towerObj() then
    towerRoll(die, color, false)
    return
  end
  rollBy = color
  pcall(function() die.roll() end)
end

function Planechase.stow(color)
  clearTable()
  data().probed = false
  rolling = false
  data().aether = false
  busy = false
  say("planar deck, plane and die packed up.")
end

function Planechase.turnCards(color)
  local st = data()
  st.flip = not st.flip
  for _, o in ipairs(getObjectsWithTag("PlanarCard")) do
    local r = o.getRotation()
    o.setRotation({ r.x, (r.y + 180) % 360, r.z })
  end
  say("plane cards turned around.")
end

---------------------------------------------------------------------------
-- The chest
---------------------------------------------------------------------------

function pc_unpack(obj, color) Planechase.build(color) end
function pc_pack(obj, color) Planechase.stow(color) end

local BUTTONS = {
  { fn = "pc_unpack", label = "UNPACK", tip = "Set up Planechase: planar deck, first plane and the planar die" },
  { fn = "pc_pack", label = "PACK UP", tip = "Put the planar deck, plane and die away" },
}

local function addButtons(obj)
  obj.clearButtons()
  for i, b in ipairs(BUTTONS) do
    obj.createButton({
      click_function = b.fn,
      function_owner = Global,
      label = b.label,
      tooltip = b.tip,
      position = { (i - 1.5) * 3.0, 3.53, 0 },
      rotation = { 0, 0, 0 },
      width = 1350, height = 520, font_size = 230,
      color = { 0.04, 0.06, 0.1, 0.95 },
      font_color = { 0.35, 0.95, 1, 1 },
      hover_color = { 0.1, 0.25, 0.3, 1 },
      press_color = { 0.2, 0.5, 0.6, 1 },
    })
  end
end

-- Put the chest where it belongs for the current layout (called on load and when the layout changes).
function Planechase.placeChest(o)
  o = o or getObjectsWithTag("PlanechaseChest")[1]
  if o == nil or o.isDestroyed() then
    return
  end
  local spot = chestSpot()
  local p = o.getPosition()
  local fell = false
  pcall(function()
    local b = o.getBounds()
    fell = math.abs((b.center.y - b.size.y / 2) - TableSetup.SURFACE_TOP) > 0.3
  end)
  if fell or math.abs(p.x - spot.x) > 0.5 or math.abs(p.z - spot.z) > 0.5 then
    o.setLock(true)
    o.setRotation({ 0, spot.yaw, 0 })
    o.setPosition({ spot.x, p.y, spot.z })
    -- Sit it on the table (it may have fallen or been knocked off).
    pcall(function()
      local b = o.getBounds()
      local bottom = b.center.y - b.size.y / 2
      o.setPosition({ spot.x, p.y + (TableSetup.SURFACE_TOP - bottom), spot.z })
    end)
  end
end

function Planechase.ensure()
  if PLANECHASE_CARDS == nil then
    return
  end
  buildIndex()
  -- The old die spot (before the dice tower): gone.
  for _, o in ipairs(getObjectsWithTag("PlanarDieSpot")) do
    o.destruct()
  end
  local plane = findPlane()
  if plane then
    planeMenu(plane)
  end
  if plane or findDeck() or findGrave() then
    ensureExtras()
    Wait.time(function() putDie() end, 2)
  end
  local mesh = BASE .. "chest.obj" .. VERSION
  for _, o in ipairs(getObjectsWithTag("PlanechaseChest")) do
    local co = o.getCustomObject()
    if co and co.mesh == mesh then
      o.setLock(true)
      Planechase.placeChest(o)
      addButtons(o)
      return
    end
    o.destruct()
  end
  local spot = chestSpot()
  local obj = spawnObject({
    type = "Custom_Model",
    position = { spot.x, TableSetup.SURFACE_TOP + 0.02, spot.z },
    rotation = { 0, spot.yaw, 0 },
    scale = { 1, 1, 1 },
    sound = false,
    callback_function = function(o)
      o.setName("Planechase Chest")
      o.setDescription("UNPACK to set up Planechase, PACK UP to put it away.")
      o.addTag("PlanechaseChest")
      o.setLock(true)
      Wait.condition(function() addButtons(o) end,
        function() return o.isDestroyed() or not o.loading_custom end, 10,
        function() addButtons(o) end)
    end,
  })
  obj.setCustomObject({ mesh = mesh, diffuse = STONE, collider = BASE .. "chest_collider.obj" .. VERSION,
    type = 0, material = 1 })
end

function Planechase.chat(message, color)
  local cmd = tostring(message):lower():match("^!planechase%s*(.*)$")
  if cmd == nil then
    return false
  end
  cmd = cmd:gsub("%s+$", "")
  if cmd == "build" or cmd == "unpack" then
    Planechase.build(color)
  elseif cmd == "roll" then
    Planechase.roll(color)
  elseif cmd == "walk" then
    Planechase.planeswalk(color)
  elseif cmd == "stow" or cmd == "pack" or cmd == "pack up" then
    Planechase.stow(color)
  elseif cmd == "turn" then
    Planechase.turnCards(color)
  elseif cmd == "nowho" or cmd == "who" then
    local st = data()
    st.noWho = cmd == "nowho"
    say("Doctor Who planes " .. (st.noWho and "left out" or "included") .. " the next time you UNPACK.")
  elseif cmd == "nophenomena" or cmd == "phenomena" then
    local st = data()
    st.noPhenomena = cmd == "nophenomena"
    say("Phenomena " .. (st.noPhenomena and "left out" or "included") .. " the next time you UNPACK.")
  else
    say("!planechase unpack | pack | roll | walk | turn | nowho / who | nophenomena / phenomena")
  end
  return true
end

-- The face-up plane's "At the beginning of your upkeep / end step / ..." abilities go on the stack for the
-- player whose turn it is (Littjara: "When you planeswalk to Littjara and at the beginning of your upkeep,
-- create a 2/2 blue Shapeshifter ...").
local PLANE_STEPS = {
  { "at the beginning of your upkeep", "upkeep" },
  { "at the beginning of each upkeep", "upkeep" },
  { "at the beginning of your draw step", "draw" },
  { "at the beginning of your precombat main phase", "main1" },
  { "at the beginning of your first main phase", "main1" },
  { "at the beginning of combat on your turn", "combat" },
  { "at the beginning of your end step", "end" },
  { "at the beginning of each end step", "end" },
}
Events.on("stepStarted", function(d)
  if not GameState.data.started or d == nil or d.seat == nil then
    return
  end
  local plane = findPlane()
  local e = plane and entryOf(plane)
  if e == nil or e.t == "Phenomenon" then
    return
  end
  for _, l in ipairs(lines(e.o)) do
    local low = l:lower()
    for _, ps in ipairs(PLANE_STEPS) do
      if ps[2] == d.step and low:find(ps[1], 1, true) then
        push(d.seat, plane.getName(), afterComma(l))
        break
      end
    end
  end
end)
