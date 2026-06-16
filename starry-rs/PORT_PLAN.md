# starry-rs Port Plan

Living working doc for the Rust + wgpu port. Edit as we go, commit alongside
the work it tracks. Public-facing roadmap lives in [`README.md`](README.md);
this file is the engineering-side scratchpad — granular phase scoping,
active todos, validation snapshots, and open questions.

## Phase Status

| Phase | Status | Commit | Notes |
|---|---|---|---|
| 0 — winit + wgpu + clear color | ✅ done | `97f6172` | Foundation |
| 1 — sprite pipeline + `--dump-png` | ✅ done | `c4b8e18` | Headless visual verification |
| 2 — skyline simulation + persistent FBO | ✅ done | `a191364` | Swift-parity clear ops; clap CLI |
| 3 — decay pipeline (shooting stars, satellites) | ✅ done | `c3a5382` | Plan approved 2026-06-10; cadence **B** (single Phase-3 commit); step ordering "composite-before-renderers"; Option-wrapped renderers for enable flags |
| 3.5 — workspace split (`starry-core` + `starry-app`) | ✅ done | `15d6bfb` | Promoted from "deferred to 4-5" — natural seam emerged once GPU lifecycle (window-agnostic) vs. surface management (winit-bound) split became obvious. Zero-impact refactor proven via headless SHA parity with Phase 3 (`476e74bc...` byte-for-byte) |
| 4 — procedural moon | ✅ done | `7e705b3` | Texture gen + phase/terminator shader + `SystemTime` wall-clock injection + windowed-shell resize-crash fix + Mach-band perception fix (default `terminator-mode = 1` smooth in both Rust + Swift). Plan approved 2026-06-11; cadence = single bundled Phase-4 commit (moon + resize fix + Mach-band fix); CPU 64×64 base albedo + nearest upsample-to-diameter + GPU linear sample; Moon owned by `Engine` (not Skyline); `MoonRenderer` draws inside composite pass *after* N-layer composite; headless anchored at `2024-01-01 UTC` for byte-stable determinism. SHA baseline `986155e2...` (differs from Phase 3.5's `476e74bc...` because the moon is now in frame — expected). |
| 5a — round planets + Keplerian ephemeris | ⏳ | — | 7 of 8 planets (Mercury, Venus, Mars, Jupiter, Uranus, Neptune, Pluto). Single planet pipeline + 7 procedural textures with mipmaps. Per-frame per-planet UBO write + draw inside composite pass after N-layer composite. 9 new CLI flags. Reuses Phase-4 `wall_now: SystemTime` injection. |
| 5b — Saturn + geometric rings | ⏳ | — | Saturn body texture (square, no rings baked) + Schlyter ring-tilt math + 7-zone ring shader branch in same `planet.wgsl` fragment (textureAspect=2.0 quad stretch) + 5 Saturn-specific CLI flags. |
| 5c — planet moon-dots (Galilean + Titan) | ⏳ | — | Transient per-frame sprite-Over draws inside composite pass *between* planets and moon (matches Swift order at `StarryMetalRenderer.swift:1648 → :1668 → :1692`). 4th `SpriteRenderer` instance dedicated to planet-moons (separate VBO from skyline). |
| 6 — TOML config + debug overlay + v0.1 | ⏳ | — | Determinism mode for golden-image tests |

## Active Todos

- [x] `Skyline::building_max_height` pub field — needed by ShootingStars `safeMinY`
- [x] `sprite.rs`: `BlendMode::{Over, Additive}` enum + parameterize `SpriteRenderer::new`
- [x] `decay.wgsl` + `decay.rs`: fullscreen-quad fragment pass with per-frame `keep_factor` uniform
- [x] `composite.rs`: stateless `draw_all(device, pass, &[&TextureView])` in Z-order (skyline → satellites → shooting)
- [x] `shooting_stars.rs`: port `ShootingStarsLayerRenderer` end-to-end (Poisson spawn, 18-segment trail, 15% fade-in) — direct half-life formula `keep = 0.5^(dt/halfLife)` matching Swift's API (`StarryDefaultsManager.shootingStarsTrailHalfLife*`)
- [x] `satellites.rs`: port `SatellitesLayerRenderer` end-to-end (exponential next-spawn, flasher-constrained band) — same half-life formula
- [x] `engine.rs`: `LayerFrame<'a>` per-layer streams + `Option<LayerFrame<'a>>` for `--*-enabled` flags; `frame_impl(dt)` helper shared by `frame()` (with clamp) and `frame_with_dt()` (no clamp)
- [x] `config.rs`: Phase-3 CLI flags mirroring Swift defaults (15 new flags: 8 shooting-stars + 7 satellites; bools use `clap::ArgAction::Set` for `--flag false` disable)
- [x] `gpu.rs`: `DecayLayer { tex_a, view_a, tex_b, view_b, active_is_a, sprites, decay }` ping-pong abstraction + Option-wrapped layer allocation + 6-pass orchestration (sat-decay → shoot-decay → skyline sprites → sat sprites → shoot sprites → composite)
- [x] `headless.rs`: 3-pass direct-to-target render (skyline-Over+Clear → satellites-Additive+Load → shooting-Additive+Load); ping-pong machinery skipped since single-frame at dt=5s collapses decay to ~0
- [x] `main.rs`: register `mod decay; mod shooting_stars; mod satellites;` (done as part of steps 5/7/8)
- [x] Validate: `cargo build` ✅ + `cargo clippy --all-targets -- -D warnings` ✅ + headless byte-stable @ seed=42 ✅ + Option-wrap flag tests ✅ + Phase-2 SHA parity confirmed
- [x] Doc closeout: `README.md`, `AGENTS.md`, this file
- [x] Single Phase-3 commit — `c3a5382`
- [x] Post-commit: patch Phase 3 commit hash into the phase status table above
- [ ] Future: windowed smoke test (multi-frame decay ping-pong is the one path headless can't exercise)

## Phase 4 Active Todos (closed 2026-06-11)

- [x] `moon.rs` — port `Moon.swift` (Julian-day phase math, synodic-month age, traversal arc position) + `radius_from_percent` helper + public `radius()` getter
- [x] `moon_texture.rs` — port `MoonTexture.swift` (64×64 base albedo: 7 hardcoded maria w/ Gaussian σ=r·0.5 + per-pixel hash noise → `[25, 240]` u8 range) + CPU nearest-neighbour upsample to target diameter
- [x] `moon_renderer.rs` (new) — wgpu pipeline + bind-group-layout + 64B `MoonUniformsGpu` UBO + linear-filter sampler + R8Unorm texture + `current_diameter` tracking so resize regenerates the texture on demand
- [x] `moon.wgsl` (new) — 6-vertex NDC quad + fragment: `r²>1` discard, soft edge `featherLocal = clamp(2/radius, 0.0015, 0.12)`, terminator math `cos_delta = 1 - 2·illum; delta = acos(...); phi = waxing ? PI-delta : delta-PI`, three terminator modes (hard / smooth / banded), bright/dark hemisphere lerp, debug-colors override
- [x] `engine.rs` — own `Option<Moon>`; thread `wall_now: SystemTime` through `frame(wall_now)` / `frame_with_dt(dt, wall_now)` / `frame_impl(dt, wall_now)`; emit `Option<MoonParams>` in `FrameOutput`
- [x] `gpu.rs` — `Option<MoonRenderer>` field; construct in `GpuPipelines::new` when `cfg.moon_enabled`; resize on canvas change (`MoonRenderer::resize` no-ops if diameter unchanged); draw inside the existing composite pass *after* the N-layer composite blend (premultiplied alpha)
- [x] `headless.rs` — hardcoded `HEADLESS_NOW_UNIX_SECS = 1_704_067_200` (2024-01-01 UTC) anchors the wall clock; eager `MoonRenderer` construction when `cfg.moon_enabled`; new Pass 4 (Load + `m.draw`) after the existing 3 sprite passes
- [x] `app.rs` — pass `SystemTime::now()` into `engine.frame()` at `RedrawRequested`
- [x] `config.rs` — 11 moon CLI flags mirroring `StarryDefaultsManager.swift` defaults (1 enable bool + diameter % + bright/dark brightness + traversal seconds + 3 terminator knobs + 2 phase-override knobs + debug-colors). Total CLI flag count is now 38 (was 27 after Phase 3)
- [x] `lib.rs` — register `pub mod moon; pub mod moon_texture; pub mod moon_renderer;` (16 `pub mod` declarations total, up from 13)
- [x] Bonus fix: `moon_renderer.rs:74` — wgpu 29 split `FilterMode` / `MipmapFilterMode` into separate enums; corrected `mipmap_filter` to use `MipmapFilterMode::Nearest`
- [x] Validate: `cargo build --workspace` ✅ + `cargo clippy --workspace --all-targets -- -D warnings` ✅ + `cargo test -p starry-core --lib` (10/10) ✅ + headless byte-stable @ seed=42 1280×800 (SHA `986155e2c009a4dbf63227d32c4171d80a43cbb05a5a54852148ac52a752fa34` with smooth-mode terminator default) ✅
- [x] Doc closeout: `README.md`, `AGENTS.md`, this file
- [ ] Single Phase-4 commit (pending user approval)
- [ ] Post-commit: patch Phase 4 commit hash into the phase status table above (rides Phase 5 commit, same pattern as Phase 3.5's `15d6bfb` hash-patch)
- [ ] Future: windowed eyeball test — `look_at` multimodal agent permanently broken, requires human at the windowed app

## Phase 4 Scoping (executed 2026-06-11)

Source-of-truth Swift files ported:
- [`Moon.swift`](../StarryExcuseForAMacScreensaver/Moon.swift) — Julian-day phase math, traversal arc geometry, override triangular wave
- [`MoonTexture.swift`](../StarryExcuseForAMacScreensaver/MoonTexture.swift) — procedural 64×64 albedo (maria + hash noise) + upsample
- [`Shaders.metal`](../StarryExcuseForAMacScreensaver/Shaders.metal) lines 152-266 — moon vertex + fragment (terminator + soft edge)
- [`MetalTypes.swift`](../StarryExcuseForAMacScreensaver/MetalTypes.swift) — `MoonParams` GPU-shared struct
- [`StarryDefaultsManager.swift`](../StarryExcuseForAMacScreensaver/StarryDefaultsManager.swift) lines 27-156 — moon defaults + slider ranges
- [`MoonLayerRenderer.swift`](../StarryExcuseForAMacScreensaver/MoonLayerRenderer.swift) — CGContext-based reference path, *not* ported (we go straight to GPU)

Architectural decisions (full rationale in the Decisions Log below):
- **Texture pipeline**: CPU 64×64 base albedo → CPU nearest upsample to `radius·2` → wgpu `R8Unorm` sampled with `linear` filter. Pixel-art look without a giant texture upload.
- **Clock injection**: `wall_now: SystemTime` is a *parameter* to `Engine::frame`, not a static `SystemTime::now()` call inside the engine. Lets the headless path anchor at a fixed instant for byte-stable determinism.
- **Ownership**: `Moon` is owned by `Engine` (mutable on resize), *not* `Skyline` (which is the static world). `MoonRenderer` owns the wgpu resource; `Moon` is pure data.
- **Render slot**: moon draws inside the composite pass *after* the N-layer composite blend (premultiplied alpha). Same pass = no extra encoder overhead; "after" = moon visually sits on top of all layers.
- **Resize policy**: `MoonRenderer::resize(device, queue, viewport_width)` no-ops if the computed diameter is unchanged; otherwise regenerates the upsampled R8Unorm texture and updates the bind group.

Step plan (executed in a single commit):
1. `moon.rs` (phase math + traversal + override) + 5 unit tests
2. `moon_texture.rs` (base gen + upsample) + 5 unit tests
3. `moon.wgsl` (vertex + fragment with terminator modes)
4. `moon_renderer.rs` (pipeline + BGL + UBO + sampler + texture + bind_group + new/resize/draw)
5. `lib.rs` mod registration
6. `config.rs` 11 moon flags
7. `engine.rs` Moon ownership + `wall_now` threading + `FrameOutput.moon`
8. `gpu.rs` `Option<MoonRenderer>` + construct/resize/draw
9. `headless.rs` `HEADLESS_NOW_UNIX_SECS` + Pass 4
10. `app.rs` `SystemTime::now()` at RedrawRequested
11. Validate (build/clippy/tests/headless-SHA)
12. Doc closeout
13. Single Phase-4 commit

## Phase 5 Scoping (planned 2026-06-11)

Planet port from `Planet.swift` (744L) + `PlanetTexture.swift` (386L) + `Shaders.metal:267-566` (planet + Saturn-ring shaders ~300L) + integration glue. Total ~1700 LOC across 8 planets.

Cadence: **3-phase split** (5a / 5b / 5c) — three distinct visual features with independent SHA baselines and bisect surfaces. User picked split over single-bundled-commit and over the {5a, 5b+5c} compromise.

### Phase 5a — Round planets + Keplerian ephemeris (~900 LOC)

7 planets (Mercury, Venus, Mars, Jupiter, Uranus, Neptune, Pluto). No Saturn yet, no moon-dots yet.

**New modules in `starry-core/src/`**:
- `planet.rs` — Keplerian J2000 ephemeris, Austin TX observer (hardcoded), alt/az → screen mapping, `Planet::frame_state(wall_now)`, deterministic per-engine `nonce: u64` from `Config::seed`, `PlanetParams` GPU-shared struct (3 packed `vec4`, mirroring `MoonParams` style; 13 fields total)
- `planet_texture.rs` — 7 generators ported from `PlanetTexture.swift` (Mercury/Venus/Mars solid surfaces with atmosphere; Jupiter with 11-color band table + Great Red Spot blend; Uranus/Neptune ice giants; Pluto). All via `scale_texture(generate_*_albedo_map(64), 64, diameter)` mirroring Swift's pipeline
- `planet_renderer.rs` — single wgpu pipeline (label "Planet"), premultiplied alpha Over blend (same as moon), per-frame per-planet UBO write + 6-vertex quad draw call. Owns `HashMap<String, wgpu::Texture>` keyed by planet ID. Mipmap chain generated on texture upload (Swift parity, user-picked)
- `planet.wgsl` — vertex (6-vert NDC quad sized from `radiusPx` + stretched by `textureAspect`) + fragment (non-Saturn branch only: cos_delta terminator math + 3 modes + soft-edge feather identical to moon shader). Sampler: `filter::nearest` (Swift parity, intentional retro pixel-art look)

**Touched files**:
- `engine.rs` — `planets: HashMap<String, Planet>`, `ensure_planets(viewport_w)` (called on init/resize/config-change; generates fresh nonce + per-planet Planet from per-planet size config), accumulate per-planet `PlanetParams` into `FrameOutput::planets: Vec<PlanetParams>`
- `gpu.rs` — `Option<PlanetRenderer>` slot (skipped if all planets disabled), draw inside composite pass after N-layer composite, *before* moon
- `config.rs` — 9 new flags: 7 per-planet sizes (Mercury 0.00056 .. Pluto 0.000272) + `--planet-below-horizon-behavior {hide|random|random-when-below}` (default `random-when-below`) + `--planet-terminator-mode {forced-full|forced-half|computed}` (default `forced-full`)
- `lib.rs` — register 3 new modules

**Step plan**:
1. `planet.rs` — Keplerian ephemeris + frame state + nonce-driven random fallback + `PlanetParams` struct
2. `planet_texture.rs` — 7 generators (no Saturn body yet)
3. `planet.wgsl` — vertex + fragment (non-Saturn branch only)
4. `planet_renderer.rs` — pipeline + BGL + per-planet texture cache + per-frame UBO write + mipmap-on-upload
5. `lib.rs` mod registration
6. `config.rs` — 9 planet flags
7. `engine.rs` — `planets` field + `ensure_planets` + frame integration
8. `gpu.rs` — `Option<PlanetRenderer>` + construct/resize/draw inside composite pass
9. Validate (build/clippy/tests/headless-SHA)
10. Doc closeout (README CLI table + AGENTS.md File Contents + Status checklist)
11. Single Phase-5a commit

### Phase 5b — Saturn + geometric rings (~500 LOC)

Saturn body texture (square, no rings baked) + geometric ring rendering in same shader.

**Touched files**:
- `planet.rs` — Schlyter ring-tilt math (`Nr = 169.51 + 3.82e-5·d`, `B = arcsin(sin(β)·cos(28.06°) − cos(β)·sin(28.06°)·sin(λ − Nr))`), ring-rotation position-angle from Saturn RA/Dec + pole `(α=40.589°, δ=83.537°)`, extend `frame_state` to populate `ringTiltDeg` / `ringRotationDeg`
- `planet_texture.rs` — `create_saturn_texture(diameter)` (square body-only, no rings baked)
- `planet.wgsl` — add Saturn branch in fragment: body radius=0.846 (rings take up the other half of the quad), ring inner=1.1·body, ring outer=2.3·body, 7 ring zones (C / B inner / B outer / Cassini gap / A inner / Encke gap / A outer), edge-on guard `|sinTilt| < 0.01`, three ring-style branches (0=Smooth, 1=Flat Retro, 2=Chunky Pixel)
- `planet_renderer.rs` — wire `textureAspect=2.0` for Saturn (vertex quad stretched horizontally to fit rings)
- `config.rs` — 5 new flags: `--saturn-ring-tilt-mode {automatic|manual}`, `--saturn-ring-tilt-manual-angle -27..27`, `--saturn-ring-rotation-mode {automatic|manual}`, `--saturn-ring-rotation-manual-angle 0..360`, `--saturn-ring-style {0|1|2}` (default 1)
- `engine.rs` — apply Saturn-specific overrides (manual ring-tilt/rotation if config says so)

### Phase 5c — Planet moon-dots (Galilean + Titan, ~200 LOC)

Transient point-sprites for Jupiter's Galilean moons (Io, Europa, Ganymede, Callisto) and Saturn's Titan.

**Touched files**:
- `planet.rs` — `MoonOrbit { name, period_days, initial_phase, color, base_size }` helper struct, hardcoded orbital tables for Jupiter (4 moons) + Saturn (Titan), `Planet::moon_sprite_states(wall_now, body_screen_pos, body_radius_px) → Vec<SpriteInstance>` (lightweight circular-orbit math — `angle = 2π · ((wall_now - t0) / period_days) + initial_phase`, screen offset = `(cos(angle)·orbit_px, sin(angle)·orbit_px)`, alpha `0.78` premultiplied)
- `engine.rs` — collect into `FrameOutput::planet_moons: Vec<SpriteInstance>` (separate from `skyline_sprites` etc.)
- `gpu.rs` — instantiate a **4th `SpriteRenderer` instance** (Over blend, dedicated to planet-moons, separate VBO from skyline). Draw inside composite pass *between* planets and moon, matching Swift's order at `StarryMetalRenderer.swift:1648 → :1668 → :1692`

No new CLI flags.

## Phase 3.5 Scoping (executed 2026-06-11)

Split the single-crate `starry-rs` into a **Cargo workspace** with two members:
- `starry-core` (library): all simulation + GPU pipeline code + WGSL shaders + headless renderer. Window-agnostic. Future home for any non-windowed embedders (CI tests, headless tooling, alternate UI shells).
- `starry-app` (binary): the thin winit-driven shell. Owns `Surface` + `SurfaceConfiguration` + main event loop + CLI dispatch. Depends on `starry-core` via path.

Why now (vs. the "Phase 4-5" timeline in the Phase 3 decisions log): the `GpuState` struct in Phase 3 grew to own *both* the surface and the entire pipeline universe. Splitting it cleanly into `GpuPipelines` (window-agnostic, in `starry-core`) and `WindowedGpu` (Surface + SurfaceConfiguration wrapper, in `starry-app`) became the obvious factoring as soon as the moon work needed to think about render-target abstraction. Doing the split *before* Phase 4 means moon shader code lands in `starry-core` from day one.

Step plan (executed in a single commit):
1. Workspace root `Cargo.toml` (resolver=3, members, `default-members=["starry-app"]` so `cargo run` from workspace root still works, `[workspace.package]`, `[workspace.dependencies]` with all pins)
2. `starry-core/Cargo.toml` (lib; wgpu/log/rand/bytemuck/png/clap/pollster — all `.workspace = true`)
3. `starry-app/Cargo.toml` (bin; starry-core path + wgpu/winit/pollster/log/env_logger/clap)
4. `starry-core/src/lib.rs` (13 `pub mod` declarations, no re-exports — keep the import surface explicit)
5. `git mv` all 18 existing source files (`.rs` + `.wgsl`) into their new crate homes, preserving git history as renames
6. Rewrite `starry-core/src/gpu.rs`: strip Arc/pollster/winit imports; rename `GpuState` → `GpuPipelines`; new constructor `new(device, queue, format, width, height, &Config)`; new `resize(width, height)`; new `render_to_view(target_view, FrameOutput)`; add `device()/queue()/format()` accessors. `DecayLayer` + `run_decay_layer` + `create_layer_target` unchanged.
7. Write new `starry-app/src/gpu.rs`: `WindowedGpu` owns Surface + SurfaceConfiguration + `GpuPipelines`. Handles instance/adapter/device/queue setup + surface format pick. `resize` reconfigures surface then delegates. `render` acquires `SurfaceTexture`, handles all error variants, presents.
8. Rewrite `starry-app/src/main.rs`: `mod app; mod gpu;` + `use starry_core::{config::Config, headless};`
9. Rewrite `starry-app/src/app.rs`: `use starry_core::{config::Config, engine::Engine};` + `use crate::gpu::WindowedGpu;`
10. Validate: `cargo build --workspace` + `cargo clippy --workspace --all-targets -- -D warnings` + headless SHA parity vs. Phase 3 baseline
11. Doc updates: `README.md` (layout block), `AGENTS.md` (file paths + conventions), this file
12. Single commit "Phase 3.5 — workspace split"

## Phase 3 Scoping (approved 2026-06-10)

Source-of-truth Swift files ported:
- [`ShootingStarsLayerRenderer.swift`](../StarryExcuseForAMacScreensaver/ShootingStarsLayerRenderer.swift)
- [`SatellitesLayerRenderer.swift`](../StarryExcuseForAMacScreensaver/SatellitesLayerRenderer.swift)

Architectural decisions (full rationale in the Decisions Log below):
- **Decay-in-place**: fullscreen-quad fragment pass with per-frame `keep_factor` uniform (Y in `out = textureLoad(src, p) * keep`).
- **Ping-pong textures**: 2 textures per decay layer; swap each frame. wgpu makes the read-write hazard explicit so this is the cleanest answer.
- **Blend modes**: separate `SpriteRenderer` per layer with `BlendMode::{Over, Additive}` enum. Skyline = Over; satellites + shooting = Additive.
- **Per-layer FBOs**: named-fields `LayerTextures { skyline, satellites, satellites_scratch, shooting, shooting_scratch }` (5 total).
- **Composite**: extend `CompositeRenderer` to hold N bind groups; `draw_all()` blends layers in Z-order skyline → satellites → shooting. Moon lands on top in Phase 4.

Step ordering (committed cadence B = single Phase-3 commit):
1. Generalize layer infrastructure (`LayerTextures`, resize logic)
2. Add decay pass + new sprite blend mode
3. Extend `CompositeRenderer` for N layers (composite scaffolding before simulation renderers — easier to wire renderers into existing slots)
4. Port `ShootingStarsLayerRenderer`
5. Port `SatellitesLayerRenderer`
6. Engine wire-up + CLI flags
7. Headless multi-layer render
8. Validate + docs + commit

## Decisions Log

Phase-level commitments live in commit messages and [`AGENTS.md`](../AGENTS.md).
This section captures decisions made between commits.

### Phase 3 (2026-06-10)

- **Layer infrastructure**: `DecayLayer { tex_a, view_a, tex_b, view_b, active_is_a, sprites, decay }` struct owns each layer's full ping-pong state. `GpuState` holds `Option<DecayLayer>` for satellites and shooting — disabled flags fully skip texture allocation, not just the pass. Skyline stays a flat single texture (no decay = no ping-pong needed).
- **Decay strategy**: fullscreen-quad fragment pass with per-frame `keep_factor` uniform. wgpu makes the read-write hazard explicit, so ping-pong is the cleanest answer (vs. a single texture + barrier dance).
- **Decay formula**: `keep = 0.5^(dt/halfLife)` direct, skipping Swift's two-step `trailDecay = 0.5^(1/halfLife)` → `keep = trailDecay^dt` round-trip. Mathematically identical; CLI exposes the user-facing `halfLife` like Swift.
- **Additive blend**: two pipelines via `BlendMode::{Over, Additive}` enum on `SpriteRenderer`. Three renderer instances total (skyline=Over, satellites+shooting=Additive). Pipeline duplication is cheap; per-layer instance VBOs need to be separate anyway.
- **Composite**: stateless `CompositeRenderer::draw_all(device, pass, &[&TextureView])` builds bind groups per call — no caching, no rebind dance on resize. Z-order skyline → satellites → shooting (moon lands on top in Phase 4). Rebuilding every frame is essentially free on the GPU side and saves an entire class of bookkeeping bugs.
- **Coord-convention quirk**: Swift `SatellitesLayerRenderer.swift` carries top-origin CGPoint terminology in its comments while actually consuming bottom-origin data from `Skyline`. Rust port keeps bottom-origin throughout; spawn-band constraint `y_min = max(y_min, flasher_y + r + gap + d/2)` reads cleanly without coordinate flips.
- **Headless multi-layer**: single-frame dump renders all 3 layers directly into the readback target via blend-stacked passes (Clear → skyline-Over → sat-Additive → shoot-Additive). No decay machinery needed since there's no previous frame; byte-stable determinism preserved because render order + blend modes are deterministic.
- **Commit cadence B + step ordering "composite-before-renderers"**: single Phase-3 commit; composite extension lands at step 3 so the orchestration scaffolding is in place when the simulation renderers get wired in. Keeps each step independently reviewable while still being a single atomic commit.
- **Workspace split (`starry-core` / `starry-app`) deferred to Phase 4-5**: no compelling seam emerged in Phase 3 planning. Reassess after the moon (Phase 4) lands — texture generation + traversal arc math might be the natural extraction point.
- **(Step 10 refinement)** `LayerFrame<'a>` lives in `engine.rs` (not in each renderer module). Renderers keep their own per-frame structs; engine converts to a uniform `LayerFrame` shape so `gpu.rs` doesn't need to know which renderer produced what.
- **(Step 10 refinement)** `Engine::frame_impl(dt)` extracted from `frame()` and `frame_with_dt()` — small DRY refactor. `frame()` adds the `MAX_DT_SECONDS = 0.25` clamp before delegating; `frame_with_dt()` skips the clamp (used by headless at dt=5.0s) and just `.max(0.0)`-s the input.
- **(Step 10 refinement)** Per-layer `FrameOutput` fields are `Option<LayerFrame<'a>>` (not `Option<&[SpriteInstance]>`) — keeps `clear_layer` decision with the sprite stream that owns it. Cleaner than splitting them.
- **(Step 11 refinement)** `DecayLayer::active_view()` semantics: after `run_decay_layer()` returns, the "active" view names the freshly-decayed texture, ready for the subsequent additive sprite pass. `swap()` flips the bool at the right moment so `active_is_a` always points at the most-recently-written texture.
- **(Step 11 refinement)** wgpu's zero-init policy on texture creation means first-frame correctness comes for free — no explicit "clear ping-pong textures on startup" code path needed.
- **(Step 11 refinement)** `GpuState::new` takes `&Config` (not `sprite_capacity` like Phase 2) to avoid signature churn for future feature flags. The config tells the constructor which optional layers to allocate.
- **(Step 12 refinement)** Headless intentionally skips ping-pong entirely — at dt=5s the decay layers mathematically collapse to ~0 (`0.5^(5/0.10) ≈ 1.4e-15`), so a single-frame render matches windowed first-frame output. Three separate render passes (load-after-clear) preserve per-layer blend modes without the complexity of intermediate FBOs.
- **(Step 12 recovery)** Edit-tool footgun observed: partial-file `oldString` + large `newString` can leave the original tail intact, producing duplicate code. Recovered via `Write` for whole-file rewrites. Lesson: prefer `Write` over `Edit` when restructuring >50% of a file.

### Phase 3.5 (2026-06-11)

- **Workspace shape**: two members — `starry-core` (lib) and `starry-app` (bin). Workspace root holds `Cargo.toml`, `README.md`, `PORT_PLAN.md`. `default-members = ["starry-app"]` so the existing `cargo run` ergonomic survives the split (no `-p starry-app` needed for the common case).
- **Dependency pinning via `[workspace.dependencies]`**: all versions live in one place at workspace root; member manifests use `.workspace = true`. wgpu pin in particular (29.x) is now load-bearing in a single spot — matches the AGENTS.md "Pinned wgpu version" rule.
- **`GpuPipelines` API (window-agnostic)**: lives in `starry-core/src/gpu.rs`. Owns `device: wgpu::Device`, `queue: wgpu::Queue`, `format: TextureFormat`, all `SpriteRenderer`s, `CompositeRenderer`, optional `DecayLayer`s, skyline target texture. New surface-free constructor: `new(device, queue, format, width, height, &Config)`. Renders into a caller-supplied `&TextureView` via `render_to_view(target_view, FrameOutput)`. Exposes `device()`, `queue()`, `format()` accessors so `WindowedGpu` doesn't need to duplicate them.
- **`WindowedGpu` shell (winit-bound)**: lives in `starry-app/src/gpu.rs`. Owns `Surface`, `SurfaceConfiguration`, and a `GpuPipelines` instance. Creates the wgpu Instance, picks adapter (high-perf preference, surface-compatible), creates Device+Queue, picks surface format (sRGB-preferred), then hands all four into `GpuPipelines::new`. `resize` reconfigures the surface then delegates. `render` acquires `SurfaceTexture`, handles `Lost`/`Outdated`/`Timeout`/`Other` error variants (reconfigure-and-retry, swallow-and-skip respectively), creates the view, calls `pipelines.render_to_view`, presents.
- **Headless unchanged**: `headless::dump_png` stayed in `starry-core` and was *not* refactored to call `GpuPipelines`. Two reasons: (a) preserves byte-stable SHA across the split (critical validation), (b) decouples headless from any future `GpuPipelines` API churn. It builds its own device/queue/textures from scratch — same code, just lives in a different crate now.
- **WGSL `include_str!()` paths**: confirmed file-relative (not crate-root-relative). All `.rs` files that `include_str!` a `.wgsl` were moved together with their shader, so zero shader-path edits needed across the split.
- **`pollster` lives in both manifests**: `starry-core` needs it for headless device acquisition; `starry-app` needs it for windowed device acquisition. Workspace dep makes the pin single-source.
- **No re-exports in `starry-core/lib.rs`**: 13 `pub mod` declarations, no `pub use`. Keeps the import surface explicit at call sites — `use starry_core::config::Config` over `use starry_core::Config` — and avoids the trap of "what does the crate root re-export this week".
- **`default-members` over a top-level `[[bin]]` proxy**: workspace virtual manifest + `default-members = ["starry-app"]` gives `cargo run` from workspace root for free, without needing a fake binary at the root. `cargo run -p starry-app` is the explicit form.
- **Validation strategy**: headless SHA parity with Phase 3 baseline (`476e74bc...`) is the gold-standard test — it proves the entire simulation pipeline + skyline GPU pass + composite are byte-for-byte unchanged across the refactor. The only path that SHA doesn't cover is the windowed Surface/SwapChain acquisition, which still needs a human eyeball.

### Phase 4 (2026-06-11)

- **Texture pipeline (`R8Unorm` + linear filter)**: Swift renders maria into a 64×64 CGContext and lets `MTKView`'s linear sampler do the upsample. We mirror this exactly: 64×64 CPU base albedo → CPU nearest upsample to `radius·2` → upload as `R8Unorm` → GPU samples with `wgpu::FilterMode::Linear`. Single-channel because the moon's only varying surface property is brightness; colour comes from the bright/dark hemisphere lerp in the shader. **`R8Unorm` has no row-alignment requirement** so `bytes_per_row: Some(diameter)` works even when `diameter < 256` — no padding gymnastics needed.
- **Clock injection (`wall_now: SystemTime`)**: the moon's phase angle depends on real-world time. Naïve choice = call `SystemTime::now()` inside `Engine::frame()`. Better choice = make wall-clock a *parameter*: `Engine::frame(wall_now)`. Headless can then anchor at a hardcoded `HEADLESS_NOW_UNIX_SECS = 1_704_067_200` (2024-01-01 UTC) for byte-stable determinism; windowed passes `SystemTime::now()` from the redraw handler. Same pattern as `dt` injection in Phase 3.
- **Moon ownership**: `Engine` owns `Option<Moon>` (mutable so resize can rebuild it), *not* `Skyline` (which is the static-world data and gets snapshotted/cloned for time-skip scenarios). Matches how `engine.rs` already owns the optional layer renderers. `MoonRenderer` owns the wgpu resource separately — `Moon` is pure data, `MoonRenderer` is pure GPU; clean split.
- **Render slot — inside composite pass, after N-layer composite**: the moon draws *during* the composite pass, after `CompositeRenderer::draw_all` has finished blending the N stacked layers. Premultiplied-alpha blend over the freshly-composited image puts the moon visually on top of everything. Same pass = no extra command encoder, no extra render-target swap. Matches Swift's [`METAL_RENDERER_MAP.md`](../METAL_RENDERER_MAP.md) ordering (moon between composite and debug overlay).
- **Resize behaviour**: `MoonRenderer::resize(device, queue, viewport_width)` recomputes the target diameter from the stashed `moon_diameter_percent` and *no-ops if unchanged*. Most window resizes that don't change width enough to round the diameter to a different integer skip the texture regeneration entirely. `GpuPipelines::resize(w, h)` signature stays the same — moon resize is internal.
- **`Option<MoonRenderer>` over runtime-enabled flag**: same pattern as Phase 3's `Option<DecayLayer>` for satellites/shooting. `--moon-enabled false` *fully skips* GPU resource creation (texture, sampler, pipeline, bind group, UBO) — not just the per-frame draw call. Zero overhead when disabled.
- **`MoonParams` lives in `moon.rs`**: keep the GPU-shared struct next to the simulation type that produces it (`MoonParams::from_frame_state` is a method on the params struct itself). Matches `sprite.rs` where `SpriteInstance` lives alongside `SpriteRenderer`. Considered putting it in `types.rs` — but `types.rs` is for value types shared across many modules, and `MoonParams` is moon-specific.
- **`MipmapFilterMode` vs `FilterMode` (wgpu 29)**: pre-existing bug from the Step 6 first draft used `FilterMode::Nearest` for the `mipmap_filter` field — wgpu 29 split these into two separate enums. Caught by `cargo check`; fixed in the same Phase 4 commit. **AGENTS.md "Pinned wgpu version" rule is exactly why this kind of break is rare** — it only bit us because Step 6 was written against a fuzzy memory of the wgpu 28 API.
- **WGSL UBO field order = explicit Rust `MoonUniformsGpu` mirror**: `viewport_size`, `center_px`, `params0 = (radius, illum, bright, dark)`, `params1 = (debug_mask_flag, waxing_sign, _, _)`, `params2 = (terminator_mode, terminator_width, terminator_bands, _)`. `repr(C)` Pod+Zeroable on the Rust side; explicit `vec2<f32>` + `vec4<f32>` on the WGSL side; verified field-by-field against `MetalTypes.swift`'s `MoonParams`. Total UBO size is 64B (matches a single uniform-buffer aligned chunk).
- **Hardcoded epoch constant `NEW_MOON_EPOCH_UNIX_SECS = 947_182_440.0`**: reference new moon `2000-01-06 18:14:00 UTC` per Swift `Moon.swift`. Hardcoded both sides — no environment dependency, no runtime computation. Pairs with `SYNODIC_MONTH_DAYS = 29.530588853` for the age calculation.
- **`rem_euclid` over `%` for negatives**: Swift `Foundation` uses `truncatingRemainder` which matches Rust's `%`, but the phase calculation can produce negative `age - epoch_jd` for pre-epoch wall-clock anchors (theoretical). `rem_euclid` matches what Swift's parity *means* (positive remainder), not what `%` does literally. Belt-and-braces correctness.
- **Edit-tool ergonomics**: parallel edits to the same file with disjoint `oldString`s work safely — the system processes them serially and each subsequent edit sees post-prior-edit state. Used this throughout Phase 4 to batch the 8 `engine.rs` edits + 6 `gpu.rs` edits + 6 `headless.rs` edits per file. Faster than sequential edits, no correctness penalty.
- **Comment-hook acknowledgement**: applied priority-3 justifications for 5 newly-added comment hooks (gpu.rs module doc + moon field docstring + headless.rs module doc + `HEADLESS_NOW_UNIX_SECS` docstring + `MoonRenderer` eager-construction comment + `Pass 4: moon disc` inline comment). Each documents either a public-API contract, an ownership-boundary invariant, render-order rationale, the byte-stable-determinism contract, or matched an existing comment pattern in the immediate vicinity.

### Flasher Fix (2026-06-11)

Mid-Phase-5a bug catch: the flasher beacon on the tallest building wasn't actually flashing in the windowed app. Root cause: `skyline_renderer.rs` only *emitted* a sprite during the ON-half, but the skyline FBO is persistent (`LoadOp::Load` 99% of frames — only cleared on the periodic full-canvas wipe), so the last-emitted red dot stuck around forever during the OFF-half. The render path was indistinguishable from "always on, except for the brief moment just after a periodic clear".

- **Architecture**: dedicated `DecayLayer` for the flasher (4th layer, between skyline and satellites in Z-order), mirroring satellites/shooting but with a different blend mode.
- **Blend mode = `Over` (not `Additive`)**: ON frame `dst = src` (snap to full red), OFF frame `dst *= keep` (pure exponential fade). Additive was rejected — equilibrium `emission/(1-keep) ≈ 17.9×` at 60fps would saturate to display-clamped 1.0 for ~0.8s before any visible fade, ruining the "flashing" feel.
- **Snap-on ON edge**: per-frame sprite emission during the ON-half drives the layer to full brightness in one frame (no fade-in). OFF edge inherits exponential decay from the `keep_factor = 0.5^(dt/half_life)` shader pass.
- **Sprite emission moved**: deleted from `skyline_renderer.rs` (added a regression-prevention note in the module doc), now lives in `engine.rs::frame_impl` between shooting-stars and moon. Still called exactly once per frame; `Skyline::flasher_state()` advances the internal timer.
- **No new `--flasher-enabled` flag**: `--flasher-period-s 0` (pre-existing) remains the disable knob and now fully skips `DecayLayer` allocation. One disable mechanism, no duplicate concerns.
- **Half-life default = 0.08s (final)**: user A/B'd 0.05/0.08/0.10/0.15/0.20 in the windowed app and picked 0.08 as the desired LED feel. Initial commit shipped 0.20 (incandescent-cooldown analog), changed to 0.08 in a follow-up edit before the commit landed. CLI knob `--flasher-decay-half-life-s` exposes it for further tuning.
- **`DecayLayer::new` parameterized** with `blend_mode: BlendMode` + `label: &str`. 8 args now (was 6); annotated `#[allow(clippy::too_many_arguments)]` — internal-only constructor, 3 call sites in `gpu.rs`. Considered a `DecayLayerConfig` struct, rejected per AGENTS.md "simplicity is highly valued" — the constructor is local, the args are all distinct types, and the allow-attribute is one line.
- **GPU encode is now 8-pass** (was 6): added flasher-decay (Pass 3) and flasher-sprite (Pass 7). Composite Z-order list grew to `[skyline, flasher, satellites, shooting]` (4 entries, was 3).
- **Headless is now 6-pass** (was 5): added flasher-sprite (Pass 2, Load+Over) before satellites. Single-frame headless doesn't run the decay layer (no cross-frame state), so `--flasher-decay-half-life-s` is moot for headless SHA — verified by byte-identical pre/post SHAs (`986155e2...` planets-off, `bc6fd368...` planets-default).
- **Validation**: `cargo build --workspace` clean; `cargo clippy --workspace --all-targets -- -D warnings` clean; `cargo test --workspace` 29/29; windowed eyeball test passed (user picked 0.08).

### Phase 5 (2026-06-11)

- **Cadence split (5a / 5b / 5c)**: Phase 5's three sub-features (round planets + Keplerian ephemeris, Saturn + rings, planet moon-dots) are visually distinct, individually validatable, and have a meaningful risk gradient (rings = highest-risk). Splitting buys a clean bisect surface, independent SHA baselines per sub-feature, and lets us course-correct Saturn-ring rendering without backing out 7 round planets. User picked split over single-bundled-commit and over the 2-phase {5a, 5b+5c} compromise.
- **Mipmaps: yes (Swift parity)**: planet albedo textures get a mipmap chain generated on upload, mirroring `StarryMetalRenderer.swift:851-942`. Considered skipping (retro pixel-art look + nearest filter argues against), but Swift parity wins — small-planet-at-distance scenarios could look bad without mips, and we'd lose Swift visual-parity validation. User picked yes.
- **CPU recovery cache: no (skip)**: Swift's `cachedPlanetAlbedoData` exists because Metal's resource-purge model differs from wgpu's. wgpu's `SurfaceError::Lost` is reconfigured-in-place; full adapter loss triggers a full re-init anyway, which would call `ensure_planets()` and regenerate textures fresh from procedural generators. Procedural regeneration is cheap. User picked skip.
- **Texture filter: `nearest`**: Locked-in Swift parity (`Shaders.metal:308`). Intentional retro pixel-art look — *different* from the moon's `linear` filter, which is also intentional Swift parity. The two surfaces have different visual languages and we mirror both.
- **Planet-moons blend: Over (premultiplied alpha)**: Verified at `StarryMetalRenderer.swift:1668` — Swift uses `spriteOverPipeline`, not additive. Alpha `0.78` premultiplied (verified at `Planet.swift:234`). Sprite shape `.circle` (the existing round-disc fragment).
- **Composite-pass draw order: planets → planet-moons → moon**: Verified at `StarryMetalRenderer.swift:1648` (planets) → `:1667` (planet-moons via spriteOverPipeline) → `:1692` (moon). Moon draws LAST (on top of everything), opposite of the assumption I started with. Phase 5c must respect this order so Swift parity is preserved.
- **4th `SpriteRenderer` instance for planet-moons**: Reusing the skyline `SpriteRenderer` would conflict on VBO contents during a single frame (skyline pass owns its VBO for skyline sprites; planet-moons happen later in the same frame). New pipeline + VBO is essentially free; cleanest factoring. Same blend mode as skyline (Over), different lifecycle (transient per-frame, not written to any FBO).
- **Single `planetPipeline` (not one-per-planet)**: Mirrors Swift's `planetPipeline` — one shader handles both non-Saturn and Saturn branches via the `textureAspect` discriminator + per-uniforms ring fields. Per-frame per-planet UBO write + draw call. Saturn-ring style 0/1/2 selected via uniform, not pipeline variant.
- **`wall_now: SystemTime` reuse**: Engine `frame(wall_now)` already takes wall-clock from Phase 4. Planet ephemerides consume the same parameter. Headless anchor at `2024-01-01 UTC` (unix `1_704_067_200`) keeps the byte-stable SHA contract intact. Same pattern as moon — payoff is deterministic headless tests with zero environment dependency.
- **Per-engine `nonce: u64` from `Config::seed`**: Swift seeds nonce from `arc4random() << 32 | arc4random()`; Rust seeds from the existing `Config::seed`-rooted `StdRng` (e.g. `rng.gen::<u64>()`) for headless byte-stability. Determinism: `(seed, w, h, wall_now)` → identical output. The nonce drives random fallback positions for planets that don't have ephemeris positions (mode `random`) or are below the horizon (mode `random-when-below`).
- **Phase Status table: split single Phase 5 row into 5a/5b/5c rows**: Reflects the cadence decision visually in the high-level roadmap, so anyone reading the doc immediately sees the three independent commits coming. Each row carries its own scope + commit-hash slot.

## Validation History

| Date | Build | Clippy | Headless `--dump-png` | Notes |
|---|---|---|---|---|
| 2026-06-10 | ✅ clean | ✅ clean (`--all-targets -- -D warnings`) | ✅ 593 sprites @ seed=42 1280×800 dt=5.0s; 149 yellow building lights in Y∈[530, 799]; 37 red flasher pixels; 449 star pixels; bg pure (0,0,0) on 99.94% of canvas. **Determinism verified**: 2 runs → identical SHA256 `c4fac4d71ed46e1d427edacdec947edeba11bf1d58514eb8689b6719592a6237`. | Post-Phase-2 commit `a191364` |
| 2026-06-10 | ✅ clean | ✅ clean | ✅ Phase-3 default (sky+sat+shoot) @ seed=42 1280×800 dt=5.0s → 593 skyline / 1 satellite / 0 shooting; SHA `476e74bc...` byte-stable across 2 runs. Option-wrap matrix: `--satellites-enabled false` → 0 sat sprites (SHA differs); `--shooting-stars-enabled false` → same as default (low spawn rate gives 0 shooting at dt=5s anyway); **both disabled → SHA `c4fac4d7...` matches Phase-2 baseline byte-for-byte**, proving the 6-pass refactor preserved skyline parity exactly. | Phase 3 closeout (commit `c3a5382`) |
| 2026-06-11 | ✅ clean (`cargo build --workspace`) | ✅ clean (`cargo clippy --workspace --all-targets -- -D warnings`) | ✅ Phase-3.5 default @ seed=42 1280×800 dt=5.0s → SHA `476e74bca9286c4ec046a288e2f567eb4a5109f39544a3c4cf20877439e6c044` — **byte-for-byte identical to Phase 3 baseline**, proving the workspace split is a zero-impact refactor at the simulation + GPU pipeline level. Windowed surface path confirmed via human eyeball test. | Phase 3.5 closeout (commit `15d6bfb`) |
| 2026-06-11 | ✅ clean (`cargo build --workspace`) | ✅ clean (`cargo clippy --workspace --all-targets -- -D warnings`) | ✅ Phase-4 default @ seed=42 1280×800 dt=5.0s → SHA `986155e2c009a4dbf63227d32c4171d80a43cbb05a5a54852148ac52a752fa34` (after defaulting `terminator-mode = 1` in both Rust + Swift to dodge the Mach-band illusion the user reported in the windowed preview; pre-default-change SHA was `d029f8f2eb8a530aaa431bc8a3627f839751e7aed5f1e8919e06be49b3544dbe`). Log confirms `moon=true` on the headless tick. New SHA *differs* from Phase 3/3.5 baseline (`476e74bc...`) because the moon disc is now in frame — expected. **10/10 unit tests pass** (`cargo test -p starry-core --lib`): `moon::tests` (5) + `moon_texture::tests` (5). Windowed eyeball validation: hard-mode default reproduced the Mach band (pixels confirmed no real valley); user picked smooth-default fix. Resize fix also landed (`Limits::downlevel_defaults().using_resolution(adapter.limits())` + clamp in `WindowedGpu::resize`). | Phase 4 closeout (commit `7e705b3`) |

## Open Questions / Parking Lot

- ~~Workspace split (`starry-core` headless + `starry-app` winit) — deferred to Phase 4-5~~ → **done in Phase 3.5** (2026-06-11). See decisions log entries above.
- Determinism testing harness — Phase 6 deliverable, but `--dump-png` already produces byte-stable output. Could add a `cargo test`-driven golden-image diff sooner if useful.
- Should the in-tree `PORT_PLAN.md` pattern be promoted to MASTER.md as a general practice, or kept project-local? (Raised mid-Phase-3 kickoff; no decision yet.)
