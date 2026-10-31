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

  // MARK: Shaders
  const VS = `#version 300 es
  in vec3 aP; in vec3 aN;
  uniform mat4 uM; uniform mat4 uVP; uniform mat3 uNM;
  out vec3 vP; out vec3 vN; out vec3 vL;
  void main() { vec4 w = uM * vec4(aP, 1.0); vP = w.xyz; vN = normalize(uNM * aN); vL = aP; gl_Position = uVP * w; }`;

  const FS = `#version 300 es
  precision highp float; precision highp int;
  #define NLIGHT 5
  in vec3 vP; in vec3 vN; in vec3 vL;
  out vec4 o;
  uniform int uMat;              // 0 floor, 1 base, 2 lid, 3 hinge
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
    if (!fromLid) {
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
    vec3 lp = (uLidInv * vec4(P, 1.0)).xyz, lx = (uLidInv * vec4(X, 1.0)).xyz;
    if (lp.y * lx.y > 0.0 || abs(lp.y - lx.y) < 1e-4) return 1.0;
    float f = lp.y / (lp.y - lx.y);
    vec3 q = mix(lp, lx, f);
    float d = sdRR(q.xz - vec2(0.0, LLEN * 0.5), vec2(${LID.hx}, LLEN * 0.5), 8.0);
    float pen = 3.0 + 0.06 * length(q - lp);
    return smoothstep(-pen, pen, d);
  }
  float Dggx(float NH, float a) { float a2 = a * a; float d = NH * NH * (a2 - 1.0) + 1.0; return a2 / (PI * d * d); }
  vec3 shade(vec3 P, vec3 N, vec3 V, vec3 F0, float rough, vec3 alb, float ao, bool fromLid) {
    float a = max(rough * rough, 0.0008);
    float NV = max(dot(N, V), 1e-3);
    float k2 = a * 0.5;
    vec3 spec = vec3(0.0), E = vec3(0.0);
    vec3 R = reflect(-V, N);
    // softboxes: the representative point on each box (closest to the reflected ray), energy-normalised
    for (int i = 0; i < NLIGHT; i++) {
      vec3 C = uLC[i], U = uLU[i], Vv = uLV[i];
      vec3 n = normalize(cross(U, Vv));
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
      E += uLCol[i] * area * max(dot(N, Dc), 0.0) * max(-dot(Dc, n), 0.0) / (dc * dc);
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
      spec += uLCol[i] * vis * Il * Dggx(NH, a) * (a / ap) * (a / ap) * G * F / (4.0 * NV);
    }
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
    if (q.x < 0.0 || q.x > 14.5 || q.y < 0.0 || q.y >= 6.0) return 99.0;
    int row = int(floor(q.y));
    float x = 0.0; float w = 1.0;
    for (int i = 0; i < 14; i++) { w = KW[row * 14 + i]; if (w == 0.0) return 99.0; if (q.x < x + w) break; x += w; }
    float top = float(row), bot = float(row) + 1.0;
    // arrows: inverted T (the last three cells of the bottom row are half height, up above down)
    if (row == 5 && x >= 11.49) {
      if (x > 12.4 && x < 12.6) { if (fract(q.y) < 0.5) bot = top + 0.5; else top = top + 0.5; }
      else top = top + 0.5;
    }
    vec2 lo = K0 + vec2(x, top) * KP, hi = K0 + vec2(x + w, bot) * KP;
    c = (lo + hi) * 0.5; hh = (hi - lo) * 0.5 - vec2(1.55, 1.55);
    if (bot - top < 0.9) hh.y = (hi.y - lo.y) * 0.5 - 0.9;
    return sdRR(p - c, hh, 2.1);
  }

  void main() {
    rs = pcg(uint(gl_FragCoord.x) * 1973u + pcg(uint(gl_FragCoord.y) * 9277u + pcg(uSeed)));
    vec3 P = vP, N = normalize(vN), V = normalize(uEye - vP);
    if (dot(N, V) < 0.0 && uMat != 0) N = -N;
    vec3 col;
    if (uMat == 0) {
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
          if (k1 < 0.0) {
            // key top: black, satin; edges round over
            float e = smoothstep(-0.7, 0.0, k1);
            vec2 g = normalize((q1 - kc) / max(kh, vec2(1.0)) + 1e-4);
            vec2 dq = q1 - kc; vec2 ad = abs(dq) - kh + 2.1; vec2 gg = ad.x > ad.y ? vec2(sign(dq.x), 0.0) : vec2(0.0, sign(dq.y));
            Nn = normalize(vec3(0.0, 1.0, 0.0) + vec3(gg.x, 0.0, gg.y) * e * 1.6 - vec3(dq.x, 0.0, dq.y) * 0.0025);
            F0 = vec3(0.045); r = 0.42; alb = vec3(0.028, 0.029, 0.032);
            ao *= 1.0;
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
        } else if (pad < 0.35) {
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
      col = shade(P, Nn, V, F0, r, alb, ao, false);
    } else if (uMat == 2) {
      vec3 lp = (uLidInv * vec4(P, 1.0)).xyz;
      vec3 ln = mat3(uLidInv) * N;
      vec3 F0 = vec3(0.075, 0.077, 0.082); float r = 0.34; vec3 alb = vec3(0.022, 0.0225, 0.025);
      float ao = occl(P, N, 0.7, 0.6);
      vec3 em = vec3(0.0);
      bool fromLid = true;
      if (ln.y < -0.98 && lp.y < 0.05) {
        float g = sdRR(lp.xz - vec2(0.0, LLEN * 0.5), vec2(${LID.hx} - 1.45, LLEN * 0.5 - 1.45), 9.0);
        if (g < -0.25) { F0 = vec3(0.035); r = 0.045; alb = vec3(0.0); em = display(lp.xz); }
        else if (g < 0.0) { F0 = vec3(0.03); r = 0.6; alb = vec3(0.004); ao *= 0.6; }
      }
      col = shade(P, N, V, F0, r, alb, ao, fromLid) + em;
    } else {
      col = shade(P, N, V, vec3(0.05), 0.36, vec3(0.012), occl(P, N, 0.7, 0.6), false);
    }
    o = vec4(col, 1.0);
  }`;

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
  void main() { o = vec4(vC * texture(uA, vT).a * uK, 1.0); }`;

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
  float tone(float x) { const float a = 0.3; return x < a ? x : a + (1.0 - a) * (1.0 - exp(-(x - a) / (1.0 - a))); }
  vec3 l2s(vec3 c) { return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c)); }
  float h(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
  void main() {
    vec3 c = texture(uT, vUV).rgb * uK * uExp + texture(uB1, vUV).rgb * uBloom1 + texture(uB2, vUV).rgb * uBloom2;
    c = vec3(tone(c.r), tone(c.g), tone(c.b));
    vec2 e = min(vUV, 1.0 - vUV) * uRes / min(uRes.x, uRes.y);
    float edge = smoothstep(0.0, 0.035, min(e.x, e.y));
    c = mix(uBg, c, edge);
    vec3 s = l2s(clamp(c, 0.0, 1.0));
    vec3 sb = l2s(uBg);
    float dif = length(s - sb);
    s += (h(gl_FragCoord.xy) - 0.5) / 255.0 * smoothstep(0.0, 0.01, dif);
    o = vec4(s, 1.0);
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

  let progGlyph, glyphVao, glyphBuf, atlas = null, glyphN = 0, progMain, progCopy, progDown, progBlur, progFinal, meshes, fsq, rtFrame, rtAcc, rtB1, rtB2, rtC1, rtC2, scrTex, halfTex;
  function init(w, h) {
    W = w; H = h; canvas.width = w; canvas.height = h;
    gl = canvas.getContext('webgl2', { antialias: false, preserveDrawingBuffer: true, alpha: false });
    if (!gl.getExtension('EXT_color_buffer_float')) throw new Error('no float buffers');
    gl.getExtension('OES_texture_float_linear');
    progMain = compile(VS, FS); progGlyph = compile(VS_G, FS_G);
    glyphVao = gl.createVertexArray(); gl.bindVertexArray(glyphVao);
    const cq = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, cq); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, 1, 1, -1, -1, 1, 1, -1, 1]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
    glyphBuf = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, glyphBuf);
    gl.enableVertexAttribArray(2); gl.vertexAttribPointer(2, 3, gl.FLOAT, false, 28, 0); gl.vertexAttribDivisor(2, 1);
    gl.enableVertexAttribArray(3); gl.vertexAttribPointer(3, 3, gl.FLOAT, false, 28, 12); gl.vertexAttribDivisor(3, 1);
    gl.enableVertexAttribArray(4); gl.vertexAttribPointer(4, 1, gl.FLOAT, false, 28, 24); gl.vertexAttribDivisor(4, 1);
    gl.bindVertexArray(null);
    progCopy = compile(VS_FULL, FS_COPY); progDown = compile(VS_FULL, FS_DOWN); progBlur = compile(VS_FULL, FS_BLUR); progFinal = compile(VS_FULL, FS_FINAL);
    meshes = { base: mesh(slab(BASE)), lid: mesh(slab({ hx: LID.hx, hz: LID.len / 2, rc: LID.rc, y0: 0, y1: LID.t, rb: LID.rin, rt: LID.rout })), hinge: mesh(barrel(HINGE.r, HINGE.hx)), floor: mesh(quad(6000)) };
    fsq = gl.createVertexArray(); gl.bindVertexArray(fsq);
    const qb = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, qb); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0); gl.bindVertexArray(null);
    rtFrame = target(w, h, gl.RGBA16F, true); rtAcc = target(w, h, gl.RGBA32F, false);
    rtB1 = target(w >> 2, h >> 2, gl.RGBA16F, false); rtB2 = target(w >> 2, h >> 2, gl.RGBA16F, false);
    rtC1 = target(w >> 4, h >> 4, gl.RGBA16F, false); rtC2 = target(w >> 4, h >> 4, gl.RGBA16F, false);
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
    const LH = R / (o.rows || 13);
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
  /// The left half alone, on black, in a square canvas round the half's own centre.
  function paintHalf(o, L) {
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
    paintHalves(c2, cw, L2, { which: [0], gain: 1, tokens: tokenMaps(L2, cw) });
    ctx.save(); ctx.filter = `blur(${(L.LH * (o.glow ?? 0.55)).toFixed(1)}px)`; ctx.globalAlpha = 0.85; ctx.drawImage(off, 0, 0); ctx.restore();
    ctx.drawImage(off, 0, 0);
    // centre of this canvas in display texture px, and its half size
    return { cx: sx + size / 2, cy: sy + size / 2, half: size / 2 };
  }
  /// Glyph atlases (crisp, and blurred with room round it for the glow), white on transparent.
  const GLYPHS = '01' + [...new Set('de-DE Europe/Berlin cookies store en-US America/New_York ads'.replace(/ /g, ''))].join('');
  function buildAtlas(cwRatio) {
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
    return { crisp: mk(1, 0), glow: mk(3, 16), n };
  }
  /// The left half's characters in the half's own frame (mm; z out of the glass on a dome of height D).
  function glyphInstances(o, L, anchor, mmPerPx, gain) {
    const { eachChar, tokenMaps, MONO } = window.CodeArt;
    const c2 = scrCanvas.getContext('2d'); c2.font = `${L.fs}px ${MONO}`;
    const cw = c2.measureText('0').width;
    if (!atlas) atlas = buildAtlas(cw / L.LH);
    const Rmm = L.R * mmPerPx, D = (o.dome ?? 0.42) * Rmm;
    const out = [];
    eachChar(cw, L, { which: [0], gain: 1, tokens: tokenMaps(L, cw) }, (ch, x, y, a, rgb, m) => {
      const k = GLYPHS.indexOf(ch); if (k < 0) return;
      const r2 = m.qx * m.qx + m.qy * m.qy;
      const z = D * Math.sqrt(Math.max(0, 1 - r2));
      const col = rgb.split(',').map((v) => s2l(Math.min(1, a) * (+v)) * gain);
      out.push((x + cw / 2 - anchor[0]) * mmPerPx, -(y - anchor[1]) * mmPerPx, z, ...col, k);
    });
    return { data: new Float32Array(out), n: out.length / 7, size: [cw / 2 * mmPerPx, L.LH / 2 * mmPerPx] };
  }

  /// Display texture px -> lid-local (x, z).
  const pxToLid = (x, y) => [-DISP.w / 2 + (x / SCR.w) * DISP.w, DISP.top - (y / SCR.h) * DISP.h];

  // MARK: Lights (softboxes): centre, half axes U and V (they face along U x V), colour * intensity
  function lights(o) {
    const L = o.lights || LIGHTS;
    const out = { c: [], u: [], v: [], col: [] };
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

  // MARK: One frame
  /// o: { eye, target, fov (deg), lid (deg), screen: {on, lifted, ghost, seam, r, rows, cx, cy},
  ///      half: {lift, dx, dy, yaw, pitch, gain, glow} | null, passes, spp, exposure, bloom, pool, shift }
  function frame(o) {
    const t0 = performance.now();
    const passes = o.passes || 16;
    const asp = W / H;
    const proj = M.persp(o.fov * Math.PI / 180, asp, 50, 20000);
    // lens shift (moves the picture in the frame without turning the camera)
    if (o.shift) { proj[8] += o.shift[0]; proj[9] += o.shift[1]; }
    const view = M.lookAt(o.eye, o.target, [0, 1, 0]);
    const lid = lidMatrix(o.lid);
    const lidInv = M.inv(lid);
    const scr = paintScreen({ ...(o.screen || {}), lifted: !!(o.half && o.half.gain > 0) });
    scrTex = texFrom(scrCanvas, scrTex);
    let half = null;
    if (o.half && o.half.gain > 0 && scr) {
      const h = paintHalf(o.half, scr.L);
      halfTex = texFrom(halfCanvas, halfTex);
      const [lx, lz] = pxToLid(h.cx, h.cy);
      const hs = h.half / SCR.w * DISP.w;
      // the half's frame in lid space: on the glass, then lifted along the glass's normal (-y, towards us)
      let hm = M.mul(lid, M.T(lx + (o.half.dx || 0), -0.4 - (o.half.lift || 0), lz + (o.half.dy || 0)));
      hm = M.mul(hm, M.Rx(Math.PI / 2));                 // plane z -> lid -y
      hm = M.mul(hm, M.Ry((o.half.yaw || 0) * Math.PI / 180));
      hm = M.mul(hm, M.Rx((o.half.pitch || 0) * Math.PI / 180));
      const hm0 = hm;
      hm = M.mul(hm, M.S(hs, hs, 1));
      half = { m: hm, c: M.xf(hm, [0, 0, 0]), u: M.xv(hm, [1, 0, 0]), v: M.xv(hm, [0, 1, 0]), gain: o.half.gain };
      const mmPx = DISP.w / SCR.w;
      const gi = glyphInstances(o.half, scr.L, [h.cx, h.cy], mmPx, o.half.gain * (o.halfGain ?? 1.6));
      const wpos = new Float32Array(gi.data.length);
      for (let i = 0; i < gi.n; i++) { const b = i * 7; const w = M.xf(hm0, [gi.data[b], gi.data[b + 1], gi.data[b + 2]]); wpos.set([w[0], w[1], w[2], gi.data[b + 3], gi.data[b + 4], gi.data[b + 5], gi.data[b + 6]], b); }
      gl.bindBuffer(gl.ARRAY_BUFFER, glyphBuf); gl.bufferData(gl.ARRAY_BUFFER, wpos, gl.DYNAMIC_DRAW);
      glyphN = gi.n;
      half.gu = M.xv(hm0, [1, 0, 0]); half.gv = M.xv(hm0, [0, 1, 0]); half.gsz = gi.size;
    }
    const Ls = lights(o);
    const bgLin = o.bg ? o.bg.map(s2l) : BG_LIN;   // the studio's backdrop (sRGB 0–255); the page's black by default

    gl.bindFramebuffer(gl.FRAMEBUFFER, rtAcc.fb); gl.viewport(0, 0, W, H);
    gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
    for (let pass = 0; pass < passes; pass++) {
      // stratified jitter inside the pixel (radius ~0.75 px, a soft box filter)
      const g = Math.ceil(Math.sqrt(passes));
      const jx = (((pass % g) + Math.random()) / g - 0.5) * 1.5, jy = ((Math.floor(pass / g) + Math.random()) / g - 0.5) * 1.5;
      const jit = M.T(jx * 2 / W, jy * 2 / H, 0);
      const vp = M.mul(jit, M.mul(proj, view));
      gl.bindFramebuffer(gl.FRAMEBUFFER, rtFrame.fb); gl.viewport(0, 0, W, H);
      gl.clearColor(bgLin[0], bgLin[1], bgLin[2], 1); gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
      gl.enable(gl.DEPTH_TEST); gl.disable(gl.BLEND); gl.disable(gl.CULL_FACE);
      const P = progMain; gl.useProgram(P.p);
      gl.uniformMatrix4fv(P.u.uVP, false, vp);
      gl.uniform3fv(P.u.uEye, o.eye);
      gl.uniform1ui(P.u.uSeed, (pass * 7919 + (o.seed || 0) * 104729) >>> 0);
      gl.uniformMatrix4fv(P.u.uLid, false, lid); gl.uniformMatrix4fv(P.u.uLidInv, false, lidInv);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, scrTex); gl.uniform1i(P.u.uScr, 0);
      gl.uniform1f(P.u.uScrGain, o.screenGain ?? 1.6);
      gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, halfTex || scrTex); gl.uniform1i(P.u.uHalfT, 1);
      gl.uniform1f(P.u.uHGain, half ? half.gain * (o.halfLight ?? 3.0) : 0);
      if (half) { gl.uniform3fv(P.u.uHC, half.c); gl.uniform3fv(P.u.uHU, half.u); gl.uniform3fv(P.u.uHV, half.v); }
      gl.uniform3fv(P.u.uLC, Ls.c); gl.uniform3fv(P.u.uLU, Ls.u); gl.uniform3fv(P.u.uLV, Ls.v); gl.uniform3fv(P.u.uLCol, Ls.col);
      gl.uniform3fv(P.u.uBg, bgLin); gl.uniform1f(P.u.uPool, o.pool ?? 1.2); gl.uniform1f(P.u.uPoolR, o.poolR ?? 330);
      gl.uniform1i(P.u.uSpp, o.spp || 2); gl.uniform1f(P.u.uClamp, o.clamp ?? 10);
      const draw = (mesh, model, mat) => {
        gl.uniform1i(P.u.uMat, mat); gl.uniformMatrix4fv(P.u.uM, false, model); gl.uniformMatrix3fv(P.u.uNM, false, M.n3(model));
        gl.bindVertexArray(mesh.vao); gl.drawElements(gl.TRIANGLES, mesh.n, gl.UNSIGNED_INT, 0);
      };
      draw(meshes.floor, M.id(), 0);
      draw(meshes.base, M.id(), 1);
      draw(meshes.lid, M.mul(lid, M.T(0, 0, LID.len / 2)), 2);
      draw(meshes.hinge, M.T(0, HINGE.y, HINGE.z), 3);
      if (half && glyphN) {
        const Q = progGlyph; gl.useProgram(Q.p);
        gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE); gl.depthMask(false);
        gl.uniformMatrix4fv(Q.u.uVP, false, vp); gl.uniform3fv(Q.u.uU, half.gu); gl.uniform3fv(Q.u.uV, half.gv); gl.uniform1f(Q.u.uN, atlas.n);
        gl.bindVertexArray(glyphVao); gl.activeTexture(gl.TEXTURE0); gl.uniform1i(Q.u.uA, 0);
        // the glow (three times the cell, blurred), then the characters
        gl.bindTexture(gl.TEXTURE_2D, atlas.glow); const gs = o.half.glowS ?? 3; gl.uniform2f(Q.u.uSz, half.gsz[0] * gs, half.gsz[1] * gs); gl.uniform1f(Q.u.uK, o.half.glowK ?? 0.5);
        gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, glyphN);
        gl.bindTexture(gl.TEXTURE_2D, atlas.crisp); gl.uniform2f(Q.u.uSz, half.gsz[0], half.gsz[1]); gl.uniform1f(Q.u.uK, 1);
        gl.drawArraysInstanced(gl.TRIANGLES, 0, 6, glyphN);
        gl.depthMask(true); gl.disable(gl.BLEND);
      }
      // add to the sum
      gl.disable(gl.DEPTH_TEST);
      gl.bindFramebuffer(gl.FRAMEBUFFER, rtAcc.fb); gl.viewport(0, 0, W, H);
      gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE);
      gl.useProgram(progCopy.p); gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, rtFrame.tex); gl.uniform1i(progCopy.u.uT, 0); gl.uniform1f(progCopy.u.uK, 1);
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
    gl.bindFramebuffer(gl.FRAMEBUFFER, null); gl.viewport(0, 0, W, H);
    const F = progFinal; gl.useProgram(F.p);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, rtAcc.tex); gl.uniform1i(F.u.uT, 0);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, rtB1.tex); gl.uniform1i(F.u.uB1, 1);
    gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_2D, rtC1.tex); gl.uniform1i(F.u.uB2, 2);
    gl.uniform1f(F.u.uK, 1 / passes); gl.uniform1f(F.u.uExp, exp);
    const bl = o.bloom ?? [0.22, 0.18]; gl.uniform1f(F.u.uBloom1, bl[0]); gl.uniform1f(F.u.uBloom2, bl[1]);
    gl.uniform3fv(F.u.uBg, bgLin); gl.uniform2f(F.u.uRes, W, H);
    full();
    gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(4));
    // where things landed on the frame (for laying the page out): the laptop's corners and the half's centre
    const vp = M.mul(proj, view);
    const toPx = (p) => { const q = [vp[0] * p[0] + vp[4] * p[1] + vp[8] * p[2] + vp[12], vp[1] * p[0] + vp[5] * p[1] + vp[9] * p[2] + vp[13], 0, vp[3] * p[0] + vp[7] * p[1] + vp[11] * p[2] + vp[15]]; return [(q[0] / q[3] * 0.5 + 0.5) * W, (1 - (q[1] / q[3] * 0.5 + 0.5)) * H]; };
    const pts = [];
    for (const z of [-110, 110]) for (const x of [-156, 156]) { pts.push(toPx([x, 0.8, z])); pts.push(toPx([x, 11.3, z])); }
    for (const x of [-156, 156]) { pts.push(toPx(M.xf(lid, [x, 0, LID.len]))); pts.push(toPx(M.xf(lid, [x, LID.t, LID.len]))); }
    const xs = pts.map((p) => p[0]), ys = pts.map((p) => p[1]);
    let hbox = null;
    if (half) { const hp = []; for (const a of [-1, 1]) for (const b of [-1, 1]) hp.push(toPx([half.c[0] + half.u[0] * a + half.v[0] * b, half.c[1] + half.u[1] * a + half.v[1] * b, half.c[2] + half.u[2] * a + half.v[2] * b])); hbox = [Math.min(...hp.map((q) => q[0])), Math.min(...hp.map((q) => q[1])), Math.max(...hp.map((q) => q[0])), Math.max(...hp.map((q) => q[1]))].map(Math.round); }
    // the display's active area, corner by corner (top left, top right, bottom right, bottom left), for laying a
    // picture onto it afterwards
    const display = [[-DISP.w / 2, DISP.top], [DISP.w / 2, DISP.top], [DISP.w / 2, DISP.top - DISP.h], [-DISP.w / 2, DISP.top - DISP.h]].map(([x, z]) => toPx(M.xf(lid, [x, 0, z])).map((v) => +v.toFixed(2)));
    return { display, ms: Math.round(performance.now() - t0), box: [Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys)].map(Math.round), half: half ? toPx(half.c).map(Math.round) : null, hbox };
  }

  window.HERO = { init, frame, setScreen, image: (type = 'image/png', q) => canvas.toDataURL(type, q) };
})();
