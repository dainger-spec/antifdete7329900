// Download. As the owner decided (question 11): Apple Silicon only, macOS 26 or later; the version, size and
// SHA-256 come from each release's build ({{rel:…}}, sample values in the mock-up); the Team ID is not published —
// the page says in words how to check the signature. The master password rule: Localizable.strings (setup.rule.length).
export default {
  title: 'Download',
  description: 'Download {{name}} for Mac: system requirements, installation, checking the signature, and the first launch.',
  hero: {
    eyebrow: 'Download',
    title: '{{name}} for Mac',
    lead: 'One .dmg file. The app is signed with a Developer ID and notarized by Apple: macOS checks both itself on the first launch.',
    button: 'Download .dmg',
    meta: ['Version {{rel:1.0}}', '{{rel:68 MB}}', 'Apple Silicon, macOS 26 or later'],
    other: 'Every release, and what is new',
  },
  req: {
    title: 'System requirements',
    rows: [
      ['macOS', '26 or later'],
      ['Processor', 'Apple Silicon. Intel Macs are not supported'],
      ['Internet', 'to load pages and sync; a proxy if you like, one per profile'],
      ['Access', 'the app asks for the camera and microphone only when a site asks for them; the Mac’s real location is never given to sites'],
    ],
  },
  install: {
    title: 'Installing',
    steps: [
      { t: 'Drag it to Applications', d: 'Open the downloaded `{{name}}.dmg` and drag {{name}} into Applications.' },
      { t: 'Open it', d: 'On the first launch macOS checks the signature and Apple’s notarization and asks whether to open an app downloaded from the internet. Click Open.' },
      { t: 'Create a master password', d: 'It encrypts everything {{name}} keeps: the profile list, settings, passwords, history, bookmarks and website data. At least 10 characters. It cannot be recovered — write it down somewhere safe.' },
      { t: 'Create a profile', d: 'A name, a proxy and, if you like, a country for warm-up. Click Launch — that profile’s Safari window opens.' },
    ],
  },
  sign: {
    title: 'Signature and checksum',
    lead: 'The signature proves we built the app and nobody changed it since. Check it with one command, and the image by its checksum.',
    rows: [
      ['Signed with', 'A Developer ID certificate issued by Apple'],
      ['Notarized by', 'Apple Notary Service'],
      ['Image SHA-256', '{{rel:9c1e4b7a…f03d2a68}} — published with every release'],
    ],
    code: '# Signature and Apple notarization\n$ codesign --verify --deep --strict --verbose=2 /Applications/{{name}}.app\n$ spctl --assess --type execute --verbose /Applications/{{name}}.app\n# Checksum of the downloaded image\n$ shasum -a 256 ~/Downloads/{{name}}.dmg',
    codeLabel: 'Terminal',
    expect: 'If the signature is intact, `codesign` answers `valid on disk` and `satisfies its Designated Requirement`, and `spctl` answers `accepted` and `source=Notarized Developer ID`: the app is signed with a developer certificate issued by Apple and notarized by Apple. If anyone changed the file, the check fails — don’t open it. The checksum of the downloaded image must match the one published here for this release.',
  },
  first: {
    title: 'The first launch',
    lead: 'This is the first screen: the vault is created once, on this Mac.',
    screen: {
      title: 'Create a master password',
      subtitle: 'The master password encrypts the profile list, every profile’s settings, saved passwords, history, bookmarks and archived website data. It cannot be recovered — if you forget it, the data is lost.',
      field: 'Master password',
      repeat: 'Repeat master password',
      rule: 'Use at least 10 characters.',
      action: 'Create Vault',
    },
    caption: 'The text is the app’s own.',
  },
  help: {
    title: 'Something wrong?',
    items: [
      { t: 'macOS will not open the app', d: 'Check the signature with the commands above. If it fails, do not open the file — write to us.', href: 'support.html' },
      { t: 'A profile does not start', d: 'Usually the proxy: a wrong address, or it wants a password. The profile does not open sites directly in that case.', href: 'docs-trouble.html' },
      { t: 'Forgot the master password', d: 'It cannot be recovered. The old vault can be set aside and a new one created.', href: 'docs-vault.html' },
    ],
  },
};
