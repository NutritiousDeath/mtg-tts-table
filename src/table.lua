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

  Chat commands (in main.lua): !layout 4, !layout 2, !view
--]]

TableSetup = {}

TableSetup.SIZE = 100          -- surface is SIZE x SIZE units
TableSetup.SURFACE_TOP = 1.0   -- height of the play surface's top face

-- Seat compass directions per layout. Angle = where the seat sits around the
-- table, in degrees: 0 = south (-z), 90 = west (-x), 180 = north, 270 = east.
local LAYOUTS = {
  four = { White = 0, Red = 90, Green = 180, Blue = 270 },
  two = { White = 0, Green = 180 },
}

-- Order seats take turns in each layout (clockwise from above).
local SEAT_ORDER = {
  four = { "White", "Red", "Green", "Blue" },
  two = { "White", "Green" },
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
  lands = { side = -3.5, depth = 6.75, w = 39, d = 5.5 },
  -- action tiles in a strip beside the library column (actions.lua)
  act_draw = { side = 25.3, depth = 24.6, w = 3, d = 4.2 },
  act_scry = { side = 25.3, depth = 19.9, w = 3, d = 4.2 },
  act_mill = { side = 25.3, depth = 15.2, w = 3, d = 4.2 },
  act_untap = { side = 25.3, depth = 10.5, w = 3, d = 4.2 },
  act_tokens = { side = 25.3, depth = 5.8, w = 3, d = 4.2 },
  -- Mana chip dispenser (mana.lua), left of the command zones.
  mana = { side = -19.8, depth = 30, w = 6.4, d = 4.4 },
  -- turn tiles to the right of the tracker (actions.lua)
  act_next = { side = 8.6, depth = 31, w = 3, d = 4.2 },
  act_endstep = { side = 11.9, depth = 31, w = 3, d = 4.2 },
  act_endturn = { side = 15.2, depth = 31, w = 3, d = 4.2 },
  -- clickable life / poison / commander damage tracker, in front of the
  -- playmat toward the table center (trackers.lua)
  tracker = { side = 0, depth = 31, w = 14, d = 4.8 },
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
function TableSetup.activeSeats()
  return SEAT_ORDER[TableSetup.layout()]
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
  local angle = LAYOUTS[TableSetup.layout()][color]
  if angle == nil then
    return nil
  end
  local rad = math.rad(angle)
  -- Seat position direction from the center (angle 0 = south = -z).
  local ox, oz = -math.sin(rad), -math.cos(rad)
  local half = TableSetup.SIZE / 2

  return {
    center = { x = ox * half, y = TableSetup.SURFACE_TOP, z = oz * half },
    inward = { x = -ox, z = -oz },
    right = { x = -oz, z = ox },
    yaw = (angle + 180) % 360,
    angle = angle,
    handDist = half - 1.5,
    outward = { x = ox, z = oz },
  }
end

-- An area for a seat: { center = world position, w, d, yaw }, or nil.
-- Custom background (a 360-degree equirectangular image, 2:1, in the repo).
-- Empty = leave TTS's background alone. Set when the image is pushed.
TableSetup.BACKGROUND_URL = ""

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
      position = { x = s.outward.x * s.handDist, y = TableSetup.SURFACE_TOP + 3, z = s.outward.z * s.handDist },
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
    scale = { TableSetup.SIZE, 1, TableSetup.SIZE },
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

-- Make sure the table exists and matches the current layout. Safe to call
-- every load: the surface is only created once.
function TableSetup.ensure()
  local d = GameState.data
  d.table = d.table or { layout = "four" }
  local state = d.table

  if Tables.getTable() ~= "Table_None" then
    Tables.setTable("Table_None")
  end

  if not (state.surface and getObjectFromGUID(state.surface)) then
    spawnSurface(state)
  end

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

-- Switch layout ("four" or "two") and reposition hand zones.
function TableSetup.setLayout(layout)
  if LAYOUTS[layout] == nil then
    return false
  end
  GameState.data.table = GameState.data.table or {}
  GameState.data.table.layout = layout
  applyHandZones()
  TableSetup.drawMats()
  if Zones then
    Zones.ensure()
  end
  TableSetup.enforceAllSeats()
  for _, color in ipairs(TableSetup.activeSeats()) do
    TableSetup.lookAtSeat(color)
  end
  return true
end
