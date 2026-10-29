// The app's drawn pieces, for the site: the mark, the LUMEN wordmark, the country flags and the
// SF Symbols stand-ins come from design/prototypes/kit (ported from LumenMark.swift, CountryFlag.swift
// and Theme.swift), loaded read-only so the site and the app prototypes draw the same thing. A few
// symbols only the site needs are drawn below on the same 16-unit grid and stroke.
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
export const SITE = path.resolve(here, '..', '..');            // design/site
export const DESIGN = path.resolve(SITE, '..');                 // design
const KIT = path.join(DESIGN, 'prototypes', 'kit');

for (const file of ['wordmark.js', 'geometry.js', 'icons.js']) {
  vm.runInThisContext(fs.readFileSync(path.join(KIT, file), 'utf8'), { filename: file });
}
const L = globalThis.Lumen;

const stroke = (d, w = 1.4) => `<path d="${d}" fill="none" stroke="currentColor" stroke-width="${w}" stroke-linecap="round" stroke-linejoin="round"/>`;
const rect = (x, y, w, h, r, sw = 1.4) => `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${r}" fill="none" stroke="currentColor" stroke-width="${sw}"/>`;
const circle = (cx, cy, r, w = 1.4) => `<circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="currentColor" stroke-width="${w}"/>`;
const dot = (cx, cy, r) => `<circle cx="${cx}" cy="${cy}" r="${r}" fill="currentColor"/>`;

// Symbols the site needs and the app kit does not have (SF Symbol names in the comments).
const SITE_ICONS = {
  download: stroke('M8 2.4v8.2M4.7 7.4L8 10.6l3.3-3.2M3 13.6h10'),                    // arrow.down.to.line
  laptop: rect(3, 3.2, 10, 7.4, 1.3) + stroke('M1.4 13h13.2'),                          // laptopcomputer
  desktop: rect(2.2, 2.8, 11.6, 8, 1.3) + stroke('M6 13.6h4M8 10.8v2.8'),               // desktopcomputer
  creditcard: rect(1.6, 3.4, 12.8, 9.2, 1.7) + stroke('M1.6 6.6h12.8M4 10h2.6'),        // creditcard
  envelope: rect(1.8, 3.4, 12.4, 9.2, 1.7) + stroke('M2.4 4.4L8 8.6l5.6-4.2'),         // envelope
  menu: stroke('M2.5 4.5h11M2.5 8h11M2.5 11.5h11', 1.5),                                // line.3.horizontal
  copy: rect(5.2, 5.2, 8.6, 8.6, 1.6) + stroke('M2.8 10.6V4.1c0-.8.6-1.4 1.4-1.4h6.4'), // doc.on.doc
  arrowUpRight: stroke('M5 11L11 5M6.2 5H11v4.8'),                                      // arrow.up.right
  terminal: rect(1.6, 2.6, 12.8, 10.8, 1.8) + stroke('M4.6 6.4l2.2 1.9-2.2 1.9M8.6 10.3h3'), // apple.terminal
  cpu: rect(4.2, 4.2, 7.6, 7.6, 1.4) + stroke('M6.4 1.8v2.4M9.6 1.8v2.4M6.4 11.8v2.4M9.6 11.8v2.4M1.8 6.4h2.4M1.8 9.6h2.4M11.8 6.4h2.4M11.8 9.6h2.4', 1.3), // cpu
  house: stroke('M2.4 7.6L8 3l5.6 4.6M4 6.6v6.6h8V6.6'),                                // house
  language: stroke('M2.2 4.2h7.2M5.8 2.4v1.8M3.9 4.2c.6 2.6 2.4 4.6 5 5.5M7.8 4.2C7.3 6.8 5.4 8.9 2.6 9.9M8.8 13.6l2.6-6.2 2.6 6.2M9.6 11.7h3.6', 1.3), // character.book.closed-ish
  calendar: rect(2, 3, 12, 11, 1.7) + stroke('M2 6.6h12M5 1.8v2.4M11 1.8v2.4'),        // calendar
  cookie: stroke('M13.7 8.7A5.8 5.8 0 1 1 7.3 2.3a1.9 1.9 0 0 0 2.5 2.3 1.9 1.9 0 0 0 2.3 2.4 1.9 1.9 0 0 0 1.6 1.7z') + dot(5.6, 6.4, 0.85) + dot(6.4, 10.3, 0.85) + dot(10, 10.6, 0.85), // a cookie (no SF Symbol)
  eye: stroke('M1.4 8S3.8 3.6 8 3.6 14.6 8 14.6 8 12.2 12.4 8 12.4 1.4 8 1.4 8z') + circle(8, 8, 2.1), // eye
  eyeSlash: stroke('M6.2 4c.6-.2 1.2-.3 1.8-.3 4.2 0 6.6 4.4 6.6 4.4a12 12 0 0 1-1.7 2.2M10.4 11.8c-.7.4-1.5.6-2.4.6-4.2 0-6.6-4.4-6.6-4.4a12.4 12.4 0 0 1 2.4-2.8M2.2 2.2l11.6 11.6M6.6 6.7a2 2 0 0 0 2.8 2.7'), // eye.slash
  signature: stroke('M1.8 11.2c1.6 0 2.2-6 3.7-6 1.3 0 .5 5 1.9 5 1.2 0 1.6-2.7 2.7-2.7.8 0 .9 1.2 1.7 1.2.6 0 1.1-.4 1.7-.9M1.8 13.8h12.4'), // signature
  server: rect(2.4, 2.4, 11.2, 4.6, 1.2) + rect(2.4, 9, 11.2, 4.6, 1.2) + dot(4.8, 4.7, 0.8) + dot(4.8, 11.3, 0.8), // server.rack
  question: circle(8, 8, 6.3) + stroke('M6.2 6.3a1.9 1.9 0 1 1 2.6 1.8c-.5.2-.8.6-.8 1.1v.5') + dot(8, 11.4, 0.85), // questionmark.circle
  chevronRight: stroke('M6 3.4L10.6 8 6 12.6', 1.5),                                     // chevron.right
  chevronLeft: stroke('M10 3.4L5.4 8 10 12.6', 1.5),                                     // chevron.left
  arrowLeft: stroke('M13 8H3M7 4L3 8l4 4'),                                              // arrow.left
  refresh: stroke('M13.2 8a5.2 5.2 0 1 1-1.6-3.8M13.4 2.6v3h-3'),                        // arrow.clockwise
  wallet: rect(1.8, 4.2, 12.4, 9.2, 1.7) + stroke('M3.6 4.2l6.9-1.9c.7-.2 1.4.3 1.4 1v.9M10.4 8.8h3.8') + dot(11.6, 8.8, 0.8), // wallet.pass-ish
  box: stroke('M2.4 5L8 2.2 13.6 5v6L8 13.8 2.4 11zM2.4 5L8 7.8 13.6 5M8 7.8v6'),       // shippingbox
  lifebuoy: circle(8, 8, 6.2) + circle(8, 8, 2.5) + stroke('M3.6 3.6l2.6 2.6M12.4 3.6L9.8 6.2M3.6 12.4l2.6-2.6M12.4 12.4L9.8 9.8'), // lifepreserver
  book: stroke('M8 4.2C6.6 3 4.6 2.6 2 2.8v9.6c2.6-.2 4.6.2 6 1.4 1.4-1.2 3.4-1.6 6-1.4V2.8c-2.6-.2-4.6.2-6 1.4zM8 4.2v9.6'), // book
  person: circle(8, 5.4, 2.6) + stroke('M2.8 13.6c.7-2.6 2.7-4 5.2-4s4.5 1.4 5.2 4'),      // person
  logout: stroke('M9.4 3H4.2C3.5 3 3 3.5 3 4.2v7.6c0 .7.5 1.2 1.2 1.2h5.2M7 8h7M11.8 5.6L14.2 8l-2.4 2.4'), // rectangle.portrait.and.arrow.right
  bolt: stroke('M9 1.8L3.6 9h4.2L7 14.2 12.4 7H8.2z'),                                   // bolt
  layers: stroke('M8 2.2l6 3.2-6 3.2-6-3.2zM2 8.2l6 3.2 6-3.2M2 11l6 3.2 6-3.2'),        // square.stack.3d.up-ish
  link: stroke('M6.8 9.2a2.6 2.6 0 0 0 3.7 0l2.2-2.2a2.6 2.6 0 0 0-3.7-3.7l-.9.9M9.2 6.8a2.6 2.6 0 0 0-3.7 0L3.3 9a2.6 2.6 0 0 0 3.7 3.7l.9-.9'), // link
  minus: stroke('M3.5 8h9', 1.5),                                                        // minus
  record: circle(8, 8, 6.2) + dot(8, 8, 2.6),                                             // record.circle
  wave: stroke('M1.5 8c1.1 0 1.1-3 2.2-3s1.1 6 2.2 6 1.1-6 2.2-6 1.1 6 2.2 6 1.1-3 2.2-3h1.5'), // waveform-ish (noise)
  equal: stroke('M3.5 6h9M3.5 10h9', 1.5),                                               // equal
  notEqual: stroke('M3.5 6h9M3.5 10h9M10.4 2.8L5.6 13.2', 1.5),                           // notequal
  compass: circle(8, 8, 6.3) + `<path d="M10.6 5.4L9 9 5.4 10.6 7 7z" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/>` + dot(8, 8, 0.7), // safari (compass)
};

const ALL = { ...L.ICONS, ...SITE_ICONS };

/// An inline icon `size` px square in the current text colour (no sprite: it draws without JavaScript).
export function icon(name, size = 16, cls = '') {
  const body = ALL[name];
  if (!body) throw new Error(`no icon "${name}"`);
  return `<svg class="icon${cls ? ' ' + cls : ''}" width="${size}" height="${size}" viewBox="0 0 16 16" aria-hidden="true" focusable="false">${body}</svg>`;
}
export const hasIcon = (name) => Boolean(ALL[name]);

/// LumenMark: the near-black continuous tile with the split disc (the cut chosen by size, as in the app).
export const mark = (size, opts) => L.geometry.markSVG(size, opts);
/// The split disc alone, in one colour.
export const glyph = (size, color = '#F4F5F7') => L.geometry.glyphSVG(size, color);
/// LUMEN, drawn from its outlines (no font).
export const wordmark = (height, color = 'currentColor') => L.geometry.wordmarkSVG(height, color);
/// A flat circle flag (CountryFlag.swift).
export const flag = (code, size = 14) => L.flagSVG(code, size);
/// The profile glyph's palette (ProfileAvatar) and the sample profiles' palette index (UISnapshots).
export const avatarPalette = L.avatar.PALETTE;
export const sampleAvatarIndex = L.avatar.sampleAvatarIndex;

/// The mark as a data: URL for the favicon (inline, nothing fetched).
export function faviconDataURL() {
  const svg = L.geometry.markSVG(64).replace('<svg ', '<svg xmlns="http://www.w3.org/2000/svg" ').replace('xmlns="http://www.w3.org/2000/svg" xmlns="http://www.w3.org/2000/svg"', 'xmlns="http://www.w3.org/2000/svg"');
  return 'data:image/svg+xml,' + encodeURIComponent(svg);
}
