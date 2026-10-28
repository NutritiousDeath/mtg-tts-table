--[[
  leave.lua
  A player leaving the game (CR 800.4a): after a confirmed loss (the tracker's Confirm loss) or a
  concession (!concede, or CONCEDE in TURN OPTIONS, which asks first):
    * their spells and abilities on the stack go away;
    * everything they OWN leaves the game: their hand, library, graveyard, exile and command zone,
      and their cards on any battlefield (including ones an opponent took), go into a locked bag at
      the edge of their seat ("Red - out of the game"); their tokens just cease to exist;
    * cards they CONTROL but don't own are exiled (to their owners' exile);
    * their seat goes dark: the tracker shows OUT, the turn strip says OUT OF THE GAME, cards dropped
      on their areas do nothing (nothing is cast, nothing triggers), and they're never asked for
      responses; if it was their turn, the turn passes on.
  The tracker's "Undo: back in game" brings the player back; their cards stay in the bag to lay out again.
  In Two-Headed Giant the whole team leaves together (trackers.lua).
--]]

Leave = {}

local WARN = { 1, 0.6, 0.2 }
local INFO = { 0.75, 0.8, 0.9 }

function Leave.isOut(seat)
  if seat == nil or GameState.data == nil or not GameState.data.started then
    return false
  end
  local p = GameState.player(seat)
  return p ~= nil and p.eliminated == true
end

local function bags()
  GameState.data.outBags = GameState.data.outBags or {}
  return GameState.data.outBags
end

-- Where the bag sits: at the edge of the seat, right of the middle, clear of the lands row.
local function bagSpot(color)
  local s = TableSetup.seat(color)
  if s == nil then
    return { 0, TableSetup.SURFACE_TOP + 3, 0 }, 0
  end
  return { s.center.x + s.right.x * 15 + s.inward.x * 2.2, TableSetup.SURFACE_TOP + 1.5,
    s.center.z + s.right.z * 15 + s.inward.z * 2.2 }, s.yaw
end

-- The seat's bag (spawned if needed), then fn(bag).
local function withBag(color, fn)
  local g = bags()[color]
  local bag = g and getObjectFromGUID(g)
  if bag and not bag.isDestroyed() then
    fn(bag)
    return
  end
  local pos, yaw = bagSpot(color)
  spawnObject({
    type = "Bag",
    position = pos,
    rotation = { 0, yaw, 0 },
    scale = { 1.4, 1.4, 1.4 },
    sound = false,
    callback_function = function(b)
      b.setName(color .. " - out of the game")
      b.setDescription("Everything " .. color .. " owned when they left the game. Open it after the game to get the deck back.")
      pcall(function() b.setColorTint(stringColorToRGB(color)) end)
      b.addTag("OutBag")
      b.setLock(true)
      bags()[color] = b.getGUID()
      fn(b)
    end,
  })
end

local function isMtg(obj)
  if obj == nil or obj.isDestroyed() then
    return false
  end
  if obj.type == "Card" then
    return obj.hasTag("MTGCard")
  end
  return obj.type == "Deck"
end

local function ownerOf(obj, fallback)
  local o = Effects and Effects.ownerOf and Effects.ownerOf(obj)
  return o or fallback
end

-- Move a card to its owner's exile.
local function exileTo(obj, owner)
  local s = TableSetup.seat(owner)
  if s == nil then
    return
  end
  obj.setLock(false)
  obj.setRotation({ 0, s.yaw, 0 })
  obj.setPosition(TableSetup.slot(owner, "exile", 3))
  Wait.time(function()
    if not obj.isDestroyed() then
      Zones.refresh(obj)
    end
  end, 1)
end

-- Everything that goes, split into what goes in the bag, what's exiled to its owner, and tokens to remove.
local function sweep(color)
  local toBag, toExile, gone = {}, {}, {}
  local inHand = {}
  pcall(function()
    for _, h in ipairs(Player[color].getHandObjects() or {}) do
      inHand[h.getGUID()] = true
    end
  end)
  -- Spells and abilities on the stack that are theirs.
  local onStack = {}
  if Stack and Stack.dropControlledBy then
    local okd, list = pcall(Stack.dropControlledBy, color)
    for _, e in ipairs(okd and list or {}) do
      onStack[e.guid] = true
      local obj = getObjectFromGUID(e.guid)
      if obj and not obj.isDestroyed() then
        if e.kind == "ability" or obj.hasTag("Token") then
          table.insert(gone, obj)
        elseif ownerOf(obj, color) == color then
          table.insert(toBag, obj)
        else
          table.insert(toExile, { obj = obj, owner = ownerOf(obj, color) })
        end
      end
    end
  end
  for _, obj in ipairs(getAllObjects()) do
    if isMtg(obj) and not onStack[obj.getGUID()] and obj.held_by_color == nil then
      local okl, loc = pcall(function() return Zones.regionAt(obj.getPosition()) end)
      loc = okl and loc or {}
      local field = loc.region == "battlefield" or loc.region == "lands"
      local token = obj.type == "Card" and obj.hasTag("Token")
      if inHand[obj.getGUID()] then
        table.insert(toBag, obj)
      elseif loc.seat == color and not field then
        -- Library, graveyard, exile, command zones (and anything else in their areas).
        if token then
          table.insert(gone, obj)
        else
          table.insert(toBag, obj)
        end
      elseif loc.seat == color and field then
        local owner = obj.type == "Card" and ownerOf(obj, color) or color
        if owner == color or not TableSetup.isActive(owner) then
          table.insert(token and gone or toBag, obj)
        elseif token then
          table.insert(gone, obj)
        else
          -- Theirs to control, someone else's to own: exiled.
          table.insert(toExile, { obj = obj, owner = owner })
        end
      elseif field and loc.seat and loc.seat ~= color and obj.type == "Card" and ownerOf(obj, nil) == color then
        -- Their card on someone else's battlefield (taken from them): it leaves the game too.
        table.insert(token and gone or toBag, obj)
      end
    end
  end
  return toBag, toExile, gone
end

-- Take a player out: called once their loss is confirmed (trackers.lua).
function Leave.run(color)
  if GameState.data == nil or not GameState.data.started then
    return
  end
  local toBag, toExile, gone = sweep(color)
  for _, e in ipairs(toExile) do
    pcall(exileTo, e.obj, e.owner)
    printToAll("MTG > " .. e.obj.getName() .. " (" .. e.owner .. "'s card, controlled by " .. color .. ") is exiled.", INFO)
  end
  for _, obj in ipairs(gone) do
    pcall(function() obj.destruct() end)
  end
  -- Their mana pool empties; nothing is waiting on them any more.
  if GameState.data.mana then
    GameState.data.mana[color] = nil
  end
  if #toBag > 0 then
    withBag(color, function(bag)
      for _, obj in ipairs(toBag) do
        if not obj.isDestroyed() then
          pcall(function()
            obj.setLock(false)
            bag.putObject(obj)
          end)
        end
      end
      printToAll("MTG > " .. color .. "'s cards are in the bag at their seat (" .. #toBag .. " item" .. (#toBag == 1 and "" or "s") .. ").", INFO)
    end)
  end
  if Turns and Turns.playerLeft then
    pcall(Turns.playerLeft, color)
  end
  if Turns and Turns.render then
    pcall(Turns.render)
  end
end

-- !concede / TURN OPTIONS > Concede: asks first.
function Leave.concede(color)
  if GameState.data == nil or not GameState.data.started then
    broadcastToColor("No game running.", color, INFO)
    return
  end
  if Leave.isOut(color) then
    broadcastToColor("You're already out of the game.", color, INFO)
    return
  end
  Effects.askChoice(color, "Concede the game?", "You leave the game: your cards go into a bag at your seat and your turns are skipped."
    .. " (The tracker's Undo can bring you back.)", { { label = "YES, CONCEDE", value = true }, { label = "NO", value = false } }, function(yes)
      if not yes then
        return
      end
      local p = GameState.player(color)
      if p == nil or p.eliminated then
        return
      end
      p.lossFlag = "conceded"
      p.conceded = true
      Trackers.confirmLoss(color, color)
    end)
end
