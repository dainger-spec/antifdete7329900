// Short recordings of motion.html: the same scripted actions on the "now" pane and on the "proposed"
// pane, recorded separately and put side by side with ffmpeg, so both play at the same moment.
//
//   node design/tools/record.mjs   →  design/shots/motion/{ru,en}/<scene>.mp4 (and ru/list.gif)
//
// Playwright records at ~25 frames a second: a 220 ms animation spans five or six frames, which is
// enough to see it, not to judge its curve — for that, open motion.html on the Mac.
import { createRequire } from 'node:module';
import { mkdirSync, rmSync, renameSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const { chromium } = createRequire(import.meta.url)('playwright');
const design = join(dirname(fileURLToPath(import.meta.url)), '..');
const url = (q) => `${pathToFileURL(join(design, 'prototypes', 'motion.html')).href}?${q}`;
const tmp = join(process.env.TMPDIR || '/tmp', `lumen-rec-${process.pid}`);

const SCENES = {
  // Hover sweep, launch a Ready profile with the pointer still on the list, leave the list, switch filters, focus search.
  list: { w: 560, h: 404, async run(page) {
    const rows = page.locator('.mrow');
    const first = await rows.first().boundingBox(), last = await rows.last().boundingBox();
    await page.mouse.move(first.x + 120, first.y - 30);
    await page.waitForTimeout(400);
    await page.mouse.move(last.x + 120, last.y + 17, { steps: 28 });
    await page.mouse.move(last.x + 120, first.y + 17, { steps: 28 });
    await page.waitForTimeout(500);
    const banking = page.locator('.mrow', { hasText: 'Banking' }).locator('[data-launch]');
    const b = await banking.boundingBox();
    await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2, { steps: 10 });
    await page.waitForTimeout(250);
    await page.mouse.down(); await page.mouse.up();
    await page.waitForTimeout(2200);
    const side = await page.locator('.mini-side').boundingBox();
    await page.mouse.move(side.x + 70, side.y + side.height - 30, { steps: 12 });
    await page.waitForTimeout(1100);
    for (const label of [1, 2, 0]) {
      const f = await page.locator('[data-filter]').nth(label).boundingBox();
      await page.mouse.move(f.x + 60, f.y + 14, { steps: 8 });
      await page.mouse.down(); await page.mouse.up();
      await page.waitForTimeout(900);
    }
    const s = await page.locator('.mini-head .field').boundingBox();
    await page.mouse.move(s.x + 80, s.y + 14, { steps: 10 });
    await page.mouse.down(); await page.mouse.up();
    await page.waitForTimeout(900);
  } },
  sheet: { w: 560, h: 290, async run(page) {
    await page.waitForTimeout(500);
    for (const i of [0, 2, 1, 0, 1]) {
      const t = await page.locator('[data-tab]').nth(i).boundingBox();
      await page.mouse.move(t.x + t.width / 2, t.y + 12, { steps: 8 });
      await page.mouse.down(); await page.mouse.up();
      await page.waitForTimeout(700);
    }
  } },
  launch: { w: 560, h: 338, async run(page) {
    await page.waitForTimeout(1200);
    for (let i = 0; i < 2; i++) {
      await page.evaluate(() => window.__motion.players.forEach((p) => p.play()));
      await page.waitForTimeout(1300);
    }
  } },
};

async function record(scene, mode, lang, rm) {
  const spec = SCENES[scene];
  const dir = join(tmp, `${scene}-${mode}-${lang}-${rm}`);
  mkdirSync(dir, { recursive: true });
  const browser = await chromium.launch();
  const context = await browser.newContext({ viewport: { width: spec.w, height: spec.h }, recordVideo: { dir, size: { width: spec.w, height: spec.h } } });
  await context.route((u) => !u.href.startsWith('file:'), (r) => r.abort());
  const page = await context.newPage();
  await page.goto(url(`scene=${scene}&only=${mode}&lang=${lang}${rm ? '&rm=1' : ''}`));
  await page.waitForFunction(() => window.__ready === true);
  await spec.run(page);
  const video = page.video();
  await context.close();
  await browser.close();
  return await video.path();
}

function ffmpeg(args) { execFileSync('ffmpeg', ['-y', '-loglevel', 'error', ...args]); }

for (const lang of ['ru', 'en']) {
  for (const scene of Object.keys(SCENES)) {
    for (const rm of [false, true]) {
      if (rm && scene !== 'list') continue;   // Reduce Motion matters most in the list
      const left = await record(scene, 'current', lang, rm);
      const right = await record(scene, 'proposed', lang, rm);
      const outDir = join(design, 'shots', 'motion', lang);
      mkdirSync(outDir, { recursive: true });
      const name = `${scene}${rm ? '-reduce-motion' : ''}`;
      // Side by side with a 12 px gap; drop the first 0.4 s (page load).
      ffmpeg(['-ss', '0.4', '-i', left, '-ss', '0.4', '-i', right, '-filter_complex',
        '[0:v]pad=iw+12:ih:0:0:color=0x0B0C0F[l];[l][1:v]hstack=inputs=2,format=yuv420p[v]', '-map', '[v]',
        '-c:v', 'libx264', '-crf', '20', '-preset', 'slow', '-movflags', '+faststart', join(outDir, `${name}.mp4`)]);
      // A GIF of the list (it plays inline in the README on GitHub), in the app's default language only.
      if (lang === 'ru' && name === 'list') ffmpeg(['-i', join(outDir, `${name}.mp4`), '-vf', 'fps=20,scale=900:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=64[p];[b][p]paletteuse=dither=none', join(outDir, `${name}.gif`)]);
      console.log(`WROTE shots/motion/${lang}/${name}.mp4${lang === 'ru' && name === 'list' ? ' + .gif' : ''}`);
    }
  }
}
rmSync(tmp, { recursive: true, force: true });
