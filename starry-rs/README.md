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
- [x] **Phase 3** — ping-pong textures + decay pipeline + shooting stars + satellites
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

`starry-rs` uses `clap` derive for argument parsing. Run `cargo run -- --help` for the full list.

**Core / Phase 2 (skyline):**

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

**Phase 3 (shooting stars):**

| Flag | Default | What |
|---|---:|---|
| `--shooting-stars-enabled <bool>` | true | Master enable for the shooting-stars layer (Option-skips texture allocation entirely if false) |
| `--shooting-stars-avg-seconds <s>` | 7.0 | Mean seconds between spawn attempts (per-frame Bernoulli `p = dt/avg`) |
| `--shooting-stars-direction-mode <0..4>` | 0 | 0=Random, 1=LeftToRight, 2=RightToLeft, 3=TopLeftToBottomRight, 4=TopRightToBottomLeft |
| `--shooting-stars-length <px>` | 160 | Base streak length, randomized ±15% per spawn |
| `--shooting-stars-speed <px/s>` | 600 | Streak speed (lifetime = length / speed) |
| `--shooting-stars-thickness <px>` | 2 | Head-sprite size |
| `--shooting-stars-brightness <0..1>` | 0.2 | Streak brightness multiplier |
| `--shooting-stars-trail-half-life-s <s>` | 0.10 | Decay half-life: every N seconds the layer fades to half intensity (0 → wipe transparent every frame) |

**Phase 3 (satellites):**

| Flag | Default | What |
|---|---:|---|
| `--satellites-enabled <bool>` | true | Master enable for the satellites layer |
| `--satellites-avg-spawn-seconds <s>` | 8.0 | Exponential mean for next-spawn timer |
| `--satellites-speed <px/s>` | 100.0 | Travel speed |
| `--satellites-size <px>` | 2 | Point-sprite size |
| `--satellites-brightness <0..1>` | 0.85 | Brightness multiplier |
| `--satellites-trailing <bool>` | true | If false, decay layer is wiped every frame (no streak) |
| `--satellites-trail-half-life-s <s>` | 0.40 | Decay half-life (longer than shooting stars → satellites leave a softer, longer trail) |

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
├── config.rs              clap Config (27 flags) + CLEAR_COLOR, LAYER_WIPE_COLOR
├── types.rs               Color + Point value types + random_star_color
├── buildings.rs           6 BuildingStyles + Building + tile-pattern lookup
├── skyline.rs             Static world: building generation, sky-floor, flasher, periodic-clear timer
├── skyline_renderer.rs    Per-frame sprite emitter (rate-clocked stars/lights/flasher)
├── shooting_stars.rs      Shooting-stars layer: Poisson spawn, 18-segment trail, 15% fade-in
├── satellites.rs          Satellites layer: exponential next-spawn, flasher-constrained band
├── engine.rs              Simulation orchestrator: Skyline + 3 layer renderers (Option-wrapped) + RNG + dt clock
├── gpu.rs                 wgpu Surface/Device/Queue + DecayLayer ping-pong + 6-pass render orchestration
├── sprite.rs              Instanced-quad sprite pipeline w/ BlendMode::{Over, Additive} + grow-on-demand VBO
├── decay.rs               Fullscreen-quad fragment pass: out = textureLoad(src) * keep_factor
├── composite.rs           Stateless N-layer compositor: draw_all(device, pass, &[&TextureView])
├── headless.rs            Offscreen single-frame render to PNG (3-pass direct-to-target, no ping-pong)
├── shader.wgsl            Sprite vertex + fragment (pixel→NDC, round-disc, premultiplied output)
├── decay.wgsl             Fullscreen-tri + textureLoad(src) * keep — per-frame UBO
└── composite.wgsl         Composite vertex (3-vert fullscreen tri) + fragment (textureLoad passthrough)
```

Phase 4 will add procedural moon-texture generation + moon shader (phase + traversal arc).

## License

MIT — same as the parent project. See [`../LICENSE.md`](../LICENSE.md).
