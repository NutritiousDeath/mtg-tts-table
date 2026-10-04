--[[
  main.lua
  Global entry point: load/save the game state, build the UI, dev test commands.

  Global.-1.lua only needs one line:
    require("src/main")
  This file loads every other module, so adding a module never means
  editing Global.-1.lua.

  Chat commands (type in TTS chat):
    !state       print the current game state
    !testparse   run the deck parser on a built-in sample list
    !testimport  import the sample list to your seat (needs a seat color)
    !cardinfo    print the image links of the card under your mouse
    !view        point your camera at your seat
    !seats       print the script version and every seat's hand zone
    !layout 4    four players, one per side (White, Red, Green, Blue)
    !layout 2    two players facing each other (White, Green)
    !reset       wipe the game state back to a fresh Commander game
--]]

-- Load order matters: later modules use the earlier ones.
require("src/gamestate")
require("src/table")
require("src/deckparser")
require("src/importer")
require("src/archidekt")
require("src/ui")

local SAMPLE_DECK = [[
Commander
1 Atraxa, Praetors' Voice *F*

Deck
1x Sol Ring
1 Arcane Signet
1 Swords to Plowshares [Removal]
1 Takenuma, Abandoned Mire (NEO)
1 Delver of Secrets // Insectile Aberration
30 Forest
1 Sol Ring

Sideboard
1 Lightning Bolt
]]

-- Bump this whenever the scripts change, so it's obvious which version TTS runs.
SCRIPT_VERSION = "0.10 (playmats drawn)"

function onLoad(saved)
  print("MTG > Scripts loaded: version " .. SCRIPT_VERSION)
  local restored = GameState.restore(saved)
  if restored then
    print("MTG > Game state restored.")
  else
    print("MTG > New Commander game state created.")
  end
  TableSetup.ensure()
  TableUI.build()
  -- Give the surface a moment to appear, then face everyone toward their seat.
  Wait.time(function()
    TableSetup.enforceAllSeats()
    for _, color in ipairs(TableSetup.activeSeats()) do
      TableSetup.lookAtSeat(color)
    end
  end, 1)
end

-- Someone sat down or switched seats: only the layout's seats are allowed;
-- otherwise face their camera toward their seat.
function onPlayerChangeColor(color)
  if color == "Grey" or color == "Black" then
    return
  end
  if TableSetup.enforceSeat(color) then
    return
  end
  Wait.time(function() TableSetup.lookAtSeat(color) end, 0.5)
end

function onSave()
  return GameState.encode()
end

local function printDeck(deck)
  print("MTG > Commanders:")
  for _, e in ipairs(deck.commanders) do
    print("   " .. DeckParser.describe(e))
  end

  print("MTG > Main deck: " .. #deck.main .. " unique cards, " .. deck.total .. " total including commanders")
  for _, e in ipairs(deck.main) do
    print("   " .. DeckParser.describe(e))
  end

  for _, msg in ipairs(deck.warnings) do
    print("WARNING > " .. msg)
  end
  for _, msg in ipairs(deck.errors) do
    print("ERROR > " .. msg)
  end
end

function onChat(message, sender)
  if message == "!state" then
    print(GameState.summary())
    return false
  end

  if message == "!testparse" then
    local deck = DeckParser.parse(SAMPLE_DECK)
    DeckParser.validateCommander(deck)
    printDeck(deck)
    return false
  end

  if message == "!testimport" then
    if sender.color == "Grey" or sender.color == "Black" then
      print("MTG > Take a seat (pick a color) first.")
    else
      Importer.importDeck(sender.color, SAMPLE_DECK)
    end
    return false
  end

  if message == "!cardinfo" then
    local obj = Player[sender.color] and Player[sender.color].getHoverObject()
    if obj == nil then
      print("MTG > Hover your mouse over a card, then type !cardinfo.")
    else
      print("MTG > " .. obj.type .. ": " .. obj.getName())
      local custom = obj.getCustomObject()
      if custom then
        print("   face: " .. tostring(custom.face))
        print("   back: " .. tostring(custom.back))
      else
        print("   (no custom image data)")
      end
    end
    return false
  end

  if message == "!seats" then
    print("MTG > Version " .. SCRIPT_VERSION .. ", you are " .. tostring(sender.color))
    TableSetup.report()
    return false
  end

  if message == "!view" then
    if TableSetup.isActive(sender.color) then
      TableSetup.lookAtSeat(sender.color)
    else
      print("MTG > Take a seat in the current layout first: " .. table.concat(TableSetup.activeSeats(), ", "))
    end
    return false
  end

  if message == "!layout 4" or message == "!layout 2" then
    local layout = message == "!layout 4" and "four" or "two"
    TableSetup.setLayout(layout)
    broadcastToAll("Table layout: " .. (layout == "four" and "4 players" or "2 players")
      .. " (" .. table.concat(TableSetup.activeSeats(), ", ") .. ")", { 0.7, 0.85, 1 })
    return false
  end

  if message == "!reset" then
    -- Keep the table (surface, layout); only the game itself resets.
    local tableState = GameState.data and GameState.data.table
    GameState.new("commander")
    GameState.data.table = tableState
    print("MTG > Game state reset.")
    return false
  end
end
