# Serialization

DataStores only accept JSON-safe values. Razor Data converts your data to a JSON-safe form when it saves and back when it loads, so you can put Roblox types straight into `profile.Data`:

```lua
profile.Data.SpawnPoint = CFrame.new(0, 10, 0)
profile.Data.FavoriteColor = Color3.fromRGB(255, 120, 0)
profile.Data.Difficulty = Enum.DifficultyLevel.Hard -- any EnumItem
```

Values are stored as a tagged table, `{ __rz = "<type>", v = <data> }`. Plain values and tables are stored as normal JSON.

## Supported types

**Primitives**

- `nil`, `boolean`, `string`
- `number`, including `NaN`, `math.huge` and `-math.huge` (which JSON can't store on its own)
- `buffer` (stored as base64)

**Tables**

- Arrays
- Dictionaries with string keys
- Tables with mixed or non-string keys, like `{ [1] = "a", [5] = "b" }` or `{ [Vector3.zero] = true }`. These are stored as a list of key/value pairs, and keys can be any supported type.

Cyclic tables error and the save is skipped.

**Roblox datatypes**

`Vector2`, `Vector3`, `Vector2int16`, `Vector3int16`, `CFrame`, `Color3`, `BrickColor`, `UDim`, `UDim2`, `Rect`, `NumberRange`, `NumberSequence`, `ColorSequence`, `EnumItem`, `Enum`, `DateTime`, `Font`, `PhysicalProperties`, `Ray`, `Region3`, `Region3int16`, `Faces`, `Axes`, `TweenInfo`

**Instances**

See [Instances](#instances) below.

Anything else, such as functions, threads or `RBXScriptConnection`, errors with `cannot serialize type '<type>'` and the save is skipped.

## Instances

Instances are saved as a tree, with their class, name, chosen properties, attributes, tags and children:

```lua
local build = Instance.new("Model")
-- ... add parts ...
profile.Data.Builds[1] = build
```

On load, a new copy is created with no parent. Parent it yourself:

```lua
local build = profile.Data.Builds[1]
build.Parent = workspace
```

Things to know:

- Only children with `Archivable = true` are saved.
- Properties that hold an Instance, like `ObjectValue.Value` or `Model.PrimaryPart`, aren't saved.
- If a class can't be created when loading (for example, it was removed from Roblox), that instance and its children are skipped with a warning. The rest of the profile still loads.
- The same Instance in two places is saved twice, and loads as two separate copies.
- Instance trees can get big quickly. Keep the 4 MB limit in mind.

### Saved properties

Properties are chosen by class with `IsA`, so a `Part` gets both the `BasePart` and `Part` lists:

| Class | Properties |
| --- | --- |
| `BasePart` | `Anchored`, `CanCollide`, `CanQuery`, `CanTouch`, `CastShadow`, `CFrame`, `Size`, `Color`, `Material`, `Transparency`, `Reflectance`, `Massless` |
| `Part` | `Shape` |
| `MeshPart` | `TextureID` |
| `Model` | `WorldPivot` |
| `ValueBase` | `Value` |
| `Decal` | `Texture`, `Color3`, `Transparency`, `Face` |
| `Light` | `Brightness`, `Color`, `Enabled`, `Shadows` |
| `GuiObject` | `Position`, `Size`, `AnchorPoint`, `BackgroundColor3`, `BackgroundTransparency`, `Visible`, `ZIndex`, `Rotation` |
| `TextLabel`, `TextButton` | `Text`, `TextColor3`, `TextSize`, `FontFace` |
| `ImageLabel`, `ImageButton` | `Image`, `ImageColor3`, `ImageTransparency` |

`MeshPart.MeshId` isn't saved, so a loaded `MeshPart` has no mesh. For meshes, save an asset ID or a name and clone from a template instead.

### Adding properties

```lua
RazorData.Serializer.RegisterInstanceProperties("PointLight", { "Range" })
RazorData.Serializer.RegisterInstanceProperties("BasePart", { "Locked" })
```

Properties are added to the existing list for that class. Any class or base class name works.

## Custom types

You can register your own table-based types, such as classes built with metatables:

```lua
local Money = {}
Money.__index = Money

RazorData.Serializer.RegisterType(
    "Money",
    function(value) -- is this a Money?
        return getmetatable(value) == Money
    end,
    function(money) -- encode
        return money.cents
    end,
    function(cents) -- decode
        return setmetatable({ cents = cents }, Money)
    end
)
```

- The check function is only called for tables, so custom types must be tables.
- The encode function must return a JSON-safe value. Its result isn't serialized again, so it can't contain Roblox types.
- Register types before any profile loads or saves, and never rename a type that's in saved data. A tag that isn't registered when loading is left as the raw `{ __rz = ..., v = ... }` table, with a warning.

## Using the serializer directly

```lua
local encoded = RazorData.Serializer.Encode(value) -- JSON-safe
local decoded = RazorData.Serializer.Decode(encoded)
```

This is useful for sending data through `MessagingService` or `MemoryStoreService`, which have the same JSON restrictions.
