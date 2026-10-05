--[[
  turns.lua
  The turn engine (Phase 4): steps in order, automatic untap and draw,
  clockwise turn order and a turn bar everyone can see.

  Steps: Untap, Upkeep, Draw, Main 1, Beginning of combat, Declare attackers,
  Declare blockers, Combat damage, End of combat, Main 2, End step, Cleanup.

    - Untap: the active player's permanents untap automatically, then the
      table moves on to Upkeep by itself (nobody gets priority in untap).
    - Draw: the active player draws automatically, then the table moves on
      to Main 1 by itself. Only in a two-player game
      does the starting player skip the draw on their first turn (rule
      103.8a); in multiplayer Commander everyone draws (rule 103.8c).
    - Cleanup: passes by itself to the next player's turn.
    - NEXT STEP / END TURN tiles beside each tracker (actions.lua), active
      player only: next step / jump to the End step (from there, next turn).
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

local ART_BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/ui/"
local ART_VERSION = "?v=1"

function Turns.xml()
  local steps = {}
  for i, s in ipairs(Turns.STEPS) do
    table.insert(steps, ([[
      <Panel id="turnStepBg_%d" color="#00000000" preferredWidth="74">
        <Text id="turnStep_%d" fontSize="11" fontStyle="Bold" color="%s">%s</Text>
      </Panel>]]):format(i, i, OFF, s.label))
  end
  return [[
<Panel id="turnBar" active="false" rectAlignment="UpperCenter" offsetXY="0 -10" width="980" height="96" color="#00000000">
  <Image id="turnBarBg" image="]] .. ART_BASE .. "turnbar_White.png" .. ART_VERSION .. [[" raycastTarget="false" />
  <VerticalLayout padding="22 22 12 12" spacing="6" childForceExpandHeight="false">
    <HorizontalLayout preferredHeight="34" spacing="12" childForceExpandWidth="false">
      <Text id="turnTitle" fontSize="20" fontStyle="Bold" color="#E6F1FF" alignment="MiddleCenter" flexibleWidth="1">TURN</Text>
    </HorizontalLayout>
    <HorizontalLayout preferredHeight="22" spacing="4">]] .. table.concat(steps) .. [[</HorizontalLayout>
  </VerticalLayout>
</Panel>
]]
end

-- Seat color as a translucent fill for the current step's chip.
local CHIP = { White = "#C7CCD955", Red = "#DB545466", Green = "#52C26B66", Blue = "#5294F266" }

function Turns.render()
  local d = GameState.data
  local t = turn()
  if not d.started or t.activeSeat == nil then
    UI.setAttribute("turnBar", "active", "false")
    return
  end
  local seat = t.activeSeat
  UI.setAttribute("turnBar", "active", "true")
  UI.setAttribute("turnBarBg", "image", ART_BASE .. "turnbar_" .. seat .. ".png" .. ART_VERSION)
  local step = Turns.STEPS[t.stepIndex or 1]
  UI.setValue("turnTitle", "TURN " .. t.number .. "  ·  " .. string.upper(seat)
    .. "  ·  " .. (step and step.label or ""))
  UI.setAttribute("turnTitle", "color", SEAT_HEX[seat] or "#E6F1FF")
  for i = 1, #Turns.STEPS do
    local on = i == t.stepIndex
    UI.setAttribute("turnStepBg_" .. i, "color", on and (CHIP[seat] or "#5AF0FF44") or "#00000000")
    UI.setAttribute("turnStep_" .. i, "color", on and "#FFFFFF" or (i < (t.stepIndex or 1) and "#5B6B80" or OFF))
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

-- Move on by itself after a moment, unless someone already moved the turn on.
local function autoAdvance(delay)
  local t = turn()
  local num, idx = t.number, t.stepIndex
  Wait.time(function()
    local now = turn()
    if now.number == num and now.stepIndex == idx and GameState.data.started then
      advance()
    end
  end, delay)
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
    autoAdvance(0.8)
  elseif step.id == "draw" then
    local skip = t.number == 1 and #players() == 2 and seat == t.startingSeat
    if skip then
      broadcastToAll(seat .. " skips the first draw (two-player rule).", INFO)
    else
      Actions.draw(seat, 1, "draw step")
    end
    -- Nothing else normally happens in the draw step: move on to Main 1.
    autoAdvance(1)
  elseif step.id == "cleanup" then
    -- Discard to 7 comes later in Phase 4; for now cleanup passes on its own.
    autoAdvance(0.6)
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
  if id == "untap" or id == "draw" or id == "cleanup" then
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
