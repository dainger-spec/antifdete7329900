// Previews of the cover over a virtual machine's start (design/prototypes/vm-cover.html): every
// frame drawn at its own time (window.__render), so a recording is as smooth as the animation,
// whatever the machine.
//
//   node design/tools/record_vm_cover.mjs <out folder> [--lang ru,en] [--size 1440x900] [--scale 2]
//        [--fps 60] [--video] [--frames] [--name Vienna]
//
// --frames: <lang>-1-early.png (signing in), <lang>-2-middle.png (the look), <lang>-3-longer.png
//           ("Show the screen", after a minute), <lang>-4-reduce-motion.png, <lang>-5-revealed.png
//           (the machine's desktop, Safari open), at --scale.
// --video:  <lang>.mp4, the whole start: a step every 3.6 s, the fade into the machine's desktop,
//           Safari opening — drawn at --scale and written at --size (ffmpeg, H.264).
// Loads the page from disk (file://) and nothing else.
import { createRequire } from 'node:module';
import { mkdirSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const { chromium } = createRequire(import.meta.url)('playwright');
const design = join(dirname(fileURLToPath(import.meta.url)), '..');
const page = pathToFileURL(join(design, 'prototypes', 'vm-cover.html')).href;

const args = process.argv.slice(2);
const out = args[0];
if (!out) { console.error('usage: record_vm_cover.mjs <out folder> [options]'); process.exit(2); }
const option = (name, fallback) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : fallback; };
const langs = option('--lang', 'ru,en').split(',');
const [width, height] = option('--size', '1440x900').split('x').map(Number);
const scale = Number(option('--scale', '2'));
const fps = Number(option('--fps', '60'));
const name = option('--name', 'Vienna');
mkdirSync(out, { recursive: true });

const browser = await chromium.launch();
async function open(query) {
  const context = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: scale });
  await context.route((u) => !u.href.startsWith('file:'), (r) => r.abort());
  const tab = await context.newPage();
  tab.on('pageerror', (e) => { console.error(`page error: ${e.message}`); process.exitCode = 1; });
  await tab.goto(`${page}?name=${encodeURIComponent(name)}&${query}&t=0`);
  await tab.waitForFunction(() => window.__ready === true);
  return { context, tab };
}
async function shot(tab, t, file) {
  await tab.evaluate((time) => window.__render(time), t);
  await tab.screenshot({ path: join(out, file) });
}

for (const lang of langs) {
  if (args.includes('--frames')) {
    // A still step, at a moment its light is on the horizon.
    for (const [file, query, t] of [
      [`${lang}-1-early.png`, `lang=${lang}&stage=signin`, 1.9],
      [`${lang}-2-middle.png`, `lang=${lang}&stage=look`, 3.0],
      [`${lang}-3-longer.png`, `lang=${lang}&stage=locale&offer=1`, 4.1],
      [`${lang}-4-reduce-motion.png`, `lang=${lang}&stage=wallpaper&rm=1`, 3.0],
    ]) {
      const { context, tab } = await open(query);
      await shot(tab, t, file);
      await context.close();
    }
    const { context, tab } = await open(`lang=${lang}`);
    const info = await tab.evaluate(() => window.__info());
    await shot(tab, info.safariAt + 1.2, `${lang}-5-revealed.png`);
    await context.close();
    console.log(`frames: ${lang}`);
  }
  if (args.includes('--video')) {
    const { context, tab } = await open(`lang=${lang}`);
    const info = await tab.evaluate(() => window.__info());
    const frames = join(out, `.frames-${lang}`);
    rmSync(frames, { recursive: true, force: true });
    mkdirSync(frames);
    const count = Math.ceil(info.end * fps);
    for (let i = 0; i <= count; i++) {
      await shot(tab, i / fps, join(`.frames-${lang}`, `${String(i).padStart(5, '0')}.png`));
    }
    execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', join(frames, '%05d.png'),
      '-vf', `scale=${width}:${height}:flags=lanczos`, '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '14',
      '-preset', 'slow', '-movflags', '+faststart', join(out, `${lang}.mp4`)]);
    rmSync(frames, { recursive: true, force: true });
    await context.close();
    console.log(`video: ${lang}.mp4 (${count + 1} frames, ${info.end.toFixed(2)} s)`);
  }
}
await browser.close();
