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
| 3 — decay pipeline (shooting stars, satellites) | 🟢 next | — | See scoping below |
| 4 — procedural moon | ⏳ | — | Texture gen + phase/traversal shader |
| 5 — planets (parity with Swift) | ⏳ | — | All 8 + Jovian/Saturnian moons |
| 6 — TOML config + debug overlay + v0.1 | ⏳ | — | Determinism mode for golden-image tests |

## Active Todos

_None — Phase 2 shipped; Phase 3 awaits kickoff discussion._

## Phase 3 Scoping (TBD — discuss before starting)

Source-of-truth Swift files to port:
- [`ShootingStarsLayerRenderer.swift`](../StarryExcuseForAMacScreensaver/ShootingStarsLayerRenderer.swift) — randomized trajectories, brightness curves, configurable spawn rates, additive sprites with trails
- [`SatellitesLayerRenderer.swift`](../StarryExcuseForAMacScreensaver/SatellitesLayerRenderer.swift) — point-lights traversing great-circle-ish paths

Architectural questions to resolve:
- **Decay-in-place strategy**: Metal uses a `decayInPlace` compute/fragment pass that fades the layer texture each frame. wgpu equivalent: render a fullscreen quad with `BlendOp::Add` + `src=One, dst=(decay factor)` to the layer? Or compute shader pass? Pick the simpler option.
- **Ping-pong vs single-target**: Swift uses ping-pong (two textures, swap each frame) to avoid read-write hazards. wgpu makes the hazard explicit — likely cleanest to just do the same.
- **Additive vs over compositing**: Shooting stars want additive blend (trails brighten); satellites are dots that move (over blend or additive — check Swift).
- **Per-layer FBOs**: Phase 2 has one persistent layer. Phase 3 needs N (skyline, shooting-stars, satellites). Generalize `GpuState` to hold a `Vec<Layer>` or keep them named?

Suggested smallest-step ordering:
1. Generalize layer infrastructure (1 → N persistent textures, named)
2. Add decay pass (simplest possible — confirm it visually matches Swift's fade rate)
3. Port `ShootingStarsLayerRenderer` end-to-end (simulation + additive sprite emission)
4. Port `SatellitesLayerRenderer` end-to-end
5. Composite all layers in correct Z-order in `CompositeRenderer`

## Decisions Log

Phase-level commitments live in commit messages and [`AGENTS.md`](../AGENTS.md).
This section captures decisions made between commits.

_(empty — fresh slate)_

## Validation History

| Date | Build | Clippy | Headless `--dump-png` | Notes |
|---|---|---|---|---|
| 2026-06-10 | ✅ clean | ✅ clean (`--all-targets -- -D warnings`) | ✅ 593 sprites @ seed=42 1280×800 dt=5.0s; 149 yellow building lights in Y∈[530, 799]; 37 red flasher pixels; 449 star pixels; bg pure (0,0,0) on 99.94% of canvas. **Determinism verified**: 2 runs → identical SHA256 `c4fac4d71ed46e1d427edacdec947edeba11bf1d58514eb8689b6719592a6237`. | Post-Phase-2 commit `a191364` |

## Open Questions / Parking Lot

- Workspace split (`starry-core` headless + `starry-app` winit) — deferred per AGENTS.md until "first natural seam, probably around Phase 3+". Phase 3 might be that seam if the decay layer + multi-FBO machinery wants to live in `core`.
- Determinism testing harness — Phase 6 deliverable, but `--dump-png` already produces byte-stable output. Could add a `cargo test`-driven golden-image diff sooner if useful.
