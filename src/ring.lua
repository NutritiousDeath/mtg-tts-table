--[[
  ring.lua
  "The Ring tempts you" (Lord of the Rings). Each player has a Ring level
  (1 to 4) and a Ring-bearer (a creature they control). Every temptation
  raises the level (up to 4) and lets the player choose the Ring-bearer.

    1  Your Ring-bearer is legendary and can't be blocked by creatures with greater power.
    2  Whenever your Ring-bearer attacks, draw a card, then discard a card.
    3  Whenever your Ring-bearer becomes blocked by a creature, that creature's controller
       sacrifices it at end of combat.
    4  Whenever your Ring-bearer deals combat damage to a player, each opponent loses 3 life.

  The table keeps the level and bearer, shows "RING-BEARER 2" on the card,
  stops illegal blocks at level 1+, and puts the level 2 and 4 triggers (and
  a level 3 reminder) on the stack. "Whenever the Ring tempts you" watchers
  (Sauron) are told through Triggers.onRing.
  !ring   (chat) the Ring tempts you, for a card the table doesn't read.
--]]

Ring = {}

local GOOD = { 0.55, 0.9, 0.6 }
local INFO = { 0.75, 0.8, 0.9 }

local LEVEL_TEXT = {
  "Level 1: your Ring-bearer is legendary and can't be blocked by creatures with greater power.",
  "Level 2: whenever your Ring-bearer attacks, draw a card, then discard a card.",
  "Level 3: whenever your Ring-bearer becomes blocked by a creature, that creature's controller sacrifices it at end of combat.",
  "Level 4: whenever your Ring-bearer deals combat damage to a player, each opponent loses 3 life.",
}

local function data()
  local d = GameState.data
  d.ring = d.ring or {}
  return d.ring
end

function Ring.level(seat)
  local r = data()[seat]
  return r and r.level or 0
end

function Ring.bearer(seat)
  local r = data()[seat]
  local obj = r and r.bearer and getObjectFromGUID(r.bearer) or nil
  if obj == nil or obj.isDestroyed() then
    return nil
  end
  return obj
end

-- Is this card some player's Ring-bearer? Returns the seat.
function Ring.isBearer(obj)
  if obj == nil or obj.isDestroyed() then
    return nil
  end
  local g = obj.getGUID()
  for seat, r in pairs(data()) do
    if r.bearer == g then
      return seat
    end
  end
  return nil
end

local function power(obj)
  local ok, st = pcall(function() return Counters.stats(obj) end)
  return ok and st and tonumber(st.power) or 0
end

-- Level 1+: can't be blocked by creatures with greater power.
function Ring.canBlock(attacker, blocker)
  local seat = Ring.isBearer(attacker)
  if seat and Ring.level(seat) >= 1 and power(blocker) > power(attacker) then
    return false, "is the Ring-bearer and " .. blocker.getName() .. " has greater power"
  end
  return true
end

local function fieldSeat(obj)
  local loc = Zones.regionAt(obj.getPosition())
  if loc.region == "battlefield" or loc.region == "lands" then
    return loc.seat
  end
  return nil
end

local function isCreature(obj)
  local ok, notes = pcall(function() return obj.getGMNotes() end)
  if not ok or notes == nil or notes == "" then
    return false
  end
  local ok2, d = pcall(function() return JSON.decode(notes) end)
  return ok2 and type(d) == "table" and tostring(d.typeLine or table.concat(d.types or {}, " ")):find("Creature", 1, true) ~= nil
end

local function setBearer(seat, obj)
  local r = data()[seat]
  local old = Ring.bearer(seat)
  r.bearer = obj and obj.getGUID() or nil
  if old and Counters then Counters.render(old) end
  if obj and Counters then Counters.render(obj) end
  if obj then
    printToAll("MTG > " .. obj.getName() .. " is " .. seat .. "'s Ring-bearer (Ring level " .. r.level .. ").", GOOD)
  end
end

-- The Ring tempts `seat`.
function Ring.tempt(seat)
  if seat == nil then
    return
  end
  local r = data()[seat] or { level = 0 }
  data()[seat] = r
  r.level = math.min(4, r.level + 1)
  printToAll("MTG > The Ring tempts " .. seat .. "! Ring level " .. r.level .. ".", { 1, 0.85, 0.3 })
  broadcastToColor(LEVEL_TEXT[r.level], seat, GOOD)
  local function done()
    if Triggers and Triggers.onRing then
      Triggers.onRing(seat)
    end
  end
  -- Choose the Ring-bearer: any creature they control.
  local choices = {}
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and fieldSeat(obj) == seat
        and isCreature(obj) then
      table.insert(choices, obj)
    end
  end
  if #choices == 0 then
    broadcastToColor("You control no creature: no Ring-bearer this time.", seat, INFO)
    done()
    return
  end
  if #choices == 1 or (GameState.solo() and not Player[seat].seated) then
    setBearer(seat, choices[1])
    done()
    return
  end
  local names = {}
  for _, o in ipairs(choices) do
    table.insert(names, o.getName())
  end
  Effects.askChoice(seat, "The Ring tempts you", "Choose your Ring-bearer: click TARGET on a creature you control.\nLegal: "
    .. table.concat(names, ", "), { { label = "KEEP", value = false } }, function(obj)
      if obj then
        setBearer(seat, obj)
      end
      done()
    end, { filter = function(obj, owner) return owner == seat and isCreature(obj) end, label = "RING-BEARER", protect = false })
end

-- Label line on the Ring-bearer.
function Ring.badge(obj)
  local seat = Ring.isBearer(obj)
  if seat then
    return "RING-BEARER " .. Ring.level(seat)
  end
  return nil
end

-- The Ring-bearer's own triggers for `kind` ("attacks", "blocked", "combatDamage"):
-- list of { obj, controller, text, name, guid }.
function Ring.triggers(obj, kind)
  local seat = Ring.isBearer(obj)
  if seat == nil then
    return {}
  end
  local lvl = Ring.level(seat)
  local text
  if kind == "attacks" and lvl >= 2 then
    text = "Whenever your Ring-bearer attacks, draw a card, then discard a card."
  elseif kind == "blocked" and lvl >= 3 then
    text = "Whenever your Ring-bearer becomes blocked by a creature, that creature's controller sacrifices it at end of combat."
  elseif kind == "combatDamage" and lvl >= 4 then
    text = "Whenever your Ring-bearer deals combat damage to a player, each opponent loses 3 life."
  end
  if text == nil then
    return {}
  end
  return { { obj = obj, controller = seat, text = text, name = "The Ring (level " .. lvl .. ")", guid = obj.getGUID() } }
end

-- A bearer leaving the battlefield loses the Ring until the next temptation.
Events.on("cardMoved", function(d)
  if d.card == nil or not d.from then
    return
  end
  if d.from.region ~= "battlefield" and d.from.region ~= "lands" then
    return
  end
  if d.to and (d.to.region == "battlefield" or d.to.region == "lands") then
    return
  end
  local seat = Ring.isBearer(d.card)
  if seat then
    data()[seat].bearer = nil
    printToAll("MTG > " .. tostring(d.name or "The Ring-bearer") .. " left the battlefield: " .. seat .. " has no Ring-bearer.", INFO)
  end
end)
