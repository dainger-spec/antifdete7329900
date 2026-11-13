#!/usr/bin/env node
// The App Store's pictures: each screenshot CI took (ScreenshotTests: appstore/<language>/NN-name.png)
// under its caption (ios/AppStore/cards/captions.json), on the app's own Eclipse ground, at the size
// App Store Connect takes for the 6.9-inch iPhone (1320 x 2868).
//
//   node ios/scripts/make_store_cards.mjs <screenshots dir: appstore/> <out dir>
//
// The words of the captions are held to the owner's rules like the card's (release_rules.py reads
// captions.json). The screenshot itself is not touched: scaled and framed only.
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const { chromium } = createRequire(import.meta.url)("playwright");   // CommonJS, wherever it is installed
const [src, out] = process.argv.slice(2);
if (!src || !out) { console.error("usage: make_store_cards.mjs <appstore dir> <out dir>"); process.exit(2); }
const here = path.dirname(fileURLToPath(import.meta.url));
const captions = JSON.parse(fs.readFileSync(path.join(here, "..", "AppStore", "cards", "captions.json"), "utf8"));
const W = 1320, H = 2868;

const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/\n/g, "<br>");
const html = (shot, title, sub) => `<!doctype html><html><head><meta charset=utf-8><style>
  html,body{margin:0;width:${W}px;height:${H}px;overflow:hidden;background:#08090b}
  body{position:relative;font-family:"Inter Display","Inter",system-ui,sans-serif;color:#f4f4f5}
  .disc{position:absolute;border-radius:50%;background:#08090b}
  .disc.a{width:1400px;height:1400px;right:-1000px;top:560px;
    box-shadow:-14px 10px 0 -2px rgba(236,240,248,.55),-30px 22px 40px rgba(236,240,248,.28),-60px 44px 160px rgba(236,240,248,.14)}
  .disc.b{width:1300px;height:1300px;left:-1000px;bottom:-420px;
    box-shadow:14px -10px 0 -2px rgba(236,240,248,.5),30px -22px 40px rgba(236,240,248,.25),60px -44px 160px rgba(236,240,248,.12)}
  header{position:absolute;left:96px;right:96px;top:150px}
  h1{margin:0;font-size:104px;line-height:1.04;font-weight:800;letter-spacing:-2.5px}
  p{margin:34px 0 0;font-size:46px;line-height:1.3;font-weight:500;color:#a1a1aa}
  .phone{position:absolute;left:50%;transform:translateX(-50%);bottom:90px;width:960px;height:2087px;
    border-radius:142px;padding:20px;background:#17191e;
    box-shadow:0 0 0 2px rgba(236,240,248,.22),0 60px 140px rgba(0,0,0,.6)}
  .phone img{display:block;width:100%;height:100%;border-radius:122px;object-fit:cover}
</style></head><body>
  <div class="disc a"></div><div class="disc b"></div>
  <header><h1>${esc(title)}</h1><p>${esc(sub)}</p></header>
  <div class="phone"><img src="data:image/png;base64,${shot.toString("base64")}"></div>
</body></html>`;

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
let made = 0;
for (const [language, items] of Object.entries(captions)) {
  for (const [name, [title, sub]] of Object.entries(items)) {
    const file = path.join(src, language, `${name}.png`);
    if (!fs.existsSync(file)) { console.log(`missing: ${language}/${name}.png`); continue; }
    await page.setContent(html(fs.readFileSync(file), title, sub), { waitUntil: "load" });
    await page.evaluate(() => document.fonts.ready);
    fs.mkdirSync(path.join(out, language), { recursive: true });
    await page.screenshot({ path: path.join(out, language, `${name}.png`) });
    made++;
  }
}
await browser.close();
console.log(`store cards: ${made} made in ${out}`);
