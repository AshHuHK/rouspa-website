import { readFile } from 'node:fs/promises';
import { routeFromLocation } from '../src/lib/seo.js';

let assertions = 0;
const check = (condition, message) => {
  assertions += 1;
  if (!condition) throw new Error(`SEO test failed: ${message}`);
};

const [index, sitemap, robots, vercel] = await Promise.all([
  readFile(new URL('../index.html', import.meta.url), 'utf8'),
  readFile(new URL('../public/sitemap.xml', import.meta.url), 'utf8'),
  readFile(new URL('../public/robots.txt', import.meta.url), 'utf8'),
  readFile(new URL('../vercel.json', import.meta.url), 'utf8'),
]);

const urls = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map(match => match[1]);
check(urls.length === 3, 'sitemap contains exactly the three public canonical pages');
check(urls.includes('https://www.rouspa.tw/'), 'sitemap includes the homepage');
check(urls.includes('https://www.rouspa.tw/shop/'), 'sitemap includes the product page');
check(urls.includes('https://www.rouspa.tw/contact/'), 'sitemap includes the contact page');
check(urls.every(url => !url.includes('#')), 'sitemap does not contain hash routes');
check(urls.every(url => !/(admin|member|lookup|manage|review)/.test(url)), 'sitemap excludes private pages');
check(/Sitemap: https:\/\/www\.rouspa\.tw\/sitemap\.xml/.test(robots), 'robots.txt points to the canonical sitemap');
for (const path of ['admin', 'member', 'lookup', 'manage', 'review']) check(robots.includes(`Disallow: /${path}/`), `robots.txt blocks the ${path} clean path`);

check(index.includes('<link rel="canonical" href="https://www.rouspa.tw/"'), 'homepage has a canonical URL');
check(index.includes('property="og:image" content="https://www.rouspa.tw/og-image.jpg"'), 'homepage has an absolute social image');
check(index.includes('name="twitter:card" content="summary_large_image"'), 'Twitter large-card metadata exists');
const jsonLd = index.match(/<script type="application\/ld\+json" id="rouspa-structured-data">([\s\S]*?)<\/script>/)?.[1];
check(Boolean(jsonLd), 'LocalBusiness JSON-LD exists');
const graph = JSON.parse(jsonLd)['@graph'];
const business = graph.find(item => Array.isArray(item['@type']) && item['@type'].includes('DaySpa'));
check(business?.address?.streetAddress === '蘭井街421號', 'LocalBusiness contains the public store address');
check(business?.telephone === '+886978918737', 'LocalBusiness contains a normalized telephone number');
check(business?.openingHoursSpecification?.opens === '10:00', 'LocalBusiness contains current opening hours');

const config = JSON.parse(vercel);
check(config.rewrites.some(item => item.source === '/shop/' && item.destination === '/index.html'), 'Vercel serves the product clean URL');
check(config.rewrites.some(item => item.source === '/contact/' && item.destination === '/index.html'), 'Vercel serves the contact clean URL');
check(routeFromLocation({ pathname: '/shop/', hash: '' }) === 'shop', 'router recognizes the product clean URL');
check(routeFromLocation({ pathname: '/contact/', hash: '' }) === 'contact', 'router recognizes the contact clean URL');
check(routeFromLocation({ pathname: '/', hash: '#admin' }) === 'admin', 'router keeps the private admin route');
check(routeFromLocation({ pathname: '/', hash: '#review/private-token' }) === 'review', 'router keeps private review links');

console.log(`PASS: ${assertions} technical SEO assertions (sitemap, robots, metadata, structured data, clean routes and private exclusions).`);
