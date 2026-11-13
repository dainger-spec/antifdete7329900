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
// Two looks (STYLE=dark | light): the app's own Eclipse — the phone rises out of an eclipse whose corona
// lights its edges — or a silver ground with dark letters, where the dark app stands out the most.
const STYLES = {
  dark: {
    ground: "radial-gradient(120% 70% at 50% 8%, #1a1c22 0%, #0b0c0f 55%, #050506 100%)",
    title: "#f4f4f5", sub: "#9a9aa3",
    corona: `<div class="corona"></div>`,
  },
  light: {
    ground: "linear-gradient(180deg, #f3f4f7 0%, #e3e5ea 55%, #cfd2d9 100%)",
    title: "#0b0c0f", sub: "#5d606a",
    corona: "",
  },
};
const style = STYLES[process.env.STYLE || "dark"];
const html = (shot, title, sub) => `<!doctype html><html><head><meta charset=utf-8><style>
  html,body{margin:0;width:${W}px;height:${H}px;overflow:hidden}
  body{position:relative;background:${style.ground};font-family:"Inter Display","Inter",system-ui,sans-serif}
  header{position:absolute;left:80px;right:80px;top:170px;text-align:center}
  h1{margin:0;font-size:92px;line-height:1.06;font-weight:700;letter-spacing:-2.2px;color:${style.title}}
  p{margin:30px 0 0;font-size:42px;line-height:1.3;font-weight:500;color:${style.sub}}
  .corona{position:absolute;left:50%;top:640px;width:1180px;height:1180px;margin-left:-590px;border-radius:50%;
    background:radial-gradient(circle at 50% 50%, #08090b 62%, #101115 69%, transparent 70.5%);
    box-shadow:0 0 0 2px rgba(236,240,248,.55), 0 0 30px 6px rgba(236,240,248,.35), 0 0 140px 40px rgba(236,240,248,.16),
      0 0 380px 120px rgba(200,210,235,.08)}
  .phone{position:absolute;left:50%;top:640px;width:1000px;height:2172px;margin-left:-500px;border-radius:168px;
    padding:7px;background:linear-gradient(140deg,#9c9fa6 0%,#e9ebef 22%,#6e7178 48%,#d4d6db 74%,#7d8087 100%);
    box-shadow:0 70px 160px rgba(0,0,0,.55), 0 20px 50px rgba(0,0,0,.35)}
  .bezel{width:100%;height:100%;border-radius:161px;background:#050506;padding:24px;box-sizing:border-box;position:relative}
  .bezel img{display:block;width:100%;height:100%;border-radius:138px;object-fit:cover}
  .island{position:absolute;top:58px;left:50%;width:250px;height:72px;margin-left:-125px;border-radius:36px;background:#000}
  .btn{position:absolute;width:9px;border-radius:4px;background:linear-gradient(90deg,#6e7178,#cfd1d6)}
</style></head><body>
  ${style.corona}
  <header><h1>${esc(title)}</h1><p>${esc(sub)}</p></header>
  <div class="phone"><div class="bezel"><img src="data:image/png;base64,${shot.toString("base64")}"><div class="island"></div></div></div>
  <div class="btn" style="left:calc(50% - 507px);top:1020px;height:110px"></div>
  <div class="btn" style="left:calc(50% - 507px);top:1170px;height:200px"></div>
  <div class="btn" style="left:calc(50% + 498px);top:1120px;height:250px"></div>
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
