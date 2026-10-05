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
local SPOTS = {
  { x = -CORNER, z = -CORNER, yaw = 225 },  -- between White (south) and Red (west)
  { x = CORNER, z = CORNER, yaw = 45 },     -- between Green (north) and Blue (east)
}

function importcards_click(obj, playerColor)
  TableUI.openImport(playerColor)
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
    width = 1250, height = 1750,
    color = { 0, 0, 0, 0 },
    hover_color = { 0.35, 0.95, 1, 0.12 },
    press_color = { 0.35, 0.95, 1, 0.25 },
  })
end

-- Remove old importer cards and spawn the two fresh ones.
function ImportCards.ensure()
  for _, obj in ipairs(getObjectsWithTag("DeckImporter")) do
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
