--[[
  triggers.lua
  Phase 6: trigger detection. The table reads each permanent's rules text
  (stored in GM Notes by the importer) and, when something happens that a
  card's trigger is waiting for, puts that trigger on the stack (stack.lua),
  labelled TRIGGER, for the players to resolve. Wrong ones come off with the
  X on the stack panel; anything missed can be added with right-click >
  "Ability to stack".

  What it watches (cards on a battlefield or lands area, face up):
    steps     "at the beginning of your / each / each opponent's upkeep",
              draw step, end step, beginning of combat, first main phase
    enters    "when ~ enters"; "whenever [another] [nontoken] creature /
              land / artifact / enchantment / permanent [you control] enters"
              (landfall included)
    dies      "when ~ dies"; "whenever [another] [nontoken] creature
              [you control / an opponent controls] dies"
    casting   "whenever you cast a [creature / noncreature / instant or
              sorcery / artifact / enchantment] spell", "whenever an
              opponent casts a [noncreature...] spell"
    drawing   "whenever you / an opponent / a player draws a card"
    also      "~ or another creature dies / enters", cumulative upkeep
    combat    (combat.lua calls these) "whenever ~ attacks", "attacks or
              blocks", "enters or attacks", "whenever ~ blocks / becomes
              blocked", "whenever a creature you control attacks" (each),
              "one or more creatures you control attack" / "whenever you
              attack" (once), "attacks alone" (exalted), "whenever a
              creature attacks you", "whenever ~ deals combat damage to a
              player", "a creature you control deals combat damage to a
              player", "one or more creatures you control deal combat damage"

  Several triggers at once go on the stack active player first, then the
  others in turn order (so the last player's resolve first), like the rules.
  A player with two or more at once picks their order in a panel only they
  see (ORDER YOUR TRIGGERS); empty seats keep the order they were found in.
  !triggers off / !triggers on   turn it off / on for the table.
--]]

Triggers = {}

local INFO = { 0.75, 0.8, 0.9 }

local function enabled()
  return not (GameState.data and GameState.data.triggersOff)
end

function Triggers.setEnabled(on)
  GameState.data.triggersOff = not on
end

---------------------------------------------------------------------------
-- Reading a card
---------------------------------------------------------------------------

local cache = {}   -- [guid .. name] = { abilities }, rebuilt when a card changes

-- A plane card (planechase.lua) reads as a permanent with the plane's rules text, minus what Planechase
-- puts on the stack itself (chaos, planeswalking, rolling).
local planeData = {}
local function cardData(obj)
  local d = CardData.get(obj)
  if next(d) == nil then
    return nil
  end
  if d.planar and Planechase and Planechase.triggerText then
    local nm = tostring(d.name)
    if planeData[nm] == nil then
      planeData[nm] = { name = nm, oracle = Planechase.triggerText(nm), typeLine = "Plane", types = { "Plane" }, keywords = {} }
    end
    return planeData[nm]
  end
  return d
end

local function plainFind(s, needle)
  return s:find(needle, 1, true) ~= nil
end

-- Text between `head` and the next `tail` (plain text, no patterns), or nil.
-- TTS's Lua can't run "lazy" patterns like (.-) on long rules text ("pattern
-- too complex"), so these helpers do it with plain searches.
local function between(s, head, tail)
  local a = s:find(head, 1, true)
  if not a then
    return nil
  end
  local from = a + #head
  local b = s:find(tail, from, true)
  if not b then
    return nil
  end
  return s:sub(from, b - 1)
end

-- Split text into lines without patterns.
local function lines(text)
  local out, i = {}, 1
  while i <= #text do
    local j = text:find("\n", i, true)
    if not j then
      table.insert(out, text:sub(i))
      break
    end
    table.insert(out, text:sub(i, j - 1))
    i = j + 1
  end
  return out
end

-- Lowercase, with the card's own name (and its short name before a comma,
-- "Kasla" for "Kasla, the Broken Halo") and "this creature" etc. as "~".
local function normalize(text, name)
  local t = " " .. text:lower() .. " "
  local function swap(n)
    if n and #n > 1 then
      local esc = n:lower():gsub("([%%%-%.%+%*%?%[%]%^%$%(%)])", "%%%1")
      t = t:gsub(esc, "~")
    end
  end
  swap(name)
  local comma = name and name:find(",", 1, true)
  if comma then
    swap(name:sub(1, comma - 1))
  end
  for _, w in ipairs({ "creature", "permanent", "artifact", "enchantment", "land", "planeswalker", "card", "token", "vehicle", "case", "class", "saga", "aura", "equipment" }) do
    t = t:gsub("this " .. w, "~")
  end
  t = t:gsub("enters the battlefield", "enters")
  return t
end

-- Card type words used in trigger subjects.
local SUBJECTS = { "creature", "land", "artifact", "enchantment", "permanent", "planeswalker" }

-- Parse one paragraph of rules text into a trigger, or nil.
local function parseTrigger(p)
  -- "Is put into a graveyard from the battlefield" (Marionette Apprentice) is "dies"
  -- for creatures, and the same check for artifacts.
  p = (p:gsub(" is put into a graveyard from the battlefield", " dies"))
  p = (p:gsub(" are put into a graveyard from the battlefield", " die"))
  -- Steps.
  local stepWho = {
    { "at the beginning of your upkeep", "upkeep", "you" },
    { "at the beginning of each opponent's upkeep", "upkeep", "opp" },
    { "at the beginning of each player's upkeep", "upkeep", "each" },
    { "at the beginning of each upkeep", "upkeep", "each" },
    { "at the beginning of your draw step", "draw", "you" },
    { "at the beginning of each player's draw step", "draw", "each" },
    { "at the beginning of each draw step", "draw", "each" },
    { "at the beginning of each of your main phases", "main", "you" },
    { "at the beginning of each main phase", "main", "each" },
    { "at the beginning of your precombat main phase", "main1", "you" },
    { "at the beginning of your first main phase", "main1", "you" },
    { "at the beginning of combat on your turn", "combat", "you" },
    { "at the beginning of each combat", "combat", "each" },
    { "at the beginning of your end step", "end", "you" },
    { "at the beginning of each opponent's end step", "end", "opp" },
    { "at the beginning of each player's end step", "end", "each" },
    { "at the beginning of each end step", "end", "each" },
    { "at the beginning of the end step", "end", "each" },
  }
  for _, sw in ipairs(stepWho) do
    if plainFind(p, sw[1]) then
      return { kind = "step", step = sw[2], who = sw[3] }
    end
  end
  -- "Whenever ~ or another creature [you control] dies / enters".
  for _, verb in ipairs({ "dies", "enters" }) do
    local subj = between(p, "whenever ~ or another ", " " .. verb)
    if subj and #subj > 40 then
      subj = nil
    end
    if subj then
      local word
      for _, w in ipairs(SUBJECTS) do
        if subj:find(w, 1, true) then
          word = w
        end
      end
      return { kind = verb, orSelf = true, another = true, subject = word or "permanent",
        nontoken = subj:find("nontoken", 1, true) ~= nil, mine = subj:find("you control", 1, true) ~= nil,
        theirs = subj:find("an opponent controls", 1, true) ~= nil }
    end
  end
  -- Cumulative upkeep is an upkeep trigger.
  if plainFind(p, "cumulative upkeep") then
    return { kind = "step", step = "upkeep", who = "you" }
  end
  -- Sly Requisitioner: "whenever a nontoken artifact you control is put into a graveyard from the battlefield".
  if plainFind(p, "whenever a nontoken artifact you control is put into a graveyard from the battlefield") then
    return { kind = "dies", subject = "artifact", subjects = { "artifact" }, nontoken = true, mine = true }
  end
  -- Baeloth: "whenever a goaded attacking or blocking creature dies".
  if plainFind(p, "whenever a goaded attacking or blocking creature dies") then
    return { kind = "dies", subject = "creature", subjects = { "creature" }, goaded = true }
  end
  -- Life: "whenever an opponent loses life" (Bloodthirsty Conqueror),
  -- "whenever you gain life".
  if plainFind(p, "whenever an opponent loses life") then
    return { kind = "life", dir = "loss", who = "opp" }
  end
  if plainFind(p, "whenever you gain life") then
    return { kind = "life", dir = "gain", who = "you" }
  end
  if plainFind(p, "whenever an opponent gains life") then
    return { kind = "life", dir = "gain", who = "opp" }
  end
  if plainFind(p, "whenever you lose life") then
    return { kind = "life", dir = "loss", who = "you" }
  end
  -- "Whenever you put one or more [+1/+1] counters on a Goblin, Orc, or Army you control".
  do
    local cAt = p:find("whenever you put one or more ", 1, true)
    if cAt then
      local seg = p:sub(cAt, cAt + 140)
      local what = seg:match("one or more (.-)counters? on ")
      local on = seg:match("counters? on (.-) you control")
      if on then
        local types = {}
        for _, t in ipairs(SUBJECTS) do
          if on:find(t, 1, true) then
            table.insert(types, t)
          end
        end
        if #types == 0 then
          for word in on:gmatch("%a+") do
            local w = word
            if w ~= "or" and w ~= "and" and w ~= "a" and w ~= "an" and w ~= "another" and w ~= "other" then
              if w:sub(-1) == "s" and w:sub(-2) ~= "ss" then
                w = w:sub(1, -2)
              end
              table.insert(types, "sub:" .. w)
            end
          end
        end
        if #types > 0 then
          return { kind = "counters", mine = true, subject = types[1], subjects = types,
            counterKind = (what and what:find("+1/+1", 1, true)) and "plus" or nil }
        end
      end
    end
  end
  if plainFind(p, "whenever the ring tempts you") then
    return { kind = "ring", who = "you" }
  end
  -- Drawing.
  if plainFind(p, "whenever an opponent draws a card") then
    return { kind = "draw", who = "opp" }
  end
  if plainFind(p, "whenever you draw a card") then
    return { kind = "draw", who = "you" }
  end
  if plainFind(p, "whenever a player draws a card") then
    return { kind = "draw", who = "each" }
  end
  -- Faerie Mastermind: "whenever an opponent draws their second card each turn".
  do
    local who, ord = p:match("whenever (%a+) draws? their (%a+) card each turn")
    local ORDN = { second = 2, third = 3 }
    if ord and ORDN[ord] then
      return { kind = "draw", who = (who == "an" or who == "opponent") and "opp" or "each", nth = ORDN[ord] }
    end
    if plainFind(p, "whenever an opponent draws their second card each turn") then
      return { kind = "draw", who = "opp", nth = 2 }
    end
  end
  -- The Endstone / Rampaging Baloths style: "whenever you play a land" (from hand, not fetched).
  if plainFind(p, "whenever you play a land") then
    return { kind = "enters", subject = "land", subjects = { "land" }, mine = true, playedOnly = true }
  end
  -- Horn of Greed / Burgeoning style: "whenever a player plays a land", "whenever an opponent plays a land".
  if plainFind(p, "whenever a player plays a land") then
    return { kind = "enters", subject = "land", subjects = { "land" }, playedOnly = true }
  end
  if plainFind(p, "whenever an opponent plays a land") then
    return { kind = "enters", subject = "land", subjects = { "land" }, theirs = true, playedOnly = true }
  end
  -- Enters.
  if plainFind(p, "when ~ enters") or plainFind(p, "whenever ~ enters") or plainFind(p, "when ~ and ") and plainFind(p, " enter") then
    return { kind = "enters", self = true }
  end
  -- "Whenever [another / a / an / one or more [other]] [nontoken] <types>
  -- [you control / an opponent controls] enters / dies". The subject is
  -- the words between "whenever" and the verb; several types joined by "or"
  -- ("creature or planeswalker") all count. Plain searches only (long rules
  -- text breaks TTS's pattern matching).
  local at = 1
  while true do
    -- "Whenever ..." or the shorter "When a Dragon you control enters".
    local w1 = p:find("whenever ", at, true)
    local w2 = p:find("when ", at, true)
    local w, headLen = w1, 9
    if w2 and (w1 == nil or w2 < w1) then
      w, headLen = w2, 5
    end
    if not w then
      break
    end
    at = w + headLen
    local window = p:sub(w + headLen, w + headLen + 80)
    local verbAt, kind
    local e = window:find(" enter", 1, true)
    local d = window:find(" die", 1, true)
    if e and (not d or e < d) then
      verbAt, kind = e, "enters"
    elseif d then
      verbAt, kind = d, "dies"
    end
    if verbAt then
      local subj = window:sub(1, verbAt - 1)
      local lead
      for _, l in ipairs({ "another ", "a ", "an ", "one or more other ", "one or more " }) do
        if lead == nil and subj:sub(1, #l) == l then
          lead = l
        end
      end
      local listy = subj:find(" or ", 1, true) ~= nil
      local clean = lead and not subj:find("~", 1, true) and (listy or not subj:find(",", 1, true))
        and not subj:find(".", 1, true)
      if clean then
        local types = {}
        for _, t in ipairs(SUBJECTS) do
          if subj:find(t, 1, true) then
            table.insert(types, t)
          end
        end
        -- Older wording: "enters the battlefield under your control".
        local after = window:sub(verbAt, verbAt + 45)
        local underMine = after:find("under your control", 1, true) ~= nil
        local underTheirs = after:find("under an opponent's control", 1, true) ~= nil
        -- No card type: a creature type ("another Rat you control", "a
        -- Zombie"), matched on the type line.
        if #types == 0 then
          local rest = subj:sub(#lead + 1):gsub("^nontoken ", ""):gsub("^other ", "")
          local cut = rest:find(" you control", 1, true) or rest:find(" an opponent controls", 1, true)
            or rest:find(" your opponents control", 1, true)
          if cut then
            rest = rest:sub(1, cut - 1)
          end
          local NOT = { player = true, spell = true, card = true, opponent = true, source = true, ability = true,
            or_ = true }
          local first = true
          for word in rest:gmatch("%a+") do
            -- "Goblin, Orc, or Army": every word is a creature type; a single
            -- subject keeps just its first word like before.
            local w = word
            if w ~= "or" and w ~= "and" and not NOT[w] and (listy or first) then
              if w:sub(-3) == "ves" then
                w = w:sub(1, -4) .. "f"
              elseif w:sub(-1) == "s" and w:sub(-2) ~= "ss" then
                w = w:sub(1, -2)
              end
              table.insert(types, "sub:" .. w)
              first = false
            end
          end
        end
        if #types > 0 then
          return { kind = kind, subject = types[1], subjects = types,
            tapped = kind == "enters" and window:sub(verbAt, verbAt + 13) == " enters tapped",
            another = lead == "another " or lead == "one or more other ",
            nontoken = subj:find("nontoken", 1, true) ~= nil,
            -- "nonbasic land", "noncreature artifact": types it must NOT have.
            excludes = (function()
              local ex = {}
              for w in subj:gmatch("non(%a+)") do
                if w ~= "token" then
                  table.insert(ex, w)
                end
              end
              return ex
            end)(),
            tokenOnly = subj:find(" token", 1, true) ~= nil and subj:find("nontoken", 1, true) == nil,
            -- Bloodline Pretender: "another creature of the chosen type" (chosen as it entered).
            chosenType = subj:find("of the chosen type", 1, true) ~= nil,
            -- Garruk's Uprising: "a creature you control with power 4 or greater".
            powerMin = tonumber(subj:match("with power (%d+) or greater") or ""),
            toughMin = tonumber(subj:match("with toughness (%d+) or greater") or ""),
            mine = subj:find("you control", 1, true) ~= nil or underMine,
            theirs = subj:find("an opponent controls", 1, true) ~= nil or subj:find("your opponents control", 1, true) ~= nil
              or underTheirs }
        end
      end
    end
  end
  -- "When ~ has no ice counters on it" (Dark Depths): a state trigger on the last counter leaving.
  do
    local kindWord = between(p, "when ~ has no ", " counters on it")
    if kindWord and #kindWord < 20 then
      return { kind = "nocounters", self = true, counter = kindWord }
    end
  end
  -- "When ~ becomes the target of a spell or ability an opponent controls" (Eternal Scourge).
  if plainFind(p, "when ~ becomes the target of a spell or ability") or plainFind(p, "whenever ~ becomes the target of a spell or ability") then
    return { kind = "targeted", self = true, opp = plainFind(p, "an opponent controls") }
  end
  -- Diffusion Sliver: "Whenever a Sliver creature you control becomes the target of a spell or ability an opponent controls".
  do
    local who = between(p, "whenever a ", " creature you control becomes the target of a spell or ability")
    if who and #who < 20 and not who:find(" ", 1, true) then
      return { kind = "targeted", mine = true, subject = "sub:" .. who, subjects = { "sub:" .. who }, opp = plainFind(p, "an opponent controls") }
    end
  end
  -- Dies (self).
  if plainFind(p, "when ~ dies") or plainFind(p, "whenever ~ dies") then
    return { kind = "dies", self = true }
  end
  -- Casting.
  if plainFind(p, "whenever an opponent casts their first noncreature spell each turn") then
    return { kind = "cast", who = "opp", spellType = "noncreature", first = true }
  end
  if plainFind(p, "whenever an opponent casts their first spell each turn") then
    return { kind = "cast", who = "opp", first = true }
  end
  -- Talion, the Kindly Lord: "a spell with mana value, power, or toughness equal to the chosen number".
  if plainFind(p, "whenever an opponent casts a spell with mana value, power, or toughness equal to the chosen number") then
    return { kind = "cast", who = "opp", spellType = "chosen number" }
  end
  local oppType = between(p, "whenever an opponent casts a", " spell")
  oppType = oppType and oppType:gsub("^n? ", "") or nil
  if oppType and #oppType < 30 then
    return { kind = "cast", who = "opp", spellType = oppType ~= "" and oppType or nil }
  end
  if plainFind(p, "whenever an opponent casts a spell") then
    return { kind = "cast", who = "opp" }
  end
  if plainFind(p, "whenever you cast a spell during an opponent's turn") then
    return { kind = "cast", who = "you", oppTurn = true }
  end
  -- Clarion Spirit: "whenever you cast your second spell each turn" (also third...).
  do
    local ord = p:match("whenever you cast your (%a+) spell each turn")
    local ORDN = { second = 2, third = 3, fourth = 4, fifth = 5 }
    if ord and ORDN[ord] then
      return { kind = "cast", who = "you", nth = ORDN[ord] }
    end
  end
  -- Ugin, Eye of the Storms: "When you cast this spell".
  if plainFind(p, "when you cast this spell") or plainFind(p, "when you cast ~") then
    return { kind = "castSelf" }
  end
  -- Silver-Fur Master, Satoru Umezawa: "Whenever you activate a ninjutsu ability".
  if plainFind(p, "whenever you activate a ninjutsu ability") then
    return { kind = "ninjutsuAct" }
  end
  -- Diamond Mare: "whenever you cast a spell of the chosen color" (chosen as it entered: effects.lua).
  if plainFind(p, "whenever you cast a spell of the chosen color") then
    return { kind = "cast", who = "you", spellType = "chosen color" }
  end
  -- Gandalf, Westward Voyager: "whenever you cast a spell with mana value 5 or greater".
  do
    local mv = p:match("whenever you cast a spell with mana value (%d+) or greater")
    if mv then
      return { kind = "cast", who = "you", mvMin = tonumber(mv) }
    end
  end
  local castType = between(p, "whenever you cast a", " spell")
  castType = castType and castType:gsub("^n? ", "") or nil
  -- "Whenever you cast another Vampire spell" (Edgar Markov's eminence): the spell isn't this card.
  local another = false
  if castType and castType:find("^nother ") then
    castType, another = castType:sub(8), true
  end
  if castType and #castType < 30 and castType ~= "" then
    return { kind = "cast", who = "you", spellType = castType, other = another or nil }
  end
  if plainFind(p, "whenever you cast a spell") then
    return { kind = "cast", who = "you" }
  end
  return nil
end

-- Combat triggers in one paragraph (a paragraph can have several, like
-- "attacks or blocks"). Returns a list.
local function parseCombat(p)
  local out = {}
  local function add(t)
    table.insert(out, t)
  end
  -- Names that read as plural ("Raph & Mikey attack"): same trigger.
  if plainFind(p, "whenever ~ attack,") or plainFind(p, "whenever ~ attack ") then
    add({ kind = "attacks", self = true })
  end
  if plainFind(p, "whenever ~ attacks") or plainFind(p, "whenever ~ enters or attacks")
      or plainFind(p, "~ enters the battlefield or attacks") or plainFind(p, "whenever ~ and at least") then
    add({ kind = "attacks", self = true })
  end
  if plainFind(p, "~ attacks or blocks") or plainFind(p, "whenever ~ blocks") then
    add({ kind = "blocks", self = true })
  end
  if plainFind(p, "whenever ~ becomes blocked") or plainFind(p, "~ blocks or becomes blocked") then
    add({ kind = "blocked", self = true })
  end
  if plainFind(p, "whenever a non-human creature you control attacks") then
    add({ kind = "attacks", mine = true, nonType = "human" })
  elseif plainFind(p, "attacks alone") then
    if plainFind(p, "whenever a creature you control attacks alone") then
      add({ kind = "attacks", mine = true, alone = true })
    end
  elseif plainFind(p, "whenever a creature you control attacks") or plainFind(p, "whenever a nontoken creature you control attacks") then
    add({ kind = "attacks", mine = true })
  elseif between(p, "whenever a", " you control attacks,") or between(p, "whenever an", " you control attacks,") then
    -- Utvara Hellkite: "Whenever a Dragon you control attacks, ..." (only that creature type).
    local word = between(p, "whenever an", " you control attacks,") or between(p, "whenever a", " you control attacks,")
    word = tostring(word or ""):gsub("^n? ", ""):gsub("^%s+", "")
    if word ~= "" and not word:find(" ", 1, true) and #word < 20 then
      add({ kind = "attacks", mine = true, onlyType = word })
    end
  elseif plainFind(p, "whenever one or more creatures you control attack") or plainFind(p, "whenever you attack") then
    add({ kind = "attacks", mine = true, once = true })
  end
  if plainFind(p, "whenever a creature attacks you") or plainFind(p, "whenever one or more creatures attack you") then
    add({ kind = "attacks", targetsMe = true, once = plainFind(p, "one or more") })
  end
  -- Equipment / Auras: "whenever equipped creature attacks", "...deals combat damage to a player".
  for _, who in ipairs({ "equipped creature", "enchanted creature" }) do
    if plainFind(p, "whenever " .. who .. " attacks") or plainFind(p, "whenever the " .. who .. " attacks") then
      add({ kind = "attacks", equipped = true })
    end
    if plainFind(p, "whenever " .. who .. " deals combat damage to a player")
        or plainFind(p, "whenever " .. who .. " deals combat damage to an opponent")
        or plainFind(p, "whenever the " .. who .. " deals combat damage to a player") then
      add({ kind = "combatDamage", equipped = true })
    end
    if plainFind(p, "whenever " .. who .. " blocks") then
      add({ kind = "blocks", equipped = true })
    end
  end
  if plainFind(p, "whenever a modified creature you control deals combat damage to a player") then
    add({ kind = "combatDamage", mine = true, modified = true })
  elseif plainFind(p, "whenever ~ deals combat damage to a player") or plainFind(p, "whenever ~ deals combat damage to an opponent") then
    add({ kind = "combatDamage", self = true })
  elseif plainFind(p, "whenever a creature you control deals combat damage to a player")
      or plainFind(p, "whenever a creature you control deals combat damage to an opponent") then
    add({ kind = "combatDamage", mine = true })
  elseif plainFind(p, "whenever one or more creatures you control deal combat damage to a player") then
    add({ kind = "combatDamage", mine = true, once = true })
  elseif p:find("whenever one or more [%a ]- creatures you control deal combat damage to a player") then
    -- Prosperous Thief: "Whenever one or more Ninja or Rogue creatures you control deal combat damage to a player".
    local list = p:match("whenever one or more ([%a ]-) creatures you control deal combat damage to a player")
    local subs = {}
    for w in list:gmatch("%a+") do
      if w ~= "or" and w ~= "and" then
        table.insert(subs, "sub:" .. w)
      end
    end
    add({ kind = "combatDamage", mine = true, once = true, subjects = subs, subject = subs[1] })
  else
    -- "Whenever an Army you control deals combat damage to a player" (Sauron).
    local subj = between(p, "whenever an ", " you control deals combat damage to a player")
      or between(p, "whenever a ", " you control deals combat damage to a player")
    if subj and #subj < 30 and not subj:find(" ", 1, true) and subj ~= "creature" then
      local w = subj
      if w:sub(-1) == "s" and w:sub(-2) ~= "ss" then
        w = w:sub(1, -2)
      end
      add({ kind = "combatDamage", mine = true, subjects = { "sub:" .. w }, subject = "sub:" .. w })
    end
  end
  return out
end

-- A card's triggered abilities: { { trig, text } } (text = original wording).
-- Reminder text "(...)" explains a keyword; it isn't rules. Reading it as
-- rules made Dreadhorde Invasion's amass reminder create tokens and a
-- Case's "(If unsolved, solve at the beginning of your end step.)" trigger.
local function stripReminder(s)
  local out, depth = {}, 0
  for i = 1, #s do
    local ch = s:sub(i, i)
    if ch == "(" then
      depth = depth + 1
    elseif ch == ")" and depth > 0 then
      depth = depth - 1
    elseif depth == 0 then
      table.insert(out, ch)
    end
  end
  return (table.concat(out):gsub("%s+$", ""))
end
Triggers.stripReminder = stripReminder

---------------------------------------------------------------------------
-- Forge data: FORGE_TRIGGERS (forge_triggers_data.lua, made by
-- tools/forge_triggers.py from Forge's card scripts). For a card it knows,
-- each triggered paragraph's trigger comes from there; anything it doesn't
-- cover (or a paragraph with a trigger it can't express) is read from the
-- rules text as before. !triggers forge off / on switches it.
---------------------------------------------------------------------------

local FORGE_SELF_WORDS = { "this creature", "this permanent", "this artifact", "this enchantment", "this land",
  "this planeswalker", "this card", "this token", "this vehicle", "this case", "this class", "this saga",
  "this aura", "this equipment", "cardname", "nickname" }

local function replacePlain(s, needle, with)
  if needle == "" then
    return s
  end
  local out, i = {}, 1
  while true do
    local a, b = s:find(needle, i, true)
    if not a then
      break
    end
    table.insert(out, s:sub(i, a - 1))
    table.insert(out, with)
    i = b + 1
  end
  table.insert(out, s:sub(i))
  return table.concat(out)
end

-- Same as forge_key() in tools/forge_triggers.py: keep the two identical. (The data stores
-- each key cut short; forgeTriggers compares by prefix.)
local function forgeKey(text, name)
  local s = stripReminder(tostring(text or "")):lower()
  s = replacePlain(s, "enters the battlefield", "enters")
  s = replacePlain(s, "whenever", "when")      -- Forge's descriptions mix the two
  local full = tostring(name or ""):lower()
  local names = { full }
  local comma = full:find(",", 1, true)
  if comma then
    table.insert(names, full:sub(1, comma - 1))
  end
  for _, n in ipairs(names) do
    if #n > 1 then
      s = replacePlain(s, n, "")
    end
  end
  for _, w in ipairs(FORGE_SELF_WORDS) do
    s = replacePlain(s, w, "")
  end
  s = (s:gsub("[^a-z]", ""))
  return s:sub(1, 64)
end
Triggers.forgeKey = forgeKey

-- "enters|s=creature/artifact;mine;nth=2" -> { kind = "enters", subjects = {...}, mine = true, nth = 2 }
local function forgeDecode(kind, fields)
  local t = { kind = kind }
  for f in (fields .. ";"):gmatch("([^;]*);") do
    if f ~= "" then
      local eq = f:find("=", 1, true)
      if eq then
        local k, v = f:sub(1, eq - 1), f:sub(eq + 1)
        if k == "s" or k == "x" then
          local list = {}
          for w in (v .. "/"):gmatch("([^/]*)/") do
            if w ~= "" then
              table.insert(list, w)
            end
          end
          if k == "s" then
            t.subjects, t.subject = list, list[1]
          else
            t.excludes = list
          end
        else
          t[k] = tonumber(v) or v
        end
      else
        t[f] = true
      end
    end
  end
  return t
end

local forgeCache = {}
-- A card's Forge entries: { { key, trig } } (trig = false: Forge has a trigger there the data can't express).
local function forgeEntries(name)
  if FORGE_TRIGGERS == nil or name == nil then
    return nil
  end
  local hit = forgeCache[name]
  if hit ~= nil then
    return hit or nil
  end
  local raw = FORGE_TRIGGERS[name]
  if raw == nil then
    forgeCache[name] = false
    return nil
  end
  local list = {}
  for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
    local bar = line:find("|", 1, true)
    if bar then
      local key, rest = line:sub(1, bar - 1), line:sub(bar + 1)
      if rest == "?" then
        table.insert(list, { key = key, trig = false })
      else
        local bar2 = rest:find("|", 1, true)
        local kind = bar2 and rest:sub(1, bar2 - 1) or rest
        table.insert(list, { key = key, trig = forgeDecode(kind, bar2 and rest:sub(bar2 + 1) or "") })
      end
    end
  end
  forgeCache[name] = list
  return list
end

-- Pair a card's Forge entries with its paragraphs (already stripped of
-- reminder text). Returns { [paragraph index] = { trig, ... } } for the
-- paragraphs Forge covers, or nil. An entry is used only when its key fits
-- exactly one paragraph; a paragraph an entry can't be told apart for, or
-- one with a trigger the data can't express ("|?"), is read from its text.
local function forgeForParas(name, paras)
  if GameState.data and GameState.data.forgeOff then
    return nil
  end
  local entries = forgeEntries(name)
  if entries == nil then
    return nil
  end
  local keys = {}
  for i, p in ipairs(paras) do
    keys[i] = forgeKey(p, name)
  end
  local per, bad = {}, {}
  for _, e in ipairs(entries) do
    local hits = {}
    for i, k in ipairs(keys) do
      if k ~= "" and k:sub(1, #e.key) == e.key then
        table.insert(hits, i)
      end
    end
    if #hits == 1 then
      local i = hits[1]
      if e.trig == false then
        bad[i] = true
      else
        per[i] = per[i] or {}
        table.insert(per[i], e.trig)
      end
    else
      for _, i in ipairs(hits) do
        bad[i] = true
      end
    end
  end
  for i in pairs(bad) do
    per[i] = nil
  end
  return per
end
Triggers.forgeForParas = forgeForParas

function Triggers.setForge(on)
  GameState.data.forgeOff = not on or nil
  cache = {}
end

-- The Soul Stone's infinity ability only counts once it has been harnessed (effects.lua sets the flag).
local function visibleTo(obj, list)
  if not list.hasHarness then
    return list
  end
  local on = false
  pcall(function() on = (GameState.data.harnessed or {})[obj.getGUID()] == true end)
  if on then
    return list
  end
  local out = {}
  for _, e in ipairs(list) do
    if not e.harness then
      table.insert(out, e)
    end
  end
  return out
end

-- Exalted as the table resolves it: "it" is the creature that attacked alone (thatCard).
local EXALTED_TEXT = "Exalted \226\128\148 Whenever a creature you control attacks alone, it gets +1/+1 until end of turn."

-- Living weapon: an Equipment's own keyword, or given by Ekthi, Contaminator Priest ("Each Equipment you control
-- has living weapon"). The trigger: create a 0/0 black Phyrexian Germ and attach the Equipment to it.
local LIVING_WEAPON_TEXT = "Living weapon: when this Equipment enters, create a 0/0 black Phyrexian Germ creature token, then attach this Equipment to it."
local function livingWeapon(obj, d)
  if not tostring(d.typeLine or ""):lower():find("equipment", 1, true) then
    return false
  end
  for line in (tostring(d.oracle or "") .. "\n"):gmatch("([^\n]*)\n") do
    if stripReminder(line):lower():gsub("^%s+", ""):sub(1, 13) == "living weapon" then
      return true
    end
  end
  local okl, loc = pcall(function() return Zones.regionAt(obj.getPosition()) end)
  local seat = okl and loc and loc.seat or nil
  if seat == nil then
    return false
  end
  for _, o in ipairs(getObjectsWithTag("MTGCard")) do
    if o ~= obj and o.type == "Card" and not o.isDestroyed() and not o.is_face_down then
      local od = cardData(o)
      local ol = type(od) == "table" and tostring(od.oracle or ""):lower() or ""
      if ol:find("equipment you control has living weapon", 1, true) or ol:find("equipment you control have living weapon", 1, true) then
        local ok2, l2 = pcall(function() return Zones.regionAt(o.getPosition()) end)
        if ok2 and l2 and l2.seat == seat and (l2.region == "battlefield" or l2.region == "lands") then
          return true
        end
      end
    end
  end
  return false
end

local function abilitiesOf(obj)
  local d = cardData(obj)
  if d == nil or type(d) ~= "table" then
    return {}
  end
  local lw = livingWeapon(obj, d)
  -- Abilities other permanents give this one (Sliver lords...): part of the key, so they come and go.
  local given = ""
  if Statics and Statics.grants then
    local okg, g = pcall(Statics.grants, obj)
    if okg and g and #g.lines > 0 then
      given = table.concat(g.lines, "\n")
    end
  end
  if type(d.oracle) ~= "string" or d.oracle == "" then
    if given == "" then
      return {}
    end
    d = setmetatable({ oracle = "" }, { __index = d })
  end
  local key = obj.getGUID() .. "|" .. tostring(d.name) .. "|" .. given .. (lw and "|lw" or "")
  if cache[key] then
    return visibleTo(obj, cache[key])
  end
  local list = {}
  list.hasHarness = false
  -- "Choose one —" modes ("• ...") belong to the line before them.
  local paras = {}
  for _, raw in ipairs(lines(given ~= "" and (d.oracle .. "\n" .. given) or d.oracle)) do
    local first = raw:sub(1, 3)
    if #paras > 0 and (first == "•" or raw:sub(1, 1) == "\149" or raw:find("^%s*•")) then
      paras[#paras] = paras[#paras] .. "\n" .. raw
    else
      table.insert(paras, raw)
    end
  end
  local stripped = {}
  for i, raw in ipairs(paras) do
    stripped[i] = stripReminder(raw)
  end
  local forgeMap = forgeForParas(d.name, stripped) or {}
  for pi, raw in ipairs(paras) do
    local para = stripped[pi]
    -- Loyalty abilities ("-8: You get an emblem with 'Whenever...'") and activated abilities
    -- ("{3}{B}: ... 'Whenever this creature attacks...'") are not triggers of this card.
    local isActivated = false
    do
      local lowp = para:lower()
      local colon = para:find(":", 1, true)
      if colon then
        local w = lowp:find("whenever ", 1, true) or lowp:find("when ", 1, true) or lowp:find("at the beginning", 1, true)
        isActivated = (w == nil) or colon < w
      end
    end
    if para ~= "" and not isActivated then
      local norm = normalize(para, d.name)
      -- Quoted rules text belongs to a token or emblem, not to this card.
      norm = norm:gsub('"[^"]*"', "")
      local harness = para:sub(1, 3) == "\226\136\158"   -- the infinity sign: active once harnessed
      if harness then
        list.hasHarness = true
      end
      -- Forge's data first (a card's own printed paragraphs); the rules text otherwise.
      local fromForge = forgeMap[pi]
      if fromForge then
        for _, ft in ipairs(fromForge) do
          table.insert(list, { trig = ft, text = para, harness = harness, forge = true })
        end
      else
        local trig = parseTrigger(norm)
        if norm:find("whenever you play a land or cast a spell", 1, true) then
          table.insert(list, { trig = { kind = "enters", subject = "land", subjects = { "land" }, mine = true, playedOnly = true }, text = para })
          trig = { kind = "cast", who = "you" }
        end
        if trig then
          table.insert(list, { trig = trig, text = para, harness = harness })
        end
        for _, ct in ipairs(parseCombat(norm)) do
          table.insert(list, { trig = ct, text = para, harness = harness })
        end
      end
    end
  end
  -- Keyword attack triggers (Scryfall rules text often has no reminder
  -- text for these, so they're read from the keyword list).
  local KEYWORD_TRIGGERS = {
    annihilator = { kind = "attacks", self = true },
    ["battle cry"] = { kind = "attacks", self = true },
    melee = { kind = "attacks", self = true },
    myriad = { kind = "attacks", self = true },
    mentor = { kind = "attacks", self = true },
    training = { kind = "attacks", self = true },
    rampage = { kind = "blocked", self = true },
    afflict = { kind = "blocked", self = true },
    flanking = { kind = "blocked", self = true },
    exalted = { kind = "attacks", mine = true, alone = true },
    fabricate = { kind = "enters", self = true },
  }
  for _, kw in ipairs(type(d.keywords) == "table" and d.keywords or {}) do
    local k = tostring(kw):lower()
    -- Scryfall lists keywords a card only gives away ("Sliver creatures you control have exalted"):
    -- those aren't this card's own ability (it gets them through the grant below, if at all).
    local onlyGiven = false
    if KEYWORD_TRIGGERS[k] then
      local own, gives = false, false
      for _, para in ipairs(lines(d.oracle)) do
        local lp = stripReminder(para):lower()
        for tok in (lp .. ","):gmatch("([^,]*),") do
          if tok:gsub("^%s+", ""):sub(1, #k) == k then
            own = true
          end
        end
        if lp:find(" have " .. k, 1, true) or lp:find(" has " .. k, 1, true) or lp:find(", " .. k, 1, true) and lp:find(" ha", 1, true) then
          gives = true
        end
      end
      onlyGiven = gives and not own
    end
    if KEYWORD_TRIGGERS[k] and not onlyGiven then
      -- The keyword's own line in the rules text (e.g. "Annihilator 2").
      local text = tostring(kw)
      for _, para in ipairs(lines(d.oracle)) do
        if para:lower():sub(1, #k) == k then
          text = para
        end
      end
      if k == "exalted" then
        text = EXALTED_TEXT
      end
      local already = false
      for _, e in ipairs(list) do
        if e.text == text then
          already = true
        end
      end
      if not already then
        local trig = KEYWORD_TRIGGERS[k]
        table.insert(list, { trig = trig, text = text })
      end
    end
  end
  if lw then
    table.insert(list, { trig = { kind = "enters", self = true }, text = LIVING_WEAPON_TEXT })
  end
  -- Exalted given by other permanents (First Sliver's Chosen): one trigger per instance.
  if given ~= "" then
    for gl in (given .. "\n"):gmatch("([^\n]*)\n") do
      if gl == "exalted" then
        table.insert(list, { trig = KEYWORD_TRIGGERS.exalted, text = EXALTED_TEXT, granted = true })
      end
    end
  end
  cache[key] = list
  return visibleTo(obj, list)
end

-- Paragraphs that read like triggered abilities ("Whenever...", "When...",
-- "At the beginning of...") but that the table could not turn into a trigger
-- it can watch for. Returns a list of texts.
function Triggers.unrecognized(obj)
  local d = cardData(obj)
  if d == nil or type(d.oracle) ~= "string" or d.oracle == "" then
    return {}
  end
  local known = {}
  for _, a in ipairs(abilitiesOf(obj)) do
    known[a.text] = true
    known[(tostring(a.text):match("^[^\n]*"))] = true   -- a mode list counts under its first line
  end
  local out = {}
  for _, raw in ipairs(lines(d.oracle)) do
    local para = stripReminder(raw)
    local low = para:lower()
    if (low:sub(1, 9) == "whenever " or low:sub(1, 5) == "when " or low:sub(1, 21) == "at the beginning of t"
        or low:sub(1, 21) == "at the beginning of y" or low:sub(1, 21) == "at the beginning of e")
        and not known[para]
        and not low:find("becomes tapped, it deals %d+ damage to you")   -- City of Brass: handled when a player taps it (actions.lua)
        and not low:find("is tapped for mana, its controller adds an additional", 1, true)   -- Wild Growth: mana.lua adds it
        and not low:find("when this class becomes level", 1, true)
        and not low:find("when the fourth plan counter is put on", 1, true) then   -- Claim the Kingdom (effects.lua planCounter)   -- said when the Class levels up (effects.lua)
      table.insert(out, para)
    end
  end
  return out
end

local function typesOf(obj)
  local d = cardData(obj)
  local t = {}
  for _, name in ipairs(d and d.types or {}) do
    t[name:lower()] = true
  end
  return t
end

-- "Whenever a permanent you control enters tapped": does this one?
local function entersTappedNow(card)
  if Effects and Effects.entersTapped and Effects.entersTapped(card) == "yes" then
    return true
  end
  local loc = Zones.regionAt(card.getPosition())
  local s = loc.seat and TableSetup.seat(loc.seat)
  if s == nil then
    return false
  end
  local diff = ((card.getRotation().y - s.yaw + 540) % 360) - 180
  return math.abs(diff) > 30
end

-- Is this permanent of creature type `w` (lowercase, "ninja")? Its type line, changeling, Arcane
-- Adaptation ("creatures you control are the chosen type") and equipment such as Ninja's Blades
-- ("is a Ninja in addition to its other types").
function Triggers.hasCreatureType(obj, w)
  local d = cardData(obj)
  local tl = tostring(d and d.typeLine or ""):lower()
  if tl:find(w, 1, true) then
    return true
  end
  if not tl:find("creature", 1, true) then
    return false
  end
  local ol = tostring(d and d.oracle or ""):lower()
  if ol:find("changeling", 1, true) then
    return true
  end
  local seat
  pcall(function() seat = Zones.regionAt(obj.getPosition()).seat end)
  if seat and Statics and Statics.chosenType then
    for _, o in ipairs(getObjectsWithTag("MTGCard")) do
      if o ~= obj and o.type == "Card" and not o.isDestroyed() then
        local loc = Zones.regionAt(o.getPosition())
        if loc.seat == seat and (loc.region == "battlefield" or loc.region == "lands") then
          local od = cardData(o)
          local otext = tostring(od and od.oracle or ""):lower()
          if otext:find("creatures you control are the chosen type", 1, true) then
            local ty = Statics.chosenType(o)
            if ty and tostring(ty):lower() == w then
              return true
            end
          end
        end
      end
    end
  end
  if Equip and Equip.attachments then
    local oka, atts = pcall(Equip.attachments, obj)
    for _, a in ipairs(oka and atts or {}) do
      local ad = cardData(a)
      if tostring(ad and ad.oracle or ""):lower():find("is a " .. w .. " in addition to its other types", 1, true) then
        return true
      end
    end
  end
  return false
end

local function matchesSubject(obj, trig)
  local list = trig.subjects or { trig.subject }
  local types = typesOf(obj)
  for _, ex in ipairs(trig.excludes or {}) do
    if types[ex] then
      return false
    end
  end
  if trig.tokenOnly and not (obj.hasTag("Token") or types.token) then
    return false
  end
  for _, sub in ipairs(list) do
    if sub == nil or sub == "permanent" or types[sub] then
      return true
    end
    if type(sub) == "string" and sub:sub(1, 4) == "sub:" then
      if Triggers.hasCreatureType(obj, sub:sub(5)) then
        return true
      end
    end
  end
  return #list == 0
end

-- "of the chosen type": the card is the creature type its watcher chose as it entered.
local function chosenTypeOk(card, watcher)
  local ty = Statics and Statics.chosenType and Statics.chosenType(watcher)
  if ty == nil then
    return false
  end
  local d = cardData(card) or {}
  if Statics.typeMatches then
    return Statics.typeMatches(d.typeLine, d.oracle, ty) == true
  end
  return tostring(d.typeLine or ""):lower():find(ty:lower(), 1, true) ~= nil
end

local function isToken(obj)
  return obj.hasTag("Token") or typesOf(obj).token == true
end

local function faceOf(obj)
  local face = ""
  pcall(function()
    for _, d in pairs(obj.getData().CustomDeck or {}) do
      face = d.FaceURL
      break
    end
  end)
  return face
end

-- Every face-up card on a battlefield or lands area: { obj, controller }.
local function permanents()
  local list = {}
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not Faces.unknown(obj) and obj.held_by_color == nil then
      local loc = Zones.regionAt(obj.getPosition())
      if loc.seat and (loc.region == "battlefield" or loc.region == "lands") then
        table.insert(list, { obj = obj, controller = loc.seat })
      end
    end
  end
  -- The face-up plane: its triggered abilities belong to the planar controller (the active player, CR 901.6).
  if Planechase and Planechase.allPlanes and GameState.data.started then
    local okp, planes = pcall(Planechase.allPlanes)
    local t = GameState.data.turn or {}
    if okp and planes and t.activeSeat then
      for _, plane in ipairs(planes) do
        table.insert(list, { obj = plane, controller = t.activeSeat, plane = true })
      end
    end
  end
  return list
end

---------------------------------------------------------------------------
-- Putting found triggers on the stack (active player first)
---------------------------------------------------------------------------

local function turnOrder()
  local t = GameState.data.turn or {}
  local order = {}
  local seats = TableSetup.activeSeats()
  local start = 1
  for i, c in ipairs(seats) do
    if c == t.activeSeat then
      start = i
    end
  end
  for k = 0, #seats - 1 do
    table.insert(order, seats[((start - 1 + k) % #seats) + 1])
  end
  return order
end

---------------------------------------------------------------------------
-- Ordering: a player with two or more triggers at once picks the order they
-- resolve in (a panel only they see). Batches go one seat at a time, active
-- player first (APNAP), so later players' triggers land on top. Empty seats
-- and more than MAX_ORDER triggers use the order they were found in.
---------------------------------------------------------------------------

local MAX_ORDER = 10
local queue = {}      -- waiting batches: { seat, list }
local ordering = nil  -- the batch being ordered: { seat, list (resolve order), picks = { [i] = n }, count }

-- Triggers found but not on the stack yet (the turn waits for them).
function Triggers.isOrdering()
  return ordering ~= nil or #queue > 0
end

local function seated(color)
  local ok, yes = pcall(function() return Player[color].seated end)
  return ok and yes
end

local function push(f)
  -- that = "that player" in the effect (the one who drew, cast, whose
  -- creature entered...), for auto-resolve (effects.lua).
  Stack.pushAbility(f.controller, f.name or "?", f.text, f.face or "", { trigger = true, that = f.that, source = f.guid, thatCard = f.thatCard, amount = f.amount, grantedBy = f.grantedBy })
end

local function shortText(f)
  local t = tostring(f.text or "")
  if #t > 70 then
    t = t:sub(1, 68) .. "..."
  end
  return tostring(f.name) .. ": " .. t
end

local function renderOrder()
  for _, c in ipairs(TableSetup.activeSeats()) do
    local o = ordering and ordering.seat == c and ordering or nil
    UI.setAttribute("trigOrder_" .. c, "active", o and "true" or "false")
    if o then
      for i = 1, MAX_ORDER do
        local id = "trigRow_" .. c .. "_" .. i
        local f = o.list[i]
        UI.setAttribute(id, "active", f and "true" or "false")
        if f then
          local n = o.picks[i]
          local key = c .. "_" .. i
          UI.setValue("trigTxt_" .. key, (n and ("[" .. n .. "]  ") or "") .. shortText(f))
          UI.setAttribute("trigBtn_" .. key, "tooltip", tostring(f.name) .. "\n" .. tostring(f.text or ""))
          UI.setAttribute("trigBtn_" .. key, "color", n and "#1B4A5A" or "#141B26")
        end
      end
      UI.setAttribute("trigOrder_" .. c, "height", tostring(118 + 40 * #o.list))
    end
  end
end

local processNext
local finishOrdering
local ORDER_TIMEOUT = 25   -- seconds before an unanswered ordering panel keeps the found order

-- Put a batch on the stack. `resolveOrder` lists them first-to-resolve
-- first, so they're pushed from the end (the last pushed resolves first).
local function pushInResolveOrder(resolveOrder)
  for i = #resolveOrder, 1, -1 do
    push(resolveOrder[i])
  end
end

processNext = function()
  while #queue > 0 do
    local b = table.remove(queue, 1)
    -- Triggers that all do the same thing (five exalted triggers) can go in any order: don't ask.
    local kinds, nk = {}, 0
    for _, f in ipairs(b.list) do
      local k = f.sameKey or (tostring(f.guid or f.name) .. "|" .. tostring(f.text))
      if not kinds[k] then
        kinds[k] = true
        nk = nk + 1
      end
    end
    local askOrder = #b.list >= 2 and nk >= 2 and #b.list <= MAX_ORDER and seated(b.seat)
      and not (GameState.data and GameState.data.autoOrder)
    if askOrder then
      -- Shown in resolve order: as found, the first found resolves last.
      local shown = {}
      for i = #b.list, 1, -1 do
        table.insert(shown, b.list[i])
      end
      ordering = { seat = b.seat, list = shown, picks = {}, count = 0 }
      renderOrder()
      broadcastToColor("You have " .. #b.list .. " triggers at once: click them in the order they should resolve"
        .. " (or KEEP THIS ORDER). If you don't answer in " .. ORDER_TIMEOUT .. " s they go in the order shown.", b.seat, { 0.35, 0.95, 1 })
      -- An unanswered panel (player away, lag, panel hidden) must not hold up every later trigger.
      local mine = ordering
      Wait.time(function()
        if ordering == mine and ordering ~= nil then
          broadcastToAll("MTG > " .. tostring(mine.seat) .. " didn't order their triggers in time: using the order shown.", { 1, 0.8, 0.3 })
          finishOrdering(mine.list)
        end
      end, ORDER_TIMEOUT)
      return
    end
    for _, f in ipairs(b.list) do
      push(f)
    end
  end
  ordering = nil
  renderOrder()
end

finishOrdering = function(resolveOrder)
  ordering = nil
  renderOrder()
  pushInResolveOrder(resolveOrder)
  processNext()
end

-- !triggers flush: put anything waiting on the stack now (a stuck ordering panel).
-- !unstick: put whatever is waiting to be ordered onto the stack, then clear the panels.
function Triggers.unstick()
  local n = #queue + (ordering and 1 or 0)
  local guard = 0
  while (ordering or #queue > 0) and guard < 20 do
    guard = guard + 1
    local ok = pcall(Triggers.flush)
    if not ok then
      break
    end
  end
  queue = {}
  ordering = nil
  pcall(renderOrder)
  return n
end

function Triggers.flush()
  if ordering then
    finishOrdering(ordering.list)
  else
    processNext()
  end
end

function ui_trigOrder(player, arg)
  local seat, what = tostring(arg):match("^(%a+)_(%w+)$")
  local o = ordering
  if o == nil or seat ~= o.seat then
    return
  end
  if player.color ~= seat and not GameState.solo() then
    return
  end
  if what == "keep" then
    finishOrdering(o.list)
  elseif what == "reset" then
    o.picks, o.count = {}, 0
    renderOrder()
  else
    local i = tonumber(what)
    if i == nil or o.list[i] == nil or o.picks[i] then
      return
    end
    o.count = o.count + 1
    o.picks[i] = o.count
    if o.count == #o.list then
      local order = {}
      for k, f in ipairs(o.list) do
        order[o.picks[k]] = f
      end
      finishOrdering(order)
    else
      renderOrder()
    end
  end
end

function Triggers.orderXml()
  local parts = {}
  for _, c in ipairs(TableSetup.activeSeats()) do
    local rows = {}
    for i = 1, MAX_ORDER do
      -- A Text over the button carries the label (changing a Button's own
      -- text from script didn't show in TTS).
      table.insert(rows, ('      <Panel id="trigRow_%s_%d" active="false" preferredHeight="34">'
        .. '<Button id="trigBtn_%s_%d" onClick="ui_trigOrder(%s_%d)" color="#141B26" tooltipPosition="Above" />'
        .. '<Text id="trigTxt_%s_%d" raycastTarget="false" fontSize="13" color="#E6F1FF" alignment="MiddleLeft" '
        .. 'rectAlignment="MiddleCenter" offsetXY="10 0">-</Text></Panel>'):format(c, i, c, i, c, i, c, i))
    end
    table.insert(parts, ([[
<Panel id="trigOrder_%s" visibility="%s" active="false" rectAlignment="MiddleLeft" offsetXY="20 60" width="600" height="200"
       color="#0B0F17F5" outline="#5AF0FF" outlineSize="2 2" allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="14 14 12 12" spacing="6" childForceExpandHeight="false">
    <Text fontSize="17" fontStyle="Bold" color="#5AF0FF" alignment="MiddleLeft" preferredHeight="24">ORDER YOUR TRIGGERS</Text>
    <Text fontSize="12" color="#8B98A9" alignment="MiddleLeft" preferredHeight="30">Click them in the order they should resolve: [1] resolves first. KEEP THIS ORDER resolves them top to bottom.</Text>
]] .. table.concat(rows, "\n") .. [[

    <HorizontalLayout preferredHeight="38" spacing="10">
      <Button onClick="ui_trigOrder(%s_keep)" color="#00B3A4" textColor="#06130B" fontStyle="Bold">KEEP THIS ORDER</Button>
      <Button onClick="ui_trigOrder(%s_reset)" color="#2A3346" textColor="#E6F1FF" fontStyle="Bold">RESET</Button>
    </HorizontalLayout>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, c))
  end
  return table.concat(parts)
end

-- Triggers of the Equipment / Auras attached to `creature` that watch for
-- `kind` ("attacks", "combatDamage", "blocks"): found-list entries.
local function attachedTriggers(creature, kind)
  local out = {}
  if Equip == nil or creature == nil or creature.isDestroyed() then
    return out
  end
  for _, a in ipairs(Equip.attachments(creature)) do
    local loc = Zones.regionAt(a.getPosition())
    local seat = loc.seat or (Zones.regionAt(creature.getPosition()).seat)
    for _, ab in ipairs(abilitiesOf(a)) do
      if ab.trig.equipped and ab.trig.kind == kind then
        table.insert(out, { obj = a, controller = seat, text = ab.text, host = creature.getGUID() })
      end
    end
  end
  return out
end

-- The Ring-bearer's level triggers (ring.lua): found-list entries with a face.
local function ringTriggers(obj, kind)
  if Ring == nil then
    return {}
  end
  local list = Ring.triggers(obj, kind)
  for _, f in ipairs(list) do
    f.face = faceOf(obj)
  end
  return list
end

-- Found triggers go out one seat at a time, active player first.
local function pushAll(found, that, thatCard)
  if #found == 0 then
    return
  end
  -- "This ability triggers only once each turn."
  local kept = {}
  local t = GameState.data.turn or {}
  GameState.data.oncePerTurn = GameState.data.oncePerTurn or {}
  for _, f in ipairs(found) do
    local once = tostring(f.text):lower():find("only once each turn", 1, true)
    local key
    if once then
      local ok, g = pcall(function() return f.obj.getGUID() end)
      key = (ok and g or "?") .. "|" .. tostring(f.text):sub(1, 40)
    end
    if key and GameState.data.oncePerTurn[key] == t.taken then
      -- Already triggered this turn.
    else
      if key then
        GameState.data.oncePerTurn[key] = t.taken
      end
      table.insert(kept, f)
    end
  end
  found = kept
  -- Intervening "if" (CR 603.4): "At the beginning of your upkeep, if you control three or more artifacts, ..."
  -- doesn't trigger at all unless it's true now (it's checked again as it resolves).
  kept = {}
  for _, f in ipairs(found) do
    local low = tostring(f.text or ""):lower()
    local cond = low:match("^%s*whenever [^,]-, if ([^,]+),") or low:match("^%s*when [^,]-, if ([^,]+),")
      or low:match("^%s*at the [^,]-, if ([^,]+),")
    local holds = nil
    if cond and Effects and Effects.condValue then
      local nm = ""
      pcall(function() nm = tostring(f.obj.getName() or ""):lower() end)
      if nm ~= "" then
        cond = replacePlain(cond, nm, "~")
      end
      local okc, v = pcall(Effects.condValue, cond, f.controller, f.obj and f.obj.getName and f.obj.getName() or nil)
      if okc then
        holds = v
      end
    end
    if holds == false then
      local nm = "?"
      pcall(function() nm = f.obj.getName() end)
      printToAll("MTG > " .. nm .. " doesn't trigger (not true: " .. cond .. ").", { 0.6, 0.65, 0.75 })
    else
      table.insert(kept, f)
    end
  end
  found = kept
  if #found == 0 then
    return
  end
  -- Roaming Throne: an additional time for creatures of the chosen type.
  if Statics and Statics.extraTriggers then
    local extra = {}
    for _, f in ipairs(found) do
      local ok, k = pcall(Statics.extraTriggers, f.obj, f.controller)
      for _ = 1, ok and k or 0 do
        local c2 = {}
        for kk, vv in pairs(f) do
          c2[kk] = vv
        end
        table.insert(extra, c2)
      end
    end
    if #extra > 0 then
      printToAll("MTG > Roaming Throne: " .. #extra .. " trigger(s) happen an additional time.", { 0.55, 0.9, 0.6 })
      for _, c2 in ipairs(extra) do
        table.insert(found, c2)
      end
    end
  end
  for _, f in ipairs(found) do
    f.that = f.that or that
    f.thatCard = f.thatCard or thatCard
    -- Name and picture now: the card object can be gone by the time the
    -- trigger goes on the stack (merged into a pile, replaced...).
    if f.name == nil then
      local ok, name = pcall(function() return f.obj.getName() end)
      f.name = ok and name or "Trigger"
      local ok2, guid = pcall(function() return f.obj.getGUID() end)
      f.guid = ok2 and guid or nil
      f.face = faceOf(f.obj)
    end
    -- An ability another permanent gave it (Tempered Sliver's, on Manaweft Sliver): say whose it is.
    if f.grantedBy == nil and Statics and Statics.grantedBy then
      if f.text == EXALTED_TEXT then
        local okx, gx = pcall(Statics.grants, f.obj)
        if okx and gx then
          for i, l in ipairs(gx.lines) do
            if l == "exalted" then
              f.grantedBy = gx.from[i]
            end
          end
        end
      else
        local okb, by = pcall(Statics.grantedBy, f.obj, f.text)
        if okb then
          f.grantedBy = by
        end
      end
    end
  end
  for _, seat in ipairs(turnOrder()) do
    local list = {}
    for _, f in ipairs(found) do
      if f.controller == seat then
        table.insert(list, f)
      end
    end
    if #list > 0 then
      table.insert(queue, { seat = seat, list = list })
    end
  end
  if ordering == nil then
    processNext()
  end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

-- A step began.
Events.on("stepStarted", function(d)
  if not enabled() or not GameState.data.started or d.step == "untap" or d.step == "cleanup" then
    return
  end
  local found = {}
  for _, p in ipairs(permanents()) do
    for _, a in ipairs(abilitiesOf(p.obj)) do
      local t = a.trig
      if t.kind == "step" and (t.step == d.step or (t.step == "main" and (d.step == "main1" or d.step == "main2"))) then
        -- 2HG: "your upkeep / your end step" is the whole team's (both teammates take the turn).
        local mine = p.controller == d.seat
          or (Turns and Turns.isActiveSeat and Turns.isActiveSeat(d.seat) and Turns.isActiveSeat(p.controller))
        local oppOf = d.seat
        local hostOk = false
        if t.who == "host" and Equip then
          -- "At the beginning of the upkeep of enchanted creature's controller" (Curses, Auras).
          local host = Equip.hostOf(p.obj)
          hostOk = host ~= nil and not host.isDestroyed() and Zones.regionAt(host.getPosition()).seat == d.seat
        end
        -- 2HG: both teammates are in their draw step (upkeep...) at once, so "each player's draw step" (Howling
        -- Mine) and "each opponent's upkeep" happen once for each player on the active team, "that player" each.
        local team = { d.seat }
        if (t.who == "each" or t.who == "opp") and TableSetup.isTeamGame and TableSetup.isTeamGame() and Turns and Turns.activeTeam then
          team = Turns.activeTeam()
          if #team == 0 then
            team = { d.seat }
          end
        end
        if t.who == "each" then
          for _, who in ipairs(team) do
            table.insert(found, { obj = p.obj, controller = p.controller, text = a.text, that = who })
          end
        elseif t.who == "opp" then
          for _, who in ipairs(team) do
            if TableSetup.isOpponent(p.controller, who) then
              table.insert(found, { obj = p.obj, controller = p.controller, text = a.text, that = who })
            end
          end
        elseif (t.who == "you" and mine) or hostOk then
          table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
        end
      end
    end
  end
  pushAll(found, d.seat)
end)

local IN_PLAY = { battlefield = true, lands = true }

-- Something entered or left the battlefield.
Events.on("cardMoved", function(d)
  if not enabled() or not GameState.data.started or d.card == nil or d.from == nil or d.to == nil then
    return
  end
  local card = d.card
  if card.isDestroyed() or Faces.unknown(card) then
    return
  end
  -- A card drawn: library -> hand.
  if d.from.region == "library" and d.to.region == "hand" and d.to.seat then
    local sg = GameState.data.searched
    if sg and sg[card.getGUID()] then
      sg[card.getGUID()] = nil      -- taken by a library search, not drawn
      return
    end
    -- Notion Thief: an opponent's extra draw is skipped; its controller draws instead.
    if Statics and Statics.drawReplacer then
      local gd = GameState.data
      local tt = gd.turn or {}
      local stepId = tt.stepIndex and Turns.STEPS[tt.stepIndex] and Turns.STEPS[tt.stepIndex].id
      gd.drawStep = gd.drawStep or {}
      local first = false
      if stepId == "draw" and Turns.isActiveSeat(d.to.seat) then
        local key = tostring(tt.taken) .. "|" .. d.to.seat
        gd.drawStep[key] = (gd.drawStep[key] or 0) + 1
        first = gd.drawStep[key] == 1
      end
      if not first then
        local thief, thiefObj = Statics.drawReplacer(d.to.seat)
        if thief then
          printToAll("MTG > " .. thiefObj.getName() .. ": " .. d.to.seat .. "'s draw is skipped (" .. card.getName() .. " goes back on top), "
            .. thief .. " draws a card instead.", { 0.55, 0.9, 0.6 })
          local who = d.to.seat
          Library.putAt(who, card, 0, function()
            Actions.draw(thief, 1, thiefObj.getName())
          end)
          return
        end
      end
    end
    do
      local gd = GameState.data
      local turnNo = gd.turn and gd.turn.taken
      local dl = gd.drawLog
      if dl == nil or dl.turn ~= turnNo then
        dl = { turn = turnNo, by = {} }
        gd.drawLog = dl
      end
      dl.by[d.to.seat] = (dl.by[d.to.seat] or 0) + 1
    end
    local found = {}
    for _, p in ipairs(permanents()) do
      for _, a in ipairs(abilitiesOf(p.obj)) do
        local t = a.trig
        if t.kind == "draw" then
          local mine = p.controller == d.to.seat
          local oppOf = d.to.seat
          local nthOk = true
          if t.nth then
            nthOk = (GameState.data.drawLog and GameState.data.drawLog.by[d.to.seat] or 0) == t.nth
          end
          if nthOk and (t.who == "each" or (t.who == "you" and mine) or (t.who == "opp" and TableSetup.isOpponent(p.controller, oppOf))) then
            table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
          end
        end
      end
    end
    pushAll(found, d.to.seat)
    return
  end
  local entering = IN_PLAY[d.to.region] and not IN_PLAY[d.from.region]
  local leaving = IN_PLAY[d.from.region] and not IN_PLAY[d.to.region]
  local dying = IN_PLAY[d.from.region] and d.to.region == "graveyard" and (typesOf(card).creature or typesOf(card).artifact)
  -- A card discarded (hand -> graveyard): "whenever you discard a card", madness-style "when you discard ~".
  if d.from.region == "hand" and d.to.region == "graveyard" and d.from.seat then
    Triggers.onDiscard(card, d.from.seat)
    return
  end
  if not entering and not leaving then
    return
  end
  -- One move can be several events: a creature dying also leaves the battlefield.
  local kinds = entering and { "enters" } or (dying and { "dies", "leaves" } or { "leaves" })
  local cardController = entering and d.to.seat or d.from.seat
  -- Warn about triggers the table can't watch for on a card that just arrived.
  if entering and cardController then
    local ok, miss = pcall(Triggers.unrecognized, card)
    if ok and #miss > 0 then
      for _, text in ipairs(miss) do
        broadcastToColor(card.getName() .. ": I can't watch for \"" .. text:sub(1, 90) .. (#text > 90 and "..." or "")
          .. "\" automatically. When it happens, right-click the card > Ability to stack.", cardController, { 1, 0.75, 0.3 })
      end
    end
  end
  local found = {}
  for _, kind in ipairs(kinds) do
    -- The card's own "when ~ enters / dies / leaves the battlefield".
    for _, a in ipairs(abilitiesOf(card)) do
      if a.trig.kind == kind and (a.trig.self or a.trig.orSelf) then
        table.insert(found, { obj = card, controller = cardController, text = a.text })
      end
    end
    -- Auras and Equipment on it: "when enchanted creature dies / leaves the battlefield".
    if kind ~= "enters" then
      for _, f in ipairs(attachedTriggers(card, kind)) do
        f.thatCard = card.getGUID()
        table.insert(found, f)
      end
    end
    -- Other permanents watching for it (an Aura's "enchanted creature" triggers come from the card above).
    for _, p in ipairs(permanents()) do
      if p.obj ~= card then
        for _, a in ipairs(abilitiesOf(p.obj)) do
          local t = a.trig
          if t.kind == kind and not t.self and not t.equipped and matchesSubject(card, t)
              and not (t.chosenType and not chosenTypeOk(card, p.obj))
              and not (t.tapped and not entersTappedNow(card))
              and not (t.goaded and not (Counters.goadedBy(card) and Combat and Combat.inCombat and Combat.inCombat(card)))
              and not (t.nontoken and isToken(card))
              and not (t.playedOnly and d.from.region ~= "hand")
              and not ((t.powerMin or t.toughMin) and not (function()
                pcall(Statics.compute)   -- anthems (Lieges...) count toward the power
                local st = Counters.stats(card)
                return (tonumber(st.power) or 0) >= (t.powerMin or -99) and (tonumber(st.toughness) or 0) >= (t.toughMin or -99)
              end)())
              and not (t.mine and cardController ~= p.controller)
              and not (t.theirs and not TableSetup.isOpponent(cardController, p.controller)) then
            table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
          end
        end
      end
    end
  end
  -- Panharmonicon: an artifact or creature entering makes your triggered abilities trigger an additional time.
  if entering and Statics and Statics.panharmonicons then
    local ty = typesOf(card)
    if ty.creature or ty.artifact then
      local extra = {}
      for _, f in ipairs(found) do
        local k = Statics.panharmonicons(f.controller)
        for _ = 1, k do
          local c2 = {}
          for kk, vv in pairs(f) do
            c2[kk] = vv
          end
          table.insert(extra, c2)
        end
      end
      if #extra > 0 then
        printToAll("MTG > Panharmonicon: " .. #extra .. " trigger(s) happen an additional time.", { 0.55, 0.9, 0.6 })
      end
      for _, c2 in ipairs(extra) do
        table.insert(found, c2)
      end
    end
  end
  -- "Whenever a creature dies" on a creature that died with it isn't
  -- checked (it's already in the graveyard): add those by hand.
  pushAll(found, cardController, card.getGUID())
end)

-- A player picked this card as the target of their spell or ability (effects.lua).
function Triggers.onTargeted(obj, bySeat)
  if not enabled() or not GameState.data.started or obj == nil or obj.isDestroyed() then
    return
  end
  local found = {}
  -- Other permanents that watch for their friends being targeted (Diffusion Sliver).
  for _, p in ipairs(permanents()) do
    if p.obj ~= obj then
      for _, a in ipairs(abilitiesOf(p.obj)) do
        local tr = a.trig
        if tr.kind == "targeted" and tr.mine and not tr.self and (not tr.opp or bySeat ~= p.controller) and matchesSubject(obj, tr) then
          local ownerSeat
          pcall(function() ownerSeat = Zones.regionAt(obj.getPosition()).seat end)
          if ownerSeat == p.controller then
            table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
          end
        end
      end
    end
  end
  for _, p in ipairs(permanents()) do
    if p.obj == obj then
      for _, a in ipairs(abilitiesOf(obj)) do
        local tr = a.trig
        if tr.kind == "targeted" and tr.self and (not tr.opp or bySeat ~= p.controller) then
          -- "...becomes the target..., exile ~": it leaves before the spell can do anything
          -- (the table applies the spell right away), so the spell has no target left.
          local low = tostring(a.text):lower()
          local nm = obj.getName():lower()
          local short = nm:match("^([^,]+),")
          local tail = low:match(", exile (.-)%.?$")
          if tail and (tail == nm or tail == short or tail == "it" or tail == "this creature") and Combat and Combat.removeCard then
            printToAll("MTG > " .. obj.getName() .. " was targeted by " .. bySeat .. " and is exiled in response: the spell or ability has no target.", { 1, 0.75, 0.3 })
            Combat.removeCard(obj, "exile")
            return true
          end
          table.insert(found, { obj = obj, controller = p.controller, text = a.text })
        end
      end
    end
  end
  pushAll(found, bySeat, obj.getGUID())
  return false
end

-- The last counter of a kind left a card ("when ~ has no ice counters on it").
function Triggers.onCountersGone(obj, kind)
  if not enabled() or not GameState.data.started then
    return
  end
  local found = {}
  for _, p in ipairs(permanents()) do
    if p.obj == obj then
      for _, a in ipairs(abilitiesOf(obj)) do
        local tr = a.trig
        if tr.kind == "nocounters" then
          local w = tostring(tr.counter)
          local isPlus = w == "+1/+1" and kind == "plus"
          local isMinus = w == "-1/-1" and kind == "minus"
          if isPlus or isMinus or (kind == "other" and w ~= "+1/+1" and w ~= "-1/-1") then
            table.insert(found, { obj = obj, controller = p.controller, text = a.text })
          end
        end
      end
    end
  end
  pushAll(found, nil, obj.getGUID())
end

-- Counters were put on a permanent (counters.lua): "whenever you put one or
-- more counters on a Goblin you control".
function Triggers.onCounters(obj, kind, amount, byColor)
  if not enabled() or not GameState.data.started or obj == nil or obj.isDestroyed() then
    return
  end
  local loc = Zones.regionAt(obj.getPosition())
  if not IN_PLAY[loc.region] or loc.seat == nil then
    return
  end
  local found = {}
  for _, p in ipairs(permanents()) do
    for _, a in ipairs(abilitiesOf(p.obj)) do
      local t = a.trig
      if t.kind == "counters" and matchesSubject(obj, t)
          and not (t.counterKind == "plus" and kind ~= "plus")
          and not (t.mine and loc.seat ~= p.controller) then
        table.insert(found, { obj = p.obj, controller = p.controller, text = a.text, amount = amount })
      end
    end
  end
  pushAll(found, loc.seat, obj.getGUID())
end

-- The Ring tempted `seat` (ring.lua): "whenever the Ring tempts you".
function Triggers.onRing(seat)
  if not enabled() or not GameState.data.started then
    return
  end
  local found = {}
  for _, p in ipairs(permanents()) do
    for _, a in ipairs(abilitiesOf(p.obj)) do
      if a.trig.kind == "ring" and p.controller == seat then
        table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
      end
    end
  end
  pushAll(found, seat)
end

-- A player's life changed (called by trackers.lua): "whenever an opponent
-- loses life", "whenever you gain life". `amount` is how much, for
-- "that much life".
function Triggers.onLife(seat, delta)
  if not enabled() or not GameState.data.started or delta == 0 then
    return
  end
  local dir = delta > 0 and "gain" or "loss"
  local found = {}
  for _, p in ipairs(permanents()) do
    for _, a in ipairs(abilitiesOf(p.obj)) do
      local t = a.trig
      if t.kind == "life" and t.dir == dir then
        local mine = p.controller == seat
        local oppOf = seat
        if (t.who == "you" and mine) or (t.who == "opp" and TableSetup.isOpponent(p.controller, oppOf)) then
          table.insert(found, { obj = p.obj, controller = p.controller, text = a.text, amount = math.abs(delta) })
        end
      end
    end
  end
  pushAll(found, seat)
end

-- A spell was cast (put on the stack).
local COLOR_LETTER = { white = "W", blue = "U", black = "B", red = "R", green = "G" }

-- The spell's colors as letters ("W", "U"...): Scryfall colors, else the mana cost's symbols.
local function spellColors(card)
  local dd = cardData(card)
  local out = {}
  if dd and type(dd.colors) == "table" then
    for _, c in pairs(dd.colors) do
      out[tostring(c)] = true
    end
  end
  if next(out) == nil and dd and dd.manaCost then
    for sym in tostring(dd.manaCost):gmatch("{([^}]*)}") do
      for l in sym:gmatch("[WUBRG]") do
        out[l] = true
      end
    end
  end
  return out
end

local function spellMatches(card, spellType, source)
  if spellType == nil then
    return true
  end
  if spellType == "chosen number" then
    local n = source and Effects and Effects.chosenNumber and Effects.chosenNumber(source)
    if n == nil then
      return false
    end
    local cd = cardData(card) or {}
    return tonumber(cd.cmc) == n or tonumber(cd.power) == n or tonumber(cd.toughness) == n
  end
  if spellType == "chosen color" then
    local chosen = source and Effects and Effects.chosenColor and Effects.chosenColor(source)
    if chosen == nil then
      return false
    end
    return spellColors(card)[COLOR_LETTER[chosen:lower()] or "?"] == true
  end
  local t = typesOf(card)
  if spellType == "noncreature" then
    return not t.creature
  end
  if spellType == "instant or sorcery" then
    return t.instant or t.sorcery
  end
  if spellType == "colorless" then
    local dd = cardData(card)
    local cols = dd and dd.colors
    local n = 0
    if type(cols) == "table" then
      for _ in pairs(cols) do
        n = n + 1
      end
    end
    return n == 0 and not t.land
  end
  -- "Whenever you cast a red spell" / "a multicolored spell" (Forge data uses these).
  if COLOR_LETTER[spellType] then
    return spellColors(card)[COLOR_LETTER[spellType]] == true
  end
  if spellType == "multicolored" then
    local n = 0
    for _ in pairs(spellColors(card)) do
      n = n + 1
    end
    return n >= 2
  end
  local first = spellType:match("^(%a+)")
  if first == nil then
    return false
  end
  if t[first] == true then
    return true
  end
  -- A creature type ("vampire", "dragon"): from the type line.
  local tl = tostring((cardData(card) or {}).typeLine or ""):lower()
  return tl:find(first, 1, true) ~= nil and tl:find("creature", 1, true) ~= nil
end

-- A Forge spell/card filter (tools/forge_triggers.py spell_filter): "alt/alt", each
-- alternative words joined by "+" that must all hold: card types, sub:<subtype>,
-- colors, colorless, multicolored, non<type>, historic, legendary, permanent,
-- mvge=N, mvle=N.
local function spellSpecMatches(card, spec)
  local t = typesOf(card)
  local d = cardData(card) or {}
  local tl = tostring(d.typeLine or ""):lower()
  local cols
  for alt in (tostring(spec) .. "/"):gmatch("([^/]*)/") do
    local ok = alt ~= ""
    for w in (alt .. "+"):gmatch("([^+]*)%+") do
      if ok and w ~= "" then
        if w:sub(1, 4) == "sub:" then
          ok = tl:find(w:sub(5), 1, true) ~= nil
        elseif w:sub(1, 5) == "mvge=" then
          ok = (tonumber(d.cmc) or 0) >= (tonumber(w:sub(6)) or 0)
        elseif w:sub(1, 5) == "mvle=" then
          ok = (tonumber(d.cmc) or 0) <= (tonumber(w:sub(6)) or 99)
        elseif w == "permanent" then
          ok = not t.instant and not t.sorcery
        elseif w == "historic" then
          ok = t.artifact == true or tl:find("legendary", 1, true) ~= nil or tl:find("saga", 1, true) ~= nil
        elseif w == "legendary" then
          ok = tl:find("legendary", 1, true) ~= nil
        elseif COLOR_LETTER[w] or w == "colorless" or w == "multicolored" then
          cols = cols or spellColors(card)
          local n = 0
          for _ in pairs(cols) do
            n = n + 1
          end
          if w == "colorless" then
            ok = n == 0
          elseif w == "multicolored" then
            ok = n >= 2
          else
            ok = cols[COLOR_LETTER[w]] == true
          end
        elseif w:sub(1, 3) == "non" then
          ok = not t[w:sub(4)]
        else
          ok = t[w] == true
        end
      end
    end
    if ok then
      return true
    end
  end
  return false
end
Triggers.spellSpecMatches = spellSpecMatches

local function whoMatches(t, seat, controller)
  return t.who == nil or t.who == "each" or (t.who == "you" and seat == controller) or (t.who == "opp" and TableSetup.isOpponent(seat, controller))
end

-- One event about a card (sacrificed, discarded, cycled, tapped, untapped): the
-- card's own triggers ("when ~ is ..."), its Auras/Equipment ("enchanted
-- creature"), and other permanents watching for it. seat = the player it
-- happened to (its controller, or the player who discarded / cycled it).
local function cardEvent(kind, card, seat)
  if not enabled() or not GameState.data.started or card == nil or card.isDestroyed() then
    return
  end
  local found = {}
  for _, a in ipairs(abilitiesOf(card)) do
    if a.trig.kind == kind and (a.trig.self or a.trig.orSelf) then
      table.insert(found, { obj = card, controller = seat, text = a.text })
    end
  end
  for _, f in ipairs(attachedTriggers(card, kind)) do
    f.thatCard = card.getGUID()
    table.insert(found, f)
  end
  for _, p in ipairs(permanents()) do
    if p.obj ~= card then
      for _, a in ipairs(abilitiesOf(p.obj)) do
        local t = a.trig
        if t.kind == kind and not t.self and not t.equipped and matchesSubject(card, t)
            and not (t.mine and seat ~= p.controller) and not (t.theirs and not TableSetup.isOpponent(seat, p.controller))
            and not (t.nontoken and isToken(card)) and not (t.tokenOnly and not isToken(card))
            and whoMatches(t, seat, p.controller) and (t.spell == nil or spellSpecMatches(card, t.spell)) then
          table.insert(found, { obj = p.obj, controller = p.controller, text = a.text, thatCard = card.getGUID() })
        end
      end
    end
  end
  pushAll(found, seat)
end

-- A permanent was sacrificed (combat.lua Combat.sacrifice: costs and effects that sacrifice).
function Triggers.onSacrificed(obj, seat)
  cardEvent("sacrificed", obj, seat)
end

-- A card went from a player's hand to their graveyard (triggers.lua cardMoved).
function Triggers.onDiscard(card, seat)
  cardEvent("discard", card, seat)
end

-- A card was cycled (stack.lua: right-click > Cycle).
function Triggers.onCycled(card, seat)
  cardEvent("cycled", card, seat)
end

-- A permanent became tapped / untapped (a player turning it, attacking, a {T} cost, the untap step).
function Triggers.onTapped(obj, seat)
  cardEvent("tapped", obj, seat)
end

function Triggers.onUntapped(obj, seat)
  cardEvent("untapped", obj, seat)
end

-- Damage was dealt: list of { obj = source (or nil), controller = its controller,
-- seat = damaged player (or nil), target = damaged permanent (or nil), amount }.
-- combat = true for combat damage. For "whenever ~ deals damage", "whenever a source
-- you control deals noncombat damage to an opponent", "whenever ~ is dealt damage".
function Triggers.onDamage(list, combat)
  if not enabled() or not GameState.data.started or #list == 0 then
    return
  end
  local found = {}
  for _, p in ipairs(permanents()) do
    for _, a in ipairs(abilitiesOf(p.obj)) do
      local t = a.trig
      if t.kind == "damage" and not (t.combat == "yes" and not combat) and not (t.combat == "no" and combat) then
        local n, last = 0, nil
        for _, h in ipairs(list) do
          local src = h.obj
          local okT = (t.tgt == "player" and h.seat ~= nil) or (t.tgt == "opp" and h.seat ~= nil and h.seat ~= p.controller)
            or (t.tgt == "you" and h.seat == p.controller) or (t.tgt == "creature" and h.target ~= nil)
            or (t.tgt == "self" and h.target == p.obj)
          local okS
          if t.tgt == "self" then
            okS = not t.opp or h.controller ~= p.controller
          elseif t.self then
            okS = src == p.obj
          elseif t.equipped then
            okS = src ~= nil and Equip ~= nil and Equip.hostOf(p.obj) == src
          else
            okS = (src == nil and t.subjects == nil) or (src ~= nil and not src.isDestroyed() and matchesSubject(src, t))
            okS = okS and not (t.mine and h.controller ~= p.controller) and not (t.theirs and not TableSetup.isOpponent(h.controller, p.controller))
          end
          if okT and okS then
            n, last = n + 1, h
          end
        end
        for _ = 1, (t.once and math.min(n, 1) or n) do
          table.insert(found, { obj = p.obj, controller = p.controller, text = a.text, amount = last.amount, that = last.seat })
        end
      end
    end
  end
  pushAll(found, list[1] and list[1].seat)
end

-- Attackers no creature blocked: list of { obj, controller } ("whenever ~ attacks and isn't blocked").
function Triggers.onUnblocked(list)
  if not enabled() or not GameState.data.started then
    return
  end
  local found = {}
  for _, u in ipairs(list) do
    for _, a in ipairs(abilitiesOf(u.obj)) do
      if a.trig.kind == "unblocked" and a.trig.self then
        table.insert(found, { obj = u.obj, controller = u.controller, text = a.text })
      end
    end
    for _, f in ipairs(attachedTriggers(u.obj, "unblocked")) do
      f.controller = u.controller
      f.thatCard = u.obj.getGUID()
      table.insert(found, f)
    end
  end
  for _, p in ipairs(permanents()) do
    for _, a in ipairs(abilitiesOf(p.obj)) do
      local t = a.trig
      if t.kind == "unblocked" and t.mine then
        for _, u in ipairs(list) do
          if u.controller == p.controller and not u.obj.isDestroyed() and matchesSubject(u.obj, t) then
            table.insert(found, { obj = p.obj, controller = p.controller, text = a.text, thatCard = u.obj.getGUID() })
          end
        end
      end
    end
  end
  pushAll(found)
end

Events.on("spellCast", function(d)
  if not enabled() or not GameState.data.started or d.card == nil then
    return
  end
  local found = {}
  local seatNo
  do
    local gd = GameState.data
    local turnNo = gd.turn and gd.turn.taken
    local sc = gd.spellCount
    if sc == nil or sc.turn ~= turnNo then
      sc = { turn = turnNo, by = {} }
      gd.spellCount = sc
    end
    sc.by[d.controller] = (sc.by[d.controller] or 0) + 1
    seatNo = sc.by[d.controller]
  end
  -- "When you cast this spell" on the spell itself.
  for _, a in ipairs(abilitiesOf(d.card)) do
    if a.trig.kind == "castSelf" then
      table.insert(found, { obj = d.card, controller = d.controller, text = a.text, guid = d.card.getGUID(),
        name = d.card.getName(), face = faceOf(d.card) })
    end
  end
  -- Eminence (Edgar Markov, The Ur-Dragon...): "if ~ is in the command zone or on the battlefield" works
  -- from the command zone too.
  local sources = permanents()
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and obj.held_by_color == nil then
      local okl, loc = pcall(function() return Zones.regionAt(obj.getPosition()) end)
      if okl and loc and loc.seat and (loc.region == "command1" or loc.region == "command2" or loc.region == "command") then
        local cd = cardData(obj)
        if tostring(cd and cd.oracle or ""):lower():find("command zone or on the battlefield", 1, true) then
          table.insert(sources, { obj = obj, controller = loc.seat })
        end
      end
    end
  end
  for _, p in ipairs(sources) do
    for _, a in ipairs(abilitiesOf(p.obj)) do
      local t = a.trig
      if t.kind == "cast" and not (t.other and p.obj == d.card) then
        local mine = p.controller == d.controller
        local oppOf = d.controller
        local firstOk = true
        if t.nth and seatNo ~= t.nth then
          firstOk = false
        end
        if t.oppTurn then
          local active = GameState.data.turn and GameState.data.turn.activeSeat
          if active and Turns.isActiveSeat(p.controller) then
            firstOk = false
          end
        end
        if t.first then
          local fc = GameState.data.firstCast
          local turnNo = GameState.data.turn and GameState.data.turn.taken
          if fc == nil or fc.turn ~= turnNo then
            fc = { turn = turnNo, seen = {} }
            GameState.data.firstCast = fc
          end
          local key = tostring(d.controller) .. "|" .. tostring(t.spellType)
          if fc.seen[key] then
            firstOk = false
          end
        end
        if t.mvMin then
          local cd = cardData(d.card)
          if (cd and tonumber(cd.cmc) or 0) < t.mvMin then
            firstOk = false
          end
        end
        if firstOk and (t.who == "each" or (t.who == "you" and mine) or (t.who == "opp" and TableSetup.isOpponent(p.controller, oppOf))) and spellMatches(d.card, t.spellType, p.obj)
            and (t.spell == nil or spellSpecMatches(d.card, t.spell)) and not (t.mvMax and (tonumber((cardData(d.card) or {}).cmc) or 0) > t.mvMax) then
          -- "That spell" (Gandalf copies it) is the spell that was cast.
          local that = tostring(a.text):lower():find("that spell", 1, true) and d.card.getGUID() or nil
          table.insert(found, { obj = p.obj, controller = p.controller, text = a.text, thatCard = that })
        end
      end
    end
  end
  -- Cascade and Storm trigger from the spell itself when it is cast.
  do
    local gd = GameState.data
    local turnNo = gd.turn and gd.turn.taken
    local cl = gd.castLog
    if cl == nil or cl.turn ~= turnNo then
      cl = { turn = turnNo, n = 0 }
      gd.castLog = cl
    end
    local before = cl.n
    cl.n = cl.n + 1
    local dd = cardData(d.card)
    local oracle = dd and type(dd.oracle) == "string" and stripReminder(dd.oracle):lower() or ""
    local cascades, storm = 0, false
    for _, line in ipairs(lines(oracle)) do
      local rest = line
      if rest:sub(1, 7) == "cascade" then
        for _ in rest:gmatch("cascade") do
          cascades = cascades + 1
        end
      elseif rest:sub(1, 5) == "storm" then
        storm = true
      end
    end
    if Statics and Statics.spellGrantCount then
      local okc, extraC = pcall(Statics.spellGrantCount, d.card, d.controller, "cascade")
      if okc and extraC then
        cascades = cascades + extraC
      end
    end
    local gid, face = d.card.getGUID(), faceOf(d.card)
    local mv = dd and tonumber(dd.cmc) or nil
    for _ = 1, cascades do
      table.insert(found, { obj = d.card, controller = d.controller, name = "Cascade (" .. d.card.getName() .. ")", guid = gid, face = face,
        text = "Cascade: exile cards from the top of your library until you exile a nonland card with mana value less than "
          .. tostring(mv or "that spell's") .. ". You may cast it without paying its mana cost. Put the exiled cards on the bottom of your library in a random order." })
    end
    if Statics and Statics.spellGrantCount and not storm then
      local oks, extraS = pcall(Statics.spellGrantCount, d.card, d.controller, "storm")
      storm = oks and extraS and extraS > 0 or false
    end
    if storm then
      -- Resolves by itself (effects.lua): `amount` copies of the spell (thatCard) go on the stack.
      table.insert(found, { obj = d.card, controller = d.controller, name = "Storm (" .. d.card.getName() .. ")", guid = gid, face = face,
        thatCard = gid, amount = before, storm = true,
        text = "Storm: copy " .. d.card.getName() .. " for each spell cast before it this turn (" .. before .. "). You may choose new targets for the copies." })
    end
  end
  local fc = GameState.data.firstCast
  if fc then
    local ty = typesOf(d.card)
    fc.seen[tostring(d.controller) .. "|noncreature"] = fc.seen[tostring(d.controller) .. "|noncreature"] or (not ty.creature) or nil
    fc.seen[tostring(d.controller) .. "|nil"] = true
  end
  -- thatCard = the spell ("that spell's mana value": Dancing from Dark to Dawn).
  pushAll(found, d.controller, d.card.getGUID())
end)

-- A ninjutsu ability was activated (combat.lua).
Events.on("ninjutsuActivated", function(d)
  if not enabled() or not GameState.data.started or d.seat == nil then
    return
  end
  local found = {}
  for _, p in ipairs(permanents()) do
    if p.controller == d.seat then
      for _, a in ipairs(abilitiesOf(p.obj)) do
        if a.trig.kind == "ninjutsuAct" then
          table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
        end
      end
    end
  end
  pushAll(found, d.seat)
end)

---------------------------------------------------------------------------
-- Combat (called by combat.lua)
---------------------------------------------------------------------------

-- Attackers were declared: list of { obj, controller, target = defending seat }.
function Triggers.onAttack(list)
  if not enabled() or not GameState.data.started then
    return
  end
  local found = {}
  local attackerOf = {}
  for _, at in ipairs(list) do
    attackerOf[at.obj.getGUID()] = true
    for _, a in ipairs(abilitiesOf(at.obj)) do
      if a.trig.kind == "attacks" and a.trig.self then
        table.insert(found, { obj = at.obj, controller = at.controller, text = a.text })
      end
    end
    for _, f in ipairs(attachedTriggers(at.obj, "attacks")) do
      f.controller = at.controller
      f.thatCard = at.obj.getGUID()
      table.insert(found, f)
    end
    for _, f in ipairs(ringTriggers(at.obj, "attacks")) do
      table.insert(found, f)
    end
  end
  for _, p in ipairs(permanents()) do
    for _, a in ipairs(abilitiesOf(p.obj)) do
      local t = a.trig
      if t.kind == "attacks" and t.mine then
        local mineCount = 0
        local mineList = {}
        for _, at in ipairs(list) do
          local okType = true
          if t.nonType then
            local dd = cardData(at.obj)
            okType = not tostring(dd and dd.typeLine or ""):lower():find(t.nonType, 1, true)
          end
          if t.onlyType then
            -- "Dragon", or several: "samurai/warrior" (any of them).
            local dd = cardData(at.obj)
            local tl = tostring(dd and dd.typeLine or ""):lower()
            okType = false
            for w in (tostring(t.onlyType) .. "/"):gmatch("([^/]*)/") do
              if w ~= "" and tl:find(w, 1, true) then
                okType = true
              end
            end
          end
          if t.commander then
            okType = okType and Combat ~= nil and Combat.isCommander ~= nil and Combat.isCommander(at.obj) == true
          end
          if at.controller == p.controller and okType then
            mineCount = mineCount + 1
            table.insert(mineList, at)
          end
        end
        if t.alone then
          if #list == 1 and mineCount == 1 then
            local f = { obj = p.obj, controller = p.controller, text = a.text, thatCard = mineList[1].obj.getGUID() }
            if a.text == EXALTED_TEXT then
              f.sameKey = "exalted"     -- every exalted trigger does the same thing: no need to order them
            end
            table.insert(found, f)
          end
        elseif t.once then
          if mineCount > 0 then
            table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
          end
        else
          for _, at in ipairs(mineList) do
            table.insert(found, { obj = p.obj, controller = p.controller, text = a.text, that = at.target })
          end
        end
      elseif t.kind == "attacks" and t.targetsMe then
        local n = 0
        for _, at in ipairs(list) do
          if at.target == p.controller then
            n = n + 1
          end
        end
        for _ = 1, (t.once and math.min(n, 1) or n) do
          table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
        end
      end
    end
  end
  pushAll(found)
end

-- Blocks locked in: list of { obj = blocker, controller, attacker, attackerController }.
function Triggers.onBlock(list)
  if not enabled() or not GameState.data.started then
    return
  end
  local found, blockedDone = {}, {}
  for _, b in ipairs(list) do
    for _, a in ipairs(abilitiesOf(b.obj)) do
      if a.trig.kind == "blocks" and a.trig.self then
        table.insert(found, { obj = b.obj, controller = b.controller, text = a.text })
      end
    end
    for _, f in ipairs(attachedTriggers(b.obj, "blocks")) do
      f.controller = b.controller
      f.thatCard = b.obj.getGUID()
      table.insert(found, f)
    end
    local att = b.attacker
    if att and not att.isDestroyed() then
      local g = att.getGUID()
      if not blockedDone[g] then
        blockedDone[g] = { att = att, controller = b.attackerController, blockers = {} }
        table.insert(blockedDone, blockedDone[g])
      end
      table.insert(blockedDone[g].blockers, b.obj)
    end
  end
  -- Each blocked attacker: "whenever ~ becomes blocked" (once), "...blocked by a creature" (once per
  -- blocker), its Auras / Equipment, and "whenever a creature you control becomes blocked".
  for _, e in ipairs(blockedDone) do
    local att = e.att
    for _, f in ipairs(ringTriggers(att, "blocked")) do
      table.insert(found, f)
    end
    for _, a in ipairs(abilitiesOf(att)) do
      if a.trig.kind == "blocked" and a.trig.self then
        if a.trig.perBlocker then
          for _, bl in ipairs(e.blockers) do
            table.insert(found, { obj = att, controller = e.controller, text = a.text, thatCard = bl.getGUID() })
          end
        else
          table.insert(found, { obj = att, controller = e.controller, text = a.text })
        end
      end
    end
    for _, f in ipairs(attachedTriggers(att, "blocked")) do
      f.controller = e.controller
      f.thatCard = att.getGUID()
      table.insert(found, f)
    end
    for _, p in ipairs(permanents()) do
      for _, a in ipairs(abilitiesOf(p.obj)) do
        local t = a.trig
        if t.kind == "blocked" and t.mine and p.controller == e.controller and matchesSubject(att, t) then
          local times = t.perBlocker and #e.blockers or 1
          for _ = 1, times do
            table.insert(found, { obj = p.obj, controller = p.controller, text = a.text, thatCard = att.getGUID() })
          end
        end
      end
    end
  end
  pushAll(found)
end

-- Creatures dealt combat damage to players: list of { obj, controller, seat }.
function Triggers.onCombatDamage(list)
  -- The monarch and the initiative change hands on combat damage (a rule, not a trigger setting).
  if GameState.data.started and Effects and Effects.combatDamageToPlayers then
    pcall(Effects.combatDamageToPlayers, list)
  end
  if not enabled() or not GameState.data.started then
    return
  end
  local found = {}
  for _, h in ipairs(list) do
    if not h.obj.isDestroyed() then
      for _, a in ipairs(abilitiesOf(h.obj)) do
        if a.trig.kind == "combatDamage" and a.trig.self then
          table.insert(found, { obj = h.obj, controller = h.controller, text = a.text, amount = h.amount })
        end
      end
      for _, f in ipairs(ringTriggers(h.obj, "combatDamage")) do
        f.that = h.seat
        table.insert(found, f)
      end
      for _, f in ipairs(attachedTriggers(h.obj, "combatDamage")) do
        f.controller = h.controller
        f.that = h.seat
        f.amount = h.amount
        f.thatCard = h.obj.getGUID()
        table.insert(found, f)
      end
    end
  end
  for _, p in ipairs(permanents()) do
    for _, a in ipairs(abilitiesOf(p.obj)) do
      local t = a.trig
      if t.kind == "combatDamage" and t.mine then
        local n = 0
        for _, h in ipairs(list) do
          local modOk = true
          if t.modified then
            modOk = false
            if not h.obj.isDestroyed() then
              local cc = Counters.get(h.obj)
              modOk = (cc.plus or 0) > 0 or (cc.minus or 0) > 0 or (cc.other or 0) > 0
                or (Equip ~= nil and #Equip.attachments(h.obj) > 0)
            end
          end
          if modOk and h.controller == p.controller and (t.subjects == nil or (not h.obj.isDestroyed() and matchesSubject(h.obj, t))) then
            n = n + 1
          end
        end
        for _ = 1, (t.once and math.min(n, 1) or n) do
          table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
        end
      end
    end
  end
  -- "Whenever ~ deals damage" (combat or not) and friends: the same damage as a damage event.
  do
    local dl = {}
    for _, h in ipairs(list) do
      table.insert(dl, { obj = h.obj, controller = h.controller, seat = h.seat, amount = h.amount })
    end
    Triggers.onDamage(dl, true)
  end
  -- The damaged player ("they get that many poison counters"): each trigger
  -- is about the player its creature hit.
  for _, f in ipairs(found) do
    for _, h in ipairs(list) do
      if f.obj == h.obj and f.that == nil then
        f.that = h.seat
      end
    end
  end
  pushAll(found, list[1] and list[1].seat)
end

-- !triggers audit: every permanent with trigger text the table can't read.
function Triggers.audit(color)
  local n = 0
  for _, p in ipairs(permanents()) do
    local ok, miss = pcall(Triggers.unrecognized, p.obj)
    if ok and #miss > 0 then
      for _, text in ipairs(miss) do
        n = n + 1
        printToColor(p.obj.getName() .. " (" .. p.controller .. "): " .. text:sub(1, 110), color, { 1, 0.75, 0.3 })
      end
    end
  end
  printToColor(n == 0 and "Every trigger on the battlefield is one the table watches for."
    or (n .. " trigger(s) above aren't watched: use right-click > Ability to stack when they happen."), color, INFO)
end

-- Debug (!triggers card): what the table reads on the card under the mouse.
function Triggers.describe(obj)
  if obj == nil then
    return "Hover over a card first."
  end
  local list = abilitiesOf(obj)
  if #list == 0 then
    return obj.getName() .. ": no triggers found."
  end
  local lines = {}
  for _, a in ipairs(list) do
    local t = a.trig
    table.insert(lines, "- " .. t.kind .. (t.step and (" " .. t.step .. " (" .. t.who .. ")") or "")
      .. (t.self and " (itself)" or "") .. (t.mine and " (yours)" or "") .. (t.once and " (once)" or "")
      .. (t.alone and " (alone)" or "") .. (t.subject and (" " .. t.subject) or "")
      .. (a.forge and " [Forge]" or " [text]") .. ": " .. a.text)
  end
  return obj.getName() .. ":\n" .. table.concat(lines, "\n")
end

Triggers.parse = parseTrigger
Triggers.abilitiesOf = abilitiesOf
Triggers.parseCombat = parseCombat
Triggers.normalize = normalize
