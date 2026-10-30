// Home scene "bento".
export default {
  title: 'Features',
  head: ['And everything you expect', 'from Safari.'],
  passwords: { t: 'Passwords', d: 'AutoFill as in Safari: save, update, fill.', site: 'shop.example', save: 'Save password' },
  history: {
    t: 'History and bookmarks',
    d: 'Every profile has its own.',
    rows: ['Orders', 'Seller dashboard', 'Support'],
  },
  cookies: {
    t: 'Cookie import',
    d: 'JSON and cookies.txt from extensions, Puppeteer, Playwright and Selenium.',
    file: 'cookies.txt',
    profile: 'Store',
  },
  sync: { t: 'Sync', d: 'Your profiles on all your Macs. Only ciphertext goes to the server.' },
  export: { t: 'Profile export', d: 'A whole profile in one file under a password.' },
  ephemeral: { t: 'Ephemeral profiles', d: 'Close it, and nothing is left.' },
  link: 'All features',
};
