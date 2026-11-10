RazorData = use "razordata"
HttpService = use "HttpService"
DataStoreService = use "DataStoreService"
Players = use "Players"

local S = RazorData.Serializer
local M = RazorData.Migrations

local STORE_NAME = "RazorDataTest"
local RUN_ID = string.sub(HttpService:GenerateGUID(false), 1, 8)
local RUN_SLOW = true -- DataStore failure tests wait through the full ~30s backoff
local KICK_PLAYER = true -- kicks the Play session's player near the end to test PlayerRemoving
local PROBE_KEY = "shutdown-probe" -- left loaded each run; the next run checks BindToClose released it

---------------------------------------------------------------- Harness

local stats = { passed = 0, failed = 0, skipped = 0 }
local failures = {}
local section = ""

local function log(msg: string)
    print(`[RazorData:Test] {msg}`)
end

local function describe(name: string)
    section = name
    log(`-- {name}`)
end

local function test(name: string, fn: () -> ())
    local started = os.clock()
    local ok, err = xpcall(fn, debug.traceback)
    local ms = math.round((os.clock() - started) * 1000)
    if ok then
        stats.passed += 1
        log(`  PASS {name} ({ms}ms)`)
    else
        stats.failed += 1
        table.insert(failures, `{section} > {name}`)
        warn(`[RazorData:Test]   FAIL {name} ({ms}ms)\n{err}`)
    end
end

local function skip(name: string, reason: string)
    stats.skipped += 1
    log(`  SKIP {name}: {reason}`)
end

local function fmt(v: any): string
    if type(v) == "string" then
        return string.format("%q", if #v > 80 then string.sub(v, 1, 80) .. "..." else v)
    end
    return `{typeof(v)}({tostring(v)})`
end

local function expect(cond: any, label: string)
    if not cond then
        error(label, 2)
    end
end

local function expectEq(actual: any, expected: any, label: string)
    if actual ~= expected then
        error(`{label}: expected {fmt(expected)}, got {fmt(actual)}`, 2)
    end
end

local function expectError(fn: () -> any, contains: string, label: string)
    local ok, err = pcall(fn)
    if ok then
        error(`{label}: expected an error containing {fmt(contains)}`, 2)
    end
    if not string.find(tostring(err), contains, 1, true) then
        error(`{label}: error {fmt(tostring(err))} does not contain {fmt(contains)}`, 2)
    end
end

-- Encodes through real JSON so tests catch values that only survive in memory.
local function roundTrip(value: any): any
    return S.Decode(HttpService:JSONDecode(HttpService:JSONEncode(S.Encode({ v = value })))).v
end

-- Datatypes without a usable == are compared through their components.
local function same(a: any, b: any): boolean
    local t = typeof(a)
    if t ~= typeof(b) then
        return false
    elseif t == "buffer" then
        return buffer.tostring(a) == buffer.tostring(b)
    elseif t == "DateTime" then
        return a.UnixTimestampMillis == b.UnixTimestampMillis
    elseif t == "Region3" then
        return a.CFrame == b.CFrame and a.Size == b.Size
    elseif t == "Ray" then
        return a.Origin == b.Origin and a.Direction == b.Direction
    elseif t == "Font" then
        return a.Family == b.Family and a.Weight == b.Weight and a.Style == b.Style
    elseif t == "Faces" or t == "Axes" then
        return tostring(a) == tostring(b)
    end
    return a == b
end

---------------------------------------------------------------- Serializer

local function serializerTests()
    describe("Serializer: primitives")

    test("passes through nil, booleans, strings and finite numbers", function()
        expectEq(S.Encode(nil), nil, "nil")
        for _, v in { true, false, "", "héllo ✓", 0, -12.75, 123456789 } do
            expectEq(roundTrip(v), v, fmt(v))
        end
    end)

    test("round-trips NaN and both infinities", function()
        local nan = roundTrip(0 / 0)
        expect(nan ~= nan, `NaN: got {fmt(nan)}`)
        expectEq(roundTrip(math.huge), math.huge, "+inf")
        expectEq(roundTrip(-math.huge), -math.huge, "-inf")
    end)

    describe("Serializer: Roblox datatypes")

    local datatypes = {
        Vector2.new(1.5, -2),
        Vector3.new(1, 2, 3),
        Vector2int16.new(4, -5),
        Vector3int16.new(6, -7, 8),
        CFrame.new(1, 2, 3) * CFrame.Angles(0, 1, 0),
        Color3.new(1, 0, 0.5),
        BrickColor.new("Bright red"),
        UDim.new(0.25, 10),
        UDim2.new(0.5, 10, 0.25, -4),
        Rect.new(1, 2, 3, 4),
        NumberRange.new(1, 5),
        NumberSequence.new({ NumberSequenceKeypoint.new(0, 0, 0.25), NumberSequenceKeypoint.new(1, 1) }),
        ColorSequence.new(Color3.new(1, 0, 0), Color3.new(0, 0, 1)),
        Enum.Material.Neon,
        Enum.Material,
        DateTime.fromUnixTimestampMillis(1700000000123),
        Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold, Enum.FontStyle.Italic),
        PhysicalProperties.new(0.7, 0.3, 0.5, 1, 1),
        Ray.new(Vector3.new(1, 2, 3), Vector3.new(0, -10, 0)),
        Region3.new(Vector3.new(0, 0, 0), Vector3.new(4, 6, 8)),
        Region3int16.new(Vector3int16.new(0, 0, 0), Vector3int16.new(4, 6, 8)),
        Faces.new(Enum.NormalId.Top, Enum.NormalId.Left),
        Axes.new(Enum.Axis.X, Enum.Axis.Z),
        TweenInfo.new(2, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 3, true, 0.5),
        buffer.fromstring("\0\1\2RazorData\255"),
    }
    for _, value in datatypes do
        local kind = typeof(value)
        test(`round-trips {kind}`, function()
            expectEq(S.Encode(value).__rz, kind, "encoded tag")
            local decoded = roundTrip(value)
            expect(same(decoded, value), `expected {fmt(value)}, got {fmt(decoded)}`)
        end)
    end

    describe("Serializer: tables")

    test("round-trips nested arrays and dictionaries", function()
        local decoded = roundTrip({ list = { 1, "two", { 3 } }, nested = { deep = { flag = true } }, empty = {} })
        expectEq(#decoded.list, 3, "array length")
        expectEq(decoded.list[2], "two", "array value")
        expectEq(decoded.list[3][1], 3, "nested array")
        expectEq(decoded.nested.deep.flag, true, "nested dictionary")
        expectEq(next(decoded.empty), nil, "empty table")
    end)

    test("round-trips sparse arrays and non-string keys", function()
        local decoded = roundTrip({ [1] = "a", [5] = "b", [2.5] = "half", [true] = "yes", key = "k" })
        expectEq(decoded[1], "a", "[1]")
        expectEq(decoded[5], "b", "[5]")
        expectEq(decoded[2.5], "half", "[2.5]")
        expectEq(decoded[true], "yes", "[true]")
        expectEq(decoded.key, "k", ".key")
    end)

    test("user tables containing the type tag key are not mistaken for datatypes", function()
        local decoded = roundTrip({ __rz = "Vector3", v = { 1, 2, 3 } })
        expectEq(typeof(decoded), "table", "decoded type")
        expectEq(decoded.__rz, "Vector3", "__rz key")
        expectEq(decoded.v[3], 3, "v key")
    end)

    test("allows the same table to appear twice without a cycle", function()
        local shared = { 1, 2 }
        local decoded = roundTrip({ a = shared, b = shared })
        expectEq(decoded.a[2], 2, "a")
        expectEq(decoded.b[2], 2, "b")
    end)

    test("rejects cyclic tables", function()
        local cyclic = {}
        cyclic.self = cyclic
        expectError(function()
            S.Encode(cyclic)
        end, "cyclic", "cyclic table")
    end)

    test("rejects unsupported types", function()
        expectError(function()
            S.Encode({ fn = function() end })
        end, "cannot serialize type 'function'", "function value")
    end)

    test("leaves unknown type tags raw", function()
        local decoded = S.Decode({ __rz = "NoSuchType", v = 1 })
        expectEq(decoded.__rz, "NoSuchType", "raw tag")
        expectEq(decoded.v, 1, "raw value")
    end)

    test("supports custom types via RegisterType", function()
        local Money = {}
        S.RegisterType("TestMoney", function(v)
            return getmetatable(v) == Money
        end, function(v)
            return v.cents
        end, function(cents)
            return setmetatable({ cents = cents }, Money)
        end)
        local decoded = roundTrip({ wallet = setmetatable({ cents = 1999 }, Money) })
        expectEq(getmetatable(decoded.wallet), Money, "metatable")
        expectEq(decoded.wallet.cents, 1999, "cents")
    end)

    describe("Serializer: instances")

    test("round-trips properties, attributes, tags and children", function()
        local part = new "Part"
        part.Name = "Crate"
        part.Size = Vector3.new(2, 3, 4)
        part.Material = Enum.Material.Wood
        part.Shape = Enum.PartType.Ball
        part.Anchored = true
        part:SetAttribute("Owner", "abc")
        part:SetAttribute("Offset", Vector3.new(1, 1, 1))
        part:AddTag("Loot")
        local count = new "IntValue"
        count.Name = "Count"
        count.Value = 7
        count.Parent = part
        local hidden = new "Folder"
        hidden.Name = "Hidden"
        hidden.Archivable = false
        hidden.Parent = part
        local ref = new "ObjectValue"
        ref.Name = "Ref"
        ref.Value = workspace
        ref.Parent = part

        local decoded = roundTrip({ items = { part } }).items[1]
        part:Destroy()
        expectEq(decoded.ClassName, "Part", "ClassName")
        expectEq(decoded.Name, "Crate", "Name")
        expectEq(decoded.Size, Vector3.new(2, 3, 4), "Size")
        expectEq(decoded.Material, Enum.Material.Wood, "Material")
        expectEq(decoded.Shape, Enum.PartType.Ball, "Shape")
        expectEq(decoded.Anchored, true, "Anchored")
        expectEq(decoded:GetAttribute("Owner"), "abc", "string attribute")
        expectEq(decoded:GetAttribute("Offset"), Vector3.new(1, 1, 1), "Vector3 attribute")
        expect(decoded:HasTag("Loot"), "tag missing")
        expectEq(decoded.Count.Value, 7, "child IntValue")
        expectEq(decoded:FindFirstChild("Hidden"), nil, "non-Archivable child")
        expectEq(decoded.Ref.Value, nil, "Instance-valued property")
        decoded:Destroy()
    end)

    test("skips instances whose class cannot be created", function()
        expectEq(S.Decode({ __rz = "Instance", v = { C = "NotARealClass", N = "Ghost" } }), nil, "top level")
        local folder = S.Decode({
            __rz = "Instance",
            v = { C = "Folder", N = "Parent", K = { { C = "NotARealClass", N = "Ghost" }, { C = "Folder", N = "Real" } } },
        })
        expectEq(#folder:GetChildren(), 1, "child count")
        expect(folder:FindFirstChild("Real"), "valid sibling missing")
        folder:Destroy()
    end)

    test("persists extra properties via RegisterInstanceProperties", function()
        S.RegisterInstanceProperties("PointLight", { "Range" })
        local light = new "PointLight"
        light.Range = 13
        local decoded = roundTrip(light)
        light:Destroy()
        expectEq(decoded.Range, 13, "Range")
        decoded:Destroy()
    end)
end

---------------------------------------------------------------- Migrations

local function migrationTests()
    describe("Migrations")

    local migrator = M.new({
        function(d)
            d.Coins = d.Gold or 0
            d.Gold = nil
        end,
        function(d)
            d.Inventory = d.Inventory or {}
        end,
        function(d)
            return { Wrapped = d } -- steps may replace the data
        end,
    })

    test("rejects non-function steps", function()
        expectError(function()
            M.new({ function() end, "nope" :: any })
        end, "Migration 2 must be a function", "bad step")
    end)

    test("runs every step from version 0", function()
        local data, version = migrator:Run({ Gold = 50 }, 0)
        expectEq(version, 3, "version")
        expectEq(data.Wrapped.Coins, 50, "Coins")
        expectEq(data.Wrapped.Gold, nil, "Gold")
        expectEq(typeof(data.Wrapped.Inventory), "table", "Inventory")
    end)

    test("treats a nil version as 0", function()
        local data = migrator:Run({ Gold = 1 }, nil :: any)
        expectEq(data.Wrapped.Coins, 1, "Coins")
    end)

    test("runs only steps after fromVersion", function()
        local data, version = migrator:Run({ Coins = 9 }, 2)
        expectEq(version, 3, "version")
        expectEq(data.Wrapped.Coins, 9, "Coins")
        expectEq(data.Wrapped.Inventory, nil, "step 2 skipped")
    end)

    test("is a no-op at the latest version", function()
        local input = { Coins = 1 }
        local data, version = migrator:Run(input, 3)
        expectEq(data, input, "same table")
        expectEq(version, 3, "version")
    end)

    test("errors on data newer than the latest step", function()
        expectError(function()
            migrator:Run({}, 4)
        end, "newer than latest", "version 4")
    end)

    test("names the failing step", function()
        local failing = M.new({ function() end, function()
            error("boom")
        end })
        expectError(function()
            failing:Run({}, 0)
        end, "Migration 2 failed", "failing step")
    end)

    describe("Migrations.Reconcile")

    test("fills missing keys without overwriting existing ones", function()
        local data = M.Reconcile({ Coins = 5, Settings = { Music = false } }, {
            Coins = 0,
            Level = 1,
            Settings = { Music = true, Sfx = true },
        })
        expectEq(data.Coins, 5, "Coins kept")
        expectEq(data.Level, 1, "Level filled")
        expectEq(data.Settings.Music, false, "nested value kept")
        expectEq(data.Settings.Sfx, true, "nested key filled")
    end)

    test("copies template tables instead of aliasing them", function()
        local template = { Settings = { Music = true } }
        local data = M.Reconcile({}, template)
        expect(data.Settings ~= template.Settings, "template table was aliased")
        expectEq(data.Settings.Music, true, "copied value")
    end)

    test("does not merge array template entries into existing arrays", function()
        local data = M.Reconcile({ Items = { "sword" } }, { Items = { "starter", "potion" } })
        expectEq(#data.Items, 1, "Items length")
        expectEq(data.Items[1], "sword", "Items[1]")
        expectEq(#M.Reconcile({}, { Items = { "starter" } }).Items, 1, "array used as default")
    end)

    test("replaces non-table data with the template", function()
        expectEq(M.Reconcile("corrupt", { Coins = 0 }).Coins, 0, "Coins")
    end)
end

---------------------------------------------------------------- Store (live DataStore)

local rawStore = DataStoreService:GetDataStore(STORE_NAME)
local noCache = new "DataStoreGetOptions"
noCache.UseCache = false
local usedKeys: { { scope: string?, key: string } } = {}

-- Bypasses the 4s GetAsync cache so reads see writes made moments ago.
local function readRaw(key: string, scope: string?): (any, DataStoreKeyInfo)
    local ds = if scope then DataStoreService:GetDataStore(STORE_NAME, scope) else rawStore
    return ds:GetAsync(key, noCache)
end

local function freshKey(name: string): string
    local key = `{RUN_ID}-{name}`
    table.insert(usedKeys, { key = key })
    return key
end

local function newStore(overrides: { [string]: any }?)
    local config = { Name = STORE_NAME, Template = { Coins = 0, Settings = { Music = true } }, LoadRetries = 1, RetryDelay = 0 }
    for k, v in overrides or {} do
        config[k] = v
    end
    return RazorData.new(config)
end

local function record(fields: { [string]: any }): any
    local rec = { __rzRecord = true, Data = { Coins = 1 }, SchemaVersion = 0, Meta = {} }
    for k, v in fields do
        rec[k] = v
    end
    return rec
end

local function otherLock(age: number): any
    return { JobId = "other-server", PlaceId = 0, Timestamp = os.time() - age }
end

-- Stands in for a Player so join, leave and kick paths run without disconnecting a real client.
local function fakePlayer(): any
    local userId = math.random(1e9, 2e9)
    table.insert(usedKeys, { key = tostring(userId) })
    local fake = { UserId = userId, InGame = true, Kicked = nil :: string? }
    function fake:Kick(message: string)
        self.Kicked = message
        self.InGame = false
    end
    function fake:IsDescendantOf(ancestor: Instance): boolean
        return self.InGame and ancestor == Players
    end
    return fake
end

local function load(store: any, key: string | number): any
    local profile, err = store:LoadProfile(key)
    expect(profile, `LoadProfile({key}) failed: {err}`)
    return profile
end

local function watchReleased(profile: any): () -> string?
    local reason
    profile.Released:Connect(function(r)
        reason = r
    end)
    return function()
        task.wait() -- deferred signals fire on the next resumption point
        return reason
    end
end

local function preflight(): boolean
    local ok, err
    for attempt = 1, 3 do
        ok, err = pcall(rawStore.GetAsync, rawStore, "preflight")
        if ok then
            return true
        end
        log(`DataStore preflight attempt {attempt}/3 failed: {err}`)
        task.wait(attempt * 2)
    end
    warn(`[RazorData:Test] DataStore unavailable: {err}\n  If this persists, check Game Settings > Security > Enable Studio Access to API Services`)
    return false
end

-- Bound from init, before the player joins, so PlayerAdded is what loads them. If the DataStore is
-- unavailable the player gets kicked once the load gives up (~30s), as BindPlayers would in a real game.
local joinStore: any
local joined: { [Player]: any } = {}
local joinedVia = ""

local function bindPlayersEarly()
    joinedVia = if #Players:GetPlayers() == 0 then "PlayerAdded" else "players present at bind"
    joinStore = newStore({ Scope = RUN_ID })
    joinStore:BindPlayers(function(player, profile)
        joined[player] = profile
    end)
end

local function storeTests(available: boolean)
    describe("Store: setup")

    if not available then
        skip("Store tests", "DataStore unavailable")
        return
    end

    local probe = readRaw(PROBE_KEY)
    if not probe then
        skip("BindToClose released the last run's profile", "no earlier run; stop this Play session and run again")
    else
        test("BindToClose released the last run's profile", function()
            expect(probe.Data and probe.Data.RunId, "last run's data was never saved")
            log(`    last run {probe.Data.RunId}`)
            expectEq(probe.Lock, nil, `lock left by run {probe.Data.RunId}`)
        end)
    end

    test("validates config", function()
        expectError(function()
            RazorData.new({ Template = {} } :: any)
        end, "Config.Name required", "missing Name")
        expectError(function()
            RazorData.new({ Name = STORE_NAME } :: any)
        end, "Config.Template required", "missing Template")
    end)

    local store = newStore()

    describe("Store: load, save, release")

    test("loads a fresh profile from a copy of the template", function()
        local key = freshKey("fresh")
        local profile = load(store, key)
        expectEq(profile.Data.Coins, 0, "Coins")
        expect(profile.Data.Settings ~= store.Config.Template.Settings, "template table was aliased")
        expect(profile:IsActive(), "profile inactive")
        expectEq(profile.Meta.LoadCount, 1, "LoadCount")
        expectEq(store:GetProfile(key), profile, "GetProfile")
        expectEq(store:LoadProfile(key), profile, "second LoadProfile")
        profile:Release()
    end)

    test("accepts numeric keys", function()
        local id = math.random(1e9, 2e9)
        table.insert(usedKeys, { key = tostring(id) })
        local profile = load(store, id)
        expectEq(profile.Key, tostring(id), "Key")
        expectEq(store:GetProfile(id), profile, "GetProfile(number)")
        profile:Release()
    end)

    test("concurrent loads of one key share a profile", function()
        local key = freshKey("concurrent")
        local results = {}
        for i = 1, 2 do
            task.spawn(function()
                results[i] = store:LoadProfile(key)
            end)
        end
        local started = os.clock()
        while not (results[1] and results[2]) and os.clock() - started < 15 do
            task.wait()
        end
        expect(results[1] and results[2], "loads did not finish")
        expectEq(results[1], results[2], "profiles differ")
        expectEq(results[1].Meta.LoadCount, 1, "LoadCount")
        results[1]:Release()
    end)

    local persistKey = freshKey("persist")

    test("Save writes encoded data and renews the lock", function()
        local profile = load(store, persistKey)
        profile.Data.Coins += 5
        profile.Data.Spawn = Vector3.new(1, 2, 3)
        expect(profile:Save(), "Save returned false")
        local rec = readRaw(persistKey)
        expectEq(rec.Data.Coins, 5, "stored Coins")
        expectEq(rec.Data.Spawn.__rz, "Vector3", "stored Spawn tag")
        expect(rec.Lock and rec.Lock.JobId ~= "other-server", "lock missing")
        expect(rec.Meta.LastSaved, "LastSaved missing")
    end)

    test("Release unlocks and deactivates the profile", function()
        local profile = store:GetProfile(persistKey)
        expect(profile, "profile from previous test missing")
        local reason = watchReleased(profile)
        expect(profile:Release(), "Release returned false")
        expectEq(reason(), "Released", "Released reason")
        expect(not profile:IsActive(), "still active")
        expectEq(store:GetProfile(persistKey), nil, "still registered")
        expectEq(readRaw(persistKey).Lock, nil, "stored lock")
        expect(not profile:Save(), "Save after release returned true")
        expect(not profile:Release(), "second Release returned true")
    end)

    test("reload restores saved data", function()
        local profile = load(store, persistKey)
        expectEq(profile.Data.Coins, 5, "Coins")
        expectEq(profile.Data.Spawn, Vector3.new(1, 2, 3), "Spawn")
        expectEq(profile.Meta.LoadCount, 2, "LoadCount")
        profile:Release()
    end)

    test("AddUserId dedupes and saves user ids", function()
        local key = freshKey("userids")
        local profile = load(store, key)
        profile:AddUserId(1)
        profile:AddUserId(1)
        expectEq(#profile.UserIds, 1, "UserIds length")
        expect(profile:Save(), "Save returned false")
        local _, keyInfo = readRaw(key)
        expectEq(keyInfo:GetUserIds()[1], 1, "stored user id")
        profile:Release()
    end)

    test("a save queued behind a release is dropped", function()
        local profile = load(store, freshKey("queued"))
        local released
        task.spawn(function()
            released = profile:Release()
        end)
        expect(not profile:Save(), "queued Save returned true")
        expect(released, "Release returned false")
    end)

    describe("Store: migrations and records")

    test("migrates and reconciles legacy raw values", function()
        local key = freshKey("legacy")
        rawStore:SetAsync(key, { Gold = 50 })
        local migrating = newStore({
            Template = { Coins = 0, Inventory = {}, Level = 1 },
            Migrations = {
                function(d)
                    d.Coins = d.Gold or 0
                    d.Gold = nil
                end,
                function(d)
                    d.Inventory = d.Inventory or {}
                end,
            },
        })
        local profile = load(migrating, key)
        expectEq(profile.Data.Coins, 50, "Coins")
        expectEq(profile.Data.Gold, nil, "Gold")
        expectEq(profile.Data.Level, 1, "Level")
        profile:Release()
        expectEq(readRaw(key).SchemaVersion, 2, "stored SchemaVersion")
    end)

    test("refuses records with a newer schema", function()
        local key = freshKey("toonew")
        rawStore:SetAsync(key, record({ SchemaVersion = 99 }))
        local profile, loadErr = store:LoadProfile(key)
        expectEq(profile, nil, "profile")
        expect(string.find(tostring(loadErr), "newer", 1, true), `unexpected error {fmt(loadErr)}`)
    end)

    test("a failing migration errors and drops the lock", function()
        local key = freshKey("badmigration")
        rawStore:SetAsync(key, { Gold = 1 })
        local failing = newStore({ Migrations = { function()
            error("boom")
        end } })
        local profile, loadErr = failing:LoadProfile(key)
        expectEq(profile, nil, "profile")
        expect(string.find(tostring(loadErr), "Migration failed", 1, true), `unexpected error {fmt(loadErr)}`)
        expectEq(readRaw(key).Lock, nil, "stored lock")
    end)

    test("corrupt data errors and drops the lock", function()
        local key = freshKey("corrupt")
        rawStore:SetAsync(key, record({ Data = { x = { __rz = "EnumItem", v = { "NoSuchEnum", "X" } } } }))
        local profile, loadErr = store:LoadProfile(key)
        expectEq(profile, nil, "profile")
        expect(string.find(tostring(loadErr), "Decode failed", 1, true), `unexpected error {fmt(loadErr)}`)
        expectEq(readRaw(key).Lock, nil, "stored lock")
    end)

    test("errors thrown while building a profile are returned and drop the lock", function()
        local cyclic = {}
        cyclic.self = cyclic
        local broken = newStore({ Template = cyclic })
        local key = freshKey("throws")
        local profile, loadErr = broken:LoadProfile(key)
        expectEq(profile, nil, "profile")
        expect(string.find(tostring(loadErr), "Profile build failed", 1, true), `unexpected error {fmt(loadErr)}`)
        expectEq(broken._loading[key], nil, "loading flag left set")
        expectEq(readRaw(key).Lock, nil, "stored lock")
    end)

    describe("Store: session locks")

    test("respects another server's live lock", function()
        local key = freshKey("locked")
        rawStore:SetAsync(key, record({ Lock = otherLock(0) }))
        local profile, loadErr = store:LoadProfile(key)
        expectEq(profile, nil, "profile")
        expect(string.find(tostring(loadErr), "session-locked", 1, true), `unexpected error {fmt(loadErr)}`)
        expectEq(readRaw(key).Lock.JobId, "other-server", "stored lock owner")
    end)

    test("takes over a lock older than LockTimeout", function()
        local key = freshKey("stale")
        rawStore:SetAsync(key, record({ Lock = otherLock(120) }))
        local profile = load(newStore({ LockTimeout = 60 }), key)
        expect(readRaw(key).Lock.JobId ~= "other-server", "lock not taken over")
        profile:Release()
    end)

    test("retries until another server releases its lock", function()
        local key = freshKey("retry")
        rawStore:SetAsync(key, record({ Lock = otherLock(0) }))
        task.delay(0.5, function()
            rawStore:UpdateAsync(key, function(rec)
                rec.Lock = nil
                return rec
            end)
        end)
        local profile = load(newStore({ LoadRetries = 3, RetryDelay = 1 }), key)
        expectEq(profile.Data.Coins, 1, "Coins")
        profile:Release()
    end)

    test("Save detects a lock taken by another server", function()
        local key = freshKey("lostlock")
        local profile = load(store, key)
        local reason = watchReleased(profile)
        rawStore:UpdateAsync(key, function(rec)
            rec.Lock = otherLock(0)
            return rec
        end)
        expect(not profile:Save(), "Save returned true")
        expectEq(reason(), "LostLock", "Released reason")
        expect(not profile:IsActive(), "still active")
        expectEq(store:GetProfile(key), nil, "still registered")
        expectEq(readRaw(key).Lock.JobId, "other-server", "stored lock owner")
    end)

    test("Save refuses to write when another server took and released the lock", function()
        local key = freshKey("stalelock")
        local profile = load(store, key)
        local reason = watchReleased(profile)
        -- Simulate another server taking over a dead lock, saving newer data, then releasing.
        rawStore:UpdateAsync(key, function(rec)
            rec.Data = { Coins = 99 }
            rec.Lock = nil
            return rec
        end)
        profile.Data.Coins = 1
        expect(not profile:Save(), "Save returned true")
        expectEq(reason(), "LostLock", "Released reason")
        expect(not profile:IsActive(), "still active")
        local rec = readRaw(key)
        expectEq(rec.Data.Coins, 99, "newer data overwritten")
        expectEq(rec.Lock, nil, "stored lock")
    end)

    describe("Store: save guards")

    test("unencodable data skips the save but keeps the profile", function()
        local key = freshKey("encode")
        local profile = load(store, key)
        profile.Data.Callback = function() end
        expect(not profile:Save(), "Save returned true")
        expect(profile:IsActive(), "profile deactivated")
        profile.Data.Callback = nil
        profile.Data.Coins = 3
        profile:AddUserId(7)
        expect(profile:Save(), "Save after fix returned false")
    end)

    test("Release with unencodable data unlocks and keeps the last save", function()
        local key = `{RUN_ID}-encode`
        local profile = store:GetProfile(key)
        expect(profile, "profile from previous test missing")
        profile.Data.Callback = function() end
        profile.Data.Coins = 4
        local reason = watchReleased(profile)
        expect(not profile:Release(), "Release returned true")
        expectEq(reason(), "Released", "Released reason")
        expect(not profile:IsActive(), "still active after Release")
        local rec, keyInfo = readRaw(key)
        expectEq(rec.Lock, nil, "stored lock")
        expectEq(rec.Data.Coins, 3, "stored Coins")
        expectEq(keyInfo:GetUserIds()[1], 7, "stored user id")
    end)

    test("oversized data skips the save", function()
        local profile = load(store, freshKey("oversized"))
        profile.Data.Blob = string.rep("x", 4_100_000)
        expect(not profile:Save(), "Save returned true")
        expect(profile:IsActive(), "profile deactivated")
        profile.Data.Blob = nil
        expect(profile:Save(), "Save after shrinking returned false")
        profile:Release()
    end)

    test("Release measures size even after small saves", function()
        -- A small save stops later saves from measuring; the release must still catch the jump.
        local key = freshKey("oversizedrelease")
        local profile = load(store, key)
        expect(profile:Save(), "small Save returned false")
        profile.Data.Blob = string.rep("x", 4_100_000)
        local reason = watchReleased(profile)
        expect(not profile:Release(), "Release returned true")
        expectEq(reason(), "Released", "Released reason")
        expect(not profile:IsActive(), "still active after Release")
        expectEq(store:GetProfile(key), nil, "still registered")
        local rec = readRaw(key)
        expectEq(rec.Lock, nil, "stored lock")
        expectEq(rec.Data.Blob, nil, "oversized data was written")
    end)

    test("concurrent saves are serialized", function()
        local profile = load(store, freshKey("serialized"))
        local results = {}
        for i = 1, 3 do
            task.spawn(function()
                profile.Data.Coins = i
                results[i] = profile:Save()
            end)
        end
        local started = os.clock()
        while #results < 3 and os.clock() - started < 15 do
            task.wait()
        end
        for i = 1, 3 do
            expectEq(results[i], true, `Save #{i}`)
        end
        profile:Release()
    end)

    test("autosave writes on the configured interval", function()
        local key = freshKey("autosave")
        local profile = load(newStore({ AutoSaveInterval = 1 }), key)
        profile.Data.Coins = 42
        task.wait(2.5)
        expectEq(readRaw(key).Data.Coins, 42, "stored Coins")
        profile:Release()
    end)

    if RUN_SLOW then
        test("DataStore errors are returned after backoff", function()
            local profile, loadErr = store:LoadProfile(string.rep("k", 60)) -- over the 50 char key limit
            expectEq(profile, nil, "profile")
            expect(string.find(tostring(loadErr), "DataStore error", 1, true), `unexpected error {fmt(loadErr)}`)
        end)

        test("Release unlocks even when the final write fails", function()
            local key = freshKey("writefail")
            local profile = load(store, key)
            expect(profile:Save(), "first Save returned false")
            local lastSaved = profile.Meta.LastSaved
            expect(lastSaved, "LastSaved missing after first Save")
            task.wait(1.1) -- so a wrongly stamped LastSaved would differ from the first save's
            profile.Data.Coins = 99
            profile.UserIds = { "not-a-number" :: any } -- UpdateAsync rejects the write (error 513)
            local reason = watchReleased(profile)
            expect(not profile:Release(), "Release returned true")
            expectEq(reason(), "Released", "Released reason")
            expectEq(profile.Meta.LastSaved, lastSaved, "failed write changed LastSaved")
            local rec = readRaw(key)
            expectEq(rec.Lock, nil, "stored lock")
            expectEq(rec.Data.Coins, 0, "failed write changed the data")
        end)
    else
        skip("DataStore errors are returned after backoff", "RUN_SLOW is off")
        skip("Release unlocks even when the final write fails", "RUN_SLOW is off")
    end

    describe("Store: player join and leave")

    test("joins load the profile and leaves release it without a kick", function()
        local fake = fakePlayer()
        local loaded
        store:_playerJoined(fake, function(p, profile)
            expectEq(p, fake, "onLoaded player")
            loaded = profile
        end)
        expect(loaded, "onLoaded not called")
        expectEq(store:GetProfile(fake.UserId), loaded, "GetProfile")
        expect(table.find(loaded.UserIds, fake.UserId), "UserId not added")
        local reason = watchReleased(loaded)
        store:_playerLeft(fake)
        expectEq(reason(), "Released", "Released reason")
        expectEq(store:GetProfile(fake.UserId), nil, "still registered")
        expectEq(readRaw(tostring(fake.UserId)).Lock, nil, "stored lock")
        expectEq(fake.Kicked, nil, "kicked")
        store:_playerLeft(fakePlayer()) -- no profile: must be a no-op
    end)

    test("kicks players whose data fails to load", function()
        local fake = fakePlayer()
        rawStore:SetAsync(tostring(fake.UserId), record({ Lock = otherLock(0) }))
        local called = false
        store:_playerJoined(fake, function()
            called = true
        end)
        expect(not called, "onLoaded called")
        expect(string.find(tostring(fake.Kicked), "failed to load", 1, true), `kick message {fmt(fake.Kicked)}`)
        expect(string.find(tostring(fake.Kicked), "session-locked", 1, true), `kick reason {fmt(fake.Kicked)}`)
    end)

    test("releases profiles of players who left during load", function()
        local fake = fakePlayer()
        fake.InGame = false
        local called = false
        store:_playerJoined(fake, function()
            called = true
        end)
        expect(not called, "onLoaded called")
        expectEq(store:GetProfile(fake.UserId), nil, "still registered")
        expectEq(readRaw(tostring(fake.UserId)).Lock, nil, "stored lock")
        expectEq(fake.Kicked, nil, "kicked")
    end)

    test("kicks players whose session is taken by another server", function()
        local fake = fakePlayer()
        local profile
        store:_playerJoined(fake, function(_, p)
            profile = p
        end)
        expect(profile, "onLoaded not called")
        rawStore:UpdateAsync(tostring(fake.UserId), function(rec)
            rec.Lock = otherLock(0)
            return rec
        end)
        expect(not profile:Save(), "Save returned true")
        task.wait() -- the kick runs from the deferred Released handler
        expect(string.find(tostring(fake.Kicked), "another server", 1, true), `kick message {fmt(fake.Kicked)}`)
    end)

    describe("Store: BindPlayers")

    local player = Players:GetPlayers()[1]
    if not player then
        skip("loads joined players", "no player in game (start a Play session)")
    else
        test(`loads joined players (via {joinedVia})`, function()
            table.insert(usedKeys, { scope = RUN_ID, key = tostring(player.UserId) })
            local started = os.clock()
            while not joined[player] and os.clock() - started < 15 do
                task.wait()
            end
            local loaded = joined[player]
            expect(loaded, "onLoaded never fired")
            expect(table.find(loaded.UserIds, player.UserId), "UserId not added")
            expectEq(joinStore:GetProfile(player.UserId), loaded, "GetProfile")
        end)
        if joinedVia ~= "PlayerAdded" then
            skip("PlayerAdded wiring", "the player joined before BindPlayers was called")
        end
    end

    if not KICK_PLAYER then
        skip("releases a player's profile when they leave", "KICK_PLAYER is off")
    elseif not (player and joined[player]) then
        skip("releases a player's profile when they leave", "no loaded player")
    else
        test("releases a player's profile when they leave", function()
            local profile = joined[player]
            local reason = watchReleased(profile)
            player:Kick("[RazorData:Test] Kicked on purpose to test PlayerRemoving. Results are in the Output.")
            local started = os.clock()
            while profile:IsActive() and os.clock() - started < 15 do
                task.wait()
            end
            expect(not profile:IsActive(), "profile still active after the player left")
            expectEq(reason(), "Released", "Released reason")
            expectEq(readRaw(tostring(player.UserId), RUN_ID).Lock, nil, "stored lock")
        end)
    end

    describe("Store: request budget")

    test("waits for request budget instead of queueing", function()
        -- Draining the real budget trips the experience-wide rate limit, so fake two empty reads.
        local original = RazorData._getBudget
        local checks = 0
        RazorData._getBudget = function(requestType)
            checks += 1
            return if checks <= 2 then 0 else original(requestType)
        end
        local started = os.clock()
        local ok, profile = pcall(load, store, freshKey("budget"))
        RazorData._getBudget = original
        expect(ok, tostring(profile))
        local waited = os.clock() - started
        expect(waited >= 2, `LoadProfile did not wait for budget ({string.format("%.2f", waited)}s)`)
        expectEq(checks, 3, "budget checks")
        profile:Release()
    end)

    describe("Store: shutdown")

    test("_releaseAll saves and releases profiles in every store", function()
        local gems = newStore({ Template = { Gems = 0 } })
        local coinKey, gemKey = freshKey("closecoins"), freshKey("closegems")
        local coins, gem = load(store, coinKey), load(gems, gemKey)
        coins.Data.Coins = 11
        gem.Data.Gems = 22
        local broken = load(store, freshKey("closebroken"))
        broken.Release = function()
            error("release exploded")
        end
        RazorData._releaseAll(15)
        expect(not coins:IsActive() and not gem:IsActive(), "profiles still active")
        local coinRec, gemRec = readRaw(coinKey), readRaw(gemKey)
        expectEq(coinRec.Data.Coins, 11, "stored Coins")
        expectEq(gemRec.Data.Gems, 22, "stored Gems")
        expectEq(coinRec.Lock, nil, "stored Coins lock")
        expectEq(gemRec.Lock, nil, "stored Gems lock")
        expect(broken:IsActive(), "failing Release should leave its profile untouched")
        broken.Release = nil
        broken:Release()
    end)

    test("_releaseAll stops waiting at the timeout", function()
        local hung = load(store, freshKey("closehung"))
        hung.Release = function()
            task.wait(3)
        end
        local started = os.clock()
        RazorData._releaseAll(0.5)
        local elapsed = os.clock() - started
        expect(elapsed >= 0.5 and elapsed < 2, `waited {string.format("%.2f", elapsed)}s`)
        hung.Release = nil
        hung:Release()
    end)

    -- Must stay last: _releaseAll above would release it.
    test("leaves a profile loaded for the next run's BindToClose check", function()
        local held = load(newStore({ LockTimeout = 0 }), PROBE_KEY)
        held.Data.RunId = RUN_ID -- autosave may write this, but only a release clears the lock
    end)
end

local function cleanup()
    local removed = 0
    for _, entry in usedKeys do
        local ds = if entry.scope then DataStoreService:GetDataStore(STORE_NAME, entry.scope) else rawStore
        if pcall(ds.RemoveAsync, ds, entry.key) then
            removed += 1
        end
    end
    log(`removed {removed}/{#usedKeys} test keys`)
end

-- init runs before any player can join, so BindPlayers sees them through PlayerAdded. Nothing here yields.
function mod:init()
    bindPlayersEarly()
end

function mod:start()
    local started = os.clock()
    log(`run {RUN_ID} starting`)
    local available = preflight()
    serializerTests()
    migrationTests()
    storeTests(available)
    cleanup()

    local summary = `{stats.passed} passed, {stats.failed} failed, {stats.skipped} skipped in {string.format("%.1f", os.clock() - started)}s`
    if stats.failed > 0 then
        warn(`[RazorData:Test] {summary}\n  ` .. table.concat(failures, "\n  "))
    else
        log(summary)
    end
end
