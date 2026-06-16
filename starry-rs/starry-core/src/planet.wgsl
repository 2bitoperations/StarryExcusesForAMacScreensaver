// planet.wgsl — vertex + fragment for round, textured planets (non-Saturn).
//
// Ports Shaders.metal :267-369 (the non-Saturn branch of PlanetFragment).
// Phase 5a: handles 7 of the 8 planets (Mercury, Venus, Mars, Jupiter, Uranus,
// Neptune, Pluto). Saturn renders via a separate branch in Swift that uses the
// `aspect > 1.0` discriminator + ring geometry; that branch lands in Phase 5b
// as an additive shader edit (this file keeps no scaffolding for it today).
//
// Layout note: the UBO struct mirrors Swift `PlanetUniforms` (Shaders.metal
// :268-274) byte-for-byte so 5b can populate the currently-unread fields
// (`params1.x/.z/.w` for Saturn rings, `params2.w` for `texture_aspect`)
// without touching the WGSL/Rust struct shape.

const PI: f32 = 3.14159265358979323846;

struct PlanetUniforms {
    // Pixel-space viewport for the NDC mapping in the vertex stage.
    viewport_size: vec2<f32>,
    // Pixel-space planet center (origin = bottom-left, matches Swift Y-up).
    center_px: vec2<f32>,
    // x = radius_px, y = phase_fraction (0=new, 1=full),
    // z = bright_brightness, w = dark_brightness.
    params0: vec4<f32>,
    // x = ring_tilt_deg, y = waxing_sign (+1 / -1),
    // z = ring_rotation_deg, w = ring_style.
    // Phase 5a reads only `.y`; the other lanes wait for 5b's Saturn work.
    params1: vec4<f32>,
    // x = terminator_mode (0=hard, 1=smooth, 2=banded),
    // y = terminator_width, z = terminator_bands, w = texture_aspect.
    // Phase 5a reads `.x .y .z`; `.w` is Saturn-only (5b).
    params2: vec4<f32>,
};

@group(0) @binding(0) var<uniform> uni: PlanetUniforms;
@group(0) @binding(1) var albedo_tex: texture_2d<f32>;
@group(0) @binding(2) var albedo_smp: sampler;

struct VertexOut {
    @builtin(position) position: vec4<f32>,
    // Quad-local coords in [-1, +1]; used by the fragment for disc test,
    // normal reconstruction, and UV.
    @location(0) local: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> VertexOut {
    // Two-triangle quad covering [-1,+1]^2 in local space.
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>( 1.0, -1.0),
        vec2<f32>(-1.0,  1.0),
        vec2<f32>(-1.0,  1.0),
        vec2<f32>( 1.0, -1.0),
        vec2<f32>( 1.0,  1.0),
    );
    let local = corners[vid];

    // Non-Saturn: quad side = 2 * radius_px (no aspect stretch).
    // Phase 5b will pre-multiply both axes by `max(uni.params2.w, 1.0)` so
    // Saturn's wider ring-encompassing quad fits.
    let radius_px = uni.params0.x;
    let offset_px = local * radius_px;
    let pos_px = uni.center_px + offset_px;

    // Pixel-space → NDC. Y-up matches Swift (bottom-left origin).
    let ndc = vec2<f32>(
        (pos_px.x / uni.viewport_size.x) * 2.0 - 1.0,
        (pos_px.y / uni.viewport_size.y) * 2.0 - 1.0,
    );

    var out: VertexOut;
    out.position = vec4<f32>(ndc, 0.0, 1.0);
    out.local = local;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    let local = in.local;
    let r2 = dot(local, local);

    // Disc test. WGSL `discard` doesn't terminate the invocation, so the
    // subsequent textureSample is still in uniform control flow.
    if (r2 > 1.0) {
        discard;
    }

    // Soft edge feather. Matches moon shader exactly: scales inverse to
    // pixel radius so small planets stay crisp and big ones stay smooth.
    let radius_px = max(uni.params0.x, 1.0);
    let r = sqrt(r2);
    let feather_local = clamp(2.0 / radius_px, 0.0015, 0.12);
    let edge_alpha = 1.0 - smoothstep(1.0 - feather_local, 1.0, r);

    // Reconstruct sphere normal at this fragment from (x, y) on a unit disc.
    let z = sqrt(max(0.0, 1.0 - r2));
    let n = normalize(vec3<f32>(local.x, local.y, z));

    // Albedo sample. UV in [0,1] from local in [-1,+1].
    let uv = local * 0.5 + vec2<f32>(0.5, 0.5);
    let albedo = textureSample(albedo_tex, albedo_smp, uv);

    // Terminator geometry: derive a sun-direction vector in shader space
    // from the phase fraction, exactly mirroring the moon shader / Swift.
    // cos δ = 1 - 2·illum    (δ = 0 at full, π at new)
    // φ      = waxing>0 ? π-δ : δ-π    (sign flips terminator across vertical)
    // l      = (sin φ, 0, cos φ)
    let f_illum = clamp(uni.params0.y, 0.0, 1.0);
    let cos_delta = 1.0 - 2.0 * f_illum;
    let delta = acos(clamp(cos_delta, -1.0, 1.0));
    let waxing_sign = uni.params1.y;
    let phi = select(delta - PI, PI - delta, waxing_sign > 0.0);
    let l = normalize(vec3<f32>(sin(phi), 0.0, cos(phi)));
    let ndotl = dot(n, l);

    // Terminator mode dispatch (0=hard, 1=smooth, 2=banded).
    let term_mode = i32(uni.params2.x);
    let term_width = uni.params2.y;
    let term_bands = uni.params2.z;

    var lit_mask: f32;
    if (term_mode == 1) {
        // Smooth gradient across the terminator.
        lit_mask = smoothstep(-term_width, term_width, ndotl);
    } else if (term_mode == 2) {
        // Banded: quantise the smooth signal into `term_bands` steps with
        // a soft edge on each band. Matches Shaders.metal :353-359.
        let smooth_lit = smoothstep(-term_width, term_width, ndotl);
        let raw = smooth_lit * term_bands;
        let f = fract(raw);
        let edge = clamp(term_width * term_bands, 0.01, 0.5);
        let soft_edge = smoothstep(0.0, edge, f);
        lit_mask = clamp((floor(raw) + soft_edge) / (term_bands - 1.0), 0.0, 1.0);
    } else {
        // Hard step: classic day/night with a sharp terminator.
        lit_mask = select(0.0, 1.0, ndotl >= 0.0);
    }

    let bright_b = uni.params0.z;
    let dark_b = uni.params0.w;
    let brightness = mix(dark_b, bright_b, lit_mask);
    let rgb = albedo.rgb * brightness;

    // Premultiplied alpha output — composite pipeline expects this.
    return vec4<f32>(rgb * edge_alpha, edge_alpha);
}
