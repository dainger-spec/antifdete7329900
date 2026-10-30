// Home scene "encryption": a profile's data turns into ciphertext under a line of light, and the ciphertext
// gathers into a lock drawn in code. The card's rows are sample data of the profile Northwind (a German
// profile, hence German sites); they are the same in both languages, only the labels are translated.
export default {
  title: 'Encryption',
  head: ['Not even we', 'can read it.'],
  lead: 'Passwords, cookies, history, bookmarks and site data of every profile are encrypted on disk.',
  picture: 'In the picture a line of light passes over a profile’s data — a saved password, cookies, history, a bookmark and site data — and turns it into ciphertext, which then gathers into a lock.',
  profile: { name: 'Northwind', meta: 'de-DE · Europe/Berlin' },
  rows: [
    { kind: 'Password', tile: 'K', t: 'konto.example', s: 'anna.berg', secret: true },
    { kind: 'Cookies', tile: 'M', t: 'mode.example', s: 'session_id, cart, lang' },
    { kind: 'History', tile: 'W', t: 'Wetter in Berlin', s: 'wetter.example' },
    { kind: 'Bookmark', tile: 'B', t: 'Fahrplan', s: 'bahn.example' },
    { kind: 'Site data', tile: 'K', t: 'karten.example', s: 'Local Storage, IndexedDB' },
  ],
  specs: [
    { t: 'AES-256-GCM', d: 'Encrypts each profile’s data with a key of its own.' },
    { t: 'Argon2id', d: 'Turns your master password into the key: 64 MiB, 3 passes, 4 lanes.' },
  ],
  key: 'The key comes from your master password, and only you {{nb:know it.}} {{nb:Without it,}} a stopped profile can’t be opened.',
};
