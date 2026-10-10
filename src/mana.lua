--[[
  mana.lua
  Mana pool. Each seat has a MANA tile left of its command zones showing six
  colors (W U B R G and colorless C). The pool is counted ON the tile: a number
  beside a color's circle (nothing shows at 0).
    click a color   +1        right-click   -1
  It fills itself: tap a land / mana creature / artifact by hand and what it
  makes is added (a land that can make one of several colors asks which), and
  effects like Dark Ritual add theirs. Casting a spell or activating an ability
  takes its mana cost out of the pool. The pool empties when the step changes
  (the rules do this too).
  Art: assets/mana/ (tools/make_mana_art.py).
--]]

ManaChips = {}

local ART_BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/mana/"
local ART_VERSION = "?v=2"
local TILE_W = 6.4
local INFO = { 0.75, 0.8, 0.9 }
local BADGE_DX, BADGE_DZ = 0.58, -0.52   -- the count is a small badge at the circle's upper right
local ORDER = { "W", "U", "B", "R", "G", "C" }

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

local function pool(color)
  GameState.data.mana = GameState.data.mana or {}
  GameState.data.mana[color] = GameState.data.mana[color] or {}
  return GameState.data.mana[color]
end

function ManaChips.get(color, key)
  return pool(color)[key] or 0
end

local renderTile

-- Add (or take away) mana of one color. Never below 0.
function ManaChips.add(color, key, delta)
  if BY_KEY[key] == nil or delta == nil or delta == 0 then
    return
  end
  local p = pool(color)
  p[key] = math.max(0, (p[key] or 0) + delta)
  if p[key] == 0 then
    p[key] = nil
  end
  renderTile(color)
end

-- Mana empties between steps. True if anything was in a pool.
function ManaChips.emptyAll()
  local any = false
  for _, color in ipairs(TableSetup.activeSeats()) do
    local p = pool(color)
    if next(p) ~= nil then
      any = true
      GameState.data.mana[color] = {}
      renderTile(color)
    end
  end
  return any
end

function ManaChips.summary(color)
  local parts = {}
  for _, k in ipairs(ORDER) do
    local n = ManaChips.get(color, k)
    if n > 0 then
      table.insert(parts, n .. k)
    end
  end
  return #parts > 0 and table.concat(parts, " ") or "empty"
end

---------------------------------------------------------------------------
-- The tile
---------------------------------------------------------------------------

renderTile = function(color)
  local guid = tiles()[color]
  local tile = guid and getObjectFromGUID(guid)
  if tile == nil then
    return
  end
  tile.clearButtons()
  for _, c in ipairs(CHIPS) do
    local fn = "mana_" .. color .. "_" .. c.key
    _G[fn] = function(_, playerColor, alt)
      if playerColor ~= color and not GameState.solo() then
        broadcastToColor("That's " .. color .. "'s mana.", playerColor, { 1, 0.6, 0.2 })
        return
      end
      ManaChips.add(color, c.key, alt and -1 or 1)
    end
    local n = ManaChips.get(color, c.key)
    Trackers.tileButton(tile, { label = "", click_function = fn,
      tooltip = string.upper(c.name) .. ": " .. n .. "\nClick: +1   Right-click: -1\nTapping lands and casting spells keep it up to date.",
      width = 440, height = 440, color = { 0, 0, 0, 0 }, hover_color = { 1, 1, 1, 0.1 },
      press_color = { 1, 1, 1, 0.2 } }, c.x, c.z)
    if n > 0 then
      local digits = #tostring(n)
      Trackers.tileButton(tile, { label = tostring(n), click_function = "trk_noop", tooltip = string.upper(c.name) .. ": " .. n,
        width = 170 + 70 * (digits - 1), height = 170, font_size = 150, color = { 0.02, 0.03, 0.06, 0.94 },
        font_color = { 1, 1, 1 } }, c.x + BADGE_DX, c.z + BADGE_DZ)
    end
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
  -- Chips from older versions are not needed any more.
  for _, obj in ipairs(getObjectsWithTag("ManaChip")) do
    obj.destruct()
  end
end

function ManaChips.returnChip(obj)
  if obj ~= nil and not obj.isDestroyed() and obj.hasTag("ManaChip") then
    obj.destruct()
  end
end

function ManaChips.onDrop(obj)
  ManaChips.returnChip(obj)
end

---------------------------------------------------------------------------
-- Tapping for mana
---------------------------------------------------------------------------

local function oracleOf(obj)
  local d = CardData.get(obj)
  local text = tostring(d.oracle or ""):lower()
  local nm = tostring(obj.getName() or ""):lower()
  if nm ~= "" then
    text = text:gsub(nm:gsub("([%%%-%.%+%*%?%[%]%^%$%(%)])", "%%%1"), "~")
  end
  return text, d
end

-- What a simple "{T}: Add ..." ability makes: a list of options, each option the mana it gives
-- ({ {"G"}, {"U"} } = green or blue; { {"C","C"} } = two colorless). nil when the mana isn't simple
-- (depends on something: "for each", X, "that much"...), or when the permanent has other {T} abilities.
function ManaChips.parseTap(text)
  local options, found, other = {}, false, false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    local l = line:gsub("^%(", ""):gsub("%)$", "")
    if l:find("^{t}") then
      local colon = l:find(":", 1, true)
      local cost = colon and l:sub(1, colon - 1) or ""
      local effect = colon and l:sub(colon + 1):gsub("^%s+", "") or ""
      if effect:find("^add ") then
        local sentence = effect:sub(5)
        local dot = sentence:find(".", 1, true)
        if dot then
          sentence = sentence:sub(1, dot - 1)
        end
        if sentence:find("for each", 1, true) or sentence:find("that much", 1, true) or sentence:find("equal", 1, true)
            or sentence:find("{x}", 1, true) or sentence:find("an amount", 1, true) or sentence:find("number", 1, true)
            or sentence:find("{s}", 1, true) or cost:find("{%d", 1) then
          return nil
        end
        found = true
        if sentence:find("any color", 1, true) or sentence:find("any one color", 1, true) then
          for _, k in ipairs({ "W", "U", "B", "R", "G" }) do
            table.insert(options, { k })
          end
        elseif sentence:find(" or ", 1, true) then
          for sym in sentence:gmatch("{(%a)}") do
            table.insert(options, { sym:upper() })
          end
        else
          local one = {}
          for sym in sentence:gmatch("{(%a)}") do
            table.insert(one, sym:upper())
          end
          if #one > 0 then
            table.insert(options, one)
          end
        end
      else
        other = true   -- another {T} ability: can't tell which one the player used
      end
    end
  end
  if not found or other or #options == 0 then
    return nil
  end
  -- Drop options that repeat (two lines both giving {C}).
  local seen, out = {}, {}
  for _, o in ipairs(options) do
    local k = table.concat(o, "")
    if not seen[k] then
      seen[k] = true
      table.insert(out, o)
    end
  end
  return out
end

local function label(opt)
  local counts, order = {}, {}
  for _, k in ipairs(opt) do
    if counts[k] == nil then
      table.insert(order, k)
    end
    counts[k] = (counts[k] or 0) + 1
  end
  local parts = {}
  for _, k in ipairs(order) do
    table.insert(parts, counts[k] > 1 and (counts[k] .. k) or k)
  end
  return table.concat(parts, "+")
end

-- Put one of the options into the pool; several options: the player picks.
function ManaChips.offer(seat, name, options)
  if options == nil or #options == 0 then
    return
  end
  local function give(opt)
    for _, k in ipairs(opt) do
      ManaChips.add(seat, k, 1)
    end
  end
  if #options == 1 then
    give(options[1])
    return
  end
  local choices = {}
  for i, o in ipairs(options) do
    table.insert(choices, { label = label(o), value = i })
  end
  Effects.askChoice(seat, name .. ": which mana?", "Pick the mana " .. name .. " makes.", choices, function(i)
    if options[i] then
      give(options[i])
    end
  end)
end

-- A player tapped this by hand. `skipAsk`: the caller already handles it (painlands).
function ManaChips.onTap(obj, seat)
  local text = oracleOf(obj)
  local options = ManaChips.parseTap(text)
  if options then
    ManaChips.offer(seat, obj.getName(), options)
  end
end

-- The colored options of a painland / Talisman text (everything except plain colorless).
function ManaChips.coloredOptions(obj)
  local text = oracleOf(obj)
  local options = ManaChips.parseTap(text) or {}
  local out = {}
  for _, o in ipairs(options) do
    if not (#o == 1 and o[1] == "C") then
      table.insert(out, o)
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Paying costs from the pool
---------------------------------------------------------------------------

-- Take a mana cost ("{2}{B}{B}", "{1}{U}, {T}") out of the pool. Returns the text of what was
-- taken (nil if nothing), and whether the whole cost was covered.
function ManaChips.pay(seat, cost, name)
  cost = tostring(cost or "")
  local colored, hybrids, generic = {}, {}, 0
  for sym in cost:gmatch("{([^}]*)}") do
    local s = sym:upper()
    if s:match("^%d+$") then
      generic = generic + tonumber(s)
    elseif BY_KEY[s] then
      colored[s] = (colored[s] or 0) + 1
    elseif s:match("^%a/%a$") then
      local a, b = s:sub(1, 1), s:sub(3, 3)
      if b == "P" then
        colored[a] = (colored[a] or 0) + 1       -- Phyrexian: the mana if there is any
      elseif BY_KEY[a] and BY_KEY[b] then
        table.insert(hybrids, { a, b })
      end
    elseif s:match("^2/%a$") then
      colored[s:sub(3, 3)] = (colored[s:sub(3, 3)] or 0) + 1
    end
  end
  local p = pool(seat)
  if next(p) == nil then
    return nil
  end
  local taken, short = {}, 0
  local function take(k, n)
    local have = p[k] or 0
    local t = math.min(have, n)
    if t > 0 then
      p[k] = have - t
      if p[k] == 0 then
        p[k] = nil
      end
      taken[k] = (taken[k] or 0) + t
    end
    return n - t
  end
  for _, k in ipairs(ORDER) do
    if colored[k] then
      short = short + take(k, colored[k])
    end
  end
  for _, h in ipairs(hybrids) do
    local k = (p[h[1]] or 0) >= (p[h[2]] or 0) and h[1] or h[2]
    short = short + take(k, 1)
  end
  -- Generic: colorless first, then the color there is most of.
  while generic > 0 do
    local best, bestN = nil, 0
    if (p["C"] or 0) > 0 then
      best = "C"
    else
      for _, k in ipairs(ORDER) do
        if (p[k] or 0) > bestN then
          best, bestN = k, p[k]
        end
      end
    end
    if best == nil then
      short = short + generic
      break
    end
    take(best, 1)
    generic = generic - 1
  end
  local parts = {}
  for _, k in ipairs(ORDER) do
    if taken[k] then
      table.insert(parts, taken[k] .. k)
    end
  end
  if #parts == 0 then
    return nil
  end
  renderTile(seat)
  printToAll("MTG > " .. seat .. " pays " .. tostring(name or "the cost") .. " from the mana pool (" .. table.concat(parts, " ")
    .. ")" .. (short > 0 and (" - " .. short .. " short, pay the rest yourself") or "") .. ". Pool: " .. ManaChips.summary(seat) .. ".", INFO)
  return table.concat(parts, " "), short == 0
end

-- A spell goes on the stack: its mana cost comes out of the pool.
Events.on("spellCast", function(d)
  if d.card == nil or d.card.isDestroyed() then
    return
  end
  local cost = CardData.get(d.card).manaCost
  if cost and cost ~= "" and d.controller and TableSetup.isActive(d.controller) then
    ManaChips.pay(d.controller, cost, d.card.getName())
  end
end)

-- The rules empty every mana pool when a step ends.
Events.on("stepStarted", function()
  if ManaChips.emptyAll() then
    printToAll("MTG > Mana pools emptied (new step).", INFO)
  end
end)
