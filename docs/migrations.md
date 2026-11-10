# Migrations

Your save format will change. Migrations let you upgrade old saves when they load, so every profile you get matches your current code.

## Writing migrations

Pass an ordered list of functions as `Migrations`. Function `n` upgrades data from version `n - 1` to version `n`:

```lua
local PlayerData = RazorData.new({
    Name = "PlayerData",
    Template = {
        Currency = { Coins = 0, Gems = 0 },
        Inventory = {},
    },
    Migrations = {
        -- 1: Coins moved into a Currency table
        function(data)
            data.Currency = { Coins = data.Coins or 0 }
            data.Coins = nil
        end,

        -- 2: Inventory changed from a set of names to a list
        function(data)
            local list = {}
            for name in data.Inventory or {} do
                table.insert(list, name)
            end
            data.Inventory = list
        end,
    },
})
```

A migration can change `data` in place, or return a new value to replace it. If it returns `nil`, the changed `data` is kept.

The schema version is the number of migrations. With the list above, the latest version is `2`.

## When migrations run

When a profile loads, every migration after the record's stored `SchemaVersion` runs in order. A save at version 0 runs both functions above, and a save at version 1 runs only the second.

New profiles start as a copy of the template at the latest version, so no migrations run for them.

If a migration errors, the load fails with `Migration failed: ...` and the lock is cleared again. The stored `Data` and `SchemaVersion` aren't changed, so the save will be migrated again on the next load once you fix the migration. The record itself has already been written by then: `Meta.LoadCount` and `Meta.LastLoaded` are updated, and a legacy value is wrapped in a Razor Data record (see [Legacy data](#legacy-data)).

## Rules

- **Only ever add migrations to the end.** Don't remove, reorder or edit migrations that have shipped. Saves at those versions may still exist.
- **Migrations should be safe on partial data.** Old saves may be missing keys, so use fallbacks like `data.Coins or 0`.
- **Don't yield.** Migrations run during the load, before the profile is returned.

## Reconciling with the template

After migrating, the data is reconciled against the template. Reconcile:

- Adds any key in the template that's missing from the data, using the template's value (tables are copied).
- Recurses into nested dictionary tables, so new keys inside `Settings` are added too.
- Never overwrites a value that's already there.
- Never deletes keys that aren't in the template.
- Treats array tables (like `Inventory = { "Sword" }`) as a default only for when the key is missing. Their items aren't merged into existing arrays, so items a player removed don't come back.

This means **adding a key doesn't need a migration**. You only need one when you rename, move, restructure or delete data.

## Rolling updates

During an update, old and new servers run at the same time. If a player's data is migrated on a new server and then they join an old one, the old server would see a version it doesn't know.

Razor Data refuses to load in this case. `LoadProfile` returns `Record schema is newer than this server; refusing to load` without writing anything, and `BindPlayers` kicks the player with that message. Once old servers shut down, the player can join normally.

## Legacy data

If a key already has data that wasn't written by Razor Data, it's treated as schema version `0` and runs through every migration. You can use your first migration to convert data from your previous save system:

```lua
Migrations = {
    -- 1: adopt saves from the old DataManager
    function(old)
        return {
            Currency = { Coins = old.cash or 0, Gems = old.gems or 0 },
            Inventory = old.items or {},
        }
    end,
}
```

Point `Name` (and `Scope`, if you used one) at the existing DataStore. A key is wrapped in a Razor Data record as soon as it loads, even if the load then fails in a migration, so your old code can't read it after that. Test the conversion on a copy of your data first.

## Using the migrator directly

The migration module is exposed as `RazorData.Migrations` if you want to use it for other data:

```lua
local migrator = RazorData.Migrations.new({ step1, step2 })
local upgraded, version = migrator:Run(data, 0)

local filled = RazorData.Migrations.Reconcile(upgraded, template)
```
