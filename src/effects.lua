--[[
  effects.lua
  Phase 8: auto-resolve. When a trigger or a planeswalker ability resolves
  off the stack, the table reads its rules text and carries out the simple
  parts itself:

    life      "you gain N life", "you lose N life", "each opponent loses N
              life", "each player loses N life", "target player / opponent
              loses N life", "(have) that player lose(s) N life",
              "deals N damage to each opponent" (as life loss)
    cards     "draw N cards" (you), "each player draws N cards"

  "You may ..." asks the controller first (YES / NO), and a target player is
  picked from buttons; both in a small panel only that player sees (in solo
  test mode, everyone sees it). Anything with conditions ("if", "unless",
  "for each", "equal to", X...) or effects it doesn't know (tokens,
  counters, destroy...) is left to the players, and chat says so.
  !auto off / !auto on turns it off / on for the table.
--]]

Effects = {}

local INFO = { 0.75, 0.8, 0.9 }
local GOOD = { 0.55, 0.9, 0.6 }
local MAX_CHOICES = 5

local function enabled()
  return not (GameState.data and GameState.data.autoOff)
end

function Effects.setEnabled(on)
  GameState.data.autoOff = not on
end

---------------------------------------------------------------------------
-- Reading the text
---------------------------------------------------------------------------

local NUMBERS = { a = 1, an = 1, one = 1, two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7,
  eight = 8, nine = 9, ten = 10 }

local function num(word)
  return tonumber(word) or NUMBERS[word or ""]
end

-- Words that mean "this needs a person": left alone.
local MANUAL = { " if ", " unless ", " for each ", " equal to ", " instead", " x ", " x life", "where x",
  " the number of ", " half ", " double " }

-- The effect part of a trigger: what follows "Whenever / When / At ..., ".
local function effectPart(t)
  local first = t:sub(1, 8)
  if first:find("^whenever") or first:find("^when ") or first:find("^at ") then
    local comma = t:find(", ", 1, true)
    if comma then
      return t:sub(comma + 2)
    end
  end
  -- Loyalty ability: "+1: ..." / "−3: ...".
  local colon = t:find(":", 1, true)
  if colon and colon <= 6 then
    return t:sub(colon + 1)
  end
  return t
end

-- Parse an effect: { optional = bool, actions = { { what, who, n } } } or
-- nil (nothing it can do), plus the reason when it's left to the players.
function Effects.parse(text, sourceName)
  -- Reminder text "(...)" isn't rules.
  if Triggers and Triggers.stripReminder then
    text = Triggers.stripReminder(tostring(text or ""))
  end
  -- Drop keyword-only lines ("Flash", "Flying, trample"): no period.
  local kept = {}
  local raw = tostring(text or "")
  local i = 1
  while i <= #raw do
    local j = raw:find("\n", i, true) or (#raw + 1)
    local line = raw:sub(i, j - 1)
    if line:find(".", 1, true) or line:find(":", 1, true) or line:lower():find("^fabricate %d") then
      table.insert(kept, line)
    end
    i = j + 1
  end
  text = table.concat(kept, "\n")
  local t = " " .. effectPart(tostring(text or ""):lower()) .. " "
  -- The card's own name (and "this creature" etc.) as "~".
  local function swap(n)
    if n and #n > 1 then
      local esc = n:lower():gsub("([%%%-%.%+%*%?%[%]%^%$%(%)])", "%%%1")
      t = t:gsub(esc, "~")
    end
  end
  if sourceName then
    swap(sourceName)
    local comma = sourceName:find(",", 1, true)
    if comma then
      swap(sourceName:sub(1, comma - 1))
    end
  end
  for _, w in ipairs({ "creature", "land", "enchantment", "artifact", "permanent", "planeswalker" }) do
    t = t:gsub("this " .. w, "~")
  end
  -- Several paragraphs (a spell: "This spell can't be countered." then
  -- "Destroy all creatures."): read them as sentences.
  t = t:gsub("\n", " ")
  -- Swords to Plowshares: "Its controller gains life equal to its power."
  -- is handled with the exile itself.
  local lifeEqualPower, loseEqualMV = false, false
  do
    local a = t:find("its controller gains life equal to its power", 1, true)
    if a then
      lifeEqualPower = true
      t = t:sub(1, a - 1) .. t:sub(a + #"its controller gains life equal to its power")
    end
    -- Feed the Swarm: "You lose life equal to that permanent's mana value."
    local lm = "you lose life equal to that permanent's mana value"
    a = t:find(lm, 1, true)
    if a then
      loseEqualMV = true
      t = t:sub(1, a - 1) .. t:sub(a + #lm)
    end
  end
  -- Aetherflux Reservoir: "You gain 1 life for each spell you've cast this
  -- turn." The table counts the spells itself.
  local perSpell = false
  for _, ap in ipairs({ "'", "\226\128\153" }) do
    local phrase = " for each spell you" .. ap .. "ve cast this turn"
    local a = t:find(phrase, 1, true)
    if a then
      perSpell = true
      t = t:sub(1, a - 1) .. t:sub(a + #phrase)
    end
  end
  -- Smaug, the Magnificent: "deals damage equal to the number of Treasures
  -- you control to any target." / Smaug, Wicked Worm: "create X tapped
  -- Treasure tokens, where X is the number of artifacts your opponents
  -- control." The table counts them when the ability resolves.
  local counted
  do
    local a, b, word = t:find("deals damage equal to the number of (%a+) you control to any target", 1)
    if a then
      counted = { kind = "lose", word = word, scope = "mine" }
      t = t:sub(1, a - 1) .. "deals 1 damage to any target" .. t:sub(b + 1)
    end
    local c, d, w2, who = t:find(", where x is the number of (%a+) (%a+ ?%a*) control", 1)
    if c and t:find("create x ", 1, true) then
      counted = { kind = "token", word = w2, scope = who:find("opponent", 1, true) and "opponents" or "mine" }
      t = t:sub(1, c - 1) .. t:sub(d + 1)
      t = t:gsub("create x ", "create 1 ", 1)
    end
  end
  -- Chaos Warp: the owner shuffles the permanent into their library, reveals
  -- the top card; a permanent card goes onto the battlefield.
  if t:find("shuffles it into their library, then reveals the top card of their library", 1, true) then
    return { optional = false, actions = { { what = "chaosWarp", who = "you", n = 1 } }, notes = {}, conds = {} }
  end
  -- Triskaidekaphobia: "Each player with exactly 13 life loses the game, then
  -- each player gains / loses 1 life."
  do
    local lifeN, dir, amt = t:match("each player with exactly (%d+) life loses the game, then each player (%a+) (%w+) life")
    if lifeN and num(amt) then
      return { optional = false, notes = {}, conds = {},
        actions = { { what = "exactLife", who = "all", n = num(amt), life = tonumber(lifeN), dir = dir == "gains" and "gain" or "lose" } } }
    end
  end
  -- Miss Highwater: combat damage to a player who has no contract counter.
  if t:find("contract counter", 1, true) and t:find("discard their hand", 1, true) and t:find("draw seven cards", 1, true) then
    return { optional = false, notes = {}, conds = {},
      actions = { { what = "contract", who = "that", n = 7 } } }
  end
  -- Kuroki: "target opponent may draw four cards. If they do, look at that
  -- player's hand and you may cast a spell from it... If they don't, put two
  -- +1/+1 counters on ~."
  do
    local dn = t:match("target opponent may draw (%w+) cards")
    local cn = t:match("if they don't, put (%w+) %+1/%+1 counters? on ~")
    if dn and num(dn) and cn and num(cn) then
      return { optional = false, notes = {}, conds = {},
        actions = { { what = "oppMayDraw", who = "targetOpponent", n = num(dn), counters = num(cn),
          cast = t:find("you may cast a spell from their hand", 1, true) ~= nil } } }
    end
  end
  -- Sentence by sentence: one with a condition ("Then if you control four
  -- or more lands, untap that land.") is left to the players; the plain
  -- sentences around it still happen.
  local kept, notes, firstWhy = {}, {}, nil
  -- "If <condition>, <effect>." sentences: asked as YES / NO when it
  -- resolves ("Is this true: you control no creatures with decayed?").
  local conds = {}
  local pos = 1
  while pos <= #t do
    local stop = t:find(". ", pos, true)
    local sentence = stop and t:sub(pos, stop) or t:sub(pos)
    local why
    for _, m in ipairs(MANUAL) do
      if why == nil and (" " .. sentence .. " "):find(m, 1, true) then
        why = m:gsub("^%s+", ""):gsub("%s+$", "")
      end
    end
    if why then
      firstWhy = firstWhy or why
      local clean = sentence:gsub("^%s+", ""):gsub("%s+$", "")
      local cond, rest
      if why == "if" and #clean < 400 then
        cond, rest = clean:match("^if ([^,]+), (.+)$")
        if cond == nil then
          cond, rest = clean:match("^then if ([^,]+), (.+)$")
        end
      end
      if cond and not rest:find("instead", 1, true) then
        local c = { cond = cond, rest = rest }
        -- "You may X. If you do, Y.": the "you may" sentence goes with it.
        if cond == "you do" and #kept > 0 then
          local prev = kept[#kept]:gsub("^%s+", ""):gsub("%s+$", "")
          if prev:find("^you may ") then
            table.remove(kept, #kept)
            c.prev = prev
          end
        end
        c.lastPos = stop and (stop + 2) or (#t + 1)
        table.insert(conds, c)
      elseif clean ~= "" then
        table.insert(notes, clean)
      end
    else
      -- "Otherwise, ..." right after an "If ..." sentence: the NO answer.
      local clean = sentence:gsub("^%s+", "")
      local other = clean:match("^otherwise, (.+)$")
      if other and #conds > 0 and conds[#conds].lastPos == pos then
        conds[#conds].otherwise = other
      else
        table.insert(kept, sentence)
      end
    end
    pos = stop and (stop + 2) or (#t + 1)
  end
  if #kept == 0 and #conds == 0 then
    return nil, "it has a condition (" .. tostring(firstWhy) .. ")"
  end
  -- "... instead" changes the other sentences too: all by hand.
  for _, n in ipairs(notes) do
    if n:find("instead", 1, true) then
      return nil, "it has a condition (instead)"
    end
  end
  t = " " .. table.concat(kept, " ") .. " "
  local actions = {}
  -- "You may sacrifice a land. If you do, ...": pick the land, then the rest.
  for i = #conds, 1, -1 do
    local c = conds[i]
    local what = c.prev and c.prev:match("^you may sacrifice (.+)$")
    if what then
      what = what:gsub("%.$", "")
      local other = what:find("^another ") ~= nil or what:find("other ", 1, true) ~= nil
      what = what:gsub("^another ", ""):gsub("^an? ", "")
      local ty = what:match("^(%a+)")
      if ty then
        table.remove(conds, i)
        table.insert(actions, { what = "sacrifice", who = "you", n = 1, type = ty, rest = c.rest, phrase = what,
          other = other })
      end
    end
  end
  local function add(what, who, n)
    if n and n > 0 then
      table.insert(actions, { what = what, who = who, n = n })
    end
  end
  local w
  w = t:match("each opponent loses (%w+) life")
  add("lose", "opponents", num(w))
  w = t:match("each player loses (%w+) life")
  add("lose", "all", num(w))
  w = t:match("target opponent loses (%w+) life")
  add("lose", "targetOpponent", num(w))
  w = t:match("target player loses (%w+) life")
  add("lose", "target", num(w))
  w = t:match("that player loses? (%w+) life")
  add("lose", "that", num(w))
  w = t:match("deals (%w+) damage to each opponent")
  add("lose", "opponents", num(w))
  w = t:match("deals (%w+) damage to that player")
  add("lose", "that", num(w))
  w = t:match("deals (%w+) damage to each player")
  add("lose", "all", num(w))
  w = t:match("deals (%w+) damage to target opponent")
  add("lose", "targetOpponent", num(w))
  w = t:match("deals (%w+) damage to target player")
  add("lose", "target", num(w))
  -- Aetherflux Reservoir: "deals 50 damage to any target". A player loses
  -- the life here; a creature or planeswalker is handled by hand.
  w = t:match("deals (%w+) damage to any target")
  add("lose", "any", num(w))
  -- Nekusar: "that player draws an additional card".
  w = t:match("that player draws (%w+) additional cards?")
  add("draw", "that", num(w))
  if t:find("you gain that much life", 1, true) or t:find("you may gain that much life", 1, true) then
    -- Bloodthirsty Conqueror: the amount comes from the trigger.
    table.insert(actions, { what = "gain", who = "you", n = 1, thatMuch = true })
  end
  w = t:match("you gain (%w+) life") or t:match("you may gain (%w+) life")
  add("gain", "you", num(w))
  if perSpell and actions[#actions] and actions[#actions].what == "gain" then
    actions[#actions].perSpell = true
  end
  w = t:match("you lose (%w+) life")
  add("lose", "you", num(w))
  -- Mana Vault / Black Vise style: "it deals 1 damage to you".
  do
    local _, e, dw = t:find("deals (%w+) damage to you")
    if dw and not t:sub(e + 1, e + 1):match("%a") then
      add("lose", "you", num(dw))
    end
  end
  -- "As an additional cost to cast this spell, pay 3 life" (X filled in).
  do
    local pAt = t:find("pay %w+ life")
    if pAt and not t:sub(math.max(1, pAt - 12), pAt):find("unless", 1, true) then
      add("lose", "you", num(t:match("pay (%w+) life")))
    end
  end
  if t:find("you win the game", 1, true) then
    table.insert(actions, { what = "win", who = "you", n = 1 })
  end
  do
    local ord = t:match("put ~ into its owner's library (%a+) from the top")
    local ORD = { second = 2, third = 3, fourth = 4, fifth = 5, sixth = 6, seventh = 7, eighth = 8, ninth = 9, tenth = 10 }
    if ord and ORD[ord] then
      table.insert(actions, { what = "toLibrary", who = "you", n = ORD[ord] })
    end
  end
  w = t:match("each player draws (%w+) cards?")
  if w then
    add("draw", "all", num(w))
  else
    local a, word = t:find("draw (%w+) cards?")
    word = t:match("draw (%w+) cards?")
    -- Only "you" draw: not "target player draws", "that player draws"...
    local before = a and t:sub(math.max(1, a - 8), a - 1) or ""
    if word and not before:find("player", 1, true) and not before:find("opponent", 1, true) then
      add("draw", "you", num(word))
    end
  end
  -- "search your library for a basic land card, put it onto the battlefield":
  -- opens the library search with the card type filled in.
  local a = t:find("search your library for ", 1, true)
  if a then
    local rest = t:sub(a + 24)
    local stop = rest:find(" card", 1, true) or rest:find(",", 1, true) or 40
    local phrase = rest:sub(1, stop - 1)
    local q
    for _, ty in ipairs({ "land", "creature", "artifact", "enchantment", "planeswalker", "instant", "sorcery", "equipment", "aura" }) do
      if phrase:find(ty, 1, true) and q == nil then
        q = ty
      end
    end
    -- "an instant or sorcery card": more than one type joined by "or".
    local anyOf
    if phrase:find(" or ", 1, true) then
      local found = {}
      for _, ty in ipairs({ "land", "creature", "artifact", "enchantment", "planeswalker", "instant", "sorcery" }) do
        if phrase:find(ty, 1, true) then
          table.insert(found, ty)
        end
      end
      if #found > 1 then
        anyOf = found
        q = table.concat(found, " or ")
      end
    end
    if q and phrase:find("basic", 1, true) then
      q = "basic " .. q
    end
    if q == nil then
      -- A card name or subtype ("a forest", "an elf"): first word after the article.
      q = phrase:gsub("^up to %w+ ", ""):gsub("^an? ", ""):match("^(%a+)") or ""
    end
    local bf = rest:find("onto the battlefield", 1, true) ~= nil
    local hand = rest:find("into your hand", 1, true) ~= nil
    local where = (bf and hand) and "both" or (bf and "battlefield" or "hand")
    -- Tutors: "...then shuffle and put that card on top".
    local top = (t:find("put that card on top", a, true) or t:find("put it on top", a, true)
      or t:find("on top of your library", a, true)) ~= nil and not bf and not hand
    if top then
      where = "top"
    end
    local mvMin = tonumber(rest:match("mana value (%d+) or greater") or "")
    local mvMax = tonumber(rest:match("mana value (%d+) or less") or "")
    table.insert(actions, { what = "search", who = "you", n = 1, query = q, where = where, mvMin = mvMin, mvMax = mvMax,
      tapped = rest:find("battlefield tapped", 1, true) ~= nil, phrase = phrase, anyOf = anyOf })
  end
  -- "untap it" / "untap that permanent" (Amulet of Vigor): the card the
  -- trigger was about.
  if t:find("untap it", 1, true) or t:find("untap that ", 1, true) then
    table.insert(actions, { what = "untap", who = "you", n = 1 })
  elseif t:find(" tap it", 1, true) or t:find(" tap that ", 1, true) then
    table.insert(actions, { what = "tap", who = "you", n = 1 })
  end
  -- "Destroy all creatures", "exile all nonland permanents your opponents
  -- control", "destroy target artifact"...
  for _, verb in ipairs({ "destroy", "exile" }) do
    for _, how in ipairs({ "all", "each", "target", "up to one target" }) do
      local a0 = t:find(verb .. " " .. how .. " ", 1, true)
      if a0 then
        local rest = t:sub(a0 + #verb + #how + 2)
        local stop = rest:find(".", 1, true) or #rest
        local phrase = rest:sub(1, stop)
        local types = {}
        for _, w in ipairs({ "creature", "artifact", "enchantment", "planeswalker", "land", "permanent", "battle" }) do
          if phrase:find(w, 1, true) then
            table.insert(types, w)
          end
        end
        if phrase:find("nonland", 1, true) then
          types = { "nonland" }
        elseif phrase:find("noncreature", 1, true) then
          types = { "noncreature" }
        end
        if #types > 0 then
          local scope = "any"
          if phrase:find("you don't control", 1, true) or phrase:find("opponents control", 1, true)
              or phrase:find("an opponent controls", 1, true) then
            scope = "opponents"
          elseif phrase:find("you control", 1, true) then
            scope = "mine"
          end
          table.insert(actions, { what = (how == "all" or how == "each") and "removeAll" or "removeTarget",
            who = "you", n = 1, verb = verb, types = types, scope = scope, other = phrase:find("other", 1, true) ~= nil,
            lifeEqualPower = lifeEqualPower, loseEqualMV = loseEqualMV,
            phrase = phrase:gsub("%.$", "") })
          break
        end
      end
    end
  end
  -- "create a 2/2 black Zombie creature token", "create a Treasure token".
  local cAt = t:find("create ", 1, true)
  if cAt then
    local before = t:sub(math.max(1, cAt - 14), cAt - 1)
    local rest = t:sub(cAt + 7)
    local tAt = rest:find(" token", 1, true)
    local mine = not (before:find("player", 1, true) or before:find("opponent", 1, true) or before:find("controller", 1, true))
    if tAt and mine then
      local phrase = rest:sub(1, tAt - 1)
      local words = {}
      for w in phrase:gmatch("%S+") do
        table.insert(words, w)
      end
      local n = num(words[1])
      if n then
        table.remove(words, 1)
        local spec = { words = {}, colors = {} }
        local COLOR = { white = "W", blue = "U", black = "B", red = "R", green = "G" }
        local SKIP = { ["and"] = true, creature = true, artifact = true, enchantment = true, legendary = true,
          colorless = true, snow = true, tapped = true }
        for _, w in ipairs(words) do
          if w:find("^%d+/%d+$") then
            spec.pt = w
          elseif COLOR[w] then
            spec.colors[COLOR[w]] = true
          elseif not SKIP[w] and w:find("^%a+$") then
            table.insert(spec.words, w)
          end
        end
        if #spec.words > 0 then
          -- "...tokens that are tapped and attacking" (Hero of Bladehold).
          local sentence = rest:sub(1, (rest:find(".", 1, true) or #rest + 1) - 1)
          local atk = sentence:find("tapped and attacking", 1, true) ~= nil
          local act = { what = "token", who = "you", n = n, spec = spec, phrase = phrase,
            attacking = atk, tapped = atk or sentence:find("tapped", 1, true) ~= nil }
          -- "create a Food token or a Treasure token" (Tireless Provisioner):
          -- the controller chooses which one.
          local altPhrase = rest:match("^[^.]- token or an? ([^.]-) token")
          if altPhrase then
            local spec2 = { words = {}, colors = {} }
            for w in altPhrase:gmatch("%S+") do
              if w:find("^%d+/%d+$") then
                spec2.pt = w
              elseif COLOR[w] then
                spec2.colors[COLOR[w]] = true
              elseif not SKIP[w] and w:find("^%a+$") then
                table.insert(spec2.words, w)
              end
            end
            if #spec2.words > 0 then
              act.alt = { spec = spec2, phrase = altPhrase }
            end
          end
          table.insert(actions, act)
        end
      end
    end
  end
  if counted then
    for _, ac in ipairs(actions) do
      if (counted.kind == "lose" and ac.what == "lose" and ac.who == "any")
          or (counted.kind == "token" and ac.what == "token") then
        ac.countWord, ac.countScope = counted.word, counted.scope
      end
    end
  end
  -- Goad: "goad target creature [an opponent controls]" (Baeloth, Disrupt Decorum).
  if t:find("goad target creature", 1, true) or t:find("goad up to one target creature", 1, true) then
    table.insert(actions, { what = "goad", who = "you", n = 1 })
  end
  -- Corroding Dragonstorm: "return this enchantment to its owner's hand".
  if t:find("return ~ to its owner's hand", 1, true) then
    table.insert(actions, { what = "bounceSelf", who = "you", n = 1 })
  end
  -- Fabricate N (Marionette Apprentice): N +1/+1 counters on it, or N 1/1
  -- Servo artifact creature tokens.
  do
    local fab = t:match("^%s*fabricate (%d+)")
    if fab then
      table.insert(actions, { what = "fabricate", who = "you", n = tonumber(fab) })
    end
  end
  -- "Amass Zombies 1": put N +1/+1 counters on your Army (make a 0/0 Army
  -- token first if you have none).
  local amType, amN = t:match("amass (%a+) (%d+)")
  if amType then
    table.insert(actions, { what = "amass", who = "you", n = tonumber(amN), kind = amType:gsub("s$", "") })
  end
  -- "Return target creature card from your graveyard to your hand / to the
  -- battlefield" (Eternal Witness...): search the graveyard.
  for _, dest in ipairs({ { "from your graveyard to your hand", "hand" }, { "from your graveyard to the battlefield", "battlefield" } }) do
    local g = t:find(dest[1], 1, true)
    if g then
      local before = t:sub(math.max(1, g - 60), g - 1)
      local r = before:find("return ", 1, true)
      if r then
        local what = before:sub(r + 7):gsub("^up to %w+ ", ""):gsub("^target ", ""):gsub("^an? ", "")
        local word = what:match("^(%a+) cards?") or ""
        if word == "card" or word == "target" then
          word = ""
        end
        table.insert(actions, { what = "graveReturn", who = "you", n = 1, type = word, where = dest[2],
          tapped = t:find("battlefield tapped", 1, true) ~= nil })
      end
      break
    end
  end
  -- "Target creature gets +2/+0 and gains trample until end of turn",
  -- "Creatures you control get +1/+1 until end of turn", "~ gets +3/+3...".
  local eot = t:find(" until end of turn", 1, true)
  if eot then
    local clause = t:sub(1, eot)
    -- Start of this clause: after the last ". " before it.
    local s0 = 1
    local look = 1
    while true do
      local d = clause:find(". ", look, true)
      if not d then
        break
      end
      s0, look = d + 2, d + 2
    end
    clause = clause:sub(s0)
    local gAt = clause:find(" gets ", 1, true) or clause:find(" get ", 1, true)
    local gainAt = clause:find(" gains ", 1, true) or clause:find(" gain ", 1, true)
    local headEnd = gAt or gainAt
    if headEnd then
      local head = clause:sub(1, headEnd - 1)
      local p, q
      if gAt then
        local after = clause:sub(gAt):gsub("^ gets? ", "")
        p, q = after:match("^([%+%-]%d+)/([%+%-]%d+)")
      end
      local kws = {}
      if gainAt then
        local words = clause:sub(gainAt):gsub("^ gains? ", "")
        for _, kw in ipairs({ "first strike", "double strike", "flying", "trample", "lifelink", "deathtouch", "vigilance",
          "haste", "indestructible", "hexproof", "menace", "reach" }) do
          if words:find(kw, 1, true) then
            table.insert(kws, kw)
          end
        end
      end
      local scope
      if head:find("target creature you control", 1, true) then
        scope = "targetMine"
      elseif head:find("target creature an opponent controls", 1, true) or head:find("target creature you don't control", 1, true) then
        scope = "targetOpp"
      elseif head:find("target creature", 1, true) then
        scope = "target"
      elseif head:find("creatures you control", 1, true) then
        scope = "allMine"
      elseif head:find("creatures your opponents control", 1, true) then
        scope = "allOpp"
      elseif head:find("each creature", 1, true) or head:find("all creatures", 1, true) then
        scope = "all"
      elseif head:sub(-1) == "~" or head:find("~$") then
        scope = "self"
      elseif (" " .. head):find(" it$") or head:find("that creature$") then
        -- Enduring Courage: "it gets +2/+0" = the creature the trigger saw.
        scope = "that"
      end
      if scope and (p or #kws > 0) then
        table.insert(actions, { what = "pump", who = "you", n = 1, p = tonumber(p or "0"), q = tonumber(q or "0"),
          kws = kws, scope = scope, other = head:find("other", 1, true) ~= nil,
          label = (p and (p .. "/" .. q) or "") .. (#kws > 0 and ((p and " and " or "") .. table.concat(kws, ", ")) or "") })
      end
    end
  end
  -- "Look at the top four cards of your library. You may reveal a creature
  -- card from among them and put it into your hand. Put the rest on the
  -- bottom": the search panel showing just those cards.
  local lAt = t:find("look at the top ", 1, true)
  if lAt and t:find("rest on the bottom", 1, true) then
    local after = t:sub(lAt, lAt + 400)
    local lw = after:match("^look at the top (%w+) cards? of your library")
    if lw and num(lw) then
      local phrase = after:match("reveal (.-) cards? from among") or after:match("put (.-) cards? from among")
        or after:match("reveal (.-) cards?") or ""
      phrase = phrase:gsub("^up to %w+ ", ""):gsub("^an? ", ""):gsub("^any number of ", "")
      local q = ""
      if not phrase:find(" or ", 1, true) and not phrase:find("non", 1, true) and phrase:match("^(%a+)$") then
        q = phrase
      end
      local picks = num(after:match("up to (%w+)") or "") or 1
      table.insert(actions, { what = "look", who = "you", n = num(lw), query = q, picks = picks,
        where = after:find("onto the battlefield", 1, true) and "battlefield" or "hand",
        tapped = after:find("battlefield tapped", 1, true) ~= nil })
    end
  end
  -- Etali: "each player exiles cards from the top of their library until
  -- they exile a nonland card. You may cast any number of spells from among
  -- the nonland cards exiled this way without paying their mana costs."
  do
    local free = t:find("without paying their mana costs", 1, true) or t:find("without paying its mana cost", 1, true)
    local everyone = t:find("each player exiles cards from the top of their library until they exile a nonland card", 1, true)
    if everyone then
      -- (the "you may cast" sentence can be on its own line: the offer is always made)
      table.insert(actions, { what = "exileCast", who = "you", n = 1, everyone = true, untilNonland = true })
    elseif free and (t:find("until you exile a nonland card", 1, true) or t:find("until they exile a nonland card", 1, true)) then
      table.insert(actions, { what = "exileCast", who = "you", n = 1, everyone = false, untilNonland = true })
    elseif free and t:find("exile the top card of each player's library", 1, true) then
      table.insert(actions, { what = "exileCast", who = "you", n = 1, everyone = true, untilNonland = false })
    end
  end
  -- "Reveal cards from the top of your library until you reveal a creature
  -- card. Put that card onto the battlefield tapped and attacking. Put the
  -- rest on the bottom of your library in a random order." (Raph & Mikey)
  do
    local ty = t:match("reveal cards from the top of your library until you reveal an? (%a+) card")
    if ty then
      local toHand = t:find("into your hand", 1, true) ~= nil
      table.insert(actions, { what = "revealUntil", who = "you", n = 1, type = ty,
        where = toHand and "hand" or "battlefield",
        allToHand = t:find("all cards revealed this way into your hand", 1, true) ~= nil,
        attacking = t:find("tapped and attacking", 1, true) ~= nil,
        tapped = t:find("tapped and attacking", 1, true) ~= nil or t:find("battlefield tapped", 1, true) ~= nil })
    end
  end
  -- "they get that many poison counters" (Etali, Primal Sickness).
  if t:find("get that many poison counters", 1, true) or t:find("gets that many poison counters", 1, true) then
    table.insert(actions, { what = "poison", who = "that", n = 1, fromTrigger = true })
  end
  -- Maze of Ith: "Untap target attacking creature. Prevent all combat damage
  -- that would be dealt to and dealt by that creature this turn."
  if t:find("untap target attacking creature", 1, true) then
    table.insert(actions, { what = "untapAttacker", who = "you", n = 1,
      prevent = t:find("prevent all combat damage that would be dealt to and dealt by that creature", 1, true) ~= nil })
  end
  -- Sothera: "each opponent chooses a creature they control and exiles it".
  do
    local ty = t:match("each opponent chooses an? (%a+) they control and exiles it")
    if ty then
      table.insert(actions, { what = "oppExile", who = "you", n = 1, type = ty })
    end
  end
  -- "sacrifice ~, then put a creature card exiled with ~ onto the battlefield
  -- under your control with two additional +1/+1 counters on it".
  if t:find("sacrifice ~", 1, true) and not t:find("you may sacrifice ~", 1, true) then
    table.insert(actions, { what = "sacSelf", who = "you", n = 1 })
  end
  do
    local ty = t:match("put an? (%a+) card exiled with [%w~]+ onto the battlefield under your control")
    if ty then
      local cw = t:match("with (%w+) additional %+1/%+1 counters? on it")
      local gains = t:find("gains haste", 1, true) ~= nil or t:find("gain haste", 1, true) ~= nil
      table.insert(actions, { what = "returnExiledWith", who = "you", n = 1, type = ty, counters = num(cw) or 0,
        haste = gains })
    end
  end
  -- "Manifest the top card of your library" / "cloak the top card".
  local mk = t:match("(manifest) the top card of your library") or t:match("(cloak) the top card of your library")
  if mk then
    table.insert(actions, { what = "manifest", who = "you", n = 1, kind = mk })
  end
  -- "Transform ~" (Sephiroth, werewolves, flip planeswalkers).
  if t:find("transform ~", 1, true) then
    table.insert(actions, { what = "transform", who = "you", n = 1 })
  end
  -- Scry / surveil / mill (you).
  local sw = t:match("scry (%d+)")
  if sw then
    table.insert(actions, { what = "scry", who = "you", n = tonumber(sw) })
  end
  sw = t:match("surveil (%d+)")
  if sw then
    table.insert(actions, { what = "scry", who = "you", n = tonumber(sw), surveil = true })
  end
  local mAt = t:find("mill ", 1, true)
  if mAt then
    local before = t:sub(math.max(1, mAt - 10), mAt - 1)
    local mw = t:match("mill (%w+) cards?")
    if mw and num(mw) and not before:find("player", 1, true) and not before:find("opponent", 1, true) then
      table.insert(actions, { what = "mill", who = "you", n = num(mw) })
    end
  end
  -- "put a quest counter on ~": counters on the card itself.
  local cn, ckind = t:match("put (%w+) ([%w%+/%-]+) counters? on ~")
  if cn and num(cn) then
    local kind = (ckind == "+1/+1" and "plus") or (ckind == "-1/-1" and "minus") or (ckind == "loyalty" and "loyalty")
      or "other"
    table.insert(actions, { what = "counter", who = "you", n = num(cn), kind = kind, label = ckind })
  end
  -- "return a land you control to its owner's hand" (bounce lands),
  -- "return target creature to its owner's hand": pick it on the table.
  local btype = t:match("return an? (%a+) you control to its owner's hand")
  if btype then
    table.insert(actions, { what = "bounce", who = "you", n = 1, type = btype, mine = true })
  else
    btype = t:match("return target (%a+) to its owner's hand")
    local other = false
    if not btype then
      -- Aether Channeler: "return another target nonland permanent to its owner's hand"
      local ph = t:match("return another target ([%a ]-) to its owner's hand")
      if ph then
        other = true
        btype = ph:match("^(nonland) permanent$") or ph:match("^(%a+)$")
      end
    end
    if not btype then
      local ph = t:match("return target (nonland) permanent to its owner's hand")
      btype = ph
    end
    if btype then
      table.insert(actions, { what = "bounce", who = "you", n = 1, type = btype, mine = false, other = other })
    end
  end
  if #actions == 0 and #conds == 0 then
    if firstWhy then
      return nil, "it has a condition (" .. firstWhy .. ")"
    end
    return nil, "nothing it can apply on its own"
  end
  local optional = t:find("you may", 1, true) ~= nil
  -- "You may reveal a creature card": the look panel is already optional.
  if #actions == 1 and actions[1].what == "look" then
    optional = false
  end
  -- Etali: the exile happens; only the casting is optional (asked per card).
  for _, act in ipairs(actions) do
    if act.what == "exileCast" or act.what == "untapAttacker" or act.what == "revealUntil" then
      optional = false
    end
  end
  return { optional = optional, actions = actions, notes = notes, conds = conds }
end

---------------------------------------------------------------------------
-- Doing it
---------------------------------------------------------------------------

local function players()
  local s = GameState.data.setup
  local list = {}
  for _, c in ipairs((s and s.participants) or TableSetup.activeSeats()) do
    local p = GameState.player(c)
    if p and not p.eliminated then
      table.insert(list, c)
    end
  end
  return list
end

local function describe(a, target, controller)
  local who = a.who == "you" and (controller or "you") or (a.who == "opponents" and "each opponent")
    or (a.who == "all" and "each player") or tostring(target or a.who)
  local you = who == "you"
  if a.what == "search" then
    return who .. (you and " search " or " searches ") .. "the library for " .. tostring(a.phrase)
  elseif a.what == "counter" then
    return a.n .. " " .. tostring(a.label) .. " counter" .. (a.n == 1 and "" or "s") .. " added"
  elseif a.what == "exactLife" then
    return "players with exactly " .. a.life .. " life lose the game, then everyone " .. (a.dir == "gain" and "gains " or "loses ") .. a.n .. " life"
  elseif a.what == "oppMayDraw" then
    return "target opponent may draw " .. a.n .. " cards (or " .. a.counters .. " +1/+1 counters on it)"
  elseif a.what == "contract" then
    return "the damaged player may discard their hand, draw seven cards and get a contract counter"
  elseif a.what == "goad" then
    return "goads a target creature"
  elseif a.what == "bounceSelf" then
    return "it returns to its owner's hand"
  elseif a.what == "chaosWarp" then
    return "a target permanent is shuffled into its owner's library, then the top card may enter"
  elseif a.what == "fabricate" then
    return "Fabricate " .. a.n .. ": a +1/+1 counter or a Servo token"
  elseif a.what == "bounce" then
    return who .. " returns a " .. tostring(a.type) .. " to hand"
  elseif a.what == "untap" or a.what == "tap" then
    return tostring(a.cardName or "it") .. (a.what == "untap" and " untapped" or " tapped")
  elseif a.what == "token" then
    local ph = tostring(a.phrase)
    if a.countWord then
      ph = ph:gsub("^1 ", "one per " .. a.countWord:gsub("s$", "") .. (a.countScope == "opponents" and " your opponents control: " or " you control: "), 1)
    end
    return who .. (you and " create " or " creates ") .. ph .. " token"
  elseif a.what == "amass" then
    return who .. (you and " amass " or " amasses ") .. a.n
  elseif a.what == "pump" then
    return tostring(a.label) .. " until end of turn (" .. tostring(a.count or "target") .. ")"
  elseif a.what == "graveReturn" then
    return who .. " returns a " .. (a.type ~= "" and (a.type .. " ") or "") .. "card from the graveyard"
  elseif a.what == "scry" then
    return who .. (a.surveil and (you and " surveil " or " surveils ") or (you and " scry " or " scries ")) .. a.n
  elseif a.what == "mill" then
    return who .. (you and " mill " or " mills ") .. a.n
  elseif a.what == "removeAll" then
    return a.verb .. " all " .. tostring(a.phrase) .. " (" .. tostring(a.count or 0) .. ")"
  elseif a.what == "removeTarget" then
    return a.verb .. " target " .. tostring(a.phrase)
  elseif a.what == "sacrifice" then
    return who .. " may sacrifice " .. tostring(a.phrase)
  elseif a.what == "look" then
    return who .. (you and " look" or " looks") .. " at the top " .. a.n .. " cards"
  elseif a.what == "transform" then
    return "it transforms"
  elseif a.what == "manifest" then
    return who .. " " .. a.kind .. "s the top card"
  elseif a.what == "win" then
    return who .. " wins the game"
  elseif a.what == "revealUntil" then
    return who .. " reveal cards until a " .. tostring(a.type) .. " and put it "
      .. (a.where == "hand" and "into their hand" or ("onto the battlefield" .. (a.attacking and " tapped and attacking" or "")))
  elseif a.what == "exileCast" then
    return who .. " exiles cards and may cast them free"
  elseif a.what == "poison" then
    return "poison counters"
  elseif a.what == "untapAttacker" then
    return "untap an attacking creature"
  elseif a.what == "oppExile" then
    return "each opponent exiles a " .. tostring(a.type)
  elseif a.what == "sacSelf" then
    return "it is sacrificed"
  elseif a.what == "returnExiledWith" then
    return "a " .. tostring(a.type) .. " exiled with it comes back"
  elseif a.what == "toLibrary" then
    return "it goes " .. a.n .. "th from the top of the library"
  end
  if a.what == "gain" then
    if a.thatMuch then
      return who .. (you and " gain " or " gains ") .. "that much life"
    end
    if a.perSpell then
      return who .. (you and " gain " or " gains ") .. a.n .. " life for each spell cast this turn"
    end
    return who .. (you and " gain " or " gains ") .. a.n .. " life"
  elseif a.what == "lose" then
    if target == "other" then
      return (a.countWord and "damage" or (a.n .. " damage")) .. " to a creature or planeswalker (by hand)"
    end
    if a.countWord then
      return who .. (you and " lose" or " loses") .. " life equal to your " .. a.countWord .. " count"
    end
    return who .. (you and " lose " or " loses ") .. a.n .. " life"
  end
  return who .. (you and " draw " or " draws ") .. a.n
end

local function amountOf(a, controller, name)
  if a.countWord then
    local n = Effects.countPermanents(controller, a.countWord, a.countScope)
    printToAll("MTG > " .. tostring(name) .. ": " .. n .. " " .. a.countWord .. (a.countScope == "opponents" and " your opponents control." or " you control."), INFO)
    return n
  end
  return a.n
end

local function apply(it, plan, target)
  local controller = it.controller
  local done = {}
  for _, a in ipairs(plan.actions) do
    local seats
    if a.who == "you" then
      seats = { controller }
    elseif a.who == "opponents" then
      seats = {}
      for _, c in ipairs(players()) do
        if c ~= controller then
          table.insert(seats, c)
        end
      end
    elseif a.who == "all" then
      seats = players()
    elseif a.who == "that" then
      seats = { it.that or target }
    elseif a.who == "any" and target == "other" then
      seats = {}
      printToAll("MTG > " .. it.name .. ": " .. a.n .. " damage to a creature or planeswalker: change its damage / loyalty by hand.", INFO)
    else
      seats = { target }
    end
    for _, seat in ipairs(seats) do
      if seat and GameState.player(seat) then
        if a.what == "gain" then
          local gain = a.n
          if a.thatMuch then
            gain = it.amount or 0
          end
          if a.perSpell then
            gain = a.n * math.max(1, Effects.spellsThisTurn(controller))
            printToAll("MTG > " .. it.name .. ": " .. controller .. " has cast " .. math.max(1, Effects.spellsThisTurn(controller))
              .. " spell(s) this turn.", INFO)
          end
          Trackers.changeLife(seat, gain, it.name)
        elseif a.what == "lose" then
          local lost = amountOf(a, controller, it.name)
          if lost > 0 then
            Trackers.changeLife(seat, -lost, it.name)
          end
        elseif a.what == "draw" then
          Actions.draw(seat, a.n, it.name)
        elseif a.what == "search" then
          local how
          if a.where == "both" then
            how = "click a card for the battlefield" .. (a.tapped and " (tapped)" or "")
              .. ", then switch TO: HAND for the other one"
          elseif a.where == "battlefield" then
            how = "click a card to put it onto the battlefield" .. (a.tapped and " tapped" or "")
          elseif a.where == "top" then
            how = "click the card: it is revealed and goes on top of your library after the shuffle"
          else
            how = "click a card to put it into your hand"
          end
          LibSearch.open(seat, a.query, it.name .. " (" .. tostring(a.phrase) .. "): " .. how .. (a.where == "top" and "." or ", then CLOSE + SHUFFLE."),
            (a.where == "hand" or a.where == "top") and a.where or "battlefield", a.tapped,
            { typeOnly = true, mvMin = a.mvMin, mvMax = a.mvMax, anyOf = a.anyOf, limit = a.where == "top" and 1 or nil })
        elseif a.what == "counter" then
          local src = it.source and getObjectFromGUID(it.source)
          if src and not src.isDestroyed() then
            Counters.change(src, a.kind, a.n, seat)
          else
            broadcastToColor(it.name .. " isn't on the table any more: no counter added.", seat, INFO)
          end
        elseif a.what == "bounce" then
          Effects.pickBounce(seat, a, it.name, it.source)
        elseif a.what == "token" then
          local made = amountOf(a, controller, it.name)
          local opts = (a.tapped or a.attacking) and { tapped = a.tapped, attacking = a.attacking, from = it.thatCard or it.source } or nil
          if made < 1 then
            printToAll("MTG > " .. it.name .. ": no tokens (the count is 0).", INFO)
          elseif a.alt then
            local first = tostring(a.phrase):gsub("^an? ", "")
            local second = tostring(a.alt.phrase):gsub("^an? ", "")
            Effects.askChoice(seat, it.name .. ": which token?", "Create " .. first .. " or " .. second .. ".",
              { { label = string.upper(first), value = 1 }, { label = string.upper(second), value = 2 } }, function(i)
                local pickSpec = i == 1 and a.spec or a.alt.spec
                printToAll("MTG > " .. seat .. " chose " .. (i == 1 and first or second) .. " (" .. it.name .. ").", GOOD)
                Tokens.create(seat, pickSpec, made, it.name, opts)
              end)
          else
            Tokens.create(seat, a.spec, made, it.name, opts)
          end
        elseif a.what == "exactLife" then
          -- Once, not once per seat: handled below the seat loop.
          if seat == seats[1] then
            for _, c in ipairs(players()) do
              local p = GameState.player(c)
              if p and not p.eliminated and p.life == a.life then
                Trackers.flagLoss(c, "exactly " .. a.life .. " life (" .. it.name .. ")")
              end
            end
            for _, c in ipairs(players()) do
              local p = GameState.player(c)
              if p and not p.eliminated then
                Trackers.changeLife(c, a.dir == "gain" and a.n or -a.n, it.name)
              end
            end
            broadcastToAll(it.name .. ": every player " .. (a.dir == "gain" and "gained " or "lost ") .. a.n .. " life.", { 1, 0.85, 0.3 })
          end
        elseif a.what == "oppMayDraw" then
          local src = it.source and getObjectFromGUID(it.source)
          Effects.askChoice(seat, it.name .. ": draw " .. a.n .. " cards?",
            controller .. "'s " .. it.name .. ": draw " .. a.n .. " cards, or " .. controller .. " gets "
            .. a.counters .. " +1/+1 counters on it.",
            { { label = "DRAW " .. a.n, value = true }, { label = "DON'T", value = false } }, function(draw)
              if draw then
                printToAll("MTG > " .. seat .. " draws " .. a.n .. " cards (" .. it.name .. ").", INFO)
                Actions.draw(seat, a.n, it.name)
                if a.cast then
                  printToAll("MTG > " .. it.name .. ": " .. controller .. " looks at " .. seat
                    .. "'s hand and may cast a spell from it without paying its mana cost (by hand).", GOOD)
                  broadcastToColor("Look at " .. seat .. "'s hand: you may cast a spell from it for free (do it by hand).", controller, GOOD)
                end
              elseif src and not src.isDestroyed() then
                Counters.change(src, "plus", a.counters, controller)
                printToAll("MTG > " .. seat .. " declines: " .. it.name .. " gets " .. a.counters .. " +1/+1 counters.", GOOD)
              else
                printToAll("MTG > " .. seat .. " declines: " .. controller .. " puts " .. a.counters .. " +1/+1 counters on " .. it.name .. " by hand.", INFO)
              end
            end)
        elseif a.what == "contract" then
          Effects.contractOffer(seat, controller, it)
        elseif a.what == "goad" then
          Effects.askChoice(seat, it.name .. ": goad a creature", "Click GOAD on the creature (it attacks each combat if able, and a player other than " .. seat .. " if able).",
            { { label = "SKIP", value = false } }, function(obj)
              if obj then
                Counters.setGoad(obj, seat)
                printToAll("MTG > " .. obj.getName() .. " is goaded by " .. seat .. " (" .. it.name .. ").", { 1, 0.6, 0.2 })
                broadcastToAll(obj.getName() .. " is GOADED by " .. seat .. ".", { 1, 0.6, 0.2 })
              end
            end, { filter = function(obj, owner)
              return Effects.cardTypes(obj).creature == true
            end, label = "GOAD" })
        elseif a.what == "bounceSelf" then
          local src = it.source and getObjectFromGUID(it.source)
          if src and not src.isDestroyed() then
            Effects.returnSelf(src)
          else
            printToAll("MTG > " .. it.name .. " isn't on the table any more.", INFO)
          end
        elseif a.what == "chaosWarp" then
          Effects.chaosWarp(seat, it)
        elseif a.what == "fabricate" then
          local src = it.source and getObjectFromGUID(it.source)
          Effects.askChoice(seat, it.name .. ": Fabricate " .. a.n, "Put " .. a.n .. " +1/+1 counter" .. (a.n == 1 and "" or "s") .. " on it, or create "
            .. a.n .. " 1/1 Servo token" .. (a.n == 1 and "" or "s") .. ".",
            { { label = "+1/+1 COUNTER", value = 1 }, { label = "SERVO TOKEN", value = 2 } }, function(i)
              if i == 1 and src and not src.isDestroyed() then
                Counters.change(src, "plus", a.n, seat)
                printToAll("MTG > " .. seat .. " put " .. a.n .. " +1/+1 counter(s) on " .. it.name .. " (fabricate).", GOOD)
              else
                if i == 1 then
                  printToAll("MTG > " .. it.name .. " isn't on the table: making Servo tokens instead.", INFO)
                end
                Tokens.create(seat, { pt = "1/1", words = { "servo" }, colors = {} }, a.n, it.name)
              end
            end)
        elseif a.what == "amass" then
          Effects.amass(seat, a.kind, a.n, it.name)
        elseif a.what == "pump" then
          a.count = Effects.pump(seat, a, it)
        elseif a.what == "graveReturn" then
          LibSearch.open(seat, a.type, it.name .. ": click the " .. (a.type ~= "" and a.type or "card") .. " to return it"
            .. (a.where == "battlefield" and " to the battlefield" or " to your hand") .. ", then CLOSE.",
            a.where, a.tapped, { typeOnly = true, zone = "graveyard" })
        elseif a.what == "scry" then
          for _ = 1, a.n do
            Actions.openScry(seat)
          end
        elseif a.what == "mill" then
          Actions.mill(seat, a.n)
        elseif a.what == "removeAll" then
          a.count = Effects.removeAll(seat, a, it)
        elseif a.what == "removeTarget" then
          Effects.pickRemove(seat, a, it.name, it.source)
        elseif a.what == "sacrifice" then
          Effects.pickSacrifice(seat, a, it)
        elseif a.what == "poison" then
          Trackers.changePoison(seat, a.fromTrigger and (it.amount or 0) or a.n, it.name)
        elseif a.what == "revealUntil" then
          Effects.revealUntil(seat, a, it)
        elseif a.what == "exileCast" then
          Effects.exileCast(seat, a, it)
        elseif a.what == "untapAttacker" then
          Effects.untapAttacker(seat, a, it)
        elseif a.what == "oppExile" then
          Effects.oppExile(seat, a, it)
        elseif a.what == "sacSelf" then
          local src = it.source and getObjectFromGUID(it.source)
          if src and not src.isDestroyed() then
            printToAll("MTG > " .. it.name .. " is sacrificed.", GOOD)
            Combat.removeCard(src, "graveyard")
          else
            broadcastToColor(it.name .. ": sacrifice it yourself.", seat, INFO)
          end
        elseif a.what == "returnExiledWith" then
          Effects.returnExiledWith(seat, a, it)
        elseif a.what == "win" then
          broadcastToAll(seat .. " WINS THE GAME (" .. it.name .. ")!", { 1, 0.85, 0.2 })
          printToAll("MTG > " .. seat .. " wins the game (" .. it.name .. ").", GOOD)
        elseif a.what == "toLibrary" then
          local card = it.card and getObjectFromGUID(it.card)
          if card and not card.isDestroyed() then
            it.cardHandled = true
            Library.putAt(seat, card, a.n - 1)
          else
            broadcastToColor(it.name .. ": put it " .. a.n .. "th from the top of your library yourself.", seat, INFO)
          end
        elseif a.what == "manifest" then
          Faces.manifest(seat, a.kind, it.name)
        elseif a.what == "transform" then
          local src = it.source and getObjectFromGUID(it.source)
          if src and not src.isDestroyed() and Faces.isDoubleFaced(src) then
            Faces.flip(src, it.name)
          else
            broadcastToColor(it.name .. ": transform it yourself (right-click > Transform / other face).", seat, INFO)
          end
        elseif a.what == "look" then
          local how = a.where == "battlefield" and ("click it to put it onto the battlefield" .. (a.tapped and " tapped" or ""))
            or "click it to put it into your hand"
          LibSearch.open(seat, a.query, it.name .. ": the top " .. a.n .. " cards" .. (a.query ~= "" and (" (" .. a.query .. ")") or "")
            .. ": " .. how .. ". CLOSE puts the rest on the bottom.", a.where, a.tapped,
            { typeOnly = true, topN = a.n, picks = a.picks })
        elseif a.what == "untap" or a.what == "tap" then
          local card = it.thatCard and getObjectFromGUID(it.thatCard)
          local owner = card and Zones.regionAt(card.getPosition()).seat
          if card and not card.isDestroyed() and owner then
            a.cardName = card.getName()
            -- After "enters tapped" has turned it (that waits 0.8 s).
            Wait.time(function()
              if not card.isDestroyed() then
                local s = TableSetup.seat(owner)
                local r = card.getRotation()
                local yaw = a.what == "untap" and s.yaw or (s.yaw + 90) % 360
                card.setRotationSmooth({ r.x, yaw, r.z }, false, true)
              end
            end, 1)
          else
            broadcastToColor(it.name .. ": " .. a.what .. " it yourself (couldn't tell which card).", seat, INFO)
          end
        end
      end
    end
    table.insert(done, describe(a, a.who == "that" and (it.that or target) or target, controller))
  end
  if #done > 0 then
    printToAll("MTG > " .. it.name .. " resolved: " .. table.concat(done, ", ") .. ".", GOOD)
  end
  for _, n in ipairs(plan.notes or {}) do
    broadcastToColor(it.name .. ": do this part yourself: \"" .. n .. "\"", controller, INFO)
  end
end

---------------------------------------------------------------------------
-- Questions (YES / NO, pick a player): a panel only the controller sees
---------------------------------------------------------------------------

local queue = {}     -- questions waiting: { seat, title, text, choices = { {label, value} }, onPick }
local current = nil

function Effects.isPending()
  return current ~= nil or #queue > 0
end

local function seated(color)
  local ok, yes = pcall(function() return Player[color].seated end)
  return ok and yes
end

local pickShown = false   -- card buttons are up for a "pick a permanent" question

-- Redraw every card on the battlefields (their buttons come from
-- Counters.render, which calls Effects.decorate).
local function refreshCards()
  if Combat and Combat.refresh then
    Combat.refresh()
  end
end

local numTyped = {}   -- [seat] = what's typed in the number box

local function render()
  local picking = current ~= nil and current.pick ~= nil
  if picking or pickShown then
    pickShown = picking
    refreshCards()
  end
  for _, c in ipairs(TableSetup.activeSeats()) do
    local q = current and current.seat == c and current or nil
    UI.setAttribute("effAsk_" .. c, "active", q and "true" or "false")
    if q then
      UI.setValue("effTitle_" .. c, q.title)
      UI.setValue("effText_" .. c, q.text)
      UI.setAttribute("effNum_" .. c, "active", q.number and "true" or "false")
      if q.number then
        numTyped[c] = nil
        UI.setAttribute("effNumIn_" .. c, "text", "")
      end
      for i = 1, MAX_CHOICES do
        local ch = q.choices[i]
        UI.setAttribute("effChoice_" .. c .. "_" .. i, "active", ch and "true" or "false")
        if ch then
          UI.setValue("effChoiceTxt_" .. c .. "_" .. i, ch.label)
        end
      end
    end
  end
end

local function nextQuestion()
  -- (TTS's Lua errors on table.remove of an empty list.)
  current = #queue > 0 and table.remove(queue, 1) or nil
  if current == nil then
    -- All answered: a step that moves on by itself (draw, upkeep via END
    -- TURN...) can carry on now.
    Wait.time(function()
      if Stack.isEmpty() and Turns.onStackEmpty then
        Turns.onStackEmpty()
      end
    end, 0.3)
  end
  if current then
    -- Nobody in that seat: in solo test mode everyone sees it; otherwise
    -- the first choice is taken (YES / the first opponent).
    if not seated(current.seat) then
      if GameState.solo() then
        UI.setAttribute("effAsk_" .. current.seat, "visibility", "")
      else
        local q = current
        current = nil
        q.onPick(q.choices[1].value)
        if current == nil then
          nextQuestion()
        end
        return
      end
    end
  end
  render()
end

local function ask(seat, title, text, choices, onPick, pick, number)
  table.insert(queue, { seat = seat, title = title, text = text, choices = choices, onPick = onPick, pick = pick,
    number = number })
  if current == nil then
    nextQuestion()
  end
end

-- For code above `ask` in this file (apply).
function Effects.askChoice(seat, title, text, choices, onPick, pick)
  ask(seat, title, text, choices, onPick, pick)
end

function ui_effPick(player, arg)
  local seat, i = tostring(arg):match("^(%a+)_(%d+)$")
  local q = current
  if q == nil or seat ~= q.seat then
    return
  end
  if player.color ~= seat and not GameState.solo() then
    return
  end
  local ch = q.choices[tonumber(i)]
  if ch == nil then
    return
  end
  current = nil
  UI.setAttribute("effAsk_" .. seat, "visibility", seat)
  q.onPick(ch.value)
  -- The answer may have asked a new question already (a mode that needs a
  -- target, "unless" then "you may"): don't skip past it.
  if current == nil then
    nextQuestion()
  end
end

function ui_effNumText(player, value)
  numTyped[player.color] = value
end

function ui_effNumOk(player, seat)
  local q = current
  if q == nil or not q.number or seat ~= q.seat then
    return
  end
  if player.color ~= seat and not GameState.solo() then
    return
  end
  local n = tonumber(numTyped[player.color] or numTyped[seat] or "")
  if n == nil or n < 0 then
    broadcastToColor("Type a number first.", player.color, INFO)
    return
  end
  current = nil
  q.onPick(math.floor(n))
  if current == nil then
    nextQuestion()
  end
end

function Effects.xml()
  local parts = {}
  for _, c in ipairs(TableSetup.activeSeats()) do
    local choices = {}
    for i = 1, MAX_CHOICES do
      table.insert(choices, ('<Panel id="effChoice_%s_%d" active="false" preferredWidth="96" preferredHeight="40">'
        .. '<Button onClick="ui_effPick(%s_%d)" color="#1B2333" />'
        .. '<Text id="effChoiceTxt_%s_%d" raycastTarget="false" fontSize="14" fontStyle="Bold" color="#E6F1FF">-</Text></Panel>')
        :format(c, i, c, i, c, i))
    end
    table.insert(parts, ([[
<Panel id="effAsk_%s" visibility="%s" active="false" rectAlignment="MiddleCenter" offsetXY="0 -60" width="560" height="236"
       color="#0B0F17F5" outline="#5AF0FF" outlineSize="2 2" allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="14 14 12 12" spacing="8" childForceExpandHeight="false">
    <Text id="effTitle_%s" fontSize="17" fontStyle="Bold" color="#5AF0FF" alignment="MiddleLeft" preferredHeight="24">-</Text>
    <Text id="effText_%s" fontSize="13" color="#E6F1FF" alignment="UpperLeft" preferredHeight="60">-</Text>
    <HorizontalLayout id="effNum_%s" active="false" spacing="8" preferredHeight="38" childForceExpandWidth="false" childAlignment="MiddleLeft">
      <InputField id="effNumIn_%s" characterValidation="Integer" onValueChanged="ui_effNumText" preferredWidth="120" fontSize="18" placeholder="X" />
      <Button onClick="ui_effNumOk(%s)" preferredWidth="96" color="#00B3A4" textColor="#06130B" fontStyle="Bold">OK</Button>
    </HorizontalLayout>
    <HorizontalLayout spacing="8" preferredHeight="40" childForceExpandWidth="false" childAlignment="MiddleLeft">
      ]] .. table.concat(choices, "\n      ") .. [[

    </HorizontalLayout>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, c, c, c, c))
  end
  return table.concat(parts)
end

---------------------------------------------------------------------------
-- Called by the stack when an ability resolves
---------------------------------------------------------------------------

-- How many times each ability has resolved this turn ("If this is the
-- fourth time this ability has resolved this turn", Sephiroth).
local ORDINAL = { first = 1, second = 2, third = 3, fourth = 4, fifth = 5, sixth = 6, seventh = 7, eighth = 8,
  ninth = 9, tenth = 10 }

local function countResolve(it)
  local d = GameState.data
  local turnNo = d.turn and d.turn.taken or 0
  if d.resolved == nil or d.resolved.turn ~= turnNo then
    d.resolved = { turn = turnNo, counts = {} }
  end
  local key = tostring(it.source or "") .. "|" .. tostring(it.name) .. "|" .. tostring(it.text):sub(1, 60)
  d.resolved.counts[key] = (d.resolved.counts[key] or 0) + 1
  return d.resolved.counts[key]
end

-- it = the stack item { name, controller, text, that, auto }.
function Effects.resolve(it)
  if not enabled() or not it.auto or not GameState.data.started then
    return
  end
  if it.resolvedTimes == nil then
    it.resolvedTimes = countResolve(it)
  end
  -- "Choose one —" with "• mode" lines: the controller picks a mode first.
  local raw = tostring(it.text or "")
  local bullet = raw:find("•", 1, true)
  if bullet and not it.modePicked then
    local modes = {}
    local rest = raw:sub(bullet)
    local pos = 1
    while true do
      local a = rest:find("•", pos, true)
      if not a then
        break
      end
      local b = rest:find("•", a + 1, true)
      local m = rest:sub(a + #"•", (b or (#rest + 1)) - 1):gsub("^%s+", ""):gsub("%s+$", "")
      table.insert(modes, m)
      pos = b or (#rest + 1)
      if not b then
        break
      end
    end
    if #modes > 0 then
      local lines, choices = {}, {}
      -- Modes that start alike (Triskaidekaphobia): the buttons show where
      -- they differ, from the last shared word on.
      local common = 0
      if #modes > 1 then
        local first = modes[1]
        local limit = #first
        for _, m in ipairs(modes) do
          limit = math.min(limit, #m)
        end
        for k = 1, limit do
          local same = true
          for _, m in ipairs(modes) do
            if m:sub(k, k) ~= first:sub(k, k) then
              same = false
            end
          end
          if not same then
            break
          end
          common = k
        end
        while common > 0 and first:sub(common, common) ~= " " do
          common = common - 1
        end
      end
      for i, m in ipairs(modes) do
        if i <= MAX_CHOICES then
          table.insert(lines, i .. ") " .. (#m > 150 and (m:sub(1, 148) .. "...") or m))
          local tail = common > 0 and m:sub(common + 1):gsub("^%s+", ""):gsub("[%.]+$", "") or ""
          table.insert(choices, { label = (tail ~= "" and #tail <= 30) and (i .. ": " .. tail) or tostring(i), value = i })
        end
      end
      ask(it.controller, it.name .. ": choose a mode", table.concat(lines, "\n"), choices, function(i)
        local copy = {}
        for k, v in pairs(it) do
          copy[k] = v
        end
        copy.text = modes[i]
        copy.modePicked = true
        printToAll("MTG > " .. it.controller .. " chose: " .. modes[i], INFO)
        -- On-screen banner for everyone: which mode was chosen.
        broadcastToAll(it.name .. " (" .. it.controller .. ") chose: " .. (#modes[i] > 140 and (modes[i]:sub(1, 138) .. "...") or modes[i]), { 1, 0.85, 0.3 })
        Effects.resolve(copy)
      end)
      return
    end
  end
  -- "... unless that player pays {1}" (Rhystic Study): that player decides first.
  local low = raw:lower()
  local un = low:find("unless that player pays", 1, true) or low:find("unless they pay", 1, true)
    or low:find("unless its controller pays", 1, true)
  if un and not it.unlessDone then
    local stop = raw:find(".", un, true) or (#raw + 1)
    local clause = raw:sub(un, stop - 1)
    local copy = {}
    for k, v in pairs(it) do
      copy[k] = v
    end
    copy.text = raw:sub(1, un - 1):gsub("%s+$", "") .. raw:sub(stop)
    copy.unlessDone = true
    local payer = it.that
    if payer and payer ~= it.controller and GameState.player(payer) then
      ask(payer, it.name .. " (" .. it.controller .. ")", "Pay to stop it? (" .. clause .. ")",
        { { label = "PAY", value = true }, { label = "DON'T", value = false } }, function(pays)
          if pays then
            printToAll("MTG > " .. payer .. " pays: " .. it.name .. " does nothing.", INFO)
          else
            Effects.resolve(copy)
          end
        end)
      return
    end
    it = copy
  end
  -- Join forces (Collective Voyage): everyone may pay, then everyone searches.
  if low:find("join forces", 1, true) then
    Effects.joinForces(it)
    return
  end
  -- X chosen when it was cast ("pay X life", {X} in the cost): ask for it,
  -- then read the text with the number in place of X.
  if not it.xDone then
    local lowX = " " .. tostring(it.text or ""):lower() .. " "
    local hasX = lowX:find("[^%a]x[^%a]") ~= nil
    local defined = lowX:find("where x", 1, true) or lowX:find(" x is ", 1, true)
    local chosen = tostring(it.manaCost or ""):find("{X}", 1, true) or lowX:find("pay x life", 1, true)
      or lowX:find("{x}", 1, true)
    if hasX and chosen and not defined then
      ask(it.controller, it.name .. ": what is X?", "Type the X it was cast with, then OK.\n" .. tostring(it.text),
        { { label = "SKIP", value = false } }, function(n)
          if n == false then
            printToAll("MTG > " .. it.name .. ": resolve it by hand.", INFO)
            return
          end
          local copy = {}
          for k, v in pairs(it) do
            copy[k] = v
          end
          local s = " " .. tostring(it.text) .. " "
          for _ = 1, 2 do
            s = s:gsub("([^%a])[Xx]([^%a])", "%1" .. n .. "%2")
          end
          copy.text = s:gsub("^ ", ""):gsub(" $", "")
          copy.xDone = true
          printToAll("MTG > " .. it.name .. ": X = " .. n .. ".", INFO)
          Effects.resolve(copy)
        end, nil, true)
      return
    end
  end
  local plan, why = Effects.parse(it.text, it.name)
  if plan == nil then
    printToAll("MTG > " .. it.name .. ": resolve it by hand (" .. tostring(why) .. ").", INFO)
    return
  end
  local seat = it.controller
  -- "If ..., ..." parts: the controller says whether it's true, then the
  -- rest resolves like any other effect.
  local function branch(c, yes)
    local text = yes and c.rest or c.otherwise
    if text == nil and c.silent then
      return
    end
    if text == nil then
      printToAll("MTG > " .. it.name .. ": not true, so that part does nothing.", INFO)
      return
    end
    local copy = {}
    for k, v in pairs(it) do
      copy[k] = v
    end
    copy.text = text
    copy.modePicked = true
    copy.unlessDone = true
    Effects.resolve(copy)
  end
  local function askConds()
    for _, c in ipairs(plan.conds or {}) do
      -- Conditions the table can see for itself.
      local auto = Effects.condValue(c.cond, seat, it.name)
      if auto ~= nil then
        c.auto = auto
        c.silent = true
      end
      -- Approach of the Second Sun: the table knows what was cast.
      if c.cond:find("cast another spell named ~ this game", 1, true) then
        local n = Effects.castCount(seat, it.name)
        printToAll("MTG > " .. it.name .. ": " .. seat .. " has cast it " .. n .. " time" .. (n == 1 and "" or "s")
          .. " this game.", INFO)
        c.auto = n >= 2
      end
    end
    for _, c in ipairs(plan.conds or {}) do
      local ordWord = c.cond:match("^this is the (%a+) time this ability has resolved this turn")
      local nth = ordWord and ORDINAL[ordWord]
      if c.auto ~= nil then
        branch(c, c.auto)
      elseif nth then
        -- The table counts it: no need to ask.
        if it.resolvedTimes == nth then
          local copy = {}
          for k, v in pairs(it) do
            copy[k] = v
          end
          copy.text = c.rest
          copy.modePicked = true
          copy.unlessDone = true
          printToAll("MTG > " .. it.name .. ": " .. ordWord .. " time this turn.", INFO)
          Effects.resolve(copy)
        end
      else
        local title, text
        if c.prev then
          title, text = it.name .. ": did you?", "Did you do this: \"" .. c.prev .. "\"\nIf you did: " .. c.rest
        elseif c.cond == "you do" then
          title, text = it.name .. ": did you?", "Did you do it? If you did: " .. c.rest
        else
          title, text = it.name .. ": is this true?", "If " .. c.cond .. "?\nThen: " .. c.rest
        end
        if c.otherwise then
          text = text .. "\nOtherwise: " .. c.otherwise
        end
        ask(seat, title, text, { { label = "YES", value = true }, { label = "NO", value = false } }, function(yes)
          branch(c, yes)
        end)
      end
    end
  end
  if #plan.actions == 0 then
    apply(it, plan, nil)   -- just the "do this yourself" notes
    askConds()
    return
  end
  local needsTarget, oppOnly = false, false
  for _, a in ipairs(plan.actions) do
    if a.who == "target" or a.who == "targetOpponent" or a.who == "any" or (a.who == "that" and it.that == nil) then
      needsTarget = true
      oppOnly = oppOnly or a.who == "targetOpponent"
    end
  end
  local function withTarget()
    if not needsTarget then
      apply(it, plan, nil)
      return
    end
    local choices = {}
    for _, c in ipairs(players()) do
      if not (oppOnly and c == seat) then
        -- Opponents first, so a seat nobody sits in picks one by default.
        table.insert(choices, c == seat and #choices + 1 or 1, { label = string.upper(c), value = c })
      end
    end
    local anyTarget = false
    for _, a in ipairs(plan.actions) do
      anyTarget = anyTarget or a.who == "any"
    end
    if anyTarget then
      table.insert(choices, { label = "CREATURE", value = "other" })
    end
    table.insert(choices, { label = "SKIP", value = false })
    while #choices > MAX_CHOICES do
      table.remove(choices, #choices - (anyTarget and 2 or 1))
    end
    ask(seat, it.name .. ": choose " .. (anyTarget and "a target" or "a player"), tostring(it.text), choices, function(target)
      if target then
        apply(it, plan, target)
      else
        printToAll("MTG > " .. it.name .. ": skipped.", INFO)
      end
    end)
  end
  if plan.optional then
    local summary = {}
    for _, a in ipairs(plan.actions) do
      table.insert(summary, describe(a, a.who == "that" and it.that or "target"))
    end
    ask(seat, it.name .. ": you may", tostring(it.text) .. "\n(" .. table.concat(summary, ", ") .. ")",
      { { label = "YES", value = true }, { label = "NO", value = false } }, function(yes)
        if yes then
          withTarget()
        else
          printToAll("MTG > " .. seat .. " chose not to (" .. it.name .. ").", INFO)
        end
      end)
  else
    withTarget()
  end
  askConds()
end

-- A spell (instant / sorcery) resolved: carry out its rules text too.
function Effects.resolveSpell(obj, controller)
  if not enabled() or not GameState.data.started or obj == nil then
    return
  end
  local text, cost = "", ""
  pcall(function()
    local d = JSON.decode(obj.getGMNotes())
    if type(d) == "table" and type(d.oracle) == "string" then
      text = d.oracle
      cost = tostring(d.manaCost or "")
    end
  end)
  if text == "" then
    return false
  end
  Effects.resolve({ name = obj.getName(), controller = controller, text = text, auto = true, manaCost = cost,
    card = obj.getGUID() })
  -- "Put ~ into its owner's library seventh from the top": the effect moves
  -- the card, so the stack shouldn't send it to the graveyard.
  return text:lower():find("into its owner's library", 1, true) ~= nil
end

-- Spells each player has cast this game, by name (Approach of the Second Sun).
Events.on("spellCast", function(d)
  if d.card == nil or d.controller == nil or GameState.data == nil then
    return
  end
  GameState.data.castNames = GameState.data.castNames or {}
  local t = GameState.data.castNames
  t[d.controller] = t[d.controller] or {}
  local n = d.card.getName()
  t[d.controller][n] = (t[d.controller][n] or 0) + 1
end)

-- Spells each seat has cast this turn (Aetherflux Reservoir).
Events.on("spellCast", function(d)
  if d.card == nil or d.controller == nil or GameState.data == nil then
    return
  end
  local turn = (GameState.data.turn or {}).number or 0
  local c = GameState.data.castTurn
  if c == nil or c.turn ~= turn then
    c = { turn = turn }
    GameState.data.castTurn = c
  end
  c[d.controller] = (c[d.controller] or 0) + 1
end)

function Effects.spellsThisTurn(seat)
  local c = (GameState.data or {}).castTurn
  local turn = ((GameState.data or {}).turn or {}).number or 0
  if c == nil or c.turn ~= turn then
    return 0
  end
  return c[seat] or 0
end

function Effects.castCount(seat, name)
  local t = GameState.data.castNames or {}
  return (t[seat] or {})[name] or 0
end

---------------------------------------------------------------------------
-- Picking a permanent on the table (bounce lands, "return target ...")
---------------------------------------------------------------------------

local function cardTypes(obj)
  local t = {}
  pcall(function()
    local d = JSON.decode(obj.getGMNotes())
    for _, n in ipairs(type(d) == "table" and d.types or {}) do
      t[tostring(n):lower()] = true
    end
  end)
  return t
end
Effects.cardTypes = cardTypes

local function fieldSeat(obj)
  local loc = Zones.regionAt(obj.getPosition())
  if loc.region == "battlefield" or loc.region == "lands" then
    return loc.seat
  end
  return nil
end

-- How many permanents of a kind a seat (or its opponents) control: "Treasures
-- you control", "artifacts your opponents control". Tokens count by name.
local ARTIFACT_TOKENS = { treasure = true, clue = true, food = true, blood = true, powerstone = true, gold = true,
  junk = true, map = true, incubator = true, shard = true }

function Effects.countPermanents(seat, word, scope)
  word = tostring(word or ""):lower():gsub("ies$", "y"):gsub("s$", "")
  local n = 0
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and obj.held_by_color == nil then
      local owner = fieldSeat(obj)
      if owner and ((scope == "mine" and owner == seat) or (scope == "opponents" and owner ~= seat)) then
        local name = tostring(obj.getName()):lower()
        local hit = cardTypes(obj)[word] or name:find(word, 1, true) ~= nil
        if not hit and word == "artifact" then
          hit = ARTIFACT_TOKENS[name] or ARTIFACT_TOKENS[name:match("^(%a+) token") or ""] or false
          if not hit then
            pcall(function() hit = tostring(obj.getDescription()):lower():find("artifact", 1, true) ~= nil end)
          end
        end
        if hit then
          n = n + 1
        end
      end
    end
  end
  return n
end


-- A card button on each permanent that can be picked.
function Effects.decorate(obj)
  local q = current
  if q == nil or q.pick == nil or Faces.unknown(obj) then
    return
  end
  local seat = fieldSeat(obj)
  if seat == nil or not q.pick.filter(obj, seat) then
    return
  end
  obj.createButton({
    click_function = "effects_cardPick",
    function_owner = Global,
    label = q.pick.label,
    tooltip = q.title,
    position = { 0, 0.3, 0.5 },
    rotation = { 0, 0, 0 },
    width = 800,
    height = 260,
    font_size = 160,
    font_color = { 1, 1, 1 },
    color = { 0.05, 0.45, 0.55, 0.95 },
  })
end

function effects_cardPick(obj, color, alt)
  local q = current
  if q == nil or q.pick == nil or obj == nil or obj.isDestroyed() then
    return
  end
  if color ~= q.seat and not GameState.solo() then
    broadcastToColor("That's " .. q.seat .. "'s choice.", color, INFO)
    return
  end
  current = nil
  UI.setAttribute("effAsk_" .. q.seat, "visibility", q.seat)
  Counters.render(obj)   -- its RETURN button goes before it moves
  q.onPick(obj)
  if current == nil then
    nextQuestion()
  end
end

local function returnToHand(obj)
  local seat = fieldSeat(obj)
  if seat == nil then
    return
  end
  if Faces and Faces.state(obj) == 2 then
    obj = Faces.front(obj)
  end
  if obj.hasTag("Token") then
    printToAll("MTG > " .. obj.getName() .. " (a token) left the battlefield and is gone.", INFO)
    obj.destruct()
    return
  end
  local s = TableSetup.seat(seat)
  obj.setRotationSmooth({ 0, s.yaw, 0 }, false, true)
  obj.setPositionSmooth(Player[seat].getHandTransform().position, false, true)
  printToAll("MTG > " .. obj.getName() .. " returned to " .. seat .. "'s hand.", GOOD)
  -- So the table knows it's in the hand now (a later discard isn't "dies").
  Wait.time(function()
    if not obj.isDestroyed() then
      Zones.refresh(obj)
    end
  end, 1.2)
end

function Effects.pickBounce(seat, a, sourceName, sourceGuid)
  local want = tostring(a.type)
  local filter = function(obj, owner)
    if a.mine and owner ~= seat then
      return false
    end
    if a.other and sourceGuid and obj.getGUID() == sourceGuid then
      return false
    end
    local t = cardTypes(obj)
    if want == "permanent" then
      return true
    elseif want == "nonland" then
      return not t.land
    end
    return t[want] == true
  end
  ask(seat, sourceName .. ": return a " .. want, "Click RETURN on the " .. want .. " to return to its owner's hand.",
    { { label = "SKIP", value = false } }, function(obj)
      if obj then
        returnToHand(obj)
      else
        printToAll("MTG > " .. sourceName .. ": nothing returned.", INFO)
      end
    end, { filter = filter, label = "RETURN" })
end

-- Miss Highwater: the damaged player may discard their hand, draw seven and
-- get a contract counter (a marker beside their battlefield). When they lose
-- the game with it, the table reminds Miss Highwater's controller.
function Effects.contractOffer(victim, controller, it)
  local p = GameState.player(victim)
  if p == nil then
    return
  end
  if p.contract then
    printToAll("MTG > " .. victim .. " already has a contract counter (" .. it.name .. "): nothing happens.", INFO)
    return
  end
  Effects.askChoice(victim, it.name .. ": discard your hand?",
    "Discard your hand, draw seven cards and get a contract counter? (When you lose the game, " .. controller
    .. " makes token copies of each artifact and creature you controlled.)",
    { { label = "DISCARD + DRAW 7", value = true }, { label = "NO", value = false } }, function(yes)
      if not yes then
        printToAll("MTG > " .. victim .. " keeps their hand (" .. it.name .. ").", INFO)
        return
      end
      Actions.discardHand(victim, it.name)
      Wait.time(function() Actions.draw(victim, 7, it.name) end, 1.2)
      p.contract = controller
      printToAll("MTG > " .. victim .. " got a contract counter (" .. it.name .. ").", GOOD)
      broadcastToAll(victim .. " now has a CONTRACT COUNTER.", { 1, 0.75, 0.3 })
      local pos = TableSetup.slot(victim, "battlefield", TableSetup.SURFACE_TOP + 1)
      local s = TableSetup.seat(victim)
      local obj = spawnObject({
        type = "Custom_Token",
        position = { pos.x + s.right.x * 11, TableSetup.SURFACE_TOP + 0.6, pos.z + s.right.z * 11 },
        rotation = { 0, s.yaw, 0 },
        sound = false,
        callback_function = function(o)
          o.setName("Contract counter (" .. victim .. ")")
          o.setDescription(victim .. " has a contract counter from " .. it.name .. ". When they lose the game, "
            .. controller .. " creates a token copy of each artifact and creature they controlled.")
          o.addTag("ContractCounter")
          Wait.condition(function()
            local b = o.getBoundsNormalized()
            local w = b and b.size and b.size.x or 0
            if w > 0.05 then
              local k = 1.6 / (w / o.getScale().x)
              o.setScale({ k, 1, k })
            end
          end, function() return o.isDestroyed() or not o.loading_custom end, 10)
        end,
      })
      obj.setCustomObject({ image = "https://raw.githubusercontent.com/NutritiousDeath/mtg-tts-table/main/assets/ui/contract.png?v=1",
        thickness = 0.1, merge_distance = 5, stackable = false })
    end)
end

function Effects.returnSelf(obj)
  returnToHand(obj)
end

-- Chaos Warp: pick the permanent, shuffle it into its owner's library, reveal
-- the top card, and put it onto the battlefield if it's a permanent card.
function Effects.chaosWarp(seat, it)
  local function reveal(owner)
    Library.revealTop(owner, function(card)
      if card == nil then
        printToAll("MTG > " .. it.name .. ": " .. owner .. "'s library is empty.", INFO)
        return
      end
      local isPermanent = true
      pcall(function()
        local d = JSON.decode(card.getGMNotes())
        for _, t in ipairs(type(d) == "table" and d.types or {}) do
          local tl = tostring(t):lower()
          if tl == "instant" or tl == "sorcery" then
            isPermanent = false
          end
        end
      end)
      printToAll("MTG > " .. it.name .. ": " .. owner .. " reveals " .. card.getName() .. (isPermanent and ": it enters the battlefield." or ": not a permanent card, it goes back on top."), GOOD)
      if isPermanent then
        card.setLock(false)
        local s = TableSetup.seat(owner)
        card.setRotation({ 0, s.yaw, 0 })
        card.setPosition(TableSetup.slot(owner, "battlefield", 2))
        Wait.time(function()
          if not card.isDestroyed() then Zones.refresh(card) end
        end, 1.2)
      else
        Library.putAt(owner, card, 0)
      end
    end)
  end
  local filter = function(obj, owner)
    return true
  end
  Effects.askChoice(seat, it.name .. ": choose the permanent", "Click CHAOS WARP on a permanent: its owner shuffles it into their library.",
    { { label = "SKIP", value = false } }, function(obj)
      if not obj then
        printToAll("MTG > " .. it.name .. ": no target chosen.", INFO)
        return
      end
      local loc = Zones.regionAt(obj.getPosition())
      local owner = loc.seat or seat
      local isToken = obj.hasTag("Token")
      printToAll("MTG > " .. it.name .. ": " .. obj.getName() .. " is shuffled into " .. owner .. "'s library.", INFO)
      if isToken then
        obj.destruct()
        reveal(owner)
      else
        obj.setLock(false)
        Library.putAt(owner, obj, 0, function(lib)
          if lib and lib.type == "Deck" and lib.shuffle then
            lib.shuffle()
          end
          Wait.time(function() reveal(owner) end, 1.0)
        end)
      end
    end, { filter = filter, label = "CHAOS WARP" })
end

-- "You may sacrifice a land. If you do, ...": a SACRIFICE button on each of
-- your permanents of that type, then the rest resolves.
function Effects.pickSacrifice(seat, a, it)
  local want = tostring(a.type)
  local filter = function(obj, owner)
    if owner ~= seat then
      return false
    end
    if a.other and it.source and obj.getGUID() == it.source then
      return false
    end
    local t = cardTypes(obj)
    return want == "permanent" or t[want] == true
  end
  ask(seat, it.name .. ": sacrifice " .. tostring(a.phrase) .. "?", "Click SACRIFICE on it, or SKIP. If you do: " .. tostring(a.rest),
    { { label = "SKIP", value = false } }, function(obj)
      if not obj then
        printToAll("MTG > " .. seat .. " didn't sacrifice (" .. it.name .. ").", INFO)
        return
      end
      local name = obj.getName()
      Combat.removeCard(obj, "graveyard")
      printToAll("MTG > " .. seat .. " sacrificed " .. name .. " (" .. it.name .. ").", GOOD)
      local copy = {}
      for k, v in pairs(it) do
        copy[k] = v
      end
      copy.text = a.rest
      copy.modePicked = true
      copy.unlessDone = true
      Effects.resolve(copy)
    end, { filter = filter, label = "SACRIFICE" })
end

---------------------------------------------------------------------------
-- "Enters tapped" (not a trigger): tap the permanent as it enters.
---------------------------------------------------------------------------

local ON_FIELD = { battlefield = true, lands = true }

Events.on("cardMoved", function(d)
  if not enabled() or not GameState.data.started or d.card == nil or d.to == nil then
    return
  end
  if not ON_FIELD[d.to.region] or (d.from and ON_FIELD[d.from.region]) then
    return
  end
  local card = d.card
  if card.isDestroyed() or card.is_face_down then
    return
  end
  local seat = d.to.seat
  local function tapIt()
    Wait.time(function()
      if card.isDestroyed() then
        return
      end
      local s = TableSetup.seat(seat)
      local r = card.getRotation()
      card.setRotationSmooth({ r.x, (s.yaw + 90) % 360, r.z }, false, true)
      printToAll("MTG > " .. card.getName() .. " enters tapped.", INFO)
    end, 0.8)
  end
  -- Shock lands: "you may pay 2 life. If you don't, it enters tapped."
  local life = Effects.shockLife(card)
  if life and seat and GameState.player(seat) then
    local name = card.getName()
    ask(seat, "Pay " .. life .. " life for " .. name .. "?", "Pay " .. life .. " life and it enters untapped, or let it enter tapped.",
      { { label = "PAY " .. life .. " LIFE", value = true }, { label = "ENTER TAPPED", value = false } }, function(pay)
        if pay then
          Trackers.changeLife(seat, -life, name)
          printToAll("MTG > " .. seat .. " pays " .. life .. " life: " .. name .. " enters untapped.", GOOD)
        else
          tapIt()
        end
      end)
    return
  end
  local how, clause = Effects.entersTapped(card)
  if how == nil then
    return
  end
  if how == "maybe" then
    broadcastToColor(card.getName() .. " may enter tapped (" .. clause .. "): tap it if it does.", seat, INFO)
    return
  end
  Wait.time(function()
    if card.isDestroyed() then
      return
    end
    local s = TableSetup.seat(seat)
    local r = card.getRotation()
    card.setRotationSmooth({ r.x, (s.yaw + 90) % 360, r.z }, false, true)
    printToAll("MTG > " .. card.getName() .. " enters tapped.", INFO)
  end, 0.8)
end)

-- Shock land: how much life it asks for ("you may pay 2 life. If you don't,
-- it enters tapped"), or nil.
function Effects.shockLife(card)
  local oracle = ""
  pcall(function()
    local data = JSON.decode(card.getGMNotes())
    oracle = type(data) == "table" and type(data.oracle) == "string" and data.oracle or ""
  end)
  local n = oracle:lower():match("you may pay (%d+) life%. if you don't, [^.]* enters tapped")
  return n and tonumber(n) or nil
end

-- Does this card enter tapped? "yes", "maybe" (a condition: "unless you
-- control..."), or nil; plus the clause.
function Effects.entersTapped(card)
  local name, oracle = card.getName(), ""
  pcall(function()
    local data = JSON.decode(card.getGMNotes())
    if type(data) == "table" then
      oracle = type(data.oracle) == "string" and data.oracle or ""
      name = data.name or name
    end
  end)
  local t = oracle:lower()
  local function swap(n)
    if n and #n > 1 then
      t = t:gsub(n:lower():gsub("([%%%-%.%+%*%?%[%]%^%$%(%)])", "%%%1"), "~")
    end
  end
  swap(name)
  for _, w in ipairs({ "creature", "land", "enchantment", "artifact", "permanent" }) do
    t = t:gsub("this " .. w, "~")
  end
  local at = t:find("~ enters tapped", 1, true) or t:find("~ enters the battlefield tapped", 1, true)
  if at == nil then
    return nil
  end
  local stop = t:find(".", at, true) or #t
  local clause = t:sub(at, stop)
  if clause:find("unless", 1, true) or clause:find(" if ", 1, true) then
    return "maybe", clause
  end
  return "yes", clause
end

---------------------------------------------------------------------------
-- Destroy / exile (board wipes and single targets)
---------------------------------------------------------------------------

local function hasKeyword(obj, kw)
  local found = Counters.hasTempKeyword and Counters.hasTempKeyword(obj, kw) or false
  pcall(function()
    local d = JSON.decode(obj.getGMNotes())
    for _, k in ipairs(type(d) == "table" and d.keywords or {}) do
      if tostring(k):lower() == kw then
        found = true
      end
    end
  end)
  return found
end

-- Does a permanent fit "creatures", "nonland permanents"... and the scope?
local function fits(obj, owner, a, seat, sourceGuid)
  if a.scope == "mine" and owner ~= seat then
    return false
  elseif a.scope == "opponents" and owner == seat then
    return false
  end
  if a.other and sourceGuid and obj.getGUID() == sourceGuid then
    return false
  end
  local t = cardTypes(obj)
  for _, want in ipairs(a.types) do
    if want == "permanent" or t[want] then
      return true
    elseif want == "nonland" and not t.land then
      return true
    elseif want == "noncreature" and not t.creature then
      return true
    end
  end
  return false
end

local function removeOne(obj, verb)
  if verb == "destroy" and hasKeyword(obj, "indestructible") then
    printToAll("MTG > " .. obj.getName() .. " is indestructible and stays.", INFO)
    return false
  end
  Combat.removeCard(obj, verb == "exile" and "exile" or "graveyard")
  return true
end

-- Everything that fits goes at once. Returns how many went.
function Effects.removeAll(seat, a, it)
  local gone, names = 0, {}
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and obj.held_by_color == nil then
      local owner = fieldSeat(obj)
      if owner and fits(obj, owner, a, seat, it.source) then
        local name = obj.getName()
        if removeOne(obj, a.verb) then
          gone = gone + 1
          table.insert(names, name)
        end
      end
    end
  end
  if gone > 0 then
    printToAll("MTG > " .. it.name .. ": " .. (a.verb == "exile" and "exiled " or "destroyed ")
      .. table.concat(names, ", ") .. ".", GOOD)
  end
  return gone
end

-- "Destroy target creature": a DESTROY / EXILE button on each candidate.
function Effects.pickRemove(seat, a, sourceName, sourceGuid)
  local label = string.upper(a.verb)
  ask(seat, sourceName .. ": " .. a.verb .. " target " .. tostring(a.phrase),
    "Click " .. label .. " on the target.", { { label = "SKIP", value = false } }, function(obj)
      if obj then
        local name = obj.getName()
        local owner = fieldSeat(obj)
        local power = tonumber(Counters.stats(obj).power or "") or 0
        local mv = 0
        pcall(function()
          local d = JSON.decode(obj.getGMNotes())
          mv = tonumber(type(d) == "table" and d.cmc or 0) or 0
        end)
        if removeOne(obj, a.verb) then
          if a.lifeEqualPower and owner and power > 0 then
            Trackers.changeLife(owner, power, sourceName)
          end
          if a.loseEqualMV and mv > 0 then
            Trackers.changeLife(seat, -mv, sourceName)
          end
          printToAll("MTG > " .. sourceName .. ": " .. (a.verb == "exile" and "exiled " or "destroyed ") .. name .. ".", GOOD)
        end
      else
        printToAll("MTG > " .. sourceName .. ": no target chosen.", INFO)
      end
    end, { filter = function(obj, owner) return fits(obj, owner, a, seat, sourceGuid) end, label = label })
end

---------------------------------------------------------------------------
-- Amass, and "enters with N counters"
---------------------------------------------------------------------------

local function armyOf(seat)
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    local isArmy = cardTypes(obj).army or tostring(obj.getName()):find("Army", 1, true) ~= nil
    if not isArmy then
      pcall(function()
        local d = JSON.decode(obj.getGMNotes())
        isArmy = type(d) == "table" and tostring(d.typeLine or ""):find("Army", 1, true) ~= nil
      end)
    end
    if obj.type == "Card" and not obj.isDestroyed() and fieldSeat(obj) == seat and isArmy then
      return obj
    end
  end
  return nil
end

function Effects.amass(seat, kind, n, sourceName)
  local army = armyOf(seat)
  if army then
    Counters.change(army, "plus", n, seat)
    printToAll("MTG > " .. seat .. " amasses " .. n .. " onto " .. army.getName() .. ".", GOOD)
    return
  end
  -- No Army yet: a 0/0 black <Kind> Army token, then the counters.
  Tokens.create(seat, { pt = "0/0", words = { kind:lower(), "army" }, colors = { B = true } }, 1, sourceName)
  Wait.time(function()
    local made = armyOf(seat)
    if made then
      Counters.change(made, "plus", n, seat)
      printToAll("MTG > " .. seat .. " amasses " .. n .. " onto the new " .. made.getName() .. ".", GOOD)
    else
      broadcastToColor(sourceName .. ": put " .. n .. " +1/+1 counter(s) on your Army yourself.", seat, INFO)
    end
  end, 3)
end

-- "Spike Feeder enters with two +1/+1 counters on it."
Events.on("cardMoved", function(d)
  if not enabled() or not GameState.data.started or d.card == nil or d.to == nil then
    return
  end
  if not ON_FIELD[d.to.region] or (d.from and ON_FIELD[d.from.region]) then
    return
  end
  local card = d.card
  if card.isDestroyed() or card.is_face_down then
    return
  end
  local oracle, name = "", card.getName()
  pcall(function()
    local data = JSON.decode(card.getGMNotes())
    if type(data) == "table" then
      oracle = type(data.oracle) == "string" and data.oracle or ""
      name = data.name or name
    end
  end)
  local t = oracle:lower()
  if Triggers and Triggers.stripReminder then
    t = Triggers.stripReminder(t)
  end
  local w, kind = t:match("enters with (%w+) ([%w%+/%-]+) counters? on it")
  local n = num(w)
  if n == nil then
    return
  end
  -- Conditional ones ("if ...", "for each", "x") are left to the player.
  local at = t:find("enters with", 1, true)
  local clause = t:sub(math.max(1, at - 30), at + 40)
  if clause:find(" if ", 1, true) or clause:find("for each", 1, true) then
    return
  end
  local key = (kind == "+1/+1" and "plus") or (kind == "-1/-1" and "minus") or (kind == "loyalty" and "loyalty") or "other"
  Wait.time(function()
    if not card.isDestroyed() then
      Counters.change(card, key, n, d.to.seat)
      printToAll("MTG > " .. card.getName() .. " enters with " .. n .. " " .. kind .. " counter"
        .. (n == 1 and "" or "s") .. ".", INFO)
    end
  end, 0.6)
end)

---------------------------------------------------------------------------
-- Until end of turn: +N/+N and keywords (cleared at cleanup, counters.lua)
---------------------------------------------------------------------------

local function boost(obj, a)
  if a.p ~= 0 then
    Counters.change(obj, "tp", a.p)
  end
  if a.q ~= 0 then
    Counters.change(obj, "tt", a.q)
  end
  for _, kw in ipairs(a.kws or {}) do
    Counters.addTempKeyword(obj, kw)
  end
end

-- Returns how many creatures got it ("target" ones are picked on the table).
function Effects.pump(seat, a, it)
  if a.scope == "self" then
    local src = it.source and getObjectFromGUID(it.source)
    if src and not src.isDestroyed() then
      boost(src, a)
      return 1
    end
    broadcastToColor(it.name .. ": give it " .. tostring(a.label) .. " yourself.", seat, INFO)
    return 0
  end
  if a.scope == "that" then
    local card = it.thatCard and getObjectFromGUID(it.thatCard)
    if card and not card.isDestroyed() and fieldSeat(card) then
      boost(card, a)
      printToAll("MTG > " .. card.getName() .. " gets " .. tostring(a.label) .. " until end of turn.", GOOD)
      return 1
    end
    broadcastToColor(it.name .. ": give it " .. tostring(a.label) .. " yourself (couldn't tell which creature).", seat, INFO)
    return 0
  end
  local function eligible(obj, owner)
    if not cardTypes(obj).creature then
      return false
    end
    if (a.scope == "allMine" or a.scope == "targetMine") and owner ~= seat then
      return false
    elseif (a.scope == "allOpp" or a.scope == "targetOpp") and owner == seat then
      return false
    end
    if a.other and it.source and obj.getGUID() == it.source then
      return false
    end
    return true
  end
  if a.scope == "target" or a.scope == "targetMine" or a.scope == "targetOpp" then
    ask(seat, it.name .. ": " .. tostring(a.label) .. " until end of turn", "Click TARGET on the creature.",
      { { label = "SKIP", value = false } }, function(obj)
        if obj then
          boost(obj, a)
          printToAll("MTG > " .. obj.getName() .. " gets " .. tostring(a.label) .. " until end of turn.", GOOD)
        end
      end, { filter = eligible, label = "TARGET" })
    return 0
  end
  local n = 0
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) then
      local owner = fieldSeat(obj)
      if owner and eligible(obj, owner) then
        boost(obj, a)
        n = n + 1
      end
    end
  end
  return n
end

---------------------------------------------------------------------------
-- Conditions the table can check, and the bigger card effects
---------------------------------------------------------------------------

local function creatureCount(seat)
  local n = 0
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and fieldSeat(obj) == seat
        and cardTypes(obj).creature then
      n = n + 1
    end
  end
  return n
end

-- true / false for the conditions it knows, nil for the rest (asked as YES / NO).
function Effects.condValue(cond, seat, name)
  if cond == "a player controls no creatures" then
    for _, c in ipairs(players()) do
      if creatureCount(c) == 0 then
        return true
      end
    end
    return false
  elseif cond == "you control no creatures" then
    return creatureCount(seat) == 0
  elseif cond == "~ is tapped" and name then
    -- Mana Vault: is the permanent itself tapped? (the table can see it)
    for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
      if obj.type == "Card" and not obj.isDestroyed() and obj.getName() == name and fieldSeat(obj) == seat then
        local diff = ((obj.getRotation().y - TableSetup.seat(seat).yaw + 540) % 360) - 180
        return math.abs(diff) > 30
      end
    end
  end
  return nil
end

-- Players in turn order starting with `first`.
local function orderFrom(first)
  local all = players()
  local list, at = {}, 1
  for i, c in ipairs(all) do
    if c == first then
      at = i
    end
  end
  for k = 0, #all - 1 do
    table.insert(list, all[(at - 1 + k) % #all + 1])
  end
  return list
end

-- Etali: exile from the top of the libraries, then offer each nonland card
-- as a free cast (onto the stack).
function Effects.exileCast(seat, a, it)
  local who = a.everyone and orderFrom(seat) or { seat }
  local pending, cards = #who, {}
  local function offer()
    if #cards == 0 then
      printToAll("MTG > " .. it.name .. ": no nonland cards were exiled.", INFO)
      return
    end
    for _, card in ipairs(cards) do
      local name = card.getName()
      local oracle = ""
      pcall(function()
        local d = JSON.decode(card.getGMNotes())
        oracle = type(d) == "table" and tostring(d.oracle or "") or ""
      end)
      ask(seat, it.name .. ": cast " .. name .. " free?", (#oracle > 150 and (oracle:sub(1, 148) .. "...") or oracle),
        { { label = "CAST", value = true }, { label = "NO", value = false } }, function(yes)
          if yes and not card.isDestroyed() then
            printToAll("MTG > " .. seat .. " casts " .. name .. " without paying its mana cost (" .. it.name .. ").", GOOD)
            Stack.pushCard(card, seat)
          else
            printToAll("MTG > " .. seat .. " doesn't cast " .. name .. " (stays exiled).", INFO)
          end
        end)
    end
  end
  for _, s in ipairs(who) do
    Library.exileUntilNonland(s, not a.untilNonland, function(card, exiled)
      printToAll("MTG > " .. s .. " exiled " .. #exiled .. " card" .. (#exiled == 1 and "" or "s") .. " from their library ("
        .. it.name .. ").", INFO)
      if card then
        table.insert(cards, card)
      end
      pending = pending - 1
      if pending == 0 then
        offer()
      end
    end)
  end
end

-- Collective Voyage: starting with the controller, each player says how much
-- mana they pay; then each searches for up to that many basic lands.
function Effects.joinForces(it)
  local order = orderFrom(it.controller)
  local total = 0
  local query = tostring(it.text or ""):lower():match("up to x ([%a ]-) cards") or "basic land"
  local function finish()
    printToAll("MTG > " .. it.name .. ": " .. total .. " mana paid in all.", INFO)
    if total <= 0 then
      return
    end
    for _, s in ipairs(order) do
      if seated(s) or GameState.solo() then
        LibSearch.open(s, query, it.name .. ": take up to " .. total .. " (" .. query .. ", they enter tapped). It closes and shuffles by itself.",
          "battlefield", true, { typeOnly = true, limit = total })
      end
    end
  end
  local function nextPlayer(i)
    if i > #order then
      finish()
      return
    end
    local s = order[i]
    ask(s, it.name .. ": join forces",
      "How much mana do you pay? Type a number and OK, or NONE." .. (total > 0 and ("\nPaid so far: " .. total) or ""),
      { { label = "NONE", value = false } }, function(n)
        n = tonumber(n) or 0
        total = total + n
        if n > 0 then
          printToAll("MTG > " .. s .. " pays " .. n .. " (" .. it.name .. ").", INFO)
        end
        nextPlayer(i + 1)
      end, nil, true)
  end
  nextPlayer(1)
end

-- Maze of Ith: untap an attacking creature; its combat damage is prevented.
function Effects.untapAttacker(seat, a, it)
  ask(seat, it.name .. ": untap an attacking creature", "Click TARGET on the attacking creature.",
    { { label = "SKIP", value = false } }, function(obj)
      if not obj then
        return
      end
      local owner = fieldSeat(obj)
      if owner then
        local r = obj.getRotation()
        obj.setRotationSmooth({ r.x, TableSetup.seat(owner).yaw, r.z }, false, true)
      end
      if a.prevent then
        Combat.preventDamage(obj)
      end
      printToAll("MTG > " .. it.name .. ": " .. obj.getName() .. " untaps" .. (a.prevent and "; no combat damage is dealt to or by it." or "."), GOOD)
    end, { filter = function(obj) return Combat.isAttacking(obj) end, label = "TARGET" })
end

-- Sothera: each opponent exiles a creature they control. The table
-- remembers which cards went, for "put a creature card exiled with it".
local function isCommanderGuid(guid)
  for _, c in ipairs(TableSetup.activeSeats()) do
    local p = GameState.player(c)
    for _, g in pairs(p and p.commanders or {}) do
      if g == guid then
        return true
      end
    end
  end
  return false
end

function Effects.oppExile(seat, a, it)
  for _, opp in ipairs(orderFrom(seat)) do
    if opp ~= seat and creatureCount(opp) > 0 then
      ask(opp, it.name .. ": exile a " .. tostring(a.type), "Click EXILE on a " .. tostring(a.type) .. " you control.",
        { { label = "NONE", value = false } }, function(obj)
          if not obj then
            return
          end
          local name, guid = obj.getName(), obj.getGUID()
          local token = obj.hasTag("Token")
          if removeOne(obj, "exile") then
            printToAll("MTG > " .. opp .. " exiles " .. name .. " (" .. it.name .. ").", GOOD)
            if not token and it.source and not isCommanderGuid(guid) then
              GameState.data.exiledWith = GameState.data.exiledWith or {}
              local list = GameState.data.exiledWith[it.source] or {}
              table.insert(list, guid)
              GameState.data.exiledWith[it.source] = list
            end
          end
        end, { filter = function(obj, owner) return owner == opp and cardTypes(obj).creature == true end, label = "EXILE" })
    end
  end
end

-- "Put a creature card exiled with it onto the battlefield under your
-- control with two additional +1/+1 counters on it."
function Effects.returnExiledWith(seat, a, it)
  local list = (GameState.data.exiledWith or {})[it.source or ""] or {}
  local cards = {}
  for _, g in ipairs(list) do
    local o = getObjectFromGUID(g)
    if o and not o.isDestroyed() and cardTypes(o)[tostring(a.type)] then
      table.insert(cards, o)
    end
  end
  local function put(card)
    local s = TableSetup.seat(seat)
    card.setLock(false)
    card.setRotation({ 0, s.yaw, 0 })
    card.setPosition(TableSetup.slot(seat, "battlefield", 2))
    printToAll("MTG > " .. seat .. " puts " .. card.getName() .. " onto the battlefield from exile (" .. it.name .. ").", GOOD)
    local ex = GameState.data.exiledWith or {}
    local rest = {}
    for _, g in ipairs(ex[it.source or ""] or {}) do
      if g ~= card.getGUID() then
        table.insert(rest, g)
      end
    end
    ex[it.source or ""] = rest
    Wait.time(function()
      if not card.isDestroyed() then
        Zones.refresh(card)
      end
    end, 1)
    Wait.time(function()
      if card.isDestroyed() then
        return
      end
      if (a.counters or 0) > 0 then
        Counters.change(card, "plus", a.counters, seat)
      end
      if a.haste then
        Counters.addTempKeyword(card, "haste")
      end
    end, 1.8)
  end
  if #cards == 0 then
    broadcastToColor(it.name .. ": no " .. tostring(a.type) .. " card is exiled with it (the table only knows the ones it exiled itself).", seat, INFO)
    return
  end
  if #cards == 1 then
    put(cards[1])
    return
  end
  local lines, choices = {}, {}
  for i, c in ipairs(cards) do
    if i <= MAX_CHOICES then
      table.insert(lines, i .. ") " .. c.getName())
      table.insert(choices, { label = tostring(i), value = i })
    end
  end
  ask(seat, it.name .. ": choose a card to put onto the battlefield", table.concat(lines, "\n"), choices, function(i)
    put(cards[i])
  end)
end


-- Reveal from the top until a card of the type; it goes to the battlefield
-- (tapped and attacking: it joins the attack) or your hand; the rest go on
-- the bottom in a random order.
function Effects.revealUntil(seat, a, it)
  Library.revealUntil(seat, a.type, function(found, others)
    if found == nil then
      printToAll("MTG > " .. seat .. " revealed " .. #others .. " cards and found no " .. tostring(a.type) .. " (" .. it.name .. ").", INFO)
    else
      printToAll("MTG > " .. seat .. " reveals " .. #others + 1 .. " cards and finds " .. found.getName() .. " (" .. it.name .. ").", GOOD)
      found.setLock(false)
      local s = TableSetup.seat(seat)
      if a.where == "hand" then
        found.setPosition(Player[seat].getHandTransform().position)
        Wait.time(function()
          if not found.isDestroyed() then Zones.refresh(found) end
        end, 1)
      else
        found.setRotation({ 0, a.tapped and (s.yaw + 90) % 360 or s.yaw, 0 })
        found.setPosition(TableSetup.slot(seat, "battlefield", 2))
        Wait.time(function()
          if found.isDestroyed() then
            return
          end
          Zones.refresh(found)
          if a.attacking then
            Wait.time(function()
              Combat.enterAttacking(found, seat, it.thatCard or it.source)
            end, 0.6)
          end
        end, 1.2)
      end
    end
    if a.allToHand then
      -- Treasure Hunt: every revealed card goes to hand, nothing to the bottom.
      local pos = Player[seat].getHandTransform().position
      for _, c in ipairs(others) do
        if c ~= nil and not c.isDestroyed() then
          c.setLock(false)
          c.setPosition(pos)
          Wait.time(function()
            if not c.isDestroyed() then Zones.refresh(c) end
          end, 1)
        end
      end
      printToAll("MTG > " .. it.name .. ": all " .. (#others + (found and 1 or 0)) .. " revealed cards go to " .. seat .. "'s hand.", INFO)
      return
    end
    Library.putBottomRandom(seat, others)
  end)
end
