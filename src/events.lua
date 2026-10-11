--[[
  events.lua
  A tiny event system so modules can react to each other without being
  wired together directly.

    Events.on("cardMoved", function(data) ... end)
    Events.emit("cardMoved", { card = obj, from = {...}, to = {...} })

  Events used so far:
    cardMoved   { card, name, from = {seat, region} or nil, to = {seat, region} }
                Fired when a card ends up in a different playmat area or hand.
                Phase 6 (triggers) listens to this for "dies", "enters", etc.
--]]

Events = {}

local listeners = {}

function Events.on(name, fn)
  listeners[name] = listeners[name] or {}
  table.insert(listeners[name], fn)
end

-- Run before the other listeners (faces.lua: a card played face down is a
-- 2/2 creature before triggers look at it).
function Events.onFirst(name, fn)
  listeners[name] = listeners[name] or {}
  table.insert(listeners[name], 1, fn)
end

-- Script errors inside guarded steps: kept (last 15) and shown in chat, so they can be copied and sent.
Events.errors = Events.errors or {}
function Events.noteError(where, err)
  local line = tostring(where) .. ": " .. tostring(err)
  table.insert(Events.errors, line)
  while #Events.errors > 15 do
    table.remove(Events.errors, 1)
  end
  printToAll("MTG > SCRIPT ERROR in " .. line:sub(1, 300) .. "  (type !errors to list the last ones)", { 1, 0.45, 0.35 })
end

function Events.emit(name, data)
  for _, fn in ipairs(listeners[name] or {}) do
    -- One broken listener shouldn't stop the others.
    local ok, err = pcall(fn, data)
    if not ok then
      print("MTG > Event '" .. name .. "' listener error: " .. tostring(err))
      Events.noteError("event '" .. name .. "'", err)
    end
  end
end
