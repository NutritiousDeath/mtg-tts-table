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
  -- Sentence by sentence: one with a condition ("Then if you control four
  -- or more lands, untap that land.") is left to the players; the plain
  -- sentences around it still happen.
  local kept, notes, firstWhy = {}, {}, nil
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
      if clean ~= "" then
        table.insert(notes, clean)
      end
    else
      table.insert(kept, sentence)
    end
    pos = stop and (stop + 2) or (#t + 1)
  end
  if #kept == 0 then
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
    table.insert(actions, { what = "search", who = "you", n = 1, query = q, where = where,
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
  if #actions == 0 then
    if firstWhy then
      return nil, "it has a condition (" .. firstWhy .. ")"
    end
    return nil, "nothing it can apply on its own"
  end
  return { optional = t:find("you may", 1, true) ~= nil, actions = actions, notes = notes }
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
  elseif a.what == "scry" then
    return who .. (a.surveil and (you and " surveil " or " surveils ") or (you and " scry " or " scries ")) .. a.n
  elseif a.what == "mill" then
    return who .. (you and " mill " or " mills ") .. a.n
  elseif a.what == "removeAll" then
    return a.verb .. " all " .. tostring(a.phrase) .. " (" .. tostring(a.count or 0) .. ")"
  elseif a.what == "removeTarget" then
    return a.verb .. " target " .. tostring(a.phrase)
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
            a.where == "hand" and "hand" or "battlefield", a.tapped)
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
  printToAll("MTG > " .. it.name .. " resolved: " .. table.concat(done, ", ") .. ".", GOOD)
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
        nextQuestion()
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
  nextQuestion()
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

-- it = the stack item { name, controller, text, that, auto }.
function Effects.resolve(it)
  if not enabled() or not it.auto or not GameState.data.started then
    return
  end
  local plan, why = Effects.parse(it.text, it.name)
  if plan == nil then
    printToAll("MTG > " .. it.name .. ": resolve it by hand (" .. tostring(why) .. ").", INFO)
    return
  end
  local seat = it.controller
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
  if q == nil or q.pick == nil or obj.is_face_down then
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
  nextQuestion()
end

local function returnToHand(obj)
  local seat = fieldSeat(obj)
  if seat == nil then
    return
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
  local found = false
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
    if obj.type == "Card" and not obj.isDestroyed() and not obj.is_face_down and obj.held_by_color == nil then
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
        if removeOne(obj, a.verb) then
          printToAll("MTG > " .. sourceName .. ": " .. (a.verb == "exile" and "exiled " or "destroyed ") .. name .. ".", GOOD)
        end
      else
        printToAll("MTG > " .. sourceName .. ": no target chosen.", INFO)
      end
    end, { filter = function(obj, owner) return fits(obj, owner, a, seat, sourceGuid) end, label = label })
end
