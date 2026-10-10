--[[
  soulbond.lua
  Soulbond (Deadeye Navigator, Wolfir Silverheart, Silverblade Paladin, Trusted Forcemage, Wingcrafter...).

  "You may pair this creature with another unpaired creature when either enters. They remain paired for
  as long as you control both of them."

  The table proposes, the player confirms:
    - A soulbond creature enters: pick another unpaired creature of yours to pair it with (or SKIP).
    - Another creature enters while one of your soulbond creatures is unpaired: YES / NO to pair them.
    - A paired creature leaves the battlefield: the pair ends.
  While paired, both creatures get what the soulbond card's "As long as ~ is paired with another creature,
  each of those creatures ..." line gives: +N/+N (shown on the card), keywords, and "quoted" abilities
  (an activated one like Deadeye Navigator's shows up in the right-click Activate list). Granted
  triggered abilities (Tandem Lookout) are shown in chat as a reminder. A PAIRED badge shows on both cards.
  Fix mistakes with right-click > Soulbond: unpair / pair.
--]]

Soulbond = {}

local INFO = { 0.75, 0.8, 0.9 }
local GOOD = { 0.35, 0.95, 1 }
local IN = { battlefield = true, lands = true }

local KEYWORDS = { "flying", "first strike", "double strike", "deathtouch", "lifelink", "haste", "trample", "vigilance",
  "reach", "menace", "hexproof", "indestructible", "defender", "flash" }

local function pairs_()
  GameState.data.pairs = GameState.data.pairs or {}
  return GameState.data.pairs
end

local function oracleOf(obj)
  return tostring(CardData.get(obj).oracle or "")
end

function Soulbond.hasSoulbond(obj)
  return oracleOf(obj):lower():find("soulbond", 1, true) ~= nil
end

-- What this soulbond card gives its two creatures: { dp, dt, kws = {..}, abilities = {"{1}{U}: ..."}, triggers = {..} }
local grantCache = {}
function Soulbond.grant(obj)
  local text = oracleOf(obj)
  local cached = grantCache[text]
  if cached then
    return cached
  end
  local out = { dp = 0, dt = 0, kws = {}, abilities = {}, triggers = {} }
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local low = line:lower()
    local at = low:find("paired with another creature", 1, true)
    if at and (low:find("as long as", 1, true) or 0) < at then
      -- Quoted abilities first, then what's left outside the quotes.
      local bare = line
      for q in line:gmatch('"([^"]*)"') do
        if q:find(":", 1, true) and not q:lower():find("^whenever") and not q:lower():find("^when ") then
          table.insert(out.abilities, q)
        else
          table.insert(out.triggers, q)
        end
      end
      bare = bare:gsub('"[^"]*"', ""):lower()
      local a, b = bare:match("gets? %+(%d+)/%+(%d+)")
      if a then
        out.dp, out.dt = tonumber(a), tonumber(b)
      end
      local a2, b2 = bare:match("gets? %-(%d+)/%-(%d+)")
      if a2 then
        out.dp, out.dt = -tonumber(a2), -tonumber(b2)
      end
      local hasPart = bare:find(" has ", 1, true) or bare:find(" have ", 1, true) or bare:find(" and ", 1, true)
      if hasPart then
        for _, kw in ipairs(KEYWORDS) do
          if bare:find(kw, 1, true) then
            table.insert(out.kws, kw)
          end
        end
      end
    end
  end
  grantCache[text] = out
  return out
end

function Soulbond.partnerOf(obj)
  if obj == nil then
    return nil
  end
  local g = pairs_()[obj.getGUID()]
  local p = g and getObjectFromGUID(g)
  if p and not p.isDestroyed() then
    return p
  end
  return nil
end

-- The grants that apply to `obj` because of the pair it is in (its own soulbond text and its partner's).
local function grantsFor(obj)
  local list = {}
  local partner = Soulbond.partnerOf(obj)
  if partner == nil then
    return list
  end
  for _, c in ipairs({ obj, partner }) do
    if Soulbond.hasSoulbond(c) then
      table.insert(list, Soulbond.grant(c))
    end
  end
  return list
end

function Soulbond.bonus(obj)
  local dp, dt = 0, 0
  for _, g in ipairs(grantsFor(obj)) do
    dp, dt = dp + g.dp, dt + g.dt
  end
  return dp, dt
end

function Soulbond.keywords(obj)
  local seen, out = {}, {}
  for _, g in ipairs(grantsFor(obj)) do
    for _, kw in ipairs(g.kws) do
      if not seen[kw] then
        seen[kw] = true
        table.insert(out, kw)
      end
    end
  end
  return out
end

function Soulbond.hasKeyword(obj, kw)
  kw = tostring(kw):lower()
  for _, k in ipairs(Soulbond.keywords(obj)) do
    if k == kw then
      return true
    end
  end
  return false
end

-- Extra rules-text lines (activated abilities) the creature has while paired.
function Soulbond.grantedLines(obj)
  local out = {}
  for _, g in ipairs(grantsFor(obj)) do
    for _, a in ipairs(g.abilities) do
      table.insert(out, a)
    end
  end
  return out
end

function Soulbond.badge(obj)
  local p = Soulbond.partnerOf(obj)
  if p then
    local nm = p.getName()
    if #nm > 18 then
      nm = nm:sub(1, 16) .. ".."
    end
    return "PAIRED: " .. nm
  end
  return nil
end

-- Part of the right-click menu signature: rebuilt when pairing changes.
function Soulbond.menuKey(obj)
  local p = pairs_()[obj.getGUID()]
  return p and "|paired" or ""
end

local function refresh(obj)
  if obj ~= nil and not obj.isDestroyed() then
    if Counters and Counters.setup then
      Counters.setup(obj)
    end
  end
end

local function isCreature(obj)
  return obj ~= nil and not obj.isDestroyed() and Effects.cardTypes(obj).creature == true
end

local function seatOf(obj)
  local loc = Zones.regionAt(obj.getPosition())
  if IN[loc.region] then
    return loc.seat
  end
  return nil
end

function Soulbond.pair(a, b, why)
  pairs_()[a.getGUID()] = b.getGUID()
  pairs_()[b.getGUID()] = a.getGUID()
  printToAll("MTG > Soulbond: " .. a.getName() .. " and " .. b.getName() .. " are paired" .. (why and (" (" .. why .. ")") or "") .. ".", GOOD)
  for _, g in ipairs(grantsFor(a)) do
    for _, t in ipairs(g.triggers) do
      printToAll("MTG > Soulbond reminder: while paired, both creatures have \"" .. t .. "\" - add it to the stack by hand when it happens.", INFO)
    end
  end
  refresh(a)
  refresh(b)
  if Statics and Statics.soon then
    Statics.soon()
  end
end

function Soulbond.unpair(obj, why)
  local g = obj.getGUID()
  local other = pairs_()[g]
  if other == nil then
    return
  end
  pairs_()[g] = nil
  pairs_()[other] = nil
  local o = getObjectFromGUID(other)
  printToAll("MTG > Soulbond: " .. obj.getName() .. (o and (" and " .. o.getName()) or " and its partner") .. " are no longer paired" .. (why and (" (" .. why .. ")") or "") .. ".", INFO)
  refresh(obj)
  refresh(o)
  if Statics and Statics.soon then
    Statics.soon()
  end
end

local function unpairedCreatures(seat, except)
  local out = {}
  for _, o in ipairs(getObjectsWithTag("MTGCard")) do
    if o.type == "Card" and not o.isDestroyed() and o ~= except and not (Faces and Faces.unknown(o)) and seatOf(o) == seat
        and isCreature(o) and pairs_()[o.getGUID()] == nil then
      table.insert(out, o)
    end
  end
  return out
end

-- A soulbond creature (or any creature, with a soulbond creature waiting) is on the battlefield: offer to pair.
local function offerPair(card, seat)
  if card.isDestroyed() or pairs_()[card.getGUID()] ~= nil then
    return
  end
  if #unpairedCreatures(seat, card) == 0 then
    return
  end
  Effects.askChoice(seat, "Soulbond: pair " .. card.getName() .. "?",
    "Click PAIR on another unpaired creature you control to pair it with " .. card.getName() .. ", or SKIP.",
    { { label = "SKIP", value = false } }, function(other)
      if other and not other.isDestroyed() and not card.isDestroyed() and pairs_()[card.getGUID()] == nil
          and pairs_()[other.getGUID()] == nil then
        Soulbond.pair(card, other)
      end
    end, { filter = function(obj, owner)
      return owner == seat and obj ~= card and isCreature(obj) and pairs_()[obj.getGUID()] == nil
    end, label = "PAIR", protect = false })
end

local function offerWithEntering(sb, entering, seat)
  if sb.isDestroyed() or entering.isDestroyed() or pairs_()[sb.getGUID()] ~= nil or pairs_()[entering.getGUID()] ~= nil then
    return
  end
  Effects.askChoice(seat, "Soulbond: pair " .. sb.getName() .. " with " .. entering.getName() .. "?",
    entering.getName() .. " just entered and " .. sb.getName() .. " is unpaired. Pair them?",
    { { label = "PAIR THEM", value = true }, { label = "NO", value = false } }, function(yes)
      if yes and not sb.isDestroyed() and not entering.isDestroyed() and pairs_()[sb.getGUID()] == nil
          and pairs_()[entering.getGUID()] == nil then
        Soulbond.pair(sb, entering)
      end
    end)
end

Events.on("cardMoved", function(d)
  if d.card == nil or d.from == nil or d.to == nil or not GameState.data or not GameState.data.started then
    return
  end
  local card = d.card
  if card.isDestroyed() then
    return
  end
  -- Left the battlefield: the pair ends.
  if IN[d.from.region] and not IN[d.to.region] then
    if pairs_()[card.getGUID()] then
      Soulbond.unpair(card, "it left the battlefield")
    end
    return
  end
  if not (IN[d.to.region] and not IN[d.from.region] and d.to.seat) then
    return
  end
  if Faces and Faces.unknown(card) then
    return
  end
  local seat = d.to.seat
  -- Let the arrival settle (its card data, other enters triggers) before asking.
  Wait.time(function()
    if card.isDestroyed() or not isCreature(card) then
      return
    end
    if Soulbond.hasSoulbond(card) then
      offerPair(card, seat)
      return
    end
    for _, o in ipairs(getObjectsWithTag("MTGCard")) do
      if o.type == "Card" and not o.isDestroyed() and o ~= card and seatOf(o) == seat and isCreature(o)
          and pairs_()[o.getGUID()] == nil and Soulbond.hasSoulbond(o) then
        offerWithEntering(o, card, seat)
        return
      end
    end
  end, 1.2)
end)

-- Right-click menu: fix a mistake by hand.
function Soulbond.addMenu(obj)
  if not Soulbond.hasSoulbond(obj) and pairs_()[obj.getGUID()] == nil then
    return
  end
  if pairs_()[obj.getGUID()] then
    obj.addContextMenuItem("Soulbond: unpair", function()
      Soulbond.unpair(obj, "by hand")
    end)
  elseif Soulbond.hasSoulbond(obj) then
    obj.addContextMenuItem("Soulbond: pair with...", function(playerColor)
      local seat = seatOf(obj) or playerColor
      if #unpairedCreatures(seat, obj) == 0 then
        broadcastToColor("No unpaired creature of yours to pair with.", playerColor, INFO)
        return
      end
      offerPair(obj, seat)
    end)
  end
end

-- Bonuses and a clean slate when the game restarts.
function Soulbond.reset()
  if GameState.data then
    GameState.data.pairs = {}
  end
end
