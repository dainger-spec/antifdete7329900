// The home page: a presentation in scenes. Each scene is a module in ./home/<scene>.mjs that takes its own
// texts (copy/source/<lang>/home-<scene>.mjs) and returns its HTML; its styles and script (assets/scenes/)
// are listed in the module's `assets`. The order below is the story the page tells.
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ORDER = ['hero', 'statement', 'mission', 'sites', 'layers', 'proxy', 'encryption', 'warmup', 'numbers', 'bento', 'cta'];
const here = path.dirname(fileURLToPath(import.meta.url));

/// One scene: its module (fresh on every call, so a preview always sees the latest file) and its texts.
export async function scene(name, ctx) {
  const mod = await import(pathToFileURL(path.join(here, 'home', `${name}.mjs`)).href + `?t=${Date.now()}`);
  const c = await ctx.copy(`home-${name}`);
  return { html: await mod.default(c, ctx), styles: mod.assets?.styles || [], scripts: mod.assets?.scripts || [] };
}

export default async function home(c, ctx, order = ORDER) {
  const parts = [];
  for (const name of order) parts.push(await scene(name, ctx));
  const uniq = (xs) => [...new Set(xs)];
  return {
    body: parts.map((p) => p.html).join('\n'),
    bodyClass: 'page-home',
    styles: uniq(parts.flatMap((p) => p.styles)),
    scripts: uniq(parts.flatMap((p) => p.scripts)),
  };
}
