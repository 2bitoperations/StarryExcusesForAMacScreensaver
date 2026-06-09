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

### Status (Phase 0 — June 2026)
Just a windowed app with a clear pass. winit `ApplicationHandler` + wgpu Surface/Device/Queue plumbing only. No sprites yet. See the phased roadmap in [`starry-rs/README.md`](starry-rs/README.md).

### File layout (will grow as phases land)
 - `starry-rs/Cargo.toml` - Crate manifest. Deps pinned to major versions: wgpu 29, winit 0.30, pollster 0.4, log 0.4, env_logger 0.11. Release profile uses `lto = "thin"` and `codegen-units = 1`.
 - `starry-rs/src/main.rs` - Phase 0 entry point: `ApplicationHandler` impl, GPU init via `pollster`, per-frame clear pass.
 - `starry-rs/README.md` - Build/run instructions, phased roadmap, layout notes.

### Conventions specific to the Rust side
 - **Pinned wgpu version.** Stay on `wgpu = "29"` until a deliberate, scoped upgrade. wgpu reshapes its API between minor releases — 29 alone introduced `experimental_features`, `multiview_mask`, `depth_slice`, and replaced `SurfaceError` with the `CurrentSurfaceTexture` enum. Bumping mid-port is a recipe for sadness.
 - **Module layout deferred.** Code is currently flat in `main.rs`. It will split into a `starry-core` (headless, testable) + `starry-app` (winit shell) workspace at the first natural seam — probably around Phase 1 or 2.
 - **Visual ground-truth = Swift.** When porting a layer, read the Swift source carefully and match behavior pixel-ish-for-pixel-ish. [`METAL_RENDERER_MAP.md`](METAL_RENDERER_MAP.md) is the architectural cheat sheet (5 pipelines: spriteOver, spriteAdditive, decayInPlace, moon, composite; ping-pong layer textures).
 - **Rust style.** Standard `cargo fmt` + `cargo clippy` cleanliness. Same simplicity/readability bar as the Swift code — fancy optimizations only when they meaningfully help.


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
