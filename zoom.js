/* Photo viewer: click a photo in .photos to open it full screen,
   the same way the ARMORY page does. */
(function () {
  const grid = document.querySelector('.photos');
  if (!grid) return;

  const photos = Array.prototype.slice.call(grid.querySelectorAll('img'));
  if (!photos.length) return;

  // Wrap each photo in a button so it can be clicked or opened with the keyboard
  photos.forEach(function (img, i) {
    const b = document.createElement('button');
    b.type = 'button';
    b.setAttribute('aria-label', 'Open photo ' + (i + 1) + ' of ' + photos.length);
    img.replaceWith(b);
    b.append(img);
    b.addEventListener('click', function () { open(i); });
  });

  // Build the viewer
  const zoom = document.createElement('div');
  zoom.className = 'zoom';
  zoom.setAttribute('role', 'dialog');
  zoom.setAttribute('aria-modal', 'true');
  zoom.setAttribute('aria-label', 'Photo viewer');
  zoom.innerHTML =
    '<button class="zoom-btn zoom-close" type="button">[CLOSE]</button>' +
    '<button class="zoom-btn zoom-prev" type="button">[PREV]</button>' +
    '<button class="zoom-btn zoom-next" type="button">[NEXT]</button>' +
    '<img class="zoom-img" alt="">' +
    '<div class="zoom-meta"></div>';
  document.body.append(zoom);

  const big = zoom.querySelector('.zoom-img');
  const meta = zoom.querySelector('.zoom-meta');
  const pad = function (n) { return String(n).padStart(2, '0'); };
  let current = 0;

  function open(i) {
    current = (i + photos.length) % photos.length;
    big.src = photos[current].currentSrc || photos[current].src;
    big.alt = photos[current].alt;
    meta.textContent = pad(current + 1) + ' / ' + pad(photos.length);
    if (!zoom.classList.contains('open')) {
      zoom.classList.add('open');
      document.body.style.overflow = 'hidden';
      zoom.querySelector('.zoom-close').focus({ preventScroll: true });
    }
  }

  function close() {
    zoom.classList.remove('open');
    document.body.style.overflow = '';
    grid.querySelectorAll('button')[current].focus({ preventScroll: true });
  }

  zoom.querySelector('.zoom-close').addEventListener('click', close);
  zoom.querySelector('.zoom-prev').addEventListener('click', function () { open(current - 1); });
  zoom.querySelector('.zoom-next').addEventListener('click', function () { open(current + 1); });
  big.addEventListener('click', function () { if (!swiped) open(current + 1); });
  zoom.addEventListener('click', function (e) { if (e.target === zoom) close(); });

  document.addEventListener('keydown', function (e) {
    if (!zoom.classList.contains('open')) return;
    if (e.key === 'Escape') close();
    if (e.key === 'ArrowLeft') open(current - 1);
    if (e.key === 'ArrowRight') open(current + 1);
  });

  // Swipe left / right on phones
  let swipe = null, swiped = false;
  zoom.addEventListener('touchstart', function (e) {
    if (e.touches.length !== 1) { swipe = null; return; }
    swipe = { x: e.touches[0].clientX, y: e.touches[0].clientY };
    swiped = false;
  }, { passive: true });
  zoom.addEventListener('touchend', function (e) {
    if (!swipe) return;
    const t = e.changedTouches[0];
    const dx = t.clientX - swipe.x, dy = t.clientY - swipe.y;
    swipe = null;
    if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy) * 1.4) {
      swiped = true;
      setTimeout(function () { swiped = false; }, 400);
      open(current + (dx < 0 ? 1 : -1));
    }
  });
})();
