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
    if line:find(".", 1, true) or line:find(":", 1, true) then
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
        table.insert(conds, c)
      elseif clean ~= "" then
        table.insert(notes, clean)
      end
    else
      table.insert(kept, sentence)
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
  -- Nekusar: "that player draws an additional card".
  w = t:match("that player draws (%w+) additional cards?")
  add("draw", "that", num(w))
  w = t:match("you gain (%w+) life") or t:match("you may gain (%w+) life")
  add("gain", "you", num(w))
  w = t:match("you lose (%w+) life")
  add("lose", "you", num(w))
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
    local mvMin = tonumber(rest:match("mana value (%d+) or greater") or "")
    local mvMax = tonumber(rest:match("mana value (%d+) or less") or "")
    table.insert(actions, { what = "search", who = "you", n = 1, query = q, where = where, mvMin = mvMin, mvMax = mvMax,
      tapped = rest:find("battlefield tapped", 1, true) ~= nil, phrase = phrase })
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
          table.insert(actions, { what = "token", who = "you", n = n, spec = spec, phrase = phrase })
        end
      end
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
    if btype then
      table.insert(actions, { what = "bounce", who = "you", n = 1, type = btype, mine = false })
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
  elseif a.what == "bounce" then
    return who .. " returns a " .. tostring(a.type) .. " to hand"
  elseif a.what == "untap" or a.what == "tap" then
    return tostring(a.cardName or "it") .. (a.what == "untap" and " untapped" or " tapped")
  elseif a.what == "token" then
    return who .. (you and " create " or " creates ") .. tostring(a.phrase) .. " token"
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
  end
  if a.what == "gain" then
    return who .. (you and " gain " or " gains ") .. a.n .. " life"
  elseif a.what == "lose" then
    return who .. (you and " lose " or " loses ") .. a.n .. " life"
  end
  return who .. (you and " draw " or " draws ") .. a.n
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
    else
      seats = { target }
    end
    for _, seat in ipairs(seats) do
      if seat and GameState.player(seat) then
        if a.what == "gain" then
          Trackers.changeLife(seat, a.n, it.name)
        elseif a.what == "lose" then
          Trackers.changeLife(seat, -a.n, it.name)
        elseif a.what == "draw" then
          Actions.draw(seat, a.n, it.name)
        elseif a.what == "search" then
          local how
          if a.where == "both" then
            how = "click a card for the battlefield" .. (a.tapped and " (tapped)" or "")
              .. ", then switch TO: HAND for the other one"
          elseif a.where == "battlefield" then
            how = "click a card to put it onto the battlefield" .. (a.tapped and " tapped" or "")
          else
            how = "click a card to put it into your hand"
          end
          LibSearch.open(seat, a.query, it.name .. " (" .. tostring(a.phrase) .. "): " .. how .. ", then CLOSE + SHUFFLE.",
            a.where == "hand" and "hand" or "battlefield", a.tapped,
            { typeOnly = true, mvMin = a.mvMin, mvMax = a.mvMax })
        elseif a.what == "counter" then
          local src = it.source and getObjectFromGUID(it.source)
          if src and not src.isDestroyed() then
            Counters.change(src, a.kind, a.n, seat)
          else
            broadcastToColor(it.name .. " isn't on the table any more: no counter added.", seat, INFO)
          end
        elseif a.what == "bounce" then
          Effects.pickBounce(seat, a, it.name)
        elseif a.what == "token" then
          Tokens.create(seat, a.spec, a.n, it.name)
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

local function ask(seat, title, text, choices, onPick, pick)
  table.insert(queue, { seat = seat, title = title, text = text, choices = choices, onPick = onPick, pick = pick })
  if current == nil then
    nextQuestion()
  end
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
<Panel id="effAsk_%s" visibility="%s" active="false" rectAlignment="MiddleCenter" offsetXY="0 -60" width="560" height="190"
       color="#0B0F17F5" outline="#5AF0FF" outlineSize="2 2" allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="14 14 12 12" spacing="8" childForceExpandHeight="false">
    <Text id="effTitle_%s" fontSize="17" fontStyle="Bold" color="#5AF0FF" alignment="MiddleLeft" preferredHeight="24">-</Text>
    <Text id="effText_%s" fontSize="13" color="#E6F1FF" alignment="UpperLeft" preferredHeight="60">-</Text>
    <HorizontalLayout spacing="8" preferredHeight="40" childForceExpandWidth="false" childAlignment="MiddleLeft">
      ]] .. table.concat(choices, "\n      ") .. [[

    </HorizontalLayout>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, c))
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
      for i, m in ipairs(modes) do
        if i <= MAX_CHOICES then
          table.insert(lines, i .. ") " .. (#m > 70 and (m:sub(1, 68) .. "...") or m))
          table.insert(choices, { label = tostring(i), value = i })
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
  local plan, why = Effects.parse(it.text, it.name)
  if plan == nil then
    printToAll("MTG > " .. it.name .. ": resolve it by hand (" .. tostring(why) .. ").", INFO)
    return
  end
  local seat = it.controller
  -- "If ..., ..." parts: the controller says whether it's true, then the
  -- rest resolves like any other effect.
  local function askConds()
    for _, c in ipairs(plan.conds or {}) do
      local ordWord = c.cond:match("^this is the (%a+) time this ability has resolved this turn")
      local nth = ordWord and ORDINAL[ordWord]
      if nth then
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
        ask(seat, title, text, { { label = "YES", value = true }, { label = "NO", value = false } }, function(yes)
          if yes then
            local copy = {}
            for k, v in pairs(it) do
              copy[k] = v
            end
            copy.text = c.rest
            copy.modePicked = true
            copy.unlessDone = true
            Effects.resolve(copy)
          else
            printToAll("MTG > " .. it.name .. ": not true, so that part does nothing.", INFO)
          end
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
    if a.who == "target" or a.who == "targetOpponent" or (a.who == "that" and it.that == nil) then
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
    table.insert(choices, { label = "SKIP", value = false })
    while #choices > MAX_CHOICES do
      table.remove(choices, MAX_CHOICES)
    end
    ask(seat, it.name .. ": choose a player", tostring(it.text), choices, function(target)
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
  local text = ""
  pcall(function()
    local d = JSON.decode(obj.getGMNotes())
    if type(d) == "table" and type(d.oracle) == "string" then
      text = d.oracle
    end
  end)
  if text == "" then
    return
  end
  Effects.resolve({ name = obj.getName(), controller = controller, text = text, auto = true })
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

local function fieldSeat(obj)
  local loc = Zones.regionAt(obj.getPosition())
  if loc.region == "battlefield" or loc.region == "lands" then
    return loc.seat
  end
  return nil
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

function Effects.pickBounce(seat, a, sourceName)
  local want = tostring(a.type)
  local filter = function(obj, owner)
    if a.mine and owner ~= seat then
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
  local how, clause = Effects.entersTapped(card)
  if how == nil then
    return
  end
  local seat = d.to.seat
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
