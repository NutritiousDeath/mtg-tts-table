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

function Library.count(color)
  local lib = Library.find(color)
  if lib == nil then
    return 0
  end
  return lib.type == "Deck" and #lib.getObjects() or 1
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
    if isPile(obj) and obj.getGUID() ~= libGuid and not skip[obj.getGUID()] and not seen[obj.getGUID()] then
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

local function hasKey(t, k)
  return t[k] ~= nil or t[tostring(k)] ~= nil or (tonumber(k) ~= nil and t[tonumber(k)] ~= nil)
end

-- Put cards on the bottom of the library. TTS can only add to the top of a
-- deck, so the deck is rebuilt from its data with the cards added at the end
-- (the end of a deck's card list is its bottom).
function Library.putOnBottom(color, cards, onDone)
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

function Library.draw(color, n)
  local lib = Library.find(color)
  if lib == nil then
    broadcastToColor("Your library is empty.", color, { 1, 0.6, 0.2 })
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

