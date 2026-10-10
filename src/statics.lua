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

local function subjectMatches(subj, q, p)
  subj = subj:gsub("^%s+", ""):gsub("%s+$", "")
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
        local base = w:gsub("s$", "")
        if base ~= "" and q.tl:find(base, 1, true) then
          return true
        end
      end
    end
    return false
  end
  local word = subj:match("^([%a%-]+)s$") or subj:match("^([%a%-]+) creatures$")
  if word then
    return q.tl:find(word, 1, true) ~= nil
  end
  return false
end

function Statics.compute()
  local list = perms()
  local new = {}
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
      -- "Creature tokens you control get +1/+1 ..." / "Other Soldiers you control get +1/+1".
      -- (plain search first: MoonSharp gives up on lazy patterns over long rules text)
      local subj, x, y
      local at = line:find(" you control get +", 1, true)
      if at and at <= 40 then
        x, y = line:sub(at):match("^ you control get %+(%d+)/%+(%d+)")
        if x then
          subj = line:sub(1, at - 1)
        end
      end
      if subj and #subj < 40 then
        for _, q in ipairs(list) do
          if q.seat == p.seat and subjectMatches(subj, q, p) then
            add(q, tonumber(x), tonumber(y))
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
