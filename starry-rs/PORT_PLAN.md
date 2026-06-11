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
| 3 — decay pipeline (shooting stars, satellites) | ✅ done | _(pending)_ | Plan approved 2026-06-10; cadence **B** (single Phase-3 commit); step ordering "composite-before-renderers"; Option-wrapped renderers for enable flags |
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
- [ ] Single Phase-3 commit (gated on explicit user OK)
- [ ] Post-commit: patch Phase 3 commit hash into the phase status table above
- [ ] Future: windowed smoke test (multi-frame decay ping-pong is the one path headless can't exercise)

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

## Validation History

| Date | Build | Clippy | Headless `--dump-png` | Notes |
|---|---|---|---|---|
| 2026-06-10 | ✅ clean | ✅ clean (`--all-targets -- -D warnings`) | ✅ 593 sprites @ seed=42 1280×800 dt=5.0s; 149 yellow building lights in Y∈[530, 799]; 37 red flasher pixels; 449 star pixels; bg pure (0,0,0) on 99.94% of canvas. **Determinism verified**: 2 runs → identical SHA256 `c4fac4d71ed46e1d427edacdec947edeba11bf1d58514eb8689b6719592a6237`. | Post-Phase-2 commit `a191364` |
| 2026-06-10 | ✅ clean | ✅ clean | ✅ Phase-3 default (sky+sat+shoot) @ seed=42 1280×800 dt=5.0s → 593 skyline / 1 satellite / 0 shooting; SHA `476e74bc...` byte-stable across 2 runs. Option-wrap matrix: `--satellites-enabled false` → 0 sat sprites (SHA differs); `--shooting-stars-enabled false` → same as default (low spawn rate gives 0 shooting at dt=5s anyway); **both disabled → SHA `c4fac4d7...` matches Phase-2 baseline byte-for-byte**, proving the 6-pass refactor preserved skyline parity exactly. | Phase 3 closeout (commit pending) |

## Open Questions / Parking Lot

- Workspace split (`starry-core` headless + `starry-app` winit) — deferred to Phase 4-5 (see Decisions Log).
- Determinism testing harness — Phase 6 deliverable, but `--dump-png` already produces byte-stable output. Could add a `cargo test`-driven golden-image diff sooner if useful.
- Should the in-tree `PORT_PLAN.md` pattern be promoted to MASTER.md as a general practice, or kept project-local? (Raised mid-Phase-3 kickoff; no decision yet.)
