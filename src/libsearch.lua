--[[
  libsearch.lua
  Search your library by name, type or rules text. Right-click your library
  > "Search library" (or type !search) opens a panel only you see:
    - type words and SEARCH: every word must appear in the card's name,
      type line or rules text ("forest" finds Breeding Pool, "scry" finds
      every card with scry, "creature elf" finds Elf creatures)
    - leave it empty and SEARCH to see the whole library
    - click a card: put it into your hand
    - the TO: button switches where a clicked card goes: hand or battlefield
  Closing the panel shuffles your library (searching always does).
--]]

LibSearch = {}

local MAX_SHOWN = 110   -- a whole Commander library fits; the grid scrolls
local VIEW_ROWS = 3        -- rows visible at once
local COLS = 8
local INFO = { 0.75, 0.8, 0.9 }
local WARN = { 1, 0.6, 0.2 }

local query = {}     -- [color] = typed text
local shown = {}     -- [color] = { guids in slot order }
local open = {}      -- [color] = true while open
local searched = {}  -- [color] = true once the panel has looked at the library
-- Where a picked card goes: "hand" or "battlefield" (the TO: button), and
-- whether it enters tapped. Buttons with a value attached can't tell left
-- from right click in TTS, so the destination is a toggle, not a click.
local dest = {}      -- [color] = { where = "hand"|"battlefield", tapped = bool }
local filters = {}   -- [color] = { typeOnly, mvMin, mvMax, zone } from an effect, or nil
local zoneOf = {}    -- [color] = "library" (default) or "graveyard" (Eternal Witness...)
-- "Look at the top N cards": { left = cards still in that top group, picks =
-- how many may still be taken }. Not cleared by typing a new search.
local look = {}
-- "Up to N cards" (Collective Voyage): the panel closes by itself after N.
local limit = {}

-- The pile being searched: the library, or the graveyard.
local function pileFor(color)
  if zoneOf[color] == "graveyard" then
    return Library.pileIn(color, "graveyard")
  end
  return Library.find(color)
end

-- A field out of the card data JSON in GM Notes, by plain search.
local function gmField(notes, key)
  local a = tostring(notes or ""):find('"' .. key .. '":', 1, true)
  if not a then
    return nil
  end
  local rest = notes:sub(a + #key + 3, a + #key + 160)
  if rest:sub(1, 1) == '"' then
    local b = rest:find('"', 2, true)
    return b and rest:sub(2, b - 1) or nil
  end
  return rest:match("^(%-?[%d%.]+)")
end

function LibSearch.xml()
  local parts = {}
  for _, c in ipairs(TableSetup.activeSeats()) do
    local slots = {}
    for i = 1, MAX_SHOWN do
      local id = c .. "_" .. i
      table.insert(slots, ('<Panel id="lsSlot_%s" active="false"><Image id="lsImg_%s" preserveAspect="true" raycastTarget="false" /><Button id="lsBtn_%s" onClick="ui_libPick(%s)" color="#00000000" /></Panel>')
        :format(id, id, id, id))
    end
    table.insert(parts, ([[
<Panel id="libsearch_%s" visibility="%s" active="false" rectAlignment="UpperCenter" offsetXY="0 -60" width="1260" height="160"
       color="#0B0F17F5" outline="#5AF0FF" outlineSize="2 2" allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="12 12 12 12" spacing="8" childForceExpandHeight="false">
    <HorizontalLayout preferredHeight="26" childForceExpandWidth="false">
      <Text id="lsTitle_%s" fontSize="15" fontStyle="Bold" color="#5AF0FF" alignment="MiddleLeft" flexibleWidth="1">SEARCH LIBRARY</Text>
      <Button onClick="ui_libClose(%s)" preferredWidth="160" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold"
              tooltip="Close and shuffle your library">CLOSE + SHUFFLE</Button>
    </HorizontalLayout>
    <HorizontalLayout spacing="8" preferredHeight="38" childForceExpandWidth="false">
      <InputField id="lsInput_%s" onValueChanged="ui_libText" onEndEdit="ui_libSubmit" fontSize="16" flexibleWidth="1"
                  placeholder="name, type or rules text: forest, creature elf, scry, draw a card... (empty = whole library)" />
      <Button onClick="ui_libSearch(%s)" preferredWidth="110" color="#00B3A4" textColor="#06130B" fontStyle="Bold">SEARCH</Button>
      <Panel preferredWidth="210">
        <Button id="lsDestBtn_%s" onClick="ui_libDest(%s)" color="#2A3346" tooltip="Where a clicked card goes: click to switch" />
        <Text id="lsDest_%s" raycastTarget="false" fontSize="15" fontStyle="Bold" color="#E6F1FF">TO: HAND</Text>
      </Panel>
    </HorizontalLayout>
    <Text id="lsStatus_%s" fontSize="12" color="#8B98A9" alignment="MiddleLeft" preferredHeight="18">Click a card to take it (the TO: button picks hand or battlefield).</Text>
    <VerticalScrollView id="lsScroll_%s" active="false" preferredHeight="204" scrollSensitivity="30" color="#00000000"
                        scrollbarColors="#5AF0FF|#8FF7FF|#5AF0FF|#00000000" scrollbarBackgroundColor="#141B26">
      <GridLayout id="lsGrid_%s" cellSize="144 204" spacing="8 8" constraint="FixedColumnCount" constraintCount="]] .. COLS .. [["
                  childAlignment="UpperLeft" preferredHeight="204">]] .. table.concat(slots) .. [[</GridLayout>
    </VerticalScrollView>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, c, c, c, c, c, c, c, c, c))
  end
  return table.concat(parts)
end

local function status(color, msg)
  UI.setValue("lsStatus_" .. color, msg)
end

-- Words to match: lowercase, split on spaces.
local function words(text)
  local list = {}
  for w in tostring(text or ""):lower():gmatch("%S+") do
    table.insert(list, w)
  end
  return list
end

-- The card's searchable text: name, description (type line + rules text)
-- and the type line / rules text stored in GM Notes.
local function haystack(entry)
  return (tostring(entry.name or "") .. " " .. tostring(entry.description or "") .. " "
    .. tostring(entry.gm_notes or "")):lower()
end

local function render(color, guids, faces, total, matched)
  local rows = math.max(1, math.ceil(#guids / COLS))
  local view = math.min(rows, VIEW_ROWS)
  UI.setAttribute("lsScroll_" .. color, "active", #guids > 0 and "true" or "false")
  UI.setAttribute("lsScroll_" .. color, "preferredHeight", view * 212)
  UI.setAttribute("lsGrid_" .. color, "preferredHeight", rows * 212)
  UI.setAttribute("libsearch_" .. color, "height", 160 + (#guids > 0 and view * 212 or 0))
  for i = 1, MAX_SHOWN do
    local id = color .. "_" .. i
    local g = guids[i]
    if g then
      UI.setAttribute("lsSlot_" .. id, "active", "true")
      UI.setAttribute("lsImg_" .. id, "image", faces[g] or "")
      UI.setAttribute("lsBtn_" .. id, "tooltip", (faces[g .. "|name"] or "Card") .. "\nClick to take it")
    else
      UI.setAttribute("lsSlot_" .. id, "active", "false")
    end
  end
  if look[color] then
    status(color, matched .. " of the top " .. look[color].left .. " cards match. Click one to take it, or CLOSE: the rest go on the bottom.")
  elseif matched == 0 then
    status(color, "Nothing in your library matches. (" .. total .. " cards in your library.)")
  elseif matched > #guids then
    status(color, "Showing " .. #guids .. " of " .. matched .. " matches. Add words to narrow it down.")
  else
    status(color, matched .. " match" .. (matched == 1 and "" or "es") .. " in " .. total
      .. " cards. Click a card to take it.")
  end
end

function LibSearch.run(color)
  local lib = pileFor(color)
  if lib == nil then
    status(color, "Your library is empty.")
    render(color, {}, {}, 0, 0)
    return
  end
  searched[color] = true
  local entries = lib.type == "Deck" and lib.getObjects() or {
    { guid = lib.getGUID(), name = lib.getName(), description = lib.getDescription(), gm_notes = lib.getGMNotes() } }
  local want = words(query[color])
  local matches = {}
  local f = filters[color]
  local lk = look[color]
  for n, e in ipairs(entries) do
    e.index = e.index or (n - 1)
    local hay = haystack(e)
    if f and f.typeOnly then
      hay = tostring(gmField(e.gm_notes, "typeLine") or e.description or ""):lower()
    end
    if lk and e.index >= lk.left then
      hay = nil
    end
    local ok = hay ~= nil
    if ok and f and f.anyOf then
      -- "an instant or sorcery card": any one of the types will do.
      ok = false
      for _, ty in ipairs(f.anyOf) do
        if hay:find(ty, 1, true) then
          ok = true
        end
      end
      want = {}
    end
    for _, w in ipairs(ok and want or {}) do
      if not hay:find(w, 1, true) then
        ok = false
        break
      end
    end
    if ok and f and (f.mvMin or f.mvMax) then
      local mv = tonumber(gmField(e.gm_notes, "cmc") or "") or 0
      if (f.mvMin and mv < f.mvMin) or (f.mvMax and mv > f.mvMax) then
        ok = false
      end
    end
    if ok then
      table.insert(matches, e)
    end
  end
  -- Picture for each shown card (small size: matches the slot, stays sharp).
  -- Cards are matched to their pictures by POSITION in the deck: cards
  -- inside a deck can share a GUID, so a GUID lookup showed one card's
  -- picture for every match (and could take the wrong card).
  local faces, guids = {}, {}
  local data = lib.getData()
  local contained = lib.type == "Deck" and (data.ContainedObjects or {}) or { data }
  for i = 1, math.min(MAX_SHOWN, #matches) do
    local e = matches[i]
    local pos = (e.index or 0) + 1        -- getObjects() index is 0-based
    local key = tostring(pos)
    table.insert(guids, key)
    local cd = contained[pos]
    local face
    for _, d in pairs(cd and cd.CustomDeck or {}) do
      face = d.FaceURL
      break
    end
    faces[key] = face and face:gsub("/large/", "/small/", 1) or ""
    faces[key .. "|name"] = e.name
  end
  shown[color] = guids
  render(color, guids, faces, #entries, #matches)
end

local held = {}   -- [color] = card taken to go on top of the library after the shuffle

local function renderDest(color)
  local d = dest[color] or { where = "hand" }
  local label = d.where == "top" and "TO: TOP OF LIBRARY"
    or (d.where == "battlefield" and ("TO: BATTLEFIELD" .. (d.tapped and " (T)" or "")) or "TO: HAND")
  UI.setValue("lsDest_" .. color, label)
  UI.setAttribute("lsDestBtn_" .. color, "color", d.where == "battlefield" and "#1B5A3A" or "#2A3346")
end

function ui_libDest(player, c)
  if c ~= player.color and not GameState.solo() then
    return
  end
  local d = dest[c] or { where = "hand" }
  if d.where == "top" then
    return   -- fixed by the card ("put that card on top")
  end
  d.where = d.where == "hand" and "battlefield" or "hand"
  if d.where == "hand" then
    d.tapped = false
  end
  dest[c] = d
  renderDest(c)
end

-- preset: search words to start with (effects.lua fills in "basic land"
-- etc.); note: a line telling the player what to do; where / tapped: where
-- picked cards go ("hand" or "battlefield").
function LibSearch.open(color, preset, note, where, tapped, opts)
  if not TableSetup.isActive(color) then
    return
  end
  open[color] = true
  searched[color] = false
  dest[color] = { where = where or "hand", tapped = tapped and true or false }
  -- An effect's search ("a basic land card") matches the TYPE LINE only,
  -- not rules text, plus any mana value limit; typing a new search clears it.
  filters[color] = opts
  zoneOf[color] = opts and opts.zone or "library"
  look[color] = (opts and opts.topN) and { left = opts.topN, picks = opts.picks or 1 } or nil
  limit[color] = (opts and opts.limit) and { left = opts.limit } or nil
  UI.setValue("lsTitle_" .. color, look[color] and ("TOP " .. opts.topN .. " CARDS")
    or (zoneOf[color] == "graveyard" and "SEARCH GRAVEYARD" or "SEARCH LIBRARY"))
  renderDest(color)
  query[color] = preset or query[color]
  if preset then
    UI.setAttribute("lsInput_" .. color, "text", preset)
  end
  UI.setAttribute("libsearch_" .. color, "active", "true")
  printToAll("MTG > " .. color .. " is searching their " .. (zoneOf[color] or "library") .. ".", INFO)
  LibSearch.run(color)
  if note then
    status(color, note)
    broadcastToColor(note, color, { 0.35, 0.95, 1 })
  end
end

function LibSearch.close(color, quiet)
  if not open[color] then
    return
  end
  open[color] = false
  shown[color] = nil
  UI.setAttribute("libsearch_" .. color, "active", "false")
  local lk = look[color]
  look[color] = nil
  limit[color] = nil
  if lk then
    -- Looked at the top cards: the rest go on the bottom, no shuffle.
    if lk.left > 0 then
      Library.topToBottom(color, lk.left)
    end
    if not quiet then
      printToAll("MTG > " .. color .. " put the rest (" .. lk.left .. ") on the bottom of their library.", INFO)
    end
  elseif searched[color] and zoneOf[color] ~= "graveyard" then
    local lib = Library.find(color)
    if lib and lib.type == "Deck" then
      lib.shuffle()
    end
    if not quiet then
      printToAll("MTG > " .. color .. " finished searching and shuffled their library.", INFO)
    end
  end
  -- "...then shuffle and put that card on top": the card stays revealed beside
  -- the library until its owner puts it on top (or draws).
  local h = held[color]
  held[color] = nil
  if h and not h.isDestroyed() then
    Library.holdRevealed(color, h)
  end
end

-- Take a shown card: to the hand, or onto the battlefield (face up).
local function take(color, slot, toBattlefield, tapped, toTop)
  local key = shown[color] and shown[color][slot]
  local lib = pileFor(color)
  local fromWhere = zoneOf[color] == "graveyard" and "graveyard" or "library"
  if key == nil or lib == nil then
    return
  end
  local index = tonumber(key) - 1         -- takeObject wants the 0-based index
  local s = TableSetup.seat(color)
  local name = "a card"
  if toTop then
    if lib.type == "Deck" then
      local card = lib.takeObject({ index = index, position = Library.revealSpot(color),
        rotation = { 0, s.yaw, 0 }, smooth = true })
      if card then
        held[color] = card
        name = card.getName()
      end
    else
      name = lib.getName()   -- the only card: it is already on top
    end
    printToAll("MTG > " .. color .. " reveals " .. name .. " and will put it on top of their library after the shuffle.", INFO)
  elseif toBattlefield then
    local pos = TableSetup.slot(color, "battlefield", 2)
    if lib.type == "Deck" then
      local yaw = tapped and (s.yaw + 90) % 360 or s.yaw
      local card = lib.takeObject({ index = index, position = pos, rotation = { 0, yaw, 0 }, smooth = true })
      name = card and card.getName() or name
      -- It entered the battlefield: let triggers see it (landfall, Amulet...).
      if card then
        Wait.time(function()
          if not card.isDestroyed() then
            Zones.refresh(card)
          end
        end, 1.2)
      end
    else
      lib.setPositionSmooth(pos)
      lib.setRotationSmooth({ 0, s.yaw, 0 })
      name = lib.getName()
    end
    printToAll("MTG > " .. color .. " put " .. name .. " onto the battlefield" .. (tapped and " tapped" or "")
      .. " from their " .. fromWhere .. ".", INFO)
  else
    local hand = Player[color].getHandTransform()
    if lib.type == "Deck" then
      local card = lib.takeObject({ index = index, position = hand.position, rotation = { 0, s.yaw, 0 }, smooth = true })
      name = card and card.getName() or name
      if card and fromWhere == "graveyard" then
        Wait.time(function()
          if not card.isDestroyed() then
            Zones.refresh(card)
          end
        end, 1.2)
      end
    else
      lib.setPositionSmooth(hand.position)
      name = lib.getName()
    end
    if fromWhere == "graveyard" then
      printToAll("MTG > " .. color .. " returned " .. name .. " from their graveyard to their hand.", INFO)
    else
      printToAll("MTG > " .. color .. " put a card from their library into their hand.", INFO)
    end
  end
  -- Top N: one fewer card in the group; done once the picks are used.
  local lk = look[color]
  if lk then
    lk.left = math.max(0, lk.left - 1)
    lk.picks = lk.picks - 1
    if lk.picks <= 0 then
      Wait.frames(function()
        LibSearch.close(color)
      end, 5)
      return
    end
  end
  local lim = limit[color]
  if lim then
    lim.left = lim.left - 1
    if lim.left <= 0 then
      Wait.frames(function()
        LibSearch.close(color)
      end, 5)
      return
    end
  end
  -- Refresh the results (the library changed).
  Wait.frames(function()
    if open[color] then
      LibSearch.run(color)
    end
  end, 5)
end

---------------------------------------------------------------------------
-- XML handlers
---------------------------------------------------------------------------

function ui_libText(player, value)
  query[player.color] = value
  filters[player.color] = nil
end

function ui_libSubmit(player, value)
  query[player.color] = value
  filters[player.color] = nil
  LibSearch.run(player.color)
end

function ui_libSearch(player, c)
  if c ~= player.color then
    return
  end
  LibSearch.run(c)
end

function ui_libClose(player, c)
  if c ~= player.color then
    return
  end
  LibSearch.close(c)
end

function ui_libPick(player, arg)
  local c, i = tostring(arg):match("^(%a+)_(%d+)$")
  if c ~= player.color and not GameState.solo() then
    return
  end
  local d = dest[c] or { where = "hand" }
  take(c, tonumber(i), d.where == "battlefield", d.tapped, d.where == "top")
end

-- Right-click menu on the library deck.
function LibSearch.addMenu(obj)
  if obj == nil or obj.isDestroyed() or obj.type ~= "Deck" then
    return
  end
  obj.addContextMenuItem("Search library", function(playerColor)
    LibSearch.open(playerColor)
  end)
end
