// "What if Lumen used macOS materials?" — the Profiles window on three desktops (light, dark, busy) as it is
// (flat), with a translucent sidebar (what Apple's own apps do), and with material everywhere it could go
// (sidebar, header over the scrolled list, menus). Measures the sidebar's text contrast on each desktop and
// lays it all out on one sheet per language.
//
//   node design/tools/effects.mjs
import { createRequire } from 'node:module';
import { mkdirSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const { chromium } = createRequire(import.meta.url)('playwright');
const here = dirname(fileURLToPath(import.meta.url));
const design = join(here, '..');
const scratch = join(process.env.TMPDIR || '/tmp', `lumen-fx-${process.pid}`);
mkdirSync(scratch, { recursive: true });
const proto = pathToFileURL(join(design, 'prototypes', 'profiles.html')).href;

const MODES = ['flat', 'sidebar', 'all'];
const WALLS = ['warm', 'dark', 'busy'];
const W = 1180 + 56, H = 740 + 56;

const browser = await chromium.launch();
const context = await browser.newContext({ deviceScaleFactor: 2 });
await context.route((u) => !u.href.startsWith('file:'), (r) => r.abort());

async function render(lang, mode, wall) {
  const page = await context.newPage();
  await page.setViewportSize({ width: W, height: H });
  await page.goto(`${proto}?frame=0&lang=${lang}&state=default&material=${mode}&wallpaper=${wall}`);
  await page.waitForFunction(() => window.__ready === true);
  await page.waitForTimeout(150);
  const file = join(scratch, `${lang}-${mode}-${wall}.png`);
  await page.screenshot({ path: file });
  await page.close();
  return file;
}

for (const lang of ['ru', 'en']) {
  const files = {};
  for (const mode of MODES) for (const wall of WALLS) files[`${mode}-${wall}`] = await render(lang, mode, wall);
  const statsFile = join(scratch, `${lang}-stats.json`);
  execFileSync('python3', ['-I', join(here, 'sample_sidebar.py'), statsFile, ...Object.values(files)]);
  const stats = JSON.parse(readFileSync(statsFile, 'utf8'));
  const T = (ru, en) => (lang === 'en' ? en : ru);
  const modeTitle = { flat: T('Плоско (как сейчас)', 'Flat (as now)'), sidebar: T('Материал в боковой панели', 'Material in the sidebar'), all: T('Материал везде', 'Material everywhere') };
  const wallTitle = { warm: T('светлые обои', 'light wallpaper'), dark: T('тёмные обои', 'dark wallpaper'), busy: T('пёстрые обои', 'busy wallpaper') };
  const cell = (mode, wall) => {
    const st = stats[`${lang}-${mode}-${wall}.png`];
    const fmt = (k) => {
      const v = st[k];
      const cls = v.worst < 4.5 ? 'bad' : '';
      return `<span class="${cls}">${k.replace('text', '')} ${v.worst === v.best ? v.worst.toFixed(1) : `${v.worst.toFixed(1)}–${v.best.toFixed(1)}`}</span>`;
    };
    return `<figure><img src="${pathToFileURL(files[`${mode}-${wall}`]).href}"><figcaption>${wallTitle[wall]} · ${fmt('textSecondary')} · ${fmt('textTertiary')}</figcaption></figure>`;
  };
  const html = `<!doctype html><html><head><meta charset="utf-8"><style>
    body { margin: 0; background: #0B0C0F; color: #A2A9B6; font: 400 12px/16px Inter, sans-serif; -webkit-font-smoothing: antialiased; }
    .wrap { padding: 24px; } h1 { font: 600 15px/20px Inter, sans-serif; color: #ECEEF2; margin: 0 0 4px; } p { margin: 0 0 14px; max-width: 1180px; }
    .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 14px 16px; }
    .col h2 { font: 600 13px/18px Inter, sans-serif; color: #ECEEF2; margin: 0 0 8px; }
    figure { margin: 0 0 12px; } img { width: 100%; display: block; border-radius: 8px; }
    figcaption { margin-top: 6px; font: 500 11px/14px Inter, sans-serif; color: #8A93A3; font-variant-numeric: tabular-nums; }
    figcaption span.bad { color: #EC6F68; } .verdict { margin-top: 6px; padding: 12px 14px; border-radius: 10px; background: #1B1F27; border: 1px solid rgba(255,255,255,.08); color: #ECEEF2; max-width: 1180px; }
  </style></head><body><div class="wrap">
    <h1>${T('Эффекты: материал macOS вместо плоских поверхностей — честно, на всех поверхностях', 'Effects: macOS material instead of flat surfaces — honestly, on every surface')}</h1>
    <p>${T('Одно и то же окно «Профили» на трёх рабочих столах. Под каждым — контраст текста боковой панели, измеренный по отрендеренным пикселям (худший–лучший, WCAG): у плоской панели он один и тот же (Secondary 7.8, Tertiary 6.0 с предлагаемым цветом), у материала зависит от обоев пользователя. Материал здесь — приближение (размытие 34 px + тёмная подложка 80 %); настоящий NSVisualEffectView .sidebar с vibrancy даст другие числа, но тоже диапазон. Меню и поповеры macOS стеклянные уже сейчас — их рисует система.', 'The same Profiles window on three desktops. Under each: the sidebar’s text contrast measured from the rendered pixels (worst–best, WCAG): flat, it never changes (Secondary 7.8, Tertiary 6.0 with the proposed colour); with material it depends on the user’s wallpaper. The material here is an approximation (34 px blur + an 80 % dark tint); the real NSVisualEffectView .sidebar with vibrancy gives other numbers, but a range too. macOS menus and popovers are glass already — the system draws them.')}</p>
    <div class="grid">${MODES.map((mode) => `<div class="col"><h2>${modeTitle[mode]}</h2>${WALLS.map((wall) => cell(mode, wall)).join('')}</div>`).join('')}</div>
    <div class="verdict">${T('Вывод: если вводить материал, то правилом для всех поверхностей сразу (боковая панель, заголовок над списком, листы, поповеры) — иначе окно наполовину стеклянное, наполовину плоское. Цена: контраст становится диапазоном, а не числом; нужна проверка на «Уменьшить прозрачность»; цвет обоев начинает просвечивать в записи экрана. Рекомендую оставить плоско.', 'Verdict: if material comes, it comes as a rule for every surface at once (sidebar, header over the list, sheets, popovers) — otherwise the window is half glass, half flat. The price: contrast becomes a range, not a number; Reduce Transparency must be checked; the wallpaper’s colours show in screen recordings. I recommend staying flat.')}</div>
  </div></body></html>`;
  const sheetFile = join(scratch, `${lang}-sheet.html`);
  writeFileSync(sheetFile, html);
  const page = await context.newPage();
  await page.setViewportSize({ width: 1260, height: 900 });
  await page.goto(pathToFileURL(sheetFile).href);
  await page.waitForTimeout(300);
  const out = join(design, 'shots', 'after', lang, 'new-effects.png');
  mkdirSync(dirname(out), { recursive: true });
  await page.screenshot({ path: out, fullPage: true });
  await page.close();
  // Two full-size views: material everywhere on the light desktop, sidebar material on the busy one.
  for (const [mode, wall] of [['all', 'warm'], ['sidebar', 'busy']]) {
    execFileSync('cp', [files[`${mode}-${wall}`], join(design, 'shots', 'after', lang, `new-effects-${mode}-${wall}.png`)]);
  }
  writeFileSync(join(design, 'shots', 'after', lang, 'new-effects-contrast.json'), JSON.stringify(stats, null, 1));
  console.log(`WROTE ${lang}/new-effects.png and the two full-size views`);
}
await browser.close();
rmSync(scratch, { recursive: true, force: true });
