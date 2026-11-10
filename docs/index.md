# Razor Data

Dead simple save data handling for Roblox.

Razor Data wraps `DataStoreService` in one small server module. You give it a template and it gives you a profile per player, which you can read and write like a normal table. Locking, retries, autosaving, migrations and shutdown are handled for you.

```lua
local RazorData = require(ServerScriptService.Packages.razordata)

local PlayerData = RazorData.new({
    Name = "PlayerData",
    Template = { Coins = 0, Inventory = {} },
})

PlayerData:BindPlayers(function(player, profile)
    profile.Data.Coins += 100
end)
```

## Features

- **Session locking.** A profile can only be loaded on one server at a time, so items can't be duplicated by hopping between servers.
- **Autosave and safe shutdown.** Profiles save on an interval, and are released when the player leaves or the server closes.
- **Migrations.** You can upgrade old save data with a list of ordered functions. Missing keys are filled in from your template.
- **Rich serialization.** You can save `Vector3`, `CFrame`, `Color3`, enums, buffers, Instances and more directly. Tables with mixed or non-string keys work too.
- **Defensive writes.** Saves retry with exponential backoff, wait for DataStore request budget, and skip writes that would go over the 4 MB limit instead of failing.
- **Legacy data adoption.** Keys written by other systems are wrapped and run through your migrations as schema version 0.

## Installation

With [ChainLink](https://github.com/Sawblade-Entertainment/ChainLink) or Wally, add it to your dependencies:

```toml
razordata = "vibeonline/razordata@0.1.3"
```

Then require it on the server:

```lua
-- ChainLink
local RazorData = use "razordata"

-- Wally
local RazorData = require(ServerScriptService.Packages.razordata)
```

You can also download a prebuilt `RazorData.rbxm` from the [GitHub releases](https://github.com/Sawblade-Entertainment/pkg-razor-data/releases).

## Next steps

- [Getting Started](getting-started.md): set up a store and save your first profile.
- [Profiles](profiles.md): loading, saving, releasing and the profile lifecycle.
- [Session Locking](session-locking.md): how cross-server locking works and how to tune it.
- [Migrations](migrations.md): change your data shape without losing player progress.
- [Serialization](serialization.md): the supported types and how to add your own.
- [API Reference](api.md): every public function and field.
