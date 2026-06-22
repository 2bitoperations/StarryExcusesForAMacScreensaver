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
| 5a — round planets + Keplerian ephemeris | ✅ done | `93b549d` + `4ba3c4b` | 7 of 8 planets (Mercury, Venus, Mars, Jupiter, Uranus, Neptune, Pluto). Single planet pipeline + 7 procedural textures with mipmaps. Per-frame per-planet UBO write + draw inside composite pass after N-layer composite, before the moon. 12 new CLI flags (1 master + 8 sizes + 3 mode selectors). Reuses Phase-4 `wall_now: SystemTime` injection. Bundled with the flasher decay-layer fix (`93b549d`) and a follow-up sRGB-8 quantization-residue fix in `decay.wgsl` (`4ba3c4b`, subtractive eps = 1/2048 linear). |
| 5b — Saturn + geometric rings | ✅ done | `554b1c5` | Saturn body texture (square pale-gold banded, body-only) + Schlyter ring-tilt math (`saturn_ring_state(now)` standalone fn in `planet.rs`) + 7-zone ring shader branch in same `planet.wgsl` fragment (textureAspect=2.0 quad stretch, body radius 0.846, ring inner 0.93 / outer 1.95). 3 CLI flags total (1 ring-style enum + 2 `Option<f64>` angle overrides — absent=automatic, present=manual). User-picked **all defaults** for Phase 5b decisions A–F. Headless SHA `fc7d5fdc...` (default) / `986155e2...` (planets-off, byte-identical to Phase 4 — proves planet-resource gating still works). 32/32 unit tests pass (was 29 pre-5b: +2 ring-state tests + 2 banded-texture tests − 1 dropped flat-gold placeholder). |
| 5c — planet moon-dots (Galilean + Titan) | ✅ done | `4f79715` | Per-frame `BlendMode::Over` sprite draws inside composite pass *between* planets and moon (matches Swift order at `StarryMetalRenderer.swift:1648 → :1668 → :1692`). Per-moon Keplerian orbital ephemeris (semi-major-axis-in-parent-radii + sidereal-period + initial-phase) → ecliptic XY → foreshorten Y by parent ring/spin tilt → 2D-rotate by ring-rotation → scale by parent radius → near/far-side z-cull. 4 user-facing CLI knobs but only **3 new flag declarations** (`--planet-moons-enabled` + `--jupiter-moon-scale` + `--saturn-moon-scale`) because the existing `--debug-moon-colors` flag does double duty. `Option<SpriteRenderer>` (capacity 5, `BlendMode::Over`) so disabling fully Option-skips GPU resources. Single bundled commit `4f79715`. **Brings Rust port to feature parity with shipping Swift macOS build.** |
| 6a — TOML configuration loader | ✅ done | `1935865` | Hand-rolled `PartialConfig` boilerplate (Path A; chosen over the `config` crate dep for transparency + zero new deps beyond `serde` + `toml`). New `--config <path>` CLI flag; auto-discovery order `$XDG_CONFIG_HOME/starry/config.toml` → `./starry.toml`; explicit-path missing = hard error, auto-path missing = silent fallthrough. Precedence is `clap defaults < TOML < CLI` — CLI vs default disambiguated via `ArgMatches::value_source() == ValueSource::CommandLine`. Flat schema (mirrors clap struct) with `#[serde(default, deny_unknown_fields)]` so typos surface immediately; 3 enums grew `#[serde(rename_all = "kebab-case")]` derives. New file `starry-core/src/toml_config.rs` (~696L) houses `PartialConfig` (58 fields = Config's 59 minus the `--config` flag itself, which is intentionally not mirrored to avoid the chicken/egg of a TOML file specifying its own path), `apply_over(&self, &mut Config)`, `cli_partial_from_matches()`, path discovery, and 7 unit tests including a `partial_field_count_matches_config` guard that pins `EXPECTED = 58`. User-picked **all defaults** for Phase 6a decisions A–G. SHAs: default headless `1e0f0067…` byte-identical to Phase 5c baseline (zero behavior change without a TOML present); TOML `seed = 999` alone → `03c1e9cc…`; TOML `seed = 999` + CLI `--seed 42` → `1e0f0067…` (CLI override wins, back to baseline). **46/46 unit tests pass** (was 39 pre-6a: +7 toml_config tests). |
| 6c — deterministic seed mode (TimeMode) | ✅ done | _pending_ | Three new CLI flags landed: `--time-mode {realtime|deterministic|frozen}` (default `realtime`), `--fixed-dt <s>` (default `1.0 / 60.0` ≈ 0.01667), `--time-anchor <unix-secs>` (default `HEADLESS_NOW_UNIX_SECS` = 1_704_067_200 = 2024-01-01 UTC). `realtime` keeps the prior `SystemTime::now()` + frame-timing-`dt` behavior unchanged (zero behavior change for default users). `deterministic` advances `wall_now = anchor + frame_count × fixed_dt` and uses `dt = fixed_dt` (no `MAX_DT_SECONDS = 0.25` clamp — user-picked, "trust the schedule"). `frozen` pins `wall_now = anchor` and uses `dt = 0` (decay layers neither accumulate nor decay). Architecturally minimal: `engine.rs` stays a pure simulator (doc-only update); `frame_count: u64` lives in `app.rs` (resets to 0 on `Resized` so the moon doesn't teleport after window resize); free helper `deterministic_wall_now(cfg, frame_count) -> SystemTime` uses `anchor + Duration::from_secs_f64((cfg.fixed_dt * frame_count as f64).max(0.0))` with defensive `max(0.0)` to dodge `Duration::from_secs_f64`'s NaN/negative panic. `HEADLESS_NOW_UNIX_SECS` promoted from a local `headless.rs` const to a `pub` const in `config.rs` so the windowed deterministic-mode default can share it (user-picked over duplicating the literal). Headless `--dump-png` ignores `--time-mode` — it has its own dt/anchor schedule already, untouched. **Golden-image diff via `cargo test` was deferred** out of this sub-phase (the SHA verification we run by hand serves as a heavyweight stand-in; a proper `cargo test`-integrated golden harness can land separately when needed). User-picked **all defaults** for Phase 6c decisions A–D (3-flag shape; promote const; skip clamp; defensive max). SHAs: default headless `1e0f0067…` **byte-identical to Phase 5c + 6a baseline** (proves `realtime` is the default and the new flags don't perturb existing paths). 46/46 unit tests pass (no new tests — det+frozen behavior lives in `app.rs` which is windowed-only and not unit-testable cheaply; SHA-parity covers regression). |
| 6b — debug overlay (FPS / CPU / build commit) | ⏳ | — | Procedural 5×7 bitmap font, R8 atlas, retro pixel aesthetic. Mirrors Swift `DebugLayerRenderer.swift`. |

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

## Phase 5a Active Todos (closed 2026-06-12)

- [x] `planet.rs` — Keplerian J2000 ephemeris (7 planets) + Austin TX observer (hardcoded) + alt/az → screen mapping + `Planet::frame_state(wall_now)` + per-engine `nonce: u64` rooted in `Config::seed` for deterministic random fallback positions + `PlanetParams` GPU-shared struct (3 packed `vec4`, 13 fields)
- [x] `planet_texture.rs` — 7 procedural generators ported from `PlanetTexture.swift` (Mercury / Venus / Mars solid surfaces with atmosphere; Jupiter with 11-color band table + Great Red Spot; Uranus / Neptune ice giants; Pluto). 64×64 base → CPU nearest upsample to per-planet diameter, mirroring Swift's pipeline
- [x] `planet.wgsl` — vertex (6-vert NDC quad sized from `radiusPx` + stretched by `textureAspect`) + fragment (non-Saturn branch only: cos_delta terminator math + 3 modes + soft-edge feather identical to moon shader)
- [x] `planet_renderer.rs` — single wgpu pipeline (label "Planet"), premultiplied-alpha Over blend (same as moon), per-frame per-planet UBO write + 6-vertex quad draw call, `HashMap<PlanetIdentity, wgpu::Texture>` keyed by planet ID, mipmap chain generated on texture upload (Swift parity, user-picked), `nearest` filter sampler (Swift parity, intentional retro pixel-art look)
- [x] `engine.rs` — `planets: HashMap<PlanetIdentity, Planet>`, `ensure_planets(viewport_w)` (called on init/resize/config-change; generates fresh nonce + per-planet `Planet` from per-planet size config), accumulate per-planet `PlanetParams` into `FrameOutput::planets: Vec<PlanetParams>`
- [x] `gpu.rs` — `Option<PlanetRenderer>` slot (skipped if `--planets-enabled false`), draw inside composite pass after N-layer composite, *before* moon (matches Swift `StarryMetalRenderer.swift:1648`)
- [x] `config.rs` — 12 new flags: `--planets-enabled` (master toggle) + 8 per-planet sizes (Mercury 0.000_56 → Pluto 0.000_272, Saturn 0.013_49 for body — rings render in 5b) + `--planet-below-horizon-behavior {hide|random|random-when-below}` (default `random-when-below`) + `--planet-phase-mode {forced-full|forced-half|computed}` (default `forced-full`) + `--planet-terminator-mode 0..2` (default 0)
- [x] `lib.rs` — register `pub mod planet; pub mod planet_renderer; pub mod planet_texture;` (3 new modules; total now 19 pub mods)
- [x] **Mid-phase flasher fix**: dedicated `DecayLayer` for the flasher with `Over` blend (snap-on at ON, exponential fade during OFF, 0.08s LED feel default). `--flasher-period-s 0` remains the master disable. Adds 8th render pass + 4th composite layer. See "Flasher Fix (2026-06-11)" decisions-log entry below
- [x] Validate: `cargo build --workspace` ✅ + `cargo clippy --workspace --all-targets -- -D warnings` ✅ + `cargo test --workspace` 29/29 ✅ + headless byte-stable @ seed=42 ✅ (planets-off SHA `986155e2…fa34`, planets-default SHA `bc6fd368…3e2b`)
- [x] Single Phase-5a commit — `93b549d` (Phase 5a Steps 1-7 + flasher fix bundled)
- [x] **Post-commit eps fix** (`4ba3c4b`, 1-line WGSL): subtractive eps = 1/2048 linear (~0.000488) in `decay.wgsl` line 42 to escape the sRGB-8 quantization fixed point that was leaving permanent shooting-star trail residue. User-confirmed "visually looks great" after windowed eyeball test. Headless SHAs byte-identical pre/post (single-frame headless skips decay machinery entirely)
- [x] Doc closeout: `README.md`, `AGENTS.md`, this file (single bundled doc-closeout commit per user pick)

## Phase 6a Scoping (executed 2026-06-22)

**Sub-phase context**: Phase 6 was scoped as 3 sub-phases with execution order **6a → 6c → 6b**, each as a single bundled commit (same cadence as Phase 5a/5b/5c). 6a (TOML config loader) goes first because it's foundational — every later sub-phase benefits from being TOML-configurable. 6c (deterministic seed mode + `cargo test` golden-image diff) goes next for highest validation value. 6b (debug overlay) goes last as the most isolated, lowest-blocking-power piece.

**Scope (this sub-phase only — Phase 6a, TOML config loader, ~700 LOC):**
- `Cargo.toml` (workspace + `starry-core`) — add `serde = { version = "1", features = ["derive"] }` and `toml = "0.8"` deps
- `toml_config.rs` (NEW) — `PartialConfig` struct mirroring `Config`'s 58 non-`--config` fields, all wrapped in `Option<T>`, derives `Deserialize` with `#[serde(deny_unknown_fields, rename_all = "kebab-case")]`; `apply_over(&self, dst: &mut Config)` walks each field and replaces `dst` when `self.<field>.is_some()`; `cli_partial_from_matches(&ArgMatches) -> PartialConfig` extracts the user-explicit subset using `ArgMatches::value_source(name) == ValueSource::CommandLine`; `load_config_from_env() -> Result<Config>` orchestrates the full precedence chain (defaults → TOML → CLI); path-discovery helpers (`discover_toml_path` → `$XDG_CONFIG_HOME/starry/config.toml` then `./starry.toml`); 7 unit tests
- `config.rs` — add `--config <path>` flag (`pub config: Option<PathBuf>`); make `BelowHorizonBehavior`, `PlanetPhaseMode`, `RingStyle` enums derive `serde::{Serialize, Deserialize}` with `#[serde(rename_all = "kebab-case")]`
- `planet.rs` — `BelowHorizonBehavior` lives here, so the serde derive lands here too
- `lib.rs` — register `pub mod toml_config;` (total now 20 pub mods)
- `starry-app/src/main.rs` — swap `Config::parse()` → `load_config_from_env()?`; update log message to "phase 6a"

**Design decisions** (all user-approved at scoping time, defaults menu):
- Path A: hand-rolled `PartialConfig` (NOT the `config` crate). Trade-off explicitly accepted: every new flag = 4 edits, but precedence wiring is ~20 obvious lines instead of a black box; zero new deps beyond serde + toml (the `config` crate brings ~12 transitive deps and overkill for "load one TOML, walk one struct"). Guarded by `partial_field_count_matches_config` test which hard-codes `EXPECTED = 58` (Config has 59 pub fields = 58 mirrored + 1 `--config`).
- Defaults source = `Config::default()` — the existing `impl Default for Config` already uses `Self::try_parse_from(["starry-rs"])`, so clap stays single source of truth for default values. No duplicated default-literal table.
- Precedence: clap defaults < TOML < explicit CLI. CLI-vs-default disambiguation uses `ArgMatches::value_source(name) == ValueSource::CommandLine` to distinguish "user typed `--seed 42`" from "clap filled in default 42". Default-equals-explicit edge case (user explicitly passes default value) correctly counts as CLI override — desired semantic (explicit intent wins).
- Path discovery asymmetry: explicit `--config <path>` missing = hard error (`std::io::Error::NotFound` propagated); auto-discovered paths missing = silent fallthrough to next candidate, then defaults. An explicit flag is an explicit promise; auto-discovery is a courtesy.
- Flat schema (NOT grouped sections like `[stars] fraction = 0.5`): TOML keys mirror clap arg names 1:1 (e.g. `stars-fraction = 0.5`). Grouped layout would diverge from clap's flat structure and force users to learn two layouts. `#[serde(deny_unknown_fields)]` catches typos at load time (e.g. `start-fraction` triggers parse error rather than silent ignore). `#[serde(rename_all = "kebab-case")]` keeps TOML feeling like CLI.
- `Option<T>` collapsing: 3 fields are already `Option<T>` in `Config` (`dump_png`, `saturn_ring_tilt_angle`, `saturn_ring_rotation_angle`). In `PartialConfig` they stay `Option<T>` (NOT `Option<Option<T>>`) — TOML key absent = no override, TOML key present = override with that value. Trade-off: no way via TOML to say "explicitly override to `None`" for these fields; that's a CLI-only operation. Acceptable: TOML-driven "automatic" angles just means "don't put the key in your TOML".
- `--config` flag itself intentionally NOT in `PartialConfig` — would create chicken/egg if a TOML file could specify its own path. `partial_field_count_matches_config` test comment explains the off-by-one so future flag-adders aren't confused.

**Phase 6a Active Todos (closed 2026-06-22):**

- [x] `Cargo.toml` (workspace + `starry-core`) — add serde + toml deps via `.workspace = true`
- [x] `toml_config.rs` (NEW, 696L) — PartialConfig + apply_over + cli_partial_from_matches + path discovery + 7 tests
- [x] `config.rs` — `pub config: Option<PathBuf>` flag; serde derives on `PlanetPhaseMode` + `RingStyle` (kebab-case rename)
- [x] `planet.rs` — serde derive on `BelowHorizonBehavior` (kebab-case rename)
- [x] `lib.rs` — `pub mod toml_config;` (total 20 pub mods)
- [x] `starry-app/src/main.rs` — `Config::parse()` → `load_config_from_env()?`; log message "phase 6a"
- [x] Validate: `cargo check --workspace` ✅ + `cargo clippy --workspace --all-targets -- -D warnings` ✅ + `cargo test --workspace` 46/46 ✅ + headless byte-stable parity (no-TOML default SHA `1e0f0067…` byte-identical to Phase 5c baseline)
- [x] 3-SHA Phase 6a proof matrix: no-TOML default `1e0f0067…`; TOML `seed=999` alone → `03c1e9cc…`; TOML `seed=999` + CLI `--seed 42` override → `1e0f0067…` back to baseline (skyline sprite counts 591→582→591 prove RNG actually flipped, not just no-op'd)
- [x] Doc closeout: `README.md`, `AGENTS.md`, this file (single bundled commit per user pick)

## Phase 6c Scoping (executed 2026-06-22)

**Sub-phase context**: With Phase 6a TOML config landed, Phase 6c is the second piece of the Phase 6 split (`6a → 6c → 6b`). Goal: make the simulation's wall-clock-time advance deterministically when requested, so external golden-image harnesses (or just `--dump-png` on a windowed build) can produce byte-stable frames at arbitrary simulated wall times without depending on host clock. **Golden-image diff via `cargo test` is explicitly deferred** out of this sub-phase — the SHA-parity verification we run by hand against `--dump-png` covers regression for now, and a dedicated test harness can land independently when needed.

**Scope (this sub-phase only — Phase 6c, deterministic seed mode, ~120 LOC):**
- `config.rs` — promote `HEADLESS_NOW_UNIX_SECS` from a local const in `headless.rs` to a `pub` const here (so both windowed deterministic-mode default and headless can share the literal); add `TimeMode` enum (`Realtime` / `Deterministic` / `Frozen`) deriving `clap::ValueEnum` + `serde::{Serialize, Deserialize}` + `Display` (kebab-case throughout); add 3 new `pub` fields: `time_mode: TimeMode` (default `Realtime`), `fixed_dt: f64` (default `1.0 / 60.0`), `time_anchor: u64` (default `HEADLESS_NOW_UNIX_SECS`)
- `engine.rs` — doc-only extension of `frame_with_dt` to list the 3 call sites (headless / Phase 6c deterministic+frozen / unit tests). NO functional changes — Phase 6c was deliberately scoped so the engine stays a pure simulator and all clock-mode logic lives in `app.rs`
- `app.rs` — `frame_count: u64` field on the App struct (resets to 0 on `Resized` so the moon doesn't teleport after window resize); imports `Duration`, `UNIX_EPOCH`, `TimeMode`; redraw handler dispatches on `match self.config.time_mode` (realtime = old path unchanged; deterministic = `deterministic_wall_now(cfg, frame_count)` + `dt = fixed_dt`; frozen = `anchor` + `dt = 0`); module docstring extended to document the 3 modes; free helper `deterministic_wall_now(cfg, frame_count) -> SystemTime` appended below the impl block using `anchor + Duration::from_secs_f64((cfg.fixed_dt * frame_count as f64).max(0.0))` (defensive `max(0.0)` to dodge `Duration::from_secs_f64`'s NaN/negative panic)
- `headless.rs` — delete local `HEADLESS_NOW_UNIX_SECS = 1_704_067_200` const (was at lines 61-66); add `HEADLESS_NOW_UNIX_SECS` to the existing `crate::config` import; module docstring untouched (still references the const correctly via the new import path)
- `toml_config.rs` — `use crate::config::TimeMode`; append 3 PartialConfig fields (`time_mode: Option<TimeMode>`, `fixed_dt: Option<f64>`, `time_anchor: Option<u64>`); append 3 setters in `apply_over`; append 3 pickers in `cli_partial_from_matches`; bump `EXPECTED = 58 → 61` in `partial_field_count_matches_config`; extend the field-touching tuple in the `apply_over_replaces_only_present` test to exercise the new fields; update assertion message `"phase-6a anchor"` → `"phase-6c anchor"`; rewrite EXPECTED comment block to mention 6c

**Design decisions** (all user-approved at scoping time, defaults menu):
- **(A) 3-flag shape (Option D over the original 2-flag `--deterministic` + `--freeze-time` sketch)**: an enum-driven `--time-mode` is more honest about the three-state nature of clock-mode (realtime ↔ deterministic ↔ frozen are genuinely distinct) than a boolean + sub-toggle. `--fixed-dt` and `--time-anchor` are split out as their own knobs so a user can change one without the other.
- **(B) Promote `HEADLESS_NOW_UNIX_SECS` to `pub` in `config.rs`**: the windowed deterministic-mode default needs to share the same anchor literal that headless uses. Considered duplicating the magic number (clearly silly) and considered exporting via `headless::HEADLESS_NOW_UNIX_SECS` (would force `config.rs` to depend on `headless.rs`, wrong direction). User picked promotion.
- **(C) Skip the `MAX_DT_SECONDS = 0.25` clamp in deterministic mode**: `realtime` still clamps (it's a guardrail against frame-pacing hitches producing 5-second `dt` jumps that would shoot the moon across the sky). `deterministic` trusts the user-provided `--fixed-dt` — if you want a 5-second step, you get a 5-second step. `frozen` clamps trivially (`dt = 0` is below the clamp anyway).
- **(D) Defensive `.max(0.0)` on the deterministic time math**: `Duration::from_secs_f64` panics on NaN or negative input. `fixed_dt * frame_count as f64` is well-defined for u64 frame counts but a malformed TOML or CLI value could feed in a negative `fixed_dt`, and the bounded clap range (which we don't currently enforce for `fixed_dt`) wouldn't catch it on the TOML path. One `.max(0.0)` clamp is cheaper than three guard tests.

**Architecturally-significant non-decisions:**
- Engine stays unchanged (modulo the doc tweak). Originally considered a new `Engine::frame_deterministic(...)` entry point; rejected as redundant — the existing `Engine::frame_with_dt(dt, wall_now)` satisfies both deterministic and frozen modes since the caller already controls both `dt` and `wall_now`. The win: simulation code keeps its current clean shape, all clock-mode policy lives in one place (`app.rs`), and the change is fully reversible without touching simulation tests.
- `frame_count` lives on the App struct, NOT on the Engine. The engine has no notion of "how many frames have I been driven" because it's stateless w.r.t. frame indexing — it just consumes `(dt, wall_now)` per call. Putting the counter on the App keeps the simulator pure and makes the clock-mode logic easy to read.
- Headless `--dump-png` ignores `--time-mode` entirely. Headless is already deterministic (fixed `dt = 5.0s` + fixed anchor); layering `--time-mode` on top would just confuse two orthogonal mechanisms.
- No unit tests added. The det/frozen behavior lives in the windowed `app.rs` path which doesn't have a cheap unit-test seam (it'd need a fake window + event loop harness, which is out of scope). SHA-parity against the default headless covers regression on the realtime-default path.

**Phase 6c Active Todos (closed 2026-06-22):**

- [x] `config.rs` — promote `HEADLESS_NOW_UNIX_SECS` to `pub`; add `TimeMode` enum; add 3 new flag fields (`time_mode`, `fixed_dt`, `time_anchor`); fix `doc_lazy_continuation` clippy lint on `HEADLESS_NOW_UNIX_SECS` docstring (blank `///` separator)
- [x] `engine.rs` — doc-only extension of `frame_with_dt` to list 3 callers; NO functional changes
- [x] `app.rs` — `frame_count: u64` field + extended module docstring + 3 new imports + redraw `match self.config.time_mode` dispatch + Resized handler resets `frame_count = 0` + `deterministic_wall_now` helper appended
- [x] `headless.rs` — delete local `HEADLESS_NOW_UNIX_SECS` const + import from `crate::config` instead
- [x] `toml_config.rs` — `use TimeMode`; 3 new PartialConfig fields + 3 setters + 3 pickers; bump `EXPECTED = 58 → 61`; extend field-touching tuple; update assertion msg `"phase-6a anchor"` → `"phase-6c anchor"`; rewrite EXPECTED comment block
- [x] Validate: `cargo check --workspace` ✅ + `cargo clippy --workspace --all-targets -- -D warnings` ✅ (after one `doc_lazy_continuation` fix) + `cargo test --workspace` 46/46 ✅
- [x] SHA verification: default headless `1e0f0067b1e16febe9668f7d2329886e35bbd95d8b64c15bce01b8355d79be5d` byte-identical to Phase 5c + 6a baseline (proves `realtime` is the default and the new flags don't perturb existing paths)
- [x] Doc closeout: `README.md`, `AGENTS.md`, this file (single bundled commit per user pick)

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

### Phase 5a (2026-06-11 → 2026-06-12)

- **`PlanetIdentity` enum (8 variants, no Earth)**: Mercury / Venus / Mars / Jupiter / Saturn / Uranus / Neptune / Pluto. Saturn is in the enum even though Phase 5a only renders 7 of them — keeping it now means the texture cache key + planet-loop iteration are stable across 5a→5b without a refactor. Earth deliberately excluded (we're standing on it; never visible from our viewpoint).
- **Single `planet.wgsl` for all 7 planets**: per-planet differentiation comes from the UBO (radius, position, terminator mode, etc.) + the per-planet texture, not from pipeline variants. One pipeline = one shader-module compilation, one bind-group layout, N texture binds. Mirrors the Swift `planetPipeline` design (`StarryMetalRenderer.swift`).
- **`PlanetParams` packed into 3 `vec4`s (13 fields total)**: same layout discipline as `MoonParams`. WGSL UBO field order = explicit Rust mirror via `#[repr(C)] Pod+Zeroable`. Verified field-by-field against `MetalTypes.swift::PlanetParams`. Keeps the GPU push minimal (per-planet UBO write is 3 × 16 = 48B, well under any alignment penalty).
- **`HashMap<PlanetIdentity, wgpu::Texture>` over `Vec<Texture>`**: the texture cache is keyed by planet identity, not draw order. Resize regenerates only the affected planet's texture (e.g. if Jupiter changed size); other planets keep their cached texture. `HashMap` lookup is O(1) and the constant overhead vs. `Vec` indexing is irrelevant compared to the per-frame draw cost.
- **Mipmap chain on texture upload (Swift parity)**: planets generate mipmaps at upload time (`generate_mipmaps` helper). Considered skipping (retro pixel-art look + nearest filter argues against), but Swift parity wins — small-planet-at-distance scenarios could look bad without mips, and we'd lose Swift visual-parity validation. User-picked.
- **`nearest` filter sampler for planets vs. `linear` for moon**: intentional Swift parity. The moon uses `linear` because the procedural albedo is dense enough that linear filtering smooths the pixel grid without losing detail; planets use `nearest` to preserve the retro pixel-art look (Jupiter's bands, Mars's surface noise). Two surfaces, two visual languages, both mirrored.
- **Per-engine `nonce: u64` for random fallback positions**: Swift seeds nonce from `arc4random() << 32 | arc4random()`; Rust seeds from the existing `Config::seed`-rooted `StdRng` via `rng.r#gen::<u64>()` for headless byte-stability. Determinism: `(seed, w, h, wall_now)` → identical PNG. Drives random fallback positions for planets in mode `random` (always randomized) or mode `random-when-below` when below the horizon.
- **Rust 2024 reserved keyword gotcha**: `rng.gen()` doesn't compile in Rust 2024 (workspace `resolver = "3"` → Rust 2024 edition); need `rng.r#gen::<u64>()` with the raw-identifier prefix. Documented inline so future-us doesn't trip on the same thing.
- **Composite-pass draw order: planets → planet-moons → moon (verified Swift parity)**: confirmed against `StarryMetalRenderer.swift:1648` (planets) → `:1668` (planet-moons via spriteOverPipeline) → `:1692` (moon). Phase 5a draws planets *before* the moon in the same composite pass; Phase 5c will slot planet-moons between them. Moon stays on top of everything — opposite of my initial assumption (which I corrected before writing the code).
- **`Option<PlanetRenderer>` over runtime-enabled flag**: same pattern as Phase 3's `Option<DecayLayer>` and Phase 4's `Option<MoonRenderer>`. `--planets-enabled false` *fully skips* GPU resource creation (pipeline, BGL, texture cache, sampler) — not just the per-frame draw call. Zero overhead when disabled.

### Decay shader sRGB-8 quantization fix (2026-06-12)

- **Diagnosis**: shooting-star streaks left a permanent faint trail on the canvas. Root cause = sRGB-8 layer textures + `dst = src * keep` decay shader → at low brightness the multiply rounds back to the same encoded value (`round(N × keep) = N`), creating a fixed point that never drains. Solved analytically: `N* ≤ floor(0.5 / (1 − keep))` for the linear regime (N ≤ ~10 sRGB-8). Shoot keep=0.938 → fixed point at sRGB-8 (visible); sat keep=0.891 → sRGB-4 (sub-perceptual); flasher keep=0.866 → sRGB-3 (sub-perceptual).
- **Why Swift didn't show this as obviously**: Swift uses linear `.bgra8Unorm` (NOT sRGB) for layer textures + clears all trail layers on the periodic-skyline-clear cycle (~5 min default), wiping residue. Rust port uses surface-format-derived sRGB textures (sRGB-preferred is the cross-platform default) + only clears skyline on the periodic clear, so the trail layer accumulates indefinitely between window-app sessions.
- **Fix = Option A (subtractive eps in linear-space decay shader, 1-line WGSL)**: `decay.wgsl` line 42 `return max(s * u.keep - vec4f(1.0 / 2048.0), vec4f(0.0));`. eps = 1/2048 ≈ 0.000488 linear, ~2 sRGB bins shift at sRGB-50 (imperceptible at brighter values), but enough to shift the rounding outcome at the low end. 4-frame escape trace verified 8→6→4→2→0 ≈ 67ms at 60fps.
- **Why not Option C (Rgba16Float intermediate buffers)**: HDR-future-proof but costs +199 MB per 4K display (6 ping-pong textures × 8.29M px × 8B/px); no concrete HDR plans; violates AGENTS.md "simplicity is highly valued". eps fix survives a future Rgba16Float migration as a no-op clamp.
- **Why eps doesn't HDR-future-proof but Rgba16Float does**: residue is on the **low end** of brightness (eps patches the floor); HDR is about the **high end** (>1.0 nits, requires float intermediate buffers — Rgba8 fundamentally cannot represent). Different axes; eps fix is the right tool for this specific bug.
- **8-line justifying comment in shader (priority-1 hook)**: explains the quantization gotcha so future-us doesn't simplify the eps away. Per AGENTS.md comment-hook policy: priority-1 (documents non-obvious correctness invariant).
- **Headless SHA byte-identical pre/post**: confirmed (planets-off `986155e2…` and planets-default `bc6fd368…` both stable). Single-frame headless skips the decay layer entirely (no cross-frame state), so the eps fix is a no-op for headless — exactly as expected. Means the SHA contract is preserved through the eps fix without any extra effort.
- **Commit cadence**: standalone follow-up commit `4ba3c4b` (1 file `decay.wgsl`, +10/−1) instead of folded into `93b549d`. Rationale: `93b549d` was already a bundled-cadence commit (Phase 5a Steps 1-7 + flasher fix) that had landed before the residue was caught; clean bisect surface = standalone fix. User-confirmed "visually looks great" before commit.

### Phase 5a doc closeout (2026-06-12)

- **Cadence: single bundled doc-closeout commit (user pick)**: `Rust port: Phase 5a doc closeout (planets + eps fix)` covering README.md + PORT_PLAN.md + AGENTS.md in one commit. Considered three commits (one per file) but rejected — the doc updates are tightly coupled (flag count drift, lib.rs mod count drift, status paragraph rewrite all reference the same Phase 5a state).
- **eps fix folded into Phase 5a narrative (user pick)**: not a standalone phase or bullet — the eps fix is documented as a "follow-up" entry within the Phase 5a section across all three docs. Rationale: the eps fix is causally Phase 5a's responsibility (the planet work didn't cause it, but the windowed eyeball test that landed at end-of-5a is what surfaced it), and folding keeps the phase narrative coherent.
- **AGENTS.md status paragraph: rewrite, not append (user pick)**: replace "Status (Phase 4 — June 2026)" prose with a Phase 5a-aware rewrite that mentions all features (sky + flasher + sat + shoot + moon + planets) and the new 8-pass encode + 5-layer Z-order. Old Phase 4 paragraph carries forward as-is in its historical-recap slot below.

### Phase 5b (2026-06-17)

User-picked **all defaults** ("Approve all defaults, proceed (Recommended)") for the six Phase 5b decision points (A–F):

- **(A-i) Shared `planet.wgsl` pipeline + `is_saturn = aspect > 1.0` discriminator** (Swift parity): one shader module, one BGL, one render pipeline. The fragment branches on `is_saturn` (derived from `uni.params2.w` aka `texture_aspect`); non-Saturn keeps the Phase-5a logic verbatim. Considered a separate `saturn.wgsl` pipeline but rejected — the planet pipeline already pays for the per-planet UBO write, and the branch divergence is uniform across the warp (every fragment in a single planet's quad takes the same path). Mirrors `Shaders.metal:312` (single `planet_fragment` with the same discriminator).
- **(B) Ring rotation default mode = automatic**: position angle computed from Saturn's RA/Dec relative to the celestial pole `(α=40.589°, δ=83.537°)` matching `Planet.swift:612`. Override knob `--saturn-ring-rotation-angle` exists but defaults to absent (= automatic). Considered defaulting to `0.0` for "always horizontal" but rejected — automatic preserves the slowly-precessing-in-real-time look that's a key visual cue.
- **(C-i) Named `RingStyle` enum (Smooth / FlatRetro / ChunkyPixel) default `FlatRetro`**: matches Swift `StarryDefaultsManager.saturnRingStyle = 1`. Considered raw `u8` (cheap but opaque) and a Swift-style stringly-typed `String` (verbose); the named enum gives clap auto-derive `--saturn-ring-style flat-retro` ergonomics + `From<RingStyle> for i32` for the GPU UBO. `Display` impl + 3 doc-comment lines justify the comment-hook fires per priority 1 (public API documentation).
- **(D) `Option<f64>` for tilt/rotation overrides** (None=automatic, Some=manual): collapses Swift's two-flag pairs (`saturnRingTiltMode` + `saturnRingTiltManualAngle`) into one `Option<f64>` per axis. clap parses `--saturn-ring-tilt-angle 12.5` as `Some(12.5)`, absent as `None`. Trade-off: users can't pass the literal value `0.0` to mean "automatic" (it'd be edge-on, rings hidden). Documented in the README flag table — small UX gotcha, but the simplification wins.
- **(E) Refresh headless baseline SHA**: Saturn now appears at `wall_now = 2024-01-01 UTC` (above-horizon at Austin TX), so the default-flags PNG diverges from Phase 5a. New baseline `fc7d5fdcb431da1566a004d5b19cf3f2c4193311043eb89984f856e60f76ebb6`. The `--planets-enabled false` baseline `986155e2c009a4dbf63227d32c4171d80a43cbb05a5a54852148ac52a752fa34` is preserved byte-for-byte against Phase 4, proving planet-resource gating still cleanly Option-skips the new Saturn shader path too.
- **(F-i) Single bundled `Phase 5b: Saturn body + rings` commit**: covers `config.rs` (RingStyle + 3 flags), `planet.rs` (`saturn_ring_state` + `normalise_signed` + 2 tests), `planet_texture.rs` (banded body generator + 2 tests), `planet.wgsl` (Saturn fragment branch + 4 constants), `engine.rs` (Saturn-aware PlanetParams construction), and the three doc updates. Net: +6 source files, ~+250 LOC, 32/32 unit tests. Commit unsigned (repo `commit.gpgsign=false` override).

**Validation snapshot**:
- `cargo build --workspace --release`: ✅ clean
- `cargo clippy --workspace --all-targets -- -D warnings`: ✅ clean
- `cargo test --workspace`: ✅ 32/32 (was 29 pre-5b)
- Headless `--dump-png` default: ✅ 8 planets render (was 7); SHA `fc7d5fdc…ebb6`
- Headless `--planets-enabled false`: ✅ SHA `986155e2…fa34` byte-identical to Phase 4 baseline
- Saturn flag matrix smoke-tested: `--saturn-ring-style smooth/flat-retro/chunky-pixel` produce 3 distinct SHAs; `--saturn-ring-tilt-angle 45.0 --saturn-ring-rotation-angle 30.0` produces a 4th distinct SHA. All shader paths exercised; WGSL validator clean.
- Windowed eyeball test: ⏳ pending user

**Open questions**: none. Phase 6 next.

### Phase 5c (2026-06-18)

User picked **"Approve all defaults, proceed (Recommended)"** for the Phase 5c decision points and explicitly said "skip pre-coding verification". Six decisions (A–F):

- **(A) Single bundled commit, skip pre-coding verification**: per user pick. Same one-commit-per-phase pattern as 5a/5b; spans `planet.rs` (+~207L production + 5 moon-state tests, now 1319L), `config.rs` (+3 flags, now 531L), `types.rs` (+1 fn + 2 debug-color tests, now 83L), `engine.rs` (+5 edits, now 461L), `gpu.rs` (+6 additive insertions, now 600L), `headless.rs` (+4 additive insertions, now 397L). `cargo check --workspace` + `cargo clippy --workspace --all-targets -- -D warnings` + `cargo test --workspace` all green at the end (deferred until after all 6 code steps landed, per user "skip pre-coding verification"). Trade-off: a per-step verification cycle would have caught any compile errors earlier; bundled trades that for less context-switching at the cost of one larger blast radius if something breaks. Net: nothing did.
- **(B) 4 user-facing knobs but only 3 NEW flag declarations**: `debug_moon_colors` already exists at `config.rs:372` (added in Phase 4 for lunar-moon raw-albedo debug mode). Reusing the same flag for planet-moon hue-distinction mode matches Swift exact parity (`StarryEngine.swift::debugMoonColorPremul` is the only flag-gated color override there too). Considered adding a separate `--debug-planet-moon-colors` flag for orthogonality, but rejected — the two debug modes are conceptually paired (both = "make moons easier to identify"), and a single toggle keeps the CLI surface tighter. The 3 new flags are `--planet-moons-enabled <bool>` (master enable, default true), `--jupiter-moon-scale <f64>` (default 1.0), `--saturn-moon-scale <f64>` (default 1.0). f64 scale flags don't enforce range via clap (matches the `saturn_ring_tilt_angle` precedent); doc comment notes recommended `0.5..=4.0`; out-of-range accepted but undocumented.
- **(C-i) Inline single-pass emission idiom**: emission loop in `engine.rs::frame_impl` calls `moon_sprite_states(...)` per visible Jupiter/Saturn and pushes into `planet_moons_sprite_buf` in the same pass that applies the `--debug-moon-colors` color override. Cleaner than Swift's two-pass approach (Swift emits first, then walks the buffer in a second pass to swap colors) because Rust has access to the moon `name` at sprite construction time via `MoonSpriteState`. Considered the Swift-style two-pass (closer ground-truth match) but rejected — the inline pass is strictly less code and produces identical output. Validated by SHA byte-stability across both modes.
- **(D) Divergent allocation gating between gpu.rs and headless.rs**: `gpu.rs` gates `Option<SpriteRenderer>` allocation on `app_config.planet_moons_enabled` (long-lived renderer; allocated once at startup, drained per-frame); `headless.rs` gates Pass 6 lazily on `!frame_output.planet_moons.is_empty()` (single-frame run, mirrors the existing `planet_renderer` pattern). Considered unifying both on the config flag, but rejected — headless is single-frame so config-gated allocation buys nothing, and the lazy check survives the case where planet-moons are conceptually enabled but no Galileans/Titan happen to be visible (none for now since both planets are above-horizon at the hardcoded 2024-01-01 anchor, but future ephemeris changes could trigger this). The inconsistency is documented in `AGENTS.md` and `starry-rs/README.md` headless.rs entries.
- **(E) Capacity 5, `BlendMode::Over`**: matches Swift parity (`StarryEngine.swift:1051` caps at 4 Galileans + Titan = 5; `StarryMetalRenderer.swift:1668` uses `MTLBlendOperation.add` with `MTLBlendFactor.one + .oneMinusSourceAlpha` which is over-blend with premultiplied alpha). Validated by the default-frame log showing exactly 5 sprites simultaneously (`planet_moons=5` in the headless log). Capacity overflow would only happen if Saturn ever grows additional moons or another planet enters the moon-emitting set; the grow-on-demand VBO in `SpriteRenderer::set_instances` covers any future overflow. Considered `BlendMode::Additive` (would brighten where moons overlap), but rejected — Over matches Swift exact parity, and the conceptual model is "moon disc occludes parent planet pixels", not "moons add light".
- **(F) Doc closeout: AGENTS.md `PlanetRenderer::resize` inaccuracy fix**: the prior wording "MoonRenderer::resize and PlanetRenderer::resize are delegated" was wrong — `PlanetRenderer` has no `resize` method; it uses per-frame `ensure_planet` for selective texture-cache regeneration. Discovered while writing the Phase 5c gpu.rs entry. Replaced with accurate single-renderer claim ("MoonRenderer::resize is delegated, and PlanetRenderer refreshes its texture cache lazily per-frame via `ensure_planet`, so resize just calls `set_viewport` on the planet-moons sprite renderer"). Noted as a separate Continuous Improvement item — pre-existing inaccuracy that survived 5a + 5b doc closeout because nobody re-grepped for resize claims.

**Validation snapshot**:
- `cargo build --workspace --release`: ✅ clean
- `cargo clippy --workspace --all-targets -- -D warnings`: ✅ clean
- `cargo check --workspace`: ✅ green
- `cargo test --workspace`: ✅ 39/39 (was 32 pre-5c: +5 moon-state tests in `planet.rs`, +2 debug-color tests in `types.rs`)
- Headless `--dump-png` default: ✅ SHA `1e0f0067b1e16febe9668f7d2329886e35bbd95d8b64c15bce01b8355d79be5d` (frame log shows `planet_moons=5` — full max-capacity exercise: 4 Galileans + Titan)
- Headless `--planet-moons-enabled false`: ✅ SHA `fc7d5fdcb431da1566a004d5b19cf3f2c4193311043eb89984f856e60f76ebb6` byte-identical to Phase-5b baseline (proves `Option<SpriteRenderer>` cleanly skips planet-moon GPU resources without altering anything else)
- Headless `--debug-moon-colors true`: ✅ SHA `b2f42ad31f8efa5e7ac46c1d44a24c2fea11a32f87b6246cf771d1c2a4253cc8` (3rd distinct SHA, proves the override path)
- Windowed eyeball test: ⏳ pending user

**Open questions**: none. **Phase 5c brings the Rust port to feature parity with the shipping Swift macOS build.** Phase 6 (TOML config + debug overlay + v0.1 deterministic-seed mode) is next.

### Phase 6 (2026-06-22)

Phase 6 was scoped as a 3-sub-phase split with execution order **6a → 6c → 6b**: TOML config loader first (foundational — every later sub-phase benefits from being TOML-configurable), then deterministic seed mode for `cargo test` golden-image diff (highest validation value), then debug overlay last (most isolated, lowest blocking-power). Same single-bundled-commit-per-sub-phase cadence as Phase 5. User picked all recommended defaults for Phase 6a decisions A–G.

- **(A) Path A — hand-rolled `PartialConfig` over the `config` crate dep**: chosen for transparency (the precedence wiring is ~20 obvious lines, not a black box), zero new deps beyond `serde` + `toml` (the `config` crate brings ~12 transitive deps), and direct control over the override mechanism. Trade-off: every new CLI flag is a 4-edit job (Config field + PartialConfig field + `cli_partial_from_matches` extractor + `apply_over` setter), guarded by the `partial_field_count_matches_config` test which pins `EXPECTED = 58`. Considered the `config` crate (less boilerplate, supports JSON/YAML/TOML/env interleaving for free), but the additional layers obscure precedence resolution and add a dep that's overkill for "load one TOML, walk one struct". Hand-rolled is cheaper to read in 6 months than to write today.
- **(B) Defaults source = `Config::default()`**: the existing `impl Default for Config` already uses `try_parse_from(["starry-rs"])` so clap stays the single source of truth for default values. `load_config_from_matches()` starts from `Config::default()`, applies the TOML partial via `apply_over`, then applies the CLI partial via `apply_over`. No duplicated default-literal table.
- **(C) Precedence: clap defaults < TOML < explicit CLI**: standard layering. CLI-vs-default disambiguation uses `ArgMatches::value_source(name) == ValueSource::CommandLine` to distinguish "user typed `--seed 42`" from "clap filled in the default 42". The default-equals-explicit edge case (user explicitly passes the default value) correctly counts as CLI override — which is the desired semantic (explicit intent wins).
- **(D) Path discovery: explicit error vs. silent fallthrough**: `--config <path>` missing the named file = hard error (`std::io::Error::NotFound` propagated). Auto-discovered paths (`$XDG_CONFIG_HOME/starry/config.toml` then `./starry.toml`) missing = silent fallthrough to the next candidate, then defaults. Asymmetric on purpose: an explicit flag is an explicit promise; auto-discovery is a courtesy.
- **(E) Flat schema + `deny_unknown_fields`**: TOML keys mirror clap arg names 1:1 (e.g. `stars-fraction = 0.5` not `[stars] fraction = 0.5`). No grouped sections — they would diverge from clap's flat structure and force users to learn two layouts. `#[serde(deny_unknown_fields)]` catches typos at load time (e.g. `start-fraction` triggers a parse error rather than silently being ignored). `#[serde(rename_all = "kebab-case")]` on the struct + 3 enum derives keeps TOML feeling like CLI.
- **(F) `Option<T>` collapsing**: `Config` has 3 already-`Option<T>` fields (`dump_png`, `saturn_ring_tilt_angle`, `saturn_ring_rotation_angle`). In `PartialConfig` they stay `Option<T>` (NOT `Option<Option<T>>`) — TOML key absent = no override, TOML key present = override with that value (which may itself be `None` semantically for the angle fields meaning "switch back to automatic"). The trade-off is no way via TOML to say "explicitly override to `None`" for these fields; that's a CLI-only operation. Acceptable: TOML-driven "automatic" angles just means "don't put the key in your TOML".
- **(G) `--config <path>` flag itself is intentionally NOT in `PartialConfig`**: would create a chicken/egg if a TOML file could specify its own path. The `partial_field_count_matches_config` test hard-codes `EXPECTED = 58` (Config has 59 pub fields = 58 mirrored + 1 `--config` flag); the comment in the test explains the off-by-one so future flag-adders aren't confused.

**Validation snapshot**:
- `cargo check --workspace`: ✅ clean
- `cargo clippy --workspace --all-targets -- -D warnings`: ✅ clean
- `cargo test --workspace`: ✅ 46/46 (was 39 pre-6a: +7 toml_config tests)
- Headless `--dump-png` no-TOML default @ seed=42 1280×800 dt=5.0s: ✅ SHA `1e0f0067…` **byte-identical to Phase 5c baseline** — zero behavior change without a TOML present
- Headless with TOML `seed = 999`: ✅ SHA `03c1e9cc…` (proves TOML applies; skyline sprite count 591→582)
- Headless with TOML `seed = 999` + CLI `--seed 42`: ✅ SHA `1e0f0067…` (proves CLI override wins, back to baseline)
- Windowed eyeball test: ⏳ pending user (no visual change expected; loader is upstream of the engine)

**Open questions**: none. Phase 6c (deterministic seed mode via TimeMode enum) followed in the same session.

### Phase 6c (2026-06-22)

Phase 6c is the second of three Phase 6 sub-phases (after 6a TOML config, before 6b debug overlay). Goal: a knob to make the simulation's wall-clock-time advance deterministically. User picked all four recommended defaults (3-flag shape, promote const, skip clamp, defensive max).

- **(A) 3-flag shape `--time-mode {realtime|deterministic|frozen}` + `--fixed-dt <s>` + `--time-anchor <unix-secs>` (Option D)**: an enum-driven mode picker over the original sketch of a boolean `--deterministic` flag with sub-toggle `--freeze-time`. Three clock-mode states are genuinely distinct (realtime ↔ deterministic ↔ frozen aren't a 2-bit composition of `is-fixed-dt` × `is-dt-zero` — they each have their own semantics for how `wall_now` advances), and an enum is more honest about that than a boolean + sub-toggle. `--fixed-dt` and `--time-anchor` are split out as their own knobs so a user can change one without the other, and so TOML can pin them independently.
- **(B) Promote `HEADLESS_NOW_UNIX_SECS` from `headless.rs` local const to `config.rs` `pub` const**: the windowed deterministic-mode default needs to share the same anchor literal that headless uses. Considered duplicating the magic number (silly), and considered exporting via `headless::HEADLESS_NOW_UNIX_SECS` (would force `config.rs` to depend on `headless.rs` — wrong layering direction). Promotion is the right factoring; `headless.rs` now imports the const from `crate::config` like everyone else.
- **(C) Skip the `MAX_DT_SECONDS = 0.25` clamp in deterministic mode**: `realtime` keeps the clamp (it's a guardrail against frame-pacing hitches producing 5-second `dt` jumps that would shoot the moon across the sky). `deterministic` trusts the user-provided `--fixed-dt` — if you want a 5-second step, you get a 5-second step. `frozen` (dt = 0) is trivially below the clamp.
- **(D) Defensive `.max(0.0)` on the deterministic time math**: `Duration::from_secs_f64` panics on NaN or negative input. `fixed_dt * frame_count as f64` is well-defined for `u64` frame counts but a malformed TOML or CLI value could feed in a negative `fixed_dt`, and we don't currently enforce a bounded clap range for `fixed_dt`. One `.max(0.0)` is cheaper than three guard tests.

**Architecturally-significant non-decisions:**

- **Engine stays unchanged** (modulo a doc tweak). Originally considered a new `Engine::frame_deterministic(...)` entry point; rejected as redundant — the existing `Engine::frame_with_dt(dt, wall_now)` satisfies both deterministic and frozen modes since the caller already controls both `dt` and `wall_now`. Wins: simulation code keeps its current shape, all clock-mode policy lives in one place (`app.rs`), and the change is fully reversible without touching simulation tests.
- **`frame_count` lives on the App struct, NOT the Engine.** The engine has no notion of "how many frames have I been driven" because it's stateless w.r.t. frame indexing — it just consumes `(dt, wall_now)` per call. Putting the counter on the App keeps the simulator pure and makes clock-mode logic easy to read. Counter resets on `Resized` so the moon doesn't teleport after a window resize.
- **Headless `--dump-png` ignores `--time-mode` entirely.** Headless is already deterministic (fixed `dt = 5.0s` + fixed anchor); layering `--time-mode` on top would just confuse two orthogonal mechanisms.
- **No unit tests added** (the originally-floated 49-test target was abandoned). Det/frozen behavior lives in the windowed `app.rs` path which doesn't have a cheap unit-test seam — testing it properly would need a fake window + event loop harness, which is out of scope. SHA-parity against the default headless covers regression on the realtime-default path; det/frozen visual correctness is human-eyeball-verified in the windowed preview.
- **Golden-image diff via `cargo test` deferred.** Original Phase 6c scope mentioned it; reality is that hand-run SHA verification against `--dump-png` already covers regression. A proper `cargo test`-integrated golden harness can land separately when it becomes a felt need.

Validation:
- `cargo check --workspace` ✅
- `cargo clippy --workspace --all-targets -- -D warnings` ✅ (after one `doc_lazy_continuation` fix on `HEADLESS_NOW_UNIX_SECS` docstring — blank `///` separator added)
- `cargo test --workspace` 46/46 ✅ (same count as Phase 6a — no new tests, per decision above)
- Headless `--dump-png` no-`--time-mode` default @ seed=42 1280×800 dt=5.0s: ✅ SHA `1e0f0067…` **byte-identical to Phase 6a baseline** — proves `realtime` is the default and the new flags don't perturb existing paths
- Windowed `--time-mode deterministic` eyeball test: ⏳ pending user (det-mode visual behavior is unverifiable headlessly by design)

**Open questions**: none. Phase 6b (debug overlay) is next.

## Validation History

| Date | Build | Clippy | Headless `--dump-png` | Notes |
|---|---|---|---|---|
| 2026-06-10 | ✅ clean | ✅ clean (`--all-targets -- -D warnings`) | ✅ 593 sprites @ seed=42 1280×800 dt=5.0s; 149 yellow building lights in Y∈[530, 799]; 37 red flasher pixels; 449 star pixels; bg pure (0,0,0) on 99.94% of canvas. **Determinism verified**: 2 runs → identical SHA256 `c4fac4d71ed46e1d427edacdec947edeba11bf1d58514eb8689b6719592a6237`. | Post-Phase-2 commit `a191364` |
| 2026-06-10 | ✅ clean | ✅ clean | ✅ Phase-3 default (sky+sat+shoot) @ seed=42 1280×800 dt=5.0s → 593 skyline / 1 satellite / 0 shooting; SHA `476e74bc...` byte-stable across 2 runs. Option-wrap matrix: `--satellites-enabled false` → 0 sat sprites (SHA differs); `--shooting-stars-enabled false` → same as default (low spawn rate gives 0 shooting at dt=5s anyway); **both disabled → SHA `c4fac4d7...` matches Phase-2 baseline byte-for-byte**, proving the 6-pass refactor preserved skyline parity exactly. | Phase 3 closeout (commit `c3a5382`) |
| 2026-06-11 | ✅ clean (`cargo build --workspace`) | ✅ clean (`cargo clippy --workspace --all-targets -- -D warnings`) | ✅ Phase-3.5 default @ seed=42 1280×800 dt=5.0s → SHA `476e74bca9286c4ec046a288e2f567eb4a5109f39544a3c4cf20877439e6c044` — **byte-for-byte identical to Phase 3 baseline**, proving the workspace split is a zero-impact refactor at the simulation + GPU pipeline level. Windowed surface path confirmed via human eyeball test. | Phase 3.5 closeout (commit `15d6bfb`) |
| 2026-06-11 | ✅ clean (`cargo build --workspace`) | ✅ clean (`cargo clippy --workspace --all-targets -- -D warnings`) | ✅ Phase-4 default @ seed=42 1280×800 dt=5.0s → SHA `986155e2c009a4dbf63227d32c4171d80a43cbb05a5a54852148ac52a752fa34` (after defaulting `terminator-mode = 1` in both Rust + Swift to dodge the Mach-band illusion the user reported in the windowed preview; pre-default-change SHA was `d029f8f2eb8a530aaa431bc8a3627f839751e7aed5f1e8919e06be49b3544dbe`). Log confirms `moon=true` on the headless tick. New SHA *differs* from Phase 3/3.5 baseline (`476e74bc...`) because the moon disc is now in frame — expected. **10/10 unit tests pass** (`cargo test -p starry-core --lib`): `moon::tests` (5) + `moon_texture::tests` (5). Windowed eyeball validation: hard-mode default reproduced the Mach band (pixels confirmed no real valley); user picked smooth-default fix. Resize fix also landed (`Limits::downlevel_defaults().using_resolution(adapter.limits())` + clamp in `WindowedGpu::resize`). | Phase 4 closeout (commit `7e705b3`) |
| 2026-06-12 | ✅ clean (`cargo build --workspace` 2.51s) | ✅ clean (`cargo clippy --workspace --all-targets -- -D warnings` 1.23s) | ✅ Phase-5a default @ seed=42 1280×800 dt=5.0s → planets-default SHA `bc6fd368…3e2b` (planets in frame); planets-off SHA `986155e2…fa34` (matches Phase-4 baseline byte-for-byte, proving `--planets-enabled false` fully Option-skips planet resources without altering the rest of the pipeline). **29/29 unit tests pass** (`cargo test --workspace`). Eps-fix commit `4ba3c4b` is byte-identical to `93b549d` for both planets-default and planets-off SHAs (single-frame headless skips decay machinery, exactly as expected). Windowed eyeball validation: planet positions broadly correct; shooting-star residue surfaced and fixed via subtractive eps in `decay.wgsl` (user-confirmed "visually looks great" post-fix). | Phase 5a closeout (commits `93b549d` Steps 1-7 + flasher fix, `4ba3c4b` eps fix; doc-closeout commit pending) |
| 2026-06-17 | ✅ clean (`cargo build --workspace --release`) | ✅ clean (`cargo clippy --workspace --all-targets -- -D warnings`) | ✅ Phase-5b default @ seed=42 1280×800 dt=5.0s → SHA `fc7d5fdcb431da1566a004d5b19cf3f2c4193311043eb89984f856e60f76ebb6` (8 planets in frame including Saturn with rings; was 7 in Phase 5a); planets-off SHA `986155e2…fa34` byte-identical to Phase-4 baseline (planet-resource gating still works through the new Saturn shader path). **32/32 unit tests pass** (was 29 pre-5b: +2 ring-state tests in `planet.rs`, +2 banded-texture tests in `planet_texture.rs`, −1 dropped flat-gold placeholder). Saturn ring-style flag matrix smoke-tested: `smooth` / `flat-retro` / `chunky-pixel` → 3 distinct SHAs (`0eb1d5ec…`, `fc7d5fdc…`, `b2b4bed0…`); manual tilt+rotation override (`--saturn-ring-tilt-angle 45.0 --saturn-ring-rotation-angle 30.0`) → 4th distinct SHA (`6e521558…`). All shader paths exercised; WGSL validator clean at pipeline creation. Windowed eyeball test: ⏳ pending user. | Phase 5b closeout (commit `554b1c5`) |
| 2026-06-18 | ✅ clean (`cargo build --workspace --release`) | ✅ clean (`cargo clippy --workspace --all-targets -- -D warnings`) | ✅ Phase-5c default @ seed=42 1280×800 dt=5.0s → SHA `1e0f0067b1e16febe9668f7d2329886e35bbd95d8b64c15bce01b8355d79be5d` (8 planets + 5 planet-moons in frame: 4 Galilean moons of Jupiter [Io, Europa, Ganymede, Callisto] + Titan of Saturn — full max-capacity exercise); `--planet-moons-enabled false` → SHA `fc7d5fdcb431da1566a004d5b19cf3f2c4193311043eb89984f856e60f76ebb6` **byte-identical to Phase-5b baseline** (proves `Option<SpriteRenderer>` cleanly skips planet-moon GPU resources without altering anything else); `--debug-moon-colors true` → SHA `b2f42ad31f8efa5e7ac46c1d44a24c2fea11a32f87b6246cf771d1c2a4253cc8` (3rd distinct SHA, proves the override path). **39/39 unit tests pass** (was 32 pre-5c: +5 moon-state tests in `planet.rs`, +2 debug-color tests in `types.rs`). Brings the Rust port to **feature parity with the shipping Swift macOS build**. Windowed eyeball test: ⏳ pending user. | Phase 5c closeout (commit `4f79715`) |
| 2026-06-22 | ✅ clean (`cargo check --workspace`) | ✅ clean (`cargo clippy --workspace --all-targets -- -D warnings`) | ✅ Phase-6a SHA matrix @ seed=42 1280×800 dt=5.0s: **(1) no TOML, no `--config`** → SHA `1e0f0067b1e16febe9668f7d2329886e35bbd95d8b64c15bce01b8355d79be5d` **byte-identical to Phase 5c baseline** — proves zero behavior change when no config file is loaded. **(2) TOML with `seed = 999`, no CLI override** → SHA `03c1e9ccd13d4b1ec8fc1c00fd2dd09fb34248518dd1fa518233e934b4928752` (skyline sprite count diverged 591→582→591 across the seed switch, confirming the value actually reaches downstream RNG). **(3) Same TOML + `--seed 42` on CLI** → SHA `1e0f0067…` back to baseline, proving the `value_source == CommandLine` precedence wiring overrides the TOML. **46/46 unit tests pass** (was 39 pre-6a: +7 toml_config tests, incl. `partial_field_count_matches_config` field-count guard pinned at `EXPECTED = 58`). | Phase 6a closeout (commit `1935865`) |
| 2026-06-22 | ✅ clean (`cargo check --workspace`) | ✅ clean (`cargo clippy --workspace --all-targets -- -D warnings`, after one `doc_lazy_continuation` fix on `HEADLESS_NOW_UNIX_SECS` docstring) | ✅ Phase-6c default headless @ seed=42 1280×800 dt=5.0s (no `--time-mode` = realtime, but headless ignores it anyway and uses its own dt/anchor schedule) → SHA `1e0f0067b1e16febe9668f7d2329886e35bbd95d8b64c15bce01b8355d79be5d` **byte-identical to Phase 5c + 6a baseline** — proves `realtime` is the default and the 3 new flags (`--time-mode`, `--fixed-dt`, `--time-anchor`) don't perturb existing paths. **46/46 unit tests pass** (same count as 6a; no new tests added since det/frozen behavior lives in windowed `app.rs` and isn't unit-testable cheaply — SHA-parity covers regression). Windowed `--time-mode deterministic` eyeball test: ⏳ pending user (det-mode visual behavior is unverifiable headlessly by design). Field-count guard bumped `EXPECTED = 58 → 61` (Config 59 → 62, PartialConfig 58 → 61). | Phase 6c closeout (commit pending) |

## Open Questions / Parking Lot

- ~~Workspace split (`starry-core` headless + `starry-app` winit) — deferred to Phase 4-5~~ → **done in Phase 3.5** (2026-06-11). See decisions log entries above.
- Determinism testing harness — Phase 6 deliverable, but `--dump-png` already produces byte-stable output. Could add a `cargo test`-driven golden-image diff sooner if useful.
- Should the in-tree `PORT_PLAN.md` pattern be promoted to MASTER.md as a general practice, or kept project-local? (Raised mid-Phase-3 kickoff; no decision yet.)
