--[[
  ui.lua
  On-screen controls. Builds the Global XML UI from code so the layout
  lives in the repo with everything else.

  Current controls:
    "Import Deck" button (top left) opens that player's own import panel
    (one panel per seat, each visible only to its seat, so nobody else sees
    it pop up). "Import" takes an Archidekt link (fetched via Archidekt) or a
    pasted list (plain text, Moxfield MTGA/MTGO export, Archidekt export) and
    hands it to Importer.importDeck for that player.
    The Deck Importer cards on the table (importcards.lua) open the same
    panel for whoever clicked.
    "Start Game" and the mulligan panels come from game.lua; "Turn Options"
    from turns.lua; the Scry / discard panels from actions.lua; "Roll Dice"
    from dice.lua; the token search panel from tokens.lua (opened by the
    TOKENS tile on the table).
--]]

TableUI = {}

-- Text each player has typed into their paste box, by seat color.
local pastedText = {}

local HEADER = [[
<Defaults>
  <Button fontSize="16" textColor="#E6F1FF" color="#1B2333" />
  <Text color="#E6F1FF" />
</Defaults>

<Button id="importToggle"
        onClick="ui_toggleImport"
        rectAlignment="UpperLeft"
        offsetXY="20 -20"
        width="150" height="40"
        fontStyle="Bold"
        color="#00B3A4">Import Deck</Button>
]]

-- ONE import panel for everyone (no per-seat visibility: players who join
-- after the table was built often never received their seat-only panel, so
-- they couldn't import). Whoever clicks Import imports to their own seat.
local function importPanel()
  return [[
<Panel id="importPanel"
       active="false"
       width="560" height="520"
       color="#0D1117F2"
       outline="#00B3A4" outlineSize="2 2"
       allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="16 16 16 16" spacing="10" childForceExpandHeight="false">
    <Text id="importTitle" fontSize="22" fontStyle="Bold" alignment="MiddleLeft" preferredHeight="32">Import Commander Deck</Text>
    <Text fontSize="13" alignment="MiddleLeft" preferredHeight="36" color="#8B98A9">Paste an Archidekt or Moxfield deck link, or a decklist. Import puts it at YOUR seat. (Or type in chat: !import followed by your deck link.)</Text>
    <InputField onValueChanged="ui_deckText"
                lineType="MultiLineNewline"
                characterLimit="0"
                fontSize="14"
                preferredHeight="340"
                placeholder="Commander&#10;1 Atraxa, Praetors' Voice&#10;&#10;Deck&#10;1 Sol Ring&#10;..." />
    <HorizontalLayout spacing="10" preferredHeight="44">
      <Button onClick="ui_importDeck" color="#00B3A4" fontStyle="Bold">Import</Button>
      <Button onClick="ui_toggleImport">Close</Button>
    </HorizontalLayout>
  </VerticalLayout>
</Panel>
]]
end

-- Build the on-screen UI. (Life tracking is on the table: trackers.lua.)
function TableUI.build()
  local panels = { importPanel() }
  local xml = HEADER .. table.concat(panels) .. GameFlow.xml() .. Turns.xml() .. Actions.xml()
    .. Dice.xml() .. Tokens.xml() .. LibSearch.xml() .. Stack.xml() .. Combat.xml() .. Triggers.orderXml() .. Effects.xml()
  -- Remember every element that's shown to one seat only (see
  -- TableUI.refreshVisibility).
  TableUI.privateIds = {}
  for tag in xml:gmatch("<%a+[^>]*>") do
    local id = tag:match('%sid="([^"]+)"')
    local vis = tag:match('%svisibility="([^"]+)"')
    if id and vis then
      table.insert(TableUI.privateIds, { id, vis })
    end
  end
  UI.setXml(xml)
  -- The new XML takes a moment to load before it can be changed.
  Wait.time(function()
    GameFlow.refreshUI()
    Turns.render()
    Stack.render()
  end, 1)
end

---------------------------------------------------------------------------
-- XML event handlers (must be global; XML calls them by name)
---------------------------------------------------------------------------

-- A player who joins (or changes seat) after the UI was built doesn't always
-- get the seat-only panels (import, dice, tokens, scry...) until their
-- visibility is set again, so the import panel never showed for them.
-- Re-apply it for every seat-only element.
function TableUI.refreshVisibility()
  for _, pair in ipairs(TableUI.privateIds or {}) do
    UI.setAttribute(pair[1], "visibility", pair[2])
  end
end

local importOpen = {}   -- [color] = true while that player's panel is open

local function seated(color)
  if color == nil or color == "Grey" or color == "Black" or not TableSetup.isActive(color) then
    broadcastToColor("Take a seat first, then import.", color or "Grey", { 1, 0.6, 0.2 })
    return false
  end
  return true
end

-- Open the import panel for one player only (the table's Deck Importer cards
-- and the screen button both use this).
function TableUI.openImport(color)
  if not seated(color) then
    return
  end
  UI.setValue("importTitle", "Import Commander Deck (" .. string.upper(color) .. ")")
  UI.setAttribute("importPanel", "active", "true")
  importOpen[color] = true
end

local function closeImport(color)
  importOpen[color] = nil
  -- Shared panel: hide it once nobody has it open.
  if next(importOpen) == nil then
    UI.setAttribute("importPanel", "active", "false")
  end
end

function ui_toggleImport(player)
  if importOpen[player.color] then
    closeImport(player.color)
  else
    TableUI.openImport(player.color)
  end
end

function ui_deckText(player, value)
  pastedText[player.color] = value
end

function ui_importDeck(player)
  local color = player.color
  if not seated(color) then
    return
  end
  closeImport(color)
  TableUI.importFor(color, pastedText[color], color)
end

-- Import a deck list or an Archidekt / Moxfield link to a seat; messages go
-- to `notify` (the player who asked). Used by the import panel and by
-- "!import <Color> <link or list>" (solo testing).
function TableUI.importFor(color, text, notify)
  notify = notify or color
  local moxId = Archidekt.moxfieldId(text)
  if moxId then
    broadcastToColor("Fetching Moxfield deck " .. moxId .. "...", notify, { 0.7, 0.85, 1 })
    Archidekt.fetchMoxfield(moxId, function(list, nameOrError)
      if list == nil then
        broadcastToColor(nameOrError, notify, { 1, 0.3, 0.3 })
        return
      end
      if nameOrError then
        broadcastToColor("Moxfield: " .. nameOrError, notify, { 0.7, 0.85, 1 })
      end
      Importer.importDeck(color, list)
    end)
    return
  end
  local deckId = Archidekt.deckId(text)
  if deckId then
    broadcastToColor("Fetching Archidekt deck " .. deckId .. "...", notify, { 0.7, 0.85, 1 })
    Archidekt.fetch(deckId, function(list, nameOrError)
      if list == nil then
        broadcastToColor(nameOrError, notify, { 1, 0.3, 0.3 })
        return
      end
      if nameOrError then
        broadcastToColor("Archidekt: " .. nameOrError, notify, { 0.7, 0.85, 1 })
      end
      Importer.importDeck(color, list)
    end)
    return
  end
  Importer.importDeck(color, text)
end
