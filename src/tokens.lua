--[[
  tokens.lua
  Token search: the TOKENS tile on your side of the table (below UNTAP)
  opens a panel only you see. Tokens that were in your imported decklist
  are kept out of the library and listed here first (MY DECK button).
  Type a token ("treasure", "1/1 soldier", "zombie", "food"...) and SEARCH:
  the relay looks it up on Scryfall (GET /tokens?q=...) and shows up to 24
  matching tokens with their pictures. Click one to put it onto your
  battlefield; the - / + buttons set how many copies each click makes.
  Tokens are real cards (tagged "Token") so counters, tapping and the
  battlefield tracking all work on them.
--]]

Tokens = {}

local MAX_RESULTS = 24
local COLS = 8
local INFO = { 0.75, 0.8, 0.9 }
local WARN = { 1, 0.6, 0.2 }

local text = {}      -- [color] = what's typed in the search box
local results = {}   -- [color] = { { name, typeLine, image, tpl } }
local copies = {}    -- [color] = copies per click
local open = {}

function Tokens.xml()
  local parts = {}
  for _, c in ipairs(TableSetup.activeSeats()) do
    local slots = {}
    for i = 1, MAX_RESULTS do
      local id = c .. "_" .. i
      table.insert(slots, ([[
<Panel id="tokSlot_%s" active="false" color="#1B2333">
  <Text id="tokName_%s" fontSize="11" color="#E6F1FF">-</Text>
  <Image id="tokImg_%s" preserveAspect="true" raycastTarget="false" />
  <Button id="tokBtn_%s" onClick="ui_tokenPick(%s)" color="#00000000" />
</Panel>]]):format(id, id, id, id, id))
    end
    table.insert(parts, ([[
<Panel id="tokens_%s" visibility="%s" active="false" rectAlignment="UpperLeft" offsetXY="20 -220" width="1260" height="156"
       color="#0B0F17F2" outline="#5AF0FF" outlineSize="2 2" allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="12 12 12 12" spacing="8" childForceExpandHeight="false">
    <HorizontalLayout preferredHeight="26" childForceExpandWidth="false">
      <Text fontSize="15" fontStyle="Bold" color="#5AF0FF" alignment="MiddleLeft" flexibleWidth="1">TOKENS</Text>
      <Button onClick="ui_tokensClose(%s)" preferredWidth="30" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold" tooltip="Close">X</Button>
    </HorizontalLayout>
    <HorizontalLayout spacing="8" preferredHeight="38" childForceExpandWidth="false">
      <InputField onValueChanged="ui_tokenText" onEndEdit="ui_tokenSubmit" fontSize="16" flexibleWidth="1"
                  placeholder="treasure, 1/1 soldier, zombie, food..." />
      <Button onClick="ui_tokenSearch" preferredWidth="110" color="#00B3A4" textColor="#06130B" fontStyle="Bold">SEARCH</Button>
      <Button onClick="ui_tokenDeck(%s)" preferredWidth="100" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold"
              tooltip="Tokens from your imported decklist">MY DECK</Button>
      <Button onClick="ui_tokenCopies(%s_minus)" preferredWidth="34" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold">-</Button>
      <Text id="tokCopies_%s" preferredWidth="70" fontSize="14" fontStyle="Bold" color="#E6F1FF">x1</Text>
      <Button onClick="ui_tokenCopies(%s_plus)" preferredWidth="34" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold">+</Button>
    </HorizontalLayout>
    <Text id="tokStatus_%s" fontSize="12" color="#8B98A9" alignment="MiddleLeft" preferredHeight="18">Search for a token, then click it to put it onto your battlefield.</Text>
    <GridLayout id="tokGrid_%s" active="false" cellSize="146 204" spacing="8 8" constraint="FixedColumnCount" constraintCount="8"
                childAlignment="UpperLeft" preferredHeight="300">]] .. table.concat(slots) .. [[</GridLayout>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, c, c, c, c, c, c))
  end
  return table.concat(parts)
end

local function status(color, msg)
  UI.setValue("tokStatus_" .. color, msg)
end

local function render(color)
  local list = results[color] or {}
  local rows = math.ceil(#list / COLS)
  UI.setAttribute("tokGrid_" .. color, "active", #list > 0 and "true" or "false")
  UI.setAttribute("tokGrid_" .. color, "preferredHeight", rows * 212)
  UI.setAttribute("tokens_" .. color, "height", 156 + rows * 212)
  UI.setValue("tokCopies_" .. color, "x" .. (copies[color] or 1))
  for i = 1, MAX_RESULTS do
    local id = color .. "_" .. i
    local r = list[i]
    if r then
      UI.setAttribute("tokSlot_" .. id, "active", "true")
      UI.setValue("tokName_" .. id, r.name)
      -- The preview uses Scryfall's "small" size (146 x 204), about the same
      -- size as the box, so TTS doesn't have to shrink it (shrinking big
      -- images is what made them fuzzy). The token itself still spawns with
      -- the large image.
      UI.setAttribute("tokImg_" .. id, "image", (r.image:gsub("/large/", "/small/", 1)))
      UI.setAttribute("tokBtn_" .. id, "tooltip", r.name .. "\n" .. r.typeLine .. "\nClick: put onto your battlefield")
    else
      UI.setAttribute("tokSlot_" .. id, "active", "false")
    end
  end
end

local function urlEncode(s)
  return (tostring(s):gsub("[^%w%-_%.~ ]", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end):gsub(" ", "%%20"))
end

function Tokens.search(color, query)
  query = tostring(query or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if query == "" then
    status(color, "Type a token name first.")
    return
  end
  status(color, "Searching for \"" .. query .. "\"...")
  WebRequest.get("https://" .. Importer.RELAY_HOST .. "/tokens?q=" .. urlEncode(query), function(req)
    if req.is_error or (req.response_code and req.response_code >= 400) then
      status(color, "Search failed. Has the relay been updated with token search?")
      return
    end
    local body = req.text or ""
    local list = {}
    if body ~= "NONE" then
      for _, line in ipairs(Importer.splitPlain(body, "\n")) do
        local f = Importer.splitPlain(line, "\t")
        if f[1] == "TOKEN" and f[6] then
          table.insert(list, { name = f[3], typeLine = f[4], image = f[5], tpl = f[6] })
        end
      end
    end
    results[color] = list
    if #list == 0 then
      status(color, "No tokens found for \"" .. query .. "\". Try a simpler word, like \"zombie\".")
    else
      status(color, #list .. " found. Click one to put it onto your battlefield.")
    end
    render(color)
  end)
end

-- Put n copies of a token onto the seat's battlefield, face up, in a row.
function Tokens.spawn(color, r, n, opts)
  local s = TableSetup.seat(color)
  local base = TableSetup.slot(color, "battlefield", 2)
  for k = 1, n do
    local id1, id2 = Importer.nextDeckId(), Importer.nextDeckId()
    local json = Importer.fillTemplate(r.tpl, id1, id2)
    json = Importer.replacePlain(json, '"Tags":["MTGCard"]', '"Tags":["MTGCard","Token"]')
    -- Spread copies sideways so they don't stack.
    local off = (k - (n + 1) / 2) * 2.6
    local pos = { x = base.x + s.right.x * off, y = base.y + 0.5, z = base.z + s.right.z * off }
    spawnObjectJSON({
      json = json,
      position = pos,
      rotation = { 0, opts and opts.tapped and (s.yaw + 90) % 360 or s.yaw, 0 },
      callback_function = function(obj)
        obj.setName(r.name)
        Zones.refresh(obj)
        -- "create a 1/1 Goblin token with haste": no summoning sickness this turn.
        if opts and opts.haste and Counters and Counters.addTempKeyword then
          Wait.time(function()
            if not obj.isDestroyed() then
              Counters.addTempKeyword(obj, "haste")
            end
          end, 0.8)
        end
        -- Tapped and attacking: joins the attack (no attack triggers).
        if opts and opts.attacking and Combat and Combat.enterAttacking then
          Wait.time(function()
            if not obj.isDestroyed() then
              Combat.enterAttacking(obj, color, opts.from)
            end
          end, 0.6)
        end
      end,
    })
  end
  printToAll("MTG > " .. color .. " creates " .. n .. " " .. r.name .. " token" .. (n == 1 and "" or "s"), INFO)
end

---------------------------------------------------------------------------
-- Creating a token from rules text (effects.lua): "create a 2/2 black Zombie
-- creature token". spec = { pt = "2/2" or nil, words = { "zombie" },
-- colors = { B = true } }. The seat's decklist tokens are tried first, then
-- a relay search; the best match (power/toughness, type words, colors) is
-- spawned n times.
---------------------------------------------------------------------------

-- Colors in a token template's card data ("colors":["B","G"], escaped).
local function tplColors(tpl)
  local set = {}
  local a = tostring(tpl):find('colors\\":[', 1, true)
  if a then
    local b = tpl:find("]", a, true) or (a + 40)
    local seg = tpl:sub(a, b)
    for _, c in ipairs({ "W", "U", "B", "R", "G" }) do
      if seg:find('\\"' .. c .. '\\"', 1, true) then
        set[c] = true
      end
    end
  end
  return set
end

-- How well a token fits the spec (higher is better; nil = wrong token).
local function score(r, spec)
  local hay = (tostring(r.name) .. " " .. tostring(r.typeLine)):lower()
  for _, w in ipairs(spec.words) do
    if not hay:find(w, 1, true) then
      return nil
    end
  end
  local s = 0
  if spec.pt then
    if tostring(r.tpl):find(spec.pt, 1, true) then
      s = s + 2
    else
      return nil
    end
  end
  local have = tplColors(r.tpl)
  local same = true
  for _, c in ipairs({ "W", "U", "B", "R", "G" }) do
    if (have[c] or false) ~= (spec.colors[c] or false) then
      same = false
    end
  end
  if same then
    s = s + 3
  end
  return s
end

local function best(list, spec)
  local top, topScore
  for _, r in ipairs(list) do
    local sc = score(r, spec)
    if sc and (topScore == nil or sc > topScore) then
      top, topScore = r, sc
    end
  end
  return top
end

function Tokens.create(color, spec, n, sourceName, opts)
  local p = GameState.player(color)
  local fromDeck = best(p and p.deckTokens or {}, spec)
  if fromDeck then
    Tokens.spawn(color, fromDeck, n, opts)
    return
  end
  local query = ((spec.pt or "") .. " " .. table.concat(spec.words, " ")):gsub("^%s+", "")
  WebRequest.get("https://" .. Importer.RELAY_HOST .. "/tokens?q=" .. urlEncode(query), function(req)
    local list = {}
    if not req.is_error and (req.response_code or 200) < 400 and req.text ~= "NONE" then
      for _, line in ipairs(Importer.splitPlain(req.text or "", "\n")) do
        local f = Importer.splitPlain(line, "\t")
        if f[1] == "TOKEN" and f[6] then
          table.insert(list, { name = f[3], typeLine = f[4], image = f[5], tpl = f[6] })
        end
      end
    end
    local r = best(list, spec)
    if r == nil then
      broadcastToColor(tostring(sourceName) .. ": couldn't find a \"" .. query
        .. "\" token. Make it with your TOKENS tile.", color, { 1, 0.6, 0.2 })
      return
    end
    Tokens.spawn(color, r, n, opts)
  end)
end

---------------------------------------------------------------------------
-- XML handlers
---------------------------------------------------------------------------

-- Show the tokens from this seat's imported decklist.
function Tokens.showDeck(c)
  local p = GameState.player(c)
  -- One entry per token (the same token listed twice shows once).
  local list, seen = {}, {}
  for _, tk in ipairs(p and p.deckTokens or {}) do
    local key = tostring(tk.image) .. "|" .. tostring(tk.name)
    if not seen[key] and #list < MAX_RESULTS then
      seen[key] = true
      table.insert(list, tk)
    end
  end
  results[c] = list
  if #list == 0 then
    status(c, "No tokens were in your imported decklist. Search for one above.")
  else
    status(c, "From your decklist: click one to put it onto your battlefield.")
  end
  render(c)
end

-- Open / close a seat's token panel (the TOKENS tile calls this). The first
-- time, it opens on the decklist's tokens if there are any.
function Tokens.toggle(c)
  open[c] = not open[c]
  UI.setAttribute("tokens_" .. c, "active", open[c] and "true" or "false")
  if open[c] then
    local p = GameState.player(c)
    if results[c] == nil and p and p.deckTokens and #p.deckTokens > 0 then
      Tokens.showDeck(c)
    else
      render(c)
    end
  end
end

function ui_tokenDeck(player, c)
  if c ~= player.color then
    return
  end
  Tokens.showDeck(c)
end

function ui_tokensClose(player, c)
  if c ~= player.color then
    return
  end
  open[c] = false
  UI.setAttribute("tokens_" .. c, "active", "false")
end

function ui_tokenText(player, value)
  text[player.color] = value
end

function ui_tokenSubmit(player, value)
  text[player.color] = value
  Tokens.search(player.color, value)
end

function ui_tokenSearch(player)
  Tokens.search(player.color, text[player.color])
end

function ui_tokenCopies(player, arg)
  local c, how = tostring(arg):match("^(%a+)_(%a+)$")
  if c ~= player.color then
    return
  end
  copies[c] = math.max(1, math.min(20, (copies[c] or 1) + (how == "plus" and 1 or -1)))
  UI.setValue("tokCopies_" .. c, "x" .. copies[c])
end

function ui_tokenPick(player, arg)
  local c, i = tostring(arg):match("^(%a+)_(%d+)$")
  if c ~= player.color then
    return
  end
  local r = results[c] and results[c][tonumber(i)]
  if r then
    Tokens.spawn(c, r, copies[c] or 1)
  end
end
