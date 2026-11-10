import fs from 'node:fs';
import path from 'node:path';
import { marked } from 'marked';
import { version as latest } from './data';

// The changelog writes itself: each release has its notes in docs/releases/<version>.md,
// and Cloudflare Pages builds the site again on each push. So a release shows here with
// no change to the site. The dates come from GitHub's release list at build time; if
// GitHub does not answer, the page shows the notes without dates.

export type Release = { version: string; date: string | null; notesHtml: string };

const repoApi = 'https://api.github.com/repos/subhashhhhhh/Velvet/releases?per_page=100';
const notesDir = path.resolve(process.cwd(), '../docs/releases');

const parts = (v: string) => v.split('.').map(Number);
const compare = (a: string, b: string) => {
  const [x, y] = [parts(a), parts(b)];
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] ?? 0) - (y[i] ?? 0);
    if (d) return d;
  }
  return 0;
};

async function publishDates(): Promise<Map<string, string>> {
  try {
    const res = await fetch(repoApi, {
      headers: { 'User-Agent': 'velvet-site-build', Accept: 'application/vnd.github+json' },
      signal: AbortSignal.timeout(8000),
    });
    if (!res.ok) throw new Error(`GitHub ${res.status}`);
    const list = (await res.json()) as { tag_name: string; published_at: string; draft: boolean }[];
    return new Map(list.filter((r) => !r.draft).map((r) => [r.tag_name.replace(/^v/, ''), r.published_at]));
  } catch (e) {
    console.warn(`[changelog] No release dates: ${e}`);
    return new Map();
  }
}

export async function releases(): Promise<Release[]> {
  const dates = await publishDates();
  const versions = fs
    .readdirSync(notesDir)
    .filter((f) => f.endsWith('.md'))
    .map((f) => f.slice(0, -3))
    // Notes are committed before the release is published. The manifest's version is
    // the newest published one, so later notes wait.
    .filter((v) => compare(v, latest) <= 0)
    .sort((a, b) => compare(b, a));
  return Promise.all(
    versions.map(async (version) => {
      const text = fs.readFileSync(path.join(notesDir, `${version}.md`), 'utf8');
      // The first heading repeats the version, which the page shows beside the notes.
      const body = text.replace(/^# .*\n+/, '').trim();
      return { version, date: dates.get(version) ?? null, notesHtml: await marked.parse(body) };
    }),
  );
}

export const formatDate = (iso: string) =>
  new Date(iso).toLocaleDateString('en-GB', { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' });
