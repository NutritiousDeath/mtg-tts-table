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
    NEXT STEP / END TURN (beside the tracker): your turn only (turns.lua)

  Only the seat's own player can use its tiles. Every tile has a tooltip.
  Tile art: assets/mats/action_<name>_<Color>.png (tools/make_mat_art.py).
--]]

Actions = {}

local ART_BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/"
local ART_VERSION = "?v=3"
local TILE_W = 3
local INFO = { 0.75, 0.8, 0.9 }
local WARN = { 1, 0.6, 0.2 }

local ACTIONS = {
  { name = "draw", label = "Draw", tip = "DRAW\nClick: draw 1 card\nRight-click: draw 3 cards" },
  { name = "scry", label = "Scry", tip = "SCRY / SURVEIL\nClick once per card to look at (2 clicks = scry 2).\nOnly you see them. Choose for each card to finish." },
  { name = "mill", label = "Mill", tip = "MILL\nClick: mill 1 card\nRight-click: mill 3 cards" },
  { name = "untap", label = "Untap", tip = "UNTAP\nClick: untap all your tapped permanents" },
  { name = "next", label = "Next step", tip = "NEXT STEP\nYour turn: move to the next step of the turn" },
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
  if playerColor ~= color then
    broadcastToColor("Those are " .. color .. "'s tiles.", playerColor, WARN)
    return false
  end
  return true
end

---------------------------------------------------------------------------
-- The actions themselves
---------------------------------------------------------------------------

function Actions.draw(color, n, reason)
  local drawn = Library.draw(color, n)
  if drawn > 0 then
    log(color .. " draws " .. drawn .. (reason and (" (" .. reason .. ")") or ""))
  end
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
---------------------------------------------------------------------------

local MAX_SCRY = 6
local scry = {}   -- [color] = { choices = { [i] = "top"|"bottom"|"grave" }, count = n }

local CHOICE_TEXT = { top = "KEEP ON TOP", bottom = "TO THE BOTTOM", grave = "TO GRAVEYARD" }

function Actions.xml()
  local parts = {}
  for _, c in ipairs(TableSetup.activeSeats()) do
    local slots = {}
    for i = 1, MAX_SCRY do
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
    <Text fontSize="12" color="#8B98A9" preferredHeight="16">Click SCRY again to look at one more card</Text>
    <HorizontalLayout spacing="12" preferredHeight="420" childForceExpandWidth="false" childAlignment="UpperCenter">]]
      .. table.concat(slots) .. [[
    </HorizontalLayout>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, c))
  end
  return table.concat(parts)
end

local function closeScry(color)
  scry[color] = nil
  UI.setAttribute("scry_" .. color, "active", "false")
end

local function renderScry(color)
  local st = scry[color]
  if st == nil then
    return
  end
  UI.setAttribute("scry_" .. color, "active", "true")
  UI.setAttribute("scry_" .. color, "width", 30 + st.count * 222)
  UI.setValue("scryTitle_" .. color, "SCRY / SURVEIL " .. st.count)
  for i = 1, MAX_SCRY do
    local id = color .. "_" .. i
    if i <= st.count then
      local card = Library.peek(color, i - 1)
      UI.setAttribute("scrySlot_" .. id, "active", "true")
      UI.setValue("scryName_" .. id, card and card.name or "-")
      UI.setAttribute("scryImg_" .. id, "image", card and card.face or "")
      local ch = st.choices[i]
      UI.setValue("scryChoice_" .. id, ch and CHOICE_TEXT[ch] or "CHOOSE")
      UI.setAttribute("scryChoice_" .. id, "color", ch and "#2FBF71" or "#5AF0FF")
    else
      UI.setAttribute("scrySlot_" .. id, "active", "false")
    end
  end
end

-- SCRY tile clicked: open with the top card, or add the next card.
function Actions.openScry(color)
  local total = Library.count(color)
  local st = scry[color]
  if st == nil then
    if total == 0 then
      broadcastToColor("Your library is empty.", color, WARN)
      return
    end
    scry[color] = { choices = {}, count = 1 }
  elseif st.count >= math.min(MAX_SCRY, total) then
    broadcastToColor("That's as many cards as the viewer shows at once.", color, WARN)
    return
  else
    st.count = st.count + 1
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
  slot = tonumber(slot)
  if slot < 1 or slot > st.count then
    return
  end
  st.choices[slot] = choice
  for i = 1, st.count do
    if st.choices[i] == nil then
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
    elseif a.name == "next" then
      Turns.next(color)
    elseif a.name == "endturn" then
      Turns.endTurn(color)
    end
  end
  -- One invisible button over the whole tile: the click area + tooltip.
  Trackers.tileButton(tile, { label = "", click_function = fn, tooltip = a.tip,
    width = 760, height = 1060, color = { 0, 0, 0, 0 }, hover_color = { 1, 1, 1, 0.08 },
    press_color = { 1, 1, 1, 0.18 } }, 0, 0)
end

function Actions.ensure()
  for _, obj in ipairs(getObjectsWithTag("ActionTile")) do
    obj.destruct()
  end
  for key, guid in pairs(tiles()) do
    local obj = getObjectFromGUID(guid)
    if obj then
      obj.destruct()
    end
    tiles()[key] = nil
  end
  for _, color in ipairs(TableSetup.activeSeats()) do
    for _, a in ipairs(ACTIONS) do
      Trackers.spawnTile(color, "act_" .. a.name, a.label .. " (" .. color .. ")",
        ART_BASE .. "mats/action_" .. a.name .. "_" .. color .. ".png" .. ART_VERSION, TILE_W,
        function(guid) tiles()[color .. "|" .. a.name] = guid end,
        function() renderTile(color, a) end,
        "ActionTile")
    end
  end
end

-- Hover text on the tile object itself too (shown by TTS when hovering).
Actions.TIPS = ACTIONS
