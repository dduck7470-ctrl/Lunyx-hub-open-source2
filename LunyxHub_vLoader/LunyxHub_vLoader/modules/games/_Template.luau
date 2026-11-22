--[[
    Lunyx Hub | game module template
    Copy to modules/games/<Game>.luau, point a Registry entry at it.

    Contract
      * The chunk receives the loader context as `...`.
      * Return a table: { Name = string, Version = string, Unload = function }.
      * Add tabs with Ctx.AddTab. The Core adds the Hub tab first and Settings last.
      * Option / Toggle indexes are global: prefix them with the module name.
      * Anything you connect must go through Ctx.Give (connections) or be
        cleaned inside Unload. Unload runs on X, panic key, reload and re-exec.

    Ctx
      Ctx.Library / Ctx.Options / Ctx.Toggles   Obsidian
      Ctx.Window, Ctx.AddTab(name, icon)
      Ctx.Game      { Name, PlaceId, GameId }
      Ctx.Use(name) load and cache another module ("Universal" or a path)
      Ctx.Give(conn)  Ctx.OnUnload(fn)
      Ctx.Err(src, msg, full)   error sink, see ERRORS.md
      Ctx.Stage(text, fraction) hook for a future loading screen
      Ctx.Env       getgenv()
]]

local Ctx = ...
local Library, Options, Toggles = Ctx.Library, Ctx.Options, Ctx.Toggles
local RunService = game:GetService("RunService")

-- Reuse the whole Universal hub inside a game hub:
-- local Uni = Ctx.Use("Universal")

local Tab = Ctx.AddTab("Template", "box")
local G = Tab:AddLeftGroupbox("Example")

G:AddToggle("TplEnabled", { Text = "Example toggle", Default = false })
G:AddButton({
    Text = "Say hi",
    Func = function() Library:Notify("hi from " .. Ctx.Game.Name, 2) end,
})

local ticks = 0
Ctx.Give(RunService.Heartbeat:Connect(function()
    if Toggles.TplEnabled and Toggles.TplEnabled.Value then
        ticks = ticks + 1
    end
end))

return {
    Name = "Template",
    Version = "1.0",
    Unload = function()
        -- restore anything you changed in the game here
    end,
}
