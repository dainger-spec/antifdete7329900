// Renders the prototypes into the "after" PNGs of design/shots/after/{ru,en}/, at Retina scale (×2)
// and in the window sizes the CI snapshots use (UISnapshots.swift), so each pair compares like with like.
//
//   node design/tools/render.mjs            # everything
//   node design/tools/render.mjs profiles   # only shots whose name contains "profiles"
//
// Uses the Chromium that comes with Playwright; loads the pages from disk (file://) and nothing else:
// any request that is not a file:// URL fails the render.
import { createRequire } from 'node:module';
import { mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

// The Playwright installed with this machine's tools (require() finds it where an ES import does not).
const { chromium } = createRequire(import.meta.url)('playwright');
const design = join(dirname(fileURLToPath(import.meta.url)), '..');
const proto = (file) => pathToFileURL(join(design, 'prototypes', file)).href;

// name: the CI snapshot it pairs with (same name) or an after-only state (prefixed "new-").
export const SHOTS = [
  { name: 'profiles', page: 'profiles.html', query: 'state=default', w: 1180, h: 740 },
  { name: 'profiles-narrow', page: 'profiles.html', query: 'state=narrow', w: 920, h: 620 },
  { name: 'profiles-proxied', page: 'profiles.html', query: 'state=proxied', w: 1180, h: 560 },
  { name: 'profiles-empty', page: 'profiles.html', query: 'state=empty', w: 1180, h: 640 },
  { name: 'profiles-no-matches', page: 'profiles.html', query: 'state=nomatch', w: 1180, h: 520 },
  { name: 'new-profiles-selection', page: 'profiles.html', query: 'state=selection', w: 1180, h: 740 },
  { name: 'new-profiles-scale', page: 'profiles.html', query: 'state=scale', w: 1180, h: 740 },
  { name: 'new-profiles-filtered', page: 'profiles.html', query: 'state=filtered', w: 1180, h: 740 },
  { name: 'new-profiles-error', page: 'profiles.html', query: 'state=error', w: 1180, h: 740 },
  { name: 'new-profiles-keyboard', page: 'profiles.html', query: 'state=keyboard', w: 1180, h: 740 },
  { name: 'new-profiles-scale-row32', page: 'profiles.html', query: 'state=scale&row=32', w: 1180, h: 740 },
  { name: 'new-profiles-scale-flat', page: 'profiles.html', query: 'state=scale&sort=status', w: 1180, h: 740 },
  // The profile editor sheet (ProfileEditorForm.size 600 × 660; sheets have no title bar)
  { name: 'editor-network', page: 'editor.html', query: 'state=network', w: 600, h: 660 },
  { name: 'editor-data-ephemeral', page: 'editor.html', query: 'state=data-ephemeral', w: 600, h: 660 },
  { name: 'editor-general-new', page: 'editor.html', query: 'state=general-new', w: 600, h: 660 },
  { name: 'editor-identity', page: 'editor.html', query: 'state=identity', w: 600, h: 660 },
  { name: 'editor-privacy', page: 'editor.html', query: 'state=privacy', w: 600, h: 660 },
  { name: 'new-editor-network-error', page: 'editor.html', query: 'state=network-error', w: 600, h: 660 },
  { name: 'new-editor-network-full', page: 'editor.html', query: 'state=network-error&h=1000', w: 600, h: 1000 },
  { name: 'new-editor-details', page: 'editor.html', query: 'state=details', w: 600, h: 660 },
  // App settings: one Settings window instead of three sheets (sync pairs with sheet-sync 540 × 460)
  { name: 'sheet-sync', page: 'settings.html', query: 'state=sync', w: 540, h: 460 },
  { name: 'sheet-change-password', page: 'settings.html', query: 'state=changepw', w: 420, h: 378 },  // taller than the 330 of CI: labels over fields, rules under them
  { name: 'new-settings-network', page: 'settings.html', query: 'state=network', w: 600, h: 400 },
  { name: 'new-settings-security', page: 'settings.html', query: 'state=security', w: 540, h: 320 },
  // The system: type scale, numerals, metrics, contrast, states, accessibility
  { name: 'new-system-type', page: 'system.html', query: 'state=type', w: 1180, h: 800 },
  { name: 'new-system-numerals', page: 'system.html', query: 'state=numerals', w: 1180, h: 420 },
  { name: 'new-system-metrics', page: 'system.html', query: 'state=metrics', w: 1180, h: 600 },
  { name: 'new-system-contrast', page: 'system.html', query: 'state=contrast', w: 1180, h: 820 },
  { name: 'new-system-states', page: 'system.html', query: 'state=states', w: 1180, h: 360 },
  { name: 'new-system-a11y', page: 'system.html', query: 'state=a11y', w: 1180, h: 520 },
];

export async function render(shots, { langs = ['ru', 'en'], extra = [] } = {}) {
  const browser = await chromium.launch();
  const context = await browser.newContext({ deviceScaleFactor: 2, reducedMotion: 'reduce' });
  // Prototypes must not reach the network, even by accident: fail loudly if one tries.
  await context.route((url) => !url.href.startsWith('file:'), (route) => {
    console.error(`BLOCKED network request ${route.request().url()}`);
    process.exitCode = 1;
    return route.abort();
  });
  for (const shot of [...shots, ...extra]) {
    for (const lang of shot.langs || langs) {
      const page = await context.newPage({});
      await page.setViewportSize({ width: shot.w, height: shot.h });
      const url = `${proto(shot.page)}?frame=0&lang=${lang}&${shot.query || ''}`;
      await page.goto(url);
      await page.waitForFunction(() => window.__ready === true);
      if (shot.prepare) await shot.prepare(page);
      await page.evaluate(() => document.fonts.ready);
      const out = join(design, 'shots', 'after', lang, `${shot.name}.png`);
      mkdirSync(dirname(out), { recursive: true });
      await page.screenshot({ path: out, clip: { x: 0, y: 0, width: shot.w, height: shot.h } });
      console.log(`WROTE ${lang}/${shot.name}.png (${shot.w * 2}×${shot.h * 2})`);
      await page.close();
    }
  }
  await browser.close();
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const filter = process.argv[2];
  await render(SHOTS.filter((s) => !filter || s.name.includes(filter)));
}
