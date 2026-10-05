--[[
  turns.lua
  The turn engine (Phase 4): steps in order, automatic untap and draw,
  clockwise turn order, and a live turn strip on the table at every seat.

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

    - Responses: NEXT STEP / END TURN ask each other player in turn order
      (a pop-up only they see): NO RESPONSE passes it on; I HAVE A RESPONSE
      stops the move. Clicking NEXT STEP again during the wait goes now.
    - END TURN: after the responses, runs end step and cleanup by itself.
    - Cleanup: discard down to 7 (actions.lua), then the turn passes.
    - TURN OPTIONS (screen, under Start Game): extra turn, extra combat,
      skip this step, reverse turn order.
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
local ART_VERSION = "?v=2"

-- The turn shows on the table strips (below). The screen only has the
-- TURN OPTIONS button (under Start Game) and its panel.
function Turns.xml()
  local function opt(which, text, tip)
    return ('<Button onClick="ui_turnOpt(%s)" color="#141B26" textColor="#E6F1FF" fontStyle="Bold" tooltip="%s">%s</Button>')
      :format(which, tip, text)
  end
  return [[
<Button id="turnOptsToggle" onClick="ui_turnOpts" rectAlignment="UpperLeft" offsetXY="20 -120"
        width="150" height="40" fontStyle="Bold" color="#2A3346" textColor="#E6F1FF">Turn Options</Button>
<Panel id="turnOpts" active="false" rectAlignment="UpperLeft" offsetXY="180 -120" width="260" height="250"
       color="#0B0F17F2" outline="#5AF0FF" outlineSize="2 2">
  <VerticalLayout padding="12 12 12 12" spacing="8">
    <Text fontSize="15" fontStyle="Bold" color="#5AF0FF" preferredHeight="22">TURN OPTIONS</Text>]]
    .. opt("extraTurn", "Extra turn for me", "You take an extra turn after this one")
    .. opt("extraCombat", "Extra combat", "Active player: one more combat phase this turn")
    .. opt("skip", "Skip this step", "Active player: move on now, no hold window")
    .. opt("reverse", "Reverse turn order", "Flip between clockwise and counter-clockwise")
    .. [[
  </VerticalLayout>
</Panel>
]] .. Turns.respondXml()
end

function Turns.render()
  Turns.renderStrips()
end

---------------------------------------------------------------------------
-- Turn strips on the table: one per seat, between its battlefield and its
-- top row, all showing the same live turn info in the active player's color.
-- The plate is a fixed image (assets/ui/turnstrip.png); border, title and the
-- lit step are buttons drawn on top, redrawn every step.
---------------------------------------------------------------------------

local STRIP_W, STRIP_D = 30.4, 1.6
local U = 500                 -- button units per table unit
local TITLE_X = -11.6         -- center of the title area (table units)
local STEPS_X0 = -8.0         -- left edge of the step chips
local CHIP_W = 1.93
local STRIP_LABELS = { "UNTAP", "UPKEEP", "DRAW", "MAIN 1", "COMBAT", "ATTACK", "BLOCK", "DAMAGE",
  "END CMBT", "MAIN 2", "END", "CLEANUP" }
local SEAT_RGB = { White = { 0.80, 0.83, 0.90 }, Red = { 0.90, 0.30, 0.33 },
  Green = { 0.30, 0.85, 0.48 }, Blue = { 0.33, 0.60, 1.0 } }
local NEUTRAL = { 0.45, 0.55, 0.65 }

local function strips()
  GameState.data.table = GameState.data.table or {}
  GameState.data.table.turnStrips = GameState.data.table.turnStrips or {}
  return GameState.data.table.turnStrips
end

local function renderStrip(color)
  local guid = strips()[color]
  local tile = guid and getObjectFromGUID(guid)
  if tile == nil then
    return
  end
  tile.clearButtons()
  local d, t = GameState.data, turn()
  local running = d.started and t.activeSeat ~= nil
  local rgb = running and (SEAT_RGB[t.activeSeat] or NEUTRAL) or NEUTRAL
  local line = { rgb[1], rgb[2], rgb[3], 1 }
  local B = function(params, x, z) params.click_function = "trk_noop"; Trackers.tileButton(tile, params, x, z) end
  -- Border in the active player's color.
  local hw, hd, th = STRIP_W / 2 - 0.05, STRIP_D / 2 - 0.05, 0.07
  B({ label = "", width = math.floor(STRIP_W * U), height = math.floor(th * U), color = line }, 0, -hd)
  B({ label = "", width = math.floor(STRIP_W * U), height = math.floor(th * U), color = line }, 0, hd)
  B({ label = "", width = math.floor(th * U), height = math.floor(STRIP_D * U), color = line }, -hw, 0)
  B({ label = "", width = math.floor(th * U), height = math.floor(STRIP_D * U), color = line }, hw, 0)
  -- Title.
  local title = running and ("TURN " .. t.number .. " · " .. string.upper(t.activeSeat)) or "NO GAME RUNNING"
  local pendingTo, waitingOn
  if Turns.pendingLabel then
    pendingTo, waitingOn = Turns.pendingLabel()
  end
  if running and pendingTo then
    title = pendingTo .. "? WAITING ON " .. string.upper(waitingOn or "")
  end
  B({ label = title, width = 0, height = 0, font_size = (running and not pendingTo) and 300 or 190,
    font_color = { rgb[1], rgb[2], rgb[3] }, color = { 0, 0, 0, 0 } }, TITLE_X, 0.02)
  -- Step chips: the current one lit in the player's color, done ones dimmed.
  for i, label in ipairs(STRIP_LABELS) do
    local x = STEPS_X0 + CHIP_W * (i - 0.5)
    local on = running and i == t.stepIndex
    local done = running and i < (t.stepIndex or 1)
    if on then
      B({ label = label, width = math.floor((CHIP_W - 0.12) * U), height = math.floor(1.1 * U), font_size = 150,
        font_color = { 1, 1, 1 }, color = { rgb[1], rgb[2], rgb[3], 0.6 } }, x, 0)
    else
      local c = done and { 0.36, 0.42, 0.50 } or { 0.62, 0.68, 0.78 }
      B({ label = label, width = 0, height = 0, font_size = 150, font_color = c, color = { 0, 0, 0, 0 } }, x, 0.02)
    end
  end
end

function Turns.renderStrips()
  for _, color in ipairs(TableSetup.activeSeats()) do
    renderStrip(color)
  end
end

function Turns.ensureStrips()
  if GameState.data.turn then
    GameState.data.turn.pending = nil   -- a hold countdown doesn't survive a reload
  end
  for _, obj in ipairs(getObjectsWithTag("TurnStrip")) do
    obj.destruct()
  end
  for key, guid in pairs(strips()) do
    local obj = getObjectFromGUID(guid)
    if obj then
      obj.destruct()
    end
    strips()[key] = nil
  end
  for _, color in ipairs(TableSetup.activeSeats()) do
    Trackers.spawnTile(color, "turnstrip", "Turn (" .. color .. ")",
      ART_BASE .. "turnstrip.png" .. ART_VERSION, STRIP_W,
      function(guid) strips()[color] = guid end,
      function() renderStrip(color) end,
      "TurnStrip")
  end
end

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------

local enterStep

local function livePlayers()
  local n = 0
  for _, c in ipairs(players()) do
    local p = GameState.player(c)
    if p and not p.eliminated then
      n = n + 1
    end
  end
  return n
end

-- The next player in turn order (clockwise, or the other way when reversed),
-- skipping players who are out.
local function nextPlayer(after)
  local list = players()
  local start
  for i, c in ipairs(list) do
    if c == after then
      start = i
    end
  end
  start = start or 0
  local dir = turn().reversed and -1 or 1
  for k = 1, #list do
    local c = list[((start - 1 + dir * k) % #list) + 1]
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
  t.pending = nil
  t.autoThrough = nil
  broadcastToAll("Turn " .. t.number .. ": " .. seat, { 0.55, 0.9, 0.6 })
  enterStep()
end

-- Who takes the next turn: a queued extra turn first, else the next player.
local function nextTurn()
  local t = turn()
  if t.extraTurns and #t.extraTurns > 0 then
    local seat = table.remove(t.extraTurns, 1)
    broadcastToAll(seat .. " takes an extra turn.", { 0.55, 0.9, 0.6 })
    Turns.beginTurn(seat)
    return
  end
  Turns.beginTurn(nextPlayer(t.activeSeat))
end

-- Where "next step" goes from here (an extra combat loops End of combat back
-- to Beginning of combat). peek = don't use up the extra combat.
local function nextIndex(peek)
  local t = turn()
  if Turns.STEPS[t.stepIndex].id == "endcombat" and (t.extraCombats or 0) > 0 then
    if not peek then
      t.extraCombats = t.extraCombats - 1
      broadcastToAll(t.activeSeat .. " gets an extra combat.", INFO)
    end
    return STEP_INDEX["combat"]
  end
  return t.stepIndex + 1
end

local function advance()
  local t = turn()
  t.pending = nil
  local i = nextIndex(false)
  if i > #Turns.STEPS then
    nextTurn()
    return
  end
  t.stepIndex = i
  enterStep()
end

-- Move on by itself after a moment, unless someone already moved the turn on.
local function autoAdvance(delay)
  local t = turn()
  local num, idx = t.number, t.stepIndex
  Wait.time(function()
    local now = turn()
    if now.number == num and now.stepIndex == idx and GameState.data.started and not now.pending then
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
  elseif step.id == "end" and t.autoThrough then
    -- Reached through END TURN: carry on to cleanup by itself.
    autoAdvance(1)
  elseif step.id == "cleanup" then
    -- Discard down to 7 first (if needed), then the turn passes.
    Actions.cleanupDiscard(seat, function() autoAdvance(0.6) end)
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

---------------------------------------------------------------------------
-- Responses: when the active player clicks NEXT STEP / END TURN, each other
-- player in turn order gets a pop-up (only they see it): NO RESPONSE passes
-- it to the next player; when the last one passes, the step changes.
-- I HAVE A RESPONSE stops it; the active player clicks NEXT STEP again when
-- the response is done. Clicking NEXT STEP again while waiting goes now.
---------------------------------------------------------------------------

local function stepLabelAt(i)
  return i > #Turns.STEPS and "NEXT TURN" or Turns.STEPS[i].label
end

-- Where the pending move lands, and who it's waiting on (for the strips).
function Turns.pendingLabel()
  local t = turn()
  if not t.pending then
    return nil
  end
  local i
  if t.pending.kind == "end" and t.stepIndex < STEP_INDEX["end"] then
    i = STEP_INDEX["end"]
  else
    i = nextIndex(true)
  end
  return stepLabelAt(i), t.pending.queue[t.pending.at]
end

local function showPrompt(color, show)
  UI.setAttribute("respond_" .. color, "active", show and "true" or "false")
end

local function hideAllPrompts()
  for _, c in ipairs(TableSetup.activeSeats()) do
    showPrompt(c, false)
  end
end

local function promptNext()
  local t = turn()
  local p = t.pending
  hideAllPrompts()
  local who = p.queue[p.at]
  local to = Turns.pendingLabel()
  UI.setValue("respondText_" .. who, t.activeSeat .. " wants to move to " .. to .. ".\nAny responses?")
  showPrompt(who, true)
  Turns.render()
end

local function commit(kind)
  local t = turn()
  t.pending = nil
  hideAllPrompts()
  if kind == "end" then
    -- END TURN runs the rest of the turn on its own: end step, cleanup, next.
    t.autoThrough = true
    if t.stepIndex < STEP_INDEX["end"] then
      t.stepIndex = STEP_INDEX["end"]
      enterStep()
      return
    end
  end
  advance()
end

local function requestMove(kind)
  local t = turn()
  if t.pending then
    broadcastToAll(t.activeSeat .. " moves on without waiting.", INFO)
    commit(t.pending.kind)
    return
  end
  -- Everyone else still in the game, in turn order after the active player.
  local queue, c = {}, t.activeSeat
  for _ = 1, #players() do
    c = nextPlayer(c)
    if c == t.activeSeat then
      break
    end
    table.insert(queue, c)
  end
  if #queue == 0 then
    commit(kind)
    return
  end
  t.pending = { kind = kind, queue = queue, at = 1 }
  promptNext()
end

-- A player answered their pop-up.
function Turns.respond(color, hasResponse)
  local t = turn()
  local p = t.pending
  if p == nil then
    return
  end
  if hasResponse then
    t.pending = nil
    hideAllPrompts()
    broadcastToAll(color .. " has a response! " .. t.activeSeat .. ": click NEXT STEP when it's done.", WARN)
    Turns.render()
    return
  end
  if p.queue[p.at] ~= color then
    return
  end
  p.at = p.at + 1
  if p.at > #p.queue then
    commit(p.kind)
  else
    promptNext()
  end
end

-- Hotkey: "MTG: hold" = I have a response (while a move is waiting).
function Turns.hold(color)
  local t = turn()
  if not GameState.data.started or not t.pending then
    return
  end
  Turns.respond(color, true)
end

function ui_respond(player, arg)
  local color, answer = tostring(arg):match("^(%a+)_(%a+)$")
  if color == nil or player.color ~= color then
    return
  end
  Turns.respond(color, answer == "yes")
end

function Turns.respondXml()
  local parts = {}
  for _, c in ipairs(TableSetup.activeSeats()) do
    table.insert(parts, ([[
<Panel id="respond_%s" visibility="%s" active="false" rectAlignment="MiddleCenter" offsetXY="0 140" width="440" height="190"
       color="#0B0F17F5" outline="#5AF0FF" outlineSize="2 2">
  <VerticalLayout padding="16 16 14 14" spacing="10" childForceExpandHeight="false">
    <Text fontSize="20" fontStyle="Bold" color="#5AF0FF" preferredHeight="26">RESPONSES?</Text>
    <Text id="respondText_%s" fontSize="15" color="#E6F1FF" preferredHeight="46">-</Text>
    <HorizontalLayout spacing="12" preferredHeight="48">
      <Button onClick="ui_respond(%s_no)" color="#00B3A4" textColor="#06130B" fontStyle="Bold" fontSize="16">NO RESPONSE</Button>
      <Button onClick="ui_respond(%s_yes)" color="#DB5454" textColor="#1A0606" fontStyle="Bold" fontSize="16">I HAVE A RESPONSE</Button>
    </HorizontalLayout>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, c, c))
  end
  return table.concat(parts)
end

function Turns.next(color)
  if not isActive(color) then
    return
  end
  local id = Turns.STEPS[turn().stepIndex].id
  if id == "untap" or id == "draw" or id == "cleanup" then
    return   -- these move on by themselves
  end
  requestMove("next")
end

function Turns.endTurn(color)
  if not isActive(color) then
    return
  end
  local id = Turns.STEPS[turn().stepIndex].id
  if id == "untap" or id == "draw" or id == "cleanup" then
    return
  end
  requestMove("end")
end

---------------------------------------------------------------------------
-- Turn options (overrides): extra turn, extra combat, skip step, reverse
---------------------------------------------------------------------------

function Turns.addExtraTurn(color)
  local t = turn()
  t.extraTurns = t.extraTurns or {}
  table.insert(t.extraTurns, color)
  broadcastToAll(color .. " will take an extra turn after this one.", INFO)
end

function Turns.addExtraCombat(color)
  if not isActive(color) then
    return
  end
  local t = turn()
  t.extraCombats = (t.extraCombats or 0) + 1
  broadcastToAll(color .. " gets an additional combat phase this turn.", INFO)
end

function Turns.skipStep(color)
  if not isActive(color) then
    return
  end
  local id = Turns.STEPS[turn().stepIndex].id
  if id == "untap" or id == "draw" or id == "cleanup" then
    return
  end
  commit("next")
end

function Turns.reverse(color)
  local t = turn()
  t.reversed = not t.reversed
  broadcastToAll(color .. " reversed the turn order: now " .. (t.reversed and "counter-clockwise" or "clockwise") .. ".", INFO)
end

-- Mulligans are done: the starting player's first turn begins.
Events.on("gameStarted", function(d)
  local t = turn()
  t.startingSeat = d.first
  t.extraTurns, t.extraCombats, t.reversed, t.pending = {}, 0, false, nil
  Turns.beginTurn(d.first, 1)
end)

local optsOpen = false

function ui_turnOpts(player)
  optsOpen = not optsOpen
  if optsOpen then
    UI.setAttribute("turnOpts", "visibility", player.color)
    UI.show("turnOpts")
  else
    UI.hide("turnOpts")
  end
end

function ui_turnOpt(player, which)
  local c = player.color
  if not TableSetup.isActive(c) then
    return
  end
  if not GameState.data.started then
    broadcastToColor("No game running. Use Start Game first.", c, WARN)
    return
  end
  if which == "extraTurn" then
    Turns.addExtraTurn(c)
  elseif which == "extraCombat" then
    Turns.addExtraCombat(c)
  elseif which == "skip" then
    Turns.skipStep(c)
  elseif which == "reverse" then
    Turns.reverse(c)
  end
end

function Turns.registerHotkeys()
  addHotkey("MTG: next step", function(playerColor) Turns.next(playerColor) end)
  addHotkey("MTG: end turn", function(playerColor) Turns.endTurn(playerColor) end)
  addHotkey("MTG: hold", function(playerColor) Turns.hold(playerColor) end)
end
