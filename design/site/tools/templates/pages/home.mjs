import { inline, esc } from '../../lib/html.mjs';
import { icon } from '../../lib/kit.mjs';
import { sectionHead, linkArrow, btn, featureCard, checkList, heroDemo, warmupSheet, stat } from '../components.mjs';

export default function home(c, { lang }) {
  const h = c.hero;
  const hero = `<section class="hero">
  <div class="container">
    <p class="eyebrow"><span class="dot"></span>${inline(h.eyebrow, lang)}</p>
    <h1 class="display">${inline(h.title, lang)}</h1>
    <p class="lead">${inline(h.lead, lang)}</p>
    <div class="btn-row stretch">
      ${btn('download.html', h.primary, 'primary', { size: 'lg', iconName: 'download', lang })}
      ${btn('verification.html', h.secondary, 'secondary', { size: 'lg', lang })}
    </div>
    <p class="hero-meta">${h.meta.map((m) => `<span>${inline(m, lang)}</span>`).join('')}</p>
    ${heroDemo(c.demo, lang)}
  </div>
</section>`;

  const a = c.audience;
  const audience = `<section class="section" id="audience">
  <div class="container">
    ${sectionHead({ title: a.title, lead: a.lead }, lang)}
    <div class="grid c4">${a.items.map((it) => featureCard(it, lang)).join('')}</div>
  </div>
</section>`;

  const p = c.pillars;
  const pillars = `<section class="section" id="why">
  <div class="container">
    <div class="row" style="justify-content:space-between;align-items:flex-end;gap:24px;margin-bottom:48px">
      <div class="section-head" style="margin:0">${`<h2 class="h2">${inline(p.title, lang)}</h2><p class="lead">${inline(p.lead, lang)}</p>`}</div>
      ${linkArrow('features.html', p.more, lang)}
    </div>
    <div class="pillars">${p.items.map((it) => `<a class="pillar reveal" href="${it.href}"><span class="pi">${icon(it.icon, 18)}${icon('arrowRight', 14, 'go')}</span><h3>${inline(it.title, lang)}</h3><p>${inline(it.text, lang)}</p></a>`).join('')}</div>
  </div>
</section>`;

  const pr = c.proof;
  const proof = `<section class="section" id="proof">
  <div class="container">
    ${sectionHead({ eyebrow: pr.eyebrow, title: pr.title, lead: pr.lead }, lang)}
    <div class="stats reveal">${pr.stats.map((s) => stat(s, lang)).join('')}</div>
    <div class="row" style="justify-content:space-between;margin-top:20px;gap:12px 24px">
      <span class="caption">${inline(pr.run, lang)}</span>
      ${linkArrow('verification.html', pr.link, lang)}
    </div>
  </div>
</section>`;

  const n = c.noise;
  const vrow = (rows, odd) => `<div class="runs">${rows.map(([k, v], i) => `<div${odd && i > 0 ? ' class="odd"' : ''}><span>${inline(k, lang)}</span><span>${inline(v, lang)}</span></div>`).join('')}</div>`;
  const noise = `<section class="section" id="noise">
  <div class="container">
    <div class="split even">
      <div>
        ${sectionHead({ eyebrow: n.eyebrow, title: n.title, lead: n.lead }, lang).replace('section-head', 'section-head reveal')}
        <div class="stack-lg">${n.points.map((pt) => `<div class="reveal"><h3 class="h4">${inline(pt.title, lang)}</h3><p class="muted small" style="margin-top:6px">${inline(pt.text, lang)}</p></div>`).join('')}</div>
        <p style="margin-top:32px">${linkArrow('blog-no-noise.html', n.link, lang)}</p>
      </div>
      <div class="versus reveal" style="align-self:center">
        <div><div class="vt">${icon('wave', 13)} ${inline(n.versus.noise, lang)}</div>${vrow(n.versus.noiseRows, true)}<p class="verdict">${inline(n.versus.noiseVerdict, lang)}</p></div>
        <div><div class="vt">${icon('equal', 13)} ${inline(n.versus.none, lang)}</div>${vrow(n.versus.noneRows)}<p class="verdict">${inline(n.versus.noneVerdict, lang)}</p></div>
      </div>
    </div>
  </div>
</section>`;

  const w = c.warmup;
  const warm = `<section class="section" id="warmup">
  <div class="container">
    <div class="split even">
      <div>
        ${sectionHead({ eyebrow: w.eyebrow, title: w.title, lead: w.lead }, lang)}
        ${checkList(w.bullets, lang, { accent: true })}
        <p style="margin-top:32px">${linkArrow('features.html#warmup', w.link, lang)}</p>
      </div>
      <div class="reveal" style="max-width:520px;width:100%;justify-self:end">${warmupSheet(w.sheet, lang)}</div>
    </div>
  </div>
</section>`;

  const pv = c.privacy;
  const privacy = `<section class="section" id="privacy">
  <div class="container">
    ${sectionHead({ eyebrow: pv.eyebrow, title: pv.title, lead: pv.lead }, lang)}
    <div class="knows reveal">
      <div><h3>${icon('server', 16)}${inline(pv.knowsTitle, lang)}</h3><ul>${pv.knows.map((k) => `<li><span>${inline(k, lang)}</span></li>`).join('')}</ul></div>
      <div><h3>${icon('lockFill', 16)}${inline(pv.notTitle, lang)}</h3><ul>${pv.not.map((k) => `<li><span>${inline(k, lang)}</span></li>`).join('')}</ul></div>
    </div>
    <div class="row" style="justify-content:space-between;align-items:flex-start;margin-top:20px;gap:16px 32px">
      <p class="small muted measure">${inline(pv.note, lang)}</p>
      ${linkArrow('privacy.html#server', pv.link, lang)}
    </div>
  </div>
</section>`;

  const ct = c.cta;
  const cta = `<section class="cta-band">
  <div class="container"><div class="inner">
    <div><h2 class="h2">${inline(ct.title, lang)}</h2><p class="lead" style="margin-top:12px">${inline(ct.lead, lang)}</p></div>
    <div class="btn-row stretch">${btn('download.html', ct.primary, 'primary', { size: 'lg', iconName: 'download', lang })}${btn('pricing.html', ct.secondary, 'secondary', { size: 'lg', lang })}</div>
  </div></div>
</section>`;

  return { body: [hero, audience, pillars, proof, noise, warm, privacy, cta].join('\n'), bodyClass: 'page-home' };
}
