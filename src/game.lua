--[[
  game.lua
  Game setup and mulligans (Phase 3).

  "Start Game" (top left) opens a panel:
    - First player: Random, or pick a seat.
    - Free first mulligan (Commander rule): on by default.
    - Start: for every seated player who has a library at their seat
        1. cards in their hand, battlefield, lands, graveyard and exile go
           back into their library; commanders go back to the command zone
        2. life, poison, commander damage and loss flags reset
        3. the library is shuffled and 7 cards are dealt
        4. everyone gets their own mulligan panel (only they can see it)

  London mulligan, everyone deciding at the same time:
    - Mulligan: hand goes back, library shuffles, a fresh 7 is dealt.
    - Keep: if you mulliganed, you put that many cards on the bottom (one
      fewer when the free first mulligan is on). Each card in your hand gets a
      button in the mulligan panel and a right-click item ("Mulligan: bottom
      / undo"); picked cards glow green in your hand. Then Confirm.
    - When every player has kept, the starting player is announced and turn 1
      is recorded in the game state (Phase 4 runs the turn itself).

  State lives in GameState.data.setup so a save mid-mulligan still knows who
  has kept.
--]]

GameFlow = {}

local HAND_SIZE = 7
local MAX_PICK_SLOTS = 10   -- card buttons in the mulligan panel
local PICK_GLOW = { 0.35, 0.95, 0.6 }
local INFO = { 0.7, 0.85, 1 }
local GOOD = { 0.55, 0.9, 0.6 }
local WARN = { 1, 0.6, 0.2 }

pcall(function() math.randomseed(os.time()) end)

local function setup()
  local d = GameState.data
  if d.setup == nil then
    d.setup = {
      firstChoice = "Random",
      freeMulligan = GameState.format().freeFirstMulligan ~= false,
      phase = nil,          -- "mulligan" while players are deciding
      participants = {},
      picks = {},           -- [color] = { [guid] = true } cards picked for the bottom
    }
  end
  return d.setup
end

local function isParticipant(color)
  for _, c in ipairs(setup().participants) do
    if c == color then
      return true
    end
  end
  return false
end

-- How many cards a player bottoms if they keep now.
local function bottomCount(color)
  local p = GameState.player(color)
  local n = p.mulligans or 0
  if setup().freeMulligan and n > 0 then
    n = n - 1
  end
  return math.min(n, HAND_SIZE)
end

---------------------------------------------------------------------------
-- UI (built into the Global XML by ui.lua)
---------------------------------------------------------------------------

local SEAT_HEX = { White = "#C7CCD9", Red = "#DB5454", Green = "#52C26B", Blue = "#5294F2" }
local OFF = "#1B2333"
local ON = "#00B3A4"

function GameFlow.xml()
  local seatButtons = {}
  table.insert(seatButtons, '<Button id="first_Random" onClick="ui_firstPlayer(Random)" color="' .. ON .. '">Random</Button>')
  for _, color in ipairs(TableSetup.activeSeats()) do
    table.insert(seatButtons, '<Button id="first_' .. color .. '" onClick="ui_firstPlayer(' .. color
      .. ')" color="' .. OFF .. '" textColor="' .. SEAT_HEX[color] .. '">' .. color .. '</Button>')
  end

  local mull = {}
  for _, color in ipairs(TableSetup.activeSeats()) do
    -- One slot per card: the name (shown if the picture can't load), the card
    -- picture over it, a green "BOTTOM" mark, and a clear button on top.
    local slots = {}
    for i = 1, MAX_PICK_SLOTS do
      local id = color .. "_" .. i
      table.insert(slots, ([[
<Panel id="mullSlot_%s" active="false" color="#1B2333">
  <Text id="mullName_%s" fontSize="12" color="#E6F1FF" alignment="MiddleCenter">-</Text>
  <Image id="mullImg_%s" preserveAspect="true" raycastTarget="false" />
  <Panel id="mullMark_%s" active="false" color="#2FBF7140" outline="#2FBF71" outlineSize="4 4" raycastTarget="false">
    <Panel height="26" rectAlignment="LowerCenter" color="#2FBF71" raycastTarget="false">
      <Text fontSize="13" fontStyle="Bold" color="#06130B">BOTTOM</Text>
    </Panel>
  </Panel>
  <Button id="mullCard_%s" onClick="ui_mullPick(%s)" color="#00000000" />
</Panel>]]):format(id, id, id, id, id, id))
    end
    table.insert(mull, ([[
<Panel id="mull_%s" visibility="%s" active="false"
       rectAlignment="LowerCenter" offsetXY="0 230" width="520" height="170"
       color="#0B0F17F5" outline="%s" outlineSize="2 2"
       allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="18 18 14 14" spacing="10" childForceExpandHeight="false">
    <HorizontalLayout preferredHeight="26" childForceExpandWidth="false" spacing="10">
      <Text fontSize="20" fontStyle="Bold" color="%s" alignment="MiddleLeft" preferredWidth="160">MULLIGAN</Text>
      <Text id="mullCount_%s" fontSize="14" color="#8B98A9" alignment="MiddleRight" flexibleWidth="1">Opening hand</Text>
    </HorizontalLayout>
    <Text id="mullText_%s" fontSize="15" color="#E6F1FF" alignment="MiddleLeft" preferredHeight="40">Mulligan</Text>
    <GridLayout id="mullCards_%s" active="false" cellSize="100 140" spacing="8 8"
                constraint="FixedColumnCount" constraintCount="7" childAlignment="MiddleCenter" preferredHeight="140">]] .. table.concat(slots) .. [[</GridLayout>
    <HorizontalLayout spacing="10" preferredHeight="42">
      <Button id="mullKeep_%s" onClick="ui_mullKeep(%s)" color="#00B3A4" textColor="#06130B" fontStyle="Bold" fontSize="16">KEEP</Button>
      <Button id="mullMull_%s" onClick="ui_mullMulligan(%s)" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold" fontSize="16">MULLIGAN</Button>
      <Button id="mullConfirm_%s" onClick="ui_mullConfirm(%s)" color="#00B3A4" textColor="#06130B" fontStyle="Bold" fontSize="16" active="false">CONFIRM BOTTOM</Button>
    </HorizontalLayout>
  </VerticalLayout>
</Panel>
]]):format(color, color, SEAT_HEX[color], SEAT_HEX[color], color, color, color, color, color, color, color, color, color))
  end

  return [[
<Button id="startToggle"
        onClick="ui_toggleStart"
        rectAlignment="UpperLeft"
        offsetXY="20 -70"
        width="150" height="40"
        fontStyle="Bold"
        color="#3B5BDB">Start Game</Button>

<Panel id="startPanel"
       active="false"
       width="560" height="300"
       color="#0D1117F2"
       outline="#3B5BDB" outlineSize="2 2"
       allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="16 16 16 16" spacing="10" childForceExpandHeight="false">
    <Text fontSize="22" fontStyle="Bold" alignment="MiddleLeft" preferredHeight="32">Start Game</Text>
    <Text fontSize="13" alignment="MiddleLeft" preferredHeight="36" color="#8B98A9">Every seated player with a deck joins. Cards in hands and on the battlefield, graveyard and exile go back into their owner's library; commanders return to the command zone. Life resets to 40.</Text>
    <Text fontSize="15" alignment="MiddleLeft" preferredHeight="22">First player</Text>
    <HorizontalLayout spacing="8" preferredHeight="36">]] .. table.concat(seatButtons) .. [[</HorizontalLayout>
    <Toggle id="freeMull" onValueChanged="ui_freeMulligan" isOn="true" preferredHeight="28" textColor="#E6F1FF">Free first mulligan (Commander)</Toggle>
    <HorizontalLayout spacing="10" preferredHeight="44">
      <Button onClick="ui_startGame" color="#3B5BDB" fontStyle="Bold">Start</Button>
      <Button onClick="ui_toggleStart">Close</Button>
    </HorizontalLayout>
  </VerticalLayout>
</Panel>
]] .. table.concat(mull)
end

-- Bring the panels in line with the saved state (after the XML is (re)built).
function GameFlow.refreshUI()
  local s = setup()
  for _, color in ipairs(TableSetup.activeSeats()) do
    UI.setAttribute("first_" .. color, "color", s.firstChoice == color and ON or OFF)
  end
  UI.setAttribute("first_Random", "color", s.firstChoice == "Random" and ON or OFF)
  UI.setAttribute("freeMull", "isOn", s.freeMulligan and "true" or "false")
  for _, color in ipairs(TableSetup.activeSeats()) do
    GameFlow.renderMulligan(color)
  end
end

function GameFlow.renderMulligan(color)
  local s = setup()
  local p = GameState.player(color)
  local show = s.phase == "mulligan" and isParticipant(color) and p and not p.hasKept
  UI.setAttribute("mull_" .. color, "active", show and "true" or "false")
  if not show then
    return
  end
  local n = p.mulligans or 0
  local bottom = bottomCount(color)
  local picking = s.picks[color] ~= nil
  local order = picking and s.pickOrder and s.pickOrder[color] or {}
  local plural = bottom == 1 and "" or "s"

  local count
  if n == 0 then
    count = "Opening hand"
  else
    count = n .. " mulligan" .. (n == 1 and "" or "s")
      .. ((s.freeMulligan and n >= 1) and " (first one free)" or "")
  end
  UI.setValue("mullCount_" .. color, count)

  local text
  if picking then
    local picked = 0
    for _ in pairs(s.picks[color]) do picked = picked + 1 end
    text = "Click " .. bottom .. " card" .. plural .. " to put on the bottom.   <b>" .. picked .. " / " .. bottom .. "</b>"
  elseif n == 0 then
    text = "Keep these 7, or shuffle back and draw a new 7?"
  else
    text = "Keeping now puts " .. bottom .. " card" .. plural .. " on the bottom of your library."
  end
  UI.setValue("mullText_" .. color, text)

  UI.setAttribute("mullKeep_" .. color, "active", picking and "false" or "true")
  UI.setAttribute("mullMull_" .. color, "active", picking and "false" or "true")
  UI.setAttribute("mullConfirm_" .. color, "active", picking and "true" or "false")
  UI.setAttribute("mullCards_" .. color, "active", picking and "true" or "false")

  -- Panel size: wide enough for a row of cards while picking.
  local rows = math.max(1, math.ceil(#order / 7))
  UI.setAttribute("mullCards_" .. color, "preferredHeight", rows * 140 + (rows - 1) * 8)
  UI.setAttribute("mull_" .. color, "width", picking and 800 or 520)
  UI.setAttribute("mull_" .. color, "height", picking and (170 + rows * 148) or 170)

  for i = 1, MAX_PICK_SLOTS do
    local id = color .. "_" .. i
    local entry = order[i]
    if entry then
      local on = s.picks[color][entry.guid] == true
      UI.setAttribute("mullSlot_" .. id, "active", "true")
      UI.setValue("mullName_" .. id, entry.name)
      UI.setAttribute("mullImg_" .. id, "image", entry.face or "")
      UI.setAttribute("mullMark_" .. id, "active", on and "true" or "false")
      UI.setAttribute("mullCard_" .. id, "tooltip", entry.name)
    else
      UI.setAttribute("mullSlot_" .. id, "active", "false")
    end
  end
end

---------------------------------------------------------------------------
-- Starting
---------------------------------------------------------------------------

local function resetPlayer(color)
  local p = GameState.player(color)
  local f = GameState.format()
  p.life = f.startingLife
  p.poison = 0
  p.commanderDamage = {}
  p.eliminated = false
  p.lossFlag = nil
  p.lossDismissed = nil
  p.mulligans = 0
  p.hasKept = false
  p.commanderTax = { 0, 0 }
end

local function returnCommanders(color)
  local p = GameState.player(color)
  local s = TableSetup.seat(color)
  for i, guid in pairs(p.commanders or {}) do
    local obj = getObjectFromGUID(guid)
    -- Commander i goes back to command zone i (2 = partner).
    local pos = TableSetup.slot(color, "command" .. math.min(i, 2), 2)
    if obj and pos then
      obj.setPositionSmooth(pos, false, true)
      obj.setRotationSmooth({ 0, s.yaw, 0 }, false, true)
    end
  end
end

local function deal(color)
  local lib = Library.find(color)
  if lib == nil then
    broadcastToAll(color .. " has no library to draw from.", WARN)
    return
  end
  lib.shuffle()
  Wait.time(function()
    local l = Library.find(color)
    if l then
      l.deal(HAND_SIZE, color)
    end
  end, 0.6)
end

function GameFlow.start(byColor)
  local s = setup()
  local players, skipped = {}, {}
  for _, color in ipairs(TableSetup.activeSeats()) do
    if Player[color].seated then
      if Library.find(color) then
        table.insert(players, color)
      else
        table.insert(skipped, color)
      end
    end
  end
  if #players == 0 then
    broadcastToColor("Nobody seated has a deck in their library area yet. Import a deck first.", byColor, WARN)
    return
  end

  s.participants = players
  s.picks = {}
  s.phase = "mulligan"
  GameState.data.started = false
  GameState.data.stack = {}

  -- Starting player.
  local first = s.firstChoice
  if first == "Random" or not isParticipant(first) then
    first = players[math.random(#players)]
  end
  GameState.data.turn = { number = 0, activeSeat = nil, startingSeat = first, stepIndex = nil }
  Turns.render()   -- hides the turn bar until everyone has kept

  for _, color in ipairs(GameState.SEATS) do
    resetPlayer(color)
  end
  Trackers.renderAll()

  for _, color in ipairs(players) do
    local back = Library.gatherTable(color)
    -- Clear selection buttons left from a previous mulligan.
    for _, obj in ipairs(back) do
      if obj.type == "Card" then obj.clearButtons() obj.highlightOff() end
    end
    Library.returnCards(color, back)
    returnCommanders(color)
  end

  broadcastToAll("New game: " .. table.concat(players, ", ") .. ". " .. first .. " goes first."
    .. (s.freeMulligan and " First mulligan is free." or ""), GOOD)
  for _, color in ipairs(skipped) do
    broadcastToAll(color .. " is seated but has no deck at their seat, so they're not in this game.", WARN)
  end

  UI.hide("startPanel")
  -- Let returned cards settle into the libraries before shuffling.
  Wait.time(function()
    for _, color in ipairs(players) do
      deal(color)
    end
    Wait.time(function()
      for _, color in ipairs(players) do
        GameFlow.renderMulligan(color)
      end
    end, 1)
  end, 1)
end

---------------------------------------------------------------------------
-- Mulligans
---------------------------------------------------------------------------

local function handCards(color)
  local out = {}
  for _, obj in ipairs(Player[color].getHandObjects() or {}) do
    if obj.type == "Card" then
      table.insert(out, obj)
    end
  end
  return out
end

local function allKept()
  for _, color in ipairs(setup().participants) do
    if not GameState.player(color).hasKept then
      return false
    end
  end
  return true
end

local function finishMulligans()
  local s = setup()
  s.phase = nil
  local d = GameState.data
  d.started = true
  broadcastToAll("Everyone has kept. " .. d.turn.startingSeat .. " takes the first turn.", GOOD)
  Events.emit("gameStarted", { first = d.turn.startingSeat, players = s.participants })
end

local function kept(color)
  local p = GameState.player(color)
  p.hasKept = true
  setup().picks[color] = nil
  GameFlow.renderMulligan(color)
  if allKept() then
    finishMulligans()
  end
end

function GameFlow.mulligan(color)
  local s = setup()
  local p = GameState.player(color)
  if s.phase ~= "mulligan" or not isParticipant(color) or p.hasKept or s.picks[color] then
    return
  end
  p.mulligans = (p.mulligans or 0) + 1
  local free = s.freeMulligan and p.mulligans == 1
  broadcastToAll(color .. " mulligans" .. (free and " (free)" or "") .. ".", INFO)
  Library.returnCards(color, handCards(color))
  UI.setAttribute("mull_" .. color, "active", "false")
  Wait.time(function()
    deal(color)
    Wait.time(function() GameFlow.renderMulligan(color) end, 1)
  end, 0.6)
end

-- Picked cards glow green in the hand.
local function markCard(card, picked)
  if picked then
    card.highlightOn(PICK_GLOW)
  else
    card.highlightOff()
  end
end

-- Right-click menus work on cards in a hand (buttons there don't get
-- clicks), so each hand card gets a menu item while its owner is picking.
local function addPickMenu(card, color)
  local guid = card.getGUID()
  card.addContextMenuItem("Mulligan: bottom / undo", function(playerColor)
    if playerColor ~= color then
      broadcastToColor("Only " .. color .. " can pick cards from their own hand.", playerColor, WARN)
      return
    end
    GameFlow.togglePickGuid(color, guid)
  end)
end

-- Take the mulligan item off a card again (its counter menu is rebuilt).
local function removePickMenu(card)
  if card == nil or card.isDestroyed() then
    return
  end
  card.highlightOff()
  card.clearContextMenu()
  Counters.setup(card)
end

function GameFlow.keep(color)
  local s = setup()
  local p = GameState.player(color)
  if s.phase ~= "mulligan" or not isParticipant(color) or p.hasKept or s.picks[color] then
    return
  end
  local bottom = bottomCount(color)
  if bottom == 0 then
    broadcastToAll(color .. " keeps " .. #handCards(color) .. ".", INFO)
    kept(color)
    return
  end
  s.picks[color] = {}
  s.pickOrder = s.pickOrder or {}
  local order = {}
  for _, card in ipairs(handCards(color)) do
    if #order < MAX_PICK_SLOTS then
      local custom = card.getCustomObject()
      table.insert(order, { guid = card.getGUID(), name = card.getName(), face = custom and custom.face or nil })
    end
  end
  s.pickOrder[color] = order
  for _, card in ipairs(handCards(color)) do
    addPickMenu(card, color)
  end
  GameFlow.renderMulligan(color)
end

-- A card name in the mulligan panel was clicked.
function GameFlow.togglePick(color, index)
  local s = setup()
  local entry = s.pickOrder and s.pickOrder[color] and s.pickOrder[color][index]
  if entry then
    GameFlow.togglePickGuid(color, entry.guid)
  end
end

-- Pick or un-pick a card (from the panel or the card's right-click menu).
function GameFlow.togglePickGuid(color, guid)
  local s = setup()
  local picks = s.picks[color]
  if picks == nil then
    return
  end
  local count = 0
  for _ in pairs(picks) do count = count + 1 end
  if picks[guid] then
    picks[guid] = nil
  elseif count < bottomCount(color) then
    picks[guid] = true
  else
    broadcastToColor("You've already picked " .. count .. ". Click a picked card to un-pick it.", color, WARN)
    return
  end
  local card = getObjectFromGUID(guid)
  if card then
    markCard(card, picks[guid] == true)
  end
  GameFlow.renderMulligan(color)
end

function GameFlow.confirmBottom(color)
  local s = setup()
  local picks = s.picks[color]
  if picks == nil then
    return
  end
  local bottom = bottomCount(color)
  local chosen = {}
  for _, card in ipairs(handCards(color)) do
    if picks[card.getGUID()] then
      table.insert(chosen, card)
    end
  end
  if #chosen ~= bottom then
    broadcastToColor("Pick exactly " .. bottom .. " card" .. (bottom == 1 and "" or "s") .. " first.", color, WARN)
    return
  end
  broadcastToAll(color .. " keeps, putting " .. bottom .. " on the bottom.", INFO)
  for _, card in ipairs(handCards(color)) do
    if not picks[card.getGUID()] then
      removePickMenu(card)
    end
  end
  for _, card in ipairs(chosen) do
    card.highlightOff()
  end
  Library.putOnBottom(color, chosen)
  kept(color)
end

-- After a reload mid-mulligan, re-light the picked cards.
function GameFlow.restore()
  local s = setup()
  if s.phase ~= "mulligan" then
    return
  end
  for color, picks in pairs(s.picks) do
    for _, card in ipairs(handCards(color)) do
      markCard(card, picks[card.getGUID()] == true)
      addPickMenu(card, color)
    end
  end
end

-- A card can be dragged out of the hand while picking: forget its pick.
Events.on("cardMoved", function(d)
  local s = GameState.data and GameState.data.setup
  if s == nil or s.picks == nil or d.card == nil then
    return
  end
  if d.from and d.from.region == "hand" and s.picks[d.from.seat]
      and not (d.to and d.to.region == "hand" and d.to.seat == d.from.seat) then
    s.picks[d.from.seat][d.card.getGUID()] = nil
    removePickMenu(d.card)
    GameFlow.renderMulligan(d.from.seat)
  end
end)

---------------------------------------------------------------------------
-- XML handlers
---------------------------------------------------------------------------

local startOpen = false

function ui_toggleStart(player)
  startOpen = not startOpen
  if startOpen then
    UI.show("startPanel")
    GameFlow.refreshUI()
  else
    UI.hide("startPanel")
  end
end

function ui_firstPlayer(player, choice)
  setup().firstChoice = choice
  GameFlow.refreshUI()
end

function ui_freeMulligan(player, value)
  setup().freeMulligan = (value == true or value == "True" or value == "true")
end

function ui_startGame(player)
  if not TableSetup.isActive(player.color) then
    broadcastToColor("Take a seat at the table to start the game.", player.color, WARN)
    return
  end
  startOpen = false
  GameFlow.start(player.color)
end

function ui_mullKeep(player, color)
  if player.color == color then GameFlow.keep(color) end
end

function ui_mullMulligan(player, color)
  if player.color == color then GameFlow.mulligan(color) end
end

function ui_mullPick(player, arg)
  local color, index = tostring(arg):match("^(%a+)_(%d+)$")
  if color and player.color == color then
    GameFlow.togglePick(color, tonumber(index))
  end
end

function ui_mullConfirm(player, color)
  if player.color == color then GameFlow.confirmBottom(color) end
end
