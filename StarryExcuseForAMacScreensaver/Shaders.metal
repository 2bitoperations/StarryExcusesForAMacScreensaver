#include <metal_stdlib>
using namespace metal;

#define PI 3.14159265358979323846f

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
    return c * tint;
}

fragment float4 SolidBlackFragment(VertexOut in [[stage_in]]) {
    return float4(0.0);
}

struct SpriteInstanceIn {
    float2 centerPx;
    float2 halfSizePx;
    float4 colorPremul;
    uint   shape;
};

struct SpriteUniforms {
    float2 viewportSize;
};

struct SpriteVarying {
    float4 position [[position]];
    float2 local;
    float4 colorPremul;
    uint   shape;
};

vertex SpriteVarying SpriteVertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  const device SpriteInstanceIn *instances [[buffer(1)]],
                                  constant SpriteUniforms &uni [[buffer(2)]]) {
    SpriteVarying out;
    const float2 corners[6] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2(-1.0,  1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };
    float2 local = corners[vid];
    SpriteInstanceIn inst = instances[iid];
    
    float2 offsetPx = local * inst.halfSizePx;
    float2 posPx = inst.centerPx + offsetPx;
    float2 ndc = float2((posPx.x / uni.viewportSize.x) * 2.0 - 1.0,
                        (posPx.y / uni.viewportSize.y) * 2.0 - 1.0);
    
    out.position = float4(ndc, 0, 1);
    out.local = local;
    out.colorPremul = inst.colorPremul;
    out.shape = inst.shape;
    return out;
}

fragment float4 SpriteFragment(SpriteVarying in [[stage_in]]) {
    float4 rgba = in.colorPremul;
    if (in.shape == 0) {
        return rgba;
    } else {
        float r = length(in.local);
        if (r > 1.0) {
            discard_fragment();
        }
        float a = 1.0 - smoothstep(0.98, 1.0, r);
        return float4(rgba.rgb * a, rgba.a * a);
    }
}

// Moon shading uniforms:
// params0: (radiusPx, illuminatedFraction, brightBrightness, darkBrightness)
// params1: (debugShowMaskFlag, waxingSign(+1 / -1), unused, unused)
struct MoonUniforms {
    float2 viewportSize;
    float2 centerPx;
    float4 params0;
    float4 params1;
};

struct MoonVarying {
    float4 position [[position]];
    float2 local;
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
    float2 local = corners[vid];
    float radiusPx = uni.params0.x;
    float2 offsetPx = local * radiusPx;
    float2 posPx = uni.centerPx + offsetPx;
    float2 ndc = float2((posPx.x / uni.viewportSize.x) * 2.0 - 1.0,
                        (posPx.y / uni.viewportSize.y) * 2.0 - 1.0);
    out.position = float4(ndc, 0, 1);
    out.local = local;
    return out;
}

fragment float4 MoonFragment(MoonVarying in [[stage_in]],
                             constant MoonUniforms &uni [[buffer(2)]],
                             texture2d<float, access::sample> albedoTex [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge, filter::nearest, coord::normalized);

    float2 local = in.local;
    float r2 = dot(local, local);
    if (r2 > 1.0) {
        discard_fragment();
    }

    float radiusPx = max(uni.params0.x, 1.0);
    float r = sqrt(r2);
    float featherLocal = clamp(1.5f / radiusPx, 0.001f, 0.10f);
    float edgeAlpha = 1.0 - smoothstep(1.0 - featherLocal, 1.0, r);

    float z = sqrt(max(0.0, 1.0 - r2));
    float3 n = normalize(float3(local.x, local.y, z));

    float fIllum = clamp(uni.params0.y, 0.0, 1.0);          // illuminated fraction
    float cosDelta = 1.0 - 2.0 * fIllum;                    // cos(delta), delta in [0, PI]
    float delta = acos(clamp(cosDelta, -1.0, 1.0));         // 0=new .. PI=full
    float waxingSign = uni.params1.y;                       // +1 (waxing) / -1 (waning)
    float phi = (waxingSign > 0.0) ? (PI - delta) : (delta - PI);
    float3 l = normalize(float3(sin(phi), 0.0, cos(phi)));

    float ndotl = dot(n, l);
    float litMask = ndotl >= 0.0 ? 1.0 : 0.0;

    float debugShowMask = uni.params1.x;

    float2 uv = local * 0.5 + 0.5;
    float albedo = 1.0;
    if (albedoTex.get_width() > 0) {
        albedo = albedoTex.sample(s, uv).r;
    }

    if (debugShowMask > 0.0) {
        float a = edgeAlpha * 0.9;
        return float4(litMask * a, 0.0, 0.0, a);
    }

    float brightB = uni.params0.z;
    float darkB = uni.params0.w;
    float brightness = mix(darkB, brightB, litMask);
    float3 rgb = float3(albedo * brightness);

    return float4(rgb * edgeAlpha, edgeAlpha);
}
