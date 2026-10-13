import { readFile, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
const root = new URL('../', import.meta.url);
const manifest = JSON.parse(await readFile(new URL('public/fonts/manifest.json', root)));
const covered = new Set();
for (const [name, font] of Object.entries(manifest)) {
  const data = await readFile(new URL('public/fonts/' + name, root));
  assert.equal(data.subarray(0, 4).toString(), 'wOF2', 'Font must be WOFF2: ' + name);
  assert.equal(createHash('sha256').update(data).digest('hex'), font.sha256, 'Font and coverage manifest must match: ' + name);
  assert(font.weight[0] <= 300 && font.weight[1] >= 700, 'Font must cover all public weights');
  assert(name.startsWith('rou-songti-tc-'), 'Current typeface must use the Source Han derivative');
  assert(font.source.includes('adobe-fonts/source-han-serif'), 'Typeface provenance must be Adobe Source Han Serif');
  for (const cp of font.codepoints) {
    assert(!covered.has(cp), 'Font subsets must have disjoint codepoint ranges');
    covered.add(cp);
  }
}
assert(covered.size >= 20000, 'Future catalogue text needs full Taiwan source coverage, not just static UI characters');
const critical = new Set(manifest['rou-songti-tc-core-v1.woff2'].codepoints);
for (const char of '苦茶籽潔淨髮浴森呼吸柔禾角質調理墨玉烏60天木質萃湯浴薑暖陽鮮薑溫通舒筋') {
  assert(critical.has(char.codePointAt(0)), 'Published treatment character must load with core: ' + char);
}
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
assert(html.includes('rel="preload" href="/fonts/rou-songti-tc-core-v1.woff2"'), 'Critical Chinese font is preloaded');
const faces = await readFile(new URL('src/source-han-fonts.css', root), 'utf8');
for (const name of Object.keys(manifest)) assert(faces.includes('/fonts/' + name), 'Every future glyph subset must have a CSS face');
assert(faces.includes('unicode-range:'), 'Extended glyphs should load on demand');
console.log('PASS: Source Han Serif provenance, WOFF2 integrity, published/core and full Taiwan glyph coverage, variable weights and on-demand subsets.');
