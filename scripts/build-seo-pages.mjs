import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { ORIGIN, PAGE_SEO, buildStructuredData } from '../src/lib/seo-content.js';
import { escapeHtml, servicePageHtml } from '../src/lib/service-content.js';

const root = resolve(import.meta.dirname, '..');
const template = await readFile(resolve(root, 'index.html'), 'utf8');
function pageHtml(route, page) {
  const copy = page.zh;
  let html = template.replace(/<title>[^<]*<\/title>/, `<title>${escapeHtml(copy.title)}</title>`)
    .replace(/<link rel="canonical" href="[^"]*"\s*\/>/, `<link rel="canonical" href="${ORIGIN}${page.canonical}" />`)
    .replace(/<script type="application\/ld\+json" id="rouspa-structured-data">[\s\S]*?<\/script>/,
      `<script type="application/ld+json" id="rouspa-structured-data">${JSON.stringify(buildStructuredData(route)).replace(/</g, '\\u003c')}</script>`);
  for (const [attribute, name, value] of [
    ['name', 'description', copy.metaDescription || copy.description], ['property', 'og:title', copy.title], ['property', 'og:description', copy.description],
    ['property', 'og:url', `${ORIGIN}${page.canonical}`], ['name', 'twitter:title', copy.title], ['name', 'twitter:description', copy.description],
  ]) html = html.replace(new RegExp(`<meta ${attribute}="${name}" content="[^"]*"\\s*\\/>`), `<meta ${attribute}="${name}" content="${escapeHtml(value)}" />`);
  if (route === 'services') {
    html = html.replace('<div id="root"></div>', `<div id="root"><div class="care-page">${servicePageHtml()}</div></div>`)
      .replace('</head>', '<link rel="stylesheet" href="/src/services.css" />\n  </head>');
  }
  return html;
}
for (const [route, page] of Object.entries(PAGE_SEO)) {
  const directory = route === 'home' ? root : resolve(root, route);
  await mkdir(directory, { recursive: true });
  await writeFile(resolve(directory, 'index.html'), pageHtml(route, page));
}
