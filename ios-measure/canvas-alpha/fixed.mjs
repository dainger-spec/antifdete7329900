// vImage formulas (Alpha.h, MacOSX11.3 SDK; WebKit PixelBufferConversion.cpp main comments)
const premul = (u, a) => Math.floor((u * a + 127) / 255);
const unpremul = (p, a) => a === 0 ? 0 : Math.floor((Math.min(p, a) * 255 + (a >> 1)) / a);
const rt = (v, a) => unpremul(premul(v, a), a);
// 1. P -> U -> P identity for every valid premultiplied p <= a?
let bad = 0;
for (let a = 1; a <= 254; a++) for (let p = 0; p <= a; p++) if (premul(unpremul(p, a), a) !== p) bad++;
console.log('premul(unpremul(p)) != p cases:', bad);
// 2. fixed points of rt per alpha
const rows = [];
let total = 0, fixedTotal = 0, pairs = 0;
const caseCount = { i: 0, ii: 0, iii: 0 };   // for representable v and v^1 (the noise move)
for (let a = 1; a <= 254; a++) {
  const fixed = [];
  for (let v = 0; v < 256; v++) if (rt(v, a) === v) fixed.push(v);
  // image of unpremul
  const img = new Set(); for (let p = 0; p <= a; p++) img.add(unpremul(p, a));
  const same = fixed.length === img.size && fixed.every((v) => img.has(v));
  // noise move from representable v to v^1
  let ci = 0, cii = 0, ciii = 0;
  for (const v of fixed) { const w = v ^ 1; const r = rt(w, a); if (r === w) ci++; else if (r === v) cii++; else ciii++; }
  caseCount.i += ci; caseCount.ii += cii; caseCount.iii += ciii;
  rows.push({ a, n: fixed.length, same, ci, cii, ciii, fixed });
  total += 256; fixedTotal += fixed.length;
}
console.log('fixed points == image of unpremul for every alpha:', rows.every((r) => r.same));
console.log('count of fixed points per alpha == a+1:', rows.every((r) => r.n === r.a + 1));
console.log('representable v -> v^1: (i) v^1 representable', caseCount.i, '(ii) snaps back to v', caseCount.ii, '(iii) snaps elsewhere', caseCount.iii);
for (const a of [1, 2, 3, 5, 10, 64, 100, 127, 128, 129, 170, 200, 250, 253, 254]) {
  const r = rows[a - 1];
  console.log(`a=${a}: ${r.n} fixed points; v->v^1 (i)${r.ci} (ii)${r.cii} (iii)${r.ciii}; ` + (r.n <= 12 ? 'set ' + r.fixed.join(',') : 'missing ' + [...Array(256).keys()].filter((v) => !r.fixed.includes(v)).slice(0, 20).join(',') + (256 - r.n > 20 ? ',...' : '')));
}
// max distance |rt(v)-v|
let maxd = 0; for (let a = 1; a < 255; a++) for (let v = 0; v < 256; v++) maxd = Math.max(maxd, Math.abs(rt(v, a) - v));
console.log('max |rt(v)-v|:', maxd);
// smallest alpha where v and v^1 both representable
for (let a = 1; a < 255; a++) { if (rows[a - 1].ci > 0) { console.log('smallest alpha with case (i):', a); break; } }
for (let a = 254; a > 0; a--) { if (rows[a - 1].ciii > 0) { console.log('largest alpha with case (iii):', a, rows[a-1].ciii); break; } }
import fs from 'node:fs';
fs.writeFileSync('fixed_points.tsv', 'alpha\tcount\tcase_i\tcase_ii\tcase_iii\tfixed_points\n' + rows.map((r) => `${r.a}\t${r.n}\t${r.ci}\t${r.cii}\t${r.ciii}\t${r.fixed.join(',')}`).join('\n') + '\n');
