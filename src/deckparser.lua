--[[
  deckparser.lua
  Turns pasted decklist text into a clean list of cards.

  Handles:
    1 Sol Ring
    1x Sol Ring
    Sol Ring                                  (count defaults to 1)
    1 Arcane Signet (CMM) 381                 (set code + collector number)
    1 Atraxa, Praetors' Voice (2X2) 190 *F*   (Moxfield foil/etched markers)
    1 Atraxa, Praetors' Voice *CMDR*          (commander marker)
    1x Atraxa (2x2) 190 [Commander{top}]      (Archidekt categories)
    1 Delver of Secrets // Insectile Aberration

  Section headers (any case, optional trailing ':' or '(N)'):
    Commander / Commanders        -> commander zone
    Deck / Main / Mainboard       -> main deck
    Sideboard / Maybeboard / Considering / Companion / Tokens / About -> ignored
--]]

DeckParser = {}

local SECTIONS = {
  ["commander"] = "commander",
  ["commanders"] = "commander",
  ["deck"] = "main",
  ["main"] = "main",
  ["main deck"] = "main",
  ["mainboard"] = "main",
  ["sideboard"] = "skip",
  ["maybeboard"] = "skip",
  ["considering"] = "skip",
  ["companion"] = "skip",
  ["tokens"] = "skip",
  ["about"] = "skip",
}

local BASICS = {
  ["plains"] = true,
  ["island"] = true,
  ["swamp"] = true,
  ["mountain"] = true,
  ["forest"] = true,
  ["wastes"] = true,
  ["snow-covered plains"] = true,
  ["snow-covered island"] = true,
  ["snow-covered swamp"] = true,
  ["snow-covered mountain"] = true,
  ["snow-covered forest"] = true,
}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Returns a section name if the line is a header, otherwise nil.
local function sectionFor(line)
  local key = line:lower()
  key = key:gsub(":%s*$", "")
  key = key:gsub("%s*%(%d+%)%s*$", "")
  key = key:gsub(":%s*$", "")
  key = trim(key)
  return SECTIONS[key]
end

local function parseCardLine(line)
  local entry = { count = 1, commander = false }
  local rest = line

  local count, remainder = line:match("^(%d+)[xX]?%s+(.+)$")
  if count then
    entry.count = tonumber(count)
    rest = remainder
  end

  -- Archidekt categories, e.g. [Commander{top}] or [Ramp,Removal]
  for tag in rest:gmatch("%[(.-)%]") do
    if tag:lower():find("commander", 1, true) then
      entry.commander = true
    end
  end
  rest = rest:gsub("%s*%[.-%]", "")

  -- Archidekt color labels, e.g. ^Have,#37d67a^
  rest = rest:gsub("%s*%^.-%^", "")

  -- Moxfield / MTGO markers: *F*, *E*, *CMDR*
  if rest:find("*CMDR*", 1, true) then
    entry.commander = true
  end
  rest = rest:gsub("%s*%*%a+%*", "")
  rest = trim(rest)

  -- Optional "(SET) collectorNumber" suffix
  local name, set, number = rest:match("^(.-)%s+%(([%w%-]+)%)%s*(%S*)$")
  if name then
    entry.name = trim(name)
    entry.set = set:lower()
    if number ~= "" then
      entry.collectorNumber = number
    end
  else
    entry.name = rest
  end

  if entry.name == "" then
    return nil
  end
  return entry
end

local function countCards(list)
  local total = 0
  for _, e in ipairs(list) do
    total = total + e.count
  end
  return total
end

-- Combine repeated lines of the same card, keeping the first line's set info.
local function mergeDuplicates(list)
  local merged = {}
  local byName = {}
  for _, e in ipairs(list) do
    local key = e.name:lower()
    if byName[key] then
      byName[key].count = byName[key].count + e.count
    else
      byName[key] = e
      table.insert(merged, e)
    end
  end
  return merged
end

function DeckParser.parse(text)
  local deck = {
    commanders = {},
    main = {},
    warnings = {},
    errors = {},
    total = 0,
  }

  local section = "main"
  local lineNo = 0

  for rawLine in (text .. "\n"):gmatch("(.-)\r?\n") do
    lineNo = lineNo + 1
    local line = trim(rawLine)

    if line == "" or line:sub(1, 2) == "//" or line:sub(1, 1) == "#" then
      -- blank line or comment
    else
      local newSection = sectionFor(line)
      if newSection then
        section = newSection
      elseif section ~= "skip" then
        local entry = parseCardLine(line)
        if entry == nil then
          table.insert(deck.errors, "Line " .. lineNo .. ": couldn't read '" .. line .. "'")
        elseif entry.commander or section == "commander" then
          entry.commander = true
          table.insert(deck.commanders, entry)
        else
          table.insert(deck.main, entry)
        end
      end
    end
  end

  deck.commanders = mergeDuplicates(deck.commanders)
  deck.main = mergeDuplicates(deck.main)
  deck.total = countCards(deck.commanders) + countCards(deck.main)
  return deck
end

-- Commander deck checks. Adds messages to deck.warnings; returns true if clean.
-- Singleton exceptions (Relentless Rats, etc.) are checked properly once
-- Scryfall data is available in the next step.
function DeckParser.validateCommander(deck)
  local w = deck.warnings
  local commanderCount = countCards(deck.commanders)

  if commanderCount == 0 then
    table.insert(w, "No commander found. Put it under a 'Commander' header or tag it [Commander].")
  elseif commanderCount > 2 then
    table.insert(w, commanderCount .. " commanders found. Commander allows 1, or 2 with partner/background.")
  end

  if deck.total ~= 100 then
    table.insert(w, "Deck has " .. deck.total .. " cards. Commander decks need exactly 100.")
  end

  for _, e in ipairs(deck.main) do
    if e.count > 1 and not BASICS[e.name:lower()] then
      table.insert(w, e.name .. " x" .. e.count .. ": Commander is singleton (fine if the card allows any number).")
    end
  end

  return #w == 0
end

function DeckParser.describe(e)
  local s = e.count .. "x " .. e.name
  if e.set then
    s = s .. " (" .. e.set:upper()
    if e.collectorNumber then
      s = s .. " #" .. e.collectorNumber
    end
    s = s .. ")"
  end
  return s
end
