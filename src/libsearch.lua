--[[
  libsearch.lua
  Search your library by name, type or rules text. Right-click your library
  > "Search library" (or type !search) opens a panel only you see:
    - type words and SEARCH: every word must appear in the card's name,
      type line or rules text ("forest" finds Breeding Pool, "scry" finds
      every card with scry, "creature elf" finds Elf creatures)
    - leave it empty and SEARCH to see the whole library
    - click a card: put it into your hand
    - right-click a card: put it onto your battlefield
  Closing the panel shuffles your library (searching always does).
--]]

LibSearch = {}

local MAX_SHOWN = 24
local COLS = 8
local INFO = { 0.75, 0.8, 0.9 }
local WARN = { 1, 0.6, 0.2 }

local query = {}     -- [color] = typed text
local shown = {}     -- [color] = { guids in slot order }
local open = {}      -- [color] = true while open
local searched = {}  -- [color] = true once the panel has looked at the library

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
      <Text fontSize="15" fontStyle="Bold" color="#5AF0FF" alignment="MiddleLeft" flexibleWidth="1">SEARCH LIBRARY</Text>
      <Button onClick="ui_libClose(%s)" preferredWidth="160" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold"
              tooltip="Close and shuffle your library">CLOSE + SHUFFLE</Button>
    </HorizontalLayout>
    <HorizontalLayout spacing="8" preferredHeight="38" childForceExpandWidth="false">
      <InputField id="lsInput_%s" onValueChanged="ui_libText" onEndEdit="ui_libSubmit" fontSize="16" flexibleWidth="1"
                  placeholder="name, type or rules text: forest, creature elf, scry, draw a card... (empty = whole library)" />
      <Button onClick="ui_libSearch(%s)" preferredWidth="110" color="#00B3A4" textColor="#06130B" fontStyle="Bold">SEARCH</Button>
    </HorizontalLayout>
    <Text id="lsStatus_%s" fontSize="12" color="#8B98A9" alignment="MiddleLeft" preferredHeight="18">Click a card: to your hand. Right-click: onto your battlefield.</Text>
    <GridLayout id="lsGrid_%s" active="false" cellSize="146 204" spacing="8 8" constraint="FixedColumnCount" constraintCount="]] .. COLS .. [["
                childAlignment="UpperLeft" preferredHeight="204">]] .. table.concat(slots) .. [[</GridLayout>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, c, c, c, c))
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
  UI.setAttribute("lsGrid_" .. color, "active", #guids > 0 and "true" or "false")
  UI.setAttribute("lsGrid_" .. color, "preferredHeight", rows * 212)
  UI.setAttribute("libsearch_" .. color, "height", 160 + (#guids > 0 and rows * 212 or 0))
  for i = 1, MAX_SHOWN do
    local id = color .. "_" .. i
    local g = guids[i]
    if g then
      UI.setAttribute("lsSlot_" .. id, "active", "true")
      UI.setAttribute("lsImg_" .. id, "image", faces[g] or "")
      UI.setAttribute("lsBtn_" .. id, "tooltip", (faces[g .. "|name"] or "Card")
        .. "\nClick: to your hand\nRight-click: onto your battlefield")
    else
      UI.setAttribute("lsSlot_" .. id, "active", "false")
    end
  end
  if matched == 0 then
    status(color, "Nothing in your library matches. (" .. total .. " cards in your library.)")
  elseif matched > #guids then
    status(color, "Showing " .. #guids .. " of " .. matched .. " matches. Add words to narrow it down.")
  else
    status(color, matched .. " match" .. (matched == 1 and "" or "es") .. " in " .. total
      .. " cards. Click: to your hand. Right-click: onto your battlefield.")
  end
end

function LibSearch.run(color)
  local lib = Library.find(color)
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
  for _, e in ipairs(entries) do
    local hay = haystack(e)
    local ok = true
    for _, w in ipairs(want) do
      if not hay:find(w, 1, true) then
        ok = false
        break
      end
    end
    if ok then
      table.insert(matches, e)
    end
  end
  -- Picture for each shown card (small size: matches the slot, stays sharp).
  local faces, guids = {}, {}
  local data = lib.getData()
  local byGuid = {}
  for _, cd in ipairs(lib.type == "Deck" and (data.ContainedObjects or {}) or { data }) do
    byGuid[cd.GUID] = cd
  end
  for i = 1, math.min(MAX_SHOWN, #matches) do
    local e = matches[i]
    table.insert(guids, e.guid)
    local cd = byGuid[e.guid]
    local face
    for _, d in pairs(cd and cd.CustomDeck or {}) do
      face = d.FaceURL
      break
    end
    faces[e.guid] = face and face:gsub("/large/", "/small/", 1) or ""
    faces[e.guid .. "|name"] = e.name
  end
  shown[color] = guids
  render(color, guids, faces, #entries, #matches)
end

-- preset: search words to start with (effects.lua fills in "basic land"
-- etc.); note: a line telling the player what to do.
function LibSearch.open(color, preset, note)
  if not TableSetup.isActive(color) then
    return
  end
  open[color] = true
  searched[color] = false
  query[color] = preset or query[color]
  if preset then
    UI.setAttribute("lsInput_" .. color, "text", preset)
  end
  UI.setAttribute("libsearch_" .. color, "active", "true")
  printToAll("MTG > " .. color .. " is searching their library.", INFO)
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
  if searched[color] then
    local lib = Library.find(color)
    if lib and lib.type == "Deck" then
      lib.shuffle()
    end
    if not quiet then
      printToAll("MTG > " .. color .. " finished searching and shuffled their library.", INFO)
    end
  end
end

-- Take a shown card: to the hand, or onto the battlefield (face up).
local function take(color, slot, toBattlefield)
  local g = shown[color] and shown[color][slot]
  local lib = Library.find(color)
  if g == nil or lib == nil then
    return
  end
  local s = TableSetup.seat(color)
  local name = "a card"
  if toBattlefield then
    local pos = TableSetup.slot(color, "battlefield", 2)
    if lib.type == "Deck" then
      local card = lib.takeObject({ guid = g, position = pos, rotation = { 0, s.yaw, 0 }, smooth = true })
      name = card and card.getName() or name
    else
      lib.setPositionSmooth(pos)
      lib.setRotationSmooth({ 0, s.yaw, 0 })
      name = lib.getName()
    end
    printToAll("MTG > " .. color .. " put " .. name .. " onto the battlefield from their library.", INFO)
  else
    local hand = Player[color].getHandTransform()
    if lib.type == "Deck" then
      local card = lib.takeObject({ guid = g, position = hand.position, rotation = { 0, s.yaw, 0 }, smooth = true })
      name = card and card.getName() or name
    else
      lib.setPositionSmooth(hand.position)
      name = lib.getName()
    end
    printToAll("MTG > " .. color .. " put a card from their library into their hand.", INFO)
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
end

function ui_libSubmit(player, value)
  query[player.color] = value
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

-- value: "-1" left click, "-2" right click.
function ui_libPick(player, arg, value)
  local c, i = tostring(arg):match("^(%a+)_(%d+)$")
  if c ~= player.color then
    return
  end
  take(c, tonumber(i), tostring(value) == "-2")
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
