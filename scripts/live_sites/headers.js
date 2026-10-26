// local: request headers in the order the local server received them (navigation, fetch, XHR)
const token = new URLSearchParams(location.search).get('token');
await fetch('/fetch.txt?token=' + token).then((r) => r.text());
await new Promise((resolve) => {
  const xhr = new XMLHttpRequest();
  xhr.open('GET', '/xhr.txt?token=' + token);
  xhr.onloadend = resolve;
  xhr.send();
});
const requests = await fetch('/echo?token=' + token, { cache: 'no-store' }).then((r) => r.json());
const out = {};
for (const request of requests) {
  const kind = request.path === '/headers.html' ? 'navigation' : request.path === '/fetch.txt' ? 'fetch'
    : request.path === '/xhr.txt' ? 'xhr' : null;
  if (!kind) continue;
  out[kind + '.order'] = request.headers.map((h) => h[0]).join(',');
  // Referer carries the per-browser token; Host and Cookie are not the browser's choice.
  for (const [name, value] of request.headers) {
    if (!/^(host|cookie|referer)$/i.test(name)) out[kind + '.' + name.toLowerCase()] = value;
  }
}
return out;
