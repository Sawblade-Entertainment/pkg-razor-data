--!strict
-- RazorData: centralized DataService with session locking, migrations and DOM serialization.
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Serializer = require(script.Serializer)
local Migrations = require(script.Migrations)

local JOB_ID = if game.JobId ~= "" then game.JobId else ("studio-" .. HttpService:GenerateGUID(false))
local MAX_BYTES = 4_000_000
local RECORD_MARK = "__rzRecord"

export type Config = {
    Name: string,
    Template: { [any]: any },
    Migrations: { (data: any) -> any }?,
    Scope: string?,
    AutoSaveInterval: number?, -- seconds (default 60)
    LockTimeout: number?, -- seconds before a lock is considered dead (default 1800)
    LoadRetries: number?, -- attempts while locked by another server (default 6)
    RetryDelay: number?, -- base seconds between lock retries (default 5)
}

local RazorData = {}
RazorData.Serializer = Serializer
RazorData.Migrations = Migrations

local Store = {}
Store.__index = Store

local Profile = {}
Profile.__index = Profile

local activeStores = {}

local function deepCopy(t: any): any
    if type(t) ~= "table" then
        return t
    end
    local c = {}
    for k, v in t do
        c[deepCopy(k)] = deepCopy(v)
    end
    return c
end

-- Overridable so tests can simulate an empty budget without spending real quota.
function RazorData._getBudget(requestType: Enum.DataStoreRequestType): number
    return DataStoreService:GetRequestBudgetForRequestType(requestType)
end

local function waitForBudget(requestType: Enum.DataStoreRequestType)
    while RazorData._getBudget(requestType) < 1 do
        task.wait(1)
    end
end

-- UpdateAsync with exponential backoff. Returns ok, result/err.
local function safeUpdate(ds: DataStore, key: string, fn: (any, any) -> ...any): (boolean, any)
    local lastErr
    for attempt = 1, 5 do
        waitForBudget(Enum.DataStoreRequestType.UpdateAsync)
        local ok, result = pcall(ds.UpdateAsync, ds, key, fn)
        if ok then
            return true, result
        end
        lastErr = result
        if attempt < 5 then
            task.wait(math.min(2 ^ attempt, 30))
        end
    end
    return false, lastErr
end

local function newRecord(): any
    return { [RECORD_MARK] = true, Data = nil, SchemaVersion = 0, Lock = nil, Meta = {} }
end

-- Wrap legacy/raw values that predate this library (treated as schema version 0).
local function normalize(raw: any): any
    if raw == nil then
        return nil
    end
    if type(raw) == "table" and raw[RECORD_MARK] then
        return raw
    end
    local rec = newRecord()
    rec.Data = raw
    rec.SchemaVersion = 0
    return rec
end

-- Clears this server's lock without touching the data, so a failed load or release doesn't
-- block other servers until LockTimeout.
local function unlock(ds: DataStore, key: string)
    local ok, err = safeUpdate(ds, key, function(raw, keyInfo: DataStoreKeyInfo?)
        local rec = normalize(raw)
        if not rec or not rec.Lock or rec.Lock.JobId ~= JOB_ID then
            return nil
        end
        rec.Lock = nil
        if keyInfo then
            return rec, keyInfo:GetUserIds(), keyInfo:GetMetadata()
        end
        return rec
    end)
    if not ok then
        warn(`[RazorData] Unlock failed for {key}: {err}`)
    end
end

---------------------------------------------------------------- Store

function RazorData.new(config: Config)
    assert(RunService:IsServer(), "RazorData can only be used on the server")
    assert(type(config.Name) == "string", "Config.Name required")
    assert(type(config.Template) == "table", "Config.Template required")
    local self = setmetatable({}, Store)
    self.Config = config
    self.Migrator = Migrations.new(config.Migrations or {})
    self.DataStore = DataStoreService:GetDataStore(config.Name, config.Scope)
    self.Profiles = {} :: { [string]: any }
    self._loading = {} :: { [string]: boolean }
    self.AutoSaveInterval = config.AutoSaveInterval or 60
    self.LockTimeout = config.LockTimeout or 1800
    table.insert(activeStores, self)
    self:_startAutoSave()
    return self
end

function Store:_startAutoSave()
    task.spawn(function()
        while true do
            task.wait(self.AutoSaveInterval)
            for _, profile in self.Profiles do
                task.spawn(profile.Save, profile)
            end
        end
    end)
end

-- Loads and session-locks a profile. Returns profile or nil, errorMessage.
function Store:LoadProfile(key: string | number): (any?, string?)
    key = tostring(key)
    -- Concurrent loads of the same key wait for the first one instead of building a second profile.
    while self._loading[key] do
        task.wait()
    end
    if self.Profiles[key] then
        return self.Profiles[key], nil
    end
    self._loading[key] = true
    local ok, profile, err = pcall(self._loadProfile, self, key)
    self._loading[key] = nil
    if not ok then
        return nil, tostring(profile)
    end
    return profile, err
end

function Store:_loadProfile(key: string): (any?, string?)
    local cfg = self.Config
    local retries = cfg.LoadRetries or 6
    local delay = cfg.RetryDelay or 5

    for attempt = 1, retries do
        local blocked = false
        local tooNew = false
        local ok, result = safeUpdate(self.DataStore, key, function(raw)
            blocked, tooNew = false, false
            local rec = normalize(raw) or newRecord()
            if rec.SchemaVersion > self.Migrator.Latest then
                tooNew = true
                return nil -- cancel write
            end
            local lock = rec.Lock
            local now = os.time()
            if lock and lock.JobId ~= JOB_ID and (now - lock.Timestamp) < self.LockTimeout then
                blocked = true
                return nil -- cancel write, someone else owns it
            end
            rec.Lock = { JobId = JOB_ID, PlaceId = game.PlaceId, Timestamp = now }
            rec.Meta.LoadCount = (rec.Meta.LoadCount or 0) + 1
            rec.Meta.LastLoaded = now
            return rec
        end)

        if not ok then
            return nil, "DataStore error: " .. tostring(result)
        end
        if tooNew then
            return nil, "Record schema is newer than this server; refusing to load"
        end
        if not blocked and result then
            local okBuild, profile, err = pcall(self._buildProfile, self, key, result)
            if not okBuild then
                profile, err = nil, "Profile build failed: " .. tostring(profile)
            end
            if not profile then
                -- Drop the lock we just took so the player isn't locked out elsewhere.
                unlock(self.DataStore, key)
            end
            return profile, err
        end
        if attempt < retries then
            task.wait(delay * attempt)
        end
    end
    return nil, "Profile is session-locked by another server"
end

function Store:_buildProfile(key: string, rec: any): (any?, string?)
    local data
    if rec.Data == nil then
        data = deepCopy(self.Config.Template)
        rec.SchemaVersion = self.Migrator.Latest
    else
        local okDecode, decoded = pcall(Serializer.Decode, rec.Data)
        if not okDecode then
            return nil, "Decode failed: " .. tostring(decoded)
        end
        local okMig, migrated, version = pcall(self.Migrator.Run, self.Migrator, decoded, rec.SchemaVersion)
        if not okMig then
            return nil, "Migration failed: " .. tostring(migrated)
        end
        data = Migrations.Reconcile(migrated, self.Config.Template)
        rec.SchemaVersion = version
    end

    local profile = setmetatable({
        Key = key,
        Data = data,
        Meta = rec.Meta,
        UserIds = {},
        _store = self,
        _schemaVersion = rec.SchemaVersion,
        _active = true,
        _saving = false,
        _lastSize = nil :: number?,
        _lastFailed = false,
        _releasedEvent = Instance.new("BindableEvent"),
    }, Profile)
    profile.Released = profile._releasedEvent.Event
    self.Profiles[key] = profile
    return profile, nil
end

function Store:GetProfile(key: string | number): any?
    return self.Profiles[tostring(key)]
end

-- Optional: wire up player join/leave automatically. Kicks players whose data can't load.
function Store:BindPlayers(onLoaded: ((Player, any) -> ())?)
    for _, p in Players:GetPlayers() do
        task.spawn(self._playerJoined, self, p, onLoaded)
    end
    Players.PlayerAdded:Connect(function(player)
        self:_playerJoined(player, onLoaded)
    end)
    Players.PlayerRemoving:Connect(function(player)
        self:_playerLeft(player)
    end)
end

function Store:_playerJoined(player: Player, onLoaded: ((Player, any) -> ())?)
    local profile, err = self:LoadProfile(player.UserId)
    if not profile then
        player:Kick("Your data failed to load, please rejoin. (" .. tostring(err) .. ")")
        return
    end
    profile:AddUserId(player.UserId)
    if not player:IsDescendantOf(Players) then
        profile:Release()
        return
    end
    profile.Released:Connect(function(reason: string)
        if reason == "LostLock" and player:IsDescendantOf(Players) then
            player:Kick("Your data was loaded on another server.")
        end
    end)
    if onLoaded then
        onLoaded(player, profile)
    end
end

function Store:_playerLeft(player: Player)
    local profile = self:GetProfile(player.UserId)
    if profile then
        profile:Release()
    end
end

---------------------------------------------------------------- Profile

function Profile:IsActive(): boolean
    return self._active
end

function Profile:AddUserId(userId: number)
    if not table.find(self.UserIds, userId) then
        table.insert(self.UserIds, userId)
    end
end

function Profile:_write(release: boolean): boolean
    if not self._active then
        return false
    end
    while self._saving do
        task.wait()
    end
    if not self._active then
        return false
    end
    self._saving = true

    -- Measuring size costs a full JSONEncode, so only do it while the profile could be near the limit.
    -- Releases always measure: an oversized final write would fail and leave the lock behind.
    local measure = release or self._lastSize == nil or self._lastSize > MAX_BYTES // 2 or self._lastFailed
    local okEncode, encoded, size = pcall(function()
        local e = Serializer.Encode(self.Data)
        return e, if measure then #HttpService:JSONEncode(e) else nil
    end)
    if not okEncode then
        warn(`[RazorData] Encode failed for {self.Key}: {encoded}; save skipped`)
        return self:_skipWrite(release)
    end
    if size then
        self._lastSize = size
        if size > MAX_BYTES then
            warn(`[RazorData] {self.Key} exceeds 4MB ({size} bytes); save skipped`)
            return self:_skipWrite(release)
        end
    end

    local lostLock = false
    local savedAt = 0
    local ok, err = safeUpdate(self._store.DataStore, self.Key, function(raw)
        lostLock = false
        local rec = normalize(raw) or newRecord()
        -- Only write while this server owns the lock. An empty lock means another server took
        -- the key and released it, so our data is stale and must not be written back.
        if not rec.Lock or rec.Lock.JobId ~= JOB_ID then
            lostLock = true
            return nil
        end
        local now = os.time()
        -- Stamp a copy so Meta.LastSaved only changes on the profile once the write succeeds.
        local meta = table.clone(self.Meta)
        meta.LastSaved = now
        savedAt = now
        rec.Data = encoded
        rec.SchemaVersion = self._schemaVersion
        rec.Meta = meta
        rec.Lock = if release then nil else { JobId = JOB_ID, PlaceId = game.PlaceId, Timestamp = now }
        return rec, self.UserIds
    end)
    self._lastFailed = not ok
    if ok and not lostLock then
        self.Meta.LastSaved = savedAt
    end

    if not ok then
        warn(`[RazorData] Save failed for {self.Key}: {err}`)
        if release then
            -- Best effort: the write may have failed for a reason the lock-only update avoids.
            unlock(self._store.DataStore, self.Key)
        end
    end
    self._saving = false
    if lostLock then
        warn(`[RazorData] Session lock for {self.Key} was taken by another server`)
        self:_shutdown("LostLock")
        return false
    end
    -- Shut down on release even if the write failed, so autosave stops renewing the lock.
    if release then
        self:_shutdown("Released")
    end
    return ok
end

-- Data that can't be written is kept as last saved; a release still frees the lock and shuts down.
-- The lock is cleared before shutdown so a reload on this server can't take it first and lose it.
function Profile:_skipWrite(release: boolean): boolean
    if release then
        unlock(self._store.DataStore, self.Key)
    end
    self._saving = false
    if release then
        self:_shutdown("Released")
    end
    return false
end

function Profile:Save(): boolean
    return self:_write(false)
end

function Profile:Release(): boolean
    return self:_write(true)
end

-- Released fires with "LostLock" (another server took the session) or "Released".
function Profile:_shutdown(reason: string)
    if not self._active then
        return
    end
    self._active = false
    self._store.Profiles[self.Key] = nil
    self._releasedEvent:Fire(reason)
    self._releasedEvent:Destroy()
end

---------------------------------------------------------------- Shutdown

-- Releases every loaded profile, waiting at most `timeout` seconds. Roblox gives BindToClose 30
-- seconds, so the default of 25 leaves a margin for the last writes to finish.
function RazorData._releaseAll(timeout: number?)
    local pending = 0
    for _, store in activeStores do
        for _, profile in store.Profiles do
            pending += 1
            task.spawn(function()
                local ok, err = pcall(profile.Release, profile)
                if not ok then
                    warn(`[RazorData] Release failed for {profile.Key} on shutdown: {err}`)
                end
                pending -= 1
            end)
        end
    end
    local start = os.clock()
    while pending > 0 and os.clock() - start < (timeout or 25) do
        task.wait()
    end
end

game:BindToClose(function()
    RazorData._releaseAll()
end)

return RazorData