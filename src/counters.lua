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
-- pc / tc: "+1/+0" and "+0/+1" counters (they change power / toughness only).
local KINDS = { "plus", "minus", "loyalty", "other", "tp", "tt", "pc", "tc" }

-- The counter kind for the name on the card ("+1/+1", "+1/+0", "loyalty", "quest"...).
function Counters.kindOf(label)
  local l = tostring(label or "")
  return (l == "+1/+1" and "plus") or (l == "-1/-1" and "minus") or (l == "+1/+0" and "pc")
    or (l == "+0/+1" and "tc") or (l == "loyalty" and "loyalty") or "other"
end

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
  local c = { plus = 0, minus = 0, loyalty = 0, other = 0, tp = 0, tt = 0, pc = 0, tc = 0 }
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
  return CardData.get(obj)
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
  local sP, sT = 0, 0
  if Statics and Statics.bonus then
    sP, sT = Statics.bonus(obj)
  end
  local function apply(v, extra)
    local n = tonumber(v)
    return n and (n + bonus + extra) or v
  end
  return {
    power = data.power and apply(data.power, c.tp + c.pc + eqP + sP) or nil,
    toughness = data.toughness and apply(data.toughness, c.tt + c.tc + eqT + sT) or nil,
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
-- The animated Zzz re-sent a label to every player for every summoning-sick creature twice a second,
-- which is a lot of traffic with a board full of tokens. Off unless asked for (!zzz).
local ANIMATE_ZZZ = false
function Counters.setZzzAnimation(on)
  ANIMATE_ZZZ = on and true or false
  return ANIMATE_ZZZ
end

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
        -- Safety net: a planeswalker on the battlefield without its loyalty buttons gets them now
        -- (planeswalkers are never summoning sick: usable the turn they arrive).
        local walkerMissing = false
        if Walkers and Walkers.handles and Walkers.handles(obj) then
          local okb, btns = pcall(function() return obj.getButtons() end)
          local found = false
          if okb and btns then
            for _, b in pairs(btns) do
              if b.click_function == "walker_loyalty" then found = true end
            end
          end
          walkerMissing = not found
        end
        if walkerMissing then
          Counters.render(obj)
        elseif sick ~= has then
          Counters.render(obj)
        elseif has and ANIMATE_ZZZ then
          pcall(function()
            obj.editButton({ index = sickIndex[g], label = SLEEP_FRAMES[frame] })
          end)
        end
      end
    end
  end, 1, -1)
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
local INFO_FONT = 115    -- the smaller info label: breakdown, keywords, equipment
local INFO_WRAP = 19     -- characters per line that fit across the card at INFO_FONT

local function sgn(n)
  return (n >= 0 and "+" or "") .. n
end

-- Split text into lines of at most `n` characters, breaking at spaces.
local function wrap(text, n, out)
  local cur = ""
  for word in tostring(text):gmatch("%S+") do
    if cur == "" then
      cur = word
    elseif #cur + 1 + #word <= n then
      cur = cur .. " " .. word
    else
      table.insert(out, cur)
      cur = word
    end
  end
  if cur ~= "" then
    table.insert(out, cur)
  end
end

-- Two labels on the card, both inside its width:
--   big:   the creature's power/toughness now (when anything changes it), loyalty, other counters
--   small: where the change comes from, keywords it was given, equipment, protection, badges
function Counters.render(obj)
  if not isCard(obj) then
    return
  end
  obj.clearButtons()
  if Library and Library.decorateRevealed then Library.decorateRevealed(obj) end
  local c = Counters.get(obj)
  local big, info = {}, {}
  local pileBadge = Pile and Pile.badge and Pile.badge(obj)
  if pileBadge then
    table.insert(big, pileBadge)
  end
  local eqP, eqT = 0, 0
  if Equip and Equip.bonus then
    eqP, eqT = Equip.bonus(obj)
  end
  local sP, sT = 0, 0
  if Statics and Statics.bonus then
    sP, sT = Statics.bonus(obj)
  end
  -- Where the change comes from, one short piece each.
  local parts = {}
  if c.plus > 0 then
    table.insert(parts, c.plus .. "x +1/+1")
  end
  if c.minus > 0 then
    table.insert(parts, c.minus .. "x -1/-1")
  end
  if c.pc ~= 0 then
    table.insert(parts, c.pc .. "x +1/+0")
  end
  if c.tc ~= 0 then
    table.insert(parts, c.tc .. "x +0/+1")
  end
  if c.tp ~= 0 or c.tt ~= 0 then
    table.insert(parts, "turn " .. sgn(c.tp) .. "/" .. sgn(c.tt))
  end
  if eqP ~= 0 or eqT ~= 0 then
    table.insert(parts, "gear " .. sgn(eqP) .. "/" .. sgn(eqT))
  end
  if sP ~= 0 or sT ~= 0 then
    table.insert(parts, "static " .. sgn(sP) .. "/" .. sgn(sT))
  end
  if #parts > 0 then
    local st = Counters.stats(obj)
    if type(st.power) == "number" and type(st.toughness) == "number" then
      table.insert(big, st.power .. "/" .. st.toughness)
    end
    wrap(table.concat(parts, " | "), INFO_WRAP, info)
  end
  -- Planeswalkers on the battlefield show loyalty on their loyalty box (walkers.lua) instead.
  if c.loyalty ~= 0 and not (Walkers and Walkers.handles(obj)) then
    table.insert(big, "LOYALTY " .. c.loyalty)
  end
  if c.other ~= 0 then
    table.insert(big, c.other .. (c.other == 1 and " COUNTER" or " COUNTERS"))
  end
  -- Keywords gained until end of turn, from equipment and from other permanents (Sliver lords...).
  local kws, seenK = {}, {}
  local function addKw(k)
    if k and not seenK[k] then
      seenK[k] = true
      table.insert(kws, k)
    end
  end
  for _, k in ipairs(Counters.tempKeywords(obj)) do
    addKw(k)
  end
  if Equip and Equip.keywordList then
    for _, k in ipairs(Equip.keywordList(obj)) do
      addKw(k)
    end
  end
  if #kws > 0 then
    wrap(table.concat(kws, ", "), INFO_WRAP, info)
  end
  local pro = Equip and Equip.protectionOf and Equip.protectionOf(obj) or {}
  if #pro > 0 then
    wrap("protection from " .. table.concat(pro, ", "), INFO_WRAP, info)
  end
  -- Equipment and Auras: one name per line, so they can be read.
  if Equip and Equip.hostOf and Equip.hostOf(obj) then
    table.insert(info, "attached to:")
    wrap(tostring(Equip.hostOf(obj).getName()), INFO_WRAP, info)
  elseif Equip and Equip.attachments then
    local list = Equip.attachments(obj)
    if #list > 0 then
      table.insert(info, "equipped / enchanted:")
      for _, a in ipairs(list) do
        table.insert(info, "- " .. tostring(a.getName()):sub(1, INFO_WRAP - 2))
      end
    end
  end
  local ringBadge = Ring and Ring.badge and Ring.badge(obj)
  if ringBadge then
    wrap(ringBadge, INFO_WRAP, info)
  end
  local sbBadge = Soulbond and Soulbond.badge and Soulbond.badge(obj)
  if sbBadge then
    wrap(sbBadge, INFO_WRAP, info)
  end
  if Actions and Actions.skipsUntap and Actions.skipsUntap(obj) then
    table.insert(info, "DOESN'T UNTAP NEXT")
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
  -- Summoning sickness: a "Zzz" badge (see Counters.animate).
  sickIndex[obj.getGUID()] = nil
  if Combat and Combat.isSick and Combat.isSick(obj) then
    obj.createButton({
      click_function = "counters_noop",
      function_owner = Global,
      label = "Zzz",
      tooltip = "Summoning sick: can't attack or use {T} abilities until its controller's next turn starts (unless it has haste).",
      position = { 0.55, 0.3, 1.25 },
      rotation = { 0, 0, 0 },
      width = 520, height = 260, font_size = 190,
      font_color = { 0.75, 0.9, 1 },
      color = { 0.1, 0.18, 0.4, 0.88 },
    })
    sickIndex[obj.getGUID()] = #obj.getButtons() - 1
  end
  local bigH = 0
  if #big > 0 then
    bigH = 90 + math.floor(LABEL_FONT * 1.15) * #big
    obj.createButton({
      click_function = "counters_noop",
      function_owner = Global,
      label = table.concat(big, "\n"),
      tooltip = "Right-click the card > Counters... to change counters",
      position = { 0, LABEL_Y, LABEL_Z },
      rotation = { 0, 0, 0 },
      -- A real size: zero-size "label only" buttons weren't drawn in TTS.
      -- Narrower than the card (about 1050 wide in button units) so the label stays inside it.
      width = 880,
      height = bigH,
      font_size = LABEL_FONT,
      font_color = { 1, 1, 1 },
      color = { 0, 0, 0, 0.8 },
    })
  end
  if #info > 0 then
    local infoH = 60 + math.floor(INFO_FONT * 1.15) * #info
    -- Under the big label when there is one (button units are about 500 to one card unit).
    local z = LABEL_Z
    if bigH > 0 then
      z = LABEL_Z + (bigH + infoH) / 1000 + 0.04
    end
    obj.createButton({
      click_function = "counters_noop",
      function_owner = Global,
      label = table.concat(info, "\n"),
      tooltip = "Where its numbers come from, keywords it was given, and what's attached",
      position = { 0, LABEL_Y, z },
      rotation = { 0, 0, 0 },
      width = 900,
      height = infoH,
      font_size = INFO_FONT,
      font_color = { 0.85, 0.95, 1 },
      color = { 0, 0, 0, 0.82 },
    })
  end
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
  local before = c[kind] or 0
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
  if delta < 0 and before > 0 and (c[kind] or 0) == 0 and kind ~= "tp" and kind ~= "tt" and Triggers and Triggers.onCountersGone then
    Triggers.onCountersGone(obj, kind)
  end
  if delta > 0 and kind ~= "tp" and kind ~= "tt" and Triggers and Triggers.onCounters then
    Triggers.onCounters(obj, kind, delta, byColor)
  end
end

-- The amount that really goes on after Doubling Season, Hardened Scales and the like
-- (statics.lua). Says so in chat when it changed.
function Counters.modAmount(obj, kind, n, byColor)
  if type(n) ~= "number" or n <= 0 or kind == "tp" or kind == "tt" or not (Statics and Statics.counterAmount) then
    return n
  end
  local ok, out, names = pcall(Statics.counterAmount, obj, kind, n, byColor)
  if not ok or type(out) ~= "number" or out == n then
    return n
  end
  local label = (kind == "plus" and "+1/+1") or (kind == "minus" and "-1/-1") or (kind == "pc" and "+1/+0") or (kind == "tc" and "+0/+1") or (kind == "loyalty" and "loyalty") or "counters"
  printToAll("MTG > " .. table.concat(names, " + ") .. ": " .. n .. " " .. label .. " -> " .. out .. " on " .. obj.getName()
    .. " (additions first, then doubling; adjust by hand if you order them differently).", { 0.35, 0.95, 1 })
  return out
end

-- Counters put on by an effect (not a hand click): replacement effects apply. Returns the amount placed.
function Counters.place(obj, kind, n, byColor)
  local final = Counters.modAmount(obj, kind, n, byColor)
  Counters.change(obj, kind, final, byColor)
  return final
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

function Counters.remember(obj)
  if not isCard(obj) then return end
  local c = Counters.get(obj)
  if c.plus ~= 0 or c.minus ~= 0 or c.loyalty ~= 0 or c.other ~= 0 or c.pc ~= 0 or c.tc ~= 0 then
    Counters.lastKnown = Counters.lastKnown or {}
    Counters.lastKnown[obj.getGUID()] = c
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
  { "+1/+0 counter", "pc", 1 },
  { "Remove +1/+0 counter", "pc", -1 },
  { "+0/+1 counter", "tc", 1 },
  { "Remove +0/+1 counter", "tc", -1 },
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
    c.loyalty = Counters.modAmount(obj, "loyalty", printed, nil)
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
  local sb = (Soulbond and Soulbond.menuKey) and Soulbond.menuKey(obj) or ""
  local pk = (Pile and Pile.menuKey) and Pile.menuKey(obj) or ""
  local prep = (Effects and Effects.preparedPart and Effects.preparedPart(obj)) and "|prepared" or ""
  return region .. "|" .. step .. att .. sb .. pk .. prep
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
  if onField and Soulbond and Soulbond.addMenu then Soulbond.addMenu(obj) end
  if onField and Pile and Pile.addMenu then Pile.addMenu(obj) end
  if onField then
    -- One item for counters, goad, untap, clone and delete: the panel (Counters.openPanel) keeps the menu short.
    obj.addContextMenuItem("Counters...", function(playerColor)
      Counters.openPanel(obj, playerColor)
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
  if onField and Effects and Effects.chooseType then
    local ol = tostring(cardData(obj).oracle or ""):lower()
    if ol:find("choose a creature type", 1, true) and ol:find("enters", 1, true) then
      obj.addContextMenuItem("Choose creature type again", function(playerColor)
        Effects.chooseType(obj, (Zones.locationOf(obj) or {}).seat or playerColor)
      end)
    end
  end
  if region == "hand" and Effects and Effects.suspendInfo and Effects.suspendInfo(obj) then
    obj.addContextMenuItem("Suspend (pay cost, exile with time counters)", function(playerColor)
      Effects.suspend(obj, (Zones.locationOf(obj) or {}).seat or playerColor)
    end)
  end
  -- Spirit Guides: "Exile this card from your hand: Add {G}." Right-click in the hand.
  if region == "hand" then
    local oracle = tostring(cardData(obj).oracle or ""):lower()
    local key
    for line in (oracle .. "\n"):gmatch("([^\n]*)\n") do
      local a = line:sub(1, 6) == "exile " and line:find(" from your hand: add {", 1, true)
      if a then
        key = line:sub(a + #" from your hand: add {", a + #" from your hand: add {")
      end
    end
    if key and (key == "w" or key == "u" or key == "b" or key == "r" or key == "g" or key == "c") then
      obj.addContextMenuItem("Exile for {" .. key:upper() .. "} mana", function(playerColor)
        local loc = Zones.locationOf(obj)
        local seat = loc and loc.seat or playerColor
        local nm = obj.getName()
        obj.setLock(false)
        obj.setRotation({ 0, TableSetup.seat(seat).yaw, 0 })
        obj.setPosition(TableSetup.slot(seat, "exile", TableSetup.SURFACE_TOP + 2))
        Wait.time(function() if not obj.isDestroyed() then Zones.refresh(obj) end end, 0.6)
        if ManaChips and ManaChips.add then
          ManaChips.add(seat, key:upper(), 1)
        end
        printToAll("MTG > " .. seat .. " exiles " .. nm .. " from their hand for {" .. key:upper() .. "}.", { 0.75, 0.8, 0.9 })
      end)
    end
  end
  -- Anyone can delete a card this way (TTS normally needs a promoted player). On the battlefield it's in Counters...
  if not onField then
    obj.addContextMenuItem("Delete card", function(playerColor) Counters.deleteCard(obj, playerColor) end)
  end
  Counters.render(obj)
end

---------------------------------------------------------------------------
-- Counters panel: right-click a permanent > Counters... One panel per seat, only that player sees it.
---------------------------------------------------------------------------

local PANEL_ROWS = {
  { "plus", "+1/+1" }, { "minus", "-1/-1" }, { "pc", "+1/+0" }, { "tc", "+0/+1" },
  { "loyalty", "Loyalty" }, { "other", "Other" },
}
local panelTarget = {}   -- [seat] = guid of the card the panel is working on

local function panelObj(color)
  local g = panelTarget[color]
  local obj = g and getObjectFromGUID(g)
  if obj == nil or obj.isDestroyed() then
    return nil
  end
  return obj
end

function Counters.refreshPanel(color)
  local obj = panelObj(color)
  if obj == nil then
    UI.setAttribute("cardPanel_" .. color, "active", "false")
    panelTarget[color] = nil
    return
  end
  local c = Counters.get(obj)
  UI.setValue("cpTitle_" .. color, tostring(obj.getName()):sub(1, 30))
  for _, r in ipairs(PANEL_ROWS) do
    UI.setValue("cpVal_" .. color .. "_" .. r[1], tostring(c[r[1]] or 0))
  end
  UI.setValue("cpGoad_" .. color, Counters.goadedBy(obj) and "UN-GOAD" or "GOAD")
  UI.setValue("cpUntap_" .. color, (Actions and Actions.skipsUntap and Actions.skipsUntap(obj)) and "UNTAP NORMALLY" or "SKIP NEXT UNTAP")
end

function Counters.openPanel(obj, color)
  if obj == nil or obj.isDestroyed() or color == nil or color == "Grey" or color == "Black" then
    return
  end
  if Pile then Pile.touch(obj) end
  panelTarget[color] = obj.getGUID()
  UI.setAttribute("cardPanel_" .. color, "active", "true")
  Counters.refreshPanel(color)
end

function ui_cardPanel(player, arg)
  local color, what = tostring(arg):match("^(%a+)_(.+)$")
  if color == nil or player.color ~= color then
    return
  end
  if what == "close" then
    panelTarget[color] = nil
    UI.setAttribute("cardPanel_" .. color, "active", "false")
    return
  end
  local obj = panelObj(color)
  if obj == nil then
    Counters.refreshPanel(color)
    return
  end
  local kind, dir = what:match("^(%a+)_(%a+)$")
  if kind and (dir == "add" or dir == "sub") then
    Counters.change(obj, kind, dir == "add" and 1 or -1, color)
  elseif what == "clear" then
    Counters.clear(obj)
  elseif what == "goad" then
    if Counters.goadedBy(obj) then
      Counters.setGoad(obj, nil)
      printToAll("MTG > " .. obj.getName() .. " isn't goaded any more.", { 0.75, 0.8, 0.9 })
    else
      Counters.setGoad(obj, color)
      printToAll("MTG > " .. obj.getName() .. " is goaded by " .. color
        .. " (attacks each combat if able, and a player other than them if able).", { 1, 0.6, 0.2 })
    end
  elseif what == "untap" then
    local on = not Actions.skipsUntap(obj)
    Actions.setSkipUntap(obj, on, color)
    printToAll("MTG > " .. obj.getName() .. (on and " won't untap in its next untap step." or " untaps normally again."),
      { 0.75, 0.8, 0.9 })
  elseif what == "clone" then
    Counters.cloneObject(obj, color)
  elseif what == "delete" then
    panelTarget[color] = nil
    UI.setAttribute("cardPanel_" .. color, "active", "false")
    Counters.deleteCard(obj, color)
    return
  end
  Counters.refreshPanel(color)
end

function Counters.xml()
  local parts = {}
  for _, c in ipairs(TableSetup.activeSeats()) do
    local rows = {}
    for _, r in ipairs(PANEL_ROWS) do
      table.insert(rows, ([[
    <HorizontalLayout preferredHeight="30" spacing="6" childForceExpandWidth="false">
      <Text fontSize="14" color="#E6F1FF" alignment="MiddleLeft" preferredWidth="96">%s</Text>
      <Button onClick="ui_cardPanel(%s_%s_sub)" preferredWidth="40" fontStyle="Bold" fontSize="18" color="#3A1F2B">-</Button>
      <Text id="cpVal_%s_%s" fontSize="17" fontStyle="Bold" color="#5AF0FF" preferredWidth="44">0</Text>
      <Button onClick="ui_cardPanel(%s_%s_add)" preferredWidth="40" fontStyle="Bold" fontSize="18" color="#123A33">+</Button>
    </HorizontalLayout>]]):format(r[2], c, r[1], c, r[1], c, r[1]))
    end
    table.insert(parts, ([[
<Panel id="cardPanel_%s" visibility="%s" active="false" rectAlignment="MiddleRight" offsetXY="-30 40" width="280" height="430"
       color="#0B0F17F5" outline="#5AF0FF" outlineSize="2 2" allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="12 12 10 10" spacing="5" childForceExpandHeight="false">
    <Text id="cpTitle_%s" fontSize="15" fontStyle="Bold" color="#5AF0FF" preferredHeight="22">-</Text>
%s
    <HorizontalLayout preferredHeight="30" spacing="6">
      <Button onClick="ui_cardPanel(%s_clear)" fontSize="12" fontStyle="Bold">CLEAR ALL</Button>
      <Button id="cpGoad_%s" onClick="ui_cardPanel(%s_goad)" fontSize="12" fontStyle="Bold">GOAD</Button>
    </HorizontalLayout>
    <Button id="cpUntap_%s" onClick="ui_cardPanel(%s_untap)" preferredHeight="30" fontSize="12" fontStyle="Bold">SKIP NEXT UNTAP</Button>
    <HorizontalLayout preferredHeight="30" spacing="6">
      <Button onClick="ui_cardPanel(%s_clone)" fontSize="12" fontStyle="Bold" color="#1B3350">CLONE</Button>
      <Button onClick="ui_cardPanel(%s_delete)" fontSize="12" fontStyle="Bold" color="#5A1020">DELETE</Button>
      <Button onClick="ui_cardPanel(%s_close)" fontSize="12" fontStyle="Bold">CLOSE</Button>
    </HorizontalLayout>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, table.concat(rows, "\n"), c, c, c, c, c, c, c, c))
  end
  return table.concat(parts)
end

-- Clone a card, token, die or other loose object for a player (TTS normally needs a promoted player).
-- A cloned card is a fresh copy: no counters, untapped, beside the original.
function Counters.cloneObject(obj, playerColor)
  if obj == nil or obj.isDestroyed() then
    return
  end
  if obj.getLock() and obj.type ~= "Card" then
    broadcastToColor("That's part of the table: it can't be cloned.", playerColor, { 1, 0.6, 0.2 })
    return
  end
  if obj.hasTag("StackAbility") then
    broadcastToColor("Stack items can't be cloned (copy the spell or ability instead).", playerColor, { 1, 0.6, 0.2 })
    return
  end
  local p = obj.getPosition()
  local loc = Zones and Zones.regionAt(p)
  local s = loc and loc.seat and TableSetup.seat(loc.seat)
  local off = s and { x = s.right.x * 2.6, z = s.right.z * 2.6 } or { x = 2.6, z = 0 }
  local copy = obj.clone({ position = { p.x + off.x, p.y + 1.5, p.z + off.z } })
  if copy and obj.type == "Card" then
    Wait.frames(function()
      if copy and not copy.isDestroyed() then
        copy.memo = ""
        local r = copy.getRotation()
        if s then
          copy.setRotation({ r.x, s.yaw, r.z })
        end
        Counters.setup(copy)
      end
    end, 3)
  end
  printToAll("MTG > " .. tostring(playerColor) .. " cloned " .. tostring(obj.getName() ~= "" and obj.getName() or obj.type) .. ".",
    { 0.75, 0.8, 0.9 })
end

-- Delete a card for a player (right-click "Delete card" or the hotkey).
-- Done by the table's script, so it works without being promoted. Said in
-- chat so everyone sees it.
function Counters.deleteCard(obj, playerColor)
  if obj == nil or obj.isDestroyed() then
    return
  end
  -- Cards, tokens, dice and other loose pieces; never the table itself (locked) or a library / graveyard pile.
  if obj.type ~= "Card" then
    local region = Zones and Zones.regionAt(obj.getPosition()).region or ""
    if obj.getLock() or obj.hasTag("StackAbility") or obj.hasTag("MatLabel")
        or (obj.type == "Deck" and (region == "library" or region == "graveyard" or region == "exile")) then
      broadcastToColor("That can't be deleted from here (it's part of the table or a library / graveyard pile).",
        playerColor, { 1, 0.6, 0.2 })
      return
    end
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
  addHotkey("MTG: clone", function(playerColor, hovered)
    Counters.cloneObject(hovered, playerColor)
  end)
  addHotkey("MTG: counters panel", function(playerColor, hovered)
    if hovered and hovered.type == "Card" then
      Counters.openPanel(hovered, playerColor)
    end
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
      -- Last known counters, for "when this dies, create a token for each +1/+1 counter on it".
      local okc, snap = pcall(Counters.get, d.card)
      if okc and snap and (snap.plus ~= 0 or snap.minus ~= 0 or snap.loyalty ~= 0 or snap.other ~= 0) then
        Counters.lastKnown = Counters.lastKnown or {}
        local cp = {}
        for k, v in pairs(snap) do cp[k] = v end
        Counters.lastKnown[d.card.getGUID()] = cp
      end
    if d.card.memo and d.card.memo ~= "" then
      Counters.clear(d.card)
    end
  elseif isOn and not wasOn then
    -- Entered the battlefield: planeswalkers get their printed loyalty.
    if Counters.lastKnown then Counters.lastKnown[d.card.getGUID()] = nil end
    startingLoyalty(d.card)
    Counters.render(d.card)
  end
end)
