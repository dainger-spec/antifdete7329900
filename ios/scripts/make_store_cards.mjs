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

// A short word (у, и, в, a, of…) stays with the word after it, a dash with the word before it.
const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/\s—/g, "&nbsp;—").replace(/(^|\s)([^\s—]{1,2})\s/g, "$1$2&nbsp;").replace(/\n/g, "<br>");
// The look (STYLE): "eclipse" — black, the eclipse's corona as the light behind the phone, silver
// letters; "midnight" — a deep blue night with a cold glow. Large letters, a large phone that leaves
// by the bottom edge (ANCHOR in captions: the screen's part to keep in view).
const STYLES = {
  eclipse: {
    ground: "#040405",
    glow: `<div class="corona"></div><div class="haze"></div>`,
    title: "linear-gradient(180deg,#ffffff 0%,#d9dce3 100%)", sub: "#a3a6ae",
  },
  midnight: {
    ground: "radial-gradient(90% 55% at 50% 38%, #24345f 0%, #111a33 45%, #070a14 100%)",
    glow: `<div class="beam"></div>`,
    title: "linear-gradient(180deg,#ffffff 0%,#c9d6ff 100%)", sub: "#9fb0d9",
  },
};
const style = STYLES[process.env.STYLE || "eclipse"];
const html = (shot, title, sub) => `<!doctype html><html><head><meta charset=utf-8><style>
  html,body{margin:0;width:${W}px;height:${H}px;overflow:hidden}
  body{position:relative;background:${style.ground};font-family:"Inter Display","Inter",system-ui,sans-serif}
  header{position:absolute;left:70px;right:70px;top:150px;text-align:center;z-index:3}
  h1{margin:0;text-wrap:balance;font-size:124px;line-height:1.02;font-weight:800;letter-spacing:-3.6px;
    background:${style.title};-webkit-background-clip:text;color:transparent}
  p{margin:40px auto 0;max-width:1100px;text-wrap:balance;font-size:54px;line-height:1.22;font-weight:500;letter-spacing:-.5px;color:${style.sub}}
  .corona{position:absolute;left:50%;top:600px;width:1500px;height:1500px;margin-left:-750px;border-radius:50%;background:#040405;
    box-shadow:0 0 0 3px rgba(240,243,250,.85),0 0 24px 6px rgba(240,243,250,.55),0 0 120px 40px rgba(210,220,245,.28),
      0 0 360px 140px rgba(170,185,230,.13)}
  .haze{position:absolute;inset:0;background:radial-gradient(70% 40% at 50% 100%, rgba(0,0,0,.0), rgba(0,0,0,.65))}
  .beam{position:absolute;left:50%;top:420px;width:1600px;height:1600px;margin-left:-800px;border-radius:50%;
    background:radial-gradient(circle, rgba(140,170,255,.35) 0%, rgba(90,120,220,.12) 35%, transparent 65%)}
  .phone{position:absolute;left:50%;top:640px;width:1080px;height:2346px;margin-left:-540px;border-radius:184px;z-index:2;
    padding:8px;background:linear-gradient(150deg,#b9bcc3 0%,#f4f5f8 18%,#5c5f66 46%,#e2e4e8 72%,#8a8d94 100%);
    box-shadow:0 80px 200px rgba(0,0,0,.7),0 0 0 1px rgba(255,255,255,.08)}
  .bezel{width:100%;height:100%;border-radius:176px;background:#000;padding:25px;box-sizing:border-box;position:relative;overflow:hidden}
  .bezel img{display:block;width:100%;height:100%;border-radius:152px;object-fit:cover;object-position:top}
  .island{position:absolute;top:62px;left:50%;width:280px;height:80px;margin-left:-140px;border-radius:40px;background:#000}
</style></head><body>
  ${style.glow}
  <header><h1>${esc(title)}</h1><p>${esc(sub)}</p></header>
  <div class="phone"><div class="bezel"><img src="data:image/png;base64,${shot.toString("base64")}"><div class="island"></div></div></div>
</body></html>`;
// The phone right under the words, however many lines they take (once the font is in); the light behind its top.
const layout = () => {
  const top = document.querySelector("header").getBoundingClientRect().bottom + 90;
  document.querySelector(".phone").style.top = top + "px";
  for (const [cls, dy] of [[".corona", -170], [".beam", -380]]) {
    const el = document.querySelector(cls); if (el) el.style.top = (top + dy) + "px";
  }
};

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
let made = 0;
for (const [language, items] of Object.entries(captions)) {
  for (const [name, [title, sub]] of Object.entries(items)) {
    const file = path.join(src, language, `${name}.png`);
    if (!fs.existsSync(file)) { console.log(`missing: ${language}/${name}.png`); continue; }
    await page.setContent(html(fs.readFileSync(file), title, sub), { waitUntil: "load" });
    await page.evaluate(() => document.fonts.ready);
    await page.evaluate(layout);
    fs.mkdirSync(path.join(out, language), { recursive: true });
    await page.screenshot({ path: path.join(out, language, `${name}.png`) });
    made++;
  }
}
await browser.close();
console.log(`store cards: ${made} made in ${out}`);
