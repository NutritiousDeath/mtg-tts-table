--[[
  flip.lua
  The table flip: a short animation on everyone's screen. Type !flip (or
  click "Flip the table!" under TURN OPTIONS) and the table tips over, cards
  and dice fly, and "<player> flipped the table!" is announced. !unflip puts
  it back, gently. Pure screen fun: nothing on the real table is moved.
--]]

Flip = {}

local FRAMES = 44
local STEP = 0.05
local running = false

local CARDS = {
  { id = "flipC1", x = -110, y = 30, vx = -9, vy = 12, spin = 17 },
  { id = "flipC2", x = -40, y = 36, vx = -4, vy = 15, spin = -23 },
  { id = "flipC3", x = 30, y = 36, vx = 5, vy = 16, spin = 29 },
  { id = "flipC4", x = 100, y = 30, vx = 10, vy = 11, spin = -19 },
  { id = "flipC5", x = 0, y = 40, vx = 1, vy = 19, spin = 37 },
}

function Flip.xml()
  local cards = {}
  for _, c in ipairs(CARDS) do
    table.insert(cards, ('<Panel id="%s" width="46" height="64" rectAlignment="MiddleCenter" offsetXY="%d %d" color="#5AF0FF" outline="#E6F1FF" outlineSize="2 2" raycastTarget="false" />')
      :format(c.id, c.x, c.y + 20))
  end
  return [[
<Panel id="flipLayer" active="false" rectAlignment="MiddleCenter" width="1000" height="600" color="#00000000" raycastTarget="false">
  <Panel id="flipTable" width="440" height="140" rectAlignment="MiddleCenter" offsetXY="0 0" color="#00000000" raycastTarget="false">
    <Panel width="440" height="34" rectAlignment="UpperCenter" color="#0B0F17" outline="#5AF0FF" outlineSize="3 3" raycastTarget="false" />
    <Panel width="26" height="104" rectAlignment="LowerLeft" offsetXY="40 0" color="#0B0F17" outline="#5AF0FF" outlineSize="3 3" raycastTarget="false" />
    <Panel width="26" height="104" rectAlignment="LowerRight" offsetXY="-40 0" color="#0B0F17" outline="#5AF0FF" outlineSize="3 3" raycastTarget="false" />
  </Panel>
  ]] .. table.concat(cards) .. [[
  <Text id="flipText" rectAlignment="LowerCenter" offsetXY="0 40" width="900" height="120" fontSize="44" fontStyle="Bold"
        alignment="MiddleCenter" color="#FF5470" raycastTarget="false"></Text>
</Panel>
]]
end

local function setAll(angle, lift, cardT, alpha)
  UI.setAttribute("flipTable", "rotation", "0 0 " .. angle)
  UI.setAttribute("flipTable", "offsetXY", "0 " .. lift)
  for _, c in ipairs(CARDS) do
    local x = c.x + c.vx * cardT * 4
    local y = c.y + 20 + c.vy * cardT * 4 - 0.5 * 2.2 * (cardT * 4) * (cardT * 4) * 0.25
    UI.setAttribute(c.id, "offsetXY", math.floor(x) .. " " .. math.floor(y))
    UI.setAttribute(c.id, "rotation", "0 0 " .. math.floor(c.spin * cardT * 4))
  end
end

-- reverse = false: the flip. true: put it back.
function Flip.play(color, reverse)
  if running then
    return
  end
  running = true
  UI.setAttribute("flipLayer", "active", "true")
  UI.setValue("flipText", "")
  local f = 0
  Wait.time(function()
    f = f + 1
    local p = f / FRAMES                      -- 0 .. 1
    local k = reverse and (1 - p) or p        -- how far flipped
    local lastThird = f > FRAMES * 0.62
    -- Tip over (ease out), lifting a little on the way.
    local e = math.min(1, k / 0.6)
    e = 1 - (1 - e) * (1 - e)
    local angle = -180 * e
    local lift = math.floor(math.sin(math.min(1, k / 0.6) * math.pi) * 70)
    -- A shake when it lands.
    if k > 0.6 and not reverse then
      lift = lift + ((f % 2 == 0) and 6 or -6) * math.max(0, 1 - (k - 0.6) / 0.4)
    end
    setAll(angle, lift, reverse and (1 - p) * 0.9 or math.min(1, p * 1.3), 1)
    if f == math.floor(FRAMES * 0.45) then
      UI.setValue("flipText", reverse and "...there. All better." or (string.upper(tostring(color)) .. " FLIPPED THE TABLE!"))
    end
    if lastThird and f % 8 == 0 and not reverse then
      UI.setAttribute("flipText", "color", (f % 16 == 0) and "#FF5470" or "#FFB347")
    end
    if f >= FRAMES then
      Wait.time(function()
        UI.setAttribute("flipLayer", "active", "false")
        setAll(0, 0, 0, 1)
        UI.setValue("flipText", "")
        running = false
      end, 1.0)
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
