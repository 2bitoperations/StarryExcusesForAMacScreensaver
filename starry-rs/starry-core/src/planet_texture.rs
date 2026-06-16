//! Procedural RGBA8 texture generation for the seven non-Saturn planets.
//!
//! Mirrors `PlanetTexture.swift` for visual parity. Each planet has a small
//! generator that produces a 64×64 RGBA pixel buffer, which is then
//! nearest-neighbour rescaled to the runtime `diameter` requested by the
//! renderer.
//!
//! # Determinism
//! Unlike [`moon_texture`](crate::moon_texture), planet textures are 100%
//! deterministic functions of `(identity, diameter)`. The base noise
//! function ([`pseudo_noise`]) is a SplitMix64-style position hash —
//! no RNG state is threaded through.
//!
//! # Saturn placeholder
//! Saturn returns a flat pale-gold disc in this phase. The full banded body
//! + Schlyter ring tilt math lands in Phase 5b.
//!
//! # Output format
//! Each call returns `Vec<u8>` of length `diameter * diameter * 4`, with
//! pixels packed as RGBA8 in row-major order, alpha always 255.
//! Premultiplied vs straight is irrelevant for fully-opaque pixels — the
//! renderer can treat it either way.

use crate::planet::PlanetIdentity;

/// Base resolution that every per-planet generator works at. Picked to
/// match Swift's `PlanetTexture` exactly.
const BASE_SIZE: u32 = 64;

/// Public entry point: returns an RGBA8 buffer of `diameter*diameter*4`
/// bytes for the given planet. The generator runs at 64×64 and the result
/// is nearest-rescaled to `diameter`.
pub fn create_planet_texture(identity: PlanetIdentity, diameter: u32) -> Vec<u8> {
    let base = match identity {
        PlanetIdentity::Mercury => generate_mercury_albedo_map(BASE_SIZE),
        PlanetIdentity::Venus => generate_venus_albedo_map(BASE_SIZE),
        PlanetIdentity::Mars => generate_mars_albedo_map(BASE_SIZE),
        PlanetIdentity::Jupiter => generate_jupiter_albedo_map(BASE_SIZE),
        PlanetIdentity::Saturn => generate_saturn_placeholder(BASE_SIZE),
        PlanetIdentity::Uranus => generate_uranus_albedo_map(BASE_SIZE),
        PlanetIdentity::Neptune => generate_neptune_albedo_map(BASE_SIZE),
        PlanetIdentity::Pluto => generate_pluto_albedo_map(BASE_SIZE),
    };
    rescale_nearest_rgba(&base, BASE_SIZE, diameter)
}

// ---------------------------------------------------------------------------
// Mercury (grey, lightly cratered)
// ---------------------------------------------------------------------------

fn generate_mercury_albedo_map(size: u32) -> Vec<u8> {
    let mut buf = vec![0u8; (size * size * 4) as usize];
    let inv = 1.0 / f64::from(size - 1);
    for y in 0..size as i32 {
        for x in 0..size as i32 {
            let nx = f64::from(x) * inv;
            let ny = f64::from(y) * inv;
            let base = 0.52 + (pseudo_noise(x, y) - 0.5) * 0.22;
            let mut r = base;
            let mut g = base;
            let mut b = base;
            let crater = pseudo_noise(
                x.wrapping_mul(7).wrapping_add(3),
                y.wrapping_mul(11).wrapping_add(5),
            );
            if crater < 0.08 {
                let depth = (0.08 - crater) / 0.08;
                r -= 0.18 * depth;
                g -= 0.18 * depth;
                b -= 0.18 * depth;
            }
            let limb = limb_darkening_factor(nx, ny);
            write_pixel(&mut buf, size, x, y, r * limb, g * limb, b * limb);
        }
    }
    buf
}

// ---------------------------------------------------------------------------
// Venus (yellowish-tan, cloudy banding)
// ---------------------------------------------------------------------------

fn generate_venus_albedo_map(size: u32) -> Vec<u8> {
    let mut buf = vec![0u8; (size * size * 4) as usize];
    let inv = 1.0 / f64::from(size - 1);
    for y in 0..size as i32 {
        for x in 0..size as i32 {
            let nx = f64::from(x) * inv;
            let ny = f64::from(y) * inv;
            let band_noise = pseudo_noise(x.wrapping_mul(3), y.wrapping_mul(5).wrapping_add(13));
            let fy = f64::from(y) / f64::from(size);
            let band = 0.5 + 0.5 * (fy * std::f64::consts::PI * 5.0 + band_noise * 1.2).sin();
            let mut r = 0.88 + band * 0.06;
            let mut g = 0.76 + band * 0.04;
            let mut b = 0.42 + band * 0.02;
            let n = (pseudo_noise(x, y) - 0.5) * 0.06;
            r = clamp01(r + n);
            g = clamp01(g + n * 0.8);
            b = clamp01(b + n * 0.4);
            let limb = limb_darkening_factor(nx, ny);
            write_pixel(&mut buf, size, x, y, r * limb, g * limb, b * limb);
        }
    }
    buf
}

// ---------------------------------------------------------------------------
// Mars (reddish-orange with darker maria and a tiny polar cap hint)
// ---------------------------------------------------------------------------

fn generate_mars_albedo_map(size: u32) -> Vec<u8> {
    let mut buf = vec![0u8; (size * size * 4) as usize];
    let inv = 1.0 / f64::from(size - 1);
    for y in 0..size as i32 {
        for x in 0..size as i32 {
            let nx = f64::from(x) * inv;
            let ny = f64::from(y) * inv;
            let mut r = 0.76 + (pseudo_noise(x, y) - 0.5) * 0.10;
            let mut g = 0.36 + (pseudo_noise(x.wrapping_add(100), y) - 0.5) * 0.06;
            let mut b = 0.22 + (pseudo_noise(x, y.wrapping_add(100)) - 0.5) * 0.04;
            let maria = pseudo_noise(
                x.wrapping_mul(5).wrapping_add(7),
                y.wrapping_mul(3).wrapping_add(11),
            );
            if maria < 0.18 {
                let d = (0.18 - maria) / 0.18;
                r -= 0.20 * d;
                g -= 0.10 * d;
                b -= 0.05 * d;
            }
            if f64::from(y) < f64::from(size) * 0.08 {
                let pct = 1.0 - f64::from(y) / (f64::from(size) * 0.08);
                r = r * (1.0 - pct) + 0.96 * pct;
                g = g * (1.0 - pct) + 0.96 * pct;
                b = b * (1.0 - pct) + 0.98 * pct;
            }
            let limb = limb_darkening_factor(nx, ny);
            write_pixel(&mut buf, size, x, y, r * limb, g * limb, b * limb);
        }
    }
    buf
}

// ---------------------------------------------------------------------------
// Jupiter (banded gas giant with Great Red Spot)
// ---------------------------------------------------------------------------

/// Per-band (R, G, B) base colors for Jupiter, in band order top-to-bottom
/// at 64×64. Ported verbatim from `PlanetTexture.swift`.
const JUPITER_BAND_COLORS: [(f64, f64, f64); 11] = [
    (0.910, 0.835, 0.639),
    (0.831, 0.533, 0.227),
    (0.545, 0.396, 0.204),
    (0.890, 0.820, 0.620),
    (0.780, 0.490, 0.240),
    (0.910, 0.835, 0.639),
    (0.780, 0.440, 0.200),
    (0.890, 0.820, 0.600),
    (0.545, 0.380, 0.190),
    (0.870, 0.820, 0.640),
    (0.780, 0.710, 0.490),
];

/// Row Y-positions (in 64-pixel space) where each band starts. The final
/// entry (64) is the sentinel "end of last band" — it makes the loop in
/// [`jupiter_band_color`] a clean `< next_start` comparison.
const JUPITER_BAND_STARTS: [i32; 12] = [0, 6, 11, 15, 21, 27, 33, 39, 45, 51, 57, 64];

fn jupiter_band_color(y: i32, noise: f64) -> (f64, f64, f64) {
    let effective_row = f64::from(y) + (noise - 0.5) * 2.5;
    let mut index = JUPITER_BAND_COLORS.len() - 1;
    for i in 0..(JUPITER_BAND_STARTS.len() - 1) {
        if effective_row < f64::from(JUPITER_BAND_STARTS[i + 1]) {
            index = i;
            break;
        }
    }
    JUPITER_BAND_COLORS[index]
}

fn great_red_spot_blend(nx: f64, ny: f64, r: f64, g: f64, b: f64) -> (f64, f64, f64) {
    let dx = (nx - 0.60) / 0.13;
    let dy = (ny - 0.55) / 0.075;
    let dist2 = dx * dx + dy * dy;
    if dist2 >= 1.0 {
        return (r, g, b);
    }
    let blend = 1.0 - dist2;
    (
        r * (1.0 - blend) + 0.753 * blend,
        g * (1.0 - blend) + 0.314 * blend,
        b * (1.0 - blend) + 0.227 * blend,
    )
}

fn generate_jupiter_albedo_map(size: u32) -> Vec<u8> {
    let mut buf = vec![0u8; (size * size * 4) as usize];
    let inv = 1.0 / f64::from(size - 1);
    for y in 0..size as i32 {
        for x in 0..size as i32 {
            let nx = f64::from(x) * inv;
            let ny = f64::from(y) * inv;
            let edge_noise = pseudo_noise(x, y.wrapping_mul(3).wrapping_add(17));
            let (mut r, mut g, mut b) = jupiter_band_color(y, edge_noise);
            let blended = great_red_spot_blend(nx, ny, r, g, b);
            r = blended.0;
            g = blended.1;
            b = blended.2;
            let limb = limb_darkening_factor(nx, ny);
            r *= limb;
            g *= limb;
            b *= limb;
            let bn = (pseudo_noise(x, y) - 0.5) * 0.14;
            r = clamp01(r + bn * r);
            g = clamp01(g + bn * g);
            b = clamp01(b + bn * b);
            write_pixel(&mut buf, size, x, y, r, g, b);
        }
    }
    buf
}

// ---------------------------------------------------------------------------
// Saturn (placeholder — full impl in Phase 5b)
// ---------------------------------------------------------------------------

/// Flat pale-gold placeholder for Saturn body. Replaced by the full banded
/// body generator + Schlyter ring tilt math in Phase 5b so that the visual
/// gap stays obvious until the proper texture lands.
fn generate_saturn_placeholder(size: u32) -> Vec<u8> {
    let mut buf = vec![0u8; (size * size * 4) as usize];
    for y in 0..size as i32 {
        for x in 0..size as i32 {
            write_pixel(&mut buf, size, x, y, 0.88, 0.77, 0.46);
        }
    }
    buf
}

// ---------------------------------------------------------------------------
// Uranus (pale blue-green, very subtle banding)
// ---------------------------------------------------------------------------

fn generate_uranus_albedo_map(size: u32) -> Vec<u8> {
    let mut buf = vec![0u8; (size * size * 4) as usize];
    let inv = 1.0 / f64::from(size - 1);
    for y in 0..size as i32 {
        for x in 0..size as i32 {
            let nx = f64::from(x) * inv;
            let ny = f64::from(y) * inv;
            let fy = f64::from(y) / f64::from(size);
            let band = 0.5 + 0.5 * (fy * std::f64::consts::PI * 3.0).sin();
            let mut r = 0.60 + band * 0.02;
            let mut g = 0.82 + band * 0.03;
            let mut b = 0.84 + band * 0.03;
            let n = (pseudo_noise(x, y) - 0.5) * 0.04;
            r = clamp01(r + n * 0.5);
            g = clamp01(g + n);
            b = clamp01(b + n);
            let limb = limb_darkening_factor(nx, ny);
            write_pixel(&mut buf, size, x, y, r * limb, g * limb, b * limb);
        }
    }
    buf
}

// ---------------------------------------------------------------------------
// Neptune (deep blue with Great Dark Spot homage)
// ---------------------------------------------------------------------------

fn generate_neptune_albedo_map(size: u32) -> Vec<u8> {
    let mut buf = vec![0u8; (size * size * 4) as usize];
    let inv = 1.0 / f64::from(size - 1);
    for y in 0..size as i32 {
        for x in 0..size as i32 {
            let nx = f64::from(x) * inv;
            let ny = f64::from(y) * inv;
            let mut r = 0.18 + (pseudo_noise(x, y) - 0.5) * 0.06;
            let mut g = 0.34 + (pseudo_noise(x.wrapping_add(50), y) - 0.5) * 0.04;
            let mut b = 0.82 + (pseudo_noise(x, y.wrapping_add(50)) - 0.5) * 0.06;
            let storm = pseudo_noise(
                x.wrapping_mul(9).wrapping_add(2),
                y.wrapping_mul(5).wrapping_add(7),
            );
            if storm < 0.07 {
                let d = (0.07 - storm) / 0.07;
                r -= 0.08 * d;
                g -= 0.10 * d;
                b -= 0.14 * d;
            }
            let limb = limb_darkening_factor(nx, ny);
            write_pixel(&mut buf, size, x, y, r * limb, g * limb, b * limb);
        }
    }
    buf
}

// ---------------------------------------------------------------------------
// Pluto (tan/cream with a lighter Tombaugh Regio heart)
// ---------------------------------------------------------------------------

fn generate_pluto_albedo_map(size: u32) -> Vec<u8> {
    let mut buf = vec![0u8; (size * size * 4) as usize];
    let inv = 1.0 / f64::from(size - 1);
    for y in 0..size as i32 {
        for x in 0..size as i32 {
            let nx = f64::from(x) * inv;
            let ny = f64::from(y) * inv;
            let mut r = 0.72 + (pseudo_noise(x, y) - 0.5) * 0.10;
            let mut g = 0.60 + (pseudo_noise(x.wrapping_add(200), y) - 0.5) * 0.08;
            let mut b = 0.44 + (pseudo_noise(x, y.wrapping_add(200)) - 0.5) * 0.06;
            // Tombaugh Regio approximation: parametric heart `|x|^1.4 + |y| <= 1`.
            let hx = (nx - 0.38) / 0.22;
            let hy = (ny - 0.58) / 0.28;
            let heart_dist = hx.abs().powf(1.4) + hy.abs() - 1.0;
            if heart_dist < 0.0 {
                let blend = (-heart_dist * 3.0).min(1.0);
                r = r * (1.0 - blend) + 0.92 * blend;
                g = g * (1.0 - blend) + 0.86 * blend;
                b = b * (1.0 - blend) + 0.72 * blend;
            }
            let limb = limb_darkening_factor(nx, ny);
            write_pixel(&mut buf, size, x, y, r * limb, g * limb, b * limb);
        }
    }
    buf
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// Quadratic limb darkening centred on (0.5, 0.5). At the disc edge
/// returns 0.82; at the centre returns 1.0.
fn limb_darkening_factor(nx: f64, ny: f64) -> f64 {
    let dx = nx - 0.5;
    let dy = ny - 0.5;
    let radial = (((dx * dx + dy * dy).sqrt()) / 0.5).min(1.0);
    1.0 - 0.18 * radial * radial
}

/// Position-only hash noise in `[0, 1)`. Mirrors Swift's `pseudoNoise`
/// (SplitMix64-style finaliser) bit-for-bit so the Rust output matches
/// the Swift output pixel-for-pixel.
fn pseudo_noise(x: i32, y: i32) -> f64 {
    // Swift: UInt64(bitPattern: Int64(x)) — sign-extend i32→i64, then
    // reinterpret as u64. `as i64 as u64` does exactly that in Rust.
    let ux = x as i64 as u64;
    let uy = y as i64 as u64;
    let mut n = ux.wrapping_mul(73_856_093);
    n = n.wrapping_add(uy.wrapping_mul(19_349_663));
    n = n.wrapping_add(0x9E37_79B9_7F4A_7C15);
    n ^= n >> 33;
    n = n.wrapping_mul(0xff51_afd7_ed55_8ccd);
    n ^= n >> 33;
    n = n.wrapping_mul(0xc4ce_b9fe_1a85_ec53);
    n ^= n >> 33;
    (n & 0xFFFFFF) as f64 / 0xFFFFFF as f64
}

/// Nearest-neighbour rescale of an RGBA buffer from `src_size` to
/// `dst_size`. Handles both upscale and downscale (Swift relies on
/// `CGContext.interpolationQuality = .none` for the same behaviour).
fn rescale_nearest_rgba(src: &[u8], src_size: u32, dst_size: u32) -> Vec<u8> {
    if src_size == dst_size {
        return src.to_vec();
    }
    let mut dst = vec![0u8; (dst_size * dst_size * 4) as usize];
    for y in 0..dst_size {
        // Map dst row to src row at the pixel centre.
        let sy = ((u64::from(y) * u64::from(src_size)) / u64::from(dst_size)) as u32;
        for x in 0..dst_size {
            let sx = ((u64::from(x) * u64::from(src_size)) / u64::from(dst_size)) as u32;
            let si = ((sy * src_size + sx) * 4) as usize;
            let di = ((y * dst_size + x) * 4) as usize;
            dst[di] = src[si];
            dst[di + 1] = src[si + 1];
            dst[di + 2] = src[si + 2];
            dst[di + 3] = src[si + 3];
        }
    }
    dst
}

fn clamp01(v: f64) -> f64 {
    v.clamp(0.0, 1.0)
}

fn byte(v: f64) -> u8 {
    (clamp01(v) * 255.0) as u8
}

fn write_pixel(buf: &mut [u8], size: u32, x: i32, y: i32, r: f64, g: f64, b: f64) {
    let i = ((y as u32 * size + x as u32) * 4) as usize;
    buf[i] = byte(r);
    buf[i + 1] = byte(g);
    buf[i + 2] = byte(b);
    buf[i + 3] = 255;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_planet_returns_correct_byte_count_and_opaque_alpha() {
        for identity in PlanetIdentity::ALL {
            for &diameter in &[1u32, 16, 41, 64, 128] {
                let tex = create_planet_texture(identity, diameter);
                assert_eq!(
                    tex.len(),
                    (diameter * diameter * 4) as usize,
                    "wrong size for {} at d={}",
                    identity.name(),
                    diameter
                );
                for chunk in tex.chunks_exact(4) {
                    assert_eq!(
                        chunk[3], 255,
                        "non-opaque alpha for {} at d={}",
                        identity.name(),
                        diameter
                    );
                }
            }
        }
    }

    #[test]
    fn texture_is_deterministic_per_identity_and_diameter() {
        for identity in PlanetIdentity::ALL {
            let a = create_planet_texture(identity, 64);
            let b = create_planet_texture(identity, 64);
            assert_eq!(a, b, "non-deterministic for {}", identity.name());
        }
    }

    #[test]
    fn rescale_identity_returns_identical_bytes() {
        // 1×1 RGBA: 4 bytes, identity rescale is a pure copy.
        let src = vec![1, 2, 3, 4];
        let out = rescale_nearest_rgba(&src, 1, 1);
        assert_eq!(out, vec![1, 2, 3, 4]);
        // 2×2 → 2×2: also a pure copy.
        let bigger = (0u8..16).collect::<Vec<u8>>();
        let out2 = rescale_nearest_rgba(&bigger, 2, 2);
        assert_eq!(out2, bigger);
    }

    #[test]
    fn rescale_handles_upsample_and_downsample() {
        // Upsample 2×2 → 4×4: each src pixel covers a 2×2 dst block.
        let src: Vec<u8> = (0u8..16).collect();
        let up = rescale_nearest_rgba(&src, 2, 4);
        assert_eq!(up.len(), 64);
        // dst (0,0) should equal src (0,0).
        assert_eq!(&up[0..4], &src[0..4]);
        // dst (3,3) should equal src (1,1). Byte offsets (y*stride + x)*4:
        //   dst: (3*4 + 3)*4 = 60
        //   src: (1*2 + 1)*4 = 12
        let last_dst = 60usize;
        let last_src = 12usize;
        assert_eq!(&up[last_dst..last_dst + 4], &src[last_src..last_src + 4]);

        // Downsample 4×4 → 2×2: must produce exactly 16 bytes.
        let src4: Vec<u8> = (0u8..64).collect();
        let down = rescale_nearest_rgba(&src4, 4, 2);
        assert_eq!(down.len(), 16);
    }

    #[test]
    fn pseudo_noise_stays_in_unit_range() {
        for x in -8..8 {
            for y in -8..8 {
                let n = pseudo_noise(x, y);
                assert!(
                    (0.0..1.0).contains(&n),
                    "pseudo_noise({}, {}) = {} out of [0, 1)",
                    x,
                    y,
                    n
                );
            }
        }
    }

    #[test]
    fn jupiter_band_index_picks_band_for_row_zero() {
        // Row 0 with zero noise → effective_row = -1.25 → first band.
        let (r, g, b) = jupiter_band_color(0, 0.5);
        assert_eq!((r, g, b), JUPITER_BAND_COLORS[0]);
    }

    #[test]
    fn saturn_placeholder_is_flat_gold() {
        let tex = create_planet_texture(PlanetIdentity::Saturn, 8);
        for chunk in tex.chunks_exact(4) {
            // 0.88 * 255 = 224.4 → 224, 0.77 * 255 = 196.35 → 196, 0.46 * 255 = 117.3 → 117.
            assert_eq!(chunk[0], 224);
            assert_eq!(chunk[1], 196);
            assert_eq!(chunk[2], 117);
            assert_eq!(chunk[3], 255);
        }
    }
}
