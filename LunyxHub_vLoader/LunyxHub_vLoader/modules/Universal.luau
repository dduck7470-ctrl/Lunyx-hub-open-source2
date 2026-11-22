--[[
    Lunyx Hub  |  Universal module (loaded by main.luau)
    Receives the loader context as the chunk argument (`...`) and returns
    { Name, Version, Unload }.

    Modules
      Aim      : Aimbot, Cursor Follow, Silent Aim, target filters + whitelist
      Combat   : Auto Clicker, Triggerbot, Kill Aura, Hitbox Expander
      Visuals  : ESP (box, bones, meters/studs, health, silhouette, tracers,
                 head dot, look line, off-screen arrows, tool), Radar,
                 Crosshair, Fullbright, FOV
      Player   : WalkSpeed, JumpPower, Infinite Jump, Noclip, Fly, Anti-void,
                 Click TP, Spectate, Teleport, player inspector, Rejoin
      HUD      : Watermark, Target HUD + marker, proximity alert, join/leave
    Menu chrome, Settings, Anti-AFK, panic key, FPS cap and server hop live in
    the Core (main.luau).

    Needs an executor with: Drawing, loadstring, game:HttpGet.
    Silent Aim needs hookmetamethod + getnamecallmethod + checkcaller.
    Cursor Follow needs mousemoverel (or mousemoveabs).
    Kill Aura "Touch" method needs firetouchinterest.
]]

local Ctx = ...
local env = Ctx.Env

----------------------------------------------------------------------
-- Services / capabilities
----------------------------------------------------------------------
local cloneref = cloneref or function(o) return o end
local function Svc(name)
    local ok, s = pcall(function() return cloneref(game:GetService(name)) end)
    return ok and s or nil
end

local Players         = Svc("Players")
local RunService      = Svc("RunService")
local UIS             = Svc("UserInputService")
local Workspace       = Svc("Workspace")
local Lighting        = Svc("Lighting")
local CoreGui         = Svc("CoreGui")
local VIM             = Svc("VirtualInputManager")
local VirtualUser     = Svc("VirtualUser")
local TeleportService = Svc("TeleportService")
local StatsSvc        = Svc("Stats")
local HttpService     = Svc("HttpService")

local HAS_DRAW = pcall(function()
    local d = Drawing.new("Line")
    d:Remove()
end)
local HAS_HOOK    = type(hookmetamethod) == "function" and type(getnamecallmethod) == "function" and type(checkcaller) == "function"
local HAS_MOVEREL = type(mousemoverel) == "function"
local HAS_MOVEABS = type(mousemoveabs) == "function"
local HAS_CLICK   = type(mouse1click) == "function"
local HAS_FTI     = type(firetouchinterest) == "function"
local newcc       = newcclosure or function(f) return f end

----------------------------------------------------------------------
-- Library
----------------------------------------------------------------------
local Library = Ctx.Library
local Options = Ctx.Options
local Toggles = Ctx.Toggles

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local LP      = Players.LocalPlayer
local Camera  = Workspace.CurrentCamera
local Mouse   = LP:GetMouse()
local Running = true

local STUD_TO_M = 0.28

-- values read by the (install-once) metamethod hooks
local Shared = env.__LunyxShared
if not Shared then
    Shared = {}
    env.__LunyxShared = Shared
end
Shared.Active  = false
Shared.Pos     = Vector3.zero
Shared.Part    = nil
Shared.Chance  = 100
Shared.Methods = { Hit = true, Raycast = true, FindPartOnRay = true, ScreenPoint = true }
Shared.Mouse   = Mouse
Shared.Camera  = Camera
Shared.Workspace = Workspace
local SilTarget = nil

-- option accessors
local function On(idx)
    local t = Toggles[idx]
    return t ~= nil and t.Value == true
end
local function Val(idx, def)
    local o = Options[idx]
    if o == nil or o.Value == nil then return def end
    return o.Value
end
local function KeyDown(idx)
    local o = Options[idx]
    return o ~= nil and o:GetState() == true
end
local function InMulti(idx, name)
    local o = Options[idx]
    return o ~= nil and type(o.Value) == "table" and o.Value[name] == true
end

-- drawing pool
local Drawings = {}
local function D(class, props)
    local d = Drawing.new(class)
    for k, v in pairs(props) do d[k] = v end
    Drawings[d] = true
    return d
end
local function Kill(d)
    if d then
        Drawings[d] = nil
        pcall(function() d:Remove() end)
    end
end

----------------------------------------------------------------------
-- Character helpers
----------------------------------------------------------------------
local function Hum(c)  return c and c:FindFirstChildOfClass("Humanoid") end
local function Root(c)
    if not c then return nil end
    return c:FindFirstChild("HumanoidRootPart") or c:FindFirstChild("Torso")
        or c:FindFirstChild("UpperTorso") or c.PrimaryPart
end
local function Alive(c)
    local h = Hum(c)
    return h ~= nil and h.Health > 0
end

local FriendCache = {}
local function IsFriend(p)
    local v = FriendCache[p.UserId]
    if v == nil then
        FriendCache[p.UserId] = false
        task.spawn(function()
            local ok, r = pcall(function() return LP:IsFriendsWith(p.UserId) end)
            FriendCache[p.UserId] = ok and r or false
        end)
        return false
    end
    return v
end

local function SameTeam(p)
    if p.Team ~= nil and LP.Team ~= nil then
        return p.Team == LP.Team
    end
    return false
end

local function Whitelisted(p)
    local o = Options.Whitelist
    if not o or type(o.Value) ~= "table" then return false end
    return o.Value[p] == true or o.Value[p.Name] == true
end

-- global combat filter
local function Valid(p)
    if p == LP or Whitelisted(p) then return false end
    if On("FTeam") and SameTeam(p) then return false end
    if On("FFriends") and IsFriend(p) then return false end
    local c = p.Character
    if not c or not Alive(c) then return false end
    if On("FForceField") and c:FindFirstChildOfClass("ForceField") then return false end
    return true
end

local function PlayerFromPart(part)
    local m = part
    while m and m ~= Workspace do
        local pl = Players:GetPlayerFromCharacter(m)
        if pl then return pl end
        m = m.Parent
    end
    return nil
end

local WallParams = RaycastParams.new()
WallParams.FilterType = Enum.RaycastFilterType.Exclude
WallParams.IgnoreWater = true
WallParams.RespectCanCollide = true

local function Visible(origin, part, char)
    WallParams.FilterDescendantsInstances = { LP.Character, char, Camera }
    return Workspace:Raycast(origin, part.Position - origin, WallParams) == nil
end

----------------------------------------------------------------------
-- Aim parts / target selection
----------------------------------------------------------------------
local ClosestList = {
    "Head", "UpperTorso", "Torso", "HumanoidRootPart", "LowerTorso",
    "LeftUpperArm", "RightUpperArm", "Left Arm", "Right Arm",
    "LeftUpperLeg", "RightUpperLeg", "Left Leg", "Right Leg",
}
local RandomCache = setmetatable({}, { __mode = "k" })

local function FindPart(c, names)
    for _, n in ipairs(names) do
        local p = c:FindFirstChild(n)
        if p and p:IsA("BasePart") then return p end
    end
    return nil
end

local function PickPart(c, mode, mousePos)
    if mode == "Head" then
        return FindPart(c, { "Head" }) or Root(c)
    elseif mode == "Torso" then
        return FindPart(c, { "UpperTorso", "Torso" }) or Root(c)
    elseif mode == "Root" then
        return Root(c)
    elseif mode == "Closest" then
        local best, bestD
        for _, n in ipairs(ClosestList) do
            local p = c:FindFirstChild(n)
            if p and p:IsA("BasePart") then
                local sp, on = Camera:WorldToViewportPoint(p.Position)
                if on then
                    local d = (Vector2.new(sp.X, sp.Y) - mousePos).Magnitude
                    if not bestD or d < bestD then best, bestD = p, d end
                end
            end
        end
        return best or Root(c)
    else -- Random (re-rolled every 0.35s per target)
        local e = RandomCache[c]
        local now = os.clock()
        if not e or now - e.t > 0.35 or not e.p.Parent then
            local n = ClosestList[math.random(1, #ClosestList)]
            e = { t = now, p = c:FindFirstChild(n) or Root(c) }
            RandomCache[c] = e
        end
        return e.p
    end
end

-- cfg: Part, Sort, Fov, MaxDist, Wall
local function GetTarget(cfg)
    local mousePos = UIS:GetMouseLocation()
    local camPos = Camera.CFrame.Position
    local best, bestScore

    for _, p in ipairs(Players:GetPlayers()) do
        if Valid(p) then
            local c = p.Character
            local root = Root(c)
            if root then
                local dist = (root.Position - camPos).Magnitude
                if dist <= cfg.MaxDist then
                    local part = PickPart(c, cfg.Part, mousePos)
                    if part then
                        local sp, on = Camera:WorldToViewportPoint(part.Position)
                        if on and sp.Z > 0 then
                            local scr = Vector2.new(sp.X, sp.Y)
                            local fd = (scr - mousePos).Magnitude
                            if fd <= cfg.Fov and (not cfg.Wall or Visible(camPos, part, c)) then
                                local score
                                if cfg.Sort == "Distance" then
                                    score = dist
                                elseif cfg.Sort == "Health" then
                                    score = Hum(c).Health
                                else
                                    score = fd
                                end
                                if not bestScore or score < bestScore then
                                    bestScore = score
                                    best = { Player = p, Char = c, Part = part, Screen = scr, Dist = dist }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return best
end

local function StillValid(t, cfg)
    if not t or not t.Part or not t.Part.Parent then return false end
    if not Valid(t.Player) then return false end
    local sp, on = Camera:WorldToViewportPoint(t.Part.Position)
    if not on or sp.Z <= 0 then return false end
    if cfg.Wall and not Visible(Camera.CFrame.Position, t.Part, t.Char) then return false end
    return true
end

local function Predict(part, amt)
    if amt and amt > 0 then
        return part.Position + part.AssemblyLinearVelocity * amt
    end
    return part.Position
end

local function CfgAim()
    return {
        Part = Val("AimPart", "Head"), Sort = Val("AimSort", "Cursor"),
        Fov = Val("AimFov", 150), MaxDist = Val("AimMaxDist", 1500), Wall = On("AimWall"),
    }
end
local function CfgCur()
    return {
        Part = Val("CurPart", "Head"), Sort = "Cursor",
        Fov = Val("CurFov", 200), MaxDist = Val("CurMaxDist", 1500), Wall = On("CurWall"),
    }
end
local function CfgSil()
    return {
        Part = Val("SilPart", "Head"), Sort = Val("SilSort", "Cursor"),
        Fov = Val("SilFov", 150), MaxDist = Val("SilMaxDist", 1500), Wall = On("SilWall"),
    }
end

----------------------------------------------------------------------
-- Aimbot (camera)
----------------------------------------------------------------------
local Aim = { Target = nil }

local function RunAimbot(dt)
    if not (On("AimEnabled") and KeyDown("AimKey")) or Library.Toggled then
        Aim.Target = nil
        return
    end
    local cfg = CfgAim()
    local t = Aim.Target
    if not (t and On("AimSticky") and StillValid(t, cfg)) then
        t = GetTarget(cfg)
    end
    Aim.Target = t
    if t then
        local pos = Predict(t.Part, Val("AimPred", 0))
        local sm = math.clamp(Val("AimSmooth", 0.3), 0, 0.98)
        local alpha = (sm <= 0) and 1 or (1 - sm ^ (dt * 60))
        local cf = Camera.CFrame
        Camera.CFrame = cf:Lerp(CFrame.lookAt(cf.Position, pos), math.clamp(alpha, 0.01, 1))
    end
end

----------------------------------------------------------------------
-- Cursor follow (moves the real cursor)
----------------------------------------------------------------------
local Cur = { Target = nil, Acc = Vector2.new(0, 0) }

local function Trunc(n)
    if n >= 0 then return math.floor(n) end
    return math.ceil(n)
end

local function RunCursor(dt)
    if not (On("CurEnabled") and KeyDown("CurKey")) or Library.Toggled then
        Cur.Target = nil
        Cur.Acc = Vector2.new(0, 0)
        return
    end
    if not (HAS_MOVEREL or HAS_MOVEABS) then return end
    local cfg = CfgCur()
    local t = GetTarget(cfg)
    Cur.Target = t
    if not t then return end

    local pos = Predict(t.Part, Val("CurPred", 0))
    local sp = Camera:WorldToViewportPoint(pos)
    local mouse = UIS:GetMouseLocation()
    local delta = Vector2.new(sp.X, sp.Y) - mouse
    if delta.Magnitude < 1.5 then return end

    local sm = math.clamp(Val("CurSmooth", 0.6), 0, 0.98)
    local alpha = (sm <= 0) and 1 or (1 - sm ^ (dt * 60))
    local mv = delta * math.clamp(alpha, 0.01, 1) + Cur.Acc
    local ix, iy = Trunc(mv.X), Trunc(mv.Y)
    Cur.Acc = Vector2.new(mv.X - ix, mv.Y - iy)

    if HAS_MOVEREL then
        mousemoverel(ix, iy)
    else
        mousemoveabs(mouse.X + ix, mouse.Y + iy)
    end
end

----------------------------------------------------------------------
-- Silent aim (metamethod hooks, installed once per session)
----------------------------------------------------------------------
if HAS_HOOK and not env.__LunyxHooked then
    env.__LunyxHooked = true
    local S = Shared
    local oldIndex, oldNamecall

    local function Roll()
        return S.Chance >= 100 or math.random(1, 100) <= S.Chance
    end

    oldIndex = hookmetamethod(game, "__index", newcc(function(self, key)
        if S.Active and S.Methods.Hit and self == S.Mouse and not checkcaller() then
            if key == "Hit" then
                return CFrame.new(S.Pos)
            elseif key == "Target" then
                return S.Part
            end
        end
        return oldIndex(self, key)
    end))

    oldNamecall = hookmetamethod(game, "__namecall", newcc(function(self, ...)
        if S.Active and not checkcaller() then
            local m = getnamecallmethod()
            if self == S.Workspace then
                if m == "Raycast" and S.Methods.Raycast then
                    local n = select("#", ...)
                    local a = { ... }
                    if typeof(a[1]) == "Vector3" and typeof(a[2]) == "Vector3" and Roll() then
                        a[2] = (S.Pos - a[1]).Unit * a[2].Magnitude
                        return oldNamecall(self, table.unpack(a, 1, n))
                    end
                elseif (m == "FindPartOnRay" or m == "FindPartOnRayWithIgnoreList" or m == "FindPartOnRayWithWhitelist")
                    and S.Methods.FindPartOnRay then
                    local n = select("#", ...)
                    local a = { ... }
                    if typeof(a[1]) == "Ray" and Roll() then
                        a[1] = Ray.new(a[1].Origin, (S.Pos - a[1].Origin).Unit * a[1].Direction.Magnitude)
                        return oldNamecall(self, table.unpack(a, 1, n))
                    end
                end
            elseif self == S.Camera and S.Methods.ScreenPoint
                and (m == "ScreenPointToRay" or m == "ViewportPointToRay") then
                local r = oldNamecall(self, ...)
                if Roll() then
                    return Ray.new(r.Origin, (S.Pos - r.Origin).Unit)
                end
                return r
            end
        end
        return oldNamecall(self, ...)
    end))
end

local function UpdateSilent()
    Shared.Active = false
    SilTarget = nil
    Shared.Camera = Camera
    if not HAS_HOOK or not Running or not On("SilEnabled") or not KeyDown("SilKey") then return end

    local m = Shared.Methods
    m.Hit           = InMulti("SilMethods", "Mouse Hit/Target")
    m.Raycast       = InMulti("SilMethods", "Raycast")
    m.FindPartOnRay = InMulti("SilMethods", "FindPartOnRay")
    m.ScreenPoint   = InMulti("SilMethods", "ScreenPointToRay")
    Shared.Chance   = Val("SilChance", 100)

    local t = GetTarget(CfgSil())
    if t then
        Shared.Active = true
        Shared.Pos    = Predict(t.Part, Val("SilPred", 0))
        Shared.Part   = t.Part
        SilTarget     = t
    end
end

-- whichever aim module is currently locked on something
local function CurrentTarget()
    return Aim.Target or Cur.Target or SilTarget
end

----------------------------------------------------------------------
-- Clicking: auto clicker / triggerbot
----------------------------------------------------------------------
local function DoClick(method)
    method = method or Val("ACMethod", "Mouse")
    if method == "Tool Activate" then
        local c = LP.Character
        local tool = c and c:FindFirstChildOfClass("Tool")
        if tool then tool:Activate() end
    elseif method == "VirtualInput" or not HAS_CLICK then
        if VIM then
            local m = UIS:GetMouseLocation()
            VIM:SendMouseButtonEvent(m.X, m.Y, 0, true, game, 0)
            VIM:SendMouseButtonEvent(m.X, m.Y, 0, false, game, 0)
        end
    else
        mouse1click()
    end
end

local Clicker = { Acc = 0 }
local function RunClicker(dt)
    if not (On("ACEnabled") and KeyDown("ACKey")) or Library.Toggled then
        Clicker.Acc = 0
        return
    end
    local cps = math.max(Val("ACCps", 12), 1)
    local jitter = Val("ACJitter", 0) / 100
    local base = 1 / cps
    local interval = base
    Clicker.Acc = Clicker.Acc + dt
    local n = 0
    while Clicker.Acc >= interval and n < 6 do
        Clicker.Acc = Clicker.Acc - interval
        n = n + 1
        DoClick()
        if jitter > 0 then
            interval = base * (1 + (math.random() * 2 - 1) * jitter)
        end
    end
    if n >= 6 then Clicker.Acc = 0 end
end

local TrigParams = RaycastParams.new()
TrigParams.FilterType = Enum.RaycastFilterType.Exclude
TrigParams.IgnoreWater = true

local Trig = { Since = nil, Last = 0 }
local function RunTrigger()
    if not (On("TrigEnabled") and KeyDown("TrigKey")) or Library.Toggled then
        Trig.Since = nil
        return
    end
    local m = UIS:GetMouseLocation()
    local ray = Camera:ViewportPointToRay(m.X, m.Y)
    TrigParams.FilterDescendantsInstances = { LP.Character, Camera }
    local r = Workspace:Raycast(ray.Origin, ray.Direction * 2000, TrigParams)
    local p = r and PlayerFromPart(r.Instance)
    if p and Valid(p) and (not On("TrigHead") or r.Instance.Name == "Head") then
        local now = os.clock()
        Trig.Since = Trig.Since or now
        if now - Trig.Since >= Val("TrigDelay", 40) / 1000
            and now - Trig.Last >= Val("TrigInterval", 90) / 1000 then
            Trig.Last = now
            DoClick(Val("ACMethod", "Mouse"))
        end
    else
        Trig.Since = nil
    end
end

----------------------------------------------------------------------
-- Kill aura
----------------------------------------------------------------------
local KA = { Last = 0, RangePart = nil }

local function SetRangeSphere(show, pos, r)
    if not show then
        if KA.RangePart then KA.RangePart.Parent = nil end
        return
    end
    if not KA.RangePart then
        local p = Instance.new("Part")
        p.Shape = Enum.PartType.Ball
        p.Anchored = true
        p.CanCollide = false
        p.CanQuery = false
        p.CanTouch = false
        p.CastShadow = false
        p.Material = Enum.Material.ForceField
        p.Name = "LunyxRange"
        KA.RangePart = p
    end
    local p = KA.RangePart
    p.Size = Vector3.new(r * 2, r * 2, r * 2)
    p.CFrame = CFrame.new(pos)
    p.Color = Val("KARangeColor", Color3.fromRGB(255, 80, 80))
    p.Transparency = 0.85
    p.Parent = Camera
end

local function GetKATool(c, hum)
    local tool = c:FindFirstChildOfClass("Tool")
    if tool then return tool, true end
    if On("KAAutoEquip") then
        local bp = LP:FindFirstChildOfClass("Backpack")
        if bp then
            local want = string.lower(Val("KAToolName", ""))
            local pick
            for _, t in ipairs(bp:GetChildren()) do
                if t:IsA("Tool") then
                    if want ~= "" then
                        if string.find(string.lower(t.Name), want, 1, true) then pick = t break end
                    else
                        pick = pick or t
                    end
                end
            end
            if pick then hum:EquipTool(pick) end
        end
    end
    return nil, false
end

local function Attack(tool, tc, troot)
    if tool and InMulti("KAMethods", "Tool Activate") then
        tool:Activate()
    end
    if tool and HAS_FTI and InMulti("KAMethods", "Touch") then
        local handle = tool:FindFirstChild("Handle") or tool:FindFirstChildWhichIsA("BasePart")
        if handle then
            local parts = { tc:FindFirstChild("Head"), troot }
            for _, part in ipairs(parts) do
                if part then
                    firetouchinterest(handle, part, 0)
                    firetouchinterest(handle, part, 1)
                end
            end
        end
    end
    if InMulti("KAMethods", "Mouse Click") then
        DoClick("Mouse")
    end
end

local function RunKillAura()
    if not (On("KAEnabled") and KeyDown("KAKey")) then
        SetRangeSphere(false)
        return
    end
    local c = LP.Character
    local root, hum = Root(c), Hum(c)
    if not root or not hum or hum.Health <= 0 then
        SetRangeSphere(false)
        return
    end

    local range = Val("KARange", 15)
    SetRangeSphere(On("KAShowRange"), root.Position, range)

    local list = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if Valid(p) then
            local tc = p.Character
            local tr = Root(tc)
            if tr then
                local d = (tr.Position - root.Position).Magnitude
                if d <= range and (not On("KAWall") or Visible(root.Position, tr, tc)) then
                    list[#list + 1] = { P = p, C = tc, R = tr, D = d, H = Hum(tc).Health }
                end
            end
        end
    end
    if #list == 0 then return end

    local byHealth = Val("KASort", "Distance") == "Health"
    table.sort(list, function(a, b)
        if byHealth then return a.H < b.H end
        return a.D < b.D
    end)

    -- stick / face the primary target every frame
    local main = list[1]
    if On("KAStick") then
        local goal = main.R.CFrame * CFrame.new(0, 0, Val("KAStickDist", 3))
        root.CFrame = CFrame.lookAt(goal.Position, main.R.Position)
        root.AssemblyLinearVelocity = Vector3.zero
    elseif On("KAFace") then
        root.CFrame = CFrame.lookAt(root.Position, Vector3.new(main.R.Position.X, root.Position.Y, main.R.Position.Z))
    end

    local now = os.clock()
    if now - KA.Last < Val("KADelay", 100) / 1000 then return end

    local tool, equipped = GetKATool(c, hum)
    if not equipped and not InMulti("KAMethods", "Mouse Click") then return end
    KA.Last = now

    local maxT = Val("KAMax", 1)
    for i = 1, math.min(#list, maxT) do
        local t = list[i]
        Attack(tool, t.C, t.R)
    end
end

----------------------------------------------------------------------
-- Hitbox expander (client side)
----------------------------------------------------------------------
local Hitbox = { Orig = {} }

local function RestoreHitboxes()
    for part, o in pairs(Hitbox.Orig) do
        if part and part.Parent then
            part.Size = o.Size
            part.Transparency = o.Transparency
            part.CanCollide = o.CanCollide
        end
        Hitbox.Orig[part] = nil
    end
end

local function RunHitbox()
    if not On("HBEnabled") then
        if next(Hitbox.Orig) then RestoreHitboxes() end
        return
    end
    local size = Val("HBSize", 10)
    local partName = Val("HBPart", "HumanoidRootPart")
    local seen = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if Valid(p) then
            local part = p.Character:FindFirstChild(partName)
            if part and part:IsA("BasePart") then
                seen[part] = true
                if not Hitbox.Orig[part] then
                    Hitbox.Orig[part] = { Size = part.Size, Transparency = part.Transparency, CanCollide = part.CanCollide }
                end
                part.Size = Vector3.new(size, size, size)
                part.Transparency = Val("HBTransp", 0.7)
                part.CanCollide = false
            end
        end
    end
    for part, o in pairs(Hitbox.Orig) do
        if not seen[part] then
            if part and part.Parent then
                part.Size = o.Size
                part.Transparency = o.Transparency
                part.CanCollide = o.CanCollide
            end
            Hitbox.Orig[part] = nil
        end
    end
end

----------------------------------------------------------------------
-- ESP
----------------------------------------------------------------------
local SKEL_R15 = {
    { "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
    { "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
    { "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
    { "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
    { "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
}
local SKEL_R6 = {
    { "Head", "Torso" }, { "Torso", "Left Arm" }, { "Torso", "Right Arm" },
    { "Torso", "Left Leg" }, { "Torso", "Right Leg" },
}

local ESP = { Objs = {} }
local HLFolder

local function GetHLFolder()
    if HLFolder and HLFolder.Parent then return HLFolder end
    HLFolder = Instance.new("Folder")
    HLFolder.Name = "LunyxHL"
    local parent = (type(gethui) == "function" and gethui()) or CoreGui
    HLFolder.Parent = parent
    return HLFolder
end

local function NewESP()
    local o = {}
    o.Fill    = D("Square", { Filled = true, Visible = false, ZIndex = 1 })
    o.BoxOut  = D("Square", { Filled = false, Visible = false, Thickness = 3, Color = Color3.new(0, 0, 0), ZIndex = 2 })
    o.Box     = D("Square", { Filled = false, Visible = false, Thickness = 1, ZIndex = 3 })
    o.Corner  = {}
    for i = 1, 8 do
        o.Corner[i] = D("Line", { Visible = false, Thickness = 1, ZIndex = 3 })
    end
    o.Name    = D("Text", { Visible = false, Center = true, Outline = true, Size = 13, Font = 2, ZIndex = 5 })
    o.Dist    = D("Text", { Visible = false, Center = true, Outline = true, Size = 13, Font = 2, ZIndex = 5 })
    o.Tool    = D("Text", { Visible = false, Center = true, Outline = true, Size = 13, Font = 2, ZIndex = 5 })
    o.HpBack  = D("Square", { Filled = true, Visible = false, Color = Color3.new(0, 0, 0), ZIndex = 2 })
    o.HpBar   = D("Square", { Filled = true, Visible = false, ZIndex = 3 })
    o.HpText  = D("Text", { Visible = false, Center = true, Outline = true, Size = 12, Font = 2, ZIndex = 5 })
    o.Tracer  = D("Line", { Visible = false, Thickness = 1, ZIndex = 2 })
    o.HeadDot = D("Circle", { Visible = false, Filled = false, Thickness = 1, NumSides = 20, ZIndex = 4 })
    o.Look    = D("Line", { Visible = false, Thickness = 1, ZIndex = 4 })
    o.Arrow   = D("Triangle", { Visible = false, Filled = true, ZIndex = 4 })
    o.Bones   = {}
    for i = 1, 14 do
        o.Bones[i] = D("Line", { Visible = false, Thickness = 1, ZIndex = 3 })
    end
    return o
end

local function HideESP(o, keepHL)
    for k, v in pairs(o) do
        if k == "Corner" or k == "Bones" then
            for _, l in ipairs(v) do l.Visible = false end
        elseif k == "HL" then
            if not keepHL then v.Enabled = false end
        else
            v.Visible = false
        end
    end
end

local function DestroyESP(o)
    for k, v in pairs(o) do
        if k == "Corner" or k == "Bones" then
            for _, l in ipairs(v) do Kill(l) end
        elseif k == "HL" then
            pcall(function() v:Destroy() end)
        else
            Kill(v)
        end
    end
end

local function FmtDist(studs)
    local unit = Val("ESPUnit", "Meters")
    local m = math.floor(studs * STUD_TO_M + 0.5)
    local s = math.floor(studs + 0.5)
    if unit == "Studs" then return s .. " studs" end
    if unit == "Both" then return m .. "m (" .. s .. " studs)" end
    return m .. "m"
end

local function HealthColor(r)
    return Color3.fromRGB(255 * (1 - r), 255 * r, 40)
end

local function ProjectPart(c, name)
    local p = c:FindFirstChild(name)
    if p and p:IsA("BasePart") then
        local v = Camera:WorldToViewportPoint(p.Position)
        if v.Z > 0 then return Vector2.new(v.X, v.Y) end
    end
    return nil
end

local function UpdateESPPlayer(p, vp, camPos, mouse)
    local o = ESP.Objs[p]
    local c = p.Character
    local root = c and Root(c)
    local hum = c and Hum(c)

    local show = On("ESPEnabled") and root ~= nil and hum ~= nil and hum.Health > 0
    if show and not On("ESPTeam") and SameTeam(p) then show = false end
    local dist = 0
    if show then
        dist = (root.Position - camPos).Magnitude
        if dist > Val("ESPMaxDist", 2000) then show = false end
    end

    if not show then
        if o then HideESP(o) end
        return
    end

    if not o then
        o = NewESP()
        ESP.Objs[p] = o
    end

    -- colour
    local col = Val("ESPColor", Color3.fromRGB(255, 70, 70))
    if On("ESPTeamColor") and p.Team ~= nil then col = p.TeamColor.Color end
    if On("ESPRainbow") then col = Color3.fromHSV((os.clock() * 0.25) % 1, 0.9, 1) end
    if On("ESPVisCheck") then
        local head = c:FindFirstChild("Head") or root
        col = Visible(camPos, head, c) and Val("ESPVisColor", Color3.fromRGB(80, 255, 120))
            or Val("ESPHidColor", Color3.fromRGB(255, 70, 70))
    end

    -- silhouette (Highlight)
    if On("ESPSil") then
        local hl = o.HL
        if not hl then
            hl = Instance.new("Highlight")
            hl.Parent = GetHLFolder()
            o.HL = hl
        end
        hl.Adornee = c
        hl.Enabled = true
        hl.DepthMode = (Val("ESPSilDepth", "AlwaysOnTop") == "AlwaysOnTop")
            and Enum.HighlightDepthMode.AlwaysOnTop or Enum.HighlightDepthMode.Occluded
        hl.FillColor = On("ESPSilUseMain") and col or Val("ESPSilFill", Color3.fromRGB(255, 70, 70))
        hl.OutlineColor = On("ESPSilUseMain") and col or Val("ESPSilOutline", Color3.new(1, 1, 1))
        hl.FillTransparency = Val("ESPSilFillT", 0.5)
        hl.OutlineTransparency = Val("ESPSilOutT", 0)
    elseif o.HL then
        o.HL.Enabled = false
    end

    -- projection
    local feet = (hum.HipHeight > 0 and hum.HipHeight or 2) + root.Size.Y / 2
    local rp = Camera:WorldToViewportPoint(root.Position)
    local top = Camera:WorldToViewportPoint(root.Position + Vector3.new(0, 2.6, 0))
    local bot = Camera:WorldToViewportPoint(root.Position - Vector3.new(0, feet, 0))
    local inView = rp.Z > 0 and rp.X > -200 and rp.X < vp.X + 200 and rp.Y > -200 and rp.Y < vp.Y + 200

    if not inView then
        HideESP(o, true)
        -- off-screen arrow
        if On("ESPArrows") then
            local rel = Camera.CFrame:PointToObjectSpace(root.Position)
            local dir = Vector2.new(rel.X, rel.Z)
            if dir.Magnitude > 0 then
                dir = dir.Unit
                local center = vp / 2
                local radius = Val("ESPArrowRadius", 200)
                local sz = 12
                local pos = center + dir * radius
                local perp = Vector2.new(-dir.Y, dir.X)
                o.Arrow.PointA = pos + dir * sz
                o.Arrow.PointB = pos - dir * (sz * 0.5) + perp * (sz * 0.7)
                o.Arrow.PointC = pos - dir * (sz * 0.5) - perp * (sz * 0.7)
                o.Arrow.Color = col
                o.Arrow.Transparency = 1
                o.Arrow.Visible = true
            end
        end
        return
    end

    local h = math.abs(bot.Y - top.Y)
    local w = h * 0.6
    local x = rp.X - w / 2
    local y = math.min(top.Y, bot.Y)
    local tsize = Val("ESPTextSize", 13)

    -- box
    local boxOn = On("ESPBox")
    local style = Val("ESPBoxStyle", "Full")
    o.BoxOut.Visible = boxOn and style == "Full"
    o.Box.Visible = o.BoxOut.Visible
    if o.Box.Visible then
        o.Box.Position, o.Box.Size, o.Box.Color = Vector2.new(x, y), Vector2.new(w, h), col
        o.BoxOut.Position, o.BoxOut.Size = Vector2.new(x, y), Vector2.new(w, h)
    end
    local cornerOn = boxOn and style == "Corner"
    if cornerOn then
        local lw, lh = w / 4, h / 4
        local pts = {
            { Vector2.new(x, y), Vector2.new(x + lw, y) }, { Vector2.new(x, y), Vector2.new(x, y + lh) },
            { Vector2.new(x + w, y), Vector2.new(x + w - lw, y) }, { Vector2.new(x + w, y), Vector2.new(x + w, y + lh) },
            { Vector2.new(x, y + h), Vector2.new(x + lw, y + h) }, { Vector2.new(x, y + h), Vector2.new(x, y + h - lh) },
            { Vector2.new(x + w, y + h), Vector2.new(x + w - lw, y + h) }, { Vector2.new(x + w, y + h), Vector2.new(x + w, y + h - lh) },
        }
        for i = 1, 8 do
            local l = o.Corner[i]
            l.From, l.To, l.Color, l.Visible = pts[i][1], pts[i][2], col, true
        end
    else
        for i = 1, 8 do o.Corner[i].Visible = false end
    end

    -- fill
    o.Fill.Visible = On("ESPFill")
    if o.Fill.Visible then
        o.Fill.Position, o.Fill.Size, o.Fill.Color = Vector2.new(x, y), Vector2.new(w, h), col
        o.Fill.Transparency = Val("ESPFillT", 0.15)
    end

    -- name
    o.Name.Visible = On("ESPName")
    if o.Name.Visible then
        o.Name.Text = (p.DisplayName ~= p.Name) and (p.DisplayName .. " (@" .. p.Name .. ")") or p.Name
        o.Name.Size = tsize
        o.Name.Position = Vector2.new(rp.X, y - tsize - 3)
        o.Name.Color = Color3.new(1, 1, 1)
    end

    -- distance + tool under the box
    local below = y + h + 2
    o.Dist.Visible = On("ESPDist")
    if o.Dist.Visible then
        o.Dist.Text = FmtDist(dist)
        o.Dist.Size = tsize
        o.Dist.Position = Vector2.new(rp.X, below)
        o.Dist.Color = Color3.fromRGB(230, 230, 230)
        below = below + tsize + 1
    end
    o.Tool.Visible = false
    if On("ESPTool") then
        local tool = c:FindFirstChildOfClass("Tool")
        if tool then
            o.Tool.Visible = true
            o.Tool.Text = "[" .. tool.Name .. "]"
            o.Tool.Size = tsize
            o.Tool.Position = Vector2.new(rp.X, below)
            o.Tool.Color = Color3.fromRGB(255, 220, 120)
        end
    end

    -- health bar
    local hpOn = On("ESPHealth")
    o.HpBack.Visible, o.HpBar.Visible = hpOn, hpOn
    o.HpText.Visible = hpOn and On("ESPHealthText")
    if hpOn then
        local r = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
        o.HpBack.Position = Vector2.new(x - 6, y - 1)
        o.HpBack.Size = Vector2.new(4, h + 2)
        o.HpBar.Position = Vector2.new(x - 5, y + h * (1 - r))
        o.HpBar.Size = Vector2.new(2, h * r)
        o.HpBar.Color = HealthColor(r)
        if o.HpText.Visible then
            o.HpText.Text = tostring(math.floor(hum.Health + 0.5))
            o.HpText.Size = math.max(tsize - 1, 9)
            o.HpText.Position = Vector2.new(x - 18, y + h * (1 - r) - 6)
            o.HpText.Color = HealthColor(r)
        end
    end

    -- tracer
    o.Tracer.Visible = On("ESPTracer")
    if o.Tracer.Visible then
        local origin = Val("ESPTracerOrigin", "Bottom")
        local from
        if origin == "Top" then from = Vector2.new(vp.X / 2, 0)
        elseif origin == "Center" then from = vp / 2
        elseif origin == "Mouse" then from = mouse
        else from = Vector2.new(vp.X / 2, vp.Y) end
        o.Tracer.From, o.Tracer.To, o.Tracer.Color = from, Vector2.new(rp.X, y + h), col
    end

    -- head dot + look direction
    local head = c:FindFirstChild("Head")
    o.HeadDot.Visible = false
    o.Look.Visible = false
    if head and head:IsA("BasePart") then
        if On("ESPHeadDot") then
            local hp = ProjectPart(c, "Head")
            if hp then
                o.HeadDot.Visible = true
                o.HeadDot.Position = hp
                o.HeadDot.Radius = math.max(h * 0.07, 2)
                o.HeadDot.Color = col
            end
        end
        if On("ESPLook") then
            local a = Camera:WorldToViewportPoint(head.Position)
            local b = Camera:WorldToViewportPoint(head.Position + head.CFrame.LookVector * 5)
            if a.Z > 0 and b.Z > 0 then
                o.Look.Visible = true
                o.Look.From, o.Look.To, o.Look.Color = Vector2.new(a.X, a.Y), Vector2.new(b.X, b.Y), Color3.fromRGB(255, 255, 90)
            end
        end
    end

    -- skeleton
    local used = 0
    if On("ESPBones") then
        local list = c:FindFirstChild("UpperTorso") and SKEL_R15 or SKEL_R6
        local bcol = On("ESPBonesMain") and col or Val("ESPBonesColor", Color3.new(1, 1, 1))
        for i = 1, #list do
            local a, b = ProjectPart(c, list[i][1]), ProjectPart(c, list[i][2])
            local l = o.Bones[i]
            if a and b and l then
                l.From, l.To, l.Color, l.Visible = a, b, bcol, true
                used = i
            elseif l then
                l.Visible = false
            end
        end
    end
    for i = used + 1, #o.Bones do o.Bones[i].Visible = false end
    o.Arrow.Visible = false
end

local function UpdateESP()
    if not HAS_DRAW then return end
    local vp = Camera.ViewportSize
    local camPos = Camera.CFrame.Position
    local mouse = UIS:GetMouseLocation()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then
            local ok, err = pcall(UpdateESPPlayer, p, vp, camPos, mouse)
            if not ok and Library.NotifyOnError then warn("[LunyxHub] ESP:", err) end
        end
    end
end

local function RemoveESP(p)
    local o = ESP.Objs[p]
    if o then
        DestroyESP(o)
        ESP.Objs[p] = nil
    end
end

----------------------------------------------------------------------
-- FOV circles, crosshair, radar
----------------------------------------------------------------------
local Overlay = {}

local function UpdateOverlay()
    if not HAS_DRAW then return end
    local mouse = UIS:GetMouseLocation()
    local vp = Camera.ViewportSize

    -- FOV circles
    local function Fov(key, enabled, radius, color)
        local c = Overlay[key]
        if not c then
            c = D("Circle", { Visible = false, Filled = false, Thickness = 1, NumSides = 64, ZIndex = 6 })
            Overlay[key] = c
        end
        c.Visible = enabled
        if enabled then
            c.Position, c.Radius, c.Color = mouse, radius, color
        end
    end
    Fov("FovAim", On("AimEnabled") and On("AimShowFov"), Val("AimFov", 150), Val("AimFovColor", Color3.fromRGB(255, 255, 255)))
    Fov("FovCur", On("CurEnabled") and On("CurShowFov"), Val("CurFov", 200), Val("CurFovColor", Color3.fromRGB(120, 200, 255)))
    Fov("FovSil", On("SilEnabled") and On("SilShowFov"), Val("SilFov", 150), Val("SilFovColor", Color3.fromRGB(255, 120, 255)))

    -- crosshair
    local xh = Overlay.Cross
    if not xh then
        xh = { Lines = {}, Dot = D("Circle", { Visible = false, Filled = true, NumSides = 12, Radius = 1.5, ZIndex = 7 }) }
        for i = 1, 4 do xh.Lines[i] = D("Line", { Visible = false, ZIndex = 7 }) end
        Overlay.Cross = xh
    end
    local on = On("XhEnabled")
    local center = vp / 2
    local size, gap = Val("XhSize", 8), Val("XhGap", 4)
    local col = Val("XhColor", Color3.new(1, 1, 1))
    local dirs = { Vector2.new(1, 0), Vector2.new(-1, 0), Vector2.new(0, 1), Vector2.new(0, -1) }
    for i = 1, 4 do
        local l = xh.Lines[i]
        l.Visible = on
        if on then
            l.From = center + dirs[i] * gap
            l.To = center + dirs[i] * (gap + size)
            l.Color, l.Thickness = col, Val("XhThick", 1)
        end
    end
    xh.Dot.Visible = on and On("XhDot")
    if xh.Dot.Visible then xh.Dot.Position, xh.Dot.Color = center, col end

    -- target marker (ring on the target + line from the cursor)
    local mk = Overlay.Marker
    if not mk then
        mk = {
            Ring = D("Circle", { Visible = false, Filled = false, Thickness = 2, NumSides = 32, Radius = 9, ZIndex = 11 }),
            Line = D("Line", { Visible = false, Thickness = 1, ZIndex = 11 }),
        }
        Overlay.Marker = mk
    end
    local mt = On("TMEnabled") and CurrentTarget() or nil
    if mt and mt.Part and mt.Part.Parent then
        local sp = Camera:WorldToViewportPoint(mt.Part.Position)
        if sp.Z > 0 then
            local mc = Val("TMColor", Color3.fromRGB(255, 60, 60))
            local pos = Vector2.new(sp.X, sp.Y)
            mk.Ring.Position, mk.Ring.Color, mk.Ring.Visible = pos, mc, true
            mk.Line.From, mk.Line.To, mk.Line.Color, mk.Line.Visible = mouse, pos, mc, On("TMLine")
        else
            mk.Ring.Visible, mk.Line.Visible = false, false
        end
    else
        mk.Ring.Visible, mk.Line.Visible = false, false
    end

    -- radar
    local rd = Overlay.Radar
    if not rd then
        rd = {
            Back = D("Circle", { Visible = false, Filled = true, NumSides = 48, ZIndex = 8, Transparency = 0.5, Color = Color3.fromRGB(15, 15, 15) }),
            Ring = D("Circle", { Visible = false, Filled = false, NumSides = 48, ZIndex = 9, Thickness = 1 }),
            Me   = D("Circle", { Visible = false, Filled = true, NumSides = 12, Radius = 3, ZIndex = 10, Color = Color3.new(1, 1, 1) }),
            Dots = {},
        }
        Overlay.Radar = rd
    end
    local ron = On("RadarEnabled")
    rd.Back.Visible, rd.Ring.Visible, rd.Me.Visible = ron, ron, ron
    local used = {}
    if ron then
        local size2 = Val("RadarSize", 150)
        local range = Val("RadarRange", 300)
        local rc = Vector2.new(30 + size2 / 2, vp.Y - 30 - size2 / 2)
        rd.Back.Position, rd.Back.Radius = rc, size2 / 2
        rd.Ring.Position, rd.Ring.Radius = rc, size2 / 2
        rd.Ring.Color = Val("RadarColor", Color3.fromRGB(255, 70, 70))
        rd.Me.Position = rc
        local camCF = Camera.CFrame
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LP then
                local root = Root(p.Character)
                local dot = rd.Dots[p]
                if root and Alive(p.Character) and (On("ESPTeam") or not SameTeam(p)) then
                    if not dot then
                        dot = D("Circle", { Filled = true, NumSides = 10, Radius = 3, ZIndex = 10 })
                        rd.Dots[p] = dot
                    end
                    local rel = camCF:PointToObjectSpace(root.Position)
                    local v = Vector2.new(rel.X, rel.Z) / range * (size2 / 2)
                    if v.Magnitude > size2 / 2 - 4 then v = v.Unit * (size2 / 2 - 4) end
                    dot.Position = rc + v
                    dot.Color = (On("ESPTeamColor") and p.Team ~= nil) and p.TeamColor.Color or Val("RadarColor", Color3.fromRGB(255, 70, 70))
                    dot.Visible = true
                    used[p] = true
                end
            end
        end
    end
    for p, dot in pairs(rd.Dots) do
        if not used[p] then
            dot.Visible = false
            if not p.Parent then
                Kill(dot)
                rd.Dots[p] = nil
            end
        end
    end
end

----------------------------------------------------------------------
-- World / movement / misc
----------------------------------------------------------------------
local LightOrig
local function ApplyFullbright(state)
    if state then
        if not LightOrig then
            LightOrig = {
                Brightness = Lighting.Brightness, ClockTime = Lighting.ClockTime,
                FogEnd = Lighting.FogEnd, GlobalShadows = Lighting.GlobalShadows,
                Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
            }
        end
        Lighting.Brightness = 2
        Lighting.ClockTime = 14
        Lighting.FogEnd = 1e9
        Lighting.GlobalShadows = false
        Lighting.Ambient = Color3.fromRGB(178, 178, 178)
        Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
    elseif LightOrig then
        for k, v in pairs(LightOrig) do Lighting[k] = v end
        LightOrig = nil
    end
end

local MoveOrig = {}
local Fly = { On = false }

local function RunMovement()
    local c = LP.Character
    local hum, root = Hum(c), Root(c)
    if not hum then return end

    if On("WSEnabled") then hum.WalkSpeed = Val("WSValue", 32) end
    if On("JPEnabled") then
        hum.UseJumpPower = true
        hum.JumpPower = Val("JPValue", 80)
    end

    if On("FlyEnabled") and root and KeyDown("FlyKey") then
        Fly.On = true
        hum.PlatformStand = true
        local cf = Camera.CFrame
        local dir = Vector3.new(0, 0, 0)
        if UIS:IsKeyDown(Enum.KeyCode.W) then dir = dir + cf.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.S) then dir = dir - cf.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.D) then dir = dir + cf.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.A) then dir = dir - cf.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.Space) then dir = dir + Vector3.new(0, 1, 0) end
        if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then dir = dir - Vector3.new(0, 1, 0) end
        if dir.Magnitude > 0 then dir = dir.Unit end
        root.AssemblyLinearVelocity = dir * Val("FlySpeed", 60)
    elseif Fly.On then
        Fly.On = false
        hum.PlatformStand = false
    end
end

local function RunNoclip()
    if not On("NoclipEnabled") then return end
    local c = LP.Character
    if not c then return end
    for _, v in ipairs(c:GetDescendants()) do
        if v:IsA("BasePart") and v.CanCollide then v.CanCollide = false end
    end
end

local function RunSpectate()
    if On("SpecEnabled") then
        local v = Val("SpecTarget", nil)
        local p = (typeof(v) == "Instance") and v or (type(v) == "string" and Players:FindFirstChild(v)) or nil
        local h = p and p.Character and Hum(p.Character)
        if h and Camera.CameraSubject ~= h then Camera.CameraSubject = h end
    end
end

local Zoom = { Orig = nil }
local function RunFov()
    local zooming = On("ZoomEnabled") and KeyDown("ZoomKey")
    local fov = Camera.FieldOfView
    if zooming then
        Zoom.Orig = Zoom.Orig or fov
        Camera.FieldOfView = fov + (Val("ZoomFov", 25) - fov) * 0.3
    elseif Zoom.Orig then
        local goal = On("FovEnabled") and Val("FovValue", 90) or Zoom.Orig
        Camera.FieldOfView = fov + (goal - fov) * 0.3
        if math.abs(Camera.FieldOfView - goal) < 0.5 then
            Camera.FieldOfView = goal
            Zoom.Orig = nil
        end
    elseif On("FovEnabled") then
        Camera.FieldOfView = Val("FovValue", 90)
    end
end

----------------------------------------------------------------------
-- HUD (watermark, target HUD) + extra utilities
----------------------------------------------------------------------
local HUD = { Frames = 0, Acc = 0, Fps = 60 }
local LastText = setmetatable({}, { __mode = "k" })

local function SetIf(label, text)
    if label and LastText[label] ~= text then
        LastText[label] = text
        label:SetText(text)
    end
end

local function PingMs()
    local ok, v = pcall(function()
        return StatsSvc.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    return ok and math.floor(v + 0.5) or 0
end

local function SelectedPlayer()
    local v = Val("SpecTarget", nil)
    if typeof(v) == "Instance" then return v end
    if type(v) == "string" then return Players:FindFirstChild(v) end
    return nil
end

local function MakeLabel(parent)
    local l = Instance.new("TextLabel")
    l.BackgroundTransparency = 1
    l.Size = UDim2.new(1, 0, 0, 16)
    l.Text = ""
    l.TextSize = 14
    l.FontFace = Library.Scheme.Font
    l.TextColor3 = Library.Scheme.FontColor
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Parent = parent
    return l
end

local function BuildHUD()
    local wm, wmC = Library:AddDraggableMenu("Lunyx Hub")
    wm.AutomaticSize = Enum.AutomaticSize.None
    wm.Size = UDim2.fromOffset(250, 72)
    wm.Position = UDim2.new(1, -264, 0, 10)
    HUD.WM, HUD.WMText = wm, MakeLabel(wmC)

    local th, thC = Library:AddDraggableMenu("Target")
    th.AutomaticSize = Enum.AutomaticSize.None
    th.Size = UDim2.fromOffset(220, 110)
    th.Position = UDim2.new(0.5, 140, 0.5, 30)
    th.Visible = false
    HUD.TH, HUD.THName, HUD.THInfo = th, MakeLabel(thC), MakeLabel(thC)
    local back = Instance.new("Frame")
    back.Size = UDim2.new(1, 0, 0, 6)
    back.BackgroundColor3 = Library.Scheme.MainColor
    back.BorderSizePixel = 0
    back.Parent = thC
    local fill = Instance.new("Frame")
    fill.Size = UDim2.fromScale(1, 1)
    fill.BorderSizePixel = 0
    fill.Parent = back
    HUD.THFill = fill
end

local function UpdateInfo()
    local ins = Options.InspInfo
    if ins then
        local p = SelectedPlayer()
        if not p then
            SetIf(ins, "select a player above")
        else
            local c = p.Character
            local hum, root, mr = Hum(c), Root(c), Root(LP.Character)
            local tool = c and c:FindFirstChildOfClass("Tool")
            local hp = hum and (math.floor(hum.Health + 0.5) .. "/" .. math.floor(hum.MaxHealth + 0.5)) or "-"
            local dist = (root and mr) and (math.floor((root.Position - mr.Position).Magnitude * STUD_TO_M + 0.5) .. "m") or "-"
            SetIf(ins, p.DisplayName .. " (@" .. p.Name .. ")\nHP: " .. hp .. "  |  " .. dist
                .. "\nTeam: " .. (p.Team and p.Team.Name or "none")
                .. "\nTool: " .. (tool and tool.Name or "none")
                .. "\nAccount: " .. p.AccountAge .. " days  |  Friend: " .. (FriendCache[p.UserId] and "yes" or "no"))
        end
    end
end

local function UpdateHUD(dt)
    HUD.Frames = HUD.Frames + 1
    HUD.Acc = HUD.Acc + dt
    if HUD.Acc >= 0.5 then
        HUD.Fps = math.floor(HUD.Frames / HUD.Acc + 0.5)
        HUD.Frames, HUD.Acc = 0, 0
        if HUD.WMText then
            HUD.WMText.Text = string.format("%d fps  |  %d ms  |  %d players", HUD.Fps, PingMs(), #Players:GetPlayers())
        end
        UpdateInfo()
    end

    if HUD.WM then HUD.WM.Visible = On("WatermarkEnabled") end

    if HUD.TH then
        local t = CurrentTarget()
        local hum = t and t.Char and t.Char.Parent and Hum(t.Char)
        local show = On("THEnabled") and hum ~= nil and t.Part ~= nil and t.Part.Parent ~= nil
        HUD.TH.Visible = show
        if show then
            local r = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
            local d = (t.Part.Position - Camera.CFrame.Position).Magnitude
            HUD.THName.Text = t.Player.DisplayName .. " (@" .. t.Player.Name .. ")"
            HUD.THInfo.Text = math.floor(hum.Health + 0.5) .. " hp  |  " .. math.floor(d * STUD_TO_M + 0.5) .. "m  |  " .. t.Part.Name
            HUD.THFill.Size = UDim2.fromScale(r, 1)
            HUD.THFill.BackgroundColor3 = HealthColor(r)
        end
    end
end

-- proximity alert
local Prox = { Last = 0 }
local function RunProximity()
    if not On("ProxEnabled") then return end
    local root = Root(LP.Character)
    if not root then return end
    local now = os.clock()
    if now - Prox.Last < 3 then return end
    local range = Val("ProxRange", 60)
    for _, p in ipairs(Players:GetPlayers()) do
        if Valid(p) then
            local tr = Root(p.Character)
            if tr then
                local d = (tr.Position - root.Position).Magnitude
                if d <= range then
                    Prox.Last = now
                    Library:Notify({
                        Title = "Proximity alert",
                        Description = p.DisplayName .. " is " .. math.floor(d * STUD_TO_M + 0.5) .. "m away",
                        Time = 2.5,
                    })
                    break
                end
            end
        end
    end
end

-- anti-void: snap back to the last grounded position
local Void = { Safe = nil }
local function RunAntiVoid()
    if not On("AntiVoid") then return end
    local c = LP.Character
    local root, hum = Root(c), Hum(c)
    if not root or not hum then return end
    if hum.FloorMaterial ~= Enum.Material.Air then Void.Safe = root.CFrame end
    if Void.Safe and root.Position.Y < Workspace.FallenPartsDestroyHeight + 60 then
        root.CFrame = Void.Safe + Vector3.new(0, 3, 0)
        root.AssemblyLinearVelocity = Vector3.zero
    end
end

-- Ctrl + Click teleport
local ClickParams = RaycastParams.new()
ClickParams.FilterType = Enum.RaycastFilterType.Exclude
ClickParams.IgnoreWater = true

local function ClickTeleport()
    local root = Root(LP.Character)
    if not root then return end
    local m = UIS:GetMouseLocation()
    local ray = Camera:ViewportPointToRay(m.X, m.Y)
    ClickParams.FilterDescendantsInstances = { LP.Character, Camera }
    local r = Workspace:Raycast(ray.Origin, ray.Direction * 3000, ClickParams)
    if r then
        root.CFrame = CFrame.new(r.Position + Vector3.new(0, 3, 0))
        root.AssemblyLinearVelocity = Vector3.zero
    end
end

local function ServerHop()
    Library:Notify("Searching for a server...", 3)
    task.spawn(function()
        local ok, body = pcall(function()
            return game:HttpGet("https://games.roblox.com/v1/games/" .. game.PlaceId .. "/servers/Public?sortOrder=Asc&limit=100")
        end)
        if not ok then
            Library:Notify("Server list request failed.", 4)
            return
        end
        local ok2, data = pcall(function() return HttpService:JSONDecode(body) end)
        local pick
        if ok2 and data and data.data then
            local wantMost = Val("HopMode", "Fewest players") == "Most players"
            for _, s in ipairs(data.data) do
                if s.id ~= game.JobId and s.playing < s.maxPlayers then
                    if not pick or (wantMost and s.playing > pick.playing) or (not wantMost and s.playing < pick.playing) then
                        pick = s
                    end
                end
            end
        end
        if not pick then
            Library:Notify("No other server found.", 4)
            return
        end
        pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, pick.id, LP) end)
    end)
end

----------------------------------------------------------------------
-- Main loops
----------------------------------------------------------------------
local BIND_NAME = "LunyxHubRender"

local function SafeRun(name, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then warn("[LunyxHub] " .. name .. ": " .. tostring(err)) end
end

RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
    if not Running then return end
    Camera = Workspace.CurrentCamera
    if not Camera then return end
    Shared.Camera = Camera

    SafeRun("Silent", UpdateSilent)
    SafeRun("Aimbot", RunAimbot, dt)
    SafeRun("Cursor", RunCursor, dt)
    SafeRun("Fov", RunFov)
    SafeRun("Spectate", RunSpectate)
    SafeRun("ESP", UpdateESP)
    SafeRun("Overlay", UpdateOverlay)
end)

Library:GiveSignal(RunService.Heartbeat:Connect(function(dt)
    if not Running then return end
    SafeRun("Clicker", RunClicker, dt)
    SafeRun("Trigger", RunTrigger)
    SafeRun("KillAura", RunKillAura)
    SafeRun("Hitbox", RunHitbox)
    SafeRun("Movement", RunMovement)
    SafeRun("Proximity", RunProximity)
    SafeRun("AntiVoid", RunAntiVoid)
    SafeRun("HUD", UpdateHUD, dt)
end))

Library:GiveSignal(RunService.Stepped:Connect(function()
    if Running then SafeRun("Noclip", RunNoclip) end
end))

Library:GiveSignal(UIS.JumpRequest:Connect(function()
    if Running and On("InfJump") then
        local h = Hum(LP.Character)
        if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end))

Library:GiveSignal(Players.PlayerRemoving:Connect(function(p)
    RemoveESP(p)
    FriendCache[p.UserId] = nil
    if Running and On("JoinNotify") then
        Library:Notify({ Title = "Player left", Description = p.DisplayName .. " (@" .. p.Name .. ")", Time = 3 })
    end
end))

Library:GiveSignal(Players.PlayerAdded:Connect(function(p)
    if Running and On("JoinNotify") then
        Library:Notify({ Title = "Player joined", Description = p.DisplayName .. " (@" .. p.Name .. ")", Time = 3 })
    end
end))

Library:GiveSignal(UIS.InputBegan:Connect(function(input, processed)
    if processed or not Running or Library.Toggled then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1
        and On("ClickTP") and UIS:IsKeyDown(Enum.KeyCode.LeftControl) then
        SafeRun("ClickTP", ClickTeleport)
    end
end))

----------------------------------------------------------------------
-- UI
----------------------------------------------------------------------
local Window = Ctx.Window

pcall(BuildHUD)

local Tabs = {
    Aim      = Ctx.AddTab("Aim", "crosshair"),
    Combat   = Ctx.AddTab("Combat", "swords"),
    Visuals  = Ctx.AddTab("Visuals", "eye"),
    Player   = Ctx.AddTab("Player", "user"),
    HUD      = Ctx.AddTab("HUD", "monitor"),
}

local PartList = { "Head", "Torso", "Root", "Closest", "Random" }
local SortList = { "Cursor", "Distance", "Health" }

---------------- HUD ----------------
do
    local O = Tabs.HUD:AddLeftGroupbox("Overlays")
    O:AddToggle("WatermarkEnabled", { Text = "Watermark (fps / ping / players)", Default = true })
    O:AddToggle("THEnabled", { Text = "Target HUD", Default = true, Tooltip = "Name, health and distance of the current aim target" })
    O:AddToggle("TMEnabled", { Text = "Target marker", Default = true, Tooltip = "Ring on the current aim target" })
        :AddColorPicker("TMColor", { Default = Color3.fromRGB(255, 60, 60), Title = "Target marker" })
    O:AddToggle("TMLine", { Text = "Line from cursor to target", Default = false })
    O:AddToggle("JoinNotify", { Text = "Join / leave notifications", Default = false })
    O:AddToggle("ProxEnabled", { Text = "Proximity alert", Default = false, Tooltip = "Notifies when a valid enemy gets close" })
    O:AddSlider("ProxRange", { Text = "Alert range", Default = 60, Min = 10, Max = 300, Rounding = 0, Suffix = " studs" })

    local G = Tabs.HUD:AddRightGroupbox("Quick guide")
    G:AddLabel(
        "RightShift  show / hide menu\n"
        .. "[-]  minimize to the Lunyx pill\n"
        .. "[x]  close (click twice to unload)\n\n"
        .. "MB2 (hold)  aimbot\n"
        .. "Q (hold)  cursor follow\n"
        .. "X (hold)  auto clicker\n"
        .. "Z (hold)  zoom\n"
        .. "Ctrl + Click  click teleport\n\n"
        .. "Every keybind can be rebound and its mode switched (Always / Toggle / Hold) by clicking the key box.",
        true
    )
end

---------------- AIM ----------------
do
    local G = Tabs.Aim:AddLeftGroupbox("Aimbot")
    G:AddToggle("AimEnabled", { Text = "Aimbot", Default = false, Tooltip = "Rotates the camera onto the target" })
        :AddKeyPicker("AimKey", { Default = "MB2", Mode = "Hold", Text = "Aimbot", NoUI = false })
    G:AddDropdown("AimPart", { Text = "Aim part", Values = PartList, Default = "Head" })
    G:AddDropdown("AimSort", { Text = "Target priority", Values = SortList, Default = "Cursor" })
    G:AddSlider("AimFov", { Text = "FOV", Default = 150, Min = 10, Max = 1000, Rounding = 0, Suffix = "px" })
    G:AddSlider("AimSmooth", { Text = "Smoothness (0 = snap)", Default = 0.30, Min = 0, Max = 0.98, Rounding = 2 })
    G:AddSlider("AimPred", { Text = "Prediction", Default = 0, Min = 0, Max = 0.5, Rounding = 3, Suffix = "s" })
    G:AddSlider("AimMaxDist", { Text = "Max distance", Default = 1500, Min = 20, Max = 5000, Rounding = 0, Suffix = " studs" })
    G:AddToggle("AimSticky", { Text = "Sticky target", Default = false })
    G:AddToggle("AimWall", { Text = "Wall check", Default = true })
    G:AddToggle("AimShowFov", { Text = "Show FOV circle", Default = true })
        :AddColorPicker("AimFovColor", { Default = Color3.fromRGB(255, 255, 255), Title = "Aimbot FOV" })

    local C = Tabs.Aim:AddLeftGroupbox("Cursor Follow")
    C:AddToggle("CurEnabled", { Text = "Cursor follow", Default = false, Tooltip = "Moves the actual mouse cursor toward the target" })
        :AddKeyPicker("CurKey", { Default = "Q", Mode = "Hold", Text = "Cursor follow" })
    C:AddDropdown("CurPart", { Text = "Aim part", Values = PartList, Default = "Head" })
    C:AddSlider("CurFov", { Text = "FOV", Default = 200, Min = 10, Max = 1000, Rounding = 0, Suffix = "px" })
    C:AddSlider("CurSmooth", { Text = "Smoothness (0 = snap)", Default = 0.60, Min = 0, Max = 0.98, Rounding = 2 })
    C:AddSlider("CurPred", { Text = "Prediction", Default = 0, Min = 0, Max = 0.5, Rounding = 3, Suffix = "s" })
    C:AddSlider("CurMaxDist", { Text = "Max distance", Default = 1500, Min = 20, Max = 5000, Rounding = 0, Suffix = " studs" })
    C:AddToggle("CurWall", { Text = "Wall check", Default = true })
    C:AddToggle("CurShowFov", { Text = "Show FOV circle", Default = false })
        :AddColorPicker("CurFovColor", { Default = Color3.fromRGB(120, 200, 255), Title = "Cursor FOV" })
    if not (HAS_MOVEREL or HAS_MOVEABS) then
        C:AddLabel("executor has no mousemoverel/mousemoveabs", true)
    end

    local S = Tabs.Aim:AddRightGroupbox("Silent Aim")
    S:AddToggle("SilEnabled", { Text = "Silent aim", Default = false, Tooltip = "Redirects shots without moving the camera" })
        :AddKeyPicker("SilKey", { Default = "None", Mode = "Always", Text = "Silent aim" })
    S:AddDropdown("SilPart", { Text = "Aim part", Values = PartList, Default = "Head" })
    S:AddDropdown("SilSort", { Text = "Target priority", Values = SortList, Default = "Cursor" })
    S:AddDropdown("SilMethods", {
        Text = "Hooks", Multi = true,
        Values = { "Mouse Hit/Target", "Raycast", "FindPartOnRay", "ScreenPointToRay" },
        Default = { "Mouse Hit/Target", "Raycast", "FindPartOnRay", "ScreenPointToRay" },
        Tooltip = "Which engine calls get redirected. Turn off the ones the game does not use.",
    })
    S:AddSlider("SilFov", { Text = "FOV", Default = 150, Min = 10, Max = 1000, Rounding = 0, Suffix = "px" })
    S:AddSlider("SilChance", { Text = "Hit chance", Default = 100, Min = 1, Max = 100, Rounding = 0, Suffix = "%" })
    S:AddSlider("SilPred", { Text = "Prediction", Default = 0, Min = 0, Max = 0.5, Rounding = 3, Suffix = "s" })
    S:AddSlider("SilMaxDist", { Text = "Max distance", Default = 1500, Min = 20, Max = 5000, Rounding = 0, Suffix = " studs" })
    S:AddToggle("SilWall", { Text = "Wall check", Default = true })
    S:AddToggle("SilShowFov", { Text = "Show FOV circle", Default = true })
        :AddColorPicker("SilFovColor", { Default = Color3.fromRGB(255, 120, 255), Title = "Silent FOV" })
    if not HAS_HOOK then
        S:AddLabel("executor has no hookmetamethod/getnamecallmethod/checkcaller: silent aim disabled", true)
    end

    local F = Tabs.Aim:AddRightGroupbox("Target Filters")
    F:AddToggle("FTeam", { Text = "Team check", Default = true, Tooltip = "Ignore teammates in every combat module" })
    F:AddToggle("FFriends", { Text = "Ignore friends", Default = false })
    F:AddToggle("FForceField", { Text = "Ignore spawn-protected", Default = true })
    F:AddDropdown("Whitelist", {
        SpecialType = "Player", ExcludeLocalPlayer = true, Multi = true,
        Text = "Whitelist", Tooltip = "Selected players are ignored by aim, kill aura, trigger and hitbox",
    })
end

---------------- COMBAT ----------------
do
    local AC = Tabs.Combat:AddLeftGroupbox("Auto Clicker")
    AC:AddToggle("ACEnabled", { Text = "Auto clicker", Default = false })
        :AddKeyPicker("ACKey", { Default = "X", Mode = "Hold", Text = "Auto clicker" })
    AC:AddSlider("ACCps", { Text = "Clicks per second", Default = 12, Min = 1, Max = 60, Rounding = 0 })
    AC:AddSlider("ACJitter", { Text = "Timing jitter", Default = 10, Min = 0, Max = 60, Rounding = 0, Suffix = "%" })
    AC:AddDropdown("ACMethod", {
        Text = "Click method", Values = { "Mouse", "VirtualInput", "Tool Activate" }, Default = "Mouse",
        Tooltip = "Also used by Triggerbot. Tool Activate fires the equipped tool directly.",
    })

    local TB = Tabs.Combat:AddLeftGroupbox("Triggerbot")
    TB:AddToggle("TrigEnabled", { Text = "Triggerbot", Default = false, Tooltip = "Clicks when the crosshair is over a valid target" })
        :AddKeyPicker("TrigKey", { Default = "None", Mode = "Always", Text = "Triggerbot" })
    TB:AddSlider("TrigDelay", { Text = "Reaction delay", Default = 40, Min = 0, Max = 500, Rounding = 0, Suffix = "ms" })
    TB:AddSlider("TrigInterval", { Text = "Interval between shots", Default = 90, Min = 10, Max = 1000, Rounding = 0, Suffix = "ms" })
    TB:AddToggle("TrigHead", { Text = "Head only", Default = false })

    local KAG = Tabs.Combat:AddRightGroupbox("Kill Aura")
    KAG:AddToggle("KAEnabled", { Text = "Kill aura", Default = false, Tooltip = "Attacks every valid player inside the range" })
        :AddKeyPicker("KAKey", { Default = "None", Mode = "Always", Text = "Kill aura" })
    KAG:AddSlider("KARange", { Text = "Range", Default = 15, Min = 3, Max = 80, Rounding = 0, Suffix = " studs" })
    KAG:AddSlider("KADelay", { Text = "Attack delay", Default = 100, Min = 0, Max = 1000, Rounding = 0, Suffix = "ms" })
    KAG:AddSlider("KAMax", { Text = "Max targets per hit", Default = 1, Min = 1, Max = 10, Rounding = 0 })
    KAG:AddDropdown("KASort", { Text = "Priority", Values = { "Distance", "Health" }, Default = "Distance" })
    KAG:AddDropdown("KAMethods", {
        Text = "Attack methods", Multi = true,
        Values = { "Tool Activate", "Touch", "Mouse Click" },
        Default = { "Tool Activate", "Touch" },
        Tooltip = "Tool Activate: swings the tool. Touch: firetouchinterest handle -> target. Mouse Click: real click.",
    })
    KAG:AddToggle("KAAutoEquip", { Text = "Auto equip tool", Default = true })
    KAG:AddInput("KAToolName", { Text = "Preferred tool name", Default = "", Placeholder = "empty = first tool", Finished = true })
    KAG:AddToggle("KAFace", { Text = "Face target", Default = false })
    KAG:AddToggle("KAStick", { Text = "Stick behind target", Default = false, Risky = true })
    KAG:AddSlider("KAStickDist", { Text = "Stick distance", Default = 3, Min = 1, Max = 12, Rounding = 1, Suffix = " studs" })
    KAG:AddToggle("KAWall", { Text = "Wall check", Default = false })
    KAG:AddToggle("KAShowRange", { Text = "Show range sphere", Default = false })
        :AddColorPicker("KARangeColor", { Default = Color3.fromRGB(255, 80, 80), Title = "Range sphere" })
    if not HAS_FTI then
        KAG:AddLabel("executor has no firetouchinterest: Touch method disabled", true)
    end

    local HB = Tabs.Combat:AddRightGroupbox("Hitbox Expander")
    HB:AddToggle("HBEnabled", { Text = "Hitbox expander", Default = false, Tooltip = "Client-side. Only helps where hits are validated from your client." })
    HB:AddDropdown("HBPart", { Text = "Part", Values = { "HumanoidRootPart", "Head" }, Default = "HumanoidRootPart" })
    HB:AddSlider("HBSize", { Text = "Size", Default = 10, Min = 2, Max = 40, Rounding = 0, Suffix = " studs" })
    HB:AddSlider("HBTransp", { Text = "Transparency", Default = 0.7, Min = 0, Max = 1, Rounding = 2 })
end

---------------- VISUALS ----------------
do
    local E = Tabs.Visuals:AddLeftGroupbox("ESP")
    E:AddToggle("ESPEnabled", { Text = "ESP", Default = false })
    E:AddToggle("ESPTeam", { Text = "Show teammates", Default = false })
    E:AddSlider("ESPMaxDist", { Text = "Max distance", Default = 2000, Min = 50, Max = 10000, Rounding = 0, Suffix = " studs" })
    E:AddSlider("ESPTextSize", { Text = "Text size", Default = 13, Min = 9, Max = 24, Rounding = 0 })
    E:AddDivider()
    E:AddToggle("ESPBox", { Text = "Box", Default = true })
        :AddColorPicker("ESPColor", { Default = Color3.fromRGB(255, 70, 70), Title = "ESP colour" })
    E:AddDropdown("ESPBoxStyle", { Text = "Box style", Values = { "Full", "Corner" }, Default = "Full" })
    E:AddToggle("ESPFill", { Text = "Box fill", Default = false })
    E:AddSlider("ESPFillT", { Text = "Fill opacity", Default = 0.15, Min = 0.02, Max = 1, Rounding = 2 })
    E:AddToggle("ESPName", { Text = "Name", Default = true })
    E:AddToggle("ESPDist", { Text = "Distance", Default = true })
    E:AddDropdown("ESPUnit", { Text = "Distance unit", Values = { "Meters", "Studs", "Both" }, Default = "Meters" })
    E:AddToggle("ESPHealth", { Text = "Health bar", Default = true })
    E:AddToggle("ESPHealthText", { Text = "Health number", Default = true })
    E:AddToggle("ESPTool", { Text = "Held tool", Default = false })
    E:AddToggle("ESPTeamColor", { Text = "Use team colour", Default = false })
    E:AddToggle("ESPRainbow", { Text = "Rainbow colour", Default = false })
    E:AddToggle("ESPVisCheck", { Text = "Visible / hidden colours", Default = false })
        :AddColorPicker("ESPVisColor", { Default = Color3.fromRGB(80, 255, 120), Title = "Visible" })
        :AddColorPicker("ESPHidColor", { Default = Color3.fromRGB(255, 70, 70), Title = "Hidden" })

    local X = Tabs.Visuals:AddRightGroupbox("ESP Extras")
    X:AddToggle("ESPBones", { Text = "Skeleton (bones)", Default = true })
        :AddColorPicker("ESPBonesColor", { Default = Color3.new(1, 1, 1), Title = "Bones" })
    X:AddToggle("ESPBonesMain", { Text = "Bones use ESP colour", Default = false })
    X:AddToggle("ESPTracer", { Text = "Tracers", Default = false })
    X:AddDropdown("ESPTracerOrigin", { Text = "Tracer origin", Values = { "Bottom", "Center", "Top", "Mouse" }, Default = "Bottom" })
    X:AddToggle("ESPHeadDot", { Text = "Head dot", Default = false })
    X:AddToggle("ESPLook", { Text = "Look direction", Default = false })
    X:AddToggle("ESPArrows", { Text = "Off-screen arrows", Default = false })
    X:AddSlider("ESPArrowRadius", { Text = "Arrow radius", Default = 200, Min = 60, Max = 600, Rounding = 0, Suffix = "px" })

    local SG = Tabs.Visuals:AddRightGroupbox("Silhouette")
    SG:AddToggle("ESPSil", { Text = "Silhouette (through walls)", Default = true, Tooltip = "Roblox Highlight. The engine caps this at 31 at once." })
    SG:AddToggle("ESPSilUseMain", { Text = "Use ESP colour", Default = true })
    SG:AddLabel("Fill"):AddColorPicker("ESPSilFill", { Default = Color3.fromRGB(255, 70, 70), Title = "Silhouette fill" })
    SG:AddLabel("Outline"):AddColorPicker("ESPSilOutline", { Default = Color3.new(1, 1, 1), Title = "Silhouette outline" })
    SG:AddSlider("ESPSilFillT", { Text = "Fill transparency", Default = 0.5, Min = 0, Max = 1, Rounding = 2 })
    SG:AddSlider("ESPSilOutT", { Text = "Outline transparency", Default = 0, Min = 0, Max = 1, Rounding = 2 })
    SG:AddDropdown("ESPSilDepth", { Text = "Depth mode", Values = { "AlwaysOnTop", "Occluded" }, Default = "AlwaysOnTop" })

    local R = Tabs.Visuals:AddLeftGroupbox("Radar")
    R:AddToggle("RadarEnabled", { Text = "Radar", Default = false })
        :AddColorPicker("RadarColor", { Default = Color3.fromRGB(255, 70, 70), Title = "Radar" })
    R:AddSlider("RadarSize", { Text = "Size", Default = 150, Min = 80, Max = 320, Rounding = 0, Suffix = "px" })
    R:AddSlider("RadarRange", { Text = "Range", Default = 300, Min = 50, Max = 2000, Rounding = 0, Suffix = " studs" })

    local XH = Tabs.Visuals:AddLeftGroupbox("Crosshair")
    XH:AddToggle("XhEnabled", { Text = "Custom crosshair", Default = false })
        :AddColorPicker("XhColor", { Default = Color3.new(1, 1, 1), Title = "Crosshair" })
    XH:AddToggle("XhDot", { Text = "Centre dot", Default = true })
    XH:AddSlider("XhSize", { Text = "Length", Default = 8, Min = 2, Max = 40, Rounding = 0 })
    XH:AddSlider("XhGap", { Text = "Gap", Default = 4, Min = 0, Max = 30, Rounding = 0 })
    XH:AddSlider("XhThick", { Text = "Thickness", Default = 1, Min = 1, Max = 5, Rounding = 0 })

    local W = Tabs.Visuals:AddRightGroupbox("World")
    W:AddToggle("FullbrightEnabled", { Text = "Fullbright", Default = false })
    W:AddToggle("FovEnabled", { Text = "Field of view", Default = false })
    W:AddSlider("FovValue", { Text = "FOV", Default = 90, Min = 30, Max = 120, Rounding = 0 })
    W:AddToggle("ZoomEnabled", { Text = "Zoom (hold key)", Default = false })
        :AddKeyPicker("ZoomKey", { Default = "Z", Mode = "Hold", Text = "Zoom" })
    W:AddSlider("ZoomFov", { Text = "Zoom FOV", Default = 25, Min = 5, Max = 70, Rounding = 0 })
    Toggles.FullbrightEnabled:OnChanged(function() ApplyFullbright(Toggles.FullbrightEnabled.Value) end)
    if not HAS_DRAW then
        W:AddLabel("executor has no Drawing library: ESP, radar, FOV circles and crosshair are off", true)
    end
end

---------------- PLAYER ----------------
do
    local M = Tabs.Player:AddLeftGroupbox("Movement")
    M:AddToggle("WSEnabled", { Text = "WalkSpeed", Default = false })
    M:AddSlider("WSValue", { Text = "Speed", Default = 32, Min = 16, Max = 200, Rounding = 0 })
    M:AddToggle("JPEnabled", { Text = "JumpPower", Default = false })
    M:AddSlider("JPValue", { Text = "Power", Default = 80, Min = 50, Max = 300, Rounding = 0 })
    M:AddToggle("InfJump", { Text = "Infinite jump", Default = false })
    M:AddToggle("NoclipEnabled", { Text = "Noclip", Default = false })
    M:AddToggle("FlyEnabled", { Text = "Fly (WASD, Space, Ctrl)", Default = false })
        :AddKeyPicker("FlyKey", { Default = "None", Mode = "Always", Text = "Fly" })
    M:AddSlider("FlySpeed", { Text = "Fly speed", Default = 60, Min = 10, Max = 300, Rounding = 0 })

    Toggles.WSEnabled:OnChanged(function()
        local h = Hum(LP.Character)
        if not h then return end
        if Toggles.WSEnabled.Value then
            MoveOrig.WalkSpeed = h.WalkSpeed
        elseif MoveOrig.WalkSpeed then
            h.WalkSpeed = MoveOrig.WalkSpeed
        end
    end)
    Toggles.JPEnabled:OnChanged(function()
        local h = Hum(LP.Character)
        if not h then return end
        if Toggles.JPEnabled.Value then
            MoveOrig.JumpPower, MoveOrig.UseJumpPower = h.JumpPower, h.UseJumpPower
        elseif MoveOrig.JumpPower then
            h.UseJumpPower, h.JumpPower = MoveOrig.UseJumpPower, MoveOrig.JumpPower
        end
    end)

    local G = Tabs.Player:AddRightGroupbox("Misc")
    G:AddToggle("AntiVoid", { Text = "Anti-void", Default = false, Tooltip = "Returns you to the last grounded spot if you fall out of the map" })
    G:AddToggle("ClickTP", { Text = "Ctrl + Click teleport", Default = false })
    G:AddDivider()
    G:AddDropdown("SpecTarget", { SpecialType = "Player", ExcludeLocalPlayer = true, Text = "Player" })
    G:AddLabel("InspInfo", { Text = "select a player above", DoesWrap = true })
    G:AddToggle("SpecEnabled", { Text = "Spectate selected", Default = false })
    G:AddButton({
        Text = "Whitelist selected",
        Func = function()
            local p = SelectedPlayer()
            if not p then return Library:Notify("Select a player first.", 3) end
            local cur = {}
            for k, v in pairs(Options.Whitelist.Value) do cur[k] = v end
            cur[p] = true
            Options.Whitelist:SetValue(cur)
            Library:Notify(p.DisplayName .. " whitelisted.", 2)
        end,
    })
    Toggles.SpecEnabled:OnChanged(function()
        if not Toggles.SpecEnabled.Value then
            local h = Hum(LP.Character)
            if h then Camera.CameraSubject = h end
        end
    end)
    G:AddButton({
        Text = "Teleport to selected",
        Func = function()
            local v = Options.SpecTarget.Value
            local p = (typeof(v) == "Instance") and v or (type(v) == "string" and Players:FindFirstChild(v)) or nil
            local tr = p and Root(p.Character)
            local mr = Root(LP.Character)
            if tr and mr then
                mr.CFrame = tr.CFrame * CFrame.new(0, 0, 3)
            else
                Library:Notify("Select a player that is alive first.", 3)
            end
        end,
    })
    G:AddButton({
        Text = "Rejoin server",
        DoubleClick = true,
        Func = function()
            pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LP) end)
        end,
    })
end

----------------------------------------------------------------------
-- Unload
----------------------------------------------------------------------
local function Cleanup()
    if not Running then return end
    Running = false
    Shared.Active = false
    pcall(function() RunService:UnbindFromRenderStep(BIND_NAME) end)

    for _, o in pairs(ESP.Objs) do DestroyESP(o) end
    ESP.Objs = {}
    for d in pairs(Drawings) do pcall(function() d:Remove() end) end
    Drawings = {}
    pcall(function() if HLFolder then HLFolder:Destroy() end end)
    pcall(function() if KA.RangePart then KA.RangePart:Destroy() end end)
    pcall(RestoreHitboxes)
    pcall(function() if HUD.WM then HUD.WM:Destroy() end end)
    pcall(function() if HUD.TH then HUD.TH:Destroy() end end)
    pcall(ApplyFullbright, false)

    local h = Hum(LP.Character)
    if h then
        pcall(function()
            if MoveOrig.WalkSpeed then h.WalkSpeed = MoveOrig.WalkSpeed end
            if MoveOrig.JumpPower then h.UseJumpPower, h.JumpPower = MoveOrig.UseJumpPower, MoveOrig.JumpPower end
            h.PlatformStand = false
            Camera.CameraSubject = h
        end)
    end
end

return { Name = "Universal", Version = "2.1", Unload = Cleanup }
