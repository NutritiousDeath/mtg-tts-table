--[[
  saga.lua
  Sagas (CR 714): "As this Saga enters and after your draw step, add a lore counter. Sacrifice after III."
    * As a Saga enters it gets a lore counter; at the start of its controller's precombat main phase
      (right after the draw step) it gets another.
    * Each lore counter added triggers the chapter with that number ("I, II - Create a Treasure token."):
      the chapter's ability goes on the stack like any trigger.
    * Once it has as many lore counters as its last chapter and that chapter's ability has left the stack,
      it is sacrificed.
  The lore counters are the table's named counters (counters.lua), so they show on the card and can be
  changed by hand ("!counter lore 1" adds one: that does NOT trigger a chapter; this file does that itself).
--]]

Saga = {}

local GOOD = { 0.55, 0.9, 0.6 }
local INFO = { 0.75, 0.8, 0.9 }
local ROMAN = { i = 1, ii = 2, iii = 3, iv = 4, v = 5, vi = 6, vii = 7 }

local function store()
  GameState.data.sagas = GameState.data.sagas or {}   -- [guid] = { lastTurn = turn.taken }
  return GameState.data.sagas
end

local function oracleOf(obj)
  local ok, d = pcall(function() return CardData.get(obj) end)
  return ok and d and tostring(d.oracle or "") or "", ok and d and tostring(d.typeLine or "") or ""
end

function Saga.isSaga(obj)
  if obj == nil or obj.isDestroyed() then
    return false
  end
  local _, tl = oracleOf(obj)
  return tl:find("Saga", 1, true) ~= nil
end

-- { [n] = "effect text" } and the last chapter number.
function Saga.chapters(obj)
  local oracle = oracleOf(obj)
  local out, last = {}, 0
  for line in (oracle .. "\n"):gmatch("([^\n]*)\n") do
    local dash = line:find("—", 1, true)
    local headLen = 3
    if not dash then
      dash = line:find(" %- ")
      headLen = 1
      if dash then
        dash = dash + 1
      end
    end
    if dash and dash < 22 then
      local head = line:sub(1, dash - 1):lower()
      local body = line:sub(dash + headLen):gsub("%s*%b()", ""):gsub("^%s+", ""):gsub("%s+$", "")
      local nums, okHead = {}, true
      for w in head:gmatch("[^,%s]+") do
        if ROMAN[w] then
          table.insert(nums, ROMAN[w])
        else
          okHead = false
        end
      end
      if okHead and #nums > 0 and body ~= "" then
        for _, n in ipairs(nums) do
          out[n] = body
          if n > last then
            last = n
          end
        end
      end
    end
  end
  return out, last
end

function Saga.lore(obj)
  local named = Counters.named and Counters.named(obj) or {}
  return tonumber(named and named.lore) or 0
end

local function faceOf(obj)
  local ok, c = pcall(function() return obj.getCustomObject() end)
  return ok and c and c.face or ""
end

-- Sacrificed once its last chapter has resolved (no ability of it left on the stack).
local function sacrificeWhenDone(obj, last)
  local g = obj.getGUID()
  local function pending()
    for _, e in ipairs(Stack.entries()) do
      if e.source == g then
        return true
      end
    end
    return false
  end
  Wait.condition(function()
    local o = getObjectFromGUID(g)
    if o == nil or o.isDestroyed() or not (Effects.fieldSeat and Effects.fieldSeat(o)) then
      return
    end
    if Saga.lore(o) >= last then
      printToAll("MTG > " .. o.getName() .. " (Saga) is sacrificed after its last chapter.", GOOD)
      store()[g] = nil
      Combat.sacrifice(o)
    end
  end, function()
    local o = getObjectFromGUID(g)
    return o == nil or o.isDestroyed() or not pending()
  end, 600)
end

-- Add one lore counter and trigger that chapter.
function Saga.addLore(obj, seat, why)
  local chapters, last = Saga.chapters(obj)
  if last == 0 then
    return
  end
  Counters.addNamed(obj, "lore", 1, seat)
  local n = Saga.lore(obj)
  printToAll("MTG > " .. obj.getName() .. ": lore counter " .. n .. (why and (" (" .. why .. ")") or "") .. ".", INFO)
  local text = chapters[n]
  if text then
    Stack.pushAbility(seat, obj.getName(), text, faceOf(obj), { trigger = true, source = obj.getGUID() })
  end
  if n >= last then
    Wait.time(function() sacrificeWhenDone(obj, last) end, 1)
  end
end

-- A Saga entering the battlefield: its first lore counter.
Events.on("cardMoved", function(d)
  if not (GameState.data and GameState.data.started) or d.card == nil or d.from == nil or d.to == nil then
    return
  end
  local into = d.to.region == "battlefield" or d.to.region == "lands"
  local was = d.from.region == "battlefield" or d.from.region == "lands"
  if not into or was or d.to.seat == nil then
    if was and not into and d.card and not d.card.isDestroyed() then
      store()[d.card.getGUID()] = nil
    end
    return
  end
  local card = d.card
  if card.isDestroyed() or (Faces and Faces.unknown and Faces.unknown(card)) or not Saga.isSaga(card) then
    return
  end
  local st = store()
  local g = card.getGUID()
  if st[g] then
    return   -- already counted (a re-check of the same card)
  end
  local t = GameState.data.turn or {}
  st[g] = { lastTurn = t.taken, seat = d.to.seat }
  Wait.time(function()
    if not card.isDestroyed() then
      Saga.addLore(card, d.to.seat, "it entered")
    end
  end, 0.8)
end)

-- After the draw step (the precombat main phase starts): each Saga its controller controls gets one.
Events.on("stepStarted", function(d)
  if not (GameState.data and GameState.data.started) or d.step ~= "main1" or d.seat == nil then
    return
  end
  local t = GameState.data.turn or {}
  local st = store()
  for g, rec in pairs(st) do
    local o = getObjectFromGUID(g)
    if o == nil or o.isDestroyed() then
      st[g] = nil
    else
      local seat = Effects.fieldSeat and Effects.fieldSeat(o)
      if seat == nil then
        st[g] = nil
      elseif seat == d.seat and rec.lastTurn ~= t.taken then
        rec.lastTurn = t.taken
        Saga.addLore(o, seat, "after the draw step")
      end
    end
  end
end)
