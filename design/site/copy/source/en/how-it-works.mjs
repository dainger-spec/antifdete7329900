// How it works — for technical readers. Sources: docs/ARCHITECTURE.md, docs/ISOLATION_AND_LIMITATIONS.md
// (§3, §4, §4a), docs/SYNC_FORMAT.md, docs/LEAK_AUDIT.md.
export default {
  title: 'How it works',
  description: 'For technical readers: a process per profile, the key hierarchy, the network and the proxy, sync — how {{name}} is built and where it stops.',
  hero: {
    eyebrow: 'How it works',
    title: 'How {{name}} keeps profiles apart',
    lead: 'For technical readers: which processes start, where the keys are, how a profile’s traffic reaches its proxy, and what the sync server sees. And where all of it stops.',
  },
  navTitle: 'Sections',
  nav: [
    ['overview', 'Overview'],
    ['process', 'The profile’s process'],
    ['keys', 'Keys and encryption'],
    ['network', 'Network and proxy'],
    ['sync', 'Sync'],
    ['limits', 'Limits'],
  ],
  overview: {
    title: 'Overview',
    paras: [
      '{{name}} runs two kinds of process. The **manager** opens the vault with your master password and holds the profile list, the profiles’ keys, the proxy list and this Mac’s settings. **Every running profile** is a macOS process of its own: Safari’s interface and the system WebKit run in it, and it knows only its own profile.',
      'Between the profile’s process and the network sits its proxy; around the process, a kernel sandbox profile: no UDP, and no access to the real Safari’s folders.',
    ],
    diagram: {
      manager: 'Manager',
      managerItems: ['Vault', 'Profile list', 'Profile keys', 'Proxy list'],
      grant: 'one profile’s key — on standard input',
      process: 'Profile process',
      processItems: ['Safari’s interface', 'System WebKit', 'Its own home', 'Language, region, time zone'],
      kernel: 'Kernel sandbox: no UDP, no Safari folders',
      proxy: 'The profile’s proxy',
      proxySub: 'SOCKS5 · HTTP · HTTPS',
      net: 'The internet',
      netSub: 'sees the proxy’s address',
      only: 'only through the proxy',
    },
  },
  process: {
    title: 'The profile’s process',
    paras: [
      'The manager starts the profile’s process and hands it that profile’s key and its entry in the list — on standard input. Not in command-line arguments, which any process of the user can read, not in the environment, and not in a file. A vault opened with that key reads and writes one profile’s files and refuses the rest: other profiles’ keys and names, the proxy list and the sync settings stay with the manager.',
      'The process’s environment is built from a list, not inherited: the user’s name and shell, the text encoding, the app’s language, a fixed `PATH`, and the profile’s own home, temporary folder and time zone. Nothing else of the manager’s reaches it.',
      'Language, region and time zone are given to the process when it starts — so WebKit, the page and its workers all get them. No script over the page is needed.',
      'If its channel to the manager closes — the manager quit or crashed — the profile’s process seals its data and exits. While it runs it holds a lock on its home, so a manager started after a crash seals that home only once the process is gone.',
    ],
    table: {
      head: ['Given to the process', 'Value'],
      rows: [
        ['`HOME`, `CFFIXED_USER_HOME`, `TMPDIR`', 'folders inside the profile’s home'],
        ['`AppleLanguages`, `AppleLocale`', 'the language and region of the proxy’s country, or yours'],
        ['`TZ`', 'the time zone where the proxy exits'],
        ['Key', 'one profile’s key; not the vault key'],
      ],
    },
  },
  keys: {
    title: 'Keys and encryption',
    paras: [
      '**Argon2id** (RFC 9106, 64 MiB, 3 passes, 4 lanes) turns the master password into a key-encryption key. That opens the **vault key** — 256 random bits. HKDF derives a key per purpose from it: the profile list, sync, this device’s settings, the proxy list. Every profile has a random key of its own, and from it the keys for passwords, history, bookmarks, cookies, warm-up and the website-data archive.',
      'Every **AES-256-GCM** ciphertext is bound to its purpose and owner by its associated data — for example `history:v1:<profile id>`. Moving a file into another profile, or swapping one file for another, fails to decrypt.',
      'Changing the master password re-encrypts only the vault key. A new device opens the vault with the same password: the header with the salt, the Argon2id parameters and the encrypted vault key syncs in the clear — it holds no secret.',
      'WebKit keeps a profile’s website data in folders of its own and has no API to encrypt it on the fly. So when a profile stops, its data is archived, the archive encrypted with a key of its own, and the folders deleted; on launch, it is restored. While the profile runs, the data is on disk in the clear, protected by macOS permissions and FileVault.',
      'Deleted files on an APFS SSD cannot be reliably overwritten, and we do not pretend they can. For deleted blocks, FileVault is the real protection.',
    ],
    diagram: {
      title: 'The key hierarchy',
      rows: [
        { icon: 'key', t: 'Master password', d: 'only you know it' },
        { icon: 'cpu', t: 'Argon2id → key-encryption key', d: '64 MiB, 3 passes, 4 lanes, 16-byte salt; never stored' },
        { icon: 'lockFill', t: 'Vault key', d: '256 random bits; stored only encrypted' },
      ],
      vault: ['Profile list', 'Profile keys', 'Sync', 'This Mac’s settings', 'Proxy list'],
      profile: { t: 'Profile key', d: '256 bits, one per profile' },
      files: ['Settings', 'Passwords', 'History', 'Bookmarks', 'Cookies', 'Warm-up', 'Website-data archive'],
      hkdf: 'HKDF per purpose',
    },
  },
  network: {
    title: 'Network and proxy',
    paras: [
      'A profile’s proxy is set on its WebKit data store with no failover: if the proxy is down, a load fails instead of going direct. But Safari’s frameworks run in the profile’s process too, so the proxy is held for the whole process, not only for the web views we know about.',
    ],
    head: ['Channel', 'How it is closed', 'How it is checked'],
    rows: [
      ['The process’s web views', 'Each gets the profile’s data store and proxy when it is made; any other store points at a proxy that does not exist', 'The process’s report: every web view has the proxy'],
      ['The process’s own requests', 'The network context and every URLSession carry the profile’s proxy', 'Three probe requests arrive at the proxy'],
      ['UDP and QUIC', 'The kernel sandbox denies the process UDP; without it the process does not start', 'A datagram and a QUIC connection are never sent'],
      ['Requests to the Mac itself', '`127.0.0.0/8`, `localhost`, `::1` and `0.0.0.0` blocked for pages not on this Mac', 'A loopback listener takes no connection'],
      ['dns-prefetch', 'Ping-type loads blocked; the setting pinned', 'No DNS question for the test page’s names in the capture'],
      ['Certificates', 'Checked without fetching intermediates or OCSP', 'A decoy certificate is refused, and never fetched for'],
      ['WebRTC and WebTransport', 'Off in every web view and worker of a proxied profile', 'Absent in the page, its frames and its workers'],
      ['Safari’s services in other processes', 'No connection is made to them', 'No packet of theirs in the capture'],
    ],
    note: 'All of it is checked on every build, together with a capture of every packet and every file written.',
    link: 'How we verify',
  },
  sync: {
    title: 'Sync',
    paras: [
      'Sync carries a profile’s settings, passwords, bookmarks, history and persistent cookies between your Macs. Every object is encrypted on the Mac before it leaves (AES-256-GCM), with the vault, the object and its revision in the associated data: the server cannot move an object under another name or pass an old revision off as new.',
      'Objects are named on the server by an HMAC of their real names: the server cannot even tell that an object is “a profile’s history”.',
      'Conflicts are resolved on the device: history and bookmarks merge record by record, cookies one by one (the newer change wins), and for settings the later edit wins while the other is kept as a copy.',
    ],
    knowsTitle: 'The server knows',
    knows: ['The vault’s identifier', 'How many objects there are, and their sizes', 'Revision counters and when objects change'],
    notTitle: 'The server does not know',
    not: ['Profile names, or exactly how many — the object count is only a rough upper bound', 'Settings and proxy details', 'Passwords, cookies, history, bookmarks, the sites you visit'],
  },
  limits: {
    title: 'Limits',
    lead: 'What {{name}} does not do or promise matters as much as what it does.',
    items: [
      { t: 'Hardware signals are shared', d: 'The graphics chip, the screen, the system fonts and audio are the same for every profile on one Mac, as for the tabs of one Safari. Profiles differ by storage, network, language and time zone.' },
      { t: 'Apple Pay and Web Push are Safari’s alone', d: 'WebKit enables them only for an app with Safari’s own entitlements. A page can tell a profile from Safari by their absence — the way it tells Safari from a preview in Mail.' },
      { t: 'WebRTC is off in a proxied profile', d: 'WebKit does not send WebRTC through a proxy. So in a proxied profile it is switched off rather than going direct: in-browser video calls do not work there.' },
      { t: 'A running profile is open on disk', d: 'While a profile runs, its website data sits in WebKit’s folders in the clear, protected by macOS permissions and FileVault.' },
      { t: 'A master password cannot be recovered', d: 'We keep neither the password nor the keys. A forgotten password is lost data — the price of only you being able to read it.' },
    ],
  },
  cta: {
    title: 'Check our claims',
    lead: 'What exactly is compared with Safari, and how leaks are caught — with the numbers of the latest runs.',
    primary: 'How we verify',
    secondary: 'Docs',
  },
};
