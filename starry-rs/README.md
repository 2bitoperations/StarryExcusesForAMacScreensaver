# starry-rs

A cross-platform Rust + [wgpu](https://wgpu.rs) port of `StarryExcuseForAMacScreensaver`.

## Why this exists

The Swift codebase in `../StarryExcuseForAMacScreensaver/` is the current shipping macOS screensaver. The long-term plan is to migrate the entire project — including macOS — to this Rust + wgpu implementation, which can target macOS (Metal), Linux (Vulkan/GL), and Windows (D3D12) from a single codebase.

Until that migration is complete, the Swift code remains the visual ground-truth: when in doubt about how a feature should *look*, run the Swift `StarryPreview.app` and compare side-by-side.

## Status

Working on the **Rust port roadmap**:

- [x] **Phase 0** — winit window + wgpu device + clear color (foundation)
- [x] **Phase 1** — sprite pipeline (random dots as star stand-ins) + headless `--dump-png` mode
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

### Headless single-frame render (`--dump-png`)

For visual verification from environments without display access (CI servers, sandboxed shells, remote machines), and as the foundation for future Phase 6 golden-image diff tests:

```bash
cargo run -- --dump-png /tmp/starry.png
```

Renders one frame of the default scene at 1280×800 to an 8-bit RGBA PNG, then exits. Because the star generator uses a fixed seed, the output is byte-stable across runs — perfect for committing reference images and diffing later.

### Logging

The app uses `env_logger`. Crank verbosity via the `RUST_LOG` environment variable:

```bash
RUST_LOG=info cargo run    # default
RUST_LOG=debug cargo run   # see wgpu's chatter too
RUST_LOG=wgpu_core=warn,starry_rs=debug cargo run  # mix-and-match
```

## Layout

```
src/
├── main.rs         entry point + CLI dispatch (windowed vs --dump-png)
├── app.rs          winit ApplicationHandler — owns the window + GpuState
├── gpu.rs          wgpu Surface/Device/Queue + per-frame render loop
├── sprite.rs       instanced-quad sprite pipeline (SpriteRenderer)
├── scene.rs        scene data & visual constants (stars, clear color, sizes)
├── headless.rs     offscreen render to PNG for visual verification / tests
└── shader.wgsl     vertex + fragment shaders for the sprite pipeline
```

Phase 2+ will grow `scene.rs` into a proper `Skyline` simulation module and likely split `gpu.rs` into per-layer renderers.

## License

MIT — same as the parent project. See [`../LICENSE.md`](../LICENSE.md).
