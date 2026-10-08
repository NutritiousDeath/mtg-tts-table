--[[
  stack.lua
  Phase 5: the stack. A STACK mat sits in the middle of the table.

    Casting: drop a card on the mat, or on your own CAST mat just above your
      life tracker (easier to reach). It goes on top of the stack, laid out
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
      UI.setValue("stackText_" .. r, (r == 1 and "TOP  " or (i .. ".  ")) .. it.name .. tag .. "  -  " .. it.controller)
    end
  end
  UI.setAttribute("stackPanel", "height", 90 + shown * 31)
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
  table.insert(items(), { guid = obj.getGUID(), kind = "card", name = obj.getName(), controller = controller })
  log(controller .. " casts " .. obj.getName() .. " (on the stack).")
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
function Stack.pushAbility(controller, sourceName, text, image, opts)
  opts = opts or {}
  local label = opts.trigger and "TRIGGER" or "ABILITY"
  local pos = { MAT.x, TableSetup.SURFACE_TOP + 1, MAT.z }
  local obj = spawnObject({
    type = "Custom_Token",
    position = pos,
    rotation = { 0, MAT_YAW, 0 },
    sound = false,
    callback_function = function(o)
      o.setName(sourceName .. (opts.trigger and " (trigger)" or " (ability)"))
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
          tooltip = sourceName .. "\n" .. tostring(text or ""), width = 900, height = 160, font_size = 120,
          color = { 0.04, 0.06, 0.1, 0.9 }, font_color = { 0.35, 0.95, 1 } }, 0, -1.3)
        Stack.layout()
      end, function() return o.isDestroyed() or not o.loading_custom end, 10)
    end,
  })
  obj.setCustomObject({ image = (image and image ~= "") and image or (ART_BASE .. "ability.png" .. ART_VERSION),
    thickness = 0.1, merge_distance = 5, stackable = false })
  -- On the list right away (not when the picture has loaded), so the turn
  -- can't move on in the meantime.
  table.insert(items(), { guid = obj.getGUID(), kind = "ability", name = sourceName, controller = controller,
    text = text, trigger = opts.trigger, that = opts.that, source = opts.source, thatCard = opts.thatCard,
    amount = opts.amount,
    auto = (opts.trigger or opts.loyalty or opts.activated) and true or nil })
  Stack.render()
  if opts.trigger then
    log(sourceName .. " triggers (" .. controller .. "): " .. tostring(text or ""))
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
function Stack.resolveTop()
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
    -- Carry out what it says, when the table can (effects.lua).
    if Effects then
      Effects.resolve(it)
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
    log(it.name .. " resolves (to " .. it.controller .. "'s graveyard).")
    -- Read its text before it merges into the graveyard pile.
    local keep = false
    if Effects and Effects.resolveSpell then
      keep = Effects.resolveSpell(obj, it.controller) == true
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
    log(it.name .. " resolves (onto " .. it.controller .. "'s battlefield).")
    sendCard(obj, it, "battlefield")
  end
end

function Stack.counterTop(byColor)
  local list = items()
  local it = list[#list]
  if it == nil then
    return
  end
  local obj = getObjectFromGUID(it.guid)
  removeAt(#list)
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

function Stack.onDrop(color, obj)
  if obj == nil or color == nil then
    return
  end
  dropper[obj.getGUID()] = color
  -- Dropped on a seat's CAST mat: put it on the stack in the middle. Where
  -- it came from (for commander tax) is known from when it was picked up.
  local from = Zones.locationOf(obj)
  Wait.time(function()
    if obj.isDestroyed() or obj.held_by_color or obj.type ~= "Card" then
      return
    end
    for _, seat in ipairs(TableSetup.activeSeats()) do
      if TableSetup.inRegion(seat, "castzone", obj.getPosition()) then
        -- The CAST mat's seat is the caster (whoever's hand it came from).
        Stack.pushCard(obj, seat, from)
        return
      end
    end
  end, 0.5)
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
  for _, color in ipairs(TableSetup.activeSeats()) do
    table.insert(wanted, { key = color, color = color, region = "castzone", name = "Cast (" .. color .. ")",
      url = ART_BASE .. "cast_" .. color .. ".png" .. ART_VERSION, width = 13, draw = function() end })
  end
  Trackers.syncTiles("CastZone", { { registry = reg.castTiles, wanted = wanted } })
end

-- The mat itself: one image tile in the middle of the table.
function Stack.ensure()
  ensureCastMats()
  local reg = data()
  reg.mat = reg.mat
  local mat = reg.mat and getObjectFromGUID(reg.mat)
  local url = ART_BASE .. "stack_mat.png" .. ART_VERSION
  local co = mat and mat.getCustomObject()
  if mat and co and co.image == url then
    mat.setLock(true)
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
  if not TableSetup.isActive(who) then
    return
  end
  local what = it.name .. (it.kind == "ability" and "'s ability" or "")
  if GameState.data.started and Turns.ask then
    Turns.ask(who, who .. " wants to resolve " .. what .. ".", "RESOLVE " .. string.upper(it.name), function()
      -- Still the same top item? (Something may have been added meanwhile.)
      local now = items()
      if now[#now] and now[#now].guid == it.guid then
        Stack.resolveTop()
      end
    end)
  else
    Stack.resolveTop()
  end
end

function ui_stackCounter(player)
  if TableSetup.isActive(player.color) then
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
  for _, line in ipairs(splitLines(text)) do
    local colon = line:find(":", 1, true)
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
  local tap = low:find("{t}", 1, true) ~= nil
  if tap and tappedNow(obj, seat) then
    broadcastToColor(obj.getName() .. " is already tapped.", playerColor, WARN)
    return
  end
  local nameLow = tostring(cardName):lower()
  local sacSelf = low:find("sacrifice " .. nameLow, 1, true) ~= nil or low:find("sacrifice this", 1, true) ~= nil
    or low:find("sacrifice it", 1, true) ~= nil
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
  if rest:find("{", 1, true) then
    table.insert(yours, "the mana")
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
function Stack.addCardMenu(obj, full)
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
