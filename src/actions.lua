--[[
  actions.lua
  Action tiles in a strip beside each seat's library column, plus the private
  Scry / Surveil viewer.

    DRAW   click: draw 1 · right-click: draw 3
    SCRY   click: look at the top card (only you see it) in the viewer:
             up arrow    = keep it on top (then shows the next card)
             down arrow  = put it on the bottom
             TOP         = surveil: keep it on top (next card)
             GRAVEYARD   = surveil: put it into your graveyard
             DONE        = close
    MILL   click: mill 1 · right-click: mill 3 (top cards face up to graveyard)
    UNTAP  click: untap every tapped permanent on your battlefield and lands

  Only the seat's own player can use its tiles. Every tile has a tooltip.
  Tile art: assets/mats/action_<name>_<Color>.png (tools/make_mat_art.py).
--]]

Actions = {}

local ART_BASE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/"
local ART_VERSION = "?v=1"
local TILE_W = 3
local INFO = { 0.75, 0.8, 0.9 }
local WARN = { 1, 0.6, 0.2 }

local ACTIONS = {
  { name = "draw", label = "Draw", tip = "DRAW\nClick: draw 1 card\nRight-click: draw 3 cards" },
  { name = "scry", label = "Scry", tip = "SCRY / SURVEIL\nClick: look at the top card of your library (only you see it)" },
  { name = "mill", label = "Mill", tip = "MILL\nClick: mill 1 card\nRight-click: mill 3 cards" },
  { name = "untap", label = "Untap", tip = "UNTAP\nClick: untap all your tapped permanents" },
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
---------------------------------------------------------------------------

local scry = {}   -- [color] = { depth = cards already kept on top }

function Actions.xml()
  local parts = {}
  for _, color in ipairs(TableSetup.activeSeats()) do
    local c = color
    local function iconButton(id, img, onClick, tip)
      return ([[
      <Panel id="%s" preferredWidth="64" preferredHeight="64">
        <Image image="%s" preserveAspect="true" raycastTarget="false" />
        <Button onClick="%s" color="#00000000" tooltip="%s" tooltipPosition="Above" />
      </Panel>]]):format(id, ART_BASE .. img .. ART_VERSION, onClick, tip)
    end
    table.insert(parts, ([[
<Panel id="scry_%s" visibility="%s" active="false"
       rectAlignment="MiddleRight" offsetXY="-40 0" width="330" height="610"
       color="#0B0F17F5" outline="#5AF0FF" outlineSize="2 2"
       allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="14 14 12 12" spacing="8" childForceExpandHeight="false" childAlignment="UpperCenter">
    <Text fontSize="18" fontStyle="Bold" color="#5AF0FF" preferredHeight="24">SCRY / SURVEIL</Text>
    <Text id="scryInfo_%s" fontSize="13" color="#8B98A9" preferredHeight="18">Top card</Text>
    <HorizontalLayout spacing="40" preferredHeight="64" childForceExpandWidth="false" childAlignment="MiddleCenter">]]
      .. iconButton("scryUp_" .. c, "ui/arrow_up.png", "ui_scry(" .. c .. "_top)", "Keep on top (scry)")
      .. iconButton("scryDown_" .. c, "ui/arrow_down.png", "ui_scry(" .. c .. "_bottom)", "Put on the bottom (scry)")
      .. [[
    </HorizontalLayout>
    <Panel preferredHeight="300" preferredWidth="215">
      <Text id="scryName_%s" fontSize="14" color="#E6F1FF">-</Text>
      <Image id="scryImg_%s" preserveAspect="true" raycastTarget="false" />
    </Panel>
    <Text fontSize="12" color="#8B98A9" preferredHeight="16">SURVEIL</Text>
    <HorizontalLayout spacing="10" preferredHeight="40">
      <Button onClick="ui_scry(%s_keep)" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold" tooltip="Keep it on top (surveil)">TOP</Button>
      <Button onClick="ui_scry(%s_grave)" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold" tooltip="Put it into your graveyard (surveil)">GRAVEYARD</Button>
    </HorizontalLayout>
    <Button onClick="ui_scry(%s_done)" color="#00B3A4" textColor="#06130B" fontStyle="Bold" preferredHeight="36">DONE</Button>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, c, c, c, c, c))
  end
  return table.concat(parts)
end

local function closeScry(color)
  scry[color] = nil
  UI.setAttribute("scry_" .. color, "active", "false")
end

-- Show the card at the current depth, or close when the library runs out.
local function showScry(color)
  local st = scry[color]
  if st == nil then
    return
  end
  local card = Library.peek(color, st.depth)
  if card == nil then
    broadcastToColor("No more cards to look at.", color, WARN)
    closeScry(color)
    return
  end
  UI.setAttribute("scry_" .. color, "active", "true")
  UI.setValue("scryInfo_" .. color, st.depth == 0 and "Top card of your library"
    or ("Card " .. (st.depth + 1) .. " from the top (" .. st.depth .. " kept above it)"))
  UI.setValue("scryName_" .. color, card.name)
  UI.setAttribute("scryImg_" .. color, "image", card.face or "")
end

function Actions.openScry(color)
  scry[color] = { depth = 0, looked = 0 }
  showScry(color)
end

-- Viewer buttons: "<Color>_<choice>".
function ui_scry(player, arg)
  local color, choice = tostring(arg):match("^(%a+)_(%a+)$")
  if color == nil or player.color ~= color or scry[color] == nil then
    return
  end
  local st = scry[color]
  if choice == "done" then
    if st.looked > 0 then
      log(color .. " finished looking at " .. st.looked .. " card" .. (st.looked == 1 and "" or "s"))
    end
    closeScry(color)
  elseif choice == "top" or choice == "keep" then
    st.looked = st.looked + 1
    log(color .. " keeps a card on top (" .. (choice == "top" and "scry" or "surveil") .. ")")
    st.depth = st.depth + 1
    showScry(color)
  elseif choice == "bottom" then
    st.looked = st.looked + 1
    log(color .. " puts a card on the bottom (scry)")
    Library.moveToBottom(color, st.depth, function() Wait.time(function() showScry(color) end, 0.3) end)
  elseif choice == "grave" then
    st.looked = st.looked + 1
    Library.mill(color, 1, st.depth, function(done)
      if done > 0 then
        log(color .. " puts a card into the graveyard (surveil)")
      end
      Wait.time(function() showScry(color) end, 0.3)
    end)
  end
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
