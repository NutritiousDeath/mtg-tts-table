--[[
  flip.lua
  The table flip: a rage-quit animation on everyone's screen. Type !flip (or
  click "Flip the table!" under TURN OPTIONS) and the table launches over,
  cards and dice fly, the screen flashes red and shakes, and "<PLAYER> RAGE
  QUIT!" is announced. !unflip puts
  it back, gently. Pure screen fun: nothing on the real table is moved.
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

function Flip.flip(color)
  broadcastToAll((color or "Someone") .. " flipped the table!", { 1, 0.33, 0.45 })
  Flip.play(color or "Someone", false)
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
