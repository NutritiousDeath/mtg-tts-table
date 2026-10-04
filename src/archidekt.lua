--[[
  archidekt.lua
  Import a deck from an Archidekt link.

  Archidekt's read API is open: https://archidekt.com/api/decks/<id>/
  The deck is converted into the same plain-text format a player would paste,
  then handed to the normal importer, so it gets the same parsing, name
  checks and image handling.

  Response fields used:
    cards[].quantity
    cards[].categories                 list of category names on the card
    cards[].card.oracleCard.name
    cards[].card.edition.editioncode   set code
    cards[].card.collectorNumber
    categories[].name / .isPremier (commander) / .includedInDeck (false = maybeboard etc.)

  Moxfield blocks all automated access (site, export and API), so Moxfield
  decks have to be exported and pasted instead.
--]]

Archidekt = {}

local API = "https://archidekt.com/api/decks/"

-- Returns the deck id if the text is an Archidekt deck link, else nil.
function Archidekt.deckId(text)
  if text == nil then
    return nil
  end
  return text:match("archidekt%.com/decks/(%d+)") or text:match("archidekt%.com/api/decks/(%d+)")
end

function Archidekt.isMoxfieldLink(text)
  return text ~= nil and text:find("moxfield%.com/decks/") ~= nil
end

-- Build decklist text from a decoded Archidekt deck. Returns text, deckName.
function Archidekt.toDecklist(deck)
  local premier, excluded = {}, {}
  for _, cat in ipairs(deck.categories or {}) do
    if cat.name then
      if cat.isPremier then
        premier[cat.name] = true
      end
      if cat.includedInDeck == false then
        excluded[cat.name] = true
      end
    end
  end

  local commanders, main = {}, {}
  for _, entry in ipairs(deck.cards or {}) do
    local card = entry.card or {}
    local name = card.oracleCard and card.oracleCard.name
    if name then
      local isCommander, inDeck = false, true
      local cats = entry.categories or {}
      if #cats > 0 then
        -- A card is out of the deck only if every category it's in is excluded.
        inDeck = false
        for _, c in ipairs(cats) do
          if premier[c] then
            isCommander = true
          end
          if not excluded[c] then
            inDeck = true
          end
        end
      end

      if inDeck or isCommander then
        local line = tostring(entry.quantity or 1) .. " " .. name
        local set = card.edition and card.edition.editioncode
        if set and set ~= "" then
          line = line .. " (" .. set .. ")"
          if card.collectorNumber and card.collectorNumber ~= "" then
            line = line .. " " .. card.collectorNumber
          end
        end
        table.insert(isCommander and commanders or main, line)
      end
    end
  end

  local lines = { "Commander" }
  for _, l in ipairs(commanders) do
    table.insert(lines, l)
  end
  table.insert(lines, "")
  table.insert(lines, "Deck")
  for _, l in ipairs(main) do
    table.insert(lines, l)
  end
  return table.concat(lines, "\n"), deck.name
end

-- Direct fetch: TTS downloads and decodes Archidekt's JSON itself (slow for
-- big decks). Used when there's no relay or the relay can't reach Archidekt.
local function fetchDirect(id, cb)
  WebRequest.custom(API .. id .. "/", "GET", true, nil, {
    ["Accept"] = "application/json",
    ["User-Agent"] = "MTG-TTS-Table/0.1",
  }, function(req)
    if req.response_code == 403 then
      cb(nil, "That Archidekt deck is private. Set it to public (or unlisted) and try again.")
      return
    end
    if req.response_code == 404 then
      cb(nil, "Archidekt couldn't find deck " .. id .. ". Check the link.")
      return
    end
    if req.is_error or req.response_code ~= 200 then
      cb(nil, "Archidekt request failed (" .. tostring(req.response_code) .. ").")
      return
    end
    -- Drop price data before decoding; it's bulky and unused.
    local text = req.text:gsub('"prices":%b{},?', ""):gsub(",}", "}")
    local ok, deck = pcall(JSON.decode, text)
    if not ok or type(deck) ~= "table" then
      cb(nil, "Couldn't read Archidekt's response.")
      return
    end
    local list, name = Archidekt.toDecklist(deck)
    cb(list, name)
  end)
end

-- Fetch a deck. cb(text, deckName) on success, cb(nil, errorMessage) on failure.
-- Tries the relay first: it returns the decklist as plain text, so nothing
-- has to be decoded in TTS. Falls back to the direct fetch if the relay fails.
function Archidekt.fetch(id, cb)
  local host = Importer and Importer.relayHost and Importer.relayHost() or ""
  if host == "" then
    fetchDirect(id, cb)
    return
  end

  WebRequest.custom("https://" .. host .. "/archidekt/" .. id, "GET", true, nil, {
    ["Accept"] = "text/plain",
  }, function(req)
    -- 403/404 only count if Archidekt itself said so (an older relay without
    -- this endpoint also answers 404, and then we should fall back instead).
    local fromArchidekt = req.text and string.sub(req.text, 1, 9) == "Archidekt"
    if req.response_code == 403 and fromArchidekt then
      cb(nil, "That Archidekt deck is private. Set it to public (or unlisted) and try again.")
      return
    end
    if req.response_code == 404 and fromArchidekt then
      cb(nil, "Archidekt couldn't find deck " .. id .. ". Check the link.")
      return
    end
    if req.is_error or req.response_code ~= 200 then
      fetchDirect(id, cb)
      return
    end

    -- First line is "#NAME<tab><deck name>"; the rest is the decklist.
    local text = req.text
    local name = nil
    local nl = string.find(text, "\n", 1, true)
    if nl and string.sub(text, 1, 6) == "#NAME\t" then
      name = string.sub(text, 7, nl - 1)
      text = string.sub(text, nl + 1)
    end
    cb(text, name)
  end)
end
