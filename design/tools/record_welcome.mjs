// Previews of the launch screen (design/prototypes/welcome.html): every frame drawn at its own time
// (window.__render), so a recording is as smooth as the animation, whatever the machine.
//
//   node design/tools/record_welcome.mjs <out folder> [--lang ru,en] [--size 1440x900] [--scale 2]
//        [--fps 60] [--video] [--frames] [--first] [--rm]
//
// --frames: <lang>-25.png, -60.png, -100.png (that much of the writing done) and <lang>-settled.png.
// --video:  <lang>.mp4, the whole screen from the window's opening to the lock screen (ffmpeg, H.264);
//           with --first, the button is pressed 1.6 s after the writing.
// Loads the page from disk (file://) and nothing else.
import { createRequire } from 'node:module';
import { mkdirSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const { chromium } = createRequire(import.meta.url)('playwright');
const design = join(dirname(fileURLToPath(import.meta.url)), '..');
const page = pathToFileURL(join(design, 'prototypes', 'welcome.html')).href;

const args = process.argv.slice(2);
const out = args[0];
if (!out) { console.error('usage: record_welcome.mjs <out folder> [options]'); process.exit(2); }
const option = (name, fallback) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : fallback; };
const langs = option('--lang', 'ru,en').split(',');
const [width, height] = option('--size', '1440x900').split('x').map(Number);
const scale = Number(option('--scale', '2'));
const fps = Number(option('--fps', '60'));
const first = args.includes('--first');
const rm = args.includes('--rm');
mkdirSync(out, { recursive: true });

const browser = await chromium.launch();
for (const lang of langs) {
  const context = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: scale });
  await context.route((u) => !u.href.startsWith('file:'), (r) => r.abort());
  const tab = await context.newPage();
  const query = `lang=${lang}${first ? '&first=1' : ''}${rm ? '&rm=1' : ''}&t=0`;
  await tab.goto(`${page}?${query}`);
  await tab.waitForFunction(() => window.__ready === true);
  // The first launch waits for its button: the recording presses it 1.6 s after the writing.
  if (first) await tab.evaluate(() => window.__skipAt(window.__info().writtenAt + 1.6));
  const info = await tab.evaluate(() => window.__info());
  const suffix = `${first ? '-first' : ''}${rm ? '-rm' : ''}`;
  const shot = async (t, file) => {
    await tab.evaluate((time) => window.__render(time), t);
    await tab.screenshot({ path: join(out, file) });
  };
  if (args.includes('--frames')) {
    const pen = info.writtenAt - info.duration;
    for (const [label, part] of [['25', 0.25], ['60', 0.6], ['100', 1]]) {
      await shot(pen + info.duration * part + (part === 1 ? 0.01 : 0), `${lang}${suffix}-${label}.png`);
    }
    await shot(info.writtenAt + 0.8, `${lang}${suffix}-settled.png`);
    console.log(`frames: ${lang}${suffix}`);
  }
  if (args.includes('--video')) {
    const frames = join(out, `.frames-${lang}${suffix}`);
    rmSync(frames, { recursive: true, force: true });
    mkdirSync(frames);
    const end = Number.isFinite(info.end) ? info.end + 0.6 : info.writtenAt + 2.2;
    const count = Math.ceil(end * fps);
    for (let i = 0; i <= count; i++) {
      await shot(i / fps, join('.frames-' + lang + suffix, `${String(i).padStart(5, '0')}.png`));
    }
    execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', join(frames, '%05d.png'),
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '16', '-preset', 'slow', '-movflags', '+faststart',
      join(out, `${lang}${suffix}.mp4`)]);
    rmSync(frames, { recursive: true, force: true });
    console.log(`video: ${lang}${suffix}.mp4 (${count + 1} frames, ${(end).toFixed(2)} s)`);
  }
  await context.close();
}
await browser.close();
