# Session Locking

When a player hops servers, the new server can load their data before the old one finishes saving. Without a lock, the old server's late save can overwrite progress made on the new server, or an item can be traded on one server and kept on the other. Razor Data prevents this by letting only one server own a key at a time.

## How it works

Every key is stored as a record:

```lua
{
    __rzRecord = true,
    Data = <encoded data>,
    SchemaVersion = 3,
    Lock = { JobId = "…", PlaceId = 123, Timestamp = 1731200000 },
    Meta = { LoadCount = 12, LastLoaded = …, LastSaved = … },
}
```

All reads and writes go through `UpdateAsync`, so checking and setting the lock happens in one atomic step.

- **Load** takes the lock if it's empty, already owned by this server, or older than `LockTimeout`. Otherwise it waits and retries.
- **Save** writes only if this server still owns the lock, and renews the lock's timestamp. If another server owns it, the profile shuts down with `"LostLock"`.
- **Release** writes the data and sets `Lock` to `nil` in one write.

In Studio `game.JobId` is empty, so each Studio session uses a random `studio-<guid>` ID instead.

## Retries while locked

If the key is locked by another server, `LoadProfile` retries with a delay that grows each attempt:

```
wait = RetryDelay * attempt
```

With the defaults (`LoadRetries = 6`, `RetryDelay = 5`) the waits are 5, 10, 15, 20 and 25 seconds. That gives the other server about 75 seconds to release before the load fails. In the usual server-hop case, the old server releases within a few seconds and the second attempt works.

## Dead locks

If a server crashes it never releases its locks. A lock is considered dead once its timestamp is older than `LockTimeout` seconds (1800 by default), and the next load takes it over.

Live servers renew their locks on every autosave, so a lock only goes stale when its server has stopped saving.

## Tuning

| Option | Default | Notes |
| --- | --- | --- |
| `AutoSaveInterval` | `60` | Also the lock renewal interval. |
| `LockTimeout` | `1800` | Must be comfortably more than `AutoSaveInterval`, or live locks will look dead. |
| `LoadRetries` | `6` | Attempts while another server holds the lock. |
| `RetryDelay` | `5` | Base delay in seconds, multiplied by the attempt number. |

A shorter `LockTimeout` gets players back in faster after a crash, but leaves less room for slow servers. Keep it at least a few times larger than `AutoSaveInterval`.

## DataStore errors

The lock retries above are separate from DataStore failures. Every `UpdateAsync` call:

1. Waits until there's request budget for `UpdateAsync`, checking once per second.
2. Tries up to 5 times, waiting 2, 4, 8 and 16 seconds between attempts.

If all 5 attempts fail, a load returns `"DataStore error: ..."` and a save returns `false`.
