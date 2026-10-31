--[[
  gamelog.lua
  A running log of the game for checking issues afterwards. It records:
    - every message the table sends (chat lines, broadcasts)
    - every card move between areas (who, what, from -> to)
    - game start, each turn and step
    - a snapshot of every player (life, poison, commander damage, tax,
      cards in library / hand / graveyard / exile / battlefield)
  It's written to a Notebook tab called "MTG Game Log" (Notebook button at
  the top of the screen) about once a minute, and is saved with the game,
  so it can be read after the game.
    !log       snapshot + write the log now
    !logclear  start a fresh log
  A new game (Start Game) adds a "NEW GAME" divider; the log keeps the most
  recent lines (MAX_LINES).
--]]

GameLog = {}

local MAX_LINES = 4000
local TAB_TITLE = "MTG Game Log"
local lines = {}
local dirty = false

local function stamp()
  local ok, t = pcall(function() return os.date("%H:%M:%S") end)
  if ok and t then
    return t
  end
  return string.format("%7.1fs", Time and Time.time or 0)
end

function GameLog.add(kind, text)
  table.insert(lines, stamp() .. " [" .. kind .. "] " .. tostring(text))
  if #lines > MAX_LINES then
    table.remove(lines, 1)
  end
  dirty = true
end

-- Totals for every seat, for spotting trackers / zones that went wrong.
function GameLog.snapshot(reason)
  GameLog.add("SNAPSHOT", reason or "state")
  local t = GameState.data.turn or {}
  GameLog.add("SNAPSHOT", "turn " .. tostring(t.number) .. " active " .. tostring(t.activeSeat)
    .. " step " .. tostring(t.stepIndex and Turns.STEPS[t.stepIndex] and Turns.STEPS[t.stepIndex].id)
    .. " started " .. tostring(GameState.data.started))
  for _, color in ipairs(TableSetup.activeSeats()) do
    local p = GameState.player(color)
    if p then
      local dmg = {}
      for k, v in pairs(p.commanderDamage or {}) do
        table.insert(dmg, k .. "=" .. v)
      end
      local counts = {}
      if Zones and Zones.countsFor then
        for region, n in pairs(Zones.countsFor(color)) do
          table.insert(counts, region .. "=" .. n)
        end
      end
      local hand = 0
      pcall(function() hand = #Player[color].getHandObjects() end)
      GameLog.add("SNAPSHOT", color .. ": life " .. tostring(p.life) .. ", poison " .. tostring(p.poison)
        .. ", cmdr dmg {" .. table.concat(dmg, " ") .. "}, tax " .. tostring((p.commanderTax or {})[1])
        .. "/" .. tostring((p.commanderTax or {})[2]) .. ", library " .. Library.count(color)
        .. ", hand " .. hand .. ", commanders " .. table.concat(p.commanderNames or {}, " + ")
        .. (p.eliminated and ", OUT" or "") .. (#counts > 0 and (", zones {" .. table.concat(counts, " ") .. "}") or ""))
    end
  end
end

-- Write the log into its Notebook tab (creating the tab the first time).
function GameLog.write()
  local body = table.concat(lines, "\n")
  local ok = pcall(function()
    for _, tab in ipairs(Notes.getNotebookTabs() or {}) do
      if tab.title == TAB_TITLE then
        Notes.editNotebookTab({ index = tab.index, title = TAB_TITLE, body = body, color = "Grey" })
        dirty = false
        return
      end
    end
    Notes.addNotebookTab({ title = TAB_TITLE, body = body, color = "Grey" })
    dirty = false
  end)
  return ok
end

---------------------------------------------------------------------------
-- Errors only: a second Notebook tab, "MTG Errors", with every script error the table caught (not just the
-- last 15 that !errors shows), each with the time and the script version. Written the moment it happens and
-- saved with the game, so it survives a crash or a reload. !errorsclear empties it.
---------------------------------------------------------------------------

local ERR_TITLE = "MTG Errors"
local MAX_ERRORS = 500
local errLines = nil

local function readTab(title)
  local out = {}
  pcall(function()
    for _, tab in ipairs(Notes.getNotebookTabs() or {}) do
      if tab.title == title and tab.body and tab.body ~= "" then
        local body, i = tab.body, 1
        while i <= #body do
          local j = body:find("\n", i, true) or (#body + 1)
          table.insert(out, body:sub(i, j - 1))
          i = j + 1
        end
      end
    end
  end)
  return out
end

local function writeErrors()
  local body = table.concat(errLines or {}, "\n")
  pcall(function()
    for _, tab in ipairs(Notes.getNotebookTabs() or {}) do
      if tab.title == ERR_TITLE then
        Notes.editNotebookTab({ index = tab.index, title = ERR_TITLE, body = body, color = "Red" })
        return
      end
    end
    Notes.addNotebookTab({ title = ERR_TITLE, body = body, color = "Red" })
  end)
end

function GameLog.error(line)
  if errLines == nil then
    errLines = readTab(ERR_TITLE)
  end
  local t = GameState and GameState.data and GameState.data.turn or {}
  table.insert(errLines, stamp() .. " v" .. tostring(SCRIPT_VERSION or "?"):match("^[%d%.]+") .. " turn "
    .. tostring(t.number or "-") .. " " .. tostring(t.activeSeat or "-") .. ": " .. tostring(line))
  while #errLines > MAX_ERRORS do
    table.remove(errLines, 1)
  end
  writeErrors()
end

function GameLog.clearErrors()
  errLines = {}
  writeErrors()
end

---------------------------------------------------------------------------
-- "MTG By Hand": every time the table tells someone to do something themselves ("resolve it by hand",
-- "do this part yourself", "the table can't watch for this"), the line goes in a third Notebook tab with
-- the time, version, turn and whose turn it is. After a game it's the list of what to automate next.
-- !byhandclear empties it. Same message to several seats (2HG teammates) within 3 seconds = one line.
---------------------------------------------------------------------------

local HAND_TITLE = "MTG By Hand"
local MAX_HAND = 500
local handLines = nil
local lastHand, lastHandAt = nil, -100

-- Plain finds only (TTS's Lua chokes on fancy patterns over long text).
local HAND_WORDS = { "by hand", "yourself", "can't watch", "cannot watch", "can't track", "not automated",
  "isn't automated", "can't automate", "wasn't found", "couldn't tell", "no rules text" }

function GameLog.isByHand(msg)
  if type(msg) ~= "string" then
    return false
  end
  local low = msg:lower()
  for _, w in ipairs(HAND_WORDS) do
    if low:find(w, 1, true) then
      return true
    end
  end
  return false
end

local function writeHand()
  local body = table.concat(handLines or {}, "\n")
  pcall(function()
    for _, tab in ipairs(Notes.getNotebookTabs() or {}) do
      if tab.title == HAND_TITLE then
        Notes.editNotebookTab({ index = tab.index, title = HAND_TITLE, body = body, color = "Orange" })
        return
      end
    end
    Notes.addNotebookTab({ title = HAND_TITLE, body = body, color = "Orange" })
  end)
end

function GameLog.byHand(msg)
  local now = (Time and Time.time) or 0
  if msg == lastHand and now - lastHandAt < 3 then
    return
  end
  lastHand, lastHandAt = msg, now
  if handLines == nil then
    handLines = readTab(HAND_TITLE)
  end
  local t = GameState and GameState.data and GameState.data.turn or {}
  table.insert(handLines, stamp() .. " v" .. tostring(SCRIPT_VERSION or "?"):match("^[%d%.]+") .. " turn "
    .. tostring(t.number or "-") .. " " .. tostring(t.activeSeat or "-") .. ": " .. tostring(msg))
  while #handLines > MAX_HAND do
    table.remove(handLines, 1)
  end
  writeHand()
end

function GameLog.clearByHand()
  handLines = {}
  lastHand = nil
  writeHand()
end

local function noteHand(msg)
  if GameLog.isByHand(msg) then
    pcall(GameLog.byHand, msg)
  end
end

function GameLog.clear()
  lines = {}
  GameLog.add("LOG", "log cleared")
  GameLog.write()
end

-- Bring back the lines saved in the notebook (after a load / reload).
local function restore()
  pcall(function()
    for _, tab in ipairs(Notes.getNotebookTabs() or {}) do
      if tab.title == TAB_TITLE and tab.body and tab.body ~= "" then
        -- Split by hand: TTS's Lua can't run (.-) patterns on long text.
        local body, i = tab.body, 1
        while i <= #body do
          local j = body:find("\n", i, true) or (#body + 1)
          table.insert(lines, body:sub(i, j - 1))
          i = j + 1
        end
      end
    end
  end)
  while #lines > MAX_LINES do
    table.remove(lines, 1)
  end
end

-- Record every message the table sends: wrap the chat functions once.
local function wrapChat()
  if GameLog.wrapped then
    return
  end
  GameLog.wrapped = true
  local bAll, pAll, bColor, pColor = broadcastToAll, printToAll, broadcastToColor, printToColor
  broadcastToAll = function(msg, ...)
    GameLog.add("MSG", msg)
    noteHand(msg)
    return bAll(msg, ...)
  end
  printToAll = function(msg, ...)
    GameLog.add("MSG", msg)
    noteHand(msg)
    return pAll(msg, ...)
  end
  -- TTS errors on a private message to an empty seat (solo tests play seats
  -- nobody sits in), so those go to everyone instead.
  local function seated(color)
    local ok, yes = pcall(function() return Player[color].seated end)
    return ok and yes
  end
  broadcastToColor = function(msg, color, ...)
    GameLog.add("TO " .. tostring(color), msg)
    noteHand(msg)
    if not seated(color) then
      return bAll(msg, ...)
    end
    return bColor(msg, color, ...)
  end
  printToColor = function(msg, color, ...)
    GameLog.add("TO " .. tostring(color), msg)
    noteHand(msg)
    if not seated(color) then
      return pAll(msg, ...)
    end
    return pColor(msg, color, ...)
  end
end

local function where(loc)
  if loc == nil then
    return "nowhere"
  end
  return (loc.seat and (loc.seat .. " ") or "") .. tostring(loc.region)
end

function GameLog.setup()
  restore()
  wrapChat()
  GameLog.add("LOG", "table loaded, script " .. tostring(SCRIPT_VERSION))
  Events.on("cardMoved", function(d)
    GameLog.add("MOVE", tostring(d.name) .. ": " .. where(d.from) .. " -> " .. where(d.to))
  end)
  Events.on("gameStarted", function(d)
    GameLog.add("GAME", "========== NEW GAME ========== first: " .. tostring(d.first))
    GameLog.snapshot("game start")
    GameLog.write()
  end)
  Events.on("stepStarted", function(d)
    GameLog.add("TURN", "turn " .. tostring(d.turn) .. " " .. tostring(d.seat) .. ": " .. tostring(d.step))
    if d.step == "untap" then
      GameLog.snapshot("start of " .. tostring(d.seat) .. "'s turn")
    end
  end)
  -- Save to the notebook about once a minute when something changed.
  Wait.time(function()
    if dirty then
      GameLog.write()
    end
  end, 60, -1)
end
