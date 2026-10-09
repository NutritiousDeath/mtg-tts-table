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

-- tp / tt: power / toughness changes until end of turn ("gets +2/+0 until
-- end of turn", effects.lua); they can be negative and clear at cleanup.
local KINDS = { "plus", "minus", "loyalty", "other", "tp", "tt" }

local ON_BATTLEFIELD = { battlefield = true, lands = true }

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

local function isCard(obj)
  return obj ~= nil and obj.type == "Card" and obj.hasTag("MTGCard")
end

-- Counters on a card: { plus, minus, loyalty, other } (missing = 0).
-- Last known counters per GUID, so a card that turns into a new object
-- (double-faced cards changing face, faces.lua) keeps them.
local memoOf = {}

function Counters.carry(old, obj)
  local m = memoOf[old]
  if m ~= nil then
    obj.memo = m
  end
  memoOf[obj.getGUID()] = obj.memo
  memoOf[old] = nil
end

function Counters.get(obj)
  local c = { plus = 0, minus = 0, loyalty = 0, other = 0, tp = 0, tt = 0 }
  local memo = obj and obj.memo
  if obj and memo then
    pcall(function() memoOf[obj.getGUID()] = memo end)
  end
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
  memoOf[obj.getGUID()] = obj.memo
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
  -- Equipment / Auras attached to it (equip.lua).
  local eqP, eqT = 0, 0
  if Equip and Equip.bonus then
    eqP, eqT = Equip.bonus(obj)
  end
  local function apply(v, extra)
    local n = tonumber(v)
    return n and (n + bonus + extra) or v
  end
  return {
    power = data.power and apply(data.power, c.tp + eqP) or nil,
    toughness = data.toughness and apply(data.toughness, c.tt + eqT) or nil,
    loyalty = c.loyalty,
    counters = c,
  }
end

---------------------------------------------------------------------------
-- Display
---------------------------------------------------------------------------

function counters_noop() end

-- GUID -> index of the card's Zzz button (set by render, used by the animation).
local sickIndex = {}
local SLEEP_FRAMES = { "z", "zZ", "zZz", "ZzZ", "Zz", "z" }
local frame = 0
local animating = false

-- Every 0.5 s: the Zzz on summoning-sick creatures cycles z / zZ / zZz...
-- and creatures whose sickness has ended lose it (or gain it).
function Counters.animate()
  if animating then
    return
  end
  animating = true
  Wait.time(function()
    frame = frame % #SLEEP_FRAMES + 1
    if not (GameState.data and GameState.data.started) then
      return
    end
    for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
      if obj.type == "Card" and not obj.isDestroyed() then
        local g = obj.getGUID()
        local sick = Combat and Combat.isSick and Combat.isSick(obj)
        local has = sickIndex[g] ~= nil
        if sick ~= has then
          Counters.render(obj)
        elseif has then
          pcall(function()
            obj.editButton({ index = sickIndex[g], label = SLEEP_FRAMES[frame] })
          end)
        end
      end
    end
  end, 0.5, -1)
end

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
  if Effects and Effects.decorate then
    Effects.decorate(obj)
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
  if Library and Library.decorateRevealed then Library.decorateRevealed(obj) end
  local c = Counters.get(obj)
  -- Each counter type is two short lines (name over number) so the text can
  -- be large and still fit inside the card's width.
  local lines = {}
  local bonus = c.plus - c.minus
  if bonus ~= 0 then
    local sign = bonus > 0 and "+" or ""
    table.insert(lines, sign .. bonus .. "/" .. sign .. bonus)
  end
  if c.tp ~= 0 or c.tt ~= 0 then
    local function sg(n)
      return (n >= 0 and "+" or "") .. n
    end
    table.insert(lines, sg(c.tp) .. "/" .. sg(c.tt) .. " (turn)")
  end
  local eqP, eqT = 0, 0
  if Equip and Equip.bonus then
    eqP, eqT = Equip.bonus(obj)
  end
  if eqP ~= 0 or eqT ~= 0 then
    local function sg2(n)
      return (n >= 0 and "+" or "") .. n
    end
    table.insert(lines, sg2(eqP) .. "/" .. sg2(eqT) .. " (equip)")
  end
  if bonus ~= 0 or c.tp ~= 0 or c.tt ~= 0 or eqP ~= 0 or eqT ~= 0 then
    local st = Counters.stats(obj)
    if type(st.power) == "number" and type(st.toughness) == "number" then
      table.insert(lines, st.power .. "/" .. st.toughness)
    end
  end
  -- Keywords gained until end of turn, and from attached equipment.
  local kws = Counters.tempKeywords(obj)
  if Equip and Equip.keywordList then
    for _, k in ipairs(Equip.keywordList(obj)) do
      table.insert(kws, k)
    end
  end
  if #kws > 0 then
    table.insert(lines, table.concat(kws, ", "))
  end
  local pro = Equip and Equip.protectionOf and Equip.protectionOf(obj) or {}
  if #pro > 0 then
    table.insert(lines, "PRO " .. table.concat(pro, ", "))
  end
  local ringBadge = Ring and Ring.badge and Ring.badge(obj)
  if ringBadge then
    table.insert(lines, ringBadge)
  end
  local badge = Equip and Equip.badge and Equip.badge(obj)
  if badge then
    table.insert(lines, badge)
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
  if Actions and Actions.skipsUntap and Actions.skipsUntap(obj) then
    table.insert(lines, "NO UNTAP")
  end
  if Counters.goadedBy(obj) then
    -- GOADED badge across the top of the card.
    obj.createButton({
      click_function = "counters_noop",
      function_owner = Global,
      label = "GOADED (" .. string.upper(Counters.goadedBy(obj)) .. ")",
      tooltip = "Goaded: attacks each combat if able, and attacks a player other than " .. Counters.goadedBy(obj) .. " if able.",
      position = { 0, 0.3, -1.3 },
      rotation = { 0, 0, 0 },
      width = 880, height = 230, font_size = 170,
      font_color = { 1, 1, 1 },
      color = { 0.85, 0.3, 0.1, 0.92 },
    })
  end
  -- Summoning sickness: an animated "Zzz" badge (see Counters.animate).
  sickIndex[obj.getGUID()] = nil
  if Combat and Combat.isSick and Combat.isSick(obj) then
    obj.createButton({
      click_function = "counters_noop",
      function_owner = Global,
      label = "Zzz",
      tooltip = "Summoning sick: came in this turn, can't attack or use {T} abilities until its controller's next turn (unless it has haste).",
      position = { 0.55, 0.3, 1.25 },
      rotation = { 0, 0, 0 },
      width = 520, height = 260, font_size = 190,
      font_color = { 0.75, 0.9, 1 },
      color = { 0.1, 0.18, 0.4, 0.88 },
    })
    sickIndex[obj.getGUID()] = #obj.getButtons() - 1
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

---------------------------------------------------------------------------
-- Goad: a GOADED badge on the creature until the goader's next turn. Kept
-- in GameState (not the card's memo) so "whenever a goaded creature dies"
-- can still see it after the card has left the battlefield.
---------------------------------------------------------------------------

local function goads()
  GameState.data.goaded = GameState.data.goaded or {}
  return GameState.data.goaded
end

function Counters.goadedBy(obj)
  local ok, g = pcall(function() return obj.getGUID() end)
  return ok and goads()[g] or nil
end

function Counters.setGoad(obj, seat)
  if not isCard(obj) then
    return
  end
  local g = obj.getGUID()
  if seat == nil then
    goads()[g] = nil
  else
    goads()[g] = seat
  end
  Counters.render(obj)
end

-- The goader's turn begins: their goads end.
function Counters.endGoadsBy(seat)
  for guid, by in pairs(goads()) do
    if by == seat then
      goads()[guid] = nil
      local o = getObjectFromGUID(guid)
      if o and not o.isDestroyed() then
        Counters.render(o)
      end
    end
  end
end

function Counters.change(obj, kind, delta, byColor)
  if not isCard(obj) then
    return
  end
  local c = Counters.get(obj)
  if kind == "tp" or kind == "tt" then
    c[kind] = (c[kind] or 0) + delta
  else
    c[kind] = math.max(0, (c[kind] or 0) + delta)
  end
  -- +1/+1 and -1/-1 counters cancel out in pairs.
  local cancel = math.min(c.plus, c.minus)
  c.plus, c.minus = c.plus - cancel, c.minus - cancel
  save(obj, c)
  Counters.render(obj)
  if delta < 0 or kind == "minus" then
    Counters.checkDeath(obj)
  end
  if delta > 0 and kind ~= "tp" and kind ~= "tt" and Triggers and Triggers.onCounters then
    Triggers.onCounters(obj, kind, delta, byColor)
  end
end

-- State-based actions: a planeswalker with 0 loyalty, or a creature with 0
-- or less toughness, goes to the graveyard. Checked a moment later, so a
-- misclick on a loyalty box can be clicked back first.
local pendingCheck = {}

function Counters.checkDeath(obj)
  local guid = obj.getGUID()
  if pendingCheck[guid] then
    return
  end
  pendingCheck[guid] = true
  Wait.time(function()
    pendingCheck[guid] = nil
    if obj == nil or obj.isDestroyed() or obj.is_face_down and not (Faces and Faces.isFaceDown(obj)) then
      return
    end
    if not (Zones and ON_BATTLEFIELD[Zones.regionAt(obj.getPosition()).region]) then
      return
    end
    local data = cardData(obj)
    local types = {}
    for _, t in ipairs(data.types or {}) do
      types[tostring(t):lower()] = true
    end
    local s = Counters.stats(obj)
    local why
    if types.planeswalker and (s.loyalty or 0) <= 0 then
      why = "has 0 loyalty"
    elseif types.creature and tonumber(s.toughness or "") and tonumber(s.toughness) <= 0 then
      why = "has 0 toughness"
    end
    if why and Combat and Combat.removeCard then
      printToAll("MTG > " .. obj.getName() .. " " .. why .. " and goes to the graveyard.", { 1, 0.6, 0.2 })
      Combat.removeCard(obj, "graveyard")
    end
  end, 2)
end

-- Keywords gained until end of turn ("gains trample until end of turn"):
-- kept in the game state by card, cleared at cleanup.
function Counters.tempKeywords(obj)
  local all = GameState.data and GameState.data.tempKeywords or {}
  local list = {}
  for k in pairs(all[obj.getGUID()] or {}) do
    table.insert(list, k)
  end
  table.sort(list)
  return list
end

function Counters.addTempKeyword(obj, kw)
  GameState.data.tempKeywords = GameState.data.tempKeywords or {}
  local t = GameState.data.tempKeywords
  t[obj.getGUID()] = t[obj.getGUID()] or {}
  t[obj.getGUID()][kw:lower()] = true
  Counters.render(obj)
end

function Counters.hasTempKeyword(obj, kw)
  local t = GameState.data and GameState.data.tempKeywords
  return t ~= nil and t[obj.getGUID()] ~= nil and t[obj.getGUID()][kw:lower()] == true
end

-- Cleanup step: "until end of turn" ends.
function Counters.endOfTurn()
  GameState.data.tempKeywords = {}
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and obj.memo and obj.memo ~= "" then
      local c = Counters.get(obj)
      if c.tp ~= 0 or c.tt ~= 0 then
        c.tp, c.tt = 0, 0
        save(obj, c)
      end
      Counters.render(obj)
    end
  end
end

Events.on("stepStarted", function(d)
  Wait.frames(Counters.refreshMenus, 2)
  if d.step == "untap" and d.seat then
    Counters.endGoadsBy(d.seat)
  end
  if d.step == "cleanup" then
    local had = GameState.data.tempKeywords and next(GameState.data.tempKeywords) ~= nil
    Counters.endOfTurn()
    if had then
      Counters.renderAll()
    end
  end
end)

function Counters.renderAll()
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" then
      Counters.render(obj)
    end
  end
end

function Counters.clear(obj)
  if not isCard(obj) then
    return
  end
  obj.memo = ""
  obj.clearButtons()
  if Library and Library.decorateRevealed then Library.decorateRevealed(obj) end
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

local menuSigs = {}   -- [guid] = what the card's menu was built for

-- What decides a card's menu: where it is, and (on the battlefield) the
-- combat step.
-- Where a card is: tracked location first (that's how hands are known),
-- else the area under it.
function Counters.regionOf(obj)
  if Zones == nil then
    return ""
  end
  local loc = Zones.locationOf(obj)
  if loc then
    return loc.region
  end
  return Zones.regionAt(obj.getPosition()).region
end

function Counters.menuSig(obj)
  local region = Counters.regionOf(obj)
  local step = ""
  if ON_BATTLEFIELD[region] and Combat and Combat.menuStep then
    step = Combat.menuStep()
  end
  local att = (Equip and Equip.isAttachment(obj) and Equip.hostOf(obj)) and "|attached" or ""
  return region .. "|" .. step .. att
end

-- Rebuild the menu if what it was built for has changed.
function Counters.refreshMenu(obj)
  if obj ~= nil and not obj.isDestroyed() and obj.type == "Card" and obj.hasTag("MTGCard")
      and menuSigs[obj.getGUID()] ~= Counters.menuSig(obj) then
    Counters.setup(obj)
  end
end

function Counters.refreshMenus()
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    Counters.refreshMenu(obj)
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
  -- The right-click list only holds what makes sense where the card is:
  -- counters and abilities on the battlefield, Cast face down in a hand,
  -- combat items during combat. Rebuilt when the card moves or the step
  -- changes (see menuSig below).
  local region = Counters.regionOf(obj)
  obj.clearContextMenu()
  menuSigs[obj.getGUID()] = Counters.menuSig(obj)
  if LibSearch and LibSearch.addMenu then
    LibSearch.addMenu(obj)
  end
  if Library and Library.addRevealedMenu then Library.addRevealedMenu(obj) end
  if Equip and Equip.addMenu then Equip.addMenu(obj) end
  if onField then
    for _, item in ipairs(menuFor(obj)) do
      obj.addContextMenuItem(item[1], function(playerColor)
        Counters.change(obj, item[2], item[3], playerColor)
      end, true)
    end
    obj.addContextMenuItem("Clear counters", function() Counters.clear(obj) end)
    if cardData(obj).typeLine and cardData(obj).typeLine:find("Creature", 1, true) then
      obj.addContextMenuItem("Goad / remove goad", function(playerColor)
        if Counters.goadedBy(obj) then
          Counters.setGoad(obj, nil)
          printToAll("MTG > " .. obj.getName() .. " isn't goaded any more.", { 0.75, 0.8, 0.9 })
        else
          Counters.setGoad(obj, playerColor)
          printToAll("MTG > " .. obj.getName() .. " is goaded by " .. tostring(playerColor)
            .. " (attacks each combat if able, and a player other than them if able).", { 1, 0.6, 0.2 })
        end
      end)
    end
    obj.addContextMenuItem("Skip next untap / untap normally", function(playerColor)
      local on = not Actions.skipsUntap(obj)
      Actions.setSkipUntap(obj, on, playerColor)
      printToAll("MTG > " .. obj.getName() .. (on and " won't untap in its next untap step." or " untaps normally again."),
        { 0.75, 0.8, 0.9 })
    end)
  end
  if Stack and (onField or region == "hand" or region == "graveyard" or region == "exile" or region == "command") then
    Stack.addCardMenu(obj, onField)
  end
  if onField and Combat then
    Combat.addCardMenu(obj)
  end
  if Faces then
    Faces.addMenu(obj)
  end
  if Combat and Combat.isCommander and region ~= "command" and Combat.isCommander(obj) then
    obj.addContextMenuItem("Send to command zone", function(playerColor)
      Combat.toCommandZone(obj, playerColor)
    end)
  end
  -- Anyone can delete a card this way (TTS normally needs a promoted player).
  obj.addContextMenuItem("Delete card", function(playerColor) Counters.deleteCard(obj, playerColor) end)
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
  Wait.frames(function() Counters.refreshMenu(d.card) end, 2)
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
