// Scene "warmup" — a placeholder until the scene is designed: its title and lead in normal flow.
import { inline, esc } from '../../../lib/html.mjs';
import { twoTone } from './lib.mjs';

export const assets = { styles: [], scripts: [] };

export default function scene(c, { lang }) {
  const head = c.head || c.title;
  return `<section class="scene sc-warmup" data-scene="warmup" data-title="${esc(c.title || c.section || '')}" style="--len:160vh">
  <div class="scene-pin"><div class="container">
    <h2 class="h-xl">${twoTone(Array.isArray(head) ? head : [head], lang)}</h2>
    ${c.lead ? `<p class="lead">${inline(c.lead, lang)}</p>` : ''}
  </div></div>
</section>`;
}
