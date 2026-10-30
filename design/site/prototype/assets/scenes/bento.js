// Home scene "bento": one picture follows the scroll — the ephemeral profile's window empties and fades
// as its tile rises: --x is 0 while the window's middle is at 72 % of the window height (the whole tile is
// in view by then) and 1 once it is at 42 %, so the reader sees it happen. Scenes only; without them --x
// stays unset and the CSS shows the closed state. Nothing moves when the scroll stops.
(window.LumenScenes = window.LumenScenes || []).push(function (api) {
  if (!api.scenesOn) return;
  const tile = document.querySelector('.sc-bento .bx-ep'), win = tile && tile.querySelector('.ep-win');
  if (!win) return;
  const art = tile.querySelector('.bx-art'); // not transformed, unlike the window
  let last = -1, queued = false;
  function update() {
    queued = false;
    const vh = window.innerHeight, r = art.getBoundingClientRect();
    if (r.bottom < -vh || r.top > 2 * vh) return;
    const c = r.top + Math.min(r.height, win.offsetHeight) / 2;
    const x = api.easeInOut((vh * 0.72 - c) / (vh * 0.3));
    if (Math.abs(x - last) < 0.002) return;
    last = x;
    win.style.setProperty('--x', x.toFixed(3));
  }
  const kick = () => { if (!queued) { queued = true; requestAnimationFrame(update); } };
  window.addEventListener('scroll', kick, { passive: true });
  window.addEventListener('resize', kick);
  update();
});
