// Composite shader: copies the persistent skyline texture into the
// swapchain via a single fullscreen triangle. No sampler is bound —
// `textureLoad` does an exact 1:1 nearest-neighbor fetch, which is what
// we want since skyline_tex is always sized to match the output target.

@group(0) @binding(0) var skyline_tex: texture_2d<f32>;

struct VsOut {
    @builtin(position) clip_position: vec4<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> VsOut {
    // Classic fullscreen-triangle trick: 3 verts at (-1,-1), (3,-1), (-1,3).
    // The triangle covers all of NDC [-1,1]² (the bits outside get clipped)
    // with no diagonal seam — strictly better than two-triangle quad here.
    //   vi = 0 -> ( (0<<1)&2 , 0&2 ) -> (0,0) -> (-1,-1)
    //   vi = 1 -> ( (1<<1)&2 , 1&2 ) -> (2,0) -> ( 3,-1)
    //   vi = 2 -> ( (2<<1)&2 , 2&2 ) -> (0,2) -> (-1, 3)
    let x = f32((vi << 1u) & 2u) * 2.0 - 1.0;
    let y = f32(vi & 2u) * 2.0 - 1.0;
    var out: VsOut;
    out.clip_position = vec4<f32>(x, y, 0.0, 1.0);
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    // clip_position in fragment stage is window-space pixel coordinates
    // (top-left origin, y-down — the GPU hardware convention). skyline_tex
    // texels use the same convention, so direct integer fetch works without
    // any Y-flip wrangling, even though our sprite layer logically thinks
    // in Y-up world coords.
    let p = vec2<i32>(in.clip_position.xy);
    return textureLoad(skyline_tex, p, 0);
}
