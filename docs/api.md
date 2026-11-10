# API Reference

## RazorData

### RazorData.new

```lua
RazorData.new(config: Config): Store
```

Creates a store and starts its autosave loop. Server only. Create each store once, and don't create two stores for the same DataStore name and scope.

### RazorData.Serializer

The [serializer](serialization.md) module: `Encode`, `Decode`, `RegisterType` and `RegisterInstanceProperties`.

### RazorData.Migrations

The [migrations](migrations.md#using-the-migrator-directly) module: `new`, `Run` and `Reconcile`.

## Config

```lua
type Config = {
    Name: string,
    Template: { [any]: any },
    Migrations: { (data: any) -> any }?,
    Scope: string?,
    AutoSaveInterval: number?,
    LockTimeout: number?,
    LoadRetries: number?,
    RetryDelay: number?,
}
```

| Field | Default | Description |
| --- | --- | --- |
| `Name` | required | DataStore name. |
| `Template` | required | Starting data for new profiles. Missing keys in existing saves are filled from it. |
| `Migrations` | `{}` | Ordered list of upgrade functions. See [Migrations](migrations.md). |
| `Scope` | `nil` | DataStore scope. |
| `AutoSaveInterval` | `60` | Seconds between autosaves. Also renews the session lock. |
| `LockTimeout` | `1800` | Seconds before a lock that hasn't been renewed is considered dead. |
| `LoadRetries` | `6` | Load attempts while another server holds the lock. |
| `RetryDelay` | `5` | Base seconds between lock retries, multiplied by the attempt number. |

## Store

### Store:LoadProfile

```lua
store:LoadProfile(key: string | number): (Profile?, string?)
```

Yields. Loads and session-locks a key. Returns the profile, or `nil` and an error message. If the key is already loaded on this server, returns the existing profile. See [Loading](profiles.md#loading).

### Store:GetProfile

```lua
store:GetProfile(key: string | number): Profile?
```

Returns the loaded profile for a key, or `nil`. Doesn't yield.

### Store:BindPlayers

```lua
store:BindPlayers(onLoaded: ((player: Player, profile: Profile) -> ())?)
```

Loads a profile for every current and future player, keyed by `UserId`, and releases it when they leave. Players whose data fails to load are kicked, and players are kicked if the lock is lost. `onLoaded` is called once the profile is ready. Call it once per store.

### Store.Profiles

```lua
store.Profiles: { [string]: Profile }
```

Every active profile, keyed by string key. Read only.

## Profile

### Profile.Key

```lua
profile.Key: string
```

The DataStore key.

### Profile.Data

```lua
profile.Data: { [any]: any }
```

Your save data. Change it directly.

### Profile.Meta

```lua
profile.Meta: { LoadCount: number, LastLoaded: number, LastSaved: number?, [string]: any }
```

Bookkeeping saved with the profile. See [Data and Meta](profiles.md#data-and-meta).

### Profile.UserIds

```lua
profile.UserIds: { number }
```

User IDs attached to the key's metadata on each write. Add to it with `AddUserId`.

### Profile.Released

```lua
profile.Released: RBXScriptSignal<reason: "Released" | "LostLock">
```

Fires once when the profile becomes inactive. See [The Released event](profiles.md#the-released-event).

### Profile:IsActive

```lua
profile:IsActive(): boolean
```

`true` until the profile is released or loses its lock.

### Profile:Save

```lua
profile:Save(): boolean
```

Yields. Saves the data and renews the lock. Returns `false` if the save failed, was skipped, or the profile isn't active.

### Profile:Release

```lua
profile:Release(): boolean
```

Yields. Saves the data, clears the lock and makes the profile inactive. If the save fails, the profile is still shut down and a lock-only write is attempted; if that write fails too, the lock expires after `LockTimeout`. Returns whether the save worked. See [Releasing](profiles.md#releasing).

### Profile:AddUserId

```lua
profile:AddUserId(userId: number)
```

Adds a user ID to the key's metadata for GDPR requests. Duplicates are ignored.

## Serializer

### Serializer.Encode

```lua
Serializer.Encode(value: any): any
```

Converts a value to a JSON-safe form. Errors on unsupported types and cyclic tables.

### Serializer.Decode

```lua
Serializer.Decode(value: any): any
```

Converts an encoded value back.

### Serializer.RegisterType

```lua
Serializer.RegisterType(
    name: string,
    is: (value: any) -> boolean,
    encode: (value: any) -> any,
    decode: (encoded: any) -> any
)
```

Adds a custom table-based type. See [Custom types](serialization.md#custom-types).

### Serializer.RegisterInstanceProperties

```lua
Serializer.RegisterInstanceProperties(className: string, properties: { string })
```

Adds properties to save for a class and its subclasses. See [Adding properties](serialization.md#adding-properties).

## Migrations

### Migrations.new

```lua
Migrations.new(steps: { (data: any) -> any }): Migrator
```

Creates a migrator. `migrator.Latest` is `#steps`.

### Migrator:Run

```lua
migrator:Run(data: any, fromVersion: number): (any, number)
```

Runs every step after `fromVersion` and returns the upgraded data and the latest version. Errors if `fromVersion` is newer than `Latest` or a step errors.

### Migrations.Reconcile

```lua
Migrations.Reconcile(data: any, template: any): any
```

Fills missing keys in `data` from `template` and returns `data`. See [Reconciling with the template](migrations.md#reconciling-with-the-template).
