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

  Look: each area is one image laid flat on the table (assets/mats, built by
  tools/make_mat_art.py) with its glowing border, title and icon.

  Debug commands: !moves (log every move), !where (card under mouse),
  !zones (what's tracked at your seat).
--]]

Zones = {}

-- Areas that count as card locations (life and tax are display-only spots).
local TRACKED_REGIONS = { "command1", "command2", "battlefield", "lands", "library", "graveyard", "exile" }
-- Both command zones count as "command"; slot says which one (2 = partner).
local REGION_AS = { command1 = { "command", 1 }, command2 = { "command", 2 } }

-- A card counts as inside an area if its center is within this margin of the
-- area's edge, so a card overhanging an outline slightly still counts.
local EDGE_MARGIN = 0.6

-- How long to wait after a drop before reading the card's position.
local SETTLE_DELAY = 0.4

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

-- Each area is drawn as one flat image on the table (tools/make_mat_art.py):
-- dark plate, glowing border in the seat's color, title and icon. Cards sit
-- on top of it; areas are still worked out from position (regionAt).
local MAT_BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/mats/"
local MAT_VERSION = "?v=6"
local MAT_AREAS = { "command1", "command2", "battlefield", "lands", "library", "graveyard", "exile", "attractions" }
local MAT_HEIGHT = 0.012   -- just above the surface, under cards lying on it

function Zones.drawIcons()
  local decals = {}
  for _, color in ipairs(TableSetup.activeSeats()) do
    local s = TableSetup.seat(color)
    for _, name in ipairs(MAT_AREAS) do
      local r = TableSetup.region(color, name)
      table.insert(decals, {
        name = color .. "_" .. name,
        url = MAT_BASE .. "mat_" .. name .. "_" .. color .. ".png" .. MAT_VERSION,
        position = { r.center.x, TableSetup.SURFACE_TOP + MAT_HEIGHT, r.center.z },
        -- Upright for the seat (image top toward the table center).
        rotation = { 90, s.angle, 0 },
        scale = { r.w, r.d, 1 },
      })
    end
  end
  Global.setDecals(decals)
end

---------------------------------------------------------------------------
-- Finding the area at a position
---------------------------------------------------------------------------

-- The area containing a world position: { seat, region }, or a "table"
-- location if it's outside every area.
-- Seat and area rectangles never move while a layout is in use, so they're worked out once.
-- Each area is kept in its seat's own directions (sideways, toward the middle) relative to the seat's
-- centre, plus one box around all of a seat's areas: a position is turned into seat directions once per
-- seat, and seats it is nowhere near are skipped (this runs for every card, many times a second).
local geo, geoLayout
local function geometry()
  local lay = TableSetup.layout()
  if geo and geoLayout == lay then
    return geo
  end
  geo = {}
  for _, color in ipairs(TableSetup.activeSeats()) do
    local s = TableSetup.seat(color)
    local regs = {}
    local minS, maxS, minD, maxD = math.huge, -math.huge, math.huge, -math.huge
    for _, name in ipairs(TRACKED_REGIONS) do
      local r = TableSetup.region(color, name)
      local dx, dz = r.center.x - s.center.x, r.center.z - s.center.z
      local side = dx * s.right.x + dz * s.right.z
      local depth = dx * s.inward.x + dz * s.inward.z
      local hw, hd = r.w / 2 + EDGE_MARGIN, r.d / 2 + EDGE_MARGIN
      table.insert(regs, { name = name, side = side, depth = depth, hw = hw, hd = hd, as = REGION_AS[name] })
      minS, maxS = math.min(minS, side - hw), math.max(maxS, side + hw)
      minD, maxD = math.min(minD, depth - hd), math.max(maxD, depth + hd)
    end
    table.insert(geo, { color = color, cx = s.center.x, cz = s.center.z, rx = s.right.x, rz = s.right.z,
      ix = s.inward.x, iz = s.inward.z, regs = regs, minS = minS, maxS = maxS, minD = minD, maxD = maxD })
  end
  geoLayout = lay
  return geo
end

function Zones.regionAt(pos)
  -- The STACK mat in the middle of the table (stack.lua).
  if Stack and Stack.contains(pos) then
    return { seat = nil, region = "stack" }
  end
  local px, pz = pos.x, pos.z
  for _, g in ipairs(geometry()) do
    local dx, dz = px - g.cx, pz - g.cz
    local side = dx * g.rx + dz * g.rz
    local depth = dx * g.ix + dz * g.iz
    if side >= g.minS and side <= g.maxS and depth >= g.minD and depth <= g.maxD then
      for _, e in ipairs(g.regs) do
        local a, b = side - e.side, depth - e.depth
        if a <= e.hw and a >= -e.hw and b <= e.hd and b >= -e.hd then
          if e.as then
            return { seat = g.color, region = e.as[1], slot = e.as[2] }
          end
          return { seat = g.color, region = e.name }
        end
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
-- Every seat's hand read once and kept for a moment: menus are rebuilt for every card at each step,
-- and asking TTS for four hands per card made big boards lag.
local handCache = { at = -100, map = {} }
local function handOwner(obj)
  local now = (Time and Time.time) or os.time()
  if now - handCache.at > 0.3 then
    local map = {}
    for _, color in ipairs(TableSetup.activeSeats()) do
      local ok, list = pcall(function() return Player[color].getHandObjects() end)
      for _, h in ipairs(ok and list or {}) do
        map[h.getGUID()] = color
      end
    end
    handCache.at, handCache.map = now, map
  end
  return handCache.map[obj.getGUID()]
end

Zones.handOwner = function(obj)
  if obj == nil or obj.isDestroyed() then
    return nil
  end
  return handOwner(obj)
end

-- A card made by script (a token, a copy) has no earlier area: say it came
-- from the stack, so "enters the battlefield" watchers see it arrive.
-- A copy made in place (a token split off a pile) is where the original is, with no "enters".
function Zones.inherit(old, new)
  if old ~= nil and new ~= nil then
    where[new.getGUID()] = where[old.getGUID()]
  end
end

function Zones.presetFrom(obj, seat)
  if obj ~= nil and not obj.isDestroyed() and where[obj.getGUID()] == nil then
    where[obj.getGUID()] = { seat = seat, region = "stack" }
  end
end

function Zones.refresh(obj)
  if not isCard(obj) or obj.held_by_color then
    return
  end
  -- A table flip is tossing everything around and will put it all back.
  if Flip and Flip.chaosOn then
    return
  end
  -- Clicking or rearranging a card in a hand also counts as a drop; it's
  -- still in the hand, not on the table.
  local owner = handOwner(obj)
  if owner then
    moveTo(obj, obj.getName(), obj.getGUID(), { seat = owner, region = "hand" })
    return
  end
  -- A spell just cast (dropped on the battlefield): it's on the stack, still gliding to the mat.
  if Stack and Stack.has and Stack.has(obj.getGUID()) then
    moveTo(obj, obj.getName(), obj.getGUID(), { seat = nil, region = "stack" })
    return
  end
  moveTo(obj, obj.getName(), obj.getGUID(), Zones.regionAt(obj.getPosition()))
end

-- A player picked something up: note where it was, so the move that follows
-- knows where it came from (cards placed by script, like commanders, are
-- never "dropped" there, so they'd otherwise have no starting area).
function Zones.onPickUp(color, obj)
  if not isCard(obj) then
    return
  end
  local owner = handOwner(obj)
  if owner then
    where[obj.getGUID()] = { seat = owner, region = "hand" }
  else
    -- TTS may already have taken it out of the hand list when it's picked up:
    -- a card we know is in a hand, lifted from outside every area, still comes from the hand
    -- (so playing a land counts as "played" for Horn of Greed and the land count).
    local was = where[obj.getGUID()]
    local here = Zones.regionAt(obj.getPosition())
    if not (was and was.region == "hand" and here.region == "table") then
      where[obj.getGUID()] = here
    end
  end
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
  if Flip and Flip.chaosOn then
    return   -- a card flying through a hand during a table flip isn't drawn
  end
  if not isCard(obj) or zone == nil or zone.type ~= "Hand" then
    return
  end
  local ok, color = pcall(function() return zone.getValue() end)
  if ok and color and TableSetup.isActive(color) then
    handCache.at = -100   -- the hands changed: read them again next time
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

-- A card became a new object (a double-faced card changed face): same place.
function Zones.rekey(old, new)
  if where[old] ~= nil then
    where[new] = where[old]
    where[old] = nil
  end
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

-- Loose cards tracked in each of a seat's areas (piles count as one).
function Zones.countsFor(color)
  local counts = {}
  for _, loc in pairs(where) do
    if loc.seat == color then
      counts[loc.region] = (counts[loc.region] or 0) + 1
    end
  end
  return counts
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
