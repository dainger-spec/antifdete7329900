// Checks that every string the prototypes call existing is the app's own, word for word, in both
// languages, and that every NEW key really is new. Run: node design/tools/check-strings.cjs
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '..', '..');

function parse(file) {
  const out = {};
  const re = /^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$/;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const m = line.trim().match(re);
    if (m) out[m[1]] = m[2].replace(/\\n/g, '\n').replace(/\\"/g, '"').replace(/\\\\/g, '\\');
  }
  return out;
}
const en = parse(path.join(root, 'Resources/en.lproj/Localizable.strings'));
const ru = parse(path.join(root, 'Resources/ru.lproj/Localizable.strings'));
globalThis.location = { search: '' };
vm.runInThisContext(fs.readFileSync(path.join(root, 'design/prototypes/kit/strings.js'), 'utf8'));
const { EXISTING, NEW } = globalThis.Lumen.strings;
let problems = 0;
for (const [key, [e, r]] of Object.entries(EXISTING)) {
  if (!(key in en)) { console.log(`MISSING in app: ${key}`); problems++; continue; }
  if (en[key] !== e) { console.log(`EN differs ${key}\n  app:   ${en[key]}\n  proto: ${e}`); problems++; }
  if (ru[key] !== r) { console.log(`RU differs ${key}\n  app:   ${ru[key]}\n  proto: ${r}`); problems++; }
}
for (const key of Object.keys(NEW)) {
  if (key in en) { console.log(`NEW key already exists in the app: ${key} = ${en[key]}`); problems++; }
}
console.log(`${Object.keys(EXISTING).length} existing strings checked, ${Object.keys(NEW).length} new; ${problems} problems`);
process.exit(problems ? 1 : 0);
