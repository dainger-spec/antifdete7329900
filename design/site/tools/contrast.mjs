// WCAG 2.x contrast of every text/background pair the site uses, with translucent tints composited
// over the surface they sit on. Prints a Markdown table (spec.md, "Contrast") and fails if a text pair
// is under 4.5:1 or a large-text / UI pair under 3:1.
//
//   node design/site/tools/contrast.mjs
const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
const over = (fg, a, bg) => fg.map((c, i) => Math.round(c * a + bg[i] * (1 - a)));
const lum = (rgb) => {
  const [r, g, b] = rgb.map((v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };

const BG = {
  backdrop: hex('#0B0C0F'), surface: hex('#161920'), card: hex('#1B1F27'), raised: hex('#1E222A'), 'raised-inset': hex('#252A33'), field: hex('#0F1115'),
};
const T = {
  'text-primary': hex('#ECEEF2'), 'text-secondary': hex('#A2A9B6'), 'text-tertiary': hex('#8A93A3'), accent: hex('#6F8FEA'),
  danger: hex('#EC6F68'), running: hex('#4CC38A'), warning: hex('#D9A441'),
};
const rows = [];
const add = (fg, fgName, bg, bgName, min, use) => rows.push({ fgName, bgName, r: ratio(fg, bg), min, use });

for (const [b, bg] of Object.entries(BG)) {
  add(T['text-primary'], 'text-primary', bg, b, 4.5, 'текст');
  add(T['text-secondary'], 'text-secondary', bg, b, 4.5, 'текст');
  add(T['text-tertiary'], 'text-tertiary', bg, b, 4.5, 'подписи, мета');
  add(T.accent, 'accent', bg, b, 4.5, 'ссылки');
}
for (const b of ['backdrop', 'surface']) {
  add(T.danger, 'danger', BG[b], b, 4.5, 'ошибки, «Удалить»');
  add(T.running, 'running', BG[b], b, 3, 'глиф «совпадает» (не текст)');
  add(T.warning, 'warning', BG[b], b, 3, 'глиф «не измерено» (не текст)');
}
// Buttons and tinted labels
add(hex('#121419'), 'primary-text', hex('#E6E8ED'), 'primary-fill', 4.5, 'основная кнопка');
add(hex('#FFFFFF'), 'white', hex('#4469D6'), 'accent-fill-strong', 4.5, 'включённый переключатель, флажок');
add(hex('#AFC2F5'), '#AFC2F5', over([111, 143, 234], 0.14, BG.surface), 'accent-tint на surface', 4.5, 'метка «рекомендуем», «через прокси»');
add(hex('#8FDDB6'), '#8FDDB6', over([76, 195, 138], 0.14, BG.surface), 'running-tint на surface', 4.5, 'метка «активна»');
add(hex('#E8C27A'), '#E8C27A', over([217, 164, 65], 0.14, BG.surface), 'warning-tint на surface', 4.5, 'метки предупреждений');
add(T['text-secondary'], 'text-secondary', over([217, 164, 65], 0.14, BG.backdrop), 'warning-tint на backdrop', 4.5, 'текст в предупреждении');
add(T['text-secondary'], 'text-secondary', over([111, 143, 234], 0.14, BG.backdrop), 'accent-tint на backdrop', 4.5, 'текст в акцентной заметке');
add(T['text-primary'], 'text-primary', over([111, 143, 234], 0.14, BG.surface), 'accent-tint на surface', 4.5, 'выбранная строка');
add(T.accent, 'accent', BG.backdrop, 'backdrop', 3, 'кольцо фокуса 2 px (не текст)');
add(over([255, 255, 255], 0.14, BG.backdrop), 'strong-border', BG.backdrop, 'backdrop', 1, 'граница окна (декор)');

let failed = 0;
console.log('| Текст / элемент | Фон | Контраст | Нужно | Где |');
console.log('|---|---|---|---|---|');
for (const x of rows) {
  const ok = x.r + 1e-9 >= x.min;
  if (!ok) failed++;
  console.log(`| ${x.fgName} | ${x.bgName} | ${x.r.toFixed(2)} : 1 | ${x.min === 1 ? '—' : x.min} | ${x.use}${ok ? '' : ' **НИЖЕ НОРМЫ**'} |`);
}
if (failed) { console.log(`\nCONTRAST: ${failed} pair(s) below their minimum`); process.exitCode = 1; }
else console.log(`\nCONTRAST: all ${rows.length} pairs meet their minimum`);
