# Lunyx Hub vLoader (multi-loader)

## Layout
```
LunyxHub_vLoader/
├── main.luau                 entry + Core (window, title bar, Hub tab, Settings, unload)
├── core/Registry.luau        which hub runs in which game  ← edit this to add games
├── modules/
│   ├── Universal.luau        aim / combat / ESP / player / HUD (the v2 hub as a module)
│   ├── Music.luau            vMusic engine + tab, loaded in every game
│   └── games/_Template.luau  copy this for a new game hub
├── ERRORS.md                 error sink (unchanged format)
└── HANDOFF.md
```

## Run
Host the folder (GitHub raw, etc.), set `BaseUrl` in main.luau (or `getgenv().LunyxConfig = { BaseUrl = "..." }`), then:
```lua
loadstring(game:HttpGet("<BaseUrl>main.luau"))()
```
Dev without hosting: copy the folder to the executor workspace as `LunyxHub/`. A file found there wins over the remote one. "Reload hub" in the Hub tab re-reads everything.

## Flow
1. Core builds the Obsidian window (+ minimize pill and close-with-confirm).
2. Registry picks the hub by `game.PlaceId`, then `game.GameId`. No match → Fallback (Universal).
3. Game module runs, then every path in `Shared` (Music).
4. Settings tab is added last. Configs are saved per game: `LunyxHub/<game>/`.
5. Unload runs modules in reverse order: X (twice), panic key, Unload button, Reload.

## Adding a game
1. Copy `modules/games/_Template.luau` → `modules/games/<Game>.luau`.
2. Add an entry to `core/Registry.luau` (`PlaceIds` and/or `UniverseIds`).
3. Inside the module: `Ctx.Use("Universal")` if you want the universal tabs too, then add your own with `Ctx.AddTab`.
The Hub tab shows the Place ID and Universe ID of the current game, with a copy button.

## Module contract
Chunk receives `Ctx` as `...` and returns `{ Name, Version, Unload }`. Prefix every Option / Toggle index with the module name (indexes are global). Connect through `Ctx.Give`, restore game state in `Unload`.

## Hooks left open
- `Config.OnStage(text, fraction)` is called at each loading step. A loading screen only has to set it.
- `Ctx.Use("<module>")` lets a game hub load a shared module (Music, a future AI module) on demand.

## Fixed while porting vMusic
- Volume slider ↔ engine loop (SetValue re-fired the callback → recursion on every change).
- Repeat "off" wrapped to track 1 when the last track ended.
- Playlist dropdown never refreshed after add / remove / remote load.
- Seek slider fought the user's drag.
- Default playlist asset IDs are not verified; many old audio IDs are private now. Use your own uploads or the remote JSON.

## Not checked
Syntax and undeclared-global checks only. Not run in Roblox or an executor.
