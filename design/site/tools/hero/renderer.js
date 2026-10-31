// The hero's MacBook Pro, rendered offline (tools/hero/render.mjs drives this page in headless Chromium).
//
// A small physically-minded rasteriser in raw WebGL2: a procedural MacBook Pro 14" in Space Black
// (aluminium unibody with softly rounded edges, thin lid, black glass with the notch, keys in a well,
// Force Touch trackpad, speaker grilles, the hinge barrel) on a black studio floor. Lighting is a handful
// of rectangular softboxes; specular is GGX importance-sampled against them (and against the display and
// the floating half of the mark, which are lights too: the keyboard picks up their glow), diffuse samples a
// random point on each light, ambient occlusion and the contact shadow come from a coarse distance field of
// the same solids. Every pass jitters the pixel and the samples; passes are summed in a float buffer
// (supersampling + Monte Carlo), then bloom, a filmic shoulder and the page's own black.
//
// The promo film's plates (tools/film/plates.mjs) use the same renderer through opt-in options (see frame()):
// a graphite cyclorama shaded like everything else (exact area-light irradiance, a contact shadow, its light
// cached once per frame), a rig of up to 12 boxes with per-box Mac / cyclorama strengths, float output
// (HERO.raw()), a display that lights the scene without being drawn, the display's corners / notch / radius
// without rendering (HERO.corners()), and the film's neutral mark (codeart.js LOOKS.neutral); and the detail:
// motion blur from a shutter spread over the passes (o.a / o.b), key legends, Touch ID's ring, the trackpad's
// bevel, the anodised micro-texture and a satin floor reflection (a small MIRROR program of its own). They
// compile a FILM variant of the shader; without them the site's hero renders bit for bit as before.
//
// Units: millimetres. World: y up, the laptop centred on the floor, its front towards +z.
(function () {
  'use strict';
  const canvas = document.getElementById('c');
  let gl, W = 0, H = 0;
  const BG = [6, 7, 9];                    // the page's #060709
  const s2l = (c) => { c /= 255; return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); };
  const BG_LIN = BG.map(s2l);

  // MARK: Dimensions (MacBook Pro 14")
  const BASE = { hx: 156.3, hz: 110.6, rc: 10.5, y0: 0.8, y1: 11.3, rb: 3.4, rt: 1.15 };
  const LID = { hx: 156.3, len: 220, t: 4.6, rc: 10.5, rin: 0.9, rout: 1.7 };
  const HINGE = { y: 7.5, z: -110.5, r: 4.0, hx: 128, dIn: 4.1, l0: -1 };
  const DISP = { w: 302.4, h: 196.4, top: 215.0 };   // active area in lid-local X/Z (Z from the hinge end)

  // MARK: Math (column-major, like GL)
  const M = {
    id: () => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
    mul(a, b) { const o = new Array(16); for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) { let s = 0; for (let k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k]; o[c * 4 + r] = s; } return o; },
    T: (x, y, z) => [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1],
    S: (x, y, z) => [x, 0, 0, 0, 0, y, 0, 0, 0, 0, z, 0, 0, 0, 0, 1],
    Rx: (a) => { const c = Math.cos(a), s = Math.sin(a); return [1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1]; },
    Ry: (a) => { const c = Math.cos(a), s = Math.sin(a); return [c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1]; },
    Rz: (a) => { const c = Math.cos(a), s = Math.sin(a); return [c, s, 0, 0, -s, c, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]; },
    persp(fovy, asp, n, f) { const t = 1 / Math.tan(fovy / 2); return [t / asp, 0, 0, 0, 0, t, 0, 0, 0, 0, (f + n) / (n - f), -1, 0, 0, 2 * f * n / (n - f), 0]; },
    lookAt(e, c, up) {
      const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]], nrm = (v) => { const l = Math.hypot(...v); return v.map((x) => x / l); };
      const cr = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]], dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
      const z = nrm(sub(e, c)), x = nrm(cr(up, z)), y = cr(z, x);
      return [x[0], y[0], z[0], 0, x[1], y[1], z[1], 0, x[2], y[2], z[2], 0, -dot(x, e), -dot(y, e), -dot(z, e), 1];
    },
    inv(m) {
      const inv = new Array(16);
      inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
      inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
      inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
      inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
      inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
      inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
      inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
      inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
      inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
      inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
      inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
      inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
      inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
      inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
      inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
      inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
      const det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
      return inv.map((x) => x / det);
    },
    xf(m, p) { return [m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12], m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13], m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14]]; },
    xv(m, p) { return [m[0] * p[0] + m[4] * p[1] + m[8] * p[2], m[1] * p[0] + m[5] * p[1] + m[9] * p[2], m[2] * p[0] + m[6] * p[1] + m[10] * p[2]]; },
    n3(m) { return [m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10]]; },
  };

  // MARK: Meshes
  /// A slab with a rounded-rectangle plan (half sizes hx, hz, corner radius rc) between y0 and y1, its
  /// bottom edge rounded with rb and its top edge with rt. Smooth normals; caps are fans.
  function slab({ hx, hz, rc, y0, y1, rb, rt }, segC = 28, segA = 12) {
    const plan = [];
    const corners = [[hx - rc, hz - rc, 0], [-(hx - rc), hz - rc, 1], [-(hx - rc), -(hz - rc), 2], [hx - rc, -(hz - rc), 3]];
    for (const [cx, cz, k] of corners) {
      for (let i = 0; i <= segC; i++) {
        const a = (k + i / segC) * Math.PI / 2;
        const n = [Math.cos(a), Math.sin(a)];
        plan.push({ x: cx + rc * n[0], z: cz + rc * n[1], nx: n[0], nz: n[1] });
      }
    }
    const prof = [];
    for (let i = 0; i <= segA; i++) { const f = -Math.PI / 2 + (i / segA) * Math.PI / 2; prof.push({ d: rb - rb * Math.cos(f), y: y0 + rb + rb * Math.sin(f), h: Math.cos(f), v: Math.sin(f) }); }
    for (let i = 0; i <= segA; i++) { const f = (i / segA) * Math.PI / 2; prof.push({ d: rt - rt * Math.cos(f), y: y1 - rt + rt * Math.sin(f), h: Math.cos(f), v: Math.sin(f) }); }
    const P = [], N = [], I = [];
    const np = plan.length, nr = prof.length;
    for (const q of prof) for (const o of plan) { P.push(o.x - o.nx * q.d, q.y, o.z - o.nz * q.d); N.push(o.nx * q.h, q.v, o.nz * q.h); }
    for (let r = 0; r < nr - 1; r++) for (let i = 0; i < np; i++) {
      const a = r * np + i, b = r * np + (i + 1) % np, c = (r + 1) * np + i, d = (r + 1) * np + (i + 1) % np;
      I.push(a, b, d, a, d, c);
    }
    const bc = P.length / 3; P.push(0, y0, 0); N.push(0, -1, 0);
    for (let i = 0; i < np; i++) I.push(bc, i, (i + 1) % np);
    const tc = P.length / 3; P.push(0, y1, 0); N.push(0, 1, 0);
    const top = (nr - 1) * np;
    for (let i = 0; i < np; i++) I.push(tc, top + i, top + (i + 1) % np);
    return { P, N, I };
  }
  /// A cylinder along x with softly rounded ends (the hinge barrel).
  function barrel(r, hx, seg = 48) {
    const P = [], N = [], I = [];
    const rings = [];
    const er = 1.4;
    const xs = [];
    for (let i = 0; i <= 6; i++) { const f = (i / 6) * Math.PI / 2; xs.push({ x: -hx + er - er * Math.cos(f), rr: r - er + er * Math.sin(f), nx: -Math.cos(f), nr: Math.sin(f) }); }
    for (let i = 6; i >= 0; i--) { const f = (i / 6) * Math.PI / 2; xs.push({ x: hx - er + er * Math.cos(f), rr: r - er + er * Math.sin(f), nx: Math.cos(f), nr: Math.sin(f) }); }
    for (const q of xs) { const row = []; for (let j = 0; j < seg; j++) { const a = (j / seg) * Math.PI * 2; row.push(P.length / 3); P.push(q.x, Math.cos(a) * q.rr, Math.sin(a) * q.rr); N.push(q.nx, Math.cos(a) * q.nr, Math.sin(a) * q.nr); } rings.push(row); }
    for (let r = 0; r < rings.length - 1; r++) for (let j = 0; j < seg; j++) { const a = rings[r][j], b = rings[r][(j + 1) % seg], c = rings[r + 1][j], d = rings[r + 1][(j + 1) % seg]; I.push(a, b, d, a, d, c); }
    return { P, N, I };
  }
  const quad = (s) => ({ P: [-s, 0, -s, s, 0, -s, s, 0, s, -s, 0, s], N: [0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0], I: [0, 1, 2, 0, 2, 3] });
  /// The graphite cyclorama: a profile swept along x (±hx): the floor from z = zFront back to zCove, a cove of
  /// radius r curving up into the wall at z = zCove − r, the wall up to yTop. Normals face into the room.
  const CYC = { zFront: 4000, zCove: -1500, r: 1200, yTop: 3200, hx: 5000 };
  function cycMesh({ zFront, zCove, r, yTop, hx } = CYC, segFloor = 16, segCove = 64, segWall = 4) {
    const prof = [];
    for (let i = 0; i < segFloor; i++) prof.push({ y: 0, z: zFront + (zCove - zFront) * i / segFloor, ny: 1, nz: 0 });
    for (let i = 0; i <= segCove; i++) { const t = (i / segCove) * Math.PI / 2; prof.push({ y: r - r * Math.cos(t), z: zCove - r * Math.sin(t), ny: Math.cos(t), nz: Math.sin(t) }); }
    for (let i = 1; i <= segWall; i++) prof.push({ y: r + (yTop - r) * i / segWall, z: zCove - r, ny: 0, nz: 1 });
    const P = [], N = [], I = [];
    for (const q of prof) for (const x of [-hx, hx]) { P.push(x, q.y, q.z); N.push(0, q.ny, q.nz); }
    for (let i = 0; i < prof.length - 1; i++) { const a = 2 * i, b = a + 1, c = a + 2, d = a + 3; I.push(a, b, d, a, d, c); }
    return { P, N, I };
  }

  // MARK: Shaders
  const VS = `#version 300 es
  in vec3 aP; in vec3 aN;
  uniform mat4 uM; uniform mat4 uVP; uniform mat3 uNM;
  out vec3 vP; out vec3 vN; out vec3 vL;
  void main() { vec4 w = uM * vec4(aP, 1.0); vP = w.xyz; vN = normalize(uNM * aN); vL = aP; gl_Position = uVP * w; }`;

  const FS = `#version 300 es
  precision highp float; precision highp int;
  #ifdef FILM
  #ifndef NLIGHT
  #define NLIGHT 12
  #endif
  #else
  #define NLIGHT 5
  #endif
  in vec3 vP; in vec3 vN; in vec3 vL;
  out vec4 o;
  uniform int uMat;              // 0 floor (or the cyclorama), 1 base, 2 lid, 3 hinge
  uniform vec3 uEye;
  uniform uint uSeed;
  uniform mat4 uLid, uLidInv;    // lid local <-> world
  uniform sampler2D uScr;        // the display (sRGB, opaque)
  uniform float uScrGain;
  uniform sampler2D uHalfT;      // the floating half (sRGB on black, additive)
  uniform vec3 uHC, uHU, uHV;    // its rectangle: centre, half axes (world)
  uniform float uHGain;
  uniform vec3 uLC[NLIGHT], uLU[NLIGHT], uLV[NLIGHT], uLCol[NLIGHT];
  uniform vec3 uBg;
  uniform float uPool, uPoolR;
  uniform int uSpp;
  uniform float uClamp;
  #ifdef FILM
  // the film's plates (the FILM variant of this shader; the site's hero compiles without it)
  uniform int uNL;               // lights in use
  uniform float uLMacK[NLIGHT], uLCycK[NLIGHT];   // per light: how strongly it lights the Mac / the cyclorama
  uniform int uCyc;              // 1: the floor is the graphite cyclorama, shaded by shade() (no pool, no backdrop colour)
  uniform int uMac;              // 0: no Mac in the scene (the empty studio)
  uniform float uScrDrawn;       // 0: the display still lights the scene, but the glass shows only its reflection
  uniform int uStrat, uPass;     // 1: the textured lights' samples are stratified across the passes
  uniform ivec2 uStratG;         // the strata grid (x * y = passes)
  uniform int uNeutral;          // 1: materials are neutral grey (no tint)
  uniform vec2 uContact;         // the cyclorama's contact shadow: brightness at contact, falloff (mm)
  bool gCyc = false;             // shading the cyclorama (lights use uLCycK, diffuse is exact)
  uniform int uCycPass;          // 1: render the cyclorama's softbox light (the cache); 2: read it from uCycT
  uniform sampler2D uCycT;
  uniform vec2 uCycPx;           // 1 / the frame's size in px (the cache is read with normalised coordinates)
  uniform ivec2 uCacheG;         // the cache pass's sample grid for the textured lights
  // detail (spec v2 §5.7–9): key legends, Touch ID and trackpad, anodised micro-texture, the floor reflection
  uniform int uLegOn;            // 1: key legends from uLeg (an atlas; cell of key k = uKeyCell[k], uv rect, z = 0: none)
  uniform sampler2D uLeg;
  uniform vec4 uKeyCell[85];
  uniform vec4 uLegCol;          // the legends' ink (linear rgb) and its opacity over the key's albedo
  uniform int uFine;             // 1: Touch ID ring, the trackpad's bevel and gap (no dotted outline)
  uniform float uMicro;          // anodised micro-texture strength (1: roughness ±0.04 at 2 mm, albedo ±3% at 5 mm)
  uniform vec3 uEyeR;            // the floor reflection (MIRROR): the real eye (the floor's Fresnel; uEye is mirrored)
  uniform float uReflK;          // the floor reflection's strength (1: 4% × Fresnel)
  int gKey = -1;                 // the key keyAt() last found (row * 14 + column; 84: the up arrow)
  #endif

  const float PI = 3.14159265;
  const vec2 DISP = vec2(${DISP.w.toFixed(2)}, ${DISP.h.toFixed(2)});
  const float DTOP = ${DISP.top.toFixed(2)};
  const float LLEN = ${LID.len.toFixed(2)};

  uint rs;
  uint pcg(uint v) { uint s = v * 747796405u + 2891336453u; uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u; return (w >> 22u) ^ w; }
  float rnd() { rs = pcg(rs); return float(rs) * (1.0 / 4294967296.0); }
  vec3 s2l(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c)); }
  float sdRR(vec2 p, vec2 b, float r) { vec2 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r; }
  float sdRB(vec3 p, vec3 b, float r) { vec3 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0) - r; }

  // MARK: Distance field of the solids (for occlusion)
  float sdF(vec3 p) {
    #ifdef FILM
    if (uMac == 0) return 1e5;
    #endif
    float b = sdRB(p - vec3(0.0, ${((BASE.y0 + BASE.y1) / 2).toFixed(3)}, 0.0), vec3(${BASE.hx}, ${((BASE.y1 - BASE.y0) / 2).toFixed(3)}, ${BASE.hz}), 3.0);
    vec3 q = (uLidInv * vec4(p, 1.0)).xyz;
    float l = sdRB(q - vec3(0.0, ${(LID.t / 2).toFixed(2)}, LLEN * 0.5), vec3(${LID.hx}, ${(LID.t / 2).toFixed(2)}, LLEN * 0.5), 2.0);
    vec2 d = vec2(length(p.yz - vec2(${HINGE.y}, ${HINGE.z})) - ${HINGE.r.toFixed(2)}, abs(p.x) - ${HINGE.hx.toFixed(1)});
    float h = min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
    return min(min(b, l), h);
  }
  float occl(vec3 P, vec3 N, float s0, float k) {
    float o = 0.0, w = 1.0;
    for (int i = 0; i < 5; i++) { float h = s0 * pow(2.0, float(i)); float d = sdF(P + N * h); o += w * clamp((h - d) / h, 0.0, 1.0); w *= 0.62; }
    return clamp(1.0 - k * o, 0.0, 1.0);
  }

  // MARK: The display: what the lid's inner face shows at lid-local (x, z); 0 outside the active area
  vec3 display(vec2 xz) {
    vec2 p = vec2(xz.x, xz.y - (DTOP - DISP.y * 0.5));
    // rounded top corners, square bottom ones
    vec2 h = DISP * 0.5;
    float d = p.y > 0.0 ? sdRR(p, h, 9.0) : max(abs(p.x) - h.x, abs(p.y) - h.y);
    float notch = sdRR(vec2(p.x, p.y - (h.y - 3.6)), vec2(15.4, 3.6 + 1.0), 2.4);
    if (d > 0.0 || notch < 0.0) return vec3(0.0);
    vec2 uv = vec2((p.x + h.x) / DISP.x, 1.0 - (p.y + h.y) / DISP.y);
    return s2l(texture(uScr, uv).rgb) * uScrGain;
  }

  // MARK: Light along a ray: softboxes, the display (and the lid, which blocks), the floating half
  vec3 env(vec3 P, vec3 L, bool fromLid) {
    float tb = 1e9; vec3 rad = vec3(0.0);
    #ifdef FILM
    if (!fromLid && uMac == 1) {
    #else
    if (!fromLid) {
    #endif
      vec3 lp = (uLidInv * vec4(P, 1.0)).xyz, ld = mat3(uLidInv) * L;
      if (abs(ld.y) > 1e-5) {
        float t = -lp.y / ld.y;
        if (t > 0.0) { vec3 q = lp + ld * t; if (abs(q.x) < ${LID.hx} && q.z > 0.0 && q.z < LLEN) { tb = t; if (ld.y > 0.0) rad = display(q.xz); } }
      }
    }
    if (uHGain > 0.0 && !fromLid) {
      vec3 n = normalize(cross(uHU, uHV));
      float dn = dot(L, n);
      if (abs(dn) > 1e-4) {
        float t = dot(uHC - P, n) / dn;
        if (t > 0.0 && t < tb) {
          vec3 q = P + L * t - uHC;
          vec2 st = vec2(dot(q, uHU) / dot(uHU, uHU), dot(q, uHV) / dot(uHV, uHV));
          if (abs(st.x) < 1.0 && abs(st.y) < 1.0) rad += s2l(texture(uHalfT, vec2(st.x * 0.5 + 0.5, 0.5 - st.y * 0.5)).rgb) * uHGain;
        }
      }
    }
    return rad;
  }

  // MARK: Shading: GGX specular sampled against the lights, diffuse from a random point on each
  /// How much of the light at X the lid (a thin rectangle) leaves visible from P: 1 clear, 0 hidden, with a
  /// soft edge that widens with the distance behind the lid (no noise, the same in every pass).
  float lidVis(vec3 P, vec3 X) {
    #ifdef FILM
    if (uMac == 0) return 1.0;
    #endif
    vec3 lp = (uLidInv * vec4(P, 1.0)).xyz, lx = (uLidInv * vec4(X, 1.0)).xyz;
    if (lp.y * lx.y > 0.0 || abs(lp.y - lx.y) < 1e-4) return 1.0;
    float f = lp.y / (lp.y - lx.y);
    vec3 q = mix(lp, lx, f);
    float d = sdRR(q.xz - vec2(0.0, LLEN * 0.5), vec2(${LID.hx}, LLEN * 0.5), 8.0);
    float pen = 3.0 + 0.06 * length(q - lp);
    return smoothstep(-pen, pen, d);
  }
  #ifdef FILM
  /// Irradiance per unit radiance at P (normal N) from the one-sided rectangle C ± U ± V emitting along n:
  /// Lambert's polygon formula, clipped to P's horizon. Exact and noiseless (the cyclorama's diffuse).
  float rectE(vec3 P, vec3 N, vec3 C, vec3 U, vec3 V, vec3 n) {
    if (dot(P - C, n) <= 0.0) return 0.0;
    vec3 q[4]; q[0] = C - U - V - P; q[1] = C + U - V - P; q[2] = C + U + V - P; q[3] = C - U + V - P;
    vec3 r[8]; int m = 0;
    for (int k = 0; k < 4; k++) {
      vec3 a = q[k], b = q[(k + 1) % 4];
      float da = dot(a, N), db = dot(b, N);
      if (da >= 0.0) { r[m] = a; m++; }
      if ((da >= 0.0) != (db >= 0.0)) { r[m] = a + (b - a) * (da / (da - db)); m++; }
    }
    if (m < 3) return 0.0;
    float s = 0.0;
    for (int k = 0; k < 8; k++) {
      if (k >= m) break;
      vec3 a = normalize(r[k]), b = normalize(r[(k + 1) % m]);
      vec3 x = cross(a, b); float lx = length(x);
      if (lx > 1e-7) s += atan(lx, dot(a, b)) * dot(N, x) / lx;
    }
    return 0.5 * abs(s);
  }
  /// A 2D sample in [0,1)^2 inside cell c of a g.x × g.y grid (strata).
  vec2 smpCell(int c, ivec2 g) {
    vec2 u = vec2(rnd(), rnd());
    c = c % (g.x * g.y);
    return (vec2(float(c % g.x), float(c / g.x)) + u) / vec2(g);
  }
  /// Value noise (deterministic: the same in every pass) and a 3-octave fbm in about -1..1: the anodising.
  float hash3(ivec3 c) { return float(pcg(uint(c.x) * 73856093u ^ pcg(uint(c.y) * 19349663u ^ pcg(uint(c.z) * 83492791u)))) * (1.0 / 4294967296.0); }
  float vnoise(vec3 p) {
    vec3 i = floor(p), f = fract(p), u = f * f * (3.0 - 2.0 * f);
    ivec3 c = ivec3(i);
    float x00 = mix(hash3(c), hash3(c + ivec3(1, 0, 0)), u.x), x10 = mix(hash3(c + ivec3(0, 1, 0)), hash3(c + ivec3(1, 1, 0)), u.x);
    float x01 = mix(hash3(c + ivec3(0, 0, 1)), hash3(c + ivec3(1, 0, 1)), u.x), x11 = mix(hash3(c + ivec3(0, 1, 1)), hash3(c + ivec3(1, 1, 1)), u.x);
    return mix(mix(x00, x10, u.y), mix(x01, x11, u.y), u.z) * 2.0 - 1.0;
  }
  float fbm(vec3 p) {
    float s = 0.0, a = 0.5;
    for (int k = 0; k < 3; k++) { s += a * vnoise(p); p = p * 2.03 + vec3(17.1, 5.3, 11.7); a *= 0.5; }
    return s;                              // within ±0.875; mostly ±0.4
  }
  /// The anodised aluminium's micro-texture at local point q (mm): roughness and albedo varied by fbm.
  void anodise(vec3 q, inout float r, inout vec3 alb) {
    if (uMicro <= 0.0) return;
    r = clamp(r + 0.04 * uMicro * fbm(q * 0.5), 0.05, 1.0);
    alb *= 1.0 + 0.03 * uMicro * fbm(q * 0.2 + vec3(31.0));
  }
  float sdPad(vec2 p) { return sdRR(p - vec2(0.0, 63.0), vec2(67.0, 40.0), 7.5); }
  #endif
  float Dggx(float NH, float a) { float a2 = a * a; float d = NH * NH * (a2 - 1.0) + 1.0; return a2 / (PI * d * d); }
  vec3 shade(vec3 P, vec3 N, vec3 V, vec3 F0, float rough, vec3 alb, float ao, bool fromLid) {
    #ifdef FILM
    if (uNeutral == 1) { const vec3 Y = vec3(0.2126, 0.7152, 0.0722); F0 = vec3(dot(F0, Y)); alb = vec3(dot(alb, Y)); }
    #endif
    float a = max(rough * rough, 0.0008);
    float NV = max(dot(N, V), 1e-3);
    float k2 = a * 0.5;
    vec3 spec = vec3(0.0), E = vec3(0.0);
    vec3 R = reflect(-V, N);
    // softboxes: the representative point on each box (closest to the reflected ray), energy-normalised
    for (int i = 0; i < NLIGHT; i++) {
      #ifdef FILM
      if (i >= uNL) break;
      float lk = gCyc ? uLCycK[i] : uLMacK[i];
      if (lk <= 0.0) continue;
      vec3 lcol = uLCol[i] * lk;
      #else
      vec3 lcol = uLCol[i];
      #endif
      vec3 C = uLC[i], U = uLU[i], Vv = uLV[i];
      vec3 n = normalize(cross(U, Vv));
      #if defined(FILM) && !defined(MIRROR)
      if (gCyc) {
        // the cyclorama (rough): the box's exact irradiance, and for the specular the lobe at the direction of
        // the box's centre times that irradiance (smooth: no representative point switching across the floor)
        float e = rectE(P, N, C, U, Vv, n);
        if (e > 0.0) {
          E += lcol * e;
          vec3 Lc = normalize(C - P);
          float NLc = max(dot(N, Lc), 0.05);
          vec3 Hc = normalize(Lc + V);
          float NHc = max(dot(N, Hc), 0.0), VHc = max(dot(V, Hc), 0.0);
          vec3 Fc = F0 + (1.0 - F0) * pow(1.0 - VHc, 5.0);
          float Gc = (NV / (NV * (1.0 - k2) + k2)) * (NLc / (NLc * (1.0 - k2) + k2));
          spec += lcol * e * Dggx(NHc, a) * Gc * Fc / (4.0 * NV * NLc);
        }
        continue;
      }
      #endif
      float dn = dot(R, n);
      vec3 pc = C;
      if (dn < -1e-4) { float t = dot(C - P, n) / dn; if (t > 0.0) pc = P + R * t; }
      else { pc = P + R * dot(C - P, R); }
      vec3 q = pc - C;
      vec3 X = C + U * clamp(dot(q, U) / dot(U, U), -1.0, 1.0) + Vv * clamp(dot(q, Vv) / dot(Vv, Vv), -1.0, 1.0);
      vec3 Ld = X - P; float d = length(Ld); Ld /= d;
      float cl = -dot(Ld, n), NL = dot(N, Ld);
      float area = 4.0 * length(U) * length(Vv);
      // diffuse from the box's centre
      vec3 Dc = C - P; float dc = length(Dc); Dc /= dc;
      E += lcol * area * max(dot(N, Dc), 0.0) * max(-dot(Dc, n), 0.0) / (dc * dc);
      if (cl <= 0.0 || NL <= 0.0) continue;
      float vis = fromLid ? 1.0 : lidVis(P + N * 0.05, X);
      if (vis <= 0.0) continue;
      float rad = sqrt(area / PI);
      float ap = min(1.0, a + rad / (2.0 * d));
      vec3 Hh = normalize(Ld + V);
      float NH = max(dot(N, Hh), 0.0), VH = max(dot(V, Hh), 0.0);
      vec3 F = F0 + (1.0 - F0) * pow(1.0 - VH, 5.0);
      float G = (NV / (NV * (1.0 - k2) + k2)) * (NL / (NL * (1.0 - k2) + k2));
      float Il = area * max(cl, 0.25) / (d * d);
      spec += lcol * vis * Il * Dggx(NH, a) * (a / ap) * (a / ap) * G * F / (4.0 * NV);
    }
    #ifdef MIRROR
    // (the floor reflection's own program: boxes only)
    #elif defined(FILM)
    // the display and the floating half: sampled (they are textured). In a pass, one sample per pixel (with
    // uStrat, pass p draws from its own cell of the strata grid); in the cyclorama's cache pass, the whole grid.
    {
      int nT = uCycPass == 1 ? uCacheG.x * uCacheG.y : 1;
      ivec2 G = uCycPass == 1 ? uCacheG : uStratG;
      bool st8 = uStrat == 1 || uCycPass == 1;
      vec3 T = normalize(abs(N.y) < 0.99 ? cross(N, vec3(0.0, 1.0, 0.0)) : cross(N, vec3(1.0, 0.0, 0.0)));
      vec3 B = cross(N, T);
      vec3 sm = vec3(0.0), Et = vec3(0.0);
      for (int t = 0; t < 64; t++) {
        if (t >= nT) break;
        int cell = uCycPass == 1 ? t : uPass;
        if ((!fromLid && uMac == 1) || uHGain > 0.0) {
          for (int k = 0; k < 4; k++) {
            if (k >= uSpp) break;
            vec2 u = st8 ? smpCell(cell, G) : vec2(rnd(), rnd());
            float phi = 2.0 * PI * u.x;
            float ct = sqrt((1.0 - u.y) / (1.0 + (a * a - 1.0) * u.y)), st = sqrt(max(0.0, 1.0 - ct * ct));
            vec3 Hh = normalize(T * (st * cos(phi)) + B * (st * sin(phi)) + N * ct);
            vec3 L = reflect(-V, Hh);
            float NL = dot(N, L);
            if (NL <= 0.0) continue;
            float VH = max(dot(V, Hh), 0.0), NH = max(dot(N, Hh), 1e-4);
            vec3 F = F0 + (1.0 - F0) * pow(1.0 - VH, 5.0);
            float G2 = (NV / (NV * (1.0 - k2) + k2)) * (NL / (NL * (1.0 - k2) + k2));
            sm += min(env(P + N * 0.02, L, fromLid), vec3(uClamp)) * F * G2 * VH / (NH * NV);
          }
        }
        if (dot(alb, alb) > 0.0) {
          if (!fromLid && uMac == 1) {
            vec2 u = st8 ? smpCell(cell, G) : vec2(rnd(), rnd());
            vec2 xz = vec2((u.x - 0.5) * DISP.x, DTOP - DISP.y * u.y);
            vec3 X = (uLid * vec4(xz.x, 0.0, xz.y, 1.0)).xyz;
            vec3 n = -normalize(mat3(uLid) * vec3(0.0, 1.0, 0.0));
            vec3 d = X - P; float dl = max(length(d), 20.0); d = normalize(d);
            Et += display(xz) * DISP.x * DISP.y * max(dot(N, d), 0.0) * max(-dot(d, n), 0.0) / (dl * dl);
          }
          if (uHGain > 0.0) {
            vec2 sq = (st8 ? smpCell(cell, G) : vec2(rnd(), rnd())) * 2.0 - 1.0;
            vec3 X = uHC + uHU * sq.x + uHV * sq.y;
            vec3 d = X - P; float dl = max(length(d), 20.0); d = normalize(d);
            vec3 n = normalize(cross(uHU, uHV));
            Et += s2l(texture(uHalfT, vec2(sq.x * 0.5 + 0.5, 0.5 - sq.y * 0.5)).rgb) * uHGain * 4.0 * length(uHU) * length(uHV) * max(dot(N, d), 0.0) * abs(dot(d, n)) / (dl * dl);
          }
        }
      }
      spec += sm / float(uSpp * nT);
      E += Et / float(nT);
    }
    #else
    // the display and the floating half: sampled (they are textured)
    if (!fromLid || uHGain > 0.0) {
      vec3 T = normalize(abs(N.y) < 0.99 ? cross(N, vec3(0.0, 1.0, 0.0)) : cross(N, vec3(1.0, 0.0, 0.0)));
      vec3 B = cross(N, T);
      vec3 sm = vec3(0.0);
      for (int k = 0; k < 4; k++) {
        if (k >= uSpp) break;
        vec2 u = vec2(rnd(), rnd());
        float phi = 2.0 * PI * u.x;
        float ct = sqrt((1.0 - u.y) / (1.0 + (a * a - 1.0) * u.y)), st = sqrt(max(0.0, 1.0 - ct * ct));
        vec3 Hh = normalize(T * (st * cos(phi)) + B * (st * sin(phi)) + N * ct);
        vec3 L = reflect(-V, Hh);
        float NL = dot(N, L);
        if (NL <= 0.0) continue;
        float VH = max(dot(V, Hh), 0.0), NH = max(dot(N, Hh), 1e-4);
        vec3 F = F0 + (1.0 - F0) * pow(1.0 - VH, 5.0);
        float G = (NV / (NV * (1.0 - k2) + k2)) * (NL / (NL * (1.0 - k2) + k2));
        sm += min(env(P + N * 0.02, L, fromLid), vec3(uClamp)) * F * G * VH / (NH * NV);
      }
      spec += sm / float(uSpp);
    }
    if (dot(alb, alb) > 0.0) {
      if (!fromLid) {
        vec2 xz = vec2((rnd() - 0.5) * DISP.x, DTOP - DISP.y * rnd());
        vec3 X = (uLid * vec4(xz.x, 0.0, xz.y, 1.0)).xyz;
        vec3 n = -normalize(mat3(uLid) * vec3(0.0, 1.0, 0.0));
        vec3 d = X - P; float dl = max(length(d), 20.0); d = normalize(d);
        E += display(xz) * DISP.x * DISP.y * max(dot(N, d), 0.0) * max(-dot(d, n), 0.0) / (dl * dl);
      }
      if (uHGain > 0.0) {
        vec2 st = vec2(rnd() * 2.0 - 1.0, rnd() * 2.0 - 1.0);
        vec3 X = uHC + uHU * st.x + uHV * st.y;
        vec3 d = X - P; float dl = max(length(d), 20.0); d = normalize(d);
        vec3 n = normalize(cross(uHU, uHV));
        E += s2l(texture(uHalfT, vec2(st.x * 0.5 + 0.5, 0.5 - st.y * 0.5)).rgb) * uHGain * 4.0 * length(uHU) * length(uHV) * max(dot(N, d), 0.0) * abs(dot(d, n)) / (dl * dl);
      }
    }
    #endif
    return spec * mix(1.0, ao, 0.7) + alb / PI * E * ao;
  }

  // MARK: The keyboard: rows of key widths (units of the pitch), 14.5 units wide
  const float KW[84] = float[84](
    1.5, 1., 1., 1., 1., 1., 1., 1., 1., 1., 1., 1., 1., 1.,
    1., 1., 1., 1., 1., 1., 1., 1., 1., 1., 1., 1., 1., 1.5,
    1.5, 1., 1., 1., 1., 1., 1., 1., 1., 1., 1., 1., 1., 1.,
    1.75, 1., 1., 1., 1., 1., 1., 1., 1., 1., 1., 1., 1.75, 0.,
    2.25, 1., 1., 1., 1., 1., 1., 1., 1., 1., 1., 2.25, 0., 0.,
    1., 1., 1., 1.25, 5., 1.25, 1., 1., 1., 1., 0., 0., 0., 0.);
  const float KP = 18.7;
  const vec2 K0 = vec2(-KP * 7.25, -99.5);     // top-left of the keys (u, v); v grows to the front
  /// The key cap under (u, v): returns its signed distance; c/h = centre and half size.
  float keyAt(vec2 p, out vec2 c, out vec2 hh) {
    vec2 q = (p - K0) / KP;
    c = vec2(0.0); hh = vec2(0.0);
    #ifdef FILM
    gKey = -1;
    #endif
    if (q.x < 0.0 || q.x > 14.5 || q.y < 0.0 || q.y >= 6.0) return 99.0;
    int row = int(floor(q.y));
    float x = 0.0; float w = 1.0;
    #ifdef FILM
    for (int i = 0; i < 14; i++) { w = KW[row * 14 + i]; if (w == 0.0) return 99.0; if (q.x < x + w) { gKey = row * 14 + i; break; } x += w; }
    #else
    for (int i = 0; i < 14; i++) { w = KW[row * 14 + i]; if (w == 0.0) return 99.0; if (q.x < x + w) break; x += w; }
    #endif
    float top = float(row), bot = float(row) + 1.0;
    // arrows: inverted T (the last three cells of the bottom row are half height, up above down)
    if (row == 5 && x >= 11.49) {
      #ifdef FILM
      if (x > 12.4 && x < 12.6) { if (fract(q.y) < 0.5) { bot = top + 0.5; gKey = 84; } else top = top + 0.5; }
      #else
      if (x > 12.4 && x < 12.6) { if (fract(q.y) < 0.5) bot = top + 0.5; else top = top + 0.5; }
      #endif
      else top = top + 0.5;
    }
    vec2 lo = K0 + vec2(x, top) * KP, hi = K0 + vec2(x + w, bot) * KP;
    c = (lo + hi) * 0.5; hh = (hi - lo) * 0.5 - vec2(1.55, 1.55);
    if (bot - top < 0.9) hh.y = (hi.y - lo.y) * 0.5 - 0.9;
    return sdRR(p - c, hh, 2.1);
  }

  #ifdef CYCREAD
  // The cyclorama in a pass, once its light is cached: the cache times the contact shadow (a small program of
  // its own: SwiftShader pays for the big shader's untaken branches on every pixel)
  void main() {
    vec3 col = texture(uCycT, gl_FragCoord.xy * uCycPx).rgb;
    float vis = 1.0;
    if (uMac == 1 && vP.y < 2.0) {
      float d = sdRR(vP.xz, vec2(${BASE.hx}, ${BASE.hz}), 10.5);
      if (d < 90.0) vis = occl(vP, vec3(0.0, 1.0, 0.0), 2.0, 0.7);
      vis = min(vis, uContact.x + (1.0 - uContact.x) * smoothstep(-6.0, uContact.y, d));
    }
    o = vec4(col * vis, 1.0);
  }
  #elif defined(MIRROR)
  // The floor reflection (o.reflect), a small program of its own (SwiftShader shades every rasterised fragment
  // with the whole shader, untaken branches included, and the mirrored Mac rasterises ~5× the pixels that show):
  // this fragment is the real surface at vP seen from the mirrored eye (uEye), plainly shaded by the boxes (the
  // deck, the display and the half face away from the floor or are lost in a 4%, height-faded, spread image). It
  // adds 4% × Fresnel (at the floor point, seen from the real eye uEyeR), fading as exp(-height / 25 mm).
  void main() {
    rs = pcg(uint(gl_FragCoord.x) * 1973u + pcg(uint(gl_FragCoord.y) * 9277u + pcg(uSeed)));
    float fade = exp(-max(vP.y, 0.0) / 25.0);
    float ct = clamp(normalize(uEyeR - vec3(vP.x, -vP.y, vP.z)).y, 0.0, 1.0);
    float rw = uReflK * fade * (0.04 + 0.96 * pow(1.0 - ct, 5.0));
    vec3 P = vP, N = normalize(vN), V = normalize(uEye - vP);
    if (dot(N, V) < 0.0) N = -N;
    vec3 col;
    if (uMat == 1) col = shade(P, N, V, vec3(0.07, 0.072, 0.077), 0.4, vec3(0.022, 0.0225, 0.025), 1.0, false);
    else if (uMat == 2) {
      vec3 lp = (uLidInv * vec4(P, 1.0)).xyz;
      bool glass = (mat3(uLidInv) * N).y < -0.98 && lp.y < 0.05;
      col = glass ? shade(P, N, V, vec3(0.035), 0.3, vec3(0.0), 1.0, true) : shade(P, N, V, vec3(0.075, 0.077, 0.082), 0.34, vec3(0.022, 0.0225, 0.025), 1.0, true);
    } else col = shade(P, N, V, vec3(0.05), 0.36, vec3(0.012), 1.0, false);
    o = vec4(col * rw, 0.0);
  }
  #else
  void main() {
    rs = pcg(uint(gl_FragCoord.x) * 1973u + pcg(uint(gl_FragCoord.y) * 9277u + pcg(uSeed)));
    vec3 P = vP, N = normalize(vN), V = normalize(uEye - vP);
    #ifdef FILM
    // the surface's footprint per pixel (the legends' mip level), taken before any branch
    vec2 gdx = dFdx(vL.xz), gdy = dFdy(vL.xz);
    #endif
    if (dot(N, V) < 0.0 && uMat != 0) N = -N;
    vec3 col;
    #ifdef FILM
    float cov = 0.0;               // alpha: 1 where this is the floor / cyclorama (the plate's empty studio)
    if (uMat == 0 && uCyc == 1) {
      // the graphite cyclorama: the same physically-based shading as the Mac (albedo 0.03 linear, roughness
      // 0.85, F0 0.02), times the contact shadow under the Mac (distance field + its soft footprint)
      // Its light is smooth and the same in every pass: rendered once per frame (uCycPass 1: the softboxes exactly,
      // the display and the half with a grid of samples) at reduced size, read back in the passes (2), which add
      // only the contact shadow at full size.
      gCyc = true; cov = 1.0;
      if (uCycPass == 1) col = shade(P, N, V, vec3(0.02), 0.85, vec3(0.03), 1.0, false);
      else {
        float vis = 1.0;
        if (uMac == 1 && P.y < 2.0) {
          float d = sdRR(P.xz, vec2(${BASE.hx}, ${BASE.hz}), 10.5);
          if (d < 90.0) vis = occl(P, vec3(0.0, 1.0, 0.0), 2.0, 0.7);
          vis = min(vis, uContact.x + (1.0 - uContact.x) * smoothstep(-6.0, uContact.y, d));
        }
        if (uCycPass == 2) {
          col = texture(uCycT, gl_FragCoord.xy * uCycPx).rgb;
        } else col = shade(P, N, V, vec3(0.02), 0.85, vec3(0.03), 1.0, false);
        col *= vis;
      }
    } else if (uMat == 0) {
      cov = 1.0;
    #else
    if (uMat == 0) {
    #endif
      // the floor: the page's black, a contact shadow under the Mac, a faint pool of light round it
      float d = sdRR(P.xz, vec2(${BASE.hx}, ${BASE.hz}), 10.5);
      float pool = exp(-pow(length(P.xz * vec2(0.85, 1.25)) / uPoolR, 2.0)) * uPool;
      float vis = d < 45.0 ? occl(P, vec3(0.0, 1.0, 0.0), 1.6, 0.9) : 1.0;
      float soft = smoothstep(-8.0, 34.0, d);
      vis = min(vis, 0.12 + 0.88 * soft);
      col = (uBg * (1.0 + pool)) * vis;
    } else if (uMat == 1) {
      vec3 L = vL;
      vec3 F0 = vec3(0.07, 0.072, 0.077); float r = 0.4; vec3 alb = vec3(0.022, 0.0225, 0.025);
      float ao = occl(P, N, 0.7, 0.6);
      bool deck = N.y > 0.995 && L.y > ${(BASE.y1 - 0.05).toFixed(2)};
      vec3 Nn = N;
      #ifdef FILM
      bool alu = true;             // the anodised aluminium (not keys, the well, grille holes or the trackpad's glass)
      #endif
      if (deck) {
        vec2 p = L.xz;
        vec3 Vt = V;
        // keyboard well: keys sit 0.25 below the deck, the well floor 1.1 below
        vec2 wellH = vec2(KP * 7.25 + 1.4, KP * 3.0 + 1.4);
        vec2 wellC = vec2(0.0, K0.y + KP * 3.0);
        float well = sdRR(p - wellC, wellH, 3.0);
        vec2 grillC = vec2(sign(p.x) * 145.6, wellC.y);
        float grill = sdRR(vec2(abs(p.x) - 145.6, p.y - wellC.y), vec2(5.1, wellH.y - 0.5), 2.6);
        float pad = sdRR(p - vec2(0.0, 63.0), vec2(67.0, 40.0), 7.5);
        if (well < 0.0) {
          vec2 off = -Vt.xz / max(Vt.y, 0.05);
          vec2 q1 = p + off * 0.25, q2 = p + off * 1.1;
          vec2 kc, kh;
          float k1 = keyAt(q1, kc, kh);
          #ifdef FILM
          int kid = gKey;
          alu = false;
          #endif
          if (k1 < 0.0) {
            // key top: black, satin; edges round over
            float e = smoothstep(-0.7, 0.0, k1);
            vec2 g = normalize((q1 - kc) / max(kh, vec2(1.0)) + 1e-4);
            vec2 dq = q1 - kc; vec2 ad = abs(dq) - kh + 2.1; vec2 gg = ad.x > ad.y ? vec2(sign(dq.x), 0.0) : vec2(0.0, sign(dq.y));
            Nn = normalize(vec3(0.0, 1.0, 0.0) + vec3(gg.x, 0.0, gg.y) * e * 1.6 - vec3(dq.x, 0.0, dq.y) * 0.0025);
            F0 = vec3(0.045); r = 0.42; alb = vec3(0.028, 0.029, 0.032);
            ao *= 1.0;
            #ifdef FILM
            // the legend printed on this key (an atlas cell per key index; mip level from the pixel's footprint)
            if (uLegOn == 1 && kid >= 0) {
              vec4 cell = uKeyCell[kid];
              if (cell.z > 0.0) {
                vec2 s2 = cell.zw / (2.0 * kh);
                vec2 uv = cell.xy + ((q1 - kc) / (2.0 * kh) + 0.5) * cell.zw;
                // mip level from the footprint's minor axis (seen this low, the major one is 3–5× longer and
                // would blur the print away); the passes' jitter supersamples along the major axis
                vec2 ts = vec2(textureSize(uLeg, 0));
                float fp = min(length(gdx * s2 * ts), length(gdy * s2 * ts));
                float m = textureLod(uLeg, uv, max(log2(max(fp, 1e-6)) - 0.5, 0.0)).a;
                alb = mix(alb, uLegCol.rgb, uLegCol.a * m);
              }
            }
            // Touch ID (the function row's last key): the sensor sits in a shallow recess; a 0.4 mm ring slopes down
            // into it, darker, glossier, so it draws a thin specular line on the side facing a light
            if (uFine == 1 && kid == 13) {
              vec2 d = q1 - kc; float rr = length(d); vec2 rd = d / max(rr, 1e-3);
              float R0 = min(kh.x, kh.y) - 1.1;
              float wall = smoothstep(R0 - 0.5, R0 - 0.3, rr) * (1.0 - smoothstep(R0 - 0.1, R0 + 0.05, rr));
              float inner = 1.0 - smoothstep(R0 - 0.5, R0 - 0.3, rr);
              Nn = normalize(mix(Nn, normalize(vec3(-rd.x * 0.85, 1.0, -rd.y * 0.85)), wall));
              alb *= 1.0 - 0.3 * inner - 0.45 * wall;
              r = mix(mix(r, 0.34, inner), 0.2, wall);
              ao *= 1.0 - 0.25 * wall;
            }
            #endif
          } else {
            float k2 = keyAt(q2, kc, kh);
            if (k2 < 0.0) {
              vec2 dq = q2 - kc; vec2 ad = abs(dq) - kh + 2.1; vec2 gg = ad.x > ad.y ? vec2(sign(dq.x), 0.0) : vec2(0.0, sign(dq.y));
              Nn = normalize(vec3(gg.x, 0.15, gg.y));
              F0 = vec3(0.04); r = 0.5; alb = vec3(0.012); ao *= 0.6;
            } else {
              Nn = vec3(0.0, 1.0, 0.0);
              F0 = vec3(0.035); r = 0.7; alb = vec3(0.006);
              float kk = keyAt(q2, kc, kh);
              ao *= 0.35 + 0.65 * smoothstep(0.0, 2.2, kk);
              if (sdRR(q2 - wellC, wellH, 3.0) > 0.0) { ao *= 0.5; }
            }
          }
        } else if (grill < 0.0) {
          vec2 g = vec2(abs(p.x), p.y) / vec2(0.78, 0.676);
          vec2 cell = vec2(g.x, g.y);
          float row = floor(cell.y); vec2 f = vec2(fract(cell.x + 0.5 * mod(row, 2.0)), fract(cell.y)) - 0.5;
          float hole = length(f * vec2(0.78, 0.676)) - 0.21;
          if (hole < 0.0) { F0 = vec3(0.02); r = 0.8; alb = vec3(0.0); ao *= 0.15; }
          else { r = 0.38; }
          #ifdef FILM
          if (hole < 0.0) alu = false;
        } else if (uFine == 1 && pad < 0.8) {
          // the trackpad: glass flush with the deck, a hairline gap, a faint roundover either side of it and soft
          // occlusion in the gap; every term is smooth over ~1 mm (the old hard groove read as a dotted line)
          vec2 ex = vec2(0.05, 0.0);
          vec2 gr = vec2(sdPad(p + ex.xy) - sdPad(p - ex.xy), sdPad(p + ex.yx) - sdPad(p - ex.yx));
          gr /= max(length(gr), 1e-5);
          // (widths ≥ a pixel at 1080: the roundovers 1.4 / 1.0 mm, the gap's shadow σ 0.35 mm)
          float gap = exp(-(pad * pad) / 0.25);
          if (pad < 0.0) {
            alu = false;
            float e = smoothstep(-1.4, 0.0, pad);
            Nn = normalize(vec3(0.0, 1.0, 0.0) + vec3(gr.x, 0.0, gr.y) * 0.16 * e);
            F0 = vec3(0.06, 0.062, 0.067); r = mix(0.27, 0.36, e); alb = vec3(0.026, 0.027, 0.03);
          } else {
            float e = 1.0 - smoothstep(0.0, 1.0, pad);
            Nn = normalize(vec3(0.0, 1.0, 0.0) - vec3(gr.x, 0.0, gr.y) * 0.12 * e);
          }
          ao *= 1.0 - 0.5 * gap; alb *= 1.0 - 0.5 * gap;
          #endif
        } else if (pad < 0.35) {
          #ifdef FILM
          alu = false;
          #endif
          if (pad > -0.35) { F0 = vec3(0.02); r = 0.6; alb = vec3(0.003); ao *= 0.25; }
          else {
            float e = smoothstep(-1.1, -0.35, pad);
            vec2 dq = p - vec2(0.0, 63.0); vec2 ad = abs(dq) - vec2(67.0, 40.0) + 7.5; vec2 gg = ad.x > ad.y ? vec2(sign(dq.x), 0.0) : vec2(0.0, sign(dq.y));
            Nn = normalize(vec3(0.0, 1.0, 0.0) + vec3(gg.x, 0.0, gg.y) * e * 0.5);
            F0 = vec3(0.06, 0.062, 0.067); r = 0.27; alb = vec3(0.026, 0.027, 0.03);
          }
        } else if (pad < 0.8) {
          float e = 1.0 - smoothstep(0.35, 0.8, pad);
          vec2 dq = p - vec2(0.0, 63.0); vec2 ad = abs(dq) - vec2(67.0, 40.0) + 7.5; vec2 gg = ad.x > ad.y ? vec2(sign(dq.x), 0.0) : vec2(0.0, sign(dq.y));
          Nn = normalize(vec3(0.0, 1.0, 0.0) - vec3(gg.x, 0.0, gg.y) * e * 0.6);
        }
      }
      #ifdef FILM
      if (alu) anodise(L, r, alb);
      #endif
      col = shade(P, Nn, V, F0, r, alb, ao, false);
    } else if (uMat == 2) {
      vec3 lp = (uLidInv * vec4(P, 1.0)).xyz;
      vec3 ln = mat3(uLidInv) * N;
      vec3 F0 = vec3(0.075, 0.077, 0.082); float r = 0.34; vec3 alb = vec3(0.022, 0.0225, 0.025);
      float ao = occl(P, N, 0.7, 0.6);
      vec3 em = vec3(0.0);
      bool fromLid = true;
      #ifdef FILM
      bool lidAlu = true;          // the lid's anodised aluminium (not the glass or the black border round it)
      #endif
      if (ln.y < -0.98 && lp.y < 0.05) {
        float g = sdRR(lp.xz - vec2(0.0, LLEN * 0.5), vec2(${LID.hx} - 1.45, LLEN * 0.5 - 1.45), 9.0);
        #ifdef FILM
        if (g < -0.25) { F0 = vec3(0.035); r = 0.045; alb = vec3(0.0); if (uScrDrawn > 0.5) em = display(lp.xz); }
        #else
        if (g < -0.25) { F0 = vec3(0.035); r = 0.045; alb = vec3(0.0); em = display(lp.xz); }
        #endif
        else if (g < 0.0) { F0 = vec3(0.03); r = 0.6; alb = vec3(0.004); ao *= 0.6; }
        #ifdef FILM
        if (g < 0.0) lidAlu = false;
        #endif
      }
      #ifdef FILM
      if (lidAlu) anodise(lp, r, alb);
      #endif
      col = shade(P, N, V, F0, r, alb, ao, fromLid) + em;
    } else {
      col = shade(P, N, V, vec3(0.05), 0.36, vec3(0.012), occl(P, N, 0.7, 0.6), false);
    }
    #ifdef FILM
    o = vec4(col, cov);
    #else
    o = vec4(col, 1.0);
    #endif
  }
  #endif`;

  // The floating half as glyphs in space: one quad per character, its colour already linear and weighted
  const VS_G = `#version 300 es
  in vec2 aQ; in vec3 iP; in vec3 iC; in float iK;
  uniform mat4 uVP; uniform vec3 uU, uV; uniform vec2 uSz; uniform float uN;
  out vec2 vT; out vec3 vC;
  void main() {
    vec3 p = iP + uU * (aQ.x * uSz.x) + uV * (aQ.y * uSz.y);
    gl_Position = uVP * vec4(p, 1.0);
    vT = vec2((iK + aQ.x * 0.5 + 0.5) / uN, 0.5 - aQ.y * 0.5);
    vC = iC;
  }`;
  const FS_G = `#version 300 es
  precision highp float; in vec2 vT; in vec3 vC; out vec4 o; uniform sampler2D uA; uniform float uK;
  void main() { float a = texture(uA, vT).a; o = vec4(vC * a * uK, a); }`;

  const VS_FULL = `#version 300 es
  in vec2 aQ; out vec2 vUV;
  void main() { vUV = aQ * 0.5 + 0.5; gl_Position = vec4(aQ, 0.0, 1.0); }`;
  const FS_COPY = `#version 300 es
  precision highp float; in vec2 vUV; out vec4 o; uniform sampler2D uT; uniform float uK;
  void main() { o = texture(uT, vUV) * uK; }`;
  // bright parts, a quarter of the size
  const FS_DOWN = `#version 300 es
  precision highp float; in vec2 vUV; out vec4 o; uniform sampler2D uT; uniform vec2 uPx; uniform float uK; uniform float uTh;
  void main() {
    vec3 c = vec3(0.0);
    for (int y = -1; y <= 2; y++) for (int x = -1; x <= 2; x++) c += texture(uT, vUV + (vec2(x, y) - 0.5) * uPx).rgb;
    c *= uK / 16.0;
    o = vec4(max(c - uTh, 0.0), 1.0);
  }`;
  const FS_BLUR = `#version 300 es
  precision highp float; in vec2 vUV; out vec4 o; uniform sampler2D uT; uniform vec2 uDir;
  void main() {
    vec3 c = vec3(0.0); float ws = 0.0;
    for (int i = -12; i <= 12; i++) { float w = exp(-float(i * i) / 50.0); c += texture(uT, vUV + uDir * float(i)).rgb * w; ws += w; }
    o = vec4(c / ws, 1.0);
  }`;
  const FS_FINAL = `#version 300 es
  precision highp float; in vec2 vUV; out vec4 o;
  uniform sampler2D uT, uB1, uB2; uniform float uK, uExp, uBloom1, uBloom2; uniform vec3 uBg; uniform vec2 uRes;
  uniform float uEdge, uDither, uAlpha;
  float tone(float x) { const float a = 0.3; return x < a ? x : a + (1.0 - a) * (1.0 - exp(-(x - a) / (1.0 - a))); }
  vec3 l2s(vec3 c) { return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c)); }
  float h(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
  void main() {
    vec4 t = texture(uT, vUV);
    vec3 c = t.rgb * uK * uExp + texture(uB1, vUV).rgb * uBloom1 + texture(uB2, vUV).rgb * uBloom2;
    c = vec3(tone(c.r), tone(c.g), tone(c.b));
    if (uEdge > 0.5) {
      vec2 e = min(vUV, 1.0 - vUV) * uRes / min(uRes.x, uRes.y);
      float edge = smoothstep(0.0, 0.035, min(e.x, e.y));
      c = mix(uBg, c, edge);
    }
    vec3 s = l2s(clamp(c, 0.0, 1.0));
    if (uDither > 0.5) {
      vec3 sb = l2s(uBg);
      float dif = length(s - sb);
      s += (h(gl_FragCoord.xy) - 0.5) / 255.0 * smoothstep(0.0, 0.01, dif);
    }
    o = vec4(s, uAlpha > 0.5 ? clamp(t.a * uK, 0.0, 1.0) : 1.0);
  }`;

  function compile(vs, fs) {
    const mk = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s) + '\n' + src.split('\n').map((l, i) => `${i + 1}: ${l}`).join('\n')); return s; };
    const p = gl.createProgram(); gl.attachShader(p, mk(gl.VERTEX_SHADER, vs)); gl.attachShader(p, mk(gl.FRAGMENT_SHADER, fs));
    gl.bindAttribLocation(p, 0, 'aP'); gl.bindAttribLocation(p, 1, 'aN'); gl.bindAttribLocation(p, 0, 'aQ'); gl.bindAttribLocation(p, 2, 'iP'); gl.bindAttribLocation(p, 3, 'iC'); gl.bindAttribLocation(p, 4, 'iK');
    gl.linkProgram(p); if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
    const u = {}; const n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
    for (let i = 0; i < n; i++) { const info = gl.getActiveUniform(p, i); const name = info.name.replace(/\[0\]$/, ''); u[name] = gl.getUniformLocation(p, info.name); }
    return { p, u };
  }
  function mesh(m) {
    const vao = gl.createVertexArray(); gl.bindVertexArray(vao);
    const b = (data, loc) => { const buf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, buf); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(data), gl.STATIC_DRAW); gl.enableVertexAttribArray(loc); gl.vertexAttribPointer(loc, 3, gl.FLOAT, false, 0, 0); };
    b(m.P, 0); b(m.N, 1);
    const ib = gl.createBuffer(); gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ib); gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint32Array(m.I), gl.STATIC_DRAW);
    gl.bindVertexArray(null);
    return { vao, n: m.I.length };
  }
  function target(w, h, fmt, depth) {
    const tex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texStorage2D(gl.TEXTURE_2D, 1, fmt, w, h);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    const fb = gl.createFramebuffer(); gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
    gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
    if (depth) { const rb = gl.createRenderbuffer(); gl.bindRenderbuffer(gl.RENDERBUFFER, rb); gl.renderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT24, w, h); gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, rb); }
    const st = gl.checkFramebufferStatus(gl.FRAMEBUFFER); if (st !== gl.FRAMEBUFFER_COMPLETE) throw new Error('fbo ' + st);
    return { tex, fb, w, h };
  }
  function texFrom(canvasEl, tex) {
    if (!tex) { tex = gl.createTexture(); }
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, canvasEl);
    gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return tex;
  }

  let filmProgs = {}, progDepth = null, progGlyph, glyphVao, glyphBuf, atlas = null, glyphN = 0, progMain, progCopy, progDown, progBlur, progFinal, meshes, fsq, rtFrame, rtRefl, rtReflB, rtAcc, rtB1, rtB2, rtC1, rtC2, rtOut, rtCyc, scrTex, halfTex, legend = null;
  function init(w, h) {
    W = w; H = h; canvas.width = w; canvas.height = h;
    gl = canvas.getContext('webgl2', { antialias: false, preserveDrawingBuffer: true, alpha: false });
    if (!gl.getExtension('EXT_color_buffer_float')) throw new Error('no float buffers');
    gl.getExtension('OES_texture_float_linear');
    progMain = compile(VS, FS); filmProgs = {}; progGlyph = compile(VS_G, FS_G);
    glyphVao = gl.createVertexArray(); gl.bindVertexArray(glyphVao);
    const cq = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, cq); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    glyphBuf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, glyphBuf);
    gl.enableVertexAttribArray(2); gl.vertexAttribPointer(2, 3, gl.FLOAT, false, 28, 0); gl.vertexAttribDivisor(2, 1);
    gl.enableVertexAttribArray(3); gl.vertexAttribPointer(3, 3, gl.FLOAT, false, 28, 12); gl.vertexAttribDivisor(3, 1);
    gl.enableVertexAttribArray(4); gl.vertexAttribPointer(4, 1, gl.FLOAT, false, 28, 24); gl.vertexAttribDivisor(4, 1);
    gl.bindVertexArray(null);
    progCopy = compile(VS_FULL, FS_COPY); progDown = compile(VS_FULL, FS_DOWN); progBlur = compile(VS_FULL, FS_BLUR); progFinal = compile(VS_FULL, FS_FINAL);
    meshes = { base: mesh(slab(BASE)), lid: mesh(slab({ hx: LID.hx, hz: LID.len / 2, rc: LID.rc, y0: 0, y1: LID.t, rb: LID.rin, rt: LID.rout })), hinge: mesh(barrel(HINGE.r, HINGE.hx)), floor: mesh(quad(6000)), cyc: mesh(cycMesh()) };
    fsq = gl.createVertexArray(); gl.bindVertexArray(fsq);
    const qb = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, qb); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0); gl.bindVertexArray(null);
    rtFrame = target(w, h, gl.RGBA16F, true); rtAcc = target(w, h, gl.RGBA32F, false);
    rtB1 = target(w >> 2, h >> 2, gl.RGBA16F, false); rtB2 = target(w >> 2, h >> 2, gl.RGBA16F, false);
    rtC1 = target(w >> 4, h >> 4, gl.RGBA16F, false); rtC2 = target(w >> 4, h >> 4, gl.RGBA16F, false);
    rtOut = null;                    // the float output (made on the first frame that asks for it)
    rtCyc = null;                    // the cyclorama's softbox light, once per frame (made when first needed)
    rtRefl = null;                   // the floor reflection's target (made when first needed)
    legend = null;                   // the key legends' atlas (made when first needed)
    return { ok: true, renderer: gl.getParameter(gl.RENDERER) };
  }
  const full = () => { gl.bindVertexArray(fsq); gl.drawArrays(gl.TRIANGLES, 0, 3); };

  /// The lid's local -> world matrix for an opening angle (degrees; 0 closed).
  const lidMatrix = (deg) => M.mul(M.mul(M.T(0, HINGE.y, HINGE.z), M.Rx(-deg * Math.PI / 180)), M.T(0, HINGE.dIn, HINGE.l0));

  // MARK: The screen and the floating half, painted with the site's code art
  const SCR = { w: 2048, h: Math.round(2048 * DISP.h / DISP.w) };
  const scrCanvas = document.createElement('canvas'); scrCanvas.width = SCR.w; scrCanvas.height = SCR.h;
  const halfCanvas = document.createElement('canvas');
  /// The mark's layout on the display, in texture pixels.
  function markLayout(o) {
    const R = SCR.h * (o.r || 0.3);
    const LH = R / (o.rows || (o.look === 'neutral' ? 20 : 13));
    return { cx: SCR.w * (o.cx ?? 0.5), cy: SCR.h * (o.cy ?? 0.49), R, LH, fs: LH * 0.8 };
  }
  // An image on the display instead of the mark (HERO.setScreen): what the film shows on the Mac.
  let screenImg = null;
  function setScreen(url) {
    if (!url) { screenImg = null; return Promise.resolve(); }
    const img = new Image();
    img.src = url;
    return img.decode().then(() => { screenImg = img; });
  }
  function paintScreen(o) {
    const { paintHalves, paintSeam, tokenMaps, MONO } = window.CodeArt;
    const ctx = scrCanvas.getContext('2d');
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.fillStyle = '#000'; ctx.fillRect(0, 0, SCR.w, SCR.h);
    if (o.on <= 0) return;
    if (o.image && screenImg) {
      // cover the active area, centred; `on` dims it (a display waking)
      const k = Math.max(SCR.w / screenImg.width, SCR.h / screenImg.height);
      const w = screenImg.width * k, h = screenImg.height * k;
      ctx.globalAlpha = Math.min(1, o.on);
      ctx.drawImage(screenImg, (SCR.w - w) / 2, (SCR.h - h) / 2, w, h);
      ctx.globalAlpha = 1;
      return null;
    }
    const L = markLayout(o);
    if (o.look === 'neutral') return paintNeutral(ctx, o, L);
    // a deep, quiet glow behind the mark, so the panel reads as lit
    const bk = (o.bg ?? 1) * o.on;
    ctx.fillStyle = `rgba(7,11,24,${Math.min(1, bk).toFixed(3)})`; ctx.fillRect(0, 0, SCR.w, SCR.h);
    const g = ctx.createRadialGradient(L.cx, L.cy, 0, L.cx, L.cy, SCR.w * 0.62);
    g.addColorStop(0, `rgba(30,52,116,${Math.min(1, 0.62 * bk).toFixed(3)})`); g.addColorStop(0.45, `rgba(13,23,56,${Math.min(1, 0.55 * bk).toFixed(3)})`); g.addColorStop(1, 'rgba(0,0,0,0)');
    ctx.fillStyle = g; ctx.fillRect(0, 0, SCR.w, SCR.h);
    const off = document.createElement('canvas'); off.width = SCR.w; off.height = SCR.h;
    const c2 = off.getContext('2d'); c2.font = `${L.fs}px ${MONO}`; c2.textBaseline = 'middle';
    const cw = c2.measureText('0').width;
    const tokens = tokenMaps(L, cw);
    const which = o.lifted ? [1] : [0, 1];
    paintHalves(c2, cw, L, { which, ghost: o.lifted ? o.ghost : 0, gain: o.on, gains: [1, o.rightGain ?? 1], flat: o.flat ?? 0, tokens });
    paintSeam(c2, L, o.seam ?? 1, (o.seam ?? 1) * o.on, L.LH / 12);
    ctx.save(); ctx.filter = `blur(${(L.LH * 0.42).toFixed(1)}px)`; ctx.globalAlpha = 0.75; ctx.drawImage(off, 0, 0); ctx.restore();
    ctx.drawImage(off, 0, 0);
    return { L, cw };
  }
  /// The film's mark (screen.look 'neutral'): true black, neutral inks, 20 rows, one flat 3 px #2F6BEF seam,
  /// no glow, no blur pass. screen.fill (0 → 1) cross-fills the characters into the solid split glyph
  /// (LumenMarkGeometry), keeping the seam.
  function paintNeutral(ctx, o, L) {
    const { paintHalves, paintSeamFlat, paintSolid, tokenMaps, LOOKS, MONO } = window.CodeArt;
    const lk = LOOKS.neutral;
    ctx.font = `${L.fs}px ${MONO}`; ctx.textBaseline = 'middle';
    const cw = ctx.measureText('0').width;
    const which = o.lifted ? [1] : [0, 1];
    const fill = Math.max(0, Math.min(1, o.fill ?? 0));
    if (fill < 1) paintHalves(ctx, cw, L, { which, ghost: 0, gain: o.on * (1 - fill), gains: [1, o.rightGain ?? 1], flat: o.flat ?? 0, tokens: tokenMaps(L, cw, lk.tokens), inks: lk.inks, edgeRGB: lk.edge, ghostRGB: lk.ghost });
    if (fill > 0) paintSolid(ctx, L, fill * o.on, o.solid || lk.solid, which);
    paintSeamFlat(ctx, L, o.seam ?? 1, (o.seam ?? 1) * o.on, o.seamPx ?? lk.seamPx, lk.seam);
    return { L, cw, look: 'neutral' };
  }
  /// The left half alone, on black, in a square canvas round the half's own centre.
  function paintHalf(o, L, look) {
    const { paintHalves, tokenMaps, MONO, OFF } = window.CodeArt;
    const hcx = L.cx - OFF[0] * L.R, hcy = L.cy - OFF[1] * L.R;
    const ext = L.R * 1.25;
    const size = Math.round(ext * 2);
    halfCanvas.width = size; halfCanvas.height = size;
    const ctx = halfCanvas.getContext('2d');
    ctx.fillStyle = '#000'; ctx.fillRect(0, 0, size, size);
    const off = document.createElement('canvas'); off.width = size; off.height = size;
    const c2 = off.getContext('2d'); c2.font = `${L.fs}px ${MONO}`; c2.textBaseline = 'middle';
    // keep the same character grid as on the display: shift by whole cells
    const cw = c2.measureText('0').width;
    const sx = Math.round((hcx - ext) / cw) * cw, sy = Math.round((hcy - ext) / L.LH) * L.LH;
    const L2 = { ...L, cx: L.cx - sx, cy: L.cy - sy };
    if (look === 'neutral') {
      // the film: the same characters, no blur pass
      const lk = window.CodeArt.LOOKS.neutral;
      paintHalves(c2, cw, L2, { which: [0], gain: 1, tokens: tokenMaps(L2, cw, lk.tokens), inks: lk.inks, edgeRGB: lk.edge });
    } else {
      paintHalves(c2, cw, L2, { which: [0], gain: 1, tokens: tokenMaps(L2, cw) });
      ctx.save(); ctx.filter = `blur(${(L.LH * (o.glow ?? 0.55)).toFixed(1)}px)`; ctx.globalAlpha = 0.85; ctx.drawImage(off, 0, 0); ctx.restore();
    }
    ctx.drawImage(off, 0, 0);
    // centre of this canvas in display texture px, and its half size
    return { cx: sx + size / 2, cy: sy + size / 2, half: size / 2 };
  }
  /// Glyph atlases (crisp, and blurred with room round it for the glow), white on transparent.
  const GLYPHS = '01' + [...new Set('de-DE Europe/Berlin cookies store en-US America/New_York ads'.replace(/ /g, ''))].join('');
  /// The characters a look's tokens need ('01' first).
  const glyphSet = (look) => look === 'neutral'
    ? '01' + [...new Set(window.CodeArt.LOOKS.neutral.tokens.flat().map((t) => t[2]).join('').replace(/[01 ]/g, ''))].join('')
    : GLYPHS;
  function buildAtlas(cwRatio, GLYPHS) {
    const ch = 100, cw = Math.round(ch * cwRatio), n = GLYPHS.length;
    const mk = (pad, blur) => {
      const c = document.createElement('canvas'); c.width = n * cw * pad; c.height = ch * pad;
      const x = c.getContext('2d'); x.fillStyle = '#fff'; x.font = `${ch * 0.8}px ${window.CodeArt.MONO}`; x.textBaseline = 'middle';
      if (blur) x.filter = `blur(${blur}px)`;
      for (let i = 0; i < n; i++) x.fillText(GLYPHS[i], i * cw * pad + (pad - 1) * cw / 2, c.height / 2);
      const t = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, t);
      gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, c); gl.generateMipmap(gl.TEXTURE_2D);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      return t;
    };
    return { crisp: mk(1, 0), glow: mk(3, 16), n, glyphs: GLYPHS, ratio: cwRatio };
  }
  /// The left half's characters in the half's own frame (mm; z out of the glass on a dome of height D).
  function glyphInstances(o, L, anchor, mmPerPx, gain, look) {
    const { eachChar, tokenMaps, MONO, LOOKS } = window.CodeArt;
    const c2 = scrCanvas.getContext('2d'); c2.font = `${L.fs}px ${MONO}`;
    const cw = c2.measureText('0').width;
    const gs = glyphSet(look);
    if (!atlas || atlas.glyphs !== gs || atlas.ratio !== cw / L.LH) atlas = buildAtlas(cw / L.LH, gs);
    const Rmm = L.R * mmPerPx, D = (o.dome ?? 0.42) * Rmm;
    const out = [];
    const lk = look === 'neutral' ? LOOKS.neutral : null;
    const opts = lk ? { which: [0], gain: 1, tokens: tokenMaps(L, cw, lk.tokens), inks: lk.inks, edgeRGB: lk.edge } : { which: [0], gain: 1, tokens: tokenMaps(L, cw) };
    eachChar(cw, L, opts, (ch, x, y, a, rgb, m) => {
      const k = gs.indexOf(ch); if (k < 0) return;
      const r2 = m.qx * m.qx + m.qy * m.qy;
      const z = D * Math.sqrt(Math.max(0, 1 - r2));
      const col = rgb.split(',').map((v) => s2l(Math.min(1, a) * (+v)) * gain);
      out.push((x + cw / 2 - anchor[0]) * mmPerPx, -(y - anchor[1]) * mmPerPx, z, ...col, k);
    });
    return { data: new Float32Array(out), n: out.length / 7, size: [cw / 2 * mmPerPx, L.LH / 2 * mmPerPx] };
  }

  /// Display texture px -> lid-local (x, z).
  const pxToLid = (x, y) => [-DISP.w / 2 + (x / SCR.w) * DISP.w, DISP.top - (y / SCR.h) * DISP.h];

  // MARK: Key legends (the film, o.legends): the print on every key, US layout (MacBook Pro 14", function row of
  // icons, Touch ID bare), Inter 500, white on transparent in a 2048 × 1024 atlas at 7.5 px/mm. Cell k is key k's
  // cap as keyAt() indexes it (row * 14 + column; 84 the up arrow, which shares a column with down). The shader
  // mixes the ink (#8E8E93 at 35% by default) over the key's albedo by the atlas's alpha.
  const KEYROWS = [[1.5, ...Array(12).fill(1), 1], [...Array(13).fill(1), 1.5], [1.5, ...Array(13).fill(1)], [1.75, ...Array(11).fill(1), 1.75], [2.25, ...Array(10).fill(1), 2.25], [1, 1, 1, 1.25, 5, 1.25, 1, 1, 1, 1]];
  const KEY_PITCH = 18.7;
  const LEG_ICONS = ['sunS', 'sunL', 'mission', 'spot', 'mic', 'moon', 'rew', 'play', 'ff', 'mute', 'volD', 'volU'];
  /// What is printed on key k: a list of items. c: centred glyph; st: two stacked glyphs (shifted above, plain
  /// below); w: a word (at: bl, br, b); s: a symbol (at: tl, tr); i: an icon; dot: the caps lock light.
  function legendOf(k) {
    const row = Math.floor(k / 14), col = k % 14;
    if (k === 84) return [{ i: 'up' }];
    if (row === 0) return col === 0 ? [{ w: 'esc', at: 'bl' }] : col <= 12 ? [{ i: LEG_ICONS[col - 1] }] : [];
    if (row === 1) { if (col === 13) return [{ w: 'delete', at: 'br' }]; const t = '~!@#$%^&*()_+', b = '`1234567890-='; return [{ st: [t[col], b[col]] }]; }
    if (row === 2) { if (col === 0) return [{ w: 'tab', at: 'bl' }]; const c = 'QWERTYUIOP'; if (col <= 10) return [{ c: c[col - 1] }]; return [{ st: [['{', '}', '|'][col - 11], ['[', ']', '\\'][col - 11]] }]; }
    if (row === 3) { if (col === 0) return [{ w: 'caps lock', at: 'bl' }, { dot: true }]; if (col === 12) return [{ w: 'return', at: 'br' }]; if (col <= 9) return [{ c: 'ASDFGHJKL'[col - 1] }]; return [{ st: [[':', '"'][col - 10], [';', "'"][col - 10]] }]; }
    if (row === 4) { if (col === 0) return [{ w: 'shift', at: 'bl' }]; if (col === 11) return [{ w: 'shift', at: 'br' }]; if (col <= 7) return [{ c: 'ZXCVBNM'[col - 1] }]; return [{ st: [['<', '>', '?'][col - 8], [',', '.', '/'][col - 8]] }]; }
    return [[{ s: 'fn', at: 'tr' }, { i: 'globe', at: 'bl' }], [{ s: '⌃', at: 'tr' }, { w: 'control', at: 'b' }], [{ s: '⌥', at: 'tr' }, { w: 'option', at: 'b' }], [{ s: '⌘', at: 'tr' }, { w: 'command', at: 'b' }], [],
      [{ s: '⌘', at: 'tl' }, { w: 'command', at: 'b' }], [{ s: '⌥', at: 'tl' }, { w: 'option', at: 'b' }], [{ i: 'left' }], [{ i: 'down' }], [{ i: 'right' }]][col];
  }
  /// The cap's half size (mm) of key k, as keyAt() makes it (1.55 mm inset; the arrows are half height).
  function capOf(k) {
    const row = k === 84 ? 5 : Math.floor(k / 14), col = k === 84 ? 8 : k % 14;
    const w = KEYROWS[row][col];
    return [w * KEY_PITCH / 2 - 1.55, row === 5 && col >= 7 ? KEY_PITCH * 0.25 - 0.9 : KEY_PITCH / 2 - 1.55];
  }
  function buildLegends() {
    const AW = 2048, AH = 1024, PX = 7.5, PAD = 8;
    const c = document.createElement('canvas'); c.width = AW; c.height = AH;
    const x = c.getContext('2d');
    x.clearRect(0, 0, AW, AH); x.fillStyle = '#fff'; x.strokeStyle = '#fff'; x.lineCap = 'round'; x.lineJoin = 'round';
    const cells = new Float32Array(85 * 4);
    const font = (mm) => `500 ${(mm * PX).toFixed(1)}px Inter, "DejaVu Sans", sans-serif`;
    let cx = PAD, cy = PAD, shelf = 0;
    const keys = [];
    for (let row = 0; row < 6; row++) for (let col = 0; col < KEYROWS[row].length; col++) keys.push(row * 14 + col);
    keys.push(84);
    for (const k of keys) {
      const items = legendOf(k);
      if (!items || !items.length) continue;
      const [hx, hy] = capOf(k);
      const w = Math.ceil(2 * hx * PX), h = Math.ceil(2 * hy * PX);
      if (cx + w + PAD > AW) { cx = PAD; cy += shelf + PAD; shelf = 0; }
      if (cy + h + PAD > AH) throw new Error('legend atlas full');
      cells.set([cx / AW, cy / AH, w / AW, h / AH], k * 4);
      x.save(); x.translate(cx, cy); x.beginPath(); x.rect(0, 0, w, h); x.clip();
      const mm = (v) => v * PX, W2 = w / 2, H2 = h / 2;
      for (const it of items) {
        if (it.c) { x.font = font(4.0); x.textAlign = 'center'; x.textBaseline = 'alphabetic'; x.fillText(it.c, W2, H2 + mm(4.0 * 0.727 / 2)); }
        else if (it.st) { x.font = font(3.3); x.textAlign = 'center'; x.textBaseline = 'middle'; x.fillText(it.st[0], W2, H2 - mm(2.5)); x.fillText(it.st[1], W2, H2 + mm(2.5)); }
        else if (it.w) {
          x.font = font(2.3); x.textBaseline = 'alphabetic';
          x.textAlign = it.at === 'bl' ? 'left' : it.at === 'br' ? 'right' : 'center';
          x.fillText(it.w, it.at === 'bl' ? mm(1.5) : it.at === 'br' ? w - mm(1.5) : W2, h - mm(1.7));
        }
        else if (it.s) {
          x.font = font(it.s === 'fn' ? 2.3 : 3.0); x.textBaseline = 'top';
          x.textAlign = it.at === 'tl' ? 'left' : 'right';
          x.fillText(it.s, it.at === 'tl' ? mm(1.5) : w - mm(1.5), mm(1.4));
        }
        else if (it.dot) { x.beginPath(); x.arc(mm(2.0), mm(2.0), mm(0.45), 0, Math.PI * 2); x.fill(); }
        else if (it.i) legendIcon(x, it.i, it.at === 'bl' ? mm(3.0) : W2, it.at === 'bl' ? h - mm(3.0) : H2, PX);
      }
      x.restore();
      cx += w + PAD; shelf = Math.max(shelf, h);
    }
    const tex = gl.createTexture(); gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, c); gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return { tex, cells, canvas: c };
  }
  /// The function row's icons, the globe and the arrows, centred on (cx, cy), in mm × px (line 0.28 mm).
  function legendIcon(x, name, cx, cy, PX) {
    const m = (v) => v * PX;
    x.save(); x.translate(cx, cy); x.lineWidth = m(0.28); x.beginPath();
    const circle = (r, fill) => { x.beginPath(); x.arc(0, 0, m(r), 0, Math.PI * 2); fill ? x.fill() : x.stroke(); };
    const rays = (r0, r1, n) => { x.beginPath(); for (let i = 0; i < n; i++) { const a = i * Math.PI * 2 / n; x.moveTo(Math.cos(a) * m(r0), Math.sin(a) * m(r0)); x.lineTo(Math.cos(a) * m(r1), Math.sin(a) * m(r1)); } x.stroke(); };
    const tri = (dx, dir, s) => { x.beginPath(); x.moveTo(m(dx + dir * s), 0); x.lineTo(m(dx - dir * s), m(-s)); x.lineTo(m(dx - dir * s), m(s)); x.closePath(); x.fill(); };
    const tri2 = (dir, s) => { x.beginPath(); x.moveTo(0, m(-dir * s)); x.lineTo(m(s), m(dir * s)); x.lineTo(m(-s), m(dir * s)); x.closePath(); x.fill(); };
    const speaker = (dx) => { x.beginPath(); x.moveTo(m(dx - 1.0), m(-0.45)); x.lineTo(m(dx - 0.5), m(-0.45)); x.lineTo(m(dx + 0.2), m(-1.0)); x.lineTo(m(dx + 0.2), m(1.0)); x.lineTo(m(dx - 0.5), m(0.45)); x.lineTo(m(dx - 1.0), m(0.45)); x.closePath(); x.fill(); };
    const waves = (dx, n) => { for (let i = 0; i < n; i++) { x.beginPath(); x.arc(m(dx), 0, m(0.6 + i * 0.5), -0.75, 0.75); x.stroke(); } };
    switch (name) {
      case 'sunS': circle(0.55, true); rays(0.95, 1.35, 8); break;
      case 'sunL': circle(0.75, true); rays(1.2, 1.85, 8); break;
      case 'mission': x.strokeRect(m(-1.7), m(-1.2), m(1.4), m(1.0)); x.strokeRect(m(0.3), m(-1.2), m(1.4), m(1.0)); x.strokeRect(m(-1.7), m(0.25), m(3.4), m(1.0)); break;
      case 'spot': x.beginPath(); x.arc(m(-0.3), m(-0.3), m(0.95), 0, Math.PI * 2); x.stroke(); x.beginPath(); x.moveTo(m(0.4), m(0.4)); x.lineTo(m(1.3), m(1.3)); x.stroke(); break;
      case 'mic': x.beginPath(); x.moveTo(m(-0.5), m(-0.9)); x.arc(0, m(-0.9), m(0.5), Math.PI, 0); x.lineTo(m(0.5), m(0.0)); x.arc(0, 0, m(0.5), 0, Math.PI); x.closePath(); x.fill(); x.beginPath(); x.arc(0, m(-0.1), m(0.95), 0.15, Math.PI - 0.15); x.stroke(); x.beginPath(); x.moveTo(0, m(0.85)); x.lineTo(0, m(1.4)); x.stroke(); break;
      case 'moon': circle(1.2, true); x.globalCompositeOperation = 'destination-out'; x.beginPath(); x.arc(m(0.6), m(-0.45), m(1.0), 0, Math.PI * 2); x.fill(); break;
      case 'rew': tri(-0.7, -1, 0.75); tri(0.55, -1, 0.75); break;
      case 'play': tri(-0.75, 1, 0.75); x.fillRect(m(0.35), m(-0.75), m(0.38), m(1.5)); x.fillRect(m(1.0), m(-0.75), m(0.38), m(1.5)); break;
      case 'ff': tri(-0.55, 1, 0.75); tri(0.7, 1, 0.75); break;
      case 'mute': speaker(0); break;
      case 'volD': speaker(-0.4); waves(-0.2, 1); break;
      case 'volU': speaker(-0.8); waves(-0.6, 3); break;
      case 'globe': circle(1.05, false); x.beginPath(); x.ellipse(0, 0, m(0.45), m(1.05), 0, 0, Math.PI * 2); x.moveTo(m(-1.05), 0); x.lineTo(m(1.05), 0); x.stroke(); break;
      case 'up': tri2(1, 0.65); break;
      case 'down': tri2(-1, 0.65); break;
      case 'left': tri(0, -1, 0.65); break;
      case 'right': tri(0, 1, 0.65); break;
    }
    x.restore();
  }

  // MARK: Lights (softboxes): centre, half axes U and V (they face along U x V), colour * intensity
  function lights(o) {
    const L = o.lights || LIGHTS;
    if (L.length > 12) throw new Error('at most 12 lights');
    const out = { c: [], u: [], v: [], col: [], mk: [], ck: [], n: L.length };
    const cr = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
    const nz = (v) => { const l = Math.hypot(...v); return v.map((x) => x / l); };
    for (const l of L) {
      // each box faces its target (the laptop by default); w across, h upright, then rolled
      const tg = l.at || [0, 60, 0];
      const n = nz([tg[0] - l.c[0], tg[1] - l.c[1], tg[2] - l.c[2]]);
      let x = nz(cr(Math.abs(n[1]) > 0.97 ? [0, 0, -1] : [0, 1, 0], n));
      let y = cr(n, x);
      const r = (l.roll || 0) * Math.PI / 180, cs = Math.cos(r), sn = Math.sin(r);
      const xr = x.map((q, i) => q * cs + y[i] * sn), yr = y.map((q, i) => -x[i] * sn + q * cs);
      out.c.push(...l.c); out.u.push(...xr.map((q) => q * l.w)); out.v.push(...yr.map((q) => q * l.h));
      out.col.push(...(l.col || [1, 1, 1]).map((q) => q * l.k));
      // mac / cyc: multipliers on how strongly this box lights the Mac and the cyclorama (1 each by default);
      // e.g. the reflection cards that stand in for the lit studio light the Mac only (cyc: 0)
      out.mk.push(l.mac ?? 1); out.ck.push(l.cyc ?? 1);
    }
    return out;
  }
  // The studio. Boxes: centre, half width w, half height h, intensity k (and roll, target).
  const LIGHTS = [
    // a broad box overhead, a little behind: the sheen on the deck
    { c: [0, 1300, -250], w: 800, h: 300, k: 2.8 },
    // a long strip high behind the lid: the rim of light along its top edge
    { c: [0, 1250, -1600], w: 1300, h: 110, k: 8.0 },
    // tall strips high left and right, behind: the long lights down the edges
    { c: [-1300, 1300, -1000], w: 200, h: 600, k: 3.0 },
    { c: [1300, 1250, -900], w: 200, h: 560, k: 2.4 },
    // a low wide strip in front: the line of light along the base's front edge
    { c: [0, 160, 1700], w: 1100, h: 60, k: 1.0 },
  ];

  // MARK: Geometry export (no rendering)
  /// The projection of a parameter set: proj · view (with lens shift) and the lid matrix, for a w × h frame.
  function camera(o, w = W, h = H) {
    const proj = M.persp(o.fov * Math.PI / 180, w / h, 50, 20000);
    // lens shift (moves the picture in the frame without turning the camera)
    if (o.shift) { proj[8] += o.shift[0]; proj[9] += o.shift[1]; }
    const view = M.lookAt(o.eye, o.target, [0, 1, 0]);
    return { proj, view, vp: M.mul(proj, view), lid: lidMatrix(o.lid) };
  }
  /// World point -> frame px (origin at the frame's top-left corner, y down; pixel centres at +0.5).
  const pxOf = (vp, w, h) => (p) => { const q = [vp[0] * p[0] + vp[4] * p[1] + vp[8] * p[2] + vp[12], vp[1] * p[0] + vp[5] * p[1] + vp[9] * p[2] + vp[13], 0, vp[3] * p[0] + vp[7] * p[1] + vp[11] * p[2] + vp[15]]; return [(q[0] / q[3] * 0.5 + 0.5) * w, (1 - (q[1] / q[3] * 0.5 + 0.5)) * h]; };
  /// The notch as the shader cuts it (display(): a rounded rectangle, half size 15.4 × 4.6 mm, radius 2.4, its
  /// centre 3.6 mm below the active area's top), as a polygon in lid-local (x, z), clockwise as seen from the
  /// front; its top edge lies 1 mm above the active area (outside it).
  const NOTCH = (() => {
    const cx = 0, cz = DISP.top - 3.6, hx = 15.4, hz = 4.6, r = 2.4, seg = 6, out = [];
    // corners in the order top-left, top-right, bottom-right, bottom-left (z up), each an arc of radius r
    const C = [[-hx + r, cz + hz - r, Math.PI, Math.PI / 2], [hx - r, cz + hz - r, Math.PI / 2, 0], [hx - r, cz - hz + r, 0, -Math.PI / 2], [-hx + r, cz - hz + r, -Math.PI / 2, -Math.PI]];
    for (const [x, z, a0, a1] of C) for (let i = 0; i <= seg; i++) { const a = a0 + (a1 - a0) * i / seg; out.push([cx + x + r * Math.cos(a), z + r * Math.sin(a)]); }
    return out;
  })();
  /// Where the display lands in a frame, without rendering (HERO.corners): the active area's corners (top-left,
  /// top-right, bottom-right, bottom-left), the notch polygon and the top corners' radius (9 mm, as drawn),
  /// in px of a w × h frame (o.w, o.h; the renderer's size by default). Same projection as frame().
  function corners(o) {
    const w = o.w || W, h = o.h || H;
    const { vp, lid } = camera(o, w, h);
    const px = pxOf(vp, w, h);
    const at = (x, z) => px(M.xf(lid, [x, 0, z]));
    const r2 = (p) => p.map((v) => +v.toFixed(3));
    const hw = DISP.w / 2, top = DISP.top, bot = DISP.top - DISP.h, RC = 9.0;
    const display = [[-hw, top], [hw, top], [hw, bot], [-hw, bot]].map(([x, z]) => r2(at(x, z)));
    const notch = NOTCH.map(([x, z]) => r2(at(x, z)));
    // the radius in px: the 9 mm run along the top edge and down the side, at both top corners, averaged
    const len = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);
    const radii = [len(at(-hw, top), at(-hw + RC, top)), len(at(-hw, top), at(-hw, top - RC)), len(at(hw, top), at(hw - RC, top)), len(at(hw, top), at(hw, top - RC))];
    return { display, notch, radius: +(radii.reduce((a, b) => a + b, 0) / 4).toFixed(3), radii: radii.map((v) => +v.toFixed(3)) };
  }
  /// The display in world space for a lid angle: centre, outward normal, up (along the glass), size (mm).
  function displayFrame(deg) {
    const lid = lidMatrix(deg);
    const c = M.xf(lid, [0, 0, DISP.top - DISP.h / 2]);
    const nz = (v) => { const l = Math.hypot(...v); return v.map((x) => x / l); };
    return { centre: c, normal: nz(M.xv(lid, [0, -1, 0])), up: nz(M.xv(lid, [0, 0, 1])), w: DISP.w, h: DISP.h };
  }

  // MARK: One frame
  /// o: { eye, target, fov (deg), lid (deg), screen: {on, lifted, ghost, seam, r, rows, cx, cy},
  ///      half: {lift, dx, dy, yaw, pitch, gain, glow} | null, passes, spp, exposure, bloom, pool, shift }
  /// Opt-in (the defaults keep the site's hero exactly as it was):
  ///   cyc: true         the graphite cyclorama instead of the floor quad (no pool, no backdrop colour, no edge
  ///                     fade, no dither: the plate is clean for post); contact: [brightness at contact, falloff mm]
  ///   mac: false        the empty studio (no Mac, no display light)
  ///   lights: [...]     the rig; each box may carry mac / cyc multipliers (how strongly it lights each)
  ///   screen.drawn: false   the display lights the scene, but its glass shows only the reflection
  ///   screen.look: 'neutral' (+ fill 0..1)   the film's mark (codeart.js LOOKS.neutral)
  ///   strat: true       stratify the textured lights' samples across the passes (less noise)
  ///   neutral: true     grey materials (no tint)
  ///   float: true       the final pass renders to an RGBA16F target; HERO.raw() reads it
  ///   edge, dither      the final pass's edge fade and dither (default on, off with cyc)
  ///   bloomTh, bloom    bloom threshold (linear) and weights
  ///   a, b: { eye, target, fov, shift, lid, half }   the shutter (motion blur inside the passes): the moving
  ///                     parameters at its opening and closing. Pass p renders the camera, the lid and the half at
  ///                     lerp(a, b, t_p), t_p stratified over the passes with a mean of exactly 0.5 (the frame's own
  ///                     moment, which o describes); the display's picture and the half's are painted once, from o
  ///   legends: true     the keys' legends (US layout, Inter 500, #8E8E93 at 35% over the key's albedo); or
  ///                     { color: [r, g, b] (sRGB 0–255), opacity }
  ///   fine: true        Touch ID's recessed ring; the trackpad's faint bevel and gap (no dotted outline)
  ///   micro: true | k   the anodised micro-texture on the base's and lid's aluminium: roughness ±0.04 (fbm, 2 mm)
  ///                     and albedo ±3% (fbm, 5 mm), × k
  ///   reflect: true | k the satin floor reflection: base, lid and hinge mirrored in the floor, 4% × Fresnel,
  ///                     fading as exp(−height / 25 mm), × k; reflectBlur: its spread (degrees, 4); reflectScale:
  ///                     its render size as a fraction of the frame (0.5); reflectSoft: a small blur on it (0.4)
  function frame(o) {
    const t0 = performance.now();
    const passes = o.passes || 16;
    const cyc = !!o.cyc, mac = o.mac !== false;
    const moving = !!(o.a && o.b);
    const refl = !!(o.reflect && mac), reflK = o.reflect === true ? 1 : +o.reflect || 0;
    const micro = o.micro === true ? 1 : +o.micro || 0;
    // the FILM variant of the shader (the site's hero keeps the original one, bit for bit)
    const film = !!(cyc || !mac || o.strat || o.neutral || (o.screen && o.screen.drawn === false) || (o.lights && (o.lights.length > 5 || o.lights.some((l) => l.mac != null || l.cyc != null))) || o.legends || o.fine || micro || refl || moving);
    // FILM programs are compiled per light count (an exact loop: SwiftShader runs untaken iterations too)
    const filmProg = (n, extra = '') => {
      const key = n + extra;
      if (!filmProgs[key]) filmProgs[key] = compile(VS, FS.replace('#version 300 es', `#version 300 es\n  #define FILM 1\n  #define NLIGHT ${n}${extra}`));
      return filmProgs[key];
    };
    const { proj, view, lid } = camera(o);
    const lidInv = M.inv(lid);
    const scr = mac ? paintScreen({ ...(o.screen || {}), lifted: !!(o.half && o.half.gain > 0) }) : null;
    scrTex = texFrom(scrCanvas, scrTex);
    const look = o.screen && o.screen.look;
    let half = null, halfAt = null, gi = null;
    /// The half's characters at their world positions for its frame m0 (the glyph pass's instances).
    const uploadGlyphs = (m0) => {
      const wpos = new Float32Array(gi.data.length);
      for (let i = 0; i < gi.n; i++) { const b = i * 7; const w = M.xf(m0, [gi.data[b], gi.data[b + 1], gi.data[b + 2]]); wpos.set([w[0], w[1], w[2], gi.data[b + 3], gi.data[b + 4], gi.data[b + 5], gi.data[b + 6]], b); }
      gl.bindBuffer(gl.ARRAY_BUFFER, glyphBuf); gl.bufferData(gl.ARRAY_BUFFER, wpos, gl.DYNAMIC_DRAW);
    };
    if (mac && o.half && o.half.gain > 0 && scr) {
      const h = paintHalf(o.half, scr.L, look);
      halfTex = texFrom(halfCanvas, halfTex);
      const [lx, lz] = pxToLid(h.cx, h.cy);
      const hs = h.half / SCR.w * DISP.w;
      // the half's frame in lid space: on the glass, then lifted along the glass's normal (-y, towards us)
      halfAt = (lidM, hp) => {
        let hm = M.mul(lidM, M.T(lx + (hp.dx || 0), -0.4 - (hp.lift || 0), lz + (hp.dy || 0)));
        hm = M.mul(hm, M.Rx(Math.PI / 2));                 // plane z -> lid -y
        hm = M.mul(hm, M.Ry((hp.yaw || 0) * Math.PI / 180));
        hm = M.mul(hm, M.Rx((hp.pitch || 0) * Math.PI / 180));
        const hm0 = hm;
        hm = M.mul(hm, M.S(hs, hs, 1));
        return { m: hm, m0: hm0, c: M.xf(hm, [0, 0, 0]), u: M.xv(hm, [1, 0, 0]), v: M.xv(hm, [0, 1, 0]), gu: M.xv(hm0, [1, 0, 0]), gv: M.xv(hm0, [0, 1, 0]) };
      };
      half = { ...halfAt(lid, o.half), gain: o.half.gain };
      const mmPx = DISP.w / SCR.w;
      gi = glyphInstances(o.half, scr.L, [h.cx, h.cy], mmPx, o.half.gain * (o.halfGain ?? 1.6), look);
      uploadGlyphs(half.m0);
      glyphN = gi.n;
      half.gsz = gi.size;
    }
    // the moment a pass renders: camera, lid and half (the shutter moves them; without it, the frame's own)
    const st0 = { eye: o.eye, proj, view, lid, lidInv, half };
    const stateAt = (t) => {
      const A = o.a, B = o.b, l = (x, y) => x + (y - x) * t, lv = (x, y) => x.map((v, i) => l(v, y[i]));
      const q = { eye: lv(A.eye, B.eye), target: lv(A.target, B.target), fov: l(A.fov, B.fov), lid: l(A.lid, B.lid), shift: lv(A.shift || [0, 0], B.shift || [0, 0]) };
      const c = camera(q);
      let hf = null;
      if (half) {
        // the half moves with the shutter when both ends carry it, and rides with the lid in any case
        const hp = A.half && B.half ? Object.fromEntries(['lift', 'dx', 'dy', 'yaw', 'pitch'].map((k) => [k, l(A.half[k] || 0, B.half[k] || 0)])) : o.half;
        hf = { ...halfAt(c.lid, hp), gain: half.gain, gsz: half.gsz };
      }
      return { eye: q.eye, proj: c.proj, view: c.view, lid: c.lid, lidInv: M.inv(c.lid), half: hf };
    };
    const Ls = lights(o);
    // with the cyclorama cached, the cache pass needs the boxes that light it, the passes those that light the Mac
    const rig = o.lights || LIGHTS;
    const LsC = lights({ lights: rig.filter((l) => (l.cyc ?? 1) > 0) }), LsM = lights({ lights: rig.filter((l) => (l.mac ?? 1) > 0) });
    const bgLin = o.bg ? o.bg.map(s2l) : BG_LIN;   // the studio's backdrop (sRGB 0–255); the page's black by default
    const clear = cyc ? [0, 0, 0] : bgLin;
    // strata for the textured lights: a grid of exactly `passes` cells, about as wide as the display
    let sg = [passes, 1];
    for (let gx = 1; gx <= passes; gx++) if (passes % gx === 0 && gx * gx <= passes * 1.6) sg = [gx, passes / gx];
    if (o.strat && sg[0] < sg[1]) sg = [sg[1], sg[0]];
    // the legends' atlas (once) and ink: #8E8E93 at 35% unless o.legends says otherwise
    if (o.legends && !legend) legend = buildLegends();
    const legInk = (o.legends && o.legends.color) || [142, 142, 147];
    const legCol = [...legInk.map(s2l), (o.legends && o.legends.opacity) ?? 0.35];

    // the cyclorama's light, once per frame (o.cycCache: its size as a fraction of the frame, 0.5 by default;
    // false renders it in every pass), the display and the half sampled on an o.cacheGrid grid (4 × 4)
    const cache = cyc && o.cycCache !== false;
    const cf = typeof o.cycCache === 'number' ? o.cycCache : 0.5, CW = Math.max(1, Math.round(W * cf)), CH = Math.max(1, Math.round(H * cf));
    const cg = o.cacheGrid || [4, 4];
    const setMain = (P, pass, vp, Ls, st) => {
      gl.useProgram(P.p);
      gl.uniformMatrix4fv(P.u.uVP, false, vp);
      gl.uniform3fv(P.u.uEye, st.eye);
      gl.uniform1ui(P.u.uSeed, (pass * 7919 + (o.seed || 0) * 104729) >>> 0);
      gl.uniformMatrix4fv(P.u.uLid, false, st.lid); gl.uniformMatrix4fv(P.u.uLidInv, false, st.lidInv);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, scrTex); gl.uniform1i(P.u.uScr, 0);
      gl.uniform1f(P.u.uScrGain, o.screenGain ?? 1.6);
      gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, halfTex || scrTex); gl.uniform1i(P.u.uHalfT, 1);
      gl.uniform1f(P.u.uHGain, half ? half.gain * (o.halfLight ?? 3.0) : 0);
      if (st.half) { gl.uniform3fv(P.u.uHC, st.half.c); gl.uniform3fv(P.u.uHU, st.half.u); gl.uniform3fv(P.u.uHV, st.half.v); }
      gl.uniform3fv(P.u.uLC, Ls.c); gl.uniform3fv(P.u.uLU, Ls.u); gl.uniform3fv(P.u.uLV, Ls.v); gl.uniform3fv(P.u.uLCol, Ls.col);
      gl.uniform1i(P.u.uNL, Ls.n); gl.uniform1fv(P.u.uLMacK, Ls.mk); gl.uniform1fv(P.u.uLCycK, Ls.ck);
      gl.uniform3fv(P.u.uBg, bgLin); gl.uniform1f(P.u.uPool, o.pool ?? 1.2); gl.uniform1f(P.u.uPoolR, o.poolR ?? 330);
      gl.uniform1i(P.u.uSpp, o.spp || 2); gl.uniform1f(P.u.uClamp, o.clamp ?? 10);
      gl.uniform1i(P.u.uCyc, cyc ? 1 : 0); gl.uniform1i(P.u.uMac, mac ? 1 : 0);
      gl.uniform1f(P.u.uScrDrawn, o.screen && o.screen.drawn === false ? 0 : 1);
      gl.uniform1i(P.u.uStrat, o.strat ? 1 : 0); gl.uniform1i(P.u.uPass, pass); gl.uniform2i(P.u.uStratG, sg[0], sg[1]);
      gl.uniform1i(P.u.uNeutral, o.neutral ? 1 : 0);
      const ct = o.contact || [0.3, 60]; gl.uniform2f(P.u.uContact, ct[0], ct[1]);
      gl.uniform1i(P.u.uCycPass, cache ? 2 : 0);
      gl.uniform2i(P.u.uCacheG, cg[0], cg[1]);
      if (cache) { gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D, rtCyc.tex); gl.uniform1i(P.u.uCycT, 2); gl.uniform2f(P.u.uCycPx, 1 / W, 1 / H); }
      if (film) {
        gl.uniform1i(P.u.uLegOn, o.legends ? 1 : 0);
        if (o.legends) { gl.activeTexture(gl.TEXTURE3); gl.bindTexture(gl.TEXTURE_2D, legend.tex); gl.uniform1i(P.u.uLeg, 3); gl.uniform4fv(P.u.uKeyCell, legend.cells); gl.uniform4fv(P.u.uLegCol, legCol); }
        gl.uniform1i(P.u.uFine, o.fine ? 1 : 0); gl.uniform1f(P.u.uMicro, micro);
        gl.uniform1f(P.u.uReflK, reflK); gl.uniform3fv(P.u.uEyeR, st.eye);
      }
    };
    const drawWith = (P) => (mesh, model, mat) => {
      gl.uniform1i(P.u.uMat, mat); gl.uniformMatrix4fv(P.u.uM, false, model); gl.uniformMatrix3fv(P.u.uNM, false, M.n3(model));
      gl.bindVertexArray(mesh.vao); gl.drawElements(gl.TRIANGLES, mesh.n, gl.UNSIGNED_INT, 0);
    };
    if (cache) {
      if (!rtCyc || rtCyc.w !== CW || rtCyc.h !== CH) rtCyc = target(CW, CH, gl.RGBA16F, true);
      gl.bindFramebuffer(gl.FRAMEBUFFER, rtCyc.fb); gl.viewport(0, 0, CW, CH);
      gl.clearColor(0, 0, 0, 1); gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      gl.enable(gl.DEPTH_TEST); gl.disable(gl.BLEND); gl.disable(gl.CULL_FACE);
      const PC = filmProg(Math.max(1, LsC.n));
      setMain(PC, 0, M.mul(proj, view), LsC, st0);
      gl.uniform1i(PC.u.uCycPass, 1);
      gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D, null);
      drawWith(PC)(meshes.cyc, M.id(), 0);
    }

    gl.bindFramebuffer(gl.FRAMEBUFFER, rtAcc.fb); gl.viewport(0, 0, W, H);
    gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
    // film: the passes' jitter, drawn up front and made exactly zero-mean, so the picture sits where corners() says
    // (a random or unevenly stratified mean would shift the whole frame by up to ~0.2 px against the composite)
    let jits = null;
    if (film) {
      const g = Math.ceil(Math.sqrt(passes));
      jits = Array.from({ length: passes }, (_, p) => [(((p % g) + Math.random()) / g - 0.5) * 1.5, ((Math.floor(p / g) + Math.random()) / g - 0.5) * 1.5]);
      const mx = jits.reduce((a, j) => a + j[0], 0) / passes, my = jits.reduce((a, j) => a + j[1], 0) / passes;
      jits = jits.map(([x, y]) => [x - mx, y - my]);
    }
    // the shutter's moments: one per pass, stratified, mean exactly 0.5 (so the blur centres on the frame's own
    // moment, where corners() puts the display), shuffled so time doesn't follow the jitter's rows
    let times = null;
    if (moving) {
      times = Array.from({ length: passes }, (_, p) => (p + Math.random()) / passes);
      const mt = times.reduce((a, t) => a + t, 0) / passes;
      times = times.map((t) => Math.min(1, Math.max(0, t + 0.5 - mt)));
      for (let k = passes - 1; k > 0; k--) { const j = Math.floor(Math.random() * (k + 1)); [times[k], times[j]] = [times[j], times[k]]; }
    }
    // the floor reflection's own target (o.reflectScale of the frame, 0.5 by default: the image is spread anyway)
    const rsc = o.reflectScale ?? 0.5, RW = Math.max(1, Math.round(W * rsc)), RH = Math.max(1, Math.round(H * rsc));
    if (refl && (!rtRefl || rtRefl.w !== RW || rtRefl.h !== RH)) { rtRefl = target(RW, RH, gl.RGBA16F, true); rtReflB = target(RW, RH, gl.RGBA16F, false); }
    const FR = rtFrame;
    for (let pass = 0; pass < passes; pass++) {
      // stratified jitter inside the pixel (radius ~0.75 px, a soft box filter)
      const g = Math.ceil(Math.sqrt(passes));
      const [jx, jy] = jits ? jits[pass] : [(((pass % g) + Math.random()) / g - 0.5) * 1.5, ((Math.floor(pass / g) + Math.random()) / g - 0.5) * 1.5];
      const jit = M.T(jx * 2 / W, jy * 2 / H, 0);
      const st = moving ? stateAt(times[pass]) : st0;
      const vp = M.mul(jit, M.mul(st.proj, st.view));
      if (moving && st.half && glyphN) uploadGlyphs(st.half.m0);
      gl.bindFramebuffer(gl.FRAMEBUFFER, FR.fb); gl.viewport(0, 0, W, H);
      gl.clearColor(clear[0], clear[1], clear[2], 1); gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      gl.enable(gl.DEPTH_TEST); gl.disable(gl.BLEND); gl.disable(gl.CULL_FACE);
      const LsP = cache ? LsM : Ls;
      const P = film ? filmProg(Math.max(1, LsP.n)) : progMain;
      if (cache) { const PR = filmProg(1, '\n  #define CYCREAD 1'); setMain(PR, pass, vp, LsP, st); drawWith(PR)(meshes.cyc, M.id(), 0); }
      setMain(P, pass, vp, LsP, st);
      const draw = drawWith(P);
      if (!cache) draw(cyc ? meshes.cyc : meshes.floor, M.id(), 0);
      const lidModel = M.mul(st.lid, M.T(0, 0, LID.len / 2)), hingeModel = M.T(0, HINGE.y, HINGE.z);
      if (film && mac && o.prepass !== false) {
        // depth first, then shade only the nearest surface (the meshes' winding is mixed, so no culling)
        if (!progDepth) progDepth = compile(VS, `#version 300 es\n  precision highp float; out vec4 o; void main() { o = vec4(0.0); }`);
        gl.useProgram(progDepth.p); gl.uniformMatrix4fv(progDepth.u.uVP, false, vp); gl.colorMask(false, false, false, false);
        const dd = drawWith(progDepth);
        dd(meshes.base, M.id(), 1); dd(meshes.lid, lidModel, 2); dd(meshes.hinge, hingeModel, 3);
        gl.colorMask(true, true, true, true); gl.depthFunc(gl.LEQUAL); gl.useProgram(P.p);
      }
      if (mac) {
        draw(meshes.base, M.id(), 1);
        draw(meshes.lid, lidModel, 2);
        draw(meshes.hinge, hingeModel, 3);
      }
      gl.depthFunc(gl.LESS);
      const hf = st.half;
      if (hf && glyphN) {
        const Q = progGlyph; gl.useProgram(Q.p);
        // colour adds; alpha (the studio's coverage) is cut where a character covers it
        gl.enable(gl.BLEND); gl.blendFuncSeparate(gl.ONE, gl.ONE, gl.ZERO, gl.ONE_MINUS_SRC_ALPHA); gl.depthMask(false);
        gl.uniformMatrix4fv(Q.u.uVP, false, vp); gl.uniform3fv(Q.u.uU, hf.gu); gl.uniform3fv(Q.u.uV, hf.gv); gl.uniform1f(Q.u.uN, atlas.n);
        gl.bindVertexArray(glyphVao); gl.activeTexture(gl.TEXTURE0); gl.uniform1i(Q.u.uA, 0);
        // the glow (three times the cell, blurred; none when glowK is 0), then the characters
        const gk = o.half.glowK ?? 0.5;
        if (gk > 0) {
          gl.bindTexture(gl.TEXTURE_2D, atlas.glow); const gs = o.half.glowS ?? 3; gl.uniform2f(Q.u.uSz, hf.gsz[0] * gs, hf.gsz[1] * gs); gl.uniform1f(Q.u.uK, gk);
          gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, glyphN);
        }
        gl.bindTexture(gl.TEXTURE_2D, atlas.crisp); gl.uniform2f(Q.u.uSz, hf.gsz[0], hf.gsz[1]); gl.uniform1f(Q.u.uK, 1);
        gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, glyphN);
        gl.depthMask(true); gl.disable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE);
      }
      if (refl) {
        // the floor reflection: the Mac mirrored in the floor, in its own (smaller) target with its own depth (the
        // nearest mirrored surface only), then added to the pass where the floor shows (weighted by the pass's
        // coverage alpha: 1 on the studio, 0 on the Mac); colour only, the coverage stays. Each pass shears the
        // mirror image by a random amount proportional to the height above the floor (a satin, not a mirror: sharp
        // at the contact, spreading upwards)
        gl.bindFramebuffer(gl.FRAMEBUFFER, rtRefl.fb); gl.viewport(0, 0, RW, RH);
        gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
        gl.enable(gl.DEPTH_TEST); gl.depthFunc(gl.LESS); gl.depthMask(true); gl.disable(gl.BLEND);
        const spread = Math.tan((o.reflectBlur ?? 4) * Math.PI / 180);
        const gauss = () => Math.sqrt(-2 * Math.log(1 - Math.random())) * Math.cos(2 * Math.PI * Math.random());
        const mir = [1, 0, 0, 0, 2 * spread * gauss(), -1, 2 * spread * gauss(), 0, 0, 0, 1, 0, 0, 0, 0, 1];
        const vpm = M.mul(vp, mir);
        if (!progDepth) progDepth = compile(VS, `#version 300 es\n  precision highp float; out vec4 o; void main() { o = vec4(0.0); }`);
        gl.useProgram(progDepth.p); gl.uniformMatrix4fv(progDepth.u.uVP, false, vpm); gl.colorMask(false, false, false, false);
        const dd = drawWith(progDepth);
        dd(meshes.base, M.id(), 1); dd(meshes.lid, lidModel, 2); dd(meshes.hinge, hingeModel, 3);
        gl.colorMask(true, true, true, true); gl.depthFunc(gl.LEQUAL); gl.depthMask(false);
        const PM = filmProg(Math.max(1, LsP.n), '\n  #define MIRROR 1');
        setMain(PM, pass, vpm, LsP, st);
        gl.uniform3fv(PM.u.uEye, [st.eye[0], -st.eye[1], st.eye[2]]);
        const dm = drawWith(PM);
        dm(meshes.base, M.id(), 1); dm(meshes.lid, lidModel, 2); dm(meshes.hinge, hingeModel, 3);
        gl.depthMask(true); gl.depthFunc(gl.LESS); gl.disable(gl.DEPTH_TEST);
        // a little spread everywhere (o.reflectSoft: the bloom blur at that fraction of a texel per tap, 0.4: σ 2
        // texels), or the small image's thin lines would sparkle from pass to pass
        const soft = o.reflectSoft ?? 0.4;
        if (soft > 0) {
          gl.useProgram(progBlur.p); gl.uniform1i(progBlur.u.uT, 0); gl.activeTexture(gl.TEXTURE0);
          gl.bindFramebuffer(gl.FRAMEBUFFER, rtReflB.fb); gl.viewport(0, 0, RW, RH); gl.bindTexture(gl.TEXTURE_2D, rtRefl.tex); gl.uniform2f(progBlur.u.uDir, soft / RW, 0); full();
          gl.bindFramebuffer(gl.FRAMEBUFFER, rtRefl.fb); gl.bindTexture(gl.TEXTURE_2D, rtReflB.tex); gl.uniform2f(progBlur.u.uDir, 0, soft / RH); full();
        }
        gl.bindFramebuffer(gl.FRAMEBUFFER, FR.fb); gl.viewport(0, 0, W, H);
        gl.enable(gl.BLEND); gl.blendFuncSeparate(gl.DST_ALPHA, gl.ONE, gl.ZERO, gl.ONE);
        gl.useProgram(progCopy.p); gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, rtRefl.tex); gl.uniform1i(progCopy.u.uT, 0); gl.uniform1f(progCopy.u.uK, 1);
        full(); gl.disable(gl.BLEND);
      }
      // add to the sum
      gl.disable(gl.DEPTH_TEST);
      gl.bindFramebuffer(gl.FRAMEBUFFER, rtAcc.fb); gl.viewport(0, 0, W, H);
      gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE);
      gl.useProgram(progCopy.p); gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, FR.tex); gl.uniform1i(progCopy.u.uT, 0); gl.uniform1f(progCopy.u.uK, 1);
      full(); gl.disable(gl.BLEND);
    }
    // bloom: two sizes
    const exp = o.exposure ?? 1;
    const down = (src, dst, k, th) => { gl.bindFramebuffer(gl.FRAMEBUFFER, dst.fb); gl.viewport(0, 0, dst.w, dst.h); gl.useProgram(progDown.p); gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, src.tex); gl.uniform1i(progDown.u.uT, 0); gl.uniform2f(progDown.u.uPx, 1 / src.w, 1 / src.h); gl.uniform1f(progDown.u.uK, k); gl.uniform1f(progDown.u.uTh, th); full(); };
    const blur = (a, b) => {
      gl.useProgram(progBlur.p); gl.uniform1i(progBlur.u.uT, 0);
      gl.bindFramebuffer(gl.FRAMEBUFFER, b.fb); gl.viewport(0, 0, b.w, b.h); gl.bindTexture(gl.TEXTURE_2D, a.tex); gl.uniform2f(progBlur.u.uDir, 1 / a.w, 0); full();
      gl.bindFramebuffer(gl.FRAMEBUFFER, a.fb); gl.bindTexture(gl.TEXTURE_2D, b.tex); gl.uniform2f(progBlur.u.uDir, 0, 1 / a.h); full();
    };
    down(rtAcc, rtB1, exp / passes, o.bloomTh ?? 0.35); blur(rtB1, rtB2);
    down(rtB1, rtC1, 1, 0); blur(rtC1, rtC2);
    // the final pass: to the canvas (8-bit), or with float to an RGBA16F target that HERO.raw() reads
    if (o.float && !rtOut) rtOut = target(W, H, gl.RGBA16F, false);
    gl.bindFramebuffer(gl.FRAMEBUFFER, o.float ? rtOut.fb : null); gl.viewport(0, 0, W, H);
    const F = progFinal; gl.useProgram(F.p);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, rtAcc.tex); gl.uniform1i(F.u.uT, 0);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, rtB1.tex); gl.uniform1i(F.u.uB1, 1);
    gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D, rtC1.tex); gl.uniform1i(F.u.uB2, 2);
    gl.uniform1f(F.u.uK, 1 / passes); gl.uniform1f(F.u.uExp, exp);
    const bl = o.bloom ?? [0.22, 0.18]; gl.uniform1f(F.u.uBloom1, bl[0]); gl.uniform1f(F.u.uBloom2, bl[1]);
    gl.uniform3fv(F.u.uBg, bgLin); gl.uniform2f(F.u.uRes, W, H);
    gl.uniform1f(F.u.uEdge, (o.edge ?? !cyc) ? 1 : 0); gl.uniform1f(F.u.uDither, (o.dither ?? !cyc) ? 1 : 0); gl.uniform1f(F.u.uAlpha, o.float ? 1 : 0);
    full();
    lastFloat = !!o.float;
    gl.readPixels(0, 0, 1, 1, gl.RGBA, o.float ? gl.FLOAT : gl.UNSIGNED_BYTE, o.float ? new Float32Array(4) : new Uint8Array(4));
    // where things landed on the frame (for laying the page out): the laptop's corners and the half's centre
    const vp = M.mul(proj, view);
    const toPx = pxOf(vp, W, H);
    const pts = [];
    for (const z of [-110, 110]) for (const x of [-156, 156]) { pts.push(toPx([x, 0.8, z])); pts.push(toPx([x, 11.3, z])); }
    for (const x of [-156, 156]) { pts.push(toPx(M.xf(lid, [x, 0, LID.len]))); pts.push(toPx(M.xf(lid, [x, LID.t, LID.len]))); }
    const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
    let hbox = null;
    if (half) { const hp = []; for (const a of [-1, 1]) for (const b of [-1, 1]) hp.push(toPx([half.c[0] + half.u[0] * a + half.v[0] * b, half.c[1] + half.u[1] * a + half.v[1] * b, half.c[2] + half.u[2] * a + half.v[2] * b])); hbox = [Math.min(...hp.map((q) => q[0])), Math.min(...hp.map((q) => q[1])), Math.max(...hp.map((q) => q[0])), Math.max(...hp.map((q) => q[1]))].map(Math.round); }
    // the display's active area, corner by corner (top left, top right, bottom right, bottom left), for laying a
    // picture onto it afterwards; plus the notch polygon and the top corners' radius (HERO.corners)
    const display = [[-DISP.w / 2, DISP.top], [DISP.w / 2, DISP.top], [DISP.w / 2, DISP.top - DISP.h], [-DISP.w / 2, DISP.top - DISP.h]].map(([x, z]) => toPx(M.xf(lid, [x, 0, z])).map((v) => +v.toFixed(2)));
    const cn = corners(o);
    return { display, notch: cn.notch, radius: cn.radius, ms: Math.round(performance.now() - t0), box: [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)].map(Math.round), half: half ? toPx(half.c).map(Math.round) : null, hbox };
  }

  /// The last float frame (frame({float: true})): tonemapped, sRGB-encoded RGBA as a Float32Array, rows top
  /// first (W × H × 4). Alpha is the empty studio's coverage (1 on the cyclorama, 0 on the Mac and the half).
  let lastFloat = false;
  function raw() {
    if (!rtOut || !lastFloat) throw new Error('raw(): render a frame with float: true first');
    gl.bindFramebuffer(gl.FRAMEBUFFER, rtOut.fb);
    const buf = new Float32Array(W * H * 4);
    gl.readPixels(0, 0, W, H, gl.RGBA, gl.FLOAT, buf);
    const row = W * 4, tmp = new Float32Array(row);
    for (let y = 0; y < (H >> 1); y++) {
      const a = y * row, b = (H - 1 - y) * row;
      tmp.set(buf.subarray(a, a + row)); buf.copyWithin(a, b, b + row); buf.set(tmp, b);
    }
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    return buf;
  }

  /// The key legends' atlas as a PNG data URL (for looking at it; built on first use).
  const legendAtlas = () => { if (!legend) legend = buildLegends(); return legend.canvas.toDataURL('image/png'); };
  window.HERO = { init, frame, setScreen, image: (type = 'image/png', q) => canvas.toDataURL(type, q), raw, corners, display: displayFrame, size: () => ({ w: W, h: H }), legendAtlas };
})();
