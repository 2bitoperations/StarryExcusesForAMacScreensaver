// Sprite shader for starry-rs.
//
// Renders instanced unit-quads (in [-0.5, 0.5] local space) as solid round
// dots in screen pixels. The vertex stage maps pixel coordinates to clip
// space using the viewport size; the fragment stage applies a smooth round
// alpha falloff so sprites read as discs rather than aliased squares.

struct Viewport {
    size: vec2<f32>,
};

@group(0) @binding(0) var<uniform> viewport: Viewport;

struct VertexOut {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) local: vec2<f32>,
};

@vertex
fn vs_main(
    @location(0) quad_pos:      vec2<f32>,
    @location(1) inst_position: vec2<f32>,
    @location(2) inst_size:     f32,
    @location(3) inst_color:    vec4<f32>,
) -> VertexOut {
    let world_px = inst_position + quad_pos * inst_size;

    // Top-left origin in pixels -> NDC with Y flipped so (0,0) is the
    // top-left of the framebuffer (matching the Swift renderer's convention).
    let ndc = vec2<f32>(
        (world_px.x / viewport.size.x) * 2.0 - 1.0,
        1.0 - (world_px.y / viewport.size.y) * 2.0,
    );

    var out: VertexOut;
    out.clip_position = vec4<f32>(ndc, 0.0, 1.0);
    out.color = inst_color;
    out.local = quad_pos;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    // Round-disc falloff: opaque to ~80% of radius, then smoothly to 0 at
    // the quad edge. Keeps tiny (1-2px) sprites looking like dots, not
    // visible squares.
    let dist = length(in.local);
    let alpha = 1.0 - smoothstep(0.4, 0.5, dist);

    // Premultiplied alpha out -- pairs with the One / OneMinusSrcAlpha blend
    // state configured on the pipeline.
    return vec4<f32>(in.color.rgb * alpha, in.color.a * alpha);
}
