--[[
  importer.lua
  Parsed decklist -> Scryfall card data -> spawned deck on the table.

  Flow:
    1. DeckParser.parse() turns pasted text into entries.
    2. Unique cards are looked up on Scryfall /cards/collection, 75 per request,
       with a short pause between requests (Scryfall asks for 50-100 ms).
    3. Each card is built as a TTS custom card from its Scryfall image, with:
         Nickname    = card name (hover title)
         Description = type line, mana cost, Oracle text, P/T (hover text)
         GMNotes     = JSON card data the automation reads later
       Double-faced cards get their back face as a second state (flip with
       the number keys or PageUp/PageDown).
    4. The main deck spawns as one shuffled deck in front of the player;
       commanders spawn face up beside it and are recorded in GameState.
--]]

Importer = {}

local SCRYFALL_COLLECTION = "https://api.scryfall.com/cards/collection"
-- Small batches keep each decode short, so the game hitches instead of freezing.
local BATCH_SIZE = 20
local REQUEST_GAP = 0.15 -- seconds between Scryfall requests
-- Scryfall blocks TTS's built-in image downloader (since June 2024), so card
-- images go through another host that uses Scryfall's exact file paths.
--
-- RELAY_HOST: your own Cloudflare Worker (relay/worker.js in this repo),
--   e.g. "mtg-relay.yourname.workers.dev". When set, every image goes through
--   it and the image checks are skipped (faster imports, art for new cards).
-- IMAGE_HOST: community mirror, used only when RELAY_HOST is empty.
local RELAY_HOST = "mtg-relay.nutritiousdeath.workers.dev"
local IMAGE_HOST = "img.klrmngr.com"

local function usingRelay()
  return RELAY_HOST ~= ""
end

-- Other modules (Archidekt) use the relay too. Returns "" when there's none.
function Importer.relayHost()
  return RELAY_HOST
end

local function imageHost()
  if usingRelay() then
    return RELAY_HOST
  end
  return IMAGE_HOST
end

-- Magic card back hosted on Steam, which TTS always loads.
local CARD_BACK = "https://steamusercontent-a.akamaihd.net/ugc/1647720103762682461/35EF6E87970E2A5D6581E7D96A99F8A575B7A15F/"

local function backUrl(card)
  return CARD_BACK
end

local busy = false

local function lower(s)
  return (s or ""):lower()
end

-- "Delver of Secrets // Insectile Aberration" -> "delver of secrets"
local function frontName(name)
  local front = name:match("^(.-)%s*//")
  return lower(front or name)
end

---------------------------------------------------------------------------
-- Card data
---------------------------------------------------------------------------

-- Point Scryfall image links at the mirror and drop the "?<timestamp>" suffix.
local function cleanUrl(url)
  if url == nil then
    return nil
  end
  url = url:gsub("%?.*$", "")
  url = url:gsub("cards%.scryfall%.io", imageHost())
  return url
end

local function pickImage(uris)
  if uris == nil then
    return nil
  end
  return cleanUrl(uris.large or uris.normal or uris.png or uris.small)
end

-- Mirror URL for a Scryfall image ID ("front" or "back" face).
local function mirrorImage(id, side)
  return "https://" .. imageHost() .. "/large/" .. side .. "/" .. id:sub(1, 1) .. "/" .. id:sub(2, 2) .. "/" .. id .. ".jpg"
end

local function faceImage(card, faceIndex)
  -- Another printing's image was chosen because the mirror lacks this one.
  if card._imageId then
    return mirrorImage(card._imageId, faceIndex == 2 and "back" or "front")
  end
  if faceIndex and card.card_faces and card.card_faces[faceIndex] then
    local img = pickImage(card.card_faces[faceIndex].image_uris)
    if img then
      return img
    end
  end
  return pickImage(card.image_uris)
    or (card.card_faces and card.card_faces[1] and pickImage(card.card_faces[1].image_uris))
end

local function isDoubleFaced(card)
  return card.image_uris == nil
    and card.card_faces ~= nil
    and #card.card_faces >= 2
    and card.card_faces[1].image_uris ~= nil
end

-- Pull the fields of one face (or the whole card for single-faced cards).
local function faceFields(card, face)
  local src = face or card
  return {
    name = src.name or card.name,
    manaCost = src.mana_cost or card.mana_cost or "",
    typeLine = src.type_line or card.type_line or "",
    oracle = src.oracle_text or card.oracle_text or "",
    power = src.power,
    toughness = src.toughness,
    loyalty = src.loyalty,
  }
end

local function splitTypes(typeLine)
  local types = {}
  local main = typeLine:match("^(.-)%s+—") or typeLine
  for word in main:gmatch("%S+") do
    table.insert(types, word)
  end
  return types
end

local function buildDescription(f)
  local lines = {}
  local header = f.typeLine
  if f.manaCost ~= "" then
    header = header .. "  " .. f.manaCost
  end
  table.insert(lines, header)
  if f.oracle ~= "" then
    table.insert(lines, f.oracle)
  end
  if f.power and f.toughness then
    table.insert(lines, f.power .. "/" .. f.toughness)
  elseif f.loyalty then
    table.insert(lines, "Loyalty: " .. f.loyalty)
  end
  return table.concat(lines, "\n")
end

-- Machine-readable data stored in GMNotes. Phases 4-8 read this.
local function buildCardData(card, f, isCommander)
  return {
    v = 1,
    name = f.name,
    scryfallId = card.id,
    manaCost = f.manaCost,
    cmc = card.cmc or 0,
    typeLine = f.typeLine,
    types = splitTypes(f.typeLine),
    oracle = f.oracle,
    power = f.power,
    toughness = f.toughness,
    loyalty = f.loyalty,
    keywords = card.keywords or {},
    colors = card.colors or {},
    colorIdentity = card.color_identity or {},
    isCommander = isCommander,
  }
end

---------------------------------------------------------------------------
-- TTS object data
---------------------------------------------------------------------------

local deckIdCounter = 0

local function nextDeckId()
  deckIdCounter = deckIdCounter + 1
  if deckIdCounter > 9999 then
    deckIdCounter = 1
  end
  return deckIdCounter
end

local function cardObject(card, faceIndex, isCommander)
  local face = nil
  if faceIndex and card.card_faces then
    face = card.card_faces[faceIndex]
  end
  local f = faceFields(card, face)
  local id = nextDeckId()

  local obj = {
    Name = "Card",
    Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 180, rotZ = 180, scaleX = 1, scaleY = 1, scaleZ = 1 },
    Nickname = f.name,
    Description = buildDescription(f),
    GMNotes = JSON.encode(buildCardData(card, f, isCommander)),
    CardID = id * 100,
    CustomDeck = {
      [tostring(id)] = {
        FaceURL = faceImage(card, faceIndex),
        BackURL = backUrl(card),
        NumWidth = 1,
        NumHeight = 1,
        BackIsHidden = true,
        UniqueBack = false,
        Type = 0,
      },
    },
    Tags = { "MTGCard" },
  }
  return obj, id
end

-- Full card object, with the back face as state 2 for double-faced cards.
local function buildCard(card, isCommander)
  if isDoubleFaced(card) then
    local front = cardObject(card, 1, isCommander)
    local back = cardObject(card, 2, isCommander)
    front.States = { ["2"] = back }
    return front
  end
  return (cardObject(card, nil, isCommander))
end

local function deckObject(cards)
  local deck = {
    Name = "Deck",
    Transform = { posX = 0, posY = 0, posZ = 0, rotX = 0, rotY = 180, rotZ = 180, scaleX = 1, scaleY = 1, scaleZ = 1 },
    Nickname = "Library",
    DeckIDs = {},
    CustomDeck = {},
    ContainedObjects = {},
  }
  for _, c in ipairs(cards) do
    table.insert(deck.DeckIDs, c.CardID)
    for k, v in pairs(c.CustomDeck) do
      deck.CustomDeck[k] = v
    end
    table.insert(deck.ContainedObjects, c)
  end
  return deck
end

---------------------------------------------------------------------------
-- Placement
---------------------------------------------------------------------------

local handSeatSpots -- defined below

-- Deck spot, command zone spot, facing yaw and command zone label spot for a
-- seat. Uses the table layout (table.lua) when the seat is part of it;
-- otherwise falls back to working it out from the seat's hand zone.
local function seatSpots(color)
  if TableSetup and TableSetup.seat and TableSetup.seat(color) then
    local s = TableSetup.seat(color)
    local deckPos = TableSetup.slot(color, "library", 2)
    local cmdrPos = TableSetup.slot(color, "command", 2)
    -- Label sits just beyond the command card (the deck is on the near side).
    local labelPos = {
      x = cmdrPos.x + s.inward.x * 2.4,
      y = TableSetup.SURFACE_TOP + 0.02,
      z = cmdrPos.z + s.inward.z * 2.4,
    }
    return deckPos, cmdrPos, s.yaw, labelPos
  end
  return handSeatSpots(color)
end

-- Order commanders (commander first, a Background second) and name their
-- roles. Cards are JSON text here: a Background's type line says
-- "Background"; the creature that takes one says "Choose a Background".
function Importer.commanderRoles(list)
  local function isBackground(c)
    return c.json:find("Background", 1, true) ~= nil and c.json:find("Choose a Background", 1, true) == nil
  end
  if #list == 2 and isBackground(list[1]) and not isBackground(list[2]) then
    list[1], list[2] = list[2], list[1]
  end
  local roles = {}
  for i, c in ipairs(list) do
    if i == 1 then
      roles[i] = "COMMANDER"
    elseif isBackground(c) then
      roles[i] = "BACKGROUND"
    else
      roles[i] = "PARTNER"
    end
  end
  return roles
end

-- Where commander number i goes: its own command zone (1 = commander,
-- 2 = partner) when the seat is on the table layout, else stacked on cmdrPos.
local function commanderSpot(color, cmdrPos, i)
  if TableSetup and TableSetup.seat and TableSetup.seat(color) then
    return TableSetup.slot(color, "command" .. math.min(i, 2), 2 + math.max(0, i - 2))
  end
  return { x = cmdrPos.x, y = cmdrPos.y + i, z = cmdrPos.z }
end

-- Fallback: spot in front of a seat's hand zone, pushed toward the center.
handSeatSpots = function(color)
  local hand = Player[color] and Player[color].getHandTransform()
  local hp = hand and hand.position or { x = 0, y = 1, z = -20 }
  local len = math.sqrt(hp.x * hp.x + hp.z * hp.z)
  local dx, dz = 0, 1
  if len > 0.01 then
    dx, dz = -hp.x / len, -hp.z / len
  end
  -- "right" from the seated player's view
  local rx, rz = -dz, dx

  local deckPos = { x = hp.x + dx * 9, y = 2, z = hp.z + dz * 9 }
  local cmdrPos = { x = deckPos.x - rx * 4, y = 2, z = deckPos.z - rz * 4 }
  -- Label sits on the player's side of the command zone, below the card.
  local labelPos = { x = cmdrPos.x - dx * 2.6, y = 1.02, z = cmdrPos.z - dz * 2.6 }
  local atan2 = math.atan2 or math.atan
  local yaw = math.deg(atan2(-dx, -dz))
  return deckPos, cmdrPos, yaw, labelPos
end

---------------------------------------------------------------------------
-- Command zone
-- One scripting zone per seat, tagged "CommandZone", with a floor label.
-- Created on first import at that seat and remembered in GameState so it
-- isn't duplicated. Phase 2 builds the other zones the same way.
---------------------------------------------------------------------------

-- The command zone itself is now built by zones.lua with the rest of the
-- playmat zones. This only removes the separate zone and "COMMAND ZONE" label
-- that older versions of the importer created.
local function ensureCommandZone(color, pos, yaw, labelPos)
  local player = GameState.player(color)
  if player == nil then
    return
  end
  for _, key in ipairs({ "commandZoneLabel", "commandZone" }) do
    local old = player[key] and getObjectFromGUID(player[key])
    if old then
      old.destruct()
    end
    player[key] = nil
  end
end

---------------------------------------------------------------------------
-- Scryfall
---------------------------------------------------------------------------

local function identifierFor(entry)
  if entry.set and entry.collectorNumber then
    return { set = entry.set, collector_number = entry.collectorNumber }
  end
  if entry.set then
    return { name = entry.name:match("^(.-)%s*//") or entry.name, set = entry.set }
  end
  return { name = entry.name:match("^(.-)%s*//") or entry.name }
end

-- Match a returned card to the entry that asked for it.
local function indexCards(cards)
  local byName, bySetNum = {}, {}
  for _, card in ipairs(cards) do
    byName[lower(card.name)] = card
    byName[frontName(card.name)] = card
    if card.card_faces and card.card_faces[1] then
      byName[lower(card.card_faces[1].name)] = card
    end
    bySetNum[lower(card.set) .. "#" .. lower(card.collector_number)] = card
  end
  return byName, bySetNum
end

local function namesMatch(entry, card)
  local want = frontName(entry.name)
  if lower(card.name) == lower(entry.name) or frontName(card.name) == want then
    return true
  end
  if card.card_faces and card.card_faces[1] and lower(card.card_faces[1].name) == want then
    return true
  end
  return false
end

-- Returns the card for an entry, or nil. A set/number hit only counts if the
-- name agrees, so a wrong collector number in a list can't swap in another card.
local function lookup(entry, byName, bySetNum)
  if entry.set and entry.collectorNumber then
    local hit = bySetNum[entry.set .. "#" .. lower(entry.collectorNumber)]
    if hit and namesMatch(entry, hit) then
      return hit
    end
  end
  local hit = byName[lower(entry.name)] or byName[frontName(entry.name)]
  if hit and namesMatch(entry, hit) then
    return hit
  end
  return nil
end

local function nameOnlyIdentifier(entry)
  return { name = entry.name:match("^(.-)%s*//") or entry.name }
end

-- Cut fields we never use out of the raw reply before decoding. These are all
-- flat objects/arrays, so balanced-bracket patterns remove them cleanly and
-- fast; it roughly halves what TTS's slow JSON decoder has to chew through.
local UNUSED_OBJECTS = { "legalities", "prices", "purchase_uris", "related_uris", "preview" }
local UNUSED_ARRAYS = { "all_parts", "multiverse_ids", "games", "finishes", "promo_types",
  "artist_ids", "frame_effects", "produced_mana", "attraction_lights" }
local UNUSED_IMAGE_SIZES = { "small", "normal", "png", "art_crop", "border_crop" }

local function slimJSON(text)
  for _, key in ipairs(UNUSED_OBJECTS) do
    text = text:gsub('"' .. key .. '":%b{},?', "")
  end
  for _, key in ipairs(UNUSED_ARRAYS) do
    text = text:gsub('"' .. key .. '":%b[],?', "")
  end
  for _, key in ipairs(UNUSED_IMAGE_SIZES) do
    text = text:gsub('"' .. key .. '":"[^"]*",?', "")
  end
  -- A removed field at the end of an object leaves ",}" behind.
  text = text:gsub(",}", "}")
  return text
end

local function now()
  return Time and Time.time or os.time()
end

local function fetchCollection(entries, onDone, idFn, onProgress)
  idFn = idFn or identifierFor
  local results = {}
  local notFound = {}
  local batches = {}

  for i = 1, #entries, BATCH_SIZE do
    local batch = {}
    for j = i, math.min(i + BATCH_SIZE - 1, #entries) do
      table.insert(batch, entries[j])
    end
    table.insert(batches, batch)
  end

  local function runBatch(n)
    if n > #batches then
      onDone(results, notFound)
      return
    end

    local ids = {}
    for _, e in ipairs(batches[n]) do
      table.insert(ids, idFn(e))
    end

    WebRequest.custom(
      SCRYFALL_COLLECTION,
      "POST",
      true,
      JSON.encode({ identifiers = ids }),
      {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
        ["User-Agent"] = "MTG-TTS-Table/0.1",
      },
      function(req)
        if req.is_error or req.response_code ~= 200 then
          print("MTG > Scryfall request failed (" .. tostring(req.response_code) .. "): " .. tostring(req.error))
          for _, e in ipairs(batches[n]) do
            table.insert(notFound, e.name)
          end
        else
          local ok, body = pcall(JSON.decode, slimJSON(req.text))
          if ok and body and body.data then
            for _, card in ipairs(body.data) do
              table.insert(results, card)
            end
          else
            print("MTG > Couldn't read Scryfall's response for batch " .. n)
          end
        end
        if onProgress then
          onProgress(#results, #entries)
        end
        Wait.time(function() runBatch(n + 1) end, REQUEST_GAP)
      end
    )
  end

  runBatch(1)
end

---------------------------------------------------------------------------
-- Image check: the mirror doesn't have every printing (the newest sets lag
-- behind). Check each card's image; if it's missing, switch to the newest
-- printing of that card the mirror does have.
---------------------------------------------------------------------------

local CHECK_PARALLEL = 8     -- image checks in flight at once (mirror, not Scryfall)
local MAX_PRINT_TRIES = 12   -- printings to try per card before giving up

local function imageExists(url, cb)
  if url == nil then
    cb(false)
    return
  end
  WebRequest.custom(url, "HEAD", true, nil, {}, function(req)
    cb((not req.is_error) and req.response_code == 200)
  end)
end

-- Run fn(item, done) over items, at most `limit` at a time; then onDone().
local function forEachLimited(items, limit, fn, onDone)
  local nextIndex, running, finished = 1, 0, 0
  if #items == 0 then
    onDone()
    return
  end
  local function pump()
    while running < limit and nextIndex <= #items do
      local item = items[nextIndex]
      nextIndex = nextIndex + 1
      running = running + 1
      fn(item, function()
        running = running - 1
        finished = finished + 1
        if finished == #items then
          onDone()
        else
          pump()
        end
      end)
    end
  end
  pump()
end

-- Raw text GET (no JSON decode: TTS's decoder freezes the game on big replies).
local function scryfallGetText(url, cb)
  WebRequest.custom(url, "GET", true, nil, {
    ["Accept"] = "application/json",
    ["User-Agent"] = "MTG-TTS-Table/0.1",
  }, function(req)
    if req.is_error or req.response_code ~= 200 then
      cb(nil)
      return
    end
    cb(req.text)
  end)
end

local function urlEncode(s)
  return (s:gsub("[^%w%-_%.~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

-- Search URL for a card's paper printings, newest first.
local function printsSearchUrl(card)
  local q
  if card.oracle_id then
    q = "oracleid:" .. card.oracle_id
  else
    q = '!"' .. card.name .. '"'
  end
  -- lang:en keeps out printings that only exist in another language.
  q = q .. " game:paper lang:en unique:prints"
  return "https://api.scryfall.com/cards/search?order=released&dir=desc&q=" .. urlEncode(q)
end

-- Find a printing of `card` whose image the mirror has.
-- cb(printingId or nil). Image IDs are pulled from the raw text with a pattern.
local function findMirroredPrinting(card, cb)
  scryfallGetText(printsSearchUrl(card), function(text)
    if text == nil then
      cb(nil)
      return
    end
    local candidates, seen = {}, {}
    for id in text:gmatch('"large":"https://cards%.scryfall%.io/large/front/%x/%x/([%x%-]+)%.jpg') do
      if id ~= card.id and not seen[id] then
        seen[id] = true
        table.insert(candidates, id)
        if #candidates >= MAX_PRINT_TRIES then
          break
        end
      end
    end
    local i = 0
    local function tryNext()
      i = i + 1
      if i > #candidates then
        cb(nil)
        return
      end
      imageExists(mirrorImage(candidates[i], "front"), function(ok)
        if ok then
          cb(candidates[i])
        else
          tryNext()
        end
      end)
    end
    tryNext()
  end)
end

-- cards: list of unique Scryfall cards. onDone(swap, noImage)
--   swap[cardId] = replacement printing; noImage = names with no image anywhere
local function ensureImages(cards, onDone, onProgress)
  local swap, noImage, missingImage = {}, {}, {}
  onProgress = onProgress or function() end

  forEachLimited(cards, CHECK_PARALLEL, function(card, done)
    imageExists(faceImage(card, 1), function(ok)
      if not ok then
        table.insert(missingImage, card)
      end
      done()
    end)
  end, function()
    if #missingImage > 0 then
      onProgress("Images missing on the mirror: " .. #missingImage .. ". Finding other printings...")
    else
      onProgress("All images found.")
    end
    -- Printing lookups hit the Scryfall API, so run them one at a time.
    local i = 0
    local function nextMissing()
      i = i + 1
      if i > #missingImage then
        onDone(swap, noImage)
        return
      end
      local card = missingImage[i]
      onProgress("Other printing for " .. card.name .. " (" .. i .. "/" .. #missingImage .. ")")
      findMirroredPrinting(card, function(imageId)
        if imageId then
          card._imageId = imageId
          swap[card.id] = card
        else
          table.insert(noImage, card.name)
        end
        Wait.time(nextMissing, REQUEST_GAP)
      end)
    end
    nextMissing()
  end)
end

---------------------------------------------------------------------------
-- Relay card building (fast path)
-- The relay returns each card as a ready-made JSON template, so Lua never
-- decodes or encodes card data; it only swaps in IDs and joins strings.
---------------------------------------------------------------------------

local RELAY_BATCH = 25

-- TTS's Lua engine (MoonSharp) throws "pattern too complex" when patterns
-- run over very long strings, and each relay line is thousands of characters.
-- So relay text is handled with plain find/sub only, never patterns.

-- Split s on a literal separator. Keeps empty fields.
local function splitPlain(s, sep)
  local out, init = {}, 1
  while true do
    local i = string.find(s, sep, init, true)
    if i == nil then
      table.insert(out, string.sub(s, init))
      return out
    end
    table.insert(out, string.sub(s, init, i - 1))
    init = i + #sep
  end
end

-- Replace every occurrence of a literal string.
local function replacePlain(s, find, repl)
  local parts, init = {}, 1
  while true do
    local i = string.find(s, find, init, true)
    if i == nil then
      table.insert(parts, string.sub(s, init))
      break
    end
    table.insert(parts, string.sub(s, init, i - 1))
    table.insert(parts, repl)
    init = i + #find
  end
  return table.concat(parts)
end

-- Swap the relay's ID placeholders for real IDs.
local function fillTemplate(tpl, id1, id2)
  local s = tpl
  s = replacePlain(s, '"@@CID1@@"', tostring(id1 * 100))
  s = replacePlain(s, '"@@CID2@@"', tostring(id2 * 100))
  s = replacePlain(s, "@@ID1@@", tostring(id1))
  s = replacePlain(s, "@@ID2@@", tostring(id2))
  return s
end

-- Shared with tokens.lua (token search spawns cards the same way).
Importer.RELAY_HOST = RELAY_HOST
Importer.splitPlain = splitPlain
Importer.replacePlain = replacePlain
Importer.fillTemplate = fillTemplate
Importer.nextDeckId = function() return nextDeckId() end

-- Read one batch of relay output into results. Lines are
-- KIND <tab> index <tab> a [<tab> b]; indexes are 0-based within the batch.
local function parseRelayText(text, first, results)
  for _, line in ipairs(splitPlain(text, "\n")) do
    local f = splitPlain(line, "\t")
    local kind, idx = f[1], tonumber(f[2])
    if idx then
      local i = first + idx
      if kind == "CARD" then
        results.cards[i] = { card = f[3] or "", entry = f[4] or "" }
      elseif kind == "MISS" then
        table.insert(results.missing, f[3] or "?")
      elseif kind == "FIXED" then
        table.insert(results.fixed, f[3] or "?")
      end
    end
  end
end

-- entries: parsed deck entries. onDone(results) or onDone(nil, error).
-- results = { cards = {[i] = {card=tpl, entry=tpl}}, missing = {names}, fixed = {names} }
local function fetchViaRelay(entries, onDone, onProgress)
  local results = { cards = {}, missing = {}, fixed = {} }
  local url = "https://" .. RELAY_HOST .. "/cards"
  local done = 0

  local function runBatch(first)
    if first > #entries then
      onDone(results)
      return
    end
    local last = math.min(first + RELAY_BATCH - 1, #entries)
    local items = {}
    for i = first, last do
      local e = entries[i]
      table.insert(items, {
        name = e.name,
        set = e.set,
        cn = e.collectorNumber,
        commander = e.commander and true or false,
      })
    end

    WebRequest.custom(url, "POST", true, JSON.encode({ items = items }), {
      ["Content-Type"] = "application/json",
      ["Accept"] = "text/plain",
    }, function(req)
      if req.is_error or req.response_code ~= 200 then
        onDone(nil, "HTTP " .. tostring(req.response_code))
        return
      end
      local ok, err = pcall(parseRelayText, req.text, first, results)
      if not ok then
        onDone(nil, "couldn't read relay reply: " .. tostring(err))
        return
      end
      done = last
      if onProgress then
        onProgress(done, #entries)
      end
      Wait.time(function() runBatch(last + 1) end, 0.1)
    end)
  end

  runBatch(1)
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

function Importer.importDeck(color, text)
  if busy then
    broadcastToColor("An import is already running. Wait for it to finish.", color, { 1, 0.6, 0.2 })
    return
  end
  if text == nil or text:match("^%s*$") then
    broadcastToColor("Paste a decklist first.", color, { 1, 0.6, 0.2 })
    return
  end
  if TableSetup and TableSetup.isActive and not TableSetup.isActive(color) then
    broadcastToColor(color .. " isn't a seat in the current layout. Seats: "
      .. table.concat(TableSetup.activeSeats(), ", ") .. ".", color, { 1, 0.6, 0.2 })
    return
  end

  local deck = DeckParser.parse(text)
  DeckParser.validateCommander(deck)

  local entries = {}
  for _, e in ipairs(deck.commanders) do
    table.insert(entries, e)
  end
  for _, e in ipairs(deck.main) do
    table.insert(entries, e)
  end
  if #entries == 0 then
    broadcastToColor("No cards found in that list.", color, { 1, 0.3, 0.3 })
    return
  end

  busy = true
  broadcastToAll(color .. " is importing a deck (" .. deck.total .. " cards)...", { 0.7, 0.85, 1 })

  -- Timed progress lines in chat, so a slow step is easy to spot.
  local started = now()
  local function progress(msg)
    printToColor(string.format("[%.1fs] %s", now() - started, msg), color, { 0.6, 0.75, 0.9 })
  end
  local function onFetchProgress(done, total)
    progress("Card data: " .. done .. "/" .. total)
  end

  local function spawnDeck(cards, fixed, swap, noImage)
    progress("Building deck...")
    local byName, bySetNum = indexCards(cards)
    local missing = {}
    local mainCards = {}
    local commanderCards = {}

    local function resolve(e)
      local card = lookup(e, byName, bySetNum)
      if card and swap[card.id] then
        return swap[card.id]
      end
      return card
    end

    for _, e in ipairs(deck.commanders) do
      local card = resolve(e)
      if card then
        table.insert(commanderCards, buildCard(card, true))
      else
        table.insert(missing, e.name)
      end
    end

    for _, e in ipairs(deck.main) do
      local card = resolve(e)
      if card then
        for _ = 1, e.count do
          table.insert(mainCards, buildCard(card, false))
        end
      else
        table.insert(missing, e.name)
      end
    end

    local deckPos, cmdrPos, yaw, labelPos = seatSpots(color)
    if #commanderCards > 0 then
      ensureCommandZone(color, cmdrPos, yaw, labelPos)
    end
    local player = GameState.player(color)
    if player then
      player.commanders = {}
      -- Commander names drive the commander damage counters on the trackers.
      player.commanderNames = {}
      for _, e in ipairs(deck.commanders) do
        table.insert(player.commanderNames, e.name)
      end
    end

    progress("Spawning " .. #mainCards .. " cards...")

    if #mainCards == 1 then
      local c = mainCards[1]
      spawnObjectJSON({ json = JSON.encode(c), position = deckPos, rotation = { 0, yaw, 180 } })
    elseif #mainCards > 1 then
      spawnObjectJSON({
        json = JSON.encode(deckObject(mainCards)),
        position = deckPos,
        rotation = { 0, yaw, 180 },
        callback_function = function(obj)
          obj.setName(color .. " Library")
          progress("Deck spawned.")
          if TableSetup and TableSetup.lookAtSeat then
            TableSetup.lookAtSeat(color)
          end
          Wait.time(function() obj.shuffle() end, 0.5)
        end,
      })
    end

    for i, c in ipairs(commanderCards) do
      spawnObjectJSON({
        json = JSON.encode(c),
        position = commanderSpot(color, cmdrPos, i),
        rotation = { 0, yaw, 0 },
        callback_function = function(obj)
          if player then
            -- By index, so commander i always matches command zone i.
            player.commanders[i] = obj.getGUID()
          end
        end,
      })
    end

    busy = false

    for _, msg in ipairs(deck.warnings) do
      broadcastToColor("Deck check: " .. msg, color, { 1, 0.8, 0.3 })
    end
    for _, name in ipairs(fixed) do
      broadcastToColor("Set/number in the list didn't match " .. name .. ", so the default printing was used.", color, { 1, 0.8, 0.3 })
    end
    if #missing > 0 then
      broadcastToColor("Not found on Scryfall: " .. table.concat(missing, ", "), color, { 1, 0.3, 0.3 })
    end
    if #noImage > 0 then
      broadcastToColor("No image available yet (card will be blank): " .. table.concat(noImage, ", "), color, { 1, 0.6, 0.2 })
    end
    broadcastToAll(color .. "'s deck is ready: " .. #mainCards .. " cards + " .. #commanderCards .. " commander(s).", { 0.6, 1, 0.6 })
    -- New commanders mean new commander damage counters on every tracker.
    if Trackers then
      Trackers.renderAll()
    end
  end

  -- Check images for every card actually used, then spawn.
  local function build(cards, fixed)
    local byName, bySetNum = indexCards(cards)
    local unique, seen = {}, {}
    for _, e in ipairs(entries) do
      local card = lookup(e, byName, bySetNum)
      if card and not seen[card.id] then
        seen[card.id] = true
        table.insert(unique, card)
      end
    end
    -- The relay can fetch any card's image, so nothing needs checking.
    if usingRelay() then
      Wait.frames(function() spawnDeck(cards, fixed, {}, {}) end, 1)
      return
    end
    progress("Checking card images (" .. #unique .. " unique cards)...")
    ensureImages(unique, function(swap, noImage)
      -- Let a frame pass so the chat updates before the heavy build step.
      Wait.frames(function() spawnDeck(cards, fixed, swap, noImage) end, 1)
    end, progress)
  end

  -- Fast path: the relay looks cards up and builds them; Lua only joins text.
  local function spawnFromTemplates(results)
    progress("Building deck...")
    local missing, fixed = results.missing, results.fixed
    local player = GameState.player(color)
    local deckPos, cmdrPos, yaw, labelPos = seatSpots(color)

    local commanderJson, mainCards, deckIds, deckEntries = {}, {}, {}, {}
    local commanderList = {}
    for i, e in ipairs(entries) do
      local t = results.cards[i]
      if t then
        local copies = e.commander and 1 or e.count
        for _ = 1, copies do
          local id1, id2 = nextDeckId(), nextDeckId()
          local json = fillTemplate(t.card, id1, id2)
          if e.commander then
            table.insert(commanderList, { json = json, name = e.name })
          else
            table.insert(mainCards, json)
            table.insert(deckIds, tostring(id1 * 100))
            table.insert(deckEntries, fillTemplate(t.entry, id1, id2))
          end
        end
      end
    end

    -- Roles: the first zone holds the commander; the second a partner or a
    -- Background (a Background goes second even if listed first).
    local roles = Importer.commanderRoles(commanderList)
    for _, c in ipairs(commanderList) do
      table.insert(commanderJson, c.json)
    end

    if #commanderJson > 0 then
      ensureCommandZone(color, cmdrPos, yaw, labelPos)
    end
    if player then
      player.commanders = {}
      -- Commander names drive the commander damage counters on the trackers.
      player.commanderNames = {}
      player.commanderRoles = roles
      for _, c in ipairs(commanderList) do
        table.insert(player.commanderNames, c.name)
      end
      if #commanderList > 0 then
        local bits = {}
        for i, c in ipairs(commanderList) do
          table.insert(bits, roles[i]:sub(1, 1) .. roles[i]:sub(2):lower() .. ": " .. c.name)
        end
        broadcastToAll(color .. " - " .. table.concat(bits, " · "), { 0.7, 0.85, 1 })
      end
    end

    progress("Spawning " .. #mainCards .. " cards...")
    if #mainCards == 1 then
      spawnObjectJSON({ json = mainCards[1], position = deckPos, rotation = { 0, yaw, 180 } })
    elseif #mainCards > 1 then
      local deckJson = '{"Name":"Deck","Transform":{"posX":0,"posY":0,"posZ":0,"rotX":0,"rotY":180,"rotZ":180,'
        .. '"scaleX":1,"scaleY":1,"scaleZ":1},"Nickname":"Library",'
        .. '"DeckIDs":[' .. table.concat(deckIds, ",") .. '],'
        .. '"CustomDeck":{' .. table.concat(deckEntries, ",") .. '},'
        .. '"ContainedObjects":[' .. table.concat(mainCards, ",") .. ']}'
      spawnObjectJSON({
        json = deckJson,
        position = deckPos,
        rotation = { 0, yaw, 180 },
        callback_function = function(obj)
          obj.setName(color .. " Library")
          progress("Deck spawned.")
          if TableSetup and TableSetup.lookAtSeat then
            TableSetup.lookAtSeat(color)
          end
          Wait.time(function() obj.shuffle() end, 0.5)
        end,
      })
    end

    for i, json in ipairs(commanderJson) do
      spawnObjectJSON({
        json = json,
        position = commanderSpot(color, cmdrPos, i),
        rotation = { 0, yaw, 0 },
        callback_function = function(obj)
          if player then
            -- By index, so commander i always matches command zone i.
            player.commanders[i] = obj.getGUID()
          end
        end,
      })
    end

    busy = false
    for _, msg in ipairs(deck.warnings) do
      broadcastToColor("Deck check: " .. msg, color, { 1, 0.8, 0.3 })
    end
    for _, name in ipairs(fixed) do
      broadcastToColor("Set/number in the list didn't match " .. name .. ", so the default printing was used.", color, { 1, 0.8, 0.3 })
    end
    if #missing > 0 then
      broadcastToColor("Not found on Scryfall: " .. table.concat(missing, ", "), color, { 1, 0.3, 0.3 })
    end
    broadcastToAll(color .. "'s deck is ready: " .. #mainCards .. " cards + " .. #commanderJson .. " commander(s).", { 0.6, 1, 0.6 })
    -- New commanders mean new commander damage counters on every tracker.
    if Trackers then
      Trackers.renderAll()
    end
  end

  -- Original path: Lua decodes Scryfall's data itself (slower). Used without
  -- a relay, or if the relay fails.
  local function runLocal()
    -- Pass 1: look up by set/number where given. Pass 2: anything that didn't
    -- come back with the right name is looked up again by name alone.
    fetchCollection(entries, function(cards)
    local byName, bySetNum = indexCards(cards)
    local retry, fixed = {}, {}
    for _, e in ipairs(entries) do
      if lookup(e, byName, bySetNum) == nil then
        table.insert(retry, e)
        if e.set then
          table.insert(fixed, e.name)
        end
      end
    end

    if #retry == 0 then
      build(cards, fixed)
      return
    end

    fetchCollection(retry, function(more)
      for _, card in ipairs(more) do
        table.insert(cards, card)
      end
      -- Only report a fix for cards the second pass actually found.
      local moreByName, moreBySetNum = indexCards(more)
      local found = {}
      for _, e in ipairs(retry) do
        if e.set and lookup(e, moreByName, moreBySetNum) then
          table.insert(found, e.name)
        end
      end
      build(cards, found)
    end, nameOnlyIdentifier, onFetchProgress)
  end, nil, onFetchProgress)
  end

  if usingRelay() then
    fetchViaRelay(entries, function(results, err)
      if results then
        Wait.frames(function()
          -- If anything in the fast path fails, recover with the built-in import
          -- instead of leaving the importer stuck as "busy".
          local ok, buildErr = pcall(spawnFromTemplates, results)
          if not ok then
            progress("Fast import failed (" .. tostring(buildErr) .. "). Using the slower built-in import.")
            runLocal()
          end
        end, 1)
      else
        progress("Relay unavailable (" .. tostring(err) .. "). Using the slower built-in import.")
        runLocal()
      end
    end, onFetchProgress)
  else
    runLocal()
  end
end
