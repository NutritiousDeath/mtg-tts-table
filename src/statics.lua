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
  return list
end

function Statics.bonus(obj)
  local b = obj and bonus[obj.getGUID()]
  if b then
    return b.p, b.t
  end
  return 0, 0
end

-- "elves" -> elf, "wolves" -> wolf, "allies" -> ally, "zombies" -> zombie, "soldiers" -> soldier.
local function singular(w)
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
  if q.tl:find("creature", 1, true) == nil then
    return false
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
    counts[p.seat] = (counts[p.seat] or 0) + (Pile and Pile.count(p.obj) or 1)
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
    for line in (p.oracle .. "\n"):gmatch("([^\n]*)\n") do
      -- "This creature gets +1/+1 for each artifact you control."
      local a, b = line:match("^this creature gets %+(%d+)/%+(%d+) for each artifact you control")
      if a then
        add(p, tonumber(a) * (artifacts[p.seat] or 0), tonumber(b) * (artifacts[p.seat] or 0))
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
        if subj and #subj < 40 and okCond then
          if subj:sub(1, 4) == "all " then
            subj = subj:sub(5)
          end
          for _, q in ipairs(list) do
            local sideOk = (scope == "all") or (scope == "mine" and q.seat == p.seat) or (scope == "opps" and q.seat ~= p.seat)
            if sideOk and subjectMatches(subj, q, p) then
              add(q, tonumber(x), tonumber(y))
            end
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
      local rest = line:sub(at + #f[1])
      local rec = { subj = subj, scope = f[2], cond = cond, kws = {}, lines = {} }
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
    if p.oracle:find(" have ", 1, true) or p.oracle:find(" has ", 1, true) then
      local nm = tostring(p.obj.getName() or ""):lower()
      for line in (p.oracle .. "\n"):gmatch("([^\n]*)\n") do
        local l2 = line
        if nm ~= "" and l2:find(nm, 1, true) then
          l2 = l2:gsub(nm:gsub("([%%%-%.%+%*%?%[%]%^%$%(%)])", "%%%1"), "~")
        end
        if l2:find(" have ", 1, true) or l2:find(" has ", 1, true) then
          local rec = parseGrantLine(l2)
          if rec then
            rec.obj, rec.seat = p.obj, p.seat
            table.insert(out, rec)
          end
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
  local out = { kws = {}, lines = {} }
  if obj == nil then
    return out
  end
  local srcs = grantSources()
  if #srcs == 0 then
    return out
  end
  local ok, loc = pcall(function() return Zones.regionAt(obj.getPosition()) end)
  if not ok or loc == nil or not IN[loc.region] or loc.seat == nil then
    return out
  end
  local d = dataOf(obj)
  local q = { obj = obj, seat = loc.seat, tl = tostring(d.typeLine or ""):lower(), token = obj.hasTag("Token") }
  local seenK = {}
  for _, g in ipairs(srcs) do
    local sideOk = g.scope == "all" or g.seat == loc.seat
    if sideOk and (g.cond ~= "hellbent" or handEmpty(g.seat)) and subjectMatches(g.subj, q, { obj = g.obj }) then
      for _, k in ipairs(g.kws) do
        if not seenK[k] then
          seenK[k] = true
          table.insert(out.kws, k)
        end
      end
      for _, l in ipairs(g.lines) do
        table.insert(out.lines, l)
      end
    end
  end
  return out
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
          local base = subj:gsub("s$", "")
          if base ~= "" and tl:find(base, 1, true) then
            n = n + 1
          end
        end
      end
    end
  end
  return n
end

-- Notion Thief: who (if anyone) replaces this seat's extra draws, and with which card.
function Statics.drawReplacer(seat)
  for _, p in ipairs(perms()) do
    if p.seat ~= seat and p.oracle:find("except the first one they draw in each of their draw steps", 1, true) then
      return p.seat, p.obj
    end
  end
  return nil
end

-- Panharmonicon: how many of them this seat controls.
function Statics.panharmonicons(seat)
  local n = 0
  for _, p in ipairs(perms()) do
    if p.seat == seat and p.oracle:find("triggers an additional time", 1, true) and p.oracle:find("artifact or creature", 1, true) then
      n = n + 1
    end
  end
  return n
end
