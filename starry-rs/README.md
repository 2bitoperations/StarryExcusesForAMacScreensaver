# starry-rs

A cross-platform Rust + [wgpu](https://wgpu.rs) port of `StarryExcuseForAMacScreensaver`.

## Why this exists

The Swift codebase in `../StarryExcuseForAMacScreensaver/` is the current shipping macOS screensaver. The long-term plan is to migrate the entire project — including macOS — to this Rust + wgpu implementation, which can target macOS (Metal), Linux (Vulkan/GL), and Windows (D3D12) from a single codebase.

Until that migration is complete, the Swift code remains the visual ground-truth: when in doubt about how a feature should *look*, run the Swift `StarryPreview.app` and compare side-by-side.

## Status

Working on the **Rust port roadmap**:

- [x] **Phase 0** — winit window + wgpu device + clear color (foundation)
- [x] **Phase 1** — sprite pipeline (random dots as star stand-ins) + headless `--dump-png` mode
- [x] **Phase 2** — port `Buildings`, `Skyline`, `SkylineCoreRenderer` (stars, buildings, window lights, flasher) + persistent skyline-layer FBO + composite pass (Swift parity)
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

Renders one simulated frame to an 8-bit RGBA PNG at the requested size and exits. The headless path drives the `Engine` at a fixed `dt = 5.0s` against a seeded RNG (default `--seed 42`), so output is byte-stable across runs for a given `(seed, width, height)` — perfect for committing reference images and diffing later.

### CLI flags

`starry-rs` uses `clap` derive for argument parsing. Run `cargo run -- --help` for the full list. Phase-2 highlights:

| Flag | Default | What |
|---|---:|---|
| `--width <px>` | 1280 | Window / dump width |
| `--height <px>` | 800 | Window / dump height |
| `--dump-png <path>` | — | Headless mode: render one frame to PNG, exit |
| `--seed <u64>` | 42 | RNG seed for skyline geometry + sprite emission |
| `--stars-fraction <0..1>` | 0.5 | Star emission rate as a fraction of the reference max |
| `--lights-fraction <0..1>` | 0.25 | Building-light emission rate fraction |
| `--clear-interval-s <s>` | 120.0 | Seconds between full-canvas wipes |
| `--building-height-pct-max <0..1>` | 0.35 | Tallest building as a fraction of canvas height |
| `--flasher-radius <px>` | 4 | Beacon-light radius on the tallest building |
| `--flasher-period-s <s>` | 2.0 | Beacon on/off period |
| `--building-frequency <0..1>` | 0.033 | Building density along the horizon |

Defaults mirror [`StarryDefaultsManager.swift`](../StarryExcuseForAMacScreensaver/StarryDefaultsManager.swift) so a fresh-install Rust run looks like a fresh-install Swift run.

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
├── main.rs                entry point + CLI dispatch (windowed vs --dump-png)
├── app.rs                 winit ApplicationHandler — owns Window + GpuState + Engine
├── config.rs              clap Config + visual constants (CLEAR_COLOR, LAYER_WIPE_COLOR, SPRITE_CAPACITY)
├── types.rs               Color + Point value types + random_star_color
├── buildings.rs           6 BuildingStyles + Building + tile-pattern lookup
├── skyline.rs             Static world: building generation, sky-floor, flasher, periodic-clear timer
├── skyline_renderer.rs    Per-frame sprite emitter (rate-clocked stars/lights/flasher)
├── engine.rs              Simulation orchestrator: Skyline + RNG + dt clock + FrameOutput
├── gpu.rs                 wgpu Surface/Device/Queue + persistent skyline FBO + per-frame 2-pass render
├── sprite.rs              Instanced-quad sprite pipeline (premultiplied-alpha blend, grow-on-demand)
├── composite.rs           Fullscreen-tri pass that blends the persistent skyline FBO over CLEAR_COLOR
├── headless.rs            Offscreen single-frame render to PNG for visual verification / tests
├── shader.wgsl            Sprite vertex + fragment (pixel→NDC, round-disc, premultiplied output)
└── composite.wgsl         Composite vertex (3-vert fullscreen tri) + fragment (textureLoad passthrough)
```

Phase 3+ will add ping-pong textures for decay (shooting stars, satellites) and likely split `gpu.rs` into per-layer renderers.

## License

MIT — same as the parent project. See [`../LICENSE.md`](../LICENSE.md).
