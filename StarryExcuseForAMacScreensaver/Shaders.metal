#include <metal_stdlib>
using namespace metal;

#define PI 3.14159265358979323846f

// MARK: - Textured quad (compositor)

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

// MARK: - Instanced sprites (rect or circle)

struct SpriteInstanceIn {
    float2 centerPx;
    float2 halfSizePx;
    float4 colorPremul; // EXPECTS premultiplied RGBA
    uint   shape; // 0=rect, 1=circle
};

struct SpriteUniforms {
    float2 viewportSize;
};

struct SpriteVarying {
    float4 position [[position]];
    float2 local;      // in [-1,1] quad space
    float4 colorPremul;
    uint   shape;
};

vertex SpriteVarying SpriteVertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  const device SpriteInstanceIn *instances [[buffer(1)]],
                                  constant SpriteUniforms &uni [[buffer(2)]]) {
    SpriteVarying out;
    // Two triangles making a quad
    const float2 corners[6] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2(-1.0,  1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };
    float2 local = corners[vid];               // [-1,1]
    SpriteInstanceIn inst = instances[iid];
    
    float2 offsetPx = local * inst.halfSizePx; // px
    float2 posPx = inst.centerPx + offsetPx;   // px position
    float2 ndc = float2((posPx.x / uni.viewportSize.x) * 2.0 - 1.0,
                        (posPx.y / uni.viewportSize.y) * 2.0 - 1.0);
    
    out.position = float4(ndc, 0, 1);
    out.local = local;
    out.colorPremul = inst.colorPremul; // premultiplied RGBA
    out.shape = inst.shape;
    return out;
}

fragment float4 SpriteFragment(SpriteVarying in [[stage_in]]) {
    // colorPremul is premultiplied RGBA
    float4 rgba = in.colorPremul;

    if (in.shape == 0) {
        // Rect
        return rgba;
    } else {
        // Circle with soft edge
        float r2 = dot(in.local, in.local); // local is in [-1,1] so radius=1
        if (r2 > 1.0) {
            discard_fragment();
        }
        // Smooth edge for anti-alias; ensure edge0 < edge1
        float edge = smoothstep(0.9, 1.0, 1.0 - r2);
        return float4(rgba.rgb * edge, rgba.a * edge);
    }
}

// MARK: - Decay (fade trails): uses blending to multiply dest by constant

// Vertex: reuse the textured-quad unit, but we don't need a texture.
// Fragment returns zero; pipeline blending must be configured to:
// src = 0, dst = blendColor (constant). See pipeline setup in Swift.
fragment float4 DecayFragment() {
    return float4(0,0,0,0);
}

// MARK: - Moon shading
// Use 16-byte-friendly packing for constant buffer to match Swift/Metal layouts.

struct MoonUniforms {
    float2 viewportSize;   // in points/pixels (consistent with centerPx/radiusPx units)
    float2 centerPx;       // center in same units as viewportSize
    float4 params0;        // x=radiusPx, y=phase, z=brightBrightness, w=darkBrightness
    float4 params1;        // x=debugShowMask, y/z/w padding
};

struct MoonVarying {
    float4 position [[position]];
    float2 local; // [-1,1] quad coords (x,y)
};

vertex MoonVarying MoonVertex(uint vid [[vertex_id]],
                              constant MoonUniforms &uni [[buffer(2)]]) {
    MoonVarying out;
    const float2 corners[6] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2(-1.0,  1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };
    float2 local = corners[vid]; // [-1,1]
    float radiusPx = uni.params0.x;
    float2 offsetPx = local * radiusPx;
    float2 posPx = uni.centerPx + offsetPx;
    float2 ndc = float2((posPx.x / uni.viewportSize.x) * 2.0 - 1.0,
                        (posPx.y / uni.viewportSize.y) * 2.0 - 1.0);
    out.position = float4(ndc, 0, 1);
    out.local = local;
    return out;
}

// Sample albedo as R8 (if bound as r8Unorm) or use red channel from other formats.
fragment float4 MoonFragment(MoonVarying in [[stage_in]],
                             constant MoonUniforms &uni [[buffer(2)]],
                             texture2d<float, access::sample> albedoTex [[texture(0)]]) {
    // Use nearest for crisp edges/details in mask/texture
    constexpr sampler s(address::clamp_to_edge, filter::nearest, coord::normalized);
    float r2 = dot(in.local, in.local);
    if (r2 > 1.0) {
        discard_fragment();
    }
    // Reconstruct sphere normal from disk coordinates
    float z = sqrt(max(0.0, 1.0 - r2));
    float3 n = normalize(float3(in.local.x, in.local.y, z));
    
    // Phase mapping:
    // phase 0.0=new (light from -Z), 0.5=full (light from +Z), 1.0=new (-Z again)
    float phase = uni.params0.y;
    float brightB = uni.params0.z;
    float darkB = uni.params0.w;
    float debugShowMask = uni.params1.x;
    
    float phi = PI * (1.0 - 2.0 * phase);
    float3 l = normalize(float3(sin(phi), 0.0, cos(phi)));
    
    // Compute a crisp lit-hemisphere mask with a small feather around the terminator.
    float ndotl = dot(n, l);
    const float terminatorFeather = 0.01; // tweak for desired sharpness
    float litMask = smoothstep(-terminatorFeather, terminatorFeather, ndotl); // ~0 on dark side, ~1 on lit side
    
    // Map local [-1,1] -> [0,1] for texture sample
    float2 uv = in.local * 0.5 + 0.5;
    float albedo = 1.0;
    if (albedoTex.get_width() > 0) {
        float4 c = albedoTex.sample(s, uv);
        albedo = c.r;
    }
    // Limb softening (edge anti-alias) — keep it tight to avoid overall fuzziness
    float edge = smoothstep(0.995, 1.0, 1.0 - r2);
    
    if (debugShowMask > 0.0) {
        // Visualize the lit hemisphere mask (crisp crescent), modulated only by limb edge alpha
        float a = edge;
        return float4(litMask * a, 0.0, 0.0, a);
    }
    
    // Uniform brightness on lit vs. unlit sides (use albedo for detail if provided)
    float brightness = mix(darkB, brightB, litMask);
    float3 rgb = float3(albedo * brightness);
    return float4(rgb * edge, edge); // premultiplied alpha
}
