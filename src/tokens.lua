--[[
  tokens.lua
  Token search: "Tokens" (screen, top left) opens a panel only you see.
  Type a token ("treasure", "1/1 soldier", "zombie", "food"...) and SEARCH:
  the relay looks it up on Scryfall (GET /tokens?q=...) and shows up to 12
  matching tokens with their pictures. Click one to put it onto your
  battlefield; the - / + buttons set how many copies each click makes.
  Tokens are real cards (tagged "Token") so counters, tapping and the
  battlefield tracking all work on them.
--]]

Tokens = {}

local MAX_RESULTS = 12
local INFO = { 0.75, 0.8, 0.9 }
local WARN = { 1, 0.6, 0.2 }

local text = {}      -- [color] = what's typed in the search box
local results = {}   -- [color] = { { name, typeLine, image, tpl } }
local copies = {}    -- [color] = copies per click
local open = {}

function Tokens.xml()
  local parts = { [[
<Button id="tokensToggle" onClick="ui_tokensToggle" rectAlignment="UpperLeft" offsetXY="20 -220"
        width="150" height="40" fontStyle="Bold" color="#2A3346" textColor="#E6F1FF">Tokens</Button>
]] }
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
<Panel id="tokens_%s" visibility="%s" active="false" rectAlignment="UpperLeft" offsetXY="180 -220" width="700" height="150"
       color="#0B0F17F2" outline="#5AF0FF" outlineSize="2 2" allowDragging="true" returnToOriginalPositionWhenReleased="false">
  <VerticalLayout padding="12 12 12 12" spacing="8" childForceExpandHeight="false">
    <Text fontSize="15" fontStyle="Bold" color="#5AF0FF" alignment="MiddleLeft" preferredHeight="22">TOKENS</Text>
    <HorizontalLayout spacing="8" preferredHeight="38" childForceExpandWidth="false">
      <InputField onValueChanged="ui_tokenText" onEndEdit="ui_tokenSubmit" fontSize="16" flexibleWidth="1"
                  placeholder="treasure, 1/1 soldier, zombie, food..." />
      <Button onClick="ui_tokenSearch" preferredWidth="110" color="#00B3A4" textColor="#06130B" fontStyle="Bold">SEARCH</Button>
      <Button onClick="ui_tokenCopies(%s_minus)" preferredWidth="34" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold">-</Button>
      <Text id="tokCopies_%s" preferredWidth="70" fontSize="14" fontStyle="Bold" color="#E6F1FF">x1</Text>
      <Button onClick="ui_tokenCopies(%s_plus)" preferredWidth="34" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold">+</Button>
    </HorizontalLayout>
    <Text id="tokStatus_%s" fontSize="12" color="#8B98A9" alignment="MiddleLeft" preferredHeight="18">Search for a token, then click it to put it onto your battlefield.</Text>
    <GridLayout id="tokGrid_%s" active="false" cellSize="104 146" spacing="8 8" constraint="FixedColumnCount" constraintCount="6"
                childAlignment="UpperLeft" preferredHeight="300">]] .. table.concat(slots) .. [[</GridLayout>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, c, c, c, c))
  end
  return table.concat(parts)
end

local function status(color, msg)
  UI.setValue("tokStatus_" .. color, msg)
end

local function render(color)
  local list = results[color] or {}
  local rows = math.ceil(#list / 6)
  UI.setAttribute("tokGrid_" .. color, "active", #list > 0 and "true" or "false")
  UI.setAttribute("tokGrid_" .. color, "preferredHeight", rows * 154)
  UI.setAttribute("tokens_" .. color, "height", 150 + rows * 154)
  UI.setValue("tokCopies_" .. color, "x" .. (copies[color] or 1))
  for i = 1, MAX_RESULTS do
    local id = color .. "_" .. i
    local r = list[i]
    if r then
      UI.setAttribute("tokSlot_" .. id, "active", "true")
      UI.setValue("tokName_" .. id, r.name)
      UI.setAttribute("tokImg_" .. id, "image", r.image)
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
function Tokens.spawn(color, r, n)
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
      rotation = { 0, s.yaw, 0 },
      callback_function = function(obj)
        obj.setName(r.name)
        Zones.refresh(obj)
      end,
    })
  end
  printToAll("MTG > " .. color .. " creates " .. n .. " " .. r.name .. " token" .. (n == 1 and "" or "s"), INFO)
end

---------------------------------------------------------------------------
-- XML handlers
---------------------------------------------------------------------------

function ui_tokensToggle(player)
  local c = player.color
  if not TableSetup.isActive(c) then
    broadcastToColor("Take a seat first.", c, WARN)
    return
  end
  open[c] = not open[c]
  UI.setAttribute("tokens_" .. c, "active", open[c] and "true" or "false")
  if open[c] then
    render(c)
  end
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
