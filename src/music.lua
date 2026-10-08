--[[
  music.lua
  The table's soundtrack, played through Tabletop Simulator's own music
  player (everyone hears it). The track list is read from GitHub: every
  .mp3 under assets/music in the repo. Push new songs, then type
  !music reload: no Save and Play needed. music_tracks.lua is only the
  backup list used if GitHub can't be reached.

    !music            show the commands
    !music play       start / resume
    !music pause
    !music next / !music prev
    !music shuffle    shuffle on / off
    !music loop       loop the playlist on / off
    !music reload     re-read the song list from GitHub
    !music list       show the track numbers
    !music 5          jump to track 5
--]]

Music = {}

require("src/music_tracks")
local tracks = MUSIC_TRACKS or {}
local INFO, GOOD, WARN = { 0.6, 0.9, 1 }, { 0.3, 1, 0.6 }, { 1, 0.4, 0.4 }

local function say(msg, color)
  printToAll("MTG > MUSIC: " .. msg, color or INFO)
end

local loaded = false
local fetched = false

local REPO = "NutritiousDeath/mtg-tts-table"
local BRANCH = "main"
local TREE_URL = "https://api.github.com/repos/" .. REPO .. "/git/trees/" .. BRANCH .. "?recursive=1"
local RAW = "https://raw.githubusercontent.com/" .. REPO .. "/" .. BRANCH .. "/"

local function encode(path)
  return (path:gsub("[^%w%-%._~/]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function pushPlaylist()
  local ok, err = pcall(function()
    local list = {}
    for _, t in ipairs(tracks) do
      table.insert(list, { title = t.title, url = t.url })
    end
    MusicPlayer.setPlaylist(list)
  end)
  if not ok then
    say("couldn't load the playlist: " .. tostring(err), WARN)
    return false
  end
  loaded = true
  return true
end

local function load()
  if loaded then
    return true
  end
  return pushPlaylist()
end

-- Read the song list from the repo. done(true/false) when finished.
function Music.refresh(done)
  WebRequest.get(TREE_URL, function(req)
    local ok = false
    local ok2, err = pcall(function()
      if req.is_error then
        error(tostring(req.error))
      end
      local data = JSON.decode(req.text)
      local paths = {}
      for _, e in ipairs(data.tree or {}) do
        if e.type == "blob" and e.path:lower():find("^assets/music/.*%.mp3$") then
          table.insert(paths, e.path)
        end
      end
      table.sort(paths)
      if #paths == 0 then
        error("no .mp3 files under assets/music in the repo yet")
      end
      local list = {}
      for _, path in ipairs(paths) do
        local title = path:match("([^/]+)%.mp3$") or path
        title = title:gsub("^%d+ %- ", ""):gsub("^Bonus %- (%d+) %- ", "Bonus %1: ")
        table.insert(list, { title = title, url = RAW .. encode(path) })
      end
      tracks = list
      ok = true
    end)
    fetched = true
    if ok then
      pushPlaylist()
      say("song list read from GitHub: " .. #tracks .. " tracks.", GOOD)
    else
      say("couldn't read GitHub (" .. tostring(err) .. "): using the saved list of " .. #tracks .. " tracks.", WARN)
      load()
    end
    if done then
      done(ok)
    end
  end)
end

-- Make sure the list has been read once, then carry on.
local function ready(fn)
  if fetched then
    load()
    fn()
  else
    say("reading the song list from GitHub...")
    Music.refresh(function() fn() end)
  end
end

local function try(label, fn)
  if not load() then
    return
  end
  local ok, err = pcall(fn)
  if not ok then
    say(label .. " failed: " .. tostring(err), WARN)
  end
end

local function current()
  local i = 0
  pcall(function() i = MusicPlayer.playlistIndex or 0 end)
  return tracks[i + 1] and tracks[i + 1].title or "?"
end

function Music.chat(message)
  local cmd = tostring(message):lower():match("^!music%s*(.*)$")
  if cmd == nil then
    return false
  end
  cmd = cmd:gsub("%s+$", "")
  if cmd == "" or cmd == "help" then
    say("!music play | pause | next | prev | shuffle | loop | list | <track number>   (" .. #tracks .. " tracks)")
  elseif cmd == "reload" then
    Music.refresh()
  elseif cmd == "play" then
    ready(function()
      try("play", function() MusicPlayer.play() end)
      say("playing: " .. current(), GOOD)
    end)
  elseif cmd == "pause" then
    try("pause", function() MusicPlayer.pause() end)
    say("paused.")
  elseif cmd == "next" then
    try("next", function() MusicPlayer.skip() end)
    Wait.time(function() say("now: " .. current(), GOOD) end, 1)
  elseif cmd == "prev" then
    try("prev", function() MusicPlayer.previous() end)
    Wait.time(function() say("now: " .. current(), GOOD) end, 1)
  elseif cmd == "shuffle" then
    try("shuffle", function()
      MusicPlayer.shuffle = not MusicPlayer.shuffle
      say("shuffle " .. (MusicPlayer.shuffle and "ON" or "OFF") .. ".", GOOD)
    end)
  elseif cmd == "loop" then
    try("loop", function()
      MusicPlayer.loop = not MusicPlayer.loop
      say("loop " .. (MusicPlayer.loop and "ON" or "OFF") .. ".", GOOD)
    end)
  elseif cmd == "list" then
    for i, t in ipairs(tracks) do
      printToAll(string.format("  %2d  %s", i, t.title), INFO)
    end
  elseif tonumber(cmd) then
    local n = math.floor(tonumber(cmd))
    if tracks[n] == nil then
      say("there are only " .. #tracks .. " tracks.", WARN)
    else
      ready(function()
        if tracks[n] == nil then
          say("there are only " .. #tracks .. " tracks.", WARN)
          return
        end
        try("jump", function()
          MusicPlayer.setCurrentAudioclip({ url = tracks[n].url, title = tracks[n].title })
          MusicPlayer.play()
        end)
        say("playing: " .. tracks[n].title, GOOD)
      end)
    end
  else
    say("unknown command: try !music")
  end
  return true
end
