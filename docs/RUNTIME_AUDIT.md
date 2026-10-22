# Runtime audit: EditableImage APIs and the Luau ops under them

This is the ground truth the rest of the project is built on. Every claim carries a status label, and every number says where it came from.

**Snapshot used (2026-10-22)**

| Source | Version |
|---|---|
| Roblox API dump (MaximumADHD/Roblox-Client-Tracker) | `0.744.0.7441077`, tracker commit `a020070` (2026-10-20) |
| Roblox/creator-docs | commit `65621e8` (2026-10-21) |
| luau-lang/luau | commit `6d36d48` (2026-10-20) |
| Host for Luau measurements | Intel Xeon @ 2.10 GHz (x64, 4 vCPU, virtualised), Luau CLI built `-O3` Release |

**Labels**

| Label | Meaning |
|---|---|
| PUBLIC CONTRACT | Stated in Roblox creator-docs, luau.org, or a public header |
| IMPLEMENTATION DETAIL | Visible in the current API dump or Luau source; may change without notice |
| ANNOUNCED | Stated by Roblox staff in a DevForum announcement but not yet in the reference docs |
| COMMUNITY REPORT | DevForum or social posts by developers; unverified |
| NOT PUBLICLY SPECIFIED | No public source states it; `studio/EditableImageProbe.luau` measures it |
| CLOSED-SOURCE ENGINE | Private engine behaviour; only names (for example flag names) are visible |

---

## 1. The runtimes: where pixel code can execute

| Context | Luau execution | Editable memory | Max EditableImage | Default opt level | Status |
|---|---|---|---|---|---|
| Client `LocalScript`, live game | Interpreter. Native codegen is documented for server scripts only. | Strict, device-specific, dynamic budget | 1024 x 1024 | 2 | PUBLIC CONTRACT (docs), client codegen status NOT PUBLICLY SPECIFIED |
| Client in a Studio playtest | Interpreter | Docs say Studio has no budget | 1024 x 1024 | **1** | PUBLIC CONTRACT |
| Server `Script` | Interpreter, or native with `--!native` / `@native` | Unlimited | 1024 x 1024 | 2 | PUBLIC CONTRACT |
| Studio plugin / command bar | Interpreter or native | Unlimited | 1024 documented; 2048 creation reported in plugin context | 1 | PUBLIC CONTRACT; 2048 is COMMUNITY REPORT |
| Actor, desynchronized (parallel phase) | Same as its script | Same | Same | Same | Thread-safety tags in section 2 |

Consequences that the design depends on:

1. **Client pixel code runs in the interpreter.** Roblox's native codegen page says "server-side scripts in your game can be compiled directly into the machine code". A 2024 staff post said clients would not be supported initially, and the open feature request "Enable --!native for clients" has no shipped answer. Treat every client per-pixel loop as interpreted. (PUBLIC CONTRACT for the server statement; client absence is NOT PUBLICLY SPECIFIED.)
2. **Studio playtests compile at optimization level 1, live games at level 2.** Level 2 inlines small local functions. The measured cost of a per-pixel helper call drops by half at level 2, so Studio timings of helper-heavy pixel code are pessimistic. Put `--!optimize 2` at the top of pixel modules when profiling in Studio. (PUBLIC CONTRACT: creator-docs `luau/comments.md`.)
3. **EditableImage content set on the server does not replicate.** The `Content` reference warns that `Object` values replicate as an unusable placeholder that renders as a cyan and magenta checkerboard. Build displays on the client, or bake them with `CreateDataModelContentAsync` (section 3). (PUBLIC CONTRACT.)
4. **Only one displayed EditableImage is updated per frame on the display side.** Updating three displayed images takes three frames. One atlas updated once beats many small images. (PUBLIC CONTRACT: EditableImage reference, "Update Limitations".)

---

## 2. EditableImage: every member

`EditableImage` inherits `Object`, not `Instance`, so it cannot be parented and is `NotCreatable`; create it through `AssetService`. (IMPLEMENTATION DETAIL: API dump.)

| Member | Signature | Thread safety | Security | Runtime contract |
|---|---|---|---|---|
| `Size` | `Vector2`, read-only | ReadSafe | None | Max 1024 x 1024. Cannot be resized; to resize, create a new image and `DrawImageTransformed` into it. (PUBLIC CONTRACT) |
| `Destroy` | `()` | Unsafe | None | Destroys contents and immediately reclaims memory. (PUBLIC CONTRACT) |
| `ReadPixelsBuffer` | `(position: Vector2, size: Vector2) -> buffer` | **Safe** | None | RGBA8, 4 bytes per pixel, length `w*h*4`. Uses alpha, not transparency. Safe means it may be called from a desynchronized Actor. (PUBLIC CONTRACT for layout; thread safety IMPLEMENTATION DETAIL from dump) |
| `WritePixelsBuffer` | `(position: Vector2, size: Vector2, buffer: buffer)` | Unsafe | None | Same layout. Serial phase only. (PUBLIC CONTRACT) |
| `DrawRectangle` | `(position, size, color: Color3, transparency: number, combineType)` | Unsafe | None | Position cannot be outside the canvas. (PUBLIC CONTRACT) |
| `DrawCircle` | `(center, radius: int, color, transparency, combineType, antiAliasing = Enabled)` | Unsafe | None | Semi-transparent circles blend with source over. Center may be outside the canvas. (PUBLIC CONTRACT) |
| `DrawLine` | `(p1, p2, color, transparency, combineType, antiAliasing = Enabled)` | Unsafe | None | One pixel thick. (PUBLIC CONTRACT) |
| `DrawImage` | `(position, image: EditableImage, combineType)` | Unsafe | None | Partly-outside positions allowed. (PUBLIC CONTRACT) |
| `DrawImageTransformed` | `(position, scale: Vector2, rotation: number (degrees), image, options?)` | Unsafe | None | Options: `CombineType` (default `AlphaBlend`), `SamplingMode` (`Default` = bilinear, `Pixelated` = nearest), `PivotPoint` (default `image.Size / 2`). (PUBLIC CONTRACT) |
| `DrawImageProjected` | `(projectionSource: EditableMesh or WrapTextureTransfer, projection, brushConfig)` | Unsafe | None | `projection = {Direction, Position, Size, Up}`; `brushConfig = {AlphaBlendType, ColorBlendType, Decal, FadeAngle, BlendIntensity}`. (PUBLIC CONTRACT) |
| `SampleImageProjected` | `(projectionSource, sourceTexture, projectionConfig, brushConfig)` | Unsafe | None | Inverse of `DrawImageProjected`: reads a mesh texture region into this image. Closest surface wins. (PUBLIC CONTRACT) |
| `DrawTriangle` | `(p1, p2, p3, color, transparency)` | Unsafe | **RobloxScriptSecurity** | Exists but experiences cannot call it. Rasterize triangles in Luau or with `DrawImageTransformed`. (IMPLEMENTATION DETAIL) |

Other runtime contracts:

- Coordinates run from `(0, 0)` top-left to `(Size.X - 1, Size.Y - 1)`. (PUBLIC CONTRACT)
- Published experiences must enable **Allow Mesh / Image APIs**, otherwise the APIs fail. (PUBLIC CONTRACT)
- `CreateEditableImageAsync` only loads assets owned by or shared with the experience owner, the Studio user, the client player, or a group where they can edit assets. It throws otherwise. (PUBLIC CONTRACT)
- Client budgets are strict; server, Studio and plugins are unlimited. Linking one EditableImage to several `Content` properties is the documented memory saver. (PUBLIC CONTRACT)
- Budget is accounted by pixel area: one 1024 x 1024 image costs the same as four 512 x 512 images. (ANNOUNCED in the 2024 to 2025 Mesh and Image API beta announcements)
- The size of the client budget is NOT PUBLICLY SPECIFIED. Developers report hitting it after five or six 1024 x 1024 images and quote 32 MB. (COMMUNITY REPORT)
- Writes and draws are reported to crash or tear when attempted from parallel Luau; the dump marks them Unsafe, which means the engine rejects them. (IMPLEMENTATION DETAIL plus COMMUNITY REPORT)

---

## 3. AssetService and `Content`: creating, baking and publishing

| Method | Yields | Thread safety | Contract |
|---|---|---|---|
| `CreateEditableImage(options?)` | no | Unsafe | Default 512 x 512; `options.Size` sets size. Returns `nil` when the device budget is exhausted. (PUBLIC CONTRACT) |
| `CreateEditableImageAsync(content, options?)` | yes | Unsafe | Loads an image; `rbxthumb://` supported; permission rules above; `nil` on budget exhaustion. (PUBLIC CONTRACT) |
| `CreateDataModelContentAsync(content, options?)` | yes | Unsafe | Bakes an EditableImage or EditableMesh into DataModel-scoped `Opaque` content. Returns `(Enum.CreateContentResult, Content)`. Fails with `StorageLimitExceeded` when the server storage budget is used up. (PUBLIC CONTRACT) |
| `CreateDecalAsync(maps)` | yes | Unsafe | Keys `TextureContent`, `NormalMapContent`, `MetalnessMapContent`, `RoughnessMapContent`; every value must be `Content.fromObject(EditableImage)`. Returns an unparented `Decal`. This is how a game script gets PBR decal maps whose properties are plugin-only. (PUBLIC CONTRACT) |
| `CreateSurfaceAppearanceAsync(maps)` | yes | Unsafe | Keys `ColorMap`, `MetalnessMap`, `NormalMap`, `RoughnessMap`, `EmissiveMask`; EditableImage content only; maps cannot be swapped afterwards. (PUBLIC CONTRACT) A SurfaceAppearance built this way has no mipmaps until published. (ANNOUNCED, 2025) |
| `CreateTextureAsync(content)` | yes | Unsafe | In the dump with `None` security; no reference page in this docs snapshot. (IMPLEMENTATION DETAIL; semantics NOT PUBLICLY SPECIFIED) |
| `ComposeDecalAsync(decal, layers)` | yes | Unsafe | Engine-side compositing of up to 8 layers of `{ColorMap, RoughnessMap, MetalnessMap, NormalMap}` asset content, bottom to top, blended by colour-map alpha. Errors if a call is already pending on that decal. (PUBLIC CONTRACT) Only public decals work today. (COMMUNITY REPORT with staff reply, mid-2026) |
| `PromptCreatePlatformContentAsync(player, object, Enum.AssetType.Image)` | yes | Unsafe | Server only. Publishes an EditableImage to the player's inventory and rewrites the referencing `Content` to the new asset id. (PUBLIC CONTRACT) |
| `CreateAssetAsync(object, Enum.AssetType.Image, params?)` | yes | Unsafe | Plugins and Open Cloud Luau Execution only; uploads without prompting. (PUBLIC CONTRACT) |

**Baking is the most important runtime fact in this audit.** The May 2026 full-release announcement of `CreateDataModelContentAsync` states that baked content (ANNOUNCED):

- is transcoded into mips for client delivery, which gives the GPU a real mip chain and smooth distance filtering;
- does not count against Editable memory budgets;
- replicates from server to clients with optimized distribution when created on the server;
- lives for the session and needs no upload or moderation.

It cannot yet feed `CreateSurfaceAppearanceAsync` (COMMUNITY REPORT feature request). Whether a baked source image may be destroyed immediately after baking is NOT PUBLICLY SPECIFIED; the probe tests it.

**`Content`** (PUBLIC CONTRACT): constructors `fromUri`, `fromAssetId`, `fromObject`, and the constant `none`. `SourceType` is one of `None`, `Uri`, `Object`, `Opaque`. A `fromObject` value is a strong reference that keeps the object alive, so clearing `Content` properties is part of freeing an image.

---

## 4. Display sinks: where pixels can be shown

Of 84 `Content` properties in the dump, these accept an EditableImage or baked content and are writable from game scripts (write security `None`). (IMPLEMENTATION DETAIL: dump; EditableImage support stated in docs for the GUI, MeshPart and Decal ones.)

| Family | Properties |
|---|---|
| 2D GUI | `ImageLabel.ImageContent`, `ImageButton.ImageContent / HoverImageContent / PressedImageContent`, `ScrollingFrame.Top/Mid/BottomImageContent`, `ImageHandleAdornment.ImageContent` |
| 3D surfaces | `MeshPart.TextureContent`, `Decal.TextureContent`, `Decal.ColorMapContent`, `Texture` (inherits Decal), `FileMesh.TextureContent`, `CharacterMesh.BaseTextureContent / OverlayTextureContent`, `Shirt/Pants/ShirtGraphic` templates |
| Effects and sky | `Beam`, `Trail`, `ParticleEmitter`, `ParticleEmitter2D` `.TextureContent`; `Sky.Skybox*Content`, `SunTextureContent`, `MoonTextureContent` |
| Cursors and icons | `Mouse.IconContent`, `UserInputService.MouseIconContent`, `ClickDetector.CursorIconContent`, drag detector cursors |

Plugin-only writes (game scripts must go through `CreateDecalAsync` or `CreateSurfaceAppearanceAsync`): all `SurfaceAppearance` maps, all `MaterialVariant` and `TerrainDetail` maps, and `Decal` normal, metalness, roughness and emissive maps. (IMPLEMENTATION DETAIL: dump)

**Free GPU ops on the sinks.** These run per pixel on the GPU and cost no Luau time. The library uses them instead of CPU pixel work. (PUBLIC CONTRACT: dump and docs)

| Sink | Per-pixel ops the GPU does for free |
|---|---|
| `ImageLabel` / `ImageButton` | `ImageTransparency` (fade), `ImageColor3` (multiply tint), `ImageRectOffset` + `ImageRectSize` (atlas window), `ScaleType` Stretch/Slice/Tile/Fit/Crop, `TileSize`, `SliceCenter`, `ResampleMode`, `Rotation`, `ZIndex` stacking |
| `CanvasGroup` | `GroupTransparency`, `GroupColor3` over a whole subtree |
| `Decal` / `Texture` | `Transparency`, `Color3` tint, `UVOffset`, `UVScale`, `Rotation` (UV rotation, clockwise degrees), `ZIndex` layering per face, `ResampleMode`, emissive tint and strength; `Texture` adds `StudsPerTileU/V` and `OffsetStudsU/V` |
| `SurfaceGui` | Hosts a grid of `ImageLabel` tiles on a 3D face; `PixelsPerStud`, `CanvasSize`, `MaxDistance` |

Whether `UVOffset` is applied before or after `UVScale`, and whether UVs outside 0..1 wrap or clamp, is NOT PUBLICLY SPECIFIED. Exact GUI tiling through `SurfaceGui` is therefore the safe path for textures larger than 1024 on 3D faces.

`ResampleMode` exists on `ImageLabel`, `ImageButton`, `VideoDisplay`, `Decal`, `Texture` and `SurfaceAppearance`. One 2025 report says the `SurfaceAppearance` one had no effect. (IMPLEMENTATION DETAIL; COMMUNITY REPORT)

---

## 5. The image ops: combine, alpha and sampling enums

| Enum | Items (value) | Documented meaning |
|---|---|---|
| `ImageCombineType` | `BlendSourceOver` (1) | Source-over alpha blending |
| | `Overwrite` (2) | Replace destination pixels with source |
| | `Add` (3) | Add; source RGB scaled by source alpha; source alpha added to destination alpha |
| | `Multiply` (4) | Multiply RGBA as 0..1 values |
| | `AlphaBlend` (5) | Blend by source alpha; unlike source-over, destination colour affects the result regardless of destination alpha |
| | `NormalMapBlend` (6) | Alpha blend, then renormalise RGB as a tangent-space normal |
| | `Subtract` (7) | Subtract; source RGB scaled by source alpha; source alpha subtracted from destination alpha |
| `ImageAlphaType` | `Default` (1), `LockCanvasAlpha` (2), `LockCanvasColor` (3) | Lock alpha or colour of the canvas; used by `DrawImageProjected` and `SampleImageProjected` brush configs |
| `ResamplerMode` | `Default` (0), `Pixelated` (1) | Bilinear over the four nearest pixels; nearest neighbour |
| `AntiAliasing` | `Disabled` (0), `Enabled` (1) | Soft or hard edges for `DrawCircle` and `DrawLine` |

All of the above is PUBLIC CONTRACT. These parts are NOT PUBLICLY SPECIFIED and the probe measures them:

- the exact arithmetic, rounding and clamping of each combine type;
- whether stored pixels are straight or premultiplied alpha, and whether RGB under alpha 0 survives a round-trip;
- whether `DrawImageTransformed` bilinear sampling is premultiplied-aware (no colour bleed from transparent texels);
- whether minification by more than 2x averages the whole footprint or only samples 2 x 2 taps (aliasing).

Known reports (COMMUNITY REPORT): `Add` ignoring source alpha between EditableImages, and alpha blending not blending colour over existing data. Engine flags with related names exist in build 0.744 (CLOSED-SOURCE ENGINE, names only): `FFlagFixEditableImageBlendTransparentSource`, `FFlagEditableImageSubtractImageCombineType`, `DFFlagEditableImageForceRGBA`, `FFlagEditableImageCatchQoiDecodeError`, `FFlagEditableImageSafeTrackPerformance`, `DFFlagSimEditableImageDisableRendering`.

---

## 6. Luau ops

### 6.1 Bytecode

The VM is register based. The current opcode set, parsed from `Common/include/Luau/Bytecode.h` (IMPLEMENTATION DETAIL):

| Family | Opcodes |
|---|---|
| Loads and moves | `NOP` `BREAK` `LOADNIL` `LOADB` `LOADN` `LOADK` `LOADKX` `MOVE` |
| Globals, upvalues, imports | `GETGLOBAL` `SETGLOBAL` `GETUPVAL` `SETUPVAL` `CLOSEUPVALS` `GETIMPORT` |
| Tables and userdata | `GETTABLE` `SETTABLE` `GETTABLEKS` `SETTABLEKS` `GETTABLEN` `SETTABLEN` `NEWTABLE` `DUPTABLE` `SETLIST` `GETUDATAKS` `SETUDATAKS` `NAMECALLUDATA` |
| Calls and closures | `NEWCLOSURE` `DUPCLOSURE` `NAMECALL` `CALL` `CALLFB` `RETURN` `CAPTURE` `PREPVARARGS` `GETVARARGS` `NATIVECALL` `FASTPCALL` `CMPPROTO` |
| Builtin fast path | `FASTCALL` `FASTCALL1` `FASTCALL2` `FASTCALL2K` `FASTCALL3` |
| Jumps and compares | `JUMP` `JUMPBACK` `JUMPX` `JUMPIF` `JUMPIFNOT` `JUMPIFEQ` `JUMPIFLE` `JUMPIFLT` `JUMPIFNOTEQ` `JUMPIFNOTLE` `JUMPIFNOTLT` `JUMPXEQKNIL` `JUMPXEQKB` `JUMPXEQKN` `JUMPXEQKS` |
| Arithmetic | `ADD` `SUB` `MUL` `DIV` `IDIV` `MOD` `POW`, constant forms `ADDK` `SUBK` `MULK` `DIVK` `IDIVK` `MODK` `POWK`, reversed `SUBRK` `DIVRK`, unary `MINUS` `NOT` `LENGTH`, `CONCAT` |
| Logic | `AND` `OR` `ANDK` `ORK` |
| Loops | `FORNPREP` `FORNLOOP` `FORGPREP` `FORGPREP_INEXT` `FORGPREP_NEXT` `FORGLOOP` |
| Classes (experimental, version 100) | `NEWCLASS` `NEWCLASSMEMBER` `CONSTRUCT` `FINCONSTRUCT` |
| Tooling | `COVERAGE` |

What matters for pixels: arithmetic has constant-operand forms, so `x * 256` and `y // 4` are one instruction; numeric `for` loops with a constant step use `FORNPREP`/`FORNLOOP` with no extra work; builtin calls compile to `FASTCALL*` followed by a fallback `CALL`.

### 6.2 Which calls become FASTCALL builtins

`LuauBuiltinFunction` lists every builtin with a fast path (IMPLEMENTATION DETAIL). The ones a pixel pipeline uses:

| Library | FASTCALL builtins |
|---|---|
| `buffer` | `readi8` `readu8` `readi16` `readu16` `readi32` `readu32` `readf32` `readf64`; `writei8/writeu8`, `writei16/writeu16`, `writei32/writeu32` share one id per width; `writef32` `writef64`; `readinteger` `writeinteger` behind flags |
| `bit32` | every function: `band` `bor` `bxor` `btest` `bnot` `lshift` `rshift` `arshift` `lrotate` `rrotate` `extract` (plus `EXTRACTK` for constant field and width) `replace` `countlz` `countrz` `byteswap` |
| `math` | `abs` `acos` `asin` `atan` `atan2` `ceil` `cos` `cosh` `deg` `exp` `floor` `fmod` `frexp` `ldexp` `log` `log10` `max` `min` `modf` `pow` `rad` `sin` `sinh` `sqrt` `tan` `tanh` `clamp` `sign` `round` `lerp` `isnan` `isinf` `isfinite` |
| `vector` | `create` `magnitude` `normalize` `cross` `dot` `floor` `ceil` `abs` `sign` `clamp` `min` `max` `lerp` |
| other | `assert` `type` `typeof` `rawget` `rawset` `rawequal` `rawlen` `getmetatable` `setmetatable` `tonumber` `tostring` `select(_, ...)` `string.byte` `string.char` `string.len` `string.sub` `table.insert` `table.unpack` `table.create` `table.clear` |

**Not builtins**, so every call is a full C-function call (about 15 to 35 ns measured, section 6.6): `buffer.create` `fromstring` `tostring` `len` `copy` `fill` `readbits` `writebits` `readstring` `writestring`, `math.random` `math.noise` `math.map`. `buffer.copy` and `buffer.fill` are still the fastest way to move many bytes, because the call overhead is paid once per span, not per pixel.

Recognition rules (IMPLEMENTATION DETAIL, `Compiler/src/Builtins.cpp`):

- `math.floor(x)` on the global library is recognised.
- A local alias that is never reassigned is recognised too: `local floor = math.floor` and `local m = math` keep the fast path. Measured cost is identical.
- Assigning to the global anywhere in the script (for example `math = ...`) disables recognition for that name. `getfenv`/`setfenv` disable the safe environment the fast path relies on.

The 64-bit `integer` library and `buffer.readinteger/writeinteger` exist in source behind `LuauIntegerLibrary`, `LuauIntegerFastcalls` and `LuauIntegerBufferFastcalls`, all default off in open-source builds. Roblox build 0.744 contains flags named `DFFlagSerializeLuauInteger` and `FFlagLuauIntegerOutput`, so the type is being wired up, but availability to experiences is NOT PUBLICLY SPECIFIED. The library feature-detects it and never depends on it.

### 6.3 What native code generation does with each op

From `CodeGen/src/IrTranslateBuiltins.cpp` (IMPLEMENTATION DETAIL). Only relevant on servers and in Studio, per section 1.

| Class | Ops | Cost shape |
|---|---|---|
| Inline IR, no call | all `buffer` read/write widths; all `bit32` ops including `countlz` `countrz` `byteswap` `replace` `extract`; `math.floor` `ceil` `sqrt` `abs` `round` `sign` `min` `max` `clamp` `lerp` `deg` `rad` `isnan`; `vector.create` and every `vector.*` above; `type` `typeof` `assert` `string.len` `table.insert` | Near zero; hidden under loop latency |
| Native call into libm | `math.exp` `sin` `cos` `tan` `asin` `acos` `atan` `sinh` `cosh` `tanh` `log10` `pow` `fmod` `atan2` `ldexp` `frexp` `modf` (and `^`) | 5 to 12 ns measured |
| Not lowered | non-builtins listed above; `string.byte/char/sub`, `rawget`, `tostring`, ... | Same C call as the interpreter |

Buffer accesses keep a bounds check (`CHECK_BUFFER_LEN`) that exits to the interpreter on failure. Consecutive accesses at constant offsets from the same index are merged into one check when the combined range stays within 4095 bytes, so reading the four bytes of a pixel at `o, o+1, o+2, o+3` costs one check.

`vector` components are 32-bit floats in default builds (`LUA_VECTOR_DOUBLE 0`). Coordinates up to 2^24 are exact, which covers any texture, but accumulating sums in vectors loses precision faster than in numbers.

### 6.4 Semantics that pixel code relies on

All PUBLIC CONTRACT unless noted; IMPLEMENTATION DETAIL items checked in `VM/src/lbuflib.cpp` and `lnumutils.h`.

- **buffer**: fixed size, zero-filled on create, maximum 1 GiB, every access bounds-checked, little-endian, two's complement, IEEE 754 floats. Offsets are converted with integer truncation.
- **buffer writes**: the value goes through unsigned 32-bit conversion, then is truncated to the target width. `writeu8(b, o, 300)` stores 44. (IMPLEMENTATION DETAIL)
- **`buffer.fill(b, offset, value, count?)`** is `memset` with `value & 0xFF`; count defaults to the rest of the buffer.
- **`buffer.copy`** has `memmove` semantics, so overlapping copies are safe. Copying a buffer onto itself at a doubling offset fills a span with a repeated 4-byte pixel in log2(n) calls.
- **`readbits/writebits`** take 0 to 32 bits, little-endian, least significant bit first. They are not builtins and cost about 20 to 35 ns.
- **bit32**: inputs are unsigned 32-bit (0 to 4294967295), bit 0 is the least significant, shifts beyond 31 give 0, rotations are modulo 32, `countlz(0) == 32`.
- **`math.round`** rounds half away from zero; `math.clamp` errors when min > max; `math.lerp` returns `b` exactly when `t == 1`.
- **`//`** is `floor(a / b)` and **`%`** is `a - floor(a / b) * b`. Both are exact for integer operands below 2^53. (IMPLEMENTATION DETAIL)

### 6.5 Determinism: which ops give the same bits everywhere

Procedural textures are only reproducible on every client if generation uses ops that round identically on x64 and ARM, interpreted and native.

| Deterministic | Not deterministic |
|---|---|
| `+ - * /`, `math.sqrt` (IEEE 754 correctly rounded) | `math.lerp` and `vector.lerp`: native code lowers them to a fused multiply-add (`MULADD_NUM`, FMA3 on x64, `fmla` on ARM), the interpreter rounds twice. Write `a + (b - a) * t` instead. (IMPLEMENTATION DETAIL) |
| `math.floor` `ceil` `abs` `min` `max` `clamp` `round` `sign` | `math.sin` `cos` `exp` `pow` `log` and `^`: platform libm, not correctly rounded |
| `//` and `%` on integers | `%` and `//` on fractional values: MSVC builds compile them in a fast-math region (`LUAU_FASTMATH_BEGIN`) |
| all `bit32` and integer `buffer` ops | `math.noise`, `math.random` (implementation-defined sequences) |
| hand-written `a + b * c` (codegen never fuses separate MUL and ADD) | `vector` arithmetic when exact sums matter (float32 lanes) |

The project's `MyMath` module builds its hashing, noise and SDF code only from the left column.

### 6.6 Measured op costs

Measured with `bench/ops.luau` (run `tools/run_bench.sh`, then `tools/merge_bench.py`). Three interleaved rounds, per-key minimum. Interpreter numbers subtract the empty loop (`ns/op`); native numbers are raw per iteration (`ns/iter`) because native loops are bound by the latency of the accumulator add, about 2 ns here, and cheap ops hide under it.

Noise between runs on this shared virtual machine is about plus or minus 1 ns per op and 10 to 20 percent per kernel, so read O1 and O2 interpreter columns as equal unless the gap is large. The full table, with every op, is `bench/results/x64-summary.md`; the raw rounds sit next to it.

**Ops (selected)**

| Op | Interp O1, Studio (ns/op) | Interp O2, live (ns/op) | Native O2 (ns/iter, loop floor 2.2) |
|---|---|---|---|
| `buffer.readu8` / `readu32` | 3.2 / 3.0 | 3.3 / 3.9 | 2.3 / 2.9 |
| `buffer.readu32`, buffer cached in a local | 2.4 | 2.5 | 2.2 |
| `buffer.writeu8` / `writeu32` | 5.6 / 5.2 | 5.8 / 5.3 | 2.1 / 2.1 |
| `buffer.readbits` / `writebits` (not builtins) | 22.0 / 23.4 | 25.3 / 23.7 | 23.4 / 18.6 |
| `buffer.copy` 4 bytes / `buffer.len` (not builtins) | 18.3 / 9.4 | 18.1 / 9.1 | 22.5 / 11.9 |
| array table read / write | 3.6 / 3.3 | 2.5 / 1.6 | 3.3 / 2.4 |
| `bit32.band` / `lshift` / `rshift` | 2.7 / 2.2 / 2.2 | 2.5 / 2.2 / 2.2 | 2.3 / 2.6 / 2.7 |
| `bit32.bor(a, b, c, d)` | 7.5 | 11.2 | 2.2 |
| `bit32.extract` constant field / `replace` | 3.1 / 8.3 | 4.8 / 9.1 | 2.6 / 2.7 |
| `x * k`, `x / k`, `x // k`, `x % k` | 1.5, 0.8, 1.0, 1.1 | 1.4, 1.5, 2.1, 2.1 | 2.2 to 2.6 |
| `math.floor` / `math.sqrt` / `math.clamp` | 3.7 / 1.5 / 6.8 | 3.7 / 1.6 / 7.7 | 2.3 / 2.0 / 2.1 |
| `math.lerp` | 5.4 | 4.6 | 2.1 |
| `x ^ 2.2` / `math.sin` / `math.exp` (libm) | 12.3 / 7.0 / 5.6 | 12.3 / 10.2 / 8.1 | 11.4 / 7.2 / 5.2 |
| `vector.create` / `vector.magnitude` / `vector.dot` | 8.1 / 13.9 / 12.0 | 8.0 / 13.5 / 12.7 | 2.1 / 13.9 / 10.9 |

**One RGBA8 pixel written or read**

| Pixel op | Interp O1 | Interp O2 | Native O2 |
|---|---|---|---|
| `writeu32(r + g*256 + b*65536 + a*16777216)` | 11.9 | 11.7 | 2.8 |
| `writeu32(bit32.bor(r, lshift(g,8), lshift(b,16), lshift(a,24)))` | 18.4 | 23.1 | 2.9 |
| four `writeu8` | 38.9 | 37.6 | 3.0 |
| `writeu32(packHelper(r,g,b,a))` through a local function | 26.9 | 10.9 | 3.5 |
| `readu32` + four `extract` | 27.4 | 23.0 | 3.9 |
| four `readu8` | 24.2 | 23.3 | 4.0 |

**Full-frame kernels, 1024 x 1024 RGBA8 (ms per frame; lower is better)**

| Kernel | Interp O1 | Interp O2 | Native O2 |
|---|---|---|---|
| `buffer.fill` (memset) | 0.18 | 0.14 | 0.18 |
| seed one pixel, then `buffer.copy` doubling | 0.23 | 0.20 | 0.24 |
| 1024 row blits with `buffer.copy` | 0.43 | 0.36 | 0.38 |
| `writeu32` per pixel, constant colour | 10.9 | 10.3 | 2.9 |
| gradient, arithmetic pack per pixel | 14.2 | 14.6 | 3.6 |
| SDF circle, `sqrt` + `clamp` per pixel | 42.7 | 43.0 | 5.9 |
| SDF circle, `vector.magnitude` per pixel | 39.1 | 37.5 | 28.5 |
| **SDF circle, span skip (math only on the anti-aliased ring)** | **0.81** | **0.62** | **0.41** |
| 2 x 2 box mip to 512 x 512, per channel | 46.9 | 36.8 | 3.4 |
| 2 x 2 box mip to 512 x 512, SWAR | 37.2 | 29.1 | 2.1 |
| source-over blend onto opaque, float per channel | 100.0 | 79.6 | 8.8 |
| source-over blend onto opaque, SWAR exact /255 | 101.0 | 114.1 | 18.0 |
| LOD crossfade on the CPU, SWAR lerp | 118.2 | 122.2 | 18.5 |
| palette expand, u8 index to u32 | 25.5 | 20.9 | 4.1 |
| chroma key with smooth alpha | 64.7 | 51.5 | 6.6 |
| bilinear resample to 512 x 512 at 0.73 | 56.0 | 58.3 | 7.5 |
| 16 dirty 64 x 64 tiles | 0.79 | 0.81 | 0.18 |

### 6.7 Op economics: the rules that fall out

These are measured on a 2.1 GHz x64 server core. Phones are slower in absolute terms; the ratios are what carry over.

1. **A client cannot touch a whole 1024 x 1024 frame every frame.** Doing nothing but writing a constant costs about 10 ns per pixel in the interpreter, so one full pass is 10 ms. Shader-like kernels cost 40 to 120 ms. A 16.7 ms frame leaves room for roughly 100k to 400k cheap pixel writes, or 25k to 100k shaded pixels.
2. **Engine memory ops are 50 to 70 times faster than Luau loops.** `buffer.fill` and `buffer.copy` move 4.5 to 7 Gpix/s. Every span whose pixels are equal goes through them.
3. **Most pixels never need math.** Rendering only the anti-aliased band of a shape and filling the rest with `buffer.copy` turned a 43 ms SDF render into 0.6 ms, a 69x speedup. The library's rasterizer generalises this to any shape.
4. **Count builtin calls, not lines.** In the interpreter a builtin call costs 2 to 5 ns, a four-argument `bit32.bor` 7 to 11 ns, `math.clamp` about 7 ns, while an arithmetic opcode costs 1 to 2 ns. Pack pixels with arithmetic (11.8 ns) rather than `bit32` (18 to 23 ns) or four `writeu8` (38 ns).
5. **Never call a non-builtin per pixel.** `readbits`, `writebits`, `buffer.copy`, `buffer.len` and `readstring` cost 9 to 35 ns each. Call them per span, row or tile.
6. **SWAR only pays when it removes builtin calls.** It speeds the box mip up by 20 percent but slows exact blending down, because the extra masks cost more than the multiplies saved.
7. **LOD crossfades on the CPU are impossible at this resolution.** A 1024 x 1024 crossfade costs about 120 ms per frame in the interpreter. The GPU does the same blend for free through `ImageTransparency` or `Decal.Transparency`, which is what `Saturn` uses.
8. **Resampling and mip generation belong to the engine.** Luau bilinear resampling runs at about 5 Mpix/s and a box mip at 7 to 9 Mpix/s. `DrawImageTransformed` and baked mips do this in native code; the probe measures how fast.
9. **Cache upvalues in locals** before hot loops: 2.4 ns instead of 3 to 4 ns per buffer read.
10. **Studio playtests lie about helper calls.** At level 1 a small local helper costs 16 ns more per call than at level 2, where it is inlined. Profile pixel code in Studio with `--!optimize 2`.
11. **Scalar math beats `vector` for SDFs.** In the interpreter the vector version is about equal; natively it is 5x slower because each temporary vector goes through VM registers.
12. **Native code is a server-side multiplier of 4 to 10x** on per-pixel kernels. The way to use it for clients is to generate on the server and bake, so the result replicates as static content.
13. **No `pow`, `sin` or `exp` per pixel.** They cost 5 to 12 ns and are not bit-identical across platforms. Gamma goes through a 256-entry lookup table.
14. **Buffers hold pixels, tables hold small lookup tables.** Array tables are as fast to index, but cost 16 bytes per entry against 4, and cannot be bulk-copied.

---

## 7. In-engine measurements still to collect

Nothing in sections 2 to 5 that is labelled NOT PUBLICLY SPECIFIED can be measured outside Roblox. Three probes do it:

| Script | Where to put it | What it reports |
|---|---|---|
| `studio/EditableImageProbe.luau` + `studio/RunProbe.client.luau` | `StarterPlayerScripts` | size limits, buffer-length rules, client budget, every API's run time, combine-op truth tables with best-fit formulas, straight vs premultiplied storage, bilinear bleed and minification aliasing, bake latency |
| `studio/RunProbe.server.luau` | `ServerScriptService` with a copy of the probe module | the same without the budget section |
| `studio/ParallelProbe.client.luau` | inside an `Actor` in `StarterPlayerScripts` | which calls the engine allows in the parallel phase, parallel `ReadPixelsBuffer` cost, serial write of a parallel-computed buffer |

Run the client probe in a published place on each target device class for budget numbers, and paste the output under this heading.

---

## 8. Sources

- Roblox creator-docs: `reference/engine/classes/EditableImage.yaml`, `AssetService.yaml`, `Decal.yaml`, `ImageLabel.yaml`, `SurfaceGui.yaml`, `MeshPart.yaml`, `SurfaceAppearance.yaml`, `datatypes/Content.yaml`, `enums/ImageCombineType.yaml`, `ImageAlphaType.yaml`, `ResamplerMode.yaml`, `luau/native-code-gen.md`, `luau/comments.md`, `scripting/multithreading.md`, `avatar/in-experience-creation.md`
- Roblox API dump and FVariables: MaximumADHD/Roblox-Client-Tracker, `API-Dump.json`, `FVariables.txt`, version `0.744.0.7441077`
- Luau source: `Common/include/Luau/Bytecode.h`, `Compiler/src/Builtins.cpp`, `CodeGen/src/IrTranslateBuiltins.cpp`, `CodeGen/src/OptimizeConstProp.cpp`, `CodeGen/src/IrLoweringX64.cpp`, `CodeGen/src/IrLoweringA64.cpp`, `VM/src/lbuflib.cpp`, `VM/src/lintlib.cpp`, `VM/src/lnumutils.h`, `VM/include/luaconf.h`
- DevForum announcements and reports (titles as published):
  - [[Full Release] Introducing CreateDataModelContent](https://devforum.roblox.com/t/full-release-introducing-createdatamodelcontent-convert-editable-mesh-and-image-data-into-static-content/4541898)
  - [Weekly Recap: May 18 - 21, 2026](https://devforum.roblox.com/t/weekly-recap-may-18-21-2026/4647113)
  - [In-Experience Build-a-Texture: EditableImage Support for SurfaceAppearance](https://devforum.roblox.com/t/in-experience-build-a-texture-editableimage-support-for-surfaceappearance/3866947)
  - [[Studio Beta] Major updates to in-experience Mesh & Image APIs](https://devforum.roblox.com/t/studio-beta-major-updates-to-in-experience-mesh-image-apis/3225681)
  - [[Client Beta] In-experience Mesh & Image APIs now available in published experiences](https://devforum.roblox.com/t/client-beta-in-experience-mesh-image-apis-now-available-in-published-experiences/3267293)
  - [Luau Native Code Generation Preview [Studio Beta]](https://devforum.roblox.com/t/luau-native-code-generation-preview-studio-beta/2572587)
  - [Enable --!native for clients](https://devforum.roblox.com/t/enable-native-for-clients/3170510)
  - [EditableImage higher resolution and memory limit](https://devforum.roblox.com/t/editableimage-higher-resolution-and-memory-limit/4389575)
  - [Allow EditableImage:WritePixelsBuffer() to go up to 2048x2048 for plugins](https://devforum.roblox.com/t/allow-editableimagewritepixelsbuffer-to-go-up-to-2048x2048-for-plugins/4568767)
  - [Failed to create empty EditableImage ... memory budget limits](https://devforum.roblox.com/t/failed-to-create-empty-editableimage-that-was-requested-due-to-reaching-memory-budget-limits-error/3490799)
  - [ComposeDecalAsync and private decals](https://devforum.roblox.com/t/composedecalasync-and-private-decals/4694441)
  - [Enable the Usage of AssetService:CreateDataModelContent for SurfaceAppearance Instances](https://devforum.roblox.com/t/enable-the-usage-of-assetservicecreatedatamodelcontent-for-surfaceappearance-instances/4802574)
  - [Crash when using Parallel luau and editable images](https://devforum.roblox.com/t/crash-when-using-parallel-luau-and-editable-images/4636165)
  - [EditableImage source blend does not blend color channel over image data](https://devforum.roblox.com/t/editableimage-source-blend-does-not-blend-color-channel-over-image-data/4636483)
  - ["Pixelated" ResampleMode for SurfaceAppearances](https://devforum.roblox.com/t/pixelated-resamplemode-for-surfaceappearances-pixel-art-meshes/4028314)
