--[[
  bugreport.lua
  BUG on a seat's console strip (or "!bug <what happened>" in chat): a small panel only that player sees,
  with "What happened?", "Attach the game's logs" (on) and "Include my Steam name" (off: the player opts in).
  SEND posts it to the card relay's /bug route, which DMs it to the table's owner on Discord (the bot token
  and the Discord user ID are Cloudflare secrets on the relay, never in this script: the Workshop script is
  readable by anyone). The logs go along as a text file: the MTG Errors and MTG By Hand lists and the end of
  the game log (gamelog.lua), plus the version, layout, format, turn and whose turn it is.
  One report per player every 2 minutes (the relay limits it too).
--]]

BugReport = {}

local GAP = 120            -- seconds between reports from one player
local MAX_TEXT = 1500
local INFO = { 0.75, 0.8, 0.9 }
local WARN = { 1, 0.6, 0.2 }
local GOOD = { 0.55, 0.9, 0.6 }

local open, text, withLogs, withSteam, lastSent, sending = {}, {}, {}, {}, {}, {}

function BugReport.xml()
  local parts = {}
  for _, c in ipairs(TableSetup.activeSeats()) do
    table.insert(parts, ([[
<Panel id="bug_%s" visibility="%s" active="false" rectAlignment="MiddleCenter" width="460" height="330"
       color="#0B0F17F5" outline="#FF6A6A" outlineSize="2 2">
  <VerticalLayout padding="14 14 12 12" spacing="8" childForceExpandHeight="false">
    <Text fontSize="17" fontStyle="Bold" color="#FF8A8A" preferredHeight="24">REPORT A BUG</Text>
    <Text fontSize="13" color="#C8D2E6" preferredHeight="34" alignment="UpperLeft">What happened, and which card? It goes straight to the table's maker with the logs.</Text>
    <InputField id="bugText_%s" onValueChanged="ui_bugText" lineType="MultiLineNewline" characterLimit="1500"
                preferredHeight="120" fontSize="14" placeholder="e.g. Notion Thief took my teammate's draw..."></InputField>
    <Toggle id="bugLogs_%s" onValueChanged="ui_bugLogs" isOn="true" textColor="#E6F1FF" fontSize="14" preferredHeight="24">Attach the game's logs (errors, by-hand list, recent game log)</Toggle>
    <Toggle id="bugSteam_%s" onValueChanged="ui_bugSteam" isOn="false" textColor="#E6F1FF" fontSize="14" preferredHeight="24">Include my Steam name (so they can ask you about it)</Toggle>
    <HorizontalLayout spacing="10" preferredHeight="40">
      <Button id="bugSend_%s" onClick="ui_bugSend" color="#E04B4B" textColor="#FFFFFF" fontStyle="Bold">SEND</Button>
      <Button onClick="ui_bugClose" color="#1B2333" textColor="#E6F1FF" fontStyle="Bold">CANCEL</Button>
    </HorizontalLayout>
  </VerticalLayout>
</Panel>
]]):format(c, c, c, c, c, c))
  end
  return table.concat(parts)
end

local function seated(c)
  if c == nil or not TableSetup.isActive(c) then
    broadcastToColor("Take a seat first, then report the bug.", c or "Grey", WARN)
    return false
  end
  return true
end

local function show(c, on)
  open[c] = on
  pcall(function() UI.setAttribute("bug_" .. c, "active", on and "true" or "false") end)
end

function ui_bugOpen(player)
  local c = player.color
  if not seated(c) then
    return
  end
  if withLogs[c] == nil then
    withLogs[c] = true
  end
  show(c, not open[c])
end

function ui_bugClose(player)
  show(player.color, false)
end

function ui_bugText(player, value)
  text[player.color] = tostring(value or "")
end

local function truthy(v)
  return v == true or v == "True" or v == "true"
end

function ui_bugLogs(player, value)
  withLogs[player.color] = truthy(value)
end

function ui_bugSteam(player, value)
  withSteam[player.color] = truthy(value)
end

local function relayUrl()
  local host = Importer and Importer.relayHost and Importer.relayHost() or ""
  if host == "" then
    return nil
  end
  return "https://" .. host .. "/bug"
end

-- Send a report for seat c. what: the player's words. opts: { logs = bool, steam = bool }.
function BugReport.send(player, what, opts)
  local c = player.color
  if not seated(c) then
    return
  end
  what = tostring(what or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if what == "" then
    broadcastToColor("Say what happened first (and which card, if there was one).", c, WARN)
    return
  end
  if #what > MAX_TEXT then
    what = what:sub(1, MAX_TEXT)
  end
  local now = os.time()
  if lastSent[c] and now - lastSent[c] < GAP then
    broadcastToColor("You just sent one: wait " .. (GAP - (now - lastSent[c])) .. " seconds before the next report.", c, WARN)
    return
  end
  if sending[c] then
    return
  end
  local url = relayUrl()
  if url == nil then
    broadcastToColor("Bug reports need the card relay, and none is set (!relay).", c, WARN)
    return
  end
  local d = GameState.data or {}
  local t = d.turn or {}
  local body = {
    text = what,
    version = tostring(SCRIPT_VERSION or "?"),
    seat = c,
    layout = TableSetup.layout and TableSetup.layout() or "?",
    format = tostring((d.table and d.table.format) or d.format or "commander"),
    started = d.started and true or false,
    turn = t.number or t.taken,
    active = t.activeSeat,
    step = (Turns and Turns.STEPS and t.stepIndex and Turns.STEPS[t.stepIndex] and Turns.STEPS[t.stepIndex].id) or t.step,
    planechase = (d.planechase and d.planechase.on) and true or nil,
  }
  if opts and opts.steam then
    local ok, name = pcall(function() return player.steam_name end)
    if ok and name and name ~= "" then
      body.steam = tostring(name)
    end
  end
  if opts and opts.logs ~= false and GameLog and GameLog.reportText then
    local ok, logs = pcall(GameLog.reportText, 250)
    if ok and logs then
      body.logs = logs
    end
  end
  sending[c] = true
  broadcastToColor("Sending your bug report...", c, INFO)
  WebRequest.custom(url, "POST", true, JSON.encode(body), {
    ["Content-Type"] = "application/json",
    ["Accept"] = "text/plain",
  }, function(req)
    sending[c] = nil
    if req.is_error and (req.response_code == nil or req.response_code == 0) then
      broadcastToColor("The bug report couldn't be sent: the relay isn't answering (" .. tostring(req.error) .. "). Try again later.", c, WARN)
      return
    end
    if req.response_code == 429 then
      broadcastToColor("Too many reports right now: wait a couple of minutes and try again.", c, WARN)
      return
    end
    if req.response_code == 404 then
      broadcastToColor("This relay doesn't take bug reports yet (it needs the update with /bug).", c, WARN)
      return
    end
    if req.is_error or req.response_code ~= 200 then
      local why = tostring(req.text or ""):gsub("^ERROR\t", ""):sub(1, 160)
      broadcastToColor("The bug report couldn't be sent (" .. tostring(req.response_code) .. (why ~= "" and (": " .. why) or "") .. ").", c, WARN)
      return
    end
    lastSent[c] = os.time()
    text[c] = nil
    pcall(function() UI.setAttribute("bugText_" .. c, "text", "") end)
    show(c, false)
    broadcastToColor("Bug report sent. Thanks!", c, GOOD)
    if GameLog and GameLog.add then
      GameLog.add("BUG", c .. " sent a bug report: " .. what)
    end
  end)
end

function ui_bugSend(player)
  local c = player.color
  BugReport.send(player, text[c], { logs = withLogs[c] ~= false, steam = withSteam[c] == true })
end
