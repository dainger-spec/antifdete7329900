// A stand-in for the iOS driver, on Chromium (Playwright), to test harness.py itself on Linux before
// spending a macOS runner: same control protocol, same commands. It proves nothing about iOS.
// Chromium has no SOCKS5 authentication: run the harness with --socks-no-auth.
//
//   node ios-measure/host/fake_driver_chromium.mjs http://127.0.0.1:28310
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const control = process.argv[2] || 'http://127.0.0.1:28310';
const browser = await chromium.launch();
const sessions = new Map();

const post = async (path, body) => {
  const r = await fetch(control + path, { method: 'POST', body: JSON.stringify(body) });
  return r.status === 200 ? r.json() : null;
};

function proxyOf(specs) {
  if (!specs || !specs.length) return undefined;
  const p = specs[0];
  const proxy = { server: `${p.type === 'socks5' ? 'socks5' : 'http'}://${p.host}:${p.port}` };
  if (p.user && p.type !== 'socks5') { proxy.username = p.user; proxy.password = p.pass; }
  return proxy;
}

async function makeSession(c) {
  const old = sessions.get(c.session);
  if (old) await old.context.close();
  const context = await browser.newContext({ proxy: proxyOf(c.proxies), ignoreHTTPSErrors: true });
  for (const s of c.userScripts || []) await context.addInitScript(s.source);
  const page = await context.newPage();
  sessions.set(c.session, { context, page, spec: c });
  return { session: c.session, store: 'context' };
}

async function run(c) {
  const s = sessions.get(c.session);
  switch (c.op) {
    case 'session': return makeSession(c);
    case 'load': try { await s.page.goto(c.url, { timeout: (c.timeout || 20) * 1000 }); return { ok: true, url: s.page.url() }; }
                 catch (e) { return { ok: false, error: String(e).slice(0, 200) }; }
    case 'eval': try {
        const text = await s.page.evaluate(`(async () => JSON.stringify(await (async () => {\n${c.js}\n})()))()`);
        return { ok: true, value: JSON.parse(text) };
      } catch (e) { return { ok: false, error: String(e).slice(0, 300) }; }
    case 'setProxy': {  // Chromium cannot change a context's proxy: a new context on the same "store" is the nearest
      return makeSession({ ...s.spec, proxies: c.proxies }).then(async (r) => { await sessions.get(c.session).page.goto(s.page.url()).catch(() => {}); return r; });
    }
    case 'close': if (s) await s.context.close(); sessions.delete(c.session); return { closed: true };
    case 'exit': return { bye: true };
    default: return { error: 'unknown op ' + c.op };
  }
}

let command = await post('/hello', { os: 'Chromium (fake driver)', osBuild: browser.version(), storeRespondsToSetProxyConfigurations: true,
                                      storeRespondsToDataStoreForIdentifier: true, proxyConfigurationDefaultAllowFailover: 'n/a' });
for (;;) {
  if (command) {
    const c = command;
    run(c).then(async (result) => {
      await post('/result', { ...result, id: c.id });
      if (c.op === 'exit') { await browser.close(); process.exit(0); }
    });
  }
  command = await post('/next', {}).catch(() => null);
}
