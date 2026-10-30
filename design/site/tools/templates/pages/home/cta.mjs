// Scene "cta": the last call — the mark drawn in code, small, comes up once (site.js, "Code art").
import { inline } from '../../../lib/html.mjs';
import { glyph } from '../../../lib/kit.mjs';
import { btn } from '../../components.mjs';

export const assets = {};

export default function cta(ct, { lang }) {
  return `<section class="final"><div class="container center-text">
    <div class="final-art"><canvas data-codeart="mark" aria-hidden="true"></canvas><div class="art-fallback">${glyph(96, '#2A2F3A')}</div></div>
    <h2 class="h-xxl" style="margin-top:28px">${inline(ct.title, lang)}</h2>
    <p class="lead" style="margin:18px auto 0;max-width:560px">${inline(ct.lead, lang)}</p>
    <div class="btn-row center" style="margin-top:34px">${btn('download.html', ct.primary, 'primary', { size: 'lg', iconName: 'download', lang })}${btn('pricing.html', ct.secondary, 'secondary', { size: 'lg', lang })}</div>
  </div></section>`;
}
