// local: the window and screen geometry a page measures (scripts/live_compare.py)
const mq = (q) => matchMedia(q).matches;
return {
  screen: [screen.width, screen.height, screen.availWidth, screen.availHeight, screen.availLeft, screen.availTop].join('x'),
  devicePixelRatio: devicePixelRatio,
  outer: outerWidth + 'x' + outerHeight,
  inner: innerWidth + 'x' + innerHeight,
  // The browser's own chrome around the page: what a user's window adds to the viewport.
  chrome: (outerWidth - innerWidth) + 'x' + (outerHeight - innerHeight),
  client: document.documentElement.clientWidth + 'x' + document.documentElement.clientHeight,
  visualViewport: window.visualViewport ? [visualViewport.width, visualViewport.height, visualViewport.scale, visualViewport.offsetTop].join('x') : 'none',
  screenPosition: [screenX, screenY, screenLeft, screenTop].join(','),
  media: [mq('(device-width: ' + screen.width + 'px)'), mq('(width: ' + innerWidth + 'px)'), mq('(display-mode: browser)'),
          mq('(display-mode: standalone)'), mq('(prefers-color-scheme: dark)'), mq('(dynamic-range: high)'), mq('(color-gamut: p3)')].join(','),
  historyLength: history.length,
};
