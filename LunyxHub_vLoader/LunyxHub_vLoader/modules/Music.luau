--[[
    Lunyx Hub | Music module (ported from vMusic)
    Engine + Music tab. Shared module: loaded in every game by the Core.

    Changes versus vMusic
      * Volume slider <-> engine feedback loop fixed (SetValue re-fired the callback).
      * Repeat "off" no longer wraps to track 1 when the last track ends by itself.
      * Playlist dropdown now refreshes on add / remove / remote load.
      * Selecting a track plays it, but never during build or refresh.
      * Seek slider is not overwritten for a moment after you drag it.
]]

local Ctx = ...
local Library, Options, Toggles = Ctx.Library, Ctx.Options, Ctx.Toggles
local env = Ctx.Env
local PushError = Ctx.Err

local cloneref = cloneref or function(o) return o end
local function Svc(name)
    local ok, s = pcall(function() return cloneref(game:GetService(name)) end)
    return ok and s or nil
end
local RunService   = Svc("RunService")
local SoundService = Svc("SoundService")
local HttpService  = Svc("HttpService")

----------------------------------------------------------------------
-- Engine
----------------------------------------------------------------------
local ME = {}
ME.__index = ME

function ME.new(opts)
    opts = opts or {}
    local self = setmetatable({}, ME)
    self.Playlist = opts.Playlist or {
        { Name = "Phonk Drift",   Artist = "Unknown",         Id = "rbxassetid://9048371035" },
        { Name = "Montagem Hit",  Artist = "Brazilian Phonk", Id = "rbxassetid://1837879082" },
        { Name = "Night Drive",   Artist = "Various",         Id = "rbxassetid://142376088" },
        { Name = "Lo-Fi Beat",    Artist = "Chill",           Id = "rbxassetid://1844702914" },
        { Name = "Drift Phonk 2", Artist = "Unknown",         Id = "rbxassetid://9048371035" },
    }
    self.Current   = 1
    self.Playing   = false
    self.Shuffle   = false
    self.Repeat    = "off" -- off | one | all
    self.Volume    = 1
    self.Sound     = nil
    self._conn     = nil
    self._ended    = nil
    self._listeners = {}
    self._lastProg = 0
    self:_ensureSound()
    return self
end

function ME:_ensureSound()
    if self.Sound and self.Sound.Parent then return self.Sound end
    local ok, s = pcall(function()
        local snd = Instance.new("Sound")
        snd.Name = "LunyxMusic"
        snd.Volume = self.Volume
        snd.Looped = false
        snd.Parent = SoundService
        return snd
    end)
    if not ok or not s then
        PushError("MusicEngine", "Sound create failed", s)
        return nil
    end
    self.Sound = s
    if self._ended then self._ended:Disconnect() end
    self._ended = s.Ended:Connect(function() self:_onEnded() end)
    return s
end

function ME:_emit(ev, ...)
    local list = self._listeners[ev]
    if not list then return end
    for _, fn in ipairs(list) do pcall(fn, ...) end
end

function ME:On(ev, fn)
    self._listeners[ev] = self._listeners[ev] or {}
    table.insert(self._listeners[ev], fn)
end

function ME:_onEnded()
    if self.Repeat == "one" then
        self:Play(self.Current)
        return
    end
    self:Next(true)
end

function ME:GetTrack(i)
    return self.Playlist[i or self.Current]
end

function ME:Play(index)
    index = index or self.Current
    local track = self.Playlist[index]
    if not track then
        PushError("MusicEngine", "Empty playlist / bad index")
        return false
    end
    local s = self:_ensureSound()
    if not s then return false end
    local ok, err = pcall(function()
        s.SoundId = track.Id
        s.TimePosition = 0
        s.Volume = self.Volume
        s:Play()
    end)
    if not ok then
        PushError("MusicEngine", "Play failed", err)
        return false
    end
    self.Current = index
    self.Playing = true
    self:_startHB()
    self:_emit("TrackChanged", track, index)
    self:_emit("PlayState", true)
    return true
end

function ME:Pause()
    if self.Sound and self.Playing then
        pcall(function() self.Sound:Pause() end)
        self.Playing = false
        self:_emit("PlayState", false)
    end
end

function ME:Resume()
    if self.Sound and not self.Playing then
        pcall(function() self.Sound:Resume() end)
        self.Playing = true
        self:_startHB()
        self:_emit("PlayState", true)
    end
end

function ME:Toggle()
    if self.Playing then
        self:Pause()
    elseif self.Sound and self.Sound.TimePosition > 0 and not self.Sound.IsPlaying then
        self:Resume()
    else
        self:Play(self.Current)
    end
end

function ME:Stop()
    if self.Sound then
        pcall(function()
            self.Sound:Stop()
            self.Sound.TimePosition = 0
        end)
    end
    self.Playing = false
    self:_stopHB()
    self:_emit("PlayState", false)
end

function ME:Next(auto)
    if #self.Playlist == 0 then return end
    local n
    if self.Shuffle then
        n = math.random(1, #self.Playlist)
    else
        n = self.Current + 1
        if n > #self.Playlist then
            -- when a track ends by itself, only wrap if repeat-all is on
            if self.Repeat == "all" or not auto then
                n = 1
            else
                self:Stop()
                return
            end
        end
    end
    self:Play(n)
end

function ME:Prev()
    if self.Sound and self.Sound.TimePosition > 2.5 then
        pcall(function() self.Sound.TimePosition = 0 end)
        return
    end
    local p = self.Current - 1
    if p < 1 then p = #self.Playlist end
    self:Play(p)
end

function ME:Seek(ratio)
    ratio = math.clamp(ratio, 0, 1)
    if self.Sound and self.Sound.TimeLength > 0 then
        pcall(function() self.Sound.TimePosition = self.Sound.TimeLength * ratio end)
        self:_emit("Progress", self:GetProgress())
    end
end

function ME:SetVolume(v)
    self.Volume = math.clamp(tonumber(v) or 1, 0, 2)
    if self.Sound then pcall(function() self.Sound.Volume = self.Volume end) end
    self:_emit("Volume", self.Volume)
end

function ME:SetShuffle(s)
    self.Shuffle = not not s
    self:_emit("Shuffle", self.Shuffle)
end

function ME:CycleRepeat()
    self.Repeat = (self.Repeat == "off" and "all") or (self.Repeat == "all" and "one") or "off"
    self:_emit("Repeat", self.Repeat)
    return self.Repeat
end

function ME:AddTrack(name, artist, id)
    if type(id) ~= "string" or id == "" then
        PushError("MusicEngine", "AddTrack bad id")
        return false
    end
    if not id:find("rbxassetid://", 1, true) and tonumber(id) then
        id = "rbxassetid://" .. tostring(id)
    end
    table.insert(self.Playlist, {
        Name = tostring(name or "Track"),
        Artist = tostring(artist or "Unknown"),
        Id = id,
    })
    self:_emit("PlaylistChanged", self.Playlist)
    return true
end

function ME:RemoveTrack(index)
    if self.Playlist[index] then
        table.remove(self.Playlist, index)
        if self.Current > #self.Playlist then self.Current = math.max(1, #self.Playlist) end
        self:_emit("PlaylistChanged", self.Playlist)
        return true
    end
    return false
end

function ME:GetProgress()
    if not self.Sound or self.Sound.TimeLength <= 0 then return 0, 0, 0 end
    local pos, len = self.Sound.TimePosition, self.Sound.TimeLength
    return pos / len, pos, len
end

function ME:IsPlaying() return self.Playing end

function ME:_startHB()
    if self._conn then return end
    self._conn = RunService.Heartbeat:Connect(function()
        if not self.Playing or not self.Sound then
            self:_stopHB()
            return
        end
        local now = os.clock()
        if now - self._lastProg > 0.1 then
            self._lastProg = now
            self:_emit("Progress", self:GetProgress())
        end
    end)
end

function ME:_stopHB()
    if self._conn then
        self._conn:Disconnect()
        self._conn = nil
    end
end

function ME:Destroy()
    self:Stop()
    self:_stopHB()
    if self._ended then self._ended:Disconnect() self._ended = nil end
    if self.Sound then pcall(function() self.Sound:Destroy() end) self.Sound = nil end
    self._listeners = {}
end

function ME:LoadRemotePlaylist(url)
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if not ok then PushError("MusicEngine", "HttpGet playlist fail", body) return false end
    local ok2, data = pcall(function() return HttpService:JSONDecode(body) end)
    if not ok2 or type(data) ~= "table" then
        PushError("MusicEngine", "JSON playlist invalid")
        return false
    end
    local list = {}
    for _, t in ipairs(data) do
        if type(t) == "table" and t.Id then
            table.insert(list, {
                Name = t.Name or "Unknown",
                Artist = t.Artist or "Unknown",
                Id = tostring(t.Id),
            })
        end
    end
    if #list == 0 then PushError("MusicEngine", "Remote empty") return false end
    self.Playlist = list
    self.Current = 1
    self:_emit("PlaylistChanged", self.Playlist)
    return true
end

----------------------------------------------------------------------
-- Instance + UI
----------------------------------------------------------------------
local Music = ME.new()
env.LunyxMusic = Music

local Tab = Ctx.AddTab("Music", "music")
local PlayerBox = Tab:AddLeftGroupbox("Now Playing")
local ListBox   = Tab:AddRightGroupbox("Playlist")
local ExtraBox  = Tab:AddLeftGroupbox("Controls & Add")

local function Safe(fn)
    return function()
        local ok, err = pcall(fn)
        if not ok then PushError("MusicUI", err) end
    end
end

local function fmt(sec)
    sec = math.floor(sec + 0.5)
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function TrackNames()
    local t = {}
    for i, track in ipairs(Music.Playlist) do
        t[i] = string.format("%d. %s — %s", i, track.Name, track.Artist)
    end
    return t
end

local function IndexOf(val)
    return val and tonumber(tostring(val):match("^(%d+)"))
end

local nowLabel  = PlayerBox:AddLabel("Nothing playing", true)
local timeLabel = PlayerBox:AddLabel("0:00 / 0:00", true)

local lastUserSeek = 0
local syncSeek, syncVol, listReady = false, false, false

PlayerBox:AddSlider("MusicSeek", {
    Text = "Seek", Default = 0, Min = 0, Max = 100, Rounding = 0,
    Callback = function(v)
        if syncSeek then return end
        lastUserSeek = os.clock()
        Music:Seek(v / 100)
    end,
})

PlayerBox:AddSlider("MusicVol", {
    Text = "Volume", Default = 100, Min = 0, Max = 200, Rounding = 0, Suffix = "%",
    Callback = function(v)
        if syncVol then return end
        Music:SetVolume(v / 100)
    end,
})

PlayerBox:AddButton({ Text = "Play / Pause", Func = Safe(function() Music:Toggle() end) })
PlayerBox:AddButton({ Text = "Previous", Func = Safe(function() Music:Prev() end) })
PlayerBox:AddButton({ Text = "Next", Func = Safe(function() Music:Next() end) })

PlayerBox:AddToggle("MusicShuffle", {
    Text = "Shuffle", Default = false,
    Callback = function(v) Music:SetShuffle(v) end,
})

local repLabel = PlayerBox:AddLabel("Repeat: off")
PlayerBox:AddButton({
    Text = "Cycle repeat (off / all / one)",
    Func = Safe(function()
        repLabel:SetText("Repeat: " .. Music:CycleRepeat())
    end),
})

ListBox:AddDropdown("MusicTrackList", {
    Text = "Select track",
    Values = TrackNames(),
    Default = 1,
    Callback = function(val)
        if not listReady then return end
        local idx = IndexOf(val)
        if idx then Music:Play(idx) end
    end,
})

ListBox:AddButton({
    Text = "Play selected",
    Func = Safe(function()
        local idx = IndexOf(Options.MusicTrackList and Options.MusicTrackList.Value)
        if idx then Music:Play(idx) end
    end),
})

ListBox:AddButton({
    Text = "Remove selected",
    Func = Safe(function()
        local idx = IndexOf(Options.MusicTrackList and Options.MusicTrackList.Value)
        if idx and Music:RemoveTrack(idx) then
            Library:Notify("Track removed", 2)
        end
    end),
})

ExtraBox:AddInput("MusicNewName", { Text = "Name", Default = "", Placeholder = "Track name" })
ExtraBox:AddInput("MusicNewArtist", { Text = "Artist", Default = "", Placeholder = "Artist" })
ExtraBox:AddInput("MusicNewId", { Text = "Asset ID", Default = "", Placeholder = "rbxassetid:// or number" })
ExtraBox:AddButton({
    Text = "Add to playlist",
    Func = Safe(function()
        local name = Options.MusicNewName.Value ~= "" and Options.MusicNewName.Value or "Track"
        local artist = Options.MusicNewArtist.Value ~= "" and Options.MusicNewArtist.Value or "Unknown"
        local id = Options.MusicNewId.Value
        if id == "" then
            Library:Notify("Need an Asset ID", 2)
            return
        end
        if Music:AddTrack(name, artist, id) then
            Library:Notify("Added: " .. name, 2)
        end
    end),
})

ExtraBox:AddInput("MusicRemoteURL", { Text = "Remote playlist JSON URL", Default = "", Placeholder = "https://.../playlist.json" })
ExtraBox:AddButton({
    Text = "Load remote playlist",
    Func = Safe(function()
        local url = Options.MusicRemoteURL.Value
        if url == "" then
            Library:Notify("Paste a JSON URL first", 2)
            return
        end
        Library:Notify(Music:LoadRemotePlaylist(url) and "Remote playlist loaded" or "Failed, check the error log", 3)
    end),
})
ExtraBox:AddButton({ Text = "Stop music", Func = Safe(function() Music:Stop() end) })

----------------------------------------------------------------------
-- engine -> UI
----------------------------------------------------------------------
local function RefreshList()
    local dd = Options.MusicTrackList
    if not dd then return end
    local names = TrackNames()
    listReady = false
    dd:SetValues(names)
    if names[Music.Current] then dd:SetValue(names[Music.Current]) end
    listReady = true
end

Music:On("PlaylistChanged", RefreshList)

Music:On("TrackChanged", function(track, idx)
    nowLabel:SetText(track.Name .. "\n" .. track.Artist)
    local dd = Options.MusicTrackList
    local names = TrackNames()
    if dd and names[idx] and dd.Value ~= names[idx] then
        listReady = false
        dd:SetValue(names[idx])
        listReady = true
    end
end)

Music:On("Progress", function(ratio, pos, len)
    timeLabel:SetText(fmt(pos) .. " / " .. fmt(len))
    if os.clock() - lastUserSeek > 0.6 and Options.MusicSeek then
        syncSeek = true
        pcall(function() Options.MusicSeek:SetValue(math.floor(ratio * 100)) end)
        syncSeek = false
    end
end)

Music:On("Volume", function(v)
    if Options.MusicVol then
        syncVol = true
        pcall(function() Options.MusicVol:SetValue(math.floor(v * 100 + 0.5)) end)
        syncVol = false
    end
end)

listReady = true

return {
    Name = "Music",
    Version = "1.1",
    Unload = function()
        pcall(function() Music:Destroy() end)
        env.LunyxMusic = nil
    end,
}
