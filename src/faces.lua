--[[
  faces.lua
  Double-faced cards. The importer gives each one its back face as TTS
  state 2 (state 1 = front). Changing state swaps in a new object, so this
  module carries everything the table knows about the card over to it:
  where it is (zones), its counters, and every GUID stored in the game data
  (summoning sickness, combat, the stack, temporary boosts, commanders).

    - Right-click > "Transform / other face": flips the card. On the
      battlefield that's transforming; in your hand it picks the face to
      cast (modal double-faced cards: a spell on one side, a land on the
      other).
    - "Transform ~" in an ability (Sephiroth, werewolves, flip walkers...)
      flips the card by itself (effects.lua).
    - A transformed card that leaves the battlefield turns back to its
      front face (a card is only ever transformed on the battlefield).
    - Pressing TTS's own state keys on a card works too: it's tracked the
      same way.

  Face-down cards (morph, disguise, manifest, cloak):
    - A card that goes onto the battlefield or the stack face down becomes a
      nameless 2/2 creature with no abilities (disguise / cloak: ward {2})
      for every part of the table. Its real name and text are kept hidden
      in its data, so nothing (triggers, tooltips) gives it away.
    - Right-click in hand > "Cast face down": onto the stack as a face-down
      creature spell (pay {3} yourself). Dropping a card face down on your
      CAST mat or the battlefield works too.
    - Right-click > "Peek (face-down card)": only its controller is told
      what it is. "Turn face up": flips it and fires its "when ~ is turned
      face up" ability. Flipping it with F does the same.
    - It's revealed when it leaves the battlefield.
    - "Manifest / cloak the top card of your library" (effects.lua).
--]]

Faces = {}

local INFO = { 0.75, 0.8, 0.9 }
local GOOD = { 0.45, 1, 0.6 }

local justChanged = {}   -- [new guid] = true: the next onObjectSpawn is this swap, not a new card

-- 1 = front, 2 = back, nil = not double-faced.
function Faces.state(obj)
  if obj == nil or obj.isDestroyed() then
    return nil
  end
  local ok, id = pcall(function() return obj.getStateId() end)
  if not ok or id == nil or id < 1 then
    return nil
  end
  return id
end

function Faces.isDoubleFaced(obj)
  return Faces.state(obj) ~= nil
end

-- Replace every use of one GUID in the game data with another (keys and
-- values, "pw:<guid>" attack targets too).
local function rekeyTable(t, old, new, depth)
  if depth > 12 or type(t) ~= "table" then
    return
  end
  local moves = {}
  for k, v in pairs(t) do
    if type(v) == "table" then
      rekeyTable(v, old, new, depth + 1)
    elseif v == old then
      t[k] = new
    elseif v == "pw:" .. old then
      t[k] = "pw:" .. new
    end
    if k == old then
      table.insert(moves, k)
    end
  end
  for _, k in ipairs(moves) do
    t[new] = t[k]
    t[k] = nil
  end
end

-- The card in `obj` used to be `old` (a GUID): carry everything over.
-- Safe to call twice (the second call finds nothing left under `old`).
function Faces.rekey(old, obj)
  if obj == nil or obj.isDestroyed() then
    return
  end
  local new = obj.getGUID()
  justChanged[new] = true
  if old == nil or old == new then
    return
  end
  if Zones.rekey then
    Zones.rekey(old, new)
  end
  if Counters.carry then
    Counters.carry(old, obj)
  end
  if GameState.data then
    rekeyTable(GameState.data, old, new, 0)
  end
end

-- After a swap: menus, counter label, loyalty for a planeswalker side.
local function setupLater(obj)
  Wait.frames(function()
    if obj ~= nil and not obj.isDestroyed() then
      obj.clearContextMenu()
      Counters.setup(obj)
      if Combat and Combat.refresh then
        Combat.refresh()
      end
    end
  end, 2)
end

-- Did onObjectSpawn get this object because of a face swap? (main.lua)
function Faces.consumeSpawn(obj)
  local g = obj and not obj.isDestroyed() and obj.getGUID()
  if g and justChanged[g] then
    justChanged[g] = nil
    return true
  end
  return false
end

-- TTS event (main.lua): any state change, by script or by a player.
function Faces.onStateChange(obj, oldGuid)
  if obj == nil or obj.isDestroyed() or not obj.hasTag("MTGCard") then
    return
  end
  Faces.rekey(oldGuid, obj)
  setupLater(obj)
end

local function onField(obj)
  local r = Zones.regionAt(obj.getPosition()).region
  return r == "battlefield" or r == "lands"
end

-- Turn the card to the given state now; returns the card object to use from
-- here on (the new one, or the same one when nothing changed).
function Faces.setState(obj, id)
  local now = Faces.state(obj)
  if now == nil or now == id then
    return obj
  end
  local old = obj.getGUID()
  local ok, new = pcall(function() return obj.setState(id) end)
  if not ok or new == nil then
    return obj
  end
  Faces.rekey(old, new)
  setupLater(new)
  return new
end

-- Flip to the other face. Says so when it's a transform on the battlefield.
function Faces.flip(obj, why)
  local now = Faces.state(obj)
  if now == nil then
    return nil
  end
  local before = obj.getName()
  local field = onField(obj)
  local new = Faces.setState(obj, now == 1 and 2 or 1)
  if field then
    printToAll("MTG > " .. before .. " transforms into " .. new.getName() .. (why and (" (" .. why .. ")") or "") .. ".", GOOD)
  end
  return new
end

-- Back to the front face (leaving the battlefield). Returns the card to use.
function Faces.front(obj)
  if Faces.state(obj) == 2 then
    return Faces.setState(obj, 1)
  end
  return obj
end

-- Is the back face a separate card to cast (modal: it has its own mana
-- cost), or the transformed side (no mana cost)?
local function backIsCastable(obj)
  local cost
  pcall(function()
    local d = JSON.decode(obj.getGMNotes())
    cost = type(d) == "table" and d.manaCost or nil
    if type(d) == "table" and d.layout then
      cost = d.layout == "modal_dfc" and "modal" or nil
    end
  end)
  if cost == nil then
    -- Lands on a modal card's back have no cost but are played: check the type.
    local isLand = false
    pcall(function()
      local d = JSON.decode(obj.getGMNotes())
      isLand = type(d) == "table" and tostring(d.typeLine or ""):find("Land", 1, true) ~= nil
        and tostring(d.layout or "") ~= "transform"
    end)
    return isLand
  end
  return cost ~= ""
end

function Faces.addMenu(obj)
  Faces.addFaceDownMenu(obj)
  if not Faces.isDoubleFaced(obj) then
    return
  end
  local where = Counters.regionOf(obj)
  if where ~= "battlefield" and where ~= "lands" then
    return   -- Transform only matters on the battlefield
  end
  obj.addContextMenuItem("Transform / other face", function(playerColor)
    if obj.isDestroyed() then
      return
    end
    Faces.flip(obj, playerColor)
  end)
end

-- Leaving the battlefield: a transformed card turns back to its front.
-- Entering it from anywhere else: a transforming card always enters front
-- face up (a modal card enters with the face that was played).
Events.on("cardMoved", function(d)
  local card = d.card
  if card == nil or card.isDestroyed() or d.to == nil or Faces.state(card) ~= 2 then
    return
  end
  local wasOn = d.from and (d.from.region == "battlefield" or d.from.region == "lands")
  local isOn = d.to.region == "battlefield" or d.to.region == "lands"
  if wasOn and not isOn then
    Wait.time(function()
      if not card.isDestroyed() and Faces.state(card) == 2 then
        Faces.front(card)
      end
    end, 0.2)
  elseif isOn and not wasOn and not backIsCastable(card) then
    Wait.time(function()
      if not card.isDestroyed() and Faces.state(card) == 2 then
        printToAll("MTG > " .. card.getName() .. " entered on its back face: turned to the front.", INFO)
        Faces.front(card)
      end
    end, 0.2)
  end
end)

---------------------------------------------------------------------------
-- Face-down cards
---------------------------------------------------------------------------

local function notes(obj)
  local ok, d = pcall(function() return JSON.decode(obj.getGMNotes()) end)
  return ok and type(d) == "table" and d or {}
end

-- Face down with its real data tucked away (a 2/2 for the table).
function Faces.isFaceDown(obj)
  return obj ~= nil and not obj.isDestroyed() and notes(obj).faceDown == true
end

-- Face down but not known to the table (a card flipped over for some other
-- reason): left alone by triggers and combat.
function Faces.unknown(obj)
  return obj ~= nil and obj.is_face_down == true and not Faces.isFaceDown(obj)
end

local function realData(obj)
  local d = notes(obj)
  if d.faceDown then
    local ok, r = pcall(function() return JSON.decode(d.real) end)
    return ok and type(r) == "table" and r or {}, d
  end
  return d, nil
end

-- What kind of face-down: from the card's keywords, or the given one.
local function kindOf(obj, kind)
  if kind then
    return kind
  end
  local d = notes(obj)
  for _, k in ipairs(d.keywords or {}) do
    local w = tostring(k):lower()
    if w == "morph" or w == "megamorph" or w == "disguise" then
      return w
    end
  end
  return "face down"
end

function Faces.hide(obj, kind, seat)
  if obj == nil or obj.isDestroyed() or Faces.isFaceDown(obj) then
    return
  end
  kind = kindOf(obj, kind)
  local ward = kind == "disguise" or kind == "cloak"
  local desc = ""
  pcall(function() desc = obj.getDescription() end)
  local data = {
    v = 1, name = "Face-down creature", types = { "Creature" }, typeLine = "Creature",
    power = "2", toughness = "2", oracle = ward and "Ward {2}" or "", keywords = ward and { "Ward" } or {},
    colors = {}, faceDown = true, kind = kind, seat = seat,
    real = obj.getGMNotes(), realName = obj.getName(), realDesc = desc,
  }
  obj.setGMNotes(JSON.encode(data))
  obj.setName("Face-down creature")
  pcall(function() obj.setDescription("2/2 face-down creature (" .. kind .. ")" .. (ward and ", ward {2}" or "")) end)
  setupLater(obj)
  if seat then
    broadcastToColor("Face down: " .. tostring(data.realName) .. " (" .. kind .. "). Right-click > Peek to check it.",
      seat, INFO)
  end
end

-- Back to its real self. Returns its name.
local function restore(obj)
  local _, d = realData(obj)
  if d == nil then
    return obj.getName()
  end
  obj.setGMNotes(d.real or "")
  obj.setName(d.realName or "Card")
  pcall(function() obj.setDescription(d.realDesc or "") end)
  setupLater(obj)
  return d.realName or "Card"
end

local function seatOf(obj)
  local loc = Zones.regionAt(obj.getPosition())
  return loc.seat
end

-- Turn it face up: "When ~ is turned face up" goes on the stack.
function Faces.turnUp(obj, byColor, flipIt)
  if not Faces.isFaceDown(obj) then
    return
  end
  local real, d = realData(obj)
  local kind = d.kind
  local name = restore(obj)
  if flipIt and obj.is_face_down then
    local r = obj.getRotation()
    obj.setRotationSmooth({ r.x, r.y, 0 }, false, true)
  end
  local cost = tostring(real.oracle or ""):match("[Mm]orph (%b{}[{}%w]*)") or tostring(real.oracle or ""):match("Disguise (%b{}[{}%w]*)")
  printToAll("MTG > " .. tostring(byColor or seatOf(obj) or "?") .. " turned " .. name .. " face up"
    .. (cost and (" (" .. kind .. " " .. cost .. ")") or "") .. ".", GOOD)
  if kind == "megamorph" then
    Counters.place(obj, "plus", 1, byColor)
  end
  local seat = seatOf(obj) or byColor
  local oracle = tostring(real.oracle or "")
  local low = oracle:lower()
  local short = name:match("^([^,]+),") or name
  for _, n in ipairs({ name, short }) do
    low = low:gsub(n:lower():gsub("([%%%-%.%+%*%?%[%]%^%$%(%)])", "%%%1"), "~")
  end
  low = low:gsub("this creature", "~")
  local at = low:find("when ~ is turned face up", 1, true)
  if at and Stack and seat then
    -- Its text from the card itself (original case), that paragraph.
    local stop = oracle:find("\n", at, true) or (#oracle + 1)
    Stack.pushAbility(seat, name, oracle:sub(at, stop - 1), "", { trigger = true, source = obj.getGUID() })
  end
  Wait.frames(function()
    if not obj.isDestroyed() then
      Counters.render(obj)
    end
  end, 2)
end

function Faces.peek(obj, color)
  if not Faces.isFaceDown(obj) then
    return
  end
  local seat = seatOf(obj)
  local real, d = realData(obj)
  if color ~= seat and color ~= d.seat and not GameState.solo() then
    broadcastToColor("Only its controller can look at a face-down card.", color, INFO)
    return
  end
  broadcastToColor("Face down: " .. tostring(d.realName) .. " (" .. tostring(d.kind) .. ")\n" .. tostring(real.oracle or ""),
    color, { 0.35, 0.95, 1 })
end

-- Right-click in hand: cast it face down.
function Faces.castFaceDown(obj, color)
  if obj == nil or obj.isDestroyed() then
    return
  end
  Faces.hide(obj, nil, color)
  local s = TableSetup.seat(color)
  obj.setRotation({ 0, s.yaw, 180 })
  Stack.pushCard(obj, color, { seat = color, region = "hand" })
  printToAll("MTG > " .. color .. " cast a face-down creature (pay {3}).", INFO)
end

function Faces.addFaceDownMenu(obj)
  if Faces.isFaceDown(obj) then
    obj.addContextMenuItem("Peek (face-down card)", function(color)
      if not obj.isDestroyed() then
        Faces.peek(obj, color)
      end
    end)
    obj.addContextMenuItem("Turn face up", function(color)
      if obj.isDestroyed() then
        return
      end
      local seat = seatOf(obj)
      if seat and color ~= seat and not GameState.solo() then
        broadcastToColor("That's " .. seat .. "'s card.", color, INFO)
        return
      end
      Faces.turnUp(obj, color, true)
    end)
    return
  end
  if kindOf(obj) == "face down" then
    return
  end
  if Counters.regionOf(obj) ~= "hand" then
    return   -- Cast face down works from a hand
  end
  obj.addContextMenuItem("Cast face down", function(color)
    if not obj.isDestroyed() then
      local loc = Zones.locationOf(obj)
      if loc and loc.region ~= "hand" then
        broadcastToColor("Cast face down works from your hand.", color, INFO)
        return
      end
      Faces.castFaceDown(obj, color)
    end
  end)
end

-- Manifest / cloak: the top card of the library onto the battlefield face down.
function Faces.manifest(seat, kind, sourceName)
  local lib = Library.find(seat)
  if lib == nil then
    broadcastToColor(sourceName .. ": your library is empty.", seat, INFO)
    return
  end
  local s = TableSetup.seat(seat)
  local pos = TableSetup.slot(seat, "battlefield", 2)
  local function done(card)
    Faces.hide(card, kind, seat)
    Wait.time(function()
      if not card.isDestroyed() then
        Zones.refresh(card)
      end
    end, 1)
    printToAll("MTG > " .. seat .. " " .. (kind == "cloak" and "cloaked" or "manifested") .. " the top card of their library ("
      .. sourceName .. ").", GOOD)
  end
  if lib.type == "Deck" then
    lib.takeObject({ index = 0, position = pos, rotation = { 0, s.yaw, 180 }, smooth = true, callback_function = done })
  else
    lib.setPositionSmooth(pos)
    lib.setRotationSmooth({ 0, s.yaw, 180 })
    done(lib)
  end
end

-- Entering the battlefield face down (dropped there flipped): a 2/2 before
-- the triggers look at it.
Events.onFirst("cardMoved", function(d)
  local card = d.card
  if card == nil or card.isDestroyed() or d.to == nil or not card.is_face_down then
    return
  end
  local isOn = d.to.region == "battlefield" or d.to.region == "lands"
  local wasOn = d.from and (d.from.region == "battlefield" or d.from.region == "lands")
  if isOn and not wasOn and not Faces.isFaceDown(card) then
    Faces.hide(card, nil, d.to.seat)
  end
end)

-- Leaving the battlefield face down: it's revealed.
Events.on("cardMoved", function(d)
  local card = d.card
  if card == nil or card.isDestroyed() or d.to == nil or not Faces.isFaceDown(card) then
    return
  end
  local wasOn = d.from and (d.from.region == "battlefield" or d.from.region == "lands" or d.from.region == "stack")
  local isOn = d.to.region == "battlefield" or d.to.region == "lands" or d.to.region == "stack"
  if wasOn and not isOn then
    local name = restore(card)
    printToAll("MTG > The face-down card was " .. name .. ".", INFO)
  end
end)

-- A player flipped a card with F (main.lua: onObjectRotate).
function Faces.onRotate(obj, flip, oldFlip, color)
  if obj == nil or obj.isDestroyed() or obj.type ~= "Card" or not obj.hasTag("MTGCard") then
    return
  end
  if flip == oldFlip then
    return
  end
  local loc = Zones.regionAt(obj.getPosition())
  if not (loc.region == "battlefield" or loc.region == "lands") then
    return
  end
  local down = math.abs(((flip or 0) % 360) - 180) < 30
  if down and not Faces.isFaceDown(obj) then
    Faces.hide(obj, nil, loc.seat)
    printToAll("MTG > " .. tostring(color or loc.seat) .. " turned a card face down.", INFO)
    Wait.frames(function()
      if not obj.isDestroyed() then
        Counters.render(obj)
      end
    end, 2)
  elseif not down and Faces.isFaceDown(obj) then
    Faces.turnUp(obj, color or loc.seat, false)
  end
end
