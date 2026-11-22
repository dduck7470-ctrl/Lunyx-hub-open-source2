# Lunyx Hub — Error Detection & Diagnostics

## Central sink

Every major module (including MusicEngine) pushes failures here:

```lua
getgenv().LunyxErrors = getgenv().LunyxErrors or {}
getgenv().LunyxLastError = nil
```

Format of each entry:

```lua
{
    t   = os.clock(),          -- when it happened
    src = "MusicEngine",       -- module name
    msg = "SoundId invalid",   -- short message
    full = "...",              -- optional full tostring(err)
}
```

## Quick reader (paste in executor console)

```lua
local errs = getgenv().LunyxErrors or {}
print("=== Lunyx Errors (" .. #errs .. ") ===")
for i, e in ipairs(errs) do
    print(string.format("[%0.1f] %s → %s", e.t, e.src or "?", e.msg))
end
print("Last:", getgenv().LunyxLastError)
```

## In-UI (optional)

If you want a permanent Diagnostics group later, add to Settings tab:

```lua
local D = Tabs.Settings:AddRightGroupbox("Diagnostics")
D:AddButton({
    Text = "Print errors to console",
    Func = function()
        local errs = getgenv().LunyxErrors or {}
        warn("[Lunyx] " .. #errs .. " errors")
        for _, e in ipairs(errs) do
            warn(string.format("[%s] %s", e.src, e.msg))
        end
    end,
})
D:AddButton({
    Text = "Clear error log",
    Func = function()
        getgenv().LunyxErrors = {}
        getgenv().LunyxLastError = nil
        Library:Notify("Error log cleared", 2)
    end,
})
```

## Music-specific failures you might see

| Message                    | Meaning                              | Fix                                      |
|---------------------------|--------------------------------------|------------------------------------------|
| Sound create failed       | Executor blocked SoundService        | Rare on Volcano; try re-inject           |
| Invalid SoundId           | Bad rbxassetid://                    | Use a valid public audio asset           |
| Playlist empty            | No tracks                            | Add tracks or restore defaults           |
| UI parent failed          | gethui / CoreGui blocked             | Falls back to PlayerGui                  |

## FPS / lag checklist

If you notice FPS drop after adding Music:

1. Confirm Music tab is closed and nothing is playing.
2. Check `getgenv().LunyxMusic and getgenv().LunyxMusic.IsPlaying()`.
3. Look for error spam in the sink (infinite retry loops).
4. Disable the Music Heartbeat connection manually if needed (exposed on the engine).

Report any new error strings back so they can be hardened.
