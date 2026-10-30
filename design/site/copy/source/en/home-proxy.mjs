// Home scene "proxy": the Safari window of the Store profile. A sign-in page is open through the proxy; Continue is
// pressed, Safari starts loading, and the proxy stops answering: the progress bar stops, the page's light goes out,
// Safari shows its own error. The line above the window: "Through the proxy …" → "… isn’t answering" → the headline; two captions under it.
// The site's text in the window (German: a profile's language follows its proxy's country) is sample data, in the
// scene's template.
export default {
  title: 'Proxy',
  head: ['The proxy is down.', 'No connection.'],
  // The profile and the proxy are the app's samples (UISnapshots: Store, Germany; the proxy Berlin 1).
  profile: 'Store',
  proxy: 'Berlin 1',
  // The line above the window while the proxy works, and the moment it stops answering ({proxy}: its name, a sample).
  live: ['Through the proxy {proxy}.', 'The Store profile goes online from Germany.'],
  drop: ['The proxy {proxy} isn’t answering.', 'Loading stopped.'],
  // The captions once the proxy is down: a bold start, then grey.
  closed: ['Never around it.', 'A profile with a proxy goes online only through it. If the proxy doesn’t answer, the page doesn’t open, and the site never learns your real IP.'],
  proof: ['0 packets around the proxy.', 'Every build checks it: the tests record all of a profile’s traffic and look for a single packet that went around.'],
  // Safari's error ({host}: the site's address).
  errorTitle: 'Safari Can’t Connect to the Server',
  errorBody: 'Safari can’t open the page “{host}” because Safari can’t connect to the server “{host}”.',
  // What the window shows, for those who cannot see it.
  label: 'The Safari window of the Store profile. A sign-in page is open through the proxy; during the next load the proxy stops answering, and instead of the page Safari shows its own error, “Can’t Connect to the Server”. The profile never goes online directly.',
};
