--[[
  fires.lua
  The turn fires: two gothic fireplaces on the floor (at the corners the deck importers point to, or
  the two ends of the 2HG table), two fire pits low on the floor in the other two corners (four-seat
  layout) and the four tower torches all burn in one colour that follows the game:
    * before the game and through mulligans: purple;
    * when the last player keeps: a ROAR (big flare, sparks, a light flash and the roar sound) and every
      fire turns the starting player's colour;
    * each new turn: a WOOSH and the fires turn the new active player's colour;
    * game over: a roar in the winner's colour.
  The stained glass (table.lua) joins in: the window behind the active player glows in their colour, the
  two big corner windows glow purple before the game.
  The fires are Unity AssetBundles (tools/unity/MTGTorchBuilder.cs) with one looping effect per colour
  and roar / woosh trigger effects; the stone fireplaces are plain TTS models (tools/make_hearth.py).
  !fire <color> [roar|woosh] tries a colour by hand (Purple, White, Red, Green, Blue).
--]]

Fires = {}

local BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/"
local HEARTH_VERSION = "?v=4"
local HEARTH_FIRE_URL = BASE .. "torch/mtg_hearth.unity3d?v=12"
-- The roar / woosh sounds on their own invisible object (trigger 0 roar, 1 woosh), so every fire can
-- change colour the moment the wave reaches it without cutting the sound off.
local SFX_URL = BASE .. "torch/mtg_sfx.unity3d?v=4"
local STONE_URL = BASE .. "table/stone.png?v=3"
local FLOOR_Y = -31

local INDEX = { Purple = 0, White = 1, Red = 2, Green = 3, Blue = 4 }
local ROAR, WOOSH, SILENT = 0, 5, 10   -- trigger effect offsets (see the builder)

local function state()
  GameState.data.table = GameState.data.table or {}
  return GameState.data.table
end

-- Where the fireplaces stand: out past the deck importers, facing the table.
--   four / two seats: the two corners (White/Red and Green/Blue), in the corner of the floor;
--   2HG: the middle of the two short ends.
local function hearthSpots()
  if TableSetup.layout() == "twohg" then
    -- The four corners have no fireplace: a fire pit low on the floor in each (tools/make_firepit.py),
    -- clear of the corner walls (the 2HG room's corner walls sit 165 out from the middle).
    return {
      { x = -146, z = 0, mesh = "hearth_edge.obj" },
      { x = 146, z = 0, mesh = "hearth_edge.obj" },
      { x = 103, z = 95, mesh = "firepit.obj", pit = true },
      { x = -103, z = 95, mesh = "firepit.obj", pit = true },
      { x = 103, z = -95, mesh = "firepit.obj", pit = true },
      { x = -103, z = -95, mesh = "firepit.obj", pit = true },
    }
  end
  local r = 152 / math.sqrt(2)
  -- The other two corners: a fire pit low on the floor (tools/make_firepit.py), so they aren't dark.
  -- Further in than the fireplaces: the pit is free-standing, clear of the corner wall and its window.
  local rp = 138 / math.sqrt(2)
  return {
    { x = -r, z = -r, mesh = "hearth_corner.obj" },
    { x = r, z = r, mesh = "hearth_corner.obj" },
    { x = rp, z = -rp, mesh = "firepit.obj", pit = true },
    { x = -rp, z = rp, mesh = "firepit.obj", pit = true },
  }
end

local function atan2(y, x)
  return math.atan2 and math.atan2(y, x) or math.atan(y, x)
end

-- Hearth local space: +Z faces the table; the firebox sits on a 30-high podium plus the 2 hearth step
-- (so the fire burns at table height), 1.5 forward.
local function spotFrame(sp)
  local len = math.sqrt(sp.x * sp.x + sp.z * sp.z)
  local dx, dz = -sp.x / len, -sp.z / len            -- toward the table
  local yaw = math.deg(atan2(dx, dz))
  local fire = { sp.x + dx * 1.5, FLOOR_Y + 32.05, sp.z + dz * 1.5 }
  if sp.pit then
    fire = { sp.x, FLOOR_Y + 0.45, sp.z }   -- on the pit's ash bed
  end
  return yaw, fire
end

function Fires.place()
  local st = state()
  for i, sp in ipairs(hearthSpots()) do
    local yaw, fire = spotFrame(sp)
    local m = st.hearths and st.hearths[i] and getObjectFromGUID(st.hearths[i])
    if m then
      m.setLock(true)
      m.setPosition({ sp.x, FLOOR_Y, sp.z })
      m.setRotation({ 0, yaw, 0 })
    end
    local f = st.hearthFires and st.hearthFires[i] and getObjectFromGUID(st.hearthFires[i])
    if f then
      f.setLock(true)
      f.setPosition(fire)
      f.setRotation({ 0, yaw, 0 })
    end
  end
end

local function spawnLocked(kind, pos, yaw, name, tag, custom, onReady)
  local obj = spawnObject({
    type = kind,
    position = pos,
    rotation = { 0, yaw, 0 },
    scale = { 1, 1, 1 },
    sound = false,
    callback_function = function(o)
      o.setLock(true)
      o.setPosition(pos)
      o.setRotation({ 0, yaw, 0 })
      o.interactable = false
      o.setName(name)
      o.addTag(tag)
      onReady(o)
    end,
  })
  obj.setCustomObject(custom)
end

function Fires.ensure()
  local st = state()
  st.hearths = st.hearths or {}
  st.hearthFires = st.hearthFires or {}
  local spots = hearthSpots()
  for i, sp in ipairs(spots) do
    local yaw, fire = spotFrame(sp)
    local mesh = BASE .. "hearth/" .. sp.mesh .. HEARTH_VERSION
    local m = st.hearths[i] and getObjectFromGUID(st.hearths[i])
    local co = m and m.getCustomObject()
    if not (m and co and co.mesh == mesh) then
      if m then
        m.destruct()
      end
      spawnLocked("Custom_Model", { sp.x, FLOOR_Y, sp.z }, yaw, sp.pit and "Fire Pit" or "Gothic Fireplace", "TableHearth",
        { mesh = mesh, diffuse = STONE_URL, collider = mesh, convex = false, type = 0, material = 3 },
        function(o) st.hearths[i] = o.getGUID() end)
    end
    local f = st.hearthFires[i] and getObjectFromGUID(st.hearthFires[i])
    local fco = f and f.getCustomObject()
    if not (f and fco and fco.assetbundle == HEARTH_FIRE_URL) then
      if f then
        f.destruct()
      end
      spawnLocked("Custom_AssetBundle", fire, yaw, sp.pit and "Pit Fire" or "Hearth Fire", "HearthFire",
        { assetbundle = HEARTH_FIRE_URL, type = 0 },
        function(o)
          st.hearthFires[i] = o.getGUID()
          Wait.time(function() Fires.refresh() end, 1)
        end)
    end
  end
  -- Fireplaces / pits the current layout doesn't use (the 2HG table has no fire pits).
  for _, list in ipairs({ st.hearths, st.hearthFires }) do
    for i = #list, #spots + 1, -1 do
      local o = getObjectFromGUID(list[i])
      if o then
        o.destruct()
      end
      list[i] = nil
    end
  end
  -- Strays from an older layout / version.
  for _, tag in ipairs({ "TableHearth", "HearthFire" }) do
    for _, o in ipairs(getObjectsWithTag(tag)) do
      local keep = false
      for _, g in ipairs(tag == "TableHearth" and st.hearths or st.hearthFires) do
        keep = keep or g == o.getGUID()
      end
      if not keep and o.getGUID() ~= nil then
        Wait.time(function()
          local still = false
          for _, g in ipairs(tag == "TableHearth" and st.hearths or st.hearthFires) do
            still = still or g == o.getGUID()
          end
          if not still and not o.isDestroyed() then
            o.destruct()
          end
        end, 3)
      end
    end
  end
  -- The sound object, hidden under the table's pedestal.
  local sfx = st.sfx and getObjectFromGUID(st.sfx)
  local sco = sfx and sfx.getCustomObject()
  if not (sfx and sco and sco.assetbundle == SFX_URL) then
    if sfx then
      sfx.destruct()
    end
    for _, o in ipairs(getObjectsWithTag("FireSfx")) do
      o.destruct()
    end
    spawnLocked("Custom_AssetBundle", { 0, FLOOR_Y + 1, 0 }, 0, "Fire Sounds", "FireSfx",
      { assetbundle = SFX_URL, type = 0 }, function(o) st.sfx = o.getGUID() end)
  end
  Fires.place()
  Wait.time(function() Fires.refresh() end, 2)
end

-- Every fire object: the hearth fires first (the first one is the one that makes the sound), then the torches.
local function fireObjects()
  local out = {}
  local st = state()
  for _, list in ipairs({ st.hearthFires or {}, st.torches or {} }) do
    for _, g in ipairs(list) do
      local o = getObjectFromGUID(g)
      if o and not o.isDestroyed() then
        table.insert(out, o)
      end
    end
  end
  return out
end

-- Run fn(o) once the bundle has loaded.
local function whenLoaded(o, fn)
  Wait.condition(function()
    if not o.isDestroyed() then
      pcall(fn, o)
    end
  end, function()
    return o.isDestroyed() or (o.loading_custom == false and o.AssetBundle ~= nil)
  end, 30)
end

-- Turn every fire to a colour (Purple, White, Red, Green, Blue), with a "roar" or "woosh" first.
-- The stained glass follows too: the window behind the active player glows (purple: the corner windows).
-- The colours the fires share out: in 2HG, on a team's turn, both teammates' colours (the fires
-- alternate between them); otherwise just the one colour.
local function shareColors(color)
  local d = GameState.data
  local t = d.turn or {}
  if d.started and color == t.activeSeat and Turns and Turns.activeTeam
      and TableSetup.isTeamGame and TableSetup.isTeamGame() then
    local out = {}
    for _, c in ipairs(Turns.activeTeam()) do
      if INDEX[c] then
        table.insert(out, c)
      end
    end
    if #out > 0 then
      return out
    end
  end
  return { color }
end

-- Turn every fire to a colour (Purple, White, Red, Green, Blue), with a "roar" or "woosh".
-- With a roar / woosh the colour sweeps round the room like a wave, timed to the sound: it starts at the
-- fires nearest the new player's seat and runs both ways round, meeting on the far side. The stained glass
-- changes as the wave passes the middle. Without one (a reload) everything changes quietly at once.
local WAVE = { woosh = 0.9, roar = 1.4 }

function Fires.set(color, mode)
  local idx = INDEX[color] or 0
  local shared = shareColors(color)
  GameState.data.fireColor = color
  local st = state()
  local wave = mode and WAVE[mode] or nil
  -- The sound, from its own object.
  if mode then
    local sfx = st.sfx and getObjectFromGUID(st.sfx)
    if sfx then
      whenLoaded(sfx, function(obj)
        pcall(function() obj.AssetBundle.playTriggerEffect(mode == "roar" and 0 or 1) end)
      end)
    end
  end
  -- Where the wave starts: the seat's direction from the middle of the table (none for purple).
  local s = TableSetup.seat(color)
  local ox, oz = s and s.outward.x or nil, s and s.outward.z or nil
  local function delayFor(obj, n)
    if not wave then
      return (n - 1) * 0.05
    end
    if ox == nil then
      return (n - 1) * 0.06
    end
    local p = obj.getPosition()
    local len = math.sqrt(p.x * p.x + p.z * p.z)
    if len < 0.01 then
      return 0
    end
    local dot = (p.x * ox + p.z * oz) / len
    dot = math.max(-1, math.min(1, dot))
    return math.acos(dot) / math.pi * wave
  end
  local glass = st.glass and getObjectFromGUID(st.glass)
  if glass then
    whenLoaded(glass, function(obj)
      Wait.time(function()
        if not obj.isDestroyed() then
          pcall(function() obj.AssetBundle.playLoopingEffect(idx) end)
        end
      end, wave and wave * 0.5 or 0)
    end)
  end
  -- Only the two fireplaces play the burst (sparks, flash), silently: the sound is on its own object.
  local nHearth = 0
  for _, sp in ipairs(hearthSpots()) do
    if not sp.pit then
      nHearth = nHearth + 1
    end
  end
  for n, o in ipairs(fireObjects()) do
    local idx = INDEX[shared[((n - 1) % #shared) + 1]] or idx
    local burst = mode and n <= nHearth
    local delay = delayFor(o, n)
    whenLoaded(o, function(obj)
      Wait.time(function()
        if obj.isDestroyed() then
          return
        end
        -- Colour first, then the burst (switching the colour after would cut the burst short).
        pcall(function() obj.AssetBundle.playLoopingEffect(idx) end)
        if burst then
          pcall(function() obj.AssetBundle.playTriggerEffect((mode == "roar" and ROAR or WOOSH) + idx + SILENT) end)
        end
      end, delay)
    end)
  end
end

-- The colour the game is at right now (after a load, a respawn, a layout change).
function Fires.current()
  local d = GameState.data
  local t = d.turn or {}
  if d.started and t.activeSeat and INDEX[t.activeSeat] then
    return t.activeSeat
  end
  return "Purple"
end

function Fires.refresh()
  Fires.set(Fires.current(), nil)
end

-- Hooks into the game flow.
local function hook()
  if Turns and Turns.beginTurn and not Fires.hookedTurns then
    Fires.hookedTurns = true
    local begin = Turns.beginTurn
    Turns.beginTurn = function(seat, number, newRound)
      begin(seat, number, newRound)
      local t = GameState.data.turn or {}
      pcall(Fires.set, seat, (t.taken or 0) <= 1 and "roar" or "woosh")
    end
  end
  if GameFlow and GameFlow.start and not Fires.hookedStart then
    Fires.hookedStart = true
    local start = GameFlow.start
    GameFlow.start = function(...)
      local r = start(...)
      GameState.data.gameOverFired = nil
      pcall(Fires.set, "Purple", nil)
      return r
    end
  end
end
hook()

Events.on("gameOver", function(d)
  local w = d and d.winner
  pcall(Fires.set, (w and INDEX[w]) and w or "Purple", "roar")
end)

function Fires.chat(message)
  local c, mode = tostring(message):match("^!fire%s+(%a+)%s*(%a*)$")
  if not c then
    return false
  end
  c = c:sub(1, 1):upper() .. c:sub(2):lower()
  if INDEX[c] == nil then
    print("MTG > !fire Purple|White|Red|Green|Blue [roar|woosh]")
    return true
  end
  Fires.set(c, mode ~= "" and mode:lower() or nil)
  return true
end
