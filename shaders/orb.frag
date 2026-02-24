// CLOAK orb fragment shader — faithful port of index.html Two-Pass rendering.
//
// index.html architecture:
//   Pass 1: Ring in bloomScene → EffectComposer with UnrealBloomPass → golden glow
//   Pass 2: Sphere in sphereScene → rendered ON TOP with NO bloom
//   Result: Dark sphere occludes bloom center; bloom peeks around sphere edges
//
// This shader replicates that by computing ring+bloom and sphere independently,
// then compositing sphere over ring+bloom with alpha-over blending.

#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform float uReveal;

out vec4 fragColor;

// ── SDFs ──────────────────────────────────────────────────────────────

// Torus in XY plane (matches Three.js TorusGeometry default orientation)
float sdTorus(vec3 p, float R, float r) {
    vec2 q = vec2(length(p.xy) - R, p.z);
    return length(q) - r;
}

vec3 torusNorm(vec3 p, float R) {
    float l = length(p.xy);
    vec3 c = vec3(p.x * R / max(l, 0.0001), p.y * R / max(l, 0.0001), 0.0);
    return normalize(p - c);
}

// ── Axis rotations ───────────────────────────────────────────────────

vec3 rX(vec3 p, float a) { float c=cos(a),s=sin(a); return vec3(p.x, c*p.y-s*p.z, s*p.y+c*p.z); }
vec3 rY(vec3 p, float a) { float c=cos(a),s=sin(a); return vec3(c*p.x+s*p.z, p.y, -s*p.x+c*p.z); }
vec3 rZ(vec3 p, float a) { float c=cos(a),s=sin(a); return vec3(c*p.x-s*p.y, s*p.x+c*p.y, p.z); }

// ── ACES Filmic tonemapping (matches Three.js ACESFilmicToneMapping) ─
vec3 aces(vec3 x) {
    return (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
}

// ── Main ─────────────────────────────────────────────────────────────

void main() {
    vec2 fc = FlutterFragCoord().xy;
    vec2 uv = (fc - uSize * 0.5) / min(uSize.x, uSize.y);
    uv.y = -uv.y; // Flutter Y-down → camera Y-up

    // Smoothstep reveal (matches index.html: t/4 smoothstep)
    float rv = clamp(uReveal, 0.0, 1.0);
    float reveal = rv * rv * (3.0 - 2.0 * rv);

    // Camera (matches index.html: PerspectiveCamera(40°), pos(0, 0.1, 6))
    float fl = 1.0 / tan(radians(20.0));
    vec3 ro = vec3(
        sin(uTime * 0.05) * 0.08,
        0.1 + sin(uTime * 0.08) * 0.03,
        6.0
    );
    vec3 fwd = normalize(-ro);
    vec3 rt = normalize(cross(fwd, vec3(0.0, 1.0, 0.0)));
    vec3 up = cross(rt, fwd);
    vec3 rd = normalize(fwd * fl + rt * uv.x + up * uv.y);

    // Rotation (matches index.html: group rx/ry + ring rz)
    float ax = sin(uTime * 0.25) * 0.025;
    float ay = sin(uTime * 0.18) * 0.03;
    float az = uTime * 0.04;

    // ═══════════════════════════════════════════════════════════════
    // PASS 1: Ring + Bloom  (bloomScene → EffectComposer)
    // Ring is rendered with bloom. Bloom creates the golden aura.
    // ═══════════════════════════════════════════════════════════════

    float t = 0.0;
    float mrd = 100.0; // min distance to ring (drives bloom)
    vec3 ringCol = vec3(0.0);
    float ringA = 0.0;

    for (int i = 0; i < 48; i++) {
        vec3 p = ro + rd * t;
        vec3 pr = rZ(rX(rY(p, -ay), -ax), -az); // inverse of group*ring rotation

        float dr = sdTorus(pr, 1.18, 0.045);
        mrd = min(mrd, dr);

        if (dr < 0.001) {
            // Ring shading (exact copy of index.html ringMaterial)
            vec3 n = torusNorm(pr, 1.18);
            // Transform normal back to world space
            n = rZ(rX(rY(n, ay), ax), az);

            vec3 vd = normalize(ro - p);
            float facing = abs(dot(n, vd));

            float dist = length(pr.xy);
            float outerFactor = smoothstep(1.135, 1.225, dist);
            float outerFade = mix(1.0, pow(facing, 1.5), outerFactor);
            float core = pow(facing, 3.5);

            vec3 ec = vec3(0.8, 0.35, 0.0);
            vec3 hc = vec3(1.0, 0.65, 0.08);
            ringCol = mix(ec * 0.5, hc, core);
            ringA = pow(facing, 2.5) * 0.85 * outerFade;
            break;
        }
        t += dr;
        if (t > 12.0) break;
    }

    // Multi-scale bloom (approximating UnrealBloomPass: strength=1.3, radius=1.5)
    // Cascaded Gaussians from very wide/subtle to tight/bright
    float bs = (1.3 + sin(uTime * 0.8) * 0.12) * reveal;
    float b1 = exp(-mrd * 0.8) * 0.12;  // very wide, subtle aura
    float b2 = exp(-mrd * 2.0) * 0.25;  // medium spread
    float b3 = exp(-mrd * 5.0) * 0.45;  // tight glow
    float b4 = exp(-mrd * 14.0) * 0.7;  // bright core near ring
    float bloom = (b1 + b2 + b3 + b4) * bs;

    // Ring layer = ring + bloom
    vec3 bloomColor = vec3(1.0, 0.65, 0.08);
    vec3 layer1 = ringCol + bloomColor * bloom;
    float layer1A = max(ringA, min(bloom, 1.0));

    // Apply exposure + tonemapping to ring layer
    layer1 *= reveal;
    layer1 = aces(layer1);
    layer1A *= reveal;

    // ═══════════════════════════════════════════════════════════════
    // PASS 2: Sphere ON TOP  (sphereScene, rendered AFTER bloom)
    // Sphere has NO bloom — blocks glow from bleeding onto it.
    // Sphere edges are transparent (rim alpha), so bloom peeks around.
    // ═══════════════════════════════════════════════════════════════

    vec3 layer2 = vec3(0.0);
    float layer2A = 0.0;

    // Analytical ray-sphere intersection (faster than SDF march)
    float sb = dot(ro, rd);
    float sc = dot(ro, ro) - 1.05 * 1.05;
    float sDisc = sb * sb - sc;

    if (sDisc > 0.0) {
        float sT = -sb - sqrt(sDisc);
        if (sT > 0.0) {
            vec3 hp = ro + rd * sT;
            // Apply same subtle tilt as ring group (sphere group has same rotation)
            vec3 n = normalize(hp);
            vec3 vd = normalize(ro - hp);
            float NdV = max(dot(vd, n), 0.0);

            // Sphere shading (exact copy of index.html sphereMaterial)
            vec3 bc = vec3(0.005);
            vec3 ld = normalize(vec3(-0.1, 1.0, 0.6));
            float sd = max(dot(reflect(-ld, n), vd), 0.0);

            bc += vec3(0.04, 0.038, 0.033) * pow(sd, 3.0);   // wide marble sheen
            bc += vec3(0.08, 0.075, 0.06) * pow(sd, 8.0);    // medium glossy zone
            bc += vec3(0.25, 0.24, 0.19) * pow(sd, 25.0);    // glossy core
            bc += vec3(0.25) * pow(sd, 80.0);                  // bright peak

            float rim = 1.0 - NdV;
            bc += vec3(0.03, 0.028, 0.025) * pow(rim, 2.5);  // rim glow

            // Soft edge alpha (transparent at edges, opaque at center)
            layer2A = smoothstep(1.0, 0.4, rim) * reveal;

            // Apply exposure + tonemapping to sphere layer (no bloom!)
            layer2 = bc * reveal;
            layer2 = aces(layer2);
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // COMPOSITE: Sphere (layer 2) over Ring+Bloom (layer 1)
    // Standard alpha-over blending — mirrors the two-pass render.
    // ═══════════════════════════════════════════════════════════════

    float outA = layer2A + layer1A * (1.0 - layer2A);
    vec3 outCol = vec3(0.0);
    if (outA > 0.001) {
        outCol = (layer2 * layer2A + layer1 * layer1A * (1.0 - layer2A)) / outA;
    }

    // ── Edge vignette — circular fade to transparent at widget boundary ──
    vec2 edgeDist = (fc - uSize * 0.5) / (uSize * 0.5);
    float edgeR = length(edgeDist);
    float vignette = 1.0 - smoothstep(0.94, 1.1, edgeR);
    outCol *= vignette;
    outA *= vignette;

    fragColor = vec4(outCol, outA);
}
