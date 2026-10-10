--[[
  gamestate.lua
  Single source of truth for the table. Every module reads and writes game
  data through GameState so it can be saved and restored as one JSON blob.
--]]

GameState = {}

-- Decoded GM Notes (the card's printed data) are read all over the place, many times a second
-- (triggers, statics, counters, combat). Decoding a few KB of JSON each time is what made big
-- boards sluggish, so the result is kept until the notes text changes. Treat the table as READ-ONLY.
CardData = {}
local cdCache, cdCount = {}, 0
local EMPTY = {}
function CardData.get(obj)
  if obj == nil then
    return EMPTY
  end
  local ok, notes = pcall(function() return obj.getGMNotes() end)
  if not ok or notes == nil or notes == "" then
    return EMPTY
  end
  local okg, guid = pcall(function() return obj.getGUID() end)
  if not okg then
    return EMPTY
  end
  local e = cdCache[guid]
  if e and e.notes == notes then
    return e.data
  end
  local ok2, d = pcall(JSON.decode, notes)
  if not ok2 or type(d) ~= "table" then
    d = EMPTY
  end
  if not e then
    cdCount = cdCount + 1
    if cdCount > 1500 then
      cdCache, cdCount = {}, 0
    end
  end
  cdCache[guid] = { notes = notes, data = d }
  return d
end

-- Seat colors used for a 4-player Commander table (TTS player colors).
GameState.SEATS = { "White", "Red", "Green", "Blue" }

GameState.FORMATS = {
  commander = {
    startingLife = 40,
    deckSize = 100,
    handSize = 7,
    poisonLethal = 10,
    commanderDamageLethal = 21,
    freeFirstMulligan = true,
  },
}

GameState.data = nil

local function newPlayer(color, format)
  return {
    color = color,
    seated = false,          -- set when a player joins this seat
    life = format.startingLife,
    poison = 0,
    commanderDamage = {},    -- ["<seat>|<slot>"] = damage taken from that seat's commander (slot 2 = partner)
    commanders = {},         -- GUIDs of this player's commander card(s)
    commanderNames = {},     -- names of this player's commander(s), set on import
    commanderRoles = {},     -- "COMMANDER" / "PARTNER" / "BACKGROUND" per command zone
    commanderTax = { 0, 0 }, -- tax per command zone (1 = commander, 2 = partner), in mana
    mulligans = 0,
    hasKept = false,
    eliminated = false,
  }
end

function GameState.new(formatName)
  formatName = formatName or "commander"
  local format = GameState.FORMATS[formatName]

  local data = {
    version = 1,
    format = formatName,
    started = false,
    turn = {
      number = 0,
      activeSeat = nil,
      startingSeat = nil,
      step = nil,
    },
    stack = {},
    players = {},
  }

  for _, color in ipairs(GameState.SEATS) do
    data.players[color] = newPlayer(color, format)
  end

  GameState.data = data
  return data
end

function GameState.format()
  return GameState.FORMATS[GameState.data.format]
end

function GameState.player(color)
  return GameState.data.players[color]
end

-- Serialize for onSave.
-- Copy of the state that JSON can always encode: only text / number keys,
-- and no functions or game objects. Anything dropped is reported once, with
-- where it was, so the cause can be found and fixed.
local reportedBad = {}

local function clean(t, path, depth, seen)
  local out = {}
  if depth > 30 or seen[t] then
    return out
  end
  seen[t] = true
  for k, v in pairs(t) do
    local tk, tv = type(k), type(v)
    if tk ~= "string" and tk ~= "number" then
      local where = path .. "/<" .. tk .. " key>"
      if not reportedBad[where] then
        reportedBad[where] = true
        print("MTG > Save: skipped a bad entry at " .. where)
      end
    elseif tv == "table" then
      out[k] = clean(v, path .. "/" .. tostring(k), depth + 1, seen)
    elseif tv == "string" or tv == "number" or tv == "boolean" then
      out[k] = v
    else
      local where = path .. "/" .. tostring(k) .. " (" .. tv .. ")"
      if not reportedBad[where] then
        reportedBad[where] = true
        print("MTG > Save: skipped a bad entry at " .. where)
      end
    end
  end
  seen[t] = nil
  return out
end

function GameState.encode()
  local ok, text = pcall(JSON.encode, GameState.data)
  if ok then
    return text
  end
  return JSON.encode(clean(GameState.data, "", 0, {}))
end

-- Restore from onLoad's saved string. Returns true if an existing game was restored.
function GameState.restore(saved)
  if saved == nil or saved == "" then
    GameState.new("commander")
    return false
  end

  local ok, decoded = pcall(JSON.decode, saved)
  if ok and type(decoded) == "table" and decoded.version == 1 then
    GameState.data = decoded
    return true
  end

  GameState.new("commander")
  return false
end

-- Readable one-line-per-player summary for chat.
function GameState.summary()
  local lines = {}
  local d = GameState.data
  table.insert(lines, "Format: " .. d.format .. " | Started: " .. tostring(d.started) .. " | Turn: " .. d.turn.number)
  for _, color in ipairs(GameState.SEATS) do
    local p = d.players[color]
    table.insert(lines, color .. ": " .. p.life .. " life, " .. p.poison .. " poison")
  end
  return table.concat(lines, "\n")
end

-- Solo test mode (!solo on): one person plays every seat. Turn buttons,
-- combat, planeswalkers and seat tiles accept anyone, response pop-ups
-- are skipped, and empty seats keep their opening hand and skip discards.
function GameState.solo()
  return GameState.data ~= nil and GameState.data.solo == true
end
