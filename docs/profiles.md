# Profiles

A profile is one loaded DataStore key. For player data this is one profile per player, but any string or number key works, such as `"guild-123"` or `"global-shop"`.

## Lifecycle

```
LoadProfile
    │
    ▼
  Active ◄─┐
    │      │ Save
    ├──────┘
    │
    ├─► Release ───┐
    │              ▼
    └─► LostLock ─► Inactive
```

1. **Load.** `store:LoadProfile(key)` takes the session lock, decodes the data, runs migrations and fills in missing template keys.
2. **Active.** You read and write `profile.Data`. Each save writes the data and renews the lock.
3. **Release.** `profile:Release()` does a final save and clears the lock. After that the profile is inactive: it's removed from `store.Profiles`, `Released` fires, and later `Save`/`Release` calls do nothing and return `false`.

Keep the profile object only while `profile:IsActive()` is true. You can always get the current one with `store:GetProfile(key)`.

## Loading

```lua
local profile, err = store:LoadProfile(key)
```

- Returns the profile, or `nil` and an error message.
- If the key is already loaded on this server, the existing profile is returned.
- If two threads load the same key at the same time, the second one waits for the first and gets the same profile.
- If another server holds the lock, the load retries for a while before giving up. See [Session Locking](session-locking.md).

Possible error messages:

| Message | Cause |
| --- | --- |
| `DataStore error: ...` | The DataStore request kept failing after 5 attempts. |
| `Profile is session-locked by another server` | Another server still held the lock after every retry. |
| `Record schema is newer than this server; refusing to load` | The save was written by a newer version of your game with more migrations. See [Migrations](migrations.md#rolling-updates). |
| `Decode failed: ...` | The stored data couldn't be deserialized. |
| `Migration failed: ...` | One of your migration functions errored. |
| `Profile build failed: ...` | An unexpected error while building the profile, for example in reconcile. |
| Anything else | `LoadProfile` itself errored unexpectedly. The message is the raw error. |

When a load fails after the lock was taken, Razor Data clears the lock again so the player isn't locked out of other servers. Note that the record has already been written at that point: `Meta.LoadCount` and `Meta.LastLoaded` are updated, and a legacy value is wrapped in a Razor Data record. See [Migrations](migrations.md#when-migrations-run).

## Data and Meta

`profile.Data` is your save data. Before you get it, the stored data has been migrated and reconciled against the template, so every key from the template is there.

`profile.Meta` is a small table that Razor Data keeps up to date:

| Field | Description |
| --- | --- |
| `LoadCount` | How many times this key has been loaded. |
| `LastLoaded` | `os.time()` of the most recent load. |
| `LastSaved` | `os.time()` of the most recent successful save. It's only updated on the profile after the write is confirmed, so a failed save leaves it unchanged. |

`Meta` is saved along with the data, so you can add your own fields to it if you want to keep bookkeeping separate from game data.

## Saving

```lua
local ok = profile:Save()
```

`Save` yields until the write finishes and returns whether it worked. Saves for one profile never overlap: if one is in progress, the next waits for it.

A save is **skipped** (and returns `false`) in these cases, with a warning in the output:

- The data can't be encoded, for example because it contains a function or a cyclic table.
- The encoded data is bigger than 4 MB, the DataStore value limit.

When a save is skipped, the last successful save is left in the DataStore. Measuring the size means encoding the whole profile to JSON, so it's only done on the first save, after a failed save, on release, and while the profile is above 2 MB.

## Releasing

```lua
profile:Release()
```

`Release` does a final save and clears the lock in the same write. If the save fails or is skipped, Razor Data makes a second, lock-only write so the player can join another server straight away. That second write can also fail, for example during a DataStore outage. If it does, a warning is logged and the lock expires on its own after `LockTimeout`.

## The Released event

```lua
profile.Released:Connect(function(reason: string)
    -- reason is "Released" or "LostLock"
end)
```

`Released` fires once, when the profile becomes inactive:

- `"Released"`: `Release()` was called by you, `BindPlayers`, or the server shutting down.
- `"LostLock"`: a save found that another server now owns the key. This server stops saving so it can't overwrite newer data. You'll usually want to kick the player, which `BindPlayers` does.

## User IDs

```lua
profile:AddUserId(player.UserId)
```

User IDs are attached to every write as DataStore key metadata. Roblox uses this for GDPR "right to erasure" requests, so add the owning player's ID to any profile that holds their data. `BindPlayers` does this automatically.

## Autosave

Each store saves all its loaded profiles every `AutoSaveInterval` seconds. Every save also renews the session lock, so keep `AutoSaveInterval` well below `LockTimeout`.

## Server shutdown

Razor Data binds `game:BindToClose` and releases every loaded profile in every store. Releases run in parallel and it waits up to 25 seconds. Roblox gives `BindToClose` callbacks 30 seconds in total, so the 25-second wait leaves a margin for the last writes to finish. If you bind your own shutdown work, it shares that same 30-second budget.
