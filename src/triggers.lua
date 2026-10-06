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

local function cardData(obj)
  local notes = obj.getGMNotes() or ""
  if notes == "" then
    return nil
  end
  local ok, d = pcall(function() return JSON.decode(notes) end)
  if ok and type(d) == "table" then
    return d
  end
  return nil
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
  for _, w in ipairs({ "creature", "permanent", "artifact", "enchantment", "land", "planeswalker", "card", "token", "vehicle" }) do
    t = t:gsub("this " .. w, "~")
  end
  t = t:gsub("enters the battlefield", "enters")
  return t
end

-- Card type words used in trigger subjects.
local SUBJECTS = { "creature", "land", "artifact", "enchantment", "permanent", "planeswalker" }

-- Parse one paragraph of rules text into a trigger, or nil.
local function parseTrigger(p)
  -- Steps.
  local stepWho = {
    { "at the beginning of your upkeep", "upkeep", "you" },
    { "at the beginning of each opponent's upkeep", "upkeep", "opp" },
    { "at the beginning of each player's upkeep", "upkeep", "each" },
    { "at the beginning of each upkeep", "upkeep", "each" },
    { "at the beginning of your draw step", "draw", "you" },
    { "at the beginning of each player's draw step", "draw", "each" },
    { "at the beginning of each draw step", "draw", "each" },
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
    local w = p:find("whenever ", at, true)
    if not w then
      break
    end
    at = w + 9
    local window = p:sub(w + 9, w + 9 + 80)
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
      local clean = lead and not subj:find("~", 1, true) and not subj:find(",", 1, true)
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
        if #types > 0 then
          return { kind = kind, subject = types[1], subjects = types,
            another = lead == "another " or lead == "one or more other ",
            nontoken = subj:find("nontoken", 1, true) ~= nil,
            tokenOnly = subj:find(" token", 1, true) ~= nil and subj:find("nontoken", 1, true) == nil,
            mine = subj:find("you control", 1, true) ~= nil or underMine,
            theirs = subj:find("an opponent controls", 1, true) ~= nil or subj:find("your opponents control", 1, true) ~= nil
              or underTheirs }
        end
      end
    end
  end
  -- Dies (self).
  if plainFind(p, "when ~ dies") or plainFind(p, "whenever ~ dies") then
    return { kind = "dies", self = true }
  end
  -- Casting.
  local oppType = between(p, "whenever an opponent casts a", " spell")
  oppType = oppType and oppType:gsub("^n? ", "") or nil
  if oppType and #oppType < 30 then
    return { kind = "cast", who = "opp", spellType = oppType ~= "" and oppType or nil }
  end
  if plainFind(p, "whenever an opponent casts a spell") then
    return { kind = "cast", who = "opp" }
  end
  local castType = between(p, "whenever you cast a", " spell")
  castType = castType and castType:gsub("^n? ", "") or nil
  if castType and #castType < 30 and castType ~= "" then
    return { kind = "cast", who = "you", spellType = castType }
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
  if plainFind(p, "attacks alone") then
    if plainFind(p, "whenever a creature you control attacks alone") then
      add({ kind = "attacks", mine = true, alone = true })
    end
  elseif plainFind(p, "whenever a creature you control attacks") or plainFind(p, "whenever a nontoken creature you control attacks") then
    add({ kind = "attacks", mine = true })
  elseif plainFind(p, "whenever one or more creatures you control attack") or plainFind(p, "whenever you attack") then
    add({ kind = "attacks", mine = true, once = true })
  end
  if plainFind(p, "whenever a creature attacks you") or plainFind(p, "whenever one or more creatures attack you") then
    add({ kind = "attacks", targetsMe = true, once = plainFind(p, "one or more") })
  end
  if plainFind(p, "whenever ~ deals combat damage to a player") or plainFind(p, "whenever ~ deals combat damage to an opponent") then
    add({ kind = "combatDamage", self = true })
  elseif plainFind(p, "whenever a creature you control deals combat damage to a player")
      or plainFind(p, "whenever a creature you control deals combat damage to an opponent") then
    add({ kind = "combatDamage", mine = true })
  elseif plainFind(p, "whenever one or more creatures you control deal combat damage to a player") then
    add({ kind = "combatDamage", mine = true, once = true })
  end
  return out
end

-- A card's triggered abilities: { { trig, text } } (text = original wording).
local function abilitiesOf(obj)
  local d = cardData(obj)
  if d == nil or type(d.oracle) ~= "string" or d.oracle == "" then
    return {}
  end
  local key = obj.getGUID() .. "|" .. tostring(d.name)
  if cache[key] then
    return cache[key]
  end
  local list = {}
  for _, para in ipairs(lines(d.oracle)) do
    if para ~= "" then
      local norm = normalize(para, d.name)
      local trig = parseTrigger(norm)
      if trig then
        table.insert(list, { trig = trig, text = para })
      end
      for _, ct in ipairs(parseCombat(norm)) do
        table.insert(list, { trig = ct, text = para })
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
  }
  for _, kw in ipairs(type(d.keywords) == "table" and d.keywords or {}) do
    local k = tostring(kw):lower()
    if KEYWORD_TRIGGERS[k] then
      -- The keyword's own line in the rules text (e.g. "Annihilator 2").
      local text = tostring(kw)
      for _, para in ipairs(lines(d.oracle)) do
        if para:lower():sub(1, #k) == k then
          text = para
        end
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
  cache[key] = list
  return list
end

local function typesOf(obj)
  local d = cardData(obj)
  local t = {}
  for _, name in ipairs(d and d.types or {}) do
    t[name:lower()] = true
  end
  return t
end

local function matchesSubject(obj, trig)
  local list = trig.subjects or { trig.subject }
  local types = typesOf(obj)
  if trig.tokenOnly and not (obj.hasTag("Token") or types.token) then
    return false
  end
  for _, sub in ipairs(list) do
    if sub == nil or sub == "permanent" or types[sub] then
      return true
    end
  end
  return #list == 0
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
    if obj.type == "Card" and not obj.is_face_down and obj.held_by_color == nil then
      local loc = Zones.regionAt(obj.getPosition())
      if loc.seat and (loc.region == "battlefield" or loc.region == "lands") then
        table.insert(list, { obj = obj, controller = loc.seat })
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
  Stack.pushAbility(f.controller, f.obj.getName(), f.text, faceOf(f.obj), { trigger = true, that = f.that })
end

local function shortText(f)
  local t = tostring(f.text or "")
  if #t > 70 then
    t = t:sub(1, 68) .. "..."
  end
  return f.obj.getName() .. ": " .. t
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
          UI.setAttribute("trigBtn_" .. key, "tooltip", f.obj.getName() .. "\n" .. tostring(f.text or ""))
          UI.setAttribute("trigBtn_" .. key, "color", n and "#1B4A5A" or "#141B26")
        end
      end
      UI.setAttribute("trigOrder_" .. c, "height", tostring(118 + 40 * #o.list))
    end
  end
end

local processNext

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
    if #b.list >= 2 and #b.list <= MAX_ORDER and seated(b.seat) then
      -- Shown in resolve order: as found, the first found resolves last.
      local shown = {}
      for i = #b.list, 1, -1 do
        table.insert(shown, b.list[i])
      end
      ordering = { seat = b.seat, list = shown, picks = {}, count = 0 }
      renderOrder()
      broadcastToColor("You have " .. #b.list .. " triggers at once: click them in the order they should resolve"
        .. " (or KEEP THIS ORDER).", b.seat, { 0.35, 0.95, 1 })
      return
    end
    for _, f in ipairs(b.list) do
      push(f)
    end
  end
  ordering = nil
  renderOrder()
end

local function finishOrdering(resolveOrder)
  ordering = nil
  renderOrder()
  pushInResolveOrder(resolveOrder)
  processNext()
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
<Panel id="trigOrder_%s" visibility="%s" active="false" rectAlignment="MiddleCenter" offsetXY="0 60" width="600" height="200"
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

-- Found triggers go out one seat at a time, active player first.
local function pushAll(found, that)
  if #found == 0 then
    return
  end
  for _, f in ipairs(found) do
    f.that = f.that or that
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
      if t.kind == "step" and t.step == d.step then
        local mine = p.controller == d.seat
        if t.who == "each" or (t.who == "you" and mine) or (t.who == "opp" and not mine) then
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
  if card.isDestroyed() or card.is_face_down then
    return
  end
  -- A card drawn: library -> hand.
  if d.from.region == "library" and d.to.region == "hand" and d.to.seat then
    local found = {}
    for _, p in ipairs(permanents()) do
      for _, a in ipairs(abilitiesOf(p.obj)) do
        local t = a.trig
        if t.kind == "draw" then
          local mine = p.controller == d.to.seat
          if t.who == "each" or (t.who == "you" and mine) or (t.who == "opp" and not mine) then
            table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
          end
        end
      end
    end
    pushAll(found, d.to.seat)
    return
  end
  local entering = IN_PLAY[d.to.region] and not IN_PLAY[d.from.region]
  local dying = IN_PLAY[d.from.region] and d.to.region == "graveyard" and typesOf(card).creature
  if not entering and not dying then
    return
  end
  local kind = entering and "enters" or "dies"
  local cardController = entering and d.to.seat or d.from.seat
  local found = {}
  -- The card's own "when ~ enters / dies".
  for _, a in ipairs(abilitiesOf(card)) do
    if a.trig.kind == kind and (a.trig.self or a.trig.orSelf) then
      table.insert(found, { obj = card, controller = cardController, text = a.text })
    end
  end
  -- Other permanents watching for it.
  for _, p in ipairs(permanents()) do
    if p.obj ~= card then
      for _, a in ipairs(abilitiesOf(p.obj)) do
        local t = a.trig
        if t.kind == kind and not t.self and matchesSubject(card, t)
            and not (t.nontoken and isToken(card))
            and not (t.mine and cardController ~= p.controller)
            and not (t.theirs and cardController == p.controller) then
          table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
        end
      end
    end
  end
  -- "Whenever a creature dies" on a creature that died with it isn't
  -- checked (it's already in the graveyard): add those by hand.
  pushAll(found, cardController)
end)

-- A spell was cast (put on the stack).
local function spellMatches(card, spellType)
  if spellType == nil then
    return true
  end
  local t = typesOf(card)
  if spellType == "noncreature" then
    return not t.creature
  end
  if spellType == "instant or sorcery" then
    return t.instant or t.sorcery
  end
  local first = spellType:match("^(%a+)")
  return first ~= nil and t[first] == true
end

Events.on("spellCast", function(d)
  if not enabled() or not GameState.data.started or d.card == nil then
    return
  end
  local found = {}
  for _, p in ipairs(permanents()) do
    for _, a in ipairs(abilitiesOf(p.obj)) do
      local t = a.trig
      if t.kind == "cast" then
        local mine = p.controller == d.controller
        if ((t.who == "you" and mine) or (t.who == "opp" and not mine)) and spellMatches(d.card, t.spellType) then
          table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
        end
      end
    end
  end
  pushAll(found, d.controller)
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
  end
  for _, p in ipairs(permanents()) do
    for _, a in ipairs(abilitiesOf(p.obj)) do
      local t = a.trig
      if t.kind == "attacks" and t.mine then
        local mineCount = 0
        for _, at in ipairs(list) do
          if at.controller == p.controller then
            mineCount = mineCount + 1
          end
        end
        if t.alone then
          if #list == 1 and mineCount == 1 then
            table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
          end
        elseif t.once then
          if mineCount > 0 then
            table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
          end
        else
          for _ = 1, mineCount do
            table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
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
    local att = b.attacker
    if att and not att.isDestroyed() and not blockedDone[att.getGUID()] then
      blockedDone[att.getGUID()] = true
      for _, a in ipairs(abilitiesOf(att)) do
        if a.trig.kind == "blocked" and a.trig.self then
          table.insert(found, { obj = att, controller = b.attackerController, text = a.text })
        end
      end
    end
  end
  pushAll(found)
end

-- Creatures dealt combat damage to players: list of { obj, controller, seat }.
function Triggers.onCombatDamage(list)
  if not enabled() or not GameState.data.started then
    return
  end
  local found = {}
  for _, h in ipairs(list) do
    if not h.obj.isDestroyed() then
      for _, a in ipairs(abilitiesOf(h.obj)) do
        if a.trig.kind == "combatDamage" and a.trig.self then
          table.insert(found, { obj = h.obj, controller = h.controller, text = a.text })
        end
      end
    end
  end
  for _, p in ipairs(permanents()) do
    for _, a in ipairs(abilitiesOf(p.obj)) do
      local t = a.trig
      if t.kind == "combatDamage" and t.mine then
        local n = 0
        for _, h in ipairs(list) do
          if h.controller == p.controller then
            n = n + 1
          end
        end
        for _ = 1, (t.once and math.min(n, 1) or n) do
          table.insert(found, { obj = p.obj, controller = p.controller, text = a.text })
        end
      end
    end
  end
  pushAll(found, list[1] and list[1].seat)
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
      .. ": " .. a.text)
  end
  return obj.getName() .. ":\n" .. table.concat(lines, "\n")
end

Triggers.parse = parseTrigger
Triggers.parseCombat = parseCombat
Triggers.normalize = normalize
