--[[
  cardwatch.lua
  Triggers the general reader can't watch, for cards seen in real games:
    Wedding Ring:  "Whenever an opponent who controls an artifact named Wedding Ring draws a card during their turn,
                   you draw a card." / "... gains life during their turn, you gain that much life."
    Coveted Jewel: "Whenever one or more creatures an opponent controls attack you and aren't blocked, that player
                   draws three cards and gains control of this artifact. Untap it."
  Each puts the trigger on the stack; effects.lua (CARD_FX) resolves it.
  triggers.lua calls CardWatch.drew / CardWatch.life; combat.lua's unblocked list carries each attacker's target.
--]]

CardWatch = {}

local RING_DRAW = "Whenever an opponent who controls an artifact named Wedding Ring draws a card during their turn, you draw a card."
local RING_LIFE = "Whenever an opponent who controls an artifact named Wedding Ring gains life during their turn, you gain that much life."
local JEWEL = "Whenever one or more creatures an opponent controls attack you and aren't blocked, that player draws three cards and gains control of this artifact. Untap it."

-- Lines handled here: triggers.lua doesn't call them "can't watch".
function CardWatch.handles(low)
  return low:find("who controls an artifact named wedding ring", 1, true) ~= nil
    or low:find("attack you and aren't blocked, that player draws three cards and gains control of this artifact", 1, true) ~= nil
end

local function onField(name)
  local out = {}
  for _, o in ipairs(getObjectsWithTag("MTGCard")) do
    if o.type == "Card" and not o.isDestroyed() and o.getName() == name and not (PlaneFx and PlaneFx.isPhased and PlaneFx.isPhased(o)) then
      local seat = Effects.fieldSeat(o)
      if seat then
        table.insert(out, { obj = o, seat = seat })
      end
    end
  end
  return out
end

local function face(o)
  local f = ""
  pcall(function() f = o.getCustomObject().face or "" end)
  return f
end

local function controls(seat, name)
  for _, e in ipairs(onField(name)) do
    if e.seat == seat then
      return true
    end
  end
  return false
end

local function ringFor(seat, text, amount)
  if not GameState.data.started or not Turns.isActiveSeat(seat) or not controls(seat, "Wedding Ring") then
    return
  end
  for _, e in ipairs(onField("Wedding Ring")) do
    if TableSetup.isOpponent(seat, e.seat) and Stack and Stack.pushAbility then
      Stack.pushAbility(e.seat, "Wedding Ring", text, face(e.obj), { trigger = true, source = e.obj.getGUID(), that = seat,
        amount = amount })
    end
  end
end

-- seat drew card (a real draw: library searches are filtered out in triggers.lua).
function CardWatch.drew(seat, card)
  ringFor(seat, RING_DRAW)
end

function CardWatch.life(seat, delta)
  if delta and delta > 0 then
    ringFor(seat, RING_LIFE, delta)
  end
end

-- list: { { obj, controller, target } } attackers nobody blocked.
function CardWatch.unblocked(list)
  local jewels = onField("Coveted Jewel")
  if #jewels == 0 then
    return
  end
  for _, j in ipairs(jewels) do
    local by = {}
    for _, u in ipairs(list) do
      if u.target == j.seat and u.controller and TableSetup.isOpponent(u.controller, j.seat) then
        by[u.controller] = true
      end
    end
    for attacker in pairs(by) do
      Stack.pushAbility(j.seat, "Coveted Jewel", JEWEL, face(j.obj), { trigger = true, source = j.obj.getGUID(), that = attacker })
    end
  end
end

-- Mishra's Bauble: "Draw a card at the beginning of the next turn's upkeep" (effects.lua records it).
Events.on("stepStarted", function(d)
  if d == nil or d.step ~= "upkeep" then
    return
  end
  local list = GameState.data and GameState.data.upkeepDraws
  if not list or #list == 0 then
    return
  end
  local now = (GameState.data.turn or {}).taken or 0
  local keep = {}
  for _, e in ipairs(list) do
    if now > (e.after or 0) then
      Actions.draw(e.seat, 1, e.name)
      printToAll("MTG > " .. tostring(e.name) .. ": " .. e.seat .. " draws a card (next turn's upkeep).", { 0.55, 0.9, 0.6 })
    else
      table.insert(keep, e)
    end
  end
  GameState.data.upkeepDraws = keep
end)
