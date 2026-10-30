// Home scene "layers": an exploded view of a profile — a Safari window comes apart into five layers.
// ui — the words on the drawn layers (samples: the profiles Store, Ads, Support, as in the other scenes).
export default {
  title: 'Isolation',
  head: ['A profile is apart', 'at every level.'],
  lead: 'Under every window: its own process, its own data, its own network and its own key.',
  items: [
    { t: 'A Safari window', d: 'Its own tabs, history and bookmarks.' },
    { t: 'A process of its own', d: 'Its own WebKit, folder and temporary files.' },
    { t: 'Its own data', d: 'Cookies and passwords other profiles cannot see.' },
    { t: 'Its own network', d: 'Only through its proxy. Direct is closed.' },
    { t: 'Its own key', d: 'Everything on disk under {{nb:AES-256-GCM.}}' },
  ],
  ui: {
    site: 'shop.example',
    orders: [['Desk lamp', 'Paid', '€49'], ['Ceramic mug', 'Shipped', '€18'], ['Linen tablecloth', 'New', '€64']],
    page: 'Orders',
    procHead: ['Profile', 'Process'],
    procs: [['Store', 'own WebKit'], ['Ads', 'own WebKit'], ['Support', 'own WebKit']],
    net: [['Proxy', 'SOCKS5 · Germany'], ['Direct', 'closed'], ['WebRTC', 'off']],
    key: 'profile key',
  },
};
