--[[
  zones.lua
  Knows which playmat area every card is in, and draws the area icons.

  How locations are worked out:
    The playmat areas are exact rectangles (table.lua's layout). Whenever a
    card is dropped, settles, or is merged into a pile, its position is checked
    against those rectangles. TTS's own scripting zones were tried first but
    didn't detect cards on this table, so areas are computed instead.
    Each seat's TTS hand zone counts as "hand" (that event works fine).

  Areas tracked per seat: command, battlefield, lands, library, graveyard,
  exile, plus hand. Anything outside all areas is "table".

  When a card ends up somewhere new, a "cardMoved" event fires (events.lua):
      { card, name, from = {seat, region} or nil, to = {seat, region} }
  Phase 6 (triggers) listens to this for "dies", "enters the battlefield" etc.

  Icons: each area gets an icon (decals, from the repo's assets/icons folder).

  Debug commands: !moves (log every move), !where (card under mouse),
  !zones (what's tracked at your seat).
--]]

Zones = {}

-- Areas that count as card locations (life and tax are display-only spots).
local TRACKED_REGIONS = { "command", "battlefield", "lands", "library", "graveyard", "exile" }

-- A card counts as inside an area if its center is within this margin of the
-- area's edge, so a card overhanging an outline slightly still counts.
local EDGE_MARGIN = 0.6

-- How long to wait after a drop before reading the card's position.
local SETTLE_DELAY = 0.4

-- Icons are served from the public GitHub repo.
local ICON_BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/icons/"
-- Areas with an icon (others, like the tracker, have none).
local ICON_SIZE = { command = 2.6, tax = 1.1, battlefield = 3.4, lands = 2.6,
  library = 2.6, graveyard = 2.6, exile = 2.6 }

local where = {}     -- card GUID -> { seat, region }
local showMoves = false

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

-- Remove the TTS scripting zones earlier versions created (they never
-- detected cards), then draw the icons.
function Zones.ensure()
  local s = GameState.data.zones
  if s and s.guids then
    for guid, _ in pairs(s.guids) do
      local obj = getObjectFromGUID(guid)
      if obj then
        obj.destruct()
      end
    end
  end
  GameState.data.zones = nil
  Zones.drawIcons()
end

function Zones.drawIcons()
  local decals = {}
  for _, color in ipairs(TableSetup.activeSeats()) do
    local s = TableSetup.seat(color)
    for _, name in ipairs(TableSetup.REGION_NAMES) do
      if ICON_SIZE[name] then
      local r = TableSetup.region(color, name)
      local size = ICON_SIZE[name]
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
  end
  Global.setDecals(decals)
end

---------------------------------------------------------------------------
-- Finding the area at a position
---------------------------------------------------------------------------

-- The area containing a world position: { seat, region }, or a "table"
-- location if it's outside every area.
function Zones.regionAt(pos)
  for _, color in ipairs(TableSetup.activeSeats()) do
    local s = TableSetup.seat(color)
    for _, name in ipairs(TRACKED_REGIONS) do
      local r = TableSetup.region(color, name)
      local dx, dz = pos.x - r.center.x, pos.z - r.center.z
      -- Position in the seat's own directions (sideways, toward the middle).
      local side = dx * s.right.x + dz * s.right.z
      local depth = dx * s.inward.x + dz * s.inward.z
      if math.abs(side) <= r.w / 2 + EDGE_MARGIN and math.abs(depth) <= r.d / 2 + EDGE_MARGIN then
        return { seat = color, region = name }
      end
    end
  end
  return { seat = nil, region = "table" }
end

---------------------------------------------------------------------------
-- Tracking
---------------------------------------------------------------------------

local function isCard(obj)
  return obj ~= nil and obj.type == "Card" and obj.hasTag("MTGCard")
end

local function describe(loc)
  if loc == nil then
    return "nowhere"
  end
  if loc.seat == nil then
    return loc.region
  end
  return loc.seat .. " " .. loc.region
end

local function same(a, b)
  return a ~= nil and b ~= nil and a.seat == b.seat and a.region == b.region
end

local function moveTo(obj, name, guid, to)
  local from = where[guid]
  where[guid] = to
  if same(from, to) then
    return
  end
  if showMoves then
    print("MTG > " .. name .. ": " .. describe(from) .. " -> " .. describe(to))
  end
  Events.emit("cardMoved", { card = obj, name = name, from = from, to = to })
end

-- Re-check a card's area from where it is now (also usable by other modules
-- after moving a card by script).
-- The seat whose hand a card is in, or nil.
local function handOwner(obj)
  local guid = obj.getGUID()
  for _, color in ipairs(TableSetup.activeSeats()) do
    for _, h in ipairs(Player[color].getHandObjects() or {}) do
      if h.getGUID() == guid then
        return color
      end
    end
  end
  return nil
end

function Zones.refresh(obj)
  if not isCard(obj) or obj.held_by_color then
    return
  end
  -- Clicking or rearranging a card in a hand also counts as a drop; it's
  -- still in the hand, not on the table.
  local owner = handOwner(obj)
  if owner then
    moveTo(obj, obj.getName(), obj.getGUID(), { seat = owner, region = "hand" })
    return
  end
  moveTo(obj, obj.getName(), obj.getGUID(), Zones.regionAt(obj.getPosition()))
end

-- A player let go of something: check where it landed once it settles.
function Zones.onDrop(color, obj)
  if not isCard(obj) then
    return
  end
  Wait.time(function()
    -- It may have been merged into a pile or picked up again meanwhile.
    if obj ~= nil and not obj.isDestroyed() then
      Zones.refresh(obj)
    end
  end, SETTLE_DELAY)
end

-- A card entered a hand zone.
function Zones.onEnterZone(zone, obj)
  if not isCard(obj) or zone == nil or zone.type ~= "Hand" then
    return
  end
  local ok, color = pcall(function() return zone.getValue() end)
  if ok and color and TableSetup.isActive(color) then
    moveTo(obj, obj.getName(), obj.getGUID(), { seat = color, region = "hand" })
  end
end

-- A card was taken out of a pile (e.g. drawn from the library): it starts out
-- in whatever area that pile is in.
function Zones.onLeaveContainer(container, obj)
  if not isCard(obj) or container == nil then
    return
  end
  where[obj.getGUID()] = Zones.regionAt(container.getPosition())
end

-- A card was dropped onto a pile and merged into it (e.g. onto the graveyard):
-- it moved to whatever area that pile is in.
function Zones.onEnterContainer(container, obj)
  if not isCard(obj) or container == nil then
    return
  end
  moveTo(obj, obj.getName(), obj.getGUID(), Zones.regionAt(container.getPosition()))
end

-- Stop tracking a card that was destroyed by script (e.g. rebuilt into a deck).
function Zones.forget(guid)
  where[guid] = nil
end

-- Where a card currently is: { seat, region } or nil.
function Zones.locationOf(obj)
  return obj and where[obj.getGUID()] or nil
end

---------------------------------------------------------------------------
-- Debug
---------------------------------------------------------------------------

function Zones.toggleMoveLog()
  showMoves = not showMoves
  return showMoves
end

function Zones.describeObject(obj)
  if obj == nil then
    return "Hover over a card first."
  end
  local p = obj.getPosition()
  local loc = where[obj.getGUID()]
  return string.format("%s at (%.1f, %.2f, %.1f) | area there: %s | tracked as: %s",
    obj.getName(), p.x, p.y, p.z, describe(Zones.regionAt(p)), loc and describe(loc) or "nothing yet")
end

function Zones.report(color)
  local counts = {}
  for _, loc in pairs(where) do
    if loc.seat == color then
      counts[loc.region] = (counts[loc.region] or 0) + 1
    end
  end
  local parts = {}
  for _, name in ipairs({ "hand", "command", "battlefield", "lands", "library", "graveyard", "exile" }) do
    table.insert(parts, name .. " " .. (counts[name] or 0))
  end
  print("MTG > Cards tracked at " .. tostring(color) .. " (loose cards, not ones inside piles): "
    .. table.concat(parts, ", "))
end
