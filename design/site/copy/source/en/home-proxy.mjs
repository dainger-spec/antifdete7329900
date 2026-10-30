// Home scene "proxy": the Safari window of the Store profile, filmed close. A sign-in page is open through the
// proxy; Continue is pressed, the progress bar runs along the address field — and freezes: the proxy has stopped
// responding. The white page and its light go out, Safari shows its own error, the camera draws back to the
// headline; two captions under the window.
// The site's text in the window (German: a profile's language follows its proxy's country) is sample data, in the
// scene's template.
export default {
  title: 'Proxy',
  head: ['The proxy is down.', 'No connection.'],
  // The profile and the proxy are the app's samples (UISnapshots: Store, Germany; the proxy Berlin 1).
  profile: 'Store',
  proxy: 'Berlin 1',
  // The line above the window while the proxy works, and the moment it stops responding ({proxy}: its name, a sample).
  live: ['Through proxy {proxy}.', 'The Store profile goes online from Germany.'],
  drop: ['Proxy {proxy} isn’t responding.', 'Loading stopped.'],
  // The captions once the proxy is down: a bold start, then grey.
  closed: ['No way around it.', 'A profile with a proxy goes online only through it. If the proxy doesn’t respond, the page doesn’t open, and the site never learns your real IP.'],
  proof: ['0 packets past the proxy.', 'Every build checks it: the tests record all of a profile’s traffic and look for a single packet that got past it.'],
  // Safari's error ({host}: the site's address).
  errorTitle: 'Safari Can’t Connect to the Server',
  errorBody: 'Safari can’t open the page “{host}” because Safari can’t connect to the server “{host}”.',
  // What the window shows, for those who cannot see it.
  label: 'The Safari window of the Store profile. A sign-in page is open through the proxy; during the next load the proxy stops responding: loading stops, and instead of the page Safari shows its own error, “Can’t Connect to the Server”. The profile never goes online directly.',
};
