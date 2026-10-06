--[[
  actions.lua
  Action tiles in a strip beside each seat's library column, plus the private
  Scry / Surveil viewer.

    DRAW   click: draw 1 · right-click: draw 3
    SCRY   each click shows one more card from the top (2 clicks = scry 2),
           in a viewer only you can see. Per card:
             up arrow / down arrow = scry: keep on top / put on the bottom
             TOP / GRAVEYARD       = surveil: keep on top / to graveyard
           When every card has a choice they all resolve and the viewer
           closes. X cancels.
    MILL   click: mill 1 · right-click: mill 3 (top cards face up to graveyard)
    UNTAP  click: untap every tapped permanent on your battlefield and lands
    TOKENS click: open / close your token search panel (tokens.lua)
    NEXT STEP / END STEP / END TURN (beside the tracker): your turn only (turns.lua)

  Only the seat's own player can use its tiles. Every tile has a tooltip.
  Tile art: assets/mats/action_<name>_<Color>.png (tools/make_mat_art.py).
--]]

Actions = {}

local ART_BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/"
local ART_VERSION = "?v=6"
local TILE_W = 3
local INFO = { 0.75, 0.8, 0.9 }
local WARN = { 1, 0.6, 0.2 }

local ACTIONS = {
  { name = "draw", label = "Draw", tip = "DRAW\nClick: draw 1 card\nRight-click: draw 3 cards" },
  { name = "scry", label = "Scry", tip = "SCRY / SURVEIL\nClick once per card to look at (2 clicks = scry 2).\nOnly you see them. Choose for each card to finish." },
  { name = "mill", label = "Mill", tip = "MILL\nClick: mill 1 card\nRight-click: mill 3 cards" },
  { name = "untap", label = "Untap", tip = "UNTAP\nClick: untap all your tapped permanents" },
  { name = "tokens", label = "Tokens", tip = "TOKENS\nClick: open token search (only you see it).\nFind a token and click it to put it onto your battlefield." },
  { name = "next", label = "Next step", tip = "NEXT STEP\nYour turn: move to the next step of the turn" },
  { name = "endstep", label = "End step", tip = "END STEP\nYour turn: go to the end step and stop there\n(for end step triggers). NEXT STEP or END TURN then passes the turn." },
  { name = "endturn", label = "End turn", tip = "END TURN\nYour turn: skip to the end step\n(from the end step: pass the turn)" },
}

local function tiles()
  GameState.data.table = GameState.data.table or {}
  GameState.data.table.actionTiles = GameState.data.table.actionTiles or {}
  return GameState.data.table.actionTiles
end

local function log(msg, color)
  printToAll("MTG > " .. msg, color or INFO)
end

-- Only the seat's own player may use its tiles.
local function mine(color, playerColor)
  if playerColor ~= color and not GameState.solo() then
    broadcastToColor("Those are " .. color .. "'s tiles.", playerColor, WARN)
    return false
  end
  return true
end

---------------------------------------------------------------------------
-- The actions themselves
---------------------------------------------------------------------------

function Actions.draw(color, n, reason)
  Library.draw(color, n, function(drawn)
    if drawn > 0 then
      log(color .. " draws " .. drawn .. (reason and (" (" .. reason .. ")") or ""))
    end
  end)
end

function Actions.mill(color, n)
  Library.mill(color, n, 0, function(done)
    if done > 0 then
      log(color .. " mills " .. done)
    end
  end)
end

-- Untap every tapped card (turned sideways) on the seat's battlefield and lands.
function Actions.untapAll(color, quiet)
  local s = TableSetup.seat(color)
  local count = 0
  for _, obj in ipairs(getObjects()) do
    if obj.type == "Card" and obj.held_by_color == nil then
      local loc = Zones.regionAt(obj.getPosition())
      if loc.seat == color and (loc.region == "battlefield" or loc.region == "lands") then
        local r = obj.getRotation()
        local diff = ((r.y - s.yaw + 540) % 360) - 180
        if math.abs(diff) > 30 then
          obj.setRotationSmooth({ r.x, s.yaw, r.z }, false, true)
          count = count + 1
        end
      end
    end
  end
  if not quiet or count > 0 then
    log(color .. " untaps " .. count .. " permanent" .. (count == 1 and "" or "s"))
  end
  return count
end

---------------------------------------------------------------------------
-- Scry / Surveil viewer (a screen panel only that player can see)
-- Each click on the SCRY tile adds the next card from the top (click twice =
-- scry 2). Each card gets its own choice; when every shown card has one,
-- they all resolve at once and the viewer closes. X cancels.
-- The viewer shows 6 cards at a time; with more, < > pages through them
-- (6 slots per seat keeps the screen UI small, which keeps loading fast).
---------------------------------------------------------------------------

local MAX_SCRY = 24          -- cards the viewer can hold
local SCRY_COLS = 6          -- cards shown at once; more are on further pages (< >)
local SCRY_CELL_H = 404
local scry = {}   -- [color] = { choices = { [i] = "top"|"bottom"|"grave" }, count = n, page = p }

local CHOICE_TEXT = { top = "KEEP ON TOP", bottom = "TO THE BOTTOM", grave = "TO GRAVEYARD" }

function Actions.xml()
  local parts = {}
  for _, c in ipairs(TableSetup.activeSeats()) do
    local slots = {}
    for i = 1, SCRY_COLS do
      local id = c .. "_" .. i
      local function icon(img, choice, tip)
        return ([[
          <Panel preferredWidth="52" preferredHeight="52">
            <Image image="%s" preserveAspect="true" raycastTarget="false" />
            <Button onClick="ui_scry(%s_%s)" color="#00000000" tooltip="%s" tooltipPosition="Above" />
          </Panel>]]):format(ART_BASE .. img .. ART_VERSION, id, choice, tip)
      end
      table.insert(slots, ([[
      <VerticalLayout id="scrySlot_%s" active="false" preferredWidth="210" spacing="6" childForceExpandHeight="false" childAlignment="UpperCenter">
        <HorizontalLayout spacing="40" preferredHeight="52" childForceExpandWidth="false" childAlignment="MiddleCenter">]]
        .. icon("ui/arrow_up.png", "top", "Scry: keep on top")
        .. icon("ui/arrow_down.png", "bottom", "Scry: put on the bottom")
        .. [[
        </HorizontalLayout>
        <Panel preferredHeight="280" preferredWidth="200">
          <Text id="scryName_%s" fontSize="13" color="#E6F1FF">-</Text>
          <Image id="scryImg_%s" preserveAspect="true" raycastTarget="false" />
        </Panel>
        <Text id="scryChoice_%s" fontSize="13" fontStyle="Bold" color="#5AF0FF" preferredHeight="18">CHOOSE</Text>
        <HorizontalLayout spacing="6" preferredHeight="34">
          <Button onClick="ui_scry(%s_top)" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold" fontSize="13" tooltip="Surveil: keep on top">TOP</Button>
          <Button onClick="ui_scry(%s_grave)" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold" fontSize="13" tooltip="Surveil: put into your graveyard">GRAVEYARD</Button>
        </HorizontalLayout>
      </VerticalLayout>]]):format(id, id, id, id, id, id))
    end
    table.insert(parts, ([[
<Panel id="scry_%s" visibility="%s" active="false"
       rectAlignment="MiddleCenter" offsetXY="0 40" width="250" height="500"
       color="#0B0F17F5" outline="#5AF0FF" outlineSize="2 2"
       allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="14 14 10 12" spacing="8" childForceExpandHeight="false">
    <HorizontalLayout preferredHeight="26" childForceExpandWidth="false">
      <Text id="scryTitle_%s" fontSize="17" fontStyle="Bold" color="#5AF0FF" alignment="MiddleLeft" flexibleWidth="1">SCRY / SURVEIL 1</Text>
      <Button onClick="ui_scry(%s_0_cancel)" preferredWidth="30" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold"
              tooltip="Cancel: leave the cards where they are">X</Button>
    </HorizontalLayout>
    <HorizontalLayout preferredHeight="22" spacing="8" childForceExpandWidth="false">
      <Text fontSize="12" color="#8B98A9" alignment="MiddleLeft" flexibleWidth="1">Click SCRY again to look at one more card</Text>
      <Button id="scryPrev_%s" onClick="ui_scry(%s_0_prev)" preferredWidth="34" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold" tooltip="Previous cards">&lt;</Button>
      <Text id="scryPage_%s" preferredWidth="96" fontSize="12" fontStyle="Bold" color="#E6F1FF">1-6 OF 6</Text>
      <Button id="scryNext_%s" onClick="ui_scry(%s_0_next)" preferredWidth="34" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold" tooltip="More cards">&gt;</Button>
    </HorizontalLayout>
    <GridLayout id="scryGrid_%s" cellSize="210 ]] .. SCRY_CELL_H .. [[" spacing="12 10" constraint="FixedColumnCount"
                constraintCount="]] .. SCRY_COLS .. [[" childAlignment="UpperLeft" preferredHeight="]] .. SCRY_CELL_H .. [[">]]
      .. table.concat(slots) .. [[
    </GridLayout>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, c, c, c, c, c, c, c))
    table.insert(parts, Actions.discardXml(c))
  end
  return table.concat(parts)
end

---------------------------------------------------------------------------
-- Discard to 7 (cleanup step): a private panel showing the hand; pick the
-- extra cards, then Confirm. "No maximum hand size" skips it.
---------------------------------------------------------------------------

local MAX_HAND = 7
local MAX_DISCARD_SLOTS = 16
local discard = {}   -- [color] = { need, order = { {guid,name,face} }, picks = { [guid]=true }, onDone }

function Actions.discardXml(c)
  local slots = {}
  for i = 1, MAX_DISCARD_SLOTS do
    local id = c .. "_" .. i
    table.insert(slots, ([[
<Panel id="dSlot_%s" active="false" color="#1B2333">
  <Text id="dName_%s" fontSize="11" color="#E6F1FF">-</Text>
  <Image id="dImg_%s" preserveAspect="true" raycastTarget="false" />
  <Panel id="dMark_%s" active="false" color="#DB545440" outline="#DB5454" outlineSize="4 4" raycastTarget="false">
    <Panel height="24" rectAlignment="LowerCenter" color="#DB5454" raycastTarget="false">
      <Text fontSize="12" fontStyle="Bold" color="#1A0606">DISCARD</Text>
    </Panel>
  </Panel>
  <Button onClick="ui_discardPick(%s)" color="#00000000" />
</Panel>]]):format(id, id, id, id, id))
  end
  return ([[
<Panel id="discard_%s" visibility="%s" active="false" rectAlignment="LowerCenter" offsetXY="0 230" width="800" height="330"
       color="#0B0F17F5" outline="#DB5454" outlineSize="2 2" allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="16 16 12 12" spacing="8" childForceExpandHeight="false">
    <Text fontSize="18" fontStyle="Bold" color="#DB5454" alignment="MiddleLeft" preferredHeight="24">CLEANUP · DISCARD TO 7</Text>
    <Text id="dText_%s" fontSize="14" color="#E6F1FF" alignment="MiddleLeft" preferredHeight="20">Pick cards to discard.</Text>
    <GridLayout cellSize="92 128" spacing="6 6" constraint="FixedColumnCount" constraintCount="8" childAlignment="UpperCenter" preferredHeight="262">]]
    .. table.concat(slots) .. [[</GridLayout>
    <HorizontalLayout spacing="10" preferredHeight="40">
      <Button onClick="ui_discardConfirm(%s)" color="#DB5454" textColor="#1A0606" fontStyle="Bold">DISCARD</Button>
      <Button onClick="ui_discardSkip(%s)" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold"
              tooltip="You have no maximum hand size (Reliquary Tower, Thought Vessel...)">NO MAXIMUM HAND SIZE</Button>
    </HorizontalLayout>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, c, c)
end

local function handCards(color)
  local out = {}
  for _, obj in ipairs(Player[color].getHandObjects() or {}) do
    if obj.type == "Card" then
      table.insert(out, obj)
    end
  end
  return out
end

local function renderDiscard(color)
  local st = discard[color]
  if st == nil then
    UI.setAttribute("discard_" .. color, "active", "false")
    return
  end
  local picked = 0
  for _ in pairs(st.picks) do picked = picked + 1 end
  UI.setAttribute("discard_" .. color, "active", "true")
  local rows = math.ceil(math.min(#st.order, MAX_DISCARD_SLOTS) / 8)
  UI.setAttribute("discard_" .. color, "height", 140 + rows * 134)
  UI.setValue("dText_" .. color, "You have " .. #st.order .. " cards: pick " .. st.need .. " to discard.   "
    .. picked .. " / " .. st.need)
  for i = 1, MAX_DISCARD_SLOTS do
    local id = color .. "_" .. i
    local e = st.order[i]
    if e then
      UI.setAttribute("dSlot_" .. id, "active", "true")
      UI.setValue("dName_" .. id, e.name)
      UI.setAttribute("dImg_" .. id, "image", e.face or "")
      UI.setAttribute("dMark_" .. id, "active", st.picks[e.guid] and "true" or "false")
    else
      UI.setAttribute("dSlot_" .. id, "active", "false")
    end
  end
end

-- Called by the turn engine in cleanup. onDone runs when the hand is legal.
function Actions.cleanupDiscard(color, onDone)
  local hand = handCards(color)
  local need = #hand - MAX_HAND
  if need <= 0 or (GameState.solo() and not Player[color].seated) then
    onDone()
    return
  end
  local order = {}
  for _, card in ipairs(hand) do
    local custom = card.getCustomObject()
    table.insert(order, { guid = card.getGUID(), name = card.getName(), face = custom and custom.face or nil })
  end
  discard[color] = { need = need, order = order, picks = {}, onDone = onDone }
  broadcastToAll(color .. " has " .. #hand .. " cards and must discard " .. need .. ".", WARN)
  renderDiscard(color)
end

local function finishDiscard(color)
  local st = discard[color]
  discard[color] = nil
  renderDiscard(color)
  for _, e in ipairs(st.order) do
    local card = getObjectFromGUID(e.guid)
    if card then card.highlightOff() end
  end
  if st.onDone then st.onDone() end
end

function ui_discardPick(player, arg)
  local color, i = tostring(arg):match("^(%a+)_(%d+)$")
  local st = color and discard[color]
  if st == nil or player.color ~= color then
    return
  end
  local e = st.order[tonumber(i)]
  if e == nil then
    return
  end
  local picked = 0
  for _ in pairs(st.picks) do picked = picked + 1 end
  local card = getObjectFromGUID(e.guid)
  if st.picks[e.guid] then
    st.picks[e.guid] = nil
    if card then card.highlightOff() end
  elseif picked < st.need then
    st.picks[e.guid] = true
    if card then card.highlightOn({ 0.86, 0.33, 0.33 }) end
  else
    broadcastToColor("You've picked " .. picked .. ". Click a picked card to un-pick it.", color, WARN)
    return
  end
  renderDiscard(color)
end

function ui_discardConfirm(player, color)
  local st = discard[color]
  if st == nil or player.color ~= color then
    return
  end
  local chosen = {}
  for _, e in ipairs(st.order) do
    if st.picks[e.guid] then
      table.insert(chosen, getObjectFromGUID(e.guid))
    end
  end
  if #chosen ~= st.need then
    broadcastToColor("Pick exactly " .. st.need .. " card" .. (st.need == 1 and "" or "s") .. " first.", color, WARN)
    return
  end
  local s = TableSetup.seat(color)
  local names = {}
  for i, card in ipairs(chosen) do
    table.insert(names, card.getName())
    card.highlightOff()
    card.setPosition(TableSetup.slot(color, "graveyard", 2 + i * 0.3))
    card.setRotation({ 0, s.yaw, 0 })
    Library.toGraveyard(color, card)
  end
  log(color .. " discards " .. table.concat(names, ", ") .. " (cleanup)")
  finishDiscard(color)
end

function ui_discardSkip(player, color)
  if discard[color] == nil or player.color ~= color then
    return
  end
  log(color .. " keeps " .. #discard[color].order .. " cards (no maximum hand size)")
  finishDiscard(color)
end

local function closeScry(color)
  scry[color] = nil
  UI.setAttribute("scry_" .. color, "active", "false")
end

local function pages(st)
  return math.max(1, math.ceil(st.count / SCRY_COLS))
end

local function renderScry(color)
  local st = scry[color]
  if st == nil then
    return
  end
  st.page = math.max(1, math.min(st.page or 1, pages(st)))
  local first = (st.page - 1) * SCRY_COLS          -- cards before this page
  local shown = math.min(SCRY_COLS, st.count - first)
  local cols = math.min(st.count, SCRY_COLS)
  UI.setAttribute("scry_" .. color, "active", "true")
  UI.setAttribute("scry_" .. color, "width", math.max(470, 30 + cols * 222))
  UI.setAttribute("scry_" .. color, "height", 104 + SCRY_CELL_H)
  UI.setValue("scryTitle_" .. color, "SCRY / SURVEIL " .. st.count)
  local paged = st.count > SCRY_COLS
  for _, part in ipairs({ "scryPrev_", "scryPage_", "scryNext_" }) do
    UI.setAttribute(part .. color, "active", paged and "true" or "false")
  end
  UI.setValue("scryPage_" .. color, (first + 1) .. "-" .. (first + shown) .. " OF " .. st.count)
  for s = 1, SCRY_COLS do
    local id = color .. "_" .. s
    local i = first + s
    if i <= st.count then
      local card = Library.peek(color, i - 1)
      UI.setAttribute("scrySlot_" .. id, "active", "true")
      UI.setValue("scryName_" .. id, card and card.name or "-")
      UI.setAttribute("scryImg_" .. id, "image", card and card.face or "")
      local ch = st.choices[i]
      UI.setValue("scryChoice_" .. id, (i .. ". ") .. (ch and CHOICE_TEXT[ch] or "CHOOSE"))
      UI.setAttribute("scryChoice_" .. id, "color", ch and "#2FBF71" or "#5AF0FF")
    else
      UI.setAttribute("scrySlot_" .. id, "active", "false")
    end
  end
end

-- SCRY tile clicked: open with the top card, or add the next card.
function Actions.openScry(color)
  if scry[color] == nil and Library.find(color) and Library.count(color) > 0 then
    -- Join any card left on top of the library into it first, so the viewer
    -- shows the real top card.
    local ready = false
    Library.consolidate(color, function() ready = true end)
    if not ready then
      Wait.condition(function() Actions.openScry(color) end, function() return ready end, 5)
      return
    end
  end
  local total = Library.count(color)
  local st = scry[color]
  if st == nil then
    if total == 0 then
      broadcastToColor("Your library is empty.", color, WARN)
      return
    end
    scry[color] = { choices = {}, count = 1, page = 1 }
  elseif st.count >= math.min(MAX_SCRY, total) then
    broadcastToColor(st.count >= total and "That's every card in your library."
      or ("The viewer holds up to " .. MAX_SCRY .. " cards at once: choose for these, then scry again."), color, WARN)
    return
  else
    st.count = st.count + 1
    st.page = pages(st)   -- show the page with the new card
  end
  renderScry(color)
end

local function resolveScry(color)
  local st = scry[color]
  local counts = { top = 0, bottom = 0, grave = 0 }
  for i = 1, st.count do
    counts[st.choices[i]] = counts[st.choices[i]] + 1
  end
  local choices = {}
  for i = 1, st.count do
    choices[i] = st.choices[i]
  end
  closeScry(color)
  Library.arrangeTop(color, choices, function()
    local bits = {}
    if counts.top > 0 then table.insert(bits, counts.top .. " on top") end
    if counts.bottom > 0 then table.insert(bits, counts.bottom .. " on the bottom") end
    if counts.grave > 0 then table.insert(bits, counts.grave .. " into the graveyard") end
    log(color .. " looked at " .. #choices .. " card" .. (#choices == 1 and "" or "s") .. ": " .. table.concat(bits, ", "))
  end)
end

-- Viewer buttons: "<Color>_<slot>_<choice>".
function ui_scry(player, arg)
  local color, slot, choice = tostring(arg):match("^(%a+)_(%d+)_(%a+)$")
  if color == nil or player.color ~= color or scry[color] == nil then
    return
  end
  if choice == "cancel" then
    closeScry(color)
    return
  end
  local st = scry[color]
  if choice == "prev" or choice == "next" then
    st.page = (st.page or 1) + (choice == "next" and 1 or -1)
    renderScry(color)
    return
  end
  -- Buttons are per slot on the page; turn that into the card's position.
  local i = ((st.page or 1) - 1) * SCRY_COLS + tonumber(slot)
  if i < 1 or i > st.count then
    return
  end
  st.choices[i] = choice
  -- Every card on this page chosen: go to the first page that still needs one.
  local pageDone = true
  local first = ((st.page or 1) - 1) * SCRY_COLS
  for k = first + 1, math.min(first + SCRY_COLS, st.count) do
    if st.choices[k] == nil then
      pageDone = false
    end
  end
  for k = 1, st.count do
    if st.choices[k] == nil then
      if pageDone then
        st.page = math.ceil(k / SCRY_COLS)
      end
      renderScry(color)
      return
    end
  end
  resolveScry(color)
end

---------------------------------------------------------------------------
-- Tiles
---------------------------------------------------------------------------

local function renderTile(color, a)
  local guid = tiles()[color .. "|" .. a.name]
  local tile = guid and getObjectFromGUID(guid)
  if tile == nil then
    return
  end
  tile.clearButtons()
  local fn = "act_" .. color .. "_" .. a.name
  _G[fn] = function(obj, playerColor, alt)
    if not mine(color, playerColor) then
      return
    end
    if a.name == "draw" then
      Actions.draw(color, alt and 3 or 1)
    elseif a.name == "mill" then
      Actions.mill(color, alt and 3 or 1)
    elseif a.name == "scry" then
      Actions.openScry(color)
    elseif a.name == "untap" then
      Actions.untapAll(color)
    elseif a.name == "tokens" then
      Tokens.toggle(color)
    elseif a.name == "next" then
      Turns.next(color)
    elseif a.name == "endturn" then
      Turns.endTurn(color)
    elseif a.name == "endstep" then
      Turns.toEndStep(color)
    end
  end
  -- One invisible button over the whole tile: the click area + tooltip.
  Trackers.tileButton(tile, { label = "", click_function = fn, tooltip = a.tip,
    width = 1460, height = 2060, color = { 0, 0, 0, 0 }, hover_color = { 1, 1, 1, 0.08 },
    press_color = { 1, 1, 1, 0.18 } }, 0, 0)
end

function Actions.ensure()
  local wanted = {}
  for _, color in ipairs(TableSetup.activeSeats()) do
    for _, a in ipairs(ACTIONS) do
      table.insert(wanted, { key = color .. "|" .. a.name, color = color, region = "act_" .. a.name,
        name = a.label .. " (" .. color .. ")",
        url = ART_BASE .. "mats/action_" .. a.name .. "_" .. color .. ".png" .. ART_VERSION, width = TILE_W,
        draw = function() renderTile(color, a) end })
    end
  end
  Trackers.syncTiles("ActionTile", { { registry = tiles(), wanted = wanted } })
end

-- Hover text on the tile object itself too (shown by TTS when hovering).
Actions.TIPS = ACTIONS
