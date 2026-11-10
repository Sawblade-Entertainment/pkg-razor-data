# Getting Started

## Requirements

- Razor Data only runs on the **server**. Requiring it is fine anywhere, but `RazorData.new` asserts `RunService:IsServer()`.
- To test in Studio, turn on **Game Settings → Security → Enable Studio Access to API Services**.

## 1. Create a store

A store is one DataStore with a template. Create it once, at the top level of a server script or service:

```lua
local RazorData = require(ServerScriptService.Packages.razordata)

local PlayerData = RazorData.new({
    Name = "PlayerData",
    Template = {
        Coins = 0,
        Level = 1,
        Inventory = {},
        Settings = { Music = true, Sfx = true },
    },
})
```

`Name` is the DataStore name. `Template` is what new players start with, and what gets merged into old saves when keys are missing. See [Config](api.md#config) for every option.

## 2. Bind players

`BindPlayers` loads a profile when each player joins and releases it when they leave:

```lua
PlayerData:BindPlayers(function(player, profile)
    print(player.Name, "has", profile.Data.Coins, "coins")
end)
```

It also handles the error cases:

- If the data can't load, the player is kicked with a message asking them to rejoin. This is safer than letting them play on a blank profile that would overwrite their real save.
- If the player leaves while their data is still loading, the profile is released straight away.
- If another server takes the session lock, the player is kicked from this server.

Players who are already in the server when you call `BindPlayers` are loaded too, so the timing of the call doesn't matter.

## 3. Read and write data

`profile.Data` is a plain table. You can change it directly, and it'll be saved on the next autosave or release:

```lua
local function addCoins(player: Player, amount: number)
    local profile = PlayerData:GetProfile(player.UserId)
    if not profile then
        return -- not loaded yet, or already released
    end
    profile.Data.Coins += amount
end
```

Profiles are keyed by `tostring(player.UserId)`. `GetProfile` accepts either the number or the string.

## 4. Saving

You don't need to save by hand:

- Every loaded profile is saved every `AutoSaveInterval` seconds (60 by default).
- A profile is saved and unlocked when its player leaves.
- Every loaded profile is released when the server shuts down.

If you want to save right away, for example after a purchase, call `profile:Save()`. It yields and returns `true` if the write worked.

```lua
profile.Data.Coins -= price
table.insert(profile.Data.Inventory, itemId)
profile:Save()
```

## Without BindPlayers

If you need more control, for example to load non-player keys or to show a loading screen, you can manage profiles yourself:

```lua
local Players = game:GetService("Players")

Players.PlayerAdded:Connect(function(player)
    local profile, err = PlayerData:LoadProfile(player.UserId)
    if not profile then
        player:Kick(`Data failed to load: {err}`)
        return
    end
    profile:AddUserId(player.UserId)

    if not player:IsDescendantOf(Players) then
        profile:Release() -- they left during the load
        return
    end

    profile.Released:Connect(function(reason)
        -- Check they're still here: the lock can be lost after they leave.
        if reason == "LostLock" and player:IsDescendantOf(Players) then
            player:Kick("Your data was loaded on another server.")
        end
    end)
end)

Players.PlayerRemoving:Connect(function(player)
    local profile = PlayerData:GetProfile(player.UserId)
    if profile then
        profile:Release()
    end
end)
```

This is what `BindPlayers` does for you. See [Profiles](profiles.md) for the full lifecycle.
