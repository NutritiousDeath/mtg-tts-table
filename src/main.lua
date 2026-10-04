--[[
  main.lua
  Global entry point: load/save the game state and dev test commands.

  Chat commands (type in TTS chat):
    !state      print the current game state
    !testparse  run the deck parser on a built-in sample list
    !reset      wipe the game state back to a fresh Commander game
--]]

local SAMPLE_DECK = [[
Commander
1 Atraxa, Praetors' Voice (2X2) 190 *F*

Deck
1x Sol Ring
1 Arcane Signet (CMM) 381
1 Swords to Plowshares [Removal]
1 Takenuma, Abandoned Mire (NEO)
1 Delver of Secrets // Insectile Aberration
30 Forest
1 Sol Ring

Sideboard
1 Lightning Bolt
]]

function onLoad(saved)
  local restored = GameState.restore(saved)
  if restored then
    print("MTG > Game state restored.")
  else
    print("MTG > New Commander game state created.")
  end
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

  if message == "!reset" then
    GameState.new("commander")
    print("MTG > Game state reset.")
    return false
  end
end
