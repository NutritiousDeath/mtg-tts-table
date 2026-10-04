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

function Events.emit(name, data)
  for _, fn in ipairs(listeners[name] or {}) do
    -- One broken listener shouldn't stop the others.
    local ok, err = pcall(fn, data)
    if not ok then
      print("MTG > Event '" .. name .. "' listener error: " .. tostring(err))
    end
  end
end
