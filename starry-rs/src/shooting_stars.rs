//! Shooting-stars layer: spawns short-lived ballistic streaks that fly
//! across the upper sky and emit a tapered 18-segment trail of additive
//! point sprites each frame. Companion to a per-layer decay pass (the
//! sprites are intentionally "dotted" — the decay pass smears them into a
//! continuous fading trail).
//!
//! Rust port of [`ShootingStarsLayerRenderer.swift`](../../StarryExcuseForAMacScreensaver/ShootingStarsLayerRenderer.swift),
//! visual-parity-faithful. The two deliberate departures, both for
//! reasons consistent with the rest of the Rust port:
//!
//! 1. **Determinism.** Uses the engine-seeded `StdRng` (threaded as
//!    `&mut R: Rng`) instead of Swift's `SystemRandomNumberGenerator`.
//!    Same `(seed, dimensions, dt-stream)` → same star spawns.
//! 2. **No debug-spawn-bounds overlay.** That visualization is a
//!    debug-overlay feature; the whole debug-overlay surface lands in a
//!    later phase. Trivial to add back when we get there.

use rand::Rng;

use crate::sprite::SpriteInstance;

/// How shooting stars choose their direction of travel. Raw integer
/// values are wire-compatible with `StarryDefaultsManager`'s persisted
/// `ShootingStarDirectionMode` setting on the Swift side, so a saved user
/// preference round-trips through the CLI without translation.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub enum ShootingStarDirectionMode {
    Random = 0,
    LeftToRight = 1,
    RightToLeft = 2,
    TopLeftToBottomRight = 3,
    TopRightToBottomLeft = 4,
}

impl ShootingStarDirectionMode {
    /// Map a raw `i32` (from CLI / persisted setting) to the enum.
    /// Unknown values silently fall back to `Random`, matching Swift's
    /// `ShootingStarDirectionMode(rawValue:) ?? .random` (line 95).
    pub fn from_int(raw: i32) -> Self {
        match raw {
            1 => Self::LeftToRight,
            2 => Self::RightToLeft,
            3 => Self::TopLeftToBottomRight,
            4 => Self::TopRightToBottomLeft,
            _ => Self::Random,
        }
    }
}

/// One in-flight shooting star. Pure simulation state — sprite emission
/// happens in `append_star_sprites` once per frame, never cached.
#[derive(Copy, Clone, Debug)]
struct ShootingStar {
    head: [f32; 2],
    dir: [f32; 2], // unit vector
    speed: f32,    // px/sec
    length: f32,   // total visible streak length
    thickness: f32,
    brightness: f32,
    lifetime: f64, // seconds (matches dt unit)
    age: f64,
}

impl ShootingStar {
    fn advance(&mut self, dt: f64) {
        self.age += dt;
        let d = self.speed * dt as f32;
        self.head[0] += self.dir[0] * d;
        self.head[1] += self.dir[1] * d;
    }

    fn done(&self) -> bool {
        self.age >= self.lifetime
    }

    fn tail(&self) -> [f32; 2] {
        [
            self.head[0] - self.dir[0] * self.length,
            self.head[1] - self.dir[1] * self.length,
        ]
    }
}

/// Per-frame output. Sprites borrow into an internal buffer reused
/// across calls; `keep_factor` feeds the layer's decay pass this frame
/// (`new = old * keep_factor`, see `decay.rs`).
pub struct ShootingStarsFrame<'a> {
    pub sprites: &'a [SpriteInstance],
    pub keep_factor: f32,
}

/// Per-frame shooting-star simulator + sprite emitter. Owns the live
/// list of in-flight stars; drives them forward each `frame()` call and
/// reuses a scratch sprite buffer across calls.
pub struct ShootingStarsRenderer {
    width: i32,
    height: i32,
    safe_min_y: f32,

    // Config (frozen at construction; mirrors Swift's per-instance state)
    avg_seconds: f64,
    direction_mode: ShootingStarDirectionMode,
    base_length: f32,
    speed: f32,
    thickness: f32,
    brightness: f32,
    trail_half_life_s: f32,

    active: Vec<ShootingStar>,
    sprites: Vec<SpriteInstance>,
}

impl ShootingStarsRenderer {
    /// `building_max_height` is read from `Skyline::building_max_height`
    /// and used to compute `safe_min_y = building_max_height + 4`, which
    /// keeps both star endpoints above the tallest possible rooftop
    /// (Swift line 138).
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        width: i32,
        height: i32,
        building_max_height: i32,
        avg_seconds: f64,
        direction_mode: ShootingStarDirectionMode,
        length: f32,
        speed: f32,
        thickness: f32,
        brightness: f32,
        trail_half_life_s: f32,
    ) -> Self {
        Self {
            width,
            height,
            safe_min_y: (building_max_height + 4) as f32,
            avg_seconds,
            direction_mode,
            base_length: length,
            speed,
            thickness,
            brightness,
            trail_half_life_s,
            active: Vec::new(),
            sprites: Vec::with_capacity(128),
        }
    }

    /// Advance every active star by `dt`, retire any that hit lifetime,
    /// roll the per-frame spawn Bernoulli, emit a fresh 18-segment trail
    /// for each survivor, and return `(sprites, keep_factor)`. Borrows
    /// into an internal buffer — caller must drain before next call.
    pub fn frame<R: Rng + ?Sized>(
        &mut self,
        dt: f64,
        rng: &mut R,
    ) -> ShootingStarsFrame<'_> {
        self.spawn_if_needed(dt, rng);

        for star in self.active.iter_mut() {
            star.advance(dt);
        }
        self.active.retain(|s| !s.done());

        self.sprites.clear();
        for star in &self.active {
            append_star_sprites(star, &mut self.sprites);
        }

        // keep_factor = 0.5^(dt/halfLife), clamped to [0, 1]. Direct
        // half-life formulation (not Swift's two-step `keep^dt` round-trip
        // of a per-second decay constant) — same exponential family, just
        // parameterized by the more intuitive "seconds to half brightness".
        // Half-life <= 0 collapses to keep_factor = 0 so the decay pass
        // wipes the layer to transparent every frame, matching Swift's
        // disabled-trail behavior (line 188-194).
        let keep_factor = if self.trail_half_life_s <= 0.0 {
            0.0
        } else {
            (0.5_f64.powf(dt / self.trail_half_life_s as f64) as f32).clamp(0.0, 1.0)
        };

        ShootingStarsFrame {
            sprites: &self.sprites,
            keep_factor,
        }
    }

    fn spawn_if_needed<R: Rng + ?Sized>(&mut self, dt: f64, rng: &mut R) {
        if self.avg_seconds <= 0.0 {
            return;
        }
        let p = dt / self.avg_seconds;
        if rng.gen_range(0.0..=1.0) < p {
            self.attempt_spawn(rng);
        }
    }

    /// Up to 8 tries to place a star inside the safe zone. Once one fits,
    /// stop — matches `attemptSpawn` (Swift line 255-274). Failures are
    /// silent: a frame with no successful placement just doesn't spawn,
    /// which is fine for a rare-event stream.
    fn attempt_spawn<R: Rng + ?Sized>(&mut self, rng: &mut R) {
        const SPAWN_ATTEMPTS: u32 = 8;
        for _ in 0..SPAWN_ATTEMPTS {
            if let Some(star) = self.make_star(rng) {
                self.active.push(star);
                return;
            }
        }
    }

    fn make_star<R: Rng + ?Sized>(&self, rng: &mut R) -> Option<ShootingStar> {
        let dir = self.pick_direction(rng);
        let length = self.base_length * rng.gen_range(0.85_f32..=1.15);
        let lifetime = (length / self.speed) as f64;

        let margin: f32 = 4.0;
        let min_x = margin + length;
        let max_x = self.width as f32 - margin - length;
        if min_x >= max_x {
            return None;
        }

        let min_y = (self.safe_min_y + margin + length).max(self.safe_min_y + 8.0);
        let max_y = self.height as f32 - margin - length;
        if min_y >= max_y {
            return None;
        }

        // 10-attempt rejection sampling for a head position s.t. both
        // streak extremities land in the safe zone (Swift line 292-315).
        // Without this, fast steep-angle stars can spawn with their tail
        // already off-screen, which looks broken.
        for _ in 0..10 {
            let hx = rng.gen_range(min_x..=max_x);
            let hy = rng.gen_range(min_y..=max_y);
            let head = [hx, hy];
            let e1 = [head[0] - dir[0] * length, head[1] - dir[1] * length];
            let e2 = [head[0] + dir[0] * length, head[1] + dir[1] * length];
            if self.inside(e1) && self.inside(e2) {
                return Some(ShootingStar {
                    head,
                    dir,
                    speed: self.speed,
                    length,
                    thickness: self.thickness.max(0.5),
                    brightness: self.brightness,
                    lifetime,
                    age: 0.0,
                });
            }
        }
        None
    }

    fn inside(&self, p: [f32; 2]) -> bool {
        p[0] >= 0.0
            && p[0] < self.width as f32
            && p[1] >= self.safe_min_y
            && p[1] < self.height as f32
    }

    fn pick_direction<R: Rng + ?Sized>(&self, rng: &mut R) -> [f32; 2] {
        let base = match self.direction_mode {
            ShootingStarDirectionMode::LeftToRight => norm(1.0, -0.25),
            ShootingStarDirectionMode::RightToLeft => norm(-1.0, -0.25),
            ShootingStarDirectionMode::TopLeftToBottomRight => norm(1.0, -1.0),
            ShootingStarDirectionMode::TopRightToBottomLeft => norm(-1.0, -1.0),
            ShootingStarDirectionMode::Random => {
                // Six canonical directions all heading downward (Y is
                // bottom-origin so dy < 0 means "toward horizon").
                const CANDIDATES: [(f32, f32); 6] = [
                    (1.0, -0.3),
                    (-1.0, -0.3),
                    (1.0, -0.8),
                    (-1.0, -0.8),
                    (0.8, -1.0),
                    (-0.8, -1.0),
                ];
                let pick = CANDIDATES[rng.gen_range(0..CANDIDATES.len())];
                norm(pick.0, pick.1)
            }
        };
        add_jitter(base, rng)
    }
}

fn norm(dx: f32, dy: f32) -> [f32; 2] {
    let len = (dx * dx + dy * dy).sqrt();
    if len == 0.0 {
        return [1.0, -0.3];
    }
    [dx / len, dy / len]
}

/// Rotate the unit direction by a uniform random angle in [-0.15, 0.15]
/// rad (~ ±8.6°) and renormalize. Matches Swift `addJitter` line 354.
/// Even tiny jitter dramatically breaks up the "all stars on parallel
/// tracks" look of unjittered random mode.
fn add_jitter<R: Rng + ?Sized>(v: [f32; 2], rng: &mut R) -> [f32; 2] {
    let angle = rng.gen_range(-0.15_f32..=0.15);
    let (sin_a, cos_a) = angle.sin_cos();
    let dx = v[0] * cos_a - v[1] * sin_a;
    let dy = v[0] * sin_a + v[1] * cos_a;
    let len = (dx * dx + dy * dy).sqrt();
    [dx / len, dy / len]
}

/// Emit 18 point sprites tracing a single star from tail (t=0) to head
/// (t=1). The intensity ramps as `brightness · t²` so the head is much
/// brighter than the tail, plus a 15%-of-lifetime fade-in at birth so
/// new stars don't pop in at full intensity. Color blends from pure
/// white at the tail to warm yellow-white at the head. Radius tapers
/// from `0.3·thickness` to `1.0·thickness`. All matches Swift
/// `appendStarSprites` lines 366-411.
fn append_star_sprites(star: &ShootingStar, out: &mut Vec<SpriteInstance>) {
    let tail = star.tail();
    let dir = star.dir;
    let len = star.length;

    let mut brightness = star.brightness;
    let fade_window = star.lifetime * 0.15;
    if star.age < fade_window {
        brightness *= (star.age / fade_window) as f32;
    }

    const SEGMENTS: usize = 18;
    const WARM_HEAD: [f32; 3] = [1.0, 0.95, 0.85];
    const TAIL_WHITE: [f32; 3] = [1.0, 1.0, 1.0];

    for i in 0..SEGMENTS {
        let t = i as f32 / (SEGMENTS - 1) as f32; // 0 tail -> 1 head
        let px = tail[0] + dir[0] * len * t;
        let py = tail[1] + dir[1] * len * t;
        let intensity = brightness * t * t;
        let radius = star.thickness * 0.3 + star.thickness * 0.7 * t;
        let rr = TAIL_WHITE[0] * (1.0 - t) + WARM_HEAD[0] * t;
        let gg = TAIL_WHITE[1] * (1.0 - t) + WARM_HEAD[1] * t;
        let bb = TAIL_WHITE[2] * (1.0 - t) + WARM_HEAD[2] * t;
        let alpha = intensity.clamp(0.0, 1.0);
        // Premultiplied alpha — the additive blend state still expects
        // premultiplied input so the math is consistent with the rest of
        // the sprite pipeline (see sprite.rs).
        let color = [rr * alpha, gg * alpha, bb * alpha, alpha];
        out.push(SpriteInstance::new([px, py], radius * 2.0, color));
    }
}
