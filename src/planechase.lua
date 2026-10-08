--[[
  planechase.lua
  Planechase for the table. A stone treasure chest (the table frame's stone)
  sits in the empty corner between White and Blue. Its lid has two buttons:

    UNPACK   shuffle the planar deck (all planes and Phenomena) into the
             middle of the table, turn the first plane face up and put the
             planar die out beside the chest
    PACK UP  put the planar deck, the plane and the die away

  Roll the planar die by hand (pick it up and drop it, or right-click it >
  Roll). The table watches it: the first roll each turn is free, every extra
  roll costs one more mana than the last; a planeswalk or chaos result is
  carried out by itself. Right-click the plane card > Planeswalk for effects
  that say "planeswalk".

  The table does the rest: the old plane goes to the bottom of the planar
  deck and the next card turns face up; "When you planeswalk to ..." and
  "Whenever chaos ensues ..." abilities go on the stack; a Phenomenon
  triggers and then you planeswalk away from it by itself; Chaotic Aether
  turns blank rolls into chaos until a player planeswalks away from a plane.
  The planes' always-on abilities (static ones and "At the beginning of ...")
  are printed in the chat when a plane turns up: players apply those.

  Chat: !planechase  (help), !planechase unpack | pack | roll | walk | turn
        ("turn" swaps which way the plane cards face, if they read upside down)

  The plane pictures are Scryfall's upright landscape images, so zooming a
  card works like any other card.

  Cards come from planechase_data.lua (tools/make_planechase_data.py).
--]]

Planechase = {}

local BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/planechase/"
local STONE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/table/stone.png?v=3"
local VERSION = "?v=1"
local DIE_IMAGE = "https://i.imgur.com/ptrUeHV.jpg"

local CHEST = { x = 38, z = -38, yaw = 135 }       -- between White (south) and Blue (east)
local DECK_AT = { x = -8.5, z = 3.8 }              -- west of the stack mat
local PLANE_AT = { x = -8.5, z = -3.8 }
local LAND = { x = 31, z = -31 }                    -- the planar die waits in front of the chest
local CARD_SCALE = 1.4
local YAW = 180                                     -- landscape plane cards, readable from White (like cards at that seat)
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

local function yaw()
  return (YAW + (data().flip and 180 or 0)) % 360
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
      [tostring(id)] = { FaceURL = c.u, BackURL = PLANECHASE_BACK, NumWidth = 1, NumHeight = 1,
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

local function finishDeck(o)
  if o and not o.isDestroyed() then
    o.setName("Planar Deck")
    o.setScale({ CARD_SCALE, 1, CARD_SCALE })
    o.addTag("PlanarCard")
  end
end

-- Put a card on the bottom of the planar deck (one rebuild).
local function putBottom(deckObj, card, cb)
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
      finishDeck(o)
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
    card.setScale({ CARD_SCALE, 1, CARD_SCALE })
    card.addTag("PlanarCard")
    planeMenu(card)
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

local function activeSeat(fallback)
  local t = GameState.data.turn
  return (t and t.activeSeat) or fallback or "White"
end

local function push(seat, name, text)
  if Stack and text and text ~= "" then
    Stack.pushAbility(seat, name, text, nil, { trigger = true })
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

local function clearTable()
  for _, o in ipairs(getObjectsWithTag("PlanarCard")) do
    if not o.isDestroyed() then
      o.destruct()
    end
  end
  for _, o in ipairs(getObjectsWithTag("PlanarDie")) do
    if not o.isDestroyed() then
      o.destruct()
    end
  end
end

function Planechase.build(color)
  if busy then
    return
  end
  if findDeck() or findPlane() then
    broadcastToColor("The planar deck is already out. Click PACK UP first to put it away.", color, WARN)
    return
  end
  buildIndex()
  local st = data()
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
      scaleX = CARD_SCALE, scaleY = 1, scaleZ = CARD_SCALE },
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

function Planechase.planeswalk(color, quiet)
  if busy and not quiet then
    return
  end
  local deck, plane = findDeck(), findPlane()
  if deck == nil and plane == nil then
    broadcastToColor("No planar deck yet: click UNPACK on the Planechase chest.", color, WARN)
    return
  end
  busy = true
  Wait.time(function() busy = false end, 20)
  local st = data()
  local function reveal(d)
    turnTop(d, function(card)
      busy = false
      arrived(card, color, false)
    end)
  end
  if plane then
    local e = entryOf(plane)
    if e and e.t == "Plane" and st.aether then
      st.aether = false
      say("Chaotic Aether ends.", INFO)
    end
    if deck == nil then
      busy = false
      broadcastToColor("The planar deck is empty.", color, WARN)
      return
    end
    putBottom(deck, plane, function(newDeck)
      Wait.time(function() reveal(newDeck) end, 0.6)
    end)
  else
    reveal(deck)
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

local function findDie()
  for _, o in ipairs(getObjectsWithTag("PlanarDie")) do
    if not o.isDestroyed() then
      return o
    end
  end
  return nil
end

putDie = function(cb)
  local die = findDie()
  if die then
    if cb then cb(die) end
    return
  end
  spawnObjectData({
    data = {
      Name = "Custom_Dice",
      Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 0, rotZ = 0, scaleX = 1.65, scaleY = 1.65, scaleZ = 1.65 },
      Nickname = "Planar Die",
      Description = "Roll it by hand: chaos or planeswalk happens by itself. First roll each turn is free, then 1, 2, 3 mana...",
      ColorDiffuse = { r = 1, g = 1, b = 1 },
      CustomImage = { ImageURL = DIE_IMAGE, ImageSecondaryURL = "", ImageScalar = 1, WidthScale = 0,
        CustomDice = { Type = 1 } },
      Tags = { "PlanarDie" },
    },
    position = { LAND.x, TableSetup.SURFACE_TOP + 3, LAND.z },
    callback_function = function(o)
      o.addTag("PlanarDie")
      if cb then cb(o) end
    end,
  })
end

local rollBy, rolling = nil, false

-- The planar die was rolled (by hand or by !planechase roll).
function Planechase.onRolled(die, color)
  if die == nil or die.isDestroyed() or not die.hasTag("PlanarDie") or rolling then
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
    if color ~= t.activeSeat then
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
  Wait.time(function() rolling = false end, 15)
  say(color .. " rolls the planar die" .. (cost == 0 and " (first roll this turn: free)." or (": pay " .. cost .. " mana for this roll.")), CYAN)
  Wait.condition(function()
    rolling = false
    if die.isDestroyed() then
      return
    end
    local v = die.getValue()
    say(color .. " rolled: " .. dieValueText(v, st.aether), v == 1 and GOOD or (v == 6 and CYAN or INFO))
    local chaos = v == 6 or (st.aether and v ~= 1)
    if v == 1 then
      Planechase.planeswalk(color, true)
    elseif chaos then
      local text = chaosOf(plane)
      if text then
        push(activeSeat(color), plane.getName(), text)
      else
        say(plane.getName() .. " has no chaos ability.", INFO)
      end
    end
  end, function() return die.isDestroyed() or (die.resting and not die.spawning) end, 10, function()
    rolling = false
  end)
end

-- !planechase roll: throw the die for the player.
function Planechase.roll(color)
  local die = findDie()
  if die == nil then
    broadcastToColor("No planar die out: UNPACK the Planechase chest first.", color, WARN)
    return
  end
  rollBy = color
  pcall(function() die.roll() end)
end

function Planechase.stow(color)
  clearTable()
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

function Planechase.ensure()
  if PLANECHASE_CARDS == nil then
    return
  end
  buildIndex()
  local plane = findPlane()
  if plane then
    planeMenu(plane)
  end
  local mesh = BASE .. "chest.obj" .. VERSION
  for _, o in ipairs(getObjectsWithTag("PlanechaseChest")) do
    local co = o.getCustomObject()
    if co and co.mesh == mesh then
      o.setLock(true)
      addButtons(o)
      return
    end
    o.destruct()
  end
  local obj = spawnObject({
    type = "Custom_Model",
    position = { CHEST.x, TableSetup.SURFACE_TOP + 0.02, CHEST.z },
    rotation = { 0, CHEST.yaw, 0 },
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
