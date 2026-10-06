--[[
  walkers.lua
  Planeswalker loyalty abilities as buttons on the card.

  Every planeswalker on a battlefield gets one button per loyalty ability
  ("+1", "-3", "0", "-X"...) down its right edge, read from the card's rules
  text (GM Notes). The tooltip shows the ability's text.

    Click        activate: pays the loyalty cost (counter on the card) and
                 puts the ability on the stack (stack.lua).
                 Checks: your planeswalker, your main phase, empty stack,
                 not used yet this turn, enough loyalty for a minus.
    Right-click  activate anyway, skipping those checks (for effects like
                 The Chain Veil or Oath of Teferi); said in chat.
    -X           puts the ability on the stack; take the X off yourself
                 (right-click the card > Loyalty -1).
  At 0 loyalty after paying, chat reminds you it goes to the graveyard.
--]]

Walkers = {}

local INFO = { 0.75, 0.8, 0.9 }
local WARN = { 1, 0.6, 0.2 }
local MINUS = "\226\136\146"   -- the "−" sign Scryfall uses in loyalty costs

local function cardData(obj)
  local notes = obj.getGMNotes and obj.getGMNotes() or ""
  if notes == "" then
    return {}
  end
  local ok, d = pcall(function() return JSON.decode(notes) end)
  return (ok and type(d) == "table") and d or {}
end

local function isWalker(obj)
  local d = cardData(obj)
  return tostring(d.typeLine or ""):find("Planeswalker", 1, true) ~= nil
end

-- Split text into lines without patterns (rules text can be long).
local function lines(text)
  local out, i = {}, 1
  while i <= #text do
    local j = text:find("\n", i, true)
    if not j then
      table.insert(out, text:sub(i))
      break
    end
    table.insert(out, text:sub(i, j - 1))
    i = j + 1
  end
  return out
end

-- Loyalty abilities: list of { label = "+1", cost = 1 (nil for X), text }.
local cache = {}
function Walkers.abilities(obj)
  local d = cardData(obj)
  local oracle = type(d.oracle) == "string" and d.oracle or ""
  local key = obj.getGUID() .. "|" .. tostring(d.name)
  if cache[key] then
    return cache[key]
  end
  local list = {}
  for _, line in ipairs(lines(oracle)) do
    local colon = line:find(":", 1, true)
    if colon and colon <= 8 then
      local head = line:sub(1, colon - 1)
      local plain = head
      if head:sub(1, #MINUS) == MINUS then
        plain = "-" .. head:sub(#MINUS + 1)
      end
      local sign, num = plain:match("^([%+%-]?)(%w+)$")
      if sign and (tonumber(num) or num == "X") and (sign ~= "" or num == "0") then
        local n = tonumber(num)
        local cost = n and (sign == "-" and -n or n) or nil
        table.insert(list, { label = sign .. num, cost = cost, text = line:sub(colon + 1):gsub("^%s+", "") })
      end
    end
  end
  cache[key] = list
  return list
end

---------------------------------------------------------------------------
-- Buttons (drawn from Counters.render, after the counters label)
---------------------------------------------------------------------------

local function controllerOf(obj)
  local loc = Zones.regionAt(obj.getPosition())
  if loc.region == "battlefield" or loc.region == "lands" then
    return loc.seat
  end
  return nil
end

local function usedThisTurn(obj)
  local used = GameState.data.walkersUsed or {}
  local t = GameState.data.turn or {}
  return used[obj.getGUID()] ~= nil and used[obj.getGUID()] == t.taken
end

function Walkers.decorate(obj)
  if obj.is_face_down or controllerOf(obj) == nil or not isWalker(obj) then
    return
  end
  local list = Walkers.abilities(obj)
  if #list == 0 then
    return
  end
  local used = usedThisTurn(obj)
  -- Down the card's right edge, spread over its lower two thirds.
  local top, bottom = -0.35, 1.25
  local step = #list > 1 and math.min(0.55, (bottom - top) / (#list - 1)) or 0
  for i, a in ipairs(list) do
    local plus = a.cost and a.cost > 0
    local zero = a.cost == 0
    local bg = plus and { 0.1, 0.45, 0.3, 0.95 } or (zero and { 0.25, 0.3, 0.4, 0.95 } or { 0.5, 0.1, 0.16, 0.95 })
    if used then
      bg = { 0.15, 0.17, 0.2, 0.9 }
    end
    obj.createButton({
      click_function = "walker_click_" .. i,
      function_owner = Global,
      label = a.label,
      tooltip = a.label .. ": " .. a.text .. (used and "\n(Already used a loyalty ability this turn)" or "")
        .. "\nClick: activate. Right-click: activate anyway (skip the checks).",
      position = { 1.38, 0.3, top + step * (i - 1) },
      rotation = { 0, 0, 0 },
      width = 300,
      height = 210,
      font_size = 150,
      font_color = { 1, 1, 1 },
      color = bg,
    })
  end
end

---------------------------------------------------------------------------
-- Activating
---------------------------------------------------------------------------

local function faceOf(obj)
  local face = ""
  pcall(function()
    for _, d in pairs(obj.getData().CustomDeck or {}) do
      face = d.FaceURL
      break
    end
  end)
  return face
end

function Walkers.activate(obj, i, color, force)
  local a = Walkers.abilities(obj)[i]
  if a == nil then
    return
  end
  local seat = controllerOf(obj)
  local t = GameState.data.turn or {}
  local loyalty = Counters.get(obj).loyalty
  if not force then
    local problem
    if seat ~= color then
      problem = "That's " .. tostring(seat) .. "'s planeswalker."
    elseif GameState.data.started and t.activeSeat ~= color then
      problem = "Loyalty abilities are used on your own turn."
    elseif GameState.data.started and t.stepIndex
        and Turns.STEPS[t.stepIndex].id ~= "main1" and Turns.STEPS[t.stepIndex].id ~= "main2" then
      problem = "Loyalty abilities are used in your main phase."
    elseif Stack and not Stack.isEmpty() then
      problem = "Loyalty abilities need an empty stack."
    elseif usedThisTurn(obj) then
      problem = obj.getName() .. " already used a loyalty ability this turn."
    elseif a.cost and a.cost < 0 and loyalty + a.cost < 0 then
      problem = obj.getName() .. " has only " .. loyalty .. " loyalty."
    end
    if problem then
      broadcastToColor(problem .. " (Right-click the button to do it anyway.)", color, WARN)
      return
    end
  end
  GameState.data.walkersUsed = GameState.data.walkersUsed or {}
  GameState.data.walkersUsed[obj.getGUID()] = t.taken or 0
  if a.cost and a.cost ~= 0 then
    Counters.change(obj, "loyalty", a.cost, color)
  else
    Counters.render(obj)
  end
  local who = seat or color
  if force then
    printToAll("MTG > " .. color .. " activates " .. obj.getName() .. " " .. a.label .. " (checks skipped).", WARN)
  end
  Stack.pushAbility(who, obj.getName(), a.label .. ": " .. a.text, faceOf(obj))
  if a.cost == nil then
    broadcastToColor("X ability: take X loyalty off " .. obj.getName() .. " yourself (right-click > Loyalty -1).",
      color, INFO)
  elseif Counters.get(obj).loyalty <= 0 then
    broadcastToAll(obj.getName() .. " has 0 loyalty: put it into its owner's graveyard.", WARN)
  end
end

-- Buttons call global functions by name: one per ability slot.
for i = 1, 8 do
  _G["walker_click_" .. i] = function(obj, color, alt)
    if obj and not obj.isDestroyed() then
      Walkers.activate(obj, i, color, alt)
    end
  end
end
