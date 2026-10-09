--[[
  library.lua
  Helpers for each seat's library (the face-down deck in its library area).

    Library.find(color)              the library deck at that seat, or nil
    Library.returnCards(color, objs) put cards/piles into that library (on top)
    Library.putOnBottom(color, cards, onDone)
                                     put cards on the BOTTOM of the library,
                                     in the given order
    Library.gatherTable(color)       every card that belongs back in this
                                     seat's library before a game: its hand,
                                     battlefield, lands, graveyard and exile
                                     (commanders excluded)
    Library.draw(color, n)           deal the top n cards to that player's hand
    Library.mill(color, n, index)    top n cards (or the one at depth index,
                                     0 = top) face up onto the graveyard
    Library.moveToBottom(color, index, onDone)
                                     card at depth index (0 = top) to the bottom
    Library.peek(color, index)       { name, face } of the card at depth index
    Library.arrangeTop(color, choices, onDone)
                                     scry / surveil the top #choices cards at
                                     once: choices[i] = "top" | "bottom" |
                                     "grave" for the i-th card from the top

  The library is found by position (the library rectangle from table.lua), so
  it works even after the deck object is replaced.
--]]

Library = {}

local function isPile(obj)
  return obj ~= nil and not obj.isDestroyed() and (obj.type == "Deck" or obj.type == "Card")
end

-- Tokens (tagged "Token") are never library cards: Start Game / mulligans
-- leave them where they are.
local function isToken(obj)
  return obj.hasTag ~= nil and obj.hasTag("Token")
end

local function hasKey(t, k)
  return t[k] ~= nil or t[tostring(k)] ~= nil or (tonumber(k) ~= nil and t[tonumber(k)] ~= nil)
end

local function regionOf(obj)
  return Zones.regionAt(obj.getPosition())
end

-- The library at a seat: the biggest deck (or a lone card) in its library area.
function Library.find(color)
  local best, bestCount = nil, -1
  for _, obj in ipairs(getObjects()) do
    if isPile(obj) and obj.held_by_color == nil then
      local loc = regionOf(obj)
      if loc.seat == color and loc.region == "library" then
        local count = obj.type == "Deck" and #obj.getObjects() or 1
        if count > bestCount then
          best, bestCount = obj, count
        end
      end
    end
  end
  return best
end

-- Every pile (deck or lone card) in a seat's library area, top first
-- (highest on the table first).
local function libraryPiles(color)
  local list = {}
  for _, obj in ipairs(getObjects()) do
    if isPile(obj) and obj.held_by_color == nil and not isToken(obj) then
      local loc = regionOf(obj)
      if loc.seat == color and loc.region == "library" then
        table.insert(list, obj)
      end
    end
  end
  table.sort(list, function(a, b) return a.getPosition().y > b.getPosition().y end)
  return list
end

-- Cards counted across every pile in the library area.
function Library.count(color)
  local n = 0
  for _, obj in ipairs(libraryPiles(color)) do
    n = n + (obj.type == "Deck" and #obj.getObjects() or 1)
  end
  return n
end

-- A card put on top of the library sometimes stays a separate pile instead
-- of joining the deck (then a draw took the card under it). Before drawing,
-- milling, scrying or putting on the bottom, any loose piles in the library
-- area are joined into one deck, keeping them on top in the order they sit
-- (highest = top). onDone(deck or nil) runs once it's one pile.
function Library.consolidate(color, onDone)
  local piles = libraryPiles(color)
  if #piles <= 1 then
    if onDone then onDone(piles[1]) end
    return
  end
  -- The biggest pile is the library; everything above it goes on top.
  local main, mainCount = nil, -1
  for _, obj in ipairs(piles) do
    local c = obj.type == "Deck" and #obj.getObjects() or 1
    if c > mainCount then
      main, mainCount = obj, c
    end
  end
  local objs, ids, custom = {}, {}, {}
  local function addCard(cd)
    table.insert(objs, cd)
    table.insert(ids, cd.CardID)
    for k, v in pairs(cd.CustomDeck or {}) do
      if not hasKey(custom, k) then
        custom[k] = v
      end
    end
  end
  local function addPile(obj)
    local d = obj.getData()
    if obj.type == "Deck" then
      for _, cd in ipairs(d.ContainedObjects or {}) do
        addCard(cd)
      end
      for k, v in pairs(d.CustomDeck or {}) do
        if not hasKey(custom, k) then
          custom[k] = v
        end
      end
    else
      addCard(d)
    end
  end
  for _, obj in ipairs(piles) do
    if obj ~= main then
      addPile(obj)
    end
  end
  addPile(main)
  local data = main.type == "Deck" and main.getData() or {
    Name = "Deck", Nickname = color .. " Library",
    Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 180, rotZ = 180, scaleX = 1, scaleY = 1, scaleZ = 1 },
  }
  data.ContainedObjects, data.DeckIDs, data.CustomDeck = objs, ids, custom
  local pos, rot = main.getPosition(), main.getRotation()
  for _, obj in ipairs(piles) do
    if Zones.forget then
      Zones.forget(obj.getGUID())
    end
    obj.destruct()
  end
  spawnObjectData({ data = data, position = pos, rotation = { rot.x, rot.y, 180 },
    callback_function = function(obj)
      obj.setName(color .. " Library")
      if onDone then onDone(obj) end
    end })
end

-- Commander card GUIDs of every seat (never shuffled into a library).
local function commanderGuids()
  local set = {}
  for _, p in pairs(GameState.data.players) do
    for _, guid in pairs(p.commanders or {}) do
      set[guid] = true
    end
  end
  return set
end

-- Areas whose cards go back into the library when a game (re)starts.
local GATHER = { battlefield = true, lands = true, graveyard = true, exile = true }

function Library.gatherTable(color)
  local lib = Library.find(color)
  local skip = commanderGuids()
  local found, seen = {}, {}
  local libGuid = lib and lib.getGUID()
  local function add(obj)
    if isPile(obj) and not isToken(obj) and obj.getGUID() ~= libGuid and not skip[obj.getGUID()]
        and not seen[obj.getGUID()] then
      seen[obj.getGUID()] = true
      table.insert(found, obj)
    end
  end
  for _, obj in ipairs(Player[color].getHandObjects() or {}) do
    add(obj)
  end
  for _, obj in ipairs(getObjects()) do
    if isPile(obj) and obj.held_by_color == nil then
      local loc = regionOf(obj)
      if loc.seat == color and GATHER[loc.region] then
        add(obj)
      end
    end
  end
  return found
end

-- Put cards (or whole piles) into the library. Returns how many objects moved.
function Library.returnCards(color, objs)
  local lib = Library.find(color)
  if lib == nil then
    return 0
  end
  local moved = 0
  local libGuid = lib.getGUID()
  for _, obj in ipairs(objs) do
    if isPile(obj) and obj.getGUID() ~= libGuid then
      lib.putObject(obj)
      moved = moved + 1
    end
  end
  return moved
end

-- Put cards on the bottom of the library. TTS can only add to the top of a
-- deck, so the deck is rebuilt from its data with the cards added at the end
-- (the end of a deck's card list is its bottom).
function Library.putOnBottom(color, cards, onDone)
  if #libraryPiles(color) > 1 then
    Library.consolidate(color, function() Library.putOnBottom(color, cards, onDone) end)
    return
  end
  local lib = Library.find(color)
  if lib == nil or lib.type ~= "Deck" then
    -- No deck to rebuild (empty or a single card): just add on top.
    if lib ~= nil then
      Library.returnCards(color, cards)
    end
    if onDone then onDone(lib) end
    return
  end

  local data = lib.getData()
  data.ContainedObjects = data.ContainedObjects or {}
  data.DeckIDs = data.DeckIDs or {}
  data.CustomDeck = data.CustomDeck or {}
  for _, card in ipairs(cards) do
    if isPile(card) and card.type == "Card" then
      local cd = card.getData()
      table.insert(data.ContainedObjects, cd)
      table.insert(data.DeckIDs, cd.CardID)
      for k, v in pairs(cd.CustomDeck or {}) do
        if not hasKey(data.CustomDeck, k) then
          data.CustomDeck[k] = v
        end
      end
      if Zones.forget then
        Zones.forget(card.getGUID())
      end
      card.destruct()
    end
  end

  local pos, rot = lib.getPosition(), lib.getRotation()
  lib.destruct()
  spawnObjectData({
    data = data,
    position = pos,
    rotation = rot,
    callback_function = function(obj)
      if onDone then onDone(obj) end
    end,
  })
end

---------------------------------------------------------------------------
-- Draw, mill, scry helpers
---------------------------------------------------------------------------

-- The pile (deck or lone card) in one of a seat's areas, ignoring `except`.
function Library.pileIn(color, region, except)
  local skip = except and except.getGUID()
  for _, obj in ipairs(getObjects()) do
    if isPile(obj) and obj.held_by_color == nil and obj.getGUID() ~= skip then
      local loc = regionOf(obj)
      if loc.seat == color and loc.region == region then
        return obj
      end
    end
  end
  return nil
end

function Library.draw(color, n, onDone)
  -- A revealed card waiting beside the library goes on top before anything is drawn.
  local rt = GameState.data.revealedTop
  if rt and rt[color] and Library.revealedCard(color) then
    Library.putRevealedOnTop(color, function()
      Wait.time(function()
        local drawn = Library.draw(color, n)
        if onDone then onDone(drawn) end
      end, 0.8)
    end)
    return 0
  end
  if #libraryPiles(color) > 1 then
    Library.consolidate(color, function()
      local drawn = Library.draw(color, n)
      if onDone then onDone(drawn) end
    end)
    return 0
  end
  local lib = Library.find(color)
  if lib == nil then
    broadcastToColor("Your library is empty.", color, { 1, 0.6, 0.2 })
    if onDone then onDone(0) end
    return 0
  end
  local count = lib.type == "Deck" and #lib.getObjects() or 1
  n = math.min(n, count)
  if lib.type == "Deck" then
    lib.deal(n, color)
  else
    local hand = Player[color].getHandTransform()
    lib.setPositionSmooth(hand.position, false, true)
  end
  if onDone then onDone(n) end
  return n
end

-- Put a card onto the seat's graveyard pile (it lands there first, then
-- merges so the graveyard stays one searchable pile).
local function toGraveyard(color, card, onDone)
  Wait.time(function()
    if card ~= nil and not card.isDestroyed() then
      local gy = Library.pileIn(color, "graveyard", card)
      if gy then
        pcall(function() gy.putObject(card) end)
      end
    end
    if onDone then onDone() end
  end, 0.4)
end

Library.toGraveyard = toGraveyard

-- Mill n cards from the top, one at a time (index = take from that depth
-- instead of the top; used by surveil).
function Library.mill(color, n, index, onDone)
  if #libraryPiles(color) > 1 then
    Library.consolidate(color, function() Library.mill(color, n, index, onDone) end)
    return
  end
  local s = TableSetup.seat(color)
  local done = 0
  local function step()
    if done >= n then
      if onDone then onDone(done) end
      return
    end
    local lib = Library.find(color)
    if lib == nil then
      if onDone then onDone(done) end
      return
    end
    done = done + 1
    local pos = TableSetup.slot(color, "graveyard", 2 + done * 0.3)
    local rot = { 0, s.yaw, 0 }   -- face up
    if lib.type == "Deck" then
      lib.takeObject({ index = index or 0, position = pos, rotation = rot, smooth = false,
        callback_function = function(card) toGraveyard(color, card, step) end })
    else
      lib.setPosition(pos)
      lib.setRotation(rot)
      toGraveyard(color, lib, step)
    end
  end
  step()
end

-- The card at depth index (0 = top) without moving it: name and face image.
function Library.peek(color, index)
  local lib = Library.find(color)
  if lib == nil then
    return nil
  end
  local data = lib.getData()
  local entry = lib.type == "Deck" and (data.ContainedObjects or {})[index + 1] or (index == 0 and data or nil)
  if entry == nil then
    return nil
  end
  local face
  for _, d in pairs(entry.CustomDeck or {}) do
    face = d.FaceURL
    break
  end
  local total = lib.type == "Deck" and #(data.ContainedObjects or {}) or 1
  return { name = entry.Nickname or "Card", face = face, total = total }
end

-- Move the card at depth index (0 = top) to the bottom (rebuilds the deck,
-- the same way as putOnBottom).
function Library.moveToBottom(color, index, onDone)
  local lib = Library.find(color)
  if lib == nil or lib.type ~= "Deck" then
    if onDone then onDone(lib) end
    return
  end
  local data = lib.getData()
  local objs, ids = data.ContainedObjects or {}, data.DeckIDs or {}
  if index + 1 > #objs then
    if onDone then onDone(lib) end
    return
  end
  local entry = table.remove(objs, index + 1)
  local id = table.remove(ids, index + 1)
  table.insert(objs, entry)
  table.insert(ids, id)
  local pos, rot = lib.getPosition(), lib.getRotation()
  lib.destruct()
  spawnObjectData({ data = data, position = pos, rotation = rot,
    callback_function = function(obj) if onDone then onDone(obj) end end })
end

-- Exile cards from the top of a library: until a nonland card is exiled
-- (Etali, Primal Conqueror), or just the top card (onlyOne). Calls
-- onDone(nonland card or nil, all exiled cards).
function Library.exileUntilNonland(color, onlyOne, onDone, accept)
  if #libraryPiles(color) > 1 then
    Library.consolidate(color, function() Library.exileUntilNonland(color, onlyOne, onDone, accept) end)
    return
  end
  local s = TableSetup.seat(color)
  local count, found, exiled = 0, nil, {}
  local function finish()
    if onDone then onDone(found, exiled) end
  end
  local function step()
    local lib = Library.find(color)
    if lib == nil then
      finish()
      return
    end
    count = count + 1
    local pos = TableSetup.slot(color, "exile", 2 + count * 0.3)
    local function got(card)
      table.insert(exiled, card)
      local isLand = false
      pcall(function()
        local d = JSON.decode(card.getGMNotes())
        for _, t in ipairs(type(d) == "table" and d.types or {}) do
          if tostring(t):lower() == "land" then
            isLand = true
          end
        end
      end)
      Wait.time(function()
        if not card.isDestroyed() then
          Zones.refresh(card)
        end
      end, 0.6)
      if not isLand and (accept == nil or accept(card)) then
        found = card
      end
      if onlyOne or found then
        finish()
      else
        step()
      end
    end
    if lib.type == "Deck" then
      lib.takeObject({ index = 0, position = pos, rotation = { 0, s.yaw, 0 }, smooth = false, callback_function = got })
    else
      lib.setPosition(pos)
      lib.setRotation({ 0, s.yaw, 0 })
      got(lib)
    end
  end
  step()
end

-- Reveal cards from the top until one has the type (a creature card...):
-- the cards are laid next to the library face up. onDone(found, others).
function Library.revealUntil(color, typeName, onDone)
  if #libraryPiles(color) > 1 then
    Library.consolidate(color, function() Library.revealUntil(color, typeName, onDone) end)
    return
  end
  local s = TableSetup.seat(color)
  local count, found, others = 0, nil, {}
  local want = tostring(typeName or ""):lower()
  local function finish()
    if onDone then onDone(found, others) end
  end
  local function step()
    local lib = Library.find(color)
    if lib == nil then
      finish()
      return
    end
    count = count + 1
    local pos = TableSetup.slot(color, "library", 3 + count * 0.3)
    local function got(card)
      local match = false
      pcall(function()
        local d = JSON.decode(card.getGMNotes())
        -- "nonland": any card that isn't a land.
        local nonWord = want:match("^non(%a+)$")
        local has = false
        for _, t in ipairs(type(d) == "table" and d.types or {}) do
          local tl = tostring(t):lower()
          if tl == want then
            match = true
          end
          if nonWord and tl == nonWord then
            has = true
          end
        end
        if nonWord and not has then
          match = true
        end
      end)
      if match then
        found = card
        finish()
      else
        table.insert(others, card)
        step()
      end
    end
    if lib.type == "Deck" then
      lib.takeObject({ index = 0, position = pos, rotation = { 0, s.yaw, 0 }, smooth = false, callback_function = got })
    else
      lib.setPosition(pos)
      lib.setRotation({ 0, s.yaw, 0 })
      got(lib)
    end
  end
  step()
end

-- Take the top card of the library face up beside it (Chaos Warp). onDone(card)
-- gets nil when the library is empty.
function Library.revealTop(color, onDone)
  if #libraryPiles(color) > 1 then
    Library.consolidate(color, function() Library.revealTop(color, onDone) end)
    return
  end
  local lib = Library.find(color)
  if lib == nil then
    onDone(nil)
    return
  end
  local s = TableSetup.seat(color)
  local pos = TableSetup.slot(color, "library", 3.5)
  if lib.type == "Deck" then
    lib.takeObject({ index = 0, position = pos, rotation = { 0, s.yaw, 0 }, smooth = false,
      callback_function = function(card) onDone(card) end })
  else
    lib.setPosition(pos)
    lib.setRotation({ 0, s.yaw, 0 })
    onDone(lib)
  end
end

---------------------------------------------------------------------------
-- A revealed card that is going on top of the library (Personal Tutor,
-- Sylvan Tutor...): it stays face up beside the library, outside the library
-- area, so everybody can see it and it isn't swept into the deck. It goes on
-- top when its owner clicks the button (or draws, which does it first).
---------------------------------------------------------------------------

local function revealedTable()
  local d = GameState.data
  d.revealedTop = d.revealedTop or {}
  return d.revealedTop
end

function Library.revealSpot(color)
  local seat = TableSetup.seat(color)
  local lib = TableSetup.slot(color, "library", 3.2)
  if seat == nil or lib == nil then
    return lib
  end
  -- Just past the library toward the table centre, clear of every area.
  return { x = lib.x + seat.inward.x * 6.8, y = lib.y, z = lib.z + seat.inward.z * 6.8 }
end

function Library.revealedCard(color)
  local guid = revealedTable()[color]
  local obj = guid and getObjectFromGUID(guid) or nil
  if obj == nil or obj.isDestroyed() then
    revealedTable()[color] = nil
    return nil
  end
  return obj
end

function Library.decorateRevealed(card)
  if card == nil or card.isDestroyed() then
    return
  end
  for color, guid in pairs(revealedTable()) do
    if guid == card.getGUID() then
      -- Still beside the library? A card that was cast or dragged away isn't "revealed" any more.
      local spot = Library.revealSpot(color)
      local p = card.getPosition()
      if spot and p and ((p.x - spot.x) ^ 2 + (p.z - spot.z) ^ 2) > 4 then
        revealedTable()[color] = nil
        return
      end
      card.createButton({
        click_function = "library_putRevealedOnTop",
        function_owner = Global,
        label = "PUT ON TOP",
        tooltip = "Revealed: click to put this card on top of " .. color .. "'s library",
        position = { 0, 0.3, 1.45 },
        rotation = { 0, 0, 0 },
        width = 900, height = 240, font_size = 160,
        font_color = { 1, 1, 1 },
        color = { 0.1, 0.55, 0.65, 0.95 },
      })
    end
  end
end

function Library.addRevealedMenu(card)
  for color, guid in pairs(GameState.data.revealedTop or {}) do
    if guid == card.getGUID() and not (Library.revealSpot(color) and ((card.getPosition().x - Library.revealSpot(color).x) ^ 2 + (card.getPosition().z - Library.revealSpot(color).z) ^ 2) > 4) then
      card.addContextMenuItem("Put on top of library", function() Library.putRevealedOnTop(color) end)
    end
  end
end

-- Take `card` out of the library to the reveal spot, face up.
function Library.holdRevealed(color, card)
  if card == nil or card.isDestroyed() then
    return
  end
  local s = TableSetup.seat(color)
  local old = Library.revealedCard(color)
  if old and old ~= card then
    Library.putRevealedOnTop(color)   -- one at a time
  end
  revealedTable()[color] = card.getGUID()
  card.setLock(false)
  card.setPositionSmooth(Library.revealSpot(color), false, true)
  card.setRotationSmooth({ 0, s.yaw, 0 }, false, true)
  Wait.time(function()
    if not card.isDestroyed() then
      pcall(function()
        card.clearButtons()
        card.clearContextMenu()
        card.addContextMenuItem("Put on top of library", function(c)
          Library.putRevealedOnTop(color)
        end)
        Library.decorateRevealed(card)
      end)
    end
  end, 1.0)
  printToAll("MTG > " .. card.getName() .. " stays revealed beside " .. color .. "'s library. Click PUT ON TOP when ready (drawing does it automatically).", { 0.55, 0.9, 0.6 })
end

function Library.putRevealedOnTop(color, onDone)
  local card = Library.revealedCard(color)
  if card == nil then
    if onDone then onDone(nil) end
    return false
  end
  revealedTable()[color] = nil
  pcall(function()
    card.clearButtons()
    card.clearContextMenu()
  end)
  Library.putAt(color, card, 0, function(lib)
    printToAll("MTG > The revealed card is now on top of " .. color .. "'s library.", { 0.75, 0.8, 0.9 })
    if onDone then onDone(lib) end
  end)
  return true
end

function library_putRevealedOnTop(obj, playerColor)
  for color, guid in pairs(revealedTable()) do
    if guid == obj.getGUID() then
      Library.putRevealedOnTop(color)
      return
    end
  end
end

-- Put these cards on the bottom of the library in a random order.
function Library.putBottomRandom(color, cards, onDone)
  local list = {}
  for _, c in ipairs(cards) do
    if c ~= nil and not c.isDestroyed() then
      table.insert(list, c)
    end
  end
  -- Shuffle the order.
  for i = #list, 2, -1 do
    local j = math.random(i)
    list[i], list[j] = list[j], list[i]
  end
  local function nextCard(i)
    if i > #list then
      if onDone then onDone() end
      return
    end
    Library.putAt(color, list[i], 100000, function() nextCard(i + 1) end)
  end
  nextCard(1)
end

-- Put a card into the library at depth (0 = top): Approach of the Second
-- Sun goes 7th from the top. The deck is rebuilt with the card in place.
function Library.putAt(color, card, depth, onDone)
  if card == nil or card.isDestroyed() then
    if onDone then onDone(Library.find(color)) end
    return
  end
  if #libraryPiles(color) > 1 then
    Library.consolidate(color, function() Library.putAt(color, card, depth, onDone) end)
    return
  end
  card.setLock(false)
  local lib = Library.find(color)
  if lib == nil or lib.type ~= "Deck" then
    -- No deck to rebuild: on top of what's there (or where the library goes).
    if lib then
      lib.putObject(card)
    else
      card.setPosition(TableSetup.slot(color, "library", 2))
      card.setRotation({ 0, TableSetup.seat(color).yaw, 180 })
    end
    if onDone then onDone(lib) end
    return
  end
  local data = lib.getData()
  data.ContainedObjects = data.ContainedObjects or {}
  data.DeckIDs = data.DeckIDs or {}
  data.CustomDeck = data.CustomDeck or {}
  local cd = card.getData()
  local at = math.min(depth, #data.ContainedObjects) + 1
  table.insert(data.ContainedObjects, at, cd)
  table.insert(data.DeckIDs, math.min(at, #data.DeckIDs + 1), cd.CardID)
  for k, v in pairs(cd.CustomDeck or {}) do
    if not hasKey(data.CustomDeck, k) then
      data.CustomDeck[k] = v
    end
  end
  if Zones.forget then
    Zones.forget(card.getGUID())
  end
  card.destruct()
  local pos, rot = lib.getPosition(), lib.getRotation()
  lib.destruct()
  printToAll("MTG > " .. tostring(cd.Nickname or "A card") .. " went into " .. color .. "'s library, "
    .. (at >= #data.ContainedObjects and "on the bottom." or (at .. " from the top.")), { 0.75, 0.8, 0.9 })
  spawnObjectData({ data = data, position = pos, rotation = rot,
    callback_function = function(obj) if onDone then onDone(obj) end end })
end

-- Move the top k cards to the bottom, in the same order (one rebuild).
function Library.topToBottom(color, k, onDone)
  local lib = Library.find(color)
  if lib == nil or lib.type ~= "Deck" or k <= 0 then
    if onDone then onDone(lib) end
    return
  end
  local data = lib.getData()
  local objs, ids = data.ContainedObjects or {}, data.DeckIDs or {}
  k = math.min(k, #objs)
  local movedObjs, movedIds = {}, {}
  for _ = 1, k do
    if #objs > 0 then
      table.insert(movedObjs, table.remove(objs, 1))
    end
    if #ids > 0 then
      table.insert(movedIds, table.remove(ids, 1))
    end
  end
  for _, o in ipairs(movedObjs) do
    table.insert(objs, o)
  end
  for _, d in ipairs(movedIds) do
    table.insert(ids, d)
  end
  local pos, rot = lib.getPosition(), lib.getRotation()
  lib.destruct()
  spawnObjectData({ data = data, position = pos, rotation = rot,
    callback_function = function(obj) if onDone then onDone(obj) end end })
end

-- Resolve a scry / surveil of the top cards in one go. Cards kept on top stay
-- in the order they were seen, "bottom" cards go under the library (in order),
-- "grave" cards are milled.
function Library.arrangeTop(color, choices, onDone)
  local lib = Library.find(color)
  local function finish() if onDone then onDone() end end
  if lib == nil then
    finish()
    return
  end
  if lib.type ~= "Deck" then
    if choices[1] == "grave" then
      Library.mill(color, 1, 0, finish)
    else
      finish()
    end
    return
  end
  local data = lib.getData()
  local objs, ids = data.ContainedObjects or {}, data.DeckIDs or {}
  local k = math.min(#choices, #objs)
  local graves, tops, bottoms, changed = {}, {}, {}, false
  for i = 1, k do
    local pair = { objs[i], ids[i] }
    local c = choices[i]
    if c == "grave" then
      table.insert(graves, pair)
      changed = true
    elseif c == "bottom" then
      table.insert(bottoms, pair)
      changed = true
    else
      table.insert(tops, pair)
    end
  end
  if not changed then
    finish()
    return
  end
  local newObjs, newIds = {}, {}
  local function add(list)
    for _, pair in ipairs(list) do
      table.insert(newObjs, pair[1])
      table.insert(newIds, pair[2])
    end
  end
  add(graves)
  add(tops)
  for i = k + 1, #objs do
    table.insert(newObjs, objs[i])
    table.insert(newIds, ids[i])
  end
  add(bottoms)
  data.ContainedObjects, data.DeckIDs = newObjs, newIds
  local pos, rot = lib.getPosition(), lib.getRotation()
  lib.destruct()
  spawnObjectData({ data = data, position = pos, rotation = rot,
    callback_function = function()
      if #graves > 0 then
        -- The graveyard cards were put on top: mill exactly those.
        Wait.time(function() Library.mill(color, #graves, 0, finish) end, 0.3)
      else
        finish()
      end
    end })
end


-- A revealed card that is drawn, cast or moved away is no longer "revealed": drop its PUT ON TOP button.
Events.on("cardMoved", function(d)
  local card = d.card
  if card == nil or d.to == nil or card.isDestroyed() then
    return
  end
  local r = d.to.region
  if r ~= "hand" and r ~= "battlefield" and r ~= "lands" and r ~= "graveyard" and r ~= "exile" and r ~= "command" then
    return
  end
  local t = revealedTable()
  for color, guid in pairs(t) do
    if guid == card.getGUID() then
      t[color] = nil
      pcall(function() card.clearButtons() end)
      if Counters and Counters.setup then
        Wait.time(function()
          if not card.isDestroyed() then Counters.setup(card) end
        end, 0.3)
      end
    end
  end
end)
