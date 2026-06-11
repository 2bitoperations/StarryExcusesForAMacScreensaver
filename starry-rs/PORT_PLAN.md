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
| 3.5 — workspace split (`starry-core` + `starry-app`) | ✅ done | _(pending)_ | Promoted from "deferred to 4-5" — natural seam emerged once GPU lifecycle (window-agnostic) vs. surface management (winit-bound) split became obvious. Zero-impact refactor proven via headless SHA parity with Phase 3 (`476e74bc...` byte-for-byte) |
| 4 — procedural moon | ⏳ | — | Texture gen + phase/traversal shader |
| 5 — planets (parity with Swift) | ⏳ | — | All 8 + Jovian/Saturnian moons |
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

## Validation History

| Date | Build | Clippy | Headless `--dump-png` | Notes |
|---|---|---|---|---|
| 2026-06-10 | ✅ clean | ✅ clean (`--all-targets -- -D warnings`) | ✅ 593 sprites @ seed=42 1280×800 dt=5.0s; 149 yellow building lights in Y∈[530, 799]; 37 red flasher pixels; 449 star pixels; bg pure (0,0,0) on 99.94% of canvas. **Determinism verified**: 2 runs → identical SHA256 `c4fac4d71ed46e1d427edacdec947edeba11bf1d58514eb8689b6719592a6237`. | Post-Phase-2 commit `a191364` |
| 2026-06-10 | ✅ clean | ✅ clean | ✅ Phase-3 default (sky+sat+shoot) @ seed=42 1280×800 dt=5.0s → 593 skyline / 1 satellite / 0 shooting; SHA `476e74bc...` byte-stable across 2 runs. Option-wrap matrix: `--satellites-enabled false` → 0 sat sprites (SHA differs); `--shooting-stars-enabled false` → same as default (low spawn rate gives 0 shooting at dt=5s anyway); **both disabled → SHA `c4fac4d7...` matches Phase-2 baseline byte-for-byte**, proving the 6-pass refactor preserved skyline parity exactly. | Phase 3 closeout (commit pending) |
| 2026-06-11 | ✅ clean (`cargo build --workspace`) | ✅ clean (`cargo clippy --workspace --all-targets -- -D warnings`) | ✅ Phase-3.5 default @ seed=42 1280×800 dt=5.0s → SHA `476e74bca9286c4ec046a288e2f567eb4a5109f39544a3c4cf20877439e6c044` — **byte-for-byte identical to Phase 3 baseline**, proving the workspace split is a zero-impact refactor at the simulation + GPU pipeline level. Windowed surface path (the only code not exercised by headless) pending human eyeball. | Phase 3.5 closeout (commit pending) |

## Open Questions / Parking Lot

- ~~Workspace split (`starry-core` headless + `starry-app` winit) — deferred to Phase 4-5~~ → **done in Phase 3.5** (2026-06-11). See decisions log entries above.
- Determinism testing harness — Phase 6 deliverable, but `--dump-png` already produces byte-stable output. Could add a `cargo test`-driven golden-image diff sooner if useful.
- Should the in-tree `PORT_PLAN.md` pattern be promoted to MASTER.md as a general practice, or kept project-local? (Raised mid-Phase-3 kickoff; no decision yet.)
