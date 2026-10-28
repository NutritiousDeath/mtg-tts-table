--[[
  stack.lua
  Phase 5: the stack. A STACK mat sits in the middle of the table.

    Casting: drop a card from your hand (or command zone) onto your battlefield,
      or onto the stack mat. It goes on top of the stack, laid out
      newest lowest on the mat (on top of the others) and locked in place.
      A commander cast from its command zone this way raises its tax by 2.
    Abilities: right-click a card on the battlefield > "Ability to stack"
      puts an ability item (the card's art, marked ABILITY) on the stack.
      Phase 6 triggers use the same thing (Stack.pushAbility).
    The stack panel (screen, right side, everyone sees it) lists every item,
      top first, with its controller.
      RESOLVE  asks everyone else for responses (same pop-up as NEXT STEP);
               when all pass, the top item resolves: instants and sorceries
               go to their controller's graveyard, permanents onto their
               controller's battlefield, abilities disappear.
      COUNTER  the top item is countered: a spell goes to the graveyard, an
               ability disappears.
      X        on a row: take that item off the stack (a card goes back to
               its controller's hand, an ability disappears), for mistakes.
    Turn steps can't move on while anything is on the stack (turns.lua).
    Picking a card up off the mat also takes it off the stack.
--]]

Stack = {}

local ART_BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/stack/"
local ART_VERSION = "?v=1"
local INFO = { 0.75, 0.8, 0.9 }
local WARN = { 1, 0.6, 0.2 }
-- Priority rounds (see Stack.offer): the item that last got its round of responses.
local offerScheduled = false
local lastOffered = nil

-- The mat, in world coordinates (center of the table).
local MAT = { x = 0, z = 0, w = 8, d = 11 }
local MAT_YAW = 180            -- readable from White's side, like a card there
local MAX_ROWS = 12             -- rows in the stack panel
local CARD_STEP = 0.8           -- how far each newer item sits down the mat
local ABILITY_W = 2.2           -- ability items are card sized

local function data()
  GameState.data.stack = GameState.data.stack or {}
  return GameState.data.stack
end

local function items()
  local d = data()
  d.items = d.items or {}
  return d.items
end

-- Empty = nothing on the stack and no triggers waiting to be ordered.
function Stack.isEmpty()
  return #items() == 0 and not (Triggers and Triggers.isOrdering and Triggers.isOrdering())
    and not (Effects and Effects.isPending and Effects.isPending())
end

function Stack.size()
  return #items()
end

-- Is a world position on the STACK mat?
function Stack.contains(pos)
  return pos ~= nil and math.abs(pos.x - MAT.x) <= MAT.w / 2 and math.abs(pos.z - MAT.z) <= MAT.d / 2
end

local function indexOf(guid)
  for i, it in ipairs(items()) do
    if it.guid == guid then
      return i
    end
  end
  return nil
end

-- Card types from the card's GM Notes (written by the importer).
local function typesOf(obj)
  local notes = obj and obj.getGMNotes() or ""
  -- Plain search (TTS's Lua can't run (.-) patterns on long text).
  local list = ""
  local a = notes:find('"types":[', 1, true)
  if a then
    local b = notes:find("]", a, true)
    list = b and notes:sub(a + 9, b - 1) or ""
  end
  local t = {}
  for name in list:gmatch('"(%a+)"') do
    t[name] = true
  end
  return t
end

---------------------------------------------------------------------------
-- Layout: items fan down the mat from its top edge, newest lowest and on top
---------------------------------------------------------------------------

function Stack.layout()
  for i, it in ipairs(items()) do
    local obj = getObjectFromGUID(it.guid)
    if obj then
      local row = (i - 1) % 7
      local col = math.floor((i - 1) / 7)
      -- Toward White's side (-z) as items stack up; a second column after 7.
      local x = MAT.x + (col == 0 and 0 or 1.2) * (col % 2 == 1 and 1 or -1)
      local z = MAT.z + MAT.d / 2 - 2.6 - row * CARD_STEP
      obj.setLock(true)
      obj.setRotationSmooth({ 0, MAT_YAW, Faces.isFaceDown(obj) and 180 or 0 }, false, true)
      obj.setPositionSmooth({ x, TableSetup.SURFACE_TOP + 0.15 + i * 0.06, z }, false, true)
    end
  end
  Stack.render()
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

function Stack.xml()
  local rows = {}
  for i = 1, MAX_ROWS do
    table.insert(rows, ([[
    <HorizontalLayout id="stackRow_%d" active="false" preferredHeight="26" spacing="6" childForceExpandWidth="false">
      <Text id="stackText_%d" fontSize="13" color="#E6F1FF" alignment="MiddleLeft" flexibleWidth="1">-</Text>
      <Button onClick="ui_stackRemove(%d)" preferredWidth="26" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold"
              tooltip="Take this off the stack (a card goes back to its controller's hand)">X</Button>
    </HorizontalLayout>]]):format(i, i, i))
  end
  return [[
<Panel id="stackPanel" active="false" rectAlignment="MiddleRight" offsetXY="-20 120" width="340" height="140"
       color="#0B0F17F2" outline="#5AF0FF" outlineSize="2 2" allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="12 12 10 10" spacing="5" childForceExpandHeight="false">
    <Text id="stackTitle" fontSize="16" fontStyle="Bold" color="#5AF0FF" alignment="MiddleLeft" preferredHeight="24">THE STACK</Text>]]
    .. table.concat(rows) .. [[
    <HorizontalLayout spacing="8" preferredHeight="36">
      <Button onClick="ui_stackResolve" color="#00B3A4" textColor="#06130B" fontStyle="Bold"
              tooltip="Resolve the top item (everyone else gets a chance to respond first)">RESOLVE</Button>
      <Button onClick="ui_stackCounter" color="#DB5454" textColor="#1A0606" fontStyle="Bold"
              tooltip="The top item is countered: a spell goes to its graveyard, an ability disappears">COUNTER</Button>
    </HorizontalLayout>
    <HorizontalLayout spacing="8" preferredHeight="32">
      <Button onClick="ui_stackResolveAll" color="#1F6F66" textColor="#E6F1FF" fontStyle="Bold"
              tooltip="Resolve the whole stack, top first, one item at a time (others are still asked; stops on a response)">RESOLVE ALL</Button>
      <Button onClick="ui_stackYield" color="#2A3346" textColor="#E6F1FF" fontStyle="Bold"
              tooltip="Pass on everything until the stack is empty (you won't be asked for responses)">YIELD</Button>
    </HorizontalLayout>
  </VerticalLayout>
</Panel>
]]
end

function Stack.render()
  local list = items()
  UI.setAttribute("stackPanel", "active", #list > 0 and "true" or "false")
  UI.setValue("stackTitle", "THE STACK (" .. #list .. ")")
  local shown = math.min(#list, MAX_ROWS)
  for r = 1, MAX_ROWS do
    -- Row 1 is the top of the stack (the newest item).
    local i = #list - r + 1
    local it = r <= shown and list[i] or nil
    UI.setAttribute("stackRow_" .. r, "active", it and "true" or "false")
    if it then
      local tag = it.trigger and " (trigger)" or (it.kind == "ability" and " (ability)" or "")
      local aim = ""
      if it.preTargets and #it.preTargets > 0 and Effects and Effects.targetSummary then
        aim = "  > " .. Effects.targetSummary(it)
      elseif it.choosing then
        aim = "  > choosing targets..."
      end
      UI.setValue("stackText_" .. r, (r == 1 and "TOP  " or (i .. ".  ")) .. it.name .. tag .. "  -  " .. it.controller .. aim)
    end
  end
  UI.setAttribute("stackPanel", "height", 130 + shown * 31)
  pcall(Stack.updateFire)
  -- The stack emptied: yields and RESOLVE ALL are over.
  -- Only when it goes from something to empty: a YIELD clicked on an empty stack waits for the next item.
  if #list == 0 and (Stack.lastCount or 0) > 0 then
    GameState.data.yield = nil
    Stack.autoResolve = nil
  end
  Stack.lastCount = #list
  if Turns and Turns.render then
    Turns.render()
  end
end

---------------------------------------------------------------------------
-- Adding and removing
---------------------------------------------------------------------------

local function log(msg, color)
  printToAll("MTG > " .. msg, color or INFO)
end

-- A card was put on the mat by `controller`.
function Stack.pushCard(obj, controller, from)
  if obj == nil or obj.isDestroyed() or indexOf(obj.getGUID()) then
    return
  end
  controller = controller or "?"
  -- Cast face down (morph, disguise): a nameless 2/2 creature spell.
  if obj.is_face_down and not Faces.isFaceDown(obj) then
    Faces.hide(obj, nil, controller)
  end
  local item = { guid = obj.getGUID(), kind = "card", name = obj.getName(), controller = controller }
  table.insert(items(), item)
  log(controller .. " casts " .. obj.getName() .. " (on the stack).")
  -- Instants and sorceries choose their targets now (CR 601.2c), then everyone gets to respond.
  local ty = typesOf(obj)
  local cd = CardData.get(obj)
  -- An Aura spell targets what it will enchant ("Enchant creature"), chosen now too.
  local enchant = tostring(cd.typeLine or ""):find("Aura", 1, true) and tostring(cd.oracle or ""):match("^[Ee]nchant ([^\n%(]+)")
  if enchant and Effects and Effects.chooseTargets and not obj.is_face_down then
    item.auraText = enchant:gsub("%s+$", "")
    item.choosing = true
    item.choosingAt = os.time()
    Wait.time(function()
      local okc, errc = pcall(Effects.chooseTargets, item, Stack.offer)
      if not okc then
        item.choosing = nil
        Events.noteError("choosing a target for " .. tostring(item.name), errc)
        Stack.offer()
      end
    end, 0.3)
  elseif (ty.Instant or ty.Sorcery) and not (ty.Creature or ty.Enchantment or ty.Artifact or ty.Planeswalker or ty.Battle or ty.Land)
      and Effects and Effects.chooseTargets then
    item.targetText = tostring(cd.oracle or "")
    item.choosing = true
    item.choosingAt = os.time()
    Wait.time(function()
      local okc, errc = pcall(Effects.chooseTargets, item, Stack.offer)
      if not okc then
        item.choosing = nil
        Events.noteError("choosing targets for " .. tostring(item.name), errc)
        Stack.offer()
      end
    end, 0.3)
  else
    Stack.offer()
  end
  Events.emit("spellCast", { card = obj, controller = controller })
  -- A commander cast from its command zone: its tax goes up by 2.
  if from and from.region == "command" then
    for _, color in ipairs(TableSetup.activeSeats()) do
      local p = GameState.player(color)
      for slot, g in pairs(p and p.commanders or {}) do
        if g == obj.getGUID() then
          Trackers.changeTax(color, math.min(slot, 2), 2, nil, "cast from the command zone; right-click the tax to undo")
        end
      end
    end
  end
  Stack.layout()
end

-- An ability (from a card, or a trigger in Phase 6) goes on the stack as a
-- card-sized item showing the source card's art. text = its rules text.
-- An ability (from a card, or a trigger found by triggers.lua) goes on the
-- stack as a card-sized item showing the source card's art.
-- text = its rules text; opts.trigger = true labels it TRIGGER.
-- Break text into lines of at most `width` characters (on spaces).
local function wrap(text, width)
  local out, line = {}, ""
  for word in tostring(text):gmatch("%S+") do
    if line == "" then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      table.insert(out, line)
      line = word
    end
  end
  if line ~= "" then
    table.insert(out, line)
  end
  return table.concat(out, "\n")
end

function Stack.pushAbility(controller, sourceName, text, image, opts)
  opts = opts or {}
  local label = opts.copyOf and "COPY" or (opts.trigger and "TRIGGER" or "ABILITY")
  if opts.planar == "chaos" then
    label = "CHAOS"
  elseif opts.planar == "walk" then
    label = "PLANESWALK"
  end
  local pos = { MAT.x, TableSetup.SURFACE_TOP + 1, MAT.z }
  local obj = spawnObject({
    type = "Custom_Token",
    position = pos,
    rotation = { 0, MAT_YAW, 0 },
    sound = false,
    callback_function = function(o)
      o.setName(sourceName .. ((opts.planar == "chaos" and " (chaos)") or (opts.copyOf and " (copy)")
        or (opts.trigger and " (trigger)" or " (ability)")))
      o.setDescription(text or "")
      o.addTag("StackAbility")
      Wait.condition(function()
        local b = o.getBoundsNormalized()
        local w = b and b.size and b.size.x or 0
        if w > 0.05 then
          local k = ABILITY_W / (w / o.getScale().x)
          o.setScale({ k, 1, k })
        end
        Trackers.tileButton(o, { label = label, click_function = "trk_noop",
          tooltip = sourceName .. (opts.grantedBy and (" (ability given by " .. tostring(opts.grantedBy) .. ")") or "")
            .. "\n" .. tostring(text or ""), width = 900, height = 160, font_size = 120,
          color = { 0.04, 0.06, 0.1, 0.9 }, font_color = opts.planar == "chaos" and { 0.8, 0.5, 1 } or { 0.35, 0.95, 1 } }, 0, -1.3)
        -- The ability itself, written on the tile (the source's name on top), so it can be read without hovering.
        local body = tostring(text or "")
        local font = (#body > 200 and 34) or (#body > 120 and 40) or 48
        local shown = wrap(sourceName, math.floor(17 * 48 / font)) .. "\n\n" .. wrap(body, math.floor(19 * 48 / font))
        Trackers.tileButton(o, { label = shown, click_function = "trk_noop", width = 0, height = 0,
          font_size = font, color = { 0, 0, 0, 0 }, font_color = { 0.85, 0.92, 1 } }, 0, 0.3)
        Stack.layout()
      end, function() return o.isDestroyed() or not o.loading_custom end, 10)
    end,
  })
  obj.setCustomObject({ image = (image and image ~= "") and image or (ART_BASE .. "ability.png" .. ART_VERSION),
    thickness = 0.1, merge_distance = 5, stackable = false })
  -- On the list right away (not when the picture has loaded), so the turn
  -- can't move on in the meantime.
  local item = { guid = obj.getGUID(), kind = "ability", name = sourceName, controller = controller,
    text = text, trigger = opts.trigger, that = opts.that, source = opts.source, thatCard = opts.thatCard,
    amount = opts.amount, copyOf = opts.copyOf, ninjutsu = opts.ninjutsu, planar = opts.planar,
    ward = opts.ward, room = opts.room,
    auto = (opts.trigger or opts.loyalty or opts.activated or opts.copyOf) and true or nil }
  table.insert(items(), item)
  Stack.render()
  -- Its targets are chosen now, as it goes on the stack (CR 602.2b / 603.3d); then everyone gets to respond.
  if Effects and Effects.chooseTargets and item.auto and not opts.copyOf then
    item.choosing = true
    item.choosingAt = os.time()
    Wait.time(function()
      local okc, errc = pcall(Effects.chooseTargets, item, Stack.offer)
      if not okc then
        item.choosing = nil
        Events.noteError("choosing targets for " .. tostring(sourceName), errc)
        Stack.offer()
      end
    end, 0.3)
  else
    Stack.offer()
  end
  if opts.copyOf then
    log(controller .. " puts a copy of " .. sourceName .. " on the stack.")
  elseif opts.trigger then
    log(sourceName .. " triggers (" .. controller .. ")"
      .. (opts.grantedBy and (" [ability given by " .. tostring(opts.grantedBy) .. "]") or "") .. ": " .. tostring(text or ""))
  else
    log(controller .. " puts " .. sourceName .. "'s ability on the stack.")
  end
end

-- Take item i off the list (the object itself is handled by the caller).
local function removeAt(i)
  local it = table.remove(items(), i)
  if #items() == 0 and Turns and Turns.onStackEmpty then
    Wait.time(function()
      if Stack.isEmpty() then
        Turns.onStackEmpty()
      end
    end, 0.3)
  end
  Stack.layout()
  return it
end

-- Where a resolved / countered card goes.
local function sendCard(obj, it, destination)
  local color = TableSetup.isActive(it.controller) and it.controller or nil
  obj.setLock(false)
  if color == nil then
    return
  end
  local s = TableSetup.seat(color)
  if destination == "graveyard" then
    obj.setRotation({ 0, s.yaw, 0 })
    obj.setPosition(TableSetup.slot(color, "graveyard", 2))
    Library.toGraveyard(color, obj, function()
      if not obj.isDestroyed() then
        Zones.refresh(obj)
      end
    end)
  elseif destination == "hand" then
    obj.setPositionSmooth(Player[color].getHandTransform().position, false, true)
  else
    local types = typesOf(obj)
    local region = types.Land and "lands" or "battlefield"
    obj.setRotationSmooth({ 0, s.yaw, Faces.isFaceDown(obj) and 180 or 0 }, false, true)
    obj.setPositionSmooth(TableSetup.slot(color, region, 1.5), false, true)
    Wait.time(function()
      if not obj.isDestroyed() then
        Zones.refresh(obj)
      end
    end, 1)
  end
end

-- Resolve the top item (after everyone passed).
local resolveTopNow
function Stack.resolveTop()
  resolveTopNow()
  -- The next item down (if any) gets its own round of responses.
  Stack.offer()
  -- State-based actions (CR 704.3): anything left at 0 toughness by what just resolved dies.
  Wait.time(function()
    if Counters and Counters.checkDeath then
      for _, o in ipairs(getObjectsWithTag("MTGCard")) do
        if o.type == "Card" and not o.isDestroyed() and o.held_by_color == nil then
          local okl, loc = pcall(function() return Zones.regionAt(o.getPosition()) end)
          if okl and loc and (loc.region == "battlefield" or loc.region == "lands") then
            pcall(Counters.checkDeath, o)
          end
        end
      end
    end
  end, 1.5)
end

-- Split second (CR 702.61): while a spell with split second is on the stack, players can't cast spells
-- or activate abilities that aren't mana abilities. Returns its name, or nil.
function Stack.splitSecond()
  for _, it in ipairs(items()) do
    if it.kind == "card" then
      local obj = getObjectFromGUID(it.guid)
      local o = obj and tostring(CardData.get(obj).oracle or ""):lower() or ""
      if o:find("split second", 1, true) then
        return it.name
      end
    end
  end
  return nil
end

function resolveTopNow()
  local list = items()
  local it = list[#list]
  if it == nil then
    return
  end
  local obj = getObjectFromGUID(it.guid)
  removeAt(#list)
  if obj == nil then
    return
  end
  if it.kind == "ability" then
    log(it.name .. "'s ability resolves.")
    obj.destruct()
    -- The planar die's planeswalker symbol: planeswalk now (the next plane turns face up).
    if it.planar == "walk" then
      if Planechase and Planechase.planeswalk then
        local okp, errp = pcall(Planechase.planeswalk, it.controller, true)
        if not okp then
          Events.noteError("planeswalking", errp)
        end
      end
      return
    end
    -- Its targets, checked again (CR 608.2b): with none of them legal any more it does nothing.
    if Effects and Effects.checkTargets then
      local okt, legal = pcall(Effects.checkTargets, it)
      if okt and legal == false then
        log(it.name .. "'s ability doesn't resolve: none of its targets are legal any more (it fizzles).", WARN)
        Stack.offer()
        return
      end
    end
    -- Carry out what it says, when the table can (effects.lua).
    if Effects then
      local okr, errr = pcall(Effects.resolve, it)
      if not okr then
        Events.noteError("resolving " .. tostring(it.name), errr)
      end
    end
    return
  end
  local types = typesOf(obj)
  -- A card with a permanent type (Virtue of Persistence: an enchantment with
  -- a sorcery Adventure side) goes to the battlefield; only plain instants
  -- and sorceries go to the graveyard.
  local permanent = types.Creature or types.Enchantment or types.Artifact or types.Planeswalker or types.Battle
    or types.Land
  if (types.Instant or types.Sorcery) and not permanent then
    -- Its targets, checked again (CR 608.2b): with none of them legal any more it does nothing.
    if Effects and Effects.checkTargets then
      local okt, legal = pcall(Effects.checkTargets, it)
      if okt and legal == false then
        log(it.name .. " doesn't resolve: none of its targets are legal any more (it fizzles, to the graveyard).", WARN)
        sendCard(obj, it, "graveyard")
        Stack.offer()
        return
      end
    end
    log(it.name .. " resolves (to " .. it.controller .. "'s graveyard).")
    -- Read its text before it merges into the graveyard pile.
    local keep = false
    if Effects then
      Effects.pendingModes = it.modesChosen   -- modes chosen as it was cast
    end
    if Effects and Effects.resolveSpell then
      local oks, res = pcall(Effects.resolveSpell, obj, it.controller)
      if oks then
        keep = res == true
      else
        Events.noteError("resolving " .. tostring(it.name), res)
      end
    end
    if keep then
      -- Its effect puts it somewhere (library): unlock it; if nothing moved
      -- it, it goes to the graveyard after a while.
      obj.setLock(false)
      Wait.time(function()
        if not obj.isDestroyed() and Zones.regionAt(obj.getPosition()).region == "stack" and not indexOf(obj.getGUID()) then
          sendCard(obj, it, "graveyard")
        end
      end, 30)
    else
      sendCard(obj, it, "graveyard")
    end
  else
    -- An Aura spell whose target is gone doesn't resolve (CR 608.3b); otherwise it enters attached to it.
    local auraOn = nil
    if it.targetsChosen and Effects and Effects.checkTargets then
      local okt, legal = pcall(Effects.checkTargets, it)
      if okt and legal == false then
        log(it.name .. " doesn't resolve: what it would enchant isn't a legal target any more (to the graveyard).", WARN)
        sendCard(obj, it, "graveyard")
        return
      end
      Effects.replay = nil
      for _, e in ipairs(it.preTargets or {}) do
        if e.kind == "card" and auraOn == nil then
          auraOn = e.guid
        end
      end
    end
    log(it.name .. " resolves (onto " .. it.controller .. "'s battlefield).")
    sendCard(obj, it, "battlefield")
    if auraOn and Equip and Equip.attach then
      local controller = it.controller
      Wait.time(function()
        local host = getObjectFromGUID(auraOn)
        if host and not host.isDestroyed() and not obj.isDestroyed() then
          Equip.attach(obj, host, controller)
        end
      end, 1.6)
    end
  end
end

-- Why a stack item can't be countered (nil when it can): Cavern of Souls mana, "This spell can't be countered."
function Stack.uncounterable(it)
  if it == nil or it.kind == "ability" then
    return nil
  end
  local nc = GameState.data and GameState.data.noCounter
  if nc and nc[it.guid] then
    return "it was cast with " .. tostring(nc[it.guid]) .. " mana"
  end
  local obj = getObjectFromGUID(it.guid)
  if obj and tostring(CardData.get(obj).oracle or ""):lower():find("this spell can't be countered", 1, true) then
    return "\"This spell can't be countered\""
  end
  return nil
end

-- Counter one item by its object (ward counters the spell it was put on the stack for, wherever it is).
function Stack.counterGuid(guid, byWhat)
  local list = items()
  local i = indexOf(guid)
  if i == nil then
    return
  end
  local it = list[i]
  local why = Stack.uncounterable(it)
  if why then
    log(it.name .. " can't be countered: " .. why .. ".", WARN)
    return
  end
  local obj = getObjectFromGUID(it.guid)
  removeAt(i)
  if Effects and Effects.clearTargets then
    pcall(Effects.clearTargets, it)
  end
  log(it.name .. (it.kind == "ability" and "'s ability" or "") .. " is countered (" .. tostring(byWhat) .. ").", WARN)
  if obj then
    if it.kind == "ability" then
      obj.destruct()
    else
      sendCard(obj, it, "graveyard")
    end
  end
  Stack.offer()
end

function Stack.counterTop(byColor)
  local list = items()
  local it = list[#list]
  if it == nil then
    return
  end
  local why = Stack.uncounterable(it)
  if why then
    log(it.name .. " can't be countered: " .. why .. ". Nothing happens.", WARN)
    return
  end
  local obj = getObjectFromGUID(it.guid)
  removeAt(#list)
  if Effects and Effects.clearTargets then
    pcall(Effects.clearTargets, it)
  end
  Stack.offer()
  log(it.name .. (it.kind == "ability" and "'s ability" or "") .. " is countered (by " .. tostring(byColor) .. ").", WARN)
  if obj == nil then
    return
  end
  if it.kind == "ability" then
    obj.destruct()
  else
    sendCard(obj, it, "graveyard")
  end
end

-- What is on the stack right now (a copy of the list, bottom to top).
function Stack.entries()
  local out = {}
  for i, it in ipairs(items()) do
    out[i] = it
  end
  return out
end

-- Counter one item by its object GUID (a counterspell resolving).
function Stack.counterGuid(guid, byName)
  local list = items()
  for i, it in ipairs(list) do
    if it.guid == guid then
      local why = Stack.uncounterable(it)
      if why then
        log(it.name .. " can't be countered: " .. why .. ". " .. tostring(byName) .. " does nothing to it.", WARN)
        return nil
      end
      local obj = getObjectFromGUID(it.guid)
      removeAt(i)
      log(it.name .. (it.kind == "ability" and "'s ability" or "") .. " is countered (by " .. tostring(byName) .. ").", WARN)
      if obj then
        if it.kind == "ability" then
          obj.destruct()
        else
          sendCard(obj, it, "graveyard")
        end
      end
      return it
    end
  end
  return nil
end

-- Take row r of the panel (1 = top) off the stack.
function Stack.removeRow(r, byColor)
  local list = items()
  local i = #list - r + 1
  local it = list[i]
  if it == nil then
    return
  end
  local obj = getObjectFromGUID(it.guid)
  removeAt(i)
  log(tostring(byColor) .. " takes " .. it.name .. (it.kind == "ability" and "'s ability" or "") .. " off the stack.")
  if obj then
    if it.kind == "ability" then
      obj.destruct()
    else
      sendCard(obj, it, "hand")
    end
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

-- Who let go of each card last (cards cast from the table have no seat).
local dropper = {}

-- A player left the game (leave.lua): their spells and abilities come off the stack. Returns the
-- removed entries (the caller deals with the objects).
function Stack.dropControlledBy(color)
  local list = items()
  local out = {}
  for i = #list, 1, -1 do
    local it = list[i]
    if it.controller == color then
      table.remove(list, i)
      if Effects and Effects.clearTargets then
        pcall(Effects.clearTargets, it)
      end
      log(it.name .. (it.kind == "ability" and "'s ability" or "") .. " leaves the stack: " .. color .. " left the game.", WARN)
      table.insert(out, it)
    end
  end
  if #out > 0 then
    Stack.layout()
    Stack.offer()
    if #list == 0 and Turns and Turns.onStackEmpty then
      Wait.time(function()
        if Stack.isEmpty() then
          Turns.onStackEmpty()
        end
      end, 0.3)
    end
  end
  return out
end

function Stack.has(guid)
  return indexOf(guid) ~= nil
end

-- Casting: a nonland card dropped from a HAND or the COMMAND ZONE onto a battlefield goes on the stack
-- (it lands on the battlefield when it resolves). Lands are played straight onto the battlefield. Where it
-- came from (for commander tax) is known from when it was picked up. Checked before the move settles
-- (zones.lua waits a little longer), so nothing "enters" before it resolves.
local CAST_FROM = { hand = true, command = true }
function Stack.onDrop(color, obj)
  if obj == nil or color == nil then
    return
  end
  -- A player who has left the game casts nothing (leave.lua).
  if Leave and Leave.isOut(color) then
    return
  end
  -- Split second on the stack: no casting (the card stays where it was dropped; take it back).
  local ss = Stack.splitSecond()
  if ss and obj.type == "Card" and obj.hasTag("MTGCard") then
    local fromLoc = Zones.locationOf(obj)
    if fromLoc and CAST_FROM[fromLoc.region] then
      broadcastToColor(ss .. " has split second: nobody can cast spells until it resolves. Take " .. obj.getName() .. " back.", color, WARN)
      return
    end
  end
  dropper[obj.getGUID()] = color
  local from = Zones.locationOf(obj)
  if from == nil or not CAST_FROM[from.region] or obj.type ~= "Card" or not obj.hasTag("MTGCard") then
    return
  end
  Wait.time(function()
    if obj.isDestroyed() or obj.held_by_color or obj.type ~= "Card" or indexOf(obj.getGUID()) then
      return
    end
    local here = Zones.regionAt(obj.getPosition())
    if here.region ~= "battlefield" and here.region ~= "lands" then
      return
    end
    local d = CardData.get(obj)
    local tl = tostring(d.typeLine or "")
    -- A land (the front face of a land card) is played, not cast. Face-down cards are cast (morph).
    if tl:find("Land", 1, true) and not tl:find("//", 1, true) and not obj.is_face_down then
      return
    end
    -- The player who dragged it out of their hand cast it. (The table's record of whose hand it was in has
    -- been seen naming the wrong seat, which made someone else draw for a spell; in a real game the
    -- dropping player wins, and the mismatch is reported so it can be tracked down.)
    local controller = from.seat or color
    if not GameState.solo() and TableSetup.isActive(color) and from.seat and from.seat ~= color then
      printToAll("MTG > Note: " .. color .. " cast " .. obj.getName() .. " but the table had it in " .. from.seat
        .. "'s " .. tostring(from.region) .. "; it counts as " .. color .. "'s spell. (Tell Claude if this shows up.)",
        { 1, 0.75, 0.3 })
      controller = color
    end
    Stack.pushCard(obj, controller, from)
  end, 0.25)
end

-- Picking a card up off the mat takes it off the stack.
function Stack.onPickUp(color, obj)
  if obj == nil then
    return
  end
  local i = indexOf(obj.getGUID())
  if i then
    obj.setLock(false)
    local it = removeAt(i)
    log(color .. " picked " .. it.name .. " up off the stack.")
  end
end

Events.on("cardMoved", function(d)
  if d.card == nil or d.to == nil then
    return
  end
  if d.to.region == "stack" and (d.from == nil or d.from.region ~= "stack") then
    -- Whoever dropped it on the mat cast it (or the seat it came from).
    local controller = dropper[d.card.getGUID()] or (d.from and d.from.seat)
    Stack.pushCard(d.card, controller, d.from)
  end
end)

-- Each seat's CAST mat above its tracker.
local function ensureCastMats()
  local reg = data()
  reg.castTiles = reg.castTiles or {}
  local wanted = {}
  -- No CAST mats any more: casting is dropping the card on the battlefield (Stack.onDrop). Old mats are removed.
  Trackers.syncTiles("CastZone", { { registry = reg.castTiles, wanted = wanted } })
end

-- The ring of flame round the mat for planar die results (planechase.lua): purple-blue for chaos, blue-white
-- (a planeswalker's spark) for planeswalking. It ignites while such an item is on the stack and goes out in a
-- puff of smoke when it has resolved (tools/unity/MTGTorchBuilder.cs, mtg_stackfire).
local STACK_FIRE_URL = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/torch/mtg_stackfire.unity3d?v=5"
local FIRE_EFFECT = { chaos = 1, walk = 2 }
local fireNow = nil   -- "chaos", "walk" or nil
local fireSpawning = false

local function fireObj()
  local g = data().fire
  local o = g and getObjectFromGUID(g)
  if o and not o.isDestroyed() then
    return o
  end
  -- Lost track of it (!reset wipes the stack's saved data): take back the one already on the table.
  for _, x in ipairs(getObjectsWithTag("StackFire")) do
    local co = x.getCustomObject()
    if not x.isDestroyed() and co and co.assetbundle == STACK_FIRE_URL then
      data().fire = x.getGUID()
      return x
    end
  end
  return nil
end

function Stack.ensureFire()
  local reg = data()
  local o = fireObj()
  local co = o and o.getCustomObject()
  local pos = { MAT.x, TableSetup.SURFACE_TOP + 0.05, MAT.z }
  if o and co and co.assetbundle == STACK_FIRE_URL then
    o.setLock(true)
    o.setPosition(pos)
    return
  end
  if o then
    o.destruct()
  end
  for _, x in ipairs(getObjectsWithTag("StackFire")) do
    x.destruct()
  end
  local obj = spawnObject({
    type = "Custom_AssetBundle",
    position = pos,
    rotation = { 0, MAT_YAW, 0 },
    sound = false,
    callback_function = function(x)
      x.setLock(true)
      x.setPosition(pos)
      x.interactable = false
      x.setName("Stack Fire")
      x.addTag("StackFire")
      reg.fire = x.getGUID()
      fireNow = nil
      Wait.time(function() Stack.updateFire(true) end, 1)
    end,
  })
  obj.setCustomObject({ assetbundle = STACK_FIRE_URL, type = 0 })
  reg.fire = obj.getGUID()
end

-- Light or put out the ring to match the stack: the topmost planar item decides the colour.
function Stack.updateFire(force)
  local want
  local list = items()
  for i = #list, 1, -1 do
    if list[i].planar then
      want = list[i].planar
      break
    end
  end
  if want == fireNow and not force then
    return
  end
  local o = fireObj()
  if o == nil then
    -- No flame ring on the table (removed, or an old version): make one, then light it once it loads.
    if want and not fireSpawning then
      fireSpawning = true
      pcall(Stack.ensureFire)
      Wait.time(function()
        fireSpawning = false
        Stack.updateFire(true)
      end, 2)
    end
    return
  end
  if o.loading_custom or o.AssetBundle == nil then
    Wait.time(function() Stack.updateFire(true) end, 1)
    return
  end
  local was = fireNow
  fireNow = want
  pcall(function()
    if want then
      o.AssetBundle.playLoopingEffect(FIRE_EFFECT[want])
    else
      o.AssetBundle.playLoopingEffect(0)
      if was then
        o.AssetBundle.playTriggerEffect(FIRE_EFFECT[was] - 1)   -- the puff of smoke
      end
    end
  end)
end

-- The mat itself: one image tile in the middle of the table.
function Stack.ensure()
  ensureCastMats()
  -- The flame ring loads a moment after the rest of the table (see TableSetup.ensure).
  Wait.time(function() pcall(Stack.ensureFire) end, 4)
  local reg = data()
  reg.mat = reg.mat
  local mat = reg.mat and getObjectFromGUID(reg.mat)
  local url = ART_BASE .. "stack_mat.png" .. ART_VERSION
  local co = mat and mat.getCustomObject()
  if mat and co and co.image == url then
    mat.setLock(true)
    -- Back in its spot (a table flip or a bump can leave it elsewhere).
    pcall(function()
      mat.setRotation({ 0, MAT_YAW, 0 })
      mat.setPosition({ MAT.x, TableSetup.SURFACE_TOP + mat.getBoundsNormalized().size.y / 2 + 0.01, MAT.z })
    end)
  else
    if mat then
      mat.destruct()
    end
    for _, obj in ipairs(getObjectsWithTag("StackMat")) do
      obj.destruct()
    end
    local o = spawnObject({
      type = "Custom_Token",
      position = { MAT.x, TableSetup.SURFACE_TOP + 0.5, MAT.z },
      rotation = { 0, MAT_YAW, 0 },
      sound = false,
      callback_function = function(obj)
        obj.setName("The Stack")
        obj.setDescription("Drop a spell here to cast it.")
        obj.addTag("StackMat")
        reg.mat = obj.getGUID()
        Wait.condition(function()
          local b = obj.getBoundsNormalized()
          local w = b and b.size and b.size.x or 0
          if w > 0.05 then
            local k = MAT.w / (w / obj.getScale().x)
            obj.setScale({ k, 1, k })
          end
          obj.setPosition({ MAT.x, TableSetup.SURFACE_TOP + obj.getBoundsNormalized().size.y / 2 + 0.01, MAT.z })
          obj.setLock(true)
        end, function() return obj.isDestroyed() or not obj.loading_custom end, 10)
      end,
    })
    o.setCustomObject({ image = url, thickness = 0.1, merge_distance = 5, stackable = false })
  end
  -- Drop items whose objects are gone (e.g. after a reload), redraw the rest.
  local keep = {}
  for _, it in ipairs(items()) do
    if getObjectFromGUID(it.guid) then
      table.insert(keep, it)
    end
  end
  data().items = keep
  Stack.render()
end

---------------------------------------------------------------------------
-- XML handlers and card menu
---------------------------------------------------------------------------

function ui_stackResolve(player)
  local list = items()
  local it = list[#list]
  if it == nil then
    return
  end
  local who = player.color
  if not TableSetup.isActive(who) or (Leave and Leave.isOut(who)) then
    return
  end
  local what = it.name .. (it.kind == "ability" and "'s ability" or "")
  lastOffered = it.guid
  if it.preTargets and #it.preTargets > 0 and Effects and Effects.targetSummary then
    what = what .. " (targeting " .. Effects.targetSummary(it) .. ")"
  end
  if GameState.data.started and Turns.ask then
    Turns.ask(who, who .. " wants to resolve " .. what .. ".", "RESOLVE " .. string.upper(it.name), function()
      -- Still the same top item? (Something may have been added meanwhile.)
      local now = items()
      if now[#now] and now[#now].guid == it.guid then
        Stack.resolveTop()
      end
      -- RESOLVE ALL: on to the next item once this one has finished (pop-ups it opened come first).
      if Stack.autoResolve == who then
        local function nextOne()
          if Stack.autoResolve ~= who or Stack.isEmpty() then
            return
          end
          -- Wait while a pop-up from the last item (a target, a choice) is still open.
          if (Effects and Effects.busy and Effects.busy()) or (LibSearch and LibSearch.isOpen and LibSearch.isOpen(who)) then
            Wait.time(nextOne, 1.0)
            return
          end
          ui_stackResolve(Player[who])
        end
        Wait.time(nextOne, 1.5)
      end
    end)
  else
    Stack.resolveTop()
  end
end

---------------------------------------------------------------------------
-- Priority: whenever something new is on top of the stack (and its targets are chosen), everyone
-- else is asked for responses straight away, in turn order (the same pop-up as RESOLVE). When they
-- all pass it resolves on its own (CR 117.4), and the next item down gets its own round. If someone
-- has a response, their spell or ability goes on top and gets a round; if they end up not adding
-- one, RESOLVE asks again. Solo test games keep the RESOLVE click (nobody else to ask).
---------------------------------------------------------------------------

local function tryOffer()
  if not GameState.data or not GameState.data.started or GameState.solo() then
    return
  end
  local list = items()
  local top = list[#list]
  if top == nil then
    lastOffered = nil
    return
  end
  if top.guid == lastOffered or Stack.autoResolve then
    return
  end
  -- Wait while anything is still being decided: targets, trigger order, a pop-up, a waiting step.
  -- (A "choosing" left over from before a reload doesn't count once nothing is being asked.)
  local busy = (top.choosing and os.time() - (top.choosingAt or 0) < 5)
    or (Triggers and Triggers.isOrdering and Triggers.isOrdering())
    or (Effects and Effects.busy and Effects.busy())
    or (Turns and Turns.isWaiting and Turns.isWaiting())
  if busy then
    Stack.offer()
    return
  end
  if not TableSetup.isActive(top.controller) or Player[top.controller] == nil then
    return
  end
  lastOffered = top.guid
  ui_stackResolve(Player[top.controller])
end

function Stack.offer()
  if offerScheduled then
    return
  end
  offerScheduled = true
  Wait.time(function()
    offerScheduled = false
    local ok, err = pcall(tryOffer)
    if not ok then
      Events.noteError("asking for responses", err)
    end
  end, 0.6)
end

-- YIELD: pass on everything until the stack is empty.
function ui_stackYield(player)
  local c = player.color
  if not TableSetup.isActive(c) or (Leave and Leave.isOut(c)) then
    return
  end
  GameState.data.yield = GameState.data.yield or {}
  GameState.data.yield[c] = not GameState.data.yield[c] or nil
  broadcastToAll(c .. (GameState.data.yield[c] and " yields: no responses until the stack is empty." or " stops yielding."), INFO)
  if GameState.data.yield[c] and Turns and Turns.yieldNow then
    Turns.yieldNow(c)
  end
end

-- RESOLVE ALL: resolve the top item, then the next, until the stack is empty or someone responds.
function ui_stackResolveAll(player)
  local c = player.color
  if not TableSetup.isActive(c) or Stack.isEmpty() or (Leave and Leave.isOut(c)) then
    return
  end
  Stack.autoResolve = c
  broadcastToAll(c .. " resolves the whole stack (one item at a time; I HAVE A RESPONSE stops it).", INFO)
  ui_stackResolve(player)
end

function ui_stackCounter(player)
  if TableSetup.isActive(player.color) and not (Leave and Leave.isOut(player.color)) then
    Stack.counterTop(player.color)
  end
end

function ui_stackRemove(player, r)
  if TableSetup.isActive(player.color) then
    Stack.removeRow(tonumber(r), player.color)
  end
end

---------------------------------------------------------------------------
-- Activated abilities ("{T}, Sacrifice ~: Search your library..."): one
-- right-click item per ability. The table pays the simple costs (tap the
-- card, sacrifice it, pay life), says which costs are yours to pay (mana,
-- discards...), and puts the effect on the stack; auto-resolve
-- (effects.lua) carries it out when it resolves. Mana abilities ("Add
-- {G}") and loyalty abilities (walkers.lua) aren't listed.
---------------------------------------------------------------------------

local function oracleOf(obj)
  local text, name = "", obj.getName()
  pcall(function()
    local d = JSON.decode(obj.getGMNotes())
    if type(d) == "table" then
      text = type(d.oracle) == "string" and d.oracle or ""
      name = d.name or name
    end
  end)
  -- Soulbond: the "paired with another creature" line isn't an ability of its own; while paired the
  -- creature has the quoted abilities it grants.
  if Soulbond and text:find("paired with another creature", 1, true) then
    local keep = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      if not line:find("paired with another creature", 1, true) then
        table.insert(keep, line)
      end
    end
    for _, a in ipairs(Soulbond.grantedLines(obj)) do
      table.insert(keep, a)
    end
    text = table.concat(keep, "\n")
  elseif Soulbond and Soulbond.partnerOf(obj) then
    for _, a in ipairs(Soulbond.grantedLines(obj)) do
      text = text .. "\n" .. a
    end
  end
  -- Abilities other permanents give it (Sliver lords...).
  if Statics and Statics.grants then
    local okg, g = pcall(Statics.grants, obj)
    if okg and g then
      for _, a in ipairs(g.lines) do
        text = text .. "\n" .. a
      end
    end
  end
  return text, name
end

local function splitLines(text)
  local out, i = {}, 1
  while i <= #text do
    local j = text:find("\n", i, true) or (#text + 1)
    table.insert(out, text:sub(i, j - 1))
    i = j + 1
  end
  return out
end

function Stack.activatedAbilities(obj)
  local text = oracleOf(obj)
  local list = {}
  local all = splitLines(text)
  for li, line in ipairs(all) do
    local colon = line:find(":", 1, true)
    -- A colon inside quotes is an ability the card GIVES (Thornbite Staff), not its own.
    local quote = line:find('"', 1, true)
    if quote and colon and quote < colon then
      colon = nil
    end
    -- A colon inside reminder text ("Ninjutsu {1}{U} ({1}{U}, Return an unblocked attacker...: Put...)")
    -- isn't an ability of its own (ninjutsu / sneak have their own menu items: combat.lua).
    local paren = line:find("(", 1, true)
    if paren and colon and paren < colon then
      colon = nil
    end
    if colon and colon <= 100 then
      local cost = line:sub(1, colon - 1)
      -- Ability word in front ("Boast — {1}{R}"): keep just the cost.
      -- (A literal dash: TTS's Lua sees it as one character, so no byte escapes.)
      local DASH = " — "
      local dash = cost:find(DASH, 1, true)
      if dash then
        cost = cost:sub(dash + #DASH)
      end
      local effect = line:sub(colon + 1):gsub("^%s+", "")
      -- "Choose one —" modes are the lines that follow.
      local nextLine = li + 1
      while all[nextLine] and all[nextLine]:find("^%s*•") do
        effect = effect .. "\n" .. all[nextLine]
        nextLine = nextLine + 1
      end
      local low = cost:lower()
      local isCost = low:find("{", 1, true) or low:find("sacrifice", 1, true) or low:find("pay ", 1, true)
        or low:find("discard", 1, true) or low:find("exile", 1, true) or low:find("remove", 1, true)
      local first = cost:sub(1, 1)
      local loyalty = first == "+" or cost == "0" or (not cost:find("{", 1, true) and #cost <= 4)
      local mana = effect:lower():sub(1, 4) == "add "
      if isCost and not loyalty and not mana then
        table.insert(list, { cost = cost, effect = effect, line = line })
      end
    end
  end
  -- Station (Spacecraft / Planets): "Tap another creature you control: put charge counters equal to its power".
  do
    local lowAll = text:lower()
    if lowAll:sub(1, 8) == "station " or lowAll:find("\nstation ", 1, true) or lowAll:sub(1, 8) == "station(" or lowAll:find("\nstation(", 1, true) then
      table.insert(list, { cost = "Tap another creature you control", effect = "Put charge counters equal to its power on this (Station, sorcery speed).",
        line = "Station", station = true })
    end
  end
  return list
end

local function seatOf(obj)
  local loc = Zones.regionAt(obj.getPosition())
  return loc.seat, loc.region
end

local function tappedNow(obj, seat)
  local s = TableSetup.seat(seat)
  if s == nil then
    return false
  end
  local diff = ((obj.getRotation().y - s.yaw + 540) % 360) - 180
  return math.abs(diff) > 30
end

-- The card itself is sacrificed: to its graveyard (a token goes away after).
local function sacrifice(obj, seat)
  if Triggers and Triggers.onSacrificed then
    pcall(Triggers.onSacrificed, obj, seat)
  end
  local s = TableSetup.seat(seat)
  obj.setLock(false)
  obj.setRotation({ 0, s.yaw, 0 })
  obj.setPosition(TableSetup.slot(seat, "graveyard", TableSetup.SURFACE_TOP + 2))
  Zones.refresh(obj)
  if obj.hasTag("Token") then
    Wait.time(function()
      if not obj.isDestroyed() then
        obj.destruct()
      end
    end, 1.5)
    return
  end
  Library.toGraveyard(seat, obj, function()
    if not obj.isDestroyed() then
      Zones.refresh(obj)
    end
  end)
end

function Stack.activate(obj, playerColor, ab)
  if obj == nil or obj.isDestroyed() then
    return
  end
  -- Split second on the stack: no activated abilities except mana abilities (CR 702.61a).
  local ss = Stack.splitSecond()
  if ss and not tostring(ab and ab.effect or ""):lower():find("^add ") then
    broadcastToColor(ss .. " has split second: no abilities (except mana abilities) until it resolves.", playerColor, WARN)
    return
  end
  -- "Activated abilities of ... can't be activated" (Forge static): warn, naming the source.
  if not ab.xDone and not ab.sacDone and Statics and Statics.cantActivate then
    local okA, src = pcall(Statics.cantActivate, obj, playerColor, false)
    if okA and src then
      broadcastToColor(obj.getName() .. ": its activated abilities can't be activated (" .. src .. ").", playerColor, WARN)
    end
  end
  if ab.station then
    local sseat, sregion = seatOf(obj)
    if not (sregion == "battlefield" or sregion == "lands") or (sseat ~= playerColor and not GameState.solo()) then
      broadcastToColor(obj.getName() .. " has to be on your battlefield to Station.", playerColor, WARN)
      return
    end
    Effects.station(obj, sseat or playerColor)
    return
  end
  local seat, region = seatOf(obj)
  if not (region == "battlefield" or region == "lands") then
    -- Off the battlefield only abilities that say so work ("Return this
    -- card from your graveyard...", "Exile this card from your hand...").
    if not ab.effect:lower():find("this card", 1, true) and not ab.cost:lower():find("this card", 1, true) then
      broadcastToColor(obj.getName() .. " has to be on the battlefield to do that.", playerColor, WARN)
      return
    end
    seat = playerColor
  end
  if seat ~= playerColor and not GameState.solo() then
    broadcastToColor("That's " .. tostring(seat) .. "'s card.", playerColor, WARN)
    return
  end
  local _, cardName = oracleOf(obj)
  local low = ab.cost:lower()
  -- {X} in the cost ("{X}, Remove X +1/+1 counters from Marath"): the player says X first.
  if not ab.xDone and (low:find("{x}", 1, true) or low:find("remove x ", 1, true)) and Effects and Effects.askNumber then
    Effects.askNumber(playerColor, obj.getName() .. ": what is X?", ab.cost .. "\nType X, then OK.", function(n)
      local function sub(text)
        local t2 = " " .. text:gsub("%s*X can't be 0%.", "") .. " "
        for _ = 1, 2 do
          t2 = t2:gsub("([^%a])[Xx]([^%a])", "%1" .. n .. "%2")
        end
        return (t2:gsub("^ ", ""):gsub(" $", ""))
      end
      local cost2 = ab.cost:gsub("{[Xx]}", "{" .. n .. "}")
      Stack.activate(obj, playerColor, { cost = sub(cost2), effect = sub(ab.effect), line = ab.line, xDone = true })
    end)
    return
  end
  local tap = low:find("{t}", 1, true) ~= nil
  if tap and tappedNow(obj, seat) then
    broadcastToColor(obj.getName() .. " is already tapped.", playerColor, WARN)
    return
  end
  local nameLow = tostring(cardName):lower()
  local sacSelf = low:find("sacrifice " .. nameLow, 1, true) ~= nil or low:find("sacrifice this", 1, true) ~= nil
    or low:find("sacrifice it", 1, true) ~= nil
  -- "Sacrifice a creature:" / "Sacrifice another creature or artifact:" - the player clicks what goes.
  if not ab.sacDone and not sacSelf and Effects and Effects.askChoice and low:find("sacrifice ", 1, true) then
    local kinds, other
    if low:find("sacrifice another creature or artifact", 1, true) then
      kinds, other = { creature = true, artifact = true }, true
    elseif low:find("sacrifice a creature or artifact", 1, true) then
      kinds = { creature = true, artifact = true }
    elseif low:find("sacrifice another creature", 1, true) then
      kinds, other = { creature = true }, true
    elseif low:find("sacrifice a creature", 1, true) then
      kinds = { creature = true }
    elseif low:find("sacrifice an artifact", 1, true) then
      kinds = { artifact = true }
    end
    if kinds then
      local what = (kinds.creature and "creature" or "") .. (kinds.creature and kinds.artifact and " or " or "") .. (kinds.artifact and "artifact" or "")
      Effects.askChoice(playerColor, obj.getName() .. ": sacrifice " .. (other and "another " or "a ") .. what,
        "Click SACRIFICE on the " .. what .. " you sacrifice to pay for " .. obj.getName() .. ".", { { label = "CANCEL", value = false } },
        function(victim)
          if not victim or victim.isDestroyed() then
            return
          end
          local pw = 0
          pcall(function() pw = tonumber(Counters.stats(victim).power) or 0 end)
          local vname = victim.getName()
          -- Birthing Pod: the effect needs the sacrificed creature's mana value.
          local vmv = 0
          pcall(function() vmv = tonumber(CardData.get(victim).cmc) or 0 end)
          GameState.data.lastSac = { seat = playerColor, mv = vmv, name = vname, at = os.time() }
          Combat.sacrifice(victim)
          local eff = ab.effect
          local lowE = eff:lower()
          local needle = "cards equal to the sacrificed creature's power"
          local at = lowE:find(needle, 1, true)
          if at then
            eff = eff:sub(1, at - 1) .. pw .. " cards" .. eff:sub(at + #needle)
          end
          Stack.activate(obj, playerColor, { cost = ab.cost, effect = eff, line = ab.line, xDone = ab.xDone, sacDone = true,
            sacName = vname, remDone = ab.remDone })
        end, { filter = function(o, owner)
          if owner ~= seat or (other and o == obj) then
            return false
          end
          local ty = Effects.cardTypes(o)
          return (kinds.creature and ty.creature == true) or (kinds.artifact and ty.artifact == true)
        end, label = "SACRIFICE", protect = false })
      return
    end
  end
  -- "Remove a counter from another permanent you control" (Xavier Sal).
  if not ab.remDone and low:find("remove a counter from another permanent", 1, true) and Effects and Effects.askChoice then
    Effects.askChoice(playerColor, obj.getName() .. ": remove a counter", "Click the permanent you control to take a counter off.",
      { { label = "CANCEL", value = false } }, function(src)
        if not src or src.isDestroyed() then
          return
        end
        local c = Counters.get(src)
        local kinds = {}
        for _, k in ipairs({ "plus", "minus", "loyalty", "other", "pc", "tc" }) do
          if (c[k] or 0) > 0 then
            table.insert(kinds, k)
          end
        end
        local NAMES = { plus = "+1/+1", minus = "-1/-1", loyalty = "loyalty", other = "other" }
        local function go(k)
          Counters.change(src, k, -1, playerColor)
          Stack.activate(obj, playerColor, { cost = ab.cost, effect = ab.effect, line = ab.line, xDone = ab.xDone, sacDone = ab.sacDone,
            sacName = ab.sacName, remDone = true, remName = src.getName() .. " (" .. NAMES[k] .. ")" })
        end
        if #kinds == 1 then
          go(kinds[1])
        else
          local choices = {}
          for _, k in ipairs(kinds) do
            table.insert(choices, { label = string.upper(NAMES[k]), value = k })
          end
          Effects.askChoice(playerColor, src.getName() .. ": which counter?", "Remove one of these.", choices, go)
        end
      end, { filter = function(o, owner)
        if owner ~= seat or o == obj then
          return false
        end
        local c = Counters.get(o)
        return (c.plus or 0) > 0 or (c.minus or 0) > 0 or (c.loyalty or 0) > 0 or (c.other or 0) > 0 or (c.pc or 0) > 0 or (c.tc or 0) > 0
      end, label = "REMOVE", protect = false })
    return
  end
  -- "Remove three quest counters from ~": check there are enough, take them off.
  local remWord, remKind = low:match("remove (%w+) ([%w%+/%-]+) counters? from")
  local NUM = { a = 1, an = 1, one = 1, two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, nine = 9, ten = 10 }
  local remN = remWord and (tonumber(remWord) or NUM[remWord])
  local remKey
  if remN then
    remKey = (remKind == "+1/+1" and "plus") or (remKind == "-1/-1" and "minus") or (remKind == "loyalty" and "loyalty")
      or "other"
    local have = Counters.get(obj)[remKey] or 0
    if have < remN then
      broadcastToColor(obj.getName() .. " has only " .. have .. " " .. remKind .. " counter" .. (have == 1 and "" or "s")
        .. " (needs " .. remN .. ").", playerColor, WARN)
      return
    end
  end
  local paid, yours = {}, {}
  if tap then
    local r = obj.getRotation()
    obj.setRotationSmooth({ r.x, (TableSetup.seat(seat).yaw + 90) % 360, r.z }, false, true)
    table.insert(paid, "tapped it")
    if Triggers and Triggers.onTapped then
      pcall(Triggers.onTapped, obj, seat)
    end
  end
  if remN then
    Counters.change(obj, remKey, -remN, playerColor)
    table.insert(paid, "removed " .. remN .. " " .. remKind .. " counters")
  end
  local life = tonumber(low:match("pay (%d+) life") or "")
  if life then
    Trackers.changeLife(seat, -life, cardName)
    table.insert(paid, "paid " .. life .. " life")
  end
  -- What's left for the player: mana symbols and other costs.
  local rest = low:gsub("{t}", ""):gsub("pay %d+ life", "")
  if remN then
    rest = rest:gsub("remove %w+ [%w%+/%-]+ counters? from [^,]*", "")
  end
  if sacSelf then
    rest = rest:gsub("sacrifice this %a+", ""):gsub("sacrifice it", ""):gsub("sacrifice " .. nameLow:gsub("([%%%-%.%+%*%?%[%]%^%$%(%)])", "%%%1"), "")
  end
  if ab.sacDone then
    for _, ph in ipairs({ "sacrifice another creature or artifact", "sacrifice a creature or artifact", "sacrifice another creature",
        "sacrifice a creature", "sacrifice an artifact" }) do
      local i, j = rest:find(ph, 1, true)
      if i then
        rest = rest:sub(1, i - 1) .. rest:sub(j + 1)
        break
      end
    end
    table.insert(paid, "sacrificed " .. tostring(ab.sacName))
  end
  if ab.remDone then
    rest = rest:gsub("remove a counter from another permanent you control", ""):gsub("remove a counter from another permanent", "")
    table.insert(paid, "removed a counter from " .. tostring(ab.remName))
  end
  if rest:find("{", 1, true) then
    -- Mana in the pool pays for it; anything the pool can't cover is still yours to pay.
    local _, covered
    if ManaChips and ManaChips.pay then
      _, covered = ManaChips.pay(seat, rest, obj.getName())
    end
    if not covered then
      table.insert(yours, "the mana")
    end
  end
  for _, word in ipairs({ "discard", "sacrifice", "exile", "remove" }) do
    if rest:find(word, 1, true) then
      table.insert(yours, word .. " (see the cost)")
    end
  end
  local face = ""
  pcall(function()
    for _, d in pairs(obj.getData().CustomDeck or {}) do
      face = d.FaceURL
      break
    end
  end)
  Stack.pushAbility(seat, obj.getName(), ab.effect, face, { activated = true, source = obj.getGUID() })
  if sacSelf then
    table.insert(paid, "sacrificed it")
    sacrifice(obj, seat)
  end
  log(seat .. " activates " .. obj.getName() .. " (" .. ab.cost .. ")"
    .. (#paid > 0 and ("; " .. table.concat(paid, ", ")) or "") .. ".")
  if #yours > 0 then
    broadcastToColor("Pay the rest of the cost yourself: " .. table.concat(yours, ", ") .. ".", playerColor, INFO)
  end
end

-- Right-click on a card: put one of its abilities on the stack.
-- Cycling: "Cycling {2}" (discard it, draw a card) or typecycling ("Basic landcycling {1}",
-- "Plainscycling {2}", "Wizardcycling {3}": discard it, search for that card type). Returns
-- { cost, search } or nil.
function Stack.cyclingOf(obj)
  local text = oracleOf(obj)
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local low = (Triggers and Triggers.stripReminder and Triggers.stripReminder(line) or line):lower()
    local a = low:find("cycling ", 1, true)
    if a and not low:find(":", 1, true) then
      local pre = low:sub(1, a - 1):gsub("^%s+", ""):gsub("%s+$", "")
      local cost = low:sub(a + 8):match("^(%S+)")
      -- Only the keyword line itself ("Cycling {2}", "Basic landcycling {1}"), not text about cycling.
      if cost and cost:sub(1, 1) == "{" and #pre < 20 and not pre:find("whenever", 1, true) then
        return { cost = cost, search = pre ~= "" and pre or nil }
      end
    end
  end
  return nil
end

-- Cycle a card from its owner's hand: pay, discard it, then draw (or search, for typecycling).
function Stack.cycle(obj, playerColor)
  local cy = Stack.cyclingOf(obj)
  if cy == nil or obj == nil or obj.isDestroyed() then
    return
  end
  local seat
  for _, c in ipairs(TableSetup.activeSeats()) do
    for _, h in ipairs(Player[c].getHandObjects() or {}) do
      if h == obj then
        seat = c
      end
    end
  end
  if seat == nil then
    broadcastToColor(obj.getName() .. " has to be in your hand to cycle it.", playerColor, WARN)
    return
  end
  if seat ~= playerColor and not GameState.solo() then
    broadcastToColor("That's " .. seat .. "'s card.", playerColor, WARN)
    return
  end
  local name = obj.getName()
  if ManaChips and ManaChips.pay then
    ManaChips.pay(seat, cy.cost, name .. " (cycling)")
  end
  -- Cycle triggers first, while the card can still be read (it merges into the graveyard pile).
  if Triggers and Triggers.onCycled then
    pcall(Triggers.onCycled, obj, seat)
  end
  local s = TableSetup.seat(seat)
  obj.setRotation({ 0, s.yaw, 0 })
  obj.setPosition(TableSetup.slot(seat, "graveyard", TableSetup.SURFACE_TOP + 2))
  Zones.refresh(obj)          -- hand -> graveyard: "whenever you discard a card" sees it
  Library.toGraveyard(seat, obj)
  if cy.search then
    printToAll("MTG > " .. seat .. " cycles " .. name .. " (" .. cy.search .. "cycling " .. cy.cost .. "): search for a "
      .. cy.search .. " card.", INFO)
    LibSearch.open(seat, cy.search, name .. ": take a " .. cy.search .. " card into your hand, then CLOSE + SHUFFLE.", "hand",
      false, { typeOnly = true })
  else
    printToAll("MTG > " .. seat .. " cycles " .. name .. " (" .. cy.cost .. ") and draws a card.", INFO)
    Wait.time(function() Actions.draw(seat, 1, name .. " (cycling)") end, 0.4)
  end
end

-- An alternative cost, cast from the hand: "If it's not your turn, you may exile a green card from your hand
-- rather than pay this spell's mana cost" (Force of Vigor), "You may pay 1 life and exile a blue card from your
-- hand rather than pay this spell's mana cost" (Force of Will). Returns { text, life, exile (color word),
-- notMyTurn, rest } or nil. rest = parts of the cost the table doesn't pay for you.
local COLOR_WORDS = { white = "W", blue = "U", black = "B", red = "R", green = "G" }
function Stack.altCostOf(obj)
  local low = string.lower(tostring(oracleOf(obj) or ""))
  local key = "rather than pay this spell's mana cost"
  local e = string.find(low, key, 1, true)
  if not e then
    return nil
  end
  -- The sentence it's in: back to the last period or line break.
  local head = string.sub(low, 1, e - 1)
  local st = 1
  for i = #head, 1, -1 do
    local ch = string.sub(head, i, i)
    if ch == "." or ch == "\n" then
      st = i + 1
      break
    end
  end
  local sentence = string.sub(head, st)
  local ym = string.find(sentence, "you may ", 1, true)
  if not ym then
    return nil
  end
  local pre = string.sub(sentence, 1, ym - 1)
  local cost = string.gsub(string.sub(sentence, ym + 8), "%s+$", "")
  local alt = { text = cost, notMyTurn = string.find(pre, "not your turn", 1, true) ~= nil, rest = {} }
  local list = string.gsub(string.gsub(cost, " and ", ","), ", ", ",")
  for part in string.gmatch(list .. ",", "([^,]+),") do
    local life = string.match(part, "^%s*pay (%d+) life%s*$")
    local col = string.match(part, "^%s*exile an? (%a+) card from your hand%s*$")
    if life then
      alt.life = tonumber(life)
    elseif col and COLOR_WORDS[col] then
      alt.exile = col
    elseif string.find(part, "%S") then
      table.insert(alt.rest, part)
    end
  end
  return alt
end

local function cardColors(o)
  local set = {}
  pcall(function()
    local d = JSON.decode(o.getGMNotes())
    for _, c in ipairs(type(d) == "table" and d.colors or {}) do
      set[tostring(c)] = true
    end
  end)
  return set
end

-- Cast it for the alternative cost: pay the life, pick the card to exile from the hand, then it goes on
-- the stack without its mana cost coming out of the pool.
function Stack.castAlt(obj, playerColor)
  local alt = Stack.altCostOf(obj)
  if alt == nil or obj.isDestroyed() then
    return
  end
  local seat = (Zones.handOwner and Zones.handOwner(obj)) or playerColor
  if not TableSetup.isActive(seat) or (seat ~= playerColor and not GameState.solo()) then
    broadcastToColor("That card is in " .. tostring(seat) .. "'s hand.", playerColor, WARN)
    return
  end
  local name = obj.getName()
  if alt.notMyTurn and Turns and Turns.isActiveSeat and Turns.isActiveSeat(seat) then
    broadcastToColor(name .. ": the alternative cost is only for when it's NOT your turn.", seat, WARN)
    return
  end
  local function go()
    if obj.isDestroyed() then
      return
    end
    if alt.life and alt.life > 0 then
      Trackers.changeLife(seat, -alt.life, seat)
    end
    if #alt.rest > 0 then
      broadcastToColor(name .. ": also pay this part of the cost yourself: " .. table.concat(alt.rest, ", ") .. ".", seat, INFO)
    end
    printToAll("MTG > " .. seat .. " casts " .. name .. " for its alternative cost (" .. alt.text .. ").", INFO)
    GameState.data.freeCast = GameState.data.freeCast or {}
    GameState.data.freeCast[obj.getGUID()] = true
    Stack.pushCard(obj, seat, { seat = seat, region = "hand" })
  end
  if not alt.exile then
    go()
    return
  end
  local key = COLOR_WORDS[alt.exile]
  local choices = {}
  local ok, hand = pcall(function() return Player[seat].getHandObjects() end)
  for _, o in ipairs(ok and hand or {}) do
    if o ~= obj and o.type == "Card" and cardColors(o)[key] and #choices < 6 then
      table.insert(choices, { label = o.getName():sub(1, 22), value = o.getGUID() })
    end
  end
  if #choices == 0 then
    broadcastToColor(name .. ": you have no other " .. alt.exile .. " card in your hand to exile.", seat, WARN)
    return
  end
  table.insert(choices, { label = "CANCEL", value = false })
  Effects.askChoice(seat, name .. ": alternative cost", "Pick the " .. alt.exile .. " card to exile from your hand"
    .. (alt.life and (" (you also pay " .. alt.life .. " life)") or "") .. ".", choices, function(g)
      local o = g and getObjectFromGUID(g)
      if not o or o.isDestroyed() then
        return
      end
      local s = TableSetup.seat(seat)
      o.setRotation({ 0, s.yaw, 0 })
      o.setPosition(TableSetup.slot(seat, "exile", TableSetup.SURFACE_TOP + 2))
      Wait.time(function() Zones.refresh(o) end, 0.6)
      printToAll("MTG > " .. seat .. " exiles " .. o.getName() .. " from their hand (" .. name .. ").", INFO)
      go()
    end)
end

function Stack.addCardMenu(obj, full)
  -- An alternative cost (Force of Will), from the hand.
  local okAlt, hasAlt = pcall(function() return Zones.handOwner(obj) ~= nil and Stack.altCostOf(obj) ~= nil end)
  if not full and okAlt and hasAlt then
    obj.addContextMenuItem("Cast: alternative cost", function(playerColor)
      Stack.castAlt(obj, playerColor)
    end)
  end
  -- Cycling, from the hand.
  local cy = Stack.cyclingOf(obj)
  if cy then
    obj.addContextMenuItem("Cycle (" .. cy.cost .. ")", function(playerColor)
      Stack.cycle(obj, playerColor)
    end)
  end
  for _, ab in ipairs(Stack.activatedAbilities(obj)) do
    local label = "Activate: " .. ab.cost
    if #label > 38 then
      label = label:sub(1, 36) .. ".."
    end
    obj.addContextMenuItem(label, function(playerColor)
      Stack.activate(obj, playerColor, ab)
    end)
  end
  if not full then
    return   -- off the battlefield only the Activate items apply
  end
  -- Prepared (Studious First-Year): cast the copy of its prepare spell.
  local part = Effects and Effects.preparedPart and Effects.preparedPart(obj)
  if part then
    local label = "Cast prepared: " .. tostring(part.name)
    if #label > 38 then
      label = label:sub(1, 36) .. ".."
    end
    obj.addContextMenuItem(label, function(playerColor)
      Effects.castPrepared(obj, playerColor)
    end)
  end
  -- Treasure, Lotus Petal: a mana ability (no stack).
  if ManaChips and ManaChips.isSacMana and ManaChips.isSacMana(obj) then
    obj.addContextMenuItem(ManaChips.sacManaLabel and ManaChips.sacManaLabel(obj) or "Sacrifice for mana", function(playerColor)
      local seat = seatOf(obj) or playerColor
      ManaChips.sacForMana(obj, seat)
    end)
  end
  obj.addContextMenuItem("Ability to stack", function(playerColor)
    local face = ""
    pcall(function()
      for _, d in pairs(obj.getData().CustomDeck or {}) do
        face = d.FaceURL
        break
      end
    end)
    -- Rules text from GM Notes (decoded; patterns can't scan long text).
    local text = obj.getDescription()
    pcall(function()
      local d = JSON.decode(obj.getGMNotes())
      if type(d) == "table" and type(d.oracle) == "string" and d.oracle ~= "" then
        text = d.oracle
      end
    end)
    Stack.pushAbility(playerColor, obj.getName(), text, face)
  end)
end
