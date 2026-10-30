--[[
  importcards.lua
  Deck Importer cards on the table: two shared cards in opposite corners,
  each between two seats (White/Red and Green/Blue), angled toward both.
  Clicking one opens the deck import panel for whoever clicked; the deck
  still goes to that player's own seat.

  Each card is a custom token wearing assets/icons/deck_importer.png, with an
  invisible button over it for the click.
--]]

ImportCards = {}

local IMAGE = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/icons/deck_importer.png?v=1"
local CARD_W = 5        -- width on the table (table units); height follows the image (5:7)
local CORNER = 37       -- distance from the table center along x and z

-- Corner spots. yaw faces the card toward the corner between the two seats
-- (same rule as cards at a seat: yaw = viewer's compass angle + 180).
local SPOTS_SQUARE = {
  { x = -CORNER, z = -CORNER, yaw = 225 },  -- between White (south) and Red (west)
  { x = CORNER, z = CORNER, yaw = 45 },     -- between Green (north) and Blue (east)
}
-- Two-Headed Giant (120 x 100 table): at the west and east ends of the open strip between the teams.
local SPOTS_2HG = {
  { x = -50, z = 0, yaw = 90 },
  { x = 50, z = 0, yaw = 270 },
}

local function spots()
  return TableSetup.layout() == "twohg" and SPOTS_2HG or SPOTS_SQUARE
end

function importcards_click(obj, playerColor)
  TableUI.openImport(playerColor)
end

-- The link box on the card itself: works for every player, even when the screen panel doesn't take
-- clicks (TTS sometimes leaves a player's screen UI unclickable after they join).
local typed = {}   -- [card guid] = text in its box

function importcards_text(obj, playerColor, value, selected)
  typed[obj.getGUID()] = value
end

function importcards_go(obj, playerColor)
  local text = typed[obj.getGUID()] or ""
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if playerColor == nil or playerColor == "Grey" or playerColor == "Black" or not TableSetup.isActive(playerColor) then
    broadcastToColor("Take a seat first, then import.", playerColor or "Grey", { 1, 0.6, 0.2 })
    return
  end
  if text == "" then
    broadcastToColor("Paste your Archidekt or Moxfield deck link into the box under the Deck Importer card, then click IMPORT TO MY SEAT.",
      playerColor, { 1, 0.6, 0.2 })
    return
  end
  typed[obj.getGUID()] = nil
  pcall(function() obj.editInput({ index = 0, value = "" }) end)
  TableUI.importFor(playerColor, text, playerColor)
end

local function ready(obj)
  local b = obj.getBoundsNormalized()
  local w = b and b.size and b.size.x or 0
  if w < 0.05 then
    Wait.time(function() if not obj.isDestroyed() then ready(obj) end end, 0.5)
    return
  end
  local k = CARD_W / (w / obj.getScale().x)
  obj.setScale({ k, 1, k })
  local p = obj.getPosition()
  obj.setPosition({ p.x, TableSetup.SURFACE_TOP + obj.getBoundsNormalized().size.y / 2 + 0.01, p.z })
  obj.setLock(true)
  obj.clearButtons()
  obj.createButton({
    click_function = "importcards_click",
    function_owner = Global,
    label = "",
    tooltip = "Import a deck to your seat",
    position = { 0, 0.12, 0 },
    rotation = { 0, 0, 0 },
    scale = { 1 / k, 1, 1 / k },
    width = 2450, height = 3450,
    color = { 0, 0, 0, 0 },
    hover_color = { 0.35, 0.95, 1, 0.12 },
    press_color = { 0.35, 0.95, 1, 0.25 },
  })
  -- Under the card: a box for the deck link and a button that imports it to whoever clicks.
  obj.clearInputs()
  local half = 3.5   -- half the card's height (table units)
  obj.createInput({
    input_function = "importcards_text",
    function_owner = Global,
    label = "Paste deck link here",
    tooltip = "Archidekt or Moxfield deck link (or a pasted list)",
    position = { 0, 0.12, (half + 0.7) / k },
    rotation = { 0, 0, 0 },
    scale = { 1 / k, 1, 1 / k },
    width = 2500, height = 300, font_size = 150,
    alignment = 3,
    color = { 0.08, 0.1, 0.14, 0.95 },
    font_color = { 0.9, 0.95, 1 },
    value = "",
  })
  obj.createButton({
    click_function = "importcards_go",
    function_owner = Global,
    label = "IMPORT TO MY SEAT",
    tooltip = "Import the deck in the box to your seat",
    position = { 0, 0.12, (half + 1.6) / k },
    rotation = { 0, 0, 0 },
    scale = { 1 / k, 1, 1 / k },
    width = 1800, height = 330, font_size = 170,
    color = { 0, 0.7, 0.64, 1 },
    font_color = { 0.02, 0.08, 0.05 },
    hover_color = { 0.2, 0.85, 0.78, 1 },
    press_color = { 0.1, 0.6, 0.55, 1 },
  })
end

-- Remove old importer cards and spawn the two fresh ones.
function ImportCards.ensure()
  -- Keep the two cards if they're already on the table with this image
  -- (respawning them is slow); otherwise replace them.
  local SPOTS = spots()
  local found = getObjectsWithTag("DeckImporter")
  local good = #found == #SPOTS
  for _, obj in ipairs(found) do
    local co = obj.getCustomObject()
    good = good and co ~= nil and co.image == IMAGE
    -- On one of this layout's spots (a layout change moves them).
    local p, on = obj.getPosition(), false
    for _, spot in ipairs(SPOTS) do
      if math.abs(p.x - spot.x) < 1 and math.abs(p.z - spot.z) < 1 then
        on = true
      end
    end
    good = good and on
  end
  if good then
    for _, obj in ipairs(found) do
      ready(obj)
    end
    return
  end
  for _, obj in ipairs(found) do
    obj.destruct()
  end
  for _, spot in ipairs(SPOTS) do
    local obj = spawnObject({
      type = "Custom_Token",
      position = { spot.x, TableSetup.SURFACE_TOP + 0.5, spot.z },
      rotation = { 0, spot.yaw, 0 },
      scale = { 1, 1, 1 },
      sound = false,
      callback_function = function(o)
        o.setName("Deck Importer")
        o.setDescription("Click to import a deck to your seat.")
        o.addTag("DeckImporter")
        o.setLock(true)
        Wait.condition(function() ready(o) end,
          function() return o.isDestroyed() or not o.loading_custom end, 10,
          function() ready(o) end)
      end,
    })
    obj.setCustomObject({ image = IMAGE, thickness = 0.1, merge_distance = 5, stackable = false })
  end
end
