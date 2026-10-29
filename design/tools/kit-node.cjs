// Loads the prototypes' classic kit scripts into Node (they attach to globalThis.Lumen).
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const kit = path.join(__dirname, '..', 'prototypes', 'kit');
for (const file of ['wordmark.js', 'geometry.js']) {
  vm.runInThisContext(fs.readFileSync(path.join(kit, file), 'utf8'), { filename: file });
}
module.exports = globalThis.Lumen;
