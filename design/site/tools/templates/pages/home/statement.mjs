// Scene "statement": the idea in one paragraph; its words light up as you scroll (the one place for this
// device on the page).
import { esc } from '../../../lib/html.mjs';
import { manifest } from './lib.mjs';

export const assets = { styles: ['scenes/statement.css'] };

export default function statement(c, { lang }) {
  return `<section class="scene statement" data-scene="statement" data-title="${esc(c.title)}" style="--len:220vh">
  <div class="scene-pin"><div class="container">${manifest(c.text, lang)}</div></div>
</section>`;
}
