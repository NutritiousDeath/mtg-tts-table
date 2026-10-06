--[[
  counters.lua
  Counters on cards: +1/+1, -1/-1, loyalty, and a generic counter.

  Adding/removing counters:
    - Right-click a card: menu items for the counters that fit it
      (creatures: +1/+1 and -1/-1; planeswalkers: loyalty; others: a
      generic counter), plus "Clear counters".
    - Hotkeys (bind them in TTS: Options > Game Keys, under "Scripting"):
      "MTG: +1/+1 counter", "MTG: -1/-1 counter", "MTG: remove +1/+1",
      "MTG: loyalty +1", "MTG: loyalty -1", "MTG: counter +1",
      "MTG: counter -1", "MTG: clear counters". They act on the card under
      your mouse.

  Display: a label over the card's art, each counter type as two lines
  (name over number), e.g. "Loyalty / 5", "+2/+2 / 4/5", "Counters / 3".

  Rules applied:
    - +1/+1 and -1/-1 counters on the same card cancel out in pairs.
    - Counters are removed when a card leaves the battlefield (uses the
      "cardMoved" event from zones.lua).
    - A planeswalker entering the battlefield starts with its printed loyalty.

  Stored on the card itself (its memo field), so counters survive saves and
  stay with the card. Other modules read them with Counters.get(card) and
  Counters.stats(card) (combat in Phase 7 uses current power/toughness).
--]]

Counters = {}

local KINDS = { "plus", "minus", "loyalty", "other" }

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

local function isCard(obj)
  return obj ~= nil and obj.type == "Card" and obj.hasTag("MTGCard")
end

-- Counters on a card: { plus, minus, loyalty, other } (missing = 0).
function Counters.get(obj)
  local c = { plus = 0, minus = 0, loyalty = 0, other = 0 }
  local memo = obj and obj.memo
  if memo and memo ~= "" then
    -- Simple "plus=2;minus=0;..." format: no JSON decoding needed.
    for k, v in memo:gmatch("(%a+)=(%-?%d+)") do
      if c[k] ~= nil then
        c[k] = tonumber(v)
      end
    end
  end
  return c
end

local function save(obj, c)
  local parts = {}
  for _, k in ipairs(KINDS) do
    if c[k] ~= 0 then
      table.insert(parts, k .. "=" .. c[k])
    end
  end
  obj.memo = table.concat(parts, ";")
end

-- The card's printed data (stored in GMNotes by the importer).
local function cardData(obj)
  local notes = obj.getGMNotes()
  if notes == nil or notes == "" then
    return {}
  end
  local ok, data = pcall(JSON.decode, notes)
  return ok and type(data) == "table" and data or {}
end

-- Current power/toughness/loyalty with counters applied. Values that aren't
-- plain numbers (like "*") stay as printed.
function Counters.stats(obj)
  local data = cardData(obj)
  local c = Counters.get(obj)
  local bonus = c.plus - c.minus
  local function apply(v)
    local n = tonumber(v)
    return n and (n + bonus) or v
  end
  return {
    power = data.power and apply(data.power) or nil,
    toughness = data.toughness and apply(data.toughness) or nil,
    loyalty = c.loyalty,
    counters = c,
  }
end

---------------------------------------------------------------------------
-- Display
---------------------------------------------------------------------------

function counters_noop() end

-- Other modules' buttons on the card, drawn after the counters label
-- (render clears every button first): combat (combat.lua) and loyalty
-- abilities (walkers.lua).
function Counters.decorate(obj)
  if Combat then
    Combat.decorate(obj)
  end
  if Walkers then
    Walkers.decorate(obj)
  end
end

-- Label position on the card face (local units). Positive z is toward the
-- bottom of the card (rules text), so the art is at negative z.
local LABEL_Z = -0.75
local LABEL_Y = 0.25
local LABEL_FONT = 250

function Counters.render(obj)
  if not isCard(obj) then
    return
  end
  obj.clearButtons()
  local c = Counters.get(obj)
  -- Each counter type is two short lines (name over number) so the text can
  -- be large and still fit inside the card's width.
  local lines = {}
  local bonus = c.plus - c.minus
  if bonus ~= 0 then
    local sign = bonus > 0 and "+" or ""
    table.insert(lines, sign .. bonus .. "/" .. sign .. bonus)
    local st = Counters.stats(obj)
    if type(st.power) == "number" and type(st.toughness) == "number" then
      table.insert(lines, st.power .. "/" .. st.toughness)
    end
  end
  -- Planeswalkers on the battlefield show loyalty on their loyalty box
  -- (walkers.lua) instead.
  if c.loyalty ~= 0 and not (Walkers and Walkers.handles(obj)) then
    table.insert(lines, "Loyalty")
    table.insert(lines, tostring(c.loyalty))
  end
  if c.other ~= 0 then
    table.insert(lines, "Counters")
    table.insert(lines, tostring(c.other))
  end
  if #lines == 0 then
    Counters.decorate(obj)
    return
  end
  obj.createButton({
    click_function = "counters_noop",
    function_owner = Global,
    label = table.concat(lines, "\n"),
    tooltip = "Counters (right-click the card to change)",
    position = { 0, LABEL_Y, LABEL_Z },
    rotation = { 0, 0, 0 },
    -- A real size: zero-size "label only" buttons weren't drawn in TTS.
    -- Narrower than the card (about 1050 wide in button units) so the
    -- label stays inside it.
    width = 880,
    height = 110 + math.floor(LABEL_FONT * 1.15) * #lines,
    font_size = LABEL_FONT,
    font_color = { 1, 1, 1 },
    color = { 0, 0, 0, 0.8 },
  })
  Counters.decorate(obj)
end

---------------------------------------------------------------------------
-- Changing counters
---------------------------------------------------------------------------

function Counters.change(obj, kind, delta, byColor)
  if not isCard(obj) then
    return
  end
  local c = Counters.get(obj)
  c[kind] = math.max(0, (c[kind] or 0) + delta)
  -- +1/+1 and -1/-1 counters cancel out in pairs.
  local cancel = math.min(c.plus, c.minus)
  c.plus, c.minus = c.plus - cancel, c.minus - cancel
  save(obj, c)
  Counters.render(obj)
end

function Counters.clear(obj)
  if not isCard(obj) then
    return
  end
  obj.memo = ""
  obj.clearButtons()
  Counters.decorate(obj)
end

---------------------------------------------------------------------------
-- Right-click menu and hotkeys
---------------------------------------------------------------------------

-- Right-click menu items by card type, kept short.
local MENU_CREATURE = {
  { "+1/+1 counter", "plus", 1 },
  { "Remove +1/+1 counter", "plus", -1 },
  { "-1/-1 counter", "minus", 1 },
  { "Remove -1/-1 counter", "minus", -1 },
}
local MENU_PLANESWALKER = {
  { "Loyalty +1", "loyalty", 1 },
  { "Loyalty -1", "loyalty", -1 },
}
local MENU_OTHER = {
  { "Counter +1", "other", 1 },
  { "Counter -1", "other", -1 },
}

local ON_BATTLEFIELD = { battlefield = true, lands = true }

local function typeLine(obj)
  return cardData(obj).typeLine or ""
end

local function menuFor(obj)
  local t = typeLine(obj)
  if t:find("Planeswalker", 1, true) then
    return MENU_PLANESWALKER
  end
  if t:find("Creature", 1, true) or t:find("Vehicle", 1, true) then
    return MENU_CREATURE
  end
  return MENU_OTHER
end

-- A planeswalker enters the battlefield with its printed loyalty.
local function startingLoyalty(obj)
  local printed = tonumber(cardData(obj).loyalty or "")
  if printed and Counters.get(obj).loyalty == 0 then
    local c = Counters.get(obj)
    c.loyalty = printed
    save(obj, c)
  end
end

-- Give a card its right-click menu items and draw its counters.
function Counters.setup(obj)
  if not isCard(obj) then
    return
  end
  local onField = false
  if Zones then
    onField = ON_BATTLEFIELD[Zones.regionAt(obj.getPosition()).region] == true
  end
  -- A card can carry stale counters if it merged into a pile before they
  -- could be cleared; anything not on the battlefield has none.
  if obj.memo and obj.memo ~= "" and Zones and not onField then
    obj.memo = ""
  end
  if onField then
    startingLoyalty(obj)
  end
  for _, item in ipairs(menuFor(obj)) do
    obj.addContextMenuItem(item[1], function(playerColor)
      Counters.change(obj, item[2], item[3], playerColor)
    end, true)
  end
  obj.addContextMenuItem("Clear counters", function() Counters.clear(obj) end)
  -- Anyone can delete a card this way (TTS normally needs a promoted player).
  obj.addContextMenuItem("Delete card", function(playerColor) Counters.deleteCard(obj, playerColor) end)
  if Stack then
    Stack.addCardMenu(obj)
  end
  if Combat then
    Combat.addCardMenu(obj)
  end
  Counters.render(obj)
end

-- Delete a card for a player (right-click "Delete card" or the hotkey).
-- Done by the table's script, so it works without being promoted. Said in
-- chat so everyone sees it.
function Counters.deleteCard(obj, playerColor)
  if obj == nil or obj.isDestroyed() or obj.type ~= "Card" then
    return
  end
  printToAll("MTG > " .. tostring(playerColor) .. " deleted " .. obj.getName() .. ".", { 0.75, 0.8, 0.9 })
  if Zones and Zones.forget then
    Zones.forget(obj.getGUID())
  end
  obj.destruct()
end

-- Debug (!counters): what's stored on a card.
function Counters.describe(obj)
  if not isCard(obj) then
    return "Hover over a card first."
  end
  local c = Counters.get(obj)
  return string.format("%s | stored: '%s' | +1/+1 %d, -1/-1 %d, loyalty %d, other %d | buttons on card: %d",
    obj.getName(), tostring(obj.memo), c.plus, c.minus, c.loyalty, c.other, #(obj.getButtons() or {}))
end

function Counters.registerHotkeys()
  local keys = {
    { "MTG: +1/+1 counter", "plus", 1 },
    { "MTG: remove +1/+1", "plus", -1 },
    { "MTG: -1/-1 counter", "minus", 1 },
    { "MTG: loyalty +1", "loyalty", 1 },
    { "MTG: loyalty -1", "loyalty", -1 },
    { "MTG: counter +1", "other", 1 },
    { "MTG: counter -1", "other", -1 },
  }
  addHotkey("MTG: delete card", function(playerColor, hovered)
    Counters.deleteCard(hovered, playerColor)
  end)
  for _, k in ipairs(keys) do
    addHotkey(k[1], function(playerColor, hovered)
      Counters.change(hovered, k[2], k[3], playerColor)
    end)
  end
  addHotkey("MTG: clear counters", function(playerColor, hovered)
    Counters.clear(hovered)
  end)
end

-- Set up every card already on the table (after a load or script reload).
function Counters.setupAll()
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    Counters.setup(obj)
  end
end

---------------------------------------------------------------------------
-- Leaving the battlefield removes counters
---------------------------------------------------------------------------

Events.on("cardMoved", function(d)
  local wasOn = d.from and ON_BATTLEFIELD[d.from.region]
  local isOn = d.to and ON_BATTLEFIELD[d.to.region]
  if d.card == nil or d.card.isDestroyed() then
    return
  end
  if wasOn and not isOn then
    -- Left the battlefield: counters go away.
    if d.card.memo and d.card.memo ~= "" then
      Counters.clear(d.card)
    end
  elseif isOn and not wasOn then
    -- Entered the battlefield: planeswalkers get their printed loyalty.
    startingLoyalty(d.card)
    Counters.render(d.card)
  end
end)
