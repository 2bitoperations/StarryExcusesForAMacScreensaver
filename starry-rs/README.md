# starry-rs

A cross-platform Rust + [wgpu](https://wgpu.rs) port of `StarryExcuseForAMacScreensaver`.

## Why this exists

The Swift codebase in `../StarryExcuseForAMacScreensaver/` is the current shipping macOS screensaver. The long-term plan is to migrate the entire project — including macOS — to this Rust + wgpu implementation, which can target macOS (Metal), Linux (Vulkan/GL), and Windows (D3D12) from a single codebase.

Until that migration is complete, the Swift code remains the visual ground-truth: when in doubt about how a feature should *look*, run the Swift `StarryPreview.app` and compare side-by-side.

## Status

Working on the **Rust port roadmap**:

- [x] **Phase 0** — winit window + wgpu device + clear color (foundation)
- [ ] **Phase 1** — sprite pipeline (random dots as star stand-ins)
- [ ] **Phase 2** — port `Buildings`, `Skyline`, `SkylineCoreRenderer` (stars, buildings, window lights, flasher)
- [ ] **Phase 3** — ping-pong textures + decay pipeline + shooting stars + satellites
- [ ] **Phase 4** — procedural moon texture + moon shader (phase + traversal)
- [ ] **Phase 5** — `Planet` + `PlanetTexture` (all 8 planets, Jovian/Saturnian moons) → feature parity with Swift build
- [ ] **Phase 6** — TOML config, debug overlay, deterministic seed mode → v0.1

Platform packaging (`.saver` bundle on macOS, `.scr` on Windows, xscreensaver hack on Linux) and a settings UI are explicitly out of scope until the renderer is at feature parity.

## Build & run

Requires a stable Rust toolchain (install via [rustup](https://rustup.rs)).

```bash
cargo run            # debug build, fast iteration
cargo run --release  # release build, full performance
```

Closing the window exits the process.

### Logging

The app uses `env_logger`. Crank verbosity via the `RUST_LOG` environment variable:

```bash
RUST_LOG=info cargo run    # default
RUST_LOG=debug cargo run   # see wgpu's chatter too
RUST_LOG=wgpu_core=warn,starry_rs=debug cargo run  # mix-and-match
```

## Layout

Currently flat — everything is in `src/main.rs` because Phase 0 is just a window + clear pass. Phase 1+ will introduce the module structure:

```
src/
├── main.rs              entry point + winit/wgpu glue
├── app.rs               app state
├── core/                simulation (engine, skyline, moon, planet, ...)
├── render/              wgpu renderer (pipelines, layer textures, frame encode)
├── textures/            procedural moon + planet textures
└── debug/               FPS counter, build info overlay
shaders/                 WGSL shaders
```

## License

MIT — same as the parent project. See [`../LICENSE.md`](../LICENSE.md).
