import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { SplitText } from 'gsap/SplitText';
import { CustomEase } from 'gsap/CustomEase';

gsap.registerPlugin(ScrollTrigger, SplitText, CustomEase);

// One easing curve for the whole page, the same as --ease in the styles.
const ease = CustomEase.create('velvet', '0.22,1,0.36,1');

// Tells the layout's fallback timer that the animations are in control.
(window as unknown as { velvetMotion: boolean }).velvetMotion = true;

const root = document.documentElement;
const $ = <T extends Element = HTMLElement>(s: string) => document.querySelector<T>(s);
const $$ = <T extends Element = HTMLElement>(s: string) => [...document.querySelectorAll<T>(s)];

// Copy buttons.
for (const btn of $$<HTMLButtonElement>('[data-copy]')) {
  btn.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(btn.dataset.copy!);
    } catch {
      return;
    }
    btn.classList.add('copied');
    const status = btn.querySelector('[data-copy-status]');
    if (status) status.textContent = 'Copied';
    setTimeout(() => {
      btn.classList.remove('copied');
      if (status) status.textContent = '';
    }, 1800);
  });
}

// The page's seek bar under the navigation: each section is a chapter (a gap in the line)
// and the scroll position is the playhead. The corner player shows the same position.
const played = $('[data-page-played]');
const gaps = $('[data-page-gaps]');
const dock = $('[data-pip-dock]');
const scrollMax = () => Math.max(1, root.scrollHeight - innerHeight);

const layoutChapters = () => {
  if (!gaps) return;
  gaps.replaceChildren();
  for (const section of $$('main > section').slice(1)) {
    const at = (section.getBoundingClientRect().top + scrollY) / scrollMax();
    if (at >= 1) continue;
    const gap = document.createElement('i');
    gap.style.left = `calc(${at * 100}% - 2px)`;
    gaps.append(gap);
  }
};

let queued = false;
const paintProgress = () => {
  queued = false;
  const p = Math.min(1, scrollY / scrollMax());
  if (played) played.style.transform = `scaleX(${p})`;
  dock?.style.setProperty('--page-progress', String(p));
};
window.addEventListener(
  'scroll',
  () => {
    if (!queued) {
      queued = true;
      requestAnimationFrame(paintProgress);
    }
  },
  { passive: true },
);
ScrollTrigger.addEventListener('refresh', () => {
  layoutChapters();
  paintProgress();
});
layoutChapters();
paintProgress();

const mm = gsap.matchMedia();

mm.add('(prefers-reduced-motion: reduce)', () => {
  root.classList.add('loaded');
});

// The hero as a room: the window starts off the right edge and comes to the centre
// while the page is held in place. Only on wide screens.
mm.add('(min-width: 1000px) and (prefers-reduced-motion: no-preference)', () => {
  root.classList.add('pin-hero');
  const win = $('[data-hero-window]');
  const text = $('[data-hero-text]');
  if (win && text) {
    gsap.set(win, { x: 0, y: 0, yPercent: -50, scale: 0.9 });
    const tl = gsap.timeline({
      scrollTrigger: { trigger: '[data-hero]', start: 'top top', end: '+=80%', pin: true, scrub: 0.5, invalidateOnRefresh: true },
    });
    tl.to(text, { autoAlpha: 0, y: -24, duration: 0.5, ease: 'none' }, 0);
    tl.to(win, { x: () => (innerWidth - win.offsetWidth) / 2 - innerWidth * 0.52, scale: 1, duration: 1, ease: 'power1.inOut' }, 0);
  }
  return () => {
    root.classList.remove('pin-hero');
    if (win) gsap.set(win, { clearProps: 'transform' });
    if (text) gsap.set(text, { clearProps: 'all' });
  };
});

mm.add('(prefers-reduced-motion: no-preference)', () => {
  // Headlines come up line by line from behind a mask. The split waits for the fonts,
  // because the line breaks depend on them.
  const splitLines = (el: HTMLElement, vars: gsap.TweenVars) => {
    gsap.set(el, { opacity: 1 });
    SplitText.create(el, {
      type: 'lines',
      mask: 'lines',
      linesClass: 'split-line',
      autoSplit: true,
      onSplit: (self) => gsap.from(self.lines, { yPercent: 110, duration: 0.8, ease, stagger: 0.06, ...vars }),
    });
  };

  document.fonts.ready.then(() => {
    const title = $('[data-hero-title]');
    if (title) splitLines(title, { delay: 0.05 });
    gsap.fromTo('[data-hero-fade]', { opacity: 0, y: 12 }, { opacity: 1, y: 0, duration: 0.5, ease, stagger: 0.06, delay: 0.3 });
    gsap.fromTo('[data-hero-window]', { opacity: 0 }, { opacity: 1, duration: 0.8, ease: 'none', delay: 0.35 });
    for (const h of $$('.title[data-reveal]')) {
      splitLines(h, { scrollTrigger: { trigger: h, start: 'top 88%', once: true } });
    }
    root.classList.add('loaded');
  });

  // Reveals: a short fade and rise.
  const rise = (selector: string, stagger = 0.05) =>
    ScrollTrigger.batch(selector, {
      start: 'top 90%',
      once: true,
      onEnter: (els) => gsap.fromTo(els, { opacity: 0, y: 12 }, { opacity: 1, y: 0, duration: 0.5, ease, stagger }),
    });
  rise('[data-reveal]:not(.title)');
  gsap.set('[data-tile], [data-row]', { opacity: 0 });
  rise('[data-tile]', 0.04);
  rise('[data-row]', 0.04);

  // The home feed comes forward as it scrolls into view.
  gsap.fromTo(
    '[data-shot]',
    { scale: 0.94, y: 48 },
    { scale: 1, y: 0, ease: 'none', scrollTrigger: { trigger: '[data-shot]', start: 'top 100%', end: 'top 40%', scrub: 0.5 } },
  );

  // The memory chart: both bars grow at the same speed, so Velvet's stops early.
  const meter = $('[data-meter]');
  if (meter) {
    const bars = [...meter.querySelectorAll<HTMLElement>('[data-bar]')];
    const counts = [...meter.querySelectorAll<HTMLElement>('[data-count]')];
    const longest = Math.max(...bars.map((b) => Number(b.style.getPropertyValue('--f'))));
    const tl = gsap.timeline({ scrollTrigger: { trigger: meter, start: 'top 70%', once: true } });
    bars.forEach((bar, i) => {
      const d = Math.max(0.4, 1.6 * (Number(bar.style.getPropertyValue('--f')) / longest));
      tl.fromTo(bar, { scaleX: 0 }, { scaleX: 1, duration: d, ease: 'power1.out' }, 0);
      const end = Number(counts[i].dataset.count);
      const v = { n: 0 };
      tl.to(v, { n: end, duration: d, ease: 'power1.out', onUpdate: () => (counts[i].textContent = Math.round(v.n).toLocaleString('en-US')) }, 0);
    });
    gsap.set(bars, { scaleX: 0 });
  }

  // Picture in Picture scene: the video leaves its slot and settles in the corner while
  // a different app comes to the front. Transforms only; the start is the slot's place.
  const scene = $('[data-pip-scene]');
  const mini = $('[data-pip-mini]');
  const slot = scene?.querySelector<HTMLElement>('.slot');
  const host = slot?.parentElement;
  if (scene && mini && slot && host) {
    const tl = gsap.timeline({
      scrollTrigger: { trigger: scene, start: 'top 78%', end: 'center 40%', scrub: 0.5, invalidateOnRefresh: true },
    });
    tl.fromTo('[data-pip-other]', { xPercent: 40, opacity: 0 }, { xPercent: 0, opacity: 1, ease: 'power1.out', duration: 1 }, 0.1);
    tl.fromTo(
      mini,
      {
        x: () => host.offsetLeft + slot.offsetLeft - mini.offsetLeft,
        y: () => host.offsetTop + slot.offsetTop - mini.offsetTop,
        scale: () => slot.offsetWidth / mini.offsetWidth,
      },
      { x: 0, y: 0, scale: 1, ease: 'power1.inOut', duration: 1 },
      0.2,
    );
    tl.to({}, { duration: 0.1 });
  }

  // The page's own Picture in Picture: a small player that stays in the corner from the
  // end of the hero to the end of the Picture in Picture section.
  if (dock) {
    const st = ScrollTrigger.create({
      trigger: '[data-hero]',
      start: 'bottom top+=96',
      endTrigger: '[data-pip-section]',
      end: 'bottom 55%',
      toggleClass: { targets: dock, className: 'on' },
    });
    dock.querySelector('[data-pip-close]')?.addEventListener('click', () => {
      st.kill();
      dock.classList.remove('on');
    });
  }

  // Image decoding and font loading move the layout.
  window.addEventListener('load', () => ScrollTrigger.refresh());
});
