# AI Agents Instructions

This repository contains swift code to implement a screensaver for MacOS that tries to be an homage to the old AfterDark Starry Night screensaver from the late 90s. Rendering layer implemented with Metal.

I always, always, always want you to discuss any changes you want to make (and their tradeoffs, if any,) before actually making them.

This project is supposed to serve as a fun learning test bed for agentic programming, and as such, our tone should always be lighthearted and welcoming.

## File Contents

### Core
 - `StarryExcuseForAView.swift` - Main entrypoint for the screensaver, where the hooks from the OS live, also where configuration options are read into the engine.
 - `StarryEngine.swift` - Orchestrates the overall simulation loop, configuration changes, timing, renderer creation, and per-frame data assembly (sprites, moon params, clears) for GPU or headless rendering.
 - `Skyline.swift` - Generates and maintains the static structural world state (buildings, flasher geometry, and moon) plus utility methods to sample stars and building light points while managing timed clearing and moon/flasher behavior.

### Simulation Layer Renderers
 - `SkylineCoreRenderer.swift` - Converts the evolving skyline simulation into per-frame sprite instances by time-based spawning of stars, building lights, and an optional flasher using configured per-second rates.
 - `ShootingStarsLayerRenderer.swift` - Simulates shooting stars with randomized trajectories, brightness curves, and configurable spawn rates. Produces additive sprites that leave trails.
 - `SatellitesLayerRenderer.swift` - Simulates satellite point-lights traversing the sky on randomized great-circle-ish paths with configurable speed, brightness, and spawn rates.
 - `MoonLayerRenderer.swift` - Computes the moon's screen position along a traversal arc and its phase angle, producing `MoonParams` for the GPU moon shader.
 - `DebugLayerRenderer.swift` - Generates the FPS counter and CPU usage debug overlay sprites when debug mode is enabled.

### Data Types & Helpers
 - `MetalTypes.swift` - Defines GPU-shared data types: `SpriteInstance`, `SpriteShape`, `MoonUniforms`, `StarryDrawData`, and related enums/structs.
 - `Moon.swift` - Moon phase calculation (based on real-world lunar cycle) and traversal path geometry.
 - `MoonTexture.swift` - Procedural generation of the moon's albedo texture (cratered, noisy lunar surface).
 - `Buildings.swift` - Building style definitions and tile patterns used to generate the skyline silhouette.
 - `Points.swift` - Lightweight `Point` and `Color` value types used throughout the simulation.
 - `DebugSprites.swift` - Helper to generate debug outline rectangle sprites for visual debugging.

### GPU Rendering
 - `StarryMetalRenderer.swift` - The Metal rendering pipeline: manages GPU resources, pipelines, offscreen textures, sprite upload, per-frame scene encoding, compositing, and moon rendering. See [METAL_RENDERER_MAP.md](METAL_RENDERER_MAP.md) for an architectural overview.

### Configuration
 - `StarryConfigSheetController.swift` - Handles drawing the screensaver options panel and associated controls.
 - `StarryDefaultsManager.swift` - Handles storing and fetching screensaver options values. Reasonable default fallback values for each option live here. Accepts an optional `moduleIdentifier` parameter to override the defaults domain.
 - `BuildInfo.swift` - Auto-generated at build time by a Run Script phase. Contains the git commit hash constant `buildCommit`.

### Preview App (`PreviewApp/`)
 - `main.swift` - Entry point for the standalone StarryPreview app.
 - `PreviewAppDelegate.swift` - Creates a borderless window hosting the screensaver view. Reads the user's saved settings from the sandboxed screensaver container (see Known Quirks below) and displays a build-info overlay.
 - `PreviewApp-Info.plist` - Minimal app plist for the preview target.


## Documentation Guidelines
Any changes to code must be paired with updates to the relevant documentation if they materially change behavior, file roles, or architecture. This includes (but is not limited to):
 - Adding, removing, or renaming source files → update the File Contents section above.
 - Changing the rendering pipeline → update [METAL_RENDERER_MAP.md](METAL_RENDERER_MAP.md).
 - Adding or completing a feature → update the Status checklist in [README.md](README.md).


## Coding Guidelines
Simplicity and understandability are highly valued. Fancy performance optimizations should only be used if they will significantly improve rendering speed or efficiency. 

Swift best practices must be followed unless we have a tremendously compelling reason to deviate from them.


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
