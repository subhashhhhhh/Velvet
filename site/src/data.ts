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
