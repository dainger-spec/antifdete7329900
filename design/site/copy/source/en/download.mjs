// Download. The minimum macOS is from Resources/Info.plist (LSMinimumSystemVersion 14.0); the master
// password rule from Localizable.strings (setup.rule.length). Version, size, Team ID, processors and the
// checksum are release data (question 11).
export default {
  title: 'Download',
  description: 'Download {{name}} for Mac: system requirements, installation, checking the signature, and the first launch.',
  hero: {
    eyebrow: 'Download',
    title: '{{name}} for Mac',
    lead: 'One .dmg file. The app is signed with a Developer ID and notarized by Apple: macOS checks both itself on the first launch.',
    button: 'Download .dmg',
    meta: ['Version {{tbd:q11:release number}}', '{{tbd:q11:file size}}', 'macOS 14 Sonoma or later'],
    other: 'Every release, and what is new',
  },
  req: {
    title: 'System requirements',
    rows: [
      ['macOS', '14 Sonoma or later'],
      ['Processor', '{{tbd:q11:Apple silicon or Intel}}'],
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
    lead: 'The signature proves we built the app and nobody changed it since. Check it with one command.',
    rows: [
      ['Signed by', 'Developer ID Application: {{tbd:q9:company name}} ({{tbd:q11:Team ID}})'],
      ['Notarized by', 'Apple Notary Service'],
      ['Image SHA-256', '{{tbd:q11:published with every release}}'],
    ],
    code: '# Signature and Apple notarization\n$ codesign --verify --deep --strict --verbose=2 /Applications/{{name}}.app\n$ spctl --assess --type execute --verbose /Applications/{{name}}.app\n# Checksum of the downloaded image\n$ shasum -a 256 ~/Downloads/{{name}}.dmg',
    codeLabel: 'Terminal',
    expect: 'Expected: `valid on disk`, `satisfies its Designated Requirement` and `source=Notarized Developer ID`.',
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
      { t: 'A profile does not start', d: 'Usually the proxy: a wrong address, or it wants a password. The profile does not open sites directly in that case.', href: 'docs.html' },
      { t: 'Forgot the master password', d: 'It cannot be recovered. The old vault can be set aside and a new one created.', href: 'docs.html' },
    ],
  },
};
