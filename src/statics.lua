-- Static effects the table can show for itself: "this creature gets +1/+1 for each artifact you control"
-- (Urza's Construct), "creature tokens you control get +1/+1" (Intangible Virtue), and token doublers
-- (Anointed Procession, Doubling Season, Academy Manufactor).
Statics = Statics or {}

local bonus = {}        -- guid -> { p, t }
local pending = false

local function dataOf(obj)
  local d = {}
  pcall(function() d = JSON.decode(obj.getGMNotes()) or {} end)
  return d
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
      artifacts[p.seat] = (artifacts[p.seat] or 0) + 1
    end
  end
  for _, p in ipairs(list) do
    for line in (p.oracle .. "\n"):gmatch("([^\n]*)\n") do
      -- "This creature gets +1/+1 for each artifact you control."
      local a, b = line:match("^this creature gets %+(%d+)/%+(%d+) for each artifact you control")
      if a then
        add(p, tonumber(a) * (artifacts[p.seat] or 0), tonumber(b) * (artifacts[p.seat] or 0))
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

-- Academy Manufactor: a Clue, Food or Treasure becomes one of each.
function Statics.hasManufactor(seat)
  for _, p in ipairs(perms()) do
    if p.seat == seat and p.oracle:find("instead create one of each", 1, true) then
      return true
    end
  end
  return false
end
