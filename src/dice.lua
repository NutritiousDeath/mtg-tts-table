--[[
  dice.lua
  Dice roller: "Roll Dice" (screen, top left) opens a panel only you see.
  Pick a die (d4 d6 d8 d10 d12 d20) and how many, then ROLL: real dice drop
  into the middle of the table (beside the STACK mat),
  tumble, and when they stop the result is announced to everyone:
      "Red rolled 2d6: 3 + 5 = 8"
  Your dice are tinted your seat color and stay until your next roll (or
  CLEAR), so they never pile up or knock cards around the playmats.
--]]

Dice = {}

local TYPES = { 4, 6, 8, 10, 12, 20 }
local MAX_DICE = 10
local DROP_HEIGHT = 7
local SPREAD = 2.5          -- dice land within this distance of LAND
-- Beside the STACK mat in the middle of the table (stack.lua), not on it.
local LAND = { x = 9, z = 0 }
local INFO = { 0.75, 0.8, 0.9 }
local SEAT_TINT = {
  White = { 0.85, 0.87, 0.92 }, Red = { 0.86, 0.33, 0.33 },
  Green = { 0.32, 0.76, 0.42 }, Blue = { 0.32, 0.58, 0.95 },
}

local choice = {}           -- [color] = { sides = 6, count = 1 }
local rolled = {}           -- [color] = { guids }
local open = {}

local function pick(color)
  choice[color] = choice[color] or { sides = 20, count = 1 }
  return choice[color]
end

function Dice.xml()
  local parts = { [[
<Button id="diceToggle" onClick="ui_diceToggle" rectAlignment="UpperLeft" offsetXY="20 -170"
        width="150" height="40" fontStyle="Bold" color="#2A3346" textColor="#E6F1FF">Roll Dice</Button>
]] }
  for _, c in ipairs(TableSetup.activeSeats()) do
    local dieButtons = {}
    for _, n in ipairs(TYPES) do
      table.insert(dieButtons, ('<Button id="die_%s_%d" onClick="ui_diceType(%s_%d)" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold">d%d</Button>')
        :format(c, n, c, n, n))
    end
    table.insert(parts, ([[
<Panel id="dice_%s" visibility="%s" active="false" rectAlignment="UpperLeft" offsetXY="180 -170" width="330" height="200"
       color="#0B0F17F2" outline="#5AF0FF" outlineSize="2 2">
  <VerticalLayout padding="12 12 12 12" spacing="8" childForceExpandHeight="false">
    <Text fontSize="15" fontStyle="Bold" color="#5AF0FF" preferredHeight="22">ROLL DICE</Text>
    <HorizontalLayout spacing="4" preferredHeight="36">]] .. table.concat(dieButtons) .. [[</HorizontalLayout>
    <HorizontalLayout spacing="6" preferredHeight="36">
      <Button onClick="ui_diceCount(%s_minus)" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold">-</Button>
      <Text id="diceCount_%s" fontSize="18" fontStyle="Bold" color="#E6F1FF">1 die</Text>
      <Button onClick="ui_diceCount(%s_plus)" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold">+</Button>
    </HorizontalLayout>
    <HorizontalLayout spacing="8" preferredHeight="40">
      <Button id="diceRoll_%s" onClick="ui_diceRoll(%s)" color="#00B3A4" textColor="#06130B" fontStyle="Bold">ROLL d20</Button>
      <Button onClick="ui_diceClear(%s)" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold"
              tooltip="Remove your dice from the table">CLEAR</Button>
    </HorizontalLayout>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, c, c, c, c, c))
  end
  return table.concat(parts)
end

local function render(color)
  local p = pick(color)
  for _, n in ipairs(TYPES) do
    UI.setAttribute("die_" .. color .. "_" .. n, "color", n == p.sides and "#00B3A4" or "#1B2333")
    UI.setAttribute("die_" .. color .. "_" .. n, "textColor", n == p.sides and "#06130B" or "#E6F1FF")
  end
  UI.setValue("diceCount_" .. color, p.count .. (p.count == 1 and " die" or " dice"))
  UI.setAttribute("diceRoll_" .. color, "text", "ROLL " .. p.count .. "d" .. p.sides)
end

local function clear(color)
  for _, guid in ipairs(rolled[color] or {}) do
    local obj = getObjectFromGUID(guid)
    if obj then
      obj.destruct()
    end
  end
  rolled[color] = {}
end

function Dice.roll(color, count, sides)
  clear(color)
  local dice = {}
  local tint = SEAT_TINT[color]
  for i = 1, count do
    local a = math.random() * math.pi * 2
    local r = math.random() * SPREAD
    local obj = spawnObject({
      type = "Die_" .. sides,
      position = { LAND.x + math.cos(a) * r, TableSetup.SURFACE_TOP + DROP_HEIGHT + i * 0.6, LAND.z + math.sin(a) * r },
      rotation = { math.random(0, 359), math.random(0, 359), math.random(0, 359) },
      scale = { 1.3, 1.3, 1.3 },
      sound = i == 1,
      callback_function = function(o)
        if tint then
          o.setColorTint(tint)
        end
        o.setName(color .. "'s d" .. sides)
        o.addTag("RolledDie")
        -- A tumble: spin and a little sideways push.
        o.setAngularVelocity({ math.random(-15, 15), math.random(-15, 15), math.random(-15, 15) })
        o.setVelocity({ math.random(-3, 3), -2, math.random(-3, 3) })
      end,
    })
    table.insert(dice, obj)
  end
  rolled[color] = {}
  for _, d in ipairs(dice) do
    table.insert(rolled[color], d.getGUID())
  end
  -- Announce once every die has come to rest.
  Wait.condition(function()
    local values, total = {}, 0
    for _, d in ipairs(dice) do
      if not d.isDestroyed() then
        local v = d.getValue()
        table.insert(values, tostring(v))
        total = total + (tonumber(v) or 0)
      end
    end
    local msg = color .. " rolled " .. count .. "d" .. sides .. ": " .. table.concat(values, " + ")
    if count > 1 then
      msg = msg .. " = " .. total
    end
    broadcastToAll(msg, tint or INFO)
  end, function()
    for _, d in ipairs(dice) do
      if not d.isDestroyed() and not d.resting then
        return false
      end
    end
    return true
  end, 10, function()
    broadcastToAll(color .. "'s dice are still rolling: check them on the table.", INFO)
  end)
end

---------------------------------------------------------------------------
-- XML handlers
---------------------------------------------------------------------------

function ui_diceToggle(player)
  local c = player.color
  if not TableSetup.isActive(c) then
    broadcastToColor("Take a seat first.", c, { 1, 0.6, 0.2 })
    return
  end
  open[c] = not open[c]
  UI.setAttribute("dice_" .. c, "active", open[c] and "true" or "false")
  if open[c] then
    render(c)
  end
end

function ui_diceType(player, arg)
  local c, n = tostring(arg):match("^(%a+)_(%d+)$")
  if c ~= player.color then
    return
  end
  pick(c).sides = tonumber(n)
  render(c)
end

function ui_diceCount(player, arg)
  local c, how = tostring(arg):match("^(%a+)_(%a+)$")
  if c ~= player.color then
    return
  end
  local p = pick(c)
  p.count = math.max(1, math.min(MAX_DICE, p.count + (how == "plus" and 1 or -1)))
  render(c)
end

function ui_diceRoll(player, c)
  if c ~= player.color then
    return
  end
  local p = pick(c)
  Dice.roll(c, p.count, p.sides)
end

function ui_diceClear(player, c)
  if c ~= player.color then
    return
  end
  clear(c)
end
