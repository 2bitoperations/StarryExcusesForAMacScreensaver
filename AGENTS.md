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

### Status (Phase 3 — June 2026)
Windowed app and headless `--dump-png` mode both drive a real `Engine` that ports `StarryEngine.swift` + `Skyline.swift` + `SkylineCoreRenderer.swift` + `Buildings.swift` + `ShootingStarsLayerRenderer.swift` + `SatellitesLayerRenderer.swift`: seeded skyline generation, horizon-weighted stars, building windows with random per-tile light states, rate-clocked sprite emission, periodic clear, a flashing beacon on the tallest building, **additive shooting-star streaks with decaying trails (`keep = 0.5^(dt/halfLife)`)**, and **additive satellite point-lights traversing a flasher-constrained band with their own decay half-life**. Rendering uses three persistent FBOs (skyline + two ping-pong pairs for satellites/shooting) orchestrated through a 6-pass per-frame encode (sat decay → shoot decay → skyline sprites → sat sprites → shoot sprites → composite), with stateless N-layer composite blending in Swift Z-order (skyline → satellites → shooting). Disabling either decay layer via `--*-enabled false` skips texture allocation entirely. CLI surfaces all 27 knobs (12 Phase-2 + 15 Phase-3) via clap with defaults mirroring `StarryDefaultsManager.swift`. No moon, no planets yet. See the phased roadmap in [`starry-rs/README.md`](starry-rs/README.md) and the granular engineering scratchpad in [`starry-rs/PORT_PLAN.md`](starry-rs/PORT_PLAN.md).

### File layout (will grow as phases land)
 - `starry-rs/Cargo.toml` - Crate manifest. Deps pinned to major versions: wgpu 29, winit 0.30, pollster 0.4, log 0.4, env_logger 0.11, rand 0.8, bytemuck 1 (derive), png 0.17, clap 4 (derive). Release profile uses `lto = "thin"` and `codegen-units = 1`.
 - `starry-rs/src/main.rs` - Entry point: env_logger init, `Config::parse()` via clap, dispatch to either the windowed path or the headless single-frame PNG dump.
 - `starry-rs/src/app.rs` - winit `ApplicationHandler` impl: window creation, GPU lifecycle, redraw loop. Owns `Engine`; rebuilds it (preserving seed) on resize since the skyline geometry is resolution-dependent.
 - `starry-rs/src/config.rs` - clap-derive `Config` (27 fields: 12 Phase-2 + 15 Phase-3 across `shooting_stars_*` and `satellites_*`; bools use `clap::ArgAction::Set` so `--flag false` disables) + `CLEAR_COLOR` (opaque black sky, per Swift parity) + `LAYER_WIPE_COLOR` (transparent black for the persistent skyline layer's periodic wipe) + `SPRITE_CAPACITY = 131_072` + rate helpers that scale Swift's reference per-second rates by canvas area.
 - `starry-rs/src/types.rs` - `Color { r, g, b: f32 }` + `Point { x, y: i32, color: Color }` value types + `random_star_color` producing pastel blue/purple/red mixes (matches Swift's `r:[0,0.5] g:[0,0.5] b:[0,1.0]` ranges).
 - `starry-rs/src/buildings.rs` - 6 `BuildingStyle` 8×8 tile patterns + `Building` (start_x, start_y, width, height, style, lights_on bitmap) + `contains` + `is_light_on` (samples the style pattern wrapped over the building rectangle).
 - `starry-rs/src/skyline.rs` - `Skyline` static world: buildings (Z-ordered topmost-by-`start_x`), per-column `sky_floor` for star rejection sampling, optional flasher on the tallest building, periodic-clear timer, **`building_max_height: i32`** for downstream layers (e.g. ShootingStars `safeMinY`). Key methods: `attempt_star` (single-shot rejection — caller drives the attempt count), `sample_building_light` (bounded ≤ 200 retries unlike Swift's infinite loop), `flasher_state`, `should_clear_now` / `mark_cleared`.
 - `starry-rs/src/skyline_renderer.rs` - Per-frame sprite emitter. Accumulates fractional sprite quotas per-second (Swift parity), drains them into instanced `SpriteInstance`s for stars, building lights, and the flasher. `POINT_SPRITE_SIZE = 1.5`.
 - `starry-rs/src/shooting_stars.rs` - `ShootingStarsRenderer` ports `ShootingStarsLayerRenderer.swift`. Poisson spawn (per-frame Bernoulli `p = dt/avg`), 18-segment trail interpolation, 15% fade-in over the first 15% of streak length, head-sprite size = thickness. Emits additive `SpriteInstance`s for each active streak per frame; engine pairs with decay layer for the trail effect.
 - `starry-rs/src/satellites.rs` - `SatellitesRenderer` ports `SatellitesLayerRenderer.swift`. Exponential next-spawn timer, flasher-constrained spawn band (`y_min = max(building_max_height, flasher_y + r + gap + d/2)`), at most one active satellite at a time. Emits one additive point-sprite per frame; engine pairs with decay layer for the trail effect.
 - `starry-rs/src/engine.rs` - Simulation orchestrator: owns `Skyline` + `SkylineRenderer` + `Option<SatellitesRenderer>` + `Option<ShootingStarsRenderer>` + seeded `StdRng` + dt clock. `frame()` ticks against wall-clock with `MAX_DT_SECONDS = 0.25` clamp; `frame_with_dt(dt)` trusts the caller (no clamp — used by headless at dt=5.0s for visually-rich single-frame output); both delegate to `frame_impl(dt)`. Returns `FrameOutput { skyline_sprites, clear_skyline, satellites: Option<LayerFrame>, shooting: Option<LayerFrame> }` where `LayerFrame { sprites, decay }` bundles the per-layer sprite stream with its decay `keep_factor`.
 - `starry-rs/src/gpu.rs` - `GpuState` — wgpu Surface/Device/Queue + skyline `Texture` + `Option<DecayLayer>` for satellites and shooting (so `--*-enabled false` fully skips GPU allocation) + skyline `SpriteRenderer` + `CompositeRenderer`. `DecayLayer { tex_a, view_a, tex_b, view_b, active_is_a, sprites, decay }` owns each layer's full ping-pong state. Per-frame 6-pass encode: (1) satellites decay → swap; (2) shooting decay → swap; (3) skyline sprite pass with `LoadOp::Clear(LAYER_WIPE_COLOR)` if `clear_skyline` else `Load`; (4) satellites sprite pass (Additive); (5) shooting sprite pass (Additive); (6) composite pass into swapchain `LoadOp::Clear(CLEAR_COLOR)` blending `[skyline, satellites?, shooting?]` in Z-order. Resize rebuilds all textures and resets `active_is_a = true`.
 - `starry-rs/src/sprite.rs` - `SpriteInstance` (POD, `repr(C)`, position + scalar diameter + RGBA) + `BlendMode::{Over, Additive}` enum + `SpriteRenderer::new(device, format, capacity, mode)` (instanced quad pipeline parameterized by blend mode, viewport UBO, **grow-on-demand instance VBO** that resizes to `n.next_power_of_two().max(capacity * 2)` on overflow). Skyline uses Over; satellites + shooting use Additive.
 - `starry-rs/src/decay.rs` - `DecayRenderer` fullscreen-quad pass that runs `out = textureLoad(src) * keep_factor` from one texture into another. Per-layer instance owns its own UBO (FIFO `write_buffer` ordering means one renderer per layer avoids overwriting in-flight uniforms). Called by `gpu.rs::run_decay_layer()` which then triggers `DecayLayer::swap()`.
 - `starry-rs/src/composite.rs` - `CompositeRenderer`: stateless N-layer compositor. `draw_all(device, pass, &[&TextureView])` builds a temporary bind group per layer view and blends each over the swapchain in slice order with `PREMULTIPLIED_ALPHA_BLENDING`. No caching, no `rebind()` — just rebuild every frame; it's essentially free on the GPU and saves an entire class of bookkeeping bugs.
 - `starry-rs/src/headless.rs` - `dump_png(&Config)` — offscreen `Rgba8UnormSrgb` render-to-texture, drives a real `Engine` at fixed `dt = 5.0s` for deterministic byte-stable output. Single-frame so it skips the ping-pong machinery entirely (at `dt=5s` the decay layers mathematically collapse to ~0): 3 render passes into the same readback target — skyline-Over with `Clear(CLEAR_COLOR)`, satellites-Additive with `Load`, shooting-Additive with `Load`. Padded `copy_texture_to_buffer` readback, writes PNG via the `png` crate.
 - `starry-rs/src/shader.wgsl` - Sprite vertex (pixel→NDC via viewport UBO, Y-up matching Swift) + fragment (round-disc with soft edge, premultiplied output) shaders.
 - `starry-rs/src/decay.wgsl` - Fullscreen-triangle vertex + fragment that samples `src` via `textureLoad` and multiplies by `uniforms.keep`. One per-layer UBO; called once per decay layer per frame.
 - `starry-rs/src/composite.wgsl` - Composite vertex (3-vert fullscreen triangle via `vertex_index`) + fragment (`textureLoad` passthrough — blending happens in the pipeline's blend state, not the shader).
 - `starry-rs/README.md` - Build/run instructions, phased roadmap, CLI reference tables (Phase 2 + Phase 3), headless usage, layout notes.
 - `starry-rs/PORT_PLAN.md` - In-tree engineering scratchpad: granular phase scoping, active todos, decisions log, validation history, open questions. Committed alongside the work it tracks; the user-facing roadmap lives in `README.md`.

### Conventions specific to the Rust side
 - **Pinned wgpu version.** Stay on `wgpu = "29"` until a deliberate, scoped upgrade. wgpu reshapes its API between minor releases — 29 alone introduced `experimental_features`, `multiview_mask`, `depth_slice`, and replaced `SurfaceError` with the `CurrentSurfaceTexture` enum. Bumping mid-port is a recipe for sadness.
 - **Module layout — single crate for now, workspace split deferred.** Code is split into focused modules within the single `starry-rs` crate (`app`, `gpu`, `sprite`, `composite`, `decay`, `config`, `types`, `buildings`, `skyline`, `skyline_renderer`, `shooting_stars`, `satellites`, `engine`, `headless`, plus three `.wgsl` shaders). It'll split into a `starry-core` (headless, testable) + `starry-app` (winit shell) workspace at the first natural seam — reassessing after the moon (Phase 4) lands, since procedural texture generation might be the natural extraction point.
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
