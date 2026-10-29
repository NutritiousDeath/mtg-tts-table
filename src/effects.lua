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
local MAX_CHOICES = 7   -- Cavern of Souls: C + five colors needs six; the panel fits seven

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

-- Plain-search stand-ins for lazy patterns: TTS's pattern matcher gives up ("pattern too complex") when a
-- "(.-)" has to stretch over a long sentence.
-- The text between the first `pre` and the nearest of the `posts` after it, like pre .. "(.-)" .. post.
local function between(s, pre, posts)
  local from = 1
  while true do
    local a = s:find(pre, from, true)
    if not a then
      return nil
    end
    local best
    for _, post in ipairs(posts) do
      local b = s:find(post, a + #pre, true)
      if b and (best == nil or b < best) then
        best = b
      end
    end
    if best then
      return s:sub(a + #pre, best - 1)
    end
    from = a + 1
  end
end

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
    -- The first comma that ends the trigger: not one inside a list in it ("with mana value, power, or
    -- toughness equal to ...", Talion).
    local from = 1
    while true do
      local comma = t:find(", ", from, true)
      if not comma then
        break
      end
      local rest = t:sub(comma + 2)
      if not (rest:find("^or ") or rest:find("^and ") or rest:find("^[%a%-]+, or ") or rest:find("^[%a%-]+, and ")) then
        return rest
      end
      from = comma + 2
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
    if line:find(".", 1, true) or line:find(":", 1, true) or line:lower():find("^fabricate %d")
        or line:lower():find("^cumulative upkeep") or line:lower():find("^%s*level %d+%s*$") then
      table.insert(kept, line)
    end
    i = j + 1
  end
  text = table.concat(kept, "\n")
  -- A token "with '<its own ability>'" (Kibo's Banana: "{T}, Sacrifice this artifact: Add {R} or {G}...")
  -- goes before the cost is split off: the colon inside the quotes isn't this ability's cost.
  text = text:gsub("\226\128\156", '"'):gsub("\226\128\157", '"')
  text = text:gsub('([Tt]okens?) named ([%a\' ]-) with "[^"]*"', "%1 named %2")
  text = text:gsub('([Tt]okens?) with "[^"]*"', "%1")
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
  -- Other ways to say the same thing.
  t = t:gsub("each of your opponents", "each opponent"):gsub("each of those opponents", "each opponent")
    :gsub("each other player", "each opponent")
  -- Several paragraphs (a spell: "This spell can't be countered." then
  -- "Destroy all creatures."): read them as sentences.
  t = t:gsub("\n", " ")
  -- Same meaning, a form the parser knows (Deathbringer Liege, Prismatic Ending).
  t = t:gsub("destroy target creature if it's tapped", "destroy target tapped creature")
  local convergeNote
  do
    local a, b = t:find("exile target nonland permanent if its mana value is less than or equal to the number of colors of mana spent to cast this spell", 1, true)
    if a then
      t = t:sub(1, a - 1) .. "exile target nonland permanent" .. t:sub(b + 1)
      convergeNote = "Prismatic Ending: only a permanent with mana value up to the number of colors spent (X)."
    end
  end
  -- Whole-text effects from the Beamtown Bullies deck (they only make sense on their own).
  do
    local tt = t:gsub("^%s+", ""):gsub("%s+$", "")
    local function only(list)
      return { optional = false, actions = list, notes = {}, conds = {} }
    end
    -- Sire of Insanity.
    if tt == "each player discards their hand." then
      return only({ { what = "discardHand", who = "all", n = 1 } })
    end
    -- Eater of Days.
    local sk = tt:match("^you skip your next (%w+) turns?%.$")
    if sk and num(sk) then
      return only({ { what = "skipTurns", who = "you", n = num(sk) } })
    end
    -- Soulgorger Orgg.
    if tt == "you lose all but 1 life." then
      return only({ { what = "allBut1", who = "you", n = 1 } })
    end
    -- Inverter of Truth.
    if tt == "exile all cards from your library face down, then shuffle all cards from your graveyard into your library." then
      return only({ { what = "exileLibrary", who = "you", n = 1, faceDown = true }, { what = "yardToLibrary", who = "you", n = 1 } })
    end
    -- Leveler.
    if tt == "exile all cards from your library." then
      return only({ { what = "exileLibrary", who = "you", n = 1 } })
    end
    -- The One Ring: "{T}: Put a burden counter on ~, then draw a card for each burden counter on ~."
    if tt == "put a burden counter on ~, then draw a card for each burden counter on ~." then
      return only({ { what = "oneRing", who = "you", n = 1 } })
    end
    -- The One Ring: "At the beginning of your upkeep, you lose 1 life for each burden counter on ~."
    if tt == "you lose 1 life for each burden counter on ~." then
      return only({ { what = "loseBurden", who = "you", n = 1 } })
    end
    -- Yuriko, the Tiger's Shadow.
    if tt == "reveal the top card of your library and put that card into your hand. each opponent loses life equal to that card's mana value." then
      return only({ { what = "yuriko", who = "you", n = 1 } })
    end
    -- Doctor Doom, Unrivaled: "You draw a card and lose 1 life. Then if your library has no cards in it, you win the game."
    if tt == "you draw a card and lose 1 life. then if your library has no cards in it, you win the game." then
      return only({ { what = "draw", who = "you", n = 1 }, { what = "lose", who = "you", n = 1 }, { what = "winIfEmpty", who = "you", n = 1 } })
    end
    -- Triskaidekaphile (at the beginning of your upkeep).
    if tt == "if you have exactly thirteen cards in your hand, you win the game." then
      return only({ { what = "winIfHand", who = "you", n = 13 } })
    end
    -- Rhystic Study: "you may draw a card unless that player pays {1}."
    local unlessPay = tt:match("^you may draw a card unless that player pays (%b{})%.$")
    if unlessPay then
      return only({ { what = "rhystic", who = "you", n = 1, cost = unlessPay:upper() } })
    end
    -- Temporal Trespass and friends: "Take an extra turn after this one."
    if tt:find("^take an extra turn after this one%.") then
      return only({ { what = "extraTurn", who = "you", n = 1 } })
    end
    -- Karn's Temporal Sundering.
    if tt:find("target player takes an extra turn after this one. return up to one target nonland permanent to its owner's hand.", 1, true) then
      return only({ { what = "extraTurn", who = "you", n = 1, ask = true },
        { what = "bounce", who = "you", n = 1, type = "nonland", mine = false, other = false, theirs = false } })
    end
    -- Figure of Destiny: "{R/W}: ~ becomes a Kithkin Spirit with base power and toughness 4/4." and the
    -- "If ~ is a Spirit, it becomes ..." levels.
    do
      local need, types, bp, bt = tt:match("^if ~ is an? (%a+), it becomes an? ([%a%s]-) with base power and toughness (%d+)/(%d+)")
      if not bp then
        types, bp, bt = tt:match("^~ becomes an? ([%a%s]-) with base power and toughness (%d+)/(%d+)")
      end
      if bp then
        local stage = 1
        local tw = " " .. types .. " "
        if tw:find(" avatar ", 1, true) then
          stage = 3
        elseif tw:find(" warrior ", 1, true) then
          stage = 2
        end
        local needStage = need == "spirit" and 1 or (need == "warrior" and 2 or (need == "avatar" and 3 or 0))
        return only({ { what = "becomeBase", who = "you", n = 1, p = tonumber(bp), t = tonumber(bt), stage = stage,
          needStage = needStage, need = need, types = types, kw = tt:find("flying, and first strike", 1, true) ~= nil } })
      end
    end
    -- Lost in Space: "Target artifact or creature's owner puts it on their choice of the top or bottom of their library."
    do
      local kinds
      local key = tt:find("'s owner puts it on their choice of the top or bottom of their library", 1, true)
      if key then
        local from = 1
        while true do
          local a = tt:find("target ", from, true)
          if not a or a + 7 > key then
            break
          end
          local mid = tt:sub(a + 7, key - 1)
          if not mid:find("[^%a%s,]") then
            kinds = mid
            break
          end
          from = a + 1
        end
      end
      if kinds then
        local list = { { what = "tuckTarget", who = "you", n = 1, kinds = kinds } }
        if tt:find("surveil 1", 1, true) then
          table.insert(list, { what = "scry", who = "you", n = 1, surveil = true })
        end
        return only(list)
      end
    end
    -- Lotus Field / Karoo lands: "When this land enters, sacrifice two lands" / "...return a land you control to its owner's hand".
    do
      local sw = tt:match("^sacrifice (%w+) lands?%.$")
      local su = tt:match("^sacrifice (%w+) untapped lands?%.$")
      if (sw and num(sw)) or (su and num(su)) then
        return only({ { what = "sacLands", who = "you", n = num(sw or su), untapped = su ~= nil } })
      end
      if tt == "return a land you control to its owner's hand." then
        return only({ { what = "bounceLand", who = "you", n = 1 } })
      end
    end
    -- Maelstrom Archangel, Omniscience-style: "you may cast a spell from your hand without paying its mana cost".
    if tt:find("you may cast a spell from your hand without paying its mana cost", 1, true)
        or tt:find("you may cast a card from your hand without paying its mana cost", 1, true) then
      return only({ { what = "freeCastHand", who = "you", n = 1 } })
    end
    -- Explore, Growth Spiral: "You may play an additional land this turn."
    do
      local lw = tt:match("you may play (%w+) additional lands? this turn")
      if lw and num(lw) then
        local list = { { what = "landBonus", who = "you", n = num(lw) } }
        if tt:find("draw a card", 1, true) then
          table.insert(list, { what = "draw", who = "you", n = 1 })
        end
        return only(list)
      end
    end
    -- Jared Carthalion deck.
    if tt:find("put a number of +1/+1 counters on it equal to the number of colors it is", 1, true) then
      return only({ { what = "colorCounters", who = "you", n = 2 } })
    end
    if tt:find("return target multicolored card from your graveyard to your hand. if that card was all colors, draw a card and create two treasure tokens", 1, true) then
      return only({ { what = "jaredUlt", who = "you", n = 1 } })
    end
    if tt:find("draw x cards and you lose x life, where x is the number of colors of mana spent to cast this spell", 1, true) then
      return only({ { what = "painfulTruths", who = "you", n = 1 } })
    end
    if tt:find("search your library for a creature, instant, or sorcery card with mana value less than or equal to the number of colors of mana spent", 1, true) then
      return only({ { what = "bringToLight", who = "you", n = 1 } })
    end
    if tt:find("if it doesn't have the same name as another creature you control or a creature card in your graveyard, draw a card", 1, true) then
      return only({ { what = "guardianProject", who = "you", n = 1 } })
    end
    if tt:find("^if you control a creature with power 4 or greater, draw a card") then
      return only({ { what = "drawIfPower", who = "you", n = 1, power = 4 } })
    end
    do
      local gl = tt:match("^target player gains (%d+) life%.$")
      if gl then
        return only({ { what = "gainTarget", who = "you", n = tonumber(gl) } })
      end
    end
    if tt:find("draw cards equal to the greatest power among non-human creatures you control", 1, true) then
      return only({ { what = "drawGreatest", who = "you", n = 1, nonHuman = true } })
    end
    if tt:find("double the number of each kind of counter on any number of target permanents", 1, true) then
      return only({ { what = "doubleCounters", who = "you", n = 1 } })
    end
    if tt:find("reveal the top ten cards of your library. for each color pair, choose a card that's exactly those colors", 1, true) then
      return only({ { what = "nivReborn", who = "you", n = 1 } })
    end
    if tt == "you may tap target creature." or tt == "tap target creature." then
      return only({ { what = "tapTarget", who = "you", n = 1, may = tt:sub(1, 7) == "you may" } })
    end
    if tt:find("your life total can't change and you gain protection from everything. all permanents you control phase out", 1, true) then
      return only({ { what = "teferiProt", who = "you", n = 1 } })
    end
    if tt:find("put target creature card from a graveyard onto the battlefield under its owner's control", 1, true) then
      return only({ { what = "reanimateAny", who = "you", n = 1 } })
    end
    -- Heroic Intervention.
    if tt == "permanents you control gain hexproof and indestructible until end of turn." then
      return only({ { what = "teamKw", who = "you", n = 1, kws = { "hexproof", "indestructible" } } })
    end
  -- Revitalizing Repast.
    if tt == "put a +1/+1 counter on target creature. it gains hexproof and indestructible until end of turn. untap it." then
      return only({ { what = "repast", who = "you", n = 1 } })
    end
  end

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
    -- Soulbond (Deadeye Navigator): "Exile this creature, then return it to the battlefield under your control."
    if tt:find("^exile ~, then return it to the battlefield under your control") or tt:find("^exile ~, then return ~ to the battlefield under your control") then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "blinkSelf", who = "you", n = 1 } } }
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
        -- "put a +1/+1 counter on each Vampire you control" (Edgar Markov): a creature type.
        local bare = rest:match("^([%a%-]+) you control")
        if w == nil and bare and not ({ other = true, creature = true, permanent = true, artifact = true,
            land = true, enchantment = true, planeswalker = true })[bare] then
          w = bare:gsub("s$", "")
          rest = "creature you control"
        end
        local other = false
        if w == "other" then
          other, w = true, nil
        end
        if w or rest:find("^creature you control") or rest:find("^other creature you control") then
          if rest:find("^other ") then
            other = true
          end
          -- "each creature you control that's an Ape or a Monkey" (Kibo, Uktabi Prince).
          local words
          local thats = rest:match("^o?t?h?e?r? ?creatures? you control that's ([%a ,%-]+)")
          if thats then
            words = {}
            for piece in thats:gsub(" or ", ","):gsub(" and ", ","):gmatch("[^,]+") do
              local wd = piece:gsub("^%s*an? ", ""):gsub("^%s+", ""):gsub("%s+$", "")
              if wd ~= "" then
                table.insert(words, wd)
              end
            end
            if #words == 0 then
              words = nil
            end
          end
          return { optional = t:find("you may put", 1, true) ~= nil, notes = {}, conds = {},
            actions = { { what = "counterAll", who = "you", n = 1, mode = "add", word = w, words = words, other = other } } }
        end
      end
    end
    -- Scute Swarm: an Insect token, or a copy of itself with six or more lands.
    if t:find("if you control six or more lands, create a token that's a copy of ~ instead", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "scute", who = "you", n = 1 } } }
    end
    -- Descent into Avernus: counters first (parsed as usual), then X Treasures and X damage, X = descent counters.
    do
      local at = t:find(" then each player creates x treasure tokens and ~ deals x damage to each player, where x is the number of descent counters on ~", 1, true)
      local tw, dw = "all", "all"
      if not at then
        at = t:find(" then each opponent creates x treasure tokens and ~ deals x damage to each opponent, where x is the number of descent counters on ~", 1, true)
        tw, dw = "opponents", "opponents"
      end
      if not at then
        at = t:find(" then each player creates x treasure tokens and ~ deals x damage to each opponent, where x is the number of descent counters on ~", 1, true)
        tw, dw = "all", "opponents"
      end
      if at then
        local first = t:sub(1, at - 1)
        local sub = Effects.parse(first, sourceName) or { actions = {}, notes = {}, conds = {} }
        table.insert(sub.actions, { what = "descentBurst", who = "you", n = 1, treasureWho = tw, damageWho = dw })
        return { optional = sub.optional or false, notes = sub.notes or {}, conds = sub.conds or {}, actions = sub.actions }
      end
    end
    -- Claim the Kingdom: "put a +1/+1 counter on target creature you control and a plan counter on this enchantment."
    if t:find("+1/+1 counter on target creature you control and a plan counter on", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = {
        { what = "counterOn", who = "you", n = 1, ty = "creature", kind = "plus", label = "+1/+1", mine = true },
        { what = "planCounter", who = "you", n = 1 } } }
    end
    -- Mossborn Hydra: "double the number of +1/+1 counters on this creature".
    if t:find("double the number of +1/+1 counters on this creature", 1, true) or t:find("double the number of +1/+1 counters on ~", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "doubleSelfCounters", who = "you", n = 1 } } }
    end
    -- Oran-Rief Hydra: one +1/+1 counter, two if the land that entered is a Forest.
    if t:find("if that land is a forest, put two +1/+1 counters on", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "landfallForestCounters", who = "you", n = 1 } } }
    end
    -- Peregrine Drake: "untap up to five lands".
    do
      local w = t:match("untap up to (%w+) lands")
      if w and num(w) and not t:find("target", 1, true) then
        return { optional = false, notes = {}, conds = {}, actions = { { what = "untapLands", who = "you", n = num(w) } } }
      end
    end
    -- Patient Naturalist: "mill three cards. Put a land card from among the milled cards into your hand. If you can't,
    -- create a Treasure token."
    do
      local w = t:match("mill (%w+) cards%. put a land card from among the milled cards into your hand")
      if w and num(w) then
        return { optional = false, notes = {}, conds = {}, actions = { { what = "millLandToHand", who = "you", n = num(w),
          treasure = t:find("if you can't, create a treasure token", 1, true) ~= nil } } }
      end
    end
    -- Freed from the Real: "{U}: Untap enchanted creature."
    if (t:find("untap enchanted permanent", 1, true) or t:find("untap enchanted creature", 1, true))
        and not t:find("doesn't untap", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "tapHost", who = "you", n = 1, untap = true } } }
    end
    -- Arbor Elf: "Untap target Forest."
    if t:match("^%s*untap target forest%.?%s*$") then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "untapForest", who = "you", n = 1 } } }
    end
    -- Fog effects (Spore Frog): "Prevent all combat damage that would be dealt this turn."
    if t:match("^%s*prevent all combat damage that would be dealt this turn%.?%s*$") then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "fog", who = "you", n = 1 } } }
    end
    -- Stuck in Summoner's Sanctum: "When this Aura enters, tap enchanted permanent."
    if t:find("tap enchanted permanent", 1, true) or t:find("tap enchanted creature", 1, true) then
      if not t:find("untap", 1, true) and not t:find("doesn't untap", 1, true) then
        return { optional = false, notes = {}, conds = {}, actions = { { what = "tapHost", who = "you", n = 1 } } }
      end
    end
    -- Dancing from Dark to Dawn: "put X +1/+1 counters on target creature you control, where X is that spell's mana value."
    if t:find("+1/+1 counters on target creature you control, where x is that spell's mana value", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "countersSpellMV", who = "you", n = 1 } } }
    end
    -- Class enchantments: "{2}{G}: Level 2" - the Class gains its next level.
    do
      local lv = t:match("^%s*level (%d+)%.?%s*$")
      if lv then
        return { optional = false, notes = {}, conds = {}, actions = { { what = "classLevel", who = "you", n = tonumber(lv) } } }
      end
    end
    -- Fell the Mighty: "Choose target creature. Destroy each creature with power greater than that creature's power."
    if t:find("choose target creature. destroy each creature with power greater than that creature's power", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "fellMighty", who = "you", n = 1 } } }
    end
    -- Damia, Sage of Stone: "if you have fewer than seven cards in hand, draw cards equal to the difference."
    do
      local w = t:match("if you have fewer than (%w+) cards in hand, draw cards equal to the difference")
      if w and num(w) then
        return { optional = false, notes = {}, conds = {}, actions = { { what = "drawUpTo", who = "you", n = num(w) } } }
      end
    end
    -- Cumulative upkeep (Mystic Remora): an age counter, then pay the cost once per age counter or sacrifice it.
    do
      local cost = t:match("^%s*cumulative upkeep[%s%-—]*([^%(]-)%s*%.?%s*$")
      if cost then
        return { optional = false, notes = {}, conds = {}, actions = { { what = "cumUpkeep", who = "you", n = 1, cost = cost } } }
      end
    end
    -- Sly Requisitioner: each player creates a Treasure token.
    -- Kibo, Uktabi Prince: each player creates a colorless artifact token named Banana.
    do
      local w = t:match("^%s*each player creates an? [%a ]- ?token named (%a+)%.?%s*$")
        or t:match("^%s*each player creates an? (%a+) token%.?%s*$")
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
  -- Wheel of Misfortune: secret numbers, highest takes damage, everyone but the lowest wheels.
  if t:find("each player secretly chooses a number 0 or greater", 1, true) and t:find("highest number", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "wheelMisfortune", who = "you", n = 1 } } }
  end
  -- World at War: an additional combat phase after the postcombat main phase (and untap the attackers).
  if (t:find("there's an additional combat phase", 1, true) or t:find("there is an additional combat phase", 1, true))
      and t:find("after the first postcombat main phase", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "extraCombat", who = "you", n = 1,
      untap = t:find("untap all creatures that attacked this turn", 1, true) ~= nil } } }
  end
  -- Windfall: everyone discards their hand, then draws as many as the most anyone discarded.
  if t:find("each player discards their hand, then draws cards equal to the greatest number of cards a player discarded this way", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "windfall", who = "all", n = 1 } } }
  end
  -- Warstorm Surge: the creature that entered deals damage equal to its power to any target.
  if t:find("it deals damage equal to its power to any target", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "powerHit", who = "you", n = 1 } } }
  end
  -- Rabid Bite / Bite Down: your creature deals damage equal to its power to another creature.
  if t:find("deals damage equal to its power to target creature", 1, true)
      and t:find("target creature you control deals damage equal to its power", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "bite", who = "you", n = 1 } } }
  end
  -- "If it's not your turn, you may exile a green card from your hand rather than pay this spell's mana
  -- cost." (Force of Vigor, Force of Will...): that is how it is cast, not part of what it does.
  do
    local rp = t:find("rather than pay this spell's mana cost", 1, true)
    if rp then
      local from = 1
      local i = 1
      while true do
        local j = t:find(". ", i, true)
        if not j or j >= rp then
          break
        end
        from = j + 2
        i = j + 1
      end
      local to = t:find(".", rp, true) or #t
      t = " " .. t:sub(1, from - 1) .. t:sub(to + 1)
      t = t:gsub("%s+", " ")
    end
  end
  -- Carpet of Flowers: up to X mana of one color, X = Islands the chosen opponent controls; once a turn.
  if t:find("islands target opponent controls", 1, true) and t:find("mana of any one color", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "carpetMana", who = "you", n = 1 } } }
  end
  -- Metamorphosis: sacrifice a creature, add X mana of one color (X = 1 + its mana value).
  if t:find("sacrificed creature's mana value", 1, true) and t:find("mana of any one color", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "sacMana", who = "you", n = 1,
      plus = t:find("1 plus", 1, true) ~= nil } } }
  end
  -- Horizon of Progress / Oracle-style: "You may put a land card from your hand onto the battlefield (tapped)."
  if t:find("put a land card from your hand onto the battlefield", 1, true) and not t:find("if ", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "handLand", who = "you", n = 1,
      tapped = t:find("onto the battlefield tapped", 1, true) ~= nil } } }
  end
  -- Mana Geyser: "Add {R} for each tapped land your opponents control." Counted from the table.
  do
    local sym, word, who = t:match("add ({%a}) for each tapped (%a+) (your opponents control)")
    local tp = sym ~= nil
    if not sym then
      sym, word, who = t:match("add ({%a}) for each (%a+) (your opponents control)")
    end
    if not sym then
      sym, word, who = t:match("add ({%a}) for each tapped (%a+) (you control)")
      tp = sym ~= nil
    end
    if not sym then
      sym, word, who = t:match("add ({%a}) for each (%a+) (you control)")
    end
    if sym and word ~= "card" then
      return { optional = false, notes = {}, conds = {},
        actions = { { what = "manaCount", who = "you", n = 1, color = sym:sub(2, 2):upper(), word = word,
          scope = who == "you control" and "mine" or "opponents", tapped = tp } } }
    end
  end
  -- Metalworker / Nykthos: the player says how many ("for each card revealed", devotion), the table adds the mana.
  do
    local per
    do
      -- plain searches: a lazy pattern over a long spell text is "too complex" for TTS
      local fe = t:find(" for each card revealed", 1, true)
      if fe then
        local head, ap, i = t:sub(1, fe - 1), nil, 1
        while true do
          local j = head:find("add ", i, true)
          if not j then
            break
          end
          ap = j
          i = j + 1
        end
        if ap then
          per = head:sub(ap + 4)
        end
      end
    end
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
  -- Unfinity: "Open an Attraction." (the top of your Attraction deck onto the battlefield).
  do
    local word = t:match("open (%a+) attractions?")
    local N = { an = 1, a = 1, one = 1, two = 2, three = 3 }
    if word and (N[word] or tonumber(word)) and not t:find("whenever you open an attraction", 1, true) then
      return { optional = false, notes = {}, conds = {}, actions = { { what = "openAttraction", who = "you",
        n = N[word] or tonumber(word) } } }
    end
  end
  -- Lithoform Engine, Reverberate, Strionic Resonator: copy a spell or ability on the stack.
  do
    local kinds = {
      { "copy target activated or triggered ability", "ability" },
      { "copy target triggered ability", "triggered" },
      { "copy target instant or sorcery spell", "instsorc" },
      { "copy target permanent spell", "permanent" },
      { "copy target spell", "spell" },
    }
    for _, k in ipairs(kinds) do
      if t:find(k[1], 1, true) then
        return { optional = false, notes = {}, conds = {}, actions = { { what = "copyStack", who = "you", n = 1,
          kind = k[2], mine = t:find(k[1] .. " you control", 1, true) ~= nil } } }
      end
    end
  end
  -- Gandalf, Westward Voyager: each opponent reveals the top card of their
  -- library; one that shares a card type with "that spell" copies it.
  if t:find("each opponent reveals the top card of their library", 1, true) and t:find("copy that spell", 1, true)
      and t:find("shares a card type with that spell", 1, true) then
    return { optional = false, notes = {}, conds = {}, actions = { { what = "revealCopy", who = "you", n = 1,
      perCard = t:find("for each card revealed", 1, true) ~= nil,
      oppDraw = t:find("each opponent draws a card", 1, true) ~= nil,
      elseDraw = t:find("otherwise, you draw a card", 1, true) ~= nil or t:find("draw a card", 1, true) ~= nil } } }
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
    local seg
    if tt:sub(1, 6) == "untap " or tt:sub(1, 4) == "tap " then
      seg = tt:gsub("%.$", "")
    end
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
  -- "Add {B}{B}{B}." (Dark Ritual, Ugin's 0): the mana goes on your mana pool.
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
          -- The last " if " in the sentence, found with plain searches: a lazy "(.-) if" pattern over a long
          -- sentence made TTS's pattern matcher give up ("pattern too complex", White Sun's Twilight).
          local eff, cc
          do
            -- The first " if " whose rest has no comma (what "^(.-) if ([^,]+)$" picked).
            local from = 1
            while true do
              local i = clean:find(" if ", from, true)
              if not i then
                break
              end
              local tail = clean:sub(i + 4)
              if tail ~= "" and not tail:find(",", 1, true) then
                eff, cc = clean:sub(1, i - 1), tail
                break
              end
              from = i + 1
            end
          end
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
  -- The Beamtown Bullies: the card goes onto the battlefield of the opponent whose turn it is.
  if t:find("target opponent whose turn it is puts target nonlegendary creature card from your graveyard onto the battlefield under their control", 1, true) then
    return { optional = false, actions = { { what = "bullies", who = "you", n = 1 } }, notes = {}, conds = {} }
  end
  -- Tamiyo's Safekeeping: "Target permanent you control gains hexproof and indestructible until end of turn."
  do
    local kwl = t:match("target permanent you control gains ([%a ,]+) until end of turn")
    if kwl then
      local kws = {}
      for _, kw in ipairs({ "hexproof", "indestructible", "shroud", "protection" }) do
        if kwl:find(kw, 1, true) then
          table.insert(kws, kw)
        end
      end
      if #kws > 0 then
        table.insert(actions, { what = "kwTargetPerm", who = "you", n = 1, kws = kws })
      end
    end
  end
  -- Blasphemous Act: "~ deals 13 damage to each creature."
  do
    local dmg = t:match("deals (%d+) damage to each creature%.")
    if dmg then
      table.insert(actions, { what = "damageAll", who = "you", n = tonumber(dmg) })
    end
  end
  -- "You may discard a card. If you do, ..." (Formidable Speaker, Bitter Reunion): discard, then the rest.
  for i = #conds, 1, -1 do
    local c = conds[i]
    if c.prev and c.prev:match("^you may discard a card%.?$") then
      table.remove(conds, i)
      table.insert(actions, { what = "mayDiscard", who = "you", n = 1, rest = c.rest })
    end
  end
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
  if w == nil then
    w = t:match("defending player loses (%w+) life")      -- Leeching Sliver
    add("lose", "that", num(w))
  end
  if w == nil then
    w = t:match(" they lose (%w+) life")      -- Sheoldred, the Apocalypse
    add("lose", "that", num(w))
  end
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
  -- Additional costs with a choice (Bitter Triumph: "discard a card or pay 3 life"; Demand Answers:
  -- "sacrifice an artifact or discard a card") and a plain discard (Thrill of Possibility). Paid first.
  local addlDone = false
  do
    local addl = t:match("as an additional cost to cast this spell, ([^%.]+)%.")
    if addl then
      local lifeN = addl:match("^discard a card or pay (%w+) life$")
      local sacK = addl:match("^sacrifice an? (%a+) or discard a card$")
      if addl == "discard a card" then
        table.insert(actions, 1, { what = "discard", who = "you", n = 1 })
        addlDone = true
      elseif lifeN and num(lifeN) then
        table.insert(actions, 1, { what = "addlChoice", who = "you", n = 1, discard = true, life = num(lifeN) })
        addlDone = true
      elseif sacK then
        table.insert(actions, 1, { what = "addlChoice", who = "you", n = 1, discard = true, sac = sacK })
        addlDone = true
      end
    end
  end
  -- "As an additional cost to cast this spell, sacrifice a land" (Crop Rotation).
  do
    local kind = t:match("as an additional cost to cast this spell, sacrifice an? (%a+)")
    if not addlDone and (kind == "land" or kind == "artifact") then
      table.insert(actions, { what = "addlSac", who = "you", n = 1, kind = kind })
    end
  end
  -- "As an additional cost to cast this spell, pay 3 life" (X filled in).
  do
    local pAt = t:find("pay %w+ life")
    if not addlDone and pAt and not t:sub(math.max(1, pAt - 12), pAt):find("unless", 1, true) then
      add("lose", "you", num(t:match("pay (%w+) life")))
    end
  end
  if t:find("you win the game", 1, true) then
    table.insert(actions, { what = "win", who = "you", n = 1 })
  end
  -- Green Sun's Zenith: "Shuffle ~ into its owner's library."
  if t:find("shuffle ~ into its owner's library", 1, true) then
    table.insert(actions, { what = "shuffleSelf", who = "you", n = 1 })
  end
  -- Finale of Devastation: "Search your library and/or graveyard for a creature card with mana value X or less".
  do
    local phrase, mv = t:match("search your library and/or graveyard for (.-) cards? with mana value (%d+) or less")
    if phrase then
      local q = phrase:gsub("^an? ", "")
      table.insert(actions, { what = "searchLibOrYard", who = "you", n = 1, query = q, mvMax = tonumber(mv),
        where = t:find("onto the battlefield", 1, true) and "battlefield" or "hand",
        bigX = tonumber(mv) >= 10 })
    end
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
  local thatW = t:match("that player draws (%w+) cards?")
  if w then
    add("draw", "all", num(w))
  elseif thatW and num(thatW) then
    -- Horn of Greed: "that player draws a card" (the player the trigger was about).
    add("draw", "that", num(thatW))
  else
    local a, word = t:find("draw (%w+) cards?")
    word = t:match("draw (%w+) cards?")
    -- Only "you" draw: not "target player draws", "that player draws"...
    local before = a and t:sub(math.max(1, a - 8), a - 1) or ""
    if word and not before:find("player", 1, true) and not before:find("opponent", 1, true) then
      add("draw", "you", num(word))
    end
  end
  -- Brainstorm: "then put two cards from your hand on top of your library in any order".
  do
    local hw = t:match("put (%w+) cards from your hand on top of your library")
    if hw and num(hw) then
      table.insert(actions, { what = "handToTop", who = "you", n = num(hw) })
    end
  end
  -- Ponder / Sensei's Divining Top: rearranging the top cards is done by hand.
  if t:find("then put them back in any order", 1, true) then
    table.insert(notes, "look at the top cards and put them back in the order you want (right-click your library > Search)"
      .. (t:find("you may shuffle", 1, true) and ", then shuffle if you want" or ""))
  end
  -- Mistblade Shinobi: "return target creature that player controls to its owner's hand".
  if t:find("return target creature that player controls to its owner's hand", 1, true) then
    table.insert(actions, { what = "bounce", who = "you", n = 1, type = "creature", mine = false, other = false, theirs = true })
  end
  -- "search your library for a basic land card, put it onto the battlefield":
  -- opens the library search with the card type filled in.
  local a = t:find("search your library for ", 1, true)
  if a then
    local rest = t:sub(a + 24)
    local stop = rest:find(" card", 1, true) or rest:find(",", 1, true) or 40
    local phrase = rest:sub(1, stop - 1)
    local q
    local anyOf
    -- Fetch lands and Farseek: "a Mountain or Plains card", "a Plains, Island, Swamp, or Mountain card":
    -- any of those land types (dual lands and shocks have them too).
    do
      local basics = {}
      local ph = " " .. phrase:gsub(",", " ") .. " "
      for _, ty in ipairs({ "plains", "island", "swamp", "mountain", "forest" }) do
        if ph:find(" " .. ty .. " ", 1, true) then
          table.insert(basics, ty)
        end
      end
      if #basics >= 2 and phrase:find(" or ", 1, true) then
        anyOf = basics
        q = table.concat(basics, " or ")
      end
    end
    for _, ty in ipairs({ "land", "creature", "artifact", "enchantment", "planeswalker", "instant", "sorcery", "equipment", "aura" }) do
      if phrase:find(ty, 1, true) and q == nil and not (ty == "land" and phrase:find("island", 1, true) and not phrase:find(" land", 1, true)) then
        q = ty
      end
    end
    -- "an instant or sorcery card": more than one type joined by "or".
    if anyOf == nil and phrase:find(" or ", 1, true) then
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
    -- Entomb / Buried Alive: "put that card into your graveyard"; Dina's Guidance: "into your hand or graveyard".
    local handOrYard = rest:find("into your hand or graveyard", 1, true) ~= nil
    if not bf and not handOrYard and (rest:find("into your graveyard", 1, true) or rest:find("put them into your graveyard", 1, true)) then
      where = "graveyard"
    end
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
      discardRandom = t:find("discard a card at random", 1, true) ~= nil,
      -- Shared Summons: "up to two creature cards ..., reveal them".
      upTo = num(phrase:match("^up to (%w+) ") or ""), reveal = rest:find("reveal", 1, true) ~= nil, handOrYard = handOrYard })
  end
  -- "untap it" / "untap that permanent" (Amulet of Vigor): the card the
  -- trigger was about.
  if t:find(" untap ~", 1, true) and not t:find("untap target", 1, true) then
    -- Thornbite Staff (on the equipped creature): "Whenever a creature dies, untap this creature."
    table.insert(actions, { what = "untapSelf", who = "you", n = 1 })
  elseif t:find("untap equipped creature", 1, true) then
    -- Sting, the Glinting Dagger: "At the beginning of each combat, untap equipped creature."
    table.insert(actions, { what = "untapEquipped", who = "you", n = 1 })
  elseif t:find("untap it", 1, true) or t:find("untap that ", 1, true) then
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
    for _, how in ipairs({ "all", "each", "target", "up to one target", "two target", "up to two target", "up to three target", "three target" }) do
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
            count = (how == "two target" or how == "up to two target") and 2 or ((how == "three target" or how == "up to three target") and 3 or 1),
            tapped = phrase:find("tapped", 1, true) ~= nil and not phrase:find("untapped", 1, true),
            untilLeaves = verb == "exile" and (t:find("until ~ leaves the battlefield", 1, true) ~= nil),
            lifeEqualPower = lifeEqualPower, loseEqualMV = loseEqualMV,
            -- Beast Within: "Its controller creates a 3/3 green Beast creature token."
            beastToken = t:find("its controller creates a 3/3 green beast creature token", 1, true) ~= nil,
            -- Force of Despair: only "creatures that entered the battlefield this turn".
            enteredThisTurn = (phrase:find("entered the battlefield this turn", 1, true) or phrase:find("entered this turn", 1, true)) ~= nil,
            -- Slaughter Pact: "nonblack creature".
            notColor = ({ white = "W", blue = "U", black = "B", red = "R", green = "G" })[phrase:match("non(%a+) ") or ""],
            -- Haywire Mite: "noncreature artifact or noncreature enchantment".
            nonCreaturePerm = phrase:find("noncreature artifact", 1, true) ~= nil,
            -- Assassin's Trophy: "Its controller may search their library for a basic land card, put it onto the battlefield".
            basicForController = t:find("its controller may search their library for a basic land card", 1, true) ~= nil,
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
          -- "a 3/3 Kavu creature token with trample that's all colors" (Jared Carthalion).
          if sentence:find("all colors", 1, true) then
            spec.colors = { W = true, U = true, B = true, R = true, G = true }
          end
          local atk = sentence:find("tapped and attacking", 1, true) ~= nil
          local act = { what = "token", who = "you", n = n, spec = spec, phrase = phrase,
            -- Living weapon: "create a 0/0 black Phyrexian Germ creature token, then attach this Equipment to it".
            attachSelf = sentence:find("then attach this", 1, true) ~= nil or sentence:find("then attach ~ to it", 1, true) ~= nil,
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
  -- The monarch (CR 724) and the initiative (CR 725).
  if t:find("you become the monarch", 1, true) then
    table.insert(actions, { what = "monarch", who = "you", n = 1 })
  end
  if t:find("you take the initiative", 1, true) then
    table.insert(actions, { what = "initiative", who = "you", n = 1 })
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
          "haste", "indestructible", "hexproof", "menace", "reach", "infect", "wither" }) do
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
      -- "each creature you control gets +2/+2" (Kessig's chaos): only yours.
      elseif head:find("each creature you control", 1, true) or head:find("each other creature you control", 1, true) then
        scope = "allMine"
      elseif head:find("each creature your opponents control", 1, true) or head:find("each creature an opponent controls", 1, true) then
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
  -- Malevolent Rumble: "Reveal the top four cards of your library. You may put a permanent card from among
  -- them into your hand. Put the rest into your graveyard."
  do
    local rw = t:match("reveal the top (%w+) cards of your library%. you may put an? [%a ]-card from among them into your hand%. put the rest into your graveyard")
    if rw and num(rw) then
      local kind = t:match("you may put an? (%a+) card from among them") or ""
      table.insert(actions, { what = "look", who = "you", n = num(rw), query = kind == "permanent" and "" or kind, picks = 1,
        where = "hand", restToYard = true, permanentOnly = kind == "permanent" })
    end
  end
  local lAt = t:find("look at the top ", 1, true)
  if lAt and t:find("rest on the bottom", 1, true) then
    local after = t:sub(lAt, lAt + 400)
    local lw = after:match("^look at the top (%w+) cards? of your library")
    if lw and num(lw) then
      local phrase = between(after, "reveal ", { " card from among", " cards from among" })
        or between(after, "put ", { " card from among", " cards from among" })
        or between(after, "reveal ", { " card" }) or ""
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
    local kind = Counters.kindOf(ckind)
    table.insert(actions, { what = "counter", who = "you", n = num(cn), kind = kind, label = ckind, onThat = onIt })
  end
  -- "put three +1/+1 counters on target creature (you control)": pick it on the table.
  do
    local t2 = t:gsub("up to one target", "target")
    local upTo = t2 ~= t
    local another = t2:find(" on another target ", 1, true) ~= nil
    t2 = t2:gsub(" on another target ", " on target ")
    local pn, pk, pty = t2:match("put (%w+) ([%w%+/%-]+) counters? on target (%a+)")
    if pn and num(pn) and pty and (pty == "creature" or pty == "permanent" or pty == "artifact" or pty == "planeswalker" or pty == "land") then
      local after = t2:match("put %w+ [%w%+/%-]+ counters? on target %a+ ([%a ]*)") or ""
      table.insert(actions, { what = "counterOn", who = "you", n = num(pn), kind = Counters.kindOf(pk), label = pk, ty = pty, mine = after:find("you control", 1, true) ~= nil,
        upTo = upTo, other = another })
    end
  end
  -- "remove an ice counter from ~" (Dark Depths).
  do
    local rn, rk = t:match("remove (%w+) ([%w%+/%-]+) counters? from ~")
    if rn and num(rn) and not t:find("^[^:]*remove [^:]*:") then
      local kind = Counters.kindOf(rk)
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
  if convergeNote then
    table.insert(notes, convergeNote)
  end
  return { optional = optional, actions = actions, notes = notes, conds = conds }
end

---------------------------------------------------------------------------
-- Forge effects (src/forge_effects_data.lua, tools/forge_effects.py)
---------------------------------------------------------------------------

-- Each Forge step becomes one plain sentence of the kind Effects.parse reads,
-- so the existing actions carry it out. A card without data, or an ability the
-- data can't express ("|?"), is read from its rules text as before.

local fxCache = {}
-- A card's Forge effect entries: { { key, optional, steps = { { api, p } } } } (steps = false: read the text).
local function forgeFxEntries(name)
  if FORGE_EFFECTS == nil or name == nil then
    return nil
  end
  local hit = fxCache[name]
  if hit ~= nil then
    return hit or nil
  end
  local raw = FORGE_EFFECTS[name]
  if raw == nil then
    fxCache[name] = false
    return nil
  end
  local list = {}
  for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
    local bar = line:find("|", 1, true)
    if bar then
      local key, rest = line:sub(1, bar - 1), line:sub(bar + 1)
      if rest == "?" then
        table.insert(list, { key = key, steps = false })
      else
        local bar2 = rest:find("|", 1, true) or 0
        local e = { key = key, optional = rest:sub(1, bar2 - 1) == "M", steps = {} }
        for part in (rest:sub(bar2 + 1) .. ">"):gmatch("([^>]*)>") do
          local colon = part:find(":", 1, true)
          if colon then
            local st = { api = part:sub(1, colon - 1), p = {} }
            for kv in (part:sub(colon + 1) .. ","):gmatch("([^,]*),") do
              local eq = kv:find("=", 1, true)
              if eq then
                st.p[kv:sub(1, eq - 1)] = kv:sub(eq + 1)
              end
            end
            table.insert(e.steps, st)
          end
        end
        table.insert(list, e)
      end
    end
  end
  fxCache[name] = list
  return list
end

local FX_NUM = { "a", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten" }
local function fxCount(n, word, plural)
  local v = tonumber(n) or 1
  return (FX_NUM[v] or tostring(v)) .. " " .. (v == 1 and word or (plural or (word .. "s")))
end
local function fxArticle(phrase)
  if phrase:find("^[aeiou]") then
    return "an " .. phrase
  end
  return "a " .. phrase
end
local FX_PLAYER = { you = "You", opp = "Each opponent", each = "Each player", tgtp = "Target player",
  tgto = "Target opponent", that = "That player" }
local FX_SIMPLE = { Scry = "Scry", Surveil = "Surveil" }

-- Forge counts ("$v.creature.you" = creatures you control...): worked out when the
-- ability resolves. Without a stack item (reading a card ahead of time) they count as 1.
local FX_BASICS = { "plains", "island", "swamp", "mountain", "forest" }

local function fxTypeLine(notes)
  local tl = tostring(notes or ""):match('"typeLine":"([^"]*)"') or ""
  return " " .. (tl:lower():gsub("[^%a]", " ")) .. " "
end

local function fxFieldCount(seat, words, ctrl, skipGuid)
  local n = 0
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and obj.held_by_color == nil then
      local owner = Effects.fieldSeat(obj)
      if owner and (ctrl == "all" or (ctrl == "you" and owner == seat) or (ctrl == "opp" and TableSetup.isOpponent(owner, seat)))
          and obj.getGUID() ~= skipGuid then
        local ty = Effects.cardTypes(obj)
        local tl
        local hit = false
        for _, w in ipairs(words) do
          if w == "permanent" or ty[w] then
            hit = true
          else
            tl = tl or fxTypeLine(obj.getGMNotes())
            if tl:find(" " .. w .. " ", 1, true) then
              hit = true
            end
          end
        end
        if hit then
          n = n + (Pile and Pile.count(obj) or 1)
        end
      end
    end
  end
  return n
end

local function fxYardCount(seat, words)
  local pile = Library and Library.pileIn and Library.pileIn(seat, "graveyard")
  if pile == nil then
    return 0
  end
  local notes = {}
  if pile.type == "Deck" then
    for _, e in ipairs(pile.getObjects()) do
      table.insert(notes, e.gm_notes or "")
    end
  else
    table.insert(notes, pile.getGMNotes())
  end
  local n = 0
  for _, g in ipairs(notes) do
    local tl = fxTypeLine(g)
    for _, w in ipairs(words) do
      if w == "permanent" or tl:find(" " .. w .. " ", 1, true) then
        n = n + 1
        break
      end
    end
  end
  return n
end

local FX_COUNT_SAYS = { hand = "cards in hand", life = "life", domain = "basic land types among your lands",
  yard = "cards in your graveyard" }

-- "$v.creature/artifact.you.o*2" -> number, what it counted.
function Effects.forgeCount(expr, it)
  local body, tail = tostring(expr):match("^%$([%a%./]+)(.*)$")
  if body == nil then
    return nil
  end
  local parts = {}
  for w in (body .. "."):gmatch("([^%.]*)%.") do
    table.insert(parts, w)
  end
  local kind = parts[1]
  local n, says
  if it == nil then
    n, says = 1, "counted when it resolves"
  else
    local seat = it.controller
    local src = it.source and getObjectFromGUID(it.source)
    local words = {}
    for w in tostring(parts[2] or ""):gmatch("[^/]+") do
      table.insert(words, w)
    end
    if kind == "v" then
      local ctrl = parts[3] or "all"
      n = fxFieldCount(seat, words, ctrl, parts[4] == "o" and it.source or nil)
      says = table.concat(words, "/") .. (ctrl == "you" and " you control" or (ctrl == "opp" and " your opponents control"
        or " on the battlefield"))
    elseif kind == "yard" then
      n = fxYardCount(seat, words)
      says = table.concat(words, "/") .. " cards in your graveyard"
    elseif kind == "hand" then
      n = 0
      pcall(function()
        for _, o in ipairs(Player[seat].getHandObjects()) do
          if o.type == "Card" then
            n = n + 1
          end
        end
      end)
      says = FX_COUNT_SAYS.hand
    elseif kind == "life" then
      local p = GameState.player(seat)
      n, says = p and tonumber(p.life) or nil, "your life"
    elseif kind == "domain" then
      n = 0
      for _, b in ipairs(FX_BASICS) do
        if fxFieldCount(seat, { b }, "you", nil) > 0 then
          n = n + 1
        end
      end
      says = FX_COUNT_SAYS.domain
    elseif kind == "pow" or kind == "tou" then
      local obj = parts[2] == "that" and it.thatCard and getObjectFromGUID(it.thatCard) or (parts[2] == "self" and src)
      if obj and not obj.isDestroyed() then
        local st = Counters.stats(obj)
        n = tonumber(kind == "pow" and st.power or st.toughness)
        says = (kind == "pow" and "power of " or "toughness of ") .. obj.getName()
      end
    elseif kind == "ctr" then
      if src and not src.isDestroyed() then
        n = Counters.get(src)[parts[2]]
        says = tostring(parts[2]) .. " counters on " .. src.getName()
      end
    end
  end
  if n == nil then
    return nil
  end
  for op, v in tostring(tail):gmatch("([%*%+%-])(%w*)") do
    local k = tonumber(v)
    if op == "*" and v == "h" then
      n = math.floor(n / 2)
    elseif op == "*" and v == "H" then
      n = math.ceil(n / 2)
    elseif op == "*" and k then
      n = n * k
    elseif op == "+" and k then
      n = n + k
    elseif op == "-" and k then
      n = n - k
    end
  end
  return math.max(0, n), says
end

-- A step's amount: a number, or a count. notes collects "X = 3 (creatures you control)".
local function fxNum(v, it, notes)
  local n = tonumber(v)
  if n then
    return n
  end
  local c, says = Effects.forgeCount(v, it)
  if c and notes and it then
    table.insert(notes, c .. " (" .. tostring(says) .. ")")
  end
  return c
end

local function fxTarget(p)
  return (p.o and "another target " or "target ") .. tostring(p.t)
end

-- One step -> a sentence (nil: not one the table can say).
local function fxSentence(st, name, it, notes)
  local p, api = st.p, st.api
  local n = fxNum(p.n or "1", it, notes)
  if n == nil then
    return nil
  end
  local w = p.w
  if api == "Draw" then
    if w == "you" then
      return "Draw " .. fxCount(n, "card") .. "."
    end
    return FX_PLAYER[w] and (FX_PLAYER[w] .. " draws " .. fxCount(n, "card") .. ".")
  elseif api == "GainLife" then
    if w == "you" then
      return "You gain " .. n .. " life."
    end
    return FX_PLAYER[w] and (FX_PLAYER[w] .. " gains " .. n .. " life.")
  elseif api == "LoseLife" then
    if w == "you" then
      return "You lose " .. n .. " life."
    end
    return FX_PLAYER[w] and (FX_PLAYER[w] .. " loses " .. n .. " life.")
  elseif api == "Mill" then
    if w == "you" then
      return "Mill " .. fxCount(n, "card") .. "."
    end
    return FX_PLAYER[w] and (FX_PLAYER[w] .. " mills " .. fxCount(n, "card") .. ".")
  elseif api == "Discard" then
    if w == "you" then
      return "Discard " .. fxCount(n, "card") .. "."
    end
    return FX_PLAYER[w] and (FX_PLAYER[w] .. " discards " .. fxCount(n, "card") .. ".")
  elseif api == "DealDamage" then
    local to = { any = "any target", tgtp = "target player", tgto = "target opponent", opp = "each opponent",
      each = "each player", that = "that player" }
    return to[w] and (name .. " deals " .. n .. " damage to " .. to[w] .. ".")
  elseif api == "DamageAll" then
    return name .. " deals " .. n .. " damage to each creature."
  elseif FX_SIMPLE[api] then
    return FX_SIMPLE[api] .. " " .. n .. "."
  elseif api == "PutCounter" or api == "PutCounterAll" then
    local what = fxArticle(tostring(p.c) .. " counter")
    if n ~= 1 then
      what = (FX_NUM[n] or tostring(n)) .. " " .. tostring(p.c) .. " counters"
    end
    local on = p.on == "self" and name or (p.on == "yours" and "each creature you control"
      or (p.on == "that" and "it") or (p.on == "tgt" and p.t and fxTarget(p)))
    return on and ("Put " .. what .. " on " .. on .. ".")
  elseif api == "Token" then
    local tapped = p.tap and not p.att and " tapped" or ""
    local tail = (p.tap and p.att) and " that are tapped and attacking" or ""
    if n == 1 and tail ~= "" then
      tail = " that's tapped and attacking"
    end
    if p.name then
      return "Create " .. fxCount(n, p.name .. " token") .. tapped .. tail .. "."
    end
    local col = (p.col == nil or p.col == "") and "colorless" or p.col
    local desc = tostring(p.pt) .. " " .. col .. " " .. tostring(p.sub or "") .. " " .. tostring(p.ty or "creature")
    desc = (desc:gsub("%s+", " "))
    local kw = (p.kw and p.kw ~= "") and (" with " .. p.kw) or ""
    if n == 1 then
      return "Create " .. fxArticle(desc .. " token") .. kw .. tapped .. tail .. "."
    end
    return "Create " .. (FX_NUM[n] or tostring(n)) .. " " .. desc .. " tokens" .. kw .. tapped .. tail .. "."
  elseif api == "Destroy" then
    return p.t and ("Destroy " .. fxTarget(p) .. ".")
  elseif api == "ChangeZone" then
    local bf = p.to == "bft" and "the battlefield tapped" or "the battlefield"
    if p.z == "bounce" then
      return "Return " .. fxTarget(p) .. " to its owner's hand."
    elseif p.z == "bounceSelf" then
      return "Return " .. name .. " to its owner's hand."
    elseif p.z == "exile" then
      return "Exile " .. fxTarget(p) .. "."
    elseif p.z == "graveHand" then
      local t = p.t == "card" and "card" or (tostring(p.t) .. " card")
      return "Return target " .. t .. " from your graveyard to your hand."
    elseif p.z == "reanimate" then
      local t = p.t == "card" and "card" or (tostring(p.t) .. " card")
      return "Return target " .. t .. " from your graveyard to " .. bf .. "."
    elseif p.z == "reanimateAny" then
      return "Put target creature card from a graveyard onto the battlefield under your control."
    elseif p.z == "yardSelf" then
      return "Return " .. name .. " from your graveyard to " .. (p.to == "hand" and "your hand" or bf) .. "."
    elseif p.z == "search" then
      local card = p.t == "any" and "a card" or fxArticle(tostring(p.t) .. " card")
      if p.mv then
        card = card .. " with mana value " .. p.mv .. " or less"
      end
      if p.to == "hand" then
        return "Search your library for " .. card .. ", reveal it, put it into your hand, then shuffle."
      end
      return "Search your library for " .. card .. ", put it onto the battlefield" .. (p.to == "bft" and " tapped" or "")
        .. ", then shuffle."
    end
    return nil
  elseif api == "Pump" or api == "PumpAll" then
    local who, plural = nil, false
    if p.on == "self" then
      who = name
    elseif p.on == "tgt" and p.t then
      local t = fxTarget(p)
      who = t:sub(1, 1):upper() .. t:sub(2)
    elseif p.on == "yours" then
      who, plural = "Creatures you control", true
    elseif p.on == "that" then
      who = "That creature"
    end
    if who == nil then
      return nil
    end
    local function signed(v)
      local sign, rest = tostring(v):match("^([+-])(.*)$")
      if sign == nil then
        return nil
      end
      local k = fxNum(rest, it, notes)
      return k and (sign .. k)
    end
    local a, b = signed(p.a), signed(p.b)
    if a == nil or b == nil then
      return nil
    end
    local parts = {}
    if a ~= "+0" or b ~= "+0" then
      table.insert(parts, (plural and "get " or "gets ") .. a .. "/" .. b)
    end
    if p.kw and p.kw ~= "" then
      table.insert(parts, (plural and "gain " or "gains ") .. p.kw)
    end
    if #parts == 0 then
      return nil
    end
    return who .. " " .. table.concat(parts, " and ") .. " until end of turn."
  elseif api == "Tap" or api == "Untap" then
    local on = p.on == "self" and name or (p.on == "that" and "that creature") or (p.t and fxTarget(p))
    return on and (api .. " " .. on .. ".")
  elseif api == "TapAll" or api == "UntapAll" then
    return p.t and ((api == "TapAll" and "Tap" or "Untap") .. " all " .. p.t .. ".")
  elseif api == "Sacrifice" then
    if p.self then
      return "Sacrifice " .. name .. "."
    end
    if w == "you" then
      return nil
    end
    local what = n == 1 and fxArticle(tostring(p.t)) or ((FX_NUM[n] or tostring(n)) .. " " .. tostring(p.t) .. "s")
    return FX_PLAYER[w] and p.t and (FX_PLAYER[w] .. " sacrifices " .. what .. ".")
  elseif api == "Counter" then
    return "Counter target " .. ((p.f and p.f ~= "") and (p.f .. " ") or "") .. "spell."
  elseif api == "Proliferate" then
    return "Proliferate."
  elseif api == "CopyPermanent" then
    if p.on == "self" then
      return "Create a token that's a copy of " .. name .. "."
    end
    return "Create a token that's a copy of target creature" .. (p.any and "" or " you control") .. "."
  elseif api == "Dig" then
    local look = "Look at the top " .. (FX_NUM[n] and n > 1 and FX_NUM[n] or tostring(n)) .. " cards of your library. "
    local rest = " Put the rest on the bottom of your library in any order."
    if p.q == nil or p.q == "" then
      return look .. "Put one of them into your hand and the rest on the bottom of your library in any order."
    end
    local into = p.to == "hand" and "put it into your hand."
      or ("put it onto the battlefield" .. (p.to == "bft" and " tapped." or "."))
    return look .. "You may reveal " .. fxArticle(p.q .. " card") .. " from among them and " .. into .. rest
  end
  return nil
end

-- Steps the rules-text reader has no words for: the table's own actions.
local function fxAction(st, it, notes)
  local p, api = st.p, st.api
  if api == "DealDamage" and p.w == "c" then
    local n = fxNum(p.n or "1", it, notes)
    local kinds = {}
    for k in tostring(p.k or "creature"):gmatch("[^/]+") do
      kinds[k] = true
    end
    return n and { what = "forgeDamage", who = "you", n = n, kinds = kinds, scope = p.c or "all",
      count = tonumber(p.m) or 1 }
  elseif api == "DamageAll" and (p.c ~= "all" or p.pl) then
    local n = fxNum(p.n or "1", it, notes)
    return n and { what = "forgeDamageAll", who = "you", n = n, cards = p.c, players = p.pl }
  elseif api == "ChangeZone" and p.z == "exileSelf" then
    return { what = "forgeExileSelf", who = "you", n = 1 }
  elseif api == "ChangeZone" and (p.z == "bounceThat" or p.z == "exileThat") then
    return { what = "forgeThat", who = "you", n = 1, verb = p.z == "bounceThat" and "bounce" or "exile" }
  elseif api == "Destroy" and p.that then
    return { what = "forgeThat", who = "you", n = 1, verb = "destroy" }
  elseif api == "DealDamage" and p.w == "thatc" then
    local n = fxNum(p.n or "1", it, notes)
    return n and { what = "forgeThat", who = "you", n = n, verb = "damage" }
  elseif api == "PayOrSac" then
    return { what = "forgePayOrSac", who = "you", n = 1, cost = p.cost }
  elseif api == "Animate" then
    local kinds = {}
    for k in tostring(p.k or ""):gmatch("[^/]+") do
      kinds[k] = true
    end
    return { what = "forgeAnimate", who = "you", n = 1, p = tonumber(p.p), t = tonumber(p.t), types = p.ty, kw = p.kw,
      on = p.on, kinds = kinds, scope = p.c or "all", other = p.o ~= nil, perm = p.perm ~= nil }
  elseif api == "GainControl" or api == "Regenerate" then
    local kinds = {}
    for k in tostring(p.k or ""):gmatch("[^/]+") do
      kinds[k] = true
    end
    return { what = api == "GainControl" and "forgeControl" or "forgeRegen", who = "you", n = 1, kinds = kinds,
      scope = p.c or "all", other = p.o ~= nil, on = p.on or "tgt", eot = p.eot ~= nil, untap = p.u ~= nil, haste = p.h ~= nil }
  elseif api == "AtStep" then
    return { what = "forgeAtStep", who = "you", n = 1, how = p["do"], on = p.of, step = p.st, mine = p.mine ~= nil }
  elseif api == "Flicker" then
    local kinds = {}
    for k in tostring(p.k or ""):gmatch("[^/]+") do
      kinds[k] = true
    end
    return { what = "forgeFlicker", who = "you", n = 1, on = p.on, kinds = kinds, scope = p.c or "all", other = p.o ~= nil,
      atEnd = p.when == "end" }
  elseif api == "Sacrifice" and p.w == "you" and not p.self then
    local n = fxNum(p.n or "1", it, notes)
    return n and { what = "edict", who = "you", n = n, scope = "you", ty = p.t }
  end
  return nil
end

-- The Forge entry for this paragraph of the card, or nil. The text must be a
-- single paragraph and exactly one of the card's entries must fit it.
function Effects.forgeFx(text, name)
  if GameState.data and GameState.data.forgeFxOff then
    return nil
  end
  local entries = forgeFxEntries(name)
  if entries == nil or not (Triggers and Triggers.forgeKey) then
    return nil
  end
  local raw = tostring(text or "")
  if Triggers.stripReminder then
    raw = Triggers.stripReminder(raw)
  end
  raw = ((raw:gsub("^%s+", "")):gsub("%s+$", ""))
  if raw == "" or raw:find("\n", 1, true) then
    return nil
  end
  local key = Triggers.forgeKey(raw, name)
  local hit
  for _, e in ipairs(entries) do
    if key ~= "" and key:sub(1, #e.key) == e.key then
      if hit then
        return nil
      end
      hit = e
    end
  end
  if hit == nil or hit.steps == false then
    return nil
  end
  -- A condition in the words ("if", "unless", "instead") may live on Forge's trigger
  -- line rather than in its effect: leave those to the text. Counts ("for each",
  -- "equal to") are fine when the entry counts them itself.
  local counted = false
  for _, st in ipairs(hit.steps) do
    for _, v in pairs(st.p) do
      if tostring(v):find("$", 1, true) then
        counted = true
      end
    end
  end
  local low = " " .. raw:lower() .. " "
  for _, m in ipairs(MANUAL) do
    local isCount = m ~= " if " and m ~= " unless " and m ~= " instead"
    if low:find(m, 1, true) and not (counted and isCount) then
      return nil
    end
  end
  return hit
end

-- The Forge entry as a plan of actions, or nil, plus what its counts came to.
local function forgePlan(text, name, it)
  local e = Effects.forgeFx(text, name)
  if e == nil then
    return nil
  end
  local nm = tostring(name or "it")
  local actions, notes = {}, {}
  for _, st in ipairs(e.steps) do
    local got = {}
    local direct = fxAction(st, it, notes)
    if direct then
      got = { direct }
    else
      local s = fxSentence(st, nm, it, notes)
      if s == nil then
        return nil
      end
      local ok, sp = pcall(Effects.parse, s, nm)
      if not ok or sp == nil then
        return nil
      end
      got = sp.actions or {}
      -- What the sentence can't say: how many cards are kept and where the rest go.
      if st.api == "Dig" then
        for _, a in ipairs(got) do
          if a.what == "look" then
            a.picks = tonumber(st.p.k) or a.picks
            a.restToYard = a.restToYard or st.p.yard ~= nil
          end
        end
      end
      -- What the sentence can't say: haste, not legendary, gone at the next end step, whose creature.
      if st.api == "CopyPermanent" then
        for _, a in ipairs(got) do
          if a.what == "copyCreature" or a.what == "copySelf" then
            a.haste = a.haste or st.p.h ~= nil
            a.nonlegendary = a.nonlegendary or st.p.nl ~= nil
            a.endHow = a.endHow or (st.p["end"] == "sacrifice" and "sacrifice") or (st.p["end"] == "exile" and "exile") or nil
            a.anyOwner = st.p.any ~= nil
          end
        end
      end
      -- What the sentence can't say: who gets the tokens, tapped / attacking.
      if st.api == "Token" then
        for _, a in ipairs(got) do
          if a.what == "token" then
            if st.p.w == "opp" then
              a.who = "opponents"
            elseif st.p.w == "each" then
              a.who = "all"
            end
            a.tapped = a.tapped or st.p.tap ~= nil
            a.attacking = a.attacking or st.p.att ~= nil
          end
        end
      end
    end
    -- Each step should read to at least one action; none means it was lost on the way.
    if #got == 0 then
      return nil
    end
    for _, a in ipairs(got) do
      table.insert(actions, a)
    end
  end
  if #actions == 0 then
    return nil
  end
  return { optional = e.optional, actions = actions, notes = {}, conds = {}, forge = true }, notes
end

-- The Forge entry as rules text ("You may draw a card. Scry 1."), or nil: for showing
-- what the data says (the table itself runs forgePlan).
function Effects.forgeSentence(text, name)
  local e = Effects.forgeFx(text, name)
  if e == nil then
    return nil
  end
  local out = {}
  for _, st in ipairs(e.steps) do
    local s = fxSentence(st, tostring(name or "it"), nil, nil) or ("[" .. st.api .. "]")
    table.insert(out, s)
  end
  local s = table.concat(out, " ")
  if e.optional then
    s = "You may " .. s:sub(1, 1):lower() .. s:sub(2)
  end
  return s, #out
end

-- The actions Forge's steps turn into. A text reading with any other action is a
-- card the table has its own handler for (The One Ring, Castle Locthwain...): it stays.
local FX_GENERIC = {}
for _, w in ipairs({ "draw", "gain", "lose", "mill", "discard", "mayDiscard", "scry", "counter", "counterOn",
  "counterAll", "token", "pump", "tap", "tapX", "tapTarget", "untap", "untapSelf", "untapAll", "removeTarget", "bounce",
  "bounceSelf", "graveReturn", "reanimate", "search", "look", "edict", "sacSelf", "counterSpell", "proliferate",
  "damageAll", "forgeDamage", "forgeDamageAll", "forgeExileSelf", "forgePayOrSac", "forgeThat", "forgeFlicker", "forgeAtStep", "forgeAnimate", "forgeControl", "forgeRegen",
  "blink", "copyCreature", "copySelf" }) do
  FX_GENERIC[w] = true
end

-- Effects.parse, preferring Forge's data for the paragraph when the rules text
-- reads to nothing or to fewer actions (on a tie the text's reading stands:
-- it already worked, and Forge's scripts have the odd slip too). `it` (the stack
-- item) lets Forge's counts be worked out; without it they count as 1.
function Effects.parseBest(text, name, it)
  local plan, why = Effects.parse(text, name)
  -- Our own readings that Forge's data would get wrong (a Class's "Level 2" is not Forge's level-up effect).
  if plan and plan.actions and plan.actions[1] and plan.actions[1].what == "classLevel" then
    return plan, why
  end
  local ok, fp, notes = pcall(forgePlan, text, name, it)
  if not ok or fp == nil then
    return plan, why
  end
  if plan ~= nil and (#plan.actions >= #fp.actions or #(plan.conds or {}) > 0) then
    -- A condition that's always true where the trigger can happen (eminence: "if ~ is in the command
    -- zone or on the battlefield") with nothing parsed for the rest: Forge's reading is better.
    local onlyWhere = #plan.actions == 0 and #(plan.conds or {}) == 1
      and tostring(plan.conds[1].cond):find("command zone or on the battlefield", 1, true) ~= nil
    if not onlyWhere then
      return plan, why
    end
  end
  for _, a in ipairs(plan and plan.actions or {}) do
    if not FX_GENERIC[a.what] then
      return plan, why
    end
  end
  if it and notes and #notes > 0 then
    printToAll("MTG > " .. tostring(name) .. ": X = " .. table.concat(notes, ", ") .. ".", INFO)
  end
  return fp
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
    return "add mana to the mana pool"
  elseif a.what == "sacMana" then
    return "sacrifice a creature, add mana of one color equal to 1 + its mana value (creature spells only)"
  elseif a.what == "handLand" then
    return "put a land card from your hand onto the battlefield" .. (a.tapped and " tapped" or "")
  elseif a.what == "descentBurst" then
    return "X Treasure tokens and X damage, X = the descent counters on this card"
  elseif a.what == "wheelMisfortune" then
    return "every player secretly picks a number; highest takes that much damage, everyone but the lowest discards their hand and draws seven"
  elseif a.what == "extraCombat" then
    return "an additional combat phase and postcombat main phase follow this turn's postcombat main phase"
  elseif a.what == "manaCount" then
    return "add {" .. tostring(a.color) .. "} for each " .. (a.tapped and "tapped " or "") .. tostring(a.word) .. " " .. (a.scope == "mine" and "you control" or "your opponents control")
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
  elseif a.what == "bite" then
    return "your creature deals damage equal to its power to a creature you don't control"
  elseif a.what == "powerHit" then
    return "damage equal to the creature's power to any target"
  elseif a.what == "carpetMana" then
    return "mana of one color for each Island the chosen opponent controls (once a turn)"
  elseif a.what == "manaAsk" then
    return "mana for each " .. tostring(a.label)
  elseif a.what == "copyThat" then
    return "a token copy of " .. tostring(a.which)
  elseif a.what == "openAttraction" then
    return "open " .. a.n .. " Attraction" .. (a.n == 1 and "" or "s")
  elseif a.what == "copyStack" then
    return "copy a " .. tostring(a.kind) .. " on the stack"
  elseif a.what == "revealCopy" then
    return "each opponent reveals their top card; if one shares a card type with the spell, copy the spell"
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
  elseif a.what == "forgeDamage" then
    return a.n .. " damage to a target " .. (a.kinds and a.kinds.planeswalker and not a.kinds.creature and "planeswalker"
      or (a.kinds and a.kinds.planeswalker and "creature or planeswalker" or "creature"))
  elseif a.what == "forgeDamageAll" then
    return a.n .. " damage to " .. (a.cards and "each creature" or "") .. (a.cards and a.players and " and " or "")
      .. (a.players == "opp" and "each opponent" or (a.players and "each player" or ""))
  elseif a.what == "forgeExileSelf" then
    return "it is exiled"
  elseif a.what == "forgeControl" then
    return "gain control of a target permanent" .. (a.eot and " until end of turn" or "")
  elseif a.what == "forgeRegen" then
    return "regenerate it"
  elseif a.what == "forgeAnimate" then
    return "becomes a " .. tostring(a.p) .. "/" .. tostring(a.t) .. " creature" .. (a.perm and "" or " until end of turn")
  elseif a.what == "forgeAtStep" then
    return "at the next " .. (a.step == "endcombat" and "end of combat" or "end step") .. ": " .. tostring(a.how) .. " it"
  elseif a.what == "forgeFlicker" then
    return "it is exiled and returns" .. (a.atEnd and " at the beginning of the next end step" or "")
  elseif a.what == "forgeThat" then
    return a.verb == "damage" and (a.n .. " damage to that creature") or ("that creature: " .. tostring(a.verb))
  elseif a.what == "forgePayOrSac" then
    return "pay " .. tostring(a.cost) .. " or sacrifice it"
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
  elseif a.what == "monarch" then
    return "becomes the monarch"
  elseif a.what == "initiative" then
    return "takes the initiative"
  elseif a.what == "bounceSelf" then
    return "it returns to its owner's hand"
  elseif a.what == "copySelf" then
    return "a token copy of itself"
  elseif a.what == "blinkSelf" then
    return "it is exiled and returns to the battlefield"
  elseif a.what == "drawGreatest" then
    return "draw cards equal to your greatest creature power"
  elseif a.what == "becomeBase" then
    return "it becomes " .. a.p .. "/" .. a.t
  elseif a.what == "tuckTarget" then
    return "a " .. tostring(a.kinds) .. " goes on top or bottom of its owner's library"
  elseif a.what == "sacLands" then
    return "sacrifice " .. a.n .. (a.untapped and " untapped" or "") .. " land" .. (a.n == 1 and "" or "s")
  elseif a.what == "bounceLand" then
    return "return a land to its owner's hand"
  elseif a.what == "freeCastHand" then
    return "cast a spell from the hand without paying its mana cost"
  elseif a.what == "landBonus" then
    return a.n .. " additional land play" .. (a.n == 1 and "" or "s") .. " this turn"
  elseif a.what == "colorCounters" then
    return "up to two creatures get a +1/+1 counter for each of their colors"
  elseif a.what == "jaredUlt" then
    return "a multicolored card returns from the graveyard (all colors: draw a card and two Treasures)"
  elseif a.what == "painfulTruths" then
    return "draw X cards and lose X life (X = colors spent)"
  elseif a.what == "bringToLight" then
    return "find a creature, instant or sorcery with mana value up to the colors spent and cast it free"
  elseif a.what == "guardianProject" then
    return "draw a card if its name is new"
  elseif a.what == "drawIfPower" then
    return "draw a card if you control a creature with power " .. tostring(a.power) .. " or greater"
  elseif a.what == "gainTarget" then
    return "a player gains " .. a.n .. " life"
  elseif a.what == "doubleCounters" then
    return "double the counters on the permanents you choose"
  elseif a.what == "nivReborn" then
    return "one card of each two-color pair from the top ten into the hand"
  elseif a.what == "tapTarget" then
    return "a creature is tapped"
  elseif a.what == "teferiProt" then
    return "protection from everything, life can't change, permanents phase out"
  elseif a.what == "reanimateAny" then
    return "a creature card from a graveyard comes back"
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
      or ("a +1/+1 counter on each " .. (a.other and "other " or "") .. (a.word and (a.word .. " ") or "") .. "creature you control"
        .. (a.words and (" that's a " .. table.concat(a.words, " or ")) or ""))
  elseif a.what == "scute" then
    return "an Insect token, or a copy of itself with six or more lands"
  elseif a.what == "eachPlayerToken" then
    return "each player creates a " .. tostring(a.word) .. " token"
  elseif a.what == "fellMighty" then
    return "destroy each creature with power greater than the chosen creature's"
  elseif a.what == "planCounter" then
    return "a plan counter on it"
  elseif a.what == "classLevel" then
    return "level " .. tostring(a.n)
  elseif a.what == "doubleSelfCounters" then
    return "double its +1/+1 counters"
  elseif a.what == "landfallForestCounters" then
    return "+1/+1 counter (two for a Forest)"
  elseif a.what == "untapLands" then
    return "untap up to " .. tostring(a.n) .. " lands"
  elseif a.what == "millLandToHand" then
    return "mill " .. tostring(a.n) .. ", a land from them to your hand"
  elseif a.what == "tapHost" then
    return (a.untap and "untap" or "tap") .. " the enchanted permanent"
  elseif a.what == "untapForest" then
    return "untap a Forest"
  elseif a.what == "fog" then
    return "prevent all combat damage this turn"
  elseif a.what == "countersSpellMV" then
    return "+1/+1 counters equal to that spell's mana value"
  elseif a.what == "drawUpTo" then
    return "draw up to " .. tostring(a.n) .. " cards in hand"
  elseif a.what == "cumUpkeep" then
    return "cumulative upkeep " .. tostring(a.cost)
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
  elseif a.what == "mayDiscard" then
    return who .. " may discard a card; if so: " .. tostring(a.rest)
  elseif a.what == "untapSelf" then
    return "this creature untaps"
  elseif a.what == "untapEquipped" then
    return "the equipped creature untaps"
  elseif a.what == "discardHand" then
    return "each player discards their hand"
  elseif a.what == "skipTurns" then
    return who .. " skip" .. (you and "" or "s") .. " the next " .. a.n .. " turns"
  elseif a.what == "allBut1" then
    return who .. " lose" .. (you and "" or "s") .. " all but 1 life"
  elseif a.what == "exileLibrary" then
    return who .. " exile" .. (you and "" or "s") .. " the whole library" .. (a.faceDown and " face down" or "")
  elseif a.what == "yardToLibrary" then
    return "the graveyard is shuffled into the library"
  elseif a.what == "oneRing" then
    return "a burden counter, then draw a card for each burden counter"
  elseif a.what == "loseBurden" then
    return "lose 1 life for each burden counter"
  elseif a.what == "handToTop" then
    return "put " .. a.n .. " cards from your hand on top of your library"
  elseif a.what == "winIfHand" then
    return "you win with exactly " .. a.n .. " cards in hand"
  elseif a.what == "rhystic" then
    return "you may draw a card unless that player pays " .. tostring(a.cost)
  elseif a.what == "extraTurn" then
    return (a.ask and "target player takes" or "you take") .. " an extra turn after this one"
  elseif a.what == "yuriko" then
    return "reveal the top card, put it into your hand; each opponent loses life equal to its mana value"
  elseif a.what == "winIfEmpty" then
    return "you win if your library is empty"
  elseif a.what == "teamKw" then
    return "your permanents gain " .. table.concat(a.kws, " and ") .. " until end of turn"
  elseif a.what == "kwTargetPerm" then
    return "a permanent you control gains " .. table.concat(a.kws, " and ") .. " until end of turn"
  elseif a.what == "damageAll" then
    return a.n .. " damage to each creature"
  elseif a.what == "bullies" then
    return "the opponent whose turn it is gets a nonlegendary creature card from your graveyard (haste, goaded, exiled at the next end step)"
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
  elseif a.what == "shuffleSelf" then
    return "it is shuffled into its owner's library"
  elseif a.what == "addlSac" then
    return "sacrifice a " .. tostring(a.kind) .. " (additional cost)"
  elseif a.what == "addlChoice" then
    return "pay the additional cost (" .. (a.sac and ("sacrifice a " .. a.sac .. " or ") or "") .. "discard a card"
      .. (a.life and (" or pay " .. a.life .. " life") or "") .. ")"
  elseif a.what == "searchLibOrYard" then
    return "search your library or graveyard for a " .. tostring(a.query) .. " with mana value " .. tostring(a.mvMax) .. " or less"
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
        if TableSetup.isOpponent(c, controller) then
          table.insert(seats, c)
        end
      end
    elseif a.who == "all" then
      seats = players()
    elseif a.who == "that" then
      seats = { it.that or target }
    elseif a.who == "any" and target == "other" then
      seats = {}
      if a.what == "lose" and Effects.pickDamage then
        Effects.pickDamage(controller, { n = amountOf(a, controller, it.name, it), kinds = { creature = true, planeswalker = true, battle = true },
          scope = "all", count = 1 }, it)
      else
        printToAll("MTG > " .. it.name .. ": " .. a.n .. " damage to a creature or planeswalker: change its damage / loyalty by hand.", INFO)
      end
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
                -- Noncombat damage: "whenever a source you control deals noncombat damage to an opponent"...
                if isDamage and Triggers and Triggers.onDamage then
                  local src = (it.source and getObjectFromGUID(it.source)) or (it.card and getObjectFromGUID(it.card)) or nil
                  pcall(Triggers.onDamage, { { obj = src, controller = controller, seat = seat, amount = v } }, false)
                end
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
          elseif a.where == "graveyard" then
            how = "click a card to put it into your graveyard"
          elseif a.handOrYard then
            how = "TO: HAND / TO: GRAVEYARD switches where it goes, then click the card"
          else
            how = "click a card to put it into your hand"
          end
          LibSearch.open(seat, a.query, it.name .. " (" .. tostring(a.phrase) .. "): " .. how .. (a.where == "top" and "." or ", then CLOSE + SHUFFLE."),
            (a.where == "hand" or a.where == "top" or a.where == "graveyard") and a.where or "battlefield", a.tapped,
            { typeOnly = true, mvMin = a.mvMin, mvMax = a.mvMax, anyOf = a.anyOf, reveal = a.reveal, handOrYard = a.handOrYard,
              limit = (a.where == "top" and 1) or a.upTo or nil,
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
          -- Cyclonic Rift: "Overload {6}{U}": each, not one.
          local srcCard = (it.guid and getObjectFromGUID(it.guid)) or (it.source and getObjectFromGUID(it.source))
          local srcText = srcCard and tostring(CardData.get(srcCard).oracle or ""):lower() or ""
          if srcText:find("\noverload {", 1, true) or srcText:sub(1, 10) == "overload {" then
            Effects.askChoice(seat, it.name .. ": overloaded?", "Did you cast it for its OVERLOAD cost? Then it returns EACH one instead of one target.",
              { { label = "OVERLOAD", value = true }, { label = "ONE TARGET", value = false } }, function(over)
                if over then
                  local n = 0
                  for _, o in ipairs(getObjectsWithTag("MTGCard")) do
                    if o.type == "Card" and not o.isDestroyed() and not Faces.unknown(o) then
                      local owner = Effects.fieldSeat(o)
                      local ty = Effects.cardTypes(o)
                      if owner and (not a.theirs or TableSetup.isOpponent(owner, seat)) and (not a.mine or owner == seat)
                          and (a.type == "permanent" or (a.type == "nonland" and not ty.land) or ty[a.type]) then
                        Effects.returnToHand(o)
                        n = n + 1
                      end
                    end
                  end
                  printToAll("MTG > " .. it.name .. " (overloaded): " .. n .. " permanent" .. (n == 1 and "" or "s") .. " returned to their owners' hands.", GOOD)
                else
                  Effects.pickBounce(seat, a, it.name, it.source)
                end
              end)
          else
            Effects.pickBounce(seat, a, it.name, it.source)
          end
        elseif a.what == "token" then
          local made = amountOf(a, controller, it.name, it)
          local opts = (a.tapped or a.attacking or a.haste)
            and { tapped = a.tapped, attacking = a.attacking, haste = a.haste, from = it.thatCard or it.source } or nil
          -- Living weapon: the Equipment goes onto the new Germ.
          if a.attachSelf and it.source then
            opts = opts or {}
            local attached = false
            opts.onSpawn = function(tok)
              local eq = getObjectFromGUID(it.source)
              if attached or eq == nil or eq.isDestroyed() or not Effects.fieldSeat(eq) then
                return
              end
              attached = true
              if Equip and Equip.attach then
                Equip.attach(eq, tok, controller)
              end
            end
          end
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
        elseif a.what == "monarch" then
          Effects.setMonarch(seat, it.name)
        elseif a.what == "initiative" then
          Effects.setInitiative(seat, it.name)
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
          -- "...to the battlefield with a finality counter on it" (Yuna, Hope of Spira): if it would go to a
          -- graveyard from the battlefield later, it's exiled instead (Effects.finality below).
          local finality = a.where == "battlefield" and tostring(it.text or ""):lower():find("finality counter", 1, true) ~= nil
          LibSearch.open(seat, a.type, it.name .. ": click the " .. (a.type ~= "" and a.type or "card") .. " to return it"
            .. (a.where == "battlefield" and " to the battlefield" or (a.where == "top" and " to the top of your library" or " to your hand"))
            .. (finality and " (with a finality counter)" or "") .. ", then CLOSE.",
            a.where, a.tapped, { typeOnly = true, zone = "graveyard", onTake = finality and function(card)
              GameState.data.finality = GameState.data.finality or {}
              GameState.data.finality[card.getGUID()] = true
              printToAll("MTG > " .. card.getName() .. " has a finality counter: if it would go to a graveyard from the battlefield, it's exiled instead.", INFO)
            end or nil })
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
          for _ = 1, (a.count or 1) do
            Effects.pickRemove(seat, a, it.name, it.source)
          end
        elseif a.what == "sacrifice" then
          Effects.pickSacrifice(seat, a, it)
        elseif a.what == "mayDiscard" then
          Effects.askChoice(seat, it.name .. ": discard a card?", "If you do: " .. tostring(a.rest),
            { { label = "DISCARD", value = true }, { label = "NO", value = false } }, function(yes)
              if not yes then
                printToAll("MTG > " .. seat .. " didn't discard (" .. it.name .. ").", INFO)
                return
              end
              Actions.forceDiscard(seat, 1, it.name, function()
                local copy = {}
                for k, v in pairs(it) do
                  copy[k] = v
                end
                copy.text = a.rest
                copy.modePicked = true
                copy.unlessDone = true
                Effects.resolve(copy)
              end)
            end)
        elseif a.what == "bullies" then
          Effects.bullies(seat, it)
        elseif a.what == "handToTop" then
          Actions.forceDiscard(seat, a.n, it.name, nil, "top")
        elseif a.what == "winIfHand" then
          local okh, hand = pcall(function() return Player[seat].getHandObjects() end)
          local n = okh and hand and #hand or 0
          if n == a.n then
            broadcastToAll(seat .. " WINS THE GAME (" .. it.name .. ": exactly " .. a.n .. " cards in hand)!", { 1, 0.85, 0.2 })
            printToAll("MTG > " .. seat .. " wins the game (" .. it.name .. ").", GOOD)
          else
            printToAll("MTG > " .. it.name .. ": " .. seat .. " has " .. n .. " cards in hand (needs exactly " .. a.n .. ").", INFO)
          end
        elseif a.what == "rhystic" then
          local caster = it.that
          if caster == nil or caster == seat then
            broadcastToColor(it.name .. ": resolve it by hand (couldn't tell who cast the spell).", seat, INFO)
          else
            Effects.askChoice(caster, it.name .. " (" .. seat .. ")", "Pay " .. a.cost .. "? If you don't, " .. seat .. " may draw a card.",
              { { label = "PAY " .. a.cost, value = true }, { label = "DON'T PAY", value = false } }, function(paid)
                if paid then
                  printToAll("MTG > " .. caster .. " pays " .. a.cost .. " for " .. it.name .. ".", INFO)
                  if ManaChips and ManaChips.pay then
                    ManaChips.pay(caster, a.cost, it.name)
                  end
                else
                  printToAll("MTG > " .. caster .. " doesn't pay: " .. seat .. " may draw (" .. it.name .. ").", INFO)
                  Effects.askChoice(seat, it.name .. ": draw a card?", caster .. " didn't pay.",
                    { { label = "DRAW", value = true }, { label = "NO", value = false } }, function(yes)
                      if yes then
                        Actions.draw(seat, 1, it.name)
                      end
                    end)
                end
              end)
          end
        elseif a.what == "extraTurn" then
          if a.ask then
            local choices = {}
            for _, c in ipairs(players()) do
              table.insert(choices, { label = string.upper(c), value = c })
            end
            Effects.askChoice(seat, it.name .. ": who takes an extra turn?", "Target player takes an extra turn after this one.", choices, function(who)
              if who then
                Turns.addExtraTurn(who)
              end
            end)
          else
            Turns.addExtraTurn(seat)
          end
        elseif a.what == "yuriko" then
          Effects.yurikoReveal(seat, it.name)
        elseif a.what == "winIfEmpty" then
          Wait.time(function()
            if Library.count(seat) == 0 then
              broadcastToAll(seat .. " WINS THE GAME (" .. it.name .. ": library is empty)!", { 1, 0.85, 0.2 })
              printToAll("MTG > " .. seat .. " wins the game (" .. it.name .. ").", GOOD)
            else
              printToAll("MTG > " .. it.name .. ": " .. seat .. "'s library isn't empty (" .. Library.count(seat) .. " left), no win.", INFO)
            end
          end, 1.2)
        elseif a.what == "oneRing" or a.what == "loseBurden" then
          -- Burden counters are the card's "Other" counters.
          local src = it.source and getObjectFromGUID(it.source)
          if src == nil or src.isDestroyed() then
            broadcastToColor(it.name .. " isn't on the table: do it by hand.", seat, INFO)
          elseif a.what == "oneRing" then
            Counters.change(src, "other", 1, seat)
            local n = Counters.get(src).other or 0
            Actions.draw(seat, n, it.name)
            printToAll("MTG > " .. it.name .. ": burden counter " .. n .. ", " .. seat .. " draws " .. n .. ".", GOOD)
          else
            local n = Counters.get(src).other or 0
            if n > 0 then
              Trackers.changeLife(seat, -n, it.name)
            end
            printToAll("MTG > " .. it.name .. ": " .. seat .. " loses " .. n .. " life (burden counters).", INFO)
          end
        elseif a.what == "repast" then
          Effects.askChoice(seat, it.name .. ": target creature", "Click TARGET: it gets a +1/+1 counter, hexproof and indestructible until end of turn, and untaps.",
            { { label = "SKIP", value = false } }, function(obj)
              if obj and not obj.isDestroyed() then
                Counters.place(obj, "plus", 1, seat)
                Counters.addTempKeyword(obj, "hexproof")
                Counters.addTempKeyword(obj, "indestructible")
                Effects.untapObj(obj)
                printToAll("MTG > " .. it.name .. ": " .. obj.getName() .. " gets a +1/+1 counter, hexproof and indestructible, and untaps.", GOOD)
              end
            end, { filter = function(o) return Effects.cardTypes(o).creature == true end, label = "TARGET" })
        elseif a.what == "teamKw" then
          local n = 0
          for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
            if obj.type == "Card" and not obj.isDestroyed() and Effects.fieldSeat(obj) == seat then
              for _, kw in ipairs(a.kws) do
                Counters.addTempKeyword(obj, kw)
              end
              n = n + 1
            end
          end
          printToAll("MTG > " .. it.name .. ": " .. seat .. "'s " .. n .. " permanents gain " .. table.concat(a.kws, " and ") .. " until end of turn.", GOOD)
        elseif a.what == "kwTargetPerm" then
          Effects.askChoice(seat, it.name .. ": " .. table.concat(a.kws, " and ") .. " until end of turn", "Click TARGET on a permanent you control.",
            { { label = "SKIP", value = false } }, function(obj)
              if obj and not obj.isDestroyed() then
                for _, kw in ipairs(a.kws) do
                  Counters.addTempKeyword(obj, kw)
                end
                printToAll("MTG > " .. obj.getName() .. " gains " .. table.concat(a.kws, " and ") .. " until end of turn (" .. it.name .. ").", GOOD)
              end
            end, { filter = function(o, owner) return owner == seat end, label = "TARGET" })
        elseif a.what == "damageAll" then
          Effects.damageAll(seat, a.n, it.name)
        elseif a.what == "discardHand" then
          local okh, hand = pcall(function() return Player[seat].getHandObjects() end)
          local n = okh and hand and #hand or 0
          if n > 0 then
            Actions.forceDiscard(seat, n, it.name)
          end
          printToAll("MTG > " .. seat .. " discards their hand (" .. n .. " card" .. (n == 1 and "" or "s") .. ", " .. it.name .. ").", INFO)
        elseif a.what == "skipTurns" then
          Turns.addSkip(seat, a.n)
          printToAll("MTG > " .. it.name .. ": " .. seat .. " skips their next " .. a.n .. " turn" .. (a.n == 1 and "" or "s") .. ".", { 1, 0.6, 0.3 })
        elseif a.what == "allBut1" then
          local p = GameState.player(seat)
          local lost = p and math.max(0, p.life - 1) or 0
          if lost > 0 then
            Trackers.changeLife(seat, -lost, it.name)
          end
          -- Soulgorger Orgg: "When it leaves the battlefield, you gain life equal to the life you lost to it."
          if it.source then
            GameState.data.lostTo = GameState.data.lostTo or {}
            GameState.data.lostTo[it.source] = { seat = seat, n = lost, name = it.name }
          end
          printToAll("MTG > " .. it.name .. ": " .. seat .. " loses " .. lost .. " life (down to 1).", { 1, 0.5, 0.4 })
        elseif a.what == "exileLibrary" then
          Effects.exileLibrary(seat, a.faceDown, it.name)
        elseif a.what == "yardToLibrary" then
          Effects.yardToLibrary(seat, it.name)
        elseif a.what == "untapSelf" or a.what == "untapEquipped" then
          local src = it.source and getObjectFromGUID(it.source)
          if src and a.what == "untapEquipped" and Equip and Equip.hostOf then
            src = Equip.hostOf(src)
          end
          if src and not src.isDestroyed() and Effects.fieldSeat(src) then
            Effects.untapObj(src)
            printToAll("MTG > " .. it.name .. ": " .. src.getName() .. " untaps.", GOOD)
          else
            broadcastToColor(it.name .. ": nothing to untap (it isn't on the battlefield).", seat, INFO)
          end
        elseif a.what == "sacDraw" then
          Effects.sacDraw(seat, a, it)
        elseif a.what == "blinkSelf" then
          local src = it.source and getObjectFromGUID(it.source)
          if src and not src.isDestroyed() then
            Effects.blinkCard(src, seat, it.name)
          else
            broadcastToColor(it.name .. ": blink the creature yourself (the card wasn't found).", seat, INFO)
          end
        elseif a.what == "copySelf" then
          local src = it.source and getObjectFromGUID(it.source)
          if src and not src.isDestroyed() then
            Effects.copyCard(src, seat, { haste = a.haste, endHow = a.endHow }, it.name)
          else
            broadcastToColor(it.name .. ": make the token copy yourself (the card wasn't found).", seat, INFO)
          end
        elseif a.what == "colorCounters" or a.what == "jaredUlt" or a.what == "painfulTruths" or a.what == "bringToLight"
            or a.what == "guardianProject" or a.what == "drawIfPower" or a.what == "gainTarget" or a.what == "doubleCounters"
            or a.what == "nivReborn" or a.what == "tapTarget" or a.what == "teferiProt" or a.what == "reanimateAny" then
          Effects.jaredDeck(seat, a, it)
        elseif a.what == "tuckTarget" or a.what == "sacLands" or a.what == "bounceLand" or a.what == "freeCastHand"
            or a.what == "landBonus" then
          Effects.misc2(seat, a, it)
        elseif a.what == "becomeBase" then
          local src = it.source and getObjectFromGUID(it.source)
          if src == nil or src.isDestroyed() then
            printToAll("MTG > " .. it.name .. " isn't on the battlefield any more.", INFO)
          else
            local c = Counters.get(src)
            if (c.bs or 0) < (a.needStage or 0) then
              printToAll("MTG > " .. it.name .. " isn't a " .. tostring(a.need) .. " yet: nothing happens.", INFO)
            else
              local parts = {}
              for k, v in src.memo:gmatch("(%a+)=(%-?%d+)") do
                if k ~= "bp" and k ~= "bt" and k ~= "bs" and k ~= "bk" then
                  table.insert(parts, k .. "=" .. v)
                end
              end
              table.insert(parts, "bp=" .. a.p)
              table.insert(parts, "bt=" .. a.t)
              table.insert(parts, "bs=" .. math.max(a.stage or 1, c.bs or 0))
              if a.kw or (c.bk or 0) > 0 then
                table.insert(parts, "bk=1")
              end
              src.memo = table.concat(parts, ";")
              Counters.render(src)
              printToAll("MTG > " .. it.name .. " becomes a " .. tostring(a.types):gsub("(%a)(%a*)", function(x, y) return x:upper() .. y end)
                .. " with base power and toughness " .. a.p .. "/" .. a.t .. (a.kw and ", flying and first strike" or "") .. ".", GOOD)
            end
          end
        elseif a.what == "drawGreatest" then
          local best = 0
          for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
            if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and Effects.fieldSeat(obj) == seat
                and Effects.cardTypes(obj).creature
                and not (a.nonHuman and tostring(CardData.get(obj).typeLine or ""):find("Human", 1, true)) then
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
              Combat.sacrifice(victim)
              Wait.time(function()
                LibSearch.open(seat, "creature", it.name .. ": click TWO creature cards in your graveyard to return them tapped, then CLOSE.",
                  "battlefield", true, { typeOnly = true, zone = "graveyard", yardOf = seat })
              end, 1.2)
            end, { filter = function(obj, owner)
              return owner == seat and Effects.cardTypes(obj).creature == true
            end, label = "SACRIFICE", protect = false })
        elseif a.what == "addManaAny" then
          Effects.askChoice(seat, it.name .. ": which color?", "Pick the color of mana to add to your mana pool.",
            { { label = "W", value = "W" }, { label = "U", value = "U" }, { label = "B", value = "B" },
              { label = "R", value = "R" }, { label = "G", value = "G" } }, function(k)
              ManaChips.add(seat, k, 1)
              printToAll("MTG > " .. it.name .. ": " .. seat .. " adds " .. k .. " to their mana pool.", GOOD)
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
        elseif a.what == "fellMighty" then
          Effects.fellMighty(seat, it)
        elseif a.what == "classLevel" then
          local src = it.source and getObjectFromGUID(it.source)
          if src and not src.isDestroyed() then
            local now = Effects.classLevel(src)
            if a.n ~= now + 1 then
              broadcastToColor(it.name .. " is level " .. now .. ": it can only go up to level " .. (now + 1) .. " next.", seat, INFO)
            else
              GameState.data.classLevels = GameState.data.classLevels or {}
              GameState.data.classLevels[src.getGUID()] = a.n
              printToAll("MTG > " .. it.name .. " is now level " .. a.n .. ".", GOOD)
              local becomes = tostring(CardData.get(src).oracle or ""):match("When this Class becomes level " .. a.n .. ", ([^\n]+)")
              if becomes then
                broadcastToColor(it.name .. " level " .. a.n .. ": " .. becomes .. " (do this part yourself).", seat, INFO)
              end
              pcall(Counters.render, src)
            end
          end
        elseif a.what == "planCounter" then
          local src = it.source and getObjectFromGUID(it.source)
          if src and not src.isDestroyed() then
            local before = Counters.get(src).other
            Counters.place(src, "other", 1, seat)
            local now = Counters.get(src).other
            printToAll("MTG > " .. it.name .. ": plan counter " .. now .. " of 4.", GOOD)
            if before < 4 and now >= 4 then
              printToAll("MTG > " .. it.name .. ": the fourth plan counter - it's sacrificed. " .. seat
                .. " puts an indestructible counter on target creature they control (by hand: right-click > Counters... > Other, and remember it's indestructible).", GOOD)
              Combat.sacrifice(src)
            end
          end
        elseif a.what == "doubleSelfCounters" then
          local src = it.source and getObjectFromGUID(it.source)
          if src and not src.isDestroyed() then
            local have = Counters.get(src).plus
            if have > 0 then
              local placed = Counters.place(src, "plus", have, seat)
              printToAll("MTG > " .. it.name .. ": +1/+1 counters doubled (" .. have .. " -> " .. (have + placed) .. ").", GOOD)
            else
              printToAll("MTG > " .. it.name .. " has no +1/+1 counters to double.", INFO)
            end
          end
        elseif a.what == "landfallForestCounters" then
          local src = it.source and getObjectFromGUID(it.source)
          local land = it.thatCard and getObjectFromGUID(it.thatCard)
          local forest = false
          pcall(function() forest = tostring(CardData.get(land).typeLine or ""):find("Forest", 1, true) ~= nil end)
          if src and not src.isDestroyed() then
            local placed = Counters.place(src, "plus", forest and 2 or 1, seat)
            printToAll("MTG > " .. it.name .. ": " .. placed .. " +1/+1 counter(s)" .. (forest and " (the land is a Forest)" or "") .. ".", GOOD)
          end
        elseif a.what == "untapLands" then
          Effects.untapLands(seat, a.n, it)
        elseif a.what == "millLandToHand" then
          Effects.millLandToHand(seat, a, it)
        elseif a.what == "tapHost" then
          local src = it.source and getObjectFromGUID(it.source)
          local host = src and Equip and Equip.hostOf and Equip.hostOf(src)
          if host and not host.isDestroyed() then
            local hs = TableSetup.seat(Effects.fieldSeat(host) or seat)
            local r = host.getRotation()
            host.setRotationSmooth({ r.x, (hs.yaw + (a.untap and 0 or 90)) % 360, r.z }, false, true)
            printToAll("MTG > " .. it.name .. ": " .. host.getName() .. (a.untap and " is untapped." or " is tapped."), GOOD)
          else
            broadcastToColor(it.name .. ": " .. (a.untap and "untap" or "tap") .. " the enchanted permanent yourself (attach the Aura first to have it done for you).", seat, INFO)
          end
        elseif a.what == "untapForest" then
          ask(seat, it.name .. ": untap a Forest", "Click UNTAP on the Forest to untap.", { { label = "SKIP", value = false } }, function(obj)
            if obj and not obj.isDestroyed() then
              local hs = TableSetup.seat(Effects.fieldSeat(obj) or seat)
              local r = obj.getRotation()
              obj.setRotationSmooth({ r.x, hs.yaw, r.z }, false, true)
              printToAll("MTG > " .. it.name .. ": " .. obj.getName() .. " is untapped.", GOOD)
            end
          end, { filter = function(obj, owner)
            return owner ~= nil and tostring(CardData.get(obj).typeLine or ""):find("Forest", 1, true) ~= nil
          end, label = "UNTAP", protect = false })
        elseif a.what == "fog" then
          GameState.data.fogTurn = (GameState.data.turn or {}).taken or 0
          GameState.data.fogBy = it.name
          printToAll("MTG > " .. it.name .. ": all combat damage this turn will be prevented.", GOOD)
        elseif a.what == "countersSpellMV" then
          local spell = it.thatCard and getObjectFromGUID(it.thatCard)
          local mv = 0
          pcall(function() mv = tonumber(CardData.get(spell).cmc) or 0 end)
          if mv <= 0 then
            printToAll("MTG > " .. it.name .. ": that spell's mana value is 0: no counters.", INFO)
          else
            Effects.counterOn(seat, { ty = "creature", kind = "plus", label = "+1/+1", n = mv, mine = true }, it)
          end
        elseif a.what == "drawUpTo" then
          local have = 0
          pcall(function() have = #(Player[seat].getHandObjects() or {}) end)
          local k = math.max(0, a.n - have)
          printToAll("MTG > " .. it.name .. ": " .. seat .. " has " .. have .. " card(s) in hand and draws " .. k .. ".", GOOD)
          if k > 0 then
            Actions.draw(seat, k, it.name)
          end
        elseif a.what == "cumUpkeep" then
          Effects.cumulativeUpkeep(seat, a, it)
        elseif a.what == "eachPlayerToken" then
          for _, c in ipairs(Effects.orderFrom(seat)) do
            Tokens.create(c, { words = { a.word }, colors = {} }, 1, it.name)
          end
        elseif a.what == "copyEachToken" then
          local n = 0
          for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
            if obj.type == "Card" and not obj.isDestroyed() and obj.hasTag("Token") and not Faces.unknown(obj)
                and Effects.fieldSeat(obj) == seat then
              n = n + (Pile and Pile.count(obj) or 1)
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
            Effects.copyCard(obj, seat, { pileCount = Pile and Pile.count(obj) or 1 }, it.name)
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
          printToAll("MTG > " .. it.name .. ": " .. seat .. " adds " .. table.concat(parts, ", ") .. " to their mana pool.", GOOD)
        elseif a.what == "sacMana" then
          local function colorAsk(x)
            Effects.askChoice(seat, it.name .. ": which color?", "Add " .. x .. " mana of one color to your mana pool (spend it only on creature spells).",
              { { label = "W", value = "W" }, { label = "U", value = "U" }, { label = "B", value = "B" },
                { label = "R", value = "R" }, { label = "G", value = "G" } }, function(k)
                ManaChips.add(seat, k, x)
                printToAll("MTG > " .. it.name .. ": " .. seat .. " adds " .. x .. " " .. k .. " to their mana pool (creature spells only).", GOOD)
              end)
          end
          Effects.askChoice(seat, it.name .. ": sacrifice a creature", "Click SACRIFICE on a creature you control (the additional cost). You add 1 + its mana value of one color.",
            { { label = "NONE", value = false } }, function(victim)
              if not victim or victim.isDestroyed() then
                printToAll("MTG > " .. seat .. " sacrifices nothing: " .. it.name .. " makes no mana.", INFO)
                return
              end
              local mv = 0
              pcall(function() mv = tonumber(JSON.decode(victim.getGMNotes()).cmc) or 0 end)
              printToAll("MTG > " .. seat .. " sacrifices " .. victim.getName() .. " (" .. it.name .. ").", GOOD)
              Combat.sacrifice(victim)
              colorAsk((a.plus and 1 or 0) + mv)
            end, { filter = function(obj, owner)
              return owner == seat and Effects.cardTypes(obj).creature == true
            end, label = "SACRIFICE", protect = false })
        elseif a.what == "handLand" then
          Effects.handLand(seat, a, it)
        elseif a.what == "descentBurst" then
          local src = it.source and getObjectFromGUID(it.source)
          local x = src and not src.isDestroyed() and (Counters.get(src).other or 0) or 0
          printToAll("MTG > " .. it.name .. ": X = " .. x .. " (descent counters).", INFO)
          if x > 0 then
            local order = Effects.orderFrom(seat)
            for i, c in ipairs(order) do
              if a.treasureWho == "all" or i > 1 then
                Tokens.create(c, { words = { "treasure" }, colors = {} }, x, it.name)
              end
            end
            for i, c in ipairs(order) do
              if a.damageWho == "all" or i > 1 then
                watched("damage", c, x, controller, it.name, function(v)
                  if v > 0 then
                    Trackers.changeLife(c, -v, it.name)
                  end
                end)
              end
            end
          end
        elseif a.what == "wheelMisfortune" then
          Effects.wheelMisfortune(controller, it)
        elseif a.what == "extraCombat" then
          Turns.addExtraCombatAfterMain(seat, a.untap)
        elseif a.what == "manaCount" then
          local k = Effects.countPermanents(seat, a.word, a.scope, a.tapped)
          if k > 0 then
            ManaChips.add(seat, a.color, k)
          end
          printToAll("MTG > " .. it.name .. ": " .. seat .. " adds " .. k .. " {" .. a.color .. "} ("
            .. (a.tapped and "tapped " or "") .. a.word .. "s " .. (a.scope == "mine" and "you control" or "your opponents control") .. ").", GOOD)
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
          Effects.sacTutor(seat, a, it)
        elseif a.what == "windfall" then
          Effects.windfall(it, a.fixed)
        elseif a.what == "bite" then
          Effects.askNumber(seat, it.name .. ": your creature's power?", "Type the power of the creature you chose, then OK. Put that much damage on the other creature by hand.", function(n)
            printToAll("MTG > " .. it.name .. ": " .. seat .. "'s creature deals " .. n .. " damage to the target creature: mark it on that creature (one-sided, it deals nothing back).", GOOD)
          end)
        elseif a.what == "powerHit" then
          Effects.powerHit(seat, a, it)
        elseif a.what == "carpetMana" then
          Effects.carpetMana(seat, a, it)
        elseif a.what == "manaAsk" then
          Effects.manaAsk(seat, a, it)
        elseif a.what == "copyThat" then
          Effects.copyThat(seat, a, it)
        elseif a.what == "revealCopy" then
          Effects.revealCopy(seat, a, it)
        elseif a.what == "copyStack" then
          Effects.copyStack(seat, a, it)
        elseif a.what == "openAttraction" then
          if Attractions then
            Attractions.open(seat, a.n, it.name)
          end
        elseif a.what == "tapX" then
          Effects.tapX(seat, a, it)
        elseif a.what == "blink" then
          Effects.blink(seat, a, it)
        elseif a.what == "copyCreature" then
          Effects.copyCreature(seat, a, it)
        elseif a.what == "forgeDamage" then
          Effects.pickDamage(seat, a, it)
        elseif a.what == "forgeDamageAll" then
          Effects.forgeDamageAll(seat, a, it)
        elseif a.what == "forgeExileSelf" then
          local src = it.source and getObjectFromGUID(it.source)
          if src and not src.isDestroyed() and Effects.fieldSeat(src) then
            printToAll("MTG > " .. it.name .. " is exiled.", GOOD)
            Combat.removeCard(src, "exile")
          else
            broadcastToColor(it.name .. ": exile it yourself.", seat, INFO)
          end
        elseif a.what == "forgePayOrSac" then
          Effects.payOrSacrifice(seat, a, it)
        elseif a.what == "forgeThat" then
          Effects.forgeThat(seat, a, it)
        elseif a.what == "forgeFlicker" then
          Effects.forgeFlicker(seat, a, it)
        elseif a.what == "forgeAnimate" then
          Effects.forgeAnimate(seat, a, it)
        elseif a.what == "forgeControl" then
          Effects.forgeControl(seat, a, it)
        elseif a.what == "forgeRegen" then
          Effects.forgeRegen(seat, a, it)
        elseif a.what == "forgeAtStep" then
          local obj = a.on == "that" and it.thatCard and getObjectFromGUID(it.thatCard)
            or (a.on == "self" and it.source and getObjectFromGUID(it.source)) or nil
          if obj and not obj.isDestroyed() and Effects.fieldSeat(obj) then
            Effects.addDelayed({ seat = seat, anySeat = not a.mine, step = a.step, kind = "forgeEnd", guid = obj.getGUID(), how = a.how,
              name = it.name })
            printToAll("MTG > " .. it.name .. ": at the next " .. (a.step == "endcombat" and "end of combat" or "end step") .. ", "
              .. obj.getName() .. " is " .. ({ sac = "sacrificed", destroy = "destroyed", exile = "exiled", bounce = "returned to its owner's hand" })[a.how]
              .. ".", INFO)
          end
        elseif a.what == "sacSelf" then
          local src = it.source and getObjectFromGUID(it.source)
          if src and not src.isDestroyed() then
            printToAll("MTG > " .. it.name .. " is sacrificed.", GOOD)
            Combat.sacrifice(src)
          else
            broadcastToColor(it.name .. ": sacrifice it yourself.", seat, INFO)
          end
        elseif a.what == "returnExiledWith" then
          Effects.returnExiledWith(seat, a, it)
        elseif a.what == "win" then
          broadcastToAll(seat .. " WINS THE GAME (" .. it.name .. ")!", { 1, 0.85, 0.2 })
          printToAll("MTG > " .. seat .. " wins the game (" .. it.name .. ").", GOOD)
        elseif a.what == "addlChoice" then
          local choices = {}
          if a.sac then
            table.insert(choices, { label = "SACRIFICE " .. string.upper(a.sac), value = "sac" })
          end
          if a.discard then
            table.insert(choices, { label = "DISCARD A CARD", value = "discard" })
          end
          if a.life then
            table.insert(choices, { label = "PAY " .. a.life .. " LIFE", value = "life" })
          end
          table.insert(choices, { label = "ALREADY PAID", value = false })
          Effects.askChoice(seat, it.name .. ": additional cost", "How do you pay the additional cost?", choices, function(v)
            if v == "discard" then
              Actions.forceDiscard(seat, 1, it.name)
            elseif v == "life" then
              Trackers.changeLife(seat, -a.life, it.name)
              printToAll("MTG > " .. seat .. " pays " .. a.life .. " life (" .. it.name .. ").", INFO)
            elseif v == "sac" then
              Effects.askChoice(seat, it.name .. ": sacrifice " .. (a.sac == "artifact" and "an " or "a ") .. a.sac,
                "Click SACRIFICE on the " .. a.sac .. " you sacrifice.", { { label = "CANCEL", value = false } }, function(victim)
                  if victim and not victim.isDestroyed() then
                    printToAll("MTG > " .. seat .. " sacrifices " .. victim.getName() .. " (" .. it.name .. ").", GOOD)
                    Combat.sacrifice(victim)
                  end
                end, { filter = function(o, owner)
                  return owner == seat and Effects.cardTypes(o)[a.sac] == true
                end, label = "SACRIFICE", protect = false })
            end
          end)
        elseif a.what == "addlSac" then
          Effects.askChoice(seat, it.name .. ": sacrifice " .. (a.kind == "artifact" and "an " or "a ") .. a.kind,
            "Click SACRIFICE on the " .. a.kind .. " you sacrifice (the additional cost of " .. it.name .. ").",
            { { label = "ALREADY DONE", value = false } }, function(victim)
              if victim and not victim.isDestroyed() then
                printToAll("MTG > " .. seat .. " sacrifices " .. victim.getName() .. " (" .. it.name .. ").", GOOD)
                Combat.sacrifice(victim)
              end
            end, { filter = function(o, owner)
              return owner == seat and Effects.cardTypes(o)[a.kind] == true
            end, label = "SACRIFICE", protect = false })
        elseif a.what == "shuffleSelf" then
          local card = it.card and getObjectFromGUID(it.card)
          if card and not card.isDestroyed() then
            it.cardHandled = true
            -- Into the library now (a creature search can't show it), shuffled
            -- once any search from the same spell is closed.
            card.setLock(false)
            Library.putAt(seat, card, 0, function()
              Wait.condition(function()
                local lib = Library.find(seat)
                if lib and lib.type == "Deck" then
                  lib.shuffle()
                end
                printToAll("MTG > " .. it.name .. " is shuffled into " .. seat .. "'s library.", INFO)
              end, function()
                return not (LibSearch.isOpen and LibSearch.isOpen(seat))
              end, 600)
            end)
          else
            broadcastToColor(it.name .. ": shuffle it into your library yourself.", seat, INFO)
          end
        elseif a.what == "searchLibOrYard" then
          local function go(zone)
            local note = it.name .. ": take a " .. a.query .. " with mana value up to " .. a.mvMax
              .. (a.where == "battlefield" and " onto the battlefield" or " into your hand")
              .. (zone == "graveyard" and " from your graveyard, then CLOSE." or ", then CLOSE + SHUFFLE.")
            LibSearch.open(seat, a.query, note, a.where, false,
              { typeOnly = true, mvMax = a.mvMax, zone = zone, yardOf = zone == "graveyard" and seat or nil })
          end
          ask(seat, it.name .. ": search where?", "Search your library or your graveyard?",
            { { label = "LIBRARY", value = "library" }, { label = "GRAVEYARD", value = "graveyard" } }, go)
          if a.bigX and tostring(it.text or ""):lower():find("10 or more, creatures you control get", 1, true) then
            broadcastToAll(it.name .. ": X is 10 or more, so " .. seat .. "'s creatures get +" .. a.mvMax .. "/+" .. a.mvMax
              .. " and haste until end of turn (add it by hand).", GOOD)
          end
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
            .. (a.permanentOnly and " (a PERMANENT card: not an instant or sorcery)" or "")
            .. ": " .. how .. ". CLOSE puts the rest " .. (a.restToYard and "into your graveyard." or "on the bottom."), a.where, a.tapped,
            { typeOnly = true, topN = a.n, picks = a.picks, restToYard = a.restToYard })
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
-- The question being shown right now (for tests and !unstick).
function Effects.currentQuestion()
  return current
end

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
        UI.setAttribute("effNumIn_" .. c, "characterValidation", q.number == "text" and "None" or "Integer")
        UI.setAttribute("effNumIn_" .. c, "placeholder", q.number == "text" and "type it here" or "X")
      end
      for i = 1, MAX_CHOICES do
        local ch = q.choices[i]
        UI.setAttribute("effChoice_" .. c .. "_" .. i, "active", ch and "true" or "false")
        if ch then
          UI.setValue("effChoiceTxt_" .. c .. "_" .. i, ch.label)
          -- Wide enough for longer labels ("YES, IT'S TRUE").
          UI.setAttribute("effChoice_" .. c .. "_" .. i, "preferredWidth", tostring(math.max(80, #tostring(ch.label) * 10 + 24)))
        end
      end
    end
  end
end

local function nextQuestion()
  -- (TTS's Lua errors on table.remove of an empty list.)
  current = #queue > 0 and table.remove(queue, 1) or nil
  if current == nil then
    Effects.replay = nil   -- everything that was resolving has been answered
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
  -- Targets chosen as it went on the stack: the resolving code's target prompts answer themselves.
  if not number and Effects.replay and Effects.replayAnswer then
    local okr, hit, v = pcall(Effects.replayAnswer, seat, title, text, choices, pick)
    if okr and hit then
      onPick(v)
      return
    end
  end
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

-- Is a question still waiting for an answer? (RESOLVE ALL waits for it before the next item.)
function Effects.busy()
  return current ~= nil or #queue > 0
end

-- !unstick: drop every waiting question (a stuck pop-up that nobody can answer).
function Effects.unstick()
  local n = #queue + (current and 1 or 0)
  queue = {}
  current = nil
  numTyped = {}
  pcall(render)
  return n
end

-- Ask for a word or two (a creature type): a text box with OK. onPick(text) only on an answer.
function Effects.askText(seat, title, text, onPick)
  ask(seat, title, text, { { label = "CANCEL", value = false } }, function(v)
    if v ~= false then
      onPick(v)
    end
  end, nil, "text")
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
    local why = Stack.uncounterable and Stack.uncounterable(e)
    if why then
      printToAll("MTG > " .. it.name .. " can't counter " .. e.name .. ": " .. why .. ".", { 1, 0.6, 0.2 })
      return
    end
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
  -- The spell it targeted as it was cast (CR 601.2c).
  local r = Effects.replay
  if r and r.seat == seat then
    for _, e in ipairs(r.entries) do
      if e.kind == "spell" and not e.used then
        e.used = true
        for _, c in ipairs(cands) do
          if c.guid == e.guid then
            counter(c)
            return
          end
        end
        printToAll("MTG > " .. it.name .. ": its target isn't a spell it can counter any more.", INFO)
        return
      end
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
      if a.other and it.source and obj.getGUID() == it.source then
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
  local spot = { x = pos.x + s.right.x * 3.2, y = pos.y + 0.6, z = pos.z + s.right.z * 3.2 }
  -- The copy must land on the SAME area as the original, or "enters the battlefield" never fires for it
  -- (a copy that slid off the battlefield was just a card sitting on the table).
  local here, there = Zones.regionAt(pos), Zones.regionAt(spot)
  if a.toField then
    local slot = TableSetup.slot(seat, "battlefield", TableSetup.SURFACE_TOP + 1.5)
    spot = { x = slot.x, y = slot.y, z = slot.z }
  elseif there.region ~= here.region or there.seat ~= here.seat then
    spot = { x = pos.x - s.right.x * 3.2, y = pos.y + 0.6, z = pos.z - s.right.z * 3.2 }
    there = Zones.regionAt(spot)
    if there.region ~= here.region or there.seat ~= here.seat then
      local slot = TableSetup.slot(seat, "battlefield", TableSetup.SURFACE_TOP + 1.5)
      spot = { x = slot.x, y = slot.y, z = slot.z }
    end
  end
  local c = obj.clone({ position = spot })
  if c == nil then
    broadcastToColor(srcName .. ": couldn't copy " .. obj.getName() .. " - make the token copy yourself.", seat, INFO)
    return nil
  end
  c.addTag("Token")
  c.memo = ""
  if a.toField then
    -- Cloned from a spell on the stack: that card is locked and turned toward the stack.
    c.setLock(false)
    c.setRotation({ 0, s.yaw, 0 })
  end
  Zones.presetFrom(c, seat)
  local pc = a.pileCount or 1
  if pc > 1 and Pile then
    Pile.set(c, pc)
  end
  -- Tell the table it arrived as soon as its card data is readable (enters triggers need the rules text).
  Wait.condition(function()
    if not c.isDestroyed() then
      Zones.refresh(c)
    end
  end, function()
    if c.isDestroyed() then
      return true
    end
    local ok, n = pcall(function() return c.getGMNotes() end)
    return ok and n ~= nil and n ~= ""
  end, 3, function()
    if not c.isDestroyed() then
      Zones.refresh(c)
    end
  end)
  Wait.time(function()
    if c.isDestroyed() then
      return
    end
    Zones.refresh(c)
    if pc > 1 and Pile then
      Pile.announceExtra(c, seat, pc)
      Pile.mergeSoon(1.5)
    end
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
    if (owner ~= seat and not a.anyOwner) or not Effects.cardTypes(obj).creature then
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
      if TableSetup.isOpponent(c, seat) then
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
              Combat.sacrifice(obj)
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
  elseif a.scope == "you" then
    victims = { seat }
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
      if a.words then
        local d = {}
        pcall(function() d = JSON.decode(obj.getGMNotes()) or {} end)
        local tl = " " .. tostring(d.typeLine or ""):lower():gsub("[^%a]", " ") .. " "
        ok = false
        for _, wd in ipairs(a.words) do
          if tl:find(" " .. wd .. " ", 1, true) then
            ok = true
          end
        end
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
    return (c.plus or 0) > 0 or (c.minus or 0) > 0 or (c.loyalty or 0) > 0 or (c.other or 0) > 0 or (c.pc or 0) > 0 or (c.tc or 0) > 0
  end
  local function step()
    ask(seat, it.name .. ": proliferate", "Click PROLIFERATE on each permanent with counters you want another counter on, then DONE."
      .. " (Players with poison or other counters: do those by hand.)", { { label = "DONE", value = false } }, function(obj)
      if obj then
        chosen[obj.getGUID()] = true
        for _, kind in ipairs({ "plus", "minus", "loyalty", "other", "pc", "tc" }) do
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
          Combat.sacrifice(obj)
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
          Combat.sacrifice(obj)
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
    if TableSetup.isOpponent(c, seat) then
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

-- Put a land card from hand onto the battlefield (Horizon of Progress, Oracle...). Lists the lands in
-- hand; the player picks one by number.
function Effects.handLand(seat, a, it)
  local lands = {}
  for _, o in ipairs(Player[seat].getHandObjects() or {}) do
    if o.type == "Card" and not o.isDestroyed() and Effects.cardTypes(o).land then
      table.insert(lands, o)
    end
  end
  if #lands == 0 then
    printToAll("MTG > " .. it.name .. ": " .. seat .. " has no land card in hand.", INFO)
    return
  end
  local lines, choices = {}, {}
  for i, o in ipairs(lands) do
    if #choices < 6 then
      table.insert(lines, i .. ") " .. o.getName())
      table.insert(choices, { label = tostring(i), value = i })
    end
  end
  table.insert(choices, { label = "NO", value = false })
  ask(seat, it.name .. ": put a land onto the battlefield" .. (a.tapped and " tapped" or ""), table.concat(lines, "\n"), choices, function(i)
    local land = i and lands[i]
    if not land or land.isDestroyed() then
      printToAll("MTG > " .. seat .. " puts no land onto the battlefield (" .. it.name .. ").", INFO)
      return
    end
    local st = TableSetup.seat(seat)
    land.setLock(false)
    land.setPositionSmooth(TableSetup.slot(seat, "lands", 2), false, true)
    land.setRotationSmooth({ 0, a.tapped and (st.yaw + 90) % 360 or st.yaw, 0 }, false, true)
    printToAll("MTG > " .. seat .. " puts " .. land.getName() .. " onto the battlefield" .. (a.tapped and " tapped" or "") .. " (" .. it.name .. ").", GOOD)
    Wait.time(function()
      if not land.isDestroyed() then
        Zones.refresh(land)
      end
    end, 1.2)
  end)
end

-- Station (Spacecraft / Planets): tap another creature you control, put charge counters equal to its power.
function Effects.station(obj, seat)
  local name = obj.getName()
  ask(seat, name .. ": Station", "Click TAP on an untapped creature you control. " .. name .. " gets charge counters equal to its power. (Station only as a sorcery.)",
    { { label = "CANCEL", value = false } }, function(c)
      if not c or c.isDestroyed() or obj.isDestroyed() then
        return
      end
      local power = tonumber(Counters.stats(c).power or "") or 0
      local st = TableSetup.seat(seat)
      local r = c.getRotation()
      c.setRotationSmooth({ r.x, (st.yaw + 90) % 360, r.z }, false, true)
      local before = Counters.get(obj).other
      Counters.change(obj, "other", power, seat)
      local total = before + power
      printToAll("MTG > " .. seat .. " stations " .. c.getName() .. " (power " .. power .. "): " .. name .. " has " .. total .. " charge counters.", GOOD)
      local oracle = ""
      pcall(function() oracle = tostring(JSON.decode(obj.getGMNotes()).oracle or "") end)
      for line in (oracle .. "\n"):gmatch("([^\n]*)\n") do
        local lvl = line:match("^(%d+)%+")
        if lvl and before < tonumber(lvl) and total >= tonumber(lvl) then
          printToAll("MTG > " .. name .. " reaches " .. lvl .. "+ charge counters: its level " .. lvl .. "+ ability is on (and it is a creature if it says so): " .. line:sub(1, 160), GOOD)
        end
      end
    end, { filter = function(o, owner)
      if owner ~= seat or o == obj or not Effects.cardTypes(o).creature then
        return false
      end
      local d = ((o.getRotation().y - (TableSetup.seat(seat) or { yaw = 0 }).yaw + 540) % 360) - 180
      return math.abs(d) <= 30
    end, label = "TAP", protect = false })
end

-- Wheel of Misfortune: everyone secretly picks a number (each player's own pop-up, in turn), then the
-- numbers are revealed: the highest takes that much damage, everyone who didn't pick the lowest
-- discards their hand and draws seven.
function Effects.wheelMisfortune(controller, it)
  local order = Effects.orderFrom(controller)
  local picks = {}
  local function reveal()
    local hi, lo
    local parts = {}
    for _, c in ipairs(order) do
      local n = picks[c] or 0
      table.insert(parts, c .. " " .. n)
      hi = (hi == nil or n > hi) and n or hi
      lo = (lo == nil or n < lo) and n or lo
    end
    printToAll("MTG > " .. it.name .. " reveals: " .. table.concat(parts, ", ") .. ". Highest " .. tostring(hi) .. ", lowest " .. tostring(lo) .. ".", GOOD)
    for _, c in ipairs(order) do
      if (picks[c] or 0) == hi and hi > 0 then
        Trackers.changeLife(c, -hi, it.name)
        printToAll("MTG > " .. it.name .. " deals " .. hi .. " damage to " .. c .. ".", GOOD)
      end
    end
    for _, c in ipairs(order) do
      if (picks[c] or 0) ~= lo then
        Actions.discardHand(c, it.name)
      end
    end
    Wait.time(function()
      for _, c in ipairs(order) do
        if (picks[c] or 0) ~= lo then
          Actions.draw(c, 7, it.name)
        end
      end
    end, 1.2)
  end
  local function nextPlayer(i)
    if i > #order then
      reveal()
      return
    end
    local c = order[i]
    ask(c, it.name .. ": secret number", "Type a number (0 or greater), then OK. Nobody else sees it until everyone has chosen.",
      { { label = "0", value = 0 } }, function(v)
        picks[c] = math.max(0, math.floor(tonumber(v) or 0))
        printToAll("MTG > " .. c .. " has chosen a number (" .. it.name .. ").", INFO)
        nextPlayer(i + 1)
      end, nil, true)
  end
  nextPlayer(1)
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

-- Carpet of Flowers: pick the opponent (each shows how many Islands they control), then a color;
-- that much mana is added. Only once a turn per card ("if you haven't added mana with this ability").
function Effects.carpetMana(seat, a, it)
  local turn = (GameState.data.turn or {}).taken or 0
  GameState.data.carpetUsed = GameState.data.carpetUsed or {}
  local key = tostring(it.source or it.name) .. "@" .. seat
  if GameState.data.carpetUsed[key] == turn then
    printToAll("MTG > " .. it.name .. ": already added mana this turn.", INFO)
    return
  end
  local choices = {}
  for _, c in ipairs(TableSetup.activeSeats()) do
    if c ~= seat and TableSetup.isOpponent(c, seat) then
      local n = Effects.countPermanents(c, "island", "mine")
      table.insert(choices, { label = c .. " (" .. n .. ")", value = { seat = c, n = n } })
    end
  end
  table.sort(choices, function(x, y) return x.value.n > y.value.n end)
  if #choices == 0 or choices[1].value.n == 0 then
    printToAll("MTG > " .. it.name .. ": no opponent controls an Island, so no mana.", INFO)
    return
  end
  table.insert(choices, { label = "NONE", value = false })
  ask(seat, it.name .. ": target opponent", "Pick an opponent: you add mana equal to the Islands they control (shown in brackets).",
    choices, function(pick)
      if not pick or pick.n == 0 then
        printToAll("MTG > " .. it.name .. ": " .. seat .. " adds no mana.", INFO)
        return
      end
      local colors = {}
      for _, c in ipairs({ "W", "U", "B", "R", "G" }) do
        table.insert(colors, { label = c, value = c })
      end
      ask(seat, it.name .. ": which color?", "Add " .. pick.n .. " mana of one color.", colors, function(color)
        GameState.data.carpetUsed[key] = turn
        ManaChips.add(seat, color, pick.n)
        printToAll("MTG > " .. it.name .. ": " .. seat .. " adds " .. pick.n .. " {" .. color .. "} (" .. pick.seat
          .. " controls " .. pick.n .. " Island" .. (pick.n == 1 and "" or "s") .. ").", GOOD)
      end)
    end)
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
      if TableSetup.isOpponent(c, seat) then
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
  local commander = Effects.controlsCommander(seat)
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
      Combat.sacrifice(obj)
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

-- Gandalf, Westward Voyager: each opponent reveals the top card of their
-- library. If one shares a card type with the spell that triggered it, the
-- spell is copied (and each opponent draws, as the card says); otherwise you
-- draw. The revealed cards go back on top.
local CARD_TYPES = { artifact = true, battle = true, creature = true, enchantment = true, instant = true,
  kindred = true, tribal = true, land = true, planeswalker = true, sorcery = true }

function Effects.revealCopy(seat, a, it)
  local spell = it.thatCard and getObjectFromGUID(it.thatCard)
  if spell == nil or spell.isDestroyed() then
    broadcastToColor(it.name .. ": the spell wasn't found - resolve this one by hand.", seat, INFO)
    return
  end
  local spellTypes = Effects.cardTypes(spell)
  local opps = {}
  for _, c in ipairs(players()) do
    if TableSetup.isOpponent(c, seat) then
      table.insert(opps, c)
    end
  end
  local revealed, hits = {}, 0
  local function finish()
    for _, r in ipairs(revealed) do
      if not r.card.isDestroyed() then
        Library.putAt(r.seat, r.card, 0)
      end
    end
    Wait.time(function()
      if hits > 0 then
        local copies = a.perCard and hits or 1
        for _ = 1, copies do
          Effects.copySpell(spell, seat, it.name)
        end
        if a.oppDraw then
          for _, c in ipairs(opps) do
            Library.draw(c, 1)
          end
          printToAll("MTG > " .. it.name .. ": each opponent draws a card.", INFO)
        end
      else
        printToAll("MTG > " .. it.name .. ": no revealed card shares a card type with " .. spell.getName()
          .. (a.elseDraw and (". " .. seat .. " draws a card.") or "."), INFO)
        if a.elseDraw then
          Library.draw(seat, 1)
        end
      end
    end, 1.2)
  end
  local function step(i)
    if i > #opps then
      -- Leave the revealed cards up for a moment so everyone sees them.
      Wait.time(finish, 2.5)
      return
    end
    local opp = opps[i]
    Library.revealTop(opp, function(card)
      if card == nil then
        printToAll("MTG > " .. it.name .. ": " .. opp .. "'s library is empty.", INFO)
      else
        table.insert(revealed, { seat = opp, card = card })
        local shared = {}
        for ty in pairs(Effects.cardTypes(card)) do
          if CARD_TYPES[ty] and spellTypes[ty] then
            table.insert(shared, ty)
          end
        end
        if #shared > 0 then
          hits = hits + 1
        end
        printToAll("MTG > " .. it.name .. ": " .. opp .. " reveals " .. card.getName()
          .. (#shared > 0 and (" (shares " .. table.concat(shared, ", ") .. ")") or " (no shared card type)") .. ".", GOOD)
      end
      Wait.time(function() step(i + 1) end, 0.6)
    end)
  end
  if #opps == 0 then
    finish()
  else
    step(1)
  end
end

-- Birthing Pod / Eldritch Evolution: search for a creature worth N more than
-- the sacrificed one. Pod's sacrifice was made while activating (stack.lua
-- remembers it); for Eldritch Evolution the player clicks the creature now.
function Effects.sacTutor(seat, a, it)
  local function search(sacMv)
    local mv = (tonumber(sacMv) or 0) + a.plus
    LibSearch.open(seat, "creature", it.name .. ": take a creature with mana value " .. (a.exact and "" or "up to ") .. mv
      .. " onto the battlefield, then CLOSE + SHUFFLE.", "battlefield", false,
      { typeOnly = true, mvMin = a.exact and mv or nil, mvMax = mv })
  end
  local function typeIt()
    Effects.askNumber(seat, it.name .. ": sacrificed creature's mana value?", "Type the mana value of the creature you sacrificed, then OK. The search is for mana value "
      .. (a.exact and "exactly " or "") .. "that + " .. a.plus .. (a.exact and "." or " or less."), search)
  end
  local ls = GameState.data.lastSac
  if ls and ls.seat == seat and os.time() - (ls.at or 0) < 300 then
    GameState.data.lastSac = nil
    printToAll("MTG > " .. it.name .. ": " .. tostring(ls.name) .. " was sacrificed (mana value " .. ls.mv .. ").", INFO)
    search(ls.mv)
    return
  end
  Effects.askChoice(seat, it.name .. ": sacrifice a creature", "Click SACRIFICE on the creature you sacrifice for " .. it.name
    .. ". (TYPE IT if you already sacrificed it.)", { { label = "TYPE IT", value = false } }, function(obj)
      if not obj or obj.isDestroyed() then
        typeIt()
        return
      end
      local mv = 0
      pcall(function() mv = tonumber(CardData.get(obj).cmc) or 0 end)
      printToAll("MTG > " .. seat .. " sacrifices " .. obj.getName() .. " (mana value " .. mv .. ") for " .. it.name .. ".", GOOD)
      Combat.sacrifice(obj)
      search(mv)
    end, { filter = function(o, owner)
      return owner == seat and Effects.cardTypes(o).creature == true
    end, label = "SACRIFICE", protect = false })
end

-- Put a copy of a spell on the stack. It resolves first (it's on top): an
-- instant or sorcery copy does what the card says; a permanent spell's copy
-- becomes a token copy on the controller's battlefield.
function Effects.copySpell(spell, seat, srcName)
  local image = ""
  pcall(function() image = spell.getCustomObject().face or "" end)
  Stack.pushAbility(seat, spell.getName(), spell.getDescription(), image, { copyOf = spell.getGUID() })
  printToAll("MTG > " .. srcName .. ": " .. seat .. " copies " .. spell.getName() .. ". The copy is on the stack"
    .. " (new targets are picked when it resolves).", GOOD)
end

-- Copy a spell or ability that's on the stack. With more than one that fits,
-- the controller picks which.
function Effects.copyStack(seat, a, it)
  local list = {}
  for _, e in ipairs(Stack.entries()) do
    local obj = getObjectFromGUID(e.guid)
    local ok = obj ~= nil and not (a.mine and e.controller ~= seat)
    if ok and e.kind == "card" then
      local ty = Effects.cardTypes(obj)
      local permanent = ty.creature or ty.artifact or ty.enchantment or ty.planeswalker or ty.battle or ty.land
      ok = a.kind == "spell" or (a.kind == "permanent" and permanent)
        or (a.kind == "instsorc" and (ty.instant or ty.sorcery) and not permanent)
    elseif ok then
      ok = (a.kind == "ability" or (a.kind == "triggered" and e.trigger)) and e.copyOf == nil
    end
    if ok then
      table.insert(list, e)
    end
  end
  local function copy(e)
    local obj = getObjectFromGUID(e.guid)
    if obj == nil then
      return
    end
    if e.kind == "card" then
      Effects.copySpell(obj, seat, it.name)
      return
    end
    local image = ""
    pcall(function() image = obj.getCustomObject().image or "" end)
    Stack.pushAbility(seat, e.name, e.text, image, { trigger = e.trigger, activated = not e.trigger, source = e.source,
      that = e.that, thatCard = e.thatCard, amount = e.amount })
    printToAll("MTG > " .. it.name .. ": " .. seat .. " copies " .. tostring(e.name) .. "'s ability. The copy is on the stack.", GOOD)
  end
  if #list == 0 then
    broadcastToColor(it.name .. ": there's nothing on the stack it can copy.", seat, INFO)
  elseif #list == 1 then
    copy(list[1])
  else
    local choices = {}
    for i = #list, math.max(1, #list - 5), -1 do
      table.insert(choices, { label = string.upper(tostring(list[i].name)):sub(1, 24), value = i })
    end
    ask(seat, it.name .. ": copy what?", "Pick the spell or ability to copy (top of the stack first).", choices, function(i)
      if list[i] then
        copy(list[i])
      end
    end)
  end
end

function Effects.resolveCopy(it)
  local spell = getObjectFromGUID(it.copyOf)
  if spell == nil or spell.isDestroyed() then
    broadcastToColor(it.name .. " (copy): the original card wasn't found - resolve the copy by hand.", it.controller, INFO)
    return
  end
  local ty = Effects.cardTypes(spell)
  if ty.creature or ty.artifact or ty.enchantment or ty.planeswalker or ty.battle or ty.land then
    -- A copy of a permanent spell isn't "created", so token doublers don't apply.
    Effects.copyCard(spell, it.controller, { toField = true, noMods = true }, it.name)
    printToAll("MTG > The copy of " .. spell.getName() .. " resolves: a token copy enters for " .. it.controller .. ".", GOOD)
    return
  end
  local text, cost = "", ""
  pcall(function()
    local d = JSON.decode(spell.getGMNotes())
    if type(d) == "table" and type(d.oracle) == "string" then
      text = d.oracle
      cost = tostring(d.manaCost or "")
    end
  end)
  if text == "" then
    broadcastToColor("The copy of " .. spell.getName() .. ": no rules text found - resolve it by hand.", it.controller, INFO)
    return
  end
  printToAll("MTG > The copy of " .. spell.getName() .. " resolves.", GOOD)
  Effects.resolve({ name = spell.getName() .. " (copy)", controller = it.controller, text = text, auto = true,
    manaCost = cost, card = spell.getGUID() })
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

-- The Jared Carthalion deck's effects.
local ALLC = { "W", "U", "B", "R", "G" }

local function dataColors(d)
  if tostring(d.oracle or ""):lower():find("is all colors", 1, true) then
    return { W = true, U = true, B = true, R = true, G = true }, 5
  end
  local set, n = {}, 0
  for _, c in pairs(type(d.colors) == "table" and d.colors or {}) do
    local k = tostring(c):upper()
    if not set[k] then
      set[k] = true
      n = n + 1
    end
  end
  -- No color list stored (some imports): read the mana cost instead ("{1}{U}{R}", hybrid "{W/U}").
  if n == 0 and d.manaCost and d.manaCost ~= "" then
    for sym in tostring(d.manaCost):gmatch("{([^}]+)}") do
      for c in sym:upper():gmatch("[WUBRG]") do
        if not set[c] then
          set[c] = true
          n = n + 1
        end
      end
    end
  end
  return set, n
end

local function colorsSpentAsk(seat, it, text, onPick)
  local ch = {}
  for i = 1, 5 do
    table.insert(ch, { label = tostring(i), value = i })
  end
  ask(seat, it.name .. ": how many colors of mana did you spend?", text, ch, onPick)
end

function Effects.jaredDeck(seat, a, it)
  local w = a.what
  if w == "colorCounters" then
    -- Jared −3: up to two creatures, +1/+1 counters equal to their number of colors.
    local picked = {}
    local function one(left)
      if left <= 0 then
        return
      end
      ask(seat, it.name .. ": counters by colors", "Click COUNTERS on a creature (up to " .. left .. " more): it gets a +1/+1 counter for each of its colors. DONE to stop.",
        { { label = "DONE", value = false } }, function(obj)
          if not obj then
            return
          end
          picked[obj.getGUID()] = true
          local n = (Statics and Statics.colorCount) and Statics.colorCount(obj) or 0
          if n > 0 then
            local placed = Counters.place(obj, "plus", n, seat)
            printToAll("MTG > " .. it.name .. ": " .. obj.getName() .. " is " .. n .. " color" .. (n == 1 and "" or "s") .. ": " .. placed .. " +1/+1 counters.", GOOD)
          else
            printToAll("MTG > " .. it.name .. ": " .. obj.getName() .. " is colorless: no counters.", INFO)
          end
          one(left - 1)
        end, { filter = function(obj)
          return not picked[obj.getGUID()] and Effects.cardTypes(obj).creature == true
        end, label = "COUNTERS", protect = false })
    end
    one(a.n or 2)
  elseif w == "jaredUlt" then
    LibSearch.open(seat, "", it.name .. ": click a MULTICOLORED card to return it to your hand, then CLOSE.", "hand", false,
      { zone = "graveyard", minColors = 2, limit = 1, onTake = function(card)
        local _, n = dataColors(CardData.get(card))
        if n >= 5 then
          printToAll("MTG > " .. it.name .. ": " .. card.getName() .. " is all colors: " .. seat .. " draws a card and creates two Treasures.", GOOD)
          Actions.draw(seat, 1, it.name)
          Tokens.create(seat, { words = { "treasure" }, colors = {} }, 2, it.name)
        end
      end })
  elseif w == "painfulTruths" then
    colorsSpentAsk(seat, it, "Converge: you draw that many cards and lose that much life.", function(x)
      printToAll("MTG > " .. it.name .. ": " .. x .. " colors spent: " .. seat .. " draws " .. x .. " and loses " .. x .. " life.", GOOD)
      Actions.draw(seat, x, it.name)
      if Trackers and Trackers.changeLife then
        Trackers.changeLife(seat, -x)
      end
    end)
  elseif w == "bringToLight" then
    colorsSpentAsk(seat, it, "Converge: find a creature, instant or sorcery with mana value up to that many.", function(x)
      LibSearch.open(seat, "", it.name .. ": pick a creature, instant or sorcery (mana value " .. x .. " or less). It comes to your hand: cast it right away without paying its mana cost (by the rules it's exiled, then cast).",
        "hand", false, { typeOnly = true, anyOf = { "creature", "instant", "sorcery" }, mvMax = x, limit = 1, fixedDest = true })
    end)
  elseif w == "guardianProject" then
    local card = (it.thatCard and getObjectFromGUID(it.thatCard)) or (it.that and type(it.that) == "string" and getObjectFromGUID(it.that))
    if card == nil or card.isDestroyed() then
      printToAll("MTG > " .. it.name .. ": the creature isn't on the table any more: check its name by hand.", INFO)
      return
    end
    local nm = card.getName()
    local clash = false
    for _, o in ipairs(getObjectsWithTag("MTGCard")) do
      if o ~= card and o.type == "Card" and not o.isDestroyed() and o.getName() == nm and Effects.fieldSeat(o) == seat
          and Effects.cardTypes(o).creature then
        clash = true
      end
    end
    local yard = Library.pileIn and Library.pileIn(seat, "graveyard")
    if yard and not clash then
      local list = yard.type == "Deck" and (yard.getData().ContainedObjects or {}) or { yard.getData() }
      for _, e in ipairs(list) do
        if e.Nickname == nm then
          clash = true
        end
      end
    end
    if clash then
      printToAll("MTG > " .. it.name .. ": " .. seat .. " already has a " .. nm .. ": no card.", INFO)
    else
      Actions.draw(seat, 1, it.name)
    end
  elseif w == "drawIfPower" then
    local ok = false
    for _, o in ipairs(getObjectsWithTag("MTGCard")) do
      if o.type == "Card" and not o.isDestroyed() and Effects.fieldSeat(o) == seat and Effects.cardTypes(o).creature
          and (tonumber(Counters.stats(o).power) or 0) >= (a.power or 4) then
        ok = true
      end
    end
    if ok then
      Actions.draw(seat, 1, it.name)
    else
      printToAll("MTG > " .. it.name .. ": " .. seat .. " controls no creature with power " .. tostring(a.power) .. " or greater: no card.", INFO)
    end
  elseif w == "gainTarget" then
    local ch = {}
    for _, c in ipairs(TableSetup.activeSeats()) do
      table.insert(ch, { label = string.upper(c), value = c })
    end
    ask(seat, it.name .. ": who gains " .. a.n .. " life?", "Pick the player.", ch, function(c)
      if Trackers and Trackers.changeLife then
        Trackers.changeLife(c, a.n)
      end
      printToAll("MTG > " .. it.name .. ": " .. c .. " gains " .. a.n .. " life.", GOOD)
    end)
  elseif w == "doubleCounters" then
    -- Deepglow Skate: double each kind of counter on any number of permanents (Doubling Season makes it more).
    local done = {}
    local function step()
      ask(seat, it.name .. ": double counters", "Click DOUBLE on each permanent whose counters double, then DONE.",
        { { label = "DONE", value = false } }, function(obj)
          if not obj then
            return
          end
          done[obj.getGUID()] = true
          local c = Counters.get(obj)
          for _, kind in ipairs({ "plus", "minus", "loyalty", "other", "pc", "tc" }) do
            if (c[kind] or 0) > 0 then
              Counters.place(obj, kind, c[kind], seat)
            end
          end
          printToAll("MTG > " .. it.name .. ": counters on " .. obj.getName() .. " doubled.", GOOD)
          step()
        end, { filter = function(obj)
          if done[obj.getGUID()] then
            return false
          end
          local c = Counters.get(obj)
          return (c.plus or 0) + (c.minus or 0) + (c.loyalty or 0) + (c.other or 0) + (c.pc or 0) + (c.tc or 0) > 0
        end, label = "DOUBLE", protect = false })
    end
    step()
  elseif w == "nivReborn" then
    local okN, errN = pcall(Effects.nivReborn, seat, it)
    if not okN then
      printToAll("MTG > " .. it.name .. ": couldn't finish it (" .. tostring(errN) .. "). Resolve it by hand.", INFO)
    end
  elseif w == "tapTarget" then
    ask(seat, it.name .. ": tap a creature?", "Click TAP on the creature to tap" .. (a.may and ", or SKIP." or "."),
      { { label = "SKIP", value = false } }, function(obj)
        if obj then
          local owner = Effects.fieldSeat(obj)
          if owner then
            turnTapped(obj, owner, true)
          end
          printToAll("MTG > " .. it.name .. ": " .. obj.getName() .. " is tapped.", GOOD)
        end
      end, { filter = function(obj)
        return Effects.cardTypes(obj).creature == true
      end, label = "TAP" })
  elseif w == "teferiProt" then
    GameState.data.playerPro = GameState.data.playerPro or {}
    GameState.data.playerPro[seat] = true
    broadcastToAll(seat .. " has PROTECTION FROM EVERYTHING until their next turn and their life total can't change (" .. it.name .. ").", { 1, 0.85, 0.3 })
    printToAll("MTG > " .. it.name .. ": all of " .. seat .. "'s permanents PHASE OUT until their next turn: treat them as not there "
      .. "(board wipes and removal skip them; they can't block). Undo any change to " .. seat .. "'s life by hand. " .. it.name .. " is exiled.", { 1, 0.6, 0.2 })
  elseif w == "reanimateAny" then
    printToAll("MTG > " .. it.name .. ": put the creature card from a graveyard onto the battlefield under its OWNER's control by hand (drag it there).", { 1, 0.6, 0.2 })
  end
end

-- Niv-Mizzet Reborn: reveal the top ten; for each two-color pair, one card that's exactly those colors goes
-- to the hand; the rest go on the bottom in a random order.
function Effects.nivReborn(seat, it)
  local lib = Library.find(seat)
  if lib == nil then
    printToAll("MTG > " .. it.name .. ": no library found.", INFO)
    return
  end
  if lib.type ~= "Deck" then
    printToAll("MTG > " .. it.name .. ": only one card in the library: check it by hand.", INFO)
    return
  end
  local data = lib.getData()
  local objs, ids = data.ContainedObjects or {}, data.DeckIDs or {}
  local n = math.min(10, #objs)
  local taken, takenPair, names, chosenNames = {}, {}, {}, {}
  for i = 1, n do
    local e = objs[i]
    local d = {}
    pcall(function() d = JSON.decode(e.GMNotes or "") or {} end)
    table.insert(names, e.Nickname or "?")
    local set, cnt = dataColors(d)
    if cnt == 2 then
      local key = ""
      for _, c in ipairs(ALLC) do
        if set[c] then
          key = key .. c
        end
      end
      if not takenPair[key] then
        takenPair[key] = true
        taken[i] = true
        table.insert(chosenNames, (e.Nickname or "?") .. " (" .. key .. ")")
      end
    end
  end
  broadcastToAll(seat .. " reveals (" .. it.name .. "): " .. table.concat(names, ", "), { 1, 0.85, 0.3 })
  local toHand, rest, restIds = {}, {}, {}
  local keepObjs, keepIds = {}, {}
  for i = 1, #objs do
    if i <= n then
      if taken[i] then
        table.insert(toHand, objs[i])
      else
        table.insert(rest, objs[i])
        table.insert(restIds, ids[i])
      end
    else
      table.insert(keepObjs, objs[i])
      table.insert(keepIds, ids[i])
    end
  end
  for i = #rest, 2, -1 do
    local j = math.random(i)
    rest[i], rest[j] = rest[j], rest[i]
    restIds[i], restIds[j] = restIds[j], restIds[i]
  end
  for i, o in ipairs(rest) do
    table.insert(keepObjs, o)
    table.insert(keepIds, restIds[i])
  end
  printToAll("MTG > " .. it.name .. ": " .. seat .. " takes " .. (#chosenNames > 0 and table.concat(chosenNames, ", ") or "nothing (no two-color cards)")
    .. "; the other " .. #rest .. " go on the bottom in a random order.", GOOD)
  local pos, rot = lib.getPosition(), lib.getRotation()
  local hand = Player[seat].getHandTransform()
  lib.destruct()
  if #keepObjs == 1 then
    spawnObjectData({ data = keepObjs[1], position = pos, rotation = rot })
  elseif #keepObjs > 1 then
    data.ContainedObjects, data.DeckIDs = keepObjs, keepIds
    spawnObjectData({ data = data, position = pos, rotation = rot })
  end
  local yaw = (TableSetup.seat(seat) or { yaw = 0 }).yaw
  for i, o in ipairs(toHand) do
    local hp = hand.position
    spawnObjectData({ data = o, position = { hp.x, hp.y + 0.2 * i, hp.z }, rotation = { 0, yaw, 0 } })
  end
end


-- Lost in Space, Lotus Field, Maelstrom Archangel, Explore.
function Effects.misc2(seat, a, it)
  local w = a.what
  if w == "tuckTarget" then
    local kinds = tostring(a.kinds)
    ask(seat, it.name .. ": target", "Click TARGET on the " .. kinds .. ".", { { label = "CANCEL", value = false } }, function(obj)
      if not obj or obj.isDestroyed() then
        return
      end
      local owner = (Effects.ownerOf and Effects.ownerOf(obj)) or Effects.fieldSeat(obj) or seat
      local nm = obj.getName()
      ask(owner, it.name .. ": top or bottom?", nm .. " goes into your library: on TOP or on the BOTTOM?",
        { { label = "TOP", value = "top" }, { label = "BOTTOM", value = "bottom" } }, function(where)
          if obj.isDestroyed() then
            return
          end
          if obj.hasTag("Token") then
            Combat.removeCard(obj, "library")
            printToAll("MTG > " .. it.name .. ": " .. nm .. " (a token) leaves the battlefield and is gone.", GOOD)
            return
          end
          obj.setLock(false)
          if where == "bottom" then
            Library.putOnBottom(owner, { obj }, function() end)
          else
            Library.putAt(owner, obj, 0, function() end)
          end
          printToAll("MTG > " .. it.name .. ": " .. owner .. " puts " .. nm .. " on the " .. where .. " of their library.", GOOD)
        end)
    end, { filter = function(obj)
      local ty = Effects.cardTypes(obj)
      return (kinds:find("artifact", 1, true) and ty.artifact) or (kinds:find("creature", 1, true) and ty.creature)
        or (kinds:find("enchantment", 1, true) and ty.enchantment) or (kinds:find("permanent", 1, true) and true)
        or (kinds:find("planeswalker", 1, true) and ty.planeswalker) or false
    end, label = "TARGET" })
  elseif w == "sacLands" or w == "bounceLand" then
    local left = a.n or 1
    local verb = w == "sacLands" and "SACRIFICE" or "RETURN"
    local function step()
      if left <= 0 then
        return
      end
      ask(seat, it.name .. ": " .. string.lower(verb) .. " a land", "Click " .. verb .. " on a" .. (a.untapped and "n untapped" or "")
        .. " land you control (" .. left .. " to go).", { { label = "STOP", value = false } }, function(obj)
          if not obj or obj.isDestroyed() then
            return
          end
          left = left - 1
          if w == "sacLands" then
            Combat.sacrifice(obj)
          else
            Effects.returnToHand(obj)
          end
          printToAll("MTG > " .. it.name .. ": " .. seat .. (w == "sacLands" and " sacrifices " or " returns ") .. obj.getName() .. ".", GOOD)
          Wait.time(step, 0.8)
        end, { filter = function(obj, owner)
          if owner ~= seat or not Effects.cardTypes(obj).land then
            return false
          end
          if a.untapped then
            local s = TableSetup.seat(owner)
            local r = obj.getRotation()
            if s and math.abs(((r.y - s.yaw + 540) % 360) - 180) > 30 then
              return false
            end
          end
          return true
        end, label = verb, protect = false })
    end
    step()
  elseif w == "freeCastHand" then
    local hand = {}
    pcall(function() hand = Player[seat].getHandObjects() or {} end)
    local ch, objs = {}, {}
    for _, o in ipairs(hand) do
      if o.type == "Card" and not tostring(CardData.get(o).typeLine or ""):find("Land", 1, true) and #ch < 9 then
        table.insert(objs, o)
        table.insert(ch, { label = tostring(o.getName()):sub(1, 22), value = #objs })
      end
    end
    if #ch == 0 then
      printToAll("MTG > " .. it.name .. ": " .. seat .. " has no spell in hand to cast.", INFO)
      return
    end
    table.insert(ch, { label = "NONE", value = false })
    ask(seat, it.name .. ": cast a spell free?", "Pick a spell from your hand to cast without paying its mana cost.", ch, function(i)
      local o = i and objs[i]
      if o and not o.isDestroyed() then
        o.setLock(false)
        Stack.pushCard(o, seat, { seat = seat, region = "hand" })
        printToAll("MTG > " .. seat .. " casts " .. o.getName() .. " without paying its mana cost (" .. it.name .. ").", GOOD)
      end
    end)
  elseif w == "landBonus" then
    local t = GameState.data.turn or {}
    GameState.data.landBonus = GameState.data.landBonus or {}
    local b = GameState.data.landBonus[seat]
    if b == nil or b.turn ~= t.taken then
      b = { turn = t.taken, n = 0 }
    end
    b.n = b.n + (a.n or 1)
    GameState.data.landBonus[seat] = b
    printToAll("MTG > " .. it.name .. ": " .. seat .. " may play " .. b.n .. " additional land" .. (b.n == 1 and "" or "s") .. " this turn.", GOOD)
  end
end

function Effects.untapObj(obj)
  local seat = Effects.fieldSeat(obj)
  if seat then
    turnTapped(obj, seat, false)
  end
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
    elseif a.scope == "opponents" and not TableSetup.isOpponent(owner, seat) then
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
      Wait.condition(function()
        if not c.isDestroyed() then
          Zones.refresh(c)
        end
      end, function()
        if c.isDestroyed() then
          return true
        end
        local ok, n = pcall(function() return c.getGMNotes() end)
        return ok and n ~= nil and n ~= ""
      end, 3, function()
        if not c.isDestroyed() then
          Zones.refresh(c)
        end
      end)
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

-- Rebound: at the beginning of the owner's next upkeep they may cast the exiled spell free.
Events.on("stepStarted", function(d)
  local list = GameState.data and GameState.data.rebound
  if d.step ~= "upkeep" or not list or #list == 0 then
    return
  end
  local keep = {}
  for _, r in ipairs(list) do
    if r.seat == d.seat then
      local card = getObjectFromGUID(r.guid)
      if card and not card.isDestroyed() then
        ask(r.seat, r.name .. ": rebound", "Cast " .. r.name .. " from exile without paying its mana cost?",
          { { label = "CAST", value = "cast" }, { label = "NO", value = false } }, function(pick)
            if pick == "cast" and not card.isDestroyed() then
              printToAll("MTG > " .. r.seat .. " casts " .. r.name .. " from exile (rebound).", GOOD)
              GameState.data.reboundCast = GameState.data.reboundCast or {}
              GameState.data.reboundCast[card.getGUID()] = true
              GameState.data.freeCast = GameState.data.freeCast or {}
              GameState.data.freeCast[card.getGUID()] = true
              Stack.pushCard(card, r.seat)
            else
              printToAll("MTG > " .. r.seat .. " doesn't cast " .. r.name .. " (rebound lost).", INFO)
            end
          end)
      end
    else
      table.insert(keep, r)
    end
  end
  GameState.data.rebound = keep
end)

-- Suspend N-{cost}: pay the cost, exile the card with N time counters. At the start of the
-- owner's upkeep one comes off; when the last one goes the card is cast free (creatures get haste).
function Effects.suspendInfo(obj)
  local d = CardData.get(obj)
  local low = tostring(d.oracle or ""):lower()
  local at = nil
  if low:sub(1, 8) == "suspend " then
    at = 1
  else
    local f = low:find("\nsuspend ", 1, true)
    at = f and (f + 1) or nil
  end
  if not at then
    return nil
  end
  local line = low:sub(at, (low:find("\n", at, true) or (#low + 1)) - 1)
  local paren = line:find("(", 1, true)
  if paren then
    line = line:sub(1, paren - 1)
  end
  local n = tonumber(line:match("^suspend (%d+)"))
  if not n then
    return nil
  end
  local cost = ""
  local fromBrace = line:find("{", 1, true)
  if fromBrace then
    for sym in line:sub(fromBrace):gmatch("{[^}]*}") do
      cost = cost .. sym:upper()
    end
  end
  return n, cost
end

function Effects.suspend(obj, seat)
  if obj == nil or obj.isDestroyed() then
    return
  end
  local n, cost = Effects.suspendInfo(obj)
  if not n then
    printToColor("That card has no suspend.", seat or "White", { 1, 0.6, 0.2 })
    return
  end
  seat = seat or (Zones.locationOf(obj) or {}).seat
  if seat == nil then
    return
  end
  local nm = obj.getName()
  if cost ~= "" and ManaChips and ManaChips.pay then
    ManaChips.pay(seat, cost, nm .. " (suspend)")
  end
  obj.setLock(false)
  local s = TableSetup.seat(seat)
  obj.setPositionSmooth(TableSetup.slot(seat, "exile", 3), false, true)
  if s then
    obj.setRotationSmooth({ 0, s.yaw, 0 }, false, true)
  end
  GameState.data.suspended = GameState.data.suspended or {}
  table.insert(GameState.data.suspended, { seat = seat, guid = obj.getGUID(), name = nm })
  Wait.time(function()
    if not obj.isDestroyed() then
      Zones.refresh(obj)
      Counters.change(obj, "other", n, seat)
    end
  end, 1.2)
  printToAll("MTG > " .. seat .. " suspends " .. nm .. ": exiled with " .. n .. " time counter" .. (n == 1 and "" or "s")
    .. (cost ~= "" and (" (cost " .. cost .. ")") or "") .. ". It comes off one at each of their upkeeps.", GOOD)
end

Events.on("stepStarted", function(d)
  local list = GameState.data and GameState.data.suspended
  if d.step ~= "upkeep" or not list or #list == 0 then
    return
  end
  local keep = {}
  for _, r in ipairs(list) do
    local card = getObjectFromGUID(r.guid)
    if card == nil or card.isDestroyed() then
      -- gone (cast or moved by hand): forget it
    elseif r.seat ~= d.seat then
      table.insert(keep, r)
    else
      Counters.change(card, "other", -1, r.seat)
      local left = Counters.get(card).other or 0
      if left > 0 then
        printToAll("MTG > " .. r.name .. " (suspended): one time counter removed, " .. left .. " left.", INFO)
        table.insert(keep, r)
      else
        printToAll("MTG > " .. r.name .. " (suspended): last time counter removed, " .. r.seat .. " casts it without paying.", GOOD)
        ask(r.seat, r.name .. ": suspend", "The last time counter came off. Cast " .. r.name .. " without paying its mana cost? (You must, if you can.)",
          { { label = "CAST", value = "cast" }, { label = "CAN'T CAST", value = false } }, function(pick)
            if pick == "cast" and not card.isDestroyed() then
              local tl = tostring(CardData.get(card).typeLine or ""):lower()
              if tl:find("creature", 1, true) and Counters.addTempKeyword then
                Counters.addTempKeyword(card, "haste")
              end
              GameState.data.freeCast = GameState.data.freeCast or {}
              GameState.data.freeCast[card.getGUID()] = true
              Stack.pushCard(card, r.seat)
            end
          end)
      end
    end
  end
  GameState.data.suspended = keep
end)

-- "As ~ enters, choose a creature type" (Cavern of Souls, Roaming Throne, Coat of Arms...):
-- the controller types it in; it is remembered for the card (Statics.chosenType).
function Effects.chooseType(obj, seat)
  if obj == nil or obj.isDestroyed() then
    return
  end
  local nm = obj.getName()
  Effects.askText(seat, nm .. ": creature type", "Type the creature type you choose for " .. nm .. " (for example Elf, Goblin, Human).", function(t)
    if obj.isDestroyed() then
      return
    end
    local ty = t:sub(1, 1):upper() .. t:sub(2):lower()
    Statics.setChosen(obj, ty)
    printToAll("MTG > " .. seat .. " chooses " .. ty .. " for " .. nm .. ".", { 0.55, 0.9, 0.6 })
  end)
end

-- Who OWNS a card (not who controls it): the seat whose library or hand it first came from, or the
-- Beamtown Bullies' controller for a creature it gave away. nil if unknown.
function Effects.ownerOf(obj)
  local m = GameState.data and GameState.data.ownerOf
  local ok, g = pcall(function() return obj.getGUID() end)
  return ok and m and m[g] or nil
end

function Effects.setOwner(obj, seat)
  GameState.data.ownerOf = GameState.data.ownerOf or {}
  GameState.data.ownerOf[obj.getGUID()] = seat
end

Events.on("cardMoved", function(d)
  if d.card == nil or d.from == nil or d.from.seat == nil then
    return
  end
  if d.from.region == "library" or d.from.region == "hand" then
    local ok, g = pcall(function() return d.card.getGUID() end)
    if ok and not (GameState.data.ownerOf and GameState.data.ownerOf[g]) then
      Effects.setOwner(d.card, d.from.seat)
    end
  end
end)

-- "As ~ enters, choose a number between 1 and 10" (Talion, the Kindly Lord): kept per card.
function Effects.chosenNumber(obj)
  local c = GameState.data and GameState.data.chosenNumber
  return c and obj and c[obj.getGUID()] or nil
end

function Effects.chooseNumber(obj, seat, lo, hi)
  if obj == nil or obj.isDestroyed() then
    return
  end
  local nm = obj.getName()
  Effects.askNumber(seat, nm .. ": choose a number", "Type a number from " .. lo .. " to " .. hi .. ", then OK.", function(n)
    n = math.floor(tonumber(n) or 0)
    if obj.isDestroyed() then
      return
    end
    if n < lo or n > hi then
      broadcastToColor(nm .. ": the number must be from " .. lo .. " to " .. hi .. ". Pick again.", seat, { 1, 0.6, 0.2 })
      Effects.chooseNumber(obj, seat, lo, hi)
      return
    end
    GameState.data.chosenNumber = GameState.data.chosenNumber or {}
    GameState.data.chosenNumber[obj.getGUID()] = n
    printToAll("MTG > " .. seat .. " chooses " .. n .. " for " .. nm .. ".", { 0.55, 0.9, 0.6 })
  end)
end

-- "As this creature enters, choose a color" (Diamond Mare): the color is kept per card.
function Effects.chosenColor(obj)
  local c = GameState.data and GameState.data.chosenColor
  return c and obj and c[obj.getGUID()] or nil
end

function Effects.chooseColor(obj, seat)
  if obj == nil or obj.isDestroyed() then
    return
  end
  local nm = obj.getName()
  local choices = {}
  for _, col in ipairs({ "White", "Blue", "Black", "Red", "Green" }) do
    table.insert(choices, { label = string.upper(col), value = col })
  end
  Effects.askChoice(seat, nm .. ": choose a color", "Pick the color for " .. nm .. ".", choices, function(col)
    if not col or obj.isDestroyed() then
      return
    end
    GameState.data.chosenColor = GameState.data.chosenColor or {}
    GameState.data.chosenColor[obj.getGUID()] = col
    printToAll("MTG > " .. seat .. " chooses " .. col .. " for " .. nm .. ".", { 0.55, 0.9, 0.6 })
  end)
end

Events.on("cardMoved", function(d)
  if d.card == nil or d.to == nil or (d.to.region ~= "battlefield" and d.to.region ~= "lands") or d.to.seat == nil then
    return
  end
  if d.from == nil or d.from.region == nil or d.from.region == "battlefield" or d.from.region == "lands" then
    return
  end
  local ok, obj = pcall(function() return d.card end)
  if not ok or obj == nil or obj.isDestroyed() then
    return
  end
  local low = tostring(CardData.get(obj).oracle or ""):lower()
  if low:find("choose a creature type", 1, true) and low:find("enters", 1, true) and not Statics.chosenType(obj) then
    Effects.chooseType(obj, d.to.seat)
  end
  -- Bronze Bombshell: "When a player other than this creature's owner controls it, that player sacrifices it.
  -- If the player does, this creature deals 7 damage to the player."
  local owner = Effects.ownerOf(obj)
  if owner and owner ~= d.to.seat and low:find("when a player other than this creature's owner controls it", 1, true) then
    local line = ""
    for l in (tostring(CardData.get(obj).oracle or "") .. "\n"):gmatch("([^\n]*)\n") do
      if l:lower():find("other than this creature's owner controls it", 1, true) then
        line = l
      end
    end
    local face = ""
    pcall(function()
      for _, cd in pairs(obj.getData().CustomDeck or {}) do
        face = cd.FaceURL
        break
      end
    end)
    Wait.time(function()
      if not obj.isDestroyed() then
        Stack.pushAbility(d.to.seat, obj.getName(), line, face, { trigger = true, source = obj.getGUID() })
      end
    end, 0.5)
  end
  do
    local lo, hi = low:match("enters, choose a number between (%d+) and (%d+)")
    if lo then
      if GameState.data.chosenNumber then
        GameState.data.chosenNumber[obj.getGUID()] = nil   -- a new object: choose again
      end
      Effects.chooseNumber(obj, d.to.seat, tonumber(lo), tonumber(hi))
    end
  end
  if low:find("enters, choose a color", 1, true) then
    if GameState.data.chosenColor then
      GameState.data.chosenColor[obj.getGUID()] = nil   -- a new object: choose again
    end
    Effects.chooseColor(obj, d.to.seat)
  end
end)

-- The Beamtown Bullies: "{T}: Target opponent whose turn it is puts target nonlegendary creature card
-- from your graveyard onto the battlefield under their control. It gains haste. Goad it. At the
-- beginning of the next end step, exile it." The Bullies' controller picks the card from their
-- graveyard; it lands on the active player's battlefield (so its enters triggers are theirs).
function Effects.bullies(seat, it)
  local active = GameState.data.turn and GameState.data.turn.activeSeat
  if active == nil or active == seat then
    broadcastToColor(it.name .. ": only on an opponent's turn (it targets the opponent whose turn it is).", seat, INFO)
    return
  end
  LibSearch.open(seat, "creature", it.name .. ": click a NONLEGENDARY creature card. It goes onto " .. active
    .. "'s battlefield under their control, with haste, goaded, and is exiled at the next end step.",
    "battlefield", false, { typeOnly = true, zone = "graveyard", nonLegendary = true, toSeat = active, fixedDest = true, limit = 1,
      onTake = function(card)
        if card == nil then
          return
        end
        Effects.setOwner(card, seat)
        Wait.time(function()
          if card.isDestroyed() then
            return
          end
          if Counters.addTempKeyword then
            Counters.addTempKeyword(card, "haste")
          end
          Counters.setGoad(card, seat)
          Effects.addDelayed({ seat = seat, anySeat = true, step = "end", kind = "exileOwner", guid = card.getGUID(), owner = seat, name = it.name })
          printToAll("MTG > " .. it.name .. ": " .. card.getName() .. " is " .. active .. "'s now, with haste and goaded by " .. seat
            .. ". It's exiled at the beginning of the next end step.", GOOD)
        end, 1.5)
      end })
end

-- Blasphemous Act: N damage to each creature. Creatures with toughness N or less die (not indestructible
-- ones); the list is shown first and the controller confirms (damage that doesn't kill is not tracked).
function Effects.damageAll(seat, n, name)
  local dying, names = {}, {}
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and Effects.fieldSeat(obj)
        and Effects.cardTypes(obj).creature then
      local tough = tonumber(Counters.stats(obj).toughness or "")
      if tough and tough <= n and not Effects.hasKeyword(obj, "indestructible") then
        table.insert(dying, obj)
        table.insert(names, obj.getName())
      end
    end
  end
  if #dying == 0 then
    printToAll("MTG > " .. name .. ": " .. n .. " damage to each creature - nothing dies.", INFO)
    return
  end
  local list = table.concat(names, ", ")
  if #list > 220 then
    list = list:sub(1, 217) .. "..."
  end
  Effects.askChoice(seat, name .. ": " .. n .. " damage to each creature", #dying .. " creature(s) die: " .. list,
    { { label = "APPLY", value = true }, { label = "BY HAND", value = false } }, function(yes)
      if not yes then
        printToAll("MTG > " .. name .. ": " .. seat .. " applies the damage by hand.", INFO)
        return
      end
      for _, obj in ipairs(dying) do
        if not obj.isDestroyed() then
          Combat.removeCard(obj, "graveyard")
        end
      end
      printToAll("MTG > " .. name .. ": " .. n .. " damage to each creature. Died: " .. list .. ".", GOOD)
    end)
end

-- Yuriko, the Tiger's Shadow: the top card is revealed and put into the hand (not drawn); each
-- opponent loses life equal to its mana value.
function Effects.yurikoReveal(seat, name)
  local lib = Library.find(seat)
  if lib == nil then
    printToAll("MTG > " .. name .. ": " .. seat .. "'s library is empty, nothing is revealed.", INFO)
    return
  end
  local entry
  if lib.type == "Deck" then
    entry = (lib.getData().ContainedObjects or {})[1]
  else
    entry = lib.getData()
    entry.GUID = lib.getGUID()
  end
  local mv, cname = 0, entry and entry.Nickname or "a card"
  pcall(function() mv = tonumber(JSON.decode(entry.GMNotes).cmc) or 0 end)
  -- Revealed and put into the hand: not a draw (no draw triggers, no Notion Thief).
  if entry and entry.GUID then
    GameState.data.searched = GameState.data.searched or {}
    GameState.data.searched[entry.GUID] = true
  end
  Library.draw(seat, 1)
  broadcastToAll(name .. ": " .. seat .. " reveals " .. cname .. " (mana value " .. mv .. ") and puts it into their hand.", { 1, 0.85, 0.3 })
  if mv > 0 then
    for _, c in ipairs(players()) do
      if TableSetup.isOpponent(c, seat) then
        Trackers.changeLife(c, -mv, name)
      end
    end
    printToAll("MTG > " .. name .. ": each opponent loses " .. mv .. " life.", { 1, 0.5, 0.4 })
  end
end

-- Leveler / Inverter of Truth: the whole library goes to exile (Inverter: face down).
function Effects.exileLibrary(seat, faceDown, name)
  local lib = Library.find(seat)
  if lib == nil then
    printToAll("MTG > " .. name .. ": " .. seat .. "'s library is already empty.", INFO)
    return
  end
  local n = lib.type == "Deck" and #lib.getObjects() or 1
  local s = TableSetup.seat(seat)
  lib.setLock(false)
  lib.setRotation({ 0, s.yaw, faceDown and 180 or 0 })
  lib.setPosition(TableSetup.slot(seat, "exile", TableSetup.SURFACE_TOP + 3))
  printToAll("MTG > " .. name .. ": " .. seat .. " exiles all " .. n .. " cards of their library" .. (faceDown and " face down" or "") .. ".",
    { 1, 0.5, 0.4 })
end

-- Inverter of Truth: "shuffle all cards from your graveyard into your library".
function Effects.yardToLibrary(seat, name)
  Wait.time(function()
    local yard = Library.pileIn(seat, "graveyard")
    if yard == nil then
      printToAll("MTG > " .. name .. ": " .. seat .. "'s graveyard is empty, so their library stays empty.", { 1, 0.5, 0.4 })
      return
    end
    local n = yard.type == "Deck" and #yard.getObjects() or 1
    local s = TableSetup.seat(seat)
    yard.setLock(false)
    yard.setRotation({ 0, s.yaw, 180 })
    yard.setPosition(TableSetup.slot(seat, "library", TableSetup.SURFACE_TOP + 2))
    Wait.time(function()
      if not yard.isDestroyed() and yard.type == "Deck" then
        yard.shuffle()
      end
      Wait.time(function()
        if Zones and Zones.refresh and not yard.isDestroyed() then
          pcall(Zones.refresh, yard)
        end
      end, 0.5)
    end, 0.8)
    printToAll("MTG > " .. name .. ": " .. seat .. " shuffles their graveyard (" .. n .. " cards) into their library.", INFO)
  end, 1.0)
end

-- Soulgorger Orgg leaving: its controller gets back the life it took.
Events.on("cardMoved", function(d)
  if d.card == nil or d.from == nil or not (d.from.region == "battlefield" or d.from.region == "lands") then
    return
  end
  if d.to and (d.to.region == "battlefield" or d.to.region == "lands") then
    return
  end
  local m = GameState.data and GameState.data.lostTo
  local ok, g = pcall(function() return d.card.getGUID() end)
  local rec = ok and m and m[g]
  if rec then
    m[g] = nil
    if rec.n > 0 then
      Trackers.changeLife(rec.seat, rec.n, rec.name)
      printToAll("MTG > " .. rec.name .. " left the battlefield: " .. rec.seat .. " gains back " .. rec.n .. " life.", GOOD)
    end
  end
end)

-- Put an exiled card back onto the battlefield (a real move, so enters triggers fire).
function Effects.returnFromExile(guid, owner, why)
  local obj = getObjectFromGUID(guid)
  if obj == nil or obj.isDestroyed() then
    -- It may have merged into the exile pile: take it back out (Worldgorger Dragon returns a whole board).
    if owner and TableSetup.isActive(owner) then
      for _, deck in ipairs(getObjects()) do
        if deck.type == "Deck" and not deck.isDestroyed() then
          local loc = Zones.regionAt(deck.getPosition())
          if loc.region == "exile" then
            for _, e in ipairs(deck.getObjects()) do
              if e.guid == guid then
                local isLand = tostring(e.gm_notes or ""):find('"typeLine":"[^"]*Land', 1) ~= nil
                local taken = deck.takeObject({ guid = guid, smooth = false, rotation = { 0, TableSetup.seat(owner).yaw, 0 },
                  position = TableSetup.slot(owner, isLand and "lands" or "battlefield", TableSetup.SURFACE_TOP + 2) })
                if taken then
                  printToAll("MTG > " .. taken.getName() .. " returns to the battlefield" .. (why and (" (" .. why .. ")") or "") .. ".", GOOD)
                  Wait.time(function()
                    if not taken.isDestroyed() then
                      Zones.refresh(taken)
                      Counters.setup(taken)
                    end
                  end, 0.8)
                end
                return
              end
            end
          end
        end
      end
    end
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

-- Mox Diamond: "If ~ would enter, you may discard a land card instead. If you
-- do, put ~ onto the battlefield. If you don't, put it into its owner's
-- graveyard." Asked as it lands on the battlefield.
Events.on("cardMoved", function(d)
  if not enabled() or not GameState.data.started or d.card == nil or d.to == nil then
    return
  end
  local into = d.to.region == "battlefield" or d.to.region == "lands"
  local fromField = d.from and (d.from.region == "battlefield" or d.from.region == "lands")
  if not into or fromField or d.card.hasTag("Token") then
    return
  end
  local oracle = ""
  pcall(function() oracle = tostring(JSON.decode(d.card.getGMNotes()).oracle or ""):lower() end)
  if not oracle:find("would enter, you may discard a land card instead", 1, true) then
    return
  end
  local card, seat, name = d.card, d.to.seat, d.card.getName()
  if seat == nil then
    return
  end
  local function toGraveyard()
    if card.isDestroyed() then
      return
    end
    -- It never entered: no "dies" / "leaves the battlefield" for it.
    if Zones.forget then
      Zones.forget(card.getGUID())
    end
    local s = TableSetup.seat(seat)
    card.setLock(false)
    card.setRotation({ 0, s.yaw, 0 })
    card.setPosition(TableSetup.slot(seat, "graveyard", TableSetup.SURFACE_TOP + 2))
    Library.toGraveyard(seat, card)
    printToAll("MTG > " .. name .. ": no land discarded, it goes to " .. seat .. "'s graveyard.", INFO)
  end
  local function isLand(data)
    for _, t in ipairs(type(data) == "table" and data.types or {}) do
      if tostring(t):lower() == "land" then
        return true
      end
    end
    return type(data) == "table" and tostring(data.typeLine or ""):find("Land", 1, true) ~= nil
  end
  local hasLand = false
  for _, o in ipairs(Player[seat].getHandObjects() or {}) do
    local okd, data = pcall(function() return JSON.decode(o.getGMNotes()) end)
    if o.type == "Card" and okd and isLand(data) then
      hasLand = true
    end
  end
  -- Always ask, so it's never silent; with no land in hand only NO is offered.
  local choices = { { label = "NO", value = false } }
  if hasLand then
    table.insert(choices, 1, { label = "DISCARD A LAND", value = true })
  end
  ask(seat, name .. ": discard a land?", hasLand
      and ("Discard a land card to keep " .. name .. " on the battlefield? If you don't, it goes to your graveyard.")
      or ("You have no land card in hand, so " .. name .. " goes to your graveyard."),
    choices, function(yes)
      if not yes then
        toGraveyard()
        return
      end
      Actions.chooseFromHand(seat, seat, name, isLand, "Pick the land card to discard.", function()
        printToAll("MTG > " .. name .. " stays on " .. seat .. "'s battlefield.", GOOD)
      end)
    end)
end)

-- "Each player plays with the top card of their library revealed" (Lantern of
-- Insight) / "Play with the top card of your library revealed" (Courser of
-- Kruphix): a label over each such library names its top card. TTS can't show
-- a deck's top card face up without taking it off, so the name is shown.
local function revealedTopSeats()
  local seats = {}
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and not obj.is_face_down then
      local owner = Effects.fieldSeat(obj)
      if owner then
        local o = ""
        pcall(function() o = tostring(JSON.decode(obj.getGMNotes()).oracle or ""):lower() end)
        if o:find("each player plays with the top card of their library revealed", 1, true) then
          for _, c in ipairs(players()) do
            seats[c] = true
          end
        elseif o:find("play with the top card of your library revealed", 1, true) then
          seats[owner] = true
        end
      end
    end
  end
  return seats
end

local topPending = false
function Effects.refreshRevealedTops()
  if topPending or GameState.data == nil then
    return
  end
  topPending = true
  Wait.time(function()
    topPending = false
    local labels = GameState.data.topLabels or {}
    GameState.data.topLabels = labels
    local want = revealedTopSeats()
    for _, c in ipairs(TableSetup.activeSeats()) do
      local label = labels[c] and getObjectFromGUID(labels[c])
      if not want[c] then
        if label then
          label.destruct()
        end
        labels[c] = nil
      else
        local lib = Library.find(c)
        local name = "(empty)"
        if lib and lib.type == "Deck" then
          local top = lib.getObjects()[1]
          name = top and (top.name or top.nickname) or name
        elseif lib then
          name = lib.getName()
        end
        local s = TableSetup.seat(c)
        local spot = TableSetup.slot(c, "library", 0.2)
        local pos = { x = spot.x + s.inward.x * 4.3, y = TableSetup.SURFACE_TOP + 0.1, z = spot.z + s.inward.z * 4.3 }
        if label == nil then
          label = spawnObject({ type = "3DText", position = pos, rotation = { 90, s.yaw, 0 } })
          label.interactable = false
          labels[c] = label.getGUID()
        else
          label.setPosition(pos)
        end
        label.TextTool.setFontSize(46)
        label.TextTool.setFontColor({ 1, 0.85, 0.3 })
        label.TextTool.setValue("TOP: " .. tostring(name))
      end
    end
  end, 0.8)
end

Events.on("cardMoved", function(d)
  if GameState.data and GameState.data.started and (GameState.data.topLabels and next(GameState.data.topLabels)
      or (d.to and (d.to.region == "battlefield" or d.to.region == "library")) or (d.from and d.from.region == "library")) then
    Effects.refreshRevealedTops()
  end
end)

Events.on("stepStarted", function()
  if GameState.data and GameState.data.started then
    Effects.refreshRevealedTops()
  end
end)

-- Prepared (Secrets of Strixhaven): "This creature enters prepared." While it
-- is prepared, its controller may cast a copy of its prepare spell (the
-- card's other part, e.g. Rampant Growth); casting it ends the prepared state.
local function partsOf(obj)
  local parts
  pcall(function() parts = JSON.decode(obj.getGMNotes()).parts end)
  return type(parts) == "table" and parts or nil
end

local function preparedTable()
  GameState.data.prepared = GameState.data.prepared or {}
  return GameState.data.prepared
end

-- The prepare spell a prepared creature can cast (nil when it isn't prepared).
function Effects.preparedPart(obj)
  if obj == nil or GameState.data == nil or not preparedTable()[obj.getGUID()] then
    return nil
  end
  local parts = partsOf(obj)
  return parts and parts[1] or nil
end

function Effects.setPrepared(obj, on)
  preparedTable()[obj.getGUID()] = on or nil
  if Counters and Counters.refreshMenu then
    Counters.refreshMenu(obj)
  end
end

function Effects.castPrepared(obj, playerColor)
  local part = Effects.preparedPart(obj)
  if part == nil then
    return
  end
  local seat = Effects.fieldSeat(obj)
  if seat ~= playerColor and not GameState.solo() then
    broadcastToColor("Only " .. tostring(seat) .. " can cast that.", playerColor, INFO)
    return
  end
  seat = seat or playerColor
  if part.manaCost and part.manaCost ~= "" and ManaChips and ManaChips.pay then
    ManaChips.pay(seat, part.manaCost, part.name)
  end
  Effects.setPrepared(obj, false)
  local image = ""
  pcall(function()
    for _, d in pairs(obj.getData().CustomDeck or {}) do
      image = d.FaceURL
      break
    end
  end)
  Stack.pushAbility(seat, part.name, part.oracle, image, { activated = true })
  printToAll("MTG > " .. seat .. " casts " .. part.name .. " (the prepared copy from " .. obj.getName()
    .. "). " .. obj.getName() .. " is no longer prepared.", GOOD)
end

Events.on("cardMoved", function(d)
  if d.card == nil or GameState.data == nil then
    return
  end
  local into = d.to and (d.to.region == "battlefield" or d.to.region == "lands")
  local fromField = d.from and (d.from.region == "battlefield" or d.from.region == "lands")
  if into and not fromField then
    local oracle = ""
    pcall(function() oracle = tostring(JSON.decode(d.card.getGMNotes()).oracle or ""):lower() end)
    if oracle:find("enters prepared", 1, true) and partsOf(d.card) then
      Effects.setPrepared(d.card, true)
      printToAll("MTG > " .. d.card.getName() .. " is prepared: right-click it > Cast prepared: "
        .. tostring(partsOf(d.card)[1].name) .. ".", GOOD)
    end
  elseif fromField and not into and preparedTable()[d.card.getGUID()] then
    preparedTable()[d.card.getGUID()] = nil
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
      elseif r.kind == "exileOwner" then
        -- Exiled to its OWNER's exile (The Beamtown Bullies gave it to someone else).
        local obj = getObjectFromGUID(r.guid)
        if obj and not obj.isDestroyed() and Effects.fieldSeat(obj) then
          local s = TableSetup.seat(r.owner)
          obj.setLock(false)
          obj.setRotation({ 0, s.yaw, 0 })
          obj.setPosition(TableSetup.slot(r.owner, "exile", TableSetup.SURFACE_TOP + 2))
          Zones.refresh(obj)
          printToAll("MTG > " .. r.name .. ": " .. obj.getName() .. " is exiled (to " .. r.owner .. "'s exile).", GOOD)
        end
      elseif r.kind == "forgeControlBack" then
        local obj = getObjectFromGUID(r.guid)
        if obj and not obj.isDestroyed() and Effects.fieldSeat(obj) and Effects.fieldSeat(obj) ~= r.to then
          Effects.moveToSeat(obj, r.to)
          printToAll("MTG > " .. r.name .. ": " .. obj.getName() .. " goes back to " .. r.to .. ".", GOOD)
        end
      elseif r.kind == "forgeUnanimate" then
        local obj = getObjectFromGUID(r.guid)
        if GameState.data.animated then
          GameState.data.animated[r.guid] = nil
        end
        if obj and not obj.isDestroyed() then
          Effects.setBasePT(obj, nil, nil)
        end
      elseif r.kind == "forgeEnd" then
        local obj = getObjectFromGUID(r.guid)
        if obj and not obj.isDestroyed() and Effects.fieldSeat(obj) then
          printToAll("MTG > " .. r.name .. ": " .. obj.getName() .. ({ sac = " is sacrificed.", destroy = " is destroyed.",
            exile = " is exiled.", bounce = " returns to its owner's hand." })[r.how], GOOD)
          if r.how == "sac" then
            Combat.sacrifice(obj)
          elseif r.how == "bounce" then
            Effects.returnToHand(obj)
          elseif r.how == "destroy" and Effects.hasKeyword(obj, "indestructible") then
            printToAll("MTG > " .. obj.getName() .. " is indestructible and stays.", INFO)
          else
            Combat.removeCard(obj, r.how == "exile" and "exile" or "graveyard")
          end
        end
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
  if q.number == "text" then
    local t = tostring(numTyped[player.color] or numTyped[seat] or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if t == "" then
      broadcastToColor("Type something first.", player.color, INFO)
      return
    end
    current = nil
    q.onPick(t)
    if current == nil then
      nextQuestion()
    end
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
      table.insert(choices, ('<Panel id="effChoice_%s_%d" active="false" preferredWidth="80" preferredHeight="40">'
        .. '<Button onClick="ui_effPick(%s_%d)" color="#1B2333" />'
        .. '<Text id="effChoiceTxt_%s_%d" raycastTarget="false" fontSize="14" fontStyle="Bold" color="#E6F1FF">-</Text></Panel>')
        :format(c, i, c, i, c, i))
    end
    table.insert(parts, ([[
<Panel id="effAsk_%s" visibility="%s" active="false" rectAlignment="LowerLeft" offsetXY="20 240" width="600" height="300"
       color="#0B0F17F5" outline="#5AF0FF" outlineSize="2 2" allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="14 14 12 12" spacing="8" childForceExpandHeight="false">
    <Text id="effTitle_%s" fontSize="17" fontStyle="Bold" color="#5AF0FF" alignment="MiddleLeft" preferredHeight="24">-</Text>
    <Text id="effText_%s" fontSize="13" color="#E6F1FF" alignment="UpperLeft" preferredHeight="124">-</Text>
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
  if it.copyOf then
    Effects.resolveCopy(it)
    return
  end
  if it.ward then
    Effects.resolveWard(it)
    return
  end
  -- Kalia of the Vast, Preeminent Captain...: "you may put an Angel, Demon, or Dragon creature card from your hand onto
  -- the battlefield tapped and attacking (that opponent)".
  do
    local lowA = tostring(it.text or ""):lower()
    local kinds = lowA:match("put an? ([%a%s,%-]-) card from your hand onto the battlefield tapped and attacking")
    if kinds and Effects.handToAttack then
      Effects.handToAttack(it, kinds)
      return
    end
  end
  -- Imprint (Chrome Mox): "you may exile a nonartifact, nonland card from your hand".
  do
    local lowI = tostring(it.text or ""):lower()
    local what = lowI:match("you may exile an? ([%a%s,%-]-) card from your hand")
    if what and it.source and Effects.imprint then
      Effects.imprint(it, what)
      return
    end
  end
  -- Modes chosen as it was cast (CR 601.2b): each chosen mode resolves in printed order.
  if it.modesChosen and not it.modePicked then
    if #it.modesChosen == 0 then
      printToAll("MTG > " .. it.name .. ": no mode was chosen, nothing happens.", INFO)
      return
    end
    for _, m in ipairs(it.modesChosen) do
      local copy = {}
      for k, v in pairs(it) do
        copy[k] = v
      end
      copy.text = (m:gsub(" %[pay [^%]]*%]$", ""))
      copy.modePicked = true
      copy.modesChosen = nil
      Effects.resolve(copy)
    end
    return
  end
  -- Ninjutsu resolving: the ninja enters tapped and attacking (combat.lua).
  if it.ninjutsu and it.source then
    if not (Combat and Combat.ninjutsuResolve and Combat.ninjutsuResolve(it.source)) then
      broadcastToColor(it.name .. ": the card wasn't found - put it onto the battlefield tapped and attacking yourself.", it.controller, INFO)
    end
    return
  end
  -- Bronze Bombshell: its controller (not its owner) sacrifices it and takes the damage.
  do
    local lowB = tostring(it.text or ""):lower()
    if it.trigger and lowB:find("when a player other than this creature's owner controls it", 1, true) then
      local src = it.source and getObjectFromGUID(it.source)
      local dmg = tonumber(lowB:match("deals (%d+) damage to the player")) or 0
      if src == nil or src.isDestroyed() or not Effects.fieldSeat(src) then
        printToAll("MTG > " .. it.name .. ": it's gone already, so nothing is sacrificed and no damage is dealt.", INFO)
        return
      end
      local who = Effects.fieldSeat(src)
      Combat.sacrifice(src)
      printToAll("MTG > " .. who .. " sacrifices " .. it.name .. (dmg > 0 and (" and takes " .. dmg .. " damage.") or "."), { 1, 0.5, 0.4 })
      if dmg > 0 then
        Trackers.changeLife(who, -dmg, it.name)
      end
      return
    end
  end
  -- Storm: a copy of the spell for each spell cast before it this turn (triggers.lua counts them).
  if it.trigger and tostring(it.text or ""):sub(1, 12) == "Storm: copy " and it.thatCard then
    local spell = getObjectFromGUID(it.thatCard)
    local n = tonumber(it.amount) or 0
    if spell == nil or spell.isDestroyed() then
      broadcastToColor(it.name .. ": the spell wasn't found - make the " .. n .. " copies by hand.", it.controller, INFO)
    elseif n <= 0 then
      printToAll("MTG > " .. it.name .. ": no spells were cast before it this turn, so no copies.", INFO)
    else
      for _ = 1, n do
        Effects.copySpell(spell, it.controller, it.name)
      end
    end
    return
  end
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
    -- Akroma's Will / commander "Will" cards: "If you control a commander as you cast this spell, you may choose both".
    local willBoth = false
    if lowRaw:find("if you control a commander as you cast this spell, you may choose both", 1, true) then
      willBoth = Effects.controlsCommander(it.controller)
      if willBoth then
        printToAll("MTG > " .. it.name .. ": " .. it.controller .. " controls a commander: they may choose both modes.", INFO)
      end
    end
    if #modes > 0 and (spree or willBoth or lowRaw:find("choose one or more", 1, true) or lowRaw:find("choose any number", 1, true)) then
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
      local n = (kindWord == "+1/+1" and c.plus) or (kindWord == "-1/-1" and c.minus) or (kindWord == "loyalty" and c.loyalty) or (kindWord == "+1/+0" and c.pc) or (kindWord == "+0/+1" and c.tc) or c.other
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
        ask(it.controller, it.name .. ": check this", Effects.checkText(cond, "instead, " .. repl, nil),
          { { label = "YES, IT'S TRUE", value = true }, { label = "NO", value = false } }, go)
      end
      return
    end
  end
  local plan, why = Effects.parseBest(it.text, it.name, it)
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
        local title, text, yesLabel
        if c.prev then
          title, yesLabel = it.name .. ": did you?", "YES, I DID"
          text = Effects.checkText(c.prev, c.rest, c.otherwise, "Did you do this?")
        elseif c.cond == "you do" then
          title, yesLabel = it.name .. ": did you?", "YES, I DID"
          text = Effects.checkText(it.text or "it", c.rest, c.otherwise, "Did you do it?")
        else
          title, yesLabel = it.name .. ": check this", "YES, IT'S TRUE"
          text = Effects.checkText(c.cond, c.rest, c.otherwise)
        end
        ask(seat, title, text, { { label = yesLabel, value = true }, { label = "NO", value = false } }, function(yes)
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

-- The text of a yes/no check ("intervening if" conditions and "if you do"): the question on its own line, then
-- exactly what happens for each answer, so nobody has to work out the card's grammar.
function Effects.checkText(cond, yes, no, question)
  local function cap(t)
    t = tostring(t or ""):gsub("^%s+", ""):gsub("[%s%.]+$", "")
    return t:sub(1, 1):upper() .. t:sub(2)
  end
  return (question or "Is this true right now?") .. "\n\n      " .. cap(cond) .. "\n\n"
    .. "YES:  " .. cap(yes) .. ".\n"
    .. "NO:  " .. (no and (cap(no) .. ".") or "nothing happens.")
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
    card = obj.getGUID(), modesChosen = Effects.pendingModes })
  Effects.pendingModes = nil
  -- Rebound: exiled as it resolves; its owner may cast it free at their next upkeep.
  local low = text:lower()
  local rc = GameState.data.reboundCast
  if rc and rc[obj.getGUID()] then
    rc[obj.getGUID()] = nil      -- cast from exile by rebound: it goes to the graveyard this time
    low = ""
  end
  if (low:find("rebound (", 1, true) or low:find("\nrebound", 1, true) or low:sub(1, 7) == "rebound") and controller then
    local seat = controller
    obj.setLock(false)
    local s = TableSetup.seat(seat)
    obj.setPositionSmooth(TableSetup.slot(seat, "exile", 2), false, true)
    if s then
      obj.setRotationSmooth({ 0, s.yaw, 0 }, false, true)
    end
    GameState.data.rebound = GameState.data.rebound or {}
    table.insert(GameState.data.rebound, { seat = seat, guid = obj.getGUID(), name = obj.getName() })
    Wait.time(function()
      if not obj.isDestroyed() then
        Zones.refresh(obj)
      end
    end, 1.2)
    printToAll("MTG > " .. obj.getName() .. " rebounds: exiled, " .. seat .. " may cast it free at their next upkeep.", GOOD)
    return true
  end
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
    local d = CardData.get(obj)
    for _, n in ipairs(type(d) == "table" and d.types or {}) do
      t[tostring(n):lower()] = true
    end
    local anim = GameState.data.animated
    if anim and anim[obj.getGUID()] then
      t.creature = true
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

-- "If you control a commander" (Akroma's Will, Jeska's Will...): any commander on this seat's battlefield,
-- known by the card it was imported as or, failing that, by its name in the seat's commander list (a
-- commander card can come back as a new object).
function Effects.controlsCommander(seat)
  local names = {}
  pcall(function()
    for _, n in ipairs(GameState.player(seat).commanderNames or {}) do
      names[n] = true
    end
  end)
  for _, o in ipairs(getObjectsWithTag("MTGCard")) do
    if o.type == "Card" and not o.isDestroyed() and fieldSeat(o) == seat then
      if (Combat and Combat.isCommander and Combat.isCommander(o)) or names[o.getName()] then
        return true
      end
    end
  end
  return false
end

-- How many permanents of a kind a seat (or its opponents) control: "Treasures
-- you control", "artifacts your opponents control". Tokens count by name.
local ARTIFACT_TOKENS = { treasure = true, clue = true, food = true, blood = true, powerstone = true, gold = true,
  junk = true, map = true, incubator = true, shard = true }

function Effects.countPermanents(seat, word, scope, tappedOnly)
  word = tostring(word or ""):lower():gsub("ies$", "y"):gsub("s$", "")
  local n = 0
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and obj.held_by_color == nil then
      local owner = fieldSeat(obj)
      if owner and ((scope == "mine" and owner == seat) or (scope == "opponents" and TableSetup.isOpponent(owner, seat)) or scope == "all") then
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
        if hit and tappedOnly then
          local st = TableSetup.seat(owner)
          hit = st ~= nil and math.abs(((obj.getRotation().y - st.yaw + 540) % 360) - 180) > 30
        end
        if hit then
          n = n + (Pile and Pile.count(obj) or 1)
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
  -- Counters.render passes a stand-in that records the buttons: the checks need the card itself.
  local real = (type(obj) == "table" and rawget(obj, "__real")) or obj
  local seat = fieldSeat(real)
  if seat == nil or not q.pick.filter(real, seat) then
    return
  end
  -- Protection: a targeted pick can't choose a creature that has protection
  -- from the source's colour (shown instead of the pick button).
  local PROT = { TARGET = true, GOAD = true, ["CHAOS WARP"] = true, DESTROY = true, EXILE = true }
  if Equip and Equip.protectedFrom and PROT[q.pick.label] and q.pick.protect ~= false and q.pick.noProtect ~= true then
    local pro = Equip.protectedFrom(real, q.pick.src or q.src)
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

local function returnToHand(obj, cmdAsked)
  local seat = fieldSeat(obj)
  if seat == nil then
    return
  end
  -- A commander that would go to its owner's hand may go to the command zone instead (CR 903.9b): asked first.
  if not cmdAsked and Combat and Combat.isCommander and Combat.isCommander(obj) then
    local owner = Effects.ownerOf(obj) or seat
    local card = obj
    Effects.askChoice(owner, card.getName() .. " would go to your hand", "It's your commander: put it into the command zone instead?",
      { { label = "COMMAND ZONE", value = true }, { label = "HAND", value = false } }, function(yes)
        if card.isDestroyed() then
          return
        end
        GameState.data.cmdAsked = GameState.data.cmdAsked or {}
        GameState.data.cmdAsked[card.getGUID()] = os.time()
        if yes then
          Combat.toCommandZone(card, owner)
        else
          returnToHand(card, true)
        end
      end)
    return
  end
  -- To its OWNER's hand (it may be someone else's card under this seat's control).
  do
    local owner = Effects.ownerOf(obj)
    if owner and owner ~= seat and TableSetup.isActive(owner) then
      seat = owner
    end
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

Effects.returnToHand = returnToHand

function Effects.pickBounce(seat, a, sourceName, sourceGuid)
  local want = tostring(a.type)
  local filter = function(obj, owner)
    if a.mine and owner ~= seat then
      return false
    end
    if a.other and sourceGuid and obj.getGUID() == sourceGuid then
      return false
    end
    if a.theirs and not TableSetup.isOpponent(owner, seat) then
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
      Combat.sacrifice(obj)
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
  if not found and Statics and Statics.hasGrantedKeyword then
    local okk, yes = pcall(Statics.hasGrantedKeyword, obj, kw)
    found = okk and yes or false
  end
  pcall(function()
    local d = CardData.get(obj)   -- (a double-faced card's keywords are just this face's)
    for _, k in ipairs(type(d) == "table" and d.keywords or {}) do
      if tostring(k):lower() == kw then
        found = true
      end
    end
  end)
  return found
end

Effects.hasKeyword = hasKeyword

-- Does a permanent fit "creatures", "nonland permanents"... and the scope?
local function fits(obj, owner, a, seat, sourceGuid)
  if a.scope == "mine" and owner ~= seat then
    return false
  elseif a.scope == "opponents" and not TableSetup.isOpponent(owner, seat) then
    return false
  end
  if a.enteredThisTurn then
    local ent = GameState.data.entered or {}
    local taken = GameState.data.turn and GameState.data.turn.taken
    if taken == nil or ent[obj.getGUID()] ~= taken then
      return false
    end
  end
  if a.notColor then
    local d = CardData.get(obj)
    for _, c in ipairs(type(d.colors) == "table" and d.colors or {}) do
      if tostring(c) == a.notColor then
        return false
      end
    end
  end
  if a.nonCreaturePerm then
    local ty = cardTypes(obj)
    return (ty.artifact or ty.enchantment) and not ty.creature and true or false
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
  -- Worldgorger Dragon: "When ~ leaves the battlefield, return the exiled cards" - remember what it exiled.
  local holdFor
  if a.verb == "exile" and it.source then
    local src = getObjectFromGUID(it.source)
    local ol = ""
    pcall(function() ol = tostring(CardData.get(src).oracle or ""):lower() end)
    if ol:find("leaves the battlefield, return the exiled cards", 1, true) then
      holdFor = it.source
    end
  end
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and obj.held_by_color == nil then
      local owner = fieldSeat(obj)
      if owner and fits(obj, owner, a, seat, it.source) then
        local name = obj.getName()
        local guid = obj.getGUID()
        local token = obj.hasTag("Token")
        if removeOne(obj, a.verb) then
          gone = gone + 1
          table.insert(names, name)
          if holdFor and not token then
            local held = GameState.data.heldExile or {}
            GameState.data.heldExile = held
            held[holdFor] = held[holdFor] or {}
            table.insert(held[holdFor], { guid = guid, owner = owner, name = name })
          end
        end
      end
    end
  end
  if gone > 0 then
    printToAll("MTG > " .. it.name .. ": " .. (a.verb == "exile" and "exiled " or "destroyed ")
      .. table.concat(names, ", ") .. "." .. (holdFor and (" They come back when " .. it.name .. " leaves the battlefield.") or ""), GOOD)
  end
  return gone
end

-- Finality counters: a permanent that has one goes to exile instead of the graveyard.
Events.on("cardMoved", function(d)
  local fin = GameState.data and GameState.data.finality
  if fin == nil or d.card == nil or d.from == nil or d.to == nil then
    return
  end
  local g = d.card.getGUID()
  if not fin[g] then
    return
  end
  local onField = d.from.region == "battlefield" or d.from.region == "lands"
  if onField and d.to.region == "graveyard" then
    fin[g] = nil
    local seat = d.to.seat or d.from.seat
    local card = d.card
    local name = card.getName()
    Wait.time(function()
      if seat == nil then
        return
      end
      local s = TableSetup.seat(seat)
      local spot = TableSetup.slot(seat, "exile", TableSetup.SURFACE_TOP + 2)
      if card.isDestroyed() then
        -- It already merged into the graveyard pile: take it back out of the pile.
        for _, o in ipairs(getObjects()) do
          if o.type == "Deck" and not o.isDestroyed() then
            local loc = Zones.regionAt(o.getPosition())
            if loc.seat == seat and loc.region == "graveyard" then
              for _, e in ipairs(o.getObjects()) do
                if e.guid == g then
                  local took = o.takeObject({ guid = g, position = spot, rotation = { 0, s.yaw, 0 }, smooth = false })
                  Wait.time(function() if took and not took.isDestroyed() then Zones.refresh(took) end end, 0.6)
                  break
                end
              end
            end
          end
        end
      else
        card.setRotation({ 0, s.yaw, 0 })
        card.setPosition(spot)
        Wait.time(function() if not card.isDestroyed() then Zones.refresh(card) end end, 0.6)
      end
      printToAll("MTG > " .. name .. " had a finality counter: exiled instead of going to the graveyard.", INFO)
    end, 0.4)
  elseif onField and d.to.region ~= "battlefield" and d.to.region ~= "lands" then
    fin[g] = nil    -- left the battlefield some other way (bounced, exiled): the counter is gone
  end
end)

-- Peregrine Drake: untap up to N of your tapped lands (the ones tapped are untapped, up to N).
function Effects.untapLands(seat, n, it)
  local s = TableSetup.seat(seat)
  local done = 0
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if done >= n then
      break
    end
    if obj.type == "Card" and not obj.isDestroyed() and obj.held_by_color == nil and fieldSeat(obj) == seat
        and Effects.cardTypes(obj).land then
      local r = obj.getRotation()
      local diff = ((r.y - s.yaw + 540) % 360) - 180
      if math.abs(diff) > 30 then
        obj.setRotationSmooth({ r.x, s.yaw, r.z }, false, true)
        done = done + 1
      end
    end
  end
  printToAll("MTG > " .. it.name .. ": " .. done .. " land(s) untapped.", GOOD)
end

-- How many cards are in a seat's graveyard (every pile and loose card there).
function Effects.graveyardSize(seat)
  local n = 0
  for _, obj in ipairs(getObjects()) do
    if (obj.type == "Deck" or obj.type == "Card") and not obj.isDestroyed() and obj.held_by_color == nil then
      local loc = Zones.regionAt(obj.getPosition())
      if loc.seat == seat and loc.region == "graveyard" then
        n = n + (obj.type == "Deck" and #obj.getObjects() or 1)
      end
    end
  end
  return n
end

-- Patient Naturalist: mill N, a land from among them goes to the hand (you pick if several); none: a Treasure.
function Effects.millLandToHand(seat, a, it)
  local lib = Library.find(seat)
  local lands = {}
  if lib and lib.type == "Deck" then
    for i, e in ipairs(lib.getObjects()) do
      if i > a.n then
        break
      end
      local d = {}
      pcall(function() d = JSON.decode(e.gm_notes) or {} end)
      if tostring(d.typeLine or ""):find("Land", 1, true) then
        table.insert(lands, { guid = e.guid, name = e.name ~= "" and e.name or tostring(d.name) })
      end
    end
  elseif lib then
    if tostring(CardData.get(lib).typeLine or ""):find("Land", 1, true) then
      table.insert(lands, { guid = lib.getGUID(), name = lib.getName() })
    end
  end
  Library.mill(seat, a.n, 0, function(done)
    local function toHand(pick)
      Wait.time(function()
        local hand = Player[seat].getHandTransform()
        local yard = Library.pileIn(seat, "graveyard")
        local loose = getObjectFromGUID(pick.guid)
        if loose and not loose.isDestroyed() and loose.type == "Card" then
          loose.setPositionSmooth(hand.position, false, true)
        elseif yard and yard.type == "Deck" then
          yard.takeObject({ guid = pick.guid, position = hand.position, smooth = true })
        else
          broadcastToColor(it.name .. ": put " .. pick.name .. " from your graveyard into your hand yourself.", seat, INFO)
          return
        end
        printToAll("MTG > " .. it.name .. ": " .. seat .. " puts " .. pick.name .. " into their hand.", GOOD)
      end, 0.6)
    end
    if #lands == 0 then
      if a.treasure then
        printToAll("MTG > " .. it.name .. ": no land among the milled cards: a Treasure instead.", GOOD)
        Tokens.create(seat, { words = { "treasure" }, colors = {} }, 1, it.name)
      end
    elseif #lands == 1 then
      toHand(lands[1])
    else
      local choices = {}
      for _, l in ipairs(lands) do
        table.insert(choices, { label = l.name:sub(1, 22), value = l.guid })
      end
      ask(seat, it.name .. ": a land to your hand", "Pick the land card from among the milled cards to put into your hand.",
        choices, function(g)
          for _, l in ipairs(lands) do
            if l.guid == g then
              toHand(l)
            end
          end
        end)
    end
  end)
end

-- Class enchantments: the level reached (1 until levelled up).
function Effects.classLevel(obj)
  local m = GameState.data.classLevels
  return (m and obj and m[obj.getGUID()]) or 1
end

-- A card's rules text without the Class levels it hasn't reached yet ("{2}{G}: Level 2" and the lines after it).
function Effects.unlockedText(obj, oracle)
  oracle = tostring(oracle or "")
  if not oracle:find(": Level 2", 1, true) then
    return oracle
  end
  local have = Effects.classLevel(obj)
  local out, level = {}, 1
  for line in (oracle .. "\n"):gmatch("([^\n]*)\n") do
    local lv = line:match(": Level (%d+)%s*$")
    if lv then
      level = tonumber(lv)
    end
    if level <= have or lv then
      table.insert(out, line)
    end
  end
  return table.concat(out, "\n")
end

-- Fell the Mighty: pick a creature; every creature with greater power is destroyed.
function Effects.fellMighty(seat, it)
  ask(seat, it.name .. ": choose target creature", "Click CHOOSE on a creature: each creature with power GREATER than its power is destroyed.",
    { { label = "SKIP", value = false } }, function(chosen)
      if not chosen or chosen.isDestroyed() then
        return
      end
      local p0 = tonumber(Counters.stats(chosen).power or "") or 0
      local gone, names = 0, {}
      for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
        if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and obj.held_by_color == nil
            and fieldSeat(obj) and Effects.cardTypes(obj).creature then
          local pw = tonumber(Counters.stats(obj).power or "") or 0
          if pw > p0 then
            local name = obj.getName()
            if removeOne(obj, "destroy") then
              gone = gone + 1
              table.insert(names, name)
            end
          end
        end
      end
      printToAll("MTG > " .. it.name .. ": chose " .. chosen.getName() .. " (power " .. p0 .. "); destroyed "
        .. (gone > 0 and table.concat(names, ", ") or "nothing") .. ".", GOOD)
    end, { filter = function(obj, owner)
      return owner ~= nil and Effects.cardTypes(obj).creature == true
    end, label = "CHOOSE" })
end

-- Cumulative upkeep: put an age counter on it, then pay the cost once per age counter, or sacrifice it.
function Effects.cumulativeUpkeep(seat, a, it)
  local src = it.source and getObjectFromGUID(it.source)
  if src == nil or src.isDestroyed() or not fieldSeat(src) then
    printToAll("MTG > " .. it.name .. ": it's gone, so there's no cumulative upkeep to pay.", INFO)
    return
  end
  Counters.change(src, "other", 1, seat)
  local n = Counters.get(src).other
  local cost = tostring(a.cost or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local mana = cost:match("^[{}%w/]+$") and cost:find("{", 1, true) and cost or nil
  local life = tonumber(cost:match("^pay (%d+) life$") or "")
  local total, say
  if mana then
    total = string.rep(mana, n)
    say = total
  elseif life then
    say = (life * n) .. " life"
  else
    say = cost .. " x" .. n
  end
  ask(seat, it.name .. ": cumulative upkeep", it.name .. " now has " .. n .. " age counter(s). Pay " .. say
    .. ", or sacrifice it.", { { label = "PAY " .. say:sub(1, 14), value = "pay" }, { label = "SACRIFICE", value = "sac" } },
    function(pick)
      if src.isDestroyed() then
        return
      end
      if pick == "pay" then
        if mana then
          local _, covered = ManaChips.pay(seat, total, it.name .. " (cumulative upkeep)")
          if not covered then
            broadcastToColor(it.name .. ": pay the rest of " .. total .. " yourself (tap lands, then it comes out of your pool).", seat, INFO)
          end
        elseif life then
          Trackers.changeLife(seat, -(life * n), it.name)
        else
          broadcastToColor(it.name .. ": pay " .. say .. " yourself.", seat, INFO)
        end
        printToAll("MTG > " .. seat .. " pays the cumulative upkeep for " .. it.name .. " (" .. say .. ").", INFO)
      elseif pick == "sac" then
        printToAll("MTG > " .. seat .. " sacrifices " .. it.name .. " instead of paying its cumulative upkeep.", INFO)
        Combat.sacrifice(src)
      end
    end)
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
          if a.beastToken and owner and Tokens and Tokens.create then
            Tokens.create(owner, { pt = "3/3", words = { "beast" }, colors = { G = true } }, 1, sourceName)
          end
          if a.basicForController and owner then
            LibSearch.open(owner, "basic land", sourceName .. ": you MAY search for a basic land card; it goes onto the battlefield. Then CLOSE + SHUFFLE (or just CLOSE).",
              "battlefield", false, { typeOnly = true, limit = 1 })
          end
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
  t = t:gsub("enters tapped with", "enters with")
  local w, kind = t:match("enters with (%w+) ([%w%+/%-]+) counters? on it")
  local n = num(w)
  -- Counters that depend on a number only the player knows: X, or the mana
  -- spent (Marath). The owner types it.
  local ask_kind = t:match("enters with x ([%w%+/%-]+) counters? on it")
  local mana_kind = t:match("enters with a number of ([%w%+/%-]+) counters on it equal to the amount of mana spent")
    or t:match("enters with a number of ([%w%+/%-]+) counters on it equal to the mana value")
  if n == nil and (ask_kind or mana_kind) and d.to.seat then
    local k2 = ask_kind or mana_kind
    local key2 = Counters.kindOf(k2)
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
              Combat.sacrifice(obj)
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
  local key = Counters.kindOf(kind)
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
    -- Eminence: the trigger only happens from the command zone or the battlefield, so it holds.
    if cond:find("is in the command zone or on the battlefield", 1, true) then
      return true
    end
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
    -- Metalcraft, Delirium-style counts: "you control three or more artifacts".
    local nw, thing = cond:match("^you control (%w+) or more (%a+)$")
    if nw then
      local need = tonumber(nw) or ({ two = 2, three = 3, four = 4, five = 5, six = 6, seven = 7, eight = 8, ten = 10 })[nw]
      if need then
        local have = Effects.countPermanents(seat, thing, "mine")
        return have >= need
      end
    end
    -- Threshold: "there are seven or more cards in your graveyard".
    local gw = cond:match("^there are (%w+) or more cards in your graveyard$")
    if gw and num(gw) then
      return Effects.graveyardSize(seat) >= num(gw)
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

---------------------------------------------------------------------------
-- Damage to creatures and planeswalkers, pay-or-sacrifice (Forge effects, "any target")
---------------------------------------------------------------------------

-- Damage marked on creatures this turn, outside combat (cleared when the turn changes).
local function markedDamage(obj, add)
  local d = GameState.data
  local t = d.turn or {}
  local now = tostring(t.number or 0) .. ":" .. tostring(t.activeSeat or "")
  if d.fxDamage == nil or d.fxDamage.turn ~= now then
    d.fxDamage = { turn = now, on = {} }
  end
  local g = obj.getGUID()
  d.fxDamage.on[g] = (d.fxDamage.on[g] or 0) + add
  return d.fxDamage.on[g]
end

-- `n` damage to a creature or planeswalker on the battlefield from `src` (may be nil).
function Effects.damageCreature(obj, n, src, sourceName, controller)
  if obj == nil or obj.isDestroyed() or n <= 0 then
    return
  end
  local name = obj.getName()
  local ty = cardTypes(obj)
  if ty.planeswalker and not ty.creature then
    Counters.change(obj, "loyalty", -n, controller)
    printToAll("MTG > " .. tostring(sourceName) .. " deals " .. n .. " damage to " .. name .. ": " .. n .. " loyalty removed.", GOOD)
  else
    local tough = tonumber(Counters.stats(obj).toughness or "")
    local total = markedDamage(obj, n)
    local deathtouch = src ~= nil and not src.isDestroyed() and hasKeyword(src, "deathtouch")
    if tough and (total >= tough or deathtouch) then
      if hasKeyword(obj, "indestructible") then
        printToAll("MTG > " .. tostring(sourceName) .. " deals " .. n .. " damage to " .. name .. ": lethal, but it's indestructible.", INFO)
      else
        printToAll("MTG > " .. tostring(sourceName) .. " deals " .. n .. " damage to " .. name .. ": it dies.", GOOD)
        Combat.removeCard(obj, "graveyard")
      end
    else
      printToAll("MTG > " .. tostring(sourceName) .. " deals " .. n .. " damage to " .. name
        .. (tough and (" (" .. total .. " this turn, toughness " .. tough .. ")") or " (check its toughness)") .. ".", INFO)
    end
  end
  if Triggers and Triggers.onDamage then
    pcall(Triggers.onDamage, { { obj = src, controller = controller, target = obj, amount = n } }, false)
  end
end

local function damageFits(obj, owner, a, seat, skip)
  if (a.scope == "you" and owner ~= seat) or (a.scope == "opp" and not TableSetup.isOpponent(owner, seat)) or skip[obj.getGUID()] then
    return false
  end
  local ty = cardTypes(obj)
  for k in pairs(a.kinds or { creature = true }) do
    if ty[k] then
      return true
    end
  end
  return false
end

-- "~ deals 3 damage to target creature": a DAMAGE button on each candidate (a.count times).
function Effects.pickDamage(seat, a, it)
  local src = (it.source and getObjectFromGUID(it.source)) or (it.card and getObjectFromGUID(it.card)) or nil
  local count, done = a.count or 1, {}
  local what = (a.kinds and a.kinds.planeswalker) and (a.kinds.creature and "creature or planeswalker" or "planeswalker")
    or "creature"
  local function one(k)
    if k > count then
      return
    end
    ask(seat, it.name .. ": " .. a.n .. " damage to target " .. what .. (count > 1 and (" (" .. k .. " of " .. count .. ")") or ""),
      "Click DAMAGE on the target, or SKIP.", { { label = "SKIP", value = false } }, function(obj)
        if obj then
          done[obj.getGUID()] = true
          Effects.damageCreature(obj, a.n, src, it.name, seat)
          one(k + 1)
        else
          printToAll("MTG > " .. it.name .. ": " .. (k == 1 and "no target chosen." or "no more targets."), INFO)
        end
      end, { filter = function(obj, owner) return damageFits(obj, owner, a, seat, done) end, label = "DAMAGE" })
  end
  one(1)
end

-- "~ deals 2 damage to each creature your opponents control (and each opponent)".
function Effects.forgeDamageAll(seat, a, it)
  local src = (it.source and getObjectFromGUID(it.source)) or (it.card and getObjectFromGUID(it.card)) or nil
  if a.cards then
    local parts = {}
    for w in tostring(a.cards):gmatch("[^%.]+") do
      parts[w] = true
    end
    local hit = {}
    for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
      if obj.type == "Card" and not obj.isDestroyed() and not Faces.unknown(obj) and obj.held_by_color == nil then
        local owner = fieldSeat(obj)
        if owner and cardTypes(obj).creature
            and not (parts.you and owner ~= seat) and not (parts.opp and owner == seat)
            and not (parts.o and it.source and obj.getGUID() == it.source)
            and not (parts.fly and not hasKeyword(obj, "flying")) and not (parts.nofly and hasKeyword(obj, "flying")) then
          table.insert(hit, obj)
        end
      end
    end
    for _, obj in ipairs(hit) do
      Effects.damageCreature(obj, a.n, src, it.name, seat)
    end
    if #hit == 0 then
      printToAll("MTG > " .. it.name .. ": no creatures to damage.", INFO)
    end
  end
  if a.players then
    for _, c in ipairs(players()) do
      if a.players == "each" or TableSetup.isOpponent(c, seat) then
        Trackers.changeLife(c, -a.n, it.name)
        if Triggers and Triggers.onDamage then
          pcall(Triggers.onDamage, { { obj = src, controller = seat, seat = c, amount = a.n } }, false)
        end
      end
    end
  end
end

-- "Sacrifice ~ unless you pay {2}": the controller picks.
function Effects.payOrSacrifice(seat, a, it)
  local src = it.source and getObjectFromGUID(it.source)
  if src == nil or src.isDestroyed() or not fieldSeat(src) then
    printToAll("MTG > " .. it.name .. ": it's gone already.", INFO)
    return
  end
  ask(seat, it.name .. ": pay " .. tostring(a.cost) .. "?", "Pay " .. tostring(a.cost) .. ", or " .. it.name .. " is sacrificed.",
    { { label = "PAY " .. tostring(a.cost), value = true }, { label = "SACRIFICE", value = false } }, function(pay)
      if pay then
        local covered = false
        if ManaChips and ManaChips.pay then
          local okP, _, cov = pcall(ManaChips.pay, seat, a.cost, it.name)
          covered = okP and cov
        end
        printToAll("MTG > " .. seat .. " pays " .. tostring(a.cost) .. " for " .. it.name
          .. (covered and "." or " (take the mana from your pool by hand if it wasn't)."), GOOD)
      else
        printToAll("MTG > " .. seat .. " sacrifices " .. it.name .. ".", GOOD)
        Combat.sacrifice(src)
      end
    end)
end

-- "Return it to its owner's hand" / destroy / exile / damage: the creature that triggered it.
function Effects.forgeThat(seat, a, it)
  local obj = it.thatCard and getObjectFromGUID(it.thatCard)
  if obj == nil or obj.isDestroyed() or not fieldSeat(obj) then
    printToAll("MTG > " .. it.name .. ": that creature isn't on the battlefield any more - nothing happens.", INFO)
    return
  end
  local name = obj.getName()
  if a.verb == "damage" then
    local src = (it.source and getObjectFromGUID(it.source)) or nil
    Effects.damageCreature(obj, a.n, src, it.name, seat)
  elseif a.verb == "bounce" then
    returnToHand(obj)
  elseif removeOne(obj, a.verb) then
    printToAll("MTG > " .. it.name .. ": " .. (a.verb == "exile" and "exiled " or "destroyed ") .. name .. ".", GOOD)
  end
end

-- Does a permanent fit a Forge target ("creature/nonland", control, another)?
local function kindsFit(obj, owner, a, seat, src)
  if (a.scope == "you" and owner ~= seat) or (a.scope == "opp" and not TableSetup.isOpponent(owner, seat)) then
    return false
  end
  if a.other and src and obj.getGUID() == src then
    return false
  end
  local ty = cardTypes(obj)
  for k in pairs(a.kinds or {}) do
    if k == "permanent" or ty[k] or (k:sub(1, 3) == "non" and not ty[k:sub(4)]) then
      return true
    end
  end
  return false
end

-- Exile a permanent and return it now (blink) or at the beginning of the next end step.
function Effects.forgeFlicker(seat, a, it)
  local function go(obj)
    if obj == nil or obj.isDestroyed() or not fieldSeat(obj) then
      printToAll("MTG > " .. it.name .. ": it isn't on the battlefield any more - nothing happens.", INFO)
      return
    end
    if not a.atEnd then
      Effects.blinkCard(obj, seat, it.name)
      return
    end
    local name, guid = obj.getName(), obj.getGUID()
    local owner = (Effects.ownerOf and Effects.ownerOf(obj)) or fieldSeat(obj)
    local token = obj.hasTag("Token")
    Combat.removeCard(obj, "exile")
    if token then
      printToAll("MTG > " .. it.name .. ": " .. name .. " is exiled (a token: it won't come back).", GOOD)
      return
    end
    printToAll("MTG > " .. it.name .. ": " .. name .. " is exiled; it returns at the beginning of the next end step.", GOOD)
    Effects.addDelayed({ seat = seat, anySeat = true, step = "end", kind = "returnCard", guid = guid, owner = owner, name = it.name })
  end
  if a.on == "self" then
    go(it.source and getObjectFromGUID(it.source))
  elseif a.on == "that" then
    go(it.thatCard and getObjectFromGUID(it.thatCard))
  else
    ask(seat, it.name .. ": exile a target" .. (a.atEnd and " (it returns at the next end step)" or " and return it"),
      "Click EXILE on the target, or SKIP.", { { label = "SKIP", value = false } }, function(obj)
        if obj then
          go(obj)
        else
          printToAll("MTG > " .. it.name .. ": no target chosen.", INFO)
        end
      end, { filter = function(obj, owner) return kindsFit(obj, owner, a, seat, it.source) end, label = "EXILE" })
  end
end

-- Base power / toughness set by an effect (nil, nil: back to the printed values).
function Effects.setBasePT(obj, p, t)
  local parts = {}
  for k, v in tostring(obj.memo or ""):gmatch("(%a+)=(%-?%d+)") do
    if k ~= "bp" and k ~= "bt" and k ~= "bs" then
      table.insert(parts, k .. "=" .. v)
    end
  end
  if p and t then
    table.insert(parts, "bp=" .. p)
    table.insert(parts, "bt=" .. t)
    table.insert(parts, "bs=1")
  end
  obj.memo = table.concat(parts, ";")
  Counters.render(obj)
end

-- "~ becomes a 3/3 Elemental creature with haste until end of turn."
function Effects.forgeAnimate(seat, a, it)
  local function go(obj)
    if obj == nil or obj.isDestroyed() or not fieldSeat(obj) then
      printToAll("MTG > " .. it.name .. ": it isn't on the battlefield any more - nothing happens.", INFO)
      return
    end
    local g = obj.getGUID()
    GameState.data.animated = GameState.data.animated or {}
    GameState.data.animated[g] = true
    Effects.setBasePT(obj, a.p, a.t)
    for k in tostring(a.kw or ""):gmatch("[^&]+") do
      for w in (k .. " and "):gmatch("(.-) and ") do
        local kw = (w:gsub("^%s+", ""):gsub("%s+$", ""))
        if kw ~= "" and Counters.addTempKeyword then
          Counters.addTempKeyword(obj, kw)
        end
      end
    end
    if not a.perm then
      Effects.addDelayed({ seat = seat, anySeat = true, step = "cleanup", kind = "forgeUnanimate", guid = g, name = it.name })
    end
    printToAll("MTG > " .. it.name .. ": " .. obj.getName() .. " becomes a " .. a.p .. "/" .. a.t
      .. ((a.types and a.types ~= "") and (" " .. a.types) or "") .. " creature"
      .. ((a.kw and a.kw ~= "") and (" with " .. a.kw) or "") .. (a.perm and "." or " until end of turn."), GOOD)
  end
  if a.on == "self" then
    go(it.source and getObjectFromGUID(it.source))
  elseif a.on == "that" then
    go(it.thatCard and getObjectFromGUID(it.thatCard))
  else
    ask(seat, it.name .. ": choose the target", "Click TARGET on it, or SKIP.", { { label = "SKIP", value = false } }, function(obj)
      if obj then
        go(obj)
      else
        printToAll("MTG > " .. it.name .. ": no target chosen.", INFO)
      end
    end, { filter = function(obj, owner) return kindsFit(obj, owner, a, seat, it.source) end, label = "TARGET" })
  end
end

-- A permanent changes control: it moves onto that seat's battlefield (its owner stays the same).
function Effects.moveToSeat(obj, seat)
  local st = TableSetup.seat(seat)
  if st == nil then
    return
  end
  local land = cardTypes(obj).land and not cardTypes(obj).creature
  obj.setLock(false)
  obj.setRotationSmooth({ 0, st.yaw, 0 }, false, true)
  obj.setPositionSmooth(TableSetup.slot(seat, land and "lands" or "battlefield", TableSetup.SURFACE_TOP + 2), false, true)
  Wait.time(function()
    if not obj.isDestroyed() then
      Zones.refresh(obj)
    end
  end, 1.2)
end

local function forgePick(seat, a, it, label, go)
  if a.on == "self" then
    go(it.source and getObjectFromGUID(it.source))
  elseif a.on == "that" then
    go(it.thatCard and getObjectFromGUID(it.thatCard))
  else
    ask(seat, it.name .. ": choose the target", "Click " .. label .. " on it, or SKIP.", { { label = "SKIP", value = false } }, function(obj)
      if obj then
        go(obj)
      else
        printToAll("MTG > " .. it.name .. ": no target chosen.", INFO)
      end
    end, { filter = function(obj, owner) return kindsFit(obj, owner, a, seat, it.source) end, label = label })
  end
end

-- "Gain control of target creature until end of turn. Untap it. It gains haste."
function Effects.forgeControl(seat, a, it)
  forgePick(seat, a, it, "TARGET", function(obj)
    local from = obj and not obj.isDestroyed() and fieldSeat(obj)
    if not from then
      printToAll("MTG > " .. it.name .. ": it isn't on the battlefield any more - nothing happens.", INFO)
      return
    end
    if from ~= seat then
      if Effects.ownerOf and Effects.setOwner and Effects.ownerOf(obj) == nil then
        Effects.setOwner(obj, from)
      end
      Effects.moveToSeat(obj, seat)
    end
    if a.untap then
      Wait.time(function()
        if not obj.isDestroyed() then
          Effects.untapObj(obj)
        end
      end, 1.4)
    end
    if a.haste and Counters.addTempKeyword then
      Counters.addTempKeyword(obj, "haste")
    end
    if a.eot and from ~= seat then
      Effects.addDelayed({ seat = seat, anySeat = true, step = "cleanup", kind = "forgeControlBack", guid = obj.getGUID(), to = from,
        name = it.name })
    end
    printToAll("MTG > " .. it.name .. ": " .. seat .. " gains control of " .. obj.getName() .. (a.eot and " until end of turn" or "")
      .. (a.untap and ", untaps it" or "") .. (a.haste and ", it gains haste" or "") .. ".", GOOD)
  end)
end

-- "Regenerate ~": a shield marker until end of turn, and the reminder of what it does.
function Effects.forgeRegen(seat, a, it)
  forgePick(seat, a, it, "REGENERATE", function(obj)
    if obj == nil or obj.isDestroyed() or not fieldSeat(obj) then
      printToAll("MTG > " .. it.name .. ": it isn't on the battlefield any more - nothing happens.", INFO)
      return
    end
    if Counters.addTempKeyword then
      Counters.addTempKeyword(obj, "regeneration shield")
    end
    printToAll("MTG > " .. obj.getName() .. " has a regeneration shield this turn: the next time it would be destroyed, instead"
      .. " tap it, remove it from combat and remove all damage from it (do that by hand).", GOOD)
  end)
end

---------------------------------------------------------------------------
-- Targets (CR 115). A spell or ability's targets are chosen as it goes on the stack
-- (Effects.chooseTargets, from stack.lua), so everyone can see what it's aimed at before they
-- answer. As it resolves (Effects.checkTargets) each target is checked again: one that has left
-- the battlefield (even if it came back: a new object), changed type, or gained hexproof, shroud
-- or protection is no longer legal. With none legal, the spell or ability does nothing
-- ("fizzles"); otherwise the resolving code's own target prompts are answered from the chosen
-- targets (Effects.replayAnswer, called from ask), skipping the illegal ones. A target the reader
-- below doesn't recognise is still asked for as it resolves, the way it always was.
---------------------------------------------------------------------------

-- Times each card has left the battlefield: a card that leaves and comes back is a new object.
local zoneChanges = {}
Events.on("cardMoved", function(d)
  if d.card == nil or d.from == nil then
    return
  end
  local fromField = d.from.region == "battlefield" or d.from.region == "lands"
  local toField = d.to and (d.to.region == "battlefield" or d.to.region == "lands")
  if fromField and not toField then
    local ok, g = pcall(function() return d.card.getGUID() end)
    if ok and g then
      zoneChanges[g] = (zoneChanges[g] or 0) + 1
    end
  end
end)

local TARGET_TYPES = { creature = true, artifact = true, enchantment = true, planeswalker = true, land = true,
  permanent = true, battle = true }
local TARGET_COUNT = { ["up to one"] = { 1, true }, ["up to two"] = { 2, true }, ["up to three"] = { 3, true },
  ["up to four"] = { 4, true }, ["one or two"] = { 2, true }, ["one, two, or three"] = { 3, true },
  ["two"] = { 2, false }, ["three"] = { 3, false }, ["four"] = { 4, false }, ["any number of"] = { 9, true } }
local TARGET_ADJ = { tapped = true, untapped = true, attacking = true, blocking = true, legendary = true,
  nonlegendary = true, token = true, nontoken = true, white = true, blue = true, black = true, red = true, green = true,
  colorless = true, multicolored = true, ["or"] = true, ["and/or"] = true }

-- The targets a rules text asks for, in order. Each: { kind = "player" | "opponent" | "any" | "card",
-- n = how many, upTo = may choose fewer, types = { creature = true, ... }, nots = { land = true },
-- ctrl = "you" | "opp" | "notyou" | nil, other = not the source, tapped / untapped / attacking }.
function Effects.targetSpecs(text)
  local t = " " .. tostring(text or ""):lower() .. " "
  t = t:gsub('"[^"]*"', ""):gsub("%b()", "")
  local out = {}
  local from = 1
  while true do
    local a, b = t:find("target", from, true)
    if not a then
      break
    end
    from = b + 1
    local nextCh = t:sub(b + 1, b + 1)
    local before = t:sub(math.max(1, a - 30), a - 1)
    local after = t:sub(b + 2)
    local sp
    -- Not a target being chosen: "becomes the target of", "choose new targets", "change the target".
    if (before:find("any $") or before:find("any other $")) and nextCh ~= "s" then
      sp = { kind = "any", n = 1, other = before:find("other $") ~= nil }
    elseif nextCh ~= " " or before:find("the $") or before:find("new $") or before:find("its $") or before:find("their $") then
      sp = nil
    else
      local w1 = after:match("^(%a+)") or ""
      if w1 == "player" or w1 == "players" then
        sp = { kind = after:find("^players? or planeswalker") and "any" or "player" }
        if sp.kind == "any" then
          sp.pwOnly = true
        end
      elseif w1 == "opponent" or w1 == "opponents" then
        sp = { kind = "opponent" }
      else
        -- Words that make up what it targets ("creature or planeswalker", "nonland permanent").
        local types, nots, adj = {}, {}, {}
        local rest = after
        local any = false
        while true do
          local w = rest:match("^(%S+)")
          if w == nil then
            break
          end
          local bare = w:gsub("[%.,;:]$", "")
          local stop = bare ~= w
          if TARGET_TYPES[bare] or TARGET_TYPES[bare:gsub("s$", "")] then
            types[bare:gsub("s$", "")] = true
            any = true
          elseif bare:sub(1, 3) == "non" and #bare > 3 and (TARGET_TYPES[bare:sub(4)] or TARGET_ADJ[bare]) then
            if TARGET_TYPES[bare:sub(4)] then
              nots[bare:sub(4)] = true
            else
              adj[bare] = true
            end
          elseif TARGET_ADJ[bare] then
            adj[bare] = true
          elseif bare == "another" or bare == "other" then
            adj.other = true
          else
            break
          end
          rest = rest:sub(#w + 1):gsub("^%s+", "")
          if stop then
            rest = ""
            break
          end
        end
        local nextWord = rest:match("^(%a+)") or ""
        local sentence = after:sub(1, (after:find("[%.;]") or (#after + 1)) - 1)
        if w1 == "activated" or w1 == "triggered" then
          -- "target activated or triggered ability" (Stifle).
          sp = { kind = "spell", ability = true, spellsToo = false, filt = "" }
        elseif nextWord == "spell" or nextWord == "spells" then
          -- "target spell", "target noncreature spell", "target spell or ability".
          local filt = after:sub(1, #after - #rest):gsub("%s+$", "")
          sp = { kind = "spell", filt = filt, spellsToo = true,
            ability = rest:find("^spells? or ability") ~= nil or rest:find("^spells?, activated ability, or triggered ability") ~= nil }
        elseif (nextWord == "card" or nextWord == "cards") and sentence:find("graveyard", 1, true) then
          -- "target creature card from your graveyard", "target card from a graveyard".
          local whose = "any"
          if sentence:find("your graveyard", 1, true) then
            whose = "you"
          elseif sentence:find("opponent's graveyard", 1, true) then
            whose = "opp"
          end
          sp = { kind = "gycard", types = types, nots = nots, whose = whose,
            phrase = (after:sub(1, #after - #rest) .. "card"):gsub("^%s+", "") }
        elseif nextWord == "card" or nextWord == "cards" then
          sp = nil
        elseif any and adj["or"] and nextWord == "player" and types.creature then
          -- Older wording: "target creature or player" is any target.
          sp = { kind = "any" }
        elseif any then
          sp = { kind = "card", types = types, nots = nots, other = adj.other or before:find("another $") ~= nil,
            tapped = adj.tapped, untapped = adj.untapped, attacking = adj.attacking, blocking = adj.blocking,
            token = adj.token, nontoken = adj.nontoken }
          if rest:find("^you control") then
            sp.ctrl = "you"
          elseif rest:find("^an opponent controls") or rest:find("^your opponents control") then
            sp.ctrl = "opp"
          elseif rest:find("^you don't control") then
            sp.ctrl = "notyou"
          end
          sp.phrase = after:sub(1, #after - #rest):gsub("%s+$", ""):gsub("[%.,;:]$", "")
        elseif nextWord ~= "" and not adj.other and (before:find("^.*%s$") ~= nil) then
          -- "target Goblin", "target Elf you control": a creature type.
          local stop = after:find("[%.,;]") or (#after + 1)
          local chunk = after:sub(1, stop - 1)
          local tw = chunk:match("^(%a+)")
          if tw and tw ~= "spell" and tw ~= "card" and tw ~= "ability" and tw ~= "activated" and tw ~= "triggered"
              and tw ~= "instant" and tw ~= "sorcery" and not chunk:find(" card", 1, true) and not chunk:find(" spell", 1, true)
              and not chunk:find("graveyard", 1, true) and not chunk:find("library", 1, true) then
            sp = { kind = "card", types = { creature = true }, nots = {}, sub = tw:gsub("s$", ""), phrase = tw }
            if chunk:find(" you control", 1, true) then
              sp.ctrl = "you"
            elseif chunk:find(" an opponent controls", 1, true) then
              sp.ctrl = "opp"
            end
          end
        end
      end
    end
    if sp then
      sp.n, sp.upTo = 1, false
      local best = 0
      for k, v in pairs(TARGET_COUNT) do
        if #k > best and before:sub(-(#k + 1)) == k .. " " then
          sp.n, sp.upTo, best = v[1], v[2], #k
        end
      end
      table.insert(out, sp)
    end
  end
  return out
end

-- Can `obj` (controlled by `owner`) be this target for `seat`'s spell or ability from `srcGuid`?
local function targetFits(sp, obj, owner, seat, srcGuid, taken)
  if obj == nil or owner == nil then
    return false
  end
  local g = obj.getGUID()
  if taken and taken[g] then
    return false
  end
  if sp.other and srcGuid and g == srcGuid then
    return false
  end
  local ty = cardTypes(obj)
  if sp.kind == "any" then
    if not (ty.creature or ty.planeswalker or ty.battle) or (sp.pwOnly and not ty.planeswalker) then
      return false
    end
  else
    local okT = false
    for k in pairs(sp.types or {}) do
      if k == "permanent" or ty[k] then
        okT = true
      end
    end
    if not okT then
      return false
    end
    for k in pairs(sp.nots or {}) do
      if ty[k] then
        return false
      end
    end
    if sp.landSub and not tostring(CardData.get(obj).typeLine or ""):lower():find(sp.landSub, 1, true) then
      return false
    end
    if sp.sub and Statics and Statics.typeMatches then
      local d = CardData.get(obj)
      if not Statics.typeMatches(d.typeLine, d.oracle, sp.sub) then
        return false
      end
    end
  end
  if sp.ctrl == "you" and owner ~= seat then
    return false
  elseif sp.ctrl == "opp" and not TableSetup.isOpponent(owner, seat) then
    return false
  elseif sp.ctrl == "notyou" and owner == seat then
    return false
  end
  if sp.tapped or sp.untapped then
    local st = TableSetup.seat(owner)
    local tapped = st ~= nil and math.abs(((obj.getRotation().y - st.yaw + 540) % 360) - 180) > 30
    if (sp.tapped and not tapped) or (sp.untapped and tapped) then
      return false
    end
  end
  if (sp.attacking or sp.blocking) and Combat and Combat.isAttacking then
    local att = Combat.isAttacking(obj)
    local blk = Combat.isBlocking and Combat.isBlocking(obj) or false
    if not ((sp.attacking and att) or (sp.blocking and blk)) then
      return false
    end
  end
  if sp.token and not obj.hasTag("Token") then
    return false
  elseif sp.nontoken and obj.hasTag("Token") then
    return false
  end
  -- Shroud: nobody can target it. Hexproof: its controller's opponents can't. Protection: not by this source.
  if hasKeyword(obj, "shroud") then
    return false
  end
  if owner ~= seat and TableSetup.isOpponent(owner, seat) and hasKeyword(obj, "hexproof") then
    return false
  end
  if Equip and Equip.protectedFrom and srcGuid then
    local okp, pro = pcall(Equip.protectedFrom, obj, srcGuid)
    if okp and pro then
      return false
    end
  end
  return true
end
Effects.targetFits = targetFits

local function seatRGB(seat)
  local rgb = { 1, 1, 1 }
  pcall(function()
    local c = stringColorToRGB(seat)
    if c then
      rgb = { c.r or c[1], c.g or c[2], c.b or c[3] }
    end
  end)
  return rgb
end

local function highlightTargets(it, on)
  for _, e in ipairs(it.preTargets or {}) do
    if e.kind == "card" then
      local obj = getObjectFromGUID(e.guid)
      if obj and not obj.isDestroyed() then
        pcall(function()
          if on then
            obj.highlightOn(seatRGB(it.controller))
          else
            obj.highlightOff()
          end
        end)
      end
    end
  end
end

function Effects.clearTargets(it)
  if it then
    highlightTargets(it, false)
  end
end

-- What a stack item's targets read as ("Llanowar Elves (Green), Red").
function Effects.targetSummary(it)
  local parts = {}
  for _, e in ipairs(it.preTargets or {}) do
    if e.kind == "player" then
      table.insert(parts, e.seat)
    else
      table.insert(parts, tostring(e.name) .. " (" .. tostring(e.owner) .. ")")
    end
  end
  return table.concat(parts, ", ")
end

-- The rules text a stack item resolves with, minus the trigger ("When ~ enters, ") or the cost ("{T}: ").
local function targetBody(text)
  local t = tostring(text or "")
  local low = t:lower()
  local colon = low:find(": ", 1, true)
  if colon and colon < 80 then
    local head = low:sub(1, colon)
    if head:find("{", 1, true) or head:find("^tap") or head:find("^sacrifice") or head:find("^pay")
        or head:find("^discard") or head:find("^exile") or head:find("^remove") or head:find("^[%+%-−]%d") then
      return low:sub(colon + 2)
    end
  end
  return effectPart(low)
end

-- Choose the targets for a stack item now (as it goes on the stack). done() runs once they're chosen.
-- Modes of a modal spell or ability: { modes = { "text", ... }, kind = "one" | "two" | "three" | "many" }, or nil.
function Effects.modeInfo(raw)
  raw = tostring(raw or "")
  local lowRaw = raw:lower()
  local modes = {}
  local spree = lowRaw:find("spree", 1, true) and raw:find("\n+ ", 1, true)
  if spree then
    for line in raw:gmatch("[^\n]+") do
      if line:sub(1, 2) == "+ " then
        local body = line:match("— (.*)$") or line:sub(3)
        local cost = (line:match("^%+ ([^—]*)—") or ""):gsub("%s+$", "")
        table.insert(modes, (body:gsub("%s+$", "")) .. (cost ~= "" and (" [pay " .. cost .. "]") or ""))
      end
    end
  else
    local bullet = raw:find("•", 1, true)
    if not bullet then
      return nil
    end
    local rest = raw:sub(bullet)
    local pos = 1
    while true do
      local a = rest:find("•", pos, true)
      if not a then
        break
      end
      local b = rest:find("•", a + 1, true)
      local m = rest:sub(a + #"•", (b or (#rest + 1)) - 1):gsub("^%s+", ""):gsub("%s+$", "")
      if m ~= "" then
        table.insert(modes, m)
      end
      if not b then
        break
      end
      pos = b
    end
  end
  if #modes == 0 then
    return nil
  end
  local kind = "one"
  if spree or lowRaw:find("choose one or more", 1, true) or lowRaw:find("choose any number", 1, true) then
    kind = "many"
  elseif lowRaw:find("choose two", 1, true) then
    kind = "two"
  elseif lowRaw:find("choose three", 1, true) then
    kind = "three"
  elseif lowRaw:find("you may choose both", 1, true) then
    kind = "will"
  end
  return { modes = modes, kind = kind }
end

-- Choose the modes now, as it's cast / put on the stack (CR 601.2b). cb(list of mode texts).
local function chooseModes(it, info, cb)
  local seat = it.controller
  local kind = info.kind
  if kind == "will" then
    kind = (Effects.controlsCommander and Effects.controlsCommander(seat)) and "many" or "one"
  end
  local function banner(chosen)
    if #chosen > 0 then
      printToAll("MTG > " .. it.name .. " (" .. seat .. ") mode" .. (#chosen == 1 and "" or "s") .. ": " .. table.concat(chosen, " + "), { 1, 0.85, 0.3 })
    else
      printToAll("MTG > " .. it.name .. " (" .. seat .. "): no mode chosen.", INFO)
    end
  end
  if kind == "many" then
    local chosen = {}
    local function step(i)
      if i > #info.modes then
        banner(chosen)
        return cb(chosen)
      end
      ask(seat, it.name .. ": mode " .. i .. " of " .. #info.modes, info.modes[i],
        { { label = "USE IT", value = true }, { label = "SKIP IT", value = false } }, function(yes)
          if yes then
            table.insert(chosen, info.modes[i])
          end
          step(i + 1)
        end)
    end
    return step(1)
  end
  local need = (kind == "two" and 2) or (kind == "three" and 3) or 1
  local chosen, used = {}, {}
  local function pick()
    if #chosen >= need then
      banner(chosen)
      return cb(chosen)
    end
    local lines, choices = {}, {}
    for i, m in ipairs(info.modes) do
      if not used[i] and #choices < MAX_CHOICES then
        table.insert(lines, i .. ") " .. (#m > 150 and (m:sub(1, 148) .. "...") or m))
        table.insert(choices, { label = tostring(i), value = i })
      end
    end
    ask(seat, it.name .. ": choose a mode" .. (need > 1 and (" (" .. (#chosen + 1) .. " of " .. need .. ")") or ""),
      "Choose now, as it goes on the stack.\n" .. table.concat(lines, "\n"), choices, function(i)
        i = tonumber(i) or 1
        used[i] = true
        table.insert(chosen, info.modes[i])
        pick()
      end)
  end
  pick()
end

-- "Enchant creature you control" -> a target spec.
local LAND_TYPES = { forest = true, island = true, swamp = true, mountain = true, plains = true }
function Effects.auraSpec(phrase)
  local p = tostring(phrase or ""):lower():gsub("^%s+", ""):gsub("[%.%s]+$", "")
  if LAND_TYPES[p] then
    return { kind = "card", types = { land = true }, nots = {}, landSub = p, phrase = p, n = 1, upTo = false }
  end
  local list = Effects.targetSpecs("target " .. p)
  local sp = list[1]
  if sp == nil then
    sp = { kind = "card", types = { permanent = true }, nots = {}, phrase = p }
  end
  sp.n, sp.upTo = 1, false
  return sp
end

local pickAll

-- Choose the targets (and modes) for a stack item now, as it goes on the stack. done() runs once they're chosen.
function Effects.chooseTargets(it, done)
  local function finish()
    it.choosing = nil
    if done then
      done()
    end
  end
  if not enabled() or not GameState.data.started or it == nil then
    return finish()
  end
  if it.kind ~= "card" and (not it.auto or it.copyOf or it.planar or it.ninjutsu) then
    return finish()
  end
  if not TableSetup.isActive(it.controller) then
    return finish()
  end
  -- An Aura spell targets what it will enchant (CR 303.4a).
  if it.auraText then
    return pickAll(it, it.auraText, { Effects.auraSpec(it.auraText) }, done)
  end
  local text = it.kind == "card" and it.targetText or it.text
  if tostring(text or "") == "" then
    return finish()
  end
  local info = Effects.modeInfo(text)
  if info and not it.modesChosen then
    it.choosing = true
    it.choosingAt = os.time()
    return chooseModes(it, info, function(chosen)
      it.modesChosen = chosen
      local body = table.concat(chosen, " ")
      pickAll(it, body, Effects.targetSpecs((body:gsub(" %[pay [^%]]*%]", ""))), done)
    end)
  end
  pickAll(it, text, Effects.targetSpecs(targetBody(text)), done)
end

-- The candidates for a "target spell / ability" on the stack (not the item itself).
local function stackCandidates(it, sp)
  local out = {}
  for _, e in ipairs(Stack.entries()) do
    if e.guid ~= it.guid and e.guid ~= it.card then
      local obj = getObjectFromGUID(e.guid)
      if obj then
        if e.kind == "ability" then
          if sp.ability then
            table.insert(out, e)
          end
        elseif sp.spellsToo and spellFits(obj, sp.filt, nil) then
          table.insert(out, e)
        end
      end
    end
  end
  return out
end

-- The cards in a seat's graveyard: { guid, name, typeLine }.
local function graveyardCards(seat)
  local out = {}
  local pile = Library and Library.pileIn and Library.pileIn(seat, "graveyard")
  if pile and pile.type == "Deck" then
    for _, e in ipairs(pile.getObjects() or {}) do
      local tl = ""
      pcall(function()
        local d = JSON.decode(e.gm_notes or "")
        tl = type(d) == "table" and tostring(d.typeLine or "") or ""
      end)
      table.insert(out, { guid = e.guid, name = e.name or e.nickname or "?", typeLine = tl })
    end
  elseif pile and pile.type == "Card" then
    table.insert(out, { guid = pile.getGUID(), name = pile.getName(), typeLine = tostring(CardData.get(pile).typeLine or "") })
  end
  return out
end
Effects.graveyardCards = graveyardCards

function pickAll(it, text, specs, done)
  local function finish()
    it.choosing = nil
    if done then
      done()
    end
  end
  if #specs == 0 then
    return finish()
  end
  local seat = it.controller
  local src = it.source or it.guid
  if not TableSetup.isActive(seat) then
    return finish()
  end
  it.choosing = true
  it.choosingAt = os.time()
  it.preTargets = {}
  it.targetsChosen = true
  local taken = {}
  local si = 0
  local nextSpec
  local function pickCard(sp, k, cont)
    local what = sp.kind == "any" and (sp.pwOnly and "planeswalker" or "creature or planeswalker") or tostring(sp.phrase or "permanent")
    ask(seat, it.name .. ": target " .. what .. (sp.n > 1 and (" (" .. k .. " of " .. (sp.upTo and ("up to " .. sp.n) or sp.n) .. ")") or ""),
      "Choose the target now, as it goes on the stack. Click TARGET on it" .. ((sp.upTo or k > 1) and ", or DONE." or ", or SKIP if there's no legal target."),
      { { label = (sp.upTo or k > 1) and "DONE" or "SKIP", value = false } }, function(obj)
        if obj then
          local owner = fieldSeat(obj)
          taken[obj.getGUID()] = true
          table.insert(it.preTargets, { kind = "card", guid = obj.getGUID(), name = obj.getName(), owner = owner,
            zc = zoneChanges[obj.getGUID()] or 0, spec = sp })
          cont()
        else
          nextSpec()
        end
      end, { filter = function(obj, owner) return targetFits(sp, obj, owner, seat, src, taken) end, label = "TARGET", src = src,
        choosing = true })
  end
  nextSpec = function()
    si = si + 1
    local sp = specs[si]
    if sp == nil then
      if #it.preTargets > 0 then
        highlightTargets(it, true)
        printToAll("MTG > " .. it.name .. " (" .. seat .. ") targets " .. Effects.targetSummary(it) .. ".", { 1, 0.85, 0.3 })
        -- Ward on anything it targets: the ward trigger goes on top (CR 702.21).
        if Effects.wardTriggers then
          pcall(Effects.wardTriggers, it)
        end
      else
        printToAll("MTG > " .. it.name .. " (" .. seat .. "): no target chosen.", INFO)
      end
      Stack.render()
      return finish()
    end
    local k = 0
    local function one()
      k = k + 1
      if k > sp.n then
        return nextSpec()
      end
      if sp.kind == "card" then
        return pickCard(sp, k, one)
      end
      if sp.kind == "spell" then
        -- "Target spell / ability": one of the items on the stack.
        local cands = stackCandidates(it, sp)
        if #cands == 0 then
          printToAll("MTG > " .. it.name .. ": nothing on the stack it can target.", INFO)
          return nextSpec()
        end
        local lines, choices = {}, {}
        for i = #cands, 1, -1 do
          if #choices < MAX_CHOICES - 1 then
            local e = cands[i]
            table.insert(lines, (#choices + 1) .. ") " .. e.name .. (e.kind == "ability" and "'s ability" or "") .. " (" .. tostring(e.controller) .. ")")
            table.insert(choices, { label = tostring(#choices + 1), value = i })
          end
        end
        table.insert(choices, { label = "SKIP", value = false })
        return ask(seat, it.name .. ": target " .. (sp.ability and not sp.spellsToo and "ability" or "spell"),
          "Choose the target now, as it goes on the stack.\n" .. table.concat(lines, "\n"), choices, function(i)
            if not i then
              return nextSpec()
            end
            local e = cands[i]
            table.insert(it.preTargets, { kind = "spell", guid = e.guid, name = e.name, owner = e.controller })
            one()
          end)
      end
      if sp.kind == "gycard" then
        -- "Target creature card from your graveyard": pick it from a list (a few at a time).
        local seats = {}
        for _, c in ipairs(players()) do
          if sp.whose == "any" or (sp.whose == "you" and c == seat) or (sp.whose == "opp" and TableSetup.isOpponent(c, seat)) then
            table.insert(seats, c)
          end
        end
        local list = {}
        for _, c in ipairs(seats) do
          for _, e in ipairs(graveyardCards(c)) do
            local tl = e.typeLine:lower()
            local okT = next(sp.types or {}) == nil
            for ty in pairs(sp.types or {}) do
              okT = okT or ty == "permanent" and not (tl:find("instant", 1, true) or tl:find("sorcery", 1, true)) or tl:find(ty, 1, true) ~= nil
            end
            for ty in pairs(sp.nots or {}) do
              if tl:find(ty, 1, true) then
                okT = false
              end
            end
            if okT and not taken[e.guid] then
              table.insert(list, { guid = e.guid, name = e.name, owner = c })
            end
          end
        end
        if #list == 0 then
          printToAll("MTG > " .. it.name .. ": no " .. tostring(sp.phrase) .. " to target in " .. (sp.whose == "you" and "your graveyard" or "a graveyard") .. ".", INFO)
          return nextSpec()
        end
        local page = 0
        local function show()
          local per = MAX_CHOICES - 2
          local lines, choices = {}, {}
          for i = page * per + 1, math.min(#list, page * per + per) do
            local e = list[i]
            table.insert(lines, (#choices + 1) .. ") " .. e.name .. " (" .. e.owner .. "'s graveyard)")
            table.insert(choices, { label = tostring(#choices + 1), value = i })
          end
          if #list > (page + 1) * per then
            table.insert(choices, { label = "MORE", value = "more" })
          elseif page > 0 then
            table.insert(choices, { label = "BACK TO START", value = "first" })
          end
          table.insert(choices, { label = "SKIP", value = false })
          ask(seat, it.name .. ": target " .. tostring(sp.phrase), "Choose the target now, as it goes on the stack.\n"
            .. table.concat(lines, "\n"), choices, function(v)
              if v == "more" then
                page = page + 1
                return show()
              elseif v == "first" then
                page = 0
                return show()
              elseif not v then
                return nextSpec()
              end
              local e = list[v]
              taken[e.guid] = true
              table.insert(it.preTargets, { kind = "gycard", guid = e.guid, name = e.name, owner = e.owner })
              one()
            end)
        end
        return show()
      end
      local choices = {}
      local pro = GameState.data.playerPro or {}
      if not sp.pwOnly or sp.kind ~= "any" then
        for _, c in ipairs(players()) do
          local usedAlready = false
          for _, e in ipairs(it.preTargets) do
            usedAlready = usedAlready or (e.kind == "player" and e.seat == c)
          end
          if not usedAlready and not (pro[c] and c ~= seat) and not (sp.kind == "opponent" and not TableSetup.isOpponent(c, seat)) then
            table.insert(choices, { label = string.upper(c), value = c })
          end
        end
      end
      if sp.kind == "any" then
        table.insert(choices, { label = sp.pwOnly and "PLANESWALKER" or "CREATURE / PW", value = "card" })
      end
      table.insert(choices, { label = (sp.upTo or k > 1) and "DONE" or "SKIP", value = false })
      ask(seat, it.name .. ": target " .. (sp.kind == "opponent" and "opponent" or (sp.kind == "any" and "(any target)" or "player")),
        "Choose the target now, as it goes on the stack.\n" .. tostring(text), choices, function(v)
          if v == false or v == nil then
            return nextSpec()
          end
          if v == "card" then
            return pickCard(sp, k, one)
          end
          table.insert(it.preTargets, { kind = "player", seat = v })
          one()
        end)
    end
    one()
  end
  nextSpec()
end

-- Just before it resolves: are its targets still legal? false = it fizzles (nothing happens).
-- Otherwise the resolving code's target prompts are answered from them (Effects.replayAnswer).
function Effects.checkTargets(it)
  Effects.replay = nil
  if it == nil or not it.targetsChosen then
    return true
  end
  highlightTargets(it, false)
  local legal = {}
  local src = it.source or it.guid
  for _, e in ipairs(it.preTargets or {}) do
    local ok, why = true, nil
    if e.kind == "player" then
      local p = GameState.player(e.seat)
      local pro = GameState.data.playerPro or {}
      ok = p ~= nil and not p.eliminated and not (pro[e.seat] and e.seat ~= it.controller)
      why = "out of the game or protected"
    elseif e.kind == "spell" then
      ok = Stack.has(e.guid)
      why = "it isn't on the stack any more"
    elseif e.kind == "gycard" then
      ok = false
      for _, g in ipairs(graveyardCards(e.owner)) do
        ok = ok or g.guid == e.guid
      end
      why = "it isn't in that graveyard any more"
    else
      local obj = getObjectFromGUID(e.guid)
      local owner = obj and not obj.isDestroyed() and fieldSeat(obj) or nil
      if owner == nil or (zoneChanges[e.guid] or 0) ~= (e.zc or 0) then
        ok, why = false, "it left the battlefield"
      elseif not targetFits(e.spec or { kind = "any" }, obj, owner, it.controller, src, nil) then
        ok, why = false, "it can't be targeted by this any more"
      end
    end
    if ok then
      table.insert(legal, { kind = e.kind, seat = e.seat, guid = e.guid, name = e.name })
    else
      printToAll("MTG > " .. it.name .. ": " .. tostring(e.name or e.seat) .. " is no longer a legal target (" .. why .. ").", { 1, 0.6, 0.2 })
    end
  end
  if #(it.preTargets or {}) > 0 and #legal == 0 then
    return false
  end
  Effects.replay = { seat = it.controller, entries = legal }
  Wait.time(function()
    if not Effects.busy() then
      Effects.replay = nil
    end
  end, 0.5)
  return true
end

-- A target prompt from the resolving code, answered from the targets chosen earlier.
-- Returns true, value when it answers; nil to show the prompt as usual.
local REPLAY_LABELS = { TARGET = true, DAMAGE = true, DESTROY = true, EXILE = true, RETURN = true, COUNTER = true,
  TAP = true, UNTAP = true, GOAD = true, ["CHAOS WARP"] = true, BLINK = true, COPY = true }
function Effects.replayAnswer(seat, title, text, choices, pick)
  local r = Effects.replay
  if r == nil or seat ~= r.seat then
    return nil
  end
  local lowT = (tostring(title) .. " " .. tostring(text)):lower()
  local skip
  for _, c in ipairs(choices or {}) do
    if c.value == false then
      skip = { false }
    end
  end
  if pick and pick.filter then
    if pick.choosing or pick.noProtect or not (lowT:find("target", 1, true) or REPLAY_LABELS[tostring(pick.label)]) then
      return nil
    end
    for _, e in ipairs(r.entries) do
      if e.kind == "card" and not e.used then
        local obj = getObjectFromGUID(e.guid)
        local owner = obj and not obj.isDestroyed() and fieldSeat(obj) or nil
        if owner then
          local okf, fits = pcall(pick.filter, obj, owner)
          if okf and fits then
            e.used = true
            return true, obj
          end
        end
      end
    end
    if skip then
      return true, false
    end
    return nil
  end
  if lowT:find(": choose a player", 1, true) or lowT:find(": choose a target", 1, true) then
    for _, e in ipairs(r.entries) do
      if not e.used then
        if e.kind == "player" then
          for _, c in ipairs(choices or {}) do
            if c.value == e.seat then
              e.used = true
              return true, e.seat
            end
          end
        elseif e.kind == "card" then
          for _, c in ipairs(choices or {}) do
            if c.value == "other" then
              return true, "other"
            end
          end
        end
      end
    end
    if skip then
      return true, false
    end
  end
  return nil
end

---------------------------------------------------------------------------
-- Ward (CR 702.21): "Whenever this permanent becomes the target of a spell or ability an opponent
-- controls, counter that spell or ability unless that player pays [cost]." Checked as the targets are
-- chosen (Effects.chooseTargets): the ward trigger goes on the stack on top of the spell or ability.
---------------------------------------------------------------------------

-- The ward cost on a permanent ("{2}", "Pay 3 life.", "Discard a card."), or nil if it has no ward.
function Effects.wardCost(obj)
  if obj == nil or not hasKeyword(obj, "ward") then
    return nil
  end
  local d = CardData.get(obj)
  for line in (tostring(d.oracle or "") .. "\n"):gmatch("([^\n]*)\n") do
    local plain = line
    if Triggers and Triggers.stripReminder then
      plain = Triggers.stripReminder(line)
    end
    local c = plain:match("^[Ww]ard%s*—%s*(.+)$") or plain:match("^[Ww]ard%s*%-%s*(.+)$") or plain:match("^[Ww]ard%s+(.+)$")
    if c then
      return (c:gsub("%s+$", ""))
    end
  end
  -- Ward given by something else ("Creatures you control have ward {1}").
  if Statics and Statics.grants then
    local okg, g = pcall(Statics.grants, obj)
    for _, k in ipairs(okg and g and g.kws or {}) do
      local c = tostring(k):match("^ward%s+(.+)$")
      if c then
        return c:upper()
      end
    end
  end
  return "its ward cost (see the card)"
end

local function wardTriggers(it)
  for _, e in ipairs(it.preTargets or {}) do
    if e.kind == "card" then
      local obj = getObjectFromGUID(e.guid)
      local owner = obj and fieldSeat(obj)
      if owner and TableSetup.isOpponent(owner, it.controller) then
        local cost = Effects.wardCost(obj)
        if cost then
          local text = "Ward: counter " .. it.name .. " (" .. it.controller .. ") unless " .. it.controller .. " pays " .. cost .. "."
          printToAll("MTG > " .. obj.getName() .. " has ward: " .. text, { 1, 0.75, 0.3 })
          Stack.pushAbility(owner, obj.getName(), text, nil, { trigger = true, source = obj.getGUID(),
            ward = { target = it.guid, cost = cost, payer = it.controller, what = it.name } })
        end
      end
    end
  end
end
Effects.wardTriggers = wardTriggers

function Effects.resolveWard(it)
  local w = it.ward
  if not (Stack and Stack.has and Stack.has(w.target)) then
    printToAll("MTG > Ward (" .. it.name .. "): " .. tostring(w.what) .. " isn't on the stack any more.", INFO)
    return
  end
  local cost = tostring(w.cost)
  local life = tonumber(cost:lower():match("pay (%d+) life"))
  ask(w.payer, "Ward: pay " .. cost .. "?", tostring(w.what) .. " targeted " .. it.name .. ", which has ward. Pay "
    .. cost .. " (do it yourself" .. (life and "; the table takes the life" or ", e.g. with your mana chips") .. "), or it's countered.",
    { { label = "PAY", value = true }, { label = "DON'T PAY", value = false } }, function(pays)
      if pays then
        if life then
          Trackers.changeLife(w.payer, -life, "ward (" .. it.name .. ")")
        end
        printToAll("MTG > " .. w.payer .. " pays " .. cost .. " for ward: " .. tostring(w.what) .. " goes on.", GOOD)
      elseif Stack.counterGuid then
        Stack.counterGuid(w.target, "ward (" .. it.name .. ")")
      end
    end)
end

---------------------------------------------------------------------------
-- The monarch (CR 724) and the initiative (CR 725). One player at a time holds each.
--   Monarch: draws a card at the beginning of their end step. A creature dealing combat damage to the
--   monarch makes its controller the monarch.
--   Initiative: taking it, and the beginning of your upkeep while you have it, venture into Undercity.
--   Combat damage to the holder passes it to the creature's controller.
--   If the holder leaves the game, the active player takes it (the next player if that's them).
---------------------------------------------------------------------------

local function badgeRefresh()
  if Trackers and Trackers.render then
    for _, c in ipairs(TableSetup.activeSeats()) do
      pcall(Trackers.render, c)
    end
  end
end

function Effects.monarch()
  return GameState.data and GameState.data.monarch or nil
end

function Effects.initiative()
  return GameState.data and GameState.data.initiative or nil
end

function Effects.setMonarch(seat, why)
  if seat == nil or GameState.data.monarch == seat then
    if seat then
      printToAll("MTG > " .. seat .. " is still the monarch.", INFO)
    end
    return
  end
  GameState.data.monarch = seat
  broadcastToAll(seat .. " becomes the monarch" .. (why and (" (" .. why .. ")") or "") .. ". They draw a card at the beginning of their end step.", { 1, 0.85, 0.3 })
  badgeRefresh()
end

-- Undercity (the initiative's dungeon): room -> { text, next rooms }.
local UNDERCITY = {
  ["Secret Entrance"] = { "Search your library for a basic land card, reveal it, put it into your hand, then shuffle.", { "Forge", "Lost Well" } },
  ["Forge"] = { "Put two +1/+1 counters on target creature.", { "Trap!", "Arena" } },
  ["Lost Well"] = { "Scry 2.", { "Arena", "Stash" } },
  ["Trap!"] = { "Target player loses 5 life.", { "Archives" } },
  ["Arena"] = { "Goad target creature.", { "Archives", "Catacombs" } },
  ["Stash"] = { "Create a Treasure token.", { "Catacombs" } },
  ["Archives"] = { "Draw a card.", { "Throne of the Dead Three" } },
  ["Catacombs"] = { "Create a 4/1 black Skeleton creature token with menace.", { "Throne of the Dead Three" } },
  ["Throne of the Dead Three"] = { "Reveal the top ten cards of your library. Put a creature card from among them onto the battlefield with three +1/+1 counters on it. It gains hexproof until your next turn. Then shuffle.", {} },
}

local function enterRoom(seat, room)
  GameState.data.undercity = GameState.data.undercity or {}
  GameState.data.undercity[seat] = room
  local r = UNDERCITY[room]
  printToAll("MTG > " .. seat .. " ventures into Undercity: " .. room .. ".", { 0.55, 0.9, 0.6 })
  if room == "Throne of the Dead Three" then
    printToAll("MTG > Throne of the Dead Three: " .. r[1] .. " (by hand). Undercity is complete; the next venture starts over.", { 1, 0.85, 0.3 })
    GameState.data.undercity[seat] = "done"
    return
  end
  -- The room's ability is a triggered ability: on the stack, targets and all.
  Stack.pushAbility(seat, "Undercity: " .. room, r[1], nil, { trigger = true, room = room })
end

function Effects.venture(seat)
  GameState.data.undercity = GameState.data.undercity or {}
  local at = GameState.data.undercity[seat]
  if at == nil or at == "done" then
    return enterRoom(seat, "Secret Entrance")
  end
  local nexts = (UNDERCITY[at] or { nil, {} })[2]
  if #nexts == 0 then
    return enterRoom(seat, "Secret Entrance")
  elseif #nexts == 1 then
    return enterRoom(seat, nexts[1])
  end
  local choices = {}
  for _, n in ipairs(nexts) do
    table.insert(choices, { label = string.upper(n), value = n })
  end
  local lines = {}
  for _, n in ipairs(nexts) do
    table.insert(lines, n .. ": " .. UNDERCITY[n][1])
  end
  ask(seat, "Venture into Undercity", "You're in " .. at .. ". Which room next?\n" .. table.concat(lines, "\n"), choices, function(n)
    enterRoom(seat, n or nexts[1])
  end)
end

function Effects.setInitiative(seat, why)
  if seat == nil then
    return
  end
  GameState.data.initiative = seat
  broadcastToAll(seat .. " takes the initiative" .. (why and (" (" .. why .. ")") or "") .. " and ventures into Undercity.", { 0.4, 0.9, 1 })
  badgeRefresh()
  Effects.venture(seat)
end

-- A player left the game (leave.lua): the monarch / initiative goes to the active player (or the next one).
function Effects.holderLeft(color)
  local t = GameState.data.turn or {}
  local function heir()
    local a = t.activeSeat
    if a and a ~= color and not (Leave and Leave.isOut(a)) then
      return a
    end
    local seats = TableSetup.activeSeats()
    local idx = 1
    for i, c in ipairs(seats) do
      if c == color then
        idx = i
      end
    end
    for k = 1, #seats do
      local c = seats[(idx - 1 + k) % #seats + 1]
      if c ~= color and not (Leave and Leave.isOut(c)) then
        return c
      end
    end
    return nil
  end
  if GameState.data.monarch == color then
    GameState.data.monarch = nil
    local h = heir()
    if h then
      Effects.setMonarch(h, color .. " left the game")
    end
  end
  if GameState.data.initiative == color then
    GameState.data.initiative = nil
    local h = heir()
    if h then
      Effects.setInitiative(h, color .. " left the game")
    end
  end
end

-- Combat damage to the holder passes the monarch / initiative on (triggers.lua calls this with each hit).
function Effects.combatDamageToPlayers(list)
  for _, h in ipairs(list or {}) do
    if (tonumber(h.amount) or 0) > 0 and h.seat and h.controller and h.controller ~= h.seat then
      if GameState.data.monarch == h.seat then
        Effects.setMonarch(h.controller, "combat damage to " .. h.seat)
      end
      if GameState.data.initiative == h.seat then
        Effects.setInitiative(h.controller, "combat damage to " .. h.seat)
      end
    end
  end
end

Events.on("stepStarted", function(d)
  if d == nil or not GameState.data.started then
    return
  end
  if d.step == "end" and GameState.data.monarch and GameState.data.monarch == d.seat then
    local m = GameState.data.monarch
    Stack.pushAbility(m, "The Monarch", "At the beginning of your end step, draw a card.", nil, { trigger = true })
  end
  if d.step == "upkeep" and GameState.data.initiative and GameState.data.initiative == d.seat then
    printToAll("MTG > " .. d.seat .. " has the initiative: they venture into Undercity.", { 0.4, 0.9, 1 })
    Effects.venture(d.seat)
  end
end)

---------------------------------------------------------------------------
-- The legend rule (CR 704.5j): two or more legendary permanents with the same name controlled by one
-- player: they choose one, the rest go to their owners' graveyards.
---------------------------------------------------------------------------

local function legendRuleOff()
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and fieldSeat(obj) then
      local o = tostring(CardData.get(obj).oracle or ""):lower()
      if o:find("the \"legend rule\" doesn't apply", 1, true) or o:find("legend rule doesn't apply", 1, true) then
        return true
      end
    end
  end
  return false
end

function Effects.legendCheck(card, seat)
  if card == nil or card.isDestroyed() or seat == nil or Faces.unknown(card) then
    return
  end
  local d = CardData.get(card)
  local tl = tostring(d.typeLine or "")
  if not tl:find("Legendary", 1, true) or tl:find("Instant", 1, true) or tl:find("Sorcery", 1, true) then
    return
  end
  local name = card.getName()
  local same = {}
  for _, obj in ipairs(getObjectsWithTag("MTGCard")) do
    if obj.type == "Card" and not obj.isDestroyed() and obj.getName() == name and fieldSeat(obj) == seat
        and not Faces.unknown(obj) then
      table.insert(same, obj)
    end
  end
  if #same < 2 or legendRuleOff() then
    return
  end
  local keepAsk = function(keep)
    for _, obj in ipairs(same) do
      if obj ~= keep and not obj.isDestroyed() then
        printToAll("MTG > Legend rule: " .. seat .. " keeps one " .. name .. "; the other goes to the graveyard.", { 1, 0.6, 0.2 })
        Combat.removeCard(obj, "graveyard")
      end
    end
  end
  local picked = {}
  for _, o in ipairs(same) do
    picked[o.getGUID()] = true
  end
  ask(seat, "Legend rule: " .. name, "You control " .. #same .. " legendary permanents named " .. name
    .. ". Click KEEP on the one that stays; the rest go to the graveyard.", { { label = "KEEP THE NEW ONE", value = false } },
    function(obj)
      keepAsk(obj or card)
    end, { filter = function(obj) return picked[obj.getGUID()] == true end, label = "KEEP", noProtect = true })
end

Events.on("cardMoved", function(d)
  if d.card == nil or d.to == nil or not GameState.data.started then
    return
  end
  if (d.to.region == "battlefield" or d.to.region == "lands") and not (d.from and (d.from.region == "battlefield" or d.from.region == "lands")) then
    local card, seat = d.card, d.to.seat
    Wait.time(function()
      pcall(Effects.legendCheck, card, seat)
    end, 1.2)
  end
end)

---------------------------------------------------------------------------
-- Before the first turn (after mulligans):
--   * Leylines and friends (CR 103.6): "If this card is in your opening hand, you may begin the game with it
--     on the battlefield." Each such card in an opening hand is offered.
--   * Color identity (CR 903.4-903.5): a warning for cards outside the commander's color identity.
---------------------------------------------------------------------------

local function handCardsOf(color)
  local out = {}
  pcall(function()
    for _, h in ipairs(Player[color].getHandObjects() or {}) do
      if h.type == "Card" and h.hasTag("MTGCard") then
        table.insert(out, h)
      end
    end
  end)
  return out
end

function Effects.openingHandStarts(color)
  local list = {}
  for _, h in ipairs(handCardsOf(color)) do
    local o = tostring(CardData.get(h).oracle or ""):lower()
    if o:find("in your opening hand, you may begin the game with it on the battlefield", 1, true) then
      table.insert(list, h)
    end
  end
  local function step(i)
    local card = list[i]
    if card == nil then
      return
    end
    ask(color, card.getName() .. ": opening hand", "It's in your opening hand: begin the game with it on the battlefield?",
      { { label = "YES, ONTO THE BATTLEFIELD", value = true }, { label = "NO, KEEP IT IN HAND", value = false } }, function(yes)
        if yes and not card.isDestroyed() then
          local s = TableSetup.seat(color)
          local tl = tostring(CardData.get(card).typeLine or "")
          card.setRotation({ 0, s.yaw, 0 })
          card.setPosition(TableSetup.slot(color, tl:find("Land", 1, true) and "lands" or "battlefield", 2))
          Wait.time(function()
            if not card.isDestroyed() then
              Zones.refresh(card)
            end
          end, 0.8)
          printToAll("MTG > " .. color .. " begins the game with " .. card.getName() .. " on the battlefield.", GOOD)
        end
        step(i + 1)
      end)
  end
  step(1)
end

local function identityOf(d)
  local out = {}
  for _, c in ipairs(type(d) == "table" and type(d.colorIdentity) == "table" and d.colorIdentity or {}) do
    out[tostring(c):upper()] = true
  end
  return out
end

function Effects.checkIdentity(color)
  local allowed, commanders = {}, {}
  for _, o in ipairs(getObjectsWithTag("MTGCard")) do
    if o.type == "Card" and not o.isDestroyed() then
      local okl, loc = pcall(function() return Zones.regionAt(o.getPosition()) end)
      if okl and loc and loc.seat == color and (loc.region == "command1" or loc.region == "command2") then
        local d = CardData.get(o)
        if d.isCommander or tostring(d.typeLine or ""):find("Legendary", 1, true) or tostring(d.oracle or ""):lower():find("can be your commander", 1, true) then
          table.insert(commanders, o.getName())
          for c in pairs(identityOf(d)) do
            allowed[c] = true
          end
        end
      end
    end
  end
  if #commanders == 0 then
    return
  end
  local bad = {}
  local function check(name, d)
    for c in pairs(identityOf(d)) do
      if not allowed[c] then
        table.insert(bad, name)
        return
      end
    end
  end
  local lib = Library and Library.find and Library.find(color)
  if lib and lib.type == "Deck" then
    for _, e in ipairs(lib.getObjects() or {}) do
      local okd, d = pcall(JSON.decode, e.gm_notes or "")
      if okd and type(d) == "table" then
        check(e.name or "?", d)
      end
    end
  end
  for _, h in ipairs(handCardsOf(color)) do
    check(h.getName(), CardData.get(h))
  end
  if #bad > 0 then
    local shown = {}
    for i = 1, math.min(#bad, 8) do
      shown[i] = bad[i]
    end
    printToAll("MTG > Heads up: " .. color .. "'s deck has " .. #bad .. " card" .. (#bad == 1 and "" or "s")
      .. " outside " .. table.concat(commanders, " + ") .. "'s color identity (CR 903.4): " .. table.concat(shown, ", ")
      .. (#bad > 8 and ", ..." or "") .. ". Fine for a house game; not legal Commander.", { 1, 0.75, 0.3 })
  end
end

Events.on("gameStarted", function(d)
  for _, c in ipairs(d and d.players or {}) do
    pcall(Effects.checkIdentity, c)
  end
  for _, c in ipairs(d and d.players or {}) do
    pcall(Effects.openingHandStarts, c)
  end
end)

---------------------------------------------------------------------------
-- Imprint (Chrome Mox and friends): "you may exile a nonartifact, nonland card from your hand". The player
-- picks the card from a list of the ones that fit; it goes to their exile and is remembered for the source
-- (GameState.data.imprint[source] = { guid, name, colors }), so "the exiled card's colors" works (mana.lua).
---------------------------------------------------------------------------

function Effects.imprint(it, what)
  local seat = it.controller
  local words = {}
  for w in tostring(what):gmatch("[%a%-]+") do
    words[w] = true
  end
  local list = {}
  pcall(function()
    for _, h in ipairs(Player[seat].getHandObjects() or {}) do
      if h.type == "Card" and h.hasTag("MTGCard") then
        local d = CardData.get(h)
        local tl = tostring(d.typeLine or ""):lower()
        local ok = true
        for w in pairs(words) do
          if w:sub(1, 3) == "non" and #w > 3 then
            ok = ok and not tl:find(w:sub(4), 1, true)
          elseif w ~= "a" and w ~= "an" and w ~= "and" and w ~= "or" and w ~= "card" then
            ok = ok and tl:find(w, 1, true) ~= nil
          end
        end
        if ok then
          table.insert(list, h)
        end
      end
    end
  end)
  if #list == 0 then
    printToAll("MTG > " .. it.name .. ": " .. seat .. " has no " .. what .. " card in hand to exile.", INFO)
    return
  end
  local page = 0
  local function show()
    local per = MAX_CHOICES - 2
    local lines, choices = {}, {}
    for i = page * per + 1, math.min(#list, page * per + per) do
      table.insert(lines, (#choices + 1) .. ") " .. list[i].getName())
      table.insert(choices, { label = tostring(#choices + 1), value = i })
    end
    if #list > (page + 1) * per then
      table.insert(choices, { label = "MORE", value = "more" })
    elseif page > 0 then
      table.insert(choices, { label = "BACK", value = "first" })
    end
    table.insert(choices, { label = "NONE", value = false })
    ask(seat, it.name .. ": exile a card from your hand?", "You may exile a " .. what .. " card from your hand.\n"
      .. table.concat(lines, "\n"), choices, function(v)
        if v == "more" then
          page = page + 1
          return show()
        elseif v == "first" then
          page = 0
          return show()
        elseif not v then
          printToAll("MTG > " .. it.name .. ": " .. seat .. " exiles nothing.", INFO)
          return
        end
        local card = list[v]
        if card == nil or card.isDestroyed() then
          return
        end
        local d = CardData.get(card)
        local cols = {}
        for _, c in ipairs(type(d.colors) == "table" and d.colors or {}) do
          table.insert(cols, tostring(c):upper())
        end
        GameState.data.imprint = GameState.data.imprint or {}
        GameState.data.imprint[it.source] = { guid = card.getGUID(), name = card.getName(), colors = cols }
        local s = TableSetup.seat(seat)
        card.setRotation({ 0, s.yaw, 0 })
        card.setPosition(TableSetup.slot(seat, "exile", 2))
        Wait.time(function()
          if not card.isDestroyed() then
            Zones.refresh(card)
          end
        end, 1)
        printToAll("MTG > " .. it.name .. ": " .. seat .. " exiles " .. card.getName()
          .. (#cols > 0 and (" (taps for " .. table.concat(cols, " or ") .. ")") or " (colorless: it makes no mana)") .. ".", GOOD)
      end)
  end
  show()
end

---------------------------------------------------------------------------
-- Pick a card from your own hand that fits (a list a few at a time, NONE allowed). cb(card or nil).
---------------------------------------------------------------------------

function Effects.pickFromHand(seat, title, text, fits, cb)
  local list = {}
  pcall(function()
    for _, h in ipairs(Player[seat].getHandObjects() or {}) do
      if h.type == "Card" and h.hasTag("MTGCard") and fits(h, CardData.get(h)) then
        table.insert(list, h)
      end
    end
  end)
  if #list == 0 then
    cb(nil, true)
    return
  end
  local page = 0
  local function show()
    local per = MAX_CHOICES - 2
    local lines, choices = {}, {}
    for i = page * per + 1, math.min(#list, page * per + per) do
      table.insert(lines, (#choices + 1) .. ") " .. list[i].getName())
      table.insert(choices, { label = tostring(#choices + 1), value = i })
    end
    if #list > (page + 1) * per then
      table.insert(choices, { label = "MORE", value = "more" })
    elseif page > 0 then
      table.insert(choices, { label = "BACK", value = "first" })
    end
    table.insert(choices, { label = "NONE", value = false })
    ask(seat, title, text .. "\n" .. table.concat(lines, "\n"), choices, function(v)
      if v == "more" then
        page = page + 1
        return show()
      elseif v == "first" then
        page = 0
        return show()
      end
      local card = v and list[v] or nil
      cb(card and not card.isDestroyed() and card or nil, false)
    end)
  end
  show()
end

-- "You may put an Angel, Demon, or Dragon creature card from your hand onto the battlefield tapped and attacking
-- that opponent" (Kalia of the Vast): it attacks whoever the source is attacking (combat.lua).
function Effects.handToAttack(it, kinds)
  local seat = it.controller
  local words = {}
  for w in tostring(kinds):gmatch("%a+") do
    if w ~= "or" and w ~= "and" and w ~= "creature" then
      table.insert(words, (w:gsub("s$", "")))
    end
  end
  local function fits(_, d)
    local tl = tostring(d.typeLine or ""):lower()
    if not tl:find("creature", 1, true) then
      return false
    end
    if #words == 0 then
      return true
    end
    for _, w in ipairs(words) do
      if tl:find(w, 1, true) then
        return true
      end
    end
    return tostring(d.oracle or ""):lower():find("changeling", 1, true) ~= nil
  end
  Effects.pickFromHand(seat, it.name .. ": put a creature onto the battlefield attacking?",
    "You may put a " .. kinds .. " card from your hand onto the battlefield tapped and attacking.", fits, function(card, none)
      if card == nil then
        printToAll("MTG > " .. it.name .. ": " .. seat .. (none and (" has no " .. kinds .. " card in hand.") or " puts nothing in."), INFO)
        return
      end
      local s = TableSetup.seat(seat)
      card.setRotation({ 0, s.yaw, 0 })   -- entering attacking taps it (combat.lua)
      card.setPosition(TableSetup.slot(seat, "battlefield", 2))
      Wait.time(function()
        if card.isDestroyed() then
          return
        end
        Zones.refresh(card)
        if Combat and Combat.enterAttacking then
          Combat.enterAttacking(card, seat, it.source)
        end
      end, 0.8)
      printToAll("MTG > " .. it.name .. ": " .. seat .. " puts " .. card.getName() .. " onto the battlefield tapped and attacking.", GOOD)
    end)
end
