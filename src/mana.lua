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
  if GameState.data then
    GameState.data.restrict = {}
  end
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
  -- Mana abilities other permanents give it (Manaweft Sliver: Slivers tap for any color).
  if Statics and Statics.grants then
    local okg, g = pcall(Statics.grants, obj)
    if okg and g then
      for _, a in ipairs(g.lines) do
        if a:find("{t}", 1, true) and a:find("add ", 1, true) then
          text = text .. "\n" .. a
        end
      end
    end
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
-- Mana with a catch ("Spend this mana only to cast a creature spell of the chosen type", Cavern of Souls):
-- it sits in the pool like any mana, and is remembered so that paying for the wrong thing is called out.
function ManaChips.addRestricted(seat, key, ty, src, unc)
  ManaChips.add(seat, key, 1)
  local d = GameState.data
  d.restrict = d.restrict or {}
  d.restrict[seat] = d.restrict[seat] or {}
  local list = d.restrict[seat][key] or {}
  d.restrict[seat][key] = list
  for _, e in ipairs(list) do
    if e.type == ty and e.src == src then
      e.n = e.n + 1
      return
    end
  end
  table.insert(list, { type = ty, src = src, n = 1, unc = unc and true or false })
end

function ManaChips.offer(seat, name, options, restrictType, restrictUnc)
  if options == nil or #options == 0 then
    return
  end
  local function give(opt)
    for _, k in ipairs(opt) do
      if restrictType and k ~= "C" then
        ManaChips.addRestricted(seat, k, restrictType, name, restrictUnc)
      else
        ManaChips.add(seat, k, 1)
      end
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
-- Every permanent the seat controls (face up, on the battlefield or lands row).
local function permanentsOf(seat)
  local out = {}
  for _, o in ipairs(getObjectsWithTag("MTGCard")) do
    if o.type == "Card" and not o.isDestroyed() and o.held_by_color == nil and not (Faces and Faces.unknown(o)) then
      local loc = Zones.regionAt(o.getPosition())
      if loc.seat == seat and (loc.region == "battlefield" or loc.region == "lands") then
        table.insert(out, o)
      end
    end
  end
  return out
end

-- The colors among the seat's permanents, in WUBRG order (Bloom Tender).
function ManaChips.colorsAmong(seat)
  local have = {}
  for _, o in ipairs(permanentsOf(seat)) do
    local d = CardData.get(o)
    local cols = type(d.colors) == "table" and d.colors or {}
    for _, c in pairs(cols) do
      have[tostring(c):upper()] = true
    end
  end
  local out = {}
  for _, k in ipairs({ "W", "U", "B", "R", "G" }) do
    if have[k] then
      table.insert(out, k)
    end
  end
  return out
end

-- What the seat's lands could produce (Horizon of Progress, Reflecting Pool style), as a list of keys.
function ManaChips.landTypes(seat)
  local have = {}
  for _, o in ipairs(permanentsOf(seat)) do
    local d = CardData.get(o)
    if tostring(d.typeLine or ""):lower():find("land", 1, true) then
      for _, opt in ipairs(ManaChips.parseTap(oracleOf(o)) or {}) do
        for _, k in ipairs(opt) do
          have[k] = true
        end
      end
    end
  end
  local out = {}
  for _, k in ipairs({ "W", "U", "B", "R", "G", "C" }) do
    if have[k] then
      table.insert(out, k)
    end
  end
  return out
end

function ManaChips.onTap(obj, seat)
  local text = oracleOf(obj)
  -- Bloom Tender: one mana of each color among your permanents.
  if text:find("for each color among permanents you control, add one mana of that color", 1, true) then
    local cols = ManaChips.colorsAmong(seat)
    for _, k in ipairs(cols) do
      ManaChips.add(seat, k, 1)
    end
    printToAll("MTG > " .. obj.getName() .. ": " .. seat .. " adds " .. (#cols > 0 and table.concat(cols, "") or "no mana (no colored permanents)") .. ".", { 0.55, 0.9, 0.6 })
    return
  end
  -- "{T}, Remove a depletion counter from this land: Add {G}{G}." (Hickory Woodlot, Peat Bog...)
  if text:find("{t}, remove ", 1, true) and text:find(" counter from ", 1, true) then
    local c = Counters.get(obj)
    if (c.other or 0) <= 0 then
      printToAll("MTG > " .. obj.getName() .. " has no counters left: no mana.", { 1, 0.6, 0.2 })
      return
    end
    Counters.change(obj, "other", -1, seat)
    local left = (c.other or 1) - 1
    local options = ManaChips.parseTap(text)
    if options then
      ManaChips.offer(seat, obj.getName(), options)
    end
    if left <= 0 and text:find("sacrifice", 1, true) then
      printToAll("MTG > " .. obj.getName() .. " has no counters left: sacrificed.", { 0.75, 0.8, 0.9 })
      Wait.time(function()
        if not obj.isDestroyed() then
          Combat.removeCard(obj, "graveyard")
        end
      end, 0.8)
    end
    return
  end
  -- Horizon of Progress: one mana of any type a land you control could produce.
  if text:find("one mana of any type that a land you control could produce", 1, true) then
    local types = ManaChips.landTypes(seat)
    if #types == 0 then
      printToAll("MTG > " .. obj.getName() .. ": your lands can't make any mana right now.", { 1, 0.6, 0.2 })
      return
    end
    local options = {}
    for _, k in ipairs(types) do
      table.insert(options, { k })
    end
    ManaChips.offer(seat, obj.getName(), options)
    return
  end
  local options = ManaChips.parseTap(text)
  if options then
    -- "Spend this mana only to cast ..." (Cavern of Souls, Unclaimed Territory, Sliver Hive, Ancient Ziggurat).
    local only = text:find("spend this mana only to cast", 1, true)
    if only then
      local tail = text:sub(only, only + 160)
      local unc = tail:find("can't be countered", 1, true) ~= nil
      local function go(ty)
        ManaChips.offer(seat, obj.getName(), options, ty, unc)
      end
      if tail:find("of the chosen type", 1, true) then
        local ty = Statics.chosenType(obj)
        if ty == nil then
          Effects.askText(seat, obj.getName() .. ": creature type", "No creature type is chosen for " .. obj.getName() .. " yet. Type it (for example Elf).", function(t)
            ty = t:sub(1, 1):upper() .. t:sub(2):lower()
            Statics.setChosen(obj, ty)
            printToAll("MTG > " .. seat .. " chooses " .. ty .. " for " .. obj.getName() .. ".", { 0.55, 0.9, 0.6 })
            go(ty)
          end)
        else
          go(ty)
        end
        return
      elseif tail:find("cast a sliver spell", 1, true) then
        go("Sliver")
        return
      elseif tail:find("cast a creature spell", 1, true) or tail:find("cast creature spells", 1, true) then
        go("")
        return
      end
    end
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
-- Which of the mana just taken was restricted, and was it allowed to pay for this? (`card` = the spell
-- being cast, nil for an ability.) A matching creature spell uses the restricted mana first, and can't be
-- countered; anything else uses ordinary mana first, and is called out if it had to use the restricted kind.
local function settleRestricted(seat, taken, p, card, spellName)
  local rs = GameState.data.restrict and GameState.data.restrict[seat]
  if not rs then
    return
  end
  local tl, orc = "", ""
  if card then
    local cd = CardData.get(card)
    tl, orc = cd.typeLine, cd.oracle
  end
  for k, t in pairs(taken) do
    local list = rs[k]
    if list then
      local before = (p[k] or 0) + t
      local total = 0
      for _, e in ipairs(list) do
        total = total + e.n
      end
      local excess = total - before
      for i = #list, 1, -1 do
        if excess > 0 then
          local cut = math.min(excess, list[i].n)
          list[i].n = list[i].n - cut
          excess = excess - cut
          total = total - cut
        end
      end
      local need = t
      for _, e in ipairs(list) do
        if need > 0 and e.n > 0 and card and ((e.type == "" and tostring(tl):lower():find("creature", 1, true)) or Statics.typeMatches(tl, orc, e.type)) then
          local u = math.min(e.n, need)
          e.n = e.n - u
          need = need - u
          if e.unc then
            GameState.data.noCounter = GameState.data.noCounter or {}
            GameState.data.noCounter[card.getGUID()] = e.src
            printToAll("MTG > " .. spellName .. " is paid with " .. e.src .. " mana: it can't be countered.", { 0.55, 0.9, 0.6 })
          end
        end
      end
      need = need - math.min(need, math.max(0, before - total))
      for _, e in ipairs(list) do
        if need > 0 and e.n > 0 then
          local u = math.min(e.n, need)
          e.n = e.n - u
          need = need - u
          printToAll("MTG > NOT ALLOWED: " .. e.src .. " mana can only be spent to cast " .. (e.type == "" and "a creature spell" or ("a creature spell of the type " .. e.type)) .. ", but "
            .. u .. k .. " of it was used for " .. spellName .. ". Take it back by hand and pay another way.", { 1, 0.45, 0.2 })
        end
      end
      local keep = {}
      for _, e in ipairs(list) do
        if e.n > 0 then
          table.insert(keep, e)
        end
      end
      rs[k] = #keep > 0 and keep or nil
    end
  end
end

function ManaChips.pay(seat, cost, name, card)
  cost = tostring(cost or "")
  if card and GameState.data.noCounter then
    GameState.data.noCounter[card.getGUID()] = nil
  end
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
  settleRestricted(seat, taken, p, card, tostring(name or "the cost"))
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
  local fc = GameState.data.freeCast
  if fc and fc[d.card.getGUID()] then
    fc[d.card.getGUID()] = nil      -- cast without paying its mana cost (suspend, rebound)
    return
  end
  if cost and cost ~= "" and d.controller and TableSetup.isActive(d.controller) then
    ManaChips.pay(d.controller, cost, d.card.getName(), d.card)
  end
end)

-- The rules empty every mana pool when a step ends.
Events.on("stepStarted", function()
  if ManaChips.emptyAll() then
    printToAll("MTG > Mana pools emptied (new step).", INFO)
  end
end)
