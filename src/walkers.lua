--[[
  walkers.lua
  Planeswalker loyalty abilities as buttons on the card.

  Every planeswalker on a battlefield gets a button on each printed loyalty
  cost shield ("+1", "-3", "0", "-X"...), read from the card's rules text
  (GM Notes); the tooltip shows the ability's text. Its loyalty box (bottom
  right) shows the current loyalty: click +1, right-click -1.

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
-- A loyalty cost before the colon: "+1", "0", "−3", "−X". Scryfall's minus is
-- the "−" character, which TTS's Lua sees as one character (not the 3 bytes
-- standard Lua sees), so any short non-alphanumeric prefix counts as minus.
-- Returns sign ("+", "-" or ""), number text; nil if it isn't a cost.
local function parseCost(head)
  head = head:gsub("^%s+", ""):gsub("%s+$", "")
  local num = head:match("([%dX]+)$")
  if num == nil or (num ~= "X" and tonumber(num) == nil) then
    return nil
  end
  local prefix = head:sub(1, #head - #num)
  if prefix == "" then
    if num == "0" then
      return "", num
    end
    return nil
  end
  if prefix == "+" then
    return "+", num
  end
  -- Plain ASCII letter/digit test: TTS's Lua counts letters like "â" as %w.
  if #prefix <= 3 and not prefix:find("[A-Za-z0-9 ]") then
    return "-", num
  end
  return nil
end

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
      local sign, num = parseCost(line:sub(1, colon - 1))
      if sign then
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

-- Card face in local units (TTS card at scale 1): x to the right, z toward
-- the bottom of the card. Positions below are fractions of the card image,
-- measured on a Scryfall planeswalker (Wrenn and Seven, 4 abilities); the
-- 3-ability frame's text box starts lower.
local HALF_W, HALF_H = 1.05, 1.47
local SHIELD_X = 0.075         -- loyalty cost shields, from the left edge
local LOYALTY_X, LOYALTY_Y = 0.877, 0.915   -- loyalty box, bottom right
local CHARS_PER_LINE = 48

local function at(fx, fy)
  return (fx - 0.5) * 2 * HALF_W, (fy - 0.5) * 2 * HALF_H
end

-- Where each loyalty ability's shield is (fraction of card height). The
-- text box is split between the paragraphs by how many lines each takes,
-- like the printed frame. Four or more paragraphs use the tall frame.
local function shieldRows(obj)
  local d = cardData(obj)
  local paras = {}
  for _, line in ipairs(lines(type(d.oracle) == "string" and d.oracle or "")) do
    if line ~= "" then
      table.insert(paras, line)
    end
  end
  local top = #paras >= 4 and 0.545 or 0.615
  local bottom = 0.89
  local weights, total = {}, 0
  for i, para in ipairs(paras) do
    local w = math.ceil(#para / CHARS_PER_LINE) + 2
    weights[i] = w
    total = total + w
  end
  local rows, acc = {}, 0
  local abil = 0
  for i, para in ipairs(paras) do
    local center = top + (bottom - top) * (acc + weights[i] / 2) / math.max(total, 1)
    acc = acc + weights[i]
    local colon = para:find(":", 1, true)
    if colon and colon <= 8 then
      if parseCost(para:sub(1, colon - 1)) then
        abil = abil + 1
        rows[abil] = center
      end
    end
  end
  return rows
end

-- Loyalty buttons are drawn here, so the counters label skips loyalty.
function Walkers.handles(obj)
  return not obj.is_face_down and controllerOf(obj) ~= nil and isWalker(obj)
end

local reported = {}

-- Draw the buttons; an error is shown once in chat instead of losing the
-- card's other buttons silently.
function Walkers.decorate(obj)
  local ok, err = pcall(Walkers.draw, obj)
  if not ok and not reported[tostring(err)] then
    reported[tostring(err)] = true
    printToAll("MTG > Planeswalker buttons failed on " .. tostring(obj.getName()) .. ": " .. tostring(err)
      .. " (please send this to Claude)", WARN)
  end
end

-- Debug (!walker): what the table reads on a planeswalker.
function Walkers.describe(obj)
  if obj == nil then
    return "Hover over a planeswalker first."
  end
  local d = cardData(obj)
  local out = { obj.getName() .. ": planeswalker " .. tostring(isWalker(obj)) .. ", on battlefield of "
    .. tostring(controllerOf(obj)) .. ", loyalty " .. tostring(Counters.get(obj).loyalty) }
  for _, line in ipairs(lines(type(d.oracle) == "string" and d.oracle or "")) do
    local colon = line:find(":", 1, true)
    local head = colon and line:sub(1, colon - 1) or ""
    local codes = {}
    for i = 1, math.min(#head, 6) do
      table.insert(codes, tostring(head:byte(i)))
    end
    local sign, num = parseCost(head)
    table.insert(out, "  [" .. head .. "] codes " .. table.concat(codes, ",") .. " -> "
      .. (sign and (sign .. num) or "not a cost"))
  end
  return table.concat(out, "\n")
end

function Walkers.draw(obj)
  if not Walkers.handles(obj) then
    return
  end
  local used = usedThisTurn(obj)
  -- Each cost button sits on its printed shield.
  local list = Walkers.abilities(obj)
  local rows = shieldRows(obj)
  for i, a in ipairs(list) do
    local x, z = at(SHIELD_X, rows[i] or (0.6 + 0.1 * i))
    obj.createButton({
      click_function = "walker_click_" .. i,
      function_owner = Global,
      label = a.label,
      tooltip = a.label .. ": " .. a.text .. (used and "\n(Already used a loyalty ability this turn)" or "")
        .. "\nClick: activate. Right-click: activate anyway (skip the checks).",
      position = { x, 0.3, z },
      rotation = { 0, 0, 0 },
      width = 125,
      height = 95,
      font_size = 62,
      font_color = used and { 0.5, 0.52, 0.56 } or { 1, 1, 1 },
      color = { 0.07, 0.07, 0.09, 0.95 },
    })
  end
  -- The loyalty box shows the current loyalty. Click +1, right-click -1.
  local x, z = at(LOYALTY_X, LOYALTY_Y)
  obj.createButton({
    click_function = "walker_loyalty",
    function_owner = Global,
    label = tostring(Counters.get(obj).loyalty),
    tooltip = "Loyalty " .. Counters.get(obj).loyalty .. "\nClick: +1. Right-click: -1.",
    position = { x, 0.3, z },
    rotation = { 0, 0, 0 },
    width = 150,
    height = 120,
    font_size = 100,
    font_color = { 1, 1, 1 },
    color = { 0.07, 0.07, 0.09, 0.97 },
  })
end

function walker_loyalty(obj, color, alt)
  if obj and not obj.isDestroyed() then
    Counters.change(obj, "loyalty", alt and -1 or 1, color)
    if Counters.get(obj).loyalty <= 0 then
      broadcastToAll(obj.getName() .. " has 0 loyalty: put it into its owner's graveyard.", WARN)
    end
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
  if GameState.solo() and seat then
    color = seat   -- solo test: you act for the planeswalker's controller
  end
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
