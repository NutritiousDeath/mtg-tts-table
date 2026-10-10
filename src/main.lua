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
    !hover       show what is under your mouse (for alt-zoom problems)
    !zones       count the cards tracked in each of your areas
    !seat <Color>   take a free seat (after a disconnect); !resync refreshes your panels
    !stack on/off   token piles: identical plain tokens share one card (xN badge); !stack merge / !stack unstack
    !perf watch  counts what the script does for 15 seconds (send me the line if it lags)
    !perf        how heavy the table is right now (objects, buttons, how long the board scan takes)
    !zzz on/off  animate the summoning-sickness badge (off by default: it costs speed)
    !counters    show the counters stored on the card under your mouse
    !trackers    list the tracker tiles on the table and their buttons
    !next        next step (active player; same as the NEXT STEP button)
    !endturn     end your turn (active player)
    !layout 4    four players, one per side (White, Red, Green, Blue)
    !layout 2    two players facing each other (White, Green)
    !search      search your library by name, type or rules text
    !triggers off / on   turn trigger detection off / on
    !order off / on      stop / start asking you to order simultaneous triggers
    !triggers flush      put any trigger that is stuck waiting onto the stack
    !auto off / on       turn auto-resolving of simple effects off / on
    !triggers card       show the triggers read on the card under your mouse
    !triggers audit      list trigger text on the battlefield the table can't watch for
    !solo on / off       solo test mode: one person plays every seat
    !import reset        clear a stuck "import already running" state
    !import <link>       import an Archidekt / Moxfield link to your seat
    !import Red <link>   import an Archidekt / Moxfield link (or list) to a seat
    !flip / !unflip   flip the table (just for fun) / put it back
    !forcepass   stop waiting on a player who isn't answering
    !afk 45 / off   priority pop-ups pass by themselves after this many seconds (default 60)
    !walker      show the loyalty abilities read on the planeswalker under your mouse
    !log         snapshot every player and save the game log to the Notebook
    !logclear    start a fresh game log
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
require("src/mana")
require("src/libsearch")
require("src/gamelog")
require("src/stack")
require("src/triggers")
require("src/combat")
require("src/equip")
require("src/ring")
require("src/walkers")
require("src/effects")
require("src/statics")
require("src/soulbond")
require("src/pile")
require("src/faces")
require("src/flip")
require("src/token_data")
require("src/tokens")
require("src/ui")
require("src/importcards")
require("src/music_tracks")
require("src/music")
require("src/planechase_data")
require("src/planechase")
Pile.install()

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
SCRIPT_VERSION = "1.49 (library search reads card data from the deck, reconnect puts you back in your seat, !seat, !resync)"

function onLoad(saved)
  GameLog.setup()
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
  Planechase.ensure()
  ManaChips.ensure()
  Stack.ensure()
  TableSetup.applyBackground()
  for _, obj in ipairs(getObjects()) do
    LibSearch.addMenu(obj)
  end
  TableUI.build()
  Counters.registerHotkeys()
  Turns.registerHotkeys()
  Counters.setupAll()
  Counters.animate()
  -- Give the surface a moment to appear, then face everyone toward their seat.
  Wait.time(function()
    TableSetup.enforceAllSeats()
    for _, color in ipairs(TableSetup.activeSeats()) do
      TableSetup.lookAtSeat(color)
    end
    GameFlow.restore()
    Combat.restore()
  end, 1)
end

-- A card appeared (drawn, taken from a pile, spawned): give it its
-- counter menu (counters.lua). Wait a frame so its tags are in place.
function onObjectSpawn(obj)
  Wait.frames(function()
    if obj ~= nil and not obj.isDestroyed() and not (Faces and Faces.consumeSpawn(obj)) then
      Counters.setup(obj)
      LibSearch.addMenu(obj)
    end
  end, 1)
end

-- A card was flipped (face down / face up: faces.lua).
function onObjectRotate(obj, spin, flip, playerColor, oldSpin, oldFlip)
  if Faces then
    Faces.onRotate(obj, flip, oldFlip, playerColor)
  end
  if Pile then
    Pile.onRotate(obj, spin, oldSpin, playerColor)
  end
  if Actions and Actions.onRotate then
    Actions.onRotate(obj, spin, oldSpin, playerColor)
  end
end

-- A double-faced card changed face (faces.lua carries its data over).
function onObjectStateChange(obj, oldGuid)
  if Faces then
    Faces.onStateChange(obj, oldGuid)
  end
end

-- Someone joined the game: make sure they get their seat-only panels.
-- Who sat where (by Steam id), so someone who drops and comes back can be put back in their seat.
local function seatMemory()
  GameState.data.seatOf = GameState.data.seatOf or {}
  return GameState.data.seatOf
end

local function takenBy(color)
  local ok, p = pcall(function() return Player[color] end)
  return ok and p ~= nil and p.seated == true
end

-- Put `player` back in the seat they had, if it is free. Returns the color or nil.
local function restoreSeat(player)
  local want = seatMemory()[player.steam_id]
  if want == nil or player.color == want or not TableSetup.isActive(want) or takenBy(want) then
    return nil
  end
  local ok = pcall(function() player.changeColor(want) end)
  return ok and want or nil
end

function onPlayerConnect(player)
  Wait.time(function() TableUI.refreshVisibility() end, 1)
  -- A returning player lands as a spectator (Grey) and can't touch anything: sit them back down.
  Wait.time(function()
    local ok, color = pcall(function() return player.color end)
    if not ok then
      return
    end
    if color == "Grey" or color == "Black" or color == "" or color == nil then
      local back = restoreSeat(player)
      if back then
        broadcastToAll("MTG > " .. tostring(player.steam_name) .. " is back: seated at " .. back
          .. " again. (Change color in the player list if you wanted a different seat.)", { 0.55, 0.9, 0.6 })
      else
        printToColor("MTG > You're a spectator. Pick a free color in the player list, or type !seat <Color> (e.g. !seat Red).",
          color or "Grey", { 1, 0.8, 0.3 })
      end
    end
    TableUI.refreshVisibility()
  end, 2.5)
end

function onPlayerDisconnect(player)
  local color = player.color
  if color and color ~= "Grey" and color ~= "Black" and color ~= "" and TableSetup.isActive(color) then
    seatMemory()[player.steam_id] = color
    broadcastToAll("MTG > " .. tostring(player.steam_name) .. " (" .. color .. ") disconnected. Their seat is kept: when they rejoin they're put back at "
      .. color .. " (or they can type !seat " .. color .. ").", { 1, 0.8, 0.3 })
  end
end

-- Someone rolled a die: the planar die is handled by planechase.lua.
function onObjectRandomize(obj, color)
  if Planechase and obj and obj.hasTag and obj.hasTag("PlanarDie") then
    Planechase.onRolled(obj, color)
  end
end

-- Card movement tracking (zones.lua).
function onObjectPickUp(color, obj)
  Stack.onPickUp(color, obj)
  Zones.onPickUp(color, obj)
  if Pile then Pile.onPickUp(color, obj) end
end

function onObjectDrop(color, obj)
  Stack.onDrop(color, obj)
  Zones.onDrop(color, obj)
  Equip.onDrop(color, obj)
  ManaChips.onDrop(obj)
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
  if color and color ~= "Grey" and color ~= "Black" and TableSetup.isActive(color) then
    local ok, p = pcall(function() return Player[color] end)
    if ok and p and p.steam_id then
      seatMemory()[p.steam_id] = color
    end
  end
  -- Seat-only panels (import etc.) for someone who just sat down.
  Wait.time(function() TableUI.refreshVisibility() end, 0.5)
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
  if Music and Music.chat(message) then
    return false
  end
  if Planechase and Planechase.chat(message, sender and sender.color) then
    return false
  end

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

  -- What is under the mouse (for alt-zoom problems): its name, kind, tags,
  -- whether players can interact with it, and every object stacked there.
  if message == "!hover" then
    local p = Player[sender.color]
    local obj = p and p.getHoverObject()
    if obj == nil then
      print("MTG > Nothing under the mouse (the zoom has nothing to show).")
      return false
    end
    local function line(o)
      local tags = ""
      pcall(function() tags = table.concat(o.getTags(), ",") end)
      local locked, inter = "?", "?"
      pcall(function() locked = tostring(o.getLock()) end)
      pcall(function() inter = tostring(o.interactable) end)
      return string.format("%s [%s] tags=%s locked=%s interactable=%s", tostring(o.getName()), tostring(o.type), tags,
        locked, inter)
    end
    print("MTG > Under the mouse: " .. line(obj))
    pcall(function()
      local pos = p.getPointerPosition()
      if pos then
        local hits = Physics.cast({ origin = { pos.x, pos.y + 10, pos.z }, direction = { 0, -1, 0 }, max_distance = 30,
          type = 1 })
        for i, h in ipairs(hits or {}) do
          if h.hit_object then
            print("MTG >   " .. i .. ". " .. line(h.hit_object) .. string.format(" y=%.2f", h.point and h.point.y or 0))
          end
        end
      end
    end)
    return false
  end

  if message == "!zzz on" or message == "!zzz off" then
    local on = Counters.setZzzAnimation(message == "!zzz on")
    broadcastToAll("MTG > Animated Zzz badge " .. (on and "ON" or "OFF (static badge, faster)"), { 0.75, 0.8, 0.9 })
    return false
  end

  if message == "!resync" then
    TableUI.refreshVisibility()
    Counters.refreshMenus()
    broadcastToColor("MTG > Refreshed your panels. You are " .. tostring(sender.color) .. (TableSetup.isActive(sender.color)
      and ", a seat in this game." or ", NOT a seat: pick a free color or type !seat <Color>."), sender.color, { 0.75, 0.8, 0.9 })
    return false
  end

  local seatWant = message:match("^!seat (%a+)$")
  if seatWant then
    local want = seatWant:sub(1, 1):upper() .. seatWant:sub(2):lower()
    if not TableSetup.isActive(want) then
      printToColor("MTG > " .. want .. " isn't a seat here: " .. table.concat(TableSetup.activeSeats(), ", "), sender.color, { 1, 0.6, 0.2 })
    elseif takenBy(want) and sender.color ~= want then
      printToColor("MTG > " .. want .. " is taken by someone else right now.", sender.color, { 1, 0.6, 0.2 })
    else
      sender.changeColor(want)
      printToColor("MTG > Moved you to " .. want .. ".", want, { 0.55, 0.9, 0.6 })
    end
    return false
  end

  if message == "!stack on" or message == "!stack off" or message == "!stack merge" or message == "!stack unstack" then
    if message == "!stack on" then
      GameState.data.pileOn = true
      local gone = Pile.mergeAll()
      broadcastToAll("MTG > Token piles ON (by " .. sender.color .. "): identical plain tokens share one card with an xN badge. Touch one (pick it up, tap, right-click, target, attack) and it comes off the pile on its own."
        .. (gone > 0 and (" Merged " .. gone .. " existing card(s).") or ""), { 0.55, 0.9, 0.6 })
    elseif message == "!stack off" then
      local n = Pile.unstackEverything()
      GameState.data.pileOn = false
      broadcastToAll("MTG > Token piles OFF: every token is its own card again" .. (n > 0 and (" (" .. n .. " tokens unstacked).") or "."), { 0.75, 0.8, 0.9 })
    elseif message == "!stack merge" then
      local gone = Pile.mergeAll()
      broadcastToAll("MTG > Token piles: merged " .. gone .. " card(s)" .. (Pile.enabled() and "." or " (piles are off: !stack on)."), { 0.75, 0.8, 0.9 })
    else
      local n = Pile.unstackEverything()
      broadcastToAll("MTG > Token piles: unstacked " .. n .. " token(s).", { 0.75, 0.8, 0.9 })
    end
    return false
  end

  if message == "!perf watch" then
    -- Count what the script does for 15 seconds: which calls it makes, so the lag can be pinned down.
    local counts = {}
    local originals = {}
    local function wrap(tbl, name, label)
      local orig = tbl[name]
      if type(orig) ~= "function" then
        return
      end
      originals[label] = { tbl = tbl, name = name, fn = orig }
      counts[label] = 0
      tbl[name] = function(...)
        counts[label] = counts[label] + 1
        return orig(...)
      end
    end
    wrap(_G, "getObjectsWithTag", "getObjectsWithTag")
    wrap(UI, "setValue", "UI.setValue")
    wrap(UI, "setAttribute", "UI.setAttribute")
    wrap(UI, "setAttributes", "UI.setAttributes")
    wrap(UI, "setXml", "UI.setXml")
    wrap(Wait, "time", "Wait.time")
    wrap(Wait, "frames", "Wait.frames")
    wrap(Counters, "render", "Counters.render")
    wrap(Counters, "setup", "Counters.setup")
    wrap(Statics, "compute", "Statics.compute")
    wrap(Zones, "refresh", "Zones.refresh")
    broadcastToAll("MTG > Perf watch started: leave the table as it is for 15 seconds (play normally).", { 0.75, 0.8, 0.9 })
    Wait.time(function()
      local names = {}
      for label in pairs(counts) do
        table.insert(names, label)
      end
      table.sort(names, function(x, y) return counts[x] > counts[y] end)
      local parts = {}
      for _, label in ipairs(names) do
        table.insert(parts, label .. "=" .. counts[label])
        local o = originals[label]
        o.tbl[o.name] = o.fn
      end
      print("MTG > Perf watch (15s): " .. table.concat(parts, ", "))
    end, 15)
    return false
  end

  if message == "!perf" then
    local cards, buttons, tokens = 0, 0, 0
    for _, o in ipairs(getObjectsWithTag("MTGCard")) do
      if o.type == "Card" and not o.isDestroyed() then
        cards = cards + 1
        if o.hasTag("Token") then
          tokens = tokens + 1
        end
        local ok, b = pcall(function() return o.getButtons() end)
        if ok and b then
          for _ in pairs(b) do
            buttons = buttons + 1
          end
        end
      end
    end
    local t0 = os.clock()
    for _ = 1, 20 do
      Statics.compute()
    end
    local ms = (os.clock() - t0) / 20 * 1000
    print(string.format("MTG > Table load: %d loose cards (%d tokens), %d buttons on them. Board scan: %.1f ms. Tips: fewer sick tokens/animations, lower TTS graphics quality, close other apps.",
      cards, tokens, buttons, ms))
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
    ManaChips.ensure()
    Stack.ensure()
    TableUI.build()
    broadcastToAll("Table layout: " .. (layout == "four" and "4 players" or "2 players")
      .. " (" .. table.concat(TableSetup.activeSeats(), ", ") .. ")", { 0.7, 0.85, 1 })
    return false
  end

  if message == "!log" then
    GameLog.snapshot("requested by " .. tostring(sender.color))
    if GameLog.write() then
      broadcastToColor("Game log saved to the Notebook tab \"MTG Game Log\".", sender.color, { 0.7, 0.85, 1 })
    end
    return false
  end

  if message == "!logclear" then
    GameLog.clear()
    broadcastToColor("Game log cleared.", sender.color, { 0.7, 0.85, 1 })
    return false
  end

  if message == "!order off" or message == "!order on" then
    GameState.data.autoOrder = (message == "!order off")
    broadcastToAll("MTG > Trigger ordering: " .. (GameState.data.autoOrder and "OFF (found order, no panel)" or "ON (you pick the order)"), { 0.75, 0.8, 0.9 })
    return false
  end

  if message == "!triggers flush" then
    Triggers.flush()
    return false
  end

  if message == "!triggers off" or message == "!triggers on" then
    Triggers.setEnabled(message == "!triggers on")
    broadcastToAll("Trigger detection " .. (message == "!triggers on" and "ON" or "OFF") .. " (by " .. sender.color .. ").",
      { 0.7, 0.85, 1 })
    return false
  end

  if message == "!auto off" or message == "!auto on" then
    Effects.setEnabled(message == "!auto on")
    broadcastToAll("Auto-resolve " .. (message == "!auto on" and "ON" or "OFF") .. " (by " .. sender.color .. ").",
      { 0.7, 0.85, 1 })
    return false
  end

  if message == "!ring" then
    if TableSetup.isActive(sender.color) then
      Ring.tempt(sender.color)
    end
    return false
  end

  if message == "!triggers audit" then
    Triggers.audit(sender.color)
    return false
  end

  if message == "!triggers card" then
    local obj = sender.getHoverObject and sender.getHoverObject() or nil
    printToColor(Triggers.describe(obj), sender.color, { 0.7, 0.85, 1 })
    return false
  end

  if message == "!solo on" or message == "!solo off" then
    GameState.data.solo = message == "!solo on"
    broadcastToAll(GameState.data.solo
      and ("Solo test mode ON (by " .. sender.color .. "): you can act for every seat. Turn buttons, combat and planeswalkers work for anyone, no response pop-ups, empty seats keep their hands. Start Game includes every seat.")
      or "Solo test mode OFF.", { 0.7, 0.85, 1 })
    return false
  end

  if message == "!import reset" then
    local was = Importer.reset()
    broadcastToAll("MTG > Importer reset" .. (was and " (a stuck import was cleared)." or " (nothing was running)."), { 0.7, 0.85, 1 })
    return false
  end

  local importSeat, importText = message:match("^!import (%a+) (.+)$")
  if importSeat and not TableSetup.isActive(importSeat) then
    -- "!import <link>": your own seat.
    importSeat, importText = nil, nil
  end
  local ownLink = message:match("^!import (%S+)$")
  if importSeat == nil and ownLink then
    if not TableSetup.isActive(sender.color) then
      printToColor("MTG > Take a seat first, then !import your deck link.", sender.color, { 1, 0.6, 0.2 })
    else
      TableUI.importFor(sender.color, ownLink, sender.color)
    end
    return false
  end
  if importSeat then
    if not TableSetup.isActive(importSeat) then
      printToColor("MTG > No such seat in this layout: " .. importSeat .. " (" .. table.concat(TableSetup.activeSeats(), ", ") .. ")",
        sender.color, { 1, 0.6, 0.2 })
    else
      TableUI.importFor(importSeat, importText, sender.color)
    end
    return false
  end

  local afkArg = message:match("^!afk%s*(.*)$")
  if afkArg then
    Turns.setAfk(sender.color, afkArg)
    return false
  end

  if Flip and Flip.chat(message, sender.color) then
    return false
  end

  if message == "!forcepass" then
    Turns.forcePass(sender.color)
    return false
  end

  if message == "!walker" then
    local obj = sender.getHoverObject and sender.getHoverObject() or nil
    printToColor(Walkers.describe(obj), sender.color, { 0.7, 0.85, 1 })
    return false
  end

  if message == "!search" then
    LibSearch.open(sender.color)
    return false
  end

  if message == "!rebuild" then
    -- Tiles are kept between loads (faster); this forces a fresh set.
    for _, tag in ipairs({ "Tracker", "ActionTile", "TurnStrip", "DeckImporter", "ManaTile", "CastZone" }) do
      for _, obj in ipairs(getObjectsWithTag(tag)) do
        obj.destruct()
      end
    end
    local t = GameState.data.table
    t.trackerTiles, t.taxTiles, t.partnerChips, t.actionTiles, t.turnStrips, t.manaTiles = {}, {}, {}, {}, {}, {}
    if GameState.data.stack then
      GameState.data.stack.castTiles = {}
    end
    Wait.frames(function()
      Trackers.ensureTableDisplay()
      Actions.ensure()
      Turns.ensureStrips()
      ImportCards.ensure()
      Planechase.ensure()
      ManaChips.ensure()
      Stack.ensure()
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
