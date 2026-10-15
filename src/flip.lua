--[[
  flip.lua
  The table flip: a rage quit. Type !flip (or click "Flip the table!" under
  TURN OPTIONS): the real cards and dice on the table are launched into the
  air, the screen flashes red and shakes with a "<PLAYER> RAGE QUIT!" banner,
  and a few seconds later everything glides back to where it was. !unflip puts
  it back, gently (screen only).
--]]

Flip = {}

local FRAMES = 56
local STEP = 0.05
local running = false

-- Debris: cards in the five mana colors plus a few dice, each with its own
-- launch speed and spin.
local CARDS = {}
do
  local COLORS = { "#F8F1D8", "#3FA9F5", "#9B7FD1", "#FF5A4E", "#3DD68C", "#5AF0FF" }
  local spots = {
    { -150, 30, -11, 13, 17 }, { -95, 36, -7, 17, -23 }, { -40, 40, -3, 20, 29 }, { 15, 40, 2, 21, -31 },
    { 70, 36, 6, 18, 37 }, { 125, 30, 10, 14, -19 }, { -120, 34, -13, 9, 41 }, { 160, 32, 13, 10, -43 },
    { -10, 44, -1, 24, 53 }, { 45, 44, 4, 23, -47 },
  }
  for i, sp in ipairs(spots) do
    table.insert(CARDS, { id = "flipC" .. i, x = sp[1], y = sp[2], vx = sp[3], vy = sp[4], spin = sp[5],
      color = COLORS[(i - 1) % #COLORS + 1], die = i > 8 })
  end
end

function Flip.xml()
  local cards = {}
  for _, c in ipairs(CARDS) do
    local w, h = c.die and 30 or 46, c.die and 30 or 64
    table.insert(cards, ('<Panel id="%s" width="%d" height="%d" rectAlignment="MiddleCenter" offsetXY="%d %d" color="%s" outline="#0B0F17" outlineSize="3 3" raycastTarget="false" />')
      :format(c.id, w, h, c.x, c.y + 20, c.color))
  end
  return [[
<Panel id="flipLayer" active="false" rectAlignment="MiddleCenter" width="1000" height="600" color="#00000000" raycastTarget="false">
  <Panel id="flipFlash" width="3000" height="2000" rectAlignment="MiddleCenter" color="#FF203000" raycastTarget="false" />
  <Panel id="flipTable" width="520" height="160" rectAlignment="MiddleCenter" offsetXY="0 0" color="#00000000" raycastTarget="false">
    <Panel width="520" height="40" rectAlignment="UpperCenter" color="#0B0F17" outline="#5AF0FF" outlineSize="4 4" raycastTarget="false" />
    <Panel width="30" height="120" rectAlignment="LowerLeft" offsetXY="46 0" color="#0B0F17" outline="#5AF0FF" outlineSize="3 3" raycastTarget="false" />
    <Panel width="30" height="120" rectAlignment="LowerRight" offsetXY="-46 0" color="#0B0F17" outline="#5AF0FF" outlineSize="3 3" raycastTarget="false" />
  </Panel>
  ]] .. table.concat(cards) .. [[
  <Text id="flipText" rectAlignment="LowerCenter" offsetXY="0 10" width="1000" height="140" fontSize="60" fontStyle="Bold"
        alignment="MiddleCenter" color="#FF5470" outline="#000000" outlineSize="3 3" raycastTarget="false"></Text>
  <Text id="flipSub" rectAlignment="LowerCenter" offsetXY="0 -50" width="1000" height="60" fontSize="26" fontStyle="Bold"
        alignment="MiddleCenter" color="#FFD0D8" outline="#000000" outlineSize="2 2" raycastTarget="false"></Text>
</Panel>
]]
end

local function setAll(angle, lift, cardT)
  UI.setAttribute("flipTable", "rotation", "0 0 " .. angle)
  UI.setAttribute("flipTable", "offsetXY", "0 " .. lift)
  for _, c in ipairs(CARDS) do
    local t = cardT * 4
    local x = c.x + c.vx * t * 1.4
    local y = c.y + 20 + c.vy * t * 1.6 - 0.5 * 2.2 * t * t * 0.3
    UI.setAttribute(c.id, "offsetXY", math.floor(x) .. " " .. math.floor(y))
    UI.setAttribute(c.id, "rotation", "0 0 " .. math.floor(c.spin * t * 2))
  end
end

local INSULTS = { "GG, I guess.", "This deck is rigged.", "I was going to win next turn.", "Nobody saw that.",
  "I'm not mad. I'm just leaving.", "Shuffle better next time." }

-- reverse = false: the flip. true: put it back.
function Flip.play(color, reverse)
  if running then
    return
  end
  running = true
  UI.setAttribute("flipLayer", "active", "true")
  UI.setAttribute("flipLayer", "offsetXY", "0 0")
  UI.setValue("flipText", "")
  UI.setValue("flipSub", "")
  local f = 0
  Wait.time(function()
    f = f + 1
    local p = f / FRAMES                      -- 0 .. 1
    local k = reverse and (1 - p) or p        -- how far flipped
    -- Tip over (ease out), lifting on the way.
    local e = math.min(1, k / 0.5)
    e = 1 - (1 - e) * (1 - e)
    local angle = -180 * e
    local lift = math.floor(math.sin(math.min(1, k / 0.5) * math.pi) * 110)
    setAll(angle, lift, reverse and (1 - p) * 0.9 or math.min(1, p * 1.25))
    if not reverse then
      -- The landing: a red flash and the whole screen shakes, fading out.
      if k > 0.5 then
        local fade = math.max(0, 1 - (k - 0.5) / 0.5)
        local a = math.floor(fade * 110)
        UI.setAttribute("flipFlash", "color", string.format("#FF2030%02X", a))
        local amp = math.floor(18 * fade)
        local sx = (f % 2 == 0) and amp or -amp
        local sy = (f % 3 == 0) and amp or -math.floor(amp / 2)
        UI.setAttribute("flipLayer", "offsetXY", sx .. " " .. sy)
      end
      if f == math.floor(FRAMES * 0.4) then
        UI.setValue("flipText", string.upper(tostring(color)) .. " RAGE QUIT!")
      end
      if f == math.floor(FRAMES * 0.62) then
        UI.setValue("flipSub", "\"" .. INSULTS[math.random(#INSULTS)] .. "\"")
      end
      if f > FRAMES * 0.5 and f % 6 == 0 then
        UI.setAttribute("flipText", "color", (f % 12 == 0) and "#FF5470" or "#FFB347")
      end
    elseif f == math.floor(FRAMES * 0.45) then
      UI.setValue("flipText", "...there. All better.")
    end
    if f >= FRAMES then
      Wait.time(function()
        UI.setAttribute("flipLayer", "active", "false")
        UI.setAttribute("flipLayer", "offsetXY", "0 0")
        UI.setAttribute("flipFlash", "color", "#FF203000")
        setAll(0, 0, 0)
        UI.setValue("flipText", "")
        UI.setValue("flipSub", "")
        running = false
      end, reverse and 1.0 or 2.2)
    end
  end, STEP, FRAMES)
end

-- The real chaos, like Tabletop Simulator's own "Flip Table" (which only works on TTS's built-in
-- tables; ours is a custom surface, so this does it by script):
--   * the play surface and stone frame tip up off the flipper's edge, pivoting on the far edge;
--   * every loose card, token, die, counter and pile on the table is launched, spinning;
--   * the mat pictures and outlines vanish while the table is up;
--   * a few seconds later the table drops back and EVERYTHING glides back to exactly where it was.
-- Kept safe: cards in hands, libraries and face-down cards stay put (nothing hidden gets revealed),
-- and locked pieces (life tiles, trackers) don't move. While it runs, nothing can merge into a deck,
-- fall into a hand, or count as a move (zones.lua checks Flip.chaosOn).
Flip.chaosOn = false

local TIP_MAX = 115        -- degrees the table tips up
local TIP_UP = 0.8         -- seconds to tip up
local HOLD = 1.6           -- seconds it stays up
local TIP_DOWN = 0.9       -- seconds to drop back
local TICK = 0.03

-- Rotate vector v about unit axis a by angle t (radians).
local function rodrigues(v, a, t)
  local c, sn = math.cos(t), math.sin(t)
  local cx = a.y * v.z - a.z * v.y
  local cy = a.z * v.x - a.x * v.z
  local cz = a.x * v.y - a.y * v.x
  local dot = a.x * v.x + a.y * v.y + a.z * v.z
  return {
    x = v.x * c + cx * sn + a.x * dot * (1 - c),
    y = v.y * c + cy * sn + a.y * dot * (1 - c),
    z = v.z * c + cz * sn + a.z * dot * (1 - c),
  }
end

-- The table pieces that tip: surface and frame, with where they rest.
local function tablePieces()
  local out = {}
  local st = GameState.data and GameState.data.table or {}
  for _, g in ipairs({ st.surface, st.frame }) do
    local o = g and getObjectFromGUID(g)
    if o and not o.isDestroyed() then
      table.insert(out, { obj = o, pos = o.getPosition(), rot = o.getRotation() })
    end
  end
  return out
end

-- Tip setup for the flipper's seat: the pivot on the far edge and the axis to turn about (snapped
-- to the table's own x or z axis so the frame's Euler angles stay simple).
local function tipFor(color)
  local s = color and TableSetup.isActive(color) and TableSetup.seat(color)
  local n = s and s.inward or { x = 0, z = 1 }
  local w, d = TableSetup.surfaceSize()
  local axis, euler, half
  if math.abs(n.x) > math.abs(n.z) then
    local sx = n.x > 0 and 1 or -1
    n = { x = sx, z = 0 }
    half = w / 2
  else
    local sz = n.z > 0 and 1 or -1
    n = { x = 0, z = sz }
    half = d / 2
  end
  -- axis = up x n: turning by +angle lifts the flipper's (near) edge.
  axis = { x = n.z, y = 0, z = -n.x }
  if axis.x ~= 0 then
    euler = function(deg) return { axis.x * deg, 0, 0 } end
  else
    euler = function(deg) return { 0, 0, axis.z * deg } end
  end
  local pivot = { x = n.x * half, y = TableSetup.SURFACE_TOP, z = n.z * half }
  return pivot, axis, euler
end

local function placeTable(pieces, pivot, axis, euler, deg)
  local t = math.rad(deg)
  for _, e in ipairs(pieces) do
    local o = e.obj
    if not o.isDestroyed() then
      local v = { x = e.pos.x - pivot.x, y = e.pos.y - pivot.y, z = e.pos.z - pivot.z }
      local r = rodrigues(v, axis, t)
      o.setPosition({ pivot.x + r.x, pivot.y + r.y, pivot.z + r.z })
      local eu = euler(deg)
      o.setRotation({ e.rot.x + eu[1], e.rot.y, e.rot.z + eu[3] })
    end
  end
end

-- Animate the tip from one angle to another over `secs`, then call done.
local function tween(pieces, pivot, axis, euler, from, to, secs, done)
  local n = math.max(1, math.floor(secs / TICK))
  local i = 0
  Wait.time(function()
    i = i + 1
    local p = i / n
    local e = (to > from) and (1 - (1 - p) * (1 - p)) or (p * p)   -- ease out going up, ease in coming down
    placeTable(pieces, pivot, axis, euler, from + (to - from) * e)
    if i >= n and done then
      done()
    end
  end, TICK, n)
end

-- Only real game pieces fly: never zones, hand zones, the table, or scripted helpers.
local FLIES = { Card = true, Deck = true, Dice = true, Tile = true, Token = true, Chip = true, Figurine = true,
  Generic = true, Coin = true }

local runChaos   -- defined below

function Flip.chaos(color)
  if Flip.chaosOn then
    return
  end
  local ok, err = pcall(runChaos, color)
  if not ok then
    Flip.chaosOn = false
    print("MTG > Table flip hit a snag: " .. tostring(err))
  end
  -- Never leave the table stuck in flip mode.
  Wait.time(function() Flip.chaosOn = false end, 15)
end

runChaos = function(color)
  local inHand = {}
  for _, c in ipairs(TableSetup.activeSeats()) do
    for _, o in ipairs(Player[c].getHandObjects() or {}) do
      inHand[o.getGUID()] = true
    end
  end
  local pieces = tablePieces()
  local skip = {}
  for _, e in ipairs(pieces) do
    skip[e.obj.getGUID()] = true
  end
  local list = {}
  for _, o in ipairs(getObjects()) do
    local ok, take = pcall(function()
      if not FLIES[o.type] or skip[o.getGUID()] or o.getLock() or o.held_by_color ~= nil
          or inHand[o.getGUID()] or o.interactable == false then
        return false
      end
      if o.type == "Card" and o.is_face_down then
        return false   -- face-down cards stay hidden
      end
      if o.type == "Deck" then
        local r = Zones and Zones.regionAt(o.getPosition()).region
        if r == "library" or o.is_face_down then
          return false   -- libraries keep their order and stay hidden
        end
      end
      return true
    end)
    if ok and take then
      table.insert(list, { obj = o, pos = o.getPosition(), rot = o.getRotation() })
    end
  end
  Flip.chaosOn = true
  -- Mat pictures and outlines would float in the air while the table is up.
  local decals, lines
  pcall(function() decals = Global.getDecals() end)
  pcall(function() lines = Global.getVectorLines() end)
  pcall(function() Global.setDecals({}) end)
  pcall(function() Global.setVectorLines({}) end)

  local pivot, axis, euler = tipFor(color)
  -- Launch: up and away from the flipper, like the table went over under them.
  local push = { x = -axis.z, z = axis.x }   -- = n, toward the far edge
  for _, e in ipairs(list) do
    local p = e.pos
    pcall(function()
      e.obj.setVelocity({ p.x * 0.25 + push.x * 10 + math.random(-8, 8), math.random(22, 38),
        p.z * 0.25 + push.z * 10 + math.random(-8, 8) })
      e.obj.setAngularVelocity({ math.random(-25, 25), math.random(-25, 25), math.random(-25, 25) })
    end)
  end
  tween(pieces, pivot, axis, euler, 0, TIP_MAX, TIP_UP, function()
    Wait.time(function()
      tween(pieces, pivot, axis, euler, TIP_MAX, 0, TIP_DOWN, function()
        -- Exactly back where it was.
        for _, e in ipairs(pieces) do
          if not e.obj.isDestroyed() then
            e.obj.setPosition(e.pos)
            e.obj.setRotation(e.rot)
            e.obj.setLock(true)
          end
        end
        -- Everything glides home, locked on the way so nothing bumps anything.
        for _, e in ipairs(list) do
          local o = e.obj
          if not o.isDestroyed() then
            o.setVelocity({ 0, 0, 0 })
            o.setAngularVelocity({ 0, 0, 0 })
            o.setLock(true)
            o.setPositionSmooth({ e.pos.x, e.pos.y + 0.05, e.pos.z }, false, false)
            o.setRotationSmooth(e.rot, false, false)
          end
        end
        pcall(function() if decals then Global.setDecals(decals) end end)
        pcall(function() if lines then Global.setVectorLines(lines) end end)
        Wait.time(function()
          for _, e in ipairs(list) do
            local o = e.obj
            if not o.isDestroyed() then
              o.setPosition(e.pos)
              o.setRotation(e.rot)
              o.setLock(false)
            end
          end
          Wait.time(function()
            Flip.chaosOn = false
          end, 0.5)
        end, 2.2)
      end)
    end, HOLD)
  end)
end

function Flip.flip(color)
  broadcastToAll((color or "Someone") .. " flipped the table!", { 1, 0.33, 0.45 })
  Flip.play(color or "Someone", false)
  -- Launch everything as the table "tips" in the animation.
  Wait.time(function() Flip.chaos(color) end, 0.6)
end

function Flip.unflip(color)
  broadcastToAll((color or "Someone") .. " put the table back. Calm down.", { 0.55, 0.9, 0.6 })
  Flip.play(color or "Someone", true)
end

function ui_flipTable(player)
  Flip.flip(player.color)
end

function Flip.chat(message, color)
  local m = tostring(message):lower()
  if m == "!flip" or m == "!tableflip" or m == "!flip table" then
    Flip.flip(color)
    return true
  elseif m == "!unflip" or m == "!tableunflip" then
    Flip.unflip(color)
    return true
  end
  return false
end
