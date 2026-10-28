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
  if s and s.participants then
    -- Drop anything in the player list that isn't a seat colour (it would break the prompts and the mana).
    for i = #s.participants, 1, -1 do
      if TableSetup.badSeat(s.participants[i], "the player list") then
        table.remove(s.participants, i)
      end
    end
    return s.participants
  end
  return TableSetup.activeSeats()
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
<Panel id="turnOpts" active="false" rectAlignment="UpperLeft" offsetXY="180 -120" width="260" height="344"
       color="#0B0F17F2" outline="#5AF0FF" outlineSize="2 2">
  <VerticalLayout padding="12 12 12 12" spacing="8">
    <Text fontSize="15" fontStyle="Bold" color="#5AF0FF" preferredHeight="22">TURN OPTIONS</Text>]]
    .. opt("extraTurn", "Extra turn for me", "You take an extra turn after this one")
    .. opt("extraCombat", "Extra combat", "Active player: one more combat phase this turn")
    .. opt("skip", "Skip this step", "Active player: move on now, no hold window")
    .. opt("reverse", "Reverse turn order", "Flip between clockwise and counter-clockwise")
    .. '<Button id="fireVolumeBtn" onClick="ui_turnOpt(fireVolume)" color="#3A2414" textColor="#FFD9A8" fontStyle="Bold" tooltip="The fireplace crackle for the whole table: Off, Low, Medium, High">Fire sound: '
      .. ((Fires and Fires.volumeName and Fires.volumeName()) or "Low") .. '</Button>'
    .. '<Button onClick="ui_flipTable" color="#5A1F2B" textColor="#FFD0D8" fontStyle="Bold" tooltip="Just for fun">Flip the table!</Button>'
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
  local title = running and ("TURN " .. t.number .. " · " .. string.upper(table.concat(Turns.activeTeam(), " + "))) or "NO GAME RUNNING"
  local pendingTo, waitingOn
  if Turns.pendingLabel then
    pendingTo, waitingOn = Turns.pendingLabel()
  end
  local size = (running and not pendingTo) and 300 or 190
  if running and pendingTo then
    -- Two lines, sized to fit the title area (about 7 table units wide).
    local l1 = string.upper(tostring(pendingTo)) .. "?"
    local l2 = "WAITING ON " .. string.upper(waitingOn or "")
    local longest = math.max(#l1, #l2)
    title = l1 .. "\n" .. l2
    size = math.max(70, math.min(170, math.floor(3300 / (0.66 * longest))))
  end
  B({ label = title, width = 0, height = 0, font_size = size,
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
    GameState.data.turn.pending = nil   -- a waiting response round doesn't survive a reload
  end
  local wanted = {}
  for _, color in ipairs(TableSetup.activeSeats()) do
    table.insert(wanted, { key = color, color = color, region = "turnstrip", name = "Turn (" .. color .. ")",
      url = ART_BASE .. "turnstrip.png" .. ART_VERSION, width = STRIP_W,
      draw = function() renderStrip(color) end })
  end
  Trackers.syncTiles("TurnStrip", { { registry = strips(), wanted = wanted } })
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

-- Two-Headed Giant: a team takes its turn together (CR 810.4). The seats taking the current turn
-- (the active player and, in 2HG, their teammate still in the game).
function Turns.activeTeam()
  local t = turn()
  local a = t.activeSeat
  if a == nil then
    return {}
  end
  if not (TableSetup.isTeamGame and TableSetup.isTeamGame()) then
    return { a }
  end
  local out = {}
  for _, c in ipairs(TableSetup.teamSeats(a)) do
    local p = GameState.player(c)
    if c == a or (p and not p.eliminated) then
      table.insert(out, c)
    end
  end
  return out
end

-- Is this seat taking the current turn (the active player, or their 2HG teammate)?
function Turns.isActiveSeat(c)
  local t = turn()
  if c == nil or t.activeSeat == nil then
    return false
  end
  if c == t.activeSeat then
    return true
  end
  local team = TableSetup.teamOf and TableSetup.teamOf(c)
  return team ~= nil and team == TableSetup.teamOf(t.activeSeat)
end

-- The next seat to take a turn: in 2HG the next player not on this team (the turn goes team to team).
local function nextTurnPlayer(after)
  local c = nextPlayer(after)
  if TableSetup.isTeamGame and TableSetup.isTeamGame() and after then
    local team = TableSetup.teamOf(after)
    for _ = 1, #players() do
      if TableSetup.teamOf(c) ~= team then
        break
      end
      c = nextPlayer(c)
    end
  end
  return c
end

-- Start a seat's turn at the untap step.
-- Start a seat's turn at the untap step. The turn NUMBER counts trips
-- around the table (turn 1 = everyone's first turn): it only goes up when
-- play gets back to the player who went first (newRound = true).
function Turns.beginTurn(seat, number, newRound)
  local t = turn()
  t.activeSeat = seat
  if number then
    t.number = number
  elseif newRound then
    t.number = (t.number or 0) + 1
  end
  t.taken = (t.taken or 0) + 1   -- turns taken in the game, by anyone
  -- When each seat's latest turn began: summoning sickness lasts until then (combat.lua isSick).
  GameState.data.turnStartOf = GameState.data.turnStartOf or {}
  local team = Turns.activeTeam()
  for _, c in ipairs(team) do
    GameState.data.turnStartOf[c] = t.taken
  end
  t.stepIndex = 1
  t.pending = nil
  t.autoThrough = nil
  t.resume = nil
  broadcastToAll("Turn " .. t.number .. ": " .. table.concat(team, " + "), { 0.55, 0.9, 0.6 })
  enterStep()
end

-- Who takes the next turn: a queued extra turn first, else the next player.
local function nextTurn()
  local t = turn()
  if t.extraTurns and #t.extraTurns > 0 then
    local seat = t.extraTurns[1] and table.remove(t.extraTurns, 1)
    broadcastToAll(seat .. " takes an extra turn.", { 0.55, 0.9, 0.6 })
    Turns.beginTurn(seat)
    return
  end
  -- A new round starts when play gets back to whoever went first (or, if
  -- they're out, the next player still in after them).
  local anchor = t.startingSeat
  local ap = anchor and GameState.player(anchor)
  if ap == nil or ap.eliminated then
    anchor = nextTurnPlayer(anchor)
  end
  -- Eater of Days: seats with turns to skip are passed over (each skip used up).
  local cur, newRound = t.activeSeat, false
  for _ = 1, 12 do
    local seat = nextTurnPlayer(cur)
    if seat == anchor or (TableSetup.isTeamGame and TableSetup.isTeamGame() and anchor
        and TableSetup.teamOf(seat) == TableSetup.teamOf(anchor)) then
      newRound = true
    end
    local sk = t.skipTurns and t.skipTurns[seat] or 0
    if sk > 0 then
      t.skipTurns[seat] = sk - 1
      broadcastToAll(seat .. " skips this turn (" .. (sk - 1) .. " more to skip).", { 1, 0.6, 0.3 })
      cur = seat
    else
      Turns.beginTurn(seat, nil, newRound)
      return
    end
  end
  Turns.beginTurn(nextTurnPlayer(t.activeSeat), nil, false)
end

-- "You skip your next N turns."
function Turns.addSkip(seat, n)
  local t = turn()
  t.skipTurns = t.skipTurns or {}
  t.skipTurns[seat] = (t.skipTurns[seat] or 0) + (n or 1)
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
  -- No attackers: skip blockers and damage (combat.lua).
  if Turns.STEPS[t.stepIndex].id == "attackers" and Combat and Combat.skipToEnd() then
    return STEP_INDEX["endcombat"]
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
    if now.number == num and now.stepIndex == idx and GameState.data.started and not now.pending
        and (Stack == nil or Stack.isEmpty()) then
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

  local team = Turns.activeTeam()
  if step.id == "untap" then
    for _, c in ipairs(team) do
      Actions.untapAll(c, true)
    end
    if Actions.othersUntap then
      pcall(Actions.othersUntap, seat)
    end
    -- No one gets priority in the untap step.
    autoAdvance(0.8)
  elseif step.id == "draw" then
    -- Two players: whoever goes first skips their first draw (the game's
    -- very first turn).
    -- Two-Headed Giant: the team that goes first skips its first draw too (CR 103.8b).
    local isTeam = TableSetup.isTeamGame and TableSetup.isTeamGame()
    local skip = (t.taken or 1) == 1 and (#players() == 2 or isTeam) and seat == t.startingSeat
    if skip then
      broadcastToAll(table.concat(team, " + ") .. (isTeam and " skip the first draw (Two-Headed Giant rule)."
        or " skips the first draw (two-player rule)."), INFO)
    else
      for _, c in ipairs(team) do
        local skipBy = Statics and Statics.skipsDrawStep and Statics.skipsDrawStep(c)
        if skipBy then
          broadcastToAll(c .. " skips their draw step (" .. skipBy .. ").", INFO)
        else
          Actions.draw(c, 1, "draw step")
        end
      end
    end
    -- Nothing else normally happens in the draw step: move on to Main 1.
    autoAdvance(1)
  elseif step.id == "end" and t.autoThrough then
    -- Reached through END TURN: carry on to cleanup by itself.
    autoAdvance(1)
  elseif step.id == "cleanup" then
    -- Discard down to 7 first (if needed), then the turn passes.
    -- Each player of the team discards down to 7, one after the other.
    local function discardFrom(i)
      if i > #team then
        autoAdvance(0.6)
        return
      end
      Actions.cleanupDiscard(team[i], function() discardFrom(i + 1) end)
    end
    discardFrom(1)
  end
end

-- Nothing moves on while spells or abilities wait on the stack.
local function stackBusy(color)
  if Stack and Stack.size() == 0 and not Stack.isEmpty() then
    broadcastToColor("Waiting for a player's choice (trigger order or a \"you may\").", color, WARN)
    return true
  end
  if Stack and not Stack.isEmpty() then
    broadcastToColor("Resolve the stack first (" .. Stack.size() .. " on it).", color, WARN)
    return true
  end
  return false
end

local function isActive(color)
  local t = turn()
  if not GameState.data.started then
    broadcastToColor("No game running. Use Start Game first.", color, WARN)
    return false
  end
  if not Turns.isActiveSeat(color) and not GameState.solo() then
    broadcastToColor("It's " .. table.concat(Turns.activeTeam(), " + ") .. "'s turn.", color, WARN)
    return false
  end
  -- The turn lost track of its step (seen once, cause unknown): put it back
  -- at Main 1 instead of erroring, and say so.
  if type(t.stepIndex) ~= "number" or Turns.STEPS[t.stepIndex] == nil then
    printToAll("MTG > Turn state had no step (" .. tostring(t.stepIndex) .. "); resuming " .. tostring(t.activeSeat)
      .. "'s turn at MAIN 1. Please tell Claude what happened just before this.", WARN)
    t.stepIndex = STEP_INDEX["main1"]
    t.pending = nil
    Turns.render()
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
  if t.pending.kind == "ask" then
    return t.pending.label or "GO ON", t.pending.queue[t.pending.at]
  end
  local i
  if (t.pending.kind == "end" or t.pending.kind == "endstep") and t.stepIndex < STEP_INDEX["end"] then
    i = STEP_INDEX["end"]
  else
    i = nextIndex(true)
  end
  return stepLabelAt(i), t.pending.queue[t.pending.at]
end

local function showPrompt(color, show)
  if TableSetup.badSeat(color, "the response pop-ups") then
    return
  end
  UI.setAttribute("respond_" .. color, "active", show and "true" or "false")
end

-- AFK timer: a player who doesn't answer a priority pop-up in time counts as
-- "no response" (!afk 45 / !afk off). Stopped whenever the pop-ups close.
local afkToken = 0

local function afkSeconds()
  local a = turn().afk
  if a == nil then
    return 60
  end
  return a
end

-- I HAVE A RESPONSE clicked by mistake: what was being asked, so that player can take it back
-- (NO RESPONSE AFTER ALL) as long as nothing has happened since.
local held = nil
local heldToken = 0

local function showUndo(color, show)
  UI.setAttribute("undoRespond_" .. color, "active", show and "true" or "false")
end

local function dropHeld()
  if held then
    showUndo(held.color, false)
  end
  held = nil
end

local function hideAllPrompts()
  afkToken = afkToken + 1
  dropHeld()
  for _, c in ipairs(TableSetup.activeSeats()) do
    showPrompt(c, false)
    if type(c) == "string" then
      UI.setValue("respondTimer_" .. c, "")
    end
  end
end

local function startAfkTimer(who)
  afkToken = afkToken + 1
  local tok = afkToken
  local total = afkSeconds()
  if total <= 0 then
    UI.setValue("respondTimer_" .. who, "")
    return
  end
  local left = total
  local function tick()
    if tok ~= afkToken then
      return
    end
    local p = turn().pending
    if not p or p.queue[p.at] ~= who then
      return
    end
    if left <= 0 then
      broadcastToAll(who .. " didn't answer in " .. total .. "s: counted as NO RESPONSE (AFK timer).", WARN)
      Turns.respond(who, false)
      return
    end
    UI.setValue("respondTimer_" .. who, "Passes by itself in " .. left .. "s")
    left = left - 1
    Wait.time(tick, 1)
  end
  tick()
end

-- !afk <seconds> / !afk off
function Turns.setAfk(color, arg)
  local t = turn()
  arg = tostring(arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if arg == "off" or arg == "0" then
    t.afk = 0
    broadcastToAll(color .. " turned the AFK timer off.", INFO)
  elseif tonumber(arg) and tonumber(arg) >= 5 then
    t.afk = math.floor(tonumber(arg))
    broadcastToAll(color .. " set the AFK timer: a priority pop-up passes by itself after " .. t.afk .. " seconds.", INFO)
  else
    broadcastToColor("AFK timer: " .. (afkSeconds() > 0 and (afkSeconds() .. " seconds") or "off")
      .. ". Use !afk 45 (5 or more seconds) or !afk off.", color, INFO)
  end
end

local function promptNext()
  local t = turn()
  local p = t.pending
  hideAllPrompts()
  -- YIELD: players who yielded pass on their own (while something is on the stack).
  local yielded = GameState.data.yield or {}
  local skipped = {}
  while p.queue[p.at] and yielded[p.queue[p.at]] and (p.kind == "ask" or not (Stack and Stack.isEmpty and Stack.isEmpty())) do
    table.insert(skipped, p.queue[p.at])
    p.at = p.at + 1
  end
  if #skipped > 0 then
    printToAll("MTG > " .. table.concat(skipped, ", ") .. " yielded: no response.", INFO)
  end
  if p.at > #p.queue then
    Turns.commitPending(p.kind)
    return
  end
  local who = p.queue[p.at]
  if p.kind == "ask" then
    UI.setValue("respondText_" .. who, tostring(p.text) .. "\nAny responses?")
  else
    local to = Turns.pendingLabel()
    local note = Combat and Combat.promptNote and Combat.promptNote()
    UI.setValue("respondText_" .. who, t.activeSeat .. " wants to move to " .. to .. "."
      .. (note and ("\n" .. note) or "") .. "\nAny responses?")
  end
  showPrompt(who, true)
  startAfkTimer(who)
  Turns.render()
end

-- What runs when everyone passes on an "ask" (e.g. resolving the stack).
-- Kept out of GameState: functions can't be saved.
local pendingAction = nil

local function commit(kind)
  local t = turn()
  t.pending = nil
  hideAllPrompts()
  if kind == "ask" then
    local action = pendingAction
    pendingAction = nil
    Turns.render()
    if action then
      action()
    end
    return
  end
  t.resume = nil
  if kind == "endstep" then
    -- END STEP: go to the end step and stop there (end step triggers).
    if t.stepIndex < STEP_INDEX["end"] then
      t.stepIndex = STEP_INDEX["end"]
      enterStep()
    end
    return
  end
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

function Turns.commitPending(kind)
  commit(kind)
end

-- A player just clicked YIELD: if they're the one being asked right now, that's a pass.
function Turns.yieldNow(color)
  local t = turn()
  local p = t.pending
  if p and p.queue[p.at] == color then
    Turns.respond(color, false)
  end
end

local function requestMove(kind)
  local t = turn()
  if t.pending and t.pending.kind == "ask" then
    broadcastToColor("Waiting for answers on: " .. tostring(t.pending.text), t.activeSeat, WARN)
    return
  end
  if t.pending then
    -- Priority protection in combat: nobody clicks past the players still
    -- being asked (!forcepass if someone is away).
    if Turns.protected() then
      broadcastToColor("Waiting on " .. tostring(t.pending.queue[t.pending.at]) .. " to answer (no skipping)."
        .. " Type !forcepass if they're away.", t.activeSeat, WARN)
      return
    end
    broadcastToAll(t.activeSeat .. " moves on without waiting.", INFO)
    commit(t.pending.kind)
    return
  end
  -- Solo test: no one else to ask.
  if GameState.solo() then
    commit(kind)
    return
  end
  -- Everyone else still in the game, in turn order after the active player.
  local queue, c = {}, t.activeSeat
  for _ = 1, #players() do
    c = nextPlayer(c)
    if c == t.activeSeat then
      break
    end
    -- 2HG: the teammate takes the turn too; only the other team is asked.
    if not Turns.isActiveSeat(c) then
      table.insert(queue, c)
    end
  end
  if #queue == 0 then
    commit(kind)
    return
  end
  t.pending = { kind = kind, queue = queue, at = 1 }
  promptNext()
end

-- The stack just emptied: a step that moves on by itself (untap, draw, or
-- the end step during END TURN) carries on.
function Turns.onStackEmpty()
  local t = turn()
  if not GameState.data.started or t.stepIndex == nil then
    return
  end
  if Combat and Combat.onStackEmpty then
    Combat.onStackEmpty()
  end
  local id = Turns.STEPS[t.stepIndex].id
  if id == "untap" or id == "draw" or (id == "end" and t.autoThrough) then
    autoAdvance(0.6)
  end
end

-- Ask everyone else (in turn order after `from`) for responses before
-- something happens, with the same pop-up as NEXT STEP. onAllPass runs
-- when every player answers NO RESPONSE. `label` shows on the turn strips
-- ("RESOLVE? WAITING ON RED"). Asking again while it's waiting goes now.
function Turns.ask(from, text, label, onAllPass)
  local t = turn()
  if t.pending then
    if t.pending.kind == "ask" and t.pending.from == from then
      if Turns.protected() then
        broadcastToColor("Waiting on " .. tostring(t.pending.queue[t.pending.at]) .. " to answer (no skipping)."
          .. " Type !forcepass if they're away.", from, WARN)
        return
      end
      broadcastToAll(from .. " goes ahead without waiting.", INFO)
      commit("ask")
    else
      broadcastToColor("Wait for the current question to be answered first.", from, WARN)
    end
    return
  end
  local queue, c = {}, from
  if GameState.solo() then
    pendingAction = onAllPass
    commit("ask")
    return
  end
  local yielded = GameState.data.yield or {}
  local skipped = {}
  for _ = 1, #players() do
    c = nextPlayer(c)
    if c == from then
      break
    end
    -- YIELD: this player passes on everything until the stack is empty.
    if yielded[c] then
      table.insert(skipped, c)
    else
      table.insert(queue, c)
    end
  end
  if #skipped > 0 then
    printToAll("MTG > " .. table.concat(skipped, ", ") .. " yielded: no response.", INFO)
  end
  pendingAction = onAllPass
  if #queue == 0 then
    commit("ask")
    return
  end
  t.pending = { kind = "ask", queue = queue, at = 1, from = from, text = text, label = label }
  promptNext()
end

-- The wait for answers can't be clicked through, in any step: whoever is
-- being asked decides (or someone types !forcepass if they're away).
function Turns.protected()
  local t = turn()
  return GameState.data.started == true and t.stepIndex ~= nil and Turns.STEPS[t.stepIndex] ~= nil
end

-- !forcepass: move on now (someone isn't answering).
function Turns.forcePass(color)
  local t = turn()
  if not t.pending then
    broadcastToColor("Nobody is being waited on.", color, INFO)
    return
  end
  broadcastToAll(color .. " forced a pass (" .. tostring(t.pending.queue[t.pending.at]) .. " didn't answer).", WARN)
  commit(t.pending.kind)
end

-- Remember a pass that was just stopped, and offer its player the take-back button for 20 seconds.
local function rememberHeld(color, p, t)
  heldToken = heldToken + 1
  local tok = heldToken
  held = { color = color, pending = p, action = pendingAction, resume = t.resume, step = t.stepIndex,
    taken = t.taken, active = t.activeSeat, stack = (Stack and Stack.size) and Stack.size() or 0, tok = tok }
  showUndo(color, true)
  Wait.time(function()
    if held and held.tok == tok then
      dropHeld()
    end
  end, 20)
end

-- NO RESPONSE AFTER ALL: put the question back where it was and count this player as passing.
function Turns.undoRespond(color)
  local h = held
  if h == nil or h.color ~= color then
    return
  end
  dropHeld()
  local t = turn()
  if t.pending ~= nil or t.stepIndex ~= h.step or t.taken ~= h.taken or t.activeSeat ~= h.active then
    broadcastToColor("Too late to take it back: the game has moved on.", color, WARN)
    return
  end
  if Stack and Stack.size and Stack.size() ~= h.stack then
    broadcastToColor("Too late to take it back: something went on the stack since.", color, WARN)
    return
  end
  t.pending = h.pending
  pendingAction = h.action
  t.resume = h.resume
  broadcastToAll(color .. " clicked I HAVE A RESPONSE by mistake: no response after all.", INFO)
  local p = t.pending
  if p.queue[p.at] == color then
    Turns.respond(color, false)
  else
    promptNext()
  end
end

function ui_undoRespond(player, arg)
  if player.color ~= tostring(arg) then
    return
  end
  Turns.undoRespond(player.color)
end

-- A player answered their pop-up.
function Turns.respond(color, hasResponse)
  local t = turn()
  local p = t.pending
  if p == nil then
    return
  end
  if hasResponse and p.kind == "ask" then
    local action = pendingAction
    t.pending = nil
    pendingAction = nil
    hideAllPrompts()
    pendingAction = action
    rememberHeld(color, p, t)
    pendingAction = nil
    broadcastToAll(color .. " has a response! Put it on the stack. " .. tostring(p.from)
      .. " can try again when it's done.", WARN)
    Turns.render()
    return
  end
  if hasResponse and Stack then
    Stack.autoResolve = nil   -- RESOLVE ALL stops for a response
  end
  if hasResponse then
    -- Remember what the active player was doing: after an END TURN is
    -- answered with a response, the next NEXT STEP / END TURN click carries
    -- on ending the turn (it doesn't start walking through the steps).
    local prevResume = t.resume
    t.pending = nil
    hideAllPrompts()
    t.resume = prevResume
    rememberHeld(color, p, t)
    t.resume = p.kind
    local again = p.kind == "end" and "END TURN" or (p.kind == "endstep" and "END STEP") or "NEXT STEP"
    broadcastToAll(color .. " has a response! " .. t.activeSeat .. ": click " .. again .. " when it's done.", WARN)
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
<Panel id="respond_%s" visibility="%s" active="false" rectAlignment="UpperCenter" offsetXY="0 -20" width="460" height="236"
       color="#0B0F17F5" outline="#5AF0FF" outlineSize="2 2" allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="16 16 14 14" spacing="10" childForceExpandHeight="false">
    <Text fontSize="20" fontStyle="Bold" color="#5AF0FF" preferredHeight="26">RESPONSES?</Text>
    <Text id="respondText_%s" fontSize="15" color="#E6F1FF" preferredHeight="70">-</Text>
    <Text id="respondTimer_%s" fontSize="13" color="#FFB347" preferredHeight="18"></Text>
    <HorizontalLayout spacing="12" preferredHeight="48">
      <Button onClick="ui_respond(%s_no)" color="#00B3A4" textColor="#06130B" fontStyle="Bold" fontSize="16">NO RESPONSE</Button>
      <Button onClick="ui_respond(%s_yes)" color="#DB5454" textColor="#1A0606" fontStyle="Bold" fontSize="16">I HAVE A RESPONSE</Button>
    </HorizontalLayout>
  </VerticalLayout>
</Panel>
<Panel id="undoRespond_%s" visibility="%s" active="false" rectAlignment="UpperCenter" offsetXY="0 -20" width="460" height="120"
       color="#0B0F17F0" outline="#FFB347" outlineSize="2 2" allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="14 14 10 10" spacing="8" childForceExpandHeight="false">
    <Text fontSize="15" color="#E6F1FF" preferredHeight="40">You clicked I HAVE A RESPONSE.
Misclick? Take it back (only until something happens).</Text>
    <Button onClick="ui_undoRespond(%s)" color="#00B3A4" textColor="#06130B" fontStyle="Bold" fontSize="16" preferredHeight="44">NO RESPONSE AFTER ALL</Button>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, c, c, c, c, c, c))
  end
  return table.concat(parts)
end

function Turns.next(color)
  if not isActive(color) or stackBusy(color) then
    return
  end
  local id = Turns.STEPS[turn().stepIndex].id
  if id == "untap" or id == "draw" or id == "cleanup" then
    return   -- these move on by themselves
  end
  -- Combat (combat.lua): NEXT STEP in ATTACK declares the attack first;
  -- in DAMAGE it waits for the damage panel.
  if Combat and Combat.onNext(color) then
    return
  end
  -- Carrying on after a response to END TURN: still end the turn.
  local resume = turn().resume
  requestMove((resume == "end" or resume == "endstep") and resume or "next")
end

-- END STEP tile: go to the end step (after responses) and stop there.
function Turns.toEndStep(color)
  if not isActive(color) or stackBusy(color) then
    return
  end
  local t = turn()
  local id = Turns.STEPS[t.stepIndex].id
  if id == "untap" or id == "draw" or id == "cleanup" then
    return
  end
  if t.stepIndex >= STEP_INDEX["end"] then
    broadcastToColor("You're already in the end step. NEXT STEP or END TURN passes the turn.", color, WARN)
    return
  end
  requestMove("endstep")
end

function Turns.endTurn(color)
  if not isActive(color) or stackBusy(color) then
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
  t.skipTurns = {}
  t.taken = 0
  GameState.data.turnStartOf = {}
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

-- The FIRE SOUND button's label (Fires.setVolume calls this).
function Turns.showFireVolume(name)
  pcall(function() UI.setValue("fireVolumeBtn", "Fire sound: " .. tostring(name)) end)
end

function ui_turnOpt(player, which)
  local c = player.color
  if which == "fireVolume" then
    -- Anyone can change it, game or no game.
    if Fires and Fires.cycleVolume then
      Fires.cycleVolume(c)
    end
    return
  end
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
