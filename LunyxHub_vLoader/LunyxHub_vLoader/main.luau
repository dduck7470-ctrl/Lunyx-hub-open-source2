--[[
    Lunyx Hub  |  multi-loader core

    Run:   loadstring(game:HttpGet(BASE_URL .. "main.luau"))()
    Dev:   copy this folder into your executor workspace as  LunyxHub/
           files found there win over the remote copy (see Config.LocalDir).

    What it does
      1. builds the Obsidian window once (title bar with minimize / close),
      2. reads core/Registry.luau and picks the hub for game.PlaceId / game.GameId,
      3. runs that module, then the Shared ones (Music),
      4. adds the Settings tab last (configs are saved per game),
      5. tears everything down in reverse order on close, panic key or reload.

    Overrides without editing this file:
      getgenv().LunyxConfig = { BaseUrl = "...", LocalDir = "...", OnStage = function(text, fraction) end }
]]

local env = (getgenv and getgenv()) or _G
if env.LunyxHubUnload then
    pcall(env.LunyxHubUnload)
end

----------------------------------------------------------------------
-- Config
----------------------------------------------------------------------
local Config = {
    BaseUrl     = "https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/", -- FILL: where this folder is hosted
    LocalDir    = "LunyxHub/",
    ObsidianUrl = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/",
    Title       = "Lunyx Hub",
    Version     = "3.0",
    OnStage     = nil, -- function(text, fraction): plug a loading screen here later
}
if type(env.LunyxConfig) == "table" then
    for k, v in pairs(env.LunyxConfig) do Config[k] = v end
end

----------------------------------------------------------------------
-- Error sink (same format as vMusic, see ERRORS.md)
----------------------------------------------------------------------
env.LunyxErrors    = env.LunyxErrors or {}
env.LunyxLastError = nil

local function PushError(src, msg, full)
    local entry = {
        t    = os.clock(),
        src  = src or "Core",
        msg  = tostring(msg),
        full = full and tostring(full) or nil,
    }
    table.insert(env.LunyxErrors, entry)
    if #env.LunyxErrors > 100 then table.remove(env.LunyxErrors, 1) end
    env.LunyxLastError = entry.msg
    warn("[Lunyx][" .. entry.src .. "] " .. entry.msg .. (entry.full and (" | " .. entry.full) or ""))
end

local function Stage(text, fraction)
    if type(Config.OnStage) == "function" then
        pcall(Config.OnStage, text, fraction)
    end
end

----------------------------------------------------------------------
-- Services
----------------------------------------------------------------------
local cloneref = cloneref or function(o) return o end
local function Svc(name)
    local ok, s = pcall(function() return cloneref(game:GetService(name)) end)
    return ok and s or nil
end

local Players         = Svc("Players")
local RunService      = Svc("RunService")
local UIS             = Svc("UserInputService")
local TeleportService = Svc("TeleportService")
local HttpService     = Svc("HttpService")
local StatsSvc        = Svc("Stats")
local VirtualUser     = Svc("VirtualUser")
local LP              = Players.LocalPlayer

----------------------------------------------------------------------
-- Source loading (local workspace first, then remote)
----------------------------------------------------------------------
local function ReadSource(path)
    if type(isfile) == "function" and type(readfile) == "function" then
        local p = Config.LocalDir .. path
        local ok, has = pcall(isfile, p)
        if ok and has then
            local ok2, body = pcall(readfile, p)
            if ok2 and type(body) == "string" and #body > 0 then return body, "local" end
        end
    end
    local ok, body = pcall(function() return game:HttpGet(Config.BaseUrl .. path) end)
    if ok and type(body) == "string" and #body > 0 then return body, "remote" end
    return nil, tostring(body)
end

-- returns ok, result_or_error, origin
local function LoadFile(path, ...)
    local src, how = ReadSource(path)
    if not src then return false, "cannot read " .. path .. ": " .. tostring(how) end
    local fn, cerr = loadstring(src, "=" .. path)
    if not fn then return false, "compile error in " .. path .. ": " .. tostring(cerr) end
    local ok, res = pcall(fn, ...)
    if not ok then return false, "runtime error in " .. path .. ": " .. tostring(res) end
    return true, res, how
end

----------------------------------------------------------------------
-- Obsidian
----------------------------------------------------------------------
Stage("Loading UI library", 0.05)
local function FetchObsidian(path)
    local ok, res = pcall(function()
        return loadstring(game:HttpGet(Config.ObsidianUrl .. path))()
    end)
    if not ok then
        PushError("Core", "Failed to fetch Obsidian: " .. path, res)
        return nil
    end
    return res
end

local Library = FetchObsidian("Library.lua")
if not Library then
    PushError("Core", "Obsidian Library missing, cannot continue")
    return
end
local ThemeManager = FetchObsidian("addons/ThemeManager.lua")
local SaveManager  = FetchObsidian("addons/SaveManager.lua")
local Options, Toggles = Library.Options, Library.Toggles

----------------------------------------------------------------------
-- Registry -> which hub for this game
----------------------------------------------------------------------
Stage("Detecting game", 0.15)
local DefaultRegistry = {
    Games = {},
    Fallback = { Name = "Universal", Module = "modules/Universal.luau" },
    Shared = { "modules/Music.luau" },
}
local okR, Registry = LoadFile("core/Registry.luau")
if not okR or type(Registry) ~= "table" then
    PushError("Core", "Registry unavailable, using built-in fallback", Registry)
    Registry = DefaultRegistry
end

local function ResolveGame(reg)
    for _, g in ipairs(reg.Games or {}) do
        for _, id in ipairs(g.PlaceIds or {}) do
            if id == game.PlaceId then return g, "PlaceId" end
        end
        for _, id in ipairs(g.UniverseIds or {}) do
            if id == game.GameId then return g, "UniverseId" end
        end
    end
    return reg.Fallback or DefaultRegistry.Fallback, "fallback"
end

local Entry, MatchedBy = ResolveGame(Registry)
local function Slug(s) return (tostring(s):lower():gsub("[^%w]+", "_")) end

----------------------------------------------------------------------
-- Window
----------------------------------------------------------------------
Library.ForceCheckbox = false
Library.ShowToggleFrameInKeybinds = true
pcall(function() Library.Scheme.AccentColor = Color3.fromRGB(138, 92, 255) end)

local Window = Library:CreateWindow({
    Title = Config.Title,
    Footer = "v" .. Config.Version .. "  |  " .. Entry.Name .. "  |  RightShift = menu",
    NotifySide = "Right",
    ShowCustomCursor = true,
    Size = UDim2.fromOffset(780, 600),
    CornerRadius = 6,
})

local Minimized, Pill = false, nil

-- title bar controls: minimize (collapses to a draggable pill) + close (confirm, then unload)
local function BuildChrome()
    local main = Library.ScreenGui and Library.ScreenGui:FindFirstChild("Main")
    if not main then return end
    local topbar
    for _, ch in ipairs(main:GetChildren()) do
        if ch:IsA("Frame") and ch.Size.X.Scale == 1 and ch.Size.Y.Offset == 48 then
            topbar = ch
            break
        end
    end
    if not topbar then return end

    local search = topbar:FindFirstChildOfClass("TextBox")
    if search then
        local sz = UDim2.new(0.7, -57 - 66, 1, -16)
        search.Size = sz
        local reg = Library.DPIRegistry and Library.DPIRegistry[search]
        if reg then reg.Size = sz end
    end

    local holder = Instance.new("Frame")
    holder.BackgroundTransparency = 1
    holder.AnchorPoint = Vector2.new(1, 0.5)
    holder.Position = UDim2.new(1, -44, 0.5, 0)
    holder.Size = UDim2.fromOffset(58, 26)
    holder.Parent = topbar
    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.Padding = UDim.new(0, 6)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = holder

    local function MakeBtn(iconName, order, hover, onClick)
        local b = Instance.new("TextButton")
        b.AutoButtonColor = false
        b.Text = ""
        b.Size = UDim2.fromOffset(26, 26)
        b.BackgroundColor3 = Library.Scheme.MainColor
        b.BorderSizePixel = 0
        b.LayoutOrder = order
        b.Parent = holder
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 5)
        corner.Parent = b
        local stroke = Instance.new("UIStroke")
        stroke.Color = Library.Scheme.OutlineColor
        stroke.Parent = b
        local icon = Library:GetIcon(iconName)
        local img = Instance.new("ImageLabel")
        img.BackgroundTransparency = 1
        img.AnchorPoint = Vector2.new(0.5, 0.5)
        img.Position = UDim2.fromScale(0.5, 0.5)
        img.Size = UDim2.fromOffset(14, 14)
        img.ImageColor3 = Library.Scheme.FontColor
        if icon then
            img.Image = icon.Url
            img.ImageRectOffset = icon.ImageRectOffset
            img.ImageRectSize = icon.ImageRectSize
        end
        img.Parent = b
        b.MouseEnter:Connect(function() b.BackgroundColor3 = hover end)
        b.MouseLeave:Connect(function() b.BackgroundColor3 = Library.Scheme.MainColor end)
        b.MouseButton1Click:Connect(function() onClick(b) end)
        return b
    end

    MakeBtn("minus", 1, Library.Scheme.AccentColor, function()
        Minimized = true
        Library:Toggle(false)
    end)

    local armedAt = 0
    MakeBtn("x", 2, Color3.fromRGB(200, 60, 60), function(btn)
        local now = os.clock()
        if now - armedAt < 2.5 then
            Library:Unload()
        else
            armedAt = now
            btn.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
            Library:Notify({ Title = "Close hub", Description = "Click the X again to unload everything.", Time = 2.5 })
        end
    end)

    Pill = Library:AddDraggableButton("  " .. Config.Title .. "  ", function() Library:Toggle(true) end)
    Pill.Button.Visible = false
end
local okC, errC = pcall(BuildChrome)
if not okC then PushError("Core", "Title bar controls failed (hub still works, use RightShift)", errC) end

----------------------------------------------------------------------
-- Context handed to every module
----------------------------------------------------------------------
local Loaded, Order, UnloadFns = {}, {}, {}

local Ctx = {
    Env = env, Config = Config, Library = Library, Options = Options, Toggles = Toggles,
    Window = Window,
    Game = { Name = Entry.Name, PlaceId = game.PlaceId, GameId = game.GameId },
    Err = PushError, Stage = Stage,
}

function Ctx.AddTab(name, icon) return Window:AddTab(name, icon) end
function Ctx.Give(conn) Library:GiveSignal(conn) return conn end
function Ctx.OnUnload(fn) table.insert(UnloadFns, fn) end

function Ctx.Use(name)
    local path = name:find("/", 1, true) and name or ("modules/" .. name .. ".luau")
    if Loaded[path] ~= nil then return Loaded[path] or nil end
    Loaded[path] = false -- cycle / failure guard
    local ok, mod, how = LoadFile(path, Ctx)
    if not ok then
        PushError("Core", "Module failed: " .. path, mod)
        Library:Notify({ Title = "Module failed", Description = path .. " (see error log)", Time = 5 })
        return nil
    end
    if type(mod) ~= "table" then mod = { Name = path } end
    mod._path, mod._how = path, how
    Loaded[path] = mod
    table.insert(Order, mod)
    return mod
end

----------------------------------------------------------------------
-- Hub tab (first)
----------------------------------------------------------------------
local Tabs = { Hub = Window:AddTab("Hub", "house") }

local FpsAcc, FpsFrames, Fps = 0, 0, 60
local function PingMs()
    local ok, v = pcall(function() return StatsSvc.Network.ServerStatsItem["Data Ping"]:GetValue() end)
    return ok and math.floor(v + 0.5) or 0
end

local LastText = {}
local function SetIf(label, text)
    if label and LastText[label] ~= text then
        LastText[label] = text
        label:SetText(text)
    end
end

local function ServerHop()
    Library:Notify("Searching for a server...", 3)
    task.spawn(function()
        local ok, body = pcall(function()
            return game:HttpGet("https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100")
        end)
        if not ok then Library:Notify("Server list request failed.", 4) return end
        local ok2, data = pcall(function() return HttpService:JSONDecode(body) end)
        local pick
        if ok2 and data and data.data then
            local most = Options.HopMode and Options.HopMode.Value == "Most players"
            for _, s in ipairs(data.data) do
                if s.id ~= game.JobId and s.playing < s.maxPlayers then
                    if not pick or (most and s.playing > pick.playing) or (not most and s.playing < pick.playing) then
                        pick = s
                    end
                end
            end
        end
        if not pick then Library:Notify("No other server found.", 4) return end
        pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, pick.id, LP) end)
    end)
end

do
    local G = Tabs.Hub:AddLeftGroupbox("Game")
    G:AddLabel("HubGame", { Text = "...", DoesWrap = true })
    G:AddButton({
        Text = "Copy Universe ID",
        Func = function()
            if setclipboard then
                setclipboard(tostring(game.GameId))
                Library:Notify("Universe ID copied (use it in Registry.UniverseIds).", 3)
            else
                Library:Notify("Executor has no setclipboard.", 3)
            end
        end,
    })
    G:AddButton({
        Text = "Reload hub",
        DoubleClick = true,
        Tooltip = "Unloads and runs main.luau again (re-reads Registry and modules)",
        Func = function()
            local src = ReadSource("main.luau")
            Library:Unload()
            if src then
                task.defer(function()
                    local fn, err = loadstring(src, "=main.luau")
                    if fn then fn() else warn("[Lunyx] reload failed: " .. tostring(err)) end
                end)
            else
                warn("[Lunyx] reload failed: main.luau unreachable")
            end
        end,
    })

    local S = Tabs.Hub:AddLeftGroupbox("Session")
    S:AddLabel("HubSession", { Text = "...", DoesWrap = true })
    S:AddDropdown("HopMode", { Text = "Server hop target", Values = { "Fewest players", "Most players" }, Default = "Fewest players" })
    S:AddButton({ Text = "Server hop", DoubleClick = true, Func = ServerHop })
    S:AddButton({
        Text = "Copy Job ID",
        Func = function()
            if setclipboard then
                setclipboard(game.JobId)
                Library:Notify("Job ID copied.", 2)
            else
                Library:Notify("Executor has no setclipboard.", 3)
            end
        end,
    })
    S:AddButton({
        Text = "Rejoin server",
        DoubleClick = true,
        Func = function()
            pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP) end)
        end,
    })

    local M = Tabs.Hub:AddRightGroupbox("Modules")
    M:AddLabel("HubModules", { Text = "loading...", DoesWrap = true })

    local SF = Tabs.Hub:AddRightGroupbox("Safety")
    SF:AddLabel("Panic key (unloads instantly)"):AddKeyPicker("PanicKey", {
        Default = "None", Mode = "Toggle", NoUI = true, Text = "Panic",
        Callback = function() Library:Unload() end,
    })
    SF:AddButton({ Text = "Panic: unload now", DoubleClick = true, Risky = true, Func = function() Library:Unload() end })
    SF:AddToggle("AntiAFK", { Text = "Anti-AFK", Default = true })
    SF:AddToggle("FpsCapEnabled", { Text = "FPS cap", Default = false })
    SF:AddSlider("FpsCapValue", { Text = "Cap", Default = 144, Min = 30, Max = 360, Rounding = 0 })
    local function ApplyCap()
        if type(setfpscap) == "function" then
            setfpscap(Toggles.FpsCapEnabled.Value and Options.FpsCapValue.Value or 60)
        end
    end
    Toggles.FpsCapEnabled:OnChanged(ApplyCap)
    Options.FpsCapValue:OnChanged(ApplyCap)

    local D = Tabs.Hub:AddRightGroupbox("Diagnostics")
    D:AddLabel("HubErrors", { Text = "errors: 0", DoesWrap = true })
    D:AddButton({
        Text = "Print error log",
        Func = function()
            local errs = env.LunyxErrors or {}
            warn("=== Lunyx errors (" .. #errs .. ") ===")
            for _, e in ipairs(errs) do
                warn(string.format("[%0.1f] %s: %s", e.t, e.src, e.msg))
            end
            Library:Notify("Printed " .. #errs .. " errors to the console", 3)
        end,
    })
    D:AddButton({
        Text = "Clear error log",
        Func = function()
            env.LunyxErrors, env.LunyxLastError = {}, nil
            Library:Notify("Error log cleared", 2)
        end,
    })
end

local function RefreshModulesLabel()
    local lines = {}
    for _, m in ipairs(Order) do
        lines[#lines + 1] = string.format("%s v%s  (%s)", tostring(m.Name or m._path), tostring(m.Version or "?"), m._how or "?")
    end
    SetIf(Options.HubModules, #lines > 0 and table.concat(lines, "\n") or "none")
end

----------------------------------------------------------------------
-- Core loops: pill, session info, anti-AFK
----------------------------------------------------------------------
local Running = true
local InfoAcc = 0

Library:GiveSignal(RunService.Heartbeat:Connect(function(dt)
    if not Running then return end
    if Pill then
        Pill.Button.Visible = Minimized and not Library.Toggled
        if Library.Toggled then Minimized = false end
    end

    FpsFrames = FpsFrames + 1
    FpsAcc = FpsAcc + dt
    if FpsAcc >= 0.5 then
        Fps = math.floor(FpsFrames / FpsAcc + 0.5)
        FpsFrames, FpsAcc = 0, 0
        SetIf(Options.HubSession, string.format("FPS: %d\nPing: %d ms\nPlayers: %d / %d\nJob ID: %s",
            Fps, PingMs(), #Players:GetPlayers(), Players.MaxPlayers, string.sub(game.JobId, 1, 18)))
        SetIf(Options.HubErrors, "errors logged: " .. #(env.LunyxErrors or {}) .. "\nlast: " .. tostring(env.LunyxLastError or "none"))
    end
end))

Library:GiveSignal(LP.Idled:Connect(function()
    if Running and Toggles.AntiAFK and Toggles.AntiAFK.Value and VirtualUser then
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end))

----------------------------------------------------------------------
-- Load hubs
----------------------------------------------------------------------
Stage("Loading " .. Entry.Name, 0.4)
local gameMod = Ctx.Use(Entry.Module)
if not gameMod and Entry.Module ~= (Registry.Fallback or DefaultRegistry.Fallback).Module then
    PushError("Core", Entry.Name .. " hub failed, falling back to Universal")
    Ctx.Use((Registry.Fallback or DefaultRegistry.Fallback).Module)
end

local shared = Registry.Shared or DefaultRegistry.Shared
for i, path in ipairs(shared) do
    Stage("Loading " .. path, 0.6 + 0.2 * (i / math.max(#shared, 1)))
    Ctx.Use(path)
end

SetIf(Options.HubGame, string.format("Game: %s\nMatched by: %s\nPlace ID: %d\nUniverse ID: %d\nHub: %s",
    Entry.Name, MatchedBy, game.PlaceId, game.GameId, Entry.Module))
RefreshModulesLabel()

----------------------------------------------------------------------
-- Settings (last tab; configs are per game)
----------------------------------------------------------------------
Stage("Finalizing", 0.9)
do
    local Tab = Window:AddTab("UI Settings", "settings")
    local Menu = Tab:AddLeftGroupbox("Menu")
    Menu:AddToggle("KeybindMenuOpen", {
        Default = Library.KeybindFrame and Library.KeybindFrame.Visible or false,
        Text = "Open keybind menu",
        Callback = function(v) if Library.KeybindFrame then Library.KeybindFrame.Visible = v end end,
    })
    Menu:AddToggle("ShowCustomCursor", {
        Text = "Custom cursor", Default = true,
        Callback = function(v) Library.ShowCustomCursor = v end,
    })
    Menu:AddDropdown("NotificationSide", {
        Values = { "Left", "Right" }, Default = "Right", Text = "Notification side",
        Callback = function(v) Library:SetNotifySide(v) end,
    })
    Menu:AddDropdown("DPIDropdown", {
        Values = { "50%", "75%", "100%", "125%", "150%", "175%", "200%" }, Default = "100%", Text = "DPI scale",
        Callback = function(v) Library:SetDPIScale(tonumber((v:gsub("%%", "")))) end,
    })
    Menu:AddDivider()
    Menu:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "RightShift", NoUI = true, Text = "Menu keybind" })
    Menu:AddButton("Unload", function() Library:Unload() end)
    Library.ToggleKeybind = Options.MenuKeybind

    if ThemeManager and SaveManager then
        ThemeManager:SetLibrary(Library)
        SaveManager:SetLibrary(Library)
        SaveManager:IgnoreThemeSettings()
        SaveManager:SetIgnoreIndexes({
            "MenuKeybind", "PanicKey", "Whitelist", "SpecTarget", "SpecEnabled",
            "MusicSeek", "MusicTrackList", "MusicNewName", "MusicNewArtist", "MusicNewId", "MusicRemoteURL",
        })
        ThemeManager:SetFolder("LunyxHub")
        SaveManager:SetFolder("LunyxHub/" .. Slug(Entry.Name))
        SaveManager:BuildConfigSection(Tab)
        ThemeManager:ApplyToTab(Tab)
        SaveManager:LoadAutoloadConfig()
    else
        PushError("Core", "ThemeManager / SaveManager missing, configs disabled")
    end
end

----------------------------------------------------------------------
-- Unload
----------------------------------------------------------------------
local Cleaned = false
local function Cleanup()
    if Cleaned then return end
    Cleaned = true
    Running = false
    for i = #Order, 1, -1 do
        local m = Order[i]
        if type(m.Unload) == "function" then
            local ok, err = pcall(m.Unload)
            if not ok then PushError("Core", "Unload failed: " .. tostring(m.Name or m._path), err) end
        end
    end
    for _, fn in ipairs(UnloadFns) do pcall(fn) end
    env.LunyxHubUnload = nil
end

Library:OnUnload(Cleanup)
env.LunyxHubUnload = function()
    if not Library.Unloaded then
        Library:Unload()
    else
        Cleanup()
    end
end

Stage("Ready", 1)
Library:Notify({
    Title = Config.Title,
    Description = Entry.Name .. " hub loaded. RightShift = menu.",
    Time = 4,
})
print("[Lunyx] ready | " .. Entry.Name .. " | errors -> getgenv().LunyxErrors")
