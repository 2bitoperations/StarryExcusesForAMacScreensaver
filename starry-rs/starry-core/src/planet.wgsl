// planet.wgsl — vertex + fragment for textured planets including Saturn.
//
// Ports Shaders.metal :267-565 (the full PlanetFragment, both branches).
// Discriminator: `is_saturn = max(params2.w, 1.0) > 1.0`. Non-Saturn planets
// share the round-disc + phase/terminator path; Saturn additionally evaluates
// 7 ring bands with 3 retro-art styles and composes them with the textured
// body using a tilt-derived front/back rule.

const PI: f32 = 3.14159265358979323846;

const SATURN_BODY_RADIUS: f32 = 0.846;
const SATURN_RING_INNER: f32 = 0.9306;
const SATURN_RING_OUTER: f32 = 1.9458;
const RING_BRIGHTNESS: f32 = 0.92;

struct PlanetUniforms {
    viewport_size: vec2<f32>,
    center_px: vec2<f32>,
    params0: vec4<f32>,
    params1: vec4<f32>,
    params2: vec4<f32>,
};

@group(0) @binding(0) var<uniform> uni: PlanetUniforms;
@group(0) @binding(1) var albedo_tex: texture_2d<f32>;
@group(0) @binding(2) var albedo_smp: sampler;

struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) local: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> VertexOut {
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
    let aspect = max(uni.params2.w, 1.0);
    let offset_px = local * radius_px * aspect;
    let pos_px = uni.center_px + offset_px;

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
    let aspect = max(uni.params2.w, 1.0);
    let is_saturn = aspect > 1.0;

    // Geometry: sphere_local maps fragment → unit-disc UV used for body
    // sampling/lighting. Non-Saturn uses local directly; Saturn rescales the
    // wider quad into the inner 0.846-radius body region.
    var sphere_local: vec2<f32>;
    var on_planet_body: bool;
    if (is_saturn) {
        let screen_p = vec2<f32>(local.x * aspect, local.y * aspect);
        sphere_local = screen_p / SATURN_BODY_RADIUS;
        on_planet_body = dot(screen_p, screen_p) <= SATURN_BODY_RADIUS * SATURN_BODY_RADIUS;
    } else {
        sphere_local = local;
        on_planet_body = dot(local, local) <= 1.0;
    }

    // Ring evaluation. Saturn-only; everything else stays at zero/false.
    var on_ring = false;
    var ring_in_front = false;
    var ring_color = vec3<f32>(0.0);
    var ring_alpha = 0.0;
    if (is_saturn) {
        let screen_p = vec2<f32>(local.x * aspect, local.y * aspect);
        let axial_tilt_rad = uni.params1.x * (PI / 180.0);
        let ring_rotation_rad = uni.params1.z * (PI / 180.0);
        let sin_tilt = sin(axial_tilt_rad);

        // Edge-on guard: projected ring thickness drops below a pixel near
        // zero opening, which would alias to noise. Skip ring rendering.
        if (abs(sin_tilt) >= 0.01) {
            let c_rot = cos(ring_rotation_rad);
            let s_rot = sin(ring_rotation_rad);
            let rp = vec2<f32>(
                 screen_p.x * c_rot + screen_p.y * s_rot,
                -screen_p.x * s_rot + screen_p.y * c_rot,
            );
            let ring_plane = vec2<f32>(rp.x, rp.y / sin_tilt);
            let ring_r = length(ring_plane);

            if (ring_r >= SATURN_RING_INNER && ring_r <= SATURN_RING_OUTER) {
                let t = (ring_r - SATURN_RING_INNER)
                      / (SATURN_RING_OUTER - SATURN_RING_INNER);

                // 7-zone band selection: C / B-inner / B-outer /
                // Cassini gap / A-inner / Encke gap / A-outer.
                if (t < 0.10) {
                    ring_color = vec3<f32>(0.68, 0.62, 0.50);
                    ring_alpha = 0.40;
                } else if (t < 0.35) {
                    ring_color = vec3<f32>(0.92, 0.84, 0.65);
                    ring_alpha = 0.92;
                } else if (t < 0.56) {
                    ring_color = vec3<f32>(0.86, 0.78, 0.60);
                    ring_alpha = 0.88;
                } else if (t < 0.64) {
                    ring_alpha = 0.0;
                } else if (t < 0.82) {
                    ring_color = vec3<f32>(0.80, 0.73, 0.56);
                    ring_alpha = 0.78;
                } else if (t < 0.85) {
                    ring_alpha = 0.0;
                } else {
                    ring_color = vec3<f32>(0.72, 0.65, 0.50);
                    ring_alpha = 0.60;
                }

                on_ring = ring_alpha > 0.0;

                if (on_ring) {
                    let ring_style = i32(uni.params1.w);
                    if (ring_style == 1) {
                        // FlatRetro: 4-color earthy quantize + 2×2 Bayer
                        // dither on alpha.
                        let lum = dot(ring_color, vec3<f32>(0.299, 0.587, 0.114));
                        if (lum > 0.75) {
                            ring_color = vec3<f32>(0.92, 0.84, 0.65);
                        } else if (lum > 0.55) {
                            ring_color = vec3<f32>(0.78, 0.70, 0.52);
                        } else if (lum > 0.35) {
                            ring_color = vec3<f32>(0.62, 0.55, 0.40);
                        } else {
                            ring_color = vec3<f32>(0.48, 0.42, 0.32);
                        }
                        let px = vec2<i32>(in.position.xy);
                        var bayer = array<f32, 4>(0.0, 0.5, 0.75, 0.25);
                        let threshold = bayer[(px.x % 2) + (px.y % 2) * 2];
                        if (ring_alpha <= threshold + 0.1) {
                            ring_alpha = 0.0;
                        }
                    } else if (ring_style == 2) {
                        // ChunkyPixel: 16-step radial quantize + checker
                        // dither.
                        let qt = floor(t * 16.0) / 16.0;
                        if (qt < 0.125) {
                            ring_color = vec3<f32>(0.60, 0.54, 0.42);
                        } else if (qt < 0.375) {
                            ring_color = vec3<f32>(0.88, 0.80, 0.60);
                        } else if (qt < 0.5625) {
                            ring_color = vec3<f32>(0.82, 0.74, 0.56);
                        } else if (qt < 0.625) {
                            ring_color = vec3<f32>(0.0);
                            ring_alpha = 0.0;
                        } else if (qt < 0.8125) {
                            ring_color = vec3<f32>(0.76, 0.68, 0.52);
                        } else {
                            ring_color = vec3<f32>(0.66, 0.58, 0.44);
                        }
                        let px = vec2<i32>(in.position.xy);
                        let checker = ((px.x + px.y) % 2) == 0;
                        if (!checker) {
                            ring_alpha = ring_alpha * 0.6;
                        }
                    }
                    on_ring = ring_alpha > 0.0;
                }

                // Front/back rule: ring fragment is in front of body iff its
                // y in the rotated frame has the opposite sign as the tilt.
                ring_in_front = (rp.y * sin_tilt) < 0.0;
            }
        }
    }

    if (!on_planet_body && !on_ring) {
        discard;
    }

    // Body lighting — runs only when on body (non-Saturn always; Saturn when
    // the fragment is inside the inner disc).
    var planet_rgb = vec3<f32>(0.0);
    var planet_alpha = 0.0;
    if (on_planet_body) {
        let radius_px = max(uni.params0.x, 1.0);
        let body_r = length(sphere_local);
        let feather_local = clamp(2.0 / radius_px, 0.0015, 0.12);
        let edge_alpha = 1.0 - smoothstep(1.0 - feather_local, 1.0, body_r);

        let uv = sphere_local * 0.5 + vec2<f32>(0.5, 0.5);
        let albedo = textureSample(albedo_tex, albedo_smp, uv);

        let z = sqrt(max(0.0, 1.0 - dot(sphere_local, sphere_local)));
        let n = normalize(vec3<f32>(sphere_local.x, sphere_local.y, z));

        // Phase → terminator direction. cos δ = 1 - 2·illum, φ flips on
        // waxing sign, l = (sin φ, 0, cos φ).
        let f_illum = clamp(uni.params0.y, 0.0, 1.0);
        let cos_delta = 1.0 - 2.0 * f_illum;
        let delta = acos(clamp(cos_delta, -1.0, 1.0));
        let waxing_sign = uni.params1.y;
        let phi = select(delta - PI, PI - delta, waxing_sign > 0.0);
        let l = normalize(vec3<f32>(sin(phi), 0.0, cos(phi)));
        let ndotl = dot(n, l);

        let term_mode = i32(uni.params2.x);
        let term_width = uni.params2.y;
        let term_bands = uni.params2.z;

        var lit_mask: f32;
        if (term_mode == 1) {
            lit_mask = smoothstep(-term_width, term_width, ndotl);
        } else if (term_mode == 2) {
            let smooth_lit = smoothstep(-term_width, term_width, ndotl);
            let raw = smooth_lit * term_bands;
            let f = fract(raw);
            let edge = clamp(term_width * term_bands, 0.01, 0.5);
            let soft_edge = smoothstep(0.0, edge, f);
            lit_mask = clamp((floor(raw) + soft_edge) / (term_bands - 1.0), 0.0, 1.0);
        } else {
            lit_mask = select(0.0, 1.0, ndotl >= 0.0);
        }

        let bright_b = uni.params0.z;
        let dark_b = uni.params0.w;
        let brightness = mix(dark_b, bright_b, lit_mask);
        planet_rgb = albedo.rgb * brightness;
        planet_alpha = edge_alpha;
    }

    // Composite. Rings are flat-shaded with a fixed brightness; body is
    // textured + lit. Front/back rule decides ring-vs-body z-order at the
    // fragment level.
    let ring_rgb = ring_color * RING_BRIGHTNESS;
    let ring_alpha_final = select(0.0, 1.0, on_ring);

    if (on_planet_body && on_ring) {
        if (ring_in_front) {
            let comp = ring_rgb * ring_alpha_final
                     + planet_rgb * planet_alpha * (1.0 - ring_alpha_final);
            let comp_a = ring_alpha_final
                       + planet_alpha * (1.0 - ring_alpha_final);
            return vec4<f32>(comp, comp_a);
        }
        return vec4<f32>(planet_rgb * planet_alpha, planet_alpha);
    }
    if (on_planet_body) {
        return vec4<f32>(planet_rgb * planet_alpha, planet_alpha);
    }
    return vec4<f32>(ring_rgb * ring_alpha_final, ring_alpha_final);
}
