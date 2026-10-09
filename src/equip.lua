--[[
  equip.lua
  Equipment and Auras that sit on a creature.

  Drop an Equipment (or an Aura that says "enchanted creature") on top of a
  creature on the battlefield and the table attaches it: the creature gets
  its +N/+N and keywords (haste ends summoning sickness, protection and so
  on show on the creature), and its "whenever equipped creature attacks /
  deals combat damage to a player" triggers go on the stack when that
  creature does it. Dragging the creature carries the attachments along.
  Drag the equipment off (or right-click > Unattach) to detach it. When the
  creature or the equipment leaves the battlefield they separate.

  State: GameState.data.attached[equipment guid] = creature guid.
--]]

Equip = {}

local INFO = { 0.75, 0.8, 0.9 }
local GOOD = { 0.55, 0.9, 0.6 }
local ON_FIELD = { battlefield = true, lands = true }
local REACH = 2.3          -- drop within this distance of a creature's centre
local KEYWORDS = { "first strike", "double strike", "flying", "trample", "lifelink", "deathtouch", "vigilance",
  "haste", "indestructible", "hexproof", "shroud", "menace", "reach", "protection", "ward", "unblockable" }

local function attached()
  local d = GameState.data
  d.attached = d.attached or {}
  return d.attached
end

local function cardData(obj)
  local ok, notes = pcall(function() return obj.getGMNotes() end)
  if not ok or notes == nil or notes == "" then
    return {}
  end
  local ok2, d = pcall(function() return JSON.decode(notes) end)
  return (ok2 and type(d) == "table") and d or {}
end

local function typeLine(obj)
  local d = cardData(obj)
  return tostring(d.typeLine or table.concat(d.types or {}, " "))
end

local function onField(obj)
  if obj == nil or obj.isDestroyed() then
    return false
  end
  local loc = Zones.regionAt(obj.getPosition())
  return ON_FIELD[loc.region] == true, loc.seat
end

local function isCreature(obj)
  return typeLine(obj):find("Creature", 1, true) ~= nil
end

-- Is this an Equipment, or an Aura that enchants a creature?
function Equip.isAttachment(obj)
  if obj == nil or obj.isDestroyed() or obj.type ~= "Card" then
    return false
  end
  local tl = typeLine(obj)
  if tl:find("Equipment", 1, true) then
    return true
  end
  if tl:find("Aura", 1, true) then
    local o = tostring(cardData(obj).oracle or ""):lower()
    return o:find("enchanted creature", 1, true) ~= nil
  end
  return false
end

-- The creature an attachment sits on (nil when none or it left).
function Equip.hostOf(att)
  local guid = att and attached()[att.getGUID()]
  if guid == nil then
    return nil
  end
  local host = getObjectFromGUID(guid)
  if host == nil or host.isDestroyed() or not onField(host) then
    return nil
  end
  return host
end

-- Attachments on a creature: list of card objects.
function Equip.attachments(creature)
  local out = {}
  if creature == nil or creature.isDestroyed() then
    return out
  end
  local me = creature.getGUID()
  for aGuid, hGuid in pairs(attached()) do
    if hGuid == me then
      local a = getObjectFromGUID(aGuid)
      if a ~= nil and not a.isDestroyed() and onField(a) then
        table.insert(out, a)
      end
    end
  end
  table.sort(out, function(x, y) return x.getGUID() < y.getGUID() end)
  return out
end

-- What an attachment gives its creature: { dp, dt, kws = { haste = true }, text }.
-- Only its static lines ("Equipped creature gets +2/+2 and has ...").
local function modsOf(att)
  local d = cardData(att)
  local out = { dp = 0, dt = 0, kws = {}, list = {} }
  local oracle = tostring(d.oracle or "")
  for raw in (oracle .. "\n"):gmatch("([^\n]*)\n") do
    local line = raw:lower()
    local head = line:sub(1, 17)
    if head == "equipped creature" or line:sub(1, 17) == "enchanted creatur" then
      if not line:find("whenever", 1, true) and not line:find("when ", 1, true) then
        local p, q = line:match("gets? ([%+%-]%d+)/([%+%-]%d+)")
        if p then
          out.dp = out.dp + tonumber(p)
          out.dt = out.dt + tonumber(q)
        end
        -- Keywords after "has" / "have" (never "can't be blocked by creatures with flying").
        local at = line:find(" has ", 1, true) or line:find(" have ", 1, true)
        if at and not line:find("can't", 1, true) then
          local words = line:sub(at)
          for _, kw in ipairs(KEYWORDS) do
            if words:find(kw, 1, true) then
              out.kws[kw] = true
              table.insert(out.list, kw)
            end
          end
          local prot = words:match("protection from ([^%.;]+)")
          if prot then
            out.protection = prot
          end
        end
      end
    end
  end
  return out
end
Equip.modsOf = modsOf

-- Total +power / +toughness the attachments give this creature.
function Equip.bonus(creature)
  local dp, dt = 0, 0
  for _, a in ipairs(Equip.attachments(creature)) do
    local m = modsOf(a)
    dp, dt = dp + m.dp, dt + m.dt
  end
  return dp, dt
end

function Equip.hasKeyword(creature, kw)
  kw = kw:lower()
  for _, a in ipairs(Equip.attachments(creature)) do
    if modsOf(a).kws[kw] then
      return true
    end
  end
  return false
end

-- Keywords given by attachments, for the card's label.
function Equip.keywordList(creature)
  local seen, out = {}, {}
  for _, a in ipairs(Equip.attachments(creature)) do
    local m = modsOf(a)
    for _, kw in ipairs(m.list) do
      if not seen[kw] and kw ~= "protection" then   -- protection has its own PRO line
        seen[kw] = true
        table.insert(out, kw)
      end
    end
  end
  return out
end

local function refresh(obj)
  if obj ~= nil and not obj.isDestroyed() and Counters and Counters.render then
    Counters.render(obj)
  end
end

local function offsetFor(host, att)
  local _, seat = onField(host)
  local s = seat and TableSetup.seat(seat)
  local p = host.getPosition()
  if s == nil then
    return { x = p.x + 0.9, y = p.y + 0.1, z = p.z + 0.9 }
  end
  -- Peeks out toward the owner and to the right.
  return { x = p.x + s.right.x * 0.9 + s.outward.x * 0.9, y = p.y + 0.15, z = p.z + s.right.z * 0.9 + s.outward.z * 0.9 }
end

function Equip.attach(att, host, byColor, quiet)
  if att == nil or host == nil or att == host then
    return
  end
  local old = attached()[att.getGUID()]
  if old == host.getGUID() then
    return
  end
  attached()[att.getGUID()] = host.getGUID()
  att.setPositionSmooth(offsetFor(host, att), false, true)
  if not quiet then
    printToAll("MTG > " .. att.getName() .. " is attached to " .. host.getName() .. ".", GOOD)
  end
  if old then
    local oldHost = getObjectFromGUID(old)
    refresh(oldHost)
  end
  refresh(att)
  refresh(host)
  if Counters and Counters.refreshMenu then Counters.refreshMenu(att) end
  Events.emit("attached", { attachment = att, host = host })
end

function Equip.detach(att, why)
  local host = Equip.hostOf(att)
  local had = attached()[att.getGUID()] ~= nil
  attached()[att.getGUID()] = nil
  if had then
    if why ~= "silent" then
      printToAll("MTG > " .. att.getName() .. " is no longer attached" .. (host and (" to " .. host.getName()) or "")
        .. (why and (" (" .. why .. ")") or "") .. ".", INFO)
    end
    refresh(host)
    refresh(att)
    if Counters and Counters.refreshMenu then Counters.refreshMenu(att) end
  end
end

-- Nearest creature (not an attachment) within reach of a spot.
local function creatureAt(pos, except)
  local best, bestD = nil, REACH
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj ~= except and obj.type == "Card" and not obj.isDestroyed() and obj.held_by_color == nil
        and onField(obj) and isCreature(obj) and not Faces.unknown(obj) then
      local p = obj.getPosition()
      local dx, dz = p.x - pos.x, p.z - pos.z
      local d = math.sqrt(dx * dx + dz * dz)
      if d < bestD then
        best, bestD = obj, d
      end
    end
  end
  return best
end

-- A card was let go: an attachment dropped on a creature attaches; a
-- creature with attachments drags them along.
function Equip.onDrop(color, obj)
  if obj == nil or obj.isDestroyed() or obj.type ~= "Card" then
    return
  end
  Wait.time(function()
    if obj.isDestroyed() or not onField(obj) then
      return
    end
    if Equip.isAttachment(obj) then
      local host = creatureAt(obj.getPosition(), obj)
      local current = Equip.hostOf(obj)
      if host and host ~= current then
        Equip.attach(obj, host, color)
      elseif host == nil and current then
        Equip.detach(obj, "moved away")
      elseif current then
        -- Dropped back near its creature: tuck it back into place.
        obj.setPositionSmooth(offsetFor(current, obj), false, true)
      end
    elseif isCreature(obj) then
      for _, a in ipairs(Equip.attachments(obj)) do
        a.setPositionSmooth(offsetFor(obj, a), false, true)
        a.setRotationSmooth(obj.getRotation(), false, true)
      end
    end
  end, 0.9)
end


---------------------------------------------------------------------------
-- Protection
---------------------------------------------------------------------------

local COLOR_WORD = { W = "white", U = "blue", B = "black", R = "red", G = "green" }

-- "white and from blue" -> { "white", "blue" }
local function splitProtection(seg)
  local out = {}
  seg = seg:gsub("%..*$", ""):gsub(" from ", " "):gsub(" and ", ","):gsub(";.*$", "")
  for part in seg:gmatch("[^,]+") do
    local w = part:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^from ", ""):gsub("^and ", "")
    if w ~= "" then
      table.insert(out, w)
    end
  end
  return out
end

-- What this card is protected from: its own "Protection from ..." keyword
-- lines plus whatever its Equipment / Auras give it. List of words
-- ("white", "red", "multicolored", "creatures", "everything").
function Equip.protectionOf(card)
  local out, seen = {}, {}
  local function add(list)
    for _, w in ipairs(list) do
      if not seen[w] then
        seen[w] = true
        table.insert(out, w)
      end
    end
  end
  if card == nil or card.isDestroyed() then
    return out
  end
  for raw in (tostring(cardData(card).oracle or ""):lower() .. "\n"):gmatch("([^\n]*)\n") do
    local at = raw:find("protection from ", 1, true)
    -- Keyword lines only: not "{T}: target creature gains protection...".
    if at and not raw:find("[:{]") and not raw:find("gain", 1, true) and not raw:find("target", 1, true)
        and not raw:find("until", 1, true) and not raw:find("equipped", 1, true) and not raw:find("enchanted", 1, true)
        and not raw:find("creatures you control", 1, true) and not raw:find("creature you control", 1, true) then
      add(splitProtection(raw:sub(at + #"protection from ")))
    end
  end
  for _, a in ipairs(Equip.attachments(card)) do
    local m = modsOf(a)
    if m.protection then
      add(splitProtection(m.protection))
    end
  end
  return out
end

-- Is `card` protected from this source (a card guid)? Returns the quality
-- that matches ("black") or nil.
function Equip.protectedFrom(card, srcGuid)
  local list = Equip.protectionOf(card)
  if #list == 0 or srcGuid == nil then
    return nil
  end
  local src = getObjectFromGUID(srcGuid)
  if src == nil or src.isDestroyed() then
    return nil
  end
  local d = cardData(src)
  local colors = {}
  for _, c in ipairs(type(d.colors) == "table" and d.colors or {}) do
    if COLOR_WORD[c] then
      table.insert(colors, COLOR_WORD[c])
    end
  end
  local tl = typeLine(src):lower()
  for _, q in ipairs(list) do
    for _, c in ipairs(colors) do
      if q == c then
        return q
      end
    end
    if q == "everything" or q == "all" or q == "all colors" or q == "each color" then
      if #colors > 0 or q == "everything" then
        return q
      end
    elseif q == "multicolored" and #colors > 1 then
      return q
    elseif q == "monocolored" and #colors == 1 then
      return q
    elseif (q == "creatures" and tl:find("creature", 1, true)) or (q == "artifacts" and tl:find("artifact", 1, true))
        or (q == "enchantments" and tl:find("enchantment", 1, true)) or (q == "planeswalkers" and tl:find("planeswalker", 1, true)) then
      return q
    end
  end
  return nil
end

-- A creature may not be blocked by creatures of a colour it has protection from.
function Equip.blockedByProtection(attacker, blocker)
  return Equip.protectedFrom(attacker, blocker.getGUID())
end

---------------------------------------------------------------------------
-- Equip: right-click > Equip... lists the creatures it can go on
---------------------------------------------------------------------------

local function equipCost(obj)
  local o = tostring(cardData(obj).oracle or "")
  return o:match("[Ee]quip (%b{}[%b{}]*)") or o:match("[Ee]quip ([^\n%.]+)")
end

function Equip.startEquip(att, byColor)
  local _, seat = onField(att)
  seat = seat or byColor
  local names = {}
  local isAura = typeLine(att):find("Aura", 1, true) ~= nil
  local function eligible(obj, owner)
    if obj == att or not isCreature(obj) then
      return false
    end
    -- Equipment goes on a creature its controller controls; an Aura on any creature.
    if not isAura and owner ~= seat then
      return false
    end
    if Equip.protectedFrom(obj, att.getGUID()) then
      return false
    end
    return true
  end
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) then
      local ok, owner = onField(obj)
      if ok and eligible(obj, owner) then
        table.insert(names, obj.getName())
      end
    end
  end
  if #names == 0 then
    broadcastToColor("There's no creature " .. att.getName() .. " can go on.", byColor or seat, INFO)
    return
  end
  local cost = equipCost(att)
  local text = (cost and ("Equip " .. cost .. ": pay it, then ") or "") .. "click TARGET on the creature.\nLegal: "
    .. table.concat(names, ", ")
  Effects.askChoice(seat, "Equip " .. att.getName(), text, { { label = "CANCEL", value = false } }, function(obj)
    if obj then
      Equip.attach(att, obj, seat)
    end
  end, { filter = eligible, label = "EQUIP", protect = false })
end

function Equip.addMenu(obj)
  if not Equip.isAttachment(obj) or not onField(obj) then
    return
  end
  local isAura = typeLine(obj):find("Aura", 1, true) ~= nil
  obj.addContextMenuItem(isAura and "Attach to creature..." or "Equip...", function(playerColor)
    Equip.startEquip(obj, playerColor)
  end)
  if Equip.hostOf(obj) then
    obj.addContextMenuItem("Unattach", function(playerColor)
      Equip.detach(obj)
    end)
  end
end

-- Things leaving the battlefield separate from what they were attached to.
Events.on("cardMoved", function(d)
  local card = d.card
  if card == nil or not d.from or not ON_FIELD[d.from.region] then
    return
  end
  if d.to and ON_FIELD[d.to.region] then
    return
  end
  local g = card.getGUID()
  local map = attached()
  if map[g] then
    map[g] = nil
  end
  for aGuid, hGuid in pairs(map) do
    if hGuid == g then
      map[aGuid] = nil
      local a = getObjectFromGUID(aGuid)
      if a and not a.isDestroyed() then
        printToAll("MTG > " .. a.getName() .. " falls off (" .. tostring(d.name or "its creature") .. " left the battlefield).", INFO)
        refresh(a)
      end
    end
  end
end)

-- The label line a card shows ("ON Goblin", "EQ Sword of...").
function Equip.badge(obj)
  local host = Equip.hostOf(obj)
  if host then
    return "ON " .. tostring(host.getName()):sub(1, 16)
  end
  local list = Equip.attachments(obj)
  if #list > 0 then
    local names = {}
    for _, a in ipairs(list) do
      table.insert(names, tostring(a.getName()):sub(1, 18))
    end
    return "EQ " .. table.concat(names, ", ")
  end
  return nil
end
