//! Procedural moon albedo texture generator.
//!
//! Direct port of `MoonTexture.swift`. The Swift implementation generates
//! a 64×64 grayscale base via deterministic 64-bit integer hashing (no
//! `rand` dependency — the hash itself is the entropy source), then
//! upsamples to the target diameter with nearest-neighbor interpolation
//! (Swift uses `CGContext.interpolationQuality = .none`) so the crater
//! detail stays blocky and retro at any radius.
//!
//! Output is **single-channel grayscale**, byte range `[25, 240]`. The
//! renderer (Step 5, `moon_renderer.rs`) decides how to upload it (likely
//! as `R8Unorm` and sampled with `linear` filter so the upsample blocks
//! get a subtle softening at large radii, matching the Swift Metal path
//! which uses `mip_filter::linear` + `filter::linear`).
//!
//! Why we keep the hash arithmetic in `u64` with explicit `wrapping_*`
//! ops: Swift's `&*` and `&+` are wrapping by design, and porting them
//! to `u64::wrapping_mul` / `wrapping_add` preserves bit-for-bit
//! identical output. Any "cleanup" to `i64` or `u128` would silently
//! drift the texture.

/// Default base resolution (matches Swift). Each pixel is one byte of
/// grayscale; one 4 KiB allocation per moon texture.
pub const BASE_TEXTURE_SIZE: usize = 64;

/// Generate the base 64×64 albedo map.
///
/// The output is a `size * size`-byte single-channel grayscale buffer in
/// row-major order, with each pixel in the range `[25, 240]` so the moon
/// never goes pure black or pure white before lighting is applied.
///
/// Algorithm (1:1 with Swift):
/// 1. Start each pixel at `0.88 - 0.10 * radial` (subtle limb darkening).
/// 2. Subtract a Gaussian falloff (`σ = radius * 0.5`) for each of 7
///    hardcoded maria, scaled by per-maria `depth * 0.5`.
/// 3. Add `(noise - 0.5) * 0.06` jitter from the per-pixel hash.
/// 4. Rare bright crater spots when a secondary hash > 0.995 add `+0.12`.
/// 5. Clamp to `[0.05, 1.0]` and quantize to `25 + brightness * 215`.
pub fn generate_albedo_map(size: usize) -> Vec<u8> {
    let mut buffer = vec![0_u8; size * size];

    // 7 maria, each is (centre_x_normalised, centre_y_normalised, radius,
    // depth). Coordinates are normalised to [0, 1] across the texture so
    // the layout is resolution-independent. Hardcoded to match Swift —
    // these are *the* maria of *the* StarryExcuse moon.
    let maria: [(f64, f64, f64, f64); 7] = [
        (0.38, 0.38, 0.20, 0.55),
        (0.55, 0.42, 0.13, 0.45),
        (0.58, 0.52, 0.11, 0.45),
        (0.32, 0.55, 0.25, 0.50),
        (0.46, 0.58, 0.12, 0.50),
        (0.50, 0.68, 0.14, 0.50),
        (0.40, 0.72, 0.18, 0.55),
    ];

    let inv_size = 1.0 / (size - 1) as f64;
    for y in 0..size {
        for x in 0..size {
            let nx = x as f64 * inv_size;
            let ny = y as f64 * inv_size;
            let dx = nx - 0.5;
            let dy = ny - 0.5;
            let r2 = dx * dx + dy * dy;
            // Soft radial falloff just for a subtle limb darkening; no hard edge.
            let radial = (r2.sqrt() / 0.5).min(1.0);
            let mut brightness = 0.88 - 0.10 * radial;

            for &(mx, my, radius, depth) in &maria {
                let ddx = nx - mx;
                let ddy = ny - my;
                let dist2 = ddx * ddx + ddy * ddy;
                let sigma = radius * 0.5;
                let influence = (-dist2 / (2.0 * sigma * sigma)).exp();
                brightness -= depth * 0.5 * influence;
            }

            let noise = pseudo_noise(x as i64, y as i64);
            brightness += (noise - 0.5) * 0.06;
            // x * 13 + y * 7 (wrapping) feeds a second hash for very rare
            // bright crater spots. Matches Swift's `x &* 13 &+ y &* 7`.
            let crater_input = (x as i64)
                .wrapping_mul(13)
                .wrapping_add((y as i64).wrapping_mul(7));
            let crater_seed = pseudo_noise_hash(crater_input);
            if crater_seed > 0.995 {
                brightness += 0.12;
            }

            brightness = brightness.clamp(0.05, 1.0);
            // Quantise to byte range [25, 240]: never pure black, never
            // pure white. Matches Swift's `25 + Int(brightness * 215.0)`.
            let val = 25 + (brightness * 215.0) as i32;
            buffer[y * size + x] = val.clamp(0, 255) as u8;
        }
    }

    buffer
}

/// Nearest-neighbor upsample a `src_size × src_size` grayscale buffer to
/// `dst_size × dst_size`. Replaces Swift's `CGContext` with
/// `interpolationQuality = .none`. If `dst_size == src_size` the source
/// is returned verbatim.
///
/// Used at moon-construction (and resize) time to stamp the 64×64 base
/// into a `(2 * radius) × (2 * radius)` texture. Output stays grayscale;
/// the renderer is free to upload it as `R8Unorm`.
pub fn upsample_nearest(src: &[u8], src_size: usize, dst_size: usize) -> Vec<u8> {
    assert_eq!(
        src.len(),
        src_size * src_size,
        "upsample_nearest: src.len() must equal src_size * src_size"
    );
    if dst_size == src_size {
        return src.to_vec();
    }
    let mut out = vec![0_u8; dst_size * dst_size];
    // Standard nearest-neighbor: each destination pixel samples from
    // `floor(src_x), floor(src_y)` where `src_x = (dst_x + 0.5) *
    // src_size / dst_size`. The `+ 0.5` centre-samples each destination
    // texel (matches CoreGraphics' default centre-of-pixel convention).
    let scale = src_size as f64 / dst_size as f64;
    for dy in 0..dst_size {
        let sy = (((dy as f64 + 0.5) * scale) as usize).min(src_size - 1);
        for dx in 0..dst_size {
            let sx = (((dx as f64 + 0.5) * scale) as usize).min(src_size - 1);
            out[dy * dst_size + dx] = src[sy * src_size + sx];
        }
    }
    out
}

/// Convenience: produce a `diameter × diameter` grayscale moon texture
/// (base albedo upsampled). Equivalent to Swift's `createMoonTexture`.
pub fn create_moon_texture(diameter: usize) -> Vec<u8> {
    let base = generate_albedo_map(BASE_TEXTURE_SIZE);
    upsample_nearest(&base, BASE_TEXTURE_SIZE, diameter.max(1))
}

// ---- Hash functions ----
//
// Both functions return a uniform `f64 ∈ [0, 1)` from a 24-bit slice of
// the final mixed `u64`. Constants are picked from well-known
// integer-hash literature (golden-ratio, splitmix64) and **must not
// change** — any tweak would visually shift the crater map.

/// 2D pixel-coordinate hash. Input is `(x, y)` integer coords (any sign);
/// output is `f64 ∈ [0, 1)`.
///
/// 1:1 port of Swift's `MoonTexture.pseudoNoise(x:y:)`. The pipeline is:
/// 1. Wrap-multiply x and y by two large primes.
/// 2. Wrap-add a golden-ratio constant.
/// 3. Three rounds of xor-shift + wrap-multiply with well-known mix
///    constants (the murmur3-style finalizer).
fn pseudo_noise(x: i64, y: i64) -> f64 {
    let ux = x as u64;
    let uy = y as u64;
    let mut n = ux.wrapping_mul(73_856_093);
    n = n.wrapping_add(uy.wrapping_mul(19_349_663));
    n = n.wrapping_add(0x9E37_79B9_7F4A_7C15);
    n ^= n >> 33;
    n = n.wrapping_mul(0xff51_afd7_ed55_8ccd);
    n ^= n >> 33;
    n = n.wrapping_mul(0xc4ce_b9fe_1a85_ec53);
    n ^= n >> 33;
    (n & 0xFF_FFFF) as f64 / 0xFF_FFFF as f64
}

/// 1D scalar hash (splitmix64 finalizer). Input is any 64-bit-signed
/// integer; output is `f64 ∈ [0, 1)`. 1:1 port of
/// `MoonTexture.pseudoNoiseHash(x:)`.
fn pseudo_noise_hash(x: i64) -> f64 {
    let mut n = x as u64;
    n = n.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    n ^= n >> 30;
    n = n.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    n ^= n >> 27;
    n = n.wrapping_mul(0x94d0_49bb_1331_11eb);
    n ^= n >> 31;
    (n & 0xFF_FFFF) as f64 / 0xFF_FFFF as f64
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Base texture is the documented size and every byte is in the
    /// documented `[25, 240]` range. The lower bound is `25` (brightness
    /// floor `0.05` × 215 → 10.75, plus the `+25` base → 35.75 floor;
    /// but the rare `+0.12` crater can push it slightly differently, so
    /// we just sanity-check the full envelope).
    #[test]
    fn base_texture_size_and_range() {
        let buf = generate_albedo_map(BASE_TEXTURE_SIZE);
        assert_eq!(buf.len(), BASE_TEXTURE_SIZE * BASE_TEXTURE_SIZE);
        let min = *buf.iter().min().unwrap();
        let max = *buf.iter().max().unwrap();
        assert!(min >= 25, "min byte should be >= 25, got {min}");
        assert!(max <= 240, "max byte should be <= 240, got {max}");
    }

    /// Same inputs must produce identical outputs — the hash chain is
    /// pure, no global state, no `rand`.
    #[test]
    fn texture_is_deterministic() {
        let a = generate_albedo_map(BASE_TEXTURE_SIZE);
        let b = generate_albedo_map(BASE_TEXTURE_SIZE);
        assert_eq!(a, b);
    }

    /// Identity upsample (dst == src size) returns a verbatim copy.
    #[test]
    fn upsample_identity() {
        let src = generate_albedo_map(BASE_TEXTURE_SIZE);
        let out = upsample_nearest(&src, BASE_TEXTURE_SIZE, BASE_TEXTURE_SIZE);
        assert_eq!(src, out);
    }

    /// 2× upsample: each 2×2 destination block should hold one source
    /// pixel's value (true nearest-neighbor with centre sampling).
    #[test]
    fn upsample_2x_replicates_pixels() {
        let src: Vec<u8> = (0..16).collect();
        let out = upsample_nearest(&src, 4, 8);
        assert_eq!(out.len(), 64);
        // Each src[y][x] should map to out[2y..2y+2][2x..2x+2].
        for sy in 0..4 {
            for sx in 0..4 {
                let s = src[sy * 4 + sx];
                for dy in 0..2 {
                    for dx in 0..2 {
                        let o = out[(sy * 2 + dy) * 8 + (sx * 2 + dx)];
                        assert_eq!(s, o, "mismatch at src ({sx},{sy})");
                    }
                }
            }
        }
    }

    /// `create_moon_texture` should match an explicit
    /// `upsample_nearest(generate_albedo_map(64), 64, diameter)` chain.
    #[test]
    fn create_moon_texture_matches_explicit_chain() {
        let direct = create_moon_texture(120);
        let explicit = upsample_nearest(
            &generate_albedo_map(BASE_TEXTURE_SIZE),
            BASE_TEXTURE_SIZE,
            120,
        );
        assert_eq!(direct, explicit);
    }
}
