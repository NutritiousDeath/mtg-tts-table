--[[
  table.lua
  The base table: our own play surface, seat layout and hand zones.

  The built-in TTS tables are a fixed size and too small for four Commander
  boards, so the default table is hidden and replaced by a large, locked,
  flat surface whose size is one setting (SIZE). Every seat's area, hand zone
  and pile spots are laid out from that size, so changing SIZE spreads
  everything out.

  Layouts:
    "four"  one player per side of a square table, everyone facing the middle
            (White south, Red west, Green north, Blue east = clockwise)
    "two"   White and Green facing each other across the table
    "three" White, Red and Green on three sides (the east side stays open)
    "twohg" Two-Headed Giant: a 120 x 100 table, team White + Red side by side on the south edge,
            team Green + Blue on the north edge

  Seat areas (a playmat layout, from the seated player's view; far = toward
  the table center, near = the player's edge):

      +--------+  +-------------------------+  +---------+
      |Command |  |                         |  | Library |
      |        |  |       Battlefield       |  +---------+
      +--------+  |                         |  |Graveyard|
       [ Tax ]    +-------------------------+  +---------+
                  |          Lands          |  |  Exile  |
                  +-------------------------+  +---------+
      ----------------- player's edge / hand -----------------
  The life / poison / commander damage tracker sits in front of the mat,
  toward the table center ("tracker" area, see trackers.lua).

  Every area is defined here once (REGIONS) and placed for each seat, so the
  importer, Phase 2's zones/markers and the life tracker all use the same spots.

  Cameras: each player's camera is pointed at their seat when they sit down,
  when they import a deck, when the layout changes, and with !view.

  Chat commands (in main.lua): !layout 4, !layout 3, !layout 2, !view
--]]

TableSetup = {}

TableSetup.SIZE = 100          -- surface is SIZE x SIZE units
TableSetup.SURFACE_TOP = 1.0   -- height of the play surface's top face

-- Seat compass directions per layout. Angle = where the seat sits around the
-- table, in degrees: 0 = south (-z), 90 = west (-x), 180 = north, 270 = east.
-- A seat is its compass angle, or { angle, offset } for two seats on one side (offset = how far along
-- the edge, to the seated player's right).
local LAYOUTS = {
  four = { White = 0, Red = 90, Green = 180, Blue = 270 },
  two = { White = 0, Green = 180 },
  -- Three players: White (south), Red (west), Green (north); the east side stays open.
  three = { White = 0, Red = 90, Green = 180 },
  -- Two-Headed Giant: team White + Red on the south side, team Green + Blue on the north side.
  twohg = { White = { 0, -29 }, Red = { 0, 29 }, Green = { 180, -29 }, Blue = { 180, 29 } },
}

-- Play surface size per layout (x by z). The 2HG table is wider so two full seats fit on each side.
local SURFACE = {
  four = { 100, 100 },
  two = { 100, 100 },
  three = { 100, 100 },
  twohg = { 120, 100 },
}

-- Teams (Two-Headed Giant only).
local TEAMS = {
  twohg = { White = "A", Red = "A", Green = "B", Blue = "B" },
}

-- Order seats take turns in each layout (clockwise from above).
local SEAT_ORDER = {
  four = { "White", "Red", "Green", "Blue" },
  two = { "White", "Green" },
  three = { "White", "Red", "Green" },
  twohg = { "White", "Red", "Green", "Blue" },
}

-- Areas in seat-local units: side = along the player's right (+) / left (-)
-- from the middle of their edge; depth = distance in from the table edge;
-- w, d = width (sideways) and depth of the area. A card is about 2.2 x 3.1.
-- Areas stay within side -23..27 and depth 3..37 so neighbouring seats'
-- areas never overlap at the corners (checked for all four seats).
local REGIONS = {
  -- right column
  library = { side = 20, depth = 23.5, w = 6, d = 6.5 },
  graveyard = { side = 20, depth = 16, w = 6, d = 6.5 },
  exile = { side = 20, depth = 8.5, w = 6, d = 6.5 },
  -- left: two command zones side by side (commander, partner), each with
  -- its commander tax counter just above it (toward the table center)
  -- command zones (commander, partner or background) up beside the tracker,
  -- each with its commander tax counter just above it
  command1 = { side = -14.0, depth = 31.0, w = 4.2, d = 5.5 },
  command2 = { side = -9.6, depth = 31.0, w = 4.2, d = 5.5 },
  tax1 = { side = -14.0, depth = 35.3, w = 4.2, d = 2.4 },
  tax2 = { side = -9.6, depth = 35.3, w = 4.2, d = 2.4 },
  -- middle: lined up with the lands row, from just above it to the tracker row
  battlefield = { side = -3.5, depth = 17.83, w = 39, d = 15.65 },
  -- turn strip between the battlefield and the top row (turns.lua)
  turnstrip = { side = -0.9, depth = 26.95, w = 30.4, d = 1.6 },
  -- lands row; the Attraction deck sits at its left end (attractions, below)
  lands = { side = -0.5, depth = 6.75, w = 33, d = 5.5 },
  -- action tiles in a strip beside the library column (actions.lua)
  -- (six tiles, a little smaller than the turn tiles so they fit the column: 2.6 x 3.64)
  act_draw = { side = 25.3, depth = 24.9, w = 2.6, d = 3.64 },
  act_scry = { side = 25.3, depth = 21.1, w = 2.6, d = 3.64 },
  act_mill = { side = 25.3, depth = 17.3, w = 2.6, d = 3.64 },
  act_exile = { side = 25.3, depth = 13.5, w = 2.6, d = 3.64 },
  act_untap = { side = 25.3, depth = 9.7, w = 2.6, d = 3.64 },
  act_tokens = { side = 25.3, depth = 5.9, w = 2.6, d = 3.64 },
  -- Attraction deck (attractions.lua), at the left end of the lands row.
  attractions = { side = -20.25, depth = 6.75, w = 5, d = 5.5 },
  -- Mana chip dispenser (mana.lua), left of the command zones.
  mana = { side = -19.8, depth = 30, w = 6.4, d = 4.4 },
  -- CAST mat above the tracker: a card dropped here goes onto the stack.
  castzone = { side = 0, depth = 35.3, w = 13, d = 3.0 },
  -- turn tiles to the right of the tracker (actions.lua)
  act_next = { side = 8.6, depth = 31, w = 3, d = 4.2 },
  act_endstep = { side = 11.9, depth = 31, w = 3, d = 4.2 },
  act_endturn = { side = 15.2, depth = 31, w = 3, d = 4.2 },
  -- clickable life / poison / commander damage tracker, in front of the
  -- playmat toward the table center (trackers.lua)
  tracker = { side = 0, depth = 31, w = 14, d = 4.8 },
  -- The seat's console strip along the table edge, left of the middle (the player's name shows in the
  -- middle of the edge), in front of the lands (actions.lua): Start Game, Turn Options, Roll Dice.
  console = { side = -14.5, depth = 2.2, w = 11, d = 2.0 },
}
TableSetup.REGION_NAMES = { "command1", "command2", "tax1", "tax2", "battlefield", "lands", "library", "graveyard",
  "exile", "tracker" }

-- Older names still used in places: "command" = the first command zone.
local ALIASES = { command = "command1", tax = "tax1" }

local SURFACE_COLOR = { 0.07, 0.08, 0.10 }

---------------------------------------------------------------------------
-- Layout data
---------------------------------------------------------------------------

function TableSetup.layout()
  local d = GameState.data
  return (d and d.table and d.table.layout) or "four"
end

-- Seats that are in play for the current layout, in turn order.
-- A fresh copy each call, so nothing that changes the list it gets back can change the layout's seats.
function TableSetup.activeSeats()
  local out = {}
  for _, c in ipairs(SEAT_ORDER[TableSetup.layout()] or SEAT_ORDER.four) do
    table.insert(out, c)
  end
  return out
end

-- A seat colour that isn't a plain string (seen once: a table got into a seat list). Says where it came from
-- (once per place) so it can be tracked down, and tells the caller to skip it.
local badSeatSeen = {}
function TableSetup.badSeat(c, where)
  if type(c) == "string" then
    return false
  end
  local tb = ""
  pcall(function() tb = debug.traceback("", 2) end)
  local desc = type(c)
  if type(c) == "table" then
    local keys = {}
    pcall(function()
      for k, v in pairs(c) do
        if #keys < 6 then
          table.insert(keys, tostring(k) .. "=" .. tostring(v))
        end
      end
    end)
    desc = "table {" .. table.concat(keys, ", ") .. "}"
  end
  local key = tostring(where) .. "|" .. tb
  if not badSeatSeen[key] then
    badSeatSeen[key] = true
    print("MTG > Skipped a broken seat entry in " .. tostring(where) .. ": " .. desc .. ". Please send Claude this: "
      .. tostring(tb):gsub("\n", " / "))
  end
  return true
end

function TableSetup.isActive(color)
  return LAYOUTS[TableSetup.layout()][color] ~= nil
end

-- Geometry for one seat, or nil if the seat isn't in this layout.
--   center:  middle of the seat's table edge (areas are placed from here)
--   inward:  unit vector toward the table center
--   right:   unit vector to the seated player's right
--   yaw:     rotation (degrees) for cards/decks placed at this seat; same
--            convention the importer has always used (south seat = 180)
--   angle:   the seat's compass angle (south seat = 0)
function TableSetup.seat(color)
  local entry = LAYOUTS[TableSetup.layout()][color]
  if entry == nil then
    return nil
  end
  local angle, offset = entry, 0
  if type(entry) == "table" then
    angle, offset = entry[1], entry[2]
  end
  local rad = math.rad(angle)
  -- Seat position direction from the center (angle 0 = south = -z).
  local ox, oz = -math.sin(rad), -math.cos(rad)
  local sw, sd = TableSetup.surfaceSize()
  -- Distance from the middle to this seat's edge: half the depth for north / south seats, half the width
  -- for east / west ones.
  local half = (math.abs(oz) > 0.5) and (sd / 2) or (sw / 2)
  local rx, rz = -oz, ox
  local cx, cz = ox * half + rx * offset, oz * half + rz * offset

  return {
    center = { x = cx, y = TableSetup.SURFACE_TOP, z = cz },
    inward = { x = -ox, z = -oz },
    right = { x = rx, z = rz },
    yaw = (angle + 180) % 360,
    angle = angle,
    handDist = half - 1.5,
    outward = { x = ox, z = oz },
  }
end

-- The play surface's size for the current layout: width (x), depth (z).
function TableSetup.surfaceSize()
  local sz = SURFACE[TableSetup.layout()] or { TableSetup.SIZE, TableSetup.SIZE }
  return sz[1], sz[2]
end

-- Two-Headed Giant: the team a seat is on ("A" / "B"), or nil outside 2HG.
function TableSetup.teamOf(color)
  local t = TEAMS[TableSetup.layout()]
  return t and t[color] or nil
end

function TableSetup.isTeamGame()
  return TEAMS[TableSetup.layout()] ~= nil
end

-- Are a and b opponents? Different players, and in 2HG not on the same team (a teammate isn't an opponent).
function TableSetup.isOpponent(a, b)
  if a == nil or b == nil or a == b then
    return a ~= b
  end
  -- Set by effects.lua while an "each other player" effect resolves in 2HG (the teammate is included).
  if TableSetup.allOthers then
    return true
  end
  local ta = TableSetup.teamOf(a)
  return ta == nil or ta ~= TableSetup.teamOf(b)
end

-- Same team: the same seat, or 2HG teammates ("your team" on Battlebond cards).
function TableSetup.sameTeam(a, b)
  if a == nil or b == nil then
    return false
  end
  if a == b then
    return true
  end
  local ta = TableSetup.teamOf(a)
  return ta ~= nil and ta == TableSetup.teamOf(b)
end

-- The other player on a seat's team (2HG), or nil.
function TableSetup.teammate(color)
  local team = TableSetup.teamOf(color)
  if team == nil then
    return nil
  end
  for _, c in ipairs(TableSetup.activeSeats()) do
    if c ~= color and TableSetup.teamOf(c) == team then
      return c
    end
  end
  return nil
end

-- Both seats of a team (or just the seat itself outside 2HG).
function TableSetup.teamSeats(color)
  local mate = TableSetup.teammate(color)
  if mate then
    return { color, mate }
  end
  return { color }
end

-- An area for a seat: { center = world position, w, d, yaw }, or nil.
-- Custom background (a 360-degree equirectangular image, 2:1, in the repo).
-- Empty = leave TTS's background alone. Set when the image is pushed.
TableSetup.BACKGROUND_URL = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/background/background.jpg?v=2"

function TableSetup.applyBackground()
  if TableSetup.BACKGROUND_URL ~= "" and Backgrounds and Backgrounds.setCustomURL then
    pcall(function() Backgrounds.setCustomURL(TableSetup.BACKGROUND_URL) end)
  end
end

-- Is a world position inside one of a seat's areas?
function TableSetup.inRegion(color, name, pos)
  local s = TableSetup.seat(color)
  local r = TableSetup.region(color, name)
  if s == nil or r == nil then
    return false
  end
  local dx, dz = pos.x - r.center.x, pos.z - r.center.z
  local side = dx * s.right.x + dz * s.right.z
  local depth = dx * s.inward.x + dz * s.inward.z
  return math.abs(side) <= r.w / 2 and math.abs(depth) <= r.d / 2
end

function TableSetup.region(color, name)
  local s = TableSetup.seat(color)
  local r = REGIONS[ALIASES[name] or name]
  if s == nil or r == nil then
    return nil
  end
  return {
    center = {
      x = s.center.x + s.right.x * r.side + s.inward.x * r.depth,
      y = TableSetup.SURFACE_TOP,
      z = s.center.z + s.right.z * r.side + s.inward.z * r.depth,
    },
    w = r.w,
    d = r.d,
    yaw = s.yaw,
  }
end

-- World position at the middle of an area, at a given height (for spawning).
function TableSetup.slot(color, name, height)
  local r = TableSetup.region(color, name)
  if r == nil then
    return nil
  end
  return { x = r.center.x, y = height or (TableSetup.SURFACE_TOP + 1), z = r.center.z }
end

---------------------------------------------------------------------------
-- Building the table
---------------------------------------------------------------------------

-- Every player color TTS offers. Only the current layout's seats are playable.
local ALL_COLORS = { "White", "Brown", "Red", "Orange", "Yellow",
  "Green", "Teal", "Blue", "Purple", "Pink" }

-- Where each color's hand zone should be. Seats sit at their table edge;
-- unused colors are parked far off the table so their seat orbs disappear.
-- Rotation: TTS's own default uses 0 for south seats and 180 for north, i.e.
-- the seat's compass angle (not the card yaw).
local function handTarget(color)
  local s = TableSetup.seat(color)
  if s then
    return {
      -- Out past the table edge, over the stone rim (the zone is 5 deep: 2.5 .. 7.5 beyond the edge), so a
      -- land dropped at the near edge of the LANDS mat stays on the table instead of falling into the hand.
      position = { x = s.center.x + s.outward.x * 5, y = TableSetup.SURFACE_TOP + 3, z = s.center.z + s.outward.z * 5 },
      rotation = { x = 0, y = s.angle, z = 0 },
      scale = { x = 30, y = 6, z = 5 },
    }
  end
  return {
    position = { x = 0, y = 1, z = -400 },
    rotation = { x = 0, y = 0, z = 0 },
    scale = { x = 1, y = 1, z = 1 },
  }
end

local function near(a, b)
  return math.abs(a.x - b.x) < 0.5 and math.abs(a.z - b.z) < 0.5
end

-- Hand zone objects on the table, by color (fallback when setHandTransform
-- doesn't take effect).
local function handObjectsByColor()
  local byColor = {}
  for _, obj in ipairs(getObjects()) do
    if obj.type == "Hand" then
      local ok, c = pcall(function() return obj.getValue() end)
      if ok and c then
        byColor[c] = obj
      end
    end
  end
  return byColor
end

-- Moves every color's hand zone, then checks they actually moved; any that
-- didn't are moved directly as objects. onDone(report lines) is optional.
local function applyHandZones(onDone)
  local errors = {}
  for _, color in ipairs(ALL_COLORS) do
    if Player[color] then
      local ok, err = pcall(function() Player[color].setHandTransform(handTarget(color)) end)
      if not ok then
        table.insert(errors, color .. ": " .. tostring(err))
      end
    end
  end

  -- Give TTS a moment, then verify and fall back where needed.
  Wait.time(function()
    local stuck = {}
    for _, color in ipairs(ALL_COLORS) do
      local ok, h = pcall(function() return Player[color].getHandTransform() end)
      if not (ok and h and near(h.position, handTarget(color).position)) then
        table.insert(stuck, color)
      end
    end

    local fixed, failed = 0, {}
    if #stuck > 0 then
      local objs = handObjectsByColor()
      for _, color in ipairs(stuck) do
        local obj = objs[color]
        local t = handTarget(color)
        if obj then
          obj.setPosition(t.position)
          obj.setRotation(t.rotation)
          obj.setScale(t.scale)
          fixed = fixed + 1
        else
          table.insert(failed, color)
        end
      end
    end

    local lines = {}
    table.insert(lines, "MTG > Table: " .. TableSetup.layout() .. " layout. Hand zones: "
      .. (10 - #stuck) .. " moved directly, " .. fixed .. " moved as objects"
      .. (#failed > 0 and (", NOT moved: " .. table.concat(failed, ", ")) or ""))
    for _, e in ipairs(errors) do
      table.insert(lines, "MTG > Hand zone error: " .. e)
    end
    for _, l in ipairs(lines) do
      print(l)
    end
    if onDone then
      onDone(lines)
    end
  end, 0.5)
end

-- Chat report of every seat's hand zone, for checking the layout in TTS.
function TableSetup.report()
  print("MTG > Table layout: " .. TableSetup.layout() .. " | surface: "
    .. tostring(GameState.data.table and GameState.data.table.surface) .. " | table: " .. tostring(Tables.getTable()))
  for _, color in ipairs(ALL_COLORS) do
    local ok, h = pcall(function() return Player[color].getHandTransform() end)
    if ok and h then
      local p, r = h.position, h.rotation
      print(string.format("   %-6s hand at (%.0f, %.0f, %.0f) rot %.0f%s", color, p.x, p.y, p.z, r.y,
        TableSetup.isActive(color) and "  [seat]" or ""))
    else
      print("   " .. color .. ": no hand zone (" .. tostring(h) .. ")")
    end
  end
end

-- If a player has taken a color that isn't a seat in this layout, send them
-- back to spectator. Returns true if they were moved.
function TableSetup.enforceSeat(color)
  if color == "Grey" or color == "Black" or TableSetup.isActive(color) then
    return false
  end
  local p = Player[color]
  if p == nil or not p.seated then
    return false
  end
  local name = p.steam_name or color
  p.changeColor("Grey")
  broadcastToAll(name .. ": " .. color .. " isn't a seat at this table. Open seats: "
    .. table.concat(TableSetup.activeSeats(), ", ") .. ".", { 1, 0.6, 0.2 })
  return true
end

-- Check every color (used on load and after a layout change).
function TableSetup.enforceAllSeats()
  for _, color in ipairs(ALL_COLORS) do
    TableSetup.enforceSeat(color)
  end
end

local function spawnSurface(state)
  spawnObject({
    type = "BlockSquare",
    position = { 0, 0, 0 },
    rotation = { 0, 0, 0 },
    scale = { (TableSetup.surfaceSize()), 1, select(2, TableSetup.surfaceSize()) },
    callback_function = function(obj)
      obj.setLock(true)
      obj.setName("Play Surface")
      obj.setColorTint(SURFACE_COLOR)
      obj.interactable = false
      obj.addTag("PlaySurface")
      -- Sit the block so its top face is exactly at SURFACE_TOP.
      local b = obj.getBounds()
      local top = b.center.y + b.size.y / 2
      local p = obj.getPosition()
      obj.setPosition({ p.x, p.y + (TableSetup.SURFACE_TOP - top), p.z })
      state.surface = obj.getGUID()
    end,
  })
end

-- Resize the play surface to the layout (the 2HG table is wider).
function TableSetup.fitSurface()
  local state = GameState.data.table or {}
  local obj = state.surface and getObjectFromGUID(state.surface)
  if obj == nil then
    return
  end
  local w, d = TableSetup.surfaceSize()
  local sc = obj.getScale()
  if math.abs(sc.x - w) > 0.01 or math.abs(sc.z - d) > 0.01 then
    obj.setLock(true)
    obj.setScale({ w, sc.y, d })
    obj.setPosition({ 0, obj.getPosition().y, 0 })
  end
end

-- The 3D frame around the play surface: a gothic stone rim, spired corner
-- towers and stone legs (tools/make_table_model.py). One locked custom model,
-- kept between loads; replaced when its files change version.
local FRAME_BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/table/"
local FRAME_VERSION = "?v=5"

function TableSetup.ensureFrame()
  local state = GameState.data.table
  local mesh = FRAME_BASE .. (TableSetup.layout() == "twohg" and "frame_2hg.obj" or "frame.obj") .. FRAME_VERSION
  local frame = state.frame and getObjectFromGUID(state.frame)
  local co = frame and frame.getCustomObject()
  if frame and co and co.mesh == mesh then
    frame.setLock(true)
    return
  end
  if frame then
    frame.destruct()
  end
  for _, obj in ipairs(getObjectsWithTag("TableFrame")) do
    obj.destruct()
  end
  local obj = spawnObject({
    type = "Custom_Model",
    position = { 0, 0, 0 },
    rotation = { 0, 0, 0 },
    scale = { 1, 1, 1 },
    sound = false,
    callback_function = function(o)
      o.setLock(true)
      o.setPosition({ 0, 0, 0 })
      o.interactable = false
      o.setName("Table Frame")
      o.addTag("TableFrame")
      state.frame = o.getGUID()
    end,
  })
  -- The frame is only for looks. TTS wrapped its full shape (spires and
  -- all) in one invisible box that cards landed on, so its collider is a
  -- tiny cube far under the table instead: cards rest on the real surface.
  obj.setCustomObject({ mesh = mesh, diffuse = FRAME_BASE .. "stone.png" .. FRAME_VERSION,
    collider = FRAME_BASE .. "collider.obj" .. FRAME_VERSION, type = 0, material = 1 })
end

-- The cathedral floor the table stands on: a floating slab of worn flagstones with glowing cracks, a
-- ragged edge and a rocky underside, and a two-step stone dais under the frame's towers
-- (tools/make_floor.py; the texture was painted with Gemini). It catches everything a table flip throws. One locked custom
-- model, kept between loads; replaced when its files change version.
local FLOOR_BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/floor/"
local FLOOR_VERSION = "?v=6"
local FLOOR_Y = -31

function TableSetup.ensureFloor()
  local state = GameState.data.table
  local suffix = TableSetup.layout() == "twohg" and "_2hg" or ""
  local mesh = FLOOR_BASE .. "floor" .. suffix .. ".obj" .. FLOOR_VERSION
  local floor = state.floor and getObjectFromGUID(state.floor)
  local co = floor and floor.getCustomObject()
  if floor and co and co.mesh == mesh then
    floor.setLock(true)
    floor.interactable = false
    return
  end
  if floor then
    floor.destruct()
  end
  for _, obj in ipairs(getObjectsWithTag("TableFloor")) do
    obj.destruct()
  end
  local obj = spawnObject({
    type = "Custom_Model",
    position = { 0, 0, 0 },
    rotation = { 0, 0, 0 },
    scale = { 1, 1, 1 },
    sound = false,
    callback_function = function(o)
      o.setLock(true)
      o.setPosition({ 0, 0, 0 })
      o.setRotation({ 0, 0, 0 })
      o.interactable = false
      o.setName("Cathedral Floor")
      o.addTag("TableFloor")
      o.setDecals({})
      state.floor = o.getGUID()
    end,
  })
  obj.setCustomObject({ mesh = mesh, diffuse = FLOOR_BASE .. "stone_floor.jpg" .. FLOOR_VERSION,
    normal = FLOOR_BASE .. "stone_floor_n.png" .. FLOOR_VERSION,
    collider = mesh,
    convex = false, type = 0, material = 3 })   -- 3: matte (no shine on stone)
end

-- The chapel around the table: a ruined eight-sided gothic chapel standing on the floor -- walls with
-- tall open windows onto the sky, pilasters, and stone rib arches overhead with the roof long gone; the
-- two fireplaces (fires.lua) are built into its cut corners (tools/make_room.py). Its walls face inward
-- only, so a camera pulled back outside the chapel sees straight through them.
local ROOM_VERSION = "?v=3"

function TableSetup.ensureRoom()
  local state = GameState.data.table
  local suffix = TableSetup.layout() == "twohg" and "_2hg" or ""
  local base = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/"
  local mesh = base .. "room/room" .. suffix .. ".obj" .. ROOM_VERSION
  local room = state.room and getObjectFromGUID(state.room)
  local co = room and room.getCustomObject()
  if room and co and co.mesh == mesh then
    room.setLock(true)
    room.interactable = false
    room.setPosition({ 0, FLOOR_Y, 0 })
    room.setRotation({ 0, 0, 0 })
    return
  end
  if room then
    room.destruct()
  end
  for _, obj in ipairs(getObjectsWithTag("TableRoom")) do
    obj.destruct()
  end
  local obj = spawnObject({
    type = "Custom_Model",
    position = { 0, FLOOR_Y, 0 },
    rotation = { 0, 0, 0 },
    scale = { 1, 1, 1 },
    sound = false,
    callback_function = function(o)
      o.setLock(true)
      o.setPosition({ 0, FLOOR_Y, 0 })
      o.setRotation({ 0, 0, 0 })
      o.interactable = false
      o.setName("Ruined Chapel")
      o.addTag("TableRoom")
      state.room = o.getGUID()
    end,
  })
  obj.setCustomObject({ mesh = mesh, diffuse = base .. "table/stone.png?v=3", collider = mesh, convex = false,
    type = 0, material = 3, cast_shadows = false })   -- 3: matte (no shine on stone)
end

-- The chapel's roof (tools/make_roof.py): a stone lid over the rib vault, hidden while you play (the vault
-- stays open to the sky). When TTS's own Flip button throws the chapel around, the roof appears on it with a
-- parting message painted on top -- a different one every flip -- and goes away again once the chapel is
-- back in place. Its collider is a tiny box (assets/room/roof_collider.obj), so the falling chapel never snags on it.
local ROOF_VERSION = "?v=3"
local ROOF_LID = 186.0       -- the lid's height above the floor (tools/make_roof.py LID)
local ALL_COLORS_INV = { "White", "Brown", "Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink",
  "Grey", "Black" }
local ROOF_FAREWELLS = {
  "BYE 2 U 2", "SEE YA", "SMELL YA LATER", "GG NO RE", "PEACE OUT", "LATER, NERDS", "HASTA LA VISTA",
  "TABLE HAS LEFT THE CHAT", "IT'S NOT ME, IT'S YOU", "NO TAKE-BACKS", "SKILL ISSUE", "GO TOUCH GRASS",
  "CTRL + Z?", "WELP.", "YEET", "BOARD WIPE!", "MULLIGAN TO ZERO", "RAGE QUIT SPEEDRUN", "THANKS FOR PLAYING",
  "SHUFFLE THAT", "BYE FELICIA", "TOODLES", "ADIOS, AMIGOS", "I DIDN'T LIKE THAT GAME ANYWAY",
  -- Trash talk (kept clean).
  "CRY ABOUT IT", "GIT GUD", "STAY MAD", "COPE", "L + RATIO", "GET REKT", "EZ CLAP", "TOO EASY", "OUTPLAYED",
  "SIT DOWN", "NEXT!", "HOLD THIS L", "BIG MAD", "SALTY MUCH?", "SODIUM LEVELS: HIGH", "BOO HOO", "WAH WAH",
  "SORRY NOT SORRY", "NOT EVEN CLOSE", "IMAGINE LOSING", "WAS THAT YOUR BEST?", "WHO INVITED YOU?",
  "SEE YOU NEVER", "DON'T LET THE DOOR HIT YA", "STICK TO CHECKERS", "UNINSTALL", "SKILL: 0",
  "YOUR DECK IS JANK", "YOUR COMMANDER IS MID", "PRECON ENERGY", "BRING A REAL DECK", "BUILD A BETTER DECK",
  "NICE NETDECK", "GO PLAY ARENA", "CASUAL DETECTED", "YOU HAD ZERO OUTS", "CONCEDE FASTER NEXT TIME",
  "TAP TO CRY", "COUNTERED.", "EXILE YOURSELF", "BOTTOM OF THE LIBRARY", "BACK TO KITCHEN TABLE MAGIC",
  "LAND, GO... HOME", "SHOULD HAVE MULLIGANED", "YOUR HAND WAS ALL LANDS", "SKIP YOUR NEXT GAME TOO",
}
local roofShown, roofLast = false, nil

local function roofObj()
  local st = GameState.data.table or {}
  local o = st.roof and getObjectFromGUID(st.roof)
  if o and not o.isDestroyed() then
    return o
  end
  return nil
end

local function hideRoof(o)
  pcall(function() o.setInvisibleTo(ALL_COLORS_INV) end)
  pcall(function() o.clearButtons() end)
  o.setLock(true)
  o.setPosition({ 0, FLOOR_Y, 0 })
  o.setRotation({ 0, 0, 0 })
end

function TableSetup.ensureRoof()
  local state = GameState.data.table
  local suffix = TableSetup.layout() == "twohg" and "_2hg" or ""
  local base = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/"
  local mesh = base .. "room/roof" .. suffix .. ".obj" .. ROOF_VERSION
  local roof = roofObj()
  local co = roof and roof.getCustomObject()
  if roof and co and co.mesh == mesh then
    roofShown = false
    hideRoof(roof)
    return
  end
  if roof then
    roof.destruct()
  end
  for _, obj in ipairs(getObjectsWithTag("TableRoof")) do
    obj.destruct()
  end
  local obj = spawnObject({
    type = "Custom_Model",
    position = { 0, FLOOR_Y, 0 },
    rotation = { 0, 0, 0 },
    scale = { 1, 1, 1 },
    sound = false,
    callback_function = function(o)
      o.interactable = false
      o.setName("Chapel Roof")
      o.addTag("TableRoof")
      state.roof = o.getGUID()
      roofShown = false
      hideRoof(o)
    end,
  })
  obj.setCustomObject({ mesh = mesh, diffuse = base .. "table/stone.png?v=3", collider = base .. "room/roof_collider.obj" .. ROOF_VERSION, convex = true,
    type = 0, material = 3, cast_shadows = false })
end

-- Paint a farewell on top of the roof (never the same one twice running).
local function paintRoof(o)
  local n = #ROOF_FAREWELLS
  local i = math.random(n)
  if ROOF_FAREWELLS[i] == roofLast and n > 1 then
    i = i % n + 1
  end
  roofLast = ROOF_FAREWELLS[i]
  pcall(function() o.clearButtons() end)
  local size = math.floor(math.min(1000, 14000 / #roofLast))
  -- A thick black outline (eight copies around it), then the message itself on top.
  local d = size / 1000 * 0.9
  for _, off in ipairs({ { -1, -1 }, { 0, -1 }, { 1, -1 }, { -1, 0 }, { 1, 0 }, { -1, 1 }, { 0, 1 }, { 1, 1 } }) do
    pcall(function()
      o.createButton({
        click_function = "roof_noop", function_owner = Global, label = roofLast,
        position = { off[1] * d, ROOF_LID + 0.35, off[2] * d }, rotation = { 0, 180, 0 }, scale = { 9, 1, 9 },
        width = 0, height = 0, font_size = size, font_color = { 0, 0, 0, 100 }, color = { 0, 0, 0, 0 },
      })
    end)
  end
  pcall(function()
    o.createButton({
      click_function = "roof_noop", function_owner = Global, label = roofLast,
      position = { 0, ROOF_LID + 0.45, 0 }, rotation = { 0, 180, 0 }, scale = { 9, 1, 9 },
      width = 0, height = 0, font_size = size, font_color = { 1, 0.3, 0.42, 100 }, color = { 0, 0, 0, 0 },
    })
  end)
end

function roof_noop() end

-- Watch the chapel: TTS's Flip throws it out of place. While it's out, the roof rides along with it.
local function watchRoom()
  local st = GameState.data and GameState.data.table or {}
  local room = st.room and getObjectFromGUID(st.room)
  local roof = roofObj()
  if room == nil or room.isDestroyed() or roof == nil then
    return
  end
  local p, r = room.getPosition(), room.getRotation()
  local function off(a)
    a = a % 360
    return math.min(a, 360 - a)
  end
  local displaced = math.abs(p.x) + math.abs(p.z) + math.abs(p.y - FLOOR_Y) > 2
    or off(r.x) + off(r.y) + off(r.z) > 3
  if displaced and not roofShown then
    roofShown = true
    paintRoof(roof)
    pcall(function() roof.setInvisibleTo({}) end)
    -- Ride along with the chapel every frame while it's out of place.
    local function follow()
      if not roofShown or room.isDestroyed() or roof.isDestroyed() then
        return
      end
      roof.setPosition(room.getPosition())
      roof.setRotation(room.getRotation())
      Wait.frames(follow, 1)
    end
    follow()
  elseif not displaced and roofShown then
    roofShown = false
    hideRoof(roof)
  end
end
Wait.time(function() pcall(watchRoom) end, 0.5, -1)

-- Stained glass in the chapel windows: translucent, glowing jewel-tone glass you can still see through;
-- the window behind each seat leans to that seat's colour (sun, drop, flame, leaf) and the two big
-- corner windows hold all five colours. A Unity AssetBundle (tools/unity/MTGGlassBuilder.cs).
local GLASS_VERSION = "?v=4"

function TableSetup.ensureGlass()
  local state = GameState.data.table
  local base = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/glass/"
  local url = base .. (TableSetup.layout() == "twohg" and "mtg_glass_2hg" or "mtg_glass") .. ".unity3d" .. GLASS_VERSION
  local glass = state.glass and getObjectFromGUID(state.glass)
  local co = glass and glass.getCustomObject()
  if glass and co and co.assetbundle == url then
    glass.setLock(true)
    glass.interactable = false
    glass.setPosition({ 0, FLOOR_Y, 0 })
    glass.setRotation({ 0, 0, 0 })
    return
  end
  if glass then
    glass.destruct()
  end
  for _, obj in ipairs(getObjectsWithTag("TableGlass")) do
    obj.destruct()
  end
  local obj = spawnObject({
    type = "Custom_AssetBundle",
    position = { 0, FLOOR_Y, 0 },
    rotation = { 0, 0, 0 },
    scale = { 1, 1, 1 },
    sound = false,
    callback_function = function(o)
      o.setLock(true)
      o.setPosition({ 0, FLOOR_Y, 0 })
      o.setRotation({ 0, 0, 0 })
      o.interactable = false
      o.setName("Stained Glass")
      o.addTag("TableGlass")
      state.glass = o.getGUID()
      if Fires then
        Wait.time(function() Fires.refresh() end, 1)
      end
    end,
  })
  obj.setCustomObject({ assetbundle = url, type = 0 })
end

-- Braziers: an iron brazier with coals and a colour-changing fire on top of each of the frame's four
-- towers (a Unity AssetBundle: tools/unity/MTGTorchBuilder.cs, no sound). They replaced the old wall
-- sconces and the towers' spires. Still called "torches" in the code (fires.lua lights them).
local TORCH_URL = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/torch/mtg_brazier.unity3d?v=2"
local TOWER_TOP = 13.6       -- the flat top of each tower (tools/make_table_model.py: lip + 12)
local BRAZIER_UP = 1.7       -- the bundle's origin is the coal bed, 1.7 above its feet
local TOWER_HALF = 4.2       -- frame edge to the tower's centre

local function torchSpots()
  local hx = TableSetup.layout() == "twohg" and 66.7 or 56.7
  local hz = 56.7
  local out = {}
  for _, sx in ipairs({ 1, -1 }) do
    for _, sz in ipairs({ 1, -1 }) do
      local cx, cz = sx * (hx - TOWER_HALF), sz * (hz - TOWER_HALF)
      table.insert(out, {
        pos = { cx, TOWER_TOP + BRAZIER_UP, cz },
        yaw = math.deg(math.atan2 and math.atan2(sx, sz) or math.atan(sx, sz)),
      })
    end
  end
  return out
end

function TableSetup.placeTorches()
  local state = GameState.data.table or {}
  local spots = torchSpots()
  for i, g in ipairs(state.torches or {}) do
    local o = getObjectFromGUID(g)
    local sp = spots[i]
    if o and sp then
      o.setLock(true)
      o.setPosition(sp.pos)
      o.setRotation({ 0, sp.yaw, 0 })
    end
  end
end

function TableSetup.ensureTorches()
  local state = GameState.data.table
  state.torches = state.torches or {}
  -- Keep the four we have if they're this version; otherwise start over.
  local good = #state.torches == 4
  for _, g in ipairs(state.torches) do
    local o = getObjectFromGUID(g)
    local co = o and o.getCustomObject()
    good = good and co ~= nil and co.assetbundle == TORCH_URL
  end
  if good then
    TableSetup.placeTorches()
    return
  end
  for _, g in ipairs(state.torches) do
    local o = getObjectFromGUID(g)
    if o then
      o.destruct()
    end
  end
  for _, o in ipairs(getObjectsWithTag("TableTorch")) do
    o.destruct()
  end
  state.torches = {}
  for i, sp in ipairs(torchSpots()) do
    local obj = spawnObject({
      type = "Custom_AssetBundle",
      position = sp.pos,
      rotation = { 0, sp.yaw, 0 },
      scale = { 1, 1, 1 },
      sound = false,
      callback_function = function(o)
        o.setLock(true)
        o.setPosition(sp.pos)
        o.setRotation({ 0, sp.yaw, 0 })
        o.interactable = false
        o.setName("Brazier")
        o.addTag("TableTorch")
        state.torches[i] = o.getGUID()
        if Fires then
          Wait.time(function() Fires.refresh() end, 1)
        end
      end,
    })
    obj.setCustomObject({ assetbundle = TORCH_URL, type = 0, material = 2 })
  end
end

-- Moody lighting to match the dark background: a dimmer, cold key light
-- and a blue-violet ambient glow.
function TableSetup.applyLighting()
  pcall(function()
    Lighting.light_intensity = 0.9
    Lighting.setLightColor({ r = 0.78, g = 0.84, b = 1.0 })
    -- 2 = gradient: ambient light from the three colours below, NOT from the background picture (its warm
    -- patches washed whole chapel walls sunset-orange)
    Lighting.ambient_type = 2
    Lighting.setAmbientSkyColor({ r = 0.30, g = 0.28, b = 0.46 })
    Lighting.setAmbientEquatorColor({ r = 0.16, g = 0.18, b = 0.28 })
    Lighting.setAmbientGroundColor({ r = 0.05, g = 0.05, b = 0.08 })
    Lighting.ambient_intensity = 1.1
    Lighting.reflection_intensity = 0.35
    Lighting.apply()
  end)
end

-- The play surface, the frame and the mat labels shouldn't take the mouse:
-- holding Alt with nothing else under the cursor then shows no zoom, instead
-- of zooming on the empty table. (Saved objects can predate the setting, so
-- it's applied again on every load.)
function TableSetup.ignorePointer()
  local state = GameState.data.table or {}
  local list = { state.surface, state.frame, state.floor }
  for _, g in ipairs(state.labels or {}) do
    table.insert(list, g)
  end
  for _, g in ipairs(list) do
    local o = g and getObjectFromGUID(g)
    if o and not o.isDestroyed() then
      pcall(function() o.interactable = false end)
    end
  end
  for _, tag in ipairs({ "PlaySurface", "TableFrame", "TableFloor", "TableHearth", "HearthFire", "FireCrackle", "FireSfx", "StackFire", "TableTorch", "TableRoom", "TableRoof", "TableGlass", "MatLabel" }) do
    for _, o in ipairs(getObjectsWithTag(tag)) do
      pcall(function() o.interactable = false end)
    end
  end
end

-- No TTS table: ours is the custom surface and frame. (v1.85 tried hiding TTS's own table under ours so
-- its Flip Table button would work, but TTS won't let a script move its table, so it showed up under
-- ours and caught falling pieces. Back to none.)
function TableSetup.ensureNative()
  pcall(function()
    if Tables.getTable() ~= "Table_None" then
      Tables.setTable("Table_None")
    end
  end)
  -- Only one play surface: a stray copy (e.g. left behind by a flip) is removed.
  local state = GameState.data.table or {}
  for _, o in ipairs(getObjectsWithTag("PlaySurface")) do
    if state.surface and o.getGUID() ~= state.surface then
      o.destruct()
    end
  end
end

-- !tableinfo: what TTS table is set, plus every big object sitting below the play surface (to track
-- down anything showing under the table).
function TableSetup.tableInfo()
  local lines = { "TTS table setting: " .. tostring(Tables.getTable()) .. (Tables.getTableObject() and " (object present)" or "") }
  for _, o in ipairs(getObjects()) do
    pcall(function()
      local b = o.getBounds()
      if b.center.y < TableSetup.SURFACE_TOP - 0.5 and b.size.x * b.size.z > 30 then
        table.insert(lines, string.format("  %s '%s' [%s] at (%.0f, %.1f, %.0f) size %.0f x %.0f", o.type,
          tostring(o.getName()), o.getGUID(), b.center.x, b.center.y, b.center.z, b.size.x, b.size.z))
      end
    end)
  end
  return table.concat(lines, "\n")
end

-- Make sure the table exists and matches the current layout. Safe to call
-- every load: the surface is only created once.
-- Two-Headed Giant: teammates see each other's hands. TTS shares hands between players on the same team,
-- so White + Red go on one team (Hearts) and Green + Blue on the other (Spades); other layouts: no teams.
function TableSetup.applyTeams()
  local names = { A = "Hearts", B = "Spades" }
  local map = TEAMS[TableSetup.layout()]
  for _, c in ipairs({ "White", "Red", "Green", "Blue" }) do
    local want = map and map[c] and names[map[c]] or "None"
    pcall(function()
      local p = Player[c]
      if p and p.seated and p.team ~= want then
        p.team = want
      end
    end)
  end
end

function TableSetup.ensure()
  local d = GameState.data
  d.table = d.table or { layout = "four" }
  local state = d.table
  pcall(TableSetup.applyTeams)

  TableSetup.ensureNative()

  if not (state.surface and getObjectFromGUID(state.surface)) then
    spawnSurface(state)
  else
    TableSetup.fitSurface()
  end
  TableSetup.ensureFrame()
  pcall(TableSetup.ensureFloor)
  pcall(TableSetup.ensureRoom)
  pcall(TableSetup.ensureRoof)
  pcall(TableSetup.ensureGlass)
  -- The braziers and fireplaces load a few seconds later, so a player joining doesn't get every
  -- asset bundle at the same moment (big bursts can time out a Steam connection).
  Wait.time(function()
    pcall(TableSetup.ensureTorches)
    if Fires then
      pcall(Fires.ensure)
    end
    if Rulebook and Rulebook.ensure then
      pcall(Rulebook.ensure)
    end
    TableSetup.ignorePointer()
  end, 3)
  TableSetup.ignorePointer()
  TableSetup.applyLighting()

  applyHandZones()
  TableSetup.drawMats()
  if Zones then
    Zones.ensure()
  end
end

---------------------------------------------------------------------------
-- Playmats: outlined areas with labels for every active seat
-- Outlines are vector lines (drawn on the table, not objects); labels are
-- locked 3D text objects, remembered in GameState so they can be replaced
-- when the layout changes. Phase 2 adds icons/markers on these same areas.
---------------------------------------------------------------------------

-- Muted versions of each seat color for the outlines and labels.
local SEAT_TINT = {
  White = { 0.78, 0.80, 0.86 },
  Red = { 0.86, 0.33, 0.33 },
  Green = { 0.32, 0.76, 0.42 },
  Blue = { 0.32, 0.58, 0.95 },
}

local LABELS = {
  command1 = "COMMANDER",
  command2 = "PARTNER / BACKGROUND",
  battlefield = "BATTLEFIELD",
  lands = "LANDS",
  library = "LIBRARY",
  graveyard = "GRAVEYARD",
  exile = "EXILE",
}

local LINE_HEIGHT = 0.03 -- just above the surface so lines aren't hidden
local DRAW_OLD_LABELS = false  -- 3D text labels (replaced by the area images)

-- The four corners of an area, closed back to the first point.
local function outlinePoints(color, name)
  local s = TableSetup.seat(color)
  local r = TableSetup.region(color, name)
  local y = TableSetup.SURFACE_TOP + LINE_HEIGHT
  local hw, hd = r.w / 2, r.d / 2
  local pts = {}
  for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 }, { -1, -1 } }) do
    table.insert(pts, {
      r.center.x + s.right.x * c[1] * hw + s.inward.x * c[2] * hd,
      y,
      r.center.z + s.right.z * c[1] * hw + s.inward.z * c[2] * hd,
    })
  end
  return pts
end

-- Where an area's label goes: just inside the far edge of the box.
local function labelPosition(color, name)
  local s = TableSetup.seat(color)
  local r = TableSetup.region(color, name)
  local offset = r.d / 2 - 0.8
  return {
    r.center.x + s.inward.x * offset,
    TableSetup.SURFACE_TOP + 0.02,
    r.center.z + s.inward.z * offset,
  }
end

local function clearLabels(state)
  for _, guid in ipairs(state.labels or {}) do
    local obj = getObjectFromGUID(guid)
    if obj then
      obj.destruct()
    end
  end
  state.labels = {}
end

-- Areas are drawn as images (zones.lua, Zones.drawIcons): borders, titles and
-- icons are all part of each image. This only clears the outlines and text
-- labels earlier versions drew.
function TableSetup.drawMats()
  local state = GameState.data.table
  Global.setVectorLines({})
  clearLabels(state)
  for _, obj in ipairs(getObjectsWithTag("MatLabel")) do
    obj.destruct()
  end
  if not DRAW_OLD_LABELS then
    return
  end
  for _, color in ipairs(TableSetup.activeSeats()) do
    local s = TableSetup.seat(color)
    local tint = SEAT_TINT[color] or { 0.7, 0.7, 0.7 }
    for _, name in ipairs(TableSetup.REGION_NAMES) do
      if LABELS[name] then
      spawnObject({
        type = "3DText",
        position = labelPosition(color, name),
        -- Same facing that made the command zone label readable from the seat.
        rotation = { 90, s.angle, 0 },
        callback_function = function(label)
          label.TextTool.setValue(LABELS[name])
          label.TextTool.setFontSize((name == "command1" or name == "command2") and 22 or 30)
          label.TextTool.setFontColor(tint)
          label.setLock(true)
          label.interactable = false
          label.addTag("MatLabel")
          table.insert(state.labels, label.getGUID())
        end,
      })
      end
    end
  end
end

-- Point a player's camera at their seat: behind their edge of the table,
-- looking across their area toward the middle. Camera yaw uses the seat's
-- compass angle (south seat = 0); the card yaw put the camera on the
-- opposite side of the table in testing.
function TableSetup.lookAtSeat(color)
  local s = TableSetup.seat(color)
  if s == nil or Player[color] == nil or not Player[color].seated then
    return
  end
  Player[color].lookAt({
    position = {
      x = s.center.x + s.inward.x * 15,
      y = TableSetup.SURFACE_TOP,
      z = s.center.z + s.inward.z * 15,
    },
    pitch = 55,
    yaw = s.angle,
    distance = 45,
  })
end

-- Point every seated player's camera at their seat, after a short wait (so it lands after any
-- seat changes, table resizes or reloads that are still going on).
function TableSetup.lookAtAll(delay)
  Wait.time(function()
    for _, color in ipairs(TableSetup.activeSeats()) do
      pcall(TableSetup.lookAtSeat, color)
    end
  end, delay or 1)
end

-- Switch layout ("four", "two", "three" or "twohg") and reposition hand zones.
function TableSetup.setLayout(layout)
  if LAYOUTS[layout] == nil then
    return false
  end
  GameState.data.table = GameState.data.table or {}
  GameState.data.table.layout = layout
  Wait.time(function() pcall(TableSetup.applyTeams) end, 0.5)
  TableSetup.fitSurface()
  TableSetup.ensureFrame()
  pcall(TableSetup.ensureFloor)
  pcall(TableSetup.placeTorches)
  pcall(TableSetup.ensureRoom)
  pcall(TableSetup.ensureRoof)
  pcall(TableSetup.ensureGlass)
  if Fires then
    pcall(Fires.ensure)
  end
  if Rulebook and Rulebook.ensure then
    pcall(Rulebook.ensure)
  end
  applyHandZones()
  TableSetup.drawMats()
  if Zones then
    Zones.ensure()
  end
  TableSetup.enforceAllSeats()
  TableSetup.lookAtAll(1)
  if Planechase and Planechase.placeChest then
    pcall(Planechase.placeChest)
  end
  return true
end
