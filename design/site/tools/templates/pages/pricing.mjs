import { inline, esc } from '../../lib/html.mjs';
import { icon } from '../../lib/kit.mjs';
import { btn, checkList, linkArrow } from '../components.mjs';

export default function pricing(c, { lang }) {
  const hero = `<section class="page-hero center"><div class="container">
    <p class="eyebrow">${inline(c.hero.eyebrow, lang)}</p>
    <h1 class="h1">${inline(c.hero.title, lang)}</h1>
    <p class="lead">${inline(c.hero.lead, lang)}</p>
  </div></section>`;

  // The billing switch is two radios and CSS: it works without JavaScript.
  const plans = `<section style="padding-bottom:var(--section-pad)"><div class="container">
    <input type="radio" name="billing" id="bill-month" class="visually-hidden" checked>
    <input type="radio" name="billing" id="bill-year" class="visually-hidden">
    <div class="billing"><div class="seg" role="group" aria-label="${lang === 'ru' ? 'Период оплаты' : 'Billing period'}">
      <label for="bill-month" data-bill="month">${inline(c.billing.monthly, lang)}</label>
      <label for="bill-year" data-bill="year">${inline(c.billing.yearly, lang)} <span class="tag accent" style="height:20px;font-size:11px">${inline(c.billing.yearlyNote, lang)}</span></label>
    </div></div>
    <div class="plans">${c.plans.map((p) => `<div class="plan${p.featured ? ' featured' : ''} reveal">
      <div class="pname"><span>${inline(p.name, lang)}</span>${p.featured ? `<span class="tag accent">${inline(p.featured, lang)}</span>` : ''}</div>
      <p class="pfor">${inline(p.for, lang)}</p>
      <div class="price"><span class="amount"><span class="billing-monthly">${inline(p.month, lang)}</span><span class="billing-yearly">${inline(p.year, lang)}</span></span><span class="per"><span class="billing-monthly">${inline(c.per.month, lang)}</span><span class="billing-yearly">${inline(c.per.year, lang)}</span></span></div>
      <a class="btn ${p.featured ? 'primary' : 'secondary'} block" href="download.html">${inline(p.cta, lang)}</a>
      <div class="limits">${p.limits.map(([k, v]) => `<div><span>${inline(k, lang)}</span><strong>${inline(v, lang)}</strong></div>`).join('')}</div>
    </div>`).join('')}</div>
    <ul class="assure">${c.assurances.map((a) => `<li>${icon('check', 15)}<span>${inline(a, lang)}</span></li>`).join('')}</ul>
  </div></section>`;

  const inc = `<section class="section"><div class="container"><div class="split even">
    <div><h2 class="h2">${inline(c.included.title, lang)}</h2></div>
    <div>${checkList(c.included.items, lang, { accent: true })}</div>
  </div></div></section>`;

  const terms = `<section class="section"><div class="container">
    <div class="grid c3">
      <div class="card pad-lg reveal"><span class="tile-icon">${icon('clock', 18)}</span><h3 class="h3">${inline(c.trial.title, lang)}</h3><p style="margin-top:10px">${inline(c.trial.text, lang)}</p></div>
      <div class="card pad-lg reveal"><span class="tile-icon">${icon('creditcard', 18)}</span><h3 class="h3">${inline(c.payment.title, lang)}</h3>
        <ul class="list-check" style="margin-top:14px">${c.payment.items.map((i) => `<li>${icon(i.icon, 16)}<span><strong>${inline(i.t, lang)}.</strong> ${inline(i.d, lang)}</span></li>`).join('')}</ul></div>
      <div class="card pad-lg reveal"><span class="tile-icon">${icon('refresh', 18)}</span><h3 class="h3">${inline(c.refunds.title, lang)}</h3><p style="margin-top:10px">${inline(c.refunds.text, lang)}</p><p style="margin-top:16px">${linkArrow('refunds.html', c.refunds.link, lang)}</p></div>
    </div>
  </div></section>`;

  const faq = `<section class="section"><div class="container medium">
    <h2 class="h2" style="margin-bottom:32px">${inline(c.faqTitle, lang)}</h2>
    <div class="faq">${c.faq.map((f, i) => `<details${i === 0 ? ' open' : ''}><summary>${inline(f.q, lang)}${icon('chevronDown', 16)}</summary><div class="answer"><p>${inline(f.a, lang)}</p></div></details>`).join('')}</div>
  </div></section>`;

  const ct = c.cta;
  const cta = `<section class="cta-band"><div class="container"><div class="inner">
    <div><h2 class="h2">${inline(ct.title, lang)}</h2><p class="lead" style="margin-top:12px">${inline(ct.lead, lang)}</p></div>
    <div class="btn-row stretch">${btn('download.html', ct.primary, 'primary', { size: 'lg', iconName: 'download', lang })}${btn('verification.html', ct.secondary, 'secondary', { size: 'lg', lang })}</div>
  </div></div></section>`;

  return { body: [hero, plans, inc, terms, faq, cta].join('\n'), bodyClass: 'page-pricing' };
}
