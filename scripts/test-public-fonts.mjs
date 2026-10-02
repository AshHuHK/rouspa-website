import { readFile, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
const root = new URL('../', import.meta.url);
const manifest = JSON.parse(await readFile(new URL('public/fonts/manifest.json', root)));
for (const [name, font] of Object.entries(manifest)) {
  const data = await readFile(new URL('public/fonts/' + name, root));
  assert.equal(data.subarray(0, 4).toString(), 'wOF2', 'Font must be WOFF2: ' + name);
  assert.equal(createHash('sha256').update(data).digest('hex'), font.sha256, 'Font and coverage manifest must match: ' + name);
  assert(font.weight[0] <= 300 && font.weight[1] >= 700, 'Font must cover all public weights');
}
const covered = new Set(manifest['rou-serif-tc-v1.woff2'].codepoints);
async function checkDirectory(url) {
  for (const file of await readdir(url, { withFileTypes: true })) {
    const path = new URL(file.name + (file.isDirectory() ? '/' : ''), url);
    if (file.isDirectory()) await checkDirectory(path);
    else if (/\.(jsx?|css)$/.test(file.name)) {
      const source = await readFile(path, 'utf8');
      for (const character of source.match(/\p{Script=Han}/gu) || []) {
        assert(covered.has(character.codePointAt(0)), `Missing Chinese glyph ${character} in ${path.pathname}; regenerate public fonts.`);
      }
    }
  }
}
await checkDirectory(new URL('src/', root));
const html = await readFile(new URL('index.html', root), 'utf8');
assert(!/fonts\.googleapis\.com|fonts\.gstatic\.com/.test(html), 'Public fonts must not depend on split external font delivery');
assert(html.includes('rel="preload" href="/fonts/rou-serif-tc-v1.woff2"'), 'Critical Chinese font is preloaded');
console.log('PASS: public WOFF2 integrity, static Chinese glyph coverage, variable weights and local preload.');
