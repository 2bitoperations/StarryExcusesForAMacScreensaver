#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct QuadVertex {
    float2 position;
    float2 texCoord;
};

vertex VertexOut TexturedQuadVertex(uint vid [[vertex_id]],
                                    const device QuadVertex *verts [[buffer(0)]]) {
    VertexOut out;
    QuadVertex v = verts[vid];
    out.position = float4(v.position, 0.0, 1.0);
    out.texCoord = v.texCoord;
    return out;
}

fragment float4 TexturedQuadFragment(VertexOut in [[stage_in]],
                                     texture2d<float, access::sample> colorTex [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge,
                        filter::linear,
                        coord::normalized);
    if (!colorTex.get_width()) {
        return float4(0,0,0,0);
    }
    float4 c = colorTex.sample(s, in.texCoord);
    return c; // premultiplied alpha content already
}
