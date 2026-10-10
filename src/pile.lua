--[[
  pile.lua
  Token piles: many identical, untouched tokens (14 Saprolings...) are one card with an "xN" badge, so the
  table has far fewer objects to draw (TTS lags with hundreds of cards, worse while streaming).

  A pile is ONE real card (the "head") plus a count in GameState.data.piles[guid]. The head's counters, tapped
  state and so on are what EVERY token in the pile has, so mass effects (a +1/+1 counter on each creature,
  untapping, an anthem) just work on the head.

  Only plain tokens pile up: keyword-only tokens (no abilities, so nothing that must trigger once per token), with
  no counters, no Equipment/Aura, not goaded/skip-untap, not in combat, not paired. Anything else stays single.
  The moment you touch ONE token it comes off the pile on its own: pick it up, tap it, right-click it, click
  ATTACK / BLOCK / a target button, attach Equipment. The head becomes that single token (so whatever you do to
  it is done to one token) and the rest wait beside it as a new pile. A modified token therefore never sits in a
  pile with unmodified ones. Plain tokens merge again when a token is made, at cleanup, and at upkeep.

  Counting stays right: "for each creature you control" and metalcraft count every token in a pile, a pile
  leaving the battlefield sends one "left the battlefield" event per token, and making N tokens sends N "enters".

  Off by default: !stack on / !stack off / !stack merge / !stack unstack.
--]]

Pile = {}

local INFO = { 0.75, 0.8, 0.9 }
local GOOD = { 0.55, 0.9, 0.6 }

local function piles()
  GameState.data.piles = GameState.data.piles or {}
  return GameState.data.piles
end

function Pile.enabled()
  return GameState.data ~= nil and GameState.data.pileOn == true
end

function Pile.count(obj)
  if obj == nil then
    return 1
  end
  local d = GameState.data
  local p = d and d.piles
  if p == nil then
    return 1
  end
  local ok, g = pcall(function() return obj.getGUID() end)
  return ok and p[g] or 1
end

function Pile.set(obj, n)
  if n <= 1 then
    piles()[obj.getGUID()] = nil
  else
    piles()[obj.getGUID()] = n
  end
end

---------------------------------------------------------------------------
-- Which tokens may pile up
---------------------------------------------------------------------------

local KEYWORDS = { ["flying"] = true, ["first strike"] = true, ["double strike"] = true, ["deathtouch"] = true,
  ["lifelink"] = true, ["haste"] = true, ["trample"] = true, ["vigilance"] = true, ["reach"] = true,
  ["menace"] = true, ["hexproof"] = true, ["indestructible"] = true, ["defender"] = true, ["flash"] = true,
  ["changeling"] = true }

local function stripReminder(text)
  local out, depth = {}, 0
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch == "(" then
      depth = depth + 1
    elseif ch == ")" then
      depth = math.max(0, depth - 1)
    elseif depth == 0 then
      table.insert(out, ch)
    end
  end
  return table.concat(out)
end

-- Rules text with nothing but plain keywords (or none at all).
function Pile.plainText(oracle)
  local t = stripReminder(tostring(oracle or ""):lower())
  local i = 1
  while i <= #t do
    local j = t:find("[\n,]", i) or (#t + 1)
    local part = t:sub(i, j - 1):gsub("^%s+", ""):gsub("%s+$", "")
    if part ~= "" and not KEYWORDS[part] then
      return false
    end
    i = j + 1
  end
  return true
end

local function seatYaw(seat)
  local s = seat and TableSetup.seat(seat)
  return s and s.yaw or 0
end

local function tappedNow(obj, seat)
  local diff = ((obj.getRotation().y - seatYaw(seat) + 540) % 360) - 180
  return math.abs(diff) > 30
end

-- Can this card be (part of) a pile right now?
function Pile.eligible(obj)
  if obj == nil or obj.isDestroyed() or obj.type ~= "Card" or not obj.hasTag("Token") or obj.held_by_color then
    return false
  end
  if obj.memo and obj.memo ~= "" then
    return false
  end
  if Faces and Faces.unknown(obj) then
    return false
  end
  local d = CardData.get(obj)
  if d.name == nil then
    return false   -- card data not readable yet
  end
  local tl = tostring(d.typeLine or "")
  if tl:find("Planeswalker", 1, true) or tl:find("Battle", 1, true) or not Pile.plainText(d.oracle) then
    return false
  end
  if Zones.regionAt(obj.getPosition()).region ~= "battlefield" then
    return false
  end
  if Equip and ((Equip.isAttachment and Equip.isAttachment(obj)) or (Equip.hostOf and Equip.hostOf(obj))
      or (Equip.attachments and #Equip.attachments(obj) > 0)) then
    return false
  end
  if Counters and ((Counters.goadedBy and Counters.goadedBy(obj)) or (Counters.tempKeywords and #Counters.tempKeywords(obj) > 0)) then
    return false
  end
  if Actions and Actions.skipsUntap and Actions.skipsUntap(obj) then
    return false
  end
  if Combat and Combat.inCombat and Combat.inCombat(obj) then
    return false
  end
  if Soulbond and Soulbond.partnerOf and Soulbond.partnerOf(obj) then
    return false
  end
  if Ring and Ring.badge and Ring.badge(obj) then
    return false
  end
  return true
end

---------------------------------------------------------------------------
-- Splitting
---------------------------------------------------------------------------

local function refreshCard(obj)
  if obj ~= nil and not obj.isDestroyed() and Counters and Counters.setup then
    Counters.setup(obj)
  end
end

-- A copy of `obj` standing for `n` tokens, put at `pos` with rotation `rot`. It is the same kind of token in the
-- same place, so the table sees no "enters" for it.
local function makeClone(obj, n, pos, rot)
  local c = obj.clone({ position = pos, snap_to_grid = false })
  if c == nil then
    return nil
  end
  Zones.inherit(obj, c)
  local g, cg = obj.getGUID(), c.getGUID()
  local ent = GameState.data.entered
  if ent and ent[g] ~= nil then
    ent[cg] = ent[g]
  end
  if rot then
    c.setRotation(rot)
  end
  c.addTag("Token")
  c.memo = obj.memo or ""
  Pile.set(c, n)
  return c
end

local function sideSpot(obj, k)
  local loc = Zones.regionAt(obj.getPosition())
  local s = loc.seat and TableSetup.seat(loc.seat)
  local p = obj.getPosition()
  if s == nil then
    return { x = p.x + 2.6 * k, y = p.y + 0.3, z = p.z }
  end
  return { x = p.x + s.right.x * 2.6 * k, y = p.y + 0.3, z = p.z + s.right.z * 2.6 * k }
end

-- Take ONE token off the pile: `obj` becomes that single token, the rest stay as a pile beside it
-- (or right where it was, if it is being picked up).
function Pile.touch(obj, opts)
  local n = Pile.count(obj)
  if n <= 1 or obj == nil or obj.isDestroyed() then
    return obj
  end
  Pile.set(obj, 1)
  local pos = (opts and opts.inPlace) and obj.getPosition() or sideSpot(obj, 1)
  if opts and opts.inPlace then
    pos = { x = pos.x, y = pos.y, z = pos.z }
  end
  local rot = opts and opts.rot or nil
  local rest = makeClone(obj, n - 1, pos, rot)
  refreshCard(obj)
  refreshCard(rest)
  if Statics and Statics.soon then
    Statics.soon()
  end
  return obj
end

-- Put `k` tokens of the pile into a pile of their own beside it.
function Pile.splitOff(obj, k)
  local n = Pile.count(obj)
  if n <= 1 or k < 1 or k >= n then
    return nil
  end
  Pile.set(obj, n - k)
  local c = makeClone(obj, k, sideSpot(obj, 1), nil)
  refreshCard(obj)
  refreshCard(c)
  return c
end

-- Every token in its own card.
function Pile.unstackAll(obj)
  local n = Pile.count(obj)
  if n <= 1 then
    return 0
  end
  Pile.set(obj, 1)
  for k = 1, n - 1 do
    local c = makeClone(obj, 1, sideSpot(obj, k), nil)
    refreshCard(c)
  end
  refreshCard(obj)
  if Statics and Statics.soon then
    Statics.soon()
  end
  return n
end

---------------------------------------------------------------------------
-- Merging
---------------------------------------------------------------------------

local function signature(obj, seat)
  local sick = Combat and Combat.isSick and Combat.isSick(obj) or false
  return seat .. "|" .. obj.getName() .. "|" .. tostring(tappedNow(obj, seat)) .. "|" .. tostring(sick)
end

-- Fold identical plain tokens together. Returns how many cards disappeared.
function Pile.mergeAll()
  if not Pile.enabled() then
    return 0
  end
  local heads, gone = {}, 0
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and obj.hasTag("Token") and obj.held_by_color == nil then
      local loc = Zones.regionAt(obj.getPosition())
      if loc.region == "battlefield" and loc.seat and Pile.eligible(obj) then
        local key = signature(obj, loc.seat)
        local head = heads[key]
        if head == nil then
          heads[key] = obj
        else
          Pile.set(head, Pile.count(head) + Pile.count(obj))
          Pile.set(obj, 1)
          if Zones.forget then
            Zones.forget(obj.getGUID())
          end
          obj.destruct()
          gone = gone + 1
        end
      end
    end
  end
  if gone > 0 then
    for _, head in pairs(heads) do
      refreshCard(head)
    end
    if Statics and Statics.soon then
      Statics.soon()
    end
  end
  return gone
end

local mergePending = false
function Pile.mergeSoon(delay)
  if not Pile.enabled() or mergePending then
    return
  end
  mergePending = true
  Wait.time(function()
    mergePending = false
    local ok, err = pcall(Pile.mergeAll)
    if not ok then
      print("MTG > pile merge: " .. tostring(err))
    end
  end, delay or 1.5)
end

-- Switch the whole feature off: everything back to single cards.
function Pile.unstackEverything()
  local n = 0
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and Pile.count(obj) > 1 then
      n = n + Pile.unstackAll(obj)
    end
  end
  return n
end

---------------------------------------------------------------------------
-- Making tokens (tokens.lua)
---------------------------------------------------------------------------

-- Pull the rules text out of a token template (JSON with the card data as an escaped string).
local function oracleFromTpl(tpl)
  local key = 'oracle\\":\\"'
  local a, b = tostring(tpl):find(key, 1, true)
  if not a then
    return nil
  end
  local e = tostring(tpl):find('\\"', b + 1, true)
  if not e then
    return nil
  end
  return (tostring(tpl):sub(b + 1, e - 1):gsub("\\\\n", "\n"))
end

-- Should a batch of this token be made as a pile?
function Pile.wantsPile(r, n, opts)
  if not Pile.enabled() or n < 1 then
    return false
  end
  if opts and (opts.attacking or opts.haste) then
    return false
  end
  local oracle
  if r.entry then
    oracle = r.entry.o or ""
  else
    oracle = oracleFromTpl(r.tpl)
  end
  return oracle ~= nil and Pile.plainText(oracle)
end

-- Announce the n-1 tokens a pile head stands for beyond the one that was announced (one "enters" per token).
function Pile.announceExtra(obj, seat, n)
  if n <= 1 then
    return
  end
  local loc = Zones.locationOf(obj) or Zones.regionAt(obj.getPosition())
  for _ = 2, n do
    Events.emit("cardMoved", { card = obj, name = obj.getName(), from = { seat = seat, region = "stack" }, to = loc,
      pileExtra = true })
  end
end

-- Spread successive piles along the battlefield so they don't sit on top of each other.
local spawnSlot = {}
function Pile.spawnOffset(seat)
  local k = (spawnSlot[seat] or 0) % 6
  spawnSlot[seat] = k + 1
  return (k - 2.5) * 2.9
end

---------------------------------------------------------------------------
-- What the player sees and does
---------------------------------------------------------------------------

function Pile.badge(obj)
  local n = Pile.count(obj)
  if n > 1 then
    return "x" .. n
  end
  return nil
end

function Pile.menuKey(obj)
  return Pile.count(obj) > 1 and "|pile" or ""
end

function Pile.allDie(obj, byColor)
  local n = Pile.count(obj)
  local loc = Zones.locationOf(obj) or Zones.regionAt(obj.getPosition())
  Pile.set(obj, 1)
  printToAll("MTG > " .. tostring(byColor) .. ": all " .. n .. " " .. obj.getName() .. " tokens die.", INFO)
  for _ = 1, n do
    Events.emit("cardMoved", { card = obj, name = obj.getName(), from = loc,
      to = { seat = loc.seat, region = "graveyard" }, pileExtra = true })
  end
end

function Pile.addMenu(obj)
  local n = Pile.count(obj)
  if n <= 1 then
    return
  end
  obj.addContextMenuItem("Pile (x" .. n .. "): split off 1", function()
    Pile.splitOff(obj, 1)
  end)
  if n > 5 then
    obj.addContextMenuItem("Pile (x" .. n .. "): split off 5", function()
      Pile.splitOff(obj, 5)
    end)
  end
  obj.addContextMenuItem("Pile (x" .. n .. "): unstack all", function()
    Pile.unstackAll(obj)
  end)
  obj.addContextMenuItem("Pile (x" .. n .. "): all die", function(playerColor)
    Pile.allDie(obj, playerColor)
  end)
end

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------

-- A player picked a pile up: they take one token; the rest stay put.
function Pile.onPickUp(color, obj)
  if obj ~= nil and not obj.isDestroyed() and Pile.count(obj) > 1 then
    Pile.touch(obj, { inPlace = true })
  end
end

-- A player turned a pile (tapped it): only the token they turned is tapped.
function Pile.onRotate(obj, spin, oldSpin, color)
  if obj == nil or obj.isDestroyed() or Pile.count(obj) <= 1 or spin == oldSpin or color == nil or color == "" then
    return
  end
  local r = obj.getRotation()
  Pile.touch(obj, { rot = { r.x, oldSpin, r.z } })
end

-- A pile that leaves the battlefield by any route (a sweeper, a bounce effect...): one "left" event per token.
Events.on("cardMoved", function(d)
  if d.pileExtra or d.card == nil or d.card.isDestroyed() or d.from == nil or d.to == nil then
    return
  end
  local left = (d.from.region == "battlefield" or d.from.region == "lands")
      and not (d.to.region == "battlefield" or d.to.region == "lands")
  if not left then
    return
  end
  local n = Pile.count(d.card)
  if n <= 1 then
    return
  end
  Pile.set(d.card, 1)
  for _ = 2, n do
    Events.emit("cardMoved", { card = d.card, name = d.name, from = d.from, to = d.to, pileExtra = true })
  end
end)

Events.on("stepStarted", function(d)
  if Pile.enabled() and (d.step == "cleanup" or d.step == "upkeep") then
    Pile.mergeSoon(1.0)
  end
end)

-- Wrap the places where a player picks ONE card out, so a pile gives up a single token first.
function Pile.install()
  local function wrapFirst(tbl, name)
    local orig = tbl[name]
    if type(orig) ~= "function" then
      return
    end
    tbl[name] = function(obj, ...)
      if obj ~= nil and Pile.count(obj) > 1 then
        Pile.touch(obj)
      end
      return orig(obj, ...)
    end
  end
  wrapFirst(Stack, "activate")
  wrapFirst(Counters, "deleteCard")
  wrapFirst(_G, "combat_cardClick")
  wrapFirst(_G, "effects_cardPick")
  local origAttach = Equip.attach
  Equip.attach = function(att, host, ...)
    if att ~= nil and Pile.count(att) > 1 then
      Pile.touch(att)
    end
    if host ~= nil and Pile.count(host) > 1 then
      Pile.touch(host)
    end
    return origAttach(att, host, ...)
  end
end
