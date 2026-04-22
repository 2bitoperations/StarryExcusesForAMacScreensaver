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
                        mip_filter::linear,
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
    float2 halfSizePx;
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
    out.halfSizePx = inst.halfSizePx;
    out.colorPremul = inst.colorPremul;
    out.shape = inst.shape;
    return out;
}

fragment float4 SpriteFragment(SpriteVarying in [[stage_in]]) {
    float4 rgba = in.colorPremul;
    
    // Shape 0: filled rect
    if (in.shape == 0) {
        return rgba;
    }
    // Shape 1: circle (soft edge)
    else if (in.shape == 1) {
        float r = length(in.local);
        if (r > 1.0) {
            discard_fragment();
        }
        float a = 1.0 - smoothstep(0.98, 1.0, r);
        return float4(rgba.rgb * a, rgba.a * a);
    }
    // Shape 2: hollow rectangle outline (debug) with pixel-accurate 2 px stroke.
    else if (in.shape == 2) {
        // Convert local [-1,1] to pixel coordinates relative to center.
        float2 posPxLocal = in.local * in.halfSizePx;
        float2 distToEdgePx = in.halfSizePx - fabs(posPxLocal);   // distance to each edge
        // If outside (should not happen due to vertex), discard.
        if (distToEdgePx.x < 0.0 || distToEdgePx.y < 0.0) {
            discard_fragment();
        }
        float borderDistPx = min(distToEdgePx.x, distToEdgePx.y); // distance inward from nearest edge
        
        const float strokePx = 2.0;
        const float featherPx = 1.0;      // inner fade
        const float outerFeatherPx = 1.0; // outer edge AA
        
        // Reject pixels fully outside stroke band.
        if (borderDistPx > strokePx + featherPx) {
            discard_fragment();
        }
        
        // Base alpha = 1 inside stroke core.
        float a = 1.0;
        
        // Inner feather (fade to 0 as we go inward past strokePx)
        if (borderDistPx > strokePx) {
            float t = clamp((borderDistPx - strokePx) / featherPx, 0.0, 1.0);
            a *= (1.0 - t);
        }
        // Outer feather near exact edge (borderDistPx ~ 0)
        if (borderDistPx < outerFeatherPx) {
            float t2 = clamp(borderDistPx / outerFeatherPx, 0.0, 1.0);
            a *= t2;
        }
        if (a <= 0.0) {
            discard_fragment();
        }
        return float4(rgba.rgb * a, rgba.a * a);
    }
    
    // Unknown shape fallback: do not draw
    discard_fragment();
    // Provide a dummy return to satisfy the compiler's control-flow analysis.
    return float4(0.0);
}

// Moon shading uniforms:
// params0: (radiusPx, illuminatedFraction, brightBrightness, darkBrightness)
// params1: (debugShowMaskFlag, waxingSign(+1 / -1), unused, unused)
// params2: (terminatorMode, terminatorWidth, terminatorBands, unused)
//   terminatorMode: 0 = hard step (default), 1 = smooth, 2 = banded
//   terminatorWidth: half-width of the smooth transition zone (used by modes 1 & 2)
//   terminatorBands: number of discrete brightness bands (used by mode 2)
struct MoonUniforms {
    float2 viewportSize;
    float2 centerPx;
    float4 params0;
    float4 params1;
    float4 params2;
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
    constexpr sampler s(address::clamp_to_edge,
                        filter::linear,
                        mip_filter::linear,
                        coord::normalized);

    float2 local = in.local;
    float r2 = dot(local, local);
    if (r2 > 1.0) {
        discard_fragment();
    }

    float radiusPx = max(uni.params0.x, 1.0);
    float r = sqrt(r2);
    float featherLocal = clamp(2.0f / radiusPx, 0.0015f, 0.12f);
    float edgeAlpha = 1.0 - smoothstep(1.0 - featherLocal, 1.0, r);

    float z = sqrt(max(0.0, 1.0 - r2));
    float3 n = normalize(float3(local.x, local.y, z));

    float fIllum = clamp(uni.params0.y, 0.0, 1.0);
    float cosDelta = 1.0 - 2.0 * fIllum;
    float delta = acos(clamp(cosDelta, -1.0, 1.0));
    float waxingSign = uni.params1.y;
    float phi = (waxingSign > 0.0) ? (PI - delta) : (delta - PI);
    float3 l = normalize(float3(sin(phi), 0.0, cos(phi)));

    float ndotl = dot(n, l);

    // Terminator mode selection
    int termMode = int(uni.params2.x);
    float termWidth = uni.params2.y;
    float termBands = uni.params2.z;

    float litMask;
    if (termMode == 1) {
        // Smooth: gentle gradient across the terminator
        litMask = smoothstep(-termWidth, termWidth, ndotl);
    } else if (termMode == 2) {
        // Banded: quantized brightness steps with softened band edges
        float smooth = smoothstep(-termWidth, termWidth, ndotl);
        float raw = smooth * termBands;
        float f = fract(raw);
        float edge = clamp(termWidth * termBands, 0.01, 0.5);
        float softEdge = smoothstep(0.0, edge, f);
        litMask = clamp((floor(raw) + softEdge) / (termBands - 1.0), 0.0, 1.0);
    } else {
        // Hard (default): original binary step
        litMask = ndotl >= 0.0 ? 1.0 : 0.0;
    }

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

struct PlanetUniforms {
    float2 viewportSize;
    float2 centerPx;
    float4 params0;  // x=radiusPx, y=phaseFraction, z=brightBrightness, w=darkBrightness
    float4 params1;  // x=ringTiltDeg, y=waxingSign, z=unused, w=unused
    float4 params2;  // x=terminatorMode, y=terminatorWidth, z=terminatorBands, w=textureAspect
};

struct PlanetVarying {
    float4 position [[position]];
    float2 local;
};

vertex PlanetVarying PlanetVertex(uint vid [[vertex_id]],
                                  constant PlanetUniforms &uni [[buffer(2)]]) {
    PlanetVarying out;
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
    float aspect = max(uni.params2.w, 1.0);
    float2 offsetPx = float2(local.x * radiusPx * aspect, local.y * radiusPx);
    float2 posPx = uni.centerPx + offsetPx;
    float2 ndc = float2((posPx.x / uni.viewportSize.x) * 2.0 - 1.0,
                        (posPx.y / uni.viewportSize.y) * 2.0 - 1.0);
    out.position = float4(ndc, 0, 1);
    out.local = local;
    return out;
}

fragment float4 PlanetFragment(PlanetVarying in [[stage_in]],
                               constant PlanetUniforms &uni [[buffer(2)]],
                               texture2d<float, access::sample> albedoTex [[texture(0)]]) {
    constexpr sampler s(address::clamp_to_edge,
                        filter::nearest,
                        coord::normalized);

    float2 local = in.local;
    float aspect = max(uni.params2.w, 1.0);
    bool isSaturn = aspect > 1.0;

    // Keep the non-Saturn path unchanged.
    if (!isSaturn) {
        float2 sphereLocal = local;
        float r2 = dot(sphereLocal, sphereLocal);

        float radiusPx = max(uni.params0.x, 1.0);
        float r = sqrt(r2);
        float featherLocal = clamp(2.0f / radiusPx, 0.0015f, 0.12f);

        float2 uv = local * 0.5 + 0.5;
        float4 albedo = float4(0.5, 0.4, 0.3, 1.0);
        if (albedoTex.get_width() > 0) {
            albedo = albedoTex.sample(s, uv);
        }

        if (r2 > 1.0) {
            discard_fragment();
        }
        float edgeAlpha = 1.0 - smoothstep(1.0 - featherLocal, 1.0, r);

        float z = sqrt(max(0.0, 1.0 - r2));
        float3 n = normalize(float3(sphereLocal.x, sphereLocal.y, z));

        float fIllum = clamp(uni.params0.y, 0.0, 1.0);
        float cosDelta = 1.0 - 2.0 * fIllum;
        float delta = acos(clamp(cosDelta, -1.0, 1.0));
        float waxingSign = uni.params1.y;
        float phi = (waxingSign > 0.0) ? (PI - delta) : (delta - PI);
        float3 l = normalize(float3(sin(phi), 0.0, cos(phi)));
        float ndotl = dot(n, l);

        int termMode = int(uni.params2.x);
        float termWidth = uni.params2.y;
        float termBands = uni.params2.z;

        float litMask;
        if (termMode == 1) {
            litMask = smoothstep(-termWidth, termWidth, ndotl);
        } else if (termMode == 2) {
            float smooth = smoothstep(-termWidth, termWidth, ndotl);
            float raw = smooth * termBands;
            float f = fract(raw);
            float edge = clamp(termWidth * termBands, 0.01, 0.5);
            float softEdge = smoothstep(0.0, edge, f);
            litMask = clamp((floor(raw) + softEdge) / (termBands - 1.0), 0.0, 1.0);
        } else {
            litMask = ndotl >= 0.0 ? 1.0 : 0.0;
        }

        float brightB = uni.params0.z;
        float darkB = uni.params0.w;
        float brightness = mix(darkB, brightB, litMask);
        float3 rgb = albedo.rgb * brightness;
        return float4(rgb * edgeAlpha, edgeAlpha);
    }

    // Saturn path: geometric rings + textured planet body.
    // in.local is [-1,+1], but PlanetVertex stretches X by `aspect` in screen pixels,
    // so convert to a screen-isotropic space before circular/elliptical tests.
    float2 screenP = float2(local.x * aspect, local.y);

    // Body radius from Saturn texture authoring: rBody=0.423 in UV-space,
    // therefore 0.846 in local [-1,+1] Y units.
    constexpr float saturnBodyRadius = 0.846f;
    float2 sphereLocal = screenP / saturnBodyRadius;
    float bodyDistSq = dot(screenP, screenP);
    bool onPlanetBody = bodyDistSq <= saturnBodyRadius * saturnBodyRadius;

    // Ring annulus in ring-plane units.
    constexpr float ringInner = 1.1f * saturnBodyRadius;
    constexpr float ringOuter = 2.3f * saturnBodyRadius;

    float axialTiltRad = uni.params1.x * (PI / 180.0f);
    float ringRotationRad = uni.params1.z * (PI / 180.0f);
    float sinTilt = sin(axialTiltRad);

    bool onRing = false;
    bool ringInFront = false;
    float3 ringColor = float3(0.0);

    // Edge-on guard: projected ring thickness is sub-pixel near zero opening.
    if (abs(sinTilt) >= 0.01f) {
        // Rotate by -ringRotation so ring major axis aligns with X in this frame.
        float cRot = cos(ringRotationRad);
        float sRot = sin(ringRotationRad);
        float2 rp = float2(screenP.x * cRot + screenP.y * sRot,
                           -screenP.x * sRot + screenP.y * cRot);

        // Undo foreshortening: divide minor axis by sin(tilt) to recover ring-plane radius.
        float2 ringPlane = float2(rp.x, rp.y / sinTilt);
        float ringR = length(ringPlane);

        if (ringR >= ringInner && ringR <= ringOuter) {
            float ringSpan = ringOuter - ringInner;
            float cassiniCenter = ringInner + ringSpan * 0.60f;
            float cassiniHalfWidth = ringSpan * 0.03f;
            float cassiniStart = cassiniCenter - cassiniHalfWidth;
            float cassiniEnd = cassiniCenter + cassiniHalfWidth;

            // B ring (inner), Cassini division (transparent), A ring (outer).
            if (ringR < cassiniStart) {
                ringColor = float3(0.88f, 0.80f, 0.62f);
                onRing = true;
            } else if (ringR > cassiniEnd) {
                ringColor = float3(0.74f, 0.67f, 0.52f);
                onRing = true;
            }

            // Sign rule from design: front if rp.y * sin(tilt) < 0.
            ringInFront = (rp.y * sinTilt) < 0.0f;
        }
    }

    if (!onPlanetBody && !onRing) {
        discard_fragment();
    }

    // Planet body keeps existing texture sampling + existing phase/terminator logic.
    float3 planetRGB = float3(0.0);
    float planetAlpha = 0.0;
    if (onPlanetBody) {
        float radiusPx = max(uni.params0.x, 1.0);
        float bodyR = length(sphereLocal);
        float featherLocal = clamp(2.0f / radiusPx, 0.0015f, 0.12f);
        float edgeAlpha = 1.0 - smoothstep(1.0 - featherLocal, 1.0, bodyR);

        float2 uv = local * 0.5 + 0.5;
        float4 albedo = float4(0.5, 0.4, 0.3, 1.0);
        if (albedoTex.get_width() > 0) {
            albedo = albedoTex.sample(s, uv);
        }

        float z = sqrt(max(0.0, 1.0 - dot(sphereLocal, sphereLocal)));
        float3 n = normalize(float3(sphereLocal.x, sphereLocal.y, z));

        float fIllum = clamp(uni.params0.y, 0.0, 1.0);
        float cosDelta = 1.0 - 2.0 * fIllum;
        float delta = acos(clamp(cosDelta, -1.0, 1.0));
        float waxingSign = uni.params1.y;
        float phi = (waxingSign > 0.0) ? (PI - delta) : (delta - PI);
        float3 l = normalize(float3(sin(phi), 0.0, cos(phi)));
        float ndotl = dot(n, l);

        int termMode = int(uni.params2.x);
        float termWidth = uni.params2.y;
        float termBands = uni.params2.z;

        float litMask;
        if (termMode == 1) {
            litMask = smoothstep(-termWidth, termWidth, ndotl);
        } else if (termMode == 2) {
            float smooth = smoothstep(-termWidth, termWidth, ndotl);
            float raw = smooth * termBands;
            float f = fract(raw);
            float edge = clamp(termWidth * termBands, 0.01, 0.5);
            float softEdge = smoothstep(0.0, edge, f);
            litMask = clamp((floor(raw) + softEdge) / (termBands - 1.0), 0.0, 1.0);
        } else {
            litMask = ndotl >= 0.0 ? 1.0 : 0.0;
        }

        float brightB = uni.params0.z;
        float darkB = uni.params0.w;
        float brightness = mix(darkB, brightB, litMask);
        planetRGB = albedo.rgb * brightness;
        planetAlpha = edgeAlpha;
    }

    // Rings are intentionally flat-shaded (simple retro look).
    float ringBrightness = 0.92f;
    float3 ringRGB = ringColor * ringBrightness;

    if (onPlanetBody && onRing) {
        if (ringInFront) {
            return float4(ringRGB, 1.0);
        }
        return float4(planetRGB * planetAlpha, planetAlpha);
    }
    if (onPlanetBody) {
        return float4(planetRGB * planetAlpha, planetAlpha);
    }
    return float4(ringRGB, 1.0);
}
