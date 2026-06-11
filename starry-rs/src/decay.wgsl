// Decay shader: exponentially fade a source texture by multiplying every
// texel by a per-frame `keep` scalar. Used to draw trails for shooting
// stars and satellites — caller computes keep = 0.5^(dt/halfLife) so each
// layer has a frame-rate-independent half-life. One fullscreen-triangle
// pass per ping-pong cycle: reads `src_tex`, writes the bound color
// attachment. Sprites for the current frame are drawn additively over
// that attachment by the layer's `SpriteRenderer`.

struct DecayUniforms {
    keep: f32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
};

@group(0) @binding(0) var src_tex: texture_2d<f32>;
@group(0) @binding(1) var<uniform> u: DecayUniforms;

struct VsOut {
    @builtin(position) clip_position: vec4<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32) -> VsOut {
    // Same fullscreen-triangle trick as composite.wgsl. See that file for
    // the index-to-NDC derivation.
    let x = f32((vi << 1u) & 2u) * 2.0 - 1.0;
    let y = f32(vi & 2u) * 2.0 - 1.0;
    var out: VsOut;
    out.clip_position = vec4<f32>(x, y, 0.0, 1.0);
    return out;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    // Same convention as composite.wgsl: window-space pixel coords map 1:1
    // to the source texture since src and dst are always the same size.
    // Premultiplied-alpha sprites are preserved correctly: scaling rgba by
    // `keep` uniformly keeps the perceived color and just fades visibility.
    let p = vec2<i32>(in.clip_position.xy);
    let s = textureLoad(src_tex, p, 0);
    return s * u.keep;
}
