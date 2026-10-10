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
  -- An ability word ("Disappear — ", "Void — ", "Landfall — ") is a label, not rules.
  do
    local a, b = t:find(" — ", 1, true)
    if a and a <= 24 and not t:sub(1, a):find("[%.:,]") then
      local rest = t:sub(b + 1)
      local f2 = rest:sub(1, 8)
      if f2:find("^whenever") or f2:find("^when ") or f2:find("^at ") then
        t = rest
      end
    end
  end
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
  for _, w in ipairs({ "creature", "land", "enchantment", "artifact", "permanent", "planeswalker", "case", "class", "saga", "aura", "equipment" }) do
    t = t:gsub("this " .. w, "~")
  end
  -- Several paragraphs (a spell: "This spell can't be countered." then
  -- "Destroy all creatures."): read them as sentences.
  t = t:gsub("\n", " ")
  -- "Until end of turn, ~ gets +2/+2 and gains lifelink." reads the same as the trailing form.
  if t:sub(1, 20) == " until end of turn, " then
    local rest = t:sub(21)
    local dot = rest:find(".", 1, true)
    if dot then
      t = " " .. rest:sub(1, dot - 1) .. " until end of turn" .. rest:sub(dot)
    else
      t = " " .. rest:gsub("%s+$", "") .. " until end of turn "
    end
  end
  -- A token "with '<its own ability>'" (Urza's Construct: "+1/+1 for each artifact"): the token's
  -- own text isn't part of this effect.
  t = t:gsub('(tokens?) with "[^"]*"', "%1"):gsub("(tokens?) with '[^']*'", "%1")
  -- A named token ("create Marit Lage, a legendary 20/20 black Avatar creature
  -- token"): the name is just a label for the token that follows.
  do
    local a, b, nm, art = t:find("create ([%a' ]+), (an?) ")
    if a and nm and not nm:find("token", 1, true) then
      local first = nm:match("^(%a+)")
      if first and not NUMBERS[first] and first ~= "x" then
        t = t:sub(1, a - 1) .. "create " .. art .. " " .. t:sub(b + 1)
      end
    end
  end
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
  -- Sephiroth: "If this is the fourth time this ability has resolved this turn, transform ~."
  local nthTransform
  do
    local p1, p2, ord = t:find("if this is the (%a+) time this ability has resolved this turn, transform ~%.?")
    if p1 then
      local ORD = { second = 2, third = 3, fourth = 4, fifth = 5 }
      if ORD[ord] then
        nthTransform = ORD[ord]
        t = t:sub(1, p1 - 1) .. t:sub(p2 + 1)
      end
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
    do
      local e1, e2, w3 = t:find(", where x is the number of (%a+) on the battlefield", 1)
      if e1 and t:find("create x ", 1, true) then
        counted = { kind = "token", word = w3, scope = "all" }
        t = t:sub(1, e1 - 1) .. t:sub(e2 + 1)
        t = t:gsub("create x ", "create 1 ", 1)
      end
    end
    -- "..., where X is the number of +1/+1 counters on ~" (Sekki) / "create a ... token for each +1/+1 counter on ~" (Mycoloth).
    do
      local e1, e2 = t:find(", where x is the number of +1/+1 counters on ~", 1, true)
      if e1 and t:find("create x ", 1, true) then
        counted = { kind = "token", word = "+1/+1 counters", scope = "mine", counters = true }
        t = t:sub(1, e1 - 1) .. t:sub(e2 + 1)
        t = t:gsub("create x ", "create 1 ", 1)
      end
      local f1, f2 = t:find(" for each +1/+1 counter on ~", 1, true)
      if f1 and t:find("create ", 1, true) then
        counted = { kind = "token", word = "+1/+1 counters", scope = "mine", counters = true }
        t = t:sub(1, f1 - 1) .. t:sub(f2 + 1)
      end
      -- Avenger of Zendikar, Garruk: "create a 0/1 Plant creature token for each land you control".
      local g1, g2, gw = t:find(" for each (%a+) you control", 1)
      local cr = t:find("create ", 1, true)
      if g1 and cr and cr < g1 and t:sub(cr, g1):find("token", 1, true) and not counted then
        counted = { kind = "token", word = gw, scope = "mine" }
        t = t:sub(1, g1 - 1) .. t:sub(g2 + 1)
      end
    end
    local c, d, w2, who = t:find(", where x is the number of (%a+) (%a+ ?%a*) control", 1)
    if c and t:find("create x ", 1, true) then
      counted = { kind = "token", word = w2, scope = who:find("opponent", 1, true) and "opponents" or "mine" }
      t = t:sub(1, c - 1) .. t:sub(d + 1)
      t = t:gsub("create x ", "create 1 ", 1)
    end
  end
  -- Consuming Corruption: "deals X damage to target creature or planeswalker and you gain X life, where X is
  -- the number of Swamps you control." The table counts X and gains the life; the damage is by hand.
  do
    local w = t:match("deals x damage to target creature or planeswalker and you gain x life, where x is the number of (%a+) you control")
    if w then
      return { optional = false, conds = {},
        notes = { "deal X damage to the target creature or planeswalker by hand (X = your " .. w .. ", counted in chat)" },
        actions = { { what = "gain", who = "you", n = 1, countWord = w, countScope = "mine" } } }
    end
  end
  -- Sephiroth: "you may sacrifice another creature. If you do, draw a card." / "you may sacrifice any
  -- number of other creatures. If you do, draw that many cards."
  do
    if t:find("you may sacrifice another creature. if you do, draw a card", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "sacDraw", who = "you", n = 1, max = 1 } } }
    end
    if t:find("you may sacrifice any number of other creatures. if you do, draw that many cards", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "sacDraw", who = "you", n = 1, max = 99 } } }
    end
  end
  -- Token deck helpers (Xavier Sal deck).
  do
    -- "Activate only as a sorcery." is a timing note, not an effect.
    local sa, sb = t:find(" activate only as a sorcery%.?")
    if sa then
      t = t:sub(1, sa - 1) .. t:sub(sb + 1)
    end
    local tt = t:gsub("^%s+", ""):gsub("%s+$", "")
    -- Myr Propagator: "Create a token that's a copy of this creature."
    if tt == "create a token that's a copy of ~." or tt == "create a token that's a copy of ~" then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "copySelf", who = "you", n = 1 } } }
    end
    -- Garruk, Primal Hunter -3.
    if tt:find("^draw cards equal to the greatest power among creatures you control") then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "drawGreatest", who = "you", n = 1 } } }
    end
    -- Xavier Sal: Populate. / Proliferate.
    if tt == "populate." or tt == "populate" then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "populate", who = "you", n = 1 } } }
    end
    if tt == "proliferate." or tt == "proliferate" then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "proliferate", who = "you", n = 1 } } }
    end
    -- Victimize: sacrifice a creature, then two creature cards from your graveyard come back tapped.
    if t:find("choose two target creature cards in your graveyard", 1, true) and t:find("sacrifice a creature", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "victimize", who = "you", n = 1 } } }
    end
    -- Springheart Nantuko landfall.
    if t:find("is attached to a creature you control", 1, true)
        and t:find("create a token that's a copy of that creature", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "nantuko", who = "you", n = 1 } } }
    end
  end
  do
    -- Tireless Tracker and friends: "investigate" = create a Clue.
    if t:find("investigate", 1, true) and not t:find("create a clue", 1, true) then
      t = t:gsub("investigate", "create a clue token", 1)
    end
    -- Lotus Cobra: "Add one mana of any color."
    if t:find("^%s*add one mana of any color%.?%s*$") then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "addManaAny", who = "you", n = 1 } } }
    end
    -- Kalonian Hydra: double the +1/+1 counters on each creature you control.
    if t:find("double the number of +1/+1 counters on each creature you control", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "counterAll", who = "you", n = 1, mode = "double" } } }
    end
    -- Avenger of Zendikar: a +1/+1 counter on each Plant (creature) you control.
    do
      local i, j = t:find("put a +1/+1 counter on each ", 1, true)
      if i then
        local rest = t:sub(j + 1)
        local w = rest:match("^([%a%-]+) creature you control")
        local other = false
        if w == "other" then
          other, w = true, nil
        end
        if w or rest:find("^creature you control") or rest:find("^other creature you control") then
          if rest:find("^other ") then
            other = true
          end
          return { optional = t:find("you may put", 1, true) ~= nil, notes = {}, conds = {},
            actions = { { what = "counterAll", who = "you", n = 1, mode = "add", word = w, other = other } } }
        end
      end
    end
    -- Scute Swarm: an Insect token, or a copy of itself with six or more lands.
    if t:find("if you control six or more lands, create a token that's a copy of ~ instead", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "scute", who = "you", n = 1 } } }
    end
    -- Sly Requisitioner: each player creates a Treasure token.
    do
      local w = t:match("^%s*each player creates an? (%a+) token%.?%s*$")
      if w then
        return { optional = false, notes = {}, conds = {}, actions = { { what = "eachPlayerToken", who = "you", n = 1, word = w } } }
      end
    end
    -- Second Harvest: a token copy of each token you control.
    if t:find("create a token that's a copy of each token you control", 1, true)
        or t:find("for each token you control, create a token that's a copy of that permanent", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "copyEachToken", who = "you", n = 1 } } }
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
  do
    local ww = t:match("you may discard your hand%. if you do, draw (%w+) cards")
    if ww and num(ww) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "wheel", who = "you", n = num(ww) } } }
    end
  end
  if t:find("you gain protection from everything until your next turn", 1, true) then
    return { optional = false, notes = {}, conds = {},
      actions = { { what = "playerPro", who = "you", n = 1 } } }
  end
  -- Niko, Light of Hope: exile a nonlegendary creature; the Shards become copies of it until the next end step, then it returns.
  if t:find("shards you control become copies of it until the next end step", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "nikoSwap", who = "you", n = 1 } } }
  end
  -- Kiki-Jiki / Twinflame: a token copy of a creature you control (haste, then sacrificed / exiled at end step).
  do
    local one = t:find("create a token that's a copy of target ", 1, true)
    local many = t:find("for each of them, create a token that's a copy of it", 1, true)
    if one or many then
      return { optional = false, notes = {}, conds = {},
        actions = { { what = "copyCreature", who = "you", n = 1, many = many ~= nil,
          nonlegendary = t:find("nonlegendary", 1, true) ~= nil,
          haste = t:find("except it has haste", 1, true) ~= nil or t:find("except it has haste", 1, true) ~= nil,
          endHow = (t:find("sacrifice it at the beginning of the next end step", 1, true) and "sacrifice")
            or (t:find("exile those tokens at the beginning of the next end step", 1, true) and "exile")
            or (t:find("exile it at the beginning of the next end step", 1, true) and "exile") or nil } } }
    end
  end
  -- Wheel of Fortune: everyone discards their hand, then draws seven.
  do
    local w = t:match("each player discards their hand, then draws (%a+) cards")
    local wn = w and NUMBERS[w]
    if wn then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "windfall", who = "all", n = 1, fixed = wn } } }
    end
  end
  -- Windfall: everyone discards their hand, then draws as many as the most anyone discarded.
  if t:find("each player discards their hand, then draws cards equal to the greatest number of cards a player discarded this way", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "windfall", who = "all", n = 1 } } }
  end
  -- Warstorm Surge: the creature that entered deals damage equal to its power to any target.
  if t:find("it deals damage equal to its power to any target", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "powerHit", who = "you", n = 1 } } }
  end
  -- Metalworker / Nykthos: the player says how many ("for each card revealed", devotion), the table adds the mana.
  do
    local per = t:match("add (.-) for each card revealed")
    if per then
      local color, k = per:match("^{(%a)}"), 0
      for _ in per:gmatch("{%a}") do
        k = k + 1
      end
      return { optional = false, notes = {}, conds = {},
        actions = { { what = "manaAsk", who = "you", n = 1, color = color:upper(), per = k, label = "cards revealed" } } }
    end
    if t:find("add an amount of mana of that color equal to your devotion to that color", 1, true) then
      return { optional = false, notes = {}, conds = {},
        actions = { { what = "manaAsk", who = "you", n = 1, pickColor = true, per = 1, label = "devotion to that color" } } }
    end
  end
  -- Sylvan Library: draw two extra, then pay 4 life or put each of two cards back on top.
  if t:find("you may draw two additional cards. if you do, choose two cards in your hand drawn this turn", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "sylvan", who = "you", n = 1 } } }
  end
  -- Jeska's Will: red mana per card in an opponent's hand, and/or exile the top three and play them this turn.
  if t:find("add {r} for each card in target opponent's hand", 1, true) and t:find("exile the top three cards of your library", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "jeska", who = "you", n = 1,
      both = t:find("control a commander", 1, true) ~= nil } } }
  end
  -- Birthing Pod / Eldritch Evolution: tutor a creature worth N more than the sacrificed one (the sacrifice is the cost).
  do
    local plus = t:match("mana value equal to (%d+) plus the sacrificed creature's mana value")
    local plus2 = t:match("where x is (%d+) plus the sacrificed creature's mana value")
    if (plus or plus2) and t:find("search your library for a creature card", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "sacTutor", who = "you", n = 1,
        plus = tonumber(plus or plus2), exact = plus ~= nil, exileSelf = t:find("exile ~", 1, true) ~= nil } } }
    end
  end
  -- Arcum Dagsson: sacrifice a target artifact creature; its controller tutors an artifact worth 1 more.
  if t:find("controller sacrifices it", 1, true) and t:find("1 plus the sacrificed creature's mana value", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "arcum", who = "you", n = 1 } } }
  end
  -- Mirrorworks / Mechanized Production / Helm of the Host: a token copy of "that artifact" / "enchanted artifact" / "equipped creature".
  do
    local which = t:match("create a token that's a copy of (that %a+)") or t:match("create a token that's a copy of (enchanted %a+)")
      or t:match("create a token that's a copy of (equipped %a+)")
    if which and not t:find("is attached to a creature you control", 1, true) then
      return { optional = false, notes = {}, conds = {},
        actions = { { what = "copyThat", who = "you", n = 1, which = which,
          pay = t:match("you may pay ({[{}%w/]+})"),
          haste = t:find("has haste", 1, true) ~= nil,
          unlegend = t:find("isn't legendary", 1, true) ~= nil } } }
    end
  end
  -- Tap / untap: "Untap target artifact." / "Untap all nonland permanents you control." / "Tap all creatures your opponents control." / "untap ~".
  do
    local tt = t:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^\226\128\162%s*", "")
    local seg = tt:match("^(untap .-)%.?$") or tt:match("^(tap .-)%.?$")
    if seg and not seg:find("%.") and not seg:find(" then ", 1, true) and not seg:find(" and ", 1, true) then
      local verb, rest = seg:match("^(%a+) (.+)$")
      local a = { what = "tapX", who = "you", n = 1, mode = verb, kinds = {}, scope = "any", count = 1 }
      local ok = true
      if rest == "~" then
        a.self = true
      elseif rest:find("^all ") then
        a.all = true
        rest = rest:sub(5)
      elseif rest:find("target ", 1, true) then
        if rest:find("^up to two ") then
          a.count, a.upTo = 2, true
        elseif rest:find("^up to one ") then
          a.count, a.upTo = 1, true
        elseif rest:find("^two ") then
          a.count = 2
        end
        a.other = rest:find("another ", 1, true) ~= nil
        rest = rest:gsub("^up to %a+ ", ""):gsub("^%a+ target ", "target "):gsub("^another ", ""):gsub("^target ", ""):gsub("^another ", "")
      else
        ok = false
      end
      if ok then
        if not a.self then
          if rest:find("you control", 1, true) and not rest:find("opponent", 1, true) then
            a.scope = "mine"
          elseif rest:find("opponent", 1, true) or rest:find("you don't control", 1, true) then
            a.scope = "opponents"
          end
          if rest:find("nonland", 1, true) then
            a.kinds.nonland = true
          end
          local r2 = rest:gsub("nonland", "")
          for _, w in ipairs({ "artifact", "creature", "land", "enchantment", "permanent", "planeswalker" }) do
            if r2:find(w, 1, true) then
              a.kinds[w] = true
            end
          end
          if next(a.kinds) == nil then
            ok = false
          end
        end
        if ok then
          return { optional = false, notes = {}, conds = {}, actions = { a } }
        end
      end
    end
  end
  -- The Soul Stone: "Harness The Soul Stone." turns its infinity ability on.
  if t:find(" harness ", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "harness", who = "you", n = 1 } } }
  end
  -- Dark Confidant: reveal the top card, put it into your hand, lose life equal to its mana value.
  if t:find("reveal the top card of your library and put that card into your hand", 1, true)
      and t:find("you lose life equal to its mana value", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "bob", who = "you", n = 1 } } }
  end
  -- Castle Locthwain: draw a card, then lose life equal to the cards in your hand.
  if t:find("draw a card, then you lose life equal to the number of cards in your hand", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "drawHandLife", who = "you", n = 1 } } }
  end
  -- "Add {B}{B}{B}." (Dark Ritual, Ugin's 0): the mana goes on your mana chips.
  do
    local syms = t:match("^%s*add ([{}%a]+)%s*%.?%s*$")
    if syms and syms:find("{", 1, true) and syms:gsub("{%a}", "") == "" then
      local colors, any = {}, false
      for k in syms:gmatch("{(%a)}") do
        local K = k:upper()
        if K == "W" or K == "U" or K == "B" or K == "R" or K == "G" or K == "C" then
          colors[K] = (colors[K] or 0) + 1
          any = true
        end
      end
      if any then
        return { optional = false, notes = {}, conds = {}, actions = { { what = "addMana", who = "you", n = 1, colors = colors } } }
      end
    end
  end
  -- Reanimate / Virtue of Persistence: a creature card from ANY graveyard onto the battlefield under your control.
  if t:find("put target creature card from a graveyard onto the battlefield under your control", 1, true) then
    return { optional = false, notes = {}, conds = {},
      actions = { { what = "reanimate", who = "you", n = 1,
        loseMV = t:find("you lose life equal to its mana value", 1, true) ~= nil } } }
  end
  -- Palantir of Orthanc: counter, scry 2, then the opponent chooses.
  if t:find("influence counter", 1, true) and t:find("target opponent may have you draw a card", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "palantir", who = "you", n = 1 } } }
  end
  -- Thoughtseize, Inquisition of Kozilek, Duress: look at a hand, choose a card, they discard it.
  if t:find("reveals their hand", 1, true) and t:find("you choose a", 1, true) and t:find("discards that card", 1, true) then
    local who = (t:find("target opponent reveals their hand", 1, true) and "targetOpponent")
      or (t:find("target player reveals their hand", 1, true) and "target")
      or (t:find("that player reveals their hand", 1, true) and "that") or nil
    if who then
      local at = t:find("you choose a", 1, true)
      local seg = t:sub(at, at + 100)
      local actions = {}
      local lw = t:match("you lose (%w+) life")
      if lw and num(lw) then
        table.insert(actions, { what = "lose", who = "you", n = num(lw) })
      end
      table.insert(actions, { what = "handPick", who = who, n = 1, nonland = seg:find("nonland", 1, true) ~= nil,
        noncreature = seg:find("noncreature", 1, true) ~= nil, mvMax = tonumber(seg:match("mana value (%d+) or less") or "") })
      return { optional = false, notes = {}, conds = {}, actions = actions }
    end
  end
  -- Invoke Despair: a creature, then an enchantment, then a planeswalker; each they can't give costs 2 life and draws you a card.
  if t:find("sacrifices a creature of their choice", 1, true) and t:find("then repeat this process", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "despair", who = "targetOpponent", n = 1 } } }
  end
  -- Edicts: "Each opponent sacrifices three creatures." / "Target player sacrifices a creature."
  -- Also "a nontoken creature" and "a creature token".
  do
    for _, w in ipairs({ "each opponent", "each player", "target opponent", "target player", "that player", "defending player" }) do
      local c, ty, ty2 = t:match(w .. " sacrifices (%a+) (%a+) ?(%a*)")
      local tokenMode
      if c and (ty == "nontoken" or ty == "token") then
        tokenMode = ty
        ty = ty2
      elseif c and ty2 == "token" then
        tokenMode = "token"
      end
      if c and ty and (num(c) or c == "a" or c == "an") then
        ty = ty:gsub("s$", "")
        local TY = { creature = true, artifact = true, enchantment = true, land = true, permanent = true, planeswalker = true }
        if TY[ty] then
          return { optional = false, notes = {}, conds = {},
            actions = { { what = "edict", who = "you", n = num(c) or 1, scope = w, ty = ty, tokenMode = tokenMode } } }
        end
      end
    end
  end
  -- Counterspells: "Counter target spell." / "...noncreature spell" / "...blue spell" /
  -- "counter target activated or triggered ability". Mana Drain adds the mana later.
  do
    local tc = t:gsub("this spell can't be countered%.", "")
    if tc:find("^%s*counter target ") then
      local filt = tc:match("^%s*counter target ([%a, ]-)spell")
      local ability = tc:find("^%s*counter target [%a ]-ability") ~= nil
      if filt or ability then
        local unless = tc:match("unless its controller pays ({[{}%w/]+})") or tc:match("unless its controller pays (%w+ mana)")
        return { optional = false, notes = {}, conds = {},
          actions = { { what = "counterSpell", who = "you", n = 1, filter = (filt or ""):gsub("%s+$", ""), ability = ability,
            mv = tonumber(tc:match("with mana value (%d+)") or ""), unless = unless,
            wizardNote = tc:find("if you control a wizard", 1, true) ~= nil,
            drain = tc:find("add an amount of {c} equal to that spell's mana value", 1, true) ~= nil,
            give = tc:match("its controller creates (.-)%.") } } }
      end
    end
  end
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
  -- "...create a 2/1 Skeleton token and suspect it": the token is made; suspecting is by hand.
  if t:find(" and suspect it", 1, true) or t:find(", then suspect it", 1, true) then
    t = t:gsub(" and suspect it", ""):gsub(", then suspect it", "")
    table.insert(notes, "suspect the token yourself (it gets menace and can't block)")
  end
  -- "If <condition>, <effect>." sentences: asked as YES / NO when it
  -- resolves ("Is this true: you control no creatures with decayed?").
  local conds = {}
  local pos = 1
  while pos <= #t do
    local stop = t:find(". ", pos, true)
    local sentence = stop and t:sub(pos, stop) or t:sub(pos)
    local why
    for _, m in ipairs(MANUAL) do
      if why == nil and (" " .. sentence:gsub("double strike", "double_strike") .. " "):find(m, 1, true) then
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
        -- "Create a 5/5 Horse token if you control a Horse." = "If you control a Horse, create ...".
        if cond == nil and not clean:find("^if ") then
          local eff, cc = clean:match("^(.-) if ([^,]+)$")
          if eff and eff ~= "" and not eff:find(" instead", 1, true) and not eff:find("^you may ") then
            cond, rest = cc:gsub("%.$", ""), eff:gsub("%.$", "") .. "."
          end
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
  -- "Lose 2 life." (a mode, or an ability worded without "you").
  w = w or t:match("^%s*lose (%w+) life") or t:match("%. lose (%w+) life") or t:match("— lose (%w+) life")
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
  -- "Target player draws three cards and loses 3 life." (Insatiable Avarice)
  do
    local tw = t:match("target player draws (%w+) cards?")
    if tw and num(tw) then
      add("draw", "target", num(tw))
      local lw = t:match("target player draws %w+ cards? and loses (%w+) life")
      if lw and num(lw) then
        add("lose", "target", num(lw))
      end
    end
  end
  w = t:match("each player draws (%w+) cards?") or t:match("each player loses %w+ life and draws (%w+) cards?")
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
    local top = (t:find("put that card on top", a, true) or t:find("put it on top", a, true) or t:find("put the card on top", a, true)
      or t:find("on top of your library", a, true)) ~= nil and not bf and not hand
    if top then
      where = "top"
    end
    local mvMin = tonumber(rest:match("mana value (%d+) or greater") or "")
    local mvMax = tonumber(rest:match("mana value (%d+) or less") or "")
    table.insert(actions, { what = "search", who = "you", n = 1, query = q, where = where, mvMin = mvMin, mvMax = mvMax,
      tapped = rest:find("battlefield tapped", 1, true) ~= nil, phrase = phrase, anyOf = anyOf,
      discardRandom = t:find("discard a card at random", 1, true) ~= nil })
  end
  -- "untap it" / "untap that permanent" (Amulet of Vigor): the card the
  -- trigger was about.
  if t:find("untap it", 1, true) or t:find("untap that ", 1, true) then
    table.insert(actions, { what = "untap", who = "you", n = 1 })
  elseif t:find(" tap it", 1, true) or t:find(" tap that ", 1, true) then
    table.insert(actions, { what = "tap", who = "you", n = 1 })
  end
  local otherT = false
  if t:find("one other target ", 1, true) or t:find("exile another target ", 1, true) or t:find("destroy another target ", 1, true) then
    otherT = true
    t = t:gsub("up to one other target ", "up to one target "):gsub("exile another target ", "exile target "):gsub("destroy another target ", "destroy target ")
  end
  -- "Destroy all creatures", "exile all nonland permanents your opponents
  -- control", "destroy target artifact"...
  for _, verb in ipairs({ "destroy", "exile" }) do
    for _, how in ipairs({ "all", "each", "target", "up to one target", "two target" }) do
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
        -- "Exile up to one target creature you own, then return it": the table
        -- can't do the return part, so it's all by hand.
        if verb == "exile" and (t:find("then return", 1, true) or t:find("return that card", 1, true)
            or t:find("return it to the battlefield", 1, true)) then
          types = {}
          -- Blink: the table exiles it and brings it back (enters triggers, summon sickness...).
          if (t:find("return it to the battlefield", 1, true) or t:find("return that card to the battlefield", 1, true)
              or t:find("return those cards to the battlefield", 1, true))
              and (phrase:find("creature", 1, true) or phrase:find("artifact", 1, true) or phrase:find("permanent", 1, true)
                or phrase:find("land", 1, true)) then
            local sub = phrase:match("^(.-), then") or phrase
            local kinds = {}
            if sub:find("nonland", 1, true) then
              kinds.nonland = true
            end
            local sub2 = sub:gsub("nonland", "")
            for _, w in ipairs({ "creature", "artifact", "land" }) do
              if sub2:find(w, 1, true) then
                kinds[w] = true
              end
            end
            table.insert(actions, { what = "blink", who = "you", n = 1, thatCreature = phrase:find("that creature", 1, true) ~= nil,
              own = phrase:find("you own", 1, true) ~= nil,
              other = otherT or phrase:find("another", 1, true) ~= nil or phrase:find("other target", 1, true) ~= nil,
              artifact = kinds.artifact == true, kinds = kinds, count = (how == "two target") and 2 or 1,
              upTo = how == "up to one target" })
          end
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
            who = "you", n = 1, verb = verb, types = types, scope = scope, other = otherT or phrase:find("other", 1, true) ~= nil,
            tapped = phrase:find("tapped", 1, true) ~= nil and not phrase:find("untapped", 1, true),
            untilLeaves = verb == "exile" and (t:find("until ~ leaves the battlefield", 1, true) ~= nil),
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
            attacking = atk, tapped = atk or sentence:find("tapped", 1, true) ~= nil,
            haste = sentence:find("with haste", 1, true) ~= nil or sentence:find("and haste", 1, true) ~= nil
              or sentence:find(", haste", 1, true) ~= nil }
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
        ac.countCounters = counted.counters
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
  for _, dest in ipairs({ { "from your graveyard to your hand", "hand" }, { "from your graveyard to the battlefield", "battlefield" },
      { "from your graveyard on top of your library", "top" } }) do
    local g = t:find(dest[1], 1, true)
    if g then
      local before = t:sub(math.max(1, g - 60), g - 1)
      local r = before:find("return ", 1, true) or before:find("put ", 1, true)
      if r then
        local what = before:sub(r + (before:find("return ", 1, true) and 7 or 4)):gsub("^up to %w+ ", ""):gsub("^target ", ""):gsub("^an? ", "")
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
      elseif head:find("equipped creature", 1, true) or head:find("enchanted creature", 1, true) then
        scope = "equipped"
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
      local lt = tonumber(t:match("nonland card with mana value less than (%d+)") or "")
      table.insert(actions, { what = "exileCast", who = "you", n = 1, everyone = false, untilNonland = true,
        mvLess = lt, bottomRest = t:find("on the bottom of your library in a random order", 1, true) ~= nil })
    elseif t:match("discover (%d+)") then
      table.insert(actions, { what = "exileCast", who = "you", n = 1, everyone = false, untilNonland = true,
        mvMax = tonumber(t:match("discover (%d+)")), bottomRest = true, discover = true })
    elseif t:find("shuffle your library, then exile the top card", 1, true) and t:find("you may play that card", 1, true) then
      -- Urza, Lord High Artificer {5}: lands can be played too.
      table.insert(actions, { what = "exileCast", who = "you", n = 1, everyone = false, untilNonland = false,
        shuffleFirst = true, play = true })
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
  if (t:find("sacrifice ~", 1, true) and not t:find("you may sacrifice ~", 1, true))
      or ((t:find(", sacrifice it", 1, true) or t:find("^%s*sacrifice it%s*%.?%s*$") or t:find("^%s*sacrifice it%.")) and not t:find("you may sacrifice it", 1, true)) then
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
  -- Swords etc.: "that player discards a card", "target opponent discards two cards".
  for _, dd in ipairs({ { "that player discards ", "that" }, { "target opponent discards ", "targetOpponent" },
      { "target player discards ", "target" }, { "each opponent discards ", "opponents" },
      { "each player discards ", "all" }, { "you discard ", "you" } }) do
    local dn = t:match(dd[1] .. "(%w+) cards?")
    if dn and num(dn) then
      table.insert(actions, { what = "discard", who = dd[2], n = num(dn) })
    end
  end
  do
    local sw = t:match("^%s*discard (%w+) cards?")
    if sw and num(sw) then
      table.insert(actions, { what = "discard", who = "you", n = num(sw) })
    end
  end
  -- Impulse draw: "exile the top card of your library. You may play that card."
  if t:find("exile the top card of your library", 1, true)
      and (t:find("you may play that card", 1, true) or t:find("you may play it", 1, true)
        or t:find("you may cast that card", 1, true)) then
    local untilWhen = t:find("end of your next turn", 1, true) and "the end of your next turn"
      or (t:find("end of turn", 1, true) and "the end of this turn" or "later")
    table.insert(actions, { what = "impulse", who = "you", n = 1, untilWhen = untilWhen })
  end
  -- "that player mills ten cards".
  for _, dd in ipairs({ { "that player mills ", "that" }, { "target player mills ", "target" },
      { "target opponent mills ", "targetOpponent" }, { "each opponent mills ", "opponents" } }) do
    local mn = t:match(dd[1] .. "(%w+) cards?")
    if mn and num(mn) then
      table.insert(actions, { what = "mill", who = dd[2], n = num(mn) })
    end
  end
  -- "untap all lands you control" (Sword of Feast and Famine).
  do
    local ut = t:match("untap all (%a+) you control")
    if ut then
      table.insert(actions, { what = "untapAll", who = "you", n = 1, type = (ut:gsub("s$", "")) })
    end
  end
  -- Lord of the Rings: "the Ring tempts you".
  if t:find("the ring tempts you", 1, true) then
    table.insert(actions, { what = "ringTempts", who = "you", n = 1 })
  end
  do
    local tw = t:match("then discard (%w+) cards?")
    if tw and num(tw) then
      table.insert(actions, { what = "discard", who = "you", n = num(tw) })
    end
  end
  -- "put a quest counter on ~": counters on the card itself.
  local cn, ckind = t:match("put (%w+) ([%w%+/%-]+) counters? on ~")
  local onIt = false
  if not cn then
    -- Emiel / Ajani's Pridemate style: "...put a +1/+1 counter on it" = the creature that entered.
    cn, ckind = t:match("put (%w+) ([%w%+/%-]+) counters? on it[%.%s]")
    onIt = cn ~= nil
  end
  if cn and num(cn) then
    local kind = (ckind == "+1/+1" and "plus") or (ckind == "-1/-1" and "minus") or (ckind == "loyalty" and "loyalty")
      or "other"
    table.insert(actions, { what = "counter", who = "you", n = num(cn), kind = kind, label = ckind, onThat = onIt })
  end
  -- "put three +1/+1 counters on target creature (you control)": pick it on the table.
  do
    local t2 = t:gsub("up to one target", "target")
    local upTo = t2 ~= t
    local pn, pk, pty = t2:match("put (%w+) ([%w%+/%-]+) counters? on target (%a+)")
    if pn and num(pn) and pty and (pty == "creature" or pty == "permanent" or pty == "artifact" or pty == "planeswalker" or pty == "land") then
      local after = t2:match("put %w+ [%w%+/%-]+ counters? on target %a+ ([%a ]*)") or ""
      table.insert(actions, { what = "counterOn", who = "you", n = num(pn), kind = (pk == "+1/+1" and "plus") or (pk == "-1/-1" and "minus")
        or (pk == "loyalty" and "loyalty") or "other", label = pk, ty = pty, mine = after:find("you control", 1, true) ~= nil,
        upTo = upTo })
    end
  end
  -- "remove an ice counter from ~" (Dark Depths).
  do
    local rn, rk = t:match("remove (%w+) ([%w%+/%-]+) counters? from ~")
    if rn and num(rn) and not t:find("^[^:]*remove [^:]*:") then
      local kind = (rk == "+1/+1" and "plus") or (rk == "-1/-1" and "minus") or (rk == "loyalty" and "loyalty") or "other"
      table.insert(actions, { what = "counter", who = "you", n = -num(rn), kind = kind, label = rk })
    end
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
    local theirs = false
    if not btype then
      local ph = t:match("return target ([%a ]-) you don't control to its owner's hand")
        or t:match("return target ([%a ]-) an opponent controls to its owner's hand")
      if ph then
        btype = ph:match("^(nonland) permanent$") or ph:match("^(%a+)$")
        theirs = btype ~= nil
      end
    end
    if btype then
      table.insert(actions, { what = "bounce", who = "you", n = 1, type = btype, mine = false, other = other, theirs = theirs })
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
    if act.what == "exileCast" or act.what == "untapAttacker" or act.what == "revealUntil" or act.what == "impulse" then
      optional = false
    end
  end
  if nthTransform and #actions > 0 then
    table.insert(actions, { what = "nthTransform", who = "you", n = nthTransform })
  end
  -- Takenuma: "Mill three cards, then return a creature ... card from your graveyard": mill first.
  do
    local mi, gi
    for i, ac in ipairs(actions) do
      if ac.what == "mill" and not mi then mi = i end
      if ac.what == "graveReturn" and not gi then gi = i end
    end
    local tm = t:find("mill ", 1, true)
    local tr = t:find("return ", 1, true)
    if mi and gi and gi < mi and tm and tr and tm < tr then
      actions[mi], actions[gi] = actions[gi], actions[mi]
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
  elseif a.what == "nikoSwap" then
    return "a creature is exiled; the Shards become copies of it until the next end step"
  elseif a.what == "edict" then
    return tostring(a.scope) .. " sacrifices " .. a.n .. " " .. tostring(a.ty) .. (a.n == 1 and "" or "s")
  elseif a.what == "despair" then
    return "target opponent sacrifices a creature, an enchantment and a planeswalker (or loses 2 life and you draw for each they can't)"
  elseif a.what == "harness" then
    return "it becomes harnessed (its infinity ability turns on)"
  elseif a.what == "bob" then
    return "reveal the top card, put it into your hand and lose life equal to its mana value"
  elseif a.what == "drawHandLife" then
    return "draw a card, then lose life equal to the cards in your hand"
  elseif a.what == "addMana" then
    return "add mana to the mana chips"
  elseif a.what == "reanimate" then
    return "a creature card from any graveyard comes back under your control" .. (a.loseMV and ", you lose life equal to its mana value" or "")
  elseif a.what == "palantir" then
    return "influence counter, scry 2, then the opponent picks: you draw, or you mill and they lose life"
  elseif a.what == "handPick" then
    return "look at the hand and choose a card to discard"
  elseif a.what == "sylvan" then
    return "you may draw two extra cards, then pay 4 life or put a card back on top for each of two cards"
  elseif a.what == "jeska" then
    return "choose: {R} for each card in an opponent's hand, and/or exile the top three cards to play this turn"
  elseif a.what == "sacTutor" then
    return "search for a creature worth " .. tostring(a.plus) .. " more than the sacrificed creature"
  elseif a.what == "arcum" then
    return "a target artifact creature is sacrificed and its controller may search for an artifact worth 1 more"
  elseif a.what == "windfall" then
    return "everyone discards their hand and draws as many cards as the most anyone discarded"
  elseif a.what == "powerHit" then
    return "damage equal to the creature's power to any target"
  elseif a.what == "manaAsk" then
    return "mana for each " .. tostring(a.label)
  elseif a.what == "copyThat" then
    return "a token copy of " .. tostring(a.which)
  elseif a.what == "tapX" then
    return tostring(a.mode) .. (a.self and " itself" or (a.all and " all matching permanents" or " target permanent"))
  elseif a.what == "counterOn" then
    return a.n .. " " .. tostring(a.label) .. " counter" .. (a.n == 1 and "" or "s") .. " on a target " .. tostring(a.ty)
  elseif a.what == "playerPro" then
    return "protection from everything until their next turn"
  elseif a.what == "counterSpell" then
    return "a spell on the stack is countered"
  elseif a.what == "blink" then
    return "a creature is exiled and returns to the battlefield"
  elseif a.what == "copyCreature" then
    return "a token copy of a creature is made"
  elseif a.what == "counter" then
    if a.n < 0 then
      return (-a.n) .. " " .. tostring(a.label) .. " counter" .. (a.n == -1 and "" or "s") .. " removed"
    end
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
  elseif a.what == "copySelf" then
    return "a token copy of itself"
  elseif a.what == "drawGreatest" then
    return "draw cards equal to your greatest creature power"
  elseif a.what == "populate" then
    return "populate: a token copy of a creature token you control"
  elseif a.what == "proliferate" then
    return "proliferate: another counter of each kind on the permanents you choose"
  elseif a.what == "victimize" then
    return "sacrifice a creature, then return two creature cards from your graveyard tapped"
  elseif a.what == "nantuko" then
    return "pay {1} for a copy of the enchanted creature, otherwise a 1/1 Insect"
  elseif a.what == "addManaAny" then
    return "add one mana of any color (you pick)"
  elseif a.what == "counterAll" then
    return a.mode == "double" and "double the +1/+1 counters on each creature you control"
      or ("a +1/+1 counter on each " .. (a.other and "other " or "") .. (a.word and (a.word .. " ") or "") .. "creature you control")
  elseif a.what == "scute" then
    return "an Insect token, or a copy of itself with six or more lands"
  elseif a.what == "eachPlayerToken" then
    return "each player creates a " .. tostring(a.word) .. " token"
  elseif a.what == "copyEachToken" then
    return "a token copy of each token you control"
  elseif a.what == "sacDraw" then
    return a.max == 1 and "you may sacrifice another creature; if you do, draw a card"
      or "you may sacrifice any number of other creatures; draw that many cards"
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
      ph = ph:gsub("^1 ", "one per " .. a.countWord:gsub("s$", "") .. (a.countScope == "opponents" and " your opponents control: " or (a.countScope == "all" and " on the battlefield: " or " you control: ")), 1)
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
  elseif a.what == "discard" then
    return who .. (you and " discard " or " discards ") .. a.n .. " card" .. (a.n == 1 and "" or "s")
  elseif a.what == "untapAll" then
    return "untap all " .. tostring(a.type) .. "s"
  elseif a.what == "ringTempts" then
    return "the Ring tempts " .. who
  elseif a.what == "wheel" then
    return who .. " may discard their hand and draw " .. a.n
  elseif a.what == "impulse" then
    return who .. " exile the top card and may play it until " .. tostring(a.untilWhen)
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
  elseif a.what == "nthTransform" then
    return "it transforms if this is the " .. a.n .. "th time this turn (the table counts)"
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
    if a.countWord then
      return who .. (you and " gain " or " gains ") .. "life equal to your " .. a.countWord .. " count"
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

local function amountOf(a, controller, name, it)
  if a.countCounters then
    local src = it and it.source and getObjectFromGUID(it.source)
    local n = 0
    if src and not src.isDestroyed() then
      n = Counters.get(src).plus
    end
    printToAll("MTG > " .. tostring(name) .. ": " .. n .. " +1/+1 counter(s) on it.", INFO)
    return n
  end
  if a.countWord then
    local n = Effects.countPermanents(controller, a.countWord, a.countScope)
    printToAll("MTG > " .. tostring(name) .. ": " .. n .. " " .. a.countWord .. (a.countScope == "opponents" and " your opponents control." or " you control."), INFO)
    return n
  end
  return a.n
end

-- Replacement effects in play (Rhox Faithmender, Tainted Remedy, Thought Reflection...): the table can't do
-- their math, so the controller confirms the real amount before it goes through.
local WATCH_VERB = { gain = "gain", lose = "lose", draw = "draw", damage = "be dealt" }
local WATCH_NOUN = { gain = " life", lose = " life", draw = " card(s)", damage = " damage" }

local function watched(kind, subject, n, controller, name, run)
  if type(n) ~= "number" or n <= 0 then
    run(n)
    return
  end
  local names = {}
  if Statics and Statics.replacers then
    local ok, list = pcall(Statics.replacers, kind, subject)
    if ok and list then
      names = list
    end
  end
  if #names == 0 then
    run(n)
    return
  end
  Effects.askAmount(controller, name .. ": " .. table.concat(names, ", ") .. " may change this",
    tostring(subject) .. " would " .. WATCH_VERB[kind] .. " " .. n .. WATCH_NOUN[kind]
      .. ". Type the real amount (0 for none), then OK, or keep " .. n .. ".",
    "KEEP " .. n, function(v)
      if v == "keep" then
        v = n
      end
      run(v)
    end)
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
          if a.countWord then
            gain = amountOf(a, controller, it.name)
          end
          if a.thatMuch then
            gain = it.amount or 0
          end
          if a.perSpell then
            gain = a.n * math.max(1, Effects.spellsThisTurn(controller))
            printToAll("MTG > " .. it.name .. ": " .. controller .. " has cast " .. math.max(1, Effects.spellsThisTurn(controller))
              .. " spell(s) this turn.", INFO)
          end
          watched("gain", seat, gain, controller, it.name, function(v)
            if v > 0 then
              Trackers.changeLife(seat, v, it.name)
            end
          end)
        elseif a.what == "lose" then
          local lost = amountOf(a, controller, it.name)
          if lost > 0 then
            local isDamage = tostring(it.text or ""):lower():find("damage", 1, true) ~= nil
            watched(isDamage and "damage" or "lose", seat, lost, controller, it.name, function(v)
              if v > 0 then
                Trackers.changeLife(seat, -v, it.name)
              end
            end)
          end
        elseif a.what == "draw" then
          watched("draw", seat, a.n, controller, it.name, function(v)
            if v > 0 then
              Actions.draw(seat, v, it.name)
            end
          end)
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
            { typeOnly = true, mvMin = a.mvMin, mvMax = a.mvMax, anyOf = a.anyOf, limit = a.where == "top" and 1 or nil,
              onClose = a.discardRandom and function()
                Wait.time(function() Actions.discardRandom(seat, 1, it.name) end, 0.6)
              end or nil })
        elseif a.what == "counter" then
          local src = it.source and getObjectFromGUID(it.source)
          if a.onThat and it.thatCard then
            src = getObjectFromGUID(it.thatCard) or src
          end
          if src and not src.isDestroyed() then
            Counters.place(src, a.kind, a.n, seat)
          else
            broadcastToColor(it.name .. " isn't on the table any more: no counter added.", seat, INFO)
          end
        elseif a.what == "bounce" then
          Effects.pickBounce(seat, a, it.name, it.source)
        elseif a.what == "token" then
          local made = amountOf(a, controller, it.name, it)
          local opts = (a.tapped or a.attacking or a.haste)
            and { tapped = a.tapped, attacking = a.attacking, haste = a.haste, from = it.thatCard or it.source } or nil
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
                local placed = Counters.place(src, "plus", a.counters, controller)
                printToAll("MTG > " .. seat .. " declines: " .. it.name .. " gets " .. placed .. " +1/+1 counters.", GOOD)
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
                local placed = Counters.place(src, "plus", a.n, seat)
                printToAll("MTG > " .. seat .. " put " .. placed .. " +1/+1 counter(s) on " .. it.name .. " (fabricate).", GOOD)
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
            .. (a.where == "battlefield" and " to the battlefield" or (a.where == "top" and " to the top of your library" or " to your hand")) .. ", then CLOSE.",
            a.where, a.tapped, { typeOnly = true, zone = "graveyard" })
        elseif a.what == "scry" then
          for _ = 1, a.n do
            Actions.openScry(seat)
          end
        elseif a.what == "mill" then
          Actions.mill(seat, a.n)
        elseif a.what == "discard" then
          Actions.forceDiscard(seat, a.n, it.name)
        elseif a.what == "untapAll" then
          Effects.untapAllOf(seat, a.type, it.name)
        elseif a.what == "ringTempts" then
          Ring.tempt(seat)
        elseif a.what == "wheel" then
          Effects.askChoice(seat, it.name .. ": discard your hand?", "Discard your hand. If you do, draw " .. a.n .. " cards.",
            { { label = "YES", value = true }, { label = "NO", value = false } }, function(yes)
              if yes then
                Actions.discardHand(seat, it.name)
                Actions.draw(seat, a.n, it.name)
              else
                printToAll("MTG > " .. seat .. " chose not to (" .. it.name .. ").", INFO)
              end
            end)
        elseif a.what == "impulse" then
          Library.exileUntilNonland(seat, true, function(card)
            local nm = card and card.getName() or "the top card"
            printToAll("MTG > " .. it.name .. ": " .. seat .. " exiles " .. nm .. " and may play it until " .. tostring(a.untilWhen)
              .. " (it waits in exile).", GOOD)
            broadcastToColor("You may play " .. nm .. " from exile until " .. tostring(a.untilWhen) .. ".", seat, GOOD)
          end)
        elseif a.what == "removeAll" then
          a.count = Effects.removeAll(seat, a, it)
        elseif a.what == "removeTarget" then
          Effects.pickRemove(seat, a, it.name, it.source)
        elseif a.what == "sacrifice" then
          Effects.pickSacrifice(seat, a, it)
        elseif a.what == "sacDraw" then
          Effects.sacDraw(seat, a, it)
        elseif a.what == "copySelf" then
          local src = it.source and getObjectFromGUID(it.source)
          if src and not src.isDestroyed() then
            Effects.copyCard(src, seat, {}, it.name)
          else
            broadcastToColor(it.name .. ": make the token copy yourself (the card wasn't found).", seat, INFO)
          end
        elseif a.what == "drawGreatest" then
          local best = 0
          for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
            if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and Effects.fieldSeat(obj) == seat
                and Effects.cardTypes(obj).creature then
              local pw = tonumber(Counters.stats(obj).power) or 0
              if pw > best then
                best = pw
              end
            end
          end
          printToAll("MTG > " .. it.name .. ": greatest power among " .. seat .. "'s creatures is " .. best .. ".", INFO)
          if best > 0 then
            Actions.draw(seat, best, it.name)
          end
        elseif a.what == "populate" then
          Effects.populate(seat, it)
        elseif a.what == "proliferate" then
          Effects.proliferate(seat, it)
        elseif a.what == "nantuko" then
          Effects.nantuko(seat, it)
        elseif a.what == "victimize" then
          ask(seat, it.name .. ": sacrifice a creature", "Click SACRIFICE on a creature you control. If you do, you pick two creature cards from your graveyard to return tapped.",
            { { label = "NONE (NOTHING HAPPENS)", value = false } }, function(victim)
              if not victim or victim.isDestroyed() then
                printToAll("MTG > " .. seat .. " sacrifices nothing: " .. it.name .. " does nothing.", INFO)
                return
              end
              printToAll("MTG > " .. seat .. " sacrifices " .. victim.getName() .. " (" .. it.name .. ").", GOOD)
              Combat.removeCard(victim, "graveyard")
              Wait.time(function()
                LibSearch.open(seat, "creature", it.name .. ": click TWO creature cards in your graveyard to return them tapped, then CLOSE.",
                  "battlefield", true, { typeOnly = true, zone = "graveyard", yardOf = seat })
              end, 1.2)
            end, { filter = function(obj, owner)
              return owner == seat and Effects.cardTypes(obj).creature == true
            end, label = "SACRIFICE", protect = false })
        elseif a.what == "addManaAny" then
          Effects.askChoice(seat, it.name .. ": which color?", "Pick the color of mana to add to your mana chips.",
            { { label = "W", value = "W" }, { label = "U", value = "U" }, { label = "B", value = "B" },
              { label = "R", value = "R" }, { label = "G", value = "G" } }, function(k)
              ManaChips.add(seat, k, 1)
              printToAll("MTG > " .. it.name .. ": " .. seat .. " adds " .. k .. " to their mana chips.", GOOD)
            end)
        elseif a.what == "counterAll" then
          Effects.counterAll(seat, a, it)
        elseif a.what == "scute" then
          local src = it.source and getObjectFromGUID(it.source)
          local lands = Effects.countPermanents(seat, "land", "mine")
          if lands >= 6 and src and not src.isDestroyed() then
            printToAll("MTG > " .. it.name .. ": " .. lands .. " lands - a copy of it instead of an Insect.", GOOD)
            Effects.copyCard(src, seat, {}, it.name)
          else
            if lands >= 6 then
              broadcastToColor(it.name .. ": " .. lands .. " lands - make the token copy of it yourself.", seat, INFO)
            else
              Tokens.create(seat, { pt = "1/1", words = { "insect" }, colors = { G = true } }, 1, it.name)
            end
          end
        elseif a.what == "eachPlayerToken" then
          for _, c in ipairs(Effects.orderFrom(seat)) do
            Tokens.create(c, { words = { a.word }, colors = {} }, 1, it.name)
          end
        elseif a.what == "copyEachToken" then
          local n = 0
          for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
            if obj.type == "Card" and not obj.isDestroyed() and obj.hasTag("Token") and not Faces.unknown(obj)
                and Effects.fieldSeat(obj) == seat then
              n = n + 1
            end
          end
          local mine = {}
          for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
            if obj.type == "Card" and not obj.isDestroyed() and obj.hasTag("Token") and not Faces.unknown(obj)
                and Effects.fieldSeat(obj) == seat then
              table.insert(mine, obj)
            end
          end
          printToAll("MTG > " .. it.name .. ": copying " .. n .. " token(s) you control.", INFO)
          for _, obj in ipairs(mine) do
            Effects.copyCard(obj, seat, {}, it.name)
          end
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
        elseif a.what == "counterSpell" then
          Effects.counterSpell(seat, a, it)
        elseif a.what == "counterOn" then
          Effects.counterOn(seat, a, it)
        elseif a.what == "playerPro" then
          GameState.data.playerPro = GameState.data.playerPro or {}
          GameState.data.playerPro[seat] = true
          printToAll("MTG > " .. seat .. " has protection from everything until their next turn (" .. it.name .. "): they can't be targeted.", GOOD)
          broadcastToAll(seat .. " has PROTECTION FROM EVERYTHING until their next turn.", { 1, 0.85, 0.3 })
        elseif a.what == "nikoSwap" then
          Effects.nikoSwap(seat, a, it)
        elseif a.what == "edict" then
          Effects.edict(seat, a, it)
        elseif a.what == "despair" then
          Effects.despair(controller, seat, it)
        elseif a.what == "harness" then
          local src = it.source and getObjectFromGUID(it.source)
          if src and not src.isDestroyed() then
            GameState.data.harnessed = GameState.data.harnessed or {}
            GameState.data.harnessed[src.getGUID()] = true
            printToAll("MTG > " .. it.name .. " is harnessed: its infinity ability is on.", GOOD)
          else
            printToAll("MTG > " .. it.name .. " isn't on the table any more.", INFO)
          end
        elseif a.what == "bob" then
          Effects.bob(seat, it)
        elseif a.what == "drawHandLife" then
          Effects.drawHandLife(seat, it)
        elseif a.what == "addMana" then
          local parts = {}
          for key, n in pairs(a.colors) do
            ManaChips.add(seat, key, n)
            table.insert(parts, n .. " " .. key)
          end
          table.sort(parts)
          printToAll("MTG > " .. it.name .. ": " .. seat .. " adds " .. table.concat(parts, ", ") .. " to their mana chips.", GOOD)
        elseif a.what == "reanimate" then
          Effects.reanimate(seat, a, it)
        elseif a.what == "palantir" then
          Effects.palantir(seat, it)
        elseif a.what == "handPick" then
          Effects.handPick(controller, seat, a, it)
        elseif a.what == "arcum" then
          Effects.arcum(seat, it)
        elseif a.what == "jeska" then
          Effects.jeska(seat, a, it)
        elseif a.what == "sylvan" then
          Effects.sylvan(seat, it)
        elseif a.what == "sacTutor" then
          Effects.askNumber(seat, it.name .. ": sacrificed creature's mana value?", "Type the mana value of the creature you sacrificed, then OK. The search is for mana value "
            .. (a.exact and "exactly " or "") .. "that + " .. a.plus .. (a.exact and "." or " or less."), function(n)
            local mv = (tonumber(n) or 0) + a.plus
            LibSearch.open(seat, "creature", it.name .. ": take a creature with mana value " .. (a.exact and "" or "up to ") .. mv
              .. " onto the battlefield, then CLOSE + SHUFFLE.", "battlefield", false,
              { typeOnly = true, mvMin = a.exact and mv or nil, mvMax = mv })
          end)
        elseif a.what == "windfall" then
          Effects.windfall(it, a.fixed)
        elseif a.what == "powerHit" then
          Effects.powerHit(seat, a, it)
        elseif a.what == "manaAsk" then
          Effects.manaAsk(seat, a, it)
        elseif a.what == "copyThat" then
          Effects.copyThat(seat, a, it)
        elseif a.what == "tapX" then
          Effects.tapX(seat, a, it)
        elseif a.what == "blink" then
          Effects.blink(seat, a, it)
        elseif a.what == "copyCreature" then
          Effects.copyCreature(seat, a, it)
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
        elseif a.what == "nthTransform" then
          local turn = (GameState.data.turn or {}).number or 0
          local c = GameState.data.nthCount
          if c == nil or c.turn ~= turn then
            c = { turn = turn }
            GameState.data.nthCount = c
          end
          local key = tostring(it.source or it.name)
          c[key] = (c[key] or 0) + 1
          printToAll("MTG > " .. it.name .. ": resolved " .. c[key] .. " time(s) this turn.", INFO)
          if c[key] == a.n then
            local src = it.source and getObjectFromGUID(it.source)
            if src and not src.isDestroyed() and Faces.isDoubleFaced(src) then
              Faces.flip(src, it.name)
            else
              broadcastToColor(it.name .. ": that was time " .. a.n .. " - transform it yourself (right-click > Transform / other face).", seat, INFO)
            end
          end
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
    number = number, src = Effects.currentSource })
  if current == nil then
    nextQuestion()
  end
end

-- For code above `ask` in this file (apply).
function Effects.askChoice(seat, title, text, choices, onPick, pick)
  ask(seat, title, text, choices, onPick, pick)
end

-- Ask for a whole number (X): the box with OK. onPick(n) only on an answer.
-- A number box with a button that keeps the suggested amount.
function Effects.askAmount(seat, title, text, keepLabel, onPick)
  ask(seat, title, text, { { label = keepLabel, value = "keep" } }, function(v)
    onPick(v)
  end, nil, true)
end

function Effects.askNumber(seat, title, text, onPick)
  ask(seat, title, text, { { label = "CANCEL", value = false } }, function(n)
    if n ~= false then
      onPick(n)
    end
  end, nil, true)
end

---------------------------------------------------------------------------
-- Counterspells and "at the beginning of your next ..." delayed effects
---------------------------------------------------------------------------

local function delayedList()
  GameState.data.delayed = GameState.data.delayed or {}
  return GameState.data.delayed
end

function Effects.addDelayed(rec)
  table.insert(delayedList(), rec)
end

local COLOR_WORDS = { white = "W", blue = "U", black = "B", red = "R", green = "G" }

local function spellFits(obj, filt, mvWant)
  if mvWant then
    local mv = -1
    pcall(function() mv = tonumber(JSON.decode(obj.getGMNotes()).cmc) or 0 end)
    if mv ~= mvWant then
      return false
    end
  end
  if filt == nil or filt == "" then
    return true
  end
  local d = {}
  pcall(function() d = JSON.decode(obj.getGMNotes()) or {} end)
  local tl = tostring(d.typeLine or ""):lower()
  local colors = {}
  for _, c in ipairs(type(d.colors) == "table" and d.colors or {}) do
    colors[tostring(c):upper()] = true
  end
  local anyOf = filt:find(" or ", 1, true) ~= nil
  local ok = not anyOf
  for w in filt:gmatch("%a+") do
    if w ~= "or" then
      local fits
      if w:sub(1, 3) == "non" then
        fits = not (tl:find(w:sub(4), 1, true) or (COLOR_WORDS[w:sub(4)] and colors[COLOR_WORDS[w:sub(4)]]))
      elseif COLOR_WORDS[w] then
        fits = colors[COLOR_WORDS[w]] == true
      else
        fits = tl:find(w, 1, true) ~= nil
      end
      if anyOf then
        ok = ok or fits
      else
        ok = ok and fits
      end
    end
  end
  return ok
end

function Effects.counterSpell(seat, a, it)
  local cands = {}
  for _, e in ipairs(Stack.entries()) do
    local obj = getObjectFromGUID(e.guid)
    if e.guid ~= it.card and obj ~= nil then
      if a.ability then
        if e.kind == "ability" then
          table.insert(cands, e)
        end
      elseif e.kind == "card" and spellFits(obj, a.filter, a.mv) then
        table.insert(cands, e)
      end
    end
  end
  local function counter(e)
    if a.unless then
      local payer = e.controller
      local extra = a.wizardNote and " (If " .. seat .. " controls a Wizard it is {4} instead.)" or ""
      ask(payer, it.name .. ": pay " .. a.unless .. "?", e.name .. " is countered unless you pay " .. a.unless .. "." .. extra,
        { { label = "PAY", value = true }, { label = "DON'T PAY", value = false } }, function(pays)
          if pays then
            printToAll("MTG > " .. payer .. " pays " .. a.unless .. ": " .. e.name .. " is not countered.", GOOD)
          else
            a.unless = nil
            counter(e)
          end
        end)
      return
    end
    local mv = 0
    local obj = getObjectFromGUID(e.guid)
    if obj then
      pcall(function() mv = tonumber(JSON.decode(obj.getGMNotes()).cmc) or 0 end)
    end
    Stack.counterGuid(e.guid, it.name)
    printToAll("MTG > " .. it.name .. " counters " .. e.name .. ".", GOOD)
    if a.give and e.controller then
      Effects.resolve({ name = it.name, controller = e.controller, auto = true, text = "Create " .. a.give .. "." })
    end
    if a.drain then
      Effects.addDelayed({ seat = seat, step = "main", kind = "mana", color = "C", amount = mv, name = it.name })
      broadcastToColor(it.name .. ": you will get " .. mv .. " colorless mana at the beginning of your next main phase.", seat, GOOD)
    end
  end
  if #cands == 0 then
    broadcastToColor(it.name .. ": nothing on the stack for it to counter.", seat, INFO)
    return
  end
  if #cands == 1 then
    counter(cands[1])
    return
  end
  local lines, choices = {}, {}
  for i = #cands, 1, -1 do
    if #choices < MAX_CHOICES then
      table.insert(lines, #choices + 1 .. ") " .. cands[i].name .. " (" .. tostring(cands[i].controller) .. ")")
      table.insert(choices, { label = tostring(#choices + 1), value = i })
    end
  end
  ask(seat, it.name .. ": counter which?", table.concat(lines, "\n"), choices, function(i)
    counter(cands[i])
  end)
end

-- Exile a creature and return it: leaves and enters the battlefield, so
-- "enters" triggers fire, counters go away and summoning sickness starts over.
function Effects.blinkCard(obj, seat, srcName)
  if obj == nil or obj.isDestroyed() then
    return
  end
  local loc = Zones.regionAt(obj.getPosition())
  local owner = loc.seat or seat
  local from = { seat = owner, region = loc.region }
  if Equip then
    if Equip.isAttachment(obj) then
      Equip.detach(obj, "silent")
    end
    for _, att in ipairs(Equip.attachments(obj)) do
      Equip.detach(att, "its creature left")
    end
  end
  local g = obj.getGUID()
  if GameState.data.tempKeywords then
    GameState.data.tempKeywords[g] = nil
  end
  local r = obj.getRotation()
  obj.setRotationSmooth({ r.x, TableSetup.seat(owner).yaw, r.z }, false, true)
  printToAll("MTG > " .. tostring(srcName) .. ": " .. obj.getName() .. " is exiled and returns to the battlefield.", GOOD)
  Events.emit("cardMoved", { card = obj, name = obj.getName(), from = from, to = { seat = owner, region = "exile" } })
  Wait.time(function()
    if obj.isDestroyed() then
      return
    end
    local now = Zones.regionAt(obj.getPosition())
    if now.region ~= "battlefield" and now.region ~= "lands" then
      return
    end
    Events.emit("cardMoved", { card = obj, name = obj.getName(), from = { seat = owner, region = "exile" }, to = from })
    Counters.render(obj)
  end, 0.8)
end

function Effects.blink(seat, a, it)
  if a.thatCreature then
    local obj = it.thatCard and getObjectFromGUID(it.thatCard)
    if obj and not obj.isDestroyed() then
      Effects.blinkCard(obj, seat, it.name)
    else
      broadcastToColor(it.name .. ": blink the creature yourself.", seat, INFO)
    end
    return
  end
  local kinds = a.kinds
  if kinds == nil or next(kinds) == nil then
    kinds = { creature = true, artifact = a.artifact or nil }
  end
  local count, done = a.count or 1, {}
  local function step(k)
    if k > count then
      return
    end
    local label = (kinds.nonland or kinds.land) and "permanent" or (kinds.artifact and (kinds.creature and "artifact or creature" or "artifact") or "creature")
    ask(seat, it.name .. ": blink " .. (count > 1 and ("a " .. label .. " (" .. k .. " of " .. count .. ")") or ("a " .. label)),
      "Click BLINK on the " .. label .. " to exile and return, or SKIP.",
      { { label = "SKIP", value = false } }, function(obj)
        if obj then
          done[obj.getGUID()] = true
          Effects.blinkCard(obj, seat, it.name)
          step(k + 1)
        else
          printToAll("MTG > " .. it.name .. ": " .. (k == 1 and "nothing blinked." or "no more blinked."), INFO)
        end
      end, { filter = function(obj, owner)
        if owner ~= seat or done[obj.getGUID()] then
          return false
        end
        local ty = Effects.cardTypes(obj)
        local ok = (kinds.creature and ty.creature) or (kinds.artifact and ty.artifact) or (kinds.land and ty.land)
          or (kinds.nonland and not ty.land)
        return ok == true and not (a.other and it.source and obj.getGUID() == it.source)
      end, label = "BLINK" })
  end
  step(1)
end

-- "Put N counters on target creature": click it on the table.
function Effects.counterOn(seat, a, it)
  ask(seat, it.name .. ": counters on a " .. a.ty, "Click COUNTER on the " .. a.ty .. " that gets " .. a.n .. " " .. a.label
    .. " counter" .. (a.n == 1 and "" or "s") .. (a.upTo and ", or SKIP." or "."),
    { { label = "SKIP", value = false } }, function(obj)
      if obj then
        local placed = Counters.place(obj, a.kind, a.n, seat)
        printToAll("MTG > " .. it.name .. ": " .. placed .. " " .. a.label .. " counter" .. (placed == 1 and "" or "s") .. " on " .. obj.getName() .. ".", GOOD)
      else
        printToAll("MTG > " .. it.name .. ": no counters placed.", INFO)
      end
    end, { filter = function(obj, owner)
      if a.mine and owner ~= seat then
        return false
      end
      local types = Effects.cardTypes(obj)
      return a.ty == "permanent" or types[a.ty] == true
    end, label = "COUNTER", protect = false })
end

-- Niko: the Shards become copies of the exiled creature until the next end step.
function Effects.nikoSwap(seat, a, it)
  ask(seat, it.name .. ": exile which creature?", "Click EXILE on a nonlegendary creature you control, or SKIP.",
    { { label = "SKIP", value = false } }, function(obj)
      if not obj then
        printToAll("MTG > " .. it.name .. ": nothing exiled.", INFO)
        return
      end
      local clones, shards = {}, {}
      for _, sh in ipairs(getObjectsWithTag("MTGCard")) do
        if sh.type == "Card" and not sh.isDestroyed() and sh.getName() == "Shard" and Effects.fieldSeat(sh) == seat then
          local pos, rot = sh.getPosition(), sh.getRotation()
          local c = obj.clone({ position = { x = pos.x, y = pos.y + 0.3, z = pos.z } })
          if c then
            c.addTag("Token")
            c.memo = ""
            Zones.presetFrom(c, seat)
            Wait.time(function()
              if not c.isDestroyed() then
                Zones.refresh(c)
                Counters.setup(c)
              end
            end, 0.7)
            table.insert(clones, c.getGUID())
            table.insert(shards, { guid = sh.getGUID(), pos = pos, rot = rot })
            sh.setPosition(TableSetup.slot(seat, "act_tokens", TableSetup.SURFACE_TOP + 1.5))
          end
        end
      end
      local owner = Effects.fieldSeat(obj) or seat
      local guid, isToken = obj.getGUID(), obj.hasTag("Token")
      Combat.removeCard(obj, "exile")
      printToAll("MTG > " .. it.name .. ": " .. obj.getName() .. " is exiled; " .. #clones .. " Shard" .. (#clones == 1 and "" or "s")
        .. " become copies of it until the next end step.", GOOD)
      Effects.addDelayed({ seat = seat, anySeat = true, step = "end", kind = "nikoEnd", clones = clones, shards = shards,
        ret = isToken and "" or guid, owner = owner, name = it.name })
    end, { filter = function(obj, owner)
      if owner ~= seat or not Effects.cardTypes(obj).creature then
        return false
      end
      local d = {}
      pcall(function() d = JSON.decode(obj.getGMNotes()) or {} end)
      return not tostring(d.typeLine or ""):find("Legendary", 1, true)
    end, label = "EXILE" })
end

-- A token copy of a creature (Kiki-Jiki, Twinflame).
function Effects.copyCard(obj, seat, a, srcName)
  if obj == nil or obj.isDestroyed() then
    return nil
  end
  -- Doubling Season / Parallel Lives / Chatterfang: more copies (each extra is made once, without re-applying).
  if not a.noMods then
    local m = 1
    if Statics and Statics.tokenMultiplier then
      m = Statics.tokenMultiplier(seat)
    end
    local extra = {}
    for k, v in pairs(a) do
      extra[k] = v
    end
    extra.noMods = true
    if m > 1 then
      printToAll("MTG > " .. srcName .. ": token doubler - " .. m .. " copies of " .. obj.getName() .. ".", { 0.55, 0.9, 0.6 })
      for _ = 2, m do
        Effects.copyCard(obj, seat, extra, srcName)
      end
    end
    if Statics and Statics.chatterfang and Statics.chatterfang(seat) then
      Tokens.create(seat, { pt = "1/1", words = { "squirrel" }, colors = { G = true } }, 1, "Chatterfang", { noChatter = true })
    end
  end
  local pos = obj.getPosition()
  local s = TableSetup.seat(seat)
  local c = obj.clone({ position = { x = pos.x + s.right.x * 3.2, y = pos.y + 0.6, z = pos.z + s.right.z * 3.2 } })
  if c == nil then
    broadcastToColor(srcName .. ": couldn't copy " .. obj.getName() .. " - make the token copy yourself.", seat, INFO)
    return nil
  end
  c.addTag("Token")
  c.memo = ""
  Zones.presetFrom(c, seat)
  Wait.time(function()
    if c.isDestroyed() then
      return
    end
    Zones.refresh(c)
    Counters.setup(c)
    if a.haste and Counters.addTempKeyword then
      Counters.addTempKeyword(c, "haste")
    end
    Counters.render(c)
  end, 0.7)
  if a.endHow then
    Effects.addDelayed({ seat = seat, anySeat = true, step = "end", kind = "removeCard", guid = c.getGUID(), how = a.endHow, name = srcName })
  end
  printToAll("MTG > " .. srcName .. ": " .. seat .. " makes a token copy of " .. obj.getName()
    .. (a.haste and " with haste" or "") .. (a.endHow and (" (" .. a.endHow .. "d at the next end step)") or "") .. ".", GOOD)
  return c
end

function Effects.copyCreature(seat, a, it)
  local function filter(obj, owner)
    if owner ~= seat or not Effects.cardTypes(obj).creature then
      return false
    end
    if a.nonlegendary then
      local d = {}
      pcall(function() d = JSON.decode(obj.getGMNotes()) or {} end)
      if tostring(d.typeLine or ""):find("Legendary", 1, true) then
        return false
      end
    end
    return true
  end
  local picked = {}
  local function askNext()
    ask(seat, it.name .. ": copy which creature?", (a.many and "Click COPY on each creature you want a copy of, then DONE." or "Click COPY on the creature.")
      .. (a.nonlegendary and " (nonlegendary)" or ""),
      { { label = a.many and "DONE" or "SKIP", value = false } }, function(obj)
        if obj then
          Effects.copyCard(obj, seat, a, it.name)
          if a.many then
            askNext()
          end
        end
      end, { filter = filter, label = "COPY" })
  end
  askNext()
end

-- Does `seat` control a permanent whose type line has this word (Horse, Soldier, Goblin...)?
function Effects.controlsWord(seat, word, name)
  word = tostring(word):lower()
  local singular = word:gsub("s$", "")
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and Effects.fieldSeat(obj) == seat then
      local d = {}
      pcall(function() d = JSON.decode(obj.getGMNotes()) or {} end)
      local tl = tostring(d.typeLine or ""):lower()
      if tl:find(word, 1, true) or tl:find(singular, 1, true) then
        return true
      end
    end
  end
  return false
end

-- All the players still in the game, starting with `seat` (for "each player" effects).
local function orderFrom(seat)
  local all = players()
  local out, start = {}, 1
  for i, c in ipairs(all) do
    if c == seat then
      start = i
    end
  end
  for k = 0, #all - 1 do
    table.insert(out, all[((start - 1 + k) % #all) + 1])
  end
  return out
end
Effects.orderFrom = orderFrom

-- "Each opponent sacrifices N creatures": each victim picks their own.
function Effects.edict(seat, a, it)
  local victims = {}
  local function others()
    for _, c in ipairs(players()) do
      if c ~= seat then
        table.insert(victims, c)
      end
    end
  end
  local function run()
    local function nextVictim(i)
      local v = victims[i]
      if v == nil then
        return
      end
      local function eligible()
        local n = 0
        for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
          if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and Effects.fieldSeat(obj) == v then
            local ty = Effects.cardTypes(obj)
            local isTok = obj.hasTag("Token")
            if (a.ty == "permanent" or ty[a.ty] == true) and not (a.tokenMode == "token" and not isTok)
                and not (a.tokenMode == "nontoken" and isTok) then
              n = n + 1
            end
          end
        end
        return n
      end
      local function pickOne(k)
        if k > a.n then
          nextVictim(i + 1)
          return
        end
        if eligible() == 0 then
          printToAll("MTG > " .. v .. " has no " .. a.ty .. (k == 1 and "" or " left") .. " to sacrifice (" .. it.name .. ").", INFO)
          nextVictim(i + 1)
          return
        end
        ask(v, it.name .. ": sacrifice a " .. a.ty .. (a.n > 1 and (" (" .. k .. " of " .. a.n .. ")") or ""),
          it.name .. " makes you sacrifice " .. a.n .. " " .. a.ty .. (a.n == 1 and "" or "s") .. ". Click SACRIFICE on one"
          .. " of yours (or NONE if you have no more).",
          { { label = "NONE", value = false } }, function(obj)
            if obj then
              printToAll("MTG > " .. v .. " sacrifices " .. obj.getName() .. " (" .. it.name .. ").", GOOD)
              Combat.removeCard(obj, "graveyard")
              pickOne(k + 1)
            else
              nextVictim(i + 1)
            end
          end, { filter = function(obj, owner)
            if owner ~= v then
              return false
            end
            local ty = Effects.cardTypes(obj)
            local isTok = obj.hasTag("Token")
            if a.tokenMode == "token" and not isTok then
              return false
            end
            if a.tokenMode == "nontoken" and isTok then
              return false
            end
            return a.ty == "permanent" or ty[a.ty] == true
          end, label = "SACRIFICE", protect = false })
      end
      pickOne(1)
    end
    nextVictim(1)
  end
  if a.scope == "each opponent" then
    others()
    run()
  elseif a.scope == "each player" then
    victims = orderFrom(seat)
    run()
  elseif a.scope == "that player" or a.scope == "defending player" then
    victims = { it.that or seat }
    run()
  else
    local choices = {}
    for _, c in ipairs(players()) do
      if not (a.scope == "target opponent" and c == seat) then
        table.insert(choices, { label = string.upper(c), value = c })
      end
    end
    ask(seat, it.name .. ": which player?", "Choose the player who sacrifices.", choices, function(c)
      victims = { c }
      run()
    end)
  end
end

-- Avenger of Zendikar / Kalonian Hydra: counters on every matching creature you control.
function Effects.counterAll(seat, a, it)
  local n = 0
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and Effects.fieldSeat(obj) == seat
        and Effects.cardTypes(obj).creature and not (a.other and it.source and obj.getGUID() == it.source) then
      local ok = true
      if a.word then
        local d = {}
        pcall(function() d = JSON.decode(obj.getGMNotes()) or {} end)
        local tl = " " .. tostring(d.typeLine or ""):lower():gsub("[^%a]", " ") .. " "
        ok = tl:find(" " .. a.word .. " ", 1, true) ~= nil
      end
      if ok then
        local amt = a.n
        if a.mode == "double" then
          amt = Counters.get(obj).plus
        end
        if amt > 0 then
          Counters.place(obj, "plus", amt, seat)
          n = n + 1
        end
      end
    end
  end
  printToAll("MTG > " .. it.name .. ": " .. (a.mode == "double" and "doubled the +1/+1 counters on " or "+1/+1 counter on ") .. n .. " creature(s).", GOOD)
end

-- Populate: a token copy of a creature token you control.
function Effects.populate(seat, it)
  ask(seat, it.name .. ": populate", "Click COPY on a creature token you control.", { { label = "SKIP", value = false } }, function(obj)
    if obj then
      Effects.copyCard(obj, seat, {}, it.name)
    end
  end, { filter = function(obj, owner)
    return owner == seat and obj.hasTag("Token") and Effects.cardTypes(obj).creature == true
  end, label = "COPY" })
end

-- Proliferate: click every permanent that should get another counter of each kind it has, then DONE.
function Effects.proliferate(seat, it)
  local chosen = {}
  local function hasAny(obj)
    local c = Counters.get(obj)
    return (c.plus or 0) > 0 or (c.minus or 0) > 0 or (c.loyalty or 0) > 0 or (c.other or 0) > 0
  end
  local function step()
    ask(seat, it.name .. ": proliferate", "Click PROLIFERATE on each permanent with counters you want another counter on, then DONE."
      .. " (Players with poison or other counters: do those by hand.)", { { label = "DONE", value = false } }, function(obj)
      if obj then
        chosen[obj.getGUID()] = true
        for _, kind in ipairs({ "plus", "minus", "loyalty", "other" }) do
          if (Counters.get(obj)[kind] or 0) > 0 then
            Counters.place(obj, kind, 1, seat)
          end
        end
        printToAll("MTG > " .. it.name .. ": proliferate " .. obj.getName() .. ".", GOOD)
        step()
      else
        printToAll("MTG > " .. it.name .. ": proliferate done.", INFO)
      end
    end, { filter = function(obj, owner)
      return owner ~= nil and not chosen[obj.getGUID()] and hasAny(obj)
    end, label = "PROLIFERATE", protect = false })
  end
  step()
end

-- Springheart Nantuko landfall.
function Effects.nantuko(seat, it)
  local src = it.source and getObjectFromGUID(it.source)
  local host = src and not src.isDestroyed() and Equip and Equip.hostOf and Equip.hostOf(src) or nil
  local function insect()
    printToAll("MTG > " .. it.name .. ": a 1/1 Insect instead.", INFO)
    Tokens.create(seat, { pt = "1/1", words = { "insect" }, colors = { G = true } }, 1, it.name)
  end
  if host and not host.isDestroyed() and Effects.fieldSeat(host) == seat then
    ask(seat, it.name .. ": pay {1}?", "Pay {1} to create a token copy of " .. host.getName() .. "? (If you don't, you get a 1/1 Insect.)",
      { { label = "PAY {1}", value = true }, { label = "NO", value = false } }, function(yes)
        if yes then
          Effects.copyCard(host, seat, {}, it.name)
        else
          insect()
        end
      end)
  else
    insect()
  end
end

-- Sephiroth: sacrifice other creatures you control (one, or any number), then draw that many cards.
function Effects.sacDraw(seat, a, it)
  local done = 0
  local function step()
    if done >= a.max then
      return Effects.sacDrawEnd(seat, done, it)
    end
    ask(seat, it.name .. ": sacrifice a creature?",
      (a.max == 1 and "You may sacrifice another creature to draw a card." or "Sacrifice other creatures, one at a time; you draw that many cards when you press DONE.")
      .. " Click SACRIFICE on one of yours" .. (done > 0 and (" (" .. done .. " so far)") or "") .. ".",
      { { label = done > 0 and "DONE" or "NO", value = false } }, function(obj)
        if obj then
          printToAll("MTG > " .. seat .. " sacrifices " .. obj.getName() .. " (" .. it.name .. ").", GOOD)
          Combat.removeCard(obj, "graveyard")
          done = done + 1
          step()
        else
          Effects.sacDrawEnd(seat, done, it)
        end
      end, { filter = function(obj, owner)
        if owner ~= seat or (it.source and (obj == it.source or obj.getGUID() == it.source)) then
          return false
        end
        return Effects.cardTypes(obj).creature == true
      end, label = "SACRIFICE", protect = false })
  end
  step()
end

function Effects.sacDrawEnd(seat, n, it)
  if n > 0 then
    Actions.draw(seat, n, it.name)
  else
    printToAll("MTG > " .. it.name .. ": nothing sacrificed, no cards drawn.", INFO)
  end
end

-- Invoke Despair: the opponent sacrifices a creature, then an enchantment, then a planeswalker.
-- Each one they can't sacrifice: they lose 2 life and the caster draws a card.
function Effects.despair(caster, victim, it)
  local types = { "creature", "enchantment", "planeswalker" }
  local function eligible(ty)
    local n = 0
    for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
      if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and Effects.fieldSeat(obj) == victim
          and Effects.cardTypes(obj)[ty] == true then
        n = n + 1
      end
    end
    return n
  end
  local function step(i)
    local ty = types[i]
    if ty == nil then
      return
    end
    if eligible(ty) == 0 then
      printToAll("MTG > " .. it.name .. ": " .. victim .. " has no " .. ty .. " to sacrifice: loses 2 life, " .. caster .. " draws a card.", GOOD)
      Trackers.changeLife(victim, -2, it.name)
      Actions.draw(caster, 1, it.name)
      step(i + 1)
      return
    end
    local art = (ty == "enchantment") and "an " or "a "
    ask(victim, it.name .. ": sacrifice " .. art .. ty, caster .. "'s " .. it.name .. " makes you sacrifice " .. art .. ty .. " (" .. i .. " of 3). Click SACRIFICE on one of yours.",
      {}, function(obj)
        if obj then
          printToAll("MTG > " .. victim .. " sacrifices " .. obj.getName() .. " (" .. it.name .. ").", GOOD)
          Combat.removeCard(obj, "graveyard")
        end
        step(i + 1)
      end, { filter = function(obj, owner)
        return owner == victim and Effects.cardTypes(obj)[ty] == true
      end, label = "SACRIFICE", protect = false })
  end
  step(1)
end

-- Dark Confidant: the top card goes to your hand face up, you lose life equal to its mana value.
function Effects.bob(seat, it)
  local lib = Library.find(seat)
  if lib == nil then
    printToAll("MTG > " .. it.name .. ": " .. seat .. "'s library is empty.", INFO)
    return
  end
  local s = TableSetup.seat(seat)
  local hand = Player[seat].getHandTransform()
  local function got(card)
    local mv = 0
    pcall(function() mv = tonumber(JSON.decode(card.getGMNotes()).cmc) or 0 end)
    broadcastToAll(it.name .. ": " .. seat .. " reveals " .. card.getName() .. " (mana value " .. mv .. ")"
      .. (mv > 0 and (" and loses " .. mv .. " life.") or "."), { 1, 0.85, 0.3 })
    if mv > 0 then
      Trackers.changeLife(seat, -mv, it.name)
    end
  end
  if lib.type == "Deck" then
    lib.takeObject({ index = 0, position = hand.position, rotation = { 0, s.yaw, 0 }, smooth = true, callback_function = got })
  else
    lib.setPositionSmooth(hand.position)
    got(lib)
  end
end

-- Castle Locthwain: draw a card, then lose life equal to the number of cards in your hand.
function Effects.drawHandLife(seat, it)
  Library.draw(seat, 1, function(drawn)
    Wait.time(function()
      local n = 0
      for _, o in ipairs(Player[seat].getHandObjects() or {}) do
        if o.type == "Card" then
          n = n + 1
        end
      end
      printToAll("MTG > " .. it.name .. ": " .. seat .. " has " .. n .. " card" .. (n == 1 and "" or "s") .. " in hand.", INFO)
      if n > 0 then
        Trackers.changeLife(seat, -n, it.name)
      end
    end, 1.2)
  end)
end

-- Reanimate, Virtue of Persistence: pick a graveyard, then the creature card in it.
function Effects.reanimate(seat, a, it)
  local choices = {}
  for _, c in ipairs(players()) do
    table.insert(choices, { label = string.upper(c) .. "'S YARD", value = c })
  end
  ask(seat, it.name .. ": which graveyard?", "Put a creature card from a graveyard onto the battlefield under your control.", choices, function(yard)
    LibSearch.open(seat, "creature", it.name .. ": click the creature card in " .. yard .. "'s graveyard to put it onto the battlefield under your control, then CLOSE.",
      "battlefield", false, { typeOnly = true, zone = "graveyard", yardOf = yard,
        onTake = a.loseMV and function(card)
          local mv = 0
          pcall(function() mv = tonumber(JSON.decode(card.getGMNotes()).cmc) or 0 end)
          printToAll("MTG > " .. it.name .. ": " .. seat .. " loses " .. mv .. " life (" .. card.getName() .. " has mana value " .. mv .. ").", GOOD)
          if mv > 0 then
            Trackers.changeLife(seat, -mv, it.name)
          end
        end or nil })
  end)
end

-- Palantir of Orthanc: influence counter, scry 2, then a target opponent chooses.
function Effects.palantir(seat, it)
  local src = it.source and getObjectFromGUID(it.source)
  local counters = 0
  if src and not src.isDestroyed() then
    Counters.change(src, "other", 1, seat)
    counters = Counters.get(src).other or 0
  else
    printToAll("MTG > " .. it.name .. " isn't on the table: count its influence counters by hand.", INFO)
  end
  Actions.openScry(seat)
  Actions.openScry(seat)
  local function opponentChooses(opp)
    ask(opp, it.name .. " (" .. seat .. ")", seat .. " has " .. counters .. " influence counter" .. (counters == 1 and "" or "s")
      .. ". Let " .. seat .. " draw a card, or they mill " .. counters .. " and you lose life equal to the total mana value of what they mill?",
      { { label = "LET THEM DRAW", value = true }, { label = "MILL " .. counters .. ", I LOSE LIFE", value = false } }, function(draw)
        if draw then
          printToAll("MTG > " .. opp .. " lets " .. seat .. " draw a card (" .. it.name .. ").", INFO)
          Actions.draw(seat, 1, it.name)
          return
        end
        local total = 0
        local lib = Library.find(seat)
        if lib and lib.type == "Deck" then
          local entries = lib.getData().ContainedObjects or {}
          for i = 1, math.min(counters, #entries) do
            local mv = 0
            pcall(function() mv = tonumber(JSON.decode(entries[i].GMNotes).cmc) or 0 end)
            total = total + mv
          end
        end
        printToAll("MTG > " .. seat .. " mills " .. counters .. " (" .. it.name .. "): " .. opp .. " loses " .. total .. " life.", GOOD)
        Actions.mill(seat, counters)
        if total > 0 then
          Trackers.changeLife(opp, -total, it.name)
        end
      end)
  end
  local opps = {}
  for _, c in ipairs(players()) do
    if c ~= seat then
      table.insert(opps, c)
    end
  end
  if #opps == 0 then
    return
  elseif #opps == 1 then
    opponentChooses(opps[1])
  else
    local choices = {}
    for _, c in ipairs(opps) do
      table.insert(choices, { label = string.upper(c), value = c })
    end
    ask(seat, it.name .. ": target opponent", "Choose the opponent who decides.", choices, opponentChooses)
  end
end

-- Thoughtseize, Inquisition of Kozilek, Duress: `target` shows their hand to `caster`, who picks the card.
function Effects.handPick(caster, target, a, it)
  local function pred(d)
    local types = {}
    for _, ty in ipairs(type(d.types) == "table" and d.types or {}) do
      types[tostring(ty):lower()] = true
    end
    local tl = tostring(d.typeLine or ""):lower()
    local isLand = types.land or tl:find("land", 1, true) ~= nil
    local isCreature = types.creature or tl:find("creature", 1, true) ~= nil
    if a.nonland and isLand then
      return false
    end
    if a.noncreature and isCreature then
      return false
    end
    if a.mvMax and (tonumber(d.cmc) or 0) > a.mvMax then
      return false
    end
    return true
  end
  local hint = (a.noncreature and "a noncreature, " or "a ") .. (a.nonland and "nonland " or "") .. "card"
    .. (a.mvMax and (" with mana value " .. a.mvMax .. " or less") or "")
  Actions.chooseFromHand(caster, target, it.name, pred, hint, nil)
end

-- Windfall: everyone discards their hand, then draws as many cards as the most anyone discarded.
function Effects.windfall(it, fixed)
  local most = 0
  for _, c in ipairs(players()) do
    local n = Actions.discardHand(c, it.name) or 0
    if n > most then
      most = n
    end
  end
  if fixed then
    most = fixed
    printToAll("MTG > " .. it.name .. ": everyone discards their hand and draws " .. fixed .. ".", GOOD)
  else
    printToAll("MTG > " .. it.name .. ": the most discarded was " .. most .. ": everyone draws " .. most .. ".", GOOD)
  end
  if most > 0 then
    Wait.time(function()
      for _, c in ipairs(players()) do
        Actions.draw(c, most, it.name)
      end
    end, 1.2)
  end
end

-- Warstorm Surge: damage equal to the entering creature's power, to any target.
function Effects.powerHit(seat, a, it)
  local function go(n)
    local choices = {}
    for _, c in ipairs(players()) do
      table.insert(choices, { label = string.upper(c), value = c })
    end
    table.insert(choices, { label = "CREATURE", value = "other" })
    table.insert(choices, { label = "SKIP", value = false })
    while #choices > MAX_CHOICES do
      table.remove(choices, #choices - 2)
    end
    ask(seat, it.name .. ": " .. n .. " damage to any target", "The creature's power is " .. n .. ". Pick who takes it.", choices, function(target)
      if target == "other" then
        printToAll("MTG > " .. it.name .. ": " .. n .. " damage to a creature or planeswalker: change its damage / loyalty by hand.", INFO)
      elseif target then
        Trackers.changeLife(target, -n, it.name)
        printToAll("MTG > " .. it.name .. " deals " .. n .. " damage to " .. target .. ".", GOOD)
      else
        printToAll("MTG > " .. it.name .. ": skipped.", INFO)
      end
    end)
  end
  local obj = it.thatCard and getObjectFromGUID(it.thatCard)
  if obj and not obj.isDestroyed() then
    go(tonumber(Counters.stats(obj).power or "") or 0)
  else
    Effects.askNumber(seat, it.name .. ": power?", "Type the creature's power, then OK.", go)
  end
end

-- Metalworker, Nykthos: the player says how many; the table adds that much mana.
function Effects.manaAsk(seat, a, it)
  local function howMany(color)
    Effects.askNumber(seat, it.name .. ": how many (" .. a.label .. ")?", "Type the number, then OK.", function(n)
      local total = n * (a.per or 1)
      if total > 0 then
        ManaChips.add(seat, color, total)
        printToAll("MTG > " .. it.name .. ": " .. seat .. " adds " .. total .. " {" .. color .. "}.", GOOD)
      end
    end)
  end
  if a.pickColor then
    local choices = {}
    for _, c in ipairs({ "W", "U", "B", "R", "G" }) do
      table.insert(choices, { label = c, value = c })
    end
    ask(seat, it.name .. ": which color?", "Choose a color; then say your devotion to it.", choices, howMany)
  else
    howMany(a.color)
  end
end

-- A token copy of "that artifact" / "enchanted artifact" / "equipped creature".
-- Sylvan Library.
function Effects.sylvan(seat, it)
  Effects.askChoice(seat, it.name .. ": draw two additional cards?", "You may draw two extra cards now. Then, for each of two cards you drew this turn, pay 4 life or put it on top of your library.",
    { { label = "DRAW 2", value = true }, { label = "NO", value = false } }, function(yes)
      if not yes then
        printToAll("MTG > " .. seat .. " doesn't draw extra cards (" .. it.name .. ").", INFO)
        return
      end
      Actions.draw(seat, 2, it.name)
      Wait.time(function()
        Effects.askChoice(seat, it.name .. ": pay 4 life for how many of two cards?",
          "Choose two cards you drew this turn. Each one: pay 4 life to keep it, or put it back on top of your library. How many do you pay for?",
          { { label = "PAY FOR 2", value = 2 }, { label = "PAY FOR 1", value = 1 }, { label = "PAY FOR 0", value = 0 } }, function(k)
            if k > 0 then
              Trackers.changeLife(seat, -4 * k, it.name)
            end
            local back = 2 - k
            if back > 0 then
              Actions.forceDiscard(seat, back, it.name, nil, "top")
            end
          end)
      end, 2.5)
    end)
end

-- Jeska's Will.
function Effects.jeska(seat, a, it)
  local function mana()
    local opps = {}
    for _, c in ipairs(players()) do
      if c ~= seat then
        table.insert(opps, c)
      end
    end
    local function give(opp)
      local n = 0
      pcall(function() n = #Player[opp].getHandObjects() end)
      Effects.askNumber(seat, it.name .. ": cards in " .. opp .. "'s hand?", "Type how many cards " .. opp .. " has in hand (counted: " .. n .. "), then OK. You add that much {R}.", function(k)
        local amount = tonumber(k) or 0
        if amount > 0 then
          ManaChips.add(seat, "R", amount)
        end
        printToAll("MTG > " .. it.name .. ": " .. seat .. " adds " .. amount .. " {R}.", GOOD)
      end)
    end
    if #opps == 1 then
      give(opps[1])
      return
    end
    local choices = {}
    for _, c in ipairs(opps) do
      table.insert(choices, { label = string.upper(c), value = c })
    end
    Effects.askChoice(seat, it.name .. ": which opponent?", "Add {R} for each card in that opponent's hand.", choices, give)
  end
  local function exile3()
    local left = 3
    local names = {}
    local function nxt()
      if left == 0 then
        printToAll("MTG > " .. it.name .. ": " .. seat .. " exiled " .. table.concat(names, ", ") .. " and may play them this turn (they wait in exile).", GOOD)
        broadcastToColor("You may play " .. table.concat(names, ", ") .. " from exile this turn.", seat, GOOD)
        return
      end
      left = left - 1
      Library.exileUntilNonland(seat, true, function(card)
        table.insert(names, card and card.getName() or "a card")
        nxt()
      end)
    end
    nxt()
  end
  local commander = false
  for _, o in ipairs(getObjectsWithTag("MTGCard")) do
    if o.type == "Card" and Combat and Combat.isCommander and Combat.isCommander(o) and Effects.fieldSeat(o) == seat then
      commander = true
    end
  end
  local choices = { { label = "RED MANA", value = "mana" }, { label = "EXILE 3", value = "exile" } }
  if commander then
    table.insert(choices, { label = "BOTH", value = "both" })
  end
  Effects.askChoice(seat, it.name .. ": choose one" .. (commander and " (or both: you control a commander)" or ""),
    "{R} for each card in target opponent's hand, or exile the top three cards of your library and play them this turn.", choices, function(m)
      if m == "mana" or m == "both" then mana() end
      if m == "exile" or m == "both" then
        if m == "both" then Wait.time(exile3, 1.5) else exile3() end
      end
    end)
end

function Effects.arcum(seat, it)
  ask(seat, it.name .. ": sacrifice which artifact creature?", "Click SACRIFICE on the target artifact creature (anyone's). Its controller then searches.",
    { { label = "SKIP", value = false } }, function(obj)
      if not obj or obj.isDestroyed() then
        return
      end
      local owner = Effects.fieldSeat(obj) or seat
      local mv = 0
      pcall(function() mv = tonumber(JSON.decode(obj.getGMNotes()).cmc) or 0 end)
      local name = obj.getName()
      printToAll("MTG > " .. it.name .. ": " .. owner .. " sacrifices " .. name .. " (mana value " .. mv .. ").", GOOD)
      Combat.removeCard(obj, "graveyard")
      Wait.time(function()
        LibSearch.open(owner, "artifact", it.name .. ": " .. owner .. " may take a NONCREATURE artifact with mana value " .. (mv + 1)
          .. " (1 plus " .. name .. "'s) onto the battlefield, then CLOSE + SHUFFLE.", "battlefield", false,
          { typeOnly = true, mvMin = mv + 1, mvMax = mv + 1 })
      end, 1.0)
    end, { filter = function(obj, owner)
      local ty = Effects.cardTypes(obj)
      return ty.artifact == true and ty.creature == true
    end, label = "SACRIFICE", protect = false })
end

function Effects.copyThat(seat, a, it)
  local src = it.source and getObjectFromGUID(it.source)
  local function target()
    if a.which:find("^that") then
      return it.thatCard and getObjectFromGUID(it.thatCard)
    end
    if src and not src.isDestroyed() and Equip and Equip.hostOf then
      return Equip.hostOf(src)
    end
  end
  local function go()
    local obj = target()
    if obj and not obj.isDestroyed() then
      Effects.copyCard(obj, seat, { haste = a.haste }, it.name)
    else
      broadcastToColor(it.name .. ": make the token copy yourself (" .. a.which .. " wasn't found).", seat, INFO)
    end
  end
  if a.pay then
    ask(seat, it.name .. ": pay " .. a.pay .. "?", "Pay " .. a.pay .. " to create a token copy of " .. a.which .. "?",
      { { label = "PAY", value = true }, { label = "NO", value = false } }, function(yes)
        if yes then
          go()
        else
          printToAll("MTG > " .. seat .. " doesn't pay: no copy (" .. it.name .. ").", INFO)
        end
      end)
  else
    go()
  end
end

-- Tap or untap permanents.
local function turnTapped(obj, owner, tapped)
  local s = TableSetup.seat(owner)
  if s == nil then
    return
  end
  local r = obj.getRotation()
  obj.setRotationSmooth({ r.x, tapped and (s.yaw + 90) % 360 or s.yaw, r.z }, false, true)
end

function Effects.tapX(seat, a, it)
  local want = a.mode == "tap"
  local function kindOk(obj)
    local ty = Effects.cardTypes(obj)
    if a.kinds.permanent then
      return true
    end
    return (a.kinds.creature and ty.creature) or (a.kinds.artifact and ty.artifact) or (a.kinds.land and ty.land)
      or (a.kinds.enchantment and ty.enchantment) or (a.kinds.planeswalker and ty.planeswalker)
      or (a.kinds.nonland and not ty.land) or false
  end
  local function scopeOk(owner)
    if a.scope == "mine" and owner ~= seat then
      return false
    elseif a.scope == "opponents" and owner == seat then
      return false
    end
    return true
  end
  if a.self then
    local src = it.source and getObjectFromGUID(it.source)
    if src and not src.isDestroyed() then
      turnTapped(src, Effects.fieldSeat(src) or seat, want)
      printToAll("MTG > " .. it.name .. ": " .. src.getName() .. (want and " is tapped." or " is untapped."), GOOD)
    else
      broadcastToColor(it.name .. ": " .. a.mode .. " it yourself.", seat, INFO)
    end
    return
  end
  if a.all then
    local n = 0
    for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
      if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) then
        local owner = Effects.fieldSeat(obj)
        if owner and scopeOk(owner) and kindOk(obj) then
          turnTapped(obj, owner, want)
          n = n + 1
        end
      end
    end
    printToAll("MTG > " .. it.name .. ": " .. n .. " permanent" .. (n == 1 and "" or "s") .. (want and " tapped." or " untapped."), GOOD)
    return
  end
  local done = {}
  local function step(k)
    if k > (a.count or 1) then
      return
    end
    ask(seat, it.name .. ": " .. a.mode .. " which?" .. (a.count > 1 and (" (" .. k .. " of " .. a.count .. ")") or ""),
      "Click " .. string.upper(a.mode) .. " on the permanent" .. (a.upTo and ", or SKIP." or "."),
      { { label = a.upTo and "DONE" or "SKIP", value = false } }, function(obj)
        if obj then
          done[obj.getGUID()] = true
          turnTapped(obj, Effects.fieldSeat(obj) or seat, want)
          printToAll("MTG > " .. it.name .. ": " .. obj.getName() .. (want and " is tapped." or " is untapped."), GOOD)
          step(k + 1)
        end
      end, { filter = function(obj, owner)
        return scopeOk(owner) and kindOk(obj) and not done[obj.getGUID()]
          and not (a.other and it.source and obj.getGUID() == it.source)
      end, label = string.upper(a.mode), protect = want })
  end
  step(1)
end

-- "...enters the battlefield as a copy of any artifact": the card becomes a token copy of the permanent you pick
-- (the real card waits beside the table); when the copy leaves, the real card goes where it went.
function Effects.cloneEnter(card, seat, kinds)
  local label = (kinds.artifact and kinds.creature) and "artifact or creature" or (kinds.artifact and "artifact")
    or (kinds.creature and "creature") or "permanent"
  ask(seat, card.getName() .. ": copy which " .. label .. "?",
    "Click COPY on the " .. label .. " it enters as a copy of, or SKIP to keep it as it is.",
    { { label = "SKIP", value = false } }, function(obj)
      if not obj or card.isDestroyed() then
        return
      end
      local pos = card.getPosition()
      local c = obj.clone({ position = { x = pos.x, y = pos.y + 0.6, z = pos.z } })
      if c == nil then
        broadcastToColor(card.getName() .. ": couldn't copy " .. obj.getName() .. " - make the copy yourself.", seat, INFO)
        return
      end
      c.addTag("Token")
      c.memo = ""
      c.setRotation({ 0, TableSetup.seat(seat).yaw, 0 })
      Zones.presetFrom(c, seat)
      GameState.data.clones = GameState.data.clones or {}
      GameState.data.clones[c.getGUID()] = { real = card.getGUID(), seat = seat, name = card.getName() }
      card.setPosition(TableSetup.slot(seat, "act_tokens", TableSetup.SURFACE_TOP + 1.5))
      Wait.time(function()
        if not c.isDestroyed() then
          Zones.refresh(c)
          Counters.setup(c)
        end
      end, 0.7)
      printToAll("MTG > " .. card.getName() .. " enters as a copy of " .. obj.getName() .. ".", GOOD)
    end, { filter = function(obj, owner)
      if obj.getGUID() == card.getGUID() then
        return false
      end
      local ty = Effects.cardTypes(obj)
      if kinds.artifact and ty.artifact then
        return true
      end
      if kinds.creature and ty.creature then
        return true
      end
      return kinds.permanent == true
    end, label = "COPY", protect = false })
end

-- The copy left the battlefield: the real card goes to the same place.
function Effects.cloneLeft(card, seat, dest)
  local cl = GameState.data and GameState.data.clones
  local rec = cl and card and cl[card.getGUID()]
  if not rec then
    return false
  end
  cl[card.getGUID()] = nil
  local real = getObjectFromGUID(rec.real)
  if real == nil or real.isDestroyed() then
    return true
  end
  dest = dest or "graveyard"
  local owner = rec.seat
  real.setLock(false)
  real.setRotation({ 0, TableSetup.seat(owner).yaw, 0 })
  if dest == "hand" then
    real.setPositionSmooth(Player[owner].getHandTransform().position, false, true)
  else
    real.setPosition(TableSetup.slot(owner, dest, TableSetup.SURFACE_TOP + 2))
    Zones.refresh(real)
    if dest == "graveyard" then
      Library.toGraveyard(owner, real, function()
        if not real.isDestroyed() then
          Zones.refresh(real)
        end
      end)
    end
  end
  printToAll("MTG > " .. rec.name .. " (the copy) left: the card goes to " .. owner .. "'s " .. dest .. ".", INFO)
  return true
end

-- A card that says "enter(s) the battlefield as a copy of..." asks what to copy as it arrives.
Events.on("cardMoved", function(d)
  if d.card == nil or d.to == nil or d.from == nil or not GameState.data or not GameState.data.started then
    return
  end
  local IN = { battlefield = true, lands = true }
  if IN[d.to.region] and not IN[d.from.region] and d.to.seat and not d.card.hasTag("Token") then
    local dd = {}
    pcall(function() dd = JSON.decode(d.card.getGMNotes()) or {} end)
    local o = tostring(dd.oracle or ""):lower()
    local at = o:find("as a copy of any ", 1, true)
    if at and not o:find("until end of turn", 1, true) and (o:find("enter", 1, true) or 0) < at then
      local seg = o:sub(at, at + 60)
      local kinds = {}
      if seg:find("artifact", 1, true) then kinds.artifact = true end
      if seg:find("creature", 1, true) then kinds.creature = true end
      if seg:find("permanent", 1, true) then kinds.permanent = true end
      if next(kinds) then
        Effects.cloneEnter(d.card, d.to.seat, kinds)
      end
    end
  end
  -- A copy dragged off the battlefield by hand.
  if IN[d.from.region] and not IN[d.to.region] and GameState.data.clones and GameState.data.clones[d.card.getGUID()] then
    local z = d.to.region
    if z == "graveyard" or z == "exile" or z == "hand" or z == "library" then
      Effects.cloneLeft(d.card, d.from.seat, z)
    end
  end
end)

-- "Until your next turn" protection ends when their turn begins.
Events.on("stepStarted", function(d)
  local pro = GameState.data and GameState.data.playerPro
  if pro and pro[d.seat] and (d.step == "untap" or d.step == "upkeep") then
    pro[d.seat] = nil
    printToAll("MTG > " .. d.seat .. "'s protection from everything ends.", INFO)
  end
end)

-- Put an exiled card back onto the battlefield (a real move, so enters triggers fire).
function Effects.returnFromExile(guid, owner, why)
  local obj = getObjectFromGUID(guid)
  if obj == nil or obj.isDestroyed() then
    return
  end
  local seat = owner or Effects.fieldSeat(obj) or Zones.regionAt(obj.getPosition()).seat
  if seat == nil or not TableSetup.isActive(seat) then
    return
  end
  local land = Effects.cardTypes(obj).land
  obj.setLock(false)
  obj.setRotation({ 0, TableSetup.seat(seat).yaw, 0 })
  obj.setPosition(TableSetup.slot(seat, land and "lands" or "battlefield", TableSetup.SURFACE_TOP + 2))
  printToAll("MTG > " .. obj.getName() .. " returns to the battlefield" .. (why and (" (" .. why .. ")") or "") .. ".", GOOD)
  Wait.time(function()
    if not obj.isDestroyed() then
      Zones.refresh(obj)
      Counters.setup(obj)
    end
  end, 0.8)
end

-- "...until ~ leaves the battlefield": when it leaves, what it exiled comes back.
Events.on("cardMoved", function(d)
  if d.card == nil or d.from == nil or not (d.from.region == "battlefield" or d.from.region == "lands") then
    return
  end
  if d.to and (d.to.region == "battlefield" or d.to.region == "lands") then
    return
  end
  local held = GameState.data and GameState.data.heldExile
  local g = d.card.getGUID()
  if held and held[g] then
    local list = held[g]
    held[g] = nil
    for _, h in ipairs(list) do
      Effects.returnFromExile(h.guid, h.owner, d.name or "its exiler left")
    end
  end
end)

-- Delayed effects come due when their step starts.
Events.on("stepStarted", function(d)
  if not enabled() or not GameState.data.started then
    return
  end
  local list = delayedList()
  for i = #list, 1, -1 do
    local r = list[i]
    if (r.seat == d.seat or r.anySeat) and (r.step == d.step or (r.step == "main" and (d.step == "main1" or d.step == "main2"))) then
      table.remove(list, i)
      if r.kind == "returnCard" then
        Effects.returnFromExile(r.guid, r.owner, r.name)
      elseif r.kind == "nikoEnd" then
        for _, g in ipairs(r.clones or {}) do
          local o = getObjectFromGUID(g)
          if o and not o.isDestroyed() then
            o.destruct()
          end
        end
        for _, s in ipairs(r.shards or {}) do
          local o = getObjectFromGUID(s.guid)
          if o and not o.isDestroyed() then
            o.setPosition(s.pos)
            o.setRotation(s.rot)
          end
        end
        printToAll("MTG > " .. r.name .. ": the Shards turn back.", GOOD)
        Effects.returnFromExile(r.ret, r.owner, r.name)
      elseif r.kind == "removeCard" then
        local obj = getObjectFromGUID(r.guid)
        if obj and not obj.isDestroyed() then
          printToAll("MTG > " .. r.name .. ": " .. obj.getName() .. " token copy is " .. r.how .. "d.", GOOD)
          if Combat and Combat.removeCard then
            Combat.removeCard(obj, r.how == "exile" and "exile" or "graveyard")
          else
            obj.destruct()
          end
        end
      elseif r.kind == "mana" then
        Wait.time(function()
          if r.amount > 0 then
            ManaChips.add(r.seat, r.color, r.amount)
          end
          printToAll("MTG > " .. r.name .. ": " .. r.seat .. " adds " .. r.amount .. " {" .. r.color .. "}.", GOOD)
          broadcastToColor(r.name .. ": " .. r.amount .. " colorless mana added (check the MANA tile).", r.seat, GOOD)
        end, 0.8)
      elseif r.kind == "pact" then
        Wait.time(function()
          ask(r.seat, r.name .. ": pay " .. r.cost .. "?", "Your upkeep: pay " .. r.cost .. " or lose the game.",
            { { label = "PAID", value = true }, { label = "CAN'T PAY", value = false } }, function(paid)
              if paid then
                printToAll("MTG > " .. r.seat .. " paid for " .. r.name .. ".", GOOD)
              else
                printToAll("MTG > " .. r.seat .. " did not pay for " .. r.name .. ".", { 1, 0.4, 0.4 })
                Trackers.flagLoss(r.seat, "didn't pay " .. r.cost .. " for " .. r.name)
              end
            end)
        end, 0.8)
      end
    end
  end
end)

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
  Effects.currentSource = it.source or it.card
  -- "Choose one —" with "• mode" lines: the controller picks a mode first.
  local raw = tostring(it.text or "")
  do
    local lowj = raw:lower()
    if lowj:find("add {r} for each card in target opponent's hand", 1, true) and lowj:find("exile the top three cards of your library", 1, true) then
      Effects.jeska(it.controller, {}, it)
      printToAll("MTG > " .. it.name .. " resolved: " .. it.controller .. " chooses.", INFO)
      return
    end
  end
  local bullet = raw:find("•", 1, true)
  -- Spree (Insatiable Avarice): "+ {2}{B} — Target player draws three cards..." lines are the modes.
  local spree = raw:lower():find("spree", 1, true) and raw:find("\n+ ", 1, true)
  if (bullet or spree) and not it.modePicked then
    local modes = {}
    if spree then
      for line in raw:gmatch("[^\n]+") do
        if line:sub(1, 2) == "+ " then
          local body = line:match("— (.*)$") or line:sub(3)
          local cost = line:match("^%+ ([^—]*)—") or ""
          cost = cost:gsub("%s+$", "")
          table.insert(modes, (body:gsub("%s+$", "")) .. (cost ~= "" and (" [pay " .. cost .. "]") or ""))
        end
      end
    else
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
    end
    -- "Choose one or more" / "any number" / Spree: a YES / NO for each mode, then all the chosen ones resolve.
    local lowRaw = raw:lower()
    if #modes > 0 and (spree or lowRaw:find("choose one or more", 1, true) or lowRaw:find("choose any number", 1, true)) then
      local chosen = {}
      local function step(i)
        if i > #modes then
          if #chosen == 0 then
            printToAll("MTG > " .. it.controller .. " chose no mode (" .. it.name .. ").", INFO)
            return
          end
          printToAll("MTG > " .. it.controller .. " chose: " .. table.concat(chosen, " + "), INFO)
          broadcastToAll(it.name .. " (" .. it.controller .. ") chose " .. #chosen .. " mode" .. (#chosen == 1 and "" or "s") .. ".", { 1, 0.85, 0.3 })
          for _, m in ipairs(chosen) do
            local copy = {}
            for k, v in pairs(it) do
              copy[k] = v
            end
            copy.text = (m:gsub(" %[pay [^%]]*%]$", ""))
            copy.modePicked = true
            Effects.resolve(copy)
          end
          return
        end
        ask(it.controller, it.name .. ": mode " .. i .. " of " .. #modes, modes[i],
          { { label = "USE IT", value = true }, { label = "SKIP IT", value = false } }, function(yes)
            if yes then
              table.insert(chosen, modes[i])
            end
            step(i + 1)
          end)
      end
      step(1)
      return
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
  if un and not it.unlessDone and not low:find("counter target", 1, true) then
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
  -- Pacts: "At the beginning of your next upkeep, pay {2}{G}{G}. If you don't, you lose the game."
  do
    local a1 = low:find("at the beginning of your next upkeep, pay ", 1, true)
    if a1 and not it.pactDone then
      local rest = raw:sub(a1 + #"at the beginning of your next upkeep, pay ")
      local cost = rest:match("^([{}%w/]+)")
      local stop = raw:find("lose the game.", a1, true)
      if cost and stop then
        Effects.addDelayed({ seat = it.controller, step = "upkeep", kind = "pact", cost = cost, name = it.name })
        printToAll("MTG > " .. it.name .. ": " .. it.controller .. " must pay " .. cost .. " at their next upkeep or lose the game.", { 1, 0.75, 0.3 })
        local copy = {}
        for k, v in pairs(it) do
          copy[k] = v
        end
        copy.text = (raw:sub(1, a1 - 1) .. raw:sub(stop + #"lose the game.")):gsub("%s+$", "")
        copy.pactDone = true
        it = copy
        raw = copy.text
        low = raw:lower()
      end
    end
  end
  -- "... for each burden counter on The One Ring": the table counts them.
  do
    local a1 = low:find(" for each ", 1, true)
    local a2 = a1 and low:find(" counter on ", a1, true)
    local src = it.source and getObjectFromGUID(it.source)
    local lk = it.source and Counters.lastKnown and Counters.lastKnown[it.source]
    if a1 and a2 and a2 - a1 < 30 and ((src and not src.isDestroyed()) or lk) and not it.countDone then
      local kindWord = low:sub(a1 + #" for each ", a2 - 1)
      local stopAt = raw:find("[%.,]", a2 + #" counter on ") or (#raw + 1)
      local c = (lk and it.trigger) and lk or Counters.get(src)
      local n = (kindWord == "+1/+1" and c.plus) or (kindWord == "-1/-1" and c.minus) or (kindWord == "loyalty" and c.loyalty) or c.other
      -- Counters this very ability puts on first ("put a burden counter on it, then draw a card for each").
      local added = low:sub(1, a1):match("put (%w+) " .. kindWord:gsub("([%%%-%.%+%*%?%[%]%^%$%(%)])", "%%%1") .. " counters? on ")
      if added and num(added) then
        n = n + num(added)
      end
      local before = raw:sub(1, a1 - 1)
      local after = raw:sub(stopAt)
      local b2 = before:gsub(" a card$", " " .. n .. " cards"):gsub(" an? card$", " " .. n .. " cards")
      if b2 == before then
        b2 = before:gsub("(%d+) life$", function(k) return (tonumber(k) * n) .. " life" end)
      end
      if b2 == before then
        b2 = before:gsub("(%d+) damage$", function(k) return (tonumber(k) * n) .. " damage" end)
      end
      if b2 == before and before:lower():find("create ", 1, true) then
        -- "create a 1/1 colorless Thopter ... token with flying for each ..."
        b2 = before:gsub("[Cc]reate an? ", "create " .. n .. " ", 1)
      end
      if b2 ~= before then
        local copy = {}
        for k, v in pairs(it) do
          copy[k] = v
        end
        copy.text = b2 .. after
        copy.countDone = true
        printToAll("MTG > " .. it.name .. ": " .. n .. " " .. kindWord .. " counter" .. (n == 1 and "" or "s") .. " counted.", INFO)
        it = copy
        raw = copy.text
        low = raw:lower()
      end
    end
  end
  -- Greater Good: "draw cards equal to the sacrificed creature's power": the player says what it was.
  if low:find("equal to the sacrificed creature's power", 1, true) and not it.sacPowerDone then
    local at = low:find("equal to the sacrificed creature's power", 1, true)
    ask(it.controller, it.name .. ": sacrificed creature's power?", "Type the power of the creature you sacrificed, then OK.",
      { { label = "SKIP", value = false } }, function(n)
        if n == false then
          printToAll("MTG > " .. it.name .. ": resolve it by hand.", INFO)
          return
        end
        local copy = {}
        for k, v in pairs(it) do
          copy[k] = v
        end
        copy.text = raw:sub(1, at - 1):gsub("cards $", n .. " cards"):gsub("a card $", n .. " cards") .. raw:sub(at + #"equal to the sacrificed creature's power")
        copy.text = copy.text:gsub("draw cards  ", "draw " .. n .. " cards "):gsub("Draw cards  ", "Draw " .. n .. " cards ")
        copy.sacPowerDone = true
        Effects.resolve(copy)
      end, nil, true)
    return
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
    local defined = lowX:find("where x", 1, true) or lowX:find(" x is the ", 1, true) or lowX:find(" x is equal", 1, true)
      or lowX:find(" x equals", 1, true)
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
  -- Scute Swarm has its own handler (counts the lands itself).
  if not it.insteadDone and tostring(it.text or ""):lower():find("if you control six or more lands, create a token that's a copy of", 1, true) then
    it.insteadDone = true
  end
  -- "Create five 1/1 tokens. If <condition>, create ten of those tokens instead.": pick the right sentence.
  if not it.insteadDone and tostring(it.text or ""):lower():find(" instead", 1, true) then
    local raw2 = tostring(it.text or "")
    -- (plain searches only: MoonSharp gives up on lazy patterns over long text)
    local a1, cond, repl
    local ip
    do
      local from = 1
      while true do
        local k = raw2:lower():find(" instead", from, true)
        if not k then break end
        ip = k
        from = k + 1
      end
    end
    if ip and not raw2:sub(ip + #" instead"):find("[^%.%s]") then
      local before = raw2:sub(1, ip - 1)
      local at
      for _, marker in ipairs({ ". If ", ". if " }) do
        local from = 1
        while true do
          local k = before:find(marker, from, true)
          if not k then break end
          if at == nil or k > at then at = k end
          from = k + 1
        end
      end
      if at then
        local seg = before:sub(at + 5)
        local comma = seg:find(",", 1, true)
        if comma and comma > 1 then
          a1 = at
          cond = seg:sub(1, comma - 1)
          repl = seg:sub(comma + 1):gsub("^%s+", "")
        end
      end
    end
    if a1 then
      local base = raw2:sub(1, a1)
      local function go(yes)
        local copy = {}
        for k, v in pairs(it) do
          copy[k] = v
        end
        copy.insteadDone = true
        if yes then
          local r2 = repl
          if r2:find("of those tokens", 1, true) then
            local desc = base:match("[Cc]reate %w+ (.-tokens?)")
            if desc then
              r2 = r2:gsub("of those tokens", (desc:gsub("%%", "%%%%")))
            end
          end
          copy.text = r2:sub(1, 1):upper() .. r2:sub(2) .. "."
        else
          copy.text = base
        end
        Effects.resolve(copy)
      end
      local auto = Effects.condValue(cond:lower(), it.controller, it.name)
      if auto ~= nil then
        go(auto)
      else
        ask(it.controller, it.name .. ": is this true?", "If " .. cond .. "?\nThen instead: " .. repl,
          { { label = "YES", value = true }, { label = "NO", value = false } }, go)
      end
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
      -- "Sacrifice it. If you do, ...": the table sacrifices it itself, so it knows.
      if c.cond == "you do" and c.auto == nil then
        for _, a in ipairs(plan.actions) do
          local src = it.source and getObjectFromGUID(it.source)
          if a.what == "sacSelf" and src and not src.isDestroyed() then
            c.auto = true
            c.silent = true
          end
        end
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
    local pro = GameState.data.playerPro or {}
    for _, c in ipairs(players()) do
      if pro[c] and c ~= seat then
        printToAll("MTG > " .. c .. " has protection from everything: " .. it.name .. " can't target them.", INFO)
      elseif not (oppOnly and c == seat) then
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
Effects.fieldSeat = fieldSeat

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
      if owner and ((scope == "mine" and owner == seat) or (scope == "opponents" and owner ~= seat) or scope == "all") then
        local name = tostring(obj.getName()):lower()
        local hit = cardTypes(obj)[word] or name:find(word, 1, true) ~= nil
        if not hit then
          pcall(function()
            local d = JSON.decode(obj.getGMNotes())
            local tl = " " .. tostring(d.typeLine or ""):lower():gsub("[^%a]", " ") .. " "
            hit = tl:find(" " .. word .. " ", 1, true) ~= nil
          end)
        end
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
  -- Protection: a targeted pick can't choose a creature that has protection
  -- from the source's colour (shown instead of the pick button).
  local PROT = { TARGET = true, GOAD = true, ["CHAOS WARP"] = true, DESTROY = true, EXILE = true }
  if Equip and Equip.protectedFrom and PROT[q.pick.label] and q.pick.protect ~= false and q.pick.noProtect ~= true then
    local pro = Equip.protectedFrom(obj, q.pick.src or q.src)
    if pro then
      obj.createButton({
        click_function = "counters_noop",
        function_owner = Global,
        label = "PRO " .. string.upper(pro),
        tooltip = "Protected: can't be targeted by this source.",
        position = { 0, 0.3, 0.5 },
        rotation = { 0, 0, 0 },
        width = 800, height = 260, font_size = 150,
        font_color = { 1, 1, 1 },
        color = { 0.7, 0.15, 0.15, 0.95 },
      })
      return
    end
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
  -- Picking someone else's permanent is targeting it ("becomes the target of...").
  local ok, owner = pcall(fieldSeat, obj)
  if ok and owner and owner ~= q.seat and Triggers and Triggers.onTargeted then
    if Triggers.onTargeted(obj, q.seat) == true then
      -- Gone before the spell resolved: nothing happens.
      if current == nil then
        nextQuestion()
      end
      return
    end
  end
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
    if Effects.cloneLeft(obj, seat, "hand") then
      obj.destruct()
      return
    end
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
    if a.theirs and owner == seat then
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
  local shown = want == "nonland" and "nonland permanent" or want
  ask(seat, sourceName .. ": return a " .. shown, "Click RETURN on the " .. shown .. " to return to its owner's hand.",
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
  if a.tapped then
    local s = TableSetup.seat(owner)
    local diff = s and ((obj.getRotation().y - s.yaw + 540) % 360) - 180 or 0
    if math.abs(diff) <= 30 then
      return false
    end
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
          if a.untilLeaves and sourceGuid and not obj.hasTag("Token") then
            local held = GameState.data.heldExile or {}
            GameState.data.heldExile = held
            held[sourceGuid] = held[sourceGuid] or {}
            table.insert(held[sourceGuid], { guid = obj.getGUID(), owner = owner, name = name })
            broadcastToColor(name .. " stays exiled until " .. sourceName .. " leaves the battlefield.", seat, INFO)
          end
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
    local placed = Counters.place(army, "plus", n, seat)
    printToAll("MTG > " .. seat .. " amasses " .. placed .. " onto " .. army.getName() .. ".", GOOD)
    return
  end
  -- No Army yet: a 0/0 black <Kind> Army token, then the counters.
  Tokens.create(seat, { pt = "0/0", words = { kind:lower(), "army" }, colors = { B = true } }, 1, sourceName)
  Wait.time(function()
    local made = armyOf(seat)
    if made then
      local placed = Counters.place(made, "plus", n, seat)
      printToAll("MTG > " .. seat .. " amasses " .. placed .. " onto the new " .. made.getName() .. ".", GOOD)
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
  t = t:gsub("enters the battlefield", "enters")
  local w, kind = t:match("enters with (%w+) ([%w%+/%-]+) counters? on it")
  local n = num(w)
  -- Counters that depend on a number only the player knows: X, or the mana
  -- spent (Marath). The owner types it.
  local ask_kind = t:match("enters with x ([%w%+/%-]+) counters? on it")
  local mana_kind = t:match("enters with a number of ([%w%+/%-]+) counters on it equal to the amount of mana spent")
    or t:match("enters with a number of ([%w%+/%-]+) counters on it equal to the mana value")
  if n == nil and (ask_kind or mana_kind) and d.to.seat then
    local k2 = ask_kind or mana_kind
    local key2 = (k2 == "+1/+1" and "plus") or (k2 == "-1/-1" and "minus") or (k2 == "loyalty" and "loyalty") or "other"
    local seat2 = d.to.seat
    local mv = 0
    pcall(function() mv = tonumber(JSON.decode(card.getGMNotes()).cmc) or 0 end)
    Wait.time(function()
      if card.isDestroyed() then
        return
      end
      ask(seat2, name .. ": how many " .. k2 .. " counters?",
        (ask_kind and "Type X (what it was cast with)" or ("Type the mana spent to cast it (its mana value is " .. mv .. ", plus any commander tax)"))
          .. ", then OK.", { { label = "SKIP", value = false } }, function(v)
          if v == false or card.isDestroyed() then
            return
          end
          if v > 0 then
            v = Counters.place(card, key2, v, seat2)
          end
          printToAll("MTG > " .. name .. " enters with " .. v .. " " .. k2 .. " counters.", INFO)
        end, nil, true)
    end, 0.6)
    return
  end
  -- Devour N (Mycoloth): sacrifice any number of creatures, it enters with N times that many +1/+1 counters.
  do
    local dv = t:match("devour (%d+)")
    if dv and d.to.seat then
      local seat3, per, eaten = d.to.seat, tonumber(dv), 0
      local function more()
        ask(seat3, name .. ": devour " .. dv, "You may sacrifice creatures to it, one at a time, then press DONE. Each one gives it "
          .. per .. " +1/+1 counters" .. (eaten > 0 and (" (" .. eaten .. " so far)") or "") .. ".",
          { { label = eaten > 0 and "DONE" or "NONE", value = false } }, function(obj)
            if obj then
              printToAll("MTG > " .. seat3 .. " sacrifices " .. obj.getName() .. " to " .. name .. " (devour).", GOOD)
              Combat.removeCard(obj, "graveyard")
              eaten = eaten + 1
              more()
            elseif eaten > 0 and not card.isDestroyed() then
              local placed = Counters.place(card, "plus", eaten * per, seat3)
              printToAll("MTG > " .. name .. " devoured " .. eaten .. " creature(s): " .. placed .. " +1/+1 counters.", GOOD)
            end
          end, { filter = function(obj, owner)
            return owner == seat3 and obj ~= card and Effects.cardTypes(obj).creature == true
          end, label = "SACRIFICE", protect = false })
      end
      Wait.time(function()
        if not card.isDestroyed() then
          more()
        end
      end, 0.8)
    end
  end
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
      local placed = Counters.place(card, key, n, d.to.seat)
      printToAll("MTG > " .. card.getName() .. " enters with " .. placed .. " " .. kind .. " counter"
        .. (placed == 1 and "" or "s") .. ".", INFO)
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
  if a.scope == "equipped" then
    local src = it.source and getObjectFromGUID(it.source)
    local card = src and not src.isDestroyed() and Equip and Equip.hostOf(src) or nil
    if card == nil and it.thatCard then
      card = getObjectFromGUID(it.thatCard)
    end
    if card and not card.isDestroyed() then
      boost(card, a)
      printToAll("MTG > " .. card.getName() .. " gets " .. tostring(a.label) .. " until end of turn.", GOOD)
      return 1
    end
    broadcastToColor(it.name .. ": give the equipped creature " .. tostring(a.label) .. " yourself.", seat, INFO)
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
  do
    local n = cond:match("^you gained (%d+) or more life this turn$")
    if n then
      return Trackers.lifeThisTurn(seat).gained >= tonumber(n)
    end
    if cond == "you didn't lose life this turn" or cond == "you did not lose life this turn" then
      return Trackers.lifeThisTurn(seat).lost == 0
    end
    if cond == "you lost life this turn" then
      return Trackers.lifeThisTurn(seat).lost > 0
    end
    local x, y = cond:match("^(%d+) is (%d+) or more$")
    if x then
      return tonumber(x) >= tonumber(y)
    end
    local word = cond:match("^you control an? (%a+)$") or cond:match("^you control another (%a+)$")
    if word and word ~= "creature" and word ~= "permanent" then
      return Effects.controlsWord(seat, word, name)
    end
  end
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

-- "Untap all lands you control": every tapped permanent of that type.
function Effects.untapAllOf(seat, ty, name)
  local s = TableSetup.seat(seat)
  local n = 0
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and fieldSeat(obj) == seat
        and cardTypes(obj)[ty] then
      local r = obj.getRotation()
      local diff = ((r.y - s.yaw + 540) % 360) - 180
      if math.abs(diff) > 30 then
        obj.setRotationSmooth({ r.x, s.yaw, r.z }, false, true)
        n = n + 1
      end
    end
  end
  printToAll("MTG > " .. tostring(name) .. ": " .. seat .. " untaps " .. n .. " " .. ty .. (n == 1 and "" or "s") .. ".", { 0.55, 0.9, 0.6 })
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
  local pending, cards, allExiled = #who, {}, {}
  local function mvOf(card)
    local mv = 0
    pcall(function() mv = tonumber(JSON.decode(card.getGMNotes()).cmc) or 0 end)
    return mv
  end
  local function restToBottom(except)
    if not a.bottomRest then
      return
    end
    local rest = {}
    for _, c in ipairs(allExiled) do
      if c ~= except and not c.isDestroyed() then
        table.insert(rest, c)
      end
    end
    if #rest > 0 then
      Library.putBottomRandom(seat, rest, function()
        printToAll("MTG > " .. it.name .. ": the other " .. #rest .. " exiled card" .. (#rest == 1 and "" or "s")
          .. " go to the bottom of " .. seat .. "'s library in a random order.", INFO)
      end)
    end
  end
  local function offer()
    if #cards == 0 and a.play and #allExiled > 0 then
      -- The exiled card is a land: it can be played (put onto the battlefield).
      local land = allExiled[1]
      if land and not land.isDestroyed() then
        ask(seat, it.name .. ": play " .. land.getName() .. "?", "Put the exiled land onto the battlefield (it counts as your land drop).",
          { { label = "PLAY", value = true }, { label = "NO", value = false } }, function(yes)
            if yes and not land.isDestroyed() then
              land.setLock(false)
              land.setRotation({ 0, TableSetup.seat(seat).yaw, 0 })
              land.setPosition(TableSetup.slot(seat, "lands", TableSetup.SURFACE_TOP + 2))
              printToAll("MTG > " .. seat .. " plays " .. land.getName() .. " from exile (" .. it.name .. ").", GOOD)
              Wait.time(function() if not land.isDestroyed() then Zones.refresh(land) end end, 0.6)
            else
              printToAll("MTG > " .. seat .. " doesn't play " .. land.getName() .. " (stays exiled).", INFO)
            end
          end)
        return
      end
    end
    if #cards == 0 then
      printToAll("MTG > " .. it.name .. ": no nonland cards were exiled.", INFO)
      restToBottom(nil)
      return
    end
    for _, card in ipairs(cards) do
      local name = card.getName()
      local oracle = ""
      pcall(function()
        local d = JSON.decode(card.getGMNotes())
        oracle = type(d) == "table" and tostring(d.oracle or "") or ""
      end)
      local choices = { { label = "CAST", value = "cast" } }
      if a.discover then
        table.insert(choices, { label = "TO HAND", value = "hand" })
      else
        table.insert(choices, { label = "NO", value = false })
      end
      ask(seat, it.name .. ": " .. (a.play and "play" or "cast") .. " " .. name .. " free?", (#oracle > 150 and (oracle:sub(1, 148) .. "...") or oracle),
        choices, function(pick)
          if pick == "cast" and not card.isDestroyed() then
            printToAll("MTG > " .. seat .. " casts " .. name .. " without paying its mana cost (" .. it.name .. ").", GOOD)
            Stack.pushCard(card, seat)
            restToBottom(card)
          elseif pick == "hand" and not card.isDestroyed() then
            printToAll("MTG > " .. seat .. " puts " .. name .. " into their hand (" .. it.name .. ").", GOOD)
            card.setPositionSmooth(Player[seat].getHandTransform().position, false, true)
            Wait.time(function() if not card.isDestroyed() then Zones.refresh(card) end end, 0.8)
            restToBottom(card)
          else
            printToAll("MTG > " .. seat .. " doesn't cast " .. name .. (a.bottomRest and "." or " (stays exiled)."), INFO)
            restToBottom(nil)
          end
        end)
    end
  end
  local accept
  if a.mvLess or a.mvMax then
    accept = function(card)
      local mv = mvOf(card)
      if a.mvLess then
        return mv < a.mvLess
      end
      return mv <= a.mvMax
    end
  end
  if a.shuffleFirst then
    local lib = Library.find(seat)
    if lib and lib.type == "Deck" and lib.shuffle then
      lib.shuffle()
      printToAll("MTG > " .. seat .. " shuffles their library (" .. it.name .. ").", INFO)
    end
  end
  for _, s in ipairs(who) do
    Library.exileUntilNonland(s, not a.untilNonland, function(card, exiled)
      printToAll("MTG > " .. s .. " exiled " .. #exiled .. " card" .. (#exiled == 1 and "" or "s") .. " from their library ("
        .. it.name .. ").", INFO)
      for _, c in ipairs(exiled) do
        table.insert(allExiled, c)
      end
      if card then
        table.insert(cards, card)
      end
      pending = pending - 1
      if pending == 0 then
        offer()
      end
    end, accept)
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
        end, { filter = function(obj, owner) return owner == opp and cardTypes(obj).creature == true end, label = "EXILE", noProtect = true })
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
        Counters.place(card, "plus", a.counters, seat)
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
