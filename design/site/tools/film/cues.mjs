// The cue sheet for a licensed track: video/cues.csv, generated from tools/film/timeline.json (spec v2 §3 (2)).
// One row per cut and per internal event: time (s), frame (60 fps), bar.beat at the film's tempo (120 bpm, 4/4,
// bar 1 beat 1 at 0.0) with the remainder in ticks (960 a beat), the absolute beat, the shot, the event, its sync
// (hard: the picture changes on that frame; soft: a movement or a step inside a shot), what the foley does there,
// and the spec's must-hit note for the music.
//
// It reads timeline.json when it has the v2 shape (version 2, shots S01–S21, events, cues). If it does not, it falls
// back to the spec v2 shot list and the contract's cue defaults, and says so in the last column of every row.
//
//   node tools/film/cues.mjs [--out video/cues.csv]
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const SITE = path.resolve(here, '../..');
const args = process.argv.slice(2);
const outArg = args.indexOf('--out');
const OUT = outArg >= 0 ? path.resolve(args[outArg + 1]) : path.join(SITE, 'video', 'cues.csv');

const CUE_DEFAULTS = { lid: [1.8, 2.9], settle: 2.9, click: 16.5, zero: [18.5, 19.0], seat: 27.0, end: 29.5, roomFadeIn: 0.25, roomReturnFade: 0.3 };

// spec v2 §4, for when timeline.json is not v2 yet
const SPEC_SHOTS = [
  ['S01', 0, 1.5, 'name'], ['S02', 1.5, 4.5, 'mac-opens'], ['S03', 4.5, 5.5, 'claim'], ['S04', 5.5, 7, 'burst'],
  ['S05', 7, 8.5, 'one-mac'], ['S06', 8.5, 9.5, 'at-once'], ['S07', 9.5, 11.5, 'countries'], ['S08', 11.5, 13.5, 'closing'],
  ['S09', 13.5, 14.5, 'sites-see'], ['S10', 14.5, 16, 'numbers'], ['S11', 16, 17, 'weiter'], ['S12', 17, 18, 'stall'],
  ['S13', 18, 19, 'lights-out'], ['S14', 19, 20.5, 'proxy-card'], ['S15', 20.5, 22, 'sealed'], ['S16', 22, 23, 'encryption'],
  ['S17', 23, 24.5, 'warm-up'], ['S18', 24.5, 26.5, 'tiles'], ['S19', 26.5, 27.5, 'halves-meet'], ['S20', 27.5, 29.5, 'end'],
  ['S21', 29.5, 30, 'black'],
];
const SPEC_EVENTS = [
  [1.8, 'lid-starts', 'soft'], [2.6, 'display-wakes', 'soft'], [2.9, 'lid-settles', 'hard'], [3.4, 'half-lifts', 'soft'],
  [5, 'line-2', 'hard'], [5.75, 'burst-cut', 'hard'], [6, 'burst-cut', 'hard'], [6.25, 'burst-cut', 'hard'],
  [6.5, 'burst-cut', 'hard'], [6.75, 'burst-cut', 'hard'], [8.3, 'lands', 'soft'], [9, 'line-2', 'hard'],
  [10.5, 'country-US', 'hard'], [11, 'country-JP', 'hard'], [12, 'halves-meet', 'hard'], [14.75, 'column-2', 'hard'],
  [15, 'column-3', 'hard'], [15.25, 'footer', 'hard'], [16.42, 'pointer-lands', 'soft'], [16.5, 'click', 'hard'],
  [16.55, 'progress-starts', 'soft'], [17.4, 'stall', 'soft'], [18.5, 'switch-dark', 'hard'], [19.5, 'line-2', 'hard'],
  [20, 'footnote', 'hard'], [20.75, 'seal-row-1', 'soft'], [20.875, 'seal-row-2', 'soft'], [21, 'seal-row-3', 'soft'],
  [21.125, 'seal-row-4', 'soft'], [21.25, 'seal-row-5', 'soft'], [22.5, 'spec-line', 'hard'],
  [23.25, 'page', 'soft'], [23.5, 'page', 'soft'], [23.75, 'page', 'soft'], [24, 'page', 'soft'], [24.25, 'page', 'soft'],
  [25, 'focus-tile-2', 'soft'], [25.5, 'focus-tile-3', 'soft'], [26, 'focus-tile-4', 'soft'], [27, 'seat', 'hard'],
  [28, 'lines', 'hard'], [29.5, 'audio-end', 'hard'],
];

let TL = null;
try { TL = JSON.parse(fs.readFileSync(path.join(here, 'timeline.json'), 'utf8')); } catch { TL = null; }
const v2 = !!(TL && TL.version === 2 && Array.isArray(TL.shots) && TL.shots.length === 21 && Array.isArray(TL.events));
const fps = (v2 && TL.fps) || 60;
const bpm = (v2 && TL.bpm) || 120;
const beatS = 60 / bpm;
const cues = { ...CUE_DEFAULTS, ...((TL && TL.cues) || {}) };
const shots = v2 ? TL.shots.map((s) => ({ id: s.id, from: s.from, to: s.to, name: s.name })) : SPEC_SHOTS.map(([id, from, to, name]) => ({ id, from, to, name }));
const shotAt = (t) => (shots.find((s) => t >= s.from - 1e-9 && t < s.to - 1e-9) || shots[shots.length - 1]).id;

let events;
if (v2) events = TL.events.map((e) => ({ t: e.t, shot: e.shot, event: e.event, sync: e.sync }));
else {
  events = shots.map((s) => ({ t: s.from, shot: s.id, event: 'cut', sync: 'hard' }))
    .concat(SPEC_EVENTS.map(([t, event, sync]) => ({ t, shot: shotAt(t), event, sync })));
}
for (const e of events) { e.sound = []; e.music = []; }

const near = (a, b) => Math.abs(a - b) < 5e-4;
function attach(t, field, text, { prefer, event, sync = 'soft' } = {}) {
  const at = events.filter((e) => near(e.t, t));
  let row = (prefer && prefer.map((p) => at.find((e) => e.event === p)).find(Boolean)) || at[0];   // in prefer's order
  if (!row) { row = { t, shot: shotAt(t), event: event || field, sync, sound: [], music: [] }; events.push(row); }
  row[field].push(text);
}

// what the foley stem does (tools/film/foley.py); everything not listed is silent
const [z0, z1] = cues.zero;
attach(0, 'sound', `room tone fades in over ${cues.roomFadeIn} s; the name arrives silently`, { prefer: ['cut'] });
attach(cues.lid[0], 'sound', `lid hinge starts: friction through the hinge, following the lid's speed until ${cues.lid[1]}`, { prefer: ['lid-starts'], event: 'lid-starts' });
attach(cues.settle, 'sound', 'lid settles: a soft felt thunk', { prefer: ['lid-settles'], event: 'lid-settles', sync: 'hard' });
attach(cues.click, 'sound', 'trackpad click, 6 ms after the frame', { prefer: ['click'], event: 'click', sync: 'hard' });
attach(Math.round((cues.click + 0.076) * 1000) / 1000, 'sound', 'trackpad release, 70 ms after the click, 8 dB quieter', { event: 'click-release' });
attach(z0, 'sound', `digital zero until ${z1}: the room tone stops too; the film's only silence`, { prefer: ['switch-dark'], event: 'switch-dark', sync: 'hard' });
attach(z1, 'sound', `room tone returns over ${cues.roomReturnFade} s`, { prefer: ['cut'] });
attach(cues.seat, 'sound', 'the halves seat: an unpitched felt thump', { prefer: ['seat'], event: 'seat', sync: 'hard' });
attach(cues.end, 'sound', 'audio ends with the picture', { prefer: ['audio-end', 'cut'] });

// spec v2 §3 (2), must-hit points for the music
attach(0, 'music', 'nothing under the name', { prefer: ['cut'] });
attach(1.5, 'music', 'the first musical event may land on this cut to the Mac', { prefer: ['cut'] });
attach(5.5, 'music', 'from here to 7.0 a pulse drives the burst (cuts on the eighths)', { prefer: ['cut'] });
attach(8.5, 'music', 'a downbeat on «Сразу.» (the track’s bar line here; the film grid calls it beat 2)', { prefer: ['cut'] });
attach(11.5, 'music', 'from here to 13.5 a thinner texture under the comparison', { prefer: ['cut'] });
attach(z0, 'music', 'HARD STOP: the music and its reverb gated to nothing within 10 ms, whatever the track does', { prefer: ['switch-dark'] });
attach(z1, 'music', 'sparse re-entry, 19.0–20.5', { prefer: ['cut'] });
attach(cues.seat, 'music', 'the last strong downbeat or chord, on the halves meeting', { prefer: ['seat'] });
attach(cues.seat + 0.5, 'music', `the tail rings until ${cues.end}`, { prefer: ['cut'] });
attach(cues.end, 'music', 'the music ends here with the picture', { prefer: ['audio-end', 'cut'] });

events.sort((a, b) => a.t - b.t || (a.event === 'cut' ? -1 : b.event === 'cut' ? 1 : 0));

function grid(t) {
  const beats = t / beatS;
  const whole = Math.floor(beats + 1e-9);
  const tick = Math.round((beats - whole) * 960);
  return { bar: Math.floor(whole / 4) + 1, beat: (whole % 4) + 1, tick: tick === 960 ? 0 : tick, beats };
}
const q = (s) => (/[",\n]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s);
const rows = [['time_s', 'frame', 'bar.beat', 'tick', 'beat', 'shot', 'event', 'sync', 'sound', 'music', 'source'].join(',')];
for (const e of events) {
  const g = grid(e.t);
  rows.push([
    e.t.toFixed(3), String(Math.round(e.t * fps)), `${g.bar}.${g.beat}`, String(g.tick), (Math.round(g.beats * 1000) / 1000).toString(),
    e.shot, e.event, e.sync, e.sound.join('; ') || (e.t >= cues.end ? '' : e.t > z0 && e.t < z1 ? 'digital zero' : 'room tone only'), e.music.join('; '),
    v2 ? 'timeline.json v2' : 'spec v2 shot list (timeline.json is not v2 yet)',
  ].map((x) => q(String(x))).join(','));
}
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT + '.tmp', rows.join('\n') + '\n');
fs.renameSync(OUT + '.tmp', OUT);
console.log(`cues: ${path.relative(SITE, OUT)} — ${events.length} rows from ${v2 ? 'timeline.json (v2)' : 'the spec v2 shot list (timeline.json is not v2)'}; ${bpm} bpm, ${fps} fps`);
