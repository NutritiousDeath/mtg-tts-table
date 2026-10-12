--[[
  attractions.lua
  Attractions (Unfinity). Each seat keeps its Attraction cards in their own
  face-down deck in the ATTRACTIONS spot above the library, not in the library.

    - Import: Attraction cards in the list are taken out of the library into
      the Attraction deck, which is shuffled.
    - Start Game: Attractions on the table go back to that deck, not the library.
    - "Open an Attraction" (effects.lua, or !attraction): the top card of your
      Attraction deck goes onto your battlefield.
    - Roll to visit: at the beginning of your first main phase, if you control
      any Attractions, the table rolls a d6. Each Attraction whose lit numbers
      include the roll is visited: its "Visit" ability goes on the stack.
      The lit numbers come from Scryfall (card data "lights").

  Chat: !attraction (open one; "!attraction Red" for another seat in solo)
        !visit (roll to visit now)
--]]

Attractions = {}

local INFO = { 0.75, 0.8, 0.9 }
local GOOD = { 0.55, 0.9, 0.6 }
local WARN = { 1, 0.6, 0.2 }

local function dataOf(notes)
  local ok, d = pcall(function() return JSON.decode(notes or "") end)
  return ok and type(d) == "table" and d or nil
end

local function isAttractionData(d)
  return d ~= nil and tostring(d.typeLine or ""):find("Attraction", 1, true) ~= nil
end

function Attractions.isAttraction(obj)
  return obj ~= nil and not obj.isDestroyed() and obj.type == "Card" and isAttractionData(dataOf(obj.getGMNotes()))
end

-- Is a world position inside this seat's ATTRACTIONS spot?
local function inSpot(color, pos)
  local r = TableSetup.region(color, "attractions")
  local s = TableSetup.seat(color)
  if r == nil or s == nil then
    return false
  end
  local dx, dz = pos.x - r.center.x, pos.z - r.center.z
  local side = dx * s.right.x + dz * s.right.z
  local depth = dx * s.inward.x + dz * s.inward.z
  return math.abs(side) <= r.w / 2 + 0.5 and math.abs(depth) <= r.d / 2 + 0.5
end

-- The seat's Attraction deck (a Deck, or a single Card), or nil.
function Attractions.deck(color)
  local best, bestN = nil, -1
  for _, obj in ipairs(getObjects()) do
    if (obj.type == "Deck" or obj.type == "Card") and obj.held_by_color == nil and inSpot(color, obj.getPosition()) then
      local n = obj.type == "Deck" and #obj.getObjects() or 1
      if n > bestN then
        best, bestN = obj, n
      end
    end
  end
  return best
end

-- Everything in the spot, merged into one face-down deck and shuffled.
local function tidy(color)
  Wait.time(function()
    local list = {}
    for _, obj in ipairs(getObjects()) do
      if (obj.type == "Deck" or obj.type == "Card") and obj.held_by_color == nil and inSpot(color, obj.getPosition()) then
        table.insert(list, obj)
      end
    end
    if #list > 1 then
      group(list)
    end
    Wait.time(function()
      local d = Attractions.deck(color)
      if d then
        d.setName(color .. " Attractions")
        if d.type == "Deck" then
          d.shuffle()
        end
      end
    end, 1.0)
  end, 1.2)
end

-- Put Attraction cards (objects already out on the table) into the deck.
function Attractions.store(color, cards)
  local spot = TableSetup.slot(color, "attractions", TableSetup.SURFACE_TOP + 1)
  local s = TableSetup.seat(color)
  if spot == nil or #cards == 0 then
    return
  end
  for i, c in ipairs(cards) do
    if not c.isDestroyed() then
      if Zones.forget then
        Zones.forget(c.getGUID())
      end
      c.setLock(false)
      c.setRotation({ 0, s.yaw, 180 })
      c.setPosition({ x = spot.x, y = spot.y + i * 0.25, z = spot.z })
    end
  end
  tidy(color)
end

-- Take the Attraction cards out of the seat's library into the Attraction deck.
function Attractions.sortOut(color)
  local lib = Library.find(color)
  local spot = TableSetup.slot(color, "attractions", TableSetup.SURFACE_TOP + 1)
  local s = TableSetup.seat(color)
  if lib == nil or spot == nil then
    return 0
  end
  local guids = {}
  if lib.type == "Deck" then
    for _, e in ipairs(lib.getObjects()) do
      if isAttractionData(dataOf(e.gm_notes)) then
        table.insert(guids, e.guid)
      end
    end
  elseif Attractions.isAttraction(lib) then
    Attractions.store(color, { lib })
    return 1
  end
  for i, g in ipairs(guids) do
    if lib.isDestroyed() then
      break
    end
    lib.takeObject({ guid = g, position = { x = spot.x, y = spot.y + i * 0.25, z = spot.z },
      rotation = { 0, s.yaw, 180 }, smooth = false })
  end
  if #guids > 0 then
    tidy(color)
    broadcastToAll(color .. ": " .. #guids .. " Attraction" .. (#guids == 1 and "" or "s")
      .. " moved to the Attraction deck (above the library).", INFO)
  end
  return #guids
end

-- Start Game: split the gathered cards; Attractions go to their deck.
function Attractions.splitGathered(color, objs)
  local rest, attr = {}, {}
  for _, o in ipairs(objs) do
    if Attractions.isAttraction(o) then
      table.insert(attr, o)
    else
      table.insert(rest, o)
    end
  end
  Attractions.store(color, attr)
  return rest
end

-- Open n Attractions: the top card(s) of the deck onto the battlefield.
function Attractions.open(color, n, why)
  n = n or 1
  local function one(i)
    if i > n then
      return
    end
    local deck = Attractions.deck(color)
    if deck == nil then
      broadcastToAll(color .. " has no Attraction deck left to open from" .. (why and (" (" .. why .. ")") or "") .. ".", WARN)
      return
    end
    local s = TableSetup.seat(color)
    local base = TableSetup.slot(color, "battlefield", TableSetup.SURFACE_TOP + 1.5)
    local off = (math.random() - 0.5) * 20
    local pos = { x = base.x + s.right.x * off, y = base.y, z = base.z + s.right.z * off }
    local function landed(card)
      Wait.time(function()
        if not card.isDestroyed() then
          Zones.refresh(card)
          broadcastToAll(color .. " opens an Attraction: " .. card.getName()
            .. (why and (" (" .. why .. ")") or "") .. ".", GOOD)
        end
        one(i + 1)
      end, 0.8)
    end
    if deck.type == "Deck" then
      deck.takeObject({ index = 0, position = pos, rotation = { 0, s.yaw, 0 }, smooth = true,
        callback_function = landed })
    else
      deck.setPositionSmooth(pos, false, true)
      deck.setRotationSmooth({ 0, s.yaw, 0 }, false, true)
      landed(deck)
    end
  end
  one(1)
end

-- The "Visit —" text of an Attraction (nil if it has none).
local function visitText(d)
  local o = tostring(d and d.oracle or "")
  for line in o:gmatch("[^\n]+") do
    local low = line:lower()
    if low:sub(1, 5) == "visit" then
      return line
    end
  end
  return nil
end

-- Roll to visit: a d6; every Attraction you control lit on that number is visited.
function Attractions.rollToVisit(color)
  local mine = {}
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if Attractions.isAttraction(obj) and Effects and Effects.fieldSeat and Effects.fieldSeat(obj) == color then
      table.insert(mine, obj)
    end
  end
  if #mine == 0 then
    return false
  end
  local roll = math.random(6)
  local visited, unknown = {}, {}
  for _, obj in ipairs(mine) do
    local d = dataOf(obj.getGMNotes())
    local lights = d and d.lights
    if type(lights) ~= "table" then
      table.insert(unknown, obj.getName())
    else
      for _, n in ipairs(lights) do
        if tonumber(n) == roll then
          table.insert(visited, obj)
          break
        end
      end
    end
  end
  broadcastToAll(color .. " rolls to visit: " .. roll .. ". "
    .. (#visited > 0 and ("Visiting " .. #visited .. " Attraction" .. (#visited == 1 and "" or "s") .. ".")
      or "No Attraction lit on " .. roll .. "."), { 1, 0.85, 0.3 })
  for _, obj in ipairs(visited) do
    local text = visitText(dataOf(obj.getGMNotes()))
    if text then
      local face = ""
      pcall(function()
        for _, cd in pairs(obj.getData().CustomDeck or {}) do
          face = cd.FaceURL
          break
        end
      end)
      Stack.pushAbility(color, obj.getName(), text, face, { trigger = true, source = obj.getGUID() })
    else
      broadcastToAll(obj.getName() .. " is visited (it has no Visit ability the table can read; do it by hand).", INFO)
    end
  end
  if #unknown > 0 then
    broadcastToAll("The table doesn't know the lit numbers on " .. table.concat(unknown, ", ")
      .. " (re-import the deck to fetch them). Check those by hand for " .. roll .. ".", WARN)
  end
  return true
end

-- "At the beginning of your precombat main phase, if you control one or more
-- Attractions, roll to visit your Attractions."
Events.on("stepStarted", function(d)
  if d and d.step == "main1" and d.seat and GameState.data and GameState.data.started then
    Wait.time(function() Attractions.rollToVisit(d.seat) end, 0.6)
  end
end)

function Attractions.chat(message, color)
  local m = tostring(message)
  local who = m:match("^!attraction (%a+)$")
  if m == "!attraction" or who then
    local seat = who and (who:sub(1, 1):upper() .. who:sub(2):lower()) or color
    if who and seat ~= color and not GameState.solo() then
      broadcastToColor("You can only open your own Attractions.", color, WARN)
      return true
    end
    Attractions.open(seat, 1, "by hand")
    return true
  end
  if m == "!visit" then
    if not Attractions.rollToVisit(color) then
      broadcastToColor("You don't control any Attractions.", color, INFO)
    end
    return true
  end
  return false
end
