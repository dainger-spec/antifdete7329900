// Home scene "encryption": a profile's data turns into ciphertext under a line of light, and the ciphertext
// gathers into a lock drawn in code. The window is sample data of the profile "Store" (Germany), the same one
// the other scenes show: the password anna@shop.example was saved in the "Features" scene, and "Orders" and
// "Shipping" come from there too. The sites are the same in both languages; labels and page titles are translated.
export default {
  title: 'Encryption',
  head: ['Not even we', 'can read it.'],
  lead: 'Passwords, cookies, history, bookmarks and site data of every profile are encrypted on disk.',
  picture: 'In the picture a line of light passes over the data of the profile “Store” — a saved password, cookies, history, a bookmark and site data — and turns it into ciphertext, which then gathers into a lock.',
  profile: { name: 'Store', lang: 'de-DE', zone: 'Europe/Berlin' },
  rows: [
    { kind: 'Password', tile: 'S', t: 'shop.example', s: 'anna@shop.example', secret: true },
    { kind: 'Cookies', tile: 'M', t: 'market.example', s: 'session_id, cart, lang' },
    { kind: 'History', tile: 'O', t: 'Orders', s: 'shop.example/orders' },
    { kind: 'Bookmark', tile: 'S', t: 'Shipping', s: 'ship.example' },
    { kind: 'Site data', tile: 'H', t: 'help.shop.example', s: 'Local Storage' },
  ],
  specs: [
    { t: 'AES-256-GCM', d: 'Encrypts each profile’s data with a key of its own.' },
    { t: 'Argon2id', d: 'Derives the key from your master password: {{nb:64 MiB of memory,}} 3 passes, 4 lanes.' },
  ],
  key: 'The key comes from your master password, and only you {{nb:know it.}} {{nb:Without it,}} a stopped profile can’t be opened.',
};
