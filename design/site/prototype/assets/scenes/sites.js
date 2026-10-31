// Home scene "sites": the profile in the window changes twice as the scene scrolls (Store → Ads → QA). Each
// change runs down the page as a wave: every roll ([data-d], its place in the wave) moves its --x from one
// profile to the next a little after the one above it — the profile in the toolbar first, then what the site
// sees, then the page from the edition line down. Safari's loading line runs along the address field while
// the new page sets. Only on scroll frames; without scenes nothing is set and the first profile shows.
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  if (!api.scenesOn) return;
  const section = document.querySelector('[data-scene="sites"]');
  if (!section) return;
  const SWITCH = [0.29, 0.59];    // where each change starts (scene progress)
  const ALL = [0.8, 0.1];         // the closing chord: every row of what the site sees lights (start, length)
  const DUR = 0.05, STEP = 0.006;   // one line's change; the delay per place in the wave (all set in 0.11)
  const rolls = Array.from(section.querySelectorAll('[data-d]')).map((el) => ({ el, d: +el.dataset.d, last: -1 }));
  const load = section.querySelector('.sw-load');
  const track = section.querySelector('.sit-track');
  let lastL = -1, lastO = -1, lastA = -1;
  api.onScene('sites', (p) => {
    const a = api.smooth((p - ALL[0]) / ALL[1]);
    if (track && Math.abs(a - lastA) > 0.0004) { lastA = a; track.style.setProperty('--all', a.toFixed(4)); }
    for (const r of rolls) {
      let x = 0;
      for (const s of SWITCH) x += api.smooth((p - s - r.d * STEP) / DUR);
      if (Math.abs(x - r.last) < 0.0004) continue;
      r.last = x;
      r.el.style.setProperty('--x', x.toFixed(4));
    }
    if (!load) return;
    let l = 0, o = 0;
    for (const s of SWITCH) {
      const t = (p - s) / 0.11;
      if (t <= 0 || t >= 1.25) continue;
      l = api.easeOut(Math.min(1, t));
      o = t < 1 ? Math.min(1, t * 6) : 1 - (t - 1) / 0.25;
    }
    if (Math.abs(l - lastL) > 0.0005 || Math.abs(o - lastO) > 0.0005) {
      lastL = l; lastO = o;
      load.style.setProperty('--l', l.toFixed(4));
      load.style.setProperty('--lo', o.toFixed(4));
    }
  });
});
