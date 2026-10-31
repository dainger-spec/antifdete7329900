// The promo film v2's gates (spec v2 §2, §6). Exit 1 if any fails.
//   facts    the stage's every text (shown or not, both languages) and copy/source/<lang>/film.mjs: no «434»,
//            «все 448», «совпадают все», «антидетект»/«antidetect», domains other than *.example, or a trial
//            length (\d+\s*(дн|day));
//   glyphs   every display-size line (XL, L, M) rendered alone, glyph by glyph in alternating colours: no two
//            neighbouring glyphs closer than 0.04 em (gates.py glyphs);
//   s08      S08's two halves, alone and unclipped: identical pixels below the toolbar band (gates.py s08);
//   palette  the finished frames: one blue at most, no other colour off the chips and traffic lights;
//   flash    WCAG 2.3.1 on a quarter-size capture of a stretch of the film (--flash a-b, seconds);
//   plates   the rendered plates are neutral (R = G = B ± 1) off the display.
//
//   node tools/film/gates.mjs [ru|en] [--frames DIR | --stills] [--flash 5.3-7.3] [--only facts,glyphs,…] [--fix]
//   --fix: the glyph pairs closer than 0.04 em get the extra space they need in tools/film/kern.json (build.mjs
//   sets it as the first glyph's right margin), then node tools/film/build.mjs and run the gate again.
//   (default frames: video/.cache/frames/<lang> if it has frames, else video/.cache/stills-v2/<lang>-*.png)
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const SITE = path.resolve(here, '../..');
const CACHE = path.join(SITE, 'video', '.cache');
const { chromium } = createRequire(path.join(SITE, 'tools/render.mjs'))('playwright');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : d; };
const lang = args[0] && !args[0].startsWith('--') ? args[0] : 'ru';
const only = opt('only', 'facts,glyphs,s08,palette,flash,plates').split(',');
const results = [];
const py = (...a) => spawnSync('python3', ['-I', path.join(here, 'gates.py'), ...a], { stdio: 'inherit' }).status === 0;
const node = (...a) => spawnSync('node', [path.join(here, ...a.slice(0, 1)), ...a.slice(1)], { stdio: 'inherit' }).status === 0;

async function stage(l) {
  const browser = await chromium.launch();
  const page = await (await browser.newContext({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 2 })).newPage();
  await page.goto(pathToFileURL(path.join(SITE, 'video', 'stage', `${l}.html`)).href);
  await page.evaluate(() => window.FILM.ready);
  return { browser, page };
}

// MARK: facts
if (only.includes('facts')) {
  const RULES = [[/434/, '«434»'], [/все\s+448/i, '«все 448»'], [/совпадают\s+все/i, '«совпадают все»'], [/антидетект/i, '«антидетект»'], [/anti-?detect/i, '«antidetect»'],
    [/\d+\s*(дн|day)/i, 'a trial length'], [/all\s+448/i, '«all 448»']];
  const FILES = /\.(txt|json|png|pbprofile|csv|html)$/i;
  let ok = true;
  for (const l of ['ru', 'en']) {
    const { browser, page } = await stage(l);
    const [text, own] = await page.evaluate(() => {
      const out = [];
      const tw = document.createTreeWalker(document.querySelector('.reel'), NodeFilter.SHOW_TEXT);
      while (tw.nextNode()) if (tw.currentNode.data.trim()) out.push(tw.currentNode.data.trim());
      return [out.join('\n'), Array.from(document.querySelectorAll('.tx')).map((e) => e.textContent).join('\n')];
    });
    await browser.close();
    const copy = JSON.stringify((await import(pathToFileURL(path.join(SITE, 'copy', 'source', l, 'film.mjs')).href)).default);
    for (const [where, s] of [[`${l} stage`, text], [`${l} film.mjs`, copy]]) {
      for (const [rx, what] of RULES) { const m = s.match(rx); if (m) { ok = false; console.log(`FACTS FAIL ${where}: ${what} in “…${s.slice(Math.max(0, m.index - 30), m.index + 30).replace(/\s+/g, ' ')}…”`); } }
      // (an e-mail's domain counts too: «hanako@example.jp» is a domain other than *.example)
      for (const m of s.matchAll(/(?<![\w.-])(?:[a-z0-9-]+\.)+[a-z]{2,}(?![\w-])/gi)) {
        const d = m[0].toLowerCase();
        if (d.endsWith('.example') || FILES.test(d) || /^(u\.s|a\.m|p\.m|z\.b)$/.test(d)) continue;
        ok = false; console.log(`FACTS FAIL ${where}: a domain that is not *.example: ${m[0]}`);
      }
    }
    // exactly one em dash in the film's own type (S03), in Russian; none needed in English
    const dashes = (own.match(/—/g) || []).length;
    if (l === 'ru' ? dashes !== 1 : dashes > 1) { ok = false; console.log(`FACTS FAIL ${l}: ${dashes} em dashes in the film's own type (the film has exactly one)`); }
    console.log(`facts ${l}: ${text.length} characters of stage text checked; ${dashes} em dash(es) in the film's own type`);
  }
  console.log(ok ? 'facts ok' : 'FACTS FAIL');
  results.push(['facts', ok]);
}

// MARK: glyphs — every pair of neighbouring glyphs of every display-size line, rendered alone (the pair red and
// green, the rest of the line invisible but in place, so kerning and tracking are the line's own)
if (only.includes('glyphs')) {
  const out = path.join(CACHE, 'gates', lang, 'glyphs');
  fs.rmSync(out, { recursive: true, force: true });
  fs.mkdirSync(out, { recursive: true });
  const { browser, page } = await stage(lang);
  const lines = await page.evaluate(() => {
    const res = [];
    document.documentElement.classList.add('measure');
    document.querySelectorAll('.shot').forEach((s) => s.classList.add('on'));
    document.querySelectorAll('.swap').forEach((s) => s.classList.add('cur'));
    const box = document.createElement('div');
    box.style.cssText = 'position:fixed;left:0;top:0;width:1920px;height:1080px;background:#000;z-index:99;';
    document.body.appendChild(box);
    let k = 0;
    for (const el of document.querySelectorAll('.tx.xl, .tx.l, .tx.m')) {
      if (el.classList.contains('clock')) continue;
      const size = ['xl', 'l', 'm'].find((c) => el.classList.contains(c));
      const shot = el.closest('.shot').dataset.shot;
      // the line as built (its kerning spans included), each character in a span of its own
      const d = el.cloneNode(true);
      d.removeAttribute('data-on');
      d.style.cssText = 'position:absolute;left:40px;top:40px;white-space:nowrap;visibility:visible;color:transparent';
      d.querySelectorAll('.bl').forEach((b) => b.remove());
      const walk = document.createTreeWalker(d, NodeFilter.SHOW_TEXT);
      const texts = []; while (walk.nextNode()) texts.push(walk.currentNode);
      const glyphs = [];
      for (const t of texts) {
        const frag = document.createDocumentFragment();
        for (const ch of t.data) { const s = document.createElement('span'); s.textContent = ch; frag.appendChild(s); if (ch.trim()) glyphs.push(s); }
        t.replaceWith(frag);
      }
      d.querySelectorAll('*').forEach((x) => { x.style.color = 'transparent'; });
      d.style.display = 'none';
      d.dataset.k = String(k);
      box.appendChild(d);
      d.style.display = 'block';
      const pairs = [];
      for (let i = 0; i + 1 < glyphs.length; i++) {
        const a = glyphs[i].getBoundingClientRect(), b = glyphs[i + 1].getBoundingClientRect();
        if (b.left - a.right > 0.3 * parseFloat(getComputedStyle(d).fontSize)) continue;      // across a space
        pairs.push({ i, a: glyphs[i].textContent, b: glyphs[i + 1].textContent, clip: { x: Math.max(0, a.left - 30), y: Math.max(0, Math.min(a.top, b.top) - 30), width: b.right - a.left + 60, height: Math.max(a.bottom, b.bottom) - Math.min(a.top, b.top) + 60 } });
      }
      d.style.display = 'none';
      window.__glyphs = window.__glyphs || {}; window.__glyphs[k] = glyphs;
      res.push({ k: k++, shot, size, text: el.textContent, px: parseFloat(getComputedStyle(d).fontSize), pairs });
    }
    return res;
  });
  const meta = [];
  for (const L of lines) {
    for (const P of L.pairs) {
      await page.evaluate(([k, i]) => {
        document.querySelectorAll('[data-k]').forEach((d) => { d.style.display = d.dataset.k === String(k) ? 'block' : 'none'; });
        window.__glyphs[k].forEach((g, j) => { g.style.color = j === i ? '#FF0000' : j === i + 1 ? '#00FF00' : 'transparent'; });
      }, [L.k, P.i]);
      const file = `g${String(L.k).padStart(2, '0')}-${String(P.i).padStart(2, '0')}.png`;
      await page.screenshot({ path: path.join(out, file), clip: P.clip });
      meta.push({ file, shot: L.shot, size: L.size, text: L.text, pair: P.a + P.b, px: L.px * 2 });
    }
  }
  await browser.close();
  fs.writeFileSync(path.join(out, 'glyphs.json'), JSON.stringify(meta, null, 1));
  const fix = args.includes('--fix') ? ['--fix', path.join(here, 'kern.json')] : [];
  results.push(['glyphs', py('glyphs', out, ...fix)]);
}

// MARK: S08 zero-diff
if (only.includes('s08')) {
  const out = path.join(CACHE, 'gates', lang);
  const okCap = node('capture.mjs', lang, '--qa', 's08', '--out', out);
  results.push(['s08', okCap && py('s08', path.join(out, 's08-l.png'), path.join(out, 's08-r.png'), String(120 + 52 * 1.95 + 3))]);
}

// MARK: palette
if (only.includes('palette')) {
  const fdir = opt('frames', path.join(CACHE, 'frames', lang));
  let files = fs.existsSync(fdir) && !args.includes('--stills') ? fs.readdirSync(fdir).filter((x) => /^\d{4}\.png$/.test(x)).map((x) => path.join(fdir, x)) : [];
  if (!files.length) {
    const sd = path.join(CACHE, 'stills-v2');
    files = fs.existsSync(sd) ? fs.readdirSync(sd).filter((x) => new RegExp(`^${lang}-\\d`).test(x)).map((x) => path.join(sd, x)) : [];
  }
  results.push(['palette', files.length ? py('palette', ...files, '--dom', path.join(CACHE, 'dom', lang)) : (console.log('palette: no frames'), true)]);
}

// MARK: flash
if (only.includes('flash') && opt('flash', null)) {
  const [a, b] = opt('flash').split('-').map(Number);
  const out = path.join(CACHE, 'gates', lang, 'flash');
  fs.rmSync(out, { recursive: true, force: true });
  const okCap = node('capture.mjs', lang, '--from', String(a), '--to', String(b), '--scale', '0.25', '--out', out, '--workers', '2');
  results.push(['flash', okCap && py('flash', out)]);
}

// MARK: plates
if (only.includes('plates')) results.push(['plates', py('plates')]);

console.log(results.map(([k, ok]) => `${k}: ${ok ? 'ok' : 'FAIL'}`).join(' · '));
if (results.some(([, ok]) => !ok)) process.exitCode = 1;
