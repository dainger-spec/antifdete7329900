const { chromium } = require('playwright');
const fs = require('fs');
const S = process.argv[2];
const png = f => 'data:image/png;base64,' + fs.readFileSync(f).toString('base64');
const icon = png(`${S}/AppIcon-dark.png`);
const W = 1206, H = 2622;
const copy = {
  en: [
    ['01-sessions', 'Every session apart', 'Its own cookies, storage, tabs and history'],
    ['02-browser', 'Sites see the proxy’s country', 'Time zone and language follow it'],
    ['03-settings', 'A proxy for every session', 'Changed without a relaunch'],
    ['04-proxies', 'Proxies checked for you', 'Working or not, which country, UDP'],
  ],
  ru: [
    ['01-sessions', 'Каждая сессия\u00a0— отдельно', 'Свои куки, хранилище, вкладки и история'],
    ['02-browser', 'Сайт видит страну прокси', 'Часовой пояс и язык\u00a0— как у\u00a0неё'],
    ['03-settings', 'Свой прокси у\u00a0каждой сессии', 'Меняется без перезапуска'],
    ['04-proxies', 'Прокси под проверкой', 'Работает ли, из какой страны, есть ли UDP'],
  ],
};
const page = (shot, title, sub) => `<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;width:${W}px;height:${H}px;overflow:hidden;background:#0a0b0d;font-family:"Inter Display",Inter,sans-serif;-webkit-font-smoothing:antialiased}
.bg{position:absolute;inset:0;background:linear-gradient(180deg,#14161a 0%,#0a0b0d 55%)}
.top{position:absolute;left:0;right:0;top:150px;text-align:center;padding:0 90px}
.icon{width:112px;height:112px;border-radius:26px;display:block;margin:0 auto 54px;box-shadow:0 0 0 2px rgba(255,255,255,.08)}
h1{margin:0;color:#f4f5f7;font-weight:700;font-size:92px;line-height:1.06;letter-spacing:-2.2px;text-wrap:balance}
p{margin:30px 0 0;color:#8f96a3;font-weight:500;font-size:44px;line-height:1.3;text-wrap:balance}
.phone{position:absolute;left:50%;top:760px;transform:translateX(-50%);width:940px;padding:26px;border-radius:150px;
  background:#000;box-shadow:0 0 0 5px #2b2e34, 0 0 0 7px #121316, 0 50px 120px rgba(0,0,0,.65)}
.phone img{display:block;width:100%;border-radius:124px}
</style></head><body><div class="bg"></div>
<div class="top"><img class="icon" src="${icon}"><h1>${title}</h1><p>${sub}</p></div>
<div class="phone"><img src="${png(shot)}"></div></body></html>`;
(async () => {
  const b = await chromium.launch();
  const p = await b.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
  for (const lang of ['en', 'ru']) {
    fs.mkdirSync(`${S}/shots2/${lang}`, { recursive: true });
    for (const [name, title, sub] of copy[lang]) {
      await p.setContent(page(`${S}/r126/x/appstore/${lang}/${name}.png`, title, sub), { waitUntil: 'load' });
      await p.screenshot({ path: `${S}/shots2/${lang}/${name}.png` });
    }
  }
  await b.close();
})();
