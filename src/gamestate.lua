--[[
  gamestate.lua
  Single source of truth for the table. Every module reads and writes game
  data through GameState so it can be saved and restored as one JSON blob.
--]]

GameState = {}

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
    commanderDamage = {},    -- ["<seat>|<commander name>"] = damage taken from that commander
    commanders = {},         -- GUIDs of this player's commander card(s)
    commanderNames = {},     -- names of this player's commander(s), set on import
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
function GameState.encode()
  return JSON.encode(GameState.data)
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
