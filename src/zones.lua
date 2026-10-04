--[[
  zones.lua
  Scripted zones on every playmat area, and tracking of where each card is.

  Each active seat gets an invisible scripting zone over these playmat areas
  (from table.lua's layout): command, battlefield, lands, library, graveyard,
  exile. Each seat's TTS hand zone counts as "hand".

  When a card enters one of these areas, its location is updated and, if it
  came from somewhere else, a "cardMoved" event is fired (see events.lua):
      { card, name, from = {seat, region} or nil, to = {seat, region} }
  Cards drawn out of a deck that sits in a library zone count as coming from
  that library.

  Icons: each area also gets an icon (decals, loaded from the repo's
  assets/icons folder on GitHub).

  Debug: !moves toggles printing every card move to chat.
--]]

Zones = {}

-- Areas that get a scripting zone (life and tax are display-only spots).
local ZONE_REGIONS = { "command", "battlefield", "lands", "library", "graveyard", "exile" }

local ZONE_HEIGHT = 6

-- Icons are served from the public GitHub repo.
local ICON_BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/icons/"
local ICON_SIZE = { life = 2.2, command = 2.6, tax = 1.1, battlefield = 3.4, lands = 2.6,
  library = 2.6, graveyard = 2.6, exile = 2.6 }

local zoneInfo = {}  -- zone GUID -> { seat, region }
local where = {}     -- card GUID -> { seat, region }
local showMoves = false

---------------------------------------------------------------------------
-- Building zones
---------------------------------------------------------------------------

local function state()
  GameState.data.zones = GameState.data.zones or {}
  return GameState.data.zones
end

local function allZonesExist(s)
  if s.layout ~= TableSetup.layout() or s.guids == nil then
    return false
  end
  local count = 0
  for guid, _ in pairs(s.guids) do
    if getObjectFromGUID(guid) == nil then
      return false
    end
    count = count + 1
  end
  return count == #TableSetup.activeSeats() * #ZONE_REGIONS
end

local function clearZones(s)
  for guid, _ in pairs(s.guids or {}) do
    local obj = getObjectFromGUID(guid)
    if obj then
      obj.destruct()
    end
  end
  s.guids = {}
  zoneInfo = {}
end

-- Create zones for the current layout, or reuse them if they're all there.
function Zones.ensure()
  local s = state()
  if allZonesExist(s) then
    for guid, info in pairs(s.guids) do
      zoneInfo[guid] = { seat = info.seat, region = info.region }
    end
    Zones.drawIcons()
    return
  end

  clearZones(s)
  s.layout = TableSetup.layout()
  for _, color in ipairs(TableSetup.activeSeats()) do
    for _, region in ipairs(ZONE_REGIONS) do
      local r = TableSetup.region(color, region)
      spawnObject({
        type = "ScriptingTrigger",
        position = { r.center.x, TableSetup.SURFACE_TOP + ZONE_HEIGHT / 2, r.center.z },
        rotation = { 0, r.yaw, 0 },
        scale = { r.w, ZONE_HEIGHT, r.d },
        callback_function = function(zone)
          zone.setName(color .. " " .. region)
          zone.addTag("MTGZone")
          local guid = zone.getGUID()
          s.guids[guid] = { seat = color, region = region }
          zoneInfo[guid] = { seat = color, region = region }
        end,
      })
    end
  end
  Zones.drawIcons()
end

-- The scripting zone object for a seat's area, or nil.
function Zones.get(color, region)
  for guid, info in pairs(zoneInfo) do
    if info.seat == color and info.region == region then
      return getObjectFromGUID(guid)
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Icons
---------------------------------------------------------------------------

function Zones.drawIcons()
  local decals = {}
  for _, color in ipairs(TableSetup.activeSeats()) do
    local s = TableSetup.seat(color)
    for _, name in ipairs(TableSetup.REGION_NAMES) do
      local r = TableSetup.region(color, name)
      local size = ICON_SIZE[name] or 2.4
      table.insert(decals, {
        name = color .. "_" .. name,
        url = ICON_BASE .. name .. ".png",
        position = { r.center.x, TableSetup.SURFACE_TOP + 0.02, r.center.z },
        -- Same facing as the mat labels, so icons are upright for the seat.
        rotation = { 90, s.angle, 0 },
        scale = { size, size, 1 },
      })
    end
  end
  Global.setDecals(decals)
end

---------------------------------------------------------------------------
-- Tracking cards
---------------------------------------------------------------------------

local function isCard(obj)
  return obj ~= nil and obj.type == "Card" and obj.hasTag("MTGCard")
end

local function describe(loc)
  if loc == nil then
    return "nowhere"
  end
  return loc.seat .. " " .. loc.region
end

local function same(a, b)
  return a ~= nil and b ~= nil and a.seat == b.seat and a.region == b.region
end

local function moveTo(obj, to)
  local guid = obj.getGUID()
  local from = where[guid]
  where[guid] = to
  if same(from, to) then
    return
  end
  if showMoves then
    print("MTG > " .. obj.getName() .. ": " .. describe(from) .. " -> " .. describe(to))
  end
  Events.emit("cardMoved", { card = obj, name = obj.getName(), from = from, to = to })
end

-- Called from main.lua's onObjectEnterZone.
function Zones.onEnter(zone, obj)
  if not isCard(obj) then
    return
  end
  if zone.type == "Hand" then
    local ok, color = pcall(function() return zone.getValue() end)
    if ok and color and TableSetup.isActive(color) then
      moveTo(obj, { seat = color, region = "hand" })
    end
    return
  end
  local info = zoneInfo[zone.getGUID()]
  if info then
    moveTo(obj, { seat = info.seat, region = info.region })
  end
end

-- Called from main.lua's onObjectLeaveContainer: a card taken out of a deck
-- that sits in a library zone starts out "in" that library.
function Zones.onLeaveContainer(container, obj)
  if not isCard(obj) or container == nil then
    return
  end
  for _, z in ipairs(container.getZones and container.getZones() or {}) do
    local info = zoneInfo[z.getGUID()]
    if info and info.region == "library" then
      where[obj.getGUID()] = { seat = info.seat, region = "library" }
      return
    end
  end
end

-- Where a card currently is: { seat, region } or nil.
function Zones.locationOf(obj)
  return obj and where[obj.getGUID()] or nil
end

function Zones.toggleMoveLog()
  showMoves = not showMoves
  return showMoves
end
