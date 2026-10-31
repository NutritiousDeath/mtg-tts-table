--[[
  planefx.lua
  What the planes and Phenomena do (Planechase), where the table's general rules reader can't do it alone.

  Every ability a plane puts on the stack (chaos, planeswalking to it, its upkeep...) is matched here by plane
  name and a piece of its text. A match either
    - rewrites the text into wording the rules reader understands (as(...)), or
    - runs a small function when the ability resolves (on(...)), built from the table's own tools: picking a
      permanent, counters, damage, tokens, the libraries, the planar deck...
  Abilities the trigger reader can't watch for on a plane ("whenever a player casts a spell", "taps a land for
  mana", "draws a card"...) are watched for here and put on the stack the same way.

  Hooks: Stack.pushAbility asks PlaneFx.adjust; Effects.resolve calls PlaneFx.run; Planechase.triggerText leaves
  out the lines PlaneFx.handlesLine says it watches itself.
--]]

PlaneFx = {}

local INFO = { 0.75, 0.8, 0.9 }
local GOOD = { 0.55, 0.9, 0.6 }
local WARN = { 1, 0.6, 0.2 }
local CYAN = { 0.35, 0.95, 1 }

local FX = {}
local function on(plane, has, fn)
  table.insert(FX, { plane = plane, has = has, fn = fn })
end
local function as(plane, has, text)
  table.insert(FX, { plane = plane, has = has, text = text })
end

local function st()
  local d = GameState.data
  d.planefx = d.planefx or {}
  return d.planefx
end

local function say(name, msg, color)
  printToAll("MTG > " .. tostring(name) .. ": " .. msg, color or GOOD)
end

---------------------------------------------------------------------------
-- Tools
---------------------------------------------------------------------------

local function players()
  local out = {}
  for _, c in ipairs(TableSetup.activeSeats()) do
    local p = GameState.player(c)
    if p and not p.eliminated and not (Leave and Leave.isOut(c)) then
      table.insert(out, c)
    end
  end
  return out
end

-- Turn order starting with `seat`.
local function fromSeat(seat)
  local list = players()
  local out, start = {}, 1
  for i, c in ipairs(list) do
    if c == seat then
      start = i
    end
  end
  for k = 0, #list - 1 do
    table.insert(out, list[((start - 1 + k) % #list) + 1])
  end
  return out
end

local function opps(seat)
  local out = {}
  for _, c in ipairs(players()) do
    if TableSetup.isOpponent(c, seat) then
      table.insert(out, c)
    end
  end
  return out
end

-- The player to `seat`'s left (the next one in turn order).
local function leftOf(seat)
  local list = fromSeat(seat)
  return list[2] or seat
end

local function data(obj)
  local ok, d = pcall(function() return CardData.get(obj) end)
  return ok and d or {}
end

local function types(obj)
  return Effects.cardTypes(obj)
end

local function isCreature(obj)
  return types(obj).creature == true
end

local function typeLine(obj)
  return tostring(data(obj).typeLine or ""):lower()
end

local function colorsOf(obj)
  return Statics and Statics.colorsOf and Statics.colorsOf(obj) or {}
end

local function powerOf(obj)
  local ok, s = pcall(Counters.stats, obj)
  return ok and (tonumber(s.power) or 0) or (tonumber(data(obj).power) or 0)
end

local function toughOf(obj)
  local ok, s = pcall(Counters.stats, obj)
  return ok and (tonumber(s.toughness) or 0) or (tonumber(data(obj).toughness) or 0)
end

local function mvOf(obj)
  return tonumber(data(obj).cmc) or 0
end

-- Every permanent on the battlefield: { obj, seat }.
local function field(fits)
  local out = {}
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and obj.held_by_color == nil and not (Faces and Faces.unknown(obj)) then
      local seat = Effects.fieldSeat(obj)
      if seat and (fits == nil or fits(obj, seat)) then
        table.insert(out, { obj = obj, seat = seat })
      end
    end
  end
  return out
end

local function countOf(seat, fits)
  local n = 0
  for _, e in ipairs(field(fits)) do
    if e.seat == seat then
      n = n + (Pile and Pile.count(e.obj) or 1)
    end
  end
  return n
end

local function handOf(seat)
  local list = {}
  pcall(function()
    for _, h in ipairs(Player[seat].getHandObjects() or {}) do
      if h.type == "Card" and h.hasTag("MTGCard") then
        table.insert(list, h)
      end
    end
  end)
  return list
end

local function life(seat, delta, why)
  if delta ~= 0 and GameState.player(seat) then
    Trackers.changeLife(seat, delta, why)
  end
end

local function setTapped(obj, seat, tapped)
  local s = TableSetup.seat(seat)
  if s == nil or obj == nil or obj.isDestroyed() then
    return
  end
  local r = obj.getRotation()
  obj.setRotationSmooth({ r.x, tapped and (s.yaw + 90) % 360 or s.yaw, r.z }, false, true)
end

-- Click a permanent: cb(obj or nil). skip: the button's label ("SKIP" / "DONE").
local function pick(seat, it, title, text, fits, cb, skip, label)
  Effects.askChoice(seat, it.name .. ": " .. title, text, { { label = skip or "SKIP", value = false } }, function(obj)
    cb(obj or nil)
  end, { filter = function(obj, owner)
    local ok, yes = pcall(fits, obj, owner)
    return ok and yes == true
  end, label = label or "TARGET" })
end

local function choose(seat, title, text, choices, cb)
  Effects.askChoice(seat, title, text, choices, cb)
end

local function yesNo(seat, title, text, yes, no, cb)
  choose(seat, title, text, { { label = yes, value = true }, { label = no, value = false } }, function(v)
    cb(v == true)
  end)
end

-- Ask about each item of a list in turn: fn(item, nextFn).
local function each(list, fn, done)
  local i = 0
  local function nxt()
    i = i + 1
    if list[i] == nil then
      if done then done() end
      return
    end
    fn(list[i], nxt)
  end
  nxt()
end

-- Resolve some rules text as `seat` with the table's own reader ("create three 0/1 white Goat creature tokens.").
local function run(it, seat, text, extra)
  local fake = { name = it.name, text = text, controller = seat, auto = true, trigger = true, kind = "ability",
    guid = it.guid, source = it.source, that = it.that, thatCard = it.thatCard }
  for k, v in pairs(extra or {}) do
    fake[k] = v
  end
  local ok, err = pcall(Effects.resolve, fake)
  if not ok and Events and Events.noteError then
    Events.noteError("resolving " .. tostring(it.name), err)
  end
end

local function boost(seat, obj, p, q, kws, label, name)
  if obj == nil or obj.isDestroyed() then
    return
  end
  pcall(Effects.pump, seat, { scope = "that", p = p or 0, q = q or 0, kws = kws or {}, label = label or "",
    n = 1, what = "pump", who = "you" }, { name = name or "Plane", thatCard = obj.getGUID() })
end

local function plus(obj, n, seat)
  if obj and not obj.isDestroyed() and n > 0 then
    Counters.place(obj, "plus", n, seat)
  end
end

local function damage(obj, n, name, seat)
  if obj and not obj.isDestroyed() and n > 0 then
    Effects.damageCreature(obj, n, nil, name, seat)
  end
end

local function sacrifice(obj)
  if obj and not obj.isDestroyed() then
    Combat.removeCard(obj, "graveyard")
  end
end

-- `seat` sacrifices one permanent that fits; done(obj or nil).
local function sacOne(it, seat, what, fits, done)
  local any = false
  for _, e in ipairs(field(fits)) do
    if e.seat == seat then
      any = true
    end
  end
  if not any then
    say(it.name, seat .. " has no " .. what .. " to sacrifice.", INFO)
    if done then done(nil) end
    return
  end
  local function ask()
    pick(seat, it, "sacrifice " .. what, seat .. ": click SACRIFICE on " .. what .. " you control.", function(obj, owner)
      return owner == seat and fits(obj, owner)
    end, function(obj)
      if obj == nil then
        broadcastToColor("You have to sacrifice one.", seat, WARN)
        ask()
        return
      end
      say(it.name, seat .. " sacrifices " .. obj.getName() .. ".")
      sacrifice(obj)
      if done then done(obj) end
    end, "SKIP", "SACRIFICE")
  end
  ask()
end

-- A token from wording the reader understands ("a 3/3 black Dalek artifact creature token with menace").
local function tokenSpec(phrase)
  local plan = Effects.parse("create " .. phrase .. ".", "Plane")
  local a = plan and plan.actions and plan.actions[1]
  if a and a.what == "token" then
    return a.spec
  end
  return nil
end

local function makeTokens(seat, phrase, n, name, opts)
  if n <= 0 then
    return
  end
  local spec = tokenSpec(phrase)
  if spec and Tokens and Tokens.create then
    Tokens.create(seat, spec, n, name, opts)
  else
    broadcastToColor(name .. ": make " .. n .. " " .. phrase .. " yourself (TOKENS tile).", seat, WARN)
  end
end

-- A copy of a creature for `seat` ("create a token that's a copy"): extra = { kws = {...}, unlegend = true }.
local function copyFor(obj, seat, name, extra)
  if obj == nil or obj.isDestroyed() then
    return nil
  end
  local ok, c = pcall(Effects.copyCard, obj, seat, { noMods = false, unlegend = extra and extra.unlegend }, name)
  if ok and c and extra and extra.kws then
    Wait.time(function()
      if not c.isDestroyed() then
        for _, k in ipairs(extra.kws) do
          pcall(Counters.addTempKeyword, c, k)
        end
      end
    end, 1.5)
  end
  return ok and c or nil
end

-- Onto the battlefield (from a hand or a pile spot): tapped or not, under `seat`'s control.
local function toBattlefield(card, seat, tapped, faceDown)
  if card == nil or card.isDestroyed() then
    return
  end
  local s = TableSetup.seat(seat)
  local isLand = typeLine(card):find("land", 1, true) ~= nil
  card.setLock(false)
  card.setRotation({ 0, tapped and (s.yaw + 90) % 360 or s.yaw, faceDown and 180 or 0 })
  card.setPosition(TableSetup.slot(seat, isLand and "lands" or "battlefield", TableSetup.SURFACE_TOP + 2))
  Wait.time(function()
    if not card.isDestroyed() then
      Zones.refresh(card)
    end
  end, 0.6)
end

local function toHand(card, seat)
  if card == nil or card.isDestroyed() then
    return
  end
  local s = TableSetup.seat(seat)
  card.setLock(false)
  card.setRotation({ 0, s.yaw, 0 })
  card.setPositionSmooth(Player[seat].getHandTransform().position, false, true)
end

-- Take cards out of a seat's pile (graveyard / exile) by GUID: cb(card) for each.
local function takeFrom(seat, region, guids, where, cb)
  local pile = Library.pileIn(seat, region)
  if pile == nil then
    return
  end
  local s = TableSetup.seat(seat)
  local pos = TableSetup.slot(seat, where or "battlefield", TableSetup.SURFACE_TOP + 2.5)
  if pile.type == "Card" then
    for _, g in ipairs(guids) do
      if pile.getGUID() == g then
        cb(pile)
      end
    end
    return
  end
  for k, g in ipairs(guids) do
    pcall(function()
      pile.takeObject({ guid = g, position = { pos.x, pos.y + k * 0.3, pos.z }, rotation = { 0, s.yaw, 0 }, smooth = false,
        callback_function = function(c) cb(c) end })
    end)
  end
end

-- The top cards of a library, one after another, laid face up beside it: cb(list).
local function revealTop(seat, n, cb)
  local got = {}
  local function step()
    if #got >= n then
      cb(got)
      return
    end
    Library.revealTop(seat, function(card)
      if card == nil then
        cb(got)
        return
      end
      local p = card.getPosition()
      card.setPosition({ p.x + #got * 1.2, p.y + 0.5 + #got * 0.2, p.z })
      card.setRotation({ 0, TableSetup.seat(seat).yaw, 0 })
      table.insert(got, card)
      Wait.time(step, 0.4)
    end)
  end
  step()
end

local function names(list)
  local out = {}
  for _, c in ipairs(list) do
    table.insert(out, c.getName())
  end
  return table.concat(out, ", ")
end

local function isActive(seat)
  return Turns and Turns.isActiveSeat and Turns.isActiveSeat(seat)
end

local function stepId()
  local t = GameState.data.turn or {}
  local s = Turns.STEPS[t.stepIndex or 1]
  return s and s.id or ""
end

local function turnNo()
  local t = GameState.data.turn or {}
  return t.taken or 0
end

-- "Until a player planeswalks": kept in st().until[key] = true; cleared on any planeswalk.
local function untilWalk(key, val)
  st().untilWalk = st().untilWalk or {}
  st().untilWalk[key] = val == nil and true or val
end
local function whileWalk(key)
  return st().untilWalk and st().untilWalk[key]
end

---------------------------------------------------------------------------
-- Phasing (Unyaro, The Doctor's Childhood Barn). A phased-out permanent stays where it is but is treated as
-- though it doesn't exist (CR 702.26): it isn't on the battlefield for targeting, counting, sweepers, static
-- abilities or triggers; it can't attack or block; it doesn't untap. It's shown greyed out and can't be
-- picked up. Auras and Equipment attached to it phase out with it. Both planes phase them back in when a
-- player planeswalks.
---------------------------------------------------------------------------

local PHASE_TINT = { 0.28, 0.3, 0.36 }

function PlaneFx.isPhased(obj)
  local d = GameState.data and GameState.data.planefx
  if d == nil or d.phasedSet == nil or obj == nil then
    return false
  end
  local ok, g = pcall(function() return obj.getGUID() end)
  return ok and d.phasedSet[g] == true
end

local function showPhased(o, out)
  pcall(function()
    if out then
      o.setColorTint(PHASE_TINT)
      o.setLock(true)
      o.interactable = false
    else
      o.setColorTint({ 1, 1, 1 })
      o.interactable = true
      o.setLock(false)
    end
  end)
end

local function phaseOut(obj, why)
  if obj == nil or obj.isDestroyed() or PlaneFx.isPhased(obj) then
    return
  end
  local s = st()
  s.phasedSet = s.phasedSet or {}
  local list = { obj }
  -- Indirectly: what's attached to it goes too.
  if Equip and Equip.attachments then
    local okA, atts = pcall(Equip.attachments, obj)
    for _, a in ipairs(okA and atts or {}) do
      table.insert(list, a)
    end
  end
  for _, o in ipairs(list) do
    s.phasedSet[o.getGUID()] = true
    showPhased(o, true)
  end
  if Statics and Statics.soon then
    Statics.soon()
  end
end

local function phaseInAll()
  local s = st()
  local n = 0
  for g in pairs(s.phasedSet or {}) do
    local o = getObjectFromGUID(g)
    if o and not o.isDestroyed() then
      showPhased(o, false)
      n = n + 1
    end
  end
  s.phasedSet = {}
  if n > 0 then
    printToAll("MTG > " .. n .. " phased-out permanent" .. (n == 1 and "" or "s") .. " phase back in.", GOOD)
    if Statics and Statics.soon then
      Statics.soon()
    end
  end
end

-- After a load: phased-out permanents keep their look.
Wait.time(function()
  local d = GameState.data and GameState.data.planefx
  for g in pairs(d and d.phasedSet or {}) do
    local o = getObjectFromGUID(g)
    if o then
      showPhased(o, true)
    end
  end
end, 3)

function PlaneFx.onPlaneswalk(leavingName)
  local s = st()
  s.untilWalk = {}
  -- Skybreen / Windriddle Palaces: the revealed top cards go back on top.
  if (leavingName == "Skybreen" or leavingName == "Windriddle Palaces") and PlaneFx.revealTopsOff then
    pcall(PlaneFx.revealTopsOff)
  end
  -- Unyaro / The Doctor's Childhood Barn: everything phased out phases back in.
  phaseInAll()
end

---------------------------------------------------------------------------
-- Plane counters (Planechase.addCounter shows them on the card)
---------------------------------------------------------------------------

local function addPC(name, kind, n)
  return Planechase.addCounter(name, kind, n or 1)
end

local function pc(name)
  return (Planechase.counter(name))
end

---------------------------------------------------------------------------
-- The abilities, plane by plane (A to Z, roughly as printed)
---------------------------------------------------------------------------

-- Academy at Tolaria West
on("Academy at Tolaria West", "discard your hand", function(it, seat)
  Actions.discardHand(seat, it.name)
end)

-- Agyrem: watched below (dies); the chaos ability lasts until a player planeswalks.
on("Agyrem", "return it to the battlefield under its owner's control at the beginning of the next end step", function(it, seat)
  local s = st()
  s.agyrem = s.agyrem or {}
  table.insert(s.agyrem, { guid = it.thatCard, owner = it.that, dest = "battlefield" })
  say(it.name, "it returns to the battlefield at the beginning of the next end step.")
end)
on("Agyrem", "return it to its owner's hand at the beginning of the next end step", function(it, seat)
  local s = st()
  s.agyrem = s.agyrem or {}
  table.insert(s.agyrem, { guid = it.thatCard, owner = it.that, dest = "hand" })
  say(it.name, "it returns to its owner's hand at the beginning of the next end step.")
end)
on("Agyrem", "creatures can't attack you until a player planeswalks", function(it, seat)
  untilWalk("noAttack:" .. seat)
  say(it.name, "creatures can't attack " .. seat .. " until a player planeswalks.", CYAN)
end)

-- Aretopolis
local function aretopolis(it, seat, draw)
  local n = addPC("Aretopolis", "scroll", 1)
  if draw then
    Actions.draw(seat, n, it.name)
  else
    life(seat, n, it.name)
  end
  if n >= 10 then
    say(it.name, "ten scroll counters: planeswalk!", CYAN)
    Planechase.push(seat, "Planeswalk", "Planeswalk: Aretopolis leaves and the next plane turns face up.", "walk")
  end
end
on("Aretopolis", "put a scroll counter on aretopolis, then you gain life", function(it, seat) aretopolis(it, seat, false) end)
on("Aretopolis", "put a scroll counter on aretopolis, then draw cards", function(it, seat) aretopolis(it, seat, true) end)

-- Bant
on("Bant", "put a divinity counter on target green, white, or blue creature", function(it, seat)
  pick(seat, it, "divinity counter", "Click TARGET on a green, white or blue creature.", function(obj)
    local c = colorsOf(obj)
    return isCreature(obj) and (c.G or c.W or c.U)
  end, function(obj)
    if obj then
      Counters.place(obj, "other", 1, seat)
      local s = st()
      s.divinity = s.divinity or {}
      s.divinity[obj.getGUID()] = true
      say(it.name, obj.getName() .. " gets a divinity counter: it has indestructible while the counter stays.")
    end
  end)
end)

-- Celestine Reef
on("Celestine Reef", "you can't lose the game and your opponents can't win the game", function(it, seat)
  untilWalk("cantLose:" .. seat)
  say(it.name, seat .. " can't lose the game until a player planeswalks.", CYAN)
end)

-- Cliffside Market
on("Cliffside Market", "exchange life totals with target player", function(it, seat)
  local ch = {}
  for _, c in ipairs(players()) do
    if c ~= seat then
      table.insert(ch, { label = string.upper(c), value = c })
    end
  end
  table.insert(ch, { label = "DON'T", value = false })
  choose(seat, it.name .. ": exchange life totals?", "Pick the player to exchange life totals with, or DON'T.", ch, function(c)
    if c then
      local a, b = GameState.player(seat), GameState.player(c)
      local la, lb = a.life, b.life
      life(seat, lb - la, it.name)
      life(c, la - lb, it.name)
      say(it.name, seat .. " and " .. c .. " exchange life totals (" .. la .. " <-> " .. lb .. ").")
    end
  end)
end)
on("Cliffside Market", "exchange control of two target permanents that share a card type", function(it, seat)
  pick(seat, it, "first permanent", "Click TARGET on the first permanent.", function() return true end, function(a)
    if not a then
      return
    end
    local ta = types(a)
    pick(seat, it, "second permanent", "Click TARGET on a permanent that shares a card type with " .. a.getName() .. ".",
      function(b, owner)
        if b == a then
          return false
        end
        local tb = types(b)
        for k, v in pairs(ta) do
          if v and tb[k] then
            return true
          end
        end
        return false
      end, function(b)
        if not b then
          return
        end
        local sa, sb = Effects.fieldSeat(a), Effects.fieldSeat(b)
        if sa and sb and sa ~= sb then
          Effects.moveToSeat(a, sb)
          Effects.moveToSeat(b, sa)
        end
        say(it.name, a.getName() .. " and " .. b.getName() .. " exchange control.")
      end)
  end)
end)

-- Edge of Malacol
as("Edge of Malacol", "untap each creature you control", "untap all creatures you control.")

-- Eloren Wilds (the mana is watched below)
on("Eloren Wilds", "target player can't cast spells until a player planeswalks", function(it, seat)
  local ch = {}
  for _, c in ipairs(players()) do
    table.insert(ch, { label = string.upper(c), value = c })
  end
  choose(seat, it.name .. ": which player?", "That player can't cast spells until a player planeswalks.", ch, function(c)
    if c then
      untilWalk("noCast:" .. c)
      say(it.name, c .. " can't cast spells until a player planeswalks.", CYAN)
    end
  end)
end)

-- Feeding Grounds
on("Feeding Grounds", "put x +1/+1 counters on target creature, where x is that creature's mana value", function(it, seat)
  pick(seat, it, "+1/+1 counters", "Click TARGET on a creature: it gets +1/+1 counters equal to its mana value.", isCreature,
    function(obj)
      if obj then
        plus(obj, mvOf(obj), seat)
      end
    end)
end)

-- Fields of Summer (watched below)
on("Fields of Summer", "that player may gain 2 life", function(it, seat)
  local who = it.that or seat
  yesNo(who, it.name, who .. ": gain 2 life?", "GAIN 2", "NO", function(y)
    if y then
      life(who, 2, it.name)
    end
  end)
end)

-- Glen Elendra
on("Glen Elendra", "exchange control of target creature you control that dealt combat damage", function(it, seat)
  pick(seat, it, "your creature", "Click TARGET on your creature that dealt combat damage to a player this combat, or SKIP.",
    function(obj, owner) return owner == seat and isCreature(obj) end, function(a)
      if not a then
        return
      end
      pick(seat, it, "their creature", "Click TARGET on a creature controlled by the player it damaged.",
        function(obj, owner) return owner ~= seat and isCreature(obj) end, function(b)
          if b then
            local sb = Effects.fieldSeat(b)
            Effects.moveToSeat(a, sb)
            Effects.moveToSeat(b, seat)
            say(it.name, a.getName() .. " and " .. b.getName() .. " exchange control.")
          end
        end)
    end)
end)
on("Glen Elendra", "gain control of target creature you own", function(it, seat)
  pick(seat, it, "gain control", "Click TARGET on a creature you own that someone else controls.", function(obj, owner)
    return isCreature(obj) and owner ~= seat and Effects.ownerOf(obj) == seat
  end, function(obj)
    if obj then
      Effects.moveToSeat(obj, seat)
      say(it.name, seat .. " gains control of " .. obj.getName() .. ".")
    end
  end)
end)

-- Glimmervoid Basin
on("Glimmervoid Basin", "copies that spell for each other spell", function(it, seat)
  local who = it.that or seat
  local spell = it.thatCard and getObjectFromGUID(it.thatCard)
  if spell == nil or not (Stack and Stack.has and Stack.has(it.thatCard)) then
    say(it.name, "the spell is gone: no copies.", INFO)
    return
  end
  -- Its single target: count everything else it could target (permanents of that kind, players).
  local entry
  for _, e in ipairs(Stack.entries()) do
    if e.guid == it.thatCard then
      entry = e
    end
  end
  local pre = entry and entry.preTargets and entry.preTargets[1]
  local n
  if pre and pre.kind == "player" then
    n = #players() - 1
  elseif pre and pre.spec and Effects.targetFits then
    n = 0
    for _, e in ipairs(field()) do
      local okf, fits = pcall(Effects.targetFits, pre.spec, e.obj, e.seat, who, spell.getGUID(), {})
      if okf and fits and e.obj.getGUID() ~= pre.guid then
        n = n + 1
      end
    end
  end
  local function make(k)
    k = math.max(0, math.min(k or 0, 20))
    for _ = 1, k do
      pcall(Effects.copySpell, spell, who, it.name)
    end
    say(it.name, who .. " copies " .. spell.getName() .. " " .. k .. " time" .. (k == 1 and "" or "s") .. ": aim each copy at a"
      .. " different target as it resolves.")
  end
  if n then
    make(n)
  else
    Effects.askAmount(who, it.name .. ": how many copies?", "One copy for each other thing " .. spell.getName() .. " could target."
      .. " Type the number, then OK.", "NONE", function(v) make(tonumber(v) or 0) end)
  end
end)
on("Glimmervoid Basin", "each player except that creature's controller creates a token that's a copy", function(it, seat)
  pick(seat, it, "creature to copy", "Click TARGET on a creature: every player except its controller gets a token copy.",
    isCreature, function(obj)
      if not obj then
        return
      end
      local ctl = Effects.fieldSeat(obj)
      for _, c in ipairs(players()) do
        if c ~= ctl then
          copyFor(obj, c, it.name)
        end
      end
    end)
end)

-- Immersturm (watched: enters)
on("Immersturm", "may have it deal damage equal to its power to any target", function(it, seat)
  local who = it.that or seat
  local card = it.thatCard and getObjectFromGUID(it.thatCard)
  if card == nil or card.isDestroyed() then
    return
  end
  local n = powerOf(card)
  yesNo(who, it.name, who .. ": have " .. card.getName() .. " deal " .. n .. " damage to any target?", "YES", "NO", function(y)
    if y then
      run(it, who, card.getName():lower() .. " deals " .. n .. " damage to any target.")
    end
  end)
end)

-- Isle of Vesuva (watched: enters)
on("Isle of Vesuva", "its controller creates a token that's a copy of that creature", function(it, seat)
  local card = it.thatCard and getObjectFromGUID(it.thatCard)
  if card and not card.hasTag("Token") then
    copyFor(card, it.that or seat, it.name)
  end
end)
on("Isle of Vesuva", "destroy target creature and all other creatures with the same name", function(it, seat)
  pick(seat, it, "destroy", "Click TARGET on a creature: it and every creature with the same name are destroyed.", isCreature,
    function(obj)
      if obj then
        local nm = obj.getName()
        for _, e in ipairs(field(function(o) return isCreature(o) and o.getName() == nm end)) do
          sacrifice(e.obj)
        end
        say(it.name, "every " .. nm .. " is destroyed.")
      end
    end)
end)

-- Izzet Steam Maze (watched below)
on("Izzet Steam Maze", "that player copies it", function(it, seat)
  local g = it.thatCard
  local spell = g and getObjectFromGUID(g)
  if spell and Stack and Stack.has and Stack.has(g) and Effects.copySpell then
    local okc = pcall(Effects.copySpell, spell, it.that or seat, it.name)
    if okc then
      say(it.name, (it.that or seat) .. " copies " .. spell.getName() .. " (choose new targets for the copy if you like).")
      return
    end
  end
  say(it.name, (it.that or seat) .. " copies that spell (use COPY on it).", CYAN)
end)
on("Izzet Steam Maze", "instant and sorcery spells you cast this turn cost {3} less", function(it, seat)
  say(it.name, seat .. "'s instant and sorcery spells cost {3} less this turn.", CYAN)
end)

-- Kilnspire District
on("Kilnspire District", "put a charge counter on kilnspire district, then add {r}", function(it, seat)
  local n = addPC("Kilnspire District", "charge", 1)
  if ManaChips and ManaChips.add then
    ManaChips.add(seat, "R", n)
  end
  say(it.name, seat .. " adds " .. string.rep("{R}", n) .. ".")
end)
on("Kilnspire District", "you may pay {x}. if you do, kilnspire district deals x damage to any target", function(it, seat)
  Effects.askAmount(seat, it.name .. ": pay {X}", "Type X (the damage), then OK. Pay it from your mana.", "DON'T", function(v)
    local n = tonumber(v)
    if n and n > 0 then
      run(it, seat, "kilnspire district deals " .. n .. " damage to any target.")
    end
  end)
end)

-- Krosa
as("Krosa", "you may add {w}{u}{b}{r}{g}", "add {W}{U}{B}{R}{G}.")

-- Goldmeadow (watched: enters)
on("Goldmeadow", "that land's controller creates three 0/1 white goat creature tokens", function(it, seat)
  makeTokens(it.that or seat, "a 0/1 white Goat creature token", 3, it.name)
end)

-- Grand Ossuary
on("Grand Ossuary", "its controller distributes a number of +1/+1 counters equal to its power", function(it, seat)
  local who = it.that or seat
  local card = it.thatCard and getObjectFromGUID(it.thatCard)
  local n = card and (tonumber(data(card).power) or 0) or 0
  if card then
    local okL, last = pcall(function() return Counters.lastKnown and Counters.lastKnown(card) end)
    if okL and last and last.power then
      n = tonumber(last.power) or n
    end
  end
  if n <= 0 then
    say(it.name, "its power was 0: no counters.", INFO)
    return
  end
  local k = 0
  local function nxt()
    k = k + 1
    if k > n then
      return
    end
    pick(who, it, "+1/+1 counter " .. k .. " of " .. n, "Click TARGET on a creature you control for this counter, or DONE.",
      function(obj, owner) return owner == who and isCreature(obj) end, function(obj)
        if obj then
          plus(obj, 1, who)
          nxt()
        end
      end, "DONE")
  end
  nxt()
end)
on("Grand Ossuary", "each player exiles all creatures they control and creates x 1/1 green saproling", function(it, seat)
  for _, c in ipairs(players()) do
    local total = 0
    for _, e in ipairs(field(function(o, s) return s == c and isCreature(o) end)) do
      total = total + math.max(0, powerOf(e.obj)) * (Pile and Pile.count(e.obj) or 1)
      Combat.removeCard(e.obj, "exile")
    end
    if total > 0 then
      makeTokens(c, "a 1/1 green Saproling creature token", total, it.name)
    end
    say(it.name, c .. " exiles their creatures and creates " .. total .. " Saproling" .. (total == 1 and "" or "s") .. ".")
  end
end)

-- Jund (watched below)
on("Jund", "it gains devour 5", function(it, seat)
  local s = st()
  s.devour = s.devour or {}
  if it.thatCard then
    s.devour[it.thatCard] = 5
  end
  say(it.name, "that creature spell gains devour 5: as it enters, " .. (it.that or seat) .. " may sacrifice any number of"
    .. " creatures; it enters with five +1/+1 counters for each.", CYAN)
end)

-- Minamo (watched below)
on("Minamo", "that player may draw a card", function(it, seat)
  local who = it.that or seat
  yesNo(who, it.name, who .. ": draw a card?", "DRAW", "NO", function(y)
    if y then
      Actions.draw(who, 1, it.name)
    end
  end)
end)
on("Minamo", "each player may return a blue card from their graveyard to their hand", function(it, seat)
  each(fromSeat(seat), function(c, nxt)
    local blue = {}
    local pile = Library.pileIn(c, "graveyard")
    if pile and pile.type == "Deck" then
      for _, e in ipairs(pile.getObjects() or {}) do
        local okd, dd = pcall(function() return JSON.decode(e.gm_notes or "{}") end)
        local isBlue = false
        if okd and type(dd) == "table" then
          for _, x in ipairs(type(dd.colors) == "table" and dd.colors or {}) do
            if x == "U" then
              isBlue = true
            end
          end
        end
        if isBlue then
          table.insert(blue, { guid = e.guid, name = e.name or e.nickname or "?" })
        end
      end
    elseif pile and pile.type == "Card" and colorsOf(pile).U then
      table.insert(blue, { guid = pile.getGUID(), name = pile.getName() })
    end
    if #blue == 0 then
      nxt()
      return
    end
    local ch = {}
    for i = 1, math.min(#blue, 8) do
      table.insert(ch, { label = blue[i].name:sub(1, 18), value = i })
    end
    table.insert(ch, { label = "NONE", value = false })
    choose(c, it.name .. ": return a blue card?", c .. ": pick a blue card from your graveyard to return to your hand, or NONE.", ch,
      function(i)
        if i then
          takeFrom(c, "graveyard", { blue[i].guid }, "battlefield", function(card) toHand(card, c) end)
        end
        nxt()
      end)
  end)
end)

-- Mirrored Depths (watched below)
on("Mirrored Depths", "that player flips a coin. if the player loses the flip, counter that spell", function(it, seat)
  local win = math.random(2) == 1
  say(it.name, (it.that or seat) .. " flips a coin: " .. (win and "WIN, the spell stays." or "LOSE, the spell is countered."), CYAN)
  if not win and it.thatCard and Stack.counterGuid then
    pcall(Stack.counterGuid, it.thatCard, it.name)
  end
end)
on("Mirrored Depths", "target player reveals the top card of their library", function(it, seat)
  local ch = {}
  for _, c in ipairs(players()) do
    table.insert(ch, { label = string.upper(c), value = c })
  end
  choose(seat, it.name .. ": which player?", "That player reveals the top card of their library.", ch, function(c)
    if not c then
      return
    end
    Library.revealTop(c, function(card)
      if card == nil then
        return
      end
      if typeLine(card):find("land", 1, true) then
        say(it.name, c .. " reveals " .. card.getName() .. " (a land): it goes back on top.")
        Library.putAt(c, card, 0)
        return
      end
      say(it.name, c .. " reveals " .. card.getName() .. ": " .. seat .. " may cast it without paying its mana cost (drag it onto"
        .. " the battlefield to cast it, or click PUT BACK).", CYAN)
      yesNo(seat, it.name, "Cast " .. card.getName() .. " without paying its mana cost?", "CAST IT", "PUT IT BACK", function(y)
        if y then
          card.setPosition(TableSetup.slot(seat, "battlefield", TableSetup.SURFACE_TOP + 2))
          Wait.time(function() if Stack and Stack.onDrop then pcall(Stack.onDrop, seat, card) end end, 0.5)
        else
          Library.putAt(c, card, 0)
        end
      end)
    end)
  end)
end)

-- Mount Keralia
on("Mount Keralia", "put a pressure counter on mount keralia", function(it, seat)
  addPC("Mount Keralia", "pressure", 1)
end)
on("Mount Keralia", "it deals damage equal to the number of pressure counters on it to each creature and each planeswalker",
  function(it, seat)
    local n = pc("Mount Keralia")
    if n <= 0 then
      say(it.name, "no pressure counters: no damage.", INFO)
      return
    end
    local safe = st().keralia or {}
    for _, e in ipairs(field(function(o) local t = types(o); return t.creature or t.planeswalker end)) do
      if not safe[e.seat] then
        if types(e.obj).planeswalker and not types(e.obj).creature then
          Counters.change(e.obj, "loyalty", -n, seat)
        else
          damage(e.obj, n, it.name, seat)
        end
      end
    end
    say(it.name, n .. " damage to each creature and each planeswalker.")
  end)
on("Mount Keralia", "prevent all damage that planes named mount keralia would deal", function(it, seat)
  local s = st()
  s.keralia = s.keralia or {}
  s.keralia[seat] = true
  say(it.name, "damage from Mount Keralia to " .. seat .. "'s permanents is prevented for the rest of the game.", CYAN)
end)

-- Murasa (watched: enters)
on("Murasa", "its controller may search their library for a basic land card", function(it, seat)
  run(it, it.that or seat, "you may search your library for a basic land card, put it onto the battlefield tapped, then shuffle.")
end)
on("Murasa", "target land becomes a 4/4 creature that's still a land", function(it, seat)
  pick(seat, it, "animate a land", "Click TARGET on a land: it becomes a 4/4 creature that's still a land.", function(obj)
    return types(obj).land
  end, function(obj)
    if obj then
      pcall(Effects.forgeAnimate, seat, { on = "that", p = 4, t = 4, perm = true, kw = "" }, { name = it.name, thatCard = obj.getGUID() })
    end
  end)
end)

-- Naar Isle
on("Naar Isle", "put a flame counter on naar isle", function(it, seat)
  local n = addPC("Naar Isle", "flame", 1)
  life(seat, -n, it.name)
  say(it.name, n .. " damage to " .. seat .. ".")
end)

-- Naya
on("Naya", "target red, green, or white creature you control gets +1/+1 until end of turn for each land you control", function(it, seat)
  local n = countOf(seat, function(o) return types(o).land end)
  pick(seat, it, "+" .. n .. "/+" .. n, "Click TARGET on a red, green or white creature you control.", function(obj, owner)
    local c = colorsOf(obj)
    return owner == seat and isCreature(obj) and (c.R or c.G or c.W)
  end, function(obj)
    if obj then
      boost(seat, obj, n, n, {}, "+" .. n .. "/+" .. n, it.name)
    end
  end)
end)

-- Orochi Colony
on("Orochi Colony", "target creature can't be blocked this turn", function(it, seat)
  pick(seat, it, "unblockable", "Click TARGET on a creature: it can't be blocked this turn.", isCreature, function(obj)
    if obj then
      local s = st()
      s.unblockable = s.unblockable or {}
      s.unblockable[obj.getGUID()] = turnNo()
      say(it.name, obj.getName() .. " can't be blocked this turn.")
    end
  end)
end)

-- Orzhova
on("Orzhova", "each player returns all creature cards from their graveyard to the battlefield", function(it, seat)
  for _, c in ipairs(players()) do
    local list = {}
    for _, e in ipairs(Effects.graveyardCards(c)) do
      if tostring(e.typeLine):lower():find("creature", 1, true) then
        table.insert(list, e.guid)
      end
    end
    takeFrom(c, "graveyard", list, "battlefield", function(card) toBattlefield(card, c, false) end)
    say(it.name, c .. " returns " .. #list .. " creature card" .. (#list == 1 and "" or "s") .. " to the battlefield.")
  end
end)
on("Orzhova", "for each opponent, exile up to one target creature card from that player's graveyard", function(it, seat)
  each(opps(seat), function(c, nxt)
    local list = {}
    for _, e in ipairs(Effects.graveyardCards(c)) do
      if tostring(e.typeLine):lower():find("creature", 1, true) then
        table.insert(list, e)
      end
    end
    if #list == 0 then
      nxt()
      return
    end
    local ch = {}
    for i = 1, math.min(#list, 8) do
      table.insert(ch, { label = list[i].name:sub(1, 18), value = i })
    end
    table.insert(ch, { label = "NONE", value = false })
    choose(seat, it.name .. ": " .. c .. "'s graveyard", "Pick a creature card to exile, or NONE.", ch, function(i)
      if i then
        takeFrom(c, "graveyard", { list[i].guid }, "exile", function(card)
          card.setPosition(TableSetup.slot(c, "exile", TableSetup.SURFACE_TOP + 2))
          Wait.time(function() if not card.isDestroyed() then Zones.refresh(card) end end, 0.5)
        end)
      end
      nxt()
    end)
  end)
end)

-- Panopticon
as("Panopticon", "draw an additional card", "draw a card.")

-- Pools of Becoming
on("Pools of Becoming", "put the cards in your hand on the bottom of your library in any order, then draw that many cards",
  function(it, seat)
    local hand = handOf(seat)
    local n = #hand
    if n == 0 then
      say(it.name, seat .. " has no cards in hand.", INFO)
      return
    end
    Library.putOnBottom(seat, hand, function()
      Actions.draw(seat, n, it.name)
    end)
    say(it.name, seat .. " puts " .. n .. " card" .. (n == 1 and "" or "s") .. " on the bottom and draws that many.")
  end)
on("Pools of Becoming", "reveal the top three cards of your planar deck", function(it, seat)
  local list = Planechase.deckList()
  local top = {}
  for i = 1, math.min(3, #list) do
    table.insert(top, list[i])
  end
  local nm = {}
  for _, e in ipairs(top) do
    table.insert(nm, e.name)
  end
  say(it.name, "reveals " .. table.concat(nm, ", ") .. ": their chaos abilities trigger.", CYAN)
  for _, e in ipairs(top) do
    if e.type ~= "Phenomenon" then
      Planechase.chaosOn(seat, e.name)
    end
  end
  local order = {}
  for i = #top + 1, #list do
    table.insert(order, i)
  end
  for i = 1, #top do
    table.insert(order, i)
  end
  Planechase.reorderDeck(order)
end)

-- Prahv
on("Prahv", "you gain life equal to the number of cards in your hand", function(it, seat)
  life(seat, #handOf(seat), it.name)
end)

-- Quicksilver Sea
on("Quicksilver Sea", "reveal the top card of your library. you may play it without paying its mana cost", function(it, seat)
  Library.revealTop(seat, function(card)
    if card == nil then
      return
    end
    yesNo(seat, it.name, "Play " .. card.getName() .. " without paying its mana cost?", "PLAY IT", "PUT IT BACK", function(y)
      if y then
        if typeLine(card):find("land", 1, true) then
          toBattlefield(card, seat, false)
        else
          card.setPosition(TableSetup.slot(seat, "battlefield", TableSetup.SURFACE_TOP + 2))
          Wait.time(function() if Stack and Stack.onDrop then pcall(Stack.onDrop, seat, card) end end, 0.5)
        end
      else
        Library.putAt(seat, card, 0)
      end
    end)
  end)
end)

-- Sanctum of Serra
on("Sanctum of Serra", "you may have your life total become 20", function(it, seat)
  yesNo(seat, it.name, "Have your life total become 20?", "YES", "NO", function(y)
    if y then
      life(seat, 20 - (GameState.player(seat).life or 0), it.name)
    end
  end)
end)

-- Sea of Sand (draws watched below)
on("Sea of Sand", "that player gains 3 life", function(it, seat) life(it.that or seat, 3, it.name) end)
on("Sea of Sand", "that player loses 3 life", function(it, seat) life(it.that or seat, -3, it.name) end)
on("Sea of Sand", "put target permanent on top of its owner's library", function(it, seat)
  pick(seat, it, "to the top of its library", "Click TARGET on a permanent: it goes on top of its owner's library.",
    function() return true end, function(obj)
      if obj then
        local owner = Effects.ownerOf(obj) or Effects.fieldSeat(obj)
        if obj.hasTag("Token") then
          Combat.removeCard(obj, "library")
        else
          Library.putAt(owner, obj, 0)
        end
        say(it.name, obj.getName() .. " goes on top of " .. tostring(owner) .. "'s library.")
      end
    end)
end)

-- Skybreen
on("Skybreen", "target player loses life equal to the number of cards in their hand", function(it, seat)
  local ch = {}
  for _, c in ipairs(players()) do
    table.insert(ch, { label = string.upper(c) .. " (" .. #handOf(c) .. ")", value = c })
  end
  choose(seat, it.name .. ": which player?", "That player loses life equal to the cards in their hand.", ch, function(c)
    if c then
      life(c, -#handOf(c), it.name)
    end
  end)
end)

-- Sokenzan / Valor's Reach: untap and an additional combat
local function extraCombat(seat, name)
  local id = stepId()
  if id == "main1" or id == "main2" then
    if Turns.addExtraCombat then
      Turns.addExtraCombat(Turns.activeTeam and Turns.activeTeam()[1] or seat)
    end
  else
    say(name, "it isn't a main phase, so there's no additional combat.", INFO)
  end
end
on("Sokenzan", "untap all creatures that attacked this turn", function(it, seat)
  local s = st()
  local n = 0
  for g, tn in pairs(s.attackedThisTurn or {}) do
    if tn == turnNo() then
      local o = getObjectFromGUID(g)
      if o and Effects.fieldSeat(o) then
        Effects.untapObj(o)
        n = n + 1
      end
    end
  end
  say(it.name, n .. " creature" .. (n == 1 and "" or "s") .. " that attacked this turn untap.")
  extraCombat(seat, it.name)
end)
on("Valor's Reach", "untap up to two target creatures your team controls", function(it, seat)
  local k = 0
  local function nxt()
    k = k + 1
    if k > 2 then
      extraCombat(seat, it.name)
      return
    end
    pick(seat, it, "untap " .. k .. " of 2", "Click TARGET on a creature your team controls, or DONE.", function(obj, owner)
      return isCreature(obj) and not TableSetup.isOpponent(owner, seat)
    end, function(obj)
      if obj then
        Effects.untapObj(obj)
        nxt()
      else
        extraCombat(seat, it.name)
      end
    end, "DONE")
  end
  nxt()
end)

-- Lair of the Ashen Idol
on("Lair of the Ashen Idol", "sacrifice a creature. if you can't, planeswalk", function(it, seat)
  if countOf(seat, isCreature) == 0 then
    say(it.name, seat .. " can't sacrifice a creature: planeswalk!", CYAN)
    Planechase.push(seat, "Planeswalk", "Planeswalk: Lair of the Ashen Idol leaves and the next plane turns face up.", "walk")
    return
  end
  sacOne(it, seat, "a creature", function(o) return isCreature(o) end)
end)
on("Lair of the Ashen Idol", "any number of target players each create a 2/2 black zombie creature token", function(it, seat)
  each(players(), function(c, nxt)
    yesNo(seat, it.name, "Does " .. c .. " create a 2/2 black Zombie?", "YES", "NO", function(y)
      if y then
        makeTokens(c, "a 2/2 black Zombie creature token", 1, it.name)
      end
      nxt()
    end)
  end)
end)

-- Selesnya Loft Gardens (mana watched below)
on("Selesnya Loft Gardens", "whenever you tap a land for mana, add one mana of any type that land produced", function(it, seat)
  local s = st()
  s.loftMana = { seat = seat, turn = turnNo() }
  say(it.name, "until end of turn, " .. seat .. "'s lands make one extra mana of a type they made.", CYAN)
end)

-- Stairs to Infinity
on("Stairs to Infinity", "reveal the top card of your planar deck. you may put it on the bottom", function(it, seat)
  local list = Planechase.deckList()
  if #list == 0 then
    return
  end
  yesNo(seat, it.name, "The top card of the planar deck is " .. list[1].name .. ". Put it on the bottom?", "BOTTOM", "KEEP ON TOP",
    function(y)
      if y then
        local order = {}
        for i = 2, #list do
          table.insert(order, i)
        end
        table.insert(order, 1)
        Planechase.reorderDeck(order)
        say(it.name, list[1].name .. " goes to the bottom of the planar deck.")
      else
        say(it.name, list[1].name .. " stays on top of the planar deck.")
      end
    end)
end)

-- Stensia (watched below)
on("Stensia", "put a +1/+1 counter on it", function(it, seat)
  local card = it.thatCard and getObjectFromGUID(it.thatCard)
  if card then
    plus(card, 1, Effects.fieldSeat(card) or seat)
  end
end)

-- Takenuma
on("Takenuma", "its controller draws a card", function(it, seat)
  Actions.draw(it.that or seat, 1, it.name)
end)
on("Takenuma", "return target creature you control to its owner's hand", function(it, seat)
  pick(seat, it, "return to hand", "Click TARGET on a creature you control.", function(obj, owner)
    return owner == seat and isCreature(obj)
  end, function(obj)
    if obj then
      Effects.returnToHand(obj)
    end
  end)
end)

-- Talon Gates
on("Talon Gates", "remove two time counters from each suspended card you own", function(it, seat)
  local n = 0
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() then
      local loc = Zones.regionAt(obj.getPosition())
      local c = Counters.get(obj)
      if loc.region == "exile" and (Effects.ownerOf(obj) or loc.seat) == seat and (c.tc or 0) > 0 then
        Counters.change(obj, "tc", -2, seat)
        n = n + 1
      end
    end
  end
  say(it.name, "two time counters come off " .. n .. " suspended card" .. (n == 1 and "" or "s") .. ".")
end)

-- Tazeem
on("Tazeem", "draw a card for each land you control", function(it, seat)
  local n = countOf(seat, function(o) return types(o).land end)
  Actions.draw(seat, n, it.name)
end)

-- Tember City
on("Tember City", "tember city deals 1 damage to that player", function(it, seat)
  life(it.that or seat, -1, it.name)
end)
on("Tember City", "each other player sacrifices a nonland permanent", function(it, seat)
  each(fromSeat(seat), function(c, nxt)
    if c == seat then
      nxt()
      return
    end
    sacOne(it, c, "a nonland permanent", function(o) return not types(o).land end, function() nxt() end)
  end)
end)

-- The Aether Flues
on("The Aether Flues", "you may sacrifice a creature. if you do, reveal cards from the top of your library", function(it, seat)
  if countOf(seat, isCreature) == 0 then
    return
  end
  yesNo(seat, it.name, "Sacrifice a creature to reveal until a creature card and put it onto the battlefield?", "SACRIFICE",
    "DON'T", function(y)
      if not y then
        return
      end
      sacOne(it, seat, "a creature", function(o) return isCreature(o) end, function(obj)
        if obj then
          run(it, seat, "reveal cards from the top of your library until you reveal a creature card. put that card onto the"
            .. " battlefield and shuffle the rest into your library.")
        end
      end)
    end)
end)
on("The Aether Flues", "you may put a creature card from your hand onto the battlefield", function(it, seat)
  Effects.pickFromHand(seat, it.name .. ": a creature from your hand", "Pick a creature card to put onto the battlefield.",
    function(h, d) return tostring(d.typeLine or ""):lower():find("creature", 1, true) ~= nil end, function(card)
      if card then
        toBattlefield(card, seat, false)
      end
    end)
end)

-- The Dark Barony (watched below)
on("The Dark Barony", "that player loses 1 life", function(it, seat)
  life(it.that or seat, -1, it.name)
end)

-- The Hippodrome
on("The Hippodrome", "you may destroy target creature if its power is 0 or less", function(it, seat)
  pick(seat, it, "destroy", "Click TARGET on a creature with power 0 or less, or SKIP.", function(obj)
    return isCreature(obj) and powerOf(obj) <= 0
  end, function(obj)
    if obj then
      sacrifice(obj)
      say(it.name, obj.getName() .. " is destroyed.")
    end
  end)
end)

-- The Maelstrom
on("The Maelstrom", "you may reveal the top card of your library. if it's a permanent card", function(it, seat)
  yesNo(seat, it.name, "Reveal the top card of your library?", "REVEAL", "DON'T", function(y)
    if not y then
      return
    end
    Library.revealTop(seat, function(card)
      if card == nil then
        return
      end
      local tl = typeLine(card)
      local perm = not (tl:find("instant", 1, true) or tl:find("sorcery", 1, true))
      if not perm then
        say(it.name, seat .. " reveals " .. card.getName() .. ": not a permanent, it goes to the bottom.")
        Library.putOnBottom(seat, { card })
        return
      end
      yesNo(seat, it.name, "Put " .. card.getName() .. " onto the battlefield?", "PUT IT IN", "BOTTOM", function(y2)
        if y2 then
          toBattlefield(card, seat, false)
        else
          Library.putOnBottom(seat, { card })
        end
      end)
    end)
  end)
end)

-- Truga Jungle / Turri Island
on("Truga Jungle", "put all land cards revealed this way into your hand and the rest on the bottom", function(it, seat)
  revealTop(seat, 3, function(list)
    local rest = {}
    for _, c in ipairs(list) do
      if typeLine(c):find("land", 1, true) then
        toHand(c, seat)
      else
        table.insert(rest, c)
      end
    end
    say(it.name, seat .. " reveals " .. names(list) .. ": lands to hand, the rest to the bottom.")
    if #rest > 0 then
      Wait.time(function() Library.putOnBottom(seat, rest) end, 0.6)
    end
  end)
end)
on("Turri Island", "put all creature cards revealed this way into your hand and the rest into your graveyard", function(it, seat)
  revealTop(seat, 3, function(list)
    for _, c in ipairs(list) do
      if typeLine(c):find("creature", 1, true) then
        toHand(c, seat)
      else
        c.setPosition(TableSetup.slot(seat, "graveyard", TableSetup.SURFACE_TOP + 2))
        Wait.time(function() if not c.isDestroyed() then Zones.refresh(c) end end, 0.5)
      end
    end
    say(it.name, seat .. " reveals " .. names(list) .. ": creatures to hand, the rest to the graveyard.")
  end)
end)

-- Undercity Reaches (combat damage watched below)
on("Undercity Reaches", "its controller may draw a card", function(it, seat)
  local who = it.that or seat
  yesNo(who, it.name, who .. ": draw a card?", "DRAW", "NO", function(y)
    if y then
      Actions.draw(who, 1, it.name)
    end
  end)
end)
on("Undercity Reaches", "you have no maximum hand size for the rest of the game", function(it, seat)
  local s = st()
  s.noMaxHand = s.noMaxHand or {}
  s.noMaxHand[seat] = true
  say(it.name, seat .. " has no maximum hand size for the rest of the game.", CYAN)
end)

-- Velis Vel
on("Velis Vel", "target creature gains all creature types until end of turn", function(it, seat)
  pick(seat, it, "all creature types", "Click TARGET on a creature: it has every creature type this turn.", isCreature, function(obj)
    if obj then
      local s = st()
      s.allTypes = s.allTypes or {}
      s.allTypes[obj.getGUID()] = turnNo()
      say(it.name, obj.getName() .. " has every creature type until end of turn.")
      if Statics and Statics.soon then
        Statics.soon()
      end
    end
  end)
end)

-- Windriddle Palaces
on("Windriddle Palaces", "each player mills a card", function(it, seat)
  for _, c in ipairs(players()) do
    Actions.mill(c, 1)
  end
end)

-- The Fourth Sphere
on("The Fourth Sphere", "sacrifice a nonblack creature", function(it, seat)
  sacOne(it, seat, "a nonblack creature", function(o) return isCreature(o) and not colorsOf(o).B end)
end)

-- Enigma Ridges
on("Enigma Ridges", "each player who controls fewer lands than the player who controls the most lands", function(it, seat)
  local most = 0
  local count = {}
  for _, c in ipairs(players()) do
    count[c] = countOf(c, function(o) return types(o).land end)
    most = math.max(most, count[c])
  end
  for _, c in ipairs(players()) do
    local diff = most - count[c]
    if diff > 0 then
      run(it, c, "search your library for up to " .. diff .. " basic land cards, reveal them, put them into your hand, then shuffle.")
    end
  end
end)

-- Esper
on("Esper", "creatures you control that are white, blue, and/or black become artifacts", function(it, seat)
  local n = 0
  for _, e in ipairs(field(function(o, s) return s == seat and isCreature(o) end)) do
    local c = colorsOf(e.obj)
    if c.W or c.U or c.B or types(e.obj).artifact then
      boost(seat, e.obj, 0, 0, { "vigilance", "menace", "lifelink" }, "vigilance, menace, lifelink", it.name)
      n = n + 1
    end
  end
  say(it.name, n .. " artifact creature" .. (n == 1 and "" or "s") .. " gain vigilance, menace and lifelink until end of turn.")
end)

-- Ghirapur / New New York: artifacts become Vehicles (the table shows it; crew by hand)
local function makeVehicles(it, seat, p, t, kw, crew, skipVehicles)
  local s = st()
  s.vehicles = s.vehicles or {}
  local n = 0
  for _, e in ipairs(field(function(o, se) return se == seat and types(o).artifact and not types(o).creature end)) do
    if not (skipVehicles and typeLine(e.obj):find("vehicle", 1, true)) then
      s.vehicles[e.obj.getGUID()] = { seat = seat, p = p, t = t, kw = kw, crew = crew, turn = turnNo(), name = it.name }
      n = n + 1
    end
  end
  say(it.name, n .. " artifact" .. (n == 1 and "" or "s") .. " of " .. seat .. " are " .. p .. "/" .. t .. " Vehicles (" .. kw
    .. ", crew " .. crew .. ") this turn: click CREW on the plane, pick the Vehicle, then tap creatures with total power "
    .. crew .. " or more.", CYAN)
  pcall(Planechase.showCounters)
end
on("Ghirapur", "each noncreature, non-vehicle artifact you control becomes a 5/3 vehicle", function(it, seat)
  makeVehicles(it, seat, 5, 3, "trample and haste", 2, true)
end)
on("New New York", "noncreature artifacts you control become 3/3 vehicles", function(it, seat)
  makeVehicles(it, seat, 3, 3, "flying and haste", 1, false)
end)

-- Inys Haen
on("Inys Haen", "each player returns all land cards from their graveyard to the battlefield tapped", function(it, seat)
  for _, c in ipairs(players()) do
    local list = {}
    for _, e in ipairs(Effects.graveyardCards(c)) do
      if tostring(e.typeLine):lower():find("land", 1, true) then
        table.insert(list, e.guid)
      end
    end
    takeFrom(c, "graveyard", list, "lands", function(card) toBattlefield(card, c, true) end)
  end
end)

-- Ketria
on("Ketria", "put your choice of a vigilance, menace, or trample counter on target creature you control", function(it, seat)
  choose(seat, it.name .. ": which counter?", "Pick the keyword counter.", { { label = "VIGILANCE", value = "vigilance" },
    { label = "MENACE", value = "menace" }, { label = "TRAMPLE", value = "trample" } }, function(kw)
      if not kw then
        return
      end
      run(it, seat, "put a " .. kw .. " counter on target creature you control.")
    end)
end)
on("Ketria", "exile cards from the top of your library until you exile a nonland permanent card", function(it, seat)
  Library.exileUntilNonland(seat, false, function(card)
    if card == nil then
      return
    end
    yesNo(seat, it.name, card.getName() .. ": onto the battlefield or into your hand?", "BATTLEFIELD", "HAND", function(y)
      if y then
        toBattlefield(card, seat, false)
      else
        toHand(card, seat)
      end
    end)
  end, function(obj)
    local tl = typeLine(obj)
    return not tl:find("land", 1, true) and not tl:find("instant", 1, true) and not tl:find("sorcery", 1, true)
  end)
end)

-- New Argive (watched below)
on("New Argive", "it gets +2/+2 until end of turn", function(it, seat)
  local card = it.thatCard and getObjectFromGUID(it.thatCard)
  if card then
    boost(seat, card, 2, 2, {}, "+2/+2", it.name)
  end
end)

-- Norn's Seedcore
on("Norn's Seedcore", "chaos ensues", function(it, seat)
  Planechase.chaosOn(seat, "Norn's Seedcore")
end)
on("Norn's Seedcore", "planeswalk to it, except don't planeswalk away from any plane", function(it, seat)
  Planechase.addPlane(seat)
end)

-- Strixhaven
on("Strixhaven", "return up to one target instant or sorcery card from a graveyard to its owner's hand", function(it, seat)
  local list = {}
  for _, c in ipairs(players()) do
    for _, e in ipairs(Effects.graveyardCards(c)) do
      local tl = tostring(e.typeLine):lower()
      if tl:find("instant", 1, true) or tl:find("sorcery", 1, true) then
        table.insert(list, { guid = e.guid, name = e.name, owner = c })
      end
    end
  end
  if #list == 0 then
    say(it.name, "no instant or sorcery card in any graveyard.", INFO)
    return
  end
  local ch = {}
  for i = 1, math.min(#list, 8) do
    table.insert(ch, { label = (list[i].name:sub(1, 14) .. " (" .. list[i].owner .. ")"), value = i })
  end
  table.insert(ch, { label = "NONE", value = false })
  choose(seat, it.name .. ": return a card", "Pick an instant or sorcery card to return to its owner's hand.", ch, function(i)
    if i then
      local e = list[i]
      takeFrom(e.owner, "graveyard", { e.guid }, "battlefield", function(card) toHand(card, e.owner) end)
    end
  end)
end)

-- The Fertile Lands of Saulvinia (mana watched below)
on("The Fertile Lands of Saulvinia", "reveal cards from the top of your planar deck until you reveal a plane card. chaos ensues on that plane",
  function(it, seat)
    local list = Planechase.deckList()
    local k
    for i, e in ipairs(list) do
      if e.type ~= "Phenomenon" then
        k = i
        break
      end
    end
    if not k then
      return
    end
    say(it.name, "reveals " .. list[k].name .. ": chaos ensues there.", CYAN)
    Planechase.chaosOn(seat, list[k].name)
    local order = {}
    for i = k + 1, #list do
      table.insert(order, i)
    end
    for i = 1, k do
      table.insert(order, i)
    end
    Planechase.reorderDeck(order)
  end)

-- The Great Aerie
on("The Great Aerie", "bolster 3", function(it, seat)
  local least, list = nil, {}
  for _, e in ipairs(field(function(o, s) return s == seat and isCreature(o) end)) do
    local t = toughOf(e.obj)
    if least == nil or t < least then
      least, list = t, { e.obj }
    elseif t == least then
      table.insert(list, e.obj)
    end
  end
  if #list == 0 then
    return
  end
  if #list == 1 then
    plus(list[1], 3, seat)
    say(it.name, list[1].getName() .. " gets three +1/+1 counters (bolster 3).")
    return
  end
  pick(seat, it, "bolster 3", "Click TARGET on one of your creatures with the least toughness (" .. least .. ").", function(obj, owner)
    return owner == seat and isCreature(obj) and toughOf(obj) == least
  end, function(obj)
    if obj then
      plus(obj, 3, seat)
    end
  end)
end)
on("The Great Aerie", "each of those creatures deals damage equal to its toughness to the other", function(it, seat)
  pick(seat, it, "your creature", "Click TARGET on a creature you control, or SKIP.", function(obj, owner)
    return owner == seat and isCreature(obj)
  end, function(a)
    pick(seat, it, "their creature", "Click TARGET on a creature an opponent controls, or SKIP.", function(obj, owner)
      return TableSetup.isOpponent(owner, seat) and isCreature(obj)
    end, function(b)
      if a and b then
        local ta, tb = toughOf(a), toughOf(b)
        damage(b, ta, it.name, seat)
        damage(a, tb, it.name, seat)
        say(it.name, a.getName() .. " and " .. b.getName() .. " deal damage equal to their toughness to each other.")
      end
    end)
  end)
end)

-- Paliano (watched below)
on("Paliano", "if there is no monarch, you become the monarch", function(it, seat)
  if GameState.data.monarch == nil and Effects.setMonarch then
    Effects.setMonarch(seat, it.name)
  end
end)

-- Riptide Island
on("Riptide Island", "slivers you control gain haste and get +x/+x", function(it, seat)
  local list = field(function(o, s) return s == seat and isCreature(o) and typeLine(o):find("sliver", 1, true) end)
  local n = 0
  for _, e in ipairs(list) do
    n = n + (Pile and Pile.count(e.obj) or 1)
  end
  for _, e in ipairs(list) do
    boost(seat, e.obj, n, n, { "haste" }, "+" .. n .. "/+" .. n .. " and haste", it.name)
  end
end)

-- Towashi
on("Towashi", "distribute three +1/+1 counters among one, two, or three target creatures you control", function(it, seat)
  local k = 0
  local function nxt()
    k = k + 1
    if k > 3 then
      return
    end
    pick(seat, it, "+1/+1 counter " .. k .. " of 3", "Click TARGET on a creature you control for this counter.", function(obj, owner)
      return owner == seat and isCreature(obj)
    end, function(obj)
      if obj then
        plus(obj, 1, seat)
        nxt()
      end
    end, "DONE")
  end
  nxt()
end)

-- Valor's Reach (attacks watched below)
on("Valor's Reach", "those creatures gain double strike until end of turn", function(it, seat)
  for _, g in ipairs(it.cards or {}) do
    local o = getObjectFromGUID(g)
    if o then
      boost(seat, o, 0, 0, { "double strike" }, "double strike", it.name)
    end
  end
end)

-- The Pit
on("The Pit", "each player creates their choice of a 3/3 white angel creature token with flying or a 6/6 black demon", function(it, seat)
  each(fromSeat(seat), function(c, nxt)
    choose(c, it.name .. ": Angel or Demon?", c .. ": a 3/3 white Angel with flying, or a 6/6 black Demon with flying and trample"
      .. " (at your upkeep, sacrifice another creature; if you can't, it deals 6 damage to you).",
      { { label = "ANGEL", value = "a" }, { label = "DEMON", value = "d" } }, function(v)
        if v == "d" then
          makeTokens(c, "a 6/6 black Demon creature token with flying and trample", 1, it.name)
          local s = st()
          s.pitDemons = s.pitDemons or {}
          s.pitDemons[c] = (s.pitDemons[c] or 0) + 1
        else
          makeTokens(c, "a 3/3 white Angel creature token with flying", 1, it.name)
        end
        nxt()
      end)
  end)
end)
on("The Pit", "each player sacrifices a nonartifact creature", function(it, seat)
  each(fromSeat(seat), function(c, nxt)
    sacOne(it, c, "a nonartifact creature", function(o) return isCreature(o) and not types(o).artifact end, function() nxt() end)
  end)
end)

-- Unyaro
on("Unyaro", "if you planeswalked to unyaro this turn, untap all creatures", function(it, seat)
  local s = st()
  if s.arrived and s.arrived["Unyaro"] == turnNo() then
    local list = field(function(o) return isCreature(o) end)
    for _, e in ipairs(list) do
      Effects.untapObj(e.obj)
    end
    Wait.time(function()
      for _, e in ipairs(list) do
        phaseOut(e.obj)
      end
    end, 0.8)
    say(it.name, #list .. " creature" .. (#list == 1 and "" or "s") .. " untap and phase out until a player planeswalks (greyed"
      .. " out: they're treated as though they don't exist).", CYAN)
  else
    say(it.name, "you didn't planeswalk to Unyaro this turn: nothing happens.", INFO)
  end
end)

-- The Golden City of Orazca
on("The Golden City of Orazca", "you may put a permanent card from your hand onto the battlefield tapped", function(it, seat)
  Effects.pickFromHand(seat, it.name .. ": a permanent from your hand", "Pick a permanent card to put onto the battlefield tapped.",
    function(h, d)
      local tl = tostring(d.typeLine or ""):lower()
      return not (tl:find("instant", 1, true) or tl:find("sorcery", 1, true))
    end, function(card)
      if card then
        toBattlefield(card, seat, true)
      end
    end)
end)

-- Phenomena
on("Chaotic Aether", "each blank roll of the planar die is a", function(it, seat)
  say(it.name, "until a player planeswalks away from a plane, blank rolls count as chaos.", CYAN)
end)
on("Interplanar Tunnel", "reveal cards from the top of your planar deck until you reveal five plane cards", function(it, seat)
  local list = Planechase.deckList()
  local planes, lastIdx = {}, 0
  for i, e in ipairs(list) do
    if e.type ~= "Phenomenon" and #planes < 5 then
      table.insert(planes, i)
      lastIdx = i
    end
  end
  if #planes == 0 then
    return
  end
  local ch = {}
  for _, i in ipairs(planes) do
    table.insert(ch, { label = list[i].name:sub(1, 22), value = i })
  end
  choose(seat, it.name .. ": the next plane", "Pick the plane that goes on top of the planar deck (the next one you planeswalk to).",
    ch, function(pickI)
      pickI = pickI or planes[1]
      local revealed = {}
      for i = 1, lastIdx do
        if i ~= pickI then
          table.insert(revealed, i)
        end
      end
      for i = #revealed, 2, -1 do
        local j = math.random(i)
        revealed[i], revealed[j] = revealed[j], revealed[i]
      end
      local order = { pickI }
      for i = lastIdx + 1, #list do
        table.insert(order, i)
      end
      for _, i in ipairs(revealed) do
        table.insert(order, i)
      end
      Planechase.reorderDeck(order)
      say(it.name, list[pickI].name .. " goes on top of the planar deck; the other revealed cards go to the bottom.")
    end)
end)
on("Morphic Tide", "each player shuffles all permanents they own into their library", function(it, seat)
  for _, c in ipairs(players()) do
    local mine = {}
    local n = 0
    for _, e in ipairs(field()) do
      local owner = Effects.ownerOf(e.obj) or e.seat
      if owner == c then
        n = n + 1
        if e.obj.hasTag("Token") then
          Combat.removeCard(e.obj, "library")
        else
          table.insert(mine, e.obj)
        end
      end
    end
    local function deal()
      if n == 0 then
        return
      end
      revealTop(c, n, function(cards)
        local later = {}
        for _, card in ipairs(cards) do
          local tl = typeLine(card)
          if tl:find("artifact", 1, true) or tl:find("creature", 1, true) or tl:find("land", 1, true)
              or tl:find("planeswalker", 1, true) then
            toBattlefield(card, c, false)
          elseif tl:find("enchantment", 1, true) then
            table.insert(later, card)
          else
            Library.putOnBottom(c, { card })
          end
        end
        Wait.time(function()
          for _, card in ipairs(later) do
            toBattlefield(card, c, false)
          end
        end, 1)
        say(it.name, c .. " reveals " .. names(cards) .. ".")
      end)
    end
    if #mine > 0 then
      Library.returnCards(c, mine)
      Wait.time(function()
        local lib = Library.find(c)
        if lib and lib.type == "Deck" then
          lib.shuffle()
        end
        Wait.time(deal, 1)
      end, 1.5)
    else
      deal()
    end
  end
end)
on("Reality Shaping", "starting with you, each player may put a permanent card from their hand onto the battlefield", function(it, seat)
  each(fromSeat(seat), function(c, nxt)
    Effects.pickFromHand(c, it.name .. ": a permanent from your hand", c .. ": pick a permanent card to put onto the battlefield.",
      function(h, d)
        local tl = tostring(d.typeLine or ""):lower()
        return not (tl:find("instant", 1, true) or tl:find("sorcery", 1, true))
      end, function(card)
        if card then
          toBattlefield(card, c, false)
        end
        nxt()
      end)
  end)
end)
on("Spatial Merging", "simultaneously planeswalk to both of them", function(it, seat)
  Planechase.mergeNext()
  say(it.name, "the next planeswalk goes to the next TWO planes (Phenomena on the way go to the bottom).", CYAN)
end)
on("Time Distortion", "reverse the game's turn order", function(it, seat)
  Turns.reverse(seat)
end)
on("Fixed Point in Time", "if a player would planeswalk as a result of rolling the planar die, chaos ensues instead", function(it, seat)
  local pcd = GameState.data.planechase or {}
  GameState.data.planechase = pcd
  pcd.fixedPoint = { seat = seat, untilTurn = turnNo() + #players() }
  say(it.name, "until " .. seat .. "'s next turn, a planeswalk roll is chaos instead.", CYAN)
end)
on("Unleash the Flux", "each player sacrifices a nonland permanent, then you flip a coin", function(it, seat)
  local function round()
    each(fromSeat(seat), function(c, nxt)
      sacOne(it, c, "a nonland permanent", function(o) return not types(o).land end, function() nxt() end)
    end, function()
      local win = math.random(2) == 1
      say(it.name, seat .. " flips a coin: " .. (win and "WIN, it stops." or "LOSE, again!"), CYAN)
      if not win then
        Wait.time(round, 1)
      end
    end)
  end
  round()
end)
on("Caught in a Parallel Universe", "each player chooses a creature controlled by the player to their left", function(it, seat)
  each(fromSeat(seat), function(c, nxt)
    local left = leftOf(c)
    pick(c, it, "copy a creature", c .. ": click TARGET on a creature " .. left .. " controls (you get a copy with menace).",
      function(obj, owner) return owner == left and isCreature(obj) end, function(obj)
        if obj then
          copyFor(obj, c, it.name, { kws = { "menace" } })
        end
        nxt()
      end)
  end)
end)
on("Human-Time Lord Meta-Crisis", "each player chooses one or two creatures they control", function(it, seat)
  each(fromSeat(seat), function(c, nxt)
    pick(c, it, "first creature", c .. ": click TARGET on a creature you control (you get a non-legendary copy), or SKIP.",
      function(obj, owner) return owner == c and isCreature(obj) end, function(a)
        if not a then
          nxt()
          return
        end
        pick(c, it, "second creature", "Click TARGET on a second creature you control (the copy gets +1/+1 counters equal to its power), or SKIP.",
          function(obj, owner) return owner == c and isCreature(obj) and obj ~= a end, function(b)
            local n = b and powerOf(b) or 0
            local copy = copyFor(a, c, it.name, { unlegend = true })
            if copy and n > 0 then
              Wait.time(function() plus(copy, n, c) end, 2)
            end
            nxt()
          end)
      end)
  end)
end)

-- Amy's Home
on("Amy's Home", "you may exile a nonland card from your hand with a number of time counters on it equal to its mana value", function(it, seat)
  Effects.pickFromHand(seat, it.name .. ": suspend a card?", "Pick a nonland card: it's exiled with time counters equal to its mana value"
    .. " (it gains suspend).", function(h, d) return not tostring(d.typeLine or ""):lower():find("land", 1, true) end, function(card)
      if not card then
        return
      end
      local n = mvOf(card)
      card.setPosition(TableSetup.slot(seat, "exile", TableSetup.SURFACE_TOP + 2))
      Wait.time(function()
        if not card.isDestroyed() then
          Zones.refresh(card)
          Counters.change(card, "tc", n, seat)
        end
      end, 0.8)
      say(it.name, card.getName() .. " is exiled with " .. n .. " time counter" .. (n == 1 and "" or "s") .. " (suspended).")
    end)
end)
on("Amy's Home", "time travel", function(it, seat)
  local list = {}
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and (Counters.get(obj).tc or 0) > 0 then
      local loc = Zones.regionAt(obj.getPosition())
      if (Effects.ownerOf(obj) or loc.seat) == seat or loc.seat == seat then
        table.insert(list, obj)
      end
    end
  end
  if #list == 0 then
    say(it.name, seat .. " has nothing with time counters.", INFO)
    return
  end
  each(list, function(obj, nxt)
    choose(seat, it.name .. ": time travel", obj.getName() .. " has " .. (Counters.get(obj).tc or 0) .. " time counters.",
      { { label = "ADD ONE", value = 1 }, { label = "REMOVE ONE", value = -1 }, { label = "LEAVE", value = false } }, function(v)
        if v then
          Counters.change(obj, "tc", v, seat)
        end
        nxt()
      end)
  end)
end)

-- Bad Wolf Bay
on("Bad Wolf Bay", "cards can't enter the battlefield from exile this turn", function(it, seat)
  st().noExileEnter = turnNo()
  say(it.name, "cards can't enter the battlefield from exile this turn.", CYAN)
end)

-- Bowie Base One
on("Bowie Base One", "target creature gains islandwalk until end of turn", function(it, seat)
  pick(seat, it, "islandwalk", "Click TARGET on a creature: it gains islandwalk until end of turn.", isCreature, function(obj)
    if obj then
      boost(seat, obj, 0, 0, { "islandwalk" }, "islandwalk", it.name)
    end
  end)
end)

-- Coal Hill School (watched below)
on("Coal Hill School", "that player draws a card", function(it, seat)
  Actions.draw(it.that or seat, 1, it.name)
end)

-- Hotel of Fears
on("Hotel of Fears", "exile the top card of your library. you lose life equal to its mana value", function(it, seat)
  Library.revealTop(seat, function(card)
    if card == nil then
      return
    end
    local mv = mvOf(card)
    card.setPosition(TableSetup.slot(seat, "exile", TableSetup.SURFACE_TOP + 2))
    Wait.time(function() if not card.isDestroyed() then Zones.refresh(card) end end, 0.5)
    life(seat, -mv, it.name)
    say(it.name, seat .. " exiles " .. card.getName() .. ", loses " .. mv .. " life, and may play it this turn.")
  end)
end)
on("Hotel of Fears", "choose a color. put x +1/+1 counters on target creature you control, where x is your devotion", function(it, seat)
  choose(seat, it.name .. ": choose a color", "Your devotion to that color = the X.", { { label = "W", value = "W" },
    { label = "U", value = "U" }, { label = "B", value = "B" }, { label = "R", value = "R" }, { label = "G", value = "G" } }, function(col)
      if not col then
        return
      end
      local dev = 0
      for _, e in ipairs(field(function(o, s) return s == seat end)) do
        local cost = tostring(data(e.obj).manaCost or "")
        for sym in cost:gmatch("{([^}]*)}") do
          if sym:find(col, 1, true) then
            dev = dev + 1
          end
        end
      end
      pick(seat, it, dev .. " +1/+1 counters", "Click TARGET on a creature you control (devotion to " .. col .. " is " .. dev .. ").",
        function(obj, owner) return owner == seat and isCreature(obj) end, function(obj)
          if obj then
            plus(obj, dev, seat)
            sacOne(it, seat, "another creature", function(o) return isCreature(o) and o ~= obj end)
          end
        end)
    end)
end)

-- Lake Silencio
on("Lake Silencio", "lake silencio deals 6 damage to target creature an opponent controls", function(it, seat)
  pick(seat, it, "6 damage", "Click TARGET on a creature an opponent controls.", function(obj, owner)
    return isCreature(obj) and TableSetup.isOpponent(owner, seat)
  end, function(obj)
    if not obj then
      return
    end
    local left = toughOf(obj) - (Counters.get(obj).dmg or 0)
    if 6 >= left and not (Effects.hasKeyword and Effects.hasKeyword(obj, "indestructible")) then
      say(it.name, obj.getName() .. " takes 6 damage and would die: it's exiled instead.")
      Combat.removeCard(obj, "exile")
    else
      damage(obj, 6, it.name, seat)
    end
  end)
end)

-- Mondassian Colony Ship
on("Mondassian Colony Ship", "it gets +1/+1 until end of turn for each other creature its controller controls that shares", function(it, seat)
  local card = it.thatCard and getObjectFromGUID(it.thatCard)
  if not card then
    return
  end
  local ctl = Effects.fieldSeat(card) or seat
  local function subs(o)
    local tl = typeLine(o)
    local dash = tl:find("\226\128\148", 1, true)
    local out = {}
    if dash then
      for w in tl:sub(dash + 3):gmatch("%a+") do
        out[w] = true
      end
    end
    return out
  end
  local mine = subs(card)
  local n = 0
  for _, e in ipairs(field(function(o, s) return s == ctl and isCreature(o) and o ~= card end)) do
    for w in pairs(subs(e.obj)) do
      if mine[w] then
        n = n + 1
        break
      end
    end
  end
  if n > 0 then
    boost(ctl, card, n, n, {}, "+" .. n .. "/+" .. n, it.name)
  end
end)
on("Mondassian Colony Ship", "turn target creature face down. it becomes a 2/2 cyberman artifact creature", function(it, seat)
  pick(seat, it, "face down", "Click TARGET on a creature: it's turned face down as a 2/2 Cyberman artifact creature.", isCreature,
    function(obj)
      if obj then
        local r = obj.getRotation()
        obj.setRotationSmooth({ r.x, r.y, 180 }, false, true)
        say(it.name, obj.getName() .. " is turned face down: a 2/2 Cyberman artifact creature.")
      end
    end)
end)

-- Antarctic Research Base
on("Antarctic Research Base", "put x +1/+1 counters on target creature you control, where x is the number of artifacts", function(it, seat)
  local n = countOf(seat, function(o) return types(o).artifact end)
  pick(seat, it, n .. " +1/+1 counters", "Click TARGET on a creature you control (it also becomes a Plant).", function(obj, owner)
    return owner == seat and isCreature(obj)
  end, function(obj)
    if obj then
      plus(obj, n, seat)
    end
  end)
end)

-- Aplan Mortarium
on("Aplan Mortarium", "put an exposure counter on aplan mortarium", function(it, seat)
  local n = addPC("Aplan Mortarium", "exposure", 1)
  life(seat, -n, it.name)
end)

-- City of the Daleks (attacks watched below)
on("City of the Daleks", "target opponent loses x life, where x is the number of artifacts you control", function(it, seat)
  local n = countOf(seat, function(o) return types(o).artifact end)
  local ch = {}
  for _, c in ipairs(opps(seat)) do
    table.insert(ch, { label = string.upper(c), value = c })
  end
  choose(seat, it.name .. ": which opponent?", "That opponent loses " .. n .. " life.", ch, function(c)
    if c then
      life(c, -n, it.name)
    end
  end)
end)
local function daleks(it, seat, n, attacking)
  local made = {}
  makeTokens(seat, "a 3/3 black Dalek artifact creature token with menace", n, it.name, { haste = attacking ~= nil,
    onSpawn = function(tok)
      table.insert(made, tok.getGUID())
      local s = st()
      s.sacAtEnd = s.sacAtEnd or {}
      if attacking then
        table.insert(s.sacAtEnd, tok.getGUID())
      end
    end })
end
on("City of the Daleks", "for each opponent, you create a 3/3 black dalek artifact creature token with menace that attacks", function(it, seat)
  for _ in ipairs(opps(seat)) do
    daleks(it, seat, 1, true)
  end
  say(it.name, seat .. " creates a 3/3 Dalek with haste for each opponent; each must attack its opponent this turn, and they're"
    .. " sacrificed at the beginning of the next end step.", CYAN)
end)

-- Dalek Intensive Care
on("Dalek Intensive Care", "exile a non-dalek creature you control. if you do, create a 3/3 black dalek", function(it, seat)
  if countOf(seat, function(o) return isCreature(o) and not typeLine(o):find("dalek", 1, true) end) == 0 then
    return
  end
  pick(seat, it, "exile a non-Dalek", "Click TARGET on a non-Dalek creature you control.", function(obj, owner)
    return owner == seat and isCreature(obj) and not typeLine(obj):find("dalek", 1, true)
  end, function(obj)
    if obj then
      Combat.removeCard(obj, "exile")
      makeTokens(seat, "a 3/3 black Dalek artifact creature token with menace", 1, it.name)
    end
  end, "DONE")
end)
on("Dalek Intensive Care", "target dalek you control deals damage equal to its power to target creature you don't control", function(it, seat)
  pick(seat, it, "your Dalek", "Click TARGET on a Dalek you control.", function(obj, owner)
    return owner == seat and typeLine(obj):find("dalek", 1, true)
  end, function(a)
    if not a then
      return
    end
    pick(seat, it, "their creature", "Click TARGET on a creature you don't control.", function(obj, owner)
      return owner ~= seat and isCreature(obj)
    end, function(b)
      if b then
        damage(b, powerOf(a), it.name, seat)
      end
    end)
  end)
end)

-- Gardens of Tranquil Repose (dies watched below)
on("Gardens of Tranquil Repose", "exile it. its controller scries 1", function(it, seat)
  local s = st()
  s.gardens = (s.gardens or 0) + 1
  local who = it.that or seat
  takeFrom(it.owner or who, "graveyard", { it.thatCard }, "exile", function(card)
    card.setPosition(TableSetup.slot(it.owner or who, "exile", TableSetup.SURFACE_TOP + 2))
    Wait.time(function() if not card.isDestroyed() then Zones.refresh(card) end end, 0.5)
  end)
  run(it, who, "scry 1.")
end)
on("Gardens of Tranquil Repose", "create x 3/3 black dalek artifact creature tokens with menace", function(it, seat)
  local n = 1 + (st().gardens or 0)
  makeTokens(seat, "a 3/3 black Dalek artifact creature token with menace", n, it.name)
end)

-- Kerblam! Warehouse: fine as read.

-- Ood Sphere
on("Ood Sphere", "for each opponent, goad up to one target creature that opponent controls", function(it, seat)
  each(opps(seat), function(c, nxt)
    pick(seat, it, "goad (" .. c .. ")", "Click TARGET on a creature " .. c .. " controls, or SKIP.", function(obj, owner)
      return owner == c and isCreature(obj)
    end, function(obj)
      if obj then
        Counters.setGoad(obj, seat)
        local s = st()
        s.noTap = s.noTap or {}
        s.noTap[obj.getGUID()] = { seat = seat, turn = turnNo() }
        say(it.name, obj.getName() .. " is goaded, and can't become tapped (except to attack) until " .. seat .. "'s next turn.")
      end
      nxt()
    end)
  end)
end)

-- Pompeii
on("Pompeii", "put an eruption counter on it", function(it, seat)
  addPC("Pompeii", "eruption", 1)
end)
on("Pompeii", "scry 2. then put an eruption counter on pompeii", function(it, seat)
  run(it, seat, "scry 2.")
  addPC("Pompeii", "eruption", 1)
end)
on("Pompeii", "pompeii deals damage to each creature and each player equal to the number of eruption counters", function(it, seat)
  local n = pc("Pompeii")
  if n > 0 then
    for _, e in ipairs(field(function(o) return isCreature(o) end)) do
      damage(e.obj, n, it.name, seat)
    end
    for _, c in ipairs(players()) do
      life(c, -n, it.name)
    end
    say(it.name, n .. " damage to each creature and each player.")
  end
  each(fromSeat(seat), function(c, nxt)
    sacOne(it, c, "a land", function(o) return types(o).land end, function() nxt() end)
  end)
end)

-- Prime Minister's Cabinet Room
on("Prime Minister's Cabinet Room", "up to one target creature you control becomes a copy of target creature", function(it, seat)
  pick(seat, it, "your creature", "Click TARGET on a creature you control, or SKIP.", function(obj, owner)
    return owner == seat and isCreature(obj)
  end, function(a)
    if not a then
      return
    end
    pick(seat, it, "creature to copy", "Click TARGET on a creature an opponent controls.", function(obj, owner)
      return TableSetup.isOpponent(owner, seat) and isCreature(obj)
    end, function(b)
      if not b or a.isDestroyed() then
        return
      end
      -- The table's clone swap: a token copy of b takes a's place; a waits aside and comes back to wherever the
      -- copy goes (effects.lua cloneLeft).
      local pos, rot = a.getPosition(), a.getRotation()
      local c = b.clone({ position = { x = pos.x, y = pos.y + 0.6, z = pos.z } })
      if c == nil then
        say(it.name, "couldn't copy " .. b.getName() .. ": make the copy yourself.", WARN)
        return
      end
      c.addTag("Token")
      c.memo = ""
      c.setRotation({ 0, rot.y, 0 })
      pcall(Zones.inherit, a, c)
      GameState.data.clones = GameState.data.clones or {}
      GameState.data.clones[c.getGUID()] = { real = a.getGUID(), seat = seat, name = a.getName() }
      a.setPosition(TableSetup.slot(seat, "act_tokens", TableSetup.SURFACE_TOP + 1.5))
      Wait.time(function()
        if not c.isDestroyed() then
          pcall(Counters.setup, c)
          pcall(Counters.render, c)
        end
      end, 1.5)
      say(it.name, a.getName() .. " becomes a copy of " .. b.getName() .. " (the real card waits beside the table and returns to"
        .. " wherever the copy goes).")
    end)
  end)
end)
on("Prime Minister's Cabinet Room", "each player votes for a creature you don't control", function(it, seat)
  local votes, objs = {}, {}
  each(fromSeat(seat), function(c, nxt)
    pick(c, it, "vote", c .. ": click VOTE on a creature " .. seat .. " doesn't control.", function(obj, owner)
      return owner ~= seat and isCreature(obj)
    end, function(obj)
      if obj then
        local g = obj.getGUID()
        votes[g] = (votes[g] or 0) + 1
        objs[g] = obj
        say(it.name, c .. " votes for " .. obj.getName() .. ".", INFO)
      end
      nxt()
    end, "SKIP", "VOTE")
  end, function()
    local most = 0
    for _, v in pairs(votes) do
      most = math.max(most, v)
    end
    for g, v in pairs(votes) do
      if v == most and most > 0 and objs[g] and not objs[g].isDestroyed() then
        say(it.name, objs[g].getName() .. " is exiled (" .. v .. " vote" .. (v == 1 and "" or "s") .. ").")
        Combat.removeCard(objs[g], "exile")
      end
    end
  end)
end)

-- Singing Towers of Darillium
on("Singing Towers of Darillium", "you may cast a foretold card you own from exile without paying its mana cost this turn", function(it, seat)
  say(it.name, seat .. " may cast a foretold card from exile this turn without paying its mana cost.", CYAN)
end)

-- Stormcage Containment Facility
on("Stormcage Containment Facility", "detain target creature an opponent controls", function(it, seat)
  pick(seat, it, "detain", "Click TARGET on a creature an opponent controls: until your next turn it can't attack, block or use"
    .. " abilities.", function(obj, owner) return isCreature(obj) and TableSetup.isOpponent(owner, seat) end, function(obj)
      if obj then
        local s = st()
        s.detained = s.detained or {}
        s.detained[obj.getGUID()] = { seat = seat, turn = turnNo() }
        say(it.name, obj.getName() .. " is detained until " .. seat .. "'s next turn.")
      end
    end)
end)

-- TARDIS Bay
on("TARDIS Bay", "gain control of target artifact", function(it, seat)
  pick(seat, it, "gain control", "Click TARGET on an artifact.", function(obj) return types(obj).artifact end, function(obj)
    if obj then
      Effects.moveToSeat(obj, seat)
      say(it.name, seat .. " gains control of " .. obj.getName() .. ".")
    end
  end)
end)

-- Temple of Atropos
on("Temple of Atropos", "there is an additional beginning phase after this phase", function(it, seat)
  local s = st()
  s.extraBeginning = turnNo()
  say(it.name, "after this main phase there's an additional beginning phase: " .. seat .. " untaps, has an upkeep and draws"
    .. " again before combat (click NEXT STEP through it).", CYAN)
end)
on("Temple of Atropos", "reverse the game's turn order", function(it, seat)
  Turns.reverse(seat)
end)

-- The Cheetah Planet
on("The Cheetah Planet", "put two +1/+1 counters on target non-cat creature you control", function(it, seat)
  pick(seat, it, "two +1/+1 counters", "Click TARGET on a non-Cat creature you control (it becomes a Cat).", function(obj, owner)
    return owner == seat and isCreature(obj) and not typeLine(obj):find("cat", 1, true)
  end, function(obj)
    if obj then
      plus(obj, 2, seat)
      local s = st()
      s.cats = s.cats or {}
      s.cats[obj.getGUID()] = true
    end
  end)
end)
on("The Cheetah Planet", "all cats gain provoke until end of turn", function(it, seat)
  local s = st()
  for _, e in ipairs(field(function(o) return isCreature(o) and (typeLine(o):find("cat", 1, true) or (s.cats or {})[o.getGUID()]) end)) do
    boost(seat, e.obj, 0, 0, { "provoke" }, "provoke", it.name)
  end
  say(it.name, "Cats have provoke this turn: when one attacks, untap a creature defending player controls; it blocks it if able.", CYAN)
end)

-- The Doctor's Childhood Barn
on("The Doctor's Childhood Barn", "for each opponent, choose up to one target nonland permanent that opponent controls", function(it, seat)
  each(opps(seat), function(c, nxt)
    pick(seat, it, "phase out (" .. c .. ")", "Click TARGET on a nonland permanent " .. c .. " controls, or SKIP.", function(obj, owner)
      return owner == c and not types(obj).land
    end, function(obj)
      if obj then
        Effects.untapObj(obj)
        Wait.time(function() phaseOut(obj) end, 0.8)
        say(it.name, obj.getName() .. " untaps and phases out until a player planeswalks (greyed out: it's treated as though"
          .. " it doesn't exist).")
      end
      nxt()
    end)
  end)
end)

-- The Doctor's Tomb
on("The Doctor's Tomb", "redistribute any number of players' life totals", function(it, seat)
  local ch = {}
  for _, c in ipairs(players()) do
    table.insert(ch, { label = string.upper(c) .. " " .. (GameState.player(c).life or 0), value = c })
  end
  table.insert(ch, { label = "DONE", value = false })
  local chosen = {}
  local function more()
    choose(seat, it.name .. ": which players?", "Pick the players whose life totals get shuffled among them; DONE when finished.", ch,
      function(c)
        if c then
          table.insert(chosen, c)
          more()
          return
        end
        if #chosen < 2 then
          return
        end
        local totals = {}
        for _, x in ipairs(chosen) do
          table.insert(totals, GameState.player(x).life or 0)
        end
        local k = 0
        each(chosen, function(x, nxt)
          local tch = {}
          for i, v in ipairs(totals) do
            if v ~= false then
              table.insert(tch, { label = tostring(v), value = i })
            end
          end
          choose(seat, it.name .. ": " .. x .. "'s new life", "Pick the life total " .. x .. " gets.", tch, function(i)
            i = i or tch[1].value
            local v = totals[i]
            totals[i] = false
            life(x, v - (GameState.player(x).life or 0), it.name)
            nxt()
          end)
        end)
      end)
  end
  more()
end)

-- The Drum, Mining Facility
on("The Drum, Mining Facility", "end the turn", function(it, seat)
  if Stack and Stack.size then
    local guard = 0
    while Stack.size() > 0 and guard < 60 do
      guard = guard + 1
      pcall(Stack.removeRow, 1, seat)
    end
  end
  say(it.name, "the turn ends: the stack is cleared and play moves to the end of turn.", CYAN)
  Wait.time(function()
    if Turns and Turns.endTurn then
      pcall(Turns.endTurn, (Turns.activeTeam and Turns.activeTeam()[1]) or seat)
    end
  end, 1)
end)
on("The Dining Car", "activated abilities of artifact tokens you control cost {2} less", function(it, seat)
  say(it.name, seat .. "'s artifact tokens' activated abilities cost {2} less this turn.", CYAN)
end)
on("The Dining Car", "sacrifice a creature with the least toughness among creatures you control. then investigate", function(it, seat)
  local least
  for _, e in ipairs(field(function(o, s) return s == seat and isCreature(o) end)) do
    local t = toughOf(e.obj)
    if least == nil or t < least then
      least = t
    end
  end
  local function clue()
    makeTokens(seat, "a Clue token", 1, it.name)
  end
  if least == nil then
    clue()
    return
  end
  sacOne(it, seat, "a creature with toughness " .. least, function(o) return isCreature(o) and toughOf(o) == least end, clue)
end)

-- The Moonbase
on("The Moonbase", "for each opponent, choose up to one target creature card in that player's graveyard", function(it, seat)
  each(opps(seat), function(c, nxt)
    local list = {}
    for _, e in ipairs(Effects.graveyardCards(c)) do
      if tostring(e.typeLine):lower():find("creature", 1, true) then
        table.insert(list, e)
      end
    end
    if #list == 0 then
      nxt()
      return
    end
    local ch = {}
    for i = 1, math.min(#list, 8) do
      table.insert(ch, { label = list[i].name:sub(1, 18), value = i })
    end
    table.insert(ch, { label = "NONE", value = false })
    choose(seat, it.name .. ": " .. c .. "'s graveyard", "Pick a creature card: it enters face down under your control as a 2/2"
      .. " Cyberman artifact creature.", ch, function(i)
        if i then
          takeFrom(c, "graveyard", { list[i].guid }, "battlefield", function(card)
            toBattlefield(card, seat, false, true)
          end)
        end
        nxt()
      end)
  end)
end)

-- Two Streams Facility
local function chooseStreams(it, seat, flip)
  local s = st()
  s.streams = s.streams or {}
  if flip then
    for c, v in pairs(s.streams) do
      s.streams[c] = (v == "anchor") and "waterfall" or "anchor"
    end
    for c, v in pairs(s.streams) do
      say(it.name, c .. " now has " .. (v == "anchor" and "GREEN ANCHOR" or "RED WATERFALL") .. ".", INFO)
    end
    if Statics and Statics.soon then
      Statics.soon()
    end
    return
  end
  each(fromSeat(seat), function(c, nxt)
    choose(c, it.name .. ": choose", c .. ": GREEN ANCHOR (an additional land each turn) or RED WATERFALL (your creatures get"
      .. " +2/+0 and haste)?", { { label = "GREEN ANCHOR", value = "anchor" }, { label = "RED WATERFALL", value = "waterfall" } },
      function(v)
        s.streams[c] = v or "anchor"
        nxt()
      end)
  end, function()
    if Statics and Statics.soon then
      Statics.soon()
    end
  end)
end
on("Two Streams Facility", "each player chooses green anchor or red waterfall", function(it, seat) chooseStreams(it, seat, false) end)
on("Two Streams Facility", "each player who last chose green anchor chooses red waterfall", function(it, seat) chooseStreams(it, seat, true) end)

-- The Matrix of Time
on("The Matrix of Time", "each player exiles the top card of their library", function(it, seat)
  local s = st()
  s.matrix = s.matrix or {}
  for _, c in ipairs(players()) do
    Library.revealTop(c, function(card)
      if card then
        card.setPosition(TableSetup.slot(c, "exile", TableSetup.SURFACE_TOP + 2))
        Wait.time(function() if not card.isDestroyed() then Zones.refresh(card) end end, 0.5)
        s.matrix[card.getGUID()] = c
        say(it.name, c .. " exiles " .. card.getName() .. " (the active player may play it).", INFO)
      end
    end)
  end
end)
on("The Matrix of Time", "that card's owner loses 3 life and exiles the top card of their library", function(it, seat)
  local owner = it.owner or it.that or seat
  life(owner, -3, it.name)
  Library.revealTop(owner, function(card)
    if card then
      card.setPosition(TableSetup.slot(owner, "exile", TableSetup.SURFACE_TOP + 2))
      Wait.time(function() if not card.isDestroyed() then Zones.refresh(card) end end, 0.5)
      st().matrix = st().matrix or {}
      st().matrix[card.getGUID()] = owner
    end
  end)
end)

-- Upkeep / combat / end step lines read wrongly by the general reader
on("Hedron Fields of Agadeem", "create a 7/7 colorless eldrazi creature token with annihilator 1", function(it, seat)
  makeTokens(seat, "a 7/7 colorless Eldrazi creature token with annihilator 1", 1, it.name)
end)
on("Kessig", "each creature you control gets +2/+2, gains trample, and becomes a werewolf", function(it, seat)
  local s = st()
  s.werewolf = s.werewolf or {}
  for _, e in ipairs(field(function(o, se) return se == seat and isCreature(o) end)) do
    boost(seat, e.obj, 2, 2, { "trample" }, "+2/+2, trample, Werewolf", it.name)
    s.werewolf[e.obj.getGUID()] = turnNo()
  end
end)

---------------------------------------------------------------------------
-- Matching (Stack.pushAbility / Effects.resolve hooks)
---------------------------------------------------------------------------

local function findFx(name, text)
  local low = tostring(text or ""):lower()
  for i, e in ipairs(FX) do
    if e.plane == name and low:find(e.has, 1, true) then
      return i, e
    end
  end
  return nil
end

function PlaneFx.adjust(sourceName, text, opts)
  opts = opts or {}
  if opts.copyOf or opts.planeFx or opts.ward then
    return text, opts
  end
  local i, e = findFx(sourceName, text)
  if e == nil then
    return text, opts
  end
  if e.text then
    return e.text, opts
  end
  opts.planeFx = i
  return text, opts
end

function PlaneFx.run(it)
  local e = it.planeFx and FX[it.planeFx]
  if e == nil or e.fn == nil then
    return false
  end
  local ok, err = pcall(e.fn, it, it.controller)
  if not ok and Events and Events.noteError then
    Events.noteError("resolving " .. tostring(it.name), err)
  end
  return true
end

---------------------------------------------------------------------------
-- Watching: plane abilities the trigger reader doesn't watch for
---------------------------------------------------------------------------

-- Lines watched here (left out of the trigger reader so they don't trigger twice): plane name -> text pieces.
local WATCHED = {
  ["Agyrem"] = { "whenever a white creature dies", "whenever a nonwhite creature dies" },
  ["Aretopolis"] = { "when aretopolis has ten or more scroll counters" },
  ["Eloren Wilds"] = { "whenever a player taps a permanent for mana" },
  ["Fields of Summer"] = { "whenever a player casts a spell" },
  ["Glimmervoid Basin"] = { "whenever a player casts an instant or sorcery spell with a single target" },
  ["Izzet Steam Maze"] = { "whenever a player casts an instant or sorcery spell" },
  ["Jund"] = { "whenever a player casts a creature spell" },
  ["Minamo"] = { "whenever a player casts a spell" },
  ["Mirrored Depths"] = { "whenever a player casts a spell" },
  ["Sea of Sand"] = { "whenever a player draws", "players reveal each card they draw" },
  ["Stensia"] = { "whenever a creature deals damage to one or more players" },
  ["Takenuma"] = { "whenever a creature leaves the battlefield" },
  ["Tember City"] = { "whenever a player taps a land for mana" },
  ["The Dark Barony"] = { "whenever a nonblack card is put into a player's graveyard" },
  ["Undercity Reaches"] = { "whenever a creature deals combat damage to a player" },
  ["New Argive"] = { "whenever a historic creature you control attacks" },
  ["The Fertile Lands of Saulvinia"] = { "whenever a player taps a land for mana" },
  ["Paliano"] = { "when one or more creatures you control deal combat damage to a player" },
  ["Valor's Reach"] = { "whenever your team attacks with exactly two creatures" },
  ["Coal Hill School"] = { "whenever a player casts a historic spell" },
  ["Mondassian Colony Ship"] = { "whenever a creature attacks" },
  ["City of the Daleks"] = { "whenever you attack" },
  ["Gardens of Tranquil Repose"] = { "whenever a creature dies" },
  ["The Matrix of Time"] = { "whenever you play a land or cast a spell from among cards exiled" },
  ["Immersturm"] = { "whenever a creature enters" },
  ["Isle of Vesuva"] = { "whenever a nontoken creature enters" },
  ["Goldmeadow"] = { "whenever a land enters" },
  ["Murasa"] = { "whenever a nontoken creature enters" },
  ["Grand Ossuary"] = { "whenever a creature dies" },
}

function PlaneFx.handlesLine(planeName, low)
  for _, piece in ipairs(WATCHED[planeName] or {}) do
    if low:find(piece, 1, true) then
      return true
    end
  end
  return false
end

-- The planes face up now, by name.
local upCache = { at = -100, map = {} }
local function planesUp()
  local now = (Time and Time.time) or os.time()
  if now - upCache.at < 0.5 then
    return upCache.map
  end
  local out = {}
  if Planechase and Planechase.allPlanes then
    local ok, list = pcall(Planechase.allPlanes)
    for _, p in ipairs(ok and list or {}) do
      out[p.getName()] = p
    end
  end
  upCache.at, upCache.map = now, out
  return out
end

local function planarSeat()
  local t = GameState.data.turn or {}
  return t.activeSeat
end

-- Put a plane's ability on the stack: text as printed (after the trigger), that = the player it's about.
local function fire(plane, text, opts)
  local seat = planarSeat()
  if seat == nil or not GameState.data.started then
    return
  end
  opts = opts or {}
  opts.trigger = true
  Stack.pushAbility(seat, plane, text, nil, opts)
end

-- The text after the trigger's comma, for the plane's line containing `piece`.
local function lineAfter(plane, piece)
  local okE, e = pcall(function() return PLANECHASE_CARDS end)
  for _, c in ipairs(okE and e or {}) do
    if c.n == plane then
      for l in tostring(c.o):gmatch("[^\n]+") do
        local low = l:lower()
        if low:find(piece, 1, true) then
          local comma = l:find(",", 1, true)
          return comma and l:sub(comma + 1):gsub("^%s+", "") or l
        end
      end
    end
  end
  return nil
end

local function fireLine(plane, piece, opts)
  local text = lineAfter(plane, piece)
  if text then
    fire(plane, text, opts)
  end
end

-- Spells cast.
Events.on("spellCast", function(d)
  if d == nil or d.card == nil or d.controller == nil or not GameState.data.started then
    return
  end
  local up = planesUp()
  if next(up) == nil then
    return
  end
  local who = d.controller
  local g = d.card.getGUID()
  local tl = typeLine(d.card)
  local isIS = tl:find("instant", 1, true) or tl:find("sorcery", 1, true)
  local opts = function() return { that = who, thatCard = g } end
  if whileWalk("noCast:" .. who) then
    broadcastToAll("Eloren Wilds: " .. who .. " can't cast spells until a player planeswalks - take " .. d.card.getName() .. " back.", WARN)
  end
  if up["Fields of Summer"] then
    fireLine("Fields of Summer", "whenever a player casts a spell", opts())
  end
  if up["Minamo"] then
    fireLine("Minamo", "whenever a player casts a spell", opts())
  end
  if up["Mirrored Depths"] then
    fireLine("Mirrored Depths", "whenever a player casts a spell", opts())
  end
  if up["Izzet Steam Maze"] and isIS then
    fireLine("Izzet Steam Maze", "whenever a player casts an instant or sorcery spell", opts())
  end
  if up["Glimmervoid Basin"] and isIS then
    fireLine("Glimmervoid Basin", "whenever a player casts an instant or sorcery spell with a single target", opts())
  end
  if up["Jund"] and tl:find("creature", 1, true) then
    local c = colorsOf(d.card)
    if c.B or c.R or c.G then
      fireLine("Jund", "whenever a player casts a creature spell", opts())
    end
  end
  if up["Coal Hill School"] and (tl:find("legendary", 1, true) or tl:find("artifact", 1, true) or tl:find("saga", 1, true)) then
    fireLine("Coal Hill School", "whenever a player casts a historic spell", opts())
  end
  if up["The Matrix of Time"] and (st().matrix or {})[g] and isActive(who) then
    fireLine("The Matrix of Time", "whenever you play a land or cast a spell", { owner = st().matrix[g], that = st().matrix[g] })
    st().matrix[g] = nil
  end
end)

-- Cards moving: draws, deaths, leaving the battlefield, graveyards, enters.
local ON_FIELD = { battlefield = true, lands = true }
Events.on("cardMoved", function(d)
  if d == nil or d.card == nil or d.from == nil or d.to == nil or not GameState.data.started or d.pileExtra then
    return
  end
  local up = planesUp()
  if next(up) == nil then
    return
  end
  local card = d.card
  local okD, destroyed = pcall(function() return card.isDestroyed() end)
  local g = okD and not destroyed and card.getGUID() or nil
  local tl = g and typeLine(card) or ""
  -- Drawn (library -> hand, not a search).
  if d.from.region == "library" and d.to.region == "hand" and d.to.seat and g then
    local sg = GameState.data.searched
    if not (sg and sg[g]) and up["Sea of Sand"] then
      printToAll("MTG > Sea of Sand: " .. d.to.seat .. " draws " .. card.getName() .. " (revealed).", INFO)
      if tl:find("land", 1, true) then
        fireLine("Sea of Sand", "whenever a player draws a land card", { that = d.to.seat })
      else
        fireLine("Sea of Sand", "whenever a player draws a nonland card", { that = d.to.seat })
      end
    end
    return
  end
  local leaving = ON_FIELD[d.from.region] and not ON_FIELD[d.to.region]
  local entering = ON_FIELD[d.to.region] and not ON_FIELD[d.from.region]
  local creature = tl:find("creature", 1, true) ~= nil
  if leaving and creature then
    if up["Takenuma"] then
      fireLine("Takenuma", "whenever a creature leaves the battlefield", { that = d.from.seat, thatCard = g })
    end
    if d.to.region == "graveyard" then
      local white = g and colorsOf(card).W
      if up["Agyrem"] then
        if white then
          fireLine("Agyrem", "whenever a white creature dies", { that = d.to.seat, thatCard = g })
        else
          fireLine("Agyrem", "whenever a nonwhite creature dies", { that = d.to.seat, thatCard = g })
        end
      end
      if up["Gardens of Tranquil Repose"] then
        fireLine("Gardens of Tranquil Repose", "whenever a creature dies", { that = d.from.seat, thatCard = g, owner = d.to.seat })
      end
      if up["Grand Ossuary"] then
        fireLine("Grand Ossuary", "whenever a creature dies", { that = d.from.seat, thatCard = g })
      end
    end
  end
  if d.to.region == "graveyard" then
    if up["The Dark Barony"] and g and not colorsOf(card).B and not card.hasTag("Token") then
      fireLine("The Dark Barony", "whenever a nonblack card is put into a player's graveyard", { that = d.to.seat })
    end
  end
  if entering and g then
    if creature and up["Immersturm"] then
      fireLine("Immersturm", "whenever a creature enters", { that = d.to.seat, thatCard = g })
    end
    if creature and not card.hasTag("Token") then
      if up["Isle of Vesuva"] then
        fireLine("Isle of Vesuva", "whenever a nontoken creature enters", { that = d.to.seat, thatCard = g })
      end
      if up["Murasa"] then
        fireLine("Murasa", "whenever a nontoken creature enters", { that = d.to.seat, thatCard = g })
      end
    end
    if tl:find("land", 1, true) and up["Goldmeadow"] then
      fireLine("Goldmeadow", "whenever a land enters", { that = d.to.seat, thatCard = g })
    end
    -- Bad Wolf Bay: nothing enters from exile this turn.
    if d.from.region == "exile" and st().noExileEnter == turnNo() then
      broadcastToAll("Bad Wolf Bay: cards can't enter the battlefield from exile this turn - put " .. card.getName() .. " back.", WARN)
    end
    -- The Matrix of Time: a land played from among its exiled cards.
    if up["The Matrix of Time"] and (st().matrix or {})[g] and tl:find("land", 1, true) then
      fireLine("The Matrix of Time", "whenever you play a land or cast a spell", { owner = st().matrix[g], that = st().matrix[g] })
      st().matrix[g] = nil
    end
  end
end)

-- Attacks, damage: wrap the trigger reader's own hooks (combat.lua calls them).
do
  local origAttack = Triggers.onAttack
  Triggers.onAttack = function(list)
    local r = origAttack(list)
    pcall(function()
      local s = st()
      s.attackedThisTurn = s.attackedThisTurn or {}
      s.attackedSeat = s.attackedSeat or {}
      for _, a in ipairs(list or {}) do
        if a.obj then
          s.attackedThisTurn[a.obj.getGUID()] = turnNo()
        end
        if a.controller then
          s.attackedSeat[a.controller] = turnNo()
        end
      end
      local up = planesUp()
      if next(up) == nil then
        return
      end
      local ps = planarSeat()
      local byTeam = {}
      for _, a in ipairs(list or {}) do
        if a.obj then
          local tl = typeLine(a.obj)
          if up["New Argive"] and a.controller == ps and (tl:find("legendary", 1, true) or tl:find("artifact", 1, true)
              or tl:find("saga", 1, true)) then
            fireLine("New Argive", "whenever a historic creature you control attacks", { thatCard = a.obj.getGUID() })
          end
          if up["Mondassian Colony Ship"] then
            fireLine("Mondassian Colony Ship", "whenever a creature attacks", { thatCard = a.obj.getGUID(), that = a.controller })
          end
          if not TableSetup.isOpponent(a.controller, ps) then
            table.insert(byTeam, a.obj.getGUID())
          end
        end
      end
      if up["City of the Daleks"] and #byTeam > 0 then
        fireLine("City of the Daleks", "whenever you attack", {})
      end
      if up["Valor's Reach"] and #byTeam == 2 then
        local opts = { cards = byTeam }
        fireLine("Valor's Reach", "whenever your team attacks with exactly two creatures", opts)
      end
    end)
    return r
  end

  local origCD = Triggers.onCombatDamage
  Triggers.onCombatDamage = function(list)
    local r = origCD(list)
    pcall(function()
      local up = planesUp()
      if next(up) == nil then
        return
      end
      local ps = planarSeat()
      local hitBy = {}
      for _, e in ipairs(list or {}) do
        if e.seat and e.obj and (e.amount or 0) > 0 then
          if up["Undercity Reaches"] then
            fireLine("Undercity Reaches", "whenever a creature deals combat damage to a player", { that = e.controller,
              thatCard = e.obj.getGUID() })
          end
          if e.controller == ps then
            hitBy[e.seat] = true
          end
        end
      end
      if up["Paliano"] and next(hitBy) then
        fireLine("Paliano", "when one or more creatures you control deal combat damage to a player", {})
      end
    end)
    return r
  end

  local origDmg = Triggers.onDamage
  Triggers.onDamage = function(list, combat)
    local r = origDmg(list, combat)
    pcall(function()
      local up = planesUp()
      if not up["Stensia"] then
        return
      end
      local s = st()
      s.stensia = s.stensia or {}
      for _, e in ipairs(list or {}) do
        if e.seat and e.obj and (e.amount or 0) > 0 then
          local g = e.obj.getGUID()
          if s.stensia[g] ~= turnNo() then
            s.stensia[g] = turnNo()
            fireLine("Stensia", "whenever a creature deals damage to one or more players", { thatCard = g })
          end
        end
      end
    end)
    return r
  end
end

-- Mana: Eloren Wilds, The Fertile Lands of Saulvinia, Selesnya Loft Gardens (one more mana of a type made),
-- Tember City (1 damage).
if ManaChips and ManaChips.onTap then
  local KEYS = { "W", "U", "B", "R", "G", "C" }
  local origTap = ManaChips.onTap
  ManaChips.onTap = function(obj, seat)
    local before = {}
    for _, k in ipairs(KEYS) do
      before[k] = ManaChips.get(seat, k) or 0
    end
    local r = origTap(obj, seat)
    pcall(function()
      local up = planesUp()
      if next(up) == nil or not GameState.data.started then
        return
      end
      local isLand = types(obj).land
      local loft = st().loftMana
      local extra = up["Eloren Wilds"] or (isLand and up["The Fertile Lands of Saulvinia"])
        or (isLand and loft and loft.seat == seat and loft.turn == turnNo())
      if extra then
        Wait.time(function()
          local made = {}
          for _, k in ipairs(KEYS) do
            if (ManaChips.get(seat, k) or 0) > before[k] then
              table.insert(made, k)
            end
          end
          if #made == 1 then
            ManaChips.add(seat, made[1], 1)
            printToAll("MTG > " .. seat .. " adds one more {" .. made[1] .. "} (plane).", GOOD)
          elseif #made > 1 then
            local ch = {}
            for _, k in ipairs(made) do
              table.insert(ch, { label = k, value = k })
            end
            Effects.askChoice(seat, "One more mana", "The plane adds one more mana of a type that permanent made.", ch, function(k)
              if k then
                ManaChips.add(seat, k, 1)
              end
            end)
          end
        end, 1.2)
      end
      if isLand and up["Tember City"] then
        fireLine("Tember City", "whenever a player taps a land for mana", { that = seat })
      end
    end)
    return r
  end
end

---------------------------------------------------------------------------
-- Steps: delayed things (Agyrem's returns, The Pit's Demons, the Daleks...)
---------------------------------------------------------------------------

Events.on("stepStarted", function(d)
  if not GameState.data.started or d == nil then
    return
  end
  local s = st()
  if d.step == "end" then
    -- Agyrem: back from the graveyard.
    local list = s.agyrem or {}
    s.agyrem = {}
    for _, r in ipairs(list) do
      local owner = r.owner
      local pile = owner and Library.pileIn(owner, "graveyard")
      if pile and r.guid then
        takeFrom(owner, "graveyard", { r.guid }, "battlefield", function(card)
          if r.dest == "hand" then
            toHand(card, owner)
          else
            toBattlefield(card, owner, false)
          end
          printToAll("MTG > Agyrem: " .. card.getName() .. " returns " .. (r.dest == "hand" and "to its owner's hand." or "to the battlefield."), GOOD)
        end)
      end
    end
    -- City of the Daleks: its attacking Daleks are sacrificed.
    local sac = s.sacAtEnd or {}
    s.sacAtEnd = {}
    for _, g in ipairs(sac) do
      local o = getObjectFromGUID(g)
      if o and Effects.fieldSeat(o) then
        sacrifice(o)
      end
    end
  end
  -- Reminders for the rules the table doesn't change itself.
  local up = planesUp()
  if d.step == "damage" then
    if up["Kessig"] then
      printToAll("MTG > Kessig: only Werewolves deal combat damage (all other combat damage is prevented): adjust by hand.", CYAN)
    end
    if up["The Great Forest"] then
      printToAll("MTG > The Great Forest: each creature deals combat damage equal to its TOUGHNESS: adjust by hand.", CYAN)
    end
  end
  if d.step == "upkeep" and (up["Skybreen"] or up["Windriddle Palaces"]) then
    local tops = {}
    for _, c in ipairs(players()) do
      local top = Library.peek(c, 0)
      table.insert(tops, c .. ": " .. tostring(top and top.name or "(empty)"))
    end
    printToAll("MTG > " .. (up["Skybreen"] and "Skybreen" or "Windriddle Palaces") .. ": the top cards of the libraries are revealed - "
      .. table.concat(tops, ", ") .. ".", CYAN)
  end
  if d.step == "upkeep" and d.seat then
    -- The Pit's Demons: "At the beginning of your upkeep, sacrifice another creature. If you can't, this deals 6 damage to you."
    for _, e in ipairs(field(function(o, se) return se == d.seat and o.hasTag("Token") and o.getName():lower():find("demon", 1, true) end)) do
      if (s.pitDemons or {})[d.seat] then
        local demon = e.obj
        local it = { name = "Demon (The Pit)", guid = demon.getGUID() }
        if countOf(d.seat, function(o) return isCreature(o) and o ~= demon end) == 0 then
          life(d.seat, -6, "The Pit's Demon")
          printToAll("MTG > The Pit's Demon deals 6 damage to " .. d.seat .. " (no other creature to sacrifice).", WARN)
        else
          sacOne(it, d.seat, "another creature", function(o) return isCreature(o) and o ~= demon end)
        end
      end
    end
    -- Detain / Ood Sphere / Stormcage end at their controller's next turn.
    for _, key in ipairs({ "detained", "noTap" }) do
      for g, r in pairs(s[key] or {}) do
        if r.seat == d.seat and r.turn < turnNo() then
          s[key][g] = nil
        end
      end
    end
  end
end)


---------------------------------------------------------------------------
-- Rules hooks: who can attack / block / cast / lose, untapping, damage
---------------------------------------------------------------------------

-- Lake Silencio: every spell has split second.
if Stack and Stack.splitSecond then
  local origSS = Stack.splitSecond
  Stack.splitSecond = function()
    local r = origSS()
    if r then
      return r
    end
    local up = planesUp()
    if up["Lake Silencio"] then
      for _, e in ipairs(Stack.entries()) do
        if e.kind == "card" then
          return e.name .. " (Lake Silencio: all spells have split second)"
        end
      end
    end
    return nil
  end
end

local function combatCount(key)
  local c = GameState.data.combat
  local n = 0
  for _ in pairs(c and c[key] or {}) do
    n = n + 1
  end
  return n
end

if Statics then
  local origCantAttack = Statics.cantAttack
  Statics.cantAttack = function(card)
    local s = st()
    local g = card and card.getGUID()
    if PlaneFx.isPhased(card) then
      return "phased out"
    end
    if g and (s.detained or {})[g] then
      return "detained (Stormcage Containment Facility)"
    end
    local up = planesUp()
    if up["Astral Arena"] and combatCount("attackers") > 1 then
      return "Astral Arena: no more than one creature can attack each combat"
    end
    -- Prahv: no attacking after casting a spell this turn.
    if up["Prahv"] then
      local seat = Effects.fieldSeat(card)
      local cast = seat and Effects.spellsThisTurn and Effects.spellsThisTurn(seat) or 0
      if (tonumber(cast) or 0) > 0 then
        return "Prahv (" .. seat .. " cast a spell this turn)"
      end
    end
    return origCantAttack(card)
  end
  local origCantBlock = Statics.cantBlock
  Statics.cantBlock = function(blocker, attacker)
    local s = st()
    if PlaneFx.isPhased(blocker) then
      return blocker.getName() .. " is phased out"
    end
    if attacker and PlaneFx.isPhased(attacker) then
      return attacker.getName() .. " is phased out"
    end
    if blocker and (s.detained or {})[blocker.getGUID()] then
      return blocker.getName() .. " is detained (Stormcage Containment Facility)"
    end
    if planesUp()["Astral Arena"] and combatCount("blocks") >= 1 then
      return "Astral Arena: no more than one creature can block each combat"
    end
    if attacker then
      local ub = (s.unblockable or {})[attacker.getGUID()]
      if ub and ub == turnNo() then
        return attacker.getName() .. " can't be blocked this turn (Orochi Colony)"
      end
      -- Islandwalk (Bowie Base One): unblockable while the defender controls an Island.
      if Effects.hasKeyword and Effects.hasKeyword(attacker, "islandwalk") then
        local def = Effects.fieldSeat(blocker)
        if def and countOf(def, function(o) return typeLine(o):find("island", 1, true) end) > 0 then
          return attacker.getName() .. " has islandwalk and " .. def .. " controls an Island"
        end
      end
    end
    return origCantBlock(blocker, attacker)
  end
  local origCantCast = Statics.cantCast
  Statics.cantCast = function(card, caster)
    if whileWalk("noCast:" .. tostring(caster)) then
      return "Eloren Wilds"
    end
    local up = planesUp()
    if up["Prahv"] then
      local at = st().attackedSeat or {}
      if at[caster] == turnNo() then
        return "Prahv: " .. caster .. " attacked this turn"
      end
    end
    -- Skybreen: spells sharing a card type with the top card of a library.
    if up["Skybreen"] then
      local tl = typeLine(card)
      for _, c in ipairs(players()) do
        local held = Library.revealedCard and Library.revealedCard(c)
        local top = held and { name = held.getName() } or Library.peek(c, 0)
        if top and top.name then
          for _, w in ipairs({ "creature", "artifact", "enchantment", "instant", "sorcery", "planeswalker", "battle", "land" }) do
            local lib = Library.find(c)
            local ttl = ""
            pcall(function()
              if held then
                ttl = typeLine(held)
                return
              end
              local dd = lib.type == "Deck" and lib.getObjects()[1] or nil
              ttl = dd and tostring(JSON.decode(dd.gm_notes or "{}").typeLine or ""):lower() or typeLine(lib)
            end)
            if tl:find(w, 1, true) and ttl:find(w, 1, true) then
              return "Skybreen (" .. top.name .. " on top of " .. c .. "'s library is also " .. w .. ")"
            end
          end
        end
      end
    end
    return origCantCast(card, caster)
  end
end

-- Celestine Reef: can't lose until a player planeswalks.
if Trackers and Trackers.confirmLoss then
  local origLoss = Trackers.confirmLoss
  Trackers.confirmLoss = function(color, byColor)
    if whileWalk("cantLose:" .. tostring(color)) then
      local p = GameState.player(color)
      if p then
        p.lossFlag, p.lossForced = nil, nil
      end
      broadcastToAll("Celestine Reef: " .. color .. " can't lose the game until a player planeswalks.", CYAN)
      return
    end
    return origLoss(color, byColor)
  end
end

-- Edge of Malacol: the planar controller's creatures get two +1/+1 counters instead of untapping.
if Actions and Actions.untapAll then
  local origUntap = Actions.untapAll
  Actions.untapAll = function(color, quiet)
    -- Phased-out permanents don't untap.
    if Actions.setSkipUntap then
      for g in pairs(st().phasedSet or {}) do
        local o = getObjectFromGUID(g)
        if o and not o.isDestroyed() and Zones.regionAt(o.getPosition()).seat == color then
          pcall(Actions.setSkipUntap, o, true, "phased out")
        end
      end
    end
    local up = planesUp()
    if up["Edge of Malacol"] and color == planarSeat() and Actions.setSkipUntap then
      local s = TableSetup.seat(color)
      for _, e in ipairs(field(function(o, se) return se == color and isCreature(o) end)) do
        local r = e.obj.getRotation()
        local diff = ((r.y - s.yaw + 540) % 360) - 180
        if math.abs(diff) > 30 then
          Actions.setSkipUntap(e.obj, true, "Edge of Malacol: two +1/+1 counters instead")
          plus(e.obj, 2, color)
        end
      end
    end
    return origUntap(color, quiet)
  end
end

-- The Western Cloud / Mount Keralia safety / The Doctor's Tomb on damage and dying.
if Effects and Effects.damageCreature then
  local origDC = Effects.damageCreature
  Effects.damageCreature = function(obj, n, src, sourceName, controller)
    local up = planesUp()
    if up["The Western Cloud"] and obj and Effects.fieldSeat(obj) == planarSeat() then
      printToAll("MTG > The Western Cloud: damage to " .. obj.getName() .. " is prevented.", INFO)
      return
    end
    return origDC(obj, n, src, sourceName, controller)
  end
end
if Combat and Combat.removeCard then
  local origRemove = Combat.removeCard
  Combat.removeCard = function(card, zone)
    local up = planesUp()
    if up["The Doctor's Tomb"] and (zone == nil or zone == "graveyard") and card and not card.isDestroyed()
        and Effects.fieldSeat(card) and isCreature(card) then
      local ctl = Effects.fieldSeat(card)
      printToAll("MTG > The Doctor's Tomb: " .. card.getName() .. " is exiled instead, and " .. ctl .. " loses 2 life.", INFO)
      life(ctl, -2, "The Doctor's Tomb")
      return origRemove(card, "exile")
    end
    return origRemove(card, zone)
  end
end

-- Undercity Reaches' "no maximum hand size for the rest of the game".
function PlaneFx.noMaxHand(seat)
  return (st().noMaxHand or {})[seat] == true
end

-- Two Streams Facility: extra land drop for anchor players.
function PlaneFx.extraLands(seat)
  local up = planesUp()
  if up["Two Streams Facility"] and (st().streams or {})[seat] == "anchor" then
    return 1
  end
  return 0
end

-- Two Streams Facility / Velis Vel / Bant's divinity: P/T and keywords (Statics.compute / grants ask).
function PlaneFx.bonus(obj, seat)
  local up = planesUp()
  local p, t = 0, 0
  if up["Two Streams Facility"] and (st().streams or {})[seat] == "waterfall" and isCreature(obj) then
    p = p + 2
  end
  if up["Velis Vel"] and isCreature(obj) then
    local function subs(o)
      local out = {}
      local allT = (st().allTypes or {})[o.getGUID()] == turnNo()
        or tostring(data(o).oracle or ""):lower():find("changeling", 1, true)
      if allT then
        return nil
      end
      local tl = typeLine(o)
      local dash = tl:find("\226\128\148", 1, true)
      if dash then
        for w in tl:sub(dash + 3):gmatch("%a+") do
          out[w] = true
        end
      end
      return out
    end
    local mine = subs(obj)
    local n = 0
    for _, e in ipairs(field(function(o) return isCreature(o) and o ~= obj end)) do
      local theirs = subs(e.obj)
      local share = (mine == nil and (theirs == nil or next(theirs) ~= nil)) or (theirs == nil and mine ~= nil and next(mine) ~= nil)
      if not share and mine and theirs then
        for w in pairs(mine) do
          if theirs[w] then
            share = true
            break
          end
        end
      end
      if share then
        n = n + (Pile and Pile.count(e.obj) or 1)
      end
    end
    p, t = p + n, t + n
  end
  return p, t
end

function PlaneFx.keywords(obj, seat)
  local up = planesUp()
  local out = {}
  if up["Two Streams Facility"] and (st().streams or {})[seat] == "waterfall" and isCreature(obj) then
    table.insert(out, "haste")
  end
  if up["Bant"] and (st().divinity or {})[obj.getGUID()] and (Counters.get(obj).other or 0) > 0 then
    table.insert(out, "indestructible")
  end
  return out
end

-- Remember when a plane arrives (Unyaro's "if you planeswalked to Unyaro this turn").
function PlaneFx.arrived(name)
  local s = st()
  s.arrived = s.arrived or {}
  s.arrived[name] = turnNo()
  if name == "Skybreen" or name == "Windriddle Palaces" then
    Wait.time(function()
      for _, c in ipairs(players()) do
        pcall(function()
          if not (Library.revealedCard and Library.revealedCard(c)) then
            Library.revealTop(c, function(card)
              if card and Library.holdRevealed then
                Library.holdRevealed(c, card)
              end
            end)
          end
        end)
      end
    end, 2)
  end
end


---------------------------------------------------------------------------
-- Devour (Jund): as the creature enters, sacrifice any number of other creatures; five +1/+1 counters for each.
---------------------------------------------------------------------------

Events.on("cardMoved", function(d)
  if d == nil or d.card == nil or d.to == nil or d.pileExtra then
    return
  end
  local s = st()
  local okG, g = pcall(function() return d.card.getGUID() end)
  local n = okG and s.devour and s.devour[g]
  if not n or not ON_FIELD[d.to.region] then
    return
  end
  s.devour[g] = nil
  local card, seat = d.card, d.to.seat
  local eaten = 0
  local it = { name = "Devour " .. n .. " (Jund)", guid = g }
  local function more()
    pick(seat, it, "devour", seat .. ": click SACRIFICE on another creature to devour (" .. eaten .. " so far), or DONE.",
      function(obj, owner) return owner == seat and isCreature(obj) and obj ~= card end, function(obj)
        if obj then
          sacrifice(obj)
          eaten = eaten + 1
          more()
        elseif eaten > 0 then
          plus(card, n * eaten, seat)
          say(it.name, card.getName() .. " devoured " .. eaten .. " creature" .. (eaten == 1 and "" or "s") .. ": "
            .. (n * eaten) .. " +1/+1 counters.")
        end
      end, "DONE", "SACRIFICE")
  end
  Wait.time(more, 1)
end)

---------------------------------------------------------------------------
-- Combat damage (combat.lua asks): The Great Forest (toughness), Kessig (only Werewolves). Agyrem's chaos.
---------------------------------------------------------------------------

function PlaneFx.combatDamage(obj, power, tough)
  local up = planesUp()
  if next(up) == nil then
    return nil
  end
  local p = power
  if up["The Great Forest"] then
    p = tough
  end
  if up["Kessig"] then
    local wolf = typeLine(obj):find("werewolf", 1, true) ~= nil or ((st().werewolf or {})[obj.getGUID()] == turnNo())
      or tostring(data(obj).oracle or ""):lower():find("changeling", 1, true) ~= nil
    if not wolf then
      p = 0
    end
  end
  return p
end

function PlaneFx.cantBeAttacked(seat)
  return whileWalk("noAttack:" .. tostring(seat)) and true or false
end

---------------------------------------------------------------------------
-- Skybreen / Windriddle Palaces: everyone plays with the top card of their library revealed. The top card is
-- held face up beside each library (Library.holdRevealed; drawing takes it first) and the next one is turned up
-- after each draw. When the plane leaves, they go back on top.
---------------------------------------------------------------------------

local function revealsTops()
  local up = planesUp()
  return up["Skybreen"] or up["Windriddle Palaces"]
end

local revealing = {}
local function revealFor(c)
  if revealing[c] or not GameState.data.started then
    return
  end
  if Library.revealedCard and Library.revealedCard(c) then
    return
  end
  revealing[c] = true
  Library.revealTop(c, function(card)
    revealing[c] = nil
    if card and Library.holdRevealed then
      Library.holdRevealed(c, card)
    end
  end)
end

local function revealAll()
  if not revealsTops() then
    return
  end
  for _, c in ipairs(players()) do
    revealFor(c)
  end
end

function PlaneFx.revealTopsOff()
  for _, c in ipairs(players()) do
    if Library.revealedCard and Library.revealedCard(c) then
      pcall(Library.putRevealedOnTop, c)
    end
  end
end

Events.on("cardMoved", function(d)
  if d == nil or d.from == nil or d.to == nil or not GameState.data.started then
    return
  end
  if d.from.region == "library" and d.to.region == "hand" and d.to.seat and revealsTops() then
    local c = d.to.seat
    Wait.time(function() revealFor(c) end, 1.2)
  end
end)

Events.on("stepStarted", function(d)
  if d and (d.step == "upkeep" or d.step == "main1") then
    Wait.time(revealAll, 0.5)
  end
end)

---------------------------------------------------------------------------
-- Buttons on the plane card for what a plane lets players do (each player clicks for themselves):
-- UNEARTH (Grixis), FLASHBACK (Otaria), EMBALM (Naktamun), ESCAPE (Stormcage Containment Facility),
-- SCAVENGE (The Cave of Skulls), BLITZ (The Caldaia), SUSPEND (Talon Gates), FORETELL (Singing Towers of
-- Darillium). Costs are paid by hand, as with every spell.
---------------------------------------------------------------------------

local GRANTS = {
  ["Grixis"] = { { "UNEARTH", "planefx_unearth", "Put a blue, black or red creature card from your graveyard onto the battlefield (pay its mana cost); it has haste and is exiled at the next end step or if it would leave" } },
  ["Otaria"] = { { "FLASHBACK", "planefx_flashback", "Cast an instant or sorcery card from your graveyard (pay its mana cost); it's exiled afterwards" } },
  ["Naktamun"] = { { "EMBALM", "planefx_embalm", "Exile a creature card from your graveyard (pay its mana cost): create a token copy, a white Zombie with no mana cost. Sorcery speed" } },
  ["Stormcage Containment Facility"] = { { "ESCAPE", "planefx_escape", "Cast a creature card from your graveyard (pay its mana cost and exile three other cards from your graveyard)" } },
  ["The Cave of Skulls"] = { { "SCAVENGE", "planefx_scavenge", "Exile a creature card from your graveyard (pay its mana cost): +1/+1 counters equal to its power on target creature. Sorcery speed" } },
  ["The Caldaia"] = { { "BLITZ", "planefx_blitz", "Cast a creature card from your hand for {3}: it has haste, draws you a card when it dies, and is sacrificed at the next end step" } },
  ["Talon Gates"] = { { "SUSPEND", "planefx_suspend", "Exile a nonland card from your hand with time counters equal to its mana value (it gains suspend). Sorcery speed" } },
  ["Singing Towers of Darillium"] = { { "FORETELL", "planefx_foretell", "Pay {2} and exile a nonland card from your hand face down; cast it on a later turn for its mana cost minus {2}" } },
}

function PlaneFx.planeButtons(plane)
  if plane == nil or plane.isDestroyed() then
    return
  end
  local list = GRANTS[plane.getName()]
  if not list then
    return
  end
  local sc = plane.getScale().x
  for i, b in ipairs(list) do
    plane.createButton({ click_function = b[2], function_owner = Global, label = b[1], tooltip = b[3],
      position = { 0, 0.3, (-0.9 - (i - 1) * 0.45) / sc * 1.4 }, rotation = { 0, 0, 0 }, scale = { 1 / sc, 1, 1 / sc },
      width = 1300, height = 300, font_size = 190, color = { 0.35, 0.12, 0.5, 0.95 }, font_color = { 1, 0.9, 1 },
      hover_color = { 0.5, 0.2, 0.7, 1 } })
  end
end

local function seated(color)
  if color == nil or color == "Grey" or color == "Black" or not TableSetup.isActive(color) or not GameState.data.started then
    broadcastToColor("Take a seat in a running game first.", color or "Grey", WARN)
    return false
  end
  return true
end

-- Pick a card from your graveyard: fits(entry) with entry = { guid, name, typeLine, gm }. cb(entry).
local function pickGrave(color, title, fits, cb)
  local list = {}
  local pile = Library.pileIn(color, "graveyard")
  if pile and pile.type == "Deck" then
    for _, e in ipairs(pile.getObjects() or {}) do
      local okd, dd = pcall(function() return JSON.decode(e.gm_notes or "{}") end)
      local ent = { guid = e.guid, name = e.name or e.nickname or "?", gm = okd and type(dd) == "table" and dd or {} }
      ent.typeLine = tostring(ent.gm.typeLine or ""):lower()
      if fits(ent) then
        table.insert(list, ent)
      end
    end
  elseif pile and pile.type == "Card" then
    local ent = { guid = pile.getGUID(), name = pile.getName(), gm = data(pile) }
    ent.typeLine = typeLine(pile)
    if fits(ent) then
      table.insert(list, ent)
    end
  end
  if #list == 0 then
    broadcastToColor(title .. ": nothing in your graveyard can.", color, INFO)
    return
  end
  local page = 0
  local function show()
    local ch = {}
    local per = 7
    for i = page * per + 1, math.min(#list, page * per + per) do
      table.insert(ch, { label = list[i].name:sub(1, 18), value = i })
    end
    if #list > (page + 1) * per then
      table.insert(ch, { label = "MORE...", value = "more" })
    end
    table.insert(ch, { label = "CANCEL", value = false })
    Effects.askChoice(color, title, "Pick the card from your graveyard.", ch, function(i)
      if i == "more" then
        page = page + 1
        show()
      elseif i then
        cb(list[i])
      end
    end)
  end
  show()
end

local function gmColors(gm)
  local out = {}
  for _, x in ipairs(type(gm.colors) == "table" and gm.colors or {}) do
    out[x] = true
  end
  return out
end

-- Cast a card taken out of a pile or hand: it goes onto the battlefield area and onto the stack.
local function castFrom(card, color)
  card.setLock(false)
  card.setRotation({ 0, TableSetup.seat(color).yaw, 0 })
  card.setPosition(TableSetup.slot(color, "battlefield", TableSetup.SURFACE_TOP + 2))
  Wait.time(function()
    if not card.isDestroyed() and Stack and Stack.onDrop then
      pcall(Stack.onDrop, color, card)
    end
  end, 0.6)
end

function planefx_unearth(obj, color)
  if not seated(color) then
    return
  end
  pickGrave(color, "Grixis: unearth", function(e)
    local c = gmColors(e.gm)
    return e.typeLine:find("creature", 1, true) and (c.U or c.B or c.R)
  end, function(e)
    takeFrom(color, "graveyard", { e.guid }, "battlefield", function(card)
      toBattlefield(card, color, false)
      local s = st()
      s.unearthed = s.unearthed or {}
      s.unearthed[card.getGUID()] = true
      Wait.time(function() pcall(Counters.addTempKeyword, card, "haste") end, 1)
      printToAll("MTG > Grixis: " .. color .. " unearths " .. card.getName() .. " (pay its mana cost). It has haste and is exiled at"
        .. " the next end step.", GOOD)
    end)
  end)
end

function planefx_flashback(obj, color)
  if not seated(color) then
    return
  end
  pickGrave(color, "Otaria: flashback", function(e)
    return e.typeLine:find("instant", 1, true) or e.typeLine:find("sorcery", 1, true)
  end, function(e)
    takeFrom(color, "graveyard", { e.guid }, "battlefield", function(card)
      local s = st()
      s.exileAfter = s.exileAfter or {}
      s.exileAfter[card.getGUID()] = color
      castFrom(card, color)
      printToAll("MTG > Otaria: " .. color .. " casts " .. card.getName() .. " with flashback (pay its mana cost). It's exiled"
        .. " afterwards.", GOOD)
    end)
  end)
end

function planefx_escape(obj, color)
  if not seated(color) then
    return
  end
  local total = #Effects.graveyardCards(color)
  pickGrave(color, "Stormcage: escape", function(e)
    return e.typeLine:find("creature", 1, true) and total >= 4
  end, function(e)
    local others = {}
    for _, x in ipairs(Effects.graveyardCards(color)) do
      if x.guid ~= e.guid then
        table.insert(others, x)
      end
    end
    local chosen = {}
    local function pickOther(k)
      if k > 3 then
        takeFrom(color, "graveyard", chosen, "exile", function(card)
          card.setPosition(TableSetup.slot(color, "exile", TableSetup.SURFACE_TOP + 2))
          Wait.time(function() if not card.isDestroyed() then Zones.refresh(card) end end, 0.5)
        end)
        Wait.time(function()
          takeFrom(color, "graveyard", { e.guid }, "battlefield", function(card)
            castFrom(card, color)
            printToAll("MTG > Stormcage Containment Facility: " .. color .. " casts " .. card.getName() .. " with escape (pay its"
              .. " mana cost; three other cards exiled).", GOOD)
          end)
        end, 1)
        return
      end
      local ch = {}
      local used = {}
      for _, g in ipairs(chosen) do
        used[g] = true
      end
      for _, x in ipairs(others) do
        if not used[x.guid] and #ch < 7 then
          table.insert(ch, { label = x.name:sub(1, 18), value = x.guid })
        end
      end
      Effects.askChoice(color, "Escape: exile " .. k .. " of 3", "Pick another card from your graveyard to exile.", ch, function(g)
        if g then
          table.insert(chosen, g)
          pickOther(k + 1)
        end
      end)
    end
    pickOther(1)
  end)
end

function planefx_embalm(obj, color)
  if not seated(color) then
    return
  end
  pickGrave(color, "Naktamun: embalm", function(e) return e.typeLine:find("creature", 1, true) end, function(e)
    takeFrom(color, "graveyard", { e.guid }, "exile", function(card)
      card.setPosition(TableSetup.slot(color, "exile", TableSetup.SURFACE_TOP + 2))
      Wait.time(function()
        if card.isDestroyed() then
          return
        end
        Zones.refresh(card)
        local copy = copyFor(card, color, "Naktamun")
        printToAll("MTG > Naktamun: " .. color .. " embalms " .. card.getName() .. " (pay its mana cost): a token copy, a white"
          .. " Zombie with no mana cost.", GOOD)
      end, 0.8)
    end)
  end)
end

function planefx_scavenge(obj, color)
  if not seated(color) then
    return
  end
  pickGrave(color, "The Cave of Skulls: scavenge", function(e) return e.typeLine:find("creature", 1, true) end, function(e)
    local n = tonumber(e.gm.power) or 0
    takeFrom(color, "graveyard", { e.guid }, "exile", function(card)
      card.setPosition(TableSetup.slot(color, "exile", TableSetup.SURFACE_TOP + 2))
      Wait.time(function() if not card.isDestroyed() then Zones.refresh(card) end end, 0.5)
      pick(color, { name = "Scavenge " .. card.getName() }, n .. " +1/+1 counters", "Pay its mana cost, then click TARGET on a"
        .. " creature: it gets " .. n .. " +1/+1 counters.", isCreature, function(t)
          if t then
            plus(t, n, color)
          end
        end)
    end)
  end)
end

function planefx_blitz(obj, color)
  if not seated(color) then
    return
  end
  Effects.pickFromHand(color, "The Caldaia: blitz", "Pick a creature card to cast for its blitz cost {3}.", function(h, d)
    return tostring(d.typeLine or ""):lower():find("creature", 1, true) ~= nil
  end, function(card)
    if not card then
      return
    end
    local s = st()
    s.blitz = s.blitz or {}
    s.blitz[card.getGUID()] = color
    castFrom(card, color)
    printToAll("MTG > The Caldaia: " .. color .. " casts " .. card.getName() .. " for its blitz cost {3}: haste, it draws a card"
      .. " when it dies, and it's sacrificed at the next end step.", GOOD)
  end)
end

function planefx_suspend(obj, color)
  if not seated(color) then
    return
  end
  Effects.pickFromHand(color, "Talon Gates: suspend", "Pick a nonland card: it's exiled with time counters equal to its mana value.",
    function(h, d) return not tostring(d.typeLine or ""):lower():find("land", 1, true) end, function(card)
      if not card then
        return
      end
      local n = mvOf(card)
      card.setPosition(TableSetup.slot(color, "exile", TableSetup.SURFACE_TOP + 2))
      Wait.time(function()
        if not card.isDestroyed() then
          Zones.refresh(card)
          Counters.change(card, "tc", n, color)
        end
      end, 0.8)
      printToAll("MTG > Talon Gates: " .. card.getName() .. " is suspended with " .. n .. " time counter" .. (n == 1 and "" or "s")
        .. ".", GOOD)
    end)
end

function planefx_foretell(obj, color)
  if not seated(color) then
    return
  end
  Effects.pickFromHand(color, "Singing Towers: foretell", "Pay {2}: pick a nonland card to exile face down (foretold).", function(h, d)
    return not tostring(d.typeLine or ""):lower():find("land", 1, true)
  end, function(card)
    if not card then
      return
    end
    local s = st()
    s.foretold = s.foretold or {}
    s.foretold[card.getGUID()] = turnNo()
    card.setRotation({ 0, TableSetup.seat(color).yaw, 180 })
    card.setPosition(TableSetup.slot(color, "exile", TableSetup.SURFACE_TOP + 2))
    Wait.time(function() if not card.isDestroyed() then Zones.refresh(card) end end, 0.8)
    printToAll("MTG > Singing Towers of Darillium: " .. color .. " foretells a card (face down in exile). Cast it on a later turn"
      .. " for its mana cost minus {2}: turn it face up and drop it on the battlefield.", GOOD)
  end)
end

-- What those leave behind: unearth (exiled at end step / instead of leaving), flashback (exiled after it
-- resolves), blitz (haste, sacrificed at end step, draws when it dies).
Events.on("cardMoved", function(d)
  if d == nil or d.card == nil or d.from == nil or d.to == nil or d.pileExtra then
    return
  end
  local s = st()
  local okG, g = pcall(function() return d.card.getGUID() end)
  if not okG then
    return
  end
  local card = d.card
  if s.exileAfter and s.exileAfter[g] and d.to.region == "graveyard" then
    local owner = s.exileAfter[g]
    s.exileAfter[g] = nil
    Wait.time(function()
      takeFrom(d.to.seat or owner, "graveyard", { g }, "exile", function(c)
        c.setPosition(TableSetup.slot(d.to.seat or owner, "exile", TableSetup.SURFACE_TOP + 2))
        Wait.time(function() if not c.isDestroyed() then Zones.refresh(c) end end, 0.5)
        printToAll("MTG > " .. c.getName() .. " (flashback) is exiled.", INFO)
      end)
    end, 1.2)
  end
  if s.unearthed and s.unearthed[g] and ON_FIELD[d.from.region] and not ON_FIELD[d.to.region] then
    s.unearthed[g] = nil
    if d.to.region ~= "exile" then
      Wait.time(function()
        local seat = d.to.seat or d.from.seat
        if d.to.region == "graveyard" then
          takeFrom(seat, "graveyard", { g }, "exile", function(c)
            c.setPosition(TableSetup.slot(seat, "exile", TableSetup.SURFACE_TOP + 2))
            Wait.time(function() if not c.isDestroyed() then Zones.refresh(c) end end, 0.5)
          end)
        elseif not card.isDestroyed() then
          card.setPosition(TableSetup.slot(seat, "exile", TableSetup.SURFACE_TOP + 2))
          Wait.time(function() if not card.isDestroyed() then Zones.refresh(card) end end, 0.5)
        end
        printToAll("MTG > Grixis: the unearthed creature is exiled instead.", INFO)
      end, 1)
    end
  end
  if s.blitz and s.blitz[g] then
    if ON_FIELD[d.to.region] and not ON_FIELD[d.from.region] then
      Wait.time(function() pcall(Counters.addTempKeyword, card, "haste") end, 1)
      s.blitzOn = s.blitzOn or {}
      s.blitzOn[g] = s.blitz[g]
    elseif ON_FIELD[d.from.region] and d.to.region == "graveyard" and (s.blitzOn or {})[g] then
      local who = s.blitzOn[g]
      s.blitzOn[g] = nil
      s.blitz[g] = nil
      Actions.draw(who, 1, "blitz")
      printToAll("MTG > Blitz: " .. who .. " draws a card (" .. tostring(d.name) .. " died).", GOOD)
    end
  end
end)

Events.on("stepStarted", function(d)
  if d == nil or d.step ~= "end" or not GameState.data.started then
    return
  end
  local s = st()
  for g in pairs(s.unearthed or {}) do
    local o = getObjectFromGUID(g)
    if o and Effects.fieldSeat(o) then
      Combat.removeCard(o, "exile")
      printToAll("MTG > Grixis: " .. o.getName() .. " (unearthed) is exiled.", INFO)
    end
    s.unearthed[g] = nil
  end
  for g, who in pairs(s.blitzOn or {}) do
    local o = getObjectFromGUID(g)
    if o and Effects.fieldSeat(o) then
      printToAll("MTG > Blitz: " .. o.getName() .. " is sacrificed.", INFO)
      Combat.removeCard(o, "graveyard")
    end
  end
end)

-- After a load: the plane card buttons come back.
Wait.time(function()
  if Planechase and Planechase.showCounters then
    pcall(Planechase.showCounters)
  end
end, 4)

---------------------------------------------------------------------------
-- v2.69: CREW (Ghirapur, New New York), CONVOKE (Ood Sphere), rebound (Trail of the Mage-Rings), demonstrate
-- (Strixhaven), cascade (TARDIS Bay), Nyx's enchantment creatures.
---------------------------------------------------------------------------

GRANTS["Ghirapur"] = { { "CREW", "planefx_crew", "Crew one of your Vehicles: tap creatures with total power at least its crew number; it becomes an artifact creature until end of turn" } }
GRANTS["New New York"] = { { "CREW", "planefx_crew", "Crew one of your Vehicles: tap creatures with total power at least its crew number; it becomes an artifact creature until end of turn" } }
GRANTS["Ood Sphere"] = { { "CONVOKE", "planefx_convoke", "Tap your untapped creatures to help pay for a noncreature spell: each adds one mana of one of its colors (or colorless)" } }

local function isTappedObj(o, seat)
  local s = TableSetup.seat(seat)
  local r = o.getRotation()
  local diff = ((r.y - s.yaw + 540) % 360) - 180
  return math.abs(diff) > 30
end

function planefx_crew(obj, color)
  if not seated(color) then
    return
  end
  local s = st()
  local mine = {}
  for g, v in pairs(s.vehicles or {}) do
    local o = getObjectFromGUID(g)
    if o and v.seat == color and v.turn == turnNo() and Effects.fieldSeat(o) == color then
      mine[g] = v
    end
  end
  if next(mine) == nil then
    broadcastToColor("You have no Vehicles from the plane to crew this turn.", color, INFO)
    return
  end
  local it = { name = "Crew" }
  pick(color, it, "which Vehicle?", "Click CREW on the Vehicle to crew.", function(o)
    return mine[o.getGUID()] ~= nil
  end, function(veh)
    if not veh then
      return
    end
    local v = mine[veh.getGUID()]
    local total, tapped = 0, {}
    local function more()
      if total >= v.crew then
        pcall(Effects.forgeAnimate, color, { on = "that", p = v.p, t = v.t, kw = v.kw, types = "artifact" },
          { name = v.name .. " (crewed)", thatCard = veh.getGUID() })
        s.vehicles[veh.getGUID()] = nil
        return
      end
      pick(color, it, "tap a creature (" .. total .. " of " .. v.crew .. " power)", "Click CREW on an untapped creature you"
        .. " control to tap it.", function(o, owner)
          return owner == color and isCreature(o) and o ~= veh and not tapped[o.getGUID()] and not isTappedObj(o, color)
        end, function(c)
          if not c then
            return
          end
          tapped[c.getGUID()] = true
          setTapped(c, color, true)
          total = total + math.max(0, powerOf(c))
          more()
        end, "CANCEL", "CREW")
    end
    more()
  end, "CANCEL", "CREW")
end

function planefx_convoke(obj, color)
  if not seated(color) then
    return
  end
  local it = { name = "Convoke (Ood Sphere)" }
  local n = 0
  local function more()
    pick(color, it, "tap a creature", "Click CONVOKE on an untapped creature you control (" .. n .. " so far), or DONE.",
      function(o, owner) return owner == color and isCreature(o) and not isTappedObj(o, color) end, function(c)
        if not c then
          if n > 0 then
            say(it.name, color .. " convoked " .. n .. " creature" .. (n == 1 and "" or "s") .. ".")
          end
          return
        end
        setTapped(c, color, true)
        n = n + 1
        local cols = colorsOf(c)
        local ch = {}
        for _, k in ipairs({ "W", "U", "B", "R", "G" }) do
          if cols[k] then
            table.insert(ch, { label = k, value = k })
          end
        end
        table.insert(ch, { label = "C", value = "C" })
        if #ch == 1 then
          ManaChips.add(color, "C", 1)
          more()
          return
        end
        Effects.askChoice(color, "Convoke: " .. c.getName(), "Which mana does it add?", ch, function(k)
          ManaChips.add(color, k or "C", 1)
          more()
        end)
      end, "DONE", "CONVOKE")
  end
  more()
end

-- Nyx: nontoken creatures are enchantments too (effects.lua / triggers.lua card types ask).
function PlaneFx.extraTypes(obj, t)
  if t and t.creature and not t.enchantment and planesUp()["Nyx"] then
    local okT, tok = pcall(function() return obj.hasTag("Token") end)
    if not (okT and tok) then
      t.enchantment = true
    end
  end
  return t
end

-- Rebound / demonstrate / cascade: on cast.
Events.on("spellCast", function(d)
  if d == nil or d.card == nil or d.controller == nil or not GameState.data.started then
    return
  end
  local up = planesUp()
  if next(up) == nil then
    return
  end
  local spell, who = d.card, d.controller
  local g = spell.getGUID()
  local tl = typeLine(spell)
  local isIS = tl:find("instant", 1, true) or tl:find("sorcery", 1, true)
  local s = st()
  -- Trail of the Mage-Rings: from the hand (it was in a hand a moment ago).
  if up["Trail of the Mage-Rings"] and isIS then
    local loc = Zones.locationOf and Zones.locationOf(spell)
    s.rebound = s.rebound or {}
    s.rebound[g] = who
    say("Trail of the Mage-Rings", spell.getName() .. " has rebound: it's exiled as it resolves, and " .. who .. " may cast it free"
      .. " at their next upkeep.", INFO)
  end
  -- Strixhaven: demonstrate.
  if up["Strixhaven"] and isIS then
    Wait.time(function()
      yesNo(who, "Strixhaven: demonstrate", who .. ": copy " .. spell.getName() .. "? If you do, an opponent you choose copies it"
        .. " too.", "COPY IT", "NO", function(y)
          if not y or not (Stack.has and Stack.has(g)) then
            return
          end
          pcall(Effects.copySpell, spell, who, "Strixhaven")
          local ch = {}
          for _, c in ipairs(opps(who)) do
            table.insert(ch, { label = string.upper(c), value = c })
          end
          Effects.askChoice(who, "Demonstrate: which opponent?", "That opponent also copies " .. spell.getName() .. ".", ch, function(c)
            if c then
              pcall(Effects.copySpell, spell, c, "Strixhaven")
            end
          end)
        end)
    end, 1)
  end
  -- TARDIS Bay: the first spell the planar controller casts each of their turns with mana value 2 or more cascades.
  if up["TARDIS Bay"] and who == planarSeat() and mvOf(spell) >= 2 and not tl:find("land", 1, true) then
    local mv = mvOf(spell)
    if s.cascadeTurn ~= turnNo() then
      s.cascadeTurn = turnNo()
      Wait.time(function()
        say("TARDIS Bay", spell.getName() .. " cascades: exiling until a nonland card with mana value less than " .. mv .. ".", CYAN)
        Library.exileUntilNonland(who, false, function(found, exiled)
          local rest = {}
          for _, c in ipairs(exiled or {}) do
            if c ~= found and not c.isDestroyed() then
              table.insert(rest, c)
            end
          end
          local function bottom()
            if #rest > 0 then
              Library.putBottomRandom(who, rest)
            end
          end
          if found == nil then
            bottom()
            return
          end
          yesNo(who, "Cascade", "Cast " .. found.getName() .. " without paying its mana cost?", "CAST IT", "NO", function(y)
            if y then
              castFrom(found, who)
            else
              table.insert(rest, found)
            end
            bottom()
          end)
        end, function(o) return mvOf(o) < mv and not typeLine(o):find("land", 1, true) end)
      end, 1.5)
    end
  end
end)

-- Rebound: the spell goes to exile instead of the graveyard; at its owner's next upkeep they may cast it free.
Events.on("cardMoved", function(d)
  if d == nil or d.card == nil or d.to == nil or d.pileExtra then
    return
  end
  local s = st()
  local okG, g = pcall(function() return d.card.getGUID() end)
  if not okG or not (s.rebound and s.rebound[g]) or d.to.region ~= "graveyard" then
    return
  end
  local who = s.rebound[g]
  s.rebound[g] = nil
  Wait.time(function()
    takeFrom(d.to.seat or who, "graveyard", { g }, "exile", function(c)
      c.setPosition(TableSetup.slot(d.to.seat or who, "exile", TableSetup.SURFACE_TOP + 2))
      Wait.time(function() if not c.isDestroyed() then Zones.refresh(c) end end, 0.5)
      s.reboundWait = s.reboundWait or {}
      s.reboundWait[c.getGUID()] = { seat = who, turn = turnNo() }
      say("Rebound", c.getName() .. " is exiled; " .. who .. " may cast it free at their next upkeep.", INFO)
    end)
  end, 1.2)
end)

Events.on("stepStarted", function(d)
  if d == nil or d.step ~= "upkeep" or d.seat == nil or not GameState.data.started then
    return
  end
  local s = st()
  for g, r in pairs(s.reboundWait or {}) do
    if Turns.isActiveSeat(r.seat) and r.turn < turnNo() then
      s.reboundWait[g] = nil
      local c = getObjectFromGUID(g)
      if c and not c.isDestroyed() then
        yesNo(r.seat, "Rebound", "Cast " .. c.getName() .. " from exile without paying its mana cost?", "CAST IT", "NO", function(y)
          if y and not c.isDestroyed() then
            castFrom(c, r.seat)
          end
        end)
      end
    end
  end
end)

---------------------------------------------------------------------------
-- Battlebond "friend or foe" (CR 701.33... "For each player, choose friend or foe"): the caster picks for
-- every player (2HG teammates are suggested as friends, the other team as foes), then each friend does the
-- friend part and each foe the foe part, in turn order. Pir's Whim, Khorvath's Fury, Virtus's Maneuver,
-- Zndrsplt's Judgment, Regna's Sanction. Lives here because it uses the same tools as the planes.
---------------------------------------------------------------------------

local function mustPick(seat, it, title, text, fits, cb, label)
  local any = false
  for _, e in ipairs(field(fits)) do
    if e.seat == seat then
      any = true
    end
  end
  if not any then
    say(it.name, seat .. " has nothing to " .. title .. ".", INFO)
    cb(nil)
    return
  end
  local function ask()
    pick(seat, it, title, text, function(obj, owner)
      return owner == seat and fits(obj, owner)
    end, function(obj)
      if obj == nil then
        broadcastToColor("You have to pick one.", seat, WARN)
        ask()
        return
      end
      cb(obj)
    end, "SKIP", label)
  end
  ask()
end

local FOF = {}

FOF.pir = {
  friend = function(it, c, nxt)
    if LibSearch and LibSearch.open then
      LibSearch.open(c, "land", it.name .. ": friend - put a land card onto the battlefield tapped, then close the search (it shuffles).",
        "battlefield", true, { limit = 1, fixedDest = true })
    end
    nxt()
  end,
  foe = function(it, c, nxt)
    sacOne(it, c, "an artifact or enchantment", function(o) local t = types(o) return t.artifact or t.enchantment end,
      function() nxt() end)
  end,
}

FOF.khorvath = {
  friend = function(it, c, nxt)
    local n = Actions.discardHand(c, it.name) or 0
    say(it.name, c .. " (friend) discards " .. n .. " and draws " .. (n + 1) .. ".")
    Wait.time(function()
      Actions.draw(c, n + 1, it.name)
      nxt()
    end, 0.8)
  end,
  foe = function(it, c, nxt)
    local n = #handOf(c)
    if n > 0 then
      say(it.name, "deals " .. n .. " damage to " .. c .. " (foe, " .. n .. " card" .. (n == 1 and "" or "s") .. " in hand).")
      life(c, -n, it.name)
    else
      say(it.name, c .. " (foe) has no cards in hand: no damage.", INFO)
    end
    nxt()
  end,
}

FOF.virtus = {
  friend = function(it, c, nxt)
    local done = false
    local ok = pcall(pickGrave, c, it.name .. ": friend - a creature card back to your hand", function(e)
      return tostring(e.typeLine):find("creature", 1, true) ~= nil
    end, function(e)
      if e then
        takeFrom(c, "graveyard", { e.guid }, "battlefield", function(card) toHand(card, c) end)
        say(it.name, c .. " (friend) returns " .. tostring(e.name) .. " to their hand.")
      end
    end)
    if not ok then
      broadcastToColor(it.name .. ": return a creature card from your graveyard to your hand yourself.", c, INFO)
    end
    nxt()
  end,
  foe = function(it, c, nxt)
    sacOne(it, c, "a creature", isCreature, function() nxt() end)
  end,
}

FOF.zndrsplt = {
  friend = function(it, c, nxt)
    mustPick(c, it, "copy a creature", c .. " (friend): click COPY on a creature you control.", isCreature, function(obj)
      if obj then
        copyFor(obj, c, it.name)
        say(it.name, c .. " (friend) creates a token copy of " .. obj.getName() .. ".")
      end
      nxt()
    end, "COPY")
  end,
  foe = function(it, c, nxt)
    mustPick(c, it, "return a creature", c .. " (foe): click RETURN on a creature you control.", isCreature, function(obj)
      if obj then
        local owner = (Effects.ownerOf and Effects.ownerOf(obj)) or c
        say(it.name, c .. " (foe) returns " .. obj.getName() .. " to its owner's hand.")
        toHand(obj, owner)
      end
      nxt()
    end, "RETURN")
  end,
}

FOF.regna = {
  friend = function(it, c, nxt)
    local n = 0
    for _, e in ipairs(field(isCreature)) do
      if e.seat == c then
        plus(e.obj, 1, c)
        n = n + 1
      end
    end
    say(it.name, c .. " (friend) puts a +1/+1 counter on each of their " .. n .. " creature" .. (n == 1 and "" or "s") .. ".")
    nxt()
  end,
  foe = function(it, c, nxt)
    local function untapped(o)
      if not isCreature(o) then
        return false
      end
      local s = TableSetup.seat(c)
      local y = (o.getRotation().y - (s and s.yaw or 0)) % 360
      return y < 45 or y > 315
    end
    mustPick(c, it, "keep one untapped", c .. " (foe): click KEEP on the untapped creature that stays untapped.", untapped, function(keep)
      local n = 0
      for _, e in ipairs(field(isCreature)) do
        if e.seat == c and e.obj ~= keep then
          setTapped(e.obj, c, true)
          n = n + 1
        end
      end
      say(it.name, c .. " (foe) keeps " .. (keep and keep.getName() or "nothing") .. " untapped; " .. n .. " other creature"
        .. (n == 1 and "" or "s") .. " tapped.")
      nxt()
    end, "KEEP")
  end,
}

local FOF_BY = {
  { "each friend searches their library for a land card", "pir" },
  { "each friend discards all cards from their hand", "khorvath" },
  { "each friend returns a creature card from their graveyard", "virtus" },
  { "each friend creates a token that's a copy of a creature they control", "zndrsplt" },
  { "each friend puts a +1/+1 counter on each creature they control", "regna" },
}

-- Effects.resolve hands any "choose friend or foe" text here: true when it's one the table runs.
function PlaneFx.friendOrFoe(it)
  local low = tostring(it and it.text or ""):lower():gsub("’", "'")
  if not low:find("choose friend or foe", 1, true) then
    return false
  end
  local h
  for _, e in ipairs(FOF_BY) do
    if low:find(e[1], 1, true) then
      h = FOF[e[2]]
    end
  end
  if h == nil then
    return false
  end
  local seat = it.controller
  local role = {}
  each(fromSeat(seat), function(c, nxt)
    local friendly = not TableSetup.isOpponent(c, seat)
    local ch = friendly and { { label = "FRIEND", value = "friend" }, { label = "FOE", value = "foe" } }
      or { { label = "FOE", value = "foe" }, { label = "FRIEND", value = "friend" } }
    choose(seat, it.name .. ": friend or foe", "Is " .. c .. (c == seat and " (you)" or "") .. " a friend or a foe?", ch, function(v)
      role[c] = v == "friend" and "friend" or "foe"
      nxt()
    end)
  end, function()
    local parts = {}
    for _, c in ipairs(fromSeat(seat)) do
      table.insert(parts, c .. " " .. string.upper(role[c] or "foe"))
    end
    say(it.name, table.concat(parts, ", ") .. ".")
    local order = {}
    for _, c in ipairs(fromSeat(seat)) do
      if role[c] == "friend" then table.insert(order, { c, "friend" }) end
    end
    for _, c in ipairs(fromSeat(seat)) do
      if role[c] ~= "friend" then table.insert(order, { c, "foe" }) end
    end
    each(order, function(e, nxt)
      local ok, err = pcall(h[e[2]], it, e[1], nxt)
      if not ok then
        if Events and Events.noteError then Events.noteError(it.name .. " (friend or foe)", err) end
        nxt()
      end
    end)
  end)
  return true
end
