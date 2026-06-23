// Debug overlay shader.
//
// Renders instanced screen-space quads textured from a 5×7 glyph atlas with
// a per-instance tint. The same pipeline draws both text glyphs and the
// dark background rectangles behind them — rects emit a code-127 (DEL)
// instance scaled to the rect's dimensions, since `font.rs` reserves DEL
// as a 5×7 solid-1s block. No shader branching needed.
//
// Coordinate convention: per-instance `position` is in TOP-DOWN screen
// pixels (y=0 is the top edge) so layout math in `debug_overlay.rs` ports
// 1:1 from Swift `DebugLayerRenderer.swift`. The vertex stage flips Y when
// mapping to bottom-up NDC.

struct Viewport {
    size: vec2<f32>,
};

@group(0) @binding(0) var<uniform> viewport: Viewport;
@group(0) @binding(1) var atlas: texture_2d<f32>;
@group(0) @binding(2) var atlas_sampler: sampler;

const ATLAS_WIDTH_PX: f32 = 640.0;
const GLYPH_WIDTH_PX: f32 = 5.0;
const UV_SPAN: vec2<f32> = vec2<f32>(GLYPH_WIDTH_PX / ATLAS_WIDTH_PX, 1.0);

struct VertexOut {
    @builtin(position) clip_position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) tint: vec4<f32>,
};

@vertex
fn vs_main(
    @builtin(vertex_index) vertex_index: u32,
    @location(0) inst_position: vec2<f32>,
    @location(1) inst_size:     vec2<f32>,
    @location(2) inst_uv_min:   vec2<f32>,
    @location(3) inst_tint:     vec4<f32>,
) -> VertexOut {
    // 4-vertex TriangleStrip, indices map to quad corners:
    //   0 -> TL (0,0), 1 -> TR (1,0), 2 -> BL (0,1), 3 -> BR (1,1)
    // corner.y=0 means top of quad, corner.y=1 means bottom (top-down).
    let corner = vec2<f32>(
        f32(vertex_index & 1u),
        f32((vertex_index >> 1u) & 1u),
    );

    let world_px = inst_position + corner * inst_size;

    // Top-down pixel -> top-down NDC. Y is flipped relative to sprite.wgsl
    // because debug overlays are positioned from the top of the screen.
    let ndc = vec2<f32>(
        (world_px.x / viewport.size.x) * 2.0 - 1.0,
        1.0 - (world_px.y / viewport.size.y) * 2.0,
    );

    var out: VertexOut;
    out.clip_position = vec4<f32>(ndc, 0.0, 1.0);
    out.uv = inst_uv_min + corner * UV_SPAN;
    out.tint = inst_tint;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    // R8 atlas: 1.0 = lit pixel, 0.0 = blank. Coverage * tint with tint
    // pre-premultiplied by the caller, output pre-multiplied alpha to pair
    // with the composite pass's PREMULTIPLIED_ALPHA_BLENDING blend state.
    let coverage = textureSample(atlas, atlas_sampler, in.uv).r;
    return in.tint * coverage;
}
