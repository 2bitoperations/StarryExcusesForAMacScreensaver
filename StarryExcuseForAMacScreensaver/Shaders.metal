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

// Debug/diagnostic: compositor with per-draw tint multiplier (premultiplied-friendly)
fragment float4 TexturedQuadFragmentTinted(VertexOut in [[stage_in]],
                                           texture2d<float, access::sample> colorTex [[texture(0)]],
                                           constant float4 &tint [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge,
                        filter::linear,
                        coord::normalized);
    if (!colorTex.get_width()) {
        return float4(0,0,0,0);
    }
    float4 c = colorTex.sample(s, in.texCoord);
    // Multiply premultiplied RGBA by tint (tint expected in non-premul range 0..1)
    return c * tint;
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
        // Circle with a thin feather only at the rim
        float r = length(in.local); // 0 at center, 1 at edge
        if (r > 1.0) {
            discard_fragment();
        }
        // Feather the last ~2% of the radius. Inside that, alpha ~1.
        float a = 1.0 - smoothstep(0.98, 1.0, r);
        return float4(rgba.rgb * a, rgba.a * a);
    }
}

// MARK: - Decay (robust sampled implementation)

// Robust: sample source texture and multiply by keep; render into scratch target (no blending).
fragment float4 DecaySampledFragment(VertexOut in [[stage_in]],
                                     texture2d<float, access::sample> srcTex [[texture(0)]],
                                     constant float4 &keepColor [[buffer(0)]]) {
    constexpr sampler s(address::clamp_to_edge,
                        filter::nearest,
                        coord::normalized);
    if (!srcTex.get_width()) {
        return float4(0,0,0,0);
    }
    float4 c = srcTex.sample(s, in.texCoord);
    return c * keepColor;
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
    // Use nearest for crisp, blocky texture sampling
    constexpr sampler s(address::clamp_to_edge, filter::nearest, coord::normalized);

    // Circle mask in local [-1,1] (unit disk)
    float2 local = in.local;
    float r2 = dot(local, local);
    if (r2 > 1.0) {
        discard_fragment();
    }

    // One-pixel feather on the limb only (anti-aliased circumference).
    // Convert one screen pixel to local-units (1.0 local = radius).
    float radiusPx = max(uni.params0.x, 1.0);
    float r = sqrt(r2);
    float featherLocal = clamp(1.5f / radiusPx, 0.001f, 0.10f); // ~1.5px feather, clamped
    // Alpha is 1 inside, fades to 0 from r in [1-featherLocal, 1].
    float edgeAlpha = 1.0 - smoothstep(1.0 - featherLocal, 1.0, r);

    // Sphere normal from disk coordinates
    float z = sqrt(max(0.0, 1.0 - r2));
    float3 n = normalize(float3(local.x, local.y, z));

    // Phase mapping:
    // phase 0.0=new (-Z light), 0.5=full (+Z light), 1.0=new (-Z)
    float phase = uni.params0.y;
    float brightB = uni.params0.z;
    float darkB = uni.params0.w;
    float debugShowMask = uni.params1.x;

    float phi = PI * (1.0 - 2.0 * phase);
    float3 l = normalize(float3(sin(phi), 0.0, cos(phi)));

    // CRISP lit hemisphere (no feather).
    float ndotl = dot(n, l);
    float litMask = step(0.0, ndotl); // 0 on dark side, 1 on lit side

    // Sample blocky albedo
    float2 uv = local * 0.5 + 0.5;
    float albedo = 1.0;
    if (albedoTex.get_width() > 0) {
        float4 c = albedoTex.sample(s, uv);
        albedo = c.r;
    }

    if (debugShowMask > 0.0) {
        // Visualize illuminated region, solid red, with limb alpha only
        float a = edgeAlpha * 0.9;
        return float4(litMask * a, 0.0, 0.0, a);
    }

    // Per-pixel mix between dark and bright sides.
    float brightness = mix(darkB, brightB, litMask);
    float3 rgb = float3(albedo * brightness);

    // Premultiplied alpha output
    return float4(rgb * edgeAlpha, edgeAlpha);
}
