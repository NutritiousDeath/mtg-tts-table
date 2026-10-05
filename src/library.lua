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
