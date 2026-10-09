--[[
  combat.lua
  Phase 7: the combat assistant. The table proposes, the players confirm.

  ATTACK step (active player)
    - Every untapped creature you control shows an ATTACK? button on the
      card. Click it to attack; click again for the next target (each
      opponent in turn order, then their planeswalkers), and once more past
      the last target to take it back out. Right-click the button = don't
      attack. The card's right-click menu has the same: "Attack / Block"
      and "Remove from combat" (works on vehicles you crewed too).
    - NEXT STEP declares: attackers tap (unless they have vigilance), the
      attack is announced, and "whenever ~ attacks" triggers go on the
      stack. NEXT STEP again moves on to blockers. With no attackers, NEXT
      STEP goes straight to END COMBAT.
    - Warnings (not blocks): summoning sick (entered this turn, no haste),
      defender.

  BLOCK step (each defending player)
    - Your untapped creatures show BLOCK? when something attacks you or your
      planeswalkers. Click to block; click again for the next attacker; past
      the last one = not blocking. Right-click = not blocking.
    - Warnings: blocking a flyer without flying / reach, a menace attacker
      blocked by only one creature.
    - The NEXT STEP pop-up reminds defenders to set blocks before passing.
    - Moving on to DAMAGE locks the blocks and puts "whenever ~ blocks" /
      "becomes blocked" triggers on the stack.

  DAMAGE step
    - When the stack is empty, a COMBAT DAMAGE panel (everyone sees it)
      lists every bit of damage the table worked out: power with counters,
      trample, deathtouch, lifelink, infect, wither, toxic, commander
      damage, damage to planeswalkers. First / double strike get their own
      round first.
    - Amounts have - / + to fix anything the table can't see (anthems,
      pump spells, prevention). Creatures and planeswalkers that would die
      are listed with DIES / KEEPS to flip.
    - CONFIRM (active player) applies it all: life, poison, commander
      damage, lifelink, loyalty, -1/-1 counters, and moves the dead to the
      graveyard (commanders to the command zone, tokens vanish after).
      "Deals combat damage to a player" triggers then go on the stack.
      SKIP closes the panel without applying anything.
  END COMBAT clears the buttons.
--]]

Combat = {}

local INFO = { 0.75, 0.8, 0.9 }
local WARN = { 1, 0.6, 0.2 }
local RED = { 1, 0.42, 0.48 }
local ON_FIELD = { battlefield = true, lands = true }
local MAX_ROWS = 16

---------------------------------------------------------------------------
-- State (kept in GameState so it survives a save)
---------------------------------------------------------------------------

local function state()
  local d = GameState.data
  d.combat = d.combat or {}
  local c = d.combat
  c.attackers = c.attackers or {}   -- [guid] = target: "Red" or "pw:<guid>"
  c.order = c.order or {}           -- attacker guids in the order chosen
  c.blocks = c.blocks or {}         -- [blocker guid] = attacker guid
  c.blockOrder = c.blockOrder or {} -- [attacker guid] = { blocker guids }
  c.blocked = c.blocked or {}       -- [attacker guid] = true once blocks lock
  c.extra = c.extra or {}           -- [blocker guid] = { further attacker guids } (blocks more than one)
  c.marked = c.marked or {}         -- damage marked on creatures this combat
  c.gone = c.gone or {}             -- [guid] = true: died / left this combat
  c.keep = c.keep or {}             -- [guid] = true: player flipped DIES -> KEEPS
  c.prevented = c.prevented or {}   -- [guid] = true: all combat damage to / by it is prevented (Maze of Ith)
  return c
end

-- Is this creature attacking right now?
function Combat.isAttacking(card)
  local c = GameState.data.combat
  return c ~= nil and card ~= nil and not card.isDestroyed() and c.attackers ~= nil
    and c.attackers[card.getGUID()] ~= nil and not (c.gone and c.gone[card.getGUID()])
end

-- Prevent all combat damage that would be dealt to and by this creature
-- this combat (Maze of Ith). Applied when the damage list is built.
function Combat.preventDamage(card)
  local c = state()
  c.prevented[card.getGUID()] = true
end

-- When each permanent entered (turns taken count), for summoning sickness.
local function entered()
  GameState.data.entered = GameState.data.entered or {}
  return GameState.data.entered
end

local function turn()
  return GameState.data.turn or {}
end

local function stepId()
  local t = turn()
  if not GameState.data.started or t.stepIndex == nil then
    return nil
  end
  return Turns.STEPS[t.stepIndex].id
end

local function players()
  local s = GameState.data.setup
  return (s and s.participants) or TableSetup.activeSeats()
end

local function alive(color)
  local p = GameState.player(color)
  return p ~= nil and not p.eliminated
end

-- Seats after `from` in turn order, still in the game.
local function othersInOrder(from)
  local list, start = players(), 0
  for i, c in ipairs(list) do
    if c == from then
      start = i
    end
  end
  local dir = turn().reversed and -1 or 1
  local out = {}
  for k = 1, #list - 1 do
    local c = list[((start - 1 + dir * k) % #list) + 1]
    if c ~= from and alive(c) then
      table.insert(out, c)
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Reading cards
---------------------------------------------------------------------------

local function cardData(obj)
  local notes = obj and obj.getGMNotes and obj.getGMNotes() or ""
  if notes == "" then
    return {}
  end
  local ok, d = pcall(function() return JSON.decode(notes) end)
  return (ok and type(d) == "table") and d or {}
end

local function hasKeyword(obj, kw)
  kw = kw:lower()
  if Counters.hasTempKeyword and Counters.hasTempKeyword(obj, kw) then
    return true
  end
  for _, k in ipairs(cardData(obj).keywords or {}) do
    if tostring(k):lower() == kw then
      return true
    end
  end
  return false
end

local function typeLine(obj)
  local d = cardData(obj)
  if d.typeLine then
    return d.typeLine
  end
  return table.concat(d.types or {}, " ")
end

local function isCreature(obj)
  return typeLine(obj):find("Creature", 1, true) ~= nil
end

local function isPlaneswalker(obj)
  return typeLine(obj):find("Planeswalker", 1, true) ~= nil
end

local function isToken(obj)
  return obj.hasTag("Token") or typeLine(obj):find("Token", 1, true) ~= nil
end

local function location(obj)
  if obj == nil or obj.isDestroyed() then
    return {}
  end
  return Zones.regionAt(obj.getPosition())
end

local function onField(obj)
  if obj == nil or obj.isDestroyed() or obj.type ~= "Card" then
    return false
  end
  return ON_FIELD[location(obj).region] == true
end

local function controller(obj)
  local loc = location(obj)
  return ON_FIELD[loc.region] and loc.seat or nil
end

local function isTapped(obj)
  local seat = controller(obj)
  local s = seat and TableSetup.seat(seat)
  if s == nil then
    return false
  end
  local diff = ((obj.getRotation().y - s.yaw + 540) % 360) - 180
  return math.abs(diff) > 30
end

local function tap(obj)
  local s = TableSetup.seat(controller(obj))
  local r = obj.getRotation()
  obj.setRotationSmooth({ r.x, (s.yaw + 90) % 360, r.z }, false, true)
end

-- Power / toughness with counters; nonnumbers ("*") count as 0 (flagged).
local function stats(obj)
  local s = Counters.stats(obj)
  local p, t = tonumber(s.power), tonumber(s.toughness)
  return p or 0, t or 0, (p == nil and s.power ~= nil)
end

local function obj(guid)
  local o = guid and getObjectFromGUID(guid)
  if o and not o.isDestroyed() then
    return o
  end
  return nil
end

-- A combatant still in the fight: on the battlefield, not dead this combat.
local function live(guid)
  local o = obj(guid)
  if o and onField(o) and not state().gone[guid] then
    return o
  end
  return nil
end

local function short(name)
  name = tostring(name or "?")
  local comma = name:find(",", 1, true)
  if comma then
    name = name:sub(1, comma - 1)
  end
  if #name > 18 then
    name = name:sub(1, 17) .. "."
  end
  return name
end

-- Commander damage key ("<owner>|<slot>") if the card is someone's commander.
local function commanderKey(card)
  local guid = card.getGUID()
  for _, color in ipairs(TableSetup.activeSeats()) do
    local p = GameState.player(color)
    for slot, g in pairs(p and p.commanders or {}) do
      if g == guid then
        return color .. "|" .. slot, color, slot
      end
    end
  end
  if cardData(card).isCommander then
    local name = card.getName()
    for _, color in ipairs(TableSetup.activeSeats()) do
      local p = GameState.player(color)
      for slot, n in ipairs(p and p.commanderNames or {}) do
        if n == name then
          return color .. "|" .. slot, color, slot
        end
      end
    end
  end
  return nil
end

-- "Toxic N" amount, read from the rules text without long patterns.
local function toxic(card)
  if not hasKeyword(card, "Toxic") then
    return 0
  end
  local text = tostring(cardData(card).oracle or ""):lower()
  local a = text:find("toxic ", 1, true)
  return a and (tonumber(text:sub(a + 6, a + 8):match("^%d+") or "") or 1) or 1
end

---------------------------------------------------------------------------
-- Attack targets
---------------------------------------------------------------------------

-- Everything the active player can attack, in order: each opponent, then
-- that opponent's planeswalkers.
local function targets(active)
  local list = {}
  local walkers = {}
  for _, o in ipairs(getObjectsWithTag("MTGCard")) do
    if o.type == "Card" and not o.is_face_down and onField(o) and isPlaneswalker(o) then
      local seat = controller(o)
      walkers[seat] = walkers[seat] or {}
      table.insert(walkers[seat], o)
    end
  end
  for _, seat in ipairs(othersInOrder(active)) do
    table.insert(list, seat)
    for _, pw in ipairs(walkers[seat] or {}) do
      table.insert(list, "pw:" .. pw.getGUID())
    end
  end
  return list
end

local function targetSeat(key)
  if key == nil then
    return nil
  end
  if key:sub(1, 3) == "pw:" then
    local pw = obj(key:sub(4))
    return pw and controller(pw) or nil
  end
  return key
end

local function targetLabel(key)
  if key and key:sub(1, 3) == "pw:" then
    local pw = obj(key:sub(4))
    return pw and short(pw.getName()) or "planeswalker"
  end
  return string.upper(tostring(key))
end

---------------------------------------------------------------------------
-- Buttons on the cards
---------------------------------------------------------------------------

local function isDefender(seat)
  local c = GameState.data.combat
  if c == nil then
    return false
  end
  for _, g in ipairs(c.order or {}) do
    if targetSeat(c.attackers[g]) == seat then
      return true
    end
  end
  return false
end

-- Draw this card's combat button (called from Counters.render, after it
-- cleared the card's buttons and drew its counters).
function Combat.decorate(card)
  local step = stepId()
  local c = GameState.data.combat
  if step == nil or c == nil or Faces.unknown(card) or not onField(card) then
    return
  end
  if step ~= "attackers" and step ~= "blockers" and step ~= "damage" then
    return
  end
  local guid = card.getGUID()
  local seat = controller(card)
  local label, bg, tip
  if c.attackers and c.attackers[guid] then
    local n = #(c.blockOrder[guid] or {})
    label = "ATTACKING\n" .. targetLabel(c.attackers[guid])
    if step ~= "attackers" and n > 0 then
      label = label .. "\nBLOCKED x" .. n
    end
    bg = { 0.55, 0.06, 0.12, 0.92 }
    tip = (step == "attackers" and not c.declared)
      and "Attacking. Click: next target. Right-click: don't attack."
      or "Attacking " .. targetLabel(c.attackers[guid])
  elseif c.blocks and c.blocks[guid] then
    local a = obj(c.blocks[guid])
    label = "BLOCKING\n" .. short(a and a.getName())
    if c.extra and c.extra[guid] and #c.extra[guid] > 0 then
      label = label .. " +" .. #c.extra[guid]
    end
    bg = { 0.05, 0.3, 0.55, 0.92 }
    tip = step == "blockers" and "Blocking. Click: next attacker. Right-click: not blocking." or "Blocking"
  elseif step == "attackers" and not c.declared and seat == turn().activeSeat
      and isCreature(card) and not isTapped(card) then
    label = "ATTACK?"
    bg = { 0.08, 0.1, 0.14, 0.75 }
    tip = "Click to attack (click again for the next target)."
  elseif step == "blockers" and seat ~= turn().activeSeat and isDefender(seat)
      and isCreature(card) and not isTapped(card) then
    label = "BLOCK?"
    bg = { 0.08, 0.1, 0.14, 0.75 }
    tip = "Click to block (click again for the next attacker)."
  end
  if label == nil then
    return
  end
  local nLines = select(2, label:gsub("\n", "\n")) + 1
  card.createButton({
    click_function = "combat_cardClick",
    function_owner = Global,
    label = label,
    tooltip = tip,
    position = { 0, 0.3, 0.95 },
    rotation = { 0, 0, 0 },
    width = 900,
    height = 60 + 175 * nLines,
    font_size = 150,
    font_color = { 1, 1, 1 },
    color = bg,
  })
end

local function redraw(card)
  if card and not card.isDestroyed() and card.type == "Card" then
    Counters.render(card)
  end
end

-- Redraw every creature / planeswalker on the battlefield (combat buttons).
function Combat.refresh()
  for _, o in ipairs(getObjectsWithTag("MTGCard")) do
    if o.type == "Card" and onField(o) then
      redraw(o)
    end
  end
end

---------------------------------------------------------------------------
-- Declaring attackers
---------------------------------------------------------------------------

local function removeAttacker(guid)
  local c = state()
  c.attackers[guid] = nil
  for i, g in ipairs(c.order) do
    if g == guid then
      table.remove(c.order, i)
      break
    end
  end
end

function Combat.attackClick(card, color, alt)
  local c = state()
  local t = turn()
  if GameState.solo() then
    color = t.activeSeat   -- solo test: you act for the active player
  end
  if color ~= t.activeSeat then
    broadcastToColor("Only " .. tostring(t.activeSeat) .. " attacks this turn.", color, WARN)
    return
  end
  if c.declared then
    broadcastToColor("Attackers are already declared.", color, WARN)
    return
  end
  if controller(card) ~= color then
    broadcastToColor("That isn't your creature.", color, WARN)
    return
  end
  local guid = card.getGUID()
  local current = c.attackers[guid]
  if alt then
    if current then
      removeAttacker(guid)
      redraw(card)
    end
    return
  end
  local list = targets(color)
  if #list == 0 then
    broadcastToColor("There's no one to attack.", color, WARN)
    return
  end
  if current == nil then
    if isTapped(card) then
      broadcastToColor(card.getName() .. " is tapped and can't attack.", color, WARN)
      return
    end
    c.attackers[guid] = list[1]
    table.insert(c.order, guid)
    if entered()[guid] == t.taken and not hasKeyword(card, "Haste") then
      broadcastToColor(card.getName() .. " came in this turn (summoning sick). Fine only if something gives it haste.",
        color, WARN)
    end
    if hasKeyword(card, "Defender") then
      broadcastToColor(card.getName() .. " has defender and normally can't attack.", color, WARN)
    end
  else
    local nextKey
    for i, k in ipairs(list) do
      if k == current then
        nextKey = list[i + 1]
      end
    end
    if nextKey then
      c.attackers[guid] = nextKey
    else
      removeAttacker(guid)
    end
  end
  redraw(card)
end

local function declare(color)
  local c = state()
  c.declared = true
  local list, parts = {}, {}
  local keep = {}
  for _, guid in ipairs(c.order) do
    local a = live(guid)
    if a then
      table.insert(keep, guid)
      if not hasKeyword(a, "Vigilance") and not isTapped(a) then
        tap(a)
      end
      table.insert(list, { obj = a, controller = color, target = targetSeat(c.attackers[guid]) })
      table.insert(parts, a.getName() .. " -> " .. targetLabel(c.attackers[guid]))
    else
      c.attackers[guid] = nil
    end
  end
  c.order = keep
  if #list == 0 then
    return
  end
  broadcastToAll(color .. " attacks: " .. table.concat(parts, ", "), RED)
  broadcastToColor("Attack declared. Resolve any attack triggers, then NEXT STEP for blockers.", color, INFO)
  if Triggers and Triggers.onAttack then
    Triggers.onAttack(list)
  end
  Combat.refresh()
end

---------------------------------------------------------------------------
-- Blocking
---------------------------------------------------------------------------

local function unblock(blockerGuid)
  local c = state()
  local a = c.blocks[blockerGuid]
  if a then
    for i, g in ipairs(c.blockOrder[a] or {}) do
      if g == blockerGuid then
        table.remove(c.blockOrder[a], i)
        break
      end
    end
  end
  c.blocks[blockerGuid] = nil
  for _, ag in ipairs(c.extra[blockerGuid] or {}) do
    for i, g in ipairs(c.blockOrder[ag] or {}) do
      if g == blockerGuid then
        table.remove(c.blockOrder[ag], i)
        break
      end
    end
  end
  c.extra[blockerGuid] = nil
  return a
end

-- Can this creature legally block that attacker? (flying / reach; "can't be
-- blocked" is left to the players.) Returns ok, reason.
local function canBlock(blocker, attacker)
  if attacker == nil then
    return true
  end
  if hasKeyword(attacker, "Flying") and not hasKeyword(blocker, "Flying") and not hasKeyword(blocker, "Reach") then
    local oracle = tostring(cardData(blocker).oracle or ""):lower()
    if not oracle:find("can block creatures with flying", 1, true) then
      return false, "has flying and " .. blocker.getName() .. " has neither flying nor reach"
    end
  end
  return true
end

function Combat.blockClick(card, color, alt)
  local c = state()
  if GameState.solo() then
    color = controller(card) or color   -- solo test: you act for every defender
  end
  if controller(card) ~= color then
    broadcastToColor("That isn't your creature.", color, WARN)
    return
  end
  if color == turn().activeSeat then
    broadcastToColor("Your creatures are attacking this turn, not blocking.", color, WARN)
    return
  end
  local guid = card.getGUID()
  local current = c.blocks[guid]
  if alt then
    if current then
      unblock(guid)
      redraw(card)
      redraw(obj(current))
    end
    return
  end
  -- Attackers this player may block: those attacking them or their walkers.
  local list = {}
  for _, g in ipairs(c.order) do
    if live(g) and targetSeat(c.attackers[g]) == color then
      table.insert(list, g)
    end
  end
  if #list == 0 then
    broadcastToColor("Nothing is attacking you.", color, WARN)
    return
  end
  if current == nil and isTapped(card) then
    broadcastToColor(card.getName() .. " is tapped and can't block.", color, WARN)
    return
  end
  -- Only attackers this creature may legally block (flying needs flying or
  -- reach). The click cycles through those.
  local legal, why = {}, nil
  for _, g in ipairs(list) do
    local ok, reason = canBlock(card, obj(g))
    if ok then
      table.insert(legal, g)
    else
      why = why or (obj(g) and (obj(g).getName() .. " " .. reason) or reason)
    end
  end
  if #legal == 0 then
    if current then
      unblock(guid)
      redraw(card)
      redraw(obj(current))
    end
    broadcastToColor(card.getName() .. " can't block anything here: " .. tostring(why) .. ".", color, WARN)
    return
  end
  list = legal
  local nextG
  if current == nil then
    nextG = list[1]
  else
    for i, g in ipairs(list) do
      if g == current then
        nextG = list[i + 1]
      end
    end
  end
  unblock(guid)
  if nextG then
    c.blocks[guid] = nextG
    c.blockOrder[nextG] = c.blockOrder[nextG] or {}
    table.insert(c.blockOrder[nextG], guid)
    local a = obj(nextG)
    if a and hasKeyword(a, "Menace") then
      local n = #(c.blockOrder[nextG] or {})
      if n < 2 then
        broadcastToColor(a.getName() .. " has menace: it can't be blocked except by two or more creatures. Block it with another creature too, or this block is removed when blocks lock.", color, WARN)
      end
    end
    redraw(a)
  end
  redraw(card)
  if current then
    redraw(obj(current))
  end
end

-- Leaving the block step: blocks are final. Announce them, warn about menace
-- and fire block triggers.
local function lockBlocks()
  local c = state()
  if c.locked then
    return
  end
  c.locked = true
  local blockList, parts = {}, {}
  for _, ag in ipairs(c.order) do
    local a = obj(ag)
    local bl = {}
    for _, bg in ipairs(c.blockOrder[ag] or {}) do
      local b = live(bg)
      if b then
        table.insert(bl, b)
        table.insert(blockList, { obj = b, controller = controller(b), attacker = a,
          attackerController = turn().activeSeat })
      end
    end
    if #bl > 0 then
      c.blocked[ag] = true
      local names = {}
      for _, b in ipairs(bl) do
        table.insert(names, b.getName())
      end
      table.insert(parts, (a and a.getName() or "?") .. " blocked by " .. table.concat(names, " + "))
      if #bl > 1 then
        table.insert(parts, "damage order for " .. (a and a.getName() or "?") .. ": " .. table.concat(names, " then "))
      end
      if a and hasKeyword(a, "Menace") and #bl == 1 then
        -- Menace: one blocker isn't a legal block. Taken back out.
        broadcastToAll(a.getName() .. " has menace: one blocker (" .. bl[1].getName() .. ") isn't a legal block, so it's removed.", WARN)
        local bg = bl[1].getGUID()
        unblock(bg)
        redraw(bl[1])
        c.blocked[ag] = nil
        for i = #blockList, 1, -1 do
          if blockList[i].obj == bl[1] then
            table.remove(blockList, i)
          end
        end
        parts[#parts] = nil
        bl = {}
      end
    end
  end
  if #parts > 0 then
    broadcastToAll("Blocks: " .. table.concat(parts, "; "), { 0.4, 0.7, 1 })
  else
    broadcastToAll("No blocks.", { 0.4, 0.7, 1 })
  end
  if #blockList > 0 and Triggers and Triggers.onBlock then
    Triggers.onBlock(blockList)
  end
end

---------------------------------------------------------------------------
-- Damage: working it out
---------------------------------------------------------------------------

local function firstStrike(o)
  return hasKeyword(o, "First strike")
end

local function doubleStrike(o)
  return hasKeyword(o, "Double strike")
end

local function dealsIn(o, phase)
  if phase == "first" then
    return firstStrike(o) or doubleStrike(o)
  end
  return not firstStrike(o) or doubleStrike(o)
end

-- Is there a first-strike damage round this combat?
local function anyFirstStrike()
  local c = state()
  for _, ag in ipairs(c.order) do
    local a = live(ag)
    if a and (firstStrike(a) or doubleStrike(a)) then
      return true
    end
    for _, bg in ipairs(c.blockOrder[ag] or {}) do
      local b = live(bg)
      if b and (firstStrike(b) or doubleStrike(b)) then
        return true
      end
    end
  end
  return false
end

-- Damage rows for one round. Each row: { kind = "player" | "pw" | "creature",
-- src, dst (guid or seat), amount, note }.
local function buildRows(phase)
  local c = state()
  local rows = {}
  local function add(row)
    if row.amount > 0 then
      table.insert(rows, row)
    end
  end
  local function toTarget(a, key, amount, note)
    if key:sub(1, 3) == "pw:" then
      if live(key:sub(4)) then
        add({ kind = "pw", src = a.getGUID(), dst = key:sub(4), amount = amount, note = note })
      end
    elseif alive(key) then
      add({ kind = "player", src = a.getGUID(), dst = key, amount = amount, note = note })
    end
  end
  for _, ag in ipairs(c.order) do
    local a = live(ag)
    if a and dealsIn(a, phase) then
      local power, _, odd = stats(a)
      local note = odd and "power is *: set it" or nil
      local key = c.attackers[ag]
      local blockers = {}
      for _, bg in ipairs(c.blockOrder[ag] or {}) do
        if live(bg) then
          table.insert(blockers, live(bg))
        end
      end
      local trample = hasKeyword(a, "Trample")
      local deathtouch = hasKeyword(a, "Deathtouch")
      if not c.blocked[ag] then
        toTarget(a, key, power, note)
        if odd and power == 0 then
          -- Still show it so the amount can be set.
          table.insert(rows, { kind = targetSeat(key) == key and "player" or "pw", src = ag,
            dst = key:sub(1, 3) == "pw:" and key:sub(4) or key, amount = 0, note = note })
        end
      elseif #blockers == 0 then
        if trample then
          toTarget(a, key, power, "trample, blockers gone")
        end
      else
        -- Lethal damage to each blocker in order, the rest to the last one
        -- (or, with trample, through to the player / planeswalker).
        local left = power
        for i, b in ipairs(blockers) do
          local _, tough = stats(b)
          local need = deathtouch and 1 or math.max(0, tough - (c.marked[b.getGUID()] or 0))
          local give = math.min(left, need)
          if i == #blockers and not trample then
            give = left
          end
          if give > 0 then
            add({ kind = "creature", src = ag, dst = b.getGUID(), amount = give })
          end
          left = left - give
        end
        if left > 0 and trample then
          toTarget(a, key, left, "trample")
        end
      end
    end
    -- Blockers hit back.
    if a then
      for _, bg in ipairs(c.blockOrder[ag] or {}) do
        local b = live(bg)
        if b and dealsIn(b, phase) then
          local power = stats(b)
          local more = #(c.extra[bg] or {})
          add({ kind = "creature", src = bg, dst = ag, amount = power,
            note = more > 0 and ("blocks " .. (more + 1) .. " attackers: split its power") or nil })
        end
      end
    end
  end
  -- Maze of Ith and the like: nothing is dealt to or by those creatures.
  local pv = c.prevented or {}
  if next(pv) ~= nil then
    local kept = {}
    for _, row in ipairs(rows) do
      if not pv[row.src] and not pv[row.dst] then
        table.insert(kept, row)
      end
    end
    rows = kept
  end
  return rows
end

local function rowText(r)
  local s = obj(r.src)
  local sName = short(s and s.getName())
  local text
  if r.kind == "player" then
    local what = "damage"
    if s and hasKeyword(s, "Infect") then
      what = "poison (infect)"
    elseif s and commanderKey(s) then
      what = "commander dmg"
    end
    text = sName .. " -> " .. r.dst .. ": " .. what
    if s and toxic(s) > 0 then
      text = text .. " +" .. toxic(s) .. " poison (toxic)"
    end
  elseif r.kind == "pw" then
    local d = obj(r.dst)
    text = sName .. " -> " .. short(d and d.getName()) .. " (loyalty)"
  else
    local d = obj(r.dst)
    text = sName .. " -> " .. short(d and d.getName())
    if s and (hasKeyword(s, "Infect") or hasKeyword(s, "Wither")) then
      text = text .. " (-1/-1 counters)"
    elseif s and hasKeyword(s, "Deathtouch") then
      text = text .. " (deathtouch)"
    end
  end
  if r.note then
    text = text .. " [" .. r.note .. "]"
  end
  return text
end

-- What the current amounts lead to: lifelink gains and deaths.
local function consequences(rows)
  local c = state()
  local gains, order = {}, {}
  local hits = {}   -- [guid] = { dmg, minus, deathtouch }
  for _, r in ipairs(rows) do
    local s = obj(r.src)
    if r.amount > 0 and s then
      if hasKeyword(s, "Lifelink") then
        local who = controller(s)
        if who then
          if gains[who] == nil then
            table.insert(order, who)
          end
          gains[who] = (gains[who] or 0) + r.amount
        end
      end
      if r.kind == "creature" or r.kind == "pw" then
        local h = hits[r.dst] or { dmg = 0, minus = 0 }
        hits[r.dst] = h
        if r.kind == "creature" and (hasKeyword(s, "Infect") or hasKeyword(s, "Wither")) then
          h.minus = h.minus + r.amount
        else
          h.dmg = h.dmg + r.amount
        end
        if hasKeyword(s, "Deathtouch") then
          h.deathtouch = true
        end
      end
    end
  end
  local deaths = {}
  for guid, h in pairs(hits) do
    local d = obj(guid)
    if d then
      local dies, why = false, nil
      if isPlaneswalker(d) and not isCreature(d) then
        local loyalty = Counters.get(d).loyalty
        dies = loyalty - h.dmg <= 0
        why = "loyalty " .. loyalty .. " -> " .. math.max(0, loyalty - h.dmg)
      else
        local _, tough = stats(d)
        tough = tough - h.minus
        local total = (c.marked[guid] or 0) + h.dmg
        if tough <= 0 then
          dies, why = true, "toughness 0"
        elseif hasKeyword(d, "Indestructible") then
          dies = false
        elseif total >= tough then
          dies, why = true, total .. " damage, toughness " .. tough
        elseif h.deathtouch and h.dmg > 0 then
          dies, why = true, "deathtouch"
        end
      end
      if dies then
        table.insert(deaths, { guid = guid, why = why })
      end
    end
  end
  table.sort(deaths, function(x, y) return x.guid < y.guid end)
  local lifelink = {}
  for _, who in ipairs(order) do
    table.insert(lifelink, { seat = who, amount = gains[who] })
  end
  return lifelink, deaths
end

---------------------------------------------------------------------------
-- The COMBAT DAMAGE panel
---------------------------------------------------------------------------

function Combat.xml()
  local rows = {}
  for i = 1, MAX_ROWS do
    table.insert(rows, ([[
    <HorizontalLayout id="cRow_%d" active="false" preferredHeight="28" spacing="6" childForceExpandWidth="false" childForceExpandHeight="false">
      <Text id="cText_%d" fontSize="13" color="#E6F1FF" alignment="MiddleLeft" flexibleWidth="1" preferredHeight="28">-</Text>
      <Button id="cMinus_%d" onClick="ui_combat(%d_minus)" preferredWidth="28" preferredHeight="26" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold">-</Button>
      <Text id="cAmt_%d" preferredWidth="34" preferredHeight="26" fontSize="15" fontStyle="Bold" color="#FF6A7A">0</Text>
      <Button id="cPlus_%d" onClick="ui_combat(%d_plus)" preferredWidth="28" preferredHeight="26" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold">+</Button>
      <Panel id="cTog_%d" preferredWidth="74" preferredHeight="26">
        <Button id="cTogBtn_%d" onClick="ui_combat(%d_toggle)" color="#5A1020" />
        <Text id="cTogTxt_%d" raycastTarget="false" color="#FFE6EA" fontStyle="Bold" fontSize="12">DIES</Text>
      </Panel>
    </HorizontalLayout>]]):format(i, i, i, i, i, i, i, i, i, i, i))
  end
  return [[
<Panel id="combatPanel" active="false" rectAlignment="UpperRight" offsetXY="-20 -170" width="560" height="300"
       color="#0B0F17F5" outline="#FF4A6A" outlineSize="2 2"
       allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="14 14 12 12" spacing="4" childForceExpandHeight="false">
    <Text id="combatTitle" fontSize="18" fontStyle="Bold" color="#FF5A7A" alignment="MiddleLeft" preferredHeight="24">COMBAT DAMAGE</Text>
    <Text fontSize="12" color="#8B98A9" alignment="MiddleLeft" preferredHeight="30">Fix any amount with - / +, flip DIES / KEEPS, then the active player clicks CONFIRM. Drag the panel to move it.</Text>
]] .. table.concat(rows) .. [[
    <HorizontalLayout preferredHeight="40" spacing="10">
      <Button onClick="ui_combat(0_confirm)" color="#00B3A4" textColor="#06130B" fontStyle="Bold" fontSize="16">CONFIRM</Button>
      <Button onClick="ui_combat(0_skip)" color="#2A3346" textColor="#E6F1FF" fontStyle="Bold" fontSize="14">SKIP (NO DAMAGE)</Button>
    </HorizontalLayout>
  </VerticalLayout>
</Panel>
]]
end

-- Fill the panel from the current rows. View rows map panel lines to rows.
local function renderPanel()
  local c = state()
  local s = c.summary
  if s == nil then
    UI.setAttribute("combatPanel", "active", "false")
    return
  end
  local lifelink, deaths = consequences(s.rows)
  local view = {}
  for i, r in ipairs(s.rows) do
    table.insert(view, { kind = "amount", row = i, text = rowText(r), amount = r.amount })
  end
  for _, g in ipairs(lifelink) do
    table.insert(view, { kind = "info", text = "Lifelink: " .. g.seat .. " gains", amount = g.amount })
  end
  for _, d in ipairs(deaths) do
    local o = obj(d.guid)
    table.insert(view, { kind = "toggle", guid = d.guid,
      text = short(o and o.getName()) .. " (" .. tostring(d.why) .. ")" })
  end
  if #view == 0 then
    table.insert(view, { kind = "info", text = "No combat damage this round." })
  end
  s.view = view
  UI.setValue("combatTitle", s.phase == "first" and "COMBAT DAMAGE: FIRST STRIKE" or "COMBAT DAMAGE")
  for i = 1, MAX_ROWS do
    local v = view[i]
    local id = tostring(i)
    if v == nil then
      UI.setAttribute("cRow_" .. id, "active", "false")
    else
      UI.setAttribute("cRow_" .. id, "active", "true")
      UI.setValue("cText_" .. id, v.text)
      local amt = v.kind == "amount" or (v.kind == "info" and v.amount ~= nil)
      UI.setAttribute("cAmt_" .. id, "active", amt and "true" or "false")
      if amt then
        UI.setValue("cAmt_" .. id, tostring(v.amount))
      end
      UI.setAttribute("cMinus_" .. id, "active", v.kind == "amount" and "true" or "false")
      UI.setAttribute("cPlus_" .. id, "active", v.kind == "amount" and "true" or "false")
      UI.setAttribute("cTog_" .. id, "active", v.kind == "toggle" and "true" or "false")
      if v.kind == "toggle" then
        local keep = c.keep[v.guid]
        UI.setValue("cTogTxt_" .. id, keep and "KEEPS" or "DIES")
        UI.setAttribute("cTogBtn_" .. id, "color", keep and "#1B4A2A" or "#5A1020")
      end
    end
  end
  if #view > MAX_ROWS then
    broadcastToAll("Combat: more than " .. MAX_ROWS .. " damage lines; the rest are applied as shown in chat.", WARN)
  end
  UI.setAttribute("combatPanel", "height", tostring(126 + 32 * math.min(#view, MAX_ROWS)))
  UI.setAttribute("combatPanel", "active", "true")
end

local openRound

-- Start a damage round (or finish combat damage when there's nothing left).
openRound = function(phase)
  local c = state()
  local rows = buildRows(phase)
  if #rows == 0 then
    if phase == "first" then
      openRound("regular")
      return
    end
    c.summary = nil
    c.damageDone = true
    renderPanel()
    broadcastToAll("No combat damage to deal. NEXT STEP when ready.", INFO)
    return
  end
  c.summary = { phase = phase, rows = rows }
  c.keep = {}
  renderPanel()
  broadcastToAll("Combat damage" .. (phase == "first" and " (first strike)" or "")
    .. " is ready: check the COMBAT DAMAGE panel. " .. tostring(turn().activeSeat) .. " confirms.", RED)
end

-- Start damage once the stack is empty (block triggers resolve first).
local function startDamage()
  local c = state()
  if c.summary or c.damageDone or stepId() ~= "damage" then
    return
  end
  if Stack and not Stack.isEmpty() then
    c.waitingStack = true
    broadcastToAll("Resolve the stack, then combat damage comes up.", INFO)
    return
  end
  c.waitingStack = nil
  openRound(anyFirstStrike() and "first" or "regular")
end

---------------------------------------------------------------------------
-- Damage: applying it
---------------------------------------------------------------------------

-- A dead permanent leaves: tokens to the graveyard then gone, commanders to
-- the command zone, everything else to its controller's graveyard.
-- zone = "exile" sends it to exile instead (effects.lua: "exile all ...").
-- Summoning sick right now: it came in during its controller's current turn
-- and has no haste.
function Combat.isSick(card)
  if not GameState.data.started or card == nil or card.isDestroyed() then
    return false
  end
  local t = turn()
  local g = card.getGUID()
  if t.taken == nil or entered()[g] ~= t.taken then
    return false
  end
  if controller(card) ~= t.activeSeat or not isCreature(card) then
    return false
  end
  return not hasKeyword(card, "Haste")
end

-- Is this creature attacking or blocking right now?
function Combat.inCombat(card)
  local c = GameState.data.combat
  if c == nil or card == nil then
    return false
  end
  local g = card.getGUID()
  return (c.attackers and c.attackers[g] ~= nil) or (c.blocks and c.blocks[g] ~= nil) or false
end

-- Commanders: is this card one, and put it back in its owner's command zone.
function Combat.isCommander(card)
  return card ~= nil and not card.isDestroyed() and commanderKey(card) ~= nil
end

function Combat.toCommandZone(card, byColor)
  local key, owner, slot = commanderKey(card)
  if key == nil then
    return false
  end
  card.setLock(false)
  card.setRotation({ 0, TableSetup.seat(owner).yaw, 0 })
  card.setPosition(TableSetup.slot(owner, "command" .. math.min(slot, 2), TableSetup.SURFACE_TOP + 1))
  Wait.time(function()
    if not card.isDestroyed() then
      Zones.refresh(card)
    end
  end, 0.5)
  broadcastToAll(card.getName() .. " went to " .. owner .. "'s command zone" .. (byColor and (" (" .. byColor .. ")") or "") .. ".", INFO)
  return true
end

-- A token that leaves the battlefield ceases to exist: it slides back to the
-- TOKENS tile (not the graveyard) and is gone.
function Combat.tokenGone(card, seat)
  if card == nil or card.isDestroyed() then
    return
  end
  local spot = TableSetup.slot(seat, "act_tokens", TableSetup.SURFACE_TOP + 1.2)
  card.setLock(false)
  if spot then
    card.setPositionSmooth(spot, false, true)
  end
  Wait.time(function()
    if not card.isDestroyed() then
      if Zones.forget then
        Zones.forget(card.getGUID())
      end
      card.destruct()
    end
  end, 0.9)
end

local function sendToGraveyard(card, zone)
  zone = zone or "graveyard"
  local seat = controller(card)
  if seat == nil then
    return
  end
  -- A transformed card turns back to its front as it leaves.
  if Faces and Faces.state(card) == 2 then
    card = Faces.front(card)
  end
  local s = TableSetup.seat(seat)
  card.setLock(false)
  local key, owner, slot = commanderKey(card)
  if key then
    card.setRotation({ 0, TableSetup.seat(owner).yaw, 0 })
    card.setPosition(TableSetup.slot(owner, "command" .. math.min(slot, 2), TableSetup.SURFACE_TOP + 1))
    Wait.time(function()
      if not card.isDestroyed() then
        Zones.refresh(card)
      end
    end, 0.5)
    broadcastToAll(card.getName() .. " went to the command zone (move it to the graveyard if " .. owner
      .. " prefers).", INFO)
    return
  end
  card.setRotation({ 0, s.yaw, 0 })
  if isToken(card) then
    Combat.tokenGone(card, seat)
    return
  end
  card.setPosition(TableSetup.slot(seat, zone, TableSetup.SURFACE_TOP + 2))
  -- Note the move now (dies triggers), before it merges into the pile.
  Zones.refresh(card)
  if zone ~= "graveyard" then
    return
  end
  Library.toGraveyard(seat, card, function()
    if not card.isDestroyed() then
      Zones.refresh(card)
    end
  end)
end
Combat.removeCard = sendToGraveyard

local function applyRound(byColor)
  local c = state()
  local s = c.summary
  if s == nil then
    return
  end
  local lifelink, deaths = consequences(s.rows)
  local damaged = {}   -- creatures that dealt combat damage to a player
  for _, r in ipairs(s.rows) do
    local src = obj(r.src)
    if r.amount > 0 and src then
      if r.kind == "player" then
        if hasKeyword(src, "Infect") then
          Trackers.changePoison(r.dst, r.amount, "combat")
        else
          local key, owner = commanderKey(src)
          if key and owner ~= r.dst then
            Trackers.changeCommanderDamage(r.dst, key, r.amount, "combat")
          else
            Trackers.changeLife(r.dst, -r.amount, "combat")
          end
        end
        local tx = toxic(src)
        if tx > 0 then
          Trackers.changePoison(r.dst, tx, "toxic")
        end
        table.insert(damaged, { obj = src, controller = controller(src), seat = r.dst, amount = r.amount })
      elseif r.kind == "pw" then
        local pw = obj(r.dst)
        if pw then
          Counters.change(pw, "loyalty", -r.amount, "combat")
        end
      else
        local d = obj(r.dst)
        if d then
          if hasKeyword(src, "Infect") or hasKeyword(src, "Wither") then
            Counters.change(d, "minus", r.amount, "combat")
          else
            c.marked[r.dst] = (c.marked[r.dst] or 0) + r.amount
          end
        end
      end
    end
  end
  for _, g in ipairs(lifelink) do
    Trackers.changeLife(g.seat, g.amount, "lifelink")
  end
  local dead = {}
  for _, d in ipairs(deaths) do
    local o = obj(d.guid)
    if o and not c.keep[d.guid] then
      c.gone[d.guid] = true
      table.insert(dead, o.getName())
      sendToGraveyard(o)
    end
  end
  if #dead > 0 then
    broadcastToAll("Died in combat: " .. table.concat(dead, ", "), WARN)
  end
  local phase = s.phase
  c.summary = nil
  renderPanel()
  if #damaged > 0 and Triggers and Triggers.onCombatDamage then
    Triggers.onCombatDamage(damaged)
  end
  if phase == "first" then
    openRound("regular")
  else
    c.damageDone = true
    broadcastToAll("Combat damage done (confirmed by " .. tostring(byColor) .. "). NEXT STEP when ready.", INFO)
  end
  Combat.refresh()
end

function ui_combat(player, arg)
  local color = player.color
  if not TableSetup.isActive(color) then
    return
  end
  local c = state()
  local s = c.summary
  if s == nil then
    UI.setAttribute("combatPanel", "active", "false")
    return
  end
  local idx, action = tostring(arg):match("^(%d+)_(%a+)$")
  idx = tonumber(idx)
  if action == "confirm" or action == "skip" then
    if color ~= turn().activeSeat and not GameState.solo() then
      broadcastToColor("The active player (" .. tostring(turn().activeSeat) .. ") confirms combat damage.", color, WARN)
      return
    end
    if action == "skip" then
      c.summary = nil
      c.damageDone = true
      renderPanel()
      broadcastToAll(color .. " skipped combat damage (nothing applied).", WARN)
      return
    end
    applyRound(color)
    return
  end
  local v = s.view and s.view[idx]
  if v == nil then
    return
  end
  if v.kind == "amount" and (action == "minus" or action == "plus") then
    local r = s.rows[v.row]
    r.amount = math.max(0, r.amount + (action == "plus" and 1 or -1))
    renderPanel()
  elseif v.kind == "toggle" and action == "toggle" then
    c.keep[v.guid] = not c.keep[v.guid] or nil
    local o = obj(v.guid)
    printToAll("MTG > " .. color .. ": " .. (o and o.getName() or "?") .. (c.keep[v.guid] and " keeps" or " dies"), INFO)
    renderPanel()
  end
end

---------------------------------------------------------------------------
-- Clicks on cards and the right-click menu
---------------------------------------------------------------------------

local function click(card, color, alt)
  local step = stepId()
  if step == "attackers" then
    Combat.attackClick(card, color, alt)
  elseif step == "blockers" then
    Combat.blockClick(card, color, alt)
  elseif step == "damage" then
    broadcastToColor("Combat damage is up: use the COMBAT DAMAGE panel.", color, INFO)
  else
    broadcastToColor("Attackers are chosen in the ATTACK step, blockers in the BLOCK step.", color, WARN)
  end
end

function combat_cardClick(card, color, alt)
  if card and not card.isDestroyed() then
    click(card, color, alt)
  end
end

-- A creature put onto the battlefield tapped and attacking (Hero of Bladehold's
-- tokens, Raph & Mikey...): it is an attacker now, but was never declared as
-- one, so attack triggers don't fire. It attacks `target` (default: what the
-- creature that put it there attacks). Needs the attack step.
function Combat.enterAttacking(card, seat, from)
  local c = GameState.data.combat
  if card == nil or card.isDestroyed() then
    return false
  end
  if c == nil or (stepId() ~= "attackers" and stepId() ~= "blockers") then
    broadcastToColor(card.getName() .. " enters attacking, but there is no attack going on: do it by hand.", seat, WARN)
    return false
  end
  local target = from and c.attackers[from]
  if target == nil then
    for _, g in ipairs(c.order) do
      if live(g) then
        target = c.attackers[g]
        break
      end
    end
  end
  if target == nil then
    broadcastToColor(card.getName() .. " enters attacking: choose who it attacks by hand.", seat, WARN)
    return false
  end
  local guid = card.getGUID()
  c.attackers[guid] = target
  table.insert(c.order, guid)
  c.gone[guid] = nil
  tap(card)
  redraw(card)
  broadcastToAll(card.getName() .. " enters tapped and attacking " .. tostring(targetLabel(target)) .. ".", { 0.9, 0.5, 0.5 })
  return true
end

-- A blocker that can block an additional creature (Palace Guard and the like).
function Combat.alsoBlock(card, color)
  local c = state()
  if stepId() ~= "blockers" then
    broadcastToColor("Extra blocks are set in the BLOCK step.", color, WARN)
    return
  end
  if GameState.solo() then
    color = controller(card) or color
  end
  local guid = card.getGUID()
  if controller(card) ~= color or c.blocks[guid] == nil then
    broadcastToColor("Block with this creature first (click BLOCK?), then use Also block.", color, WARN)
    return
  end
  local have = { [c.blocks[guid]] = true }
  for _, g in ipairs(c.extra[guid] or {}) do
    have[g] = true
  end
  for _, g in ipairs(c.order) do
    if live(g) and not have[g] and targetSeat(c.attackers[g]) == color then
      c.extra[guid] = c.extra[guid] or {}
      table.insert(c.extra[guid], g)
      c.blockOrder[g] = c.blockOrder[g] or {}
      table.insert(c.blockOrder[g], guid)
      broadcastToAll(card.getName() .. " also blocks " .. (obj(g) and obj(g).getName() or "?")
        .. ". Its power will be split: edit the numbers in the damage panel.", { 0.4, 0.7, 1 })
      redraw(card)
      redraw(obj(g))
      return
    end
  end
  broadcastToColor("No other attacker for " .. card.getName() .. " to block.", color, WARN)
end

-- Several blockers on one attacker: the attacker's controller picks the order
-- damage is dealt in. Each use moves the first blocker to the back.
function Combat.cycleOrder(card, color)
  local c = state()
  local guid = card.getGUID()
  if stepId() ~= "blockers" then
    broadcastToColor("Set the damage order in the BLOCK step.", color, WARN)
    return
  end
  if c.attackers[guid] == nil then
    broadcastToColor("Use this on an attacking creature.", color, WARN)
    return
  end
  local list = c.blockOrder[guid] or {}
  if #list < 2 then
    broadcastToColor(card.getName() .. " has fewer than two blockers.", color, WARN)
    return
  end
  table.insert(list, table.remove(list, 1))
  local names = {}
  for _, g in ipairs(list) do
    local b = obj(g)
    table.insert(names, b and b.getName() or "?")
  end
  broadcastToAll(card.getName() .. " damage order: " .. table.concat(names, " then "), { 0.4, 0.7, 1 })
end

-- Which combat step the right-click menus are built for ("" outside combat).
function Combat.menuStep()
  local step = stepId()
  if step == "attackers" or step == "blockers" then
    return step
  end
  return ""
end

-- Combat items show only in the steps where they do something.
function Combat.addCardMenu(card)
  local step = Combat.menuStep()
  if step == "" or not isCreature(card) then
    return
  end
  if step == "blockers" then
    card.addContextMenuItem("Also block next attacker", function(playerColor)
      if not card.isDestroyed() then
        Combat.alsoBlock(card, playerColor)
      end
    end)
    card.addContextMenuItem("Damage order (cycle blockers)", function(playerColor)
      if not card.isDestroyed() then
        Combat.cycleOrder(card, playerColor)
      end
    end)
  end
  card.addContextMenuItem(step == "attackers" and "Attack" or "Block", function(playerColor)
    if not card.isDestroyed() then
      click(card, playerColor, false)
    end
  end)
  card.addContextMenuItem("Remove from combat", function(playerColor)
    if not card.isDestroyed() then
      click(card, playerColor, true)
    end
  end)
end

---------------------------------------------------------------------------
-- Hooks used by turns.lua
---------------------------------------------------------------------------

-- NEXT STEP by the active player. true = handled here (don't move on).
function Combat.onNext(color)
  local step = stepId()
  local c = GameState.data.combat
  if step == "attackers" then
    c = state()
    if not c.declared then
      if #c.order > 0 then
        declare(color)
        if #c.order > 0 then
          return true
        end
      end
      c.declared = true
    end
  elseif step == "damage" and c then
    if c.summary then
      broadcastToColor("Confirm (or skip) the COMBAT DAMAGE panel first.", color, WARN)
      return true
    end
    if not c.damageDone then
      startDamage()
      return c.summary ~= nil or c.waitingStack == true
    end
  end
  return false
end

-- No attackers declared: NEXT STEP from ATTACK goes straight to END COMBAT.
function Combat.skipToEnd()
  if stepId() ~= "attackers" then
    return false
  end
  local c = GameState.data.combat
  return c == nil or c.order == nil or #c.order == 0
end

-- Extra line for the response pop-up (defenders: block first).
function Combat.promptNote()
  if stepId() == "blockers" then
    return "Defenders: set your blocks (BLOCK? on your creatures) before you pass."
  end
  return nil
end

function Combat.onStackEmpty()
  local c = GameState.data.combat
  if c and c.waitingStack and stepId() == "damage" then
    startDamage()
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function clear()
  local had = GameState.data.combat ~= nil
  GameState.data.combat = nil
  UI.setAttribute("combatPanel", "active", "false")
  if had then
    Combat.refresh()
  end
end

Events.on("stepStarted", function(d)
  local step = d.step
  if step == "combat" then
    clear()
    state()
  elseif step == "attackers" then
    state()
    Combat.refresh()
    broadcastToColor("ATTACK: click ATTACK? on your creatures (again = next target), then NEXT STEP to declare.",
      d.seat, RED)
  elseif step == "blockers" then
    Combat.refresh()
    for _, seat in ipairs(othersInOrder(d.seat)) do
      if isDefender(seat) then
        broadcastToColor("BLOCK: click BLOCK? on your untapped creatures (again = next attacker).", seat, { 0.4, 0.7, 1 })
      end
    end
  elseif step == "damage" then
    lockBlocks()
    Combat.refresh()
    startDamage()
  else
    clear()
  end
end)

Events.on("cardMoved", function(d)
  if d.card == nil or d.card.isDestroyed() then
    return
  end
  local wasOn = d.from and ON_FIELD[d.from.region]
  local isOn = d.to and ON_FIELD[d.to.region]
  local guid = d.card.getGUID()
  if isOn and not wasOn then
    entered()[guid] = turn().taken
  elseif wasOn and not isOn then
    entered()[guid] = nil
    -- A commander leaving the battlefield: offer the command zone.
    if d.to and (d.to.region == "graveyard" or d.to.region == "exile" or d.to.region == "hand" or d.to.region == "library")
        and GameState.data.started and commanderKey(d.card) and Effects and Effects.askChoice then
      local _, owner = commanderKey(d.card)
      local card = d.card
      Wait.time(function()
        if not card.isDestroyed() and Combat.isCommander(card) then
          Effects.askChoice(owner, card.getName() .. " left the battlefield",
            "Put " .. card.getName() .. " into the command zone instead?",
            { { label = "COMMAND ZONE", value = true }, { label = "LEAVE IT", value = false } }, function(yes)
              if yes and not card.isDestroyed() then
                Combat.toCommandZone(card, owner)
              end
            end)
        end
      end, 0.8)
    end
    -- A token dragged (or sent) anywhere off the battlefield is gone.
    local r = d.to and d.to.region
    if (r == "graveyard" or r == "exile" or r == "hand" or r == "library") and d.card.hasTag("Token") then
      Combat.tokenGone(d.card, d.to.seat or (d.from and d.from.seat) or "White")
    end
    local c = GameState.data.combat
    if c and (c.attackers and c.attackers[guid] or c.blocks and c.blocks[guid]) then
      if c.attackers[guid] then
        removeAttacker(guid)
      end
      local a = c.blocks[guid]
      if a then
        unblock(guid)
        redraw(obj(a))
      end
      c.gone[guid] = true
      redraw(d.card)
    end
  end
end)

-- After a reload: put the panel back if a damage round was open.
function Combat.restore()
  if GameState.data.combat and GameState.data.combat.summary then
    renderPanel()
  end
end
