// prototype/index.html — the review page of the prototype (not part of the site): every page in both
// languages with its shots, the motion recordings, and the owner's questions with a copy-answers button.
import { esc, inline } from '../lib/html.mjs';
import { mark, wordmark, icon } from '../lib/kit.mjs';
import { QUESTIONS } from '../questions.mjs';

export const MOTION = [
  { file: 'hero-1440.mp4', title: 'Главная: профиль уходит в прокси и прогревается', note: 'Один проход, затем покой. Каждое движение ≤ 280 мс; счётчик cookies доходит до образца из приложения (84) и останавливается.' },
  { file: 'hero-390.mp4', title: 'То же на телефоне', note: 'Схема сети вертикальная; линии рисуются сверху вниз.' },
  { file: 'hero-reduced-1440.mp4', title: 'С Reduce Motion', note: 'Без движения: три состояния сменяют друг друга, счётчик не бежит.' },
  { file: 'reveal-1440.mp4', title: 'Появление при прокрутке', note: 'Один раз, 240 мс, сдвиг 10 px; соседние блоки — с шагом 40 мс.' },
  { file: 'sections-1440.mp4', title: 'Переходы между разделами страницы', note: 'Боковая навигация «Возможностей»: плавная прокрутка, индикатор раздела едет 200 мс.' },
  { file: 'pages-1440.mp4', title: 'Переходы между страницами', note: 'View Transitions: шапка стоит, содержимое меняется затуханием 200 мс.' },
  { file: 'pricing-1440.mp4', title: 'Помесячно / за год', note: 'Без JavaScript: два radio и CSS.' },
  { file: 'menu-390.mp4', title: 'Меню на телефоне', note: 'Без JavaScript: <details>; панель появляется за 200 мс.' },
];

export function hub({ pages, tbdIndex }) {
  const groups = [...new Set(pages.map((p) => p.group))];
  const names = {
    index: 'Главная', features: 'Возможности', 'how-it-works': 'Как устроено', verification: 'Как мы проверяем', pricing: 'Цены', download: 'Скачать',
    docs: 'Документация — структура', 'docs-import-cookies': 'Документация — шаблон статьи', blog: 'Обновления — список', 'blog-no-noise': 'Обновления — запись',
    login: 'Вход по email', 'login-code': 'Вход: код из письма', 'login-key': 'Вход по ключу', signup: 'Регистрация',
    account: 'Кабинет: подписка и оплата', 'account-devices': 'Кабинет: устройства', 'account-sync': 'Кабинет: синхронизация', 'account-invoices': 'Кабинет: счета', 'account-settings': 'Кабинет: настройки',
    privacy: 'Политика конфиденциальности', terms: 'Условия использования', refunds: 'Правила возврата', support: 'Поддержка и контакты', 404: 'Страница 404',
  };
  const rows = groups.map((g) => `<tr><th colspan="4" style="padding-top:24px;color:var(--text-secondary)">${esc(g)}</th></tr>` +
    pages.filter((p) => p.group === g).map((p) => `<tr>
      <td class="strong">${esc(names[p.slug] || p.slug)}</td>
      <td><a href="ru/${p.slug}.html">RU</a> · <a href="en/${p.slug}.html">EN</a></td>
      <td><a href="../shots/ru/${p.slug}-1440.png">1440</a> · <a href="../shots/ru/${p.slug}-390.png">390</a> <span class="caption">ru</span></td>
      <td><a href="../shots/en/${p.slug}-1440.png">1440</a> · <a href="../shots/en/${p.slug}-390.png">390</a> <span class="caption">en</span></td></tr>`).join('')).join('');

  const motion = MOTION.map((m) => `<figure class="card" style="padding:16px"><video src="../shots/motion/${m.file}" controls muted playsinline preload="metadata" style="width:100%;border-radius:8px;background:var(--backdrop);display:block" aria-label="${esc(m.title)}"></video>
    <figcaption style="margin-top:12px"><div class="h4" style="font-size:15px">${esc(m.title)}</div><p class="caption" style="margin-top:4px">${esc(m.note)}</p><p class="caption" style="margin-top:4px"><a href="../shots/motion/${m.file}">${esc(m.file)}</a></p></figcaption></figure>`).join('');

  const q = QUESTIONS.map((x, i) => {
    const where = tbdIndex[x.id] ? Object.entries(tbdIndex[x.id]).map(([slug, n]) => `<a href="ru/${slug}.html">${esc(names[slug] || slug)}</a>${n > 1 ? ` <span class="caption">×${n}</span>` : ''}`).join(', ') : '';
    const opts = x.options ? `<div class="qopts">${x.options.map((o, k) => `<label class="qopt"><input type="radio" name="${x.id}" value="${o.id}"${k === 0 ? ' checked' : ''}><span><strong>${o.id}. ${esc(o.label)}</strong>${k === 0 && x.recommend ? ' <span class="tag accent" style="height:20px;font-size:11px">рекомендую</span>' : ''}<br><span class="caption" style="font-size:13px;color:var(--text-secondary)">${esc(o.note)}</span></span></label>`).join('')}</div>` : '';
    const facts = x.facts ? `<ul class="bullets" style="margin-top:12px">${x.facts.map((f) => `<li>${esc(f)}</li>`).join('')}</ul>` : '';
    const extra = x.extra ? `<ul class="bullets" style="margin-top:12px">${x.extra.map((f) => `<li>${esc(f)}</li>`).join('')}</ul>` : '';
    return `<section class="card pad-lg qcard" id="${x.id}" data-q="${x.id}">
      <div class="row" style="justify-content:space-between;align-items:flex-start"><h3 class="h3">${i + 1}. ${esc(x.title)}</h3>${where ? '' : ''}</div>
      <p class="small muted" style="margin-top:8px">${esc(x.why)}</p>
      ${opts}${extra}${facts}
      ${x.recommend ? `<p class="small" style="margin-top:12px;color:var(--text-primary)">${esc(x.recommend)}</p>` : ''}
      <textarea class="input" data-note placeholder="Комментарий или свой вариант" style="margin-top:14px;min-height:64px"></textarea>
      ${where ? `<p class="caption" style="margin-top:10px">Жёлтым на страницах: ${where}</p>` : ''}
    </section>`;
  }).join('');

  return `<!doctype html>
<html lang="ru" class="no-js">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Сайт Lumen — прототип и ревью</title>
<meta name="color-scheme" content="dark">
<link rel="stylesheet" href="assets/site.css">
<style>
  .qopts { display: grid; gap: 8px; margin-top: 16px; }
  .qopt { display: grid; grid-template-columns: 18px minmax(0, 1fr); gap: 12px; align-items: start; padding: 12px 14px; border-radius: 8px; border: 1px solid var(--hairline); background: var(--card); cursor: pointer; font: var(--t-small); }
  .qopt:hover { border-color: var(--strong-border); }
  .qopt input { margin-top: 3px; accent-color: #4469D6; }
  .qopt:has(input:checked) { border-color: rgba(111, 143, 234, 0.55); background: var(--accent-tint); }
  .hub-head { border-bottom: 1px solid var(--hairline); }
  .hub-head .container { display: flex; align-items: center; justify-content: space-between; gap: 16px; height: 64px; }
  .copied-msg { display: none; }
  .copied .copied-msg { display: inline; }
</style>
<script>document.documentElement.classList.replace('no-js','js');</script>
</head>
<body>
<header class="hub-head"><div class="container"><span style="display:inline-flex;align-items:center;gap:10px">${mark(24)}${wordmark(12.4)}<span class="caption" style="margin-left:6px">сайт · дизайн-прототип</span></span>
  <span class="row"><a class="btn ghost sm" href="../README.md">README</a><a class="btn ghost sm" href="../spec.md">Спецификация</a><a class="btn secondary sm" href="ru/index.html">Открыть сайт</a><a class="btn ghost sm" href="en/index.html">English</a></span></div></header>
<main class="container" style="padding-top:56px;padding-bottom:120px">
  <h1 class="h1">Сайт: прототип и ревью</h1>
  <p class="lead" style="margin-top:14px;max-width:820px">Все страницы сайта на русском и английском, в ширинах 1440 и 390. Это прототип: ничего не деплоится, бэкенда нет, формы никуда не отправляют. Внизу каждой страницы — панель прототипа: язык, жёлтые отметки решений и «Без движения».</p>
  <div class="note" style="margin-top:24px;max-width:820px">${icon('infoCircle', 18)}<div><p><strong>Переходы между страницами</strong> (View Transitions) браузер делает только для страниц с сервера, не для файлов с диска. Чтобы их увидеть: <code>cd design/site/prototype && python3 -m http.server 8000</code> и откройте <code>http://localhost:8000</code>. Остальное работает и с диска.</p></div></div>

  <h2 class="h2" style="margin-top:72px">Страницы</h2>
  <div class="table-wrap" style="margin-top:20px"><div class="table-scroll"><table class="table compact"><thead><tr><th>Страница</th><th>Прототип</th><th>Снимки, ru</th><th>Снимки, en</th></tr></thead><tbody>${rows}</tbody></table></div></div>

  <h2 class="h2" style="margin-top:72px">Движение</h2>
  <p class="lead" style="margin-top:10px;max-width:820px">Записи из этого же прототипа (Chromium, 25 кадров в секунду — кривые лучше смотреть вживую). Правила: обычное движение ≤ 300 мс, ничего не пульсирует в покое, всё уважает Reduce Motion, страница читается без JavaScript.</p>
  <div class="grid c2" style="margin-top:24px">${motion}</div>

  <h2 class="h2" style="margin-top:72px" id="questions">Вопросы</h2>
  <p class="lead" style="margin-top:10px;max-width:820px">Выберите варианты — рекомендуемый отмечен и выбран по умолчанию, — допишите комментарии и нажмите «Скопировать ответы»: получится текст для чата.</p>
  <div style="display:grid;gap:16px;margin-top:24px;max-width:900px">${q}</div>
  <div class="row" style="margin-top:24px"><button class="btn primary lg" type="button" id="copy-answers">${icon('copy', 16)}Скопировать ответы</button><span class="caption copied-msg">Скопировано в буфер обмена</span></div>
  <pre id="answers-out" class="code" style="margin-top:16px;padding:14px 16px;white-space:pre-wrap;display:none"></pre>
</main>
<script>
(function () {
  var btn = document.getElementById('copy-answers');
  btn.addEventListener('click', function () {
    var lines = [];
    document.querySelectorAll('.qcard').forEach(function (card, i) {
      var id = card.getAttribute('data-q');
      var picked = card.querySelector('input[type=radio]:checked');
      var note = card.querySelector('[data-note]').value.trim();
      var title = card.querySelector('h3').textContent.replace(/^\\d+\\.\\s*/, '');
      var line = (i + 1) + '. ' + title + ': ' + (picked ? picked.value + ' — ' + picked.parentElement.querySelector('strong').textContent.replace(/^\\w\\.\\s*/, '') : '—');
      if (note) line += ' (' + note + ')';
      lines.push(line);
    });
    var text = lines.join('\\n');
    var out = document.getElementById('answers-out');
    out.textContent = text; out.style.display = 'block';
    if (navigator.clipboard) navigator.clipboard.writeText(text).then(function () { btn.parentElement.classList.add('copied'); });
  });
})();
</script>
</body>
</html>
`;
}
