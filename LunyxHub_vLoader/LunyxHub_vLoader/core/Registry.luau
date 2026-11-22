--[[
    Lunyx Hub | game registry
    Edit this file to add games. No change to main.luau is needed.

    Games[i]:
      Name         display name
      PlaceIds     list of game.PlaceId values   (the number in roblox.com/games/<id>)
      UniverseIds  list of game.GameId values    (shown in the Hub tab; use it when the
                                                  match runs in a different place than the lobby)
      Module       path of the game hub, relative to the hub root

    Fallback : used when nothing matches.
    Shared   : modules loaded after the game module in every game.
]]

return {
    Games = {
        {
            Name = "Walls",
            PlaceIds = { 124550432477389 },
            UniverseIds = {},
            Module = "modules/Universal.luau", -- swap for modules/games/Walls.luau once a dedicated hub exists
        },
        -- {
        --     Name = "Another Game",
        --     PlaceIds = { 0 },
        --     UniverseIds = {},
        --     Module = "modules/games/AnotherGame.luau",
        -- },
    },

    Fallback = { Name = "Universal", Module = "modules/Universal.luau" },

    Shared = { "modules/Music.luau" },
}
