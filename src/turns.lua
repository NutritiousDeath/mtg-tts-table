--[[
  turns.lua
  The turn engine (Phase 4): steps in order, automatic untap and draw,
  clockwise turn order and a turn bar everyone can see.

  Steps: Untap, Upkeep, Draw, Main 1, Beginning of combat, Declare attackers,
  Declare blockers, Combat damage, End of combat, Main 2, End step, Cleanup.

    - Untap: the active player's permanents untap automatically, then the
      table moves on to Upkeep by itself (nobody gets priority in untap).
    - Draw: the active player draws automatically. Only in a two-player game
      does the starting player skip the draw on their first turn (rule
      103.8a); in multiplayer Commander everyone draws (rule 103.8c).
    - Cleanup: passes by itself to the next player's turn.
    - NEXT STEP (active player): move to the next step.
      END TURN (active player): jump to the End step; from there, to the next turn.
      Hotkeys: "MTG: next step", "MTG: end turn" (TTS Options > Game Keys).
    - Turn order is clockwise (White, Red, Green, Blue), skipping players
      who are out of the game.

  Later in Phase 4: Hold windows for other players, discard to 7, overrides.
  Other modules can listen for Events "stepStarted" { seat, step, turn }.
--]]

Turns = {}

Turns.STEPS = {
  { id = "untap", label = "UNTAP" },
  { id = "upkeep", label = "UPKEEP" },
  { id = "draw", label = "DRAW" },
  { id = "main1", label = "MAIN 1" },
  { id = "combat", label = "COMBAT" },
  { id = "attackers", label = "ATTACK" },
  { id = "blockers", label = "BLOCK" },
  { id = "damage", label = "DAMAGE" },
  { id = "endcombat", label = "END COMBAT" },
  { id = "main2", label = "MAIN 2" },
  { id = "end", label = "END" },
  { id = "cleanup", label = "CLEANUP" },
}
local STEP_INDEX = {}
for i, s in ipairs(Turns.STEPS) do
  STEP_INDEX[s.id] = i
end

local SEAT_HEX = { White = "#C7CCD9", Red = "#DB5454", Green = "#52C26B", Blue = "#5294F2" }
local ON, OFF = "#5AF0FF", "#3A4556"
local INFO = { 0.75, 0.8, 0.9 }
local WARN = { 1, 0.6, 0.2 }

local function turn()
  local d = GameState.data
  d.turn = d.turn or { number = 0 }
  return d.turn
end

local function players()
  local s = GameState.data.setup
  return (s and s.participants) or TableSetup.activeSeats()
end

---------------------------------------------------------------------------
-- Turn bar (top of the screen)
---------------------------------------------------------------------------

function Turns.xml()
  local steps = {}
  for i, s in ipairs(Turns.STEPS) do
    table.insert(steps, ('<Text id="turnStep_%d" fontSize="12" fontStyle="Bold" color="%s">%s</Text>')
      :format(i, OFF, s.label))
  end
  return [[
<Panel id="turnBar" active="false" rectAlignment="UpperCenter" offsetXY="0 -12" width="980" height="96"
       color="#0B0F17F0" outline="#5AF0FF" outlineSize="2 2">
  <VerticalLayout padding="14 14 8 8" spacing="6" childForceExpandHeight="false">
    <HorizontalLayout preferredHeight="34" spacing="12" childForceExpandWidth="false">
      <Text id="turnTitle" fontSize="20" fontStyle="Bold" color="#E6F1FF" alignment="MiddleLeft" flexibleWidth="1">TURN</Text>
      <Button id="turnNext" onClick="ui_turnNext" preferredWidth="150" color="#00B3A4" textColor="#06130B" fontStyle="Bold"
              tooltip="Active player: go to the next step">NEXT STEP</Button>
      <Button id="turnEnd" onClick="ui_turnEnd" preferredWidth="150" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold"
              tooltip="Active player: skip to the end of your turn">END TURN</Button>
    </HorizontalLayout>
    <HorizontalLayout preferredHeight="22" spacing="4">]] .. table.concat(steps) .. [[</HorizontalLayout>
  </VerticalLayout>
</Panel>
]]
end

function Turns.render()
  local d = GameState.data
  local t = turn()
  if not d.started or t.activeSeat == nil then
    UI.setAttribute("turnBar", "active", "false")
    return
  end
  UI.setAttribute("turnBar", "active", "true")
  UI.setAttribute("turnBar", "outline", SEAT_HEX[t.activeSeat] or ON)
  local step = Turns.STEPS[t.stepIndex or 1]
  UI.setValue("turnTitle", "TURN " .. t.number .. "  ·  " .. string.upper(t.activeSeat)
    .. "  ·  " .. (step and step.label or ""))
  UI.setAttribute("turnTitle", "color", SEAT_HEX[t.activeSeat] or "#E6F1FF")
  for i = 1, #Turns.STEPS do
    UI.setAttribute("turnStep_" .. i, "color", i == t.stepIndex and ON or OFF)
  end
end

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------

local enterStep

local function nextPlayer(after)
  local list = players()
  local start
  for i, c in ipairs(list) do
    if c == after then
      start = i
    end
  end
  start = start or 0
  for k = 1, #list do
    local c = list[((start + k - 1) % #list) + 1]
    local p = GameState.player(c)
    if p and not p.eliminated then
      return c
    end
  end
  return after
end

-- Start a seat's turn at the untap step.
function Turns.beginTurn(seat, number)
  local t = turn()
  t.activeSeat = seat
  t.number = number or ((t.number or 0) + 1)
  t.stepIndex = 1
  broadcastToAll("Turn " .. t.number .. ": " .. seat, { 0.55, 0.9, 0.6 })
  enterStep()
end

local function advance()
  local t = turn()
  if t.stepIndex >= #Turns.STEPS then
    Turns.beginTurn(nextPlayer(t.activeSeat))
    return
  end
  t.stepIndex = t.stepIndex + 1
  enterStep()
end

enterStep = function()
  local t = turn()
  local step = Turns.STEPS[t.stepIndex]
  local seat = t.activeSeat
  Turns.render()
  Events.emit("stepStarted", { seat = seat, step = step.id, turn = t.number })

  if step.id == "untap" then
    Actions.untapAll(seat, true)
    -- No one gets priority in the untap step.
    Wait.time(advance, 0.8)
  elseif step.id == "draw" then
    local skip = t.number == 1 and #players() == 2 and seat == t.startingSeat
    if skip then
      broadcastToAll(seat .. " skips the first draw (two-player rule).", INFO)
    else
      Actions.draw(seat, 1, "draw step")
    end
  elseif step.id == "cleanup" then
    -- Discard to 7 comes later in Phase 4; for now cleanup passes on its own.
    Wait.time(advance, 0.6)
  end
end

local function isActive(color)
  local t = turn()
  if not GameState.data.started then
    broadcastToColor("No game running. Use Start Game first.", color, WARN)
    return false
  end
  if color ~= t.activeSeat then
    broadcastToColor("It's " .. tostring(t.activeSeat) .. "'s turn.", color, WARN)
    return false
  end
  return true
end

function Turns.next(color)
  if not isActive(color) then
    return
  end
  local id = Turns.STEPS[turn().stepIndex].id
  if id == "untap" or id == "cleanup" then
    return   -- these move on by themselves
  end
  advance()
end

function Turns.endTurn(color)
  if not isActive(color) then
    return
  end
  local t = turn()
  local endIndex = STEP_INDEX["end"]
  if t.stepIndex < endIndex then
    t.stepIndex = endIndex
    enterStep()
  else
    advance()
  end
end

-- Mulligans are done: the starting player's first turn begins.
Events.on("gameStarted", function(d)
  local t = turn()
  t.startingSeat = d.first
  Turns.beginTurn(d.first, 1)
end)

function ui_turnNext(player)
  Turns.next(player.color)
end

function ui_turnEnd(player)
  Turns.endTurn(player.color)
end

function Turns.registerHotkeys()
  addHotkey("MTG: next step", function(playerColor) Turns.next(playerColor) end)
  addHotkey("MTG: end turn", function(playerColor) Turns.endTurn(playerColor) end)
end
