// Moon shader for starry-rs.
//
// Renders a circular moon disc with Lambertian lighting (computed from a
// hemisphere normal projected out of the disc), a phase terminator
// (driven by `illuminatedFraction` and `waxingSign` packed in the UBO),
// and procedural-albedo texturing sampled from a grayscale R8 map.
//
// Direct port of `MoonVertex` / `MoonFragment` in
// `StarryExcuseForAMacScreensaver/Shaders.metal` (lines 152-266). The
// UBO `params0/1/2` packing matches the Metal layout exactly so the
// shader source stays readable side-by-side with the Swift version.
//
// Coordinate convention: pixel coordinates are **bottom-left origin,
// Y-up**, matching `shader.wgsl` (sprite shader) and the Swift Metal
// path. The vertex stage maps `centerPx + local * radiusPx` through the
// standard `(2*x/w - 1, 2*y/h - 1)` formula.

struct MoonUniforms {
    viewport_size: vec2<f32>,
    center_px:     vec2<f32>,
    // params0: (radiusPx, illuminatedFraction, brightBrightness, darkBrightness)
    params0:       vec4<f32>,
    // params1: (debugShowMaskFlag, waxingSign(+1/-1), _, _)
    params1:       vec4<f32>,
    // params2: (terminatorMode, terminatorWidth, terminatorBands, _)
    //   terminatorMode: 0 = hard step, 1 = smooth, 2 = banded
    //   terminatorWidth: half-width of smooth transition (modes 1 + 2)
    //   terminatorBands: discrete bands count (mode 2 only)
    params2:       vec4<f32>,
};

@group(0) @binding(0) var<uniform> uni: MoonUniforms;
@group(0) @binding(1) var albedo_tex: texture_2d<f32>;
@group(0) @binding(2) var albedo_smp: sampler;

struct VertexOut {
    @builtin(position) clip_position: vec4<f32>,
    // Disc-local coordinates in `[-1, 1]²`. Fragment uses `length(local)`
    // to discard outside the unit circle and to project the hemisphere
    // normal `(local.x, local.y, sqrt(1 - r²))`.
    @location(0) local: vec2<f32>,
};

const PI: f32 = 3.14159265358979323846;

@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> VertexOut {
    // 6-vertex triangle list (no vertex buffer needed) — same layout as
    // the Metal `MoonVertex`. Two triangles: (BL, BR, TL), (TL, BR, TR).
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>( 1.0, -1.0),
        vec2<f32>(-1.0,  1.0),
        vec2<f32>(-1.0,  1.0),
        vec2<f32>( 1.0, -1.0),
        vec2<f32>( 1.0,  1.0),
    );
    let local = corners[vid];
    let radius_px = uni.params0.x;
    let pos_px = uni.center_px + local * radius_px;
    let ndc = vec2<f32>(
        (pos_px.x / uni.viewport_size.x) * 2.0 - 1.0,
        (pos_px.y / uni.viewport_size.y) * 2.0 - 1.0,
    );

    var out: VertexOut;
    out.clip_position = vec4<f32>(ndc, 0.0, 1.0);
    out.local = local;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    let local = in.local;
    let r2 = dot(local, local);
    if (r2 > 1.0) {
        discard;
    }

    let radius_px = max(uni.params0.x, 1.0);
    let r = sqrt(r2);
    // Edge feather: ~2 destination pixels of soft alpha falloff at the
    // disc boundary, clamped so tiny moons don't disappear into the
    // gradient and huge ones don't get a comically soft outline. Matches
    // Metal's `clamp(2.0 / radiusPx, 0.0015, 0.12)`.
    let feather_local = clamp(2.0 / radius_px, 0.0015, 0.12);
    let edge_alpha = 1.0 - smoothstep(1.0 - feather_local, 1.0, r);

    // Project the disc-local point onto the front hemisphere of a unit
    // sphere. `z = sqrt(1 - r²)`. Result is the surface normal used for
    // Lambertian shading.
    let z = sqrt(max(0.0, 1.0 - r2));
    let n = normalize(vec3<f32>(local.x, local.y, z));

    // Terminator direction.
    //   illuminatedFraction → δ = acos(1 - 2·f)
    //   waxing  → φ = π - δ   (light from right)
    //   waning  → φ = δ - π   (light from left)
    //   light dir l = (sin φ, 0, cos φ); ndotl = dot(n, l)
    let f_illum = clamp(uni.params0.y, 0.0, 1.0);
    let cos_delta = 1.0 - 2.0 * f_illum;
    let delta = acos(clamp(cos_delta, -1.0, 1.0));
    let waxing_sign = uni.params1.y;
    var phi: f32;
    if (waxing_sign > 0.0) {
        phi = PI - delta;
    } else {
        phi = delta - PI;
    }
    let l = normalize(vec3<f32>(sin(phi), 0.0, cos(phi)));
    let ndotl = dot(n, l);

    // Terminator mode (0 = hard, 1 = smooth, 2 = banded). Matches the
    // Metal switch on `int(params2.x)`.
    let term_mode = i32(uni.params2.x);
    let term_width = uni.params2.y;
    let term_bands = uni.params2.z;

    var lit_mask: f32;
    if (term_mode == 1) {
        lit_mask = smoothstep(-term_width, term_width, ndotl);
    } else if (term_mode == 2) {
        // Banded: quantize `smoothstep(...)` into N discrete steps with
        // softened band edges. `edge = clamp(termWidth * termBands, 0.01,
        // 0.5)` prevents harsh transitions when the smooth zone is thin
        // and there are many bands.
        let smooth_v = smoothstep(-term_width, term_width, ndotl);
        let raw = smooth_v * term_bands;
        let f = fract(raw);
        let edge = clamp(term_width * term_bands, 0.01, 0.5);
        let soft_edge = smoothstep(0.0, edge, f);
        lit_mask = clamp((floor(raw) + soft_edge) / (term_bands - 1.0), 0.0, 1.0);
    } else {
        if (ndotl >= 0.0) {
            lit_mask = 1.0;
        } else {
            lit_mask = 0.0;
        }
    }

    let debug_show_mask = uni.params1.x;

    // Albedo lookup: disc-local → texture UV via the standard
    // `local * 0.5 + 0.5` mapping (matches Metal line 249).
    let uv = local * 0.5 + 0.5;
    let albedo_sample = textureSample(albedo_tex, albedo_smp, uv).r;

    // Debug-mask path: render the terminator lit mask as a red
    // visualisation so the texture/lighting interaction can be inspected
    // in isolation. Wired to the `--debug-moon-colors` CLI flag.
    if (debug_show_mask > 0.0) {
        let a = edge_alpha * 0.9;
        return vec4<f32>(lit_mask * a, 0.0, 0.0, a);
    }

    let bright_b = uni.params0.z;
    let dark_b = uni.params0.w;
    let brightness = mix(dark_b, bright_b, lit_mask);
    let rgb = vec3<f32>(albedo_sample * brightness);

    // Premultiplied alpha out, matching the composite pipeline's
    // `PREMULTIPLIED_ALPHA_BLENDING` state.
    return vec4<f32>(rgb * edge_alpha, edge_alpha);
}
