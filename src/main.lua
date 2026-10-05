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
    !moves       toggle printing every card move between areas
    !where       show which zones the card under your mouse is in
    !zones       count the cards tracked in each of your areas
    !counters    show the counters stored on the card under your mouse
    !trackers    list the tracker tiles on the table and their buttons
    !next        next step (active player; same as the NEXT STEP button)
    !endturn     end your turn (active player)
    !layout 4    four players, one per side (White, Red, Green, Blue)
    !layout 2    two players facing each other (White, Green)
    !rebuild     remove and respawn every table tile (if one looks wrong)
    !reset       wipe the game state back to a fresh Commander game
--]]

-- Load order matters: later modules use the earlier ones.
require("src/gamestate")
require("src/events")
require("src/table")
require("src/zones")
require("src/counters")
require("src/library")
require("src/trackers")
require("src/actions")
require("src/turns")
require("src/deckparser")
require("src/importer")
require("src/archidekt")
require("src/game")
require("src/dice")
require("src/tokens")
require("src/ui")
require("src/importcards")

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
SCRIPT_VERSION = "0.64 (faster loading)"

function onLoad(saved)
  print("MTG > Scripts loaded: version " .. SCRIPT_VERSION)
  local restored = GameState.restore(saved)
  if restored then
    print("MTG > Game state restored.")
  else
    print("MTG > New Commander game state created.")
  end
  TableSetup.ensure()
  Trackers.ensureTableDisplay()
  Actions.ensure()
  Turns.ensureStrips()
  ImportCards.ensure()
  TableUI.build()
  Counters.registerHotkeys()
  Turns.registerHotkeys()
  Counters.setupAll()
  -- Give the surface a moment to appear, then face everyone toward their seat.
  Wait.time(function()
    TableSetup.enforceAllSeats()
    for _, color in ipairs(TableSetup.activeSeats()) do
      TableSetup.lookAtSeat(color)
    end
    GameFlow.restore()
  end, 1)
end

-- A card appeared (drawn, taken from a pile, spawned): give it its
-- counter menu (counters.lua). Wait a frame so its tags are in place.
function onObjectSpawn(obj)
  Wait.frames(function()
    if obj ~= nil and not obj.isDestroyed() then
      Counters.setup(obj)
    end
  end, 1)
end

-- Card movement tracking (zones.lua).
function onObjectPickUp(color, obj)
  Zones.onPickUp(color, obj)
end

function onObjectDrop(color, obj)
  Zones.onDrop(color, obj)
end

function onObjectEnterZone(zone, obj)
  Zones.onEnterZone(zone, obj)
end

function onObjectLeaveContainer(container, obj)
  Zones.onLeaveContainer(container, obj)
end

-- A player finished searching a library (right-click > Search): shuffle it,
-- as searching a library always ends with a shuffle.
function onObjectSearchEnd(obj, playerColor)
  if obj == nil or obj.isDestroyed() or obj.type ~= "Deck" then
    return
  end
  local loc = Zones.regionAt(obj.getPosition())
  if loc.region == "library" then
    obj.shuffle()
    broadcastToAll((loc.seat or "A") .. "'s library was shuffled after " .. tostring(playerColor) .. " searched it.",
      { 0.75, 0.8, 0.9 })
  end
end

function onObjectEnterContainer(container, obj)
  Zones.onEnterContainer(container, obj)
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

  if message == "!counters" then
    local obj = Player[sender.color] and Player[sender.color].getHoverObject()
    print("MTG > " .. Counters.describe(obj))
    return false
  end

  if message == "!next" then
    Turns.next(sender.color)
    return false
  end

  if message == "!endturn" then
    Turns.endTurn(sender.color)
    return false
  end

  if message == "!trackers" then
    Trackers.report()
    return false
  end

  if message == "!zones" then
    Zones.report(sender.color)
    return false
  end

  if message == "!where" then
    local obj = Player[sender.color] and Player[sender.color].getHoverObject()
    print("MTG > " .. Zones.describeObject(obj))
    local surface = GameState.data.table and getObjectFromGUID(GameState.data.table.surface or "")
    if surface then
      local b = surface.getBounds()
      print(string.format("MTG > Table surface top is at height %.2f", b.center.y + b.size.y / 2))
    end
    return false
  end

  if message == "!moves" then
    print("MTG > Card move log " .. (Zones.toggleMoveLog() and "ON" or "OFF"))
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
    Trackers.ensureTableDisplay()
    Actions.ensure()
    Turns.ensureStrips()
    TableUI.build()
    broadcastToAll("Table layout: " .. (layout == "four" and "4 players" or "2 players")
      .. " (" .. table.concat(TableSetup.activeSeats(), ", ") .. ")", { 0.7, 0.85, 1 })
    return false
  end

  if message == "!rebuild" then
    -- Tiles are kept between loads (faster); this forces a fresh set.
    for _, tag in ipairs({ "Tracker", "ActionTile", "TurnStrip", "DeckImporter" }) do
      for _, obj in ipairs(getObjectsWithTag(tag)) do
        obj.destruct()
      end
    end
    local t = GameState.data.table
    t.trackerTiles, t.taxTiles, t.partnerChips, t.actionTiles, t.turnStrips = {}, {}, {}, {}, {}
    Wait.frames(function()
      Trackers.ensureTableDisplay()
      Actions.ensure()
      Turns.ensureStrips()
      ImportCards.ensure()
      broadcastToAll("Table tiles rebuilt.", { 0.7, 0.85, 1 })
    end, 3)
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
