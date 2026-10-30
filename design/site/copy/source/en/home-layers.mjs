// Home scene "layers".
export default {
  title: 'Isolation',
  k: 'Isolation',
  head: ['A profile is apart', 'at every level.'],
  lead: 'Window, process, data, network and key — every profile has its own.',
  items: [
    { icon: 'compass', t: 'A Safari window', d: 'Its own tabs, history and bookmarks' },
    { icon: 'cpu', t: 'A process of its own', d: 'Its own WebKit, folder and temporary files' },
    { icon: 'cookie', t: 'Its own data', d: 'Cookies and passwords other profiles cannot see' },
    { icon: 'network', t: 'Its own network', d: 'Only through its proxy; direct is closed' },
    { icon: 'key', t: 'Its own key', d: 'Everything on disk under AES-256-GCM' },
  ],
};
