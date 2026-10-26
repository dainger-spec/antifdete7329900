// url: https://tls.peet.ws/api/all settle=0 timeout=60000
// TLS ClientHello (JA3, JA4), HTTP/2 SETTINGS/WINDOW_UPDATE/pseudo-header order (Akamai), the
// navigation's HTTP/2 header order, and the TCP SYN (p0f) as the server saw them.
const data = JSON.parse(document.body.innerText);
const tls = data.tls || {};
const h2 = data.http2 || {};
const frames = h2.sent_frames || [];
const headers = (frames.find((f) => f.frame_type === 'HEADERS') || {}).headers || [];
const syn = (data.tcpip || {}).tcp_syn || {};
return {
  httpVersion: data.http_version,
  tlsVersion: [tls.tls_version_record, tls.tls_version_negotiated].join('/'),
  ja3: tls.ja3,
  ja3Hash: tls.ja3_hash,
  ja4: tls.ja4,
  ja4r: tls.ja4_r,
  peetprintHash: tls.peetprint_hash,
  // GREASE values are random per connection (RFC 8701); everything else must be identical.
  ciphers: (tls.ciphers || []).filter((c) => !/GREASE/.test(c)).join(','),
  extensions: (tls.extensions || []).map((e) => e.name).filter((n) => !/GREASE/.test(n)).join(','),
  akamai: h2.akamai_fingerprint,
  akamaiHash: h2.akamai_fingerprint_hash,
  // An empty SETTINGS (the ACK of the server's) lands before or after WINDOW_UPDATE by timing.
  frames: frames.filter((f) => f.frame_type !== 'HEADERS' && !(f.frame_type === 'SETTINGS' && !(f.settings || []).length))
    .map((f) => f.frame_type + (f.settings ? '[' + f.settings.join(';') + ']' : '') + (f.increment ? '+' + f.increment : '')).join(' '),
  headerOrder: headers.map((h) => h.slice(0, h.indexOf(':', 1))).join(','),
  // Header values without the per-run ones (none of these carry a token).
  headerValues: headers.filter((h) => /^(accept|accept-encoding|accept-language|priority|sec-fetch-[a-z]+|upgrade-insecure-requests|user-agent):/i.test(h)).join(' | '),
  tcpSyn: syn.option_order ? [syn.window, syn.mss, syn.window_scale, syn.option_order, syn.ttl].join('/') : 'n/a',
};
