--[[
  mana.lua
  Reusable mana chips. Each seat has a MANA tile left of its command zones
  showing six chips (W U B R G and colorless C):
    click a chip       take 1 of that color
    right-click        take 3
  Chips land just in front of the tile and stack by color. To put chips
  away, drop them back on any MANA tile, or right-click a chip > Return chip
  (works for everyone, no promotion needed).
  Art: assets/mana/ (tools/make_mana_art.py).
--]]

ManaChips = {}

local ART_BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/mana/"
local ART_VERSION = "?v=1"
local TILE_W = 6.4
local CHIP_W = 1.05
local INFO = { 0.75, 0.8, 0.9 }

-- Same order and spots as tools/make_mana_art.py (x right, z toward the player).
local CHIPS = {
  { key = "W", name = "White mana", x = -2.0, z = -0.55 },
  { key = "U", name = "Blue mana", x = 0.0, z = -0.55 },
  { key = "B", name = "Black mana", x = 2.0, z = -0.55 },
  { key = "R", name = "Red mana", x = -2.0, z = 1.30 },
  { key = "G", name = "Green mana", x = 0.0, z = 1.30 },
  { key = "C", name = "Colorless mana", x = 2.0, z = 1.30 },
}
local BY_KEY = {}
for _, c in ipairs(CHIPS) do
  BY_KEY[c.key] = c
end

local function tiles()
  GameState.data.table = GameState.data.table or {}
  GameState.data.table.manaTiles = GameState.data.table.manaTiles or {}
  return GameState.data.table.manaTiles
end

local function chipUrl(key)
  return ART_BASE .. "chip_" .. key .. ".png" .. ART_VERSION
end

-- Put a chip away (right-click "Return chip", or dropped on a MANA tile).
function ManaChips.returnChip(obj)
  if obj ~= nil and not obj.isDestroyed() and obj.hasTag("ManaChip") then
    obj.destruct()
  end
end

local function chipMenu(obj)
  obj.clearContextMenu()
  obj.addContextMenuItem("Return chip", function() ManaChips.returnChip(obj) end)
end

-- Spawn n chips of a color in front of a seat's MANA tile, stacked.
function ManaChips.take(color, key, n)
  local c = BY_KEY[key]
  local r = TableSetup.region(color, "mana")
  local s = TableSetup.seat(color)
  if c == nil or r == nil then
    return
  end
  -- In front of the tile, toward the battlefield, under this chip's column.
  local depthOff = -(r.d / 2 + 0.9)
  local px = r.center.x + s.right.x * c.x + s.inward.x * depthOff
  local pz = r.center.z + s.right.z * c.x + s.inward.z * depthOff
  for i = 1, n do
    local obj = spawnObject({
      type = "Custom_Token",
      position = { px, TableSetup.SURFACE_TOP + 0.6 + i * 0.25, pz },
      rotation = { 0, s.yaw, 0 },
      sound = false,
      callback_function = function(o)
        o.setName(c.name)
        o.addTag("ManaChip")
        chipMenu(o)
        Wait.condition(function()
          local b = o.getBoundsNormalized()
          local w = b and b.size and b.size.x or 0
          if w > 0.05 then
            local k = CHIP_W / (w / o.getScale().x)
            o.setScale({ k, 1, k })
          end
        end, function() return o.isDestroyed() or not o.loading_custom end, 10)
      end,
    })
    obj.setCustomObject({ image = chipUrl(key), thickness = 0.15, merge_distance = 5, stackable = true })
  end
end

local function renderTile(color)
  local guid = tiles()[color]
  local tile = guid and getObjectFromGUID(guid)
  if tile == nil then
    return
  end
  tile.clearButtons()
  for _, c in ipairs(CHIPS) do
    local fn = "mana_" .. color .. "_" .. c.key
    _G[fn] = function(_, playerColor, alt)
      if playerColor ~= color then
        broadcastToColor("Those are " .. color .. "'s mana chips.", playerColor, { 1, 0.6, 0.2 })
        return
      end
      ManaChips.take(color, c.key, alt and 3 or 1)
    end
    Trackers.tileButton(tile, { label = "", click_function = fn,
      tooltip = string.upper(c.name) .. "\nClick: take 1 chip\nRight-click: take 3\nDrop chips back here to put them away",
      width = 440, height = 440, color = { 0, 0, 0, 0 }, hover_color = { 1, 1, 1, 0.1 },
      press_color = { 1, 1, 1, 0.2 } }, c.x, c.z)
  end
end

function ManaChips.ensure()
  local wanted = {}
  for _, color in ipairs(TableSetup.activeSeats()) do
    table.insert(wanted, { key = color, color = color, region = "mana", name = "Mana (" .. color .. ")",
      url = ART_BASE .. "mana_tile.png" .. ART_VERSION, width = TILE_W,
      draw = function() renderTile(color) end })
  end
  Trackers.syncTiles("ManaTile", { { registry = tiles(), wanted = wanted } })
  -- Chips already on the table (after a load) get their menu back.
  for _, obj in ipairs(getObjectsWithTag("ManaChip")) do
    chipMenu(obj)
  end
end

-- A chip dropped on any MANA tile is put away.
function ManaChips.onDrop(obj)
  if obj == nil or obj.isDestroyed() or not obj.hasTag("ManaChip") then
    return
  end
  local p = obj.getPosition()
  for _, color in ipairs(TableSetup.activeSeats()) do
    if TableSetup.inRegion(color, "mana", p) then
      ManaChips.returnChip(obj)
      return
    end
  end
end
