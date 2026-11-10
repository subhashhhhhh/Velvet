import fs from 'node:fs';
import path from 'node:path';

// The release manifest that the in-app updater reads. Reading it at build time keeps the
// version and the download links correct after each release without a client request.
const manifest = JSON.parse(
  fs.readFileSync(path.resolve(process.cwd(), '../updates/latest.json'), 'utf8'),
) as { version: string; tag: string; archives: Record<string, { size: number }> };

export const repo = 'https://github.com/subhashhhhhh/Velvet';
export const version = manifest.version;
const base = `${repo}/releases/download/${manifest.tag}`;
export const downloads = {
  appleSilicon: `${base}/Velvet-${manifest.version}-AppleSilicon.dmg`,
  intel: `${base}/Velvet-${manifest.version}-Intel.dmg`,
};
export const brew = 'brew install --cask subhashhhhhh/velvet/velvet';

// Memory figures, in MB ("Memory" in Activity Monitor).
// `compare` is the maintainer's measurement from the README: the same 1440p video on one Mac.
// `sequoia` was measured on macOS 15.8 on an M1 MacBook Air, two minutes into Big Buck Bunny
// at 60 fps. At 1080p the figure rose during a ten-minute video; see the note on the page.
export const memory = {
  axisMax: 1500,
  compare: [
    { name: 'youtube.com in Safari', mb: 1400, velvet: false },
    { name: 'Velvet', mb: 360, velvet: true },
  ],
  sequoia: [
    { name: '1080p', mb: 172 },
    { name: '4K', mb: 292 },
  ],
};

// The same bookmarklet that Settings › General copies (SettingsView.swift).
export const bookmarklet =
  "javascript:(()=>{document.querySelector('video')?.pause();location.href='velvet://open?url='+encodeURIComponent(location.href)})()";

// Every service that the app connects to (README §3).
export const services = [
  {
    name: 'YouTube and Google',
    sends: 'Your session cookies and your searches',
    why: 'Feeds, search, videos, comments, notifications and account actions',
    optional: false,
  },
  {
    name: 'GitHub',
    sends: 'No personal data',
    why: 'Downloads of yt-dlp and its JavaScript runtime, the daily update check, and the list of AI channels (only with the AI filter)',
    optional: false,
  },
  {
    name: 'SponsorBlock',
    sends: 'Four characters of a hash of the video ID. The service cannot find which video you watch',
    why: 'Segments to skip',
    optional: true,
  },
  { name: 'DeArrow titles', sends: 'Four characters of a hash of the video ID', why: 'Better titles', optional: true },
  {
    name: 'DeArrow thumbnails',
    sends: 'The video ID. This service can see which videos you look at',
    why: 'Better thumbnails',
    optional: true,
  },
  { name: 'Return YouTube Dislike', sends: 'The video ID', why: 'Dislike counts', optional: true },
];
