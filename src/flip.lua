--[[
  flip.lua
  The table flip: a rage quit. Type !flip, or click
  "Flip the table!" under TURN OPTIONS: the stone table and everything on it is launched into the
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
        UI.setValue("flipText", color and (string.upper(tostring(color)) .. " RAGE QUIT!") or "TABLE FLIP!")
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

-- The real chaos, like Tabletop Simulator's own "Flip Table" (TTS's button only works on its built-in
-- tables; ours is a custom surface, so this does it by script):
--   * every card, token, die, counter, tile and pile on the table is launched, spinning;
--   * a moment later the stone table itself (surface and frame) rears up and tumbles;
--   * the mat pictures vanish while it's all in the air;
--   * it all crashes down onto the cathedral floor (table.lua) and lies there a few seconds;
--   * then the table glides back, then EVERYTHING glides back to exactly where it was.
-- Kept safe: cards in hands, libraries and face-down cards stay put (nothing hidden gets revealed).
-- While it runs, nothing can merge into a deck, fall into a hand, or count as a move (zones.lua checks
-- Flip.chaosOn).
Flip.chaosOn = false

-- The table pieces that fly: surface and frame, with where they rest.
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

-- Only real game pieces fly: never zones, hand zones, the table, or scripted helpers.
local FLIES = { Card = true, Deck = true, Dice = true, Tile = true, Token = true, Chip = true, Figurine = true,
  Generic = true, Coin = true, Block = true }

local runChaos   -- defined below

-- Seconds everything lies scattered on the cathedral floor before it all glides home.
local LAND = 10   -- seconds everything stays thrown before it glides home

-- A parting shot painted on the underside of the table, a different one each flip: you see it as the
-- table rears up and tumbles.
local FAREWELLS = {
  "BYE 2 U 2", "SEE YA", "SMELL YA LATER", "GG NO RE", "PEACE OUT", "LATER, NERDS", "HASTA LA VISTA",
  "TABLE HAS LEFT THE CHAT", "IT'S NOT ME, IT'S YOU", "NO TAKE-BACKS", "SKILL ISSUE", "GO TOUCH GRASS",
  "CTRL + Z?", "WELP.", "YEET", "BOARD WIPE!", "MULLIGAN TO ZERO", "RAGE QUIT SPEEDRUN", "THANKS FOR PLAYING",
  "SHUFFLE THAT", "BYE FELICIA", "TOODLES", "ADIOS, AMIGOS", "I DIDN'T LIKE THAT GAME ANYWAY",
}
local lastFarewell

-- Paint a farewell on the bottom of the play surface. Returns how to remove it.
local function paintFarewell(surf)
  local n = #FAREWELLS
  local i = math.random(n)
  if FAREWELLS[i] == lastFarewell and n > 1 then
    i = i % n + 1
  end
  lastFarewell = FAREWELLS[i]
  local before = #(surf.getButtons() or {})
  local sc = surf.getScale()
  -- Buttons are drawn in the block's own units (scaled by its size): undo that, then make the text huge.
  local k = 4
  local okb = pcall(function()
    surf.createButton({
      click_function = "flip_noop", function_owner = Global, label = lastFarewell,
      position = { 0, -0.52, 0 }, rotation = { 180, 0, 0 },
      scale = { k / sc.x, 1, k / sc.z }, width = 0, height = 0,
      font_size = math.floor(math.min(900, 12000 / #lastFarewell)),
      font_color = { 1, 0.33, 0.45, 100 }, color = { 0, 0, 0, 0 },
    })
  end)
  return function()
    if okb and surf and not surf.isDestroyed() then
      pcall(function() surf.removeButton(before) end)
    end
  end
end

function flip_noop() end

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
  Wait.time(function() Flip.chaosOn = false end, 20)
  Wait.time(function() pcall(Flip.fixTable); pcall(function() Zones.drawIcons() end) end, 16)
end

-- Does o go flying in a flip (and so get put back after one)? inHand / skip: GUID sets to leave alone.
function Flip.flies(o, inHand, skip)
  if not FLIES[o.type] or (skip and skip[o.getGUID()]) or o.held_by_color ~= nil or (inHand and inHand[o.getGUID()])
      or o.hasTag("TableFloor") or o.hasTag("TableHearth") or o.hasTag("HearthFire") or o.hasTag("FireCrackle") or o.hasTag("FireSfx") or o.hasTag("StackFire") or o.hasTag("DiceTower") or o.hasTag("RulesBook") or o.hasTag("TableRoom") or o.hasTag("TableRoof") or o.hasTag("TableGlass") then
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
end

local function plain(v)
  return { x = v.x or v[1] or 0, y = v.y or v[2] or 0, z = v.z or v[3] or 0 }
end

local function flipLog(msg)
  if GameLog and GameLog.add then
    pcall(GameLog.add, "FLIP", msg)
  end
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
    local ok, take = pcall(Flip.flies, o, inHand, skip)
    if ok and take then
      table.insert(list, { obj = o, pos = o.getPosition(), rot = o.getRotation(), locked = o.getLock() })
    end
  end
  Flip.chaosOn = true
  -- Remember where everything lives, in the save too: a save or a Save and Play while it's all in the
  -- air would otherwise keep the table and the pieces wherever they landed (Flip.recover puts them back).
  local home = { pieces = {}, table = {}, at = os.time() }
  for _, e in ipairs(list) do
    table.insert(home.pieces, { g = e.obj.getGUID(), p = plain(e.pos), r = plain(e.rot), l = e.locked == true })
  end
  for _, e in ipairs(pieces) do
    table.insert(home.table, { g = e.obj.getGUID(), p = plain(e.pos), r = plain(e.rot) })
  end
  if GameState.data then
    GameState.data.flipHome = home
  end
  flipLog((color or "someone") .. " flipped the table: " .. #list .. " pieces recorded")
  local unpaint
  for _, e in ipairs(pieces) do
    if e.obj.hasTag("PlaySurface") then
      unpaint = paintFarewell(e.obj)
    end
  end
  print("MTG > Table flip: " .. #list .. " piece" .. (#list == 1 and "" or "s") .. " go flying.")
  -- Everything is launched up and away from the flipper, spinning: the pieces first, and a moment
  -- later the stone table itself rears up and tumbles. The mat pictures vanish while it's up.
  local s = color and TableSetup.isActive(color) and TableSetup.seat(color)
  local push = s and s.inward or { x = 0, z = 0 }
  for _, e in ipairs(list) do
    local p = e.pos
    pcall(function()
      e.obj.setLock(false)
      e.obj.setVelocity({ p.x * 0.25 + push.x * 12 + math.random(-8, 8), math.random(25, 40),
        p.z * 0.25 + push.z * 12 + math.random(-8, 8) })
      e.obj.setAngularVelocity({ math.random(-25, 25), math.random(-25, 25), math.random(-25, 25) })
    end)
  end
  pcall(function() Global.setDecals({}) end)
  Wait.time(function()
    for i, e in ipairs(pieces) do
      pcall(function()
        e.obj.setLock(false)
        e.obj.setVelocity({ push.x * 10, 18 + i * 3, push.z * 10 })
        local spin = (push.x ~= 0 or push.z ~= 0) and { push.z * 4, 0, -push.x * 4 } or { 3, 1, -2 }
        e.obj.setAngularVelocity(spin)
      end)
    end
  end, 0.15)
  -- A few seconds later: everything glides home, locked on the way so nothing bumps anything.
  Wait.time(function()
    -- The table glides home first.
    for _, e in ipairs(pieces) do
      pcall(function()
        local o = e.obj
        o.setVelocity({ 0, 0, 0 })
        o.setAngularVelocity({ 0, 0, 0 })
        o.setLock(true)
        o.setPositionSmooth(e.pos, false, false)
        o.setRotationSmooth(e.rot, false, false)
      end)
    end
  end, LAND - 0.5)
  Wait.time(function()
    for _, e in ipairs(list) do
      pcall(function()
        local o = e.obj
        if not o.isDestroyed() then
          o.setVelocity({ 0, 0, 0 })
          o.setAngularVelocity({ 0, 0, 0 })
          o.setLock(true)
          o.setPositionSmooth({ e.pos.x, e.pos.y + 0.05, e.pos.z }, false, false)
          o.setRotationSmooth(e.rot, false, false)
        end
      end)
    end
    Wait.time(function()
      if unpaint then
        unpaint()
      end
      pcall(Flip.fixTable)
      pcall(function() Zones.drawIcons() end)
      for _, e in ipairs(list) do
        pcall(function()
          local o = e.obj
          if not o.isDestroyed() then
            o.setPosition(e.pos)
            o.setRotation(e.rot)
            o.setLock(e.locked == true)
          end
        end)
      end
      if GameState.data then
        GameState.data.flipHome = nil
      end
      flipLog("flip finished: " .. #list .. " pieces put back")
      Wait.time(function()
        Flip.chaosOn = false
      end, 0.5)
    end, 2.2)
  end, LAND)
end

-- Put the play surface and the stone frame back exactly in place (an older flip could leave them moved
-- or dropped). Runs on load and before every flip.
function Flip.fixTable()
  local st = GameState.data and GameState.data.table or {}
  local surf = st.surface and getObjectFromGUID(st.surface)
  if surf and not surf.isDestroyed() then
    surf.setLock(true)
    surf.setRotation({ 0, 0, 0 })
    local b = surf.getBounds()
    local top = b.center.y + b.size.y / 2
    local p = surf.getPosition()
    surf.setPosition({ 0, p.y + (TableSetup.SURFACE_TOP - top), 0 })
  end
  local frame = st.frame and getObjectFromGUID(st.frame)
  if frame and not frame.isDestroyed() then
    frame.setLock(true)
    frame.setRotation({ 0, 0, 0 })
    frame.setPosition({ 0, 0, 0 })
  end
end

-- A flip that never finished (saved, or Save and Play, while the pieces were in the air): put every
-- piece back where it was before the flip. Returns how many went back.
function Flip.recover()
  local home = GameState.data and GameState.data.flipHome
  if home == nil then
    return 0
  end
  local n = 0
  for _, e in ipairs(home.table or {}) do
    local o = getObjectFromGUID(e.g)
    if o and not o.isDestroyed() then
      pcall(function()
        o.setVelocity({ 0, 0, 0 })
        o.setAngularVelocity({ 0, 0, 0 })
        o.setLock(true)
        o.setPosition(e.p)
        o.setRotation(e.r)
      end)
    end
  end
  pcall(Flip.fixTable)
  for _, e in ipairs(home.pieces or {}) do
    local o = getObjectFromGUID(e.g)
    if o and not o.isDestroyed() then
      pcall(function()
        o.setVelocity({ 0, 0, 0 })
        o.setAngularVelocity({ 0, 0, 0 })
        o.setPosition(e.p)
        o.setRotation(e.r)
        o.setLock(e.l == true)
      end)
      n = n + 1
    end
  end
  GameState.data.flipHome = nil
  flipLog("unfinished flip found on load: " .. n .. " pieces put back")
  -- A farewell painted under the surface by the unfinished flip goes too.
  local st = GameState.data.table or {}
  local surf = st.surface and getObjectFromGUID(st.surface)
  if surf and not surf.isDestroyed() then
    pcall(function()
      local bs = surf.getButtons() or {}
      for i = #bs, 1, -1 do
        if bs[i].click_function == "flip_noop" then
          surf.removeButton(bs[i].index)
        end
      end
    end)
  end
  pcall(function() Zones.drawIcons() end)
  return n
end

-- Is the surface or the stone frame out of place (moved, tipped, unlocked)?
local function tableDrift()
  local st = GameState.data and GameState.data.table or {}
  for _, g in ipairs({ st.surface, st.frame }) do
    local o = g and getObjectFromGUID(g)
    if o and not o.isDestroyed() then
      local p, r = o.getPosition(), o.getRotation()
      local function tilt(a)
        a = (a or 0) % 360
        return math.min(a, 360 - a)
      end
      if math.abs(p.x) > 0.05 or math.abs(p.z) > 0.05 or tilt(r.x) > 0.5 or tilt(r.y) > 0.5 or tilt(r.z) > 0.5
          or not o.getLock() then
        return true
      end
      if g == st.frame and math.abs(p.y) > 0.05 then
        return true
      end
      if g == st.surface then
        local b = o.getBounds()
        if math.abs((b.center.y + b.size.y / 2) - TableSetup.SURFACE_TOP) > 0.05 then
          return true
        end
      end
    end
  end
  return false
end

-- Where the pieces were the last time the table stood still (every 15 s). If the table is found knocked
-- out of place with no flip of ours running (TTS's own "Flip Table", a physics accident), the pieces that
-- moved go back from here, not just the table.
local snap = nil
local NOT_PHYSICAL = { Scripting = true, Hand = true, Fog = true, Layout = true, Randomize = true, Snap = true, Trigger = true }
function Flip.snapshot()
  if Flip.chaosOn or (Flip.knocked and Flip.knocked()) then
    return
  end
  local list = {}
  local inHand = {}
  for _, c in ipairs(TableSetup.activeSeats()) do
    pcall(function()
      for _, h in ipairs(Player[c].getHandObjects() or {}) do
        inHand[h.getGUID()] = true
      end
    end)
  end
  for _, o in ipairs(getObjects()) do
    -- Everything physical, the room and its building pieces included (TTS's own Flip Table throws those
    -- too, locked or not); not zones, not cards in hands or being held.
    local ok, take = pcall(function()
      return not (NOT_PHYSICAL[o.type] or o.held_by_color ~= nil or inHand[o.getGUID()])
    end)
    if ok and take then
      local okv, resting = pcall(function()
        local v = o.getVelocity()
        return math.abs(v.x) + math.abs(v.y) + math.abs(v.z) < 0.5
      end)
      if okv and resting then
        list[o.getGUID()] = { p = plain(o.getPosition()), r = plain(o.getRotation()), l = o.getLock() }
      end
    end
  end
  snap = { at = os.time(), pieces = list }
end

local function restoreSnapshot()
  if snap == nil then
    return 0
  end
  local moved = {}
  for g, e in pairs(snap.pieces) do
    local o = getObjectFromGUID(g)
    if o and not o.isDestroyed() and o.held_by_color == nil then
      local p = o.getPosition()
      local d = math.abs(p.x - e.p.x) + math.abs(p.y - e.p.y) + math.abs(p.z - e.p.z)
      if d > 3 then
        table.insert(moved, { o = o, e = e })
      end
    end
  end
  -- One or two moved pieces are players' own moves; a flip throws everything.
  if #moved < 5 then
    return 0
  end
  for _, m in ipairs(moved) do
    pcall(function()
      m.o.setVelocity({ 0, 0, 0 })
      m.o.setAngularVelocity({ 0, 0, 0 })
      m.o.setPosition(m.e.p)
      m.o.setRotation(m.e.r)
      m.o.setLock(m.e.l == true)
    end)
  end
  flipLog("table found knocked over: " .. #moved .. " pieces put back from " .. (os.time() - snap.at) .. " s ago")
  return #moved
end

-- Everything back to normal: an unfinished flip undone, the table and frame in place, the hand zones on
-- the table edges. look = true also points seated players' cameras back at their seats.
local lastReset, lastResetAt
local driftSince = nil
local DOWN_FOR = 10
-- Really knocked over (TTS's own Flip Table, a physics accident): the surface or the stone frame well out of
-- place or tipped. Small differences (a measuring wobble) don't count, so nothing is moved while people play.
local function knocked()
  local st = GameState.data and GameState.data.table or {}
  for _, g in ipairs({ st.surface, st.frame }) do
    local o = g and getObjectFromGUID(g)
    if o and not o.isDestroyed() then
      local p, r = o.getPosition(), o.getRotation()
      local function tilt(a)
        a = (a or 0) % 360
        return math.min(a, 360 - a)
      end
      if math.abs(p.x) > 1 or math.abs(p.z) > 1 or tilt(r.x) > 10 or tilt(r.z) > 10 then
        return true
      end
      if g == st.frame and math.abs(p.y) > 1 then
        return true
      end
    end
  end
  return false
end

Flip.knocked = knocked
local lastRebuild = 0

-- now = true (load, !fixtable): square everything up straight away, hand zones included.
-- now = false (the watchdog): act only on a table that is really knocked over, after it has been down
-- DOWN_FOR seconds, and at most once a minute; it never touches the hand zones (moving one while cards are
-- being dealt into it drops them on the floor).
function Flip.reset(look, quiet, now)
  if Flip.chaosOn then
    return false
  end
  local back = Flip.recover()
  local fullFix = now or back > 0
  local isDown = knocked()
  if not fullFix then
    if not isDown then
      driftSince = nil
      return false
    end
    driftSince = driftSince or os.time()
    if os.time() - driftSince < DOWN_FOR or os.time() - lastRebuild < 60 then
      return false
    end
  end
  driftSince = nil
  local drift = tableDrift()
  if drift then
    pcall(Flip.fixTable)
  end
  if isDown and back == 0 then
    -- Thrown pieces back from the last snapshot, then the room rebuilt like a layout switch.
    local okr, n = pcall(restoreSnapshot)
    if okr and n and n > 0 then
      back = n
    end
    lastRebuild = os.time()
    Wait.time(function() pcall(Flip.rebuildRoom) end, 0.3)
    flipLog("table found knocked over: room rebuilt")
  end
  local hands = {}
  if fullFix then
    pcall(function() hands = TableSetup.handsOff() end)
    if #hands > 0 then
      pcall(TableSetup.fixHands, hands)
    end
  end
  if look then
    pcall(TableSetup.lookAtAll, 0.5)
  end
  local did = back > 0 or drift or #hands > 0
  if did and not quiet then
    local bits = {}
    if back > 0 then
      table.insert(bits, back .. " piece" .. (back == 1 and "" or "s") .. " put back")
    end
    if drift then
      table.insert(bits, "the table put back in place")
    end
    if #hands > 0 then
      table.insert(bits, "hand zones fixed (" .. table.concat(hands, ", ") .. ")")
    end
    local msg = "MTG > Table reset: " .. table.concat(bits, "; ") .. "."
    if msg ~= lastReset or os.time() - (lastResetAt or 0) > 300 then
      print(msg)
      lastReset, lastResetAt = msg, os.time()
    end
  end
  return did
end

-- On load (and Save and Play): undo any unfinished flip, square the table up, then point everyone at
-- their seat once it's all back (main.lua points them again at 8 s for slow loaders).
Wait.time(function() pcall(Flip.reset, false, false, true) end, 2.5)
Wait.time(function() pcall(Flip.fixTable) end, 3)
Wait.time(function() pcall(TableSetup.lookAtAll, 0.1) end, 4)
Wait.time(function() pcall(TableSetup.lookAtAll, 0.1) end, 15)

-- The watchdog: every 5 seconds, if no flip is running, check the table, the frame and the hand
-- zones, and put back whatever is off. Quiet unless it had to fix something.
local beat = 0
local function watchdog()
  beat = beat + 1
  pcall(function()
    if not Flip.chaosOn then
      Flip.reset(false, false)
      if beat % 3 == 0 then
        Flip.snapshot()
      end
    end
  end)
  Wait.time(watchdog, 5)
end
Wait.time(watchdog, 6)

function Flip.flip(color)
  pcall(Flip.fixTable)
  broadcastToAll((color or "Someone") .. " flipped the table!", { 1, 0.33, 0.45 })
  Flip.play(color or "Someone", false)
  -- Launch everything as the table "tips" in the animation.
  Wait.time(function() Flip.chaos(color) end, 0.6)
end

function Flip.unflip(color)
  broadcastToAll((color or "Someone") .. " put the table back. Calm down.", { 0.55, 0.9, 0.6 })
  Flip.play(color or "Someone", true)
end

-- !fixtable: put the table and every table tile (trackers, action tiles, console strips, turn strips,
-- mana tiles, the stack mat, importers) back where they belong, e.g. after something got knocked off.
-- Put the whole room back the way a layout switch does: the table, frame, floor, walls, roof, glass,
-- torches, fireplaces, rulebook, the planechase chest, hand zones, mats, and every table tile.
function Flip.rebuildRoom()
  pcall(Flip.fixTable)
  pcall(TableSetup.ensure)
  pcall(function() TableSetup.setLayout(TableSetup.layout()) end)
  for _, f in ipairs({ "Trackers.ensureTableDisplay", "Actions.ensure", "Turns.ensureStrips", "ManaChips.ensure",
    "Stack.ensure", "ImportCards.ensure", "Planechase.placeChest", "TableSetup.placeTorches", "Fires.place" }) do
    local mod, fn = f:match("^(%w+)%.(%w+)$")
    pcall(function() _G[mod][fn]() end)
  end
  pcall(function() TableSetup.fixHands() end)
end

function Flip.repair(color)
  pcall(Flip.reset, false, false, true)
  Flip.rebuildRoom()
  if color and TableSetup.isActive(color) then
    Wait.time(function() pcall(TableSetup.lookAtSeat, color) end, 1)
  end
  print("MTG > Table tiles put back in place.")
end

function ui_flipTable(player)
  Flip.flip(player.color)
end

function Flip.chat(message, color)
  local m = tostring(message):lower()
  if m == "!flip" or m == "!tableflip" or m == "!flip table" then
    Flip.flip(color)
    return true
  elseif m == "!tableinfo" then
    print("MTG > " .. TableSetup.tableInfo())
    return true
  elseif m == "!fixtable" or m == "!resettable" then
    Flip.repair(color)
    return true
  elseif m == "!unflip" or m == "!tableunflip" then
    Flip.unflip(color)
    return true
  end
  return false
end
