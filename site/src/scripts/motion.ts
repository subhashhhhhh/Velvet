import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { SplitText } from 'gsap/SplitText';

gsap.registerPlugin(ScrollTrigger, SplitText);

// Tells the layout's fallback timer that the animations are in control.
(window as unknown as { velvetMotion: boolean }).velvetMotion = true;

const root = document.documentElement;
const $ = <T extends Element = HTMLElement>(s: string) => document.querySelector<T>(s);
const $$ = <T extends Element = HTMLElement>(s: string) => [...document.querySelectorAll<T>(s)];

// Navigation bar: a solid background after the first scroll.
const nav = $('[data-nav]');
const onScroll = () => nav?.classList.toggle('scrolled', window.scrollY > 12);
window.addEventListener('scroll', onScroll, { passive: true });
onScroll();

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

const mm = gsap.matchMedia();

mm.add('(prefers-reduced-motion: reduce)', () => {
  root.classList.add('loaded');
});

mm.add('(prefers-reduced-motion: no-preference)', () => {
  const ease = 'expo.out';

  // Headlines come up line by line from behind a mask. The split waits for the fonts,
  // because the line breaks depend on them.
  const splitLines = (el: HTMLElement, vars: (lines: Element[]) => gsap.TweenVars) => {
    gsap.set(el, { opacity: 1 });
    SplitText.create(el, {
      type: 'lines',
      mask: 'lines',
      linesClass: 'split-line',
      autoSplit: true,
      onSplit: (self) => gsap.from(self.lines, { yPercent: 115, duration: 1.15, ease, stagger: 0.1, ...vars(self.lines) }),
    });
  };

  document.fonts.ready.then(() => {
    // Hero: title, then the supporting lines, then the window.
    const title = $('[data-hero-title]');
    if (title) splitLines(title, () => ({ delay: 0.1 }));
    gsap.fromTo('[data-hero-fade]', { opacity: 0, y: 18 }, { opacity: 1, y: 0, duration: 1, ease, stagger: 0.09, delay: 0.35 });
    gsap.fromTo('[data-hero-stage]', { opacity: 0, y: 90 }, { opacity: 1, y: 0, duration: 1.5, ease, delay: 0.55 });
    gsap.to('[data-hero-window]', { '--sheen-x': '360%', duration: 1.7, ease: 'power2.inOut', delay: 1.3 });

    for (const h of $$('.display[data-reveal]')) {
      splitLines(h, () => ({ scrollTrigger: { trigger: h, start: 'top 88%', once: true } }));
    }
    root.classList.add('loaded');
  });

  // The hero window lies back a little and stands up as it comes into view.
  gsap.fromTo(
    '[data-hero-window]',
    { rotateX: 16, scale: 0.94 },
    { rotateX: 0, scale: 1, ease: 'none', scrollTrigger: { trigger: '[data-hero-stage]', start: 'top 92%', end: 'top 22%', scrub: 0.6 } },
  );

  gsap.fromTo(
    '[data-shot-inner]',
    { rotateX: 14, scale: 0.93, opacity: 0.5 },
    { rotateX: 0, scale: 1, opacity: 1, ease: 'none', scrollTrigger: { trigger: '[data-shot]', start: 'top 95%', end: 'top 30%', scrub: 0.6 } },
  );

  // General reveals.
  ScrollTrigger.batch('[data-reveal]:not(.display)', {
    start: 'top 90%',
    once: true,
    onEnter: (els) => gsap.fromTo(els, { opacity: 0, y: 26 }, { opacity: 1, y: 0, duration: 1, ease, stagger: 0.08 }),
  });
  gsap.set('[data-tile], [data-row]', { opacity: 0 });
  ScrollTrigger.batch('[data-tile]', {
    start: 'top 92%',
    once: true,
    onEnter: (els) => gsap.fromTo(els, { opacity: 0, y: 20 }, { opacity: 1, y: 0, duration: 0.8, ease, stagger: 0.06 }),
  });
  ScrollTrigger.batch('[data-row]', {
    start: 'top 92%',
    once: true,
    onEnter: (els) => gsap.fromTo(els, { opacity: 0, x: -18 }, { opacity: 1, x: 0, duration: 0.8, ease, stagger: 0.07 }),
  });

  // Numbers count up when they come into view.
  const countUp = (el: HTMLElement, duration: number, st?: ScrollTrigger.Vars) => {
    const end = Number(el.dataset.count);
    const decimals = Number(el.dataset.decimals ?? 0);
    const v = { n: 0 };
    return gsap.to(v, {
      n: end,
      duration,
      ease: 'power2.out',
      scrollTrigger: st,
      onUpdate: () => (el.textContent = v.n.toFixed(decimals)),
    });
  };

  // The memory meter: both bars grow at the same speed, so Velvet's stops early.
  const meter = $('[data-meter]');
  if (meter) {
    const bars = [...meter.querySelectorAll<HTMLElement>('[data-bar]')];
    const counts = [...meter.querySelectorAll<HTMLElement>('[data-count]')];
    const full = 1.9;
    const tl = gsap.timeline({ scrollTrigger: { trigger: meter, start: 'top 72%', once: true } });
    bars.forEach((bar, i) => {
      const share = parseFloat(bar.style.getPropertyValue('--w')) / 100;
      const d = Math.max(0.5, full * share);
      tl.fromTo(bar, { scaleX: 0 }, { scaleX: 1, duration: d, ease: 'power1.out' }, 0);
      const end = Number(counts[i].dataset.count);
      const decimals = Number(counts[i].dataset.decimals ?? 0);
      const v = { n: 0 };
      tl.to(v, { n: end, duration: d, ease: 'power1.out', onUpdate: () => (counts[i].textContent = v.n.toFixed(decimals)) }, 0);
    });
    gsap.set(bars, { scaleX: 0 });
  }
  for (const el of $$('.stats [data-count]')) countUp(el, 1.4, { trigger: el, start: 'top 90%', once: true });

  // Picture in Picture scene: the video leaves its slot and settles in the corner
  // while a different app comes to the front.
  const scene = $('[data-pip-scene]');
  const mini = $('[data-pip-mini]');
  const slot = scene?.querySelector<HTMLElement>('.slot');
  if (scene && mini && slot) {
    const from = () => {
      const s = scene.getBoundingClientRect();
      const r = slot.getBoundingClientRect();
      return {
        left: `${((r.left - s.left) / s.width) * 100}%`,
        top: `${((r.top - s.top) / s.height) * 100}%`,
        width: `${(r.width / s.width) * 100}%`,
      };
    };
    const tl = gsap.timeline({
      scrollTrigger: { trigger: scene, start: 'top 78%', end: 'center 38%', scrub: 0.7, invalidateOnRefresh: true },
    });
    tl.fromTo('[data-pip-other]', { xPercent: 70, opacity: 0 }, { xPercent: 0, opacity: 1, ease: 'power2.out', duration: 1 }, 0.15);
    tl.fromTo(mini, from, { left: '61%', top: '62%', width: '34%', ease: 'power2.inOut', duration: 1 }, 0.25);
    tl.to({}, { duration: 0.15 });
  }

  // The page's own Picture in Picture: a small player that stays in the corner
  // from the end of the hero to the end of the Picture in Picture section.
  const dock = $('[data-pip-dock]');
  if (dock) {
    const st = ScrollTrigger.create({
      trigger: '[data-hero-window]',
      start: 'bottom top+=120',
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
