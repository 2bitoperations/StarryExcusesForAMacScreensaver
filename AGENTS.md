# AI Agents Instructions

This repository contains swift code to implement a screensaver for MacOS that tries to be an homage to the old AfterDark Starry Night screensaver from the late 90s. Rendering layer implemented with Metal.

I always, always, always want you to discuss any changes you want to make (and their tradeoffs, if any,) before actually making them.

This project is supposed to serve as a fun learning test bed for agentic programming, and as such, our tone should always be lighthearted and welcoming.

## File Contents

### Core
 - `StarryExcuseForAView.swift` - Main entrypoint for the screensaver, where the hooks from the OS live, also where configuration options are read into the engine.
 - `StarryEngine.swift` - Orchestrates the overall simulation loop, configuration changes, timing, renderer creation, and per-frame data assembly (sprites, moon params, clears) for GPU or headless rendering. Also emits automatic planet-moon point sprites (Galilean moons + Titan) into the shared sprite path.
 - `Skyline.swift` - Generates and maintains the static structural world state (buildings, flasher geometry, and moon) plus utility methods to sample stars and building light points while managing timed clearing and moon/flasher behavior.

### Simulation Layer Renderers
 - `SkylineCoreRenderer.swift` - Converts the evolving skyline simulation into per-frame sprite instances by time-based spawning of stars, building lights, and an optional flasher using configured per-second rates.
 - `ShootingStarsLayerRenderer.swift` - Simulates shooting stars with randomized trajectories, brightness curves, and configurable spawn rates. Produces additive sprites that leave trails.
 - `SatellitesLayerRenderer.swift` - Simulates satellite point-lights traversing the sky on randomized great-circle-ish paths with configurable speed, brightness, and spawn rates.
 - `MoonLayerRenderer.swift` - Computes the moon's screen position along a traversal arc and its phase angle, producing `MoonParams` for the GPU moon shader.
 - `DebugLayerRenderer.swift` - Generates the FPS counter and CPU usage debug overlay sprites when debug mode is enabled.

### Data Types & Helpers
 - `MetalTypes.swift` - Defines GPU-shared data types: `SpriteInstance`, `SpriteShape`, `MoonUniforms`, `PlanetParams`, `StarryDrawData`, and related enums/structs.
 - `Moon.swift` - Moon phase calculation (based on real-world lunar cycle) and traversal path geometry.
 - `MoonTexture.swift` - Procedural generation of the moon's albedo texture (cratered, noisy lunar surface).
 - `Planet.swift` - Keplerian orbital ephemeris for all 8 planets (Mercury, Venus, Mars, Jupiter, Saturn, Uranus, Neptune, Pluto), altitude/azimuth sky position from a hardcoded observer location, and screen-space mapping with three positioning modes: "random" (always randomised), "hide" (hidden when below horizon), or "randomWhenBelow" (orbital when visible, random otherwise). Positions use a per-engine nonce so "Regenerate Preview" shuffles them. Includes Saturn ring tilt calculation (Schlyter formula) and lightweight circular-orbit helpers for Jupiter/Saturn moon dot positions.
 - `PlanetTexture.swift` - Procedural RGBA texture generation for all 8 planets in a retro pixel-art style: Jupiter (horizontal bands, Great Red Spot, limb darkening, per-pixel noise), Saturn (square body-only texture — rings rendered geometrically in shader), Venus/Mars/Mercury (solid surfaces with atmospheric or weathered effects), and outer planets (gas giants and ice giants with varying detail and color schemes).
 - `Buildings.swift` - Building style definitions and tile patterns used to generate the skyline silhouette.
 - `Points.swift` - Lightweight `Point` and `Color` value types used throughout the simulation.
 - `DebugSprites.swift` - Helper to generate debug outline rectangle sprites for visual debugging.

### GPU Rendering
 - `StarryMetalRenderer.swift` - The Metal rendering pipeline: manages GPU resources, pipelines, offscreen textures, sprite upload, per-frame scene encoding, compositing, and moon rendering. See [METAL_RENDERER_MAP.md](METAL_RENDERER_MAP.md) for an architectural overview.

### Configuration
 - `StarryConfigSheetController.swift` - Handles drawing the screensaver options panel and associated controls, including per-planet size sliders, planetary position mode dropdown, Saturn ring tilt override (Automatic/Manual with angle slider), and planet terminator mode.
 - `StarryDefaultsManager.swift` - Handles storing and fetching screensaver options values. Reasonable default fallback values for each option live here. Accepts an optional `moduleIdentifier` parameter to override the defaults domain.
 - `BuildInfo.swift` - Auto-generated at build time by a Run Script phase. Contains the git commit hash constant `buildCommit`.

### Preview App (`PreviewApp/`)
 - `main.swift` - Entry point for the standalone StarryPreview app.
 - `PreviewAppDelegate.swift` - Creates a borderless window hosting the screensaver view. Reads the user's saved settings from the sandboxed screensaver container (see Known Quirks below) and displays a build-info overlay.
 - `PreviewApp-Info.plist` - Minimal app plist for the preview target.


## Rust + wgpu port (`starry-rs/`)

A cross-platform Rust + wgpu rewrite lives in [`starry-rs/`](starry-rs/). The plan is to eventually retire the Swift codebase on every platform — including macOS — once the Rust side reaches feature parity. Until then the Swift code remains the visual ground-truth and the shipping macOS product, and both trees live happily side by side in this repo.

### Status (Phase 2 — June 2026)
Windowed app and headless `--dump-png` mode both drive a real `Engine` that ports `StarryEngine.swift` + `Skyline.swift` + `SkylineCoreRenderer.swift` + `Buildings.swift`: seeded skyline generation, horizon-weighted stars, building windows with random per-tile light states, rate-clocked sprite emission, periodic clear, and a flashing beacon on the tallest building. Rendering uses a persistent skyline-layer FBO that accumulates sprites across frames and a composite pass that blends the layer over an opaque-black sky (Swift parity — `StarryMetalRenderer.swift:1593`). CLI surfaces all Phase-2 knobs via clap with defaults mirroring `StarryDefaultsManager.swift`. No moon, no decay layers (shooting stars, satellites), no planets yet. See the phased roadmap in [`starry-rs/README.md`](starry-rs/README.md).

### File layout (will grow as phases land)
 - `starry-rs/Cargo.toml` - Crate manifest. Deps pinned to major versions: wgpu 29, winit 0.30, pollster 0.4, log 0.4, env_logger 0.11, rand 0.8, bytemuck 1 (derive), png 0.17, clap 4 (derive). Release profile uses `lto = "thin"` and `codegen-units = 1`.
 - `starry-rs/src/main.rs` - Entry point: env_logger init, `Config::parse()` via clap, dispatch to either the windowed path or the headless single-frame PNG dump.
 - `starry-rs/src/app.rs` - winit `ApplicationHandler` impl: window creation, GPU lifecycle, redraw loop. Owns `Engine`; rebuilds it (preserving seed) on resize since the skyline geometry is resolution-dependent.
 - `starry-rs/src/config.rs` - clap-derive `Config` (12 fields: dimensions, dump path, emission fractions, geometry, seed, etc.) + `CLEAR_COLOR` (opaque black sky, per Swift parity) + `LAYER_WIPE_COLOR` (transparent black for the persistent skyline layer's periodic wipe) + `SPRITE_CAPACITY = 131_072` + rate helpers that scale Swift's reference per-second rates by canvas area.
 - `starry-rs/src/types.rs` - `Color { r, g, b: f32 }` + `Point { x, y: i32, color: Color }` value types + `random_star_color` producing pastel blue/purple/red mixes (matches Swift's `r:[0,0.5] g:[0,0.5] b:[0,1.0]` ranges).
 - `starry-rs/src/buildings.rs` - 6 `BuildingStyle` 8×8 tile patterns + `Building` (start_x, start_y, width, height, style, lights_on bitmap) + `contains` + `is_light_on` (samples the style pattern wrapped over the building rectangle).
 - `starry-rs/src/skyline.rs` - `Skyline` static world: buildings (Z-ordered topmost-by-`start_x`), per-column `sky_floor` for star rejection sampling, optional flasher on the tallest building, periodic-clear timer. Key methods: `attempt_star` (single-shot rejection — caller drives the attempt count), `sample_building_light` (bounded ≤ 200 retries unlike Swift's infinite loop), `flasher_state`, `should_clear_now` / `mark_cleared`.
 - `starry-rs/src/skyline_renderer.rs` - Per-frame sprite emitter. Accumulates fractional sprite quotas per-second (Swift parity), drains them into instanced `SpriteInstance`s for stars, building lights, and the flasher. `POINT_SPRITE_SIZE = 1.5`.
 - `starry-rs/src/engine.rs` - Simulation orchestrator: owns `Skyline` + `SkylineRenderer` + seeded `StdRng` + dt clock. `frame()` ticks against wall-clock with `MAX_DT_SECONDS = 0.25` clamp; `frame_with_dt(dt)` trusts the caller (no clamp — used by headless at dt=5.0s for visually-rich single-frame output). Returns `FrameOutput { sprites: &[SpriteInstance], clear_layer: bool }`.
 - `starry-rs/src/gpu.rs` - `GpuState` — wgpu Surface/Device/Queue + persistent `skyline_tex` RGBA layer + `SpriteRenderer` + `CompositeRenderer`. Per-frame: (1) sprite pass into `skyline_tex` with `LoadOp::Clear(LAYER_WIPE_COLOR)` if `clear_layer` else `Load`; (2) composite pass into swapchain with `LoadOp::Clear(CLEAR_COLOR)` then blends `skyline_tex` over it. Recreates `skyline_tex` and rebinds the composite bind group on resize.
 - `starry-rs/src/sprite.rs` - `SpriteInstance` (POD, `repr(C)`, position + scalar diameter + RGBA) + `SpriteRenderer` (instanced quad pipeline, viewport UBO, **grow-on-demand instance VBO** that resizes to `n.next_power_of_two().max(capacity * 2)` on overflow, premultiplied-alpha blend).
 - `starry-rs/src/composite.rs` - `CompositeRenderer`: fullscreen-triangle pipeline (no vertex buffer, 3-vert draw) that samples `skyline_tex` via `textureLoad` and blends with premultiplied-alpha over the swapchain. Exposes `rebind()` for resize-time re-pointing of the bind group.
 - `starry-rs/src/headless.rs` - `dump_png(&Config)` — offscreen `Rgba8UnormSrgb` render-to-texture, drives a real `Engine` at fixed `dt = 5.0s` for deterministic byte-stable output, renders sprites directly to the readback target (no persistence machinery needed since headless is single-frame), padded `copy_texture_to_buffer` readback, writes PNG via the `png` crate.
 - `starry-rs/src/shader.wgsl` - Sprite vertex (pixel→NDC via viewport UBO, Y-up matching Swift) + fragment (round-disc with soft edge, premultiplied output) shaders.
 - `starry-rs/src/composite.wgsl` - Composite vertex (3-vert fullscreen triangle via `vertex_index`) + fragment (`textureLoad` passthrough — blending happens in the pipeline's blend state, not the shader).
 - `starry-rs/README.md` - Build/run instructions, phased roadmap, CLI reference table, headless usage, layout notes.

### Conventions specific to the Rust side
 - **Pinned wgpu version.** Stay on `wgpu = "29"` until a deliberate, scoped upgrade. wgpu reshapes its API between minor releases — 29 alone introduced `experimental_features`, `multiview_mask`, `depth_slice`, and replaced `SurfaceError` with the `CurrentSurfaceTexture` enum. Bumping mid-port is a recipe for sadness.
 - **Module layout — single crate for now, workspace split deferred.** Code is split into focused modules within the single `starry-rs` crate (`app`, `gpu`, `sprite`, `composite`, `config`, `types`, `buildings`, `skyline`, `skyline_renderer`, `engine`, `headless`, plus two `.wgsl` shaders). It'll split into a `starry-core` (headless, testable) + `starry-app` (winit shell) workspace at the first natural seam — probably around Phase 3+ as the simulation layer grows.
 - **Visual ground-truth = Swift.** When porting a layer, read the Swift source carefully and match behavior pixel-ish-for-pixel-ish. [`METAL_RENDERER_MAP.md`](METAL_RENDERER_MAP.md) is the architectural cheat sheet (5 pipelines: spriteOver, spriteAdditive, decayInPlace, moon, composite; ping-pong layer textures).
 - **Determinism is a feature.** Both the windowed shell and headless mode seed all randomness from `Config::seed`. Resize rebuilds the `Engine` with the same seed so a given `(seed, w, h)` is reproducible.
 - **Rust style.** Standard `cargo fmt` + `cargo clippy --all-targets -- -D warnings` cleanliness. Same simplicity/readability bar as the Swift code — fancy optimizations only when they meaningfully help.


## Documentation Guidelines
Any changes to code must be paired with updates to the relevant documentation if they materially change behavior, file roles, or architecture. This includes (but is not limited to):
 - Adding, removing, or renaming source files → update the File Contents section above.
 - Changing the rendering pipeline → update [METAL_RENDERER_MAP.md](METAL_RENDERER_MAP.md).
 - Adding or completing a feature → update the Status checklist in [README.md](README.md).
 - Touching the Rust port (`starry-rs/`) → update [`starry-rs/README.md`](starry-rs/README.md) (phase status, file layout, dep versions) and the Rust section in this file when conventions change.


## Coding Guidelines
Simplicity and understandability are highly valued. Fancy performance optimizations should only be used if they will significantly improve rendering speed or efficiency. 

Swift best practices must be followed unless we have a tremendously compelling reason to deviate from them.


## Building, Installing & Running

The Xcode project has two targets:

| Target | Scheme | Product | What it is |
|--------|--------|---------|------------|
| `StarryExcuseForAMacScreensaver` | `StarryExcuseForAMacScreensaver` | `StarryExcuseForAMacScreensaver.saver` | The screensaver bundle |
| `StarryPreview` | `StarryPreview` | `StarryPreview.app` | Standalone preview app (borderless window, no System Prefs needed) |

### Build from the command line

```bash
# Build the screensaver bundle (Debug)
xcodebuild -project StarryExcuseForAMacScreensaver.xcodeproj \
  -scheme StarryExcuseForAMacScreensaver \
  -configuration Debug \
  build

# Build the preview app (Debug)
xcodebuild -project StarryExcuseForAMacScreensaver.xcodeproj \
  -scheme StarryPreview \
  -configuration Debug \
  build
```

Both products land in DerivedData:
```
~/Library/Developer/Xcode/DerivedData/StarryExcuseForAMacScreensaver-<hash>/Build/Products/Debug/
```

### Install the screensaver

Copy the built `.saver` bundle into the user Screen Savers directory:
```bash
BUILT="$(xcodebuild -project StarryExcuseForAMacScreensaver.xcodeproj \
  -scheme StarryExcuseForAMacScreensaver -showBuildSettings 2>/dev/null \
  | grep ' TARGET_BUILD_DIR' | xargs | cut -d' ' -f3)"

cp -R "$BUILT/StarryExcuseForAMacScreensaver.saver" ~/Library/Screen\ Savers/
```

After copying, open **System Settings → Screen Saver** and select it. (On first install macOS may prompt you to approve the bundle.)

### Run the preview app

The fastest way to visually verify changes — no screensaver activation required:
```bash
BUILT="$(xcodebuild -project StarryExcuseForAMacScreensaver.xcodeproj \
  -scheme StarryPreview -showBuildSettings 2>/dev/null \
  | grep ' TARGET_BUILD_DIR' | xargs | cut -d' ' -f3)"

open "$BUILT/StarryPreview.app"
```

Or equivalently, run the `StarryPreview` scheme directly from Xcode (⌘R with that scheme selected).

### Build & run the Rust port

The Rust crate is self-contained under `starry-rs/`. You need a Rust toolchain via [rustup](https://rustup.rs) (`sh.rustup.rs`); make sure `$HOME/.cargo/env` is sourced in your shell.

```bash
# Build (debug)
cargo build --manifest-path starry-rs/Cargo.toml

# Build + launch the window
cargo run --manifest-path starry-rs/Cargo.toml

# With logging
RUST_LOG=info cargo run --manifest-path starry-rs/Cargo.toml
```

Or `cd starry-rs && cargo run`. Phase 0 just opens a window and clears to a deep night-sky color — sprites land in Phase 1. See [`starry-rs/README.md`](starry-rs/README.md) for the full roadmap.


## Known Quirks

### Screensaver Defaults Live in a Sandboxed Container

On modern macOS (Ventura+), screensavers run inside the `com.apple.ScreenSaver.Engine.legacyScreenSaver` sandbox container. `ScreenSaverDefaults(forModuleWithName:)` persists preferences into that container's **ByHost** directory, not the user's global `~/Library/Preferences/`:

```
~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/
  Data/Library/Preferences/ByHost/<bundle-id>.<hardware-uuid>.plist
```

This means a standalone app (like StarryPreview) can't read those settings through the normal `ScreenSaverDefaults` API — it resolves to a different, non-containerized location and finds nothing.

**Our workaround**: `PreviewAppDelegate.seedDefaultsFromScreenSaverContainer()` reads the plist directly from the container path and seeds the values into the local `ScreenSaverDefaults` instance before the engine starts. If the plist isn't found (screensaver was never configured), the built-in fallback defaults in `StarryDefaultsManager` take over gracefully.

**If this breaks after a macOS update**, check whether Apple changed:
 - The container name (`com.apple.ScreenSaver.Engine.legacyScreenSaver`)
 - The storage path within the container (`Data/Library/Preferences/ByHost/`)
 - The plist naming convention (`<bundle-id>.<hardware-uuid>.plist`)
