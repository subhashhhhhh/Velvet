// Draws the link-preview cards (Open Graph, 1200×630) into public/og/, one for each page,
// in the site's look. The cards are React components; a headless browser makes the images.
// Do `npm run og` after a change to this file or to the memory figures, then commit the
// images. WhatsApp ignores images over approximately 300 KB, so they are JPEGs.
import React from 'react';
import { chromium } from 'playwright';
import { renderToStaticMarkup } from 'react-dom/server';
import sharp from 'sharp';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const dataUrl = (bytes, type) => `data:${type};base64,${Buffer.from(bytes).toString('base64')}`;
const file = (path, type) => dataUrl(readFileSync(join(root, path)), type);

const sans = file('node_modules/@fontsource-variable/instrument-sans/files/instrument-sans-latin-wght-normal.woff2', 'font/woff2');
const mono = file('node_modules/@fontsource-variable/geist-mono/files/geist-mono-latin-wght-normal.woff2', 'font/woff2');
const icon = file('public/favicon.svg', 'image/svg+xml');
const frame = dataUrl(await sharp(join(root, 'src/assets/frame.png')).resize(1440).jpeg({ quality: 88 }).toBuffer(), 'image/jpeg');

// The figures on the home page (src/data.ts), in MB.
const VELVET = 360;
const SAFARI = 1400;

const css = `
@font-face { font-family: Sans; src: url(${sans}) format('woff2'); font-weight: 100 900; }
@font-face { font-family: Mono; src: url(${mono}) format('woff2'); font-weight: 100 900; }
* { box-sizing: border-box; margin: 0; }
h1, .sub { text-wrap: balance; }
body { width: 1200px; height: 630px; overflow: hidden; background: #161513; color: #efe9de; font-family: Sans; }
.card { position: relative; width: 1200px; height: 630px; padding: 60px 72px 64px; display: flex; flex-direction: column; }
.brand { display: flex; align-items: center; gap: 16px; font-size: 34px; font-weight: 600; letter-spacing: -0.01em; }
.brand img { width: 52px; height: 52px; }
.text { margin-top: auto; width: 580px; }
.label { font-size: 26px; color: #8a847a; margin-bottom: 16px; }
h1 { font-size: 72px; line-height: 76px; font-weight: 500; letter-spacing: -0.035em; }
h1.long { font-size: 64px; line-height: 68px; letter-spacing: -0.03em; }
.sub { margin-top: 24px; font-size: 29px; line-height: 38px; color: #aaa398; }
.url { position: absolute; right: 72px; bottom: 60px; font-size: 24px; color: #8a847a; }

/* The lit screen: a frame of the video with the player's seek bar. It runs off the right edge. */
.screen { position: absolute; left: 688px; top: 104px; width: 704px; height: 396px; border-radius: 20px; overflow: hidden;
  box-shadow: 0 0 0 2px rgba(239,233,222,0.14), 0 40px 80px rgba(0,0,0,0.5); }
.screen img { width: 100%; height: 100%; object-fit: cover; display: block; }
.screen::after { content: ''; position: absolute; inset: 55% 0 0 0; background: linear-gradient(rgba(0,0,0,0), rgba(0,0,0,0.7)); }
.rail { position: absolute; z-index: 1; left: 28px; right: -40px; bottom: 34px; height: 6px; border-radius: 3px; background: rgba(239,233,222,0.3); }
.rail b { position: absolute; left: 0; top: 0; bottom: 0; width: 31%; border-radius: 3px 0 0 3px; background: #e0103a; }
.rail i { position: absolute; top: 0; bottom: 0; width: 5px; background: rgba(0,0,0,0.8); }
.rail u { position: absolute; left: 31%; top: 50%; width: 18px; height: 18px; margin: -9px 0 0 -9px; border-radius: 50%; background: #efe9de; }

/* The memory comparison: the one place with the accent. */
.bars { margin-top: 36px; display: grid; gap: 14px; }
.bar { display: flex; align-items: center; gap: 16px; font-size: 26px; }
.bar span { width: 92px; color: #aaa398; }
.bar i { height: 24px; border-radius: 5px; background: #3a3733; }
.bar.velvet span { color: #efe9de; }
.bar.velvet i { background: #e0103a; }
.bar em { font-family: Mono; font-style: normal; font-size: 24px; }
.note { margin-top: 20px; font-size: 22px; color: #8a847a; }

.chart { position: absolute; left: 688px; top: 176px; width: 440px; }
.chart .bars { margin: 0; gap: 28px; }
.chart .bar { display: grid; grid-template-columns: 1fr; gap: 10px; font-size: 28px; }
.chart .bar span { width: auto; display: flex; justify-content: space-between; align-items: baseline; }
.chart .bar i { height: 48px; border-radius: 8px; }
.chart .bar em { font-size: 28px; }
.chart .note { margin-top: 24px; font-size: 22px; }

.keys { position: absolute; left: 688px; top: 150px; display: grid; gap: 20px; }
.keys div { display: flex; gap: 20px; }
kbd { display: grid; place-items: center; min-width: 104px; height: 104px; padding: 0 28px; border-radius: 20px; background: #262421;
  box-shadow: inset 0 0 0 2px rgba(239,233,222,0.14), inset 0 -6px 0 rgba(0,0,0,0.3); font-family: Mono; font-size: 40px; color: #efe9de; }
kbd.on { background: #efe9de; color: #12110f; box-shadow: inset 0 -6px 0 rgba(0,0,0,0.16); }
`;

const Brand = () => (
  <div className="brand">
    <img src={icon} alt="" />
    Velvet
  </div>
);

const Screen = () => (
  <div className="screen">
    <img src={frame} alt="" />
    <div className="rail">
      <b />
      {[10, 28, 50, 72, 90].map((at) => (
        <i key={at} style={{ left: `${at}%` }} />
      ))}
      <u />
    </div>
  </div>
);

const Bars = ({ width }) => (
  <div className="bars">
    <div className="bar velvet">
      <span>Velvet</span>
      <i style={{ width: Math.round((width * VELVET) / SAFARI) }} />
      <em>{VELVET} MB</em>
    </div>
    <div className="bar">
      <span>Safari</span>
      <i style={{ width }} />
      <em>{SAFARI.toLocaleString('en-US')} MB</em>
    </div>
  </div>
);

// The same bars, large, with each value under its name (for the memory page).
const Chart = () => (
  <div className="chart">
    <div className="bars">
      <div className="bar velvet">
        <span>Velvet <em>{VELVET} MB</em></span>
        <i style={{ width: Math.round((440 * VELVET) / SAFARI) }} />
      </div>
      <div className="bar">
        <span>youtube.com in Safari <em>{SAFARI.toLocaleString('en-US')} MB</em></span>
        <i style={{ width: 440 }} />
      </div>
    </div>
    <p className="note">Memory with the same 1440p video</p>
  </div>
);

const Keys = () => (
  <div className="keys">
    <div>
      <kbd>J</kbd>
      <kbd className="on">K</kbd>
      <kbd>L</kbd>
    </div>
    <div>
      <kbd>M</kbd>
      <kbd>C</kbd>
      <kbd>T</kbd>
    </div>
    <div>
      <kbd style={{ minWidth: 352 }}>Space</kbd>
    </div>
  </div>
);

const Page = ({ label, title, sub, path, visual = <Screen /> }) => (
  <div className="card">
    <Brand />
    <div className="text">
      <p className="label">{label}</p>
      <h1 className="long">{title}</h1>
      <p className="sub">{sub}</p>
    </div>
    {visual}
    <span className="url">velvet.subhashh.tech{path}</span>
  </div>
);

const cards = {
  home: (
    <div className="card">
      <Brand />
      <div className="text">
        <h1>YouTube, without<br />the weight</h1>
        <Bars width={280} />
        <p className="note">Memory with the same 1440p video</p>
      </div>
      <Screen />
      <span className="url">A native YouTube client for macOS</span>
    </div>
  ),
  download: <Page label="Download" title="Download Velvet for macOS" sub="Free and open source, for Apple silicon and Intel" path="/download" />,
  changelog: <Page label="Changelog" title="What changed in each release" sub="Newest first" path="/changelog" />,
  help: <Page label="Help" title="Solutions for the usual problems" sub="The first start, playback, updates and sign-in" path="/help" />,
  open: <Page label="Open links" title="Open YouTube links in Velvet" sub="Copy, drag, a bookmarklet or a velvet:// link" path="/open" />,
  privacy: <Page label="Privacy" title="What Velvet keeps and what it sends" sub="No analytics, no telemetry, no crash reports" path="/privacy" />,
  shortcuts: <Page label="Keyboard shortcuts" title="All the keys" sub="For the player and for the app" path="/shortcuts" visual={<Keys />} />,
  memory: <Page label="Memory" title="How Velvet stays light" sub="The decisions that keep memory low, with the measurements" path="/memory" visual={<Chart />} />,
};

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 } });
for (const [name, card] of Object.entries(cards)) {
  await page.setContent(`<!doctype html><style>${css}</style>${renderToStaticMarkup(card)}`, { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  await page.screenshot({ path: join(root, 'public/og', `${name}.jpg`), type: 'jpeg', quality: 84 });
  console.log(`public/og/${name}.jpg`);
}
await browser.close();
