-- Static effects the table can show for itself: "this creature gets +1/+1 for each artifact you control"
-- (Urza's Construct), "creature tokens you control get +1/+1" (Intangible Virtue), and token doublers
-- (Anointed Procession, Doubling Season, Academy Manufactor).
Statics = Statics or {}

local bonus = {}        -- guid -> { p, t }
local pending = false

local function dataOf(obj)
  return CardData.get(obj)
end

local IN = { battlefield = true, lands = true }

-- Everything face-up on a battlefield: { obj, seat, d, tl, oracle }.
-- The face-up plane (Planechase): its always-on lines, lower case, and the planar controller (the active
-- player, CR 901.6). Lines the table carries out itself (chaos, planeswalking, rolling) are left out.
local planeCache = { at = -100 }
local function planeNow()
  local now = (Time and Time.time) or os.time()
  if now - planeCache.at < 0.5 then
    return planeCache.obj, planeCache.text, planeCache.seat
  end
  local obj, text, seat
  if Planechase and Planechase.currentPlane and GameState.data and GameState.data.started then
    local okp, plane = pcall(Planechase.currentPlane)
    local t = GameState.data.turn or {}
    if okp and plane and t.activeSeat then
      local okt, tx = pcall(Planechase.triggerText, plane.getName())
      obj, text, seat = plane, (okt and tostring(tx or "") or ""):lower(), t.activeSeat
    end
  end
  planeCache = { at = now, obj = obj, text = text, seat = seat }
  return obj, text, seat
end

-- Does the plane in play say this (lower case, plain text)? Returns the plane's name, or nil.
function Statics.planeSays(phrase)
  local obj, text = planeNow()
  if obj and text and text:find(phrase, 1, true) then
    local nm = "the plane"
    pcall(function() nm = obj.getName() end)
    return nm
  end
  return nil
end

local function perms()
  local list = {}
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and obj.held_by_color == nil and not (Faces and Faces.unknown(obj)) then
      local loc = Zones.regionAt(obj.getPosition())
      if loc.seat and IN[loc.region] then
        local d = dataOf(obj)
        table.insert(list, { obj = obj, seat = loc.seat, d = d, tl = tostring(d.typeLine or ""):lower(),
          oracle = tostring(d.oracle or ""):lower(), token = obj.hasTag("Token") })
      end
    end
  end
  -- The plane in play counts as a source of always-on abilities ("All creatures get +2/+2", "All creatures
  -- have vigilance"): not a permanent, so nothing is counted on it and it gets nothing itself.
  local pobj, ptext, pseat = planeNow()
  if pobj and ptext and ptext ~= "" then
    table.insert(list, { obj = pobj, seat = pseat, d = {}, tl = "plane", oracle = ptext, token = false, plane = true })
  end
  return list
end

-- A card's colors as a set { W = true, ... }: its printed colors, "is all colors" (Transguild Courier,
-- Jared's Kavu tokens), and Leyline of the Guildpact ("Each nonland permanent you control is all colors").
local ALL5 = { W = true, U = true, B = true, R = true, G = true }
local leyCache = { at = -100, seats = {} }
local function leylineSeats()
  local now = (Time and Time.time) or os.time()
  if now - leyCache.at < 1 then
    return leyCache.seats
  end
  local seats = {}
  for _, p in ipairs(perms()) do
    if p.oracle:find("each nonland permanent you control is all colors", 1, true) then
      seats[p.seat] = true
    end
  end
  leyCache.at, leyCache.seats = now, seats
  return seats
end

function Statics.colorsOf(obj, seat)
  local out = {}
  if obj == nil then
    return out
  end
  local d = dataOf(obj)
  local tl = tostring(d.typeLine or ""):lower()
  local o = tostring(d.oracle or ""):lower()
  if o:find("is all colors", 1, true) then
    return ALL5
  end
  if seat == nil then
    local okl, loc = pcall(function() return Zones.regionAt(obj.getPosition()) end)
    seat = okl and loc and IN[loc.region] and loc.seat or nil
  end
  if seat and not tl:find("land", 1, true) and leylineSeats()[seat] then
    return ALL5
  end
  for _, c in pairs(type(d.colors) == "table" and d.colors or {}) do
    out[tostring(c):upper()] = true
  end
  return out
end

-- Leyline of the Guildpact: "Lands you control are every basic land type" (they tap for any color).
function Statics.landsEveryType(seat)
  for _, p in ipairs(perms()) do
    if p.seat == seat and p.oracle:find("lands you control are every basic land type", 1, true) then
      return true
    end
  end
  return false
end

function Statics.colorCount(obj, seat)
  local n = 0
  for _ in pairs(Statics.colorsOf(obj, seat)) do
    n = n + 1
  end
  return n
end

local COLOR_WORD = { white = "W", blue = "U", black = "B", red = "R", green = "G" }

function Statics.bonus(obj)
  local b = obj and bonus[obj.getGUID()]
  if b then
    return b.p, b.t
  end
  return 0, 0
end

-- "elves" -> elf, "wolves" -> wolf, "allies" -> ally, "zombies" -> zombie, "soldiers" -> soldier.
-- Plurals that don't just add an "s" (Thurid: "Other Pegasi, Unicorns, and Horses you control get +1/+1").
local IRREGULAR = { pegasi = "pegasus", mice = "mouse", fungi = "fungus", octopi = "octopus", cacti = "cactus",
  djinn = "djinn", efreet = "efreet", sphinxes = "sphinx", foxes = "fox", lynxes = "lynx", oxen = "ox",
  homunculi = "homunculus", phoenixes = "phoenix", allies = "ally", dwarves = "dwarf", elves = "elf",
  wolves = "wolf", werewolves = "werewolf", sheep = "sheep", fish = "fish", lizardfolk = "lizardfolk",
  mercenaries = "mercenary", faeries = "faerie", zombies = "zombie", jellyfish = "jellyfish" }

local function singular(w)
  if IRREGULAR[w] then
    return { IRREGULAR[w] }
  end
  if w:sub(-3) == "ves" then
    return { w:sub(1, -4) .. "f", w:sub(1, -2) }
  elseif w:sub(-3) == "ies" then
    return { w:sub(1, -4) .. "y", w:sub(1, -2) }
  end
  return { (w:gsub("s$", "")) }
end

local function subjectMatches(subj, q, p)
  subj = subj:gsub("^%s+", ""):gsub("%s+$", "")
  -- "each other creature" / "each creature": same as "other creatures" / "creatures".
  if subj:sub(1, 5) == "each " then
    subj = subj:sub(6)
  elseif subj:sub(1, 4) == "all " then
    subj = subj:sub(5)   -- "All creatures have vigilance" (Gavony), "All Slivers have ..."
  end
  if subj:sub(-9) == " creature" or subj == "creature" then
    subj = subj .. "s"
  end
  local other = false
  if subj:sub(1, 6) == "other " then
    other = true
    subj = subj:sub(7)
  end
  if other and q.obj == p.obj then
    return false
  end
  -- "Lands you control have '{T}: Add one mana of any color.'" (Chromatic Lantern).
  if subj == "lands" then
    return q.tl:find("land", 1, true) ~= nil
  end
  if q.tl:find("creature", 1, true) == nil then
    return false
  end
  -- "Attacking creatures you control have deathtouch" (Ohran Frostfang).
  if subj:sub(1, 10) == "attacking " then
    if not (Combat and Combat.isAttacking and Combat.isAttacking(q.obj)) then
      return false
    end
    subj = subj:sub(11)
  end
  -- Colors: "Other red creatures you control get +1/+1" (the Lieges), "multicolored creatures".
  do
    local cw = subj:match("^(%a+) creatures$")
    if cw and (COLOR_WORD[cw] or cw == "multicolored" or cw == "monocolored" or cw == "colorless") then
      local cols = Statics.colorsOf(q.obj, q.seat)
      local n = 0
      for _ in pairs(cols) do
        n = n + 1
      end
      if COLOR_WORD[cw] then
        return cols[COLOR_WORD[cw]] == true
      elseif cw == "multicolored" then
        return n >= 2
      elseif cw == "monocolored" then
        return n == 1
      end
      return n == 0
    end
  end
  -- Changeling: every creature type (Changeling Outcast is a Ninja for Splinter, a Sliver for Sliver lords).
  local changeling = tostring(dataOf(q.obj).oracle or ""):lower():find("changeling", 1, true) ~= nil
  if changeling and subj ~= "creatures" and subj ~= "creature tokens" and subj ~= "nontoken creatures"
      and not subj:find("artifact", 1, true) and not subj:find("legendary", 1, true) then
    return true
  end
  -- Planes: "Creatures with flying get +2/+0" / "Creatures without flying get -2/-0" (The Zephyr Maze),
  -- "Each creature with mana value 2 or less gets +2/+2" (Megaflora Jungle).
  do
    local fw = subj:match("^creatures? with (%a+)$")
    local nw = subj:match("^creatures? without (%a+)$")
    if fw or nw then
      local has = Effects ~= nil and Effects.hasKeyword ~= nil and Effects.hasKeyword(q.obj, fw or nw) == true
      return (fw ~= nil) == has
    end
    local mvMax = subj:match("^creatures? with mana value (%d+) or less$")
    if mvMax then
      local mv = tonumber(dataOf(q.obj).cmc) or 0
      return mv <= tonumber(mvMax)
    end
  end
  if subj == "creatures" then
    return true
  elseif subj == "creature tokens" then
    return q.token
  elseif subj == "nontoken creatures" then
    return not q.token
  end
  -- "Skeletons, Vampires, and Zombies you control get +1/+1" (Death-Priest of Myrkul).
  if subj:find(",", 1, true) or subj:find(" and ", 1, true) or subj:find(" or ", 1, true) then
    for w in subj:gmatch("[%a%-]+") do
      if w ~= "and" and w ~= "or" then
        for _, base in ipairs(singular(w)) do
          if base ~= "" and q.tl:find(base, 1, true) then
            return true
          end
        end
      end
    end
    return false
  end
  local plural = subj:match("^([%a%-]+)s$")
  if plural then
    for _, base in ipairs(singular(plural .. "s")) do
      if q.tl:find(base, 1, true) then
        return true
      end
    end
    return false
  end
  local word = subj:match("^([%a%-]+) creatures$")
  if word then
    return q.tl:find(word, 1, true) ~= nil
  end
  return false
end

---------------------------------------------------------------------------
-- Forge's static abilities (src/forge_statics_data.lua, tools/forge_statics.py): used only for a
-- rules-text line this file's own reader doesn't understand.
---------------------------------------------------------------------------

local fsCache = {}
-- A card's Forge static entries: { { key, kind, fields } } (kind false: Forge has one the data can't express).
local function forgeStaticEntries(name)
  if FORGE_STATICS == nil or name == nil or (GameState.data and GameState.data.forgeStaticsOff) then
    return nil
  end
  local hit = fsCache[name]
  if hit ~= nil then
    return hit or nil
  end
  local raw = FORGE_STATICS[name]
  if raw == nil then
    fsCache[name] = false
    return nil
  end
  local list = {}
  for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
    local b1 = line:find("|", 1, true)
    if b1 then
      local key, rest = line:sub(1, b1 - 1), line:sub(b1 + 1)
      local b2 = rest:find("|", 1, true)
      if rest == "?" or b2 == nil then
        table.insert(list, { key = key, kind = false })
      else
        local e = { key = key, kind = rest:sub(1, b2 - 1), f = {} }
        for kv in (rest:sub(b2 + 1) .. ";"):gmatch("([^;]*);") do
          local eq = kv:find("=", 1, true)
          if eq then
            e.f[kv:sub(1, eq - 1)] = kv:sub(eq + 1)
          end
        end
        table.insert(list, e)
      end
    end
  end
  fsCache[name] = list
  return list
end

-- { [line number] = entry } for the lines of a card's rules text that exactly one Forge entry fits.
local forgeLinesCache, forgeLinesN = {}, 0
function Statics.forgeLines(name, oracle)
  local key = tostring(name) .. "\0" .. tostring(oracle)
  local hit = forgeLinesCache[key]
  if hit then
    return hit
  end
  local out = Statics.forgeLinesRead(name, oracle)
  forgeLinesN = forgeLinesN + 1
  if forgeLinesN > 2000 then
    forgeLinesCache, forgeLinesN = {}, 0
  end
  forgeLinesCache[key] = out
  return out
end

function Statics.forgeLinesRead(name, oracle)
  local entries = forgeStaticEntries(name)
  if entries == nil or not (Triggers and Triggers.forgeKey) then
    return {}
  end
  local keys, i = {}, 0
  for line in (tostring(oracle or "") .. "\n"):gmatch("([^\n]*)\n") do
    i = i + 1
    keys[i] = Triggers.forgeKey(line, name)
  end
  local out, bad = {}, {}
  for _, e in ipairs(entries) do
    local hits = {}
    for j, k in ipairs(keys) do
      if k ~= "" and k:sub(1, #e.key) == e.key then
        table.insert(hits, j)
      end
    end
    if #hits == 1 and e.kind then
      if out[hits[1]] then
        bad[hits[1]] = true
      end
      out[hits[1]] = e
    else
      for _, j in ipairs(hits) do
        bad[j] = true
      end
    end
  end
  for j in pairs(bad) do
    out[j] = nil
  end
  return out
end

local FS_COLORS = { W = true, U = true, B = true, R = true, G = true }
local FS_FLAGS = { you = true, opp = true, other = true, self = true, token = true, nontoken = true, attacking = true,
  blocking = true }
local FS_TYPES = { creature = true, artifact = true, enchantment = true, land = true, planeswalker = true, permanent = true }

-- Does permanent q ({ obj, seat, tl, token }) fit a Forge filter from source src ({ obj, seat })?
function Statics.forgeMatches(filter, q, src)
  for alt in (tostring(filter) .. ","):gmatch("([^,]*),") do
    local ok = alt ~= ""
    for tok in alt:gmatch("[^%.]+") do
      if not ok then
        break
      end
      if FS_TYPES[tok] then
        ok = tok == "permanent" or q.tl:find(tok, 1, true) ~= nil
      elseif tok == "perm" then
        -- A permanent (spell): anything but an instant or sorcery.
        ok = q.tl:find("instant", 1, true) == nil and q.tl:find("sorcery", 1, true) == nil
      elseif FS_COLORS[tok] then
        ok = Statics.colorsOf(q.obj, q.seat)[tok] == true
      elseif tok == "you" then
        ok = q.seat == src.seat
      elseif tok == "opp" then
        ok = q.seat ~= src.seat
      elseif tok == "other" then
        ok = q.obj ~= src.obj
      elseif tok == "self" then
        ok = q.obj == src.obj
      elseif tok == "token" then
        ok = q.token == true
      elseif tok == "nontoken" then
        ok = not q.token
      elseif tok == "attacking" then
        ok = Combat ~= nil and Combat.isAttacking ~= nil and Combat.isAttacking(q.obj) == true
      elseif tok == "fly" or tok == "nofly" or tok == "reach" then
        local has = Effects ~= nil and Effects.hasKeyword ~= nil and Effects.hasKeyword(q.obj, tok == "reach" and "reach" or "flying")
        ok = (tok == "nofly") ~= (has == true)
      elseif tok:sub(1, 1) == "!" then
        local w = tok:sub(2)
        if FS_COLORS[w] then
          ok = Statics.colorsOf(q.obj, q.seat)[w] ~= true
        else
          ok = q.tl:find(w, 1, true) == nil
        end
      elseif tok:sub(1, 3) == "pow" then
        local pw = tonumber(Counters and Counters.stats and Counters.stats(q.obj).power or "") or 0
        local n = tonumber(tok:sub(6)) or 0
        ok = (tok:sub(4, 5) == "<=" and pw <= n) or (tok:sub(4, 5) == ">=" and pw >= n)
      elseif FS_FLAGS[tok] then
        ok = false
      else
        -- A subtype; changelings are every creature type.
        ok = q.tl:find(tok, 1, true) ~= nil
          or (q.tl:find("creature", 1, true) ~= nil and tostring(dataOf(q.obj).oracle or ""):lower():find("changeling", 1, true) ~= nil)
      end
    end
    if ok then
      return true
    end
  end
  return false
end

-- "<subject> you control get +1/+1" -> subject, "mine"; "... your opponents control get -2/-2" -> "opps";
-- "All Slivers get +1/+1" -> "all". Plain searches only (TTS gives up on lazy patterns over long text).
local function parseAnthem(line)
  local forms = { { " you control get ", "mine" }, { " you control gets ", "mine" },
    { " your opponents control get ", "opps" }, { " your opponents control gets ", "opps" },
    { " get ", "all" }, { " gets ", "all" } }
  for _, f in ipairs(forms) do
    local at = line:find(f[1], 1, true)
    if at and at <= 40 then
      local x, y = line:sub(at + #f[1]):match("^([%+%-]%d+)/([%+%-]%d+)")
      if x then
        return line:sub(1, at - 1), f[2], x, y
      end
    end
  end
  return nil
end

-- The city's blessing (Ascend): kept per seat for the rest of the game.
function Statics.blessing(seat)
  local b = GameState.data and GameState.data.blessing
  return b ~= nil and b[seat] == true
end

local function checkAscend(list)
  local counts, ascenders = {}, {}
  for _, p in ipairs(list) do
    counts[p.seat] = (counts[p.seat] or 0) + (p.plane and 0 or (Pile and Pile.count(p.obj) or 1))
    if p.oracle:find("ascend", 1, true) == 1 or p.oracle:find("\nascend", 1, true) then
      ascenders[p.seat] = p.obj.getName()
    end
  end
  for seat, name in pairs(ascenders) do
    if (counts[seat] or 0) >= 10 and not Statics.blessing(seat) then
      GameState.data.blessing = GameState.data.blessing or {}
      GameState.data.blessing[seat] = true
      printToAll("MTG > " .. seat .. " has ten or more permanents: they get the CITY'S BLESSING for the rest of the game (" .. tostring(name) .. ").", { 1, 0.85, 0.3 })
    end
  end
end

function Statics.compute()
  leyCache.at = -100   -- Leyline of the Guildpact may have come or gone
  local list = perms()
  local new = {}
  pcall(checkAscend, list)
  local function add(q, a, b)
    local g = q.obj.getGUID()
    new[g] = new[g] or { p = 0, t = 0 }
    new[g].p = new[g].p + a
    new[g].t = new[g].t + b
  end
  local artifacts = {}
  for _, p in ipairs(list) do
    if p.tl:find("artifact", 1, true) then
      artifacts[p.seat] = (artifacts[p.seat] or 0) + (Pile and Pile.count(p.obj) or 1)
    end
  end
  for _, p in ipairs(list) do
    local fl = Statics.forgeLines(p.obj.getName(), p.oracle)
    local idx = 0
    for line in (p.oracle .. "\n"):gmatch("([^\n]*)\n") do
      idx = idx + 1
      local understood = false
      -- "This creature gets +1/+1 for each artifact you control."
      local a, b = line:match("^this creature gets %+(%d+)/%+(%d+) for each artifact you control")
      if a then
        understood = true
        add(p, tonumber(a) * (artifacts[p.seat] or 0), tonumber(b) * (artifacts[p.seat] or 0))
      end
      -- Faeburrow Elder: "~ gets +1/+1 for each color among permanents you control."
      if line:find(" gets +1/+1 for each color among permanents you control", 1, true) then
        understood = true
        local have = {}
        for _, q in ipairs(list) do
          if q.seat == p.seat then
            for c in pairs(Statics.colorsOf(q.obj, q.seat)) do
              have[c] = true
            end
          end
        end
        local n = 0
        for _ in pairs(have) do
          n = n + 1
        end
        add(p, n, n)
      end
      -- Metalcraft: "~ gets +2/+2 as long as you control three or more artifacts."
      do
        local l2 = line
        local nm = tostring(p.obj.getName()):lower()
        local ds = l2:find(" — ", 1, true)
        if ds and ds <= 14 then
          l2 = l2:sub(ds + 5)
        end
        if nm ~= "" and l2:sub(1, #nm) == nm then
          l2 = "this creature" .. l2:sub(#nm + 1)
        end
        local mp, mt, mn = l2:match("^this creature gets %+(%d+)/%+(%d+) as long as you control (%w+) or more artifacts")
        if mp then
          understood = true
          local need = tonumber(mn) or ({ two = 2, three = 3, four = 4, five = 5, six = 6 })[mn] or 3
          if (artifacts[p.seat] or 0) >= need then
            add(p, tonumber(mp), tonumber(mt))
          end
        end
      end
      -- Anthems: "Creatures you control get +1/+1", "Other Soldiers you control get +1/+1", "Creatures your
      -- opponents control get -2/-2", "Saprolings you control get +2/+2 as long as you have the city's blessing".
      -- Only lasting effects: not "until end of turn", not triggered ("whenever...") or activated ("{2}: ...") lines.
      -- (plain search first: MoonSharp gives up on lazy patterns over long rules text)
      do
        local gat = line:find(" get ", 1, true)
        if gat and gat <= 40 and line:find(" for each other ", 1, true) and line:find(" on the battlefield", 1, true)
            and not line:find(":", 1, true) and not line:find("until end of turn", 1, true) then
          local gx, gy, gw = line:sub(gat + 5):match("^([%+%-]%d+)/([%+%-]%d+) for each other (%a+) on the battlefield")
          if gx then
            understood = true
            local subj = line:sub(1, gat - 1)
            if subj:sub(1, 4) == "all " then
              subj = subj:sub(5)
            end
            local bases = singular(gw)
            local total = 0
            for _, q in ipairs(list) do
              for _, b in ipairs(bases) do
                if b ~= "" and q.tl:find(b, 1, true) then
                  total = total + 1
                  break
                end
              end
            end
            for _, q in ipairs(list) do
              if subjectMatches(subj, q, p) then
                local mine = 0
                for _, b in ipairs(bases) do
                  if b ~= "" and q.tl:find(b, 1, true) then
                    mine = 1
                    break
                  end
                end
                local k = total - mine
                add(q, tonumber(gx) * k, tonumber(gy) * k)
              end
            end
          end
        end
      end
      local lowl = line
      local temporary = lowl:find("until end of turn", 1, true) or lowl:find("until your next turn", 1, true)
        or lowl:find("this turn", 1, true) or lowl:find(":", 1, true) or lowl:sub(1, 4) == "when"
        or lowl:find("at the beginning", 1, true) or lowl:find("target", 1, true) or lowl:find(" for each ", 1, true)
      if not temporary then
        local subj, scope, x, y = parseAnthem(line)
        -- Conditions: only the city's blessing is understood; any other "as long as" is left out
        -- rather than applied all the time.
        local okCond = true
        if line:find(" as long as ", 1, true) then
          okCond = line:find("as long as you have the city's blessing", 1, true) ~= nil and Statics.blessing(p.seat) == true
        end
        if subj then
          understood = true
        end
        if subj and #subj < 40 and okCond then
          if subj:sub(1, 4) == "all " then
            subj = subj:sub(5)
          end
          for _, q in ipairs(list) do
            local sideOk = (scope == "all") or (scope == "mine" and q.seat == p.seat) or (scope == "opps" and q.seat ~= p.seat and TableSetup.isOpponent(q.seat, p.seat))
            if sideOk and subjectMatches(subj, q, p) then
              add(q, tonumber(x), tonumber(y))
            end
          end
        end
      end
      -- A line the reader above didn't understand: Forge's reading of it, if any (P/T only;
      -- its keywords go through Statics.grants).
      local fe = fl[idx]
      if not understood and fe and fe.kind == "C" and (fe.f.p or fe.f.t) then
        local fp, ft = tonumber(fe.f.p) or 0, tonumber(fe.f.t) or 0
        for _, q in ipairs(list) do
          if Statics.forgeMatches(fe.f.f, q, p) then
            add(q, fp, ft)
          end
        end
      end
    end
  end
  -- Redraw the cards whose numbers changed.
  local changed = {}
  for g, b in pairs(new) do
    local o = bonus[g]
    if o == nil or o.p ~= b.p or o.t ~= b.t then
      changed[g] = true
    end
  end
  for g in pairs(bonus) do
    if new[g] == nil then
      changed[g] = true
    end
  end
  bonus = new
  for g in pairs(changed) do
    local obj = getObjectFromGUID(g)
    if obj and not obj.isDestroyed() and Counters and Counters.render then
      pcall(Counters.render, obj)
    end
  end
  if Statics.refreshGrantLabels then
    pcall(Statics.refreshGrantLabels)
  end
end

-- Recompute shortly after anything moves (several moves in a row count once).
function Statics.soon()
  if pending then
    return
  end
  pending = true
  Wait.time(function()
    pending = false
    if GameState.data and GameState.data.started then
      local ok, err = pcall(Statics.compute)
      if not ok then
        print("MTG > statics: " .. tostring(err))
      end
    end
  end, 1.0)
end

Events.on("stepStarted", function()
  Statics.soon()
end)

Events.on("cardMoved", function(d)
  if d.from == nil or d.to == nil then
    return
  end
  if IN[d.from.region] or IN[d.to.region] then
    Statics.soon()
  end
end)

-- "If an effect would create one or more tokens under your control, it creates twice that many" (x2 each).
function Statics.tokenMultiplier(seat)
  local m = 1
  for _, p in ipairs(perms()) do
    if p.seat == seat and p.oracle:find("twice that many", 1, true) and p.oracle:find("token", 1, true) then
      m = m * 2
    elseif p.plane and p.seat ~= seat and p.oracle:find("if an effect would create one or more tokens, it creates twice that many", 1, true) then
      -- Selesnya Loft Gardens: every player's tokens, not only the planar controller's.
      m = m * 2
    end
  end
  return m
end

-- Counter replacement effects: Doubling Season ("twice that many of those counters"), Hardened Scales
-- and Winding Constrictor ("that many plus one"), Branching Evolution, Primal Vigor, Pir, Vorinclex
-- ("twice that many" for you, "half that many" for opponents). Read from the rules text of every
-- permanent in play, a sentence at a time. Additions come first, then doubling, then halving
-- (the usual best order for the player; they can fix it by hand if they pick another).
-- Returns the new amount and the names of the permanents that changed it.
function Statics.counterAmount(obj, kind, n, putter)
  if type(n) ~= "number" or n <= 0 or kind == "tp" or kind == "tt" then
    return n, {}
  end
  local owner
  pcall(function() owner = Zones.regionAt(obj.getPosition()).seat end)
  local tl = tostring(dataOf(obj).typeLine or ""):lower()
  local isCreature = tl:find("creature", 1, true) ~= nil
  local isArtifact = tl:find("artifact", 1, true) ~= nil
  local adds, muls, halves, names = 0, 0, 0, {}
  for _, p in ipairs(perms()) do
    local o = p.oracle
    if o:find("counter", 1, true) and o:find("would", 1, true) then
      for s in o:gmatch("[^%.\n]+") do
        local mode
        if s:find("twice that many", 1, true) then
          mode = "mul"
        elseif s:find("that many plus one", 1, true) or s:find("one additional", 1, true) then
          mode = "add"
        elseif s:find("half that many", 1, true) then
          mode = "half"
        end
        if mode and s:find("counter", 1, true) and s:find("would", 1, true)
            and not (s:find("player", 1, true) and not s:find("permanent", 1, true)) then
          local ok = true
          if s:find("+1/+1 counter", 1, true) and kind ~= "plus" then
            ok = false
          end
          if s:find("artifact or creature", 1, true) then
            ok = ok and (isArtifact or isCreature)
          elseif not s:find("permanent", 1, true) and s:find("creature", 1, true) then
            ok = ok and isCreature
          end
          if s:find("you control", 1, true) then
            ok = ok and owner ~= nil and owner == p.seat
          elseif s:find("an opponent would", 1, true) then
            ok = ok and putter ~= nil and putter ~= p.seat
          elseif s:find("if you would", 1, true) then
            ok = ok and (putter or owner) == p.seat
          end
          if ok then
            if mode == "add" then
              adds = adds + 1
            elseif mode == "mul" then
              muls = muls + 1
            else
              halves = halves + 1
            end
            table.insert(names, p.obj.getName())
          end
        end
      end
    end
  end
  local out = n + adds
  for _ = 1, muls do
    out = out * 2
  end
  for _ = 1, halves do
    out = math.floor(out / 2)
  end
  return out, names
end

-- Replacement effects the table can't do the math for (Rhox Faithmender, Tainted Remedy, Boon Reflection,
-- Thought Reflection, Furnace of Rath, Torbran, Sulfuric Vortex...). kind: "gain", "lose", "draw" or "damage";
-- subject: the seat that gains / loses / draws / is dealt damage. Returns the names of the permanents in play
-- that may change the amount, so auto-resolve can ask for the real number.
local WATCH = {
  gain = { "would gain life" },
  lose = { "would lose life", "would pay life" },
  draw = { "would draw" },
  damage = { "would deal damage", "would be dealt damage", "would deal noncombat damage", "would be dealt noncombat damage" },
}

function Statics.replacers(kind, subject)
  local found, seen = {}, {}
  local phrases = WATCH[kind] or {}
  for _, p in ipairs(perms()) do
    local o = p.oracle
    if o:find("would", 1, true) then
      for s in o:gmatch("[^%.\n]+") do
        local hit = false
        for _, ph in ipairs(phrases) do
          if s:find(ph, 1, true) then
            hit = true
          end
        end
        if hit and (s:find("instead", 1, true) or s:find("plus", 1, true) or s:find("double", 1, true)) then
          local ok = true
          if kind ~= "damage" then
            if s:find("an opponent would", 1, true) then
              ok = subject ~= nil and subject ~= p.seat
            elseif s:find("if you would", 1, true) then
              ok = subject == p.seat
            end
          end
          if ok and not seen[p.obj.getGUID()] then
            seen[p.obj.getGUID()] = true
            table.insert(found, p.obj.getName())
          end
        end
      end
    end
  end
  return found
end

-- Academy Manufactor: a Clue, Food or Treasure becomes one of each.
function Statics.hasManufactor(seat)
  for _, p in ipairs(perms()) do
    if p.seat == seat and p.oracle:find("instead create one of each", 1, true) then
      return true
    end
  end
  return false
end

-- Chatterfang, Squirrel General: "those tokens plus that many 1/1 green Squirrel creature tokens are created instead".
function Statics.chatterfang(seat)
  for _, p in ipairs(perms()) do
    if p.seat == seat and p.oracle:find("plus that many", 1, true) and p.oracle:find("squirrel", 1, true)
        and p.oracle:find("token", 1, true) then
      return true
    end
  end
  return false
end

-- "Choose a creature type" permanents (Cavern of Souls, Roaming Throne...): what was chosen.
function Statics.chosenType(obj)
  local c = GameState.data and GameState.data.chosen
  return c and obj and c[obj.getGUID()] or nil
end

function Statics.setChosen(obj, ty)
  GameState.data.chosen = GameState.data.chosen or {}
  GameState.data.chosen[obj.getGUID()] = ty
end

-- Is a card with this type line (and rules text, for changeling) of the creature type `ty`?
-- Plurals are forgiven: elves -> elf, goblins -> goblin.
function Statics.typeMatches(typeLine, oracle, ty)
  typeLine = tostring(typeLine or ""):lower()
  ty = tostring(ty or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if ty == "" or not typeLine:find("creature", 1, true) then
    return false
  end
  if tostring(oracle or ""):lower():find("changeling", 1, true) then
    return true
  end
  if typeLine:find(ty, 1, true) then
    return true
  end
  for _, w in ipairs(singular(ty)) do
    if w ~= "" and typeLine:find(w, 1, true) then
      return true
    end
  end
  return false
end

-- Roaming Throne: triggered abilities of the chosen type's other creatures trigger an additional time.
function Statics.extraTriggers(src, seat)
  if src == nil or seat == nil then
    return 0
  end
  local n = 0
  local sd
  for _, p in ipairs(perms()) do
    if p.seat == seat and p.obj ~= src and p.oracle:find("triggers an additional time", 1, true)
        and p.oracle:find("creature you control of the chosen type", 1, true) then
      local ty = Statics.chosenType(p.obj)
      if ty then
        sd = sd or CardData.get(src)
        if Statics.typeMatches(sd.typeLine, sd.oracle, ty) then
          n = n + 1
        end
      end
    end
  end
  return n
end

---------------------------------------------------------------------------
-- Abilities given to other creatures: "Sliver creatures you control have flying and haste",
-- "Creatures you control have trample", "Hellbent - As long as you have no cards in hand, Sliver
-- creatures you control have '{T}: This creature deals 1 damage to target player.'"
-- Keywords go to combat; quoted abilities are added to the creature's rules text (triggers.lua,
-- stack.lua right-click Activate, mana.lua tapping for mana).
---------------------------------------------------------------------------
local GRANTABLE = { ["flying"] = true, ["first strike"] = true, ["double strike"] = true, ["deathtouch"] = true,
  ["lifelink"] = true, ["haste"] = true, ["trample"] = true, ["vigilance"] = true, ["reach"] = true,
  ["menace"] = true, ["hexproof"] = true, ["indestructible"] = true, ["defender"] = true, ["flash"] = true,
  ["infect"] = true, ["wither"] = true, ["exalted"] = true, ["shroud"] = true, ["fear"] = true, ["intimidate"] = true }

local grantSrc = { epoch = -1, at = -100, list = {} }

local function clockNow()
  return (Time and Time.time) or os.time()
end

local function parseGrantLine(line)
  line = line:gsub("%b()", "")
  line = line:gsub("^%s+", "")
  if line:find("until end of turn", 1, true) or line:find("target", 1, true) and not line:find('"', 1, true) then
    return nil
  end
  local cond
  -- "During your turn, Yuna and enchantment creatures you control have trample, lifelink, and ward {2}."
  if line:sub(1, 18) == "during your turn, " then
    cond = "myturn"
    line = line:sub(19)
  end
  local lead = line:find("as long as you have no cards in hand, ", 1, true)
  if lead then
    cond = "hellbent"
    line = line:sub(lead + #"as long as you have no cards in hand, ")
  end
  local first = line:sub(1, 4)
  if first == "when" or line:sub(1, 3) == "at " or line:sub(1, 3) == "if " or line:sub(1, 4) == "{t}:" then
    return nil
  end
  local forms = { { " you control have ", "mine" }, { " you control has ", "mine" } }
  if line:sub(1, 4) == "all " or line:sub(1, 5) == "each " then
    table.insert(forms, { " have ", "all" })
    table.insert(forms, { " has ", "all" })
  end
  for _, f in ipairs(forms) do
    local at = line:find(f[1], 1, true)
    if at and at <= 40 then
      local subj = line:sub(1, at - 1)
      if subj:find(":", 1, true) or subj:find('"', 1, true) then
        return nil
      end
      -- "All creatures get +1/+1 and have haste" (Sokenzan), "All creatures are black and have deathtouch"
      -- (Onakke Catacomb): the subject is what comes before "get" / "are".
      subj = subj:gsub(" gets? [%+%-]%d+/[%+%-]%d+ and$", ""):gsub(" are %a+ and$", "")
      local rest = line:sub(at + #f[1])
      -- "~ and enchantment creatures": the card itself as well as the others.
      local selfToo = false
      if subj:sub(1, 6) == "~ and " then
        selfToo = true
        subj = subj:sub(7)
      end
      local rec = { subj = subj, scope = f[2], cond = cond, kws = {}, lines = {}, selfToo = selfToo }
      for q in rest:gmatch('"([^"]*)"') do
        local t = q:gsub("%s+$", "")
        if t:sub(-1) ~= "." then
          t = t .. "."
        end
        table.insert(rec.lines, t)
      end
      local bare = rest:gsub('"[^"]*"', "")
      bare = bare:gsub("%.", ""):gsub(" and ", ","):gsub("^%s+", "")
      for raw in bare:gmatch("[^,]+") do
        local tok = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if GRANTABLE[tok] then
          table.insert(rec.kws, tok)
          if tok == "exalted" then
            table.insert(rec.lines, "exalted")
          end
        elseif tok:sub(1, 7) == "outlast" then
          local ol = tok:gsub("outlast (%d+)", "{%1}, {t}: put a +1/+1 counter on this creature. activate only as a sorcery.")
          table.insert(rec.lines, ol)
        end
      end
      if #rec.kws > 0 or #rec.lines > 0 then
        return rec
      end
      return nil
    end
  end
  return nil
end

local function grantSources()
  local ep = Events and Events.epoch or 0
  local now = clockNow()
  if grantSrc.epoch == ep and now - grantSrc.at < 2 then
    return grantSrc.list
  end
  local out = {}
  for _, p in ipairs(perms()) do
    local fl = Statics.forgeLines(p.obj.getName(), p.oracle)
    if p.oracle:find(" have ", 1, true) or p.oracle:find(" has ", 1, true) or next(fl) ~= nil then
      local nm = tostring(p.obj.getName() or ""):lower()
      local idx = 0
      for line in (p.oracle .. "\n"):gmatch("([^\n]*)\n") do
        idx = idx + 1
        local l2 = line
        if nm ~= "" and l2:find(nm, 1, true) then
          l2 = l2:gsub(nm:gsub("([%%%-%.%+%*%?%[%]%^%$%(%)])", "%%%1"), "~")
        end
        -- The short name too ("Yuna" for Yuna, Hope of Spira).
        local short = nm:match("^([^,]+),")
        if short and #short > 2 and l2:find(short, 1, true) then
          l2 = l2:gsub(short:gsub("([%%%-%.%+%*%?%[%]%^%$%(%)])", "%%%1"), "~")
        end
        local rec
        if l2:find(" have ", 1, true) or l2:find(" has ", 1, true) then
          rec = parseGrantLine(l2)
        end
        -- Forge's reading of a line the reader above doesn't understand ("... get +1/+1 and have flying").
        local fe = fl[idx]
        if rec == nil and fe and fe.kind == "C" and (fe.f.k or fe.f.q) then
          rec = { forge = fe.f.f, scope = "all", kws = {}, lines = {} }
          for k in ((fe.f.k or "") .. "/"):gmatch("([^/]*)/") do
            if k ~= "" then
              table.insert(rec.kws, k)
            end
          end
          -- Granted abilities ("have '{T}: Add {G}.'"): their quoted text, as the reader above takes it.
          if fe.f.q then
            for qt in l2:gmatch('"([^"]*)"') do
              local t = qt:gsub("%s+$", "")
              if t:sub(-1) ~= "." then
                t = t .. "."
              end
              table.insert(rec.lines, t)
            end
          end
        end
        if rec then
          rec.obj, rec.seat = p.obj, p.seat
          table.insert(out, rec)
        end
      end
    end
  end
  grantSrc.epoch, grantSrc.at, grantSrc.list = ep, now, out
  return out
end

local function handEmpty(seat)
  local n = 1
  pcall(function() n = #(Player[seat].getHandObjects() or {}) end)
  return n == 0
end

-- What `obj` is given by the other permanents: { kws = {"flying", ...}, lines = {"{t}: add ...", ...} }
function Statics.grants(obj)
  local out = { kws = {}, lines = {}, from = {} }
  if obj == nil then
    return out
  end
  local srcs = grantSources()
  local ok, loc = pcall(function() return Zones.regionAt(obj.getPosition()) end)
  if not ok or loc == nil or not IN[loc.region] or loc.seat == nil then
    return out
  end
  -- Quoted abilities from its Equipment / Auras (Thornbite Staff).
  if Equip and Equip.attachments and Equip.modsOf then
    local oka, atts = pcall(Equip.attachments, obj)
    for _, a in ipairs(oka and atts or {}) do
      local m = Equip.modsOf(a)
      for _, l in ipairs(m.lines or {}) do
        table.insert(out.lines, l)
        table.insert(out.from, a.getName())
      end
    end
  end
  local d = dataOf(obj)
  local q = { obj = obj, seat = loc.seat, tl = tostring(d.typeLine or ""):lower(), token = obj.hasTag("Token") }
  local seenK = {}
  for _, g in ipairs(srcs) do
    local sideOk = g.scope == "all" or g.seat == loc.seat
    local fits
    if g.forge then
      fits = Statics.forgeMatches(g.forge, q, { obj = g.obj, seat = g.seat })
    else
      local condOk = (g.cond ~= "hellbent" or handEmpty(g.seat))
        and (g.cond ~= "myturn" or (Turns and Turns.isActiveSeat and Turns.isActiveSeat(g.seat)))
      local subjOk = (g.selfToo and obj == g.obj) or subjectMatches(g.subj, q, { obj = g.obj })
      -- "<type> creatures" (enchantment creatures, artifact creatures): a creature with that type too.
      if not subjOk then
        local tw = g.subj:match("^(%a+) creatures$")
        subjOk = tw ~= nil and q.tl:find("creature", 1, true) ~= nil and q.tl:find(tw, 1, true) ~= nil
      end
      fits = sideOk and condOk and subjOk
    end
    if fits then
      for _, k in ipairs(g.kws) do
        if not seenK[k] then
          seenK[k] = true
          table.insert(out.kws, k)
        end
      end
      local srcName = "?"
      pcall(function() srcName = g.obj.getName() end)
      for _, l in ipairs(g.lines) do
        table.insert(out.lines, l)
        table.insert(out.from, srcName)
      end
    end
  end
  return out
end

-- Which permanent gave `obj` this ability text (for the chat line), or nil if it's the card's own.
function Statics.grantedBy(obj, text)
  local t = tostring(text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local okg, g = pcall(Statics.grants, obj)
  if not okg or g == nil then
    return nil
  end
  for i, l in ipairs(g.lines) do
    if l == t then
      return g.from[i]
    end
  end
  return nil
end

-- Granted keywords show on the card's label: when a lord enters or leaves, every creature it
-- affects is redrawn (not only the ones that moved). Called from Statics.compute.
local grantLabelSig = {}
function Statics.refreshGrantLabels()
  grantSrc.at = -100     -- read the lords again now
  -- Nothing gives keywords and no card shows given ones: nothing to redraw (the common case).
  if #grantSources() == 0 and next(grantLabelSig) == nil then
    return
  end
  local seen = {}
  for _, p in ipairs(perms()) do
    local g = p.obj.getGUID()
    seen[g] = true
    local okg, gr = pcall(Statics.grants, p.obj)
    local sig = (okg and gr) and table.concat(gr.kws, ",") or ""
    if (grantLabelSig[g] or "") ~= sig then
      grantLabelSig[g] = sig
      if Counters and Counters.render then
        pcall(Counters.render, p.obj)
      end
    end
  end
  for g in pairs(grantLabelSig) do
    if not seen[g] then
      grantLabelSig[g] = nil
    end
  end
end

function Statics.hasGrantedKeyword(obj, kw)
  kw = tostring(kw):lower()
  for _, k in ipairs(Statics.grants(obj).kws) do
    if k == kw then
      return true
    end
  end
  return false
end

-- "Sliver spells you cast have cascade" (The First Sliver): how many extra cascades this spell gets.
function Statics.spellGrantCount(card, seat, word)
  local d = dataOf(card)
  local tl = tostring(d.typeLine or ""):lower()
  local n = 0
  for _, p in ipairs(perms()) do
    if p.seat == seat then
      for line in (p.oracle .. "\n"):gmatch("([^\n]*)\n") do
        local at = line:find(" spells you cast have " .. word, 1, true)
        if at and at <= 30 then
          local subj = line:sub(1, at - 1):gsub("^%s+", "")
          -- "Sliver spells", "Instant and sorcery spells": any of the named types.
          local hit = false
          for w in subj:gmatch("[%a%-]+") do
            if w ~= "and" and w ~= "or" then
              local base = w:gsub("s$", "")
              if base ~= "" and tl:find(base, 1, true) then
                hit = true
              end
            end
          end
          if hit then
            n = n + 1
          end
        end
      end
    end
  end
  return n
end

-- Notion Thief: who (if anyone) replaces this seat's extra draws, and with which card.
-- Mana that isn't lost as steps end: { all = Upwelling, colorless = Horizon Stone / Kruphix (the rest becomes
-- colorless), keep = { G = true } (Omnath, Locus of Mana: "you don't lose unspent green mana") }.
local KEEP_WORDS = { white = "W", blue = "U", black = "B", red = "R", green = "G" }
function Statics.manaKeep(seat)
  local out = { keep = {}, from = {} }
  for _, p in ipairs(perms()) do
    local o = p.oracle
    if o:find("don't lose unspent mana", 1, true) or o:find("mana pools don't empty", 1, true) then
      out.all = true
      table.insert(out.from, p.obj.getName())
    elseif p.seat == seat then
      if o:find("if you would lose unspent mana, that mana becomes colorless instead", 1, true) then
        out.colorless = true
        table.insert(out.from, p.obj.getName())
      end
      local w = o:match("you don't lose unspent (%a+) mana")
      if w and KEEP_WORDS[w] then
        out.keep[KEEP_WORDS[w]] = true
        table.insert(out.from, p.obj.getName())
      end
    end
  end
  return out
end

-- "Skip your draw step." (Damia, Sage of Stone, Necropotence): the name of a permanent of `seat`'s that says so.
function Statics.skipsDrawStep(seat)
  for _, p in ipairs(perms()) do
    if p.seat == seat and p.oracle:find("skip your draw step", 1, true) then
      return p.obj.getName()
    end
  end
  return nil
end

function Statics.drawReplacer(seat)
  for _, p in ipairs(perms()) do
    -- Only an OPPONENT's Notion Thief (in 2HG a teammate's doesn't take your draws).
    if p.seat ~= seat and TableSetup.isOpponent(p.seat, seat)
        and p.oracle:find("except the first one they draw in each of their draw steps", 1, true) then
      return p.seat, p.obj
    end
  end
  return nil
end

-- Panharmonicon: how many of them this seat controls.
function Statics.panharmonicons(seat)
  local n = 0
  for _, p in ipairs(perms()) do
    if p.seat == seat then
      if p.oracle:find("triggers an additional time", 1, true) and p.oracle:find("artifact or creature", 1, true) then
        n = n + 1
      else
        -- Forge's Panharmonicon static, for wording the line above doesn't catch.
        for _, e in pairs(Statics.forgeLines(p.obj.getName(), p.oracle)) do
          if e.kind == "PH" then
            n = n + 1
            break
          end
        end
      end
    end
  end
  return n
end

-- Forge's combat statics (CantAttack / CantBlock / CantBlockBy) of the permanents on the table:
-- { { kind, f / a / b, src = { obj, seat }, name } }. The table's rules-text reader has none of these.
local combatSrc = { epoch = -1, at = -100, list = {} }
local function combatStatics()
  local ep = Events and Events.epoch or 0
  local now = clockNow()
  if combatSrc.epoch == ep and now - combatSrc.at < 2 then
    return combatSrc.list
  end
  local out = {}
  for _, p in ipairs(perms()) do
    for _, e in pairs(Statics.forgeLines(p.obj.getName(), p.oracle)) do
      if e.kind == "CA" or e.kind == "CB" or e.kind == "CAB" or e.kind == "CBB" then
        table.insert(out, { kind = e.kind, f = e.f, src = { obj = p.obj, seat = p.seat }, name = p.obj.getName() })
      end
    end
  end
  combatSrc.epoch, combatSrc.at, combatSrc.list = ep, now, out
  return out
end

local function asQ(obj)
  local okl, loc = pcall(function() return Zones.regionAt(obj.getPosition()) end)
  local d = dataOf(obj)
  return { obj = obj, seat = okl and loc and loc.seat or nil, tl = tostring(d.typeLine or ""):lower(), token = obj.hasTag("Token") }
end

-- Why `card` can't attack (Forge static), or nil.
-- The plane's combat restrictions: Tazeem ("Creatures can't block"), Celestine Reef ("Creatures without
-- flying or islandwalk can't attack"), Hedron Fields of Agadeem ("Creatures with power 7 or greater can't
-- attack or block"). what: "attack" or "block". Returns the plane's name, or nil.
local function planeForbids(card, what)
  local obj, text = planeNow()
  if obj == nil or text == nil or text == "" then
    return nil
  end
  local nm = "the plane"
  pcall(function() nm = obj.getName() end)
  local function kw(k)
    return Effects ~= nil and Effects.hasKeyword ~= nil and Effects.hasKeyword(card, k) == true
  end
  if text:find("creatures can't " .. what, 1, true) and not text:find("creatures can't " .. what .. " you", 1, true) then
    local before = text:sub(1, (text:find("creatures can't " .. what, 1, true)) - 1)
    if before == "" or before:sub(-1) == "\n" then
      return nm
    end
  end
  if what == "attack" and text:find("creatures without flying or islandwalk can't attack", 1, true)
      and not kw("flying") and not kw("islandwalk") then
    return nm
  end
  if text:find("creatures with power 7 or greater can't attack or block", 1, true) then
    local pw = tonumber(Counters and Counters.stats and Counters.stats(card).power or "") or 0
    if pw >= 7 then
      return nm
    end
  end
  return nil
end

function Statics.cantAttack(card)
  local pf = planeForbids(card, "attack")
  if pf then
    return pf
  end
  local q = asQ(card)
  for _, s in ipairs(combatStatics()) do
    if (s.kind == "CA" or s.kind == "CAB") and Statics.forgeMatches(s.f.f, q, s.src) then
      return s.name
    end
  end
  return nil
end

-- Why `blocker` can't block `attacker` (Forge static), or nil.
function Statics.cantBlock(blocker, attacker)
  local pf = planeForbids(blocker, "block")
  if pf then
    return blocker.getName() .. " can't block (" .. pf .. ")"
  end
  local b = asQ(blocker)
  local a = attacker and asQ(attacker)
  for _, s in ipairs(combatStatics()) do
    if (s.kind == "CB" or s.kind == "CAB") and Statics.forgeMatches(s.f.f, b, s.src) then
      return blocker.getName() .. " can't block (" .. s.name .. ")"
    end
    if s.kind == "CBB" and a and Statics.forgeMatches(s.f.a, a, s.src) and (s.f.b == nil or Statics.forgeMatches(s.f.b, b, s.src)) then
      return "can't be blocked by " .. blocker.getName() .. " (" .. s.name .. ")"
    end
  end
  return nil
end

-- Forge's cost statics ("Artifact spells you cast cost {1} less", "Noncreature spells cost {1} more"):
-- the generic mana a spell costs less (negative: more), and which permanents say so. Chat only:
-- the payment itself stays as it is.
function Statics.costChange(card, caster)
  local q = asQ(card)
  q.seat = caster
  local n, from = 0, {}
  local function use(e, src)
    local w = e.f.w
    if (w == "you" and caster ~= src.seat) or (w == "opp" and caster == src.seat) then
      return
    end
    if Statics.forgeMatches(e.f.f, q, src) then
      local k = tonumber(e.f.n) or 0
      n = n + k
      table.insert(from, src.obj.getName() .. (k >= 0 and (" -" .. k) or (" +" .. -k)))
    end
  end
  for _, p in ipairs(perms()) do
    for _, e in pairs(Statics.forgeLines(p.obj.getName(), p.oracle)) do
      if e.kind == "RC" and not tostring(e.f.f):find("self", 1, true) then
        use(e, { obj = p.obj, seat = p.seat })
      end
    end
  end
  -- The plane: "Creature spells cost {2} less to cast" (Turri Island), "Red spells cost {1} less to cast"
  -- (Feeding Grounds), "Artifact spells cost {1} less to cast" (Esper).
  local pobj, ptext = planeNow()
  if pobj and ptext then
    local d0 = dataOf(card)
    local tl0 = tostring(d0.typeLine or ""):lower()
    local cols = Statics.colorsOf(card, caster)
    for w, k in ptext:gmatch("(%a+) spells cost {(%d+)} less to cast") do
      local fits = (COLOR_WORD[w] and cols[COLOR_WORD[w]] == true) or (not COLOR_WORD[w] and tl0:find(w, 1, true) ~= nil)
      if fits then
        n = n + tonumber(k)
        table.insert(from, pobj.getName() .. " -" .. k)
      end
    end
  end
  -- "This spell costs {2} less to cast" on the card itself.
  local d = dataOf(card)
  for _, e in pairs(Statics.forgeLines(card.getName(), tostring(d.oracle or ""):lower())) do
    if e.kind == "RC" and tostring(e.f.f):find("self", 1, true) then
      use(e, { obj = card, seat = caster })
    end
  end
  return n, from
end

Events.on("spellCast", function(d)
  if d == nil or d.card == nil or d.controller == nil then
    return
  end
  -- Sorcery speed: a spell that isn't an instant, cast on someone else's turn, needs flash.
  local active = GameState.data and GameState.data.turn and GameState.data.turn.activeSeat
  local tl = tostring(dataOf(d.card).typeLine or ""):lower()
  if active and not Turns.isActiveSeat(d.controller) and tl ~= "" and not tl:find("instant", 1, true) and not tl:find("land", 1, true) then
    local okF, flash = pcall(Statics.hasFlash, d.card, d.controller)
    if okF and not flash then
      broadcastToColor(d.card.getName() .. " isn't an instant and has no flash: normally it's cast only on your own turn.",
        d.controller, { 1, 0.6, 0.2 })
    end
  end
  local okC, banned = pcall(Statics.cantCast, d.card, d.controller)
  if okC and banned then
    broadcastToAll(d.card.getName() .. ": " .. d.controller .. " can't cast this spell (" .. banned .. ") - take it back if so.",
      { 1, 0.55, 0.3 })
  end
  local ok, n, from = pcall(Statics.costChange, d.card, d.controller)
  if ok and n and #from > 0 and n ~= 0 then
    printToAll("MTG > " .. d.card.getName() .. " costs {" .. math.abs(n) .. "} " .. (n > 0 and "less" or "more")
      .. " (" .. table.concat(from, ", ") .. "). Adjust the payment by hand.", { 0.75, 0.8, 0.9 })
  end
end)

-- Every Forge static of the permanents on the table that isn't Continuous: { { kind, f, src, name } }.
local otherSrc = { epoch = -1, at = -100, list = {} }
function Statics.forgeOthers()
  local ep = Events and Events.epoch or 0
  local now = clockNow()
  if otherSrc.epoch == ep and now - otherSrc.at < 2 then
    return otherSrc.list
  end
  local out = {}
  for _, p in ipairs(perms()) do
    for _, e in pairs(Statics.forgeLines(p.obj.getName(), p.oracle)) do
      if e.kind ~= "C" then
        table.insert(out, { kind = e.kind, f = e.f, src = { obj = p.obj, seat = p.seat }, name = p.obj.getName() })
      end
    end
  end
  otherSrc.epoch, otherSrc.at, otherSrc.list = ep, now, out
  return out
end

-- "Attacks each combat if able": the permanent that says so, or nil.
function Statics.mustAttack(card)
  local q = asQ(card)
  for _, s in ipairs(Statics.forgeOthers()) do
    if s.kind == "MA" and Statics.forgeMatches(s.f.f, q, s.src) then
      return s.name
    end
  end
  return nil
end

local function whoFits(w, actor, srcSeat)
  return w == "all" or (w == "you" and actor == srcSeat) or (w == "opp" and actor ~= srcSeat)
end

-- "Your opponents can't cast creature spells": the permanent that says so, or nil.
function Statics.cantCast(card, caster)
  local q = asQ(card)
  q.seat = caster
  for _, s in ipairs(Statics.forgeOthers()) do
    if s.kind == "NC" and whoFits(s.f.w, caster, s.src.seat) and Statics.forgeMatches(s.f.f, q, s.src) then
      return s.name
    end
  end
  return nil
end

-- "Activated abilities of artifacts can't be activated": the permanent that says so, or nil.
function Statics.cantActivate(obj, seat, isMana)
  local q = asQ(obj)
  for _, s in ipairs(Statics.forgeOthers()) do
    if s.kind == "NA" and not (isMana and s.f.nm) and whoFits(s.f.w, seat, s.src.seat) and Statics.forgeMatches(s.f.f, q, s.src) then
      return s.name
    end
  end
  return nil
end

-- Can `caster` cast this spell at instant speed (flash, or "as though it had flash")?
function Statics.hasFlash(card, caster)
  local d = dataOf(card)
  for _, k in ipairs(type(d.keywords) == "table" and d.keywords or {}) do
    if tostring(k):lower() == "flash" then
      return true
    end
  end
  local o = tostring(d.oracle or ""):lower()
  if o:sub(1, 5) == "flash" or o:find("\nflash", 1, true) or o:find("as though it had flash", 1, true) then
    return true
  end
  -- The table's own reading: a permanent of the caster's that says "as though they had flash".
  for _, p in ipairs(perms()) do
    if p.plane then
      -- Akoum: "Players may cast enchantment spells as though they had flash."
      local ty = p.oracle:match("players may cast (%a+) spells as though they had flash")
      if ty and tostring(d.typeLine or ""):lower():find(ty, 1, true) then
        return true
      end
    elseif p.seat == caster and (p.oracle:find("as though they had flash", 1, true) or p.oracle:find("as though it had flash", 1, true)) then
      return true
    end
  end
  -- Forge's CastWithFlash statics (on the battlefield, or the spell's own).
  local q = asQ(card)
  q.seat = caster
  for _, s in ipairs(Statics.forgeOthers()) do
    if s.kind == "FL" and whoFits(s.f.w, caster, s.src.seat) and Statics.forgeMatches(s.f.f, q, s.src) then
      return true
    end
  end
  for _, e in pairs(Statics.forgeLines(card.getName(), o)) do
    if e.kind == "FL" and tostring(e.f.f):find("self", 1, true) then
      return true
    end
  end
  return false
end

-- "Players can't gain life" / "Your opponents can't gain life": the permanent that says so, or nil.
function Statics.cantGainLife(seat)
  for _, s in ipairs(Statics.forgeOthers()) do
    if s.kind == "NL" and whoFits(s.f.w, seat, s.src.seat) then
      return s.name
    end
  end
  return nil
end
