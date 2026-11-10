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

// Memory figures, measured by the maintainer with Activity Monitor's "Memory" value.
export const memory = {
  headline: 'A quarter of the memory.',
  browserLabel: 'youtube.com in Safari',
  browser: 1400,
  velvet: 360,
  note: 'The same 1440p video on the same Mac. Memory changes with the video, the quality and the macOS version; your numbers can be different.',
  stats: [
    { value: 160, unit: 'MB', label: 'Velvet with a 1080p video, on macOS 15.' },
    { value: 280, unit: 'MB', label: 'Velvet with a 4K video, on macOS 15.' },
    { value: 0, unit: '', label: 'Analytics, telemetry or crash reports.' },
  ],
};
