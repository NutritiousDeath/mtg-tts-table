--[[
  ui.lua
  On-screen controls. Builds the Global XML UI from code so the layout
  lives in the repo with everything else.

  Current controls:
    "Import Deck" button (top left) opens a panel with a paste box.
    "Import" takes an Archidekt link (fetched via Archidekt) or a pasted
    list, and hands it to Importer.importDeck for that player.
--]]

TableUI = {}

-- Text each player has typed into the paste box, by seat color.
local pastedText = {}

local XML = [[
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

<Panel id="importPanel"
       active="false"
       width="560" height="520"
       color="#0D1117F2"
       outline="#00B3A4" outlineSize="2 2"
       allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="16 16 16 16" spacing="10" childForceExpandHeight="false">
    <Text fontSize="22" fontStyle="Bold" alignment="MiddleLeft" preferredHeight="32">Import Commander Deck</Text>
    <Text fontSize="13" alignment="MiddleLeft" preferredHeight="36" color="#8B98A9">Paste an Archidekt deck link, or a decklist (plain text, Moxfield or Archidekt export). In a pasted list, put the commander under a "Commander" header or tag it [Commander] / *CMDR*.</Text>
    <InputField id="deckInput"
                onValueChanged="ui_deckText"
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

function TableUI.build()
  UI.setXml(XML)
end

---------------------------------------------------------------------------
-- XML event handlers (must be global; XML calls them by name)
---------------------------------------------------------------------------

local importOpen = false

function ui_toggleImport(player)
  importOpen = not importOpen
  if importOpen then
    UI.show("importPanel")
  else
    UI.hide("importPanel")
  end
end

function ui_deckText(player, value)
  pastedText[player.color] = value
end

function ui_importDeck(player)
  local color = player.color
  if color == "Grey" or color == "Black" then
    broadcastToColor("Take a seat first, then import.", color, { 1, 0.6, 0.2 })
    return
  end
  local text = pastedText[color]

  if Archidekt.isMoxfieldLink(text) then
    broadcastToColor("Moxfield blocks importing by link. In Moxfield: Export > Copy for MTGO, then paste the list here.", color, { 1, 0.6, 0.2 })
    return
  end

  importOpen = false
  UI.hide("importPanel")

  local deckId = Archidekt.deckId(text)
  if deckId then
    broadcastToColor("Fetching Archidekt deck " .. deckId .. "...", color, { 0.7, 0.85, 1 })
    Archidekt.fetch(deckId, function(list, nameOrError)
      if list == nil then
        broadcastToColor(nameOrError, color, { 1, 0.3, 0.3 })
        return
      end
      if nameOrError then
        broadcastToColor("Archidekt: " .. nameOrError, color, { 0.7, 0.85, 1 })
      end
      Importer.importDeck(color, list)
    end)
    return
  end

  Importer.importDeck(color, text)
end
