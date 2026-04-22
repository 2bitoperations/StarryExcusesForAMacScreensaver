# Metal Renderer Architecture Map

A friendly guide to how `StarryMetalRenderer.swift` turns simulation data into pixels. If you're poking around the rendering code for the first time, start here!

## High-Level Data Flow

```
StarryExcuseForAView (OS timer fires)
  → StarryEngine.assembleDrawData()
      ├─ SkylineCoreRenderer  → base sprites (stars, building lights, flasher)
      ├─ ShootingStarsLayerRenderer → shooting star sprites
      ├─ SatellitesLayerRenderer    → satellite sprites
      └─ MoonLayerRenderer          → moon parameters (position, phase, brightness)
  → StarryMetalRenderer.render(drawData)
      ├─ Upload sprites to GPU
      ├─ Encode scene passes (base, satellites, shooting stars)
      ├─ Encode composite + moon pass
      └─ Present to screen
```

The engine assembles a `StarryDrawData` struct each frame containing all the sprites and moon info. The Metal renderer's job is purely visual — it doesn't know about simulation logic, it just draws what it's told.

## GPU Pipelines

Five render pipelines are built once in `buildPipelines()`:

| Pipeline | Blend Mode | Purpose |
|---|---|---|
| `spriteOverPipeline` | Alpha-over | Standard sprites — stars, building lights, flasher |
| `spriteAdditivePipeline` | Additive | Trail-leaving sprites — satellites, shooting stars |
| `decayInPlacePipeline` | Custom (keep factor) | Fades trail textures over time for that comet-tail look |
| `moonPipeline` | Alpha-over | Dedicated moon shader with phase and albedo |
| `compositePipeline` | Alpha-over | Composites layer textures onto the final drawable |

All pipelines use `bgra8Unorm` pixel format to match the screen drawable.

## Layer Textures

The renderer maintains a set of offscreen textures (all `.private` storage, same size as the screen) organized in a `LayerTextures` struct:

```
LayerTextures
  ├─ base           — stars, buildings, flasher (cleared each frame)
  ├─ satellites      — satellite trails (persistent, decayed each frame)
  ├─ satellitesScratch — temp buffer for satellite decay pass
  ├─ shooting        — shooting star trails (persistent, decayed each frame)
  └─ shootingScratch  — temp buffer for shooting star decay pass
```

**Why scratch textures?** The decay pass reads from one texture and writes to another — you can't read and write the same texture in Metal. So each trail layer ping-pongs between its main texture and its scratch texture.

## Per-Frame Render Flow

Each call to `render()` follows this sequence:

### 1. Sprite Upload
CPU-side sprite data (from `StarryDrawData`) is copied into a Metal staging buffer, then blitted to a private GPU buffer. Sprites are grouped by *provenance* — which layer they belong to — so each scene pass knows its slice of the buffer.

### 2. Scene Passes (`encodeScenePasses`)

Three passes, one per layer:

1. **Base layer** — Clear the base texture to black, then draw base sprites (stars, building lights, flasher) using `spriteOverPipeline` with alpha-over blending.

2. **Satellites layer** — Apply `decayInPlacePipeline` to fade the previous frame's satellite trails (the "keep" factor controls how fast trails fade). Then draw new satellite sprites using `spriteAdditivePipeline` with additive blending, so bright points accumulate.

3. **Shooting stars layer** — Same decay-then-draw pattern as satellites, but with its own textures and decay rate.

### 3. Composite + Moon Pass (`encodeCompositeAndMoon`)

1. Clear the drawable to black
2. Draw each layer texture (base, satellites, shooting) as a full-screen textured quad using `compositePipeline`
3. Draw the moon using `moonPipeline` with its dedicated vertex/fragment shader
4. Optionally draw the debug overlay (FPS, CPU stats)

## Planet Rendering

Planets use a dedicated `PlanetVertex` / `PlanetFragment` shader pair similar to the moon pipeline:

1. **Vertex shader**: Maps planet position and radius to screen space, supporting non-square aspect ratios (used only for Saturn to accommodate geometric rings).
2. **Fragment shader**: Handles two distinct code paths:
   - **Non-Saturn planets**: Standard textured sphere with phase-based illumination and terminator shading (same modes as moon: Hard, Smooth, Banded).
   - **Saturn**: Geometric ring rendering with six procedural bands (C ring, B ring inner/outer, Cassini division, A ring inner/outer, Encke gap). Rings are composited with occlusion-aware blending — rings in front of the planet alpha-blend over the body; rings behind the planet are occluded. Ring tilt angle (B) and position angle (P) are computed from Keplerian orbital mechanics and passed via uniforms. Rings render as flat-shaded bands with distinct colors and opacity for retro pixel-art aesthetic. Edge-on guard skips ring rendering when opening angle is sub-pixel.
3. **Textures**: All planets use square procedural textures except Saturn's legacy non-square path is removed — Saturn now uses a square body-only texture (rings are pure geometry).

## The Trail System (Decay-in-Place)

The shooting star and satellite trails are the trickiest bit of rendering. Here's how they work:

1. **Persistence**: Unlike the base layer (cleared every frame), trail textures are *never* cleared. Old sprites stay in the texture.
2. **Decay**: Each frame, a full-screen decay pass multiplies every pixel by a "keep" factor less than 1.0, gradually fading old content toward black.
3. **Keep factor math**: `keep = 0.5^(dt / halfLife)` — where `halfLife` is configured per layer. A 2-second half-life means pixels reach half brightness after 2 seconds.
4. **Additive blending**: New sprites are drawn with additive blending, so overlapping trails get brighter rather than occluding each other.

The result: bright points that leave smoothly fading trails behind them. ✨

## Moon Rendering

The moon gets special treatment with its own shader pipeline:

1. **Albedo texture**: Generated procedurally by `MoonTexture.swift` — a cratered, slightly noisy lunar surface. Uploaded once via a staging→private blit with mipmap generation.
2. **Moon shader**: A dedicated vertex/fragment shader pair that receives `MoonUniforms` — position, radius, phase angle, brightness, albedo texture, and terminator parameters (via `params2`). The fragment shader uses the phase to illuminate the correct portion of the disk.
3. **Terminator modes**: The transition between the lit and dark sides of the moon supports three rendering modes, controlled by `params2.x`:
   - **Mode 0 — Hard** (default): Binary step at the terminator line. Classic retro look.
   - **Mode 1 — Smooth**: `smoothstep` transition with configurable width (`params2.y`). Softer, more natural edge.
   - **Mode 2 — Banded**: Quantized brightness bands with soft transitions. Configurable band count (`params2.z`) and width (`params2.y`). Preserves the stylized 8-bit aesthetic while softening the terminator.
4. **Drawn last** in the composite pass so it composites correctly over the star field.

## Headless Rendering

`renderToImage()` provides the same rendering pipeline but outputs to a shared offscreen texture instead of a screen drawable. Used for preview thumbnails and testing. Returns a `CGImage`.

## Debug Features

- **Composite debug modes**: Can isolate individual layers (`satellitesOnly`, `baseOnly`, etc.) for visual debugging
- **Layer dumps**: Can save any layer texture to a PNG file via notification
- **Debug overlay**: `DebugLayerRenderer` draws FPS and CPU usage stats when enabled

## Resource Management

- `clearOffscreenTextures()` — Lightweight: fills textures with zeros (used on config changes, screen transitions)
- `releaseAllGPUResources()` — Deep clean: nils out all textures and buffers (used on sleep/dealloc)
- Drawable availability is tracked to handle cases where the GPU can't provide a drawable (window hidden, etc.)
