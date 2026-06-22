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
- [x] **Phase 3.5** — workspace split into `starry-core` (lib) + `starry-app` (bin)
- [x] **Phase 4** — procedural moon texture + moon shader (phase + traversal)
- [x] **Phase 5a** — round planets + Keplerian ephemeris (7 of 8 planets — Mercury, Venus, Mars, Jupiter, Uranus, Neptune, Pluto) + procedural textures with mipmaps + planet pipeline (single shader, per-planet UBO)
- [x] **Phase 5a (follow-up)** — subtractive eps in decay shader to escape sRGB-8 quantization fixed point (shooting-star residue fix)
- [x] **Phase 5b** — Saturn body + geometric ring rendering (Schlyter ring-tilt math, 7-zone shader branch in shared `planet.wgsl`, 3 ring styles)
- [x] **Phase 5c** — planet moon-dots (Galilean: Io / Europa / Ganymede / Callisto + Saturn's Titan) → **feature parity with Swift build achieved**
- [x] **Phase 6a** — TOML config loader (defaults < TOML < explicit CLI; `--config <path>`, auto-discovery, `deny_unknown_fields`)
- [x] **Phase 6c** — deterministic seed mode (`--time-mode {realtime|deterministic|frozen}` + `--fixed-dt` + `--time-anchor`; `frame_count`-driven wall clock, MAX_DT clamp skipped in det mode)
- [ ] **Phase 6b** — debug overlay (FPS counter + CPU usage via procedural bitmap font) → v0.1

Platform packaging (`.saver` bundle on macOS, `.scr` on Windows, xscreensaver hack on Linux) and a settings UI are explicitly out of scope until the renderer is at feature parity.

## Build & run

Requires a stable Rust toolchain (install via [rustup](https://rustup.rs)).

```bash
cargo run            # debug build, fast iteration (uses workspace default-member starry-app)
cargo run --release  # release build, full performance
cargo run -p starry-app  # explicit form — equivalent to the above
```

Closing the window exits the process.

### Headless single-frame render (`--dump-png`)

For visual verification from environments without display access (CI servers, sandboxed shells, remote machines), and as the foundation for future Phase 6 golden-image diff tests:

```bash
cargo run -- --dump-png /tmp/starry.png
```

Renders one simulated frame to an 8-bit RGBA PNG at the requested size and exits. The headless path drives the `Engine` at a fixed `dt = 5.0s` against a seeded RNG (default `--seed 42`), so output is byte-stable across runs for a given `(seed, width, height)` — perfect for committing reference images and diffing later.

### Configuration file (TOML)

Any CLI flag can be set in a TOML config file using its kebab-case name. Precedence is **clap defaults < TOML file < explicit CLI flags**, so a CLI flag always wins over the TOML, and the TOML always wins over the built-in defaults.

Minimal example (`./starry.toml`):

```toml
seed = 12345
width = 1920
height = 1080
```

Path discovery:
- `--config <path>` — explicit. If the file is missing, that's a hard error (the flag is a promise).
- `$XDG_CONFIG_HOME/starry/config.toml` — auto-discovered. Missing = silent fallthrough.
- `./starry.toml` (current working directory) — auto-discovered. Missing = silent fallthrough.
- No file found anywhere → built-in defaults.

`#[serde(deny_unknown_fields)]` is enabled, so typos in TOML key names (e.g. `start-fraction` instead of `stars-fraction`) trigger a parse error at load time rather than being silently ignored. The full list of valid keys is exactly the long-form CLI flag names (kebab-case, without the leading `--`).

### CLI flags

`starry-rs` uses `clap` derive for argument parsing. Run `cargo run -- --help` for the full list.

**Core / Phase 2 (skyline):**

| Flag | Default | What |
|---|---:|---|
| `--width <px>` | 1280 | Window / dump width |
| `--height <px>` | 800 | Window / dump height |
| `--dump-png <path>` | — | Headless mode: render one frame to PNG, exit |
| `--config <path>` | — | Explicit TOML config file path (missing file = hard error). Without this flag, auto-discovered at `$XDG_CONFIG_HOME/starry/config.toml` then `./starry.toml` |
| `--seed <u64>` | 42 | RNG seed for skyline geometry + sprite emission |
| `--stars-fraction <0..1>` | 0.5 | Star emission rate as a fraction of the reference max |
| `--lights-fraction <0..1>` | 0.25 | Building-light emission rate fraction |
| `--clear-interval-s <s>` | 120.0 | Seconds between full-canvas wipes |
| `--building-height-pct-max <0..1>` | 0.35 | Tallest building as a fraction of canvas height |
| `--flasher-radius <px>` | 4 | Beacon-light radius on the tallest building |
| `--flasher-period-s <s>` | 2.0 | Beacon on/off period (set to 0 to disable the flasher entirely — no GPU layer allocated, no per-frame emission) |
| `--flasher-decay-half-life-s <s>` | 0.08 | Off-half fade-out half-life: every N seconds the OFF-half intensity halves. 0.08 ≈ snappy LED (90→10% ≈0.25s); ~0.20 ≈ thermal/incandescent (~0.63s). Set to 0 to wipe every frame (square wave) |
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

**Phase 4 (moon):**

| Flag | Default | What |
|---|---:|---|
| `--moon-enabled <bool>` | true | Master enable for the moon layer (Option-skips texture + sampler + pipeline + bind-group + UBO allocation if false) |
| `--moon-diameter-percent <0.001..0.25>` | `80/3000 ≈ 0.02667` | Moon diameter as a fraction of viewport width |
| `--moon-bright-brightness <0.2..1.2>` | 1.0 | Brightness multiplier for the lit hemisphere |
| `--moon-dark-brightness <0.0..0.9>` | 0.15 | Brightness multiplier for the unlit hemisphere (earthshine) |
| `--moon-traversal-seconds <s>` | 3600.0 | Full left→right traversal duration in seconds |
| `--moon-terminator-mode <0..2>` | 1 | 0=hard step, 1=smooth gradient (default — hard mode produces a strong Mach-band illusion when the moon is large in frame), 2=banded |
| `--moon-terminator-width <0.01..0.30>` | 0.06 | Terminator half-width (fraction of disc, modes 1+2) |
| `--moon-terminator-bands <u32>` | 4 | Discrete brightness band count (mode 2 only) |
| `--moon-phase-override-enabled <bool>` | false | Replace live phase calculation with a slider-driven triangular wave |
| `--moon-phase-override-value <0..1>` | 0.0 | Override phase value (`p ≤ 0.5` waxes up to full at 0.5; `p > 0.5` wanes back to new at 1.0) |
| `--debug-moon-colors <bool>` | false | Render the moon as raw albedo only (no lighting, no terminator) |

**Phase 5a (planets):**

| Flag | Default | What |
|---|---:|---|
| `--planets-enabled <bool>` | true | Master enable for the planet layer (Option-skips pipeline + per-planet texture allocation if false) |
| `--mercury-size <0..0.1>` | 0.000_56 | Mercury diameter as a fraction of viewport width |
| `--venus-size <0..0.1>` | 0.001_39 | Venus diameter (fraction of viewport width) |
| `--mars-size <0..0.1>` | 0.000_784 | Mars diameter |
| `--jupiter-size <0..0.1>` | 0.016 | Jupiter diameter (largest non-Sun body) |
| `--saturn-size <0..0.1>` | 0.013_49 | Saturn body diameter (rings render geometrically — see Phase 5b flags below) |
| `--uranus-size <0..0.1>` | 0.005_84 | Uranus diameter |
| `--neptune-size <0..0.1>` | 0.005_66 | Neptune diameter |
| `--pluto-size <0..0.1>` | 0.000_272 | Pluto diameter (the runt of the litter) |
| `--planet-below-horizon-behavior <hide\|random\|random-when-below>` | random-when-below | What to do with planets below the horizon at `wall_now`: `hide` = fully cull, `random` = always randomize across canvas, `random-when-below` = use Keplerian ephemeris when above horizon, randomize when below |
| `--planet-phase-mode <forced-full\|forced-half\|computed>` | forced-full | Phase override: `forced-full` = fully lit (default, retro look), `forced-half` = always half-lit, `computed` = real astronomical phase from observer-Sun-planet geometry |
| `--planet-terminator-mode <0..2>` | 0 | Terminator style: 0 = hard step, 1 = smooth gradient, 2 = banded (same modes as `--moon-terminator-mode`) |

**Phase 5b (Saturn rings):**

| Flag | Default | What |
|---|---:|---|
| `--saturn-ring-style <smooth\|flat-retro\|chunky-pixel>` | flat-retro | Ring rendering style: `smooth` = continuous brightness across zones, `flat-retro` = 4-color luminance quantization with 2×2 Bayer alpha dither (default — pixel-art screensaver aesthetic), `chunky-pixel` = 16-step radial quantization with checker-pattern alpha dither (chunkiest look) |
| `--saturn-ring-tilt-angle <-27..27>` | (automatic) | Manual override for Saturn's ring-plane tilt in degrees (Schlyter B-formula). Omit (or pass nothing) for the automatic real-world tilt computed from `wall_now`. Pass an explicit value to lock the tilt for cinematic effect — note `0.0` is *edge-on* (rings hidden), not "automatic". |
| `--saturn-ring-rotation-angle <0..360>` | (automatic) | Manual override for Saturn's ring-plane rotation in degrees (celestial-pole position angle). Omit for the automatic value computed from Saturn's RA/Dec; pass an explicit value to fix the orientation. |

**Phase 5c (planet moons — Galilean + Titan):**

| Flag | Default | What |
|---|---:|---|
| `--planet-moons-enabled <bool>` | true | Enable automatic point-sprite emission for the 4 Galilean moons (Io / Europa / Ganymede / Callisto orbiting Jupiter) and Saturn's Titan. Disable to skip engine emission AND the GPU sprite pass entirely (saves a `SpriteRenderer` allocation). |
| `--debug-moon-colors <bool>` | false | Debug-visualisation override (shared with the lunar moon's raw-albedo mode from Phase 4). When `true`: per-moon hue distinction at α = 1.0 — Io = red, Europa = green, Ganymede = blue, Callisto = cyan, Titan = yellow — handy for verifying which dot is which. When `false`: white at α = 0.78 (default Swift look). |
| `--jupiter-moon-scale <f64>` | 1.0 | Per-group multiplier on the Galilean moon sprite size before the `[1.0, 3.0]` clamp. Reasonable range `0.5..=4.0`; outside that it's mostly useful for stress tests. No Swift counterpart — Rust-only knob. |
| `--saturn-moon-scale <f64>` | 1.0 | Per-group multiplier on Titan's sprite size before the `[1.0, 3.0]` clamp. Same defaults / range as `--jupiter-moon-scale`. No Swift counterpart — Rust-only knob. |

**Phase 6c (time mode):**

| Flag | Default | What |
|---|---:|---|
| `--time-mode <realtime\|deterministic\|frozen>` | realtime | Clock source for `wall_now` (drives moon phase, planet ephemerides, satellite/shooting decay). `realtime` = `SystemTime::now()`, frame `dt` from actual frame pacing (clamped to `MAX_DT_SECONDS = 0.25` to absorb pacing hitches); `deterministic` = `wall_now = anchor + frame_count × fixed_dt`, frame `dt = fixed_dt` (clamp skipped — caller is trusted); `frozen` = `wall_now = anchor`, frame `dt = 0` (decay layers neither accumulate nor decay; great for cinematic stills). Headless `--dump-png` ignores this flag entirely — it has its own fixed dt + anchor schedule. |
| `--fixed-dt <f64>` | 0.016_666_666 | Simulated seconds per frame in `deterministic` mode (default = 1/60s, matching 60 Hz). Ignored in `realtime` and `frozen`. Negative values defensively clamped to 0 to avoid panicking `Duration::from_secs_f64`. |
| `--time-anchor <u64>` | 1_704_067_200 | Unix epoch seconds anchoring `wall_now` in `deterministic` and `frozen` modes (default = 2024-01-01 UTC, byte-identical to headless `HEADLESS_NOW_UNIX_SECS`). Promoted from `headless.rs` to a `pub const` in `config.rs` so both windowed and headless paths share the literal. Ignored in `realtime`. |

Defaults mirror [`StarryDefaultsManager.swift`](../StarryExcuseForAMacScreensaver/StarryDefaultsManager.swift) so a fresh-install Rust run looks like a fresh-install Swift run.

### Logging

The app uses `env_logger`. Crank verbosity via the `RUST_LOG` environment variable:

```bash
RUST_LOG=info cargo run    # default
RUST_LOG=debug cargo run   # see wgpu's chatter too
RUST_LOG=wgpu_core=warn,starry_rs=debug cargo run  # mix-and-match
```

## Layout

A Cargo workspace with two members:

```
starry-rs/
├── Cargo.toml                workspace root: members, default-members, [workspace.package], [workspace.dependencies]
├── README.md                 this file
├── PORT_PLAN.md              in-tree engineering scratchpad
│
├── starry-core/              library crate — window-agnostic; all simulation + GPU pipeline + WGSL + headless
│   ├── Cargo.toml
│   └── src/
│       ├── lib.rs                20 pub mod declarations (no re-exports)
│       ├── config.rs             clap Config (62 flags incl. `--config <path>` + Phase 6c `--time-mode` / `--fixed-dt` / `--time-anchor`) + CLEAR_COLOR, LAYER_WIPE_COLOR + `HEADLESS_NOW_UNIX_SECS` pub const (shared by windowed Phase 6c det-mode default + headless) + RingStyle enum + Phase 6c TimeMode enum (`Realtime` / `Deterministic` / `Frozen`, serde-derived for TOML)
│       ├── toml_config.rs        Phase 6a TOML loader: PartialConfig (mirrors Config minus `--config`, all Option<T>) + apply_over + cli_partial_from_matches (uses ValueSource::CommandLine) + path discovery (`$XDG_CONFIG_HOME/starry/config.toml`, `./starry.toml`) + load_config_from_env(). `#[serde(deny_unknown_fields, rename_all = "kebab-case")]`. Phase 6c bumped EXPECTED field-count guard 58 → 61 (Config 59 → 62, PartialConfig 58 → 61).
│       ├── types.rs              Color + Point value types + random_star_color + debug_moon_color_premul (per-Galilean/Titan hue for --debug-moon-colors mode)
│       ├── buildings.rs          6 BuildingStyles + Building + tile-pattern lookup
│       ├── skyline.rs            Static world: building generation, sky-floor, flasher, periodic-clear timer
│       ├── skyline_renderer.rs   Per-frame sprite emitter (rate-clocked stars/lights/flasher)
│       ├── shooting_stars.rs     Shooting-stars layer: Poisson spawn, 18-segment trail, 15% fade-in
│       ├── satellites.rs         Satellites layer: exponential next-spawn, flasher-constrained band
│       ├── moon.rs               Phase math (Julian day, synodic month age) + traversal arc + MoonParams GPU-shared struct
│       ├── moon_texture.rs       Procedural 64×64 albedo (7 maria + hash noise) + CPU nearest upsample
│       ├── moon_renderer.rs      Moon GPU pipeline: BGL + 64B UBO + linear sampler + R8Unorm texture + resize-on-demand
│       ├── planet.rs             Keplerian J2000 ephemeris (8 planets), Austin TX observer, alt/az → screen mapping, nonce-driven random fallback, Saturn ring-tilt (Schlyter B) + ring-position-angle math, PlanetParams GPU-shared struct + MoonSpriteState struct + moon_sprite_states() (per-moon Keplerian orbital ephemeris for Galilean moons + Titan)
│       ├── planet_texture.rs     8 procedural albedo generators (Mercury/Venus/Mars/Jupiter/Saturn/Uranus/Neptune/Pluto) → 64×64 base → CPU nearest upsample to per-planet diameter; Saturn = pale-gold banded body-only (rings drawn geometrically in shader)
│       ├── planet_renderer.rs    Planet GPU pipeline: single shader for all 8 planets, per-frame per-planet UBO write, texture cache (HashMap<PlanetIdentity, Texture>), mipmap chain on upload (Swift parity), Saturn-aware quad-aspect 2.0 stretch
│       ├── engine.rs             Simulation orchestrator: Skyline + 3 layer renderers + Option<Moon> + planets HashMap + RNG + dt clock (wall_now: SystemTime injected). Phase 6c: `frame_with_dt(dt, wall_now)` doc now lists 3 callers (headless, Phase 6c det+frozen modes, unit tests) — no API change.
│       ├── gpu.rs                GpuPipelines — window-agnostic wgpu pipelines: DecayLayer ping-pong (3) + Option<MoonRenderer> + Option<PlanetRenderer> + Option<SpriteRenderer> for planet-moons (capacity 5, BlendMode::Over) + 8-pass render orchestration; renders into a caller-supplied &TextureView
│       ├── sprite.rs             Instanced-quad sprite pipeline w/ BlendMode::{Over, Additive} + grow-on-demand VBO
│       ├── decay.rs              Fullscreen-quad fragment pass: out = max(textureLoad(src) * keep_factor − eps, 0) — eps subtracted in linear space to escape sRGB-8 quantization fixed point
│       ├── composite.rs          Stateless N-layer compositor: draw_all(device, pass, &[&TextureView])
│       ├── headless.rs           Offscreen single-frame render to PNG (up to 7 passes direct-to-target, no ping-pong; imports `HEADLESS_NOW_UNIX_SECS` from `crate::config` for byte-stable moon phase + planet ephemerides — Phase 6c promoted the const out of headless.rs so windowed det-mode shares the literal)
│       ├── shader.wgsl           Sprite vertex + fragment (pixel→NDC, round-disc, premultiplied output)
│       ├── decay.wgsl            Fullscreen-tri + max(textureLoad(src) * keep − 1/2048, 0) — per-frame UBO; subtractive eps escapes sRGB-8 quantization residue (~0.000488 linear, imperceptible)
│       ├── moon.wgsl             Moon vertex + fragment (NDC quad, r²>1 discard, soft edge, terminator math, 3 modes, debug-colors override)
│       ├── planet.wgsl           Planet vertex + fragment (NDC quad sized from radiusPx + textureAspect stretch, cos_delta terminator math, 3 modes, soft-edge feather identical to moon shader, nearest-filter sampler for retro pixel-art look). Saturn fragment branch (`is_saturn = aspect > 1.0`) renders pale-gold banded body inside r ≤ 0.846 + geometric rings across r ∈ [0.93, 1.95] with 7-zone band selection (C / B-inner / B-outer / Cassini gap / A-inner / Encke gap / A-outer), edge-on guard `|sin_tilt| ≥ 0.01`, and 3 ring styles (smooth / flat-retro 4-color quant + 2×2 Bayer dither / chunky-pixel 16-step radial quant + checker dither)
│       └── composite.wgsl        Composite vertex (3-vert fullscreen tri) + fragment (textureLoad passthrough)
│
└── starry-app/               binary crate — winit shell; owns the surface + main event loop
    ├── Cargo.toml
    └── src/
        ├── main.rs               entry point + CLI dispatch (windowed vs --dump-png)
        ├── app.rs                winit ApplicationHandler — owns Window + WindowedGpu + Engine + Phase 6c `frame_count: u64` (reset on Resized to keep moon from teleporting after resize). Per-frame `match self.config.time_mode` dispatch: realtime → `Engine::frame(now)` (clamps dt); deterministic → `Engine::frame_with_dt(fixed_dt, anchor + frame_count × fixed_dt)`; frozen → `Engine::frame_with_dt(0.0, anchor)`. `deterministic_wall_now` helper with defensive `.max(0.0)` on negative fixed_dt.
        └── gpu.rs                WindowedGpu — surface + swap-chain wrapper around GpuPipelines
```

The split keeps `starry-core` free of any winit/Surface entanglement so it can be embedded headlessly (CI tests, future tooling, alternate UI shells). `starry-app` is the thin windowed shell — instance creation, adapter pick, surface format selection, event loop, and CLI dispatch.

Phase 4 added the procedural moon: `moon.rs` (phase + traversal), `moon_texture.rs` (procedural albedo + upsample), `moon_renderer.rs` (wgpu pipeline + R8Unorm texture), and `moon.wgsl` (vertex + terminator fragment). Wall-clock time is now an injected parameter (`Engine::frame(wall_now: SystemTime)`) — windowed passes `SystemTime::now()`, headless anchors at `2024-01-01 UTC` for byte-stable determinism.

Phase 5a added 7 of the 8 planets (Mercury, Venus, Mars, Jupiter, Uranus, Neptune, Pluto — Saturn lands in 5b along with the rings): `planet.rs` (Keplerian J2000 ephemeris + alt/az → screen mapping with a hardcoded Austin TX observer, plus a per-engine `nonce: u64` rooted in `Config::seed` for deterministic random fallback positions), `planet_texture.rs` (7 procedural generators ported from `PlanetTexture.swift`), `planet_renderer.rs` (single shader handles all 7 planets via per-frame per-planet UBO writes, mipmap chain on upload for Swift parity, nearest-filter sampler for the intentional retro pixel-art look), and `planet.wgsl` (vertex + non-Saturn fragment branch with the same 3-mode terminator math as the moon). A follow-up commit added a 1-line subtractive-eps fix in `decay.wgsl` to escape the sRGB-8 quantization fixed point that was leaving permanent shooting-star trail residue (`max(s * keep − 1/2048, 0)`; eps ≈ 0.000488 linear; imperceptible at brighter values).

Phase 5b filled in Saturn (now all 8 planets are alive): `planet.rs` gained `saturn_ring_state(now)` (Schlyter B-formula tilt + celestial-pole position-angle rotation), `planet_texture.rs` gained a pale-gold banded body-only generator (no rings baked into the albedo — they're geometric), `planet.wgsl` gained a Saturn fragment branch with a 7-zone radial ring band selector (C / B-inner / B-outer / Cassini gap / A-inner / Encke gap / A-outer), an edge-on guard, and 3 user-pickable ring styles (`smooth` / `flat-retro` / `chunky-pixel`). Three new CLI flags (`--saturn-ring-style`, `--saturn-ring-tilt-angle`, `--saturn-ring-rotation-angle`) — the two angle flags are `Option<f64>` so absent = automatic, present = manual override.

Phase 5c brought the Rust port to **feature parity with the shipping Swift macOS build** by adding automatic point-sprite emission for the four Galilean moons (Io, Europa, Ganymede, Callisto) and Saturn's Titan. `planet.rs` gained a `MoonSpriteState` struct + `moon_sprite_states(parent, wall_now, parent_radius_px, parent_center_px, ring_tilt_deg, ring_rotation_deg, scale)` standalone function: per-moon orbital constants (semi-major axis in parent-radii, sidereal period in days, initial phase) → 2π·days/period angle → ecliptic XY → foreshorten Y by `sin(ring_tilt_deg)` (3° hardcoded for Jupiter; Saturn uses live ring-tilt) → 2D rotate by ring-rotation → scale by parent radius → near/far-side z-cull. `types.rs` gained `debug_moon_color_premul(name)` returning premultiplied-alpha RGBA per moon for `--debug-moon-colors` mode (Io = red, Europa = green, Ganymede = blue, Callisto = cyan, Titan = yellow at α = 1.0). The `Engine::FrameOutput` grew an 8th field (`planet_moons: &[SpriteInstance]`) populated by an inline single-pass emission loop in `frame_impl`. The `gpu.rs::GpuPipelines` gained an `Option<SpriteRenderer>` field for planet-moons (capacity 5, `BlendMode::Over`) — gated on `--planet-moons-enabled` so disabling fully Option-skips pipeline + VBO + viewport-UBO allocation. The new draw call slots into the existing composite pass between `planets.draw_all()` and `moon.draw()` (3 sub-draws inside the same composite pass — encode-pass count stays at 8). The headless plan grew from 6 passes to 7 (planet-moons inserted between Pass 5 planets and the now-renamed Pass 7 moon, gated lazily on `!frame_output.planet_moons.is_empty()`). Three new CLI flags (`--planet-moons-enabled`, `--jupiter-moon-scale`, `--saturn-moon-scale`); the existing `--debug-moon-colors` flag does double duty toggling both lunar-moon raw-albedo and per-planet-moon hue-distinction modes.

## License

MIT — same as the parent project. See [`../LICENSE.md`](../LICENSE.md).
