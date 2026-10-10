import { readFile } from 'node:fs/promises';
import { routeFromLocation } from '../src/lib/seo.js';
import { buildStructuredData, PAGE_SEO } from '../src/lib/seo-content.js';
import { servicePageHtml } from '../src/lib/service-content.js';

let assertions = 0;
const check = (condition, message) => {
  assertions += 1;
  if (!condition) throw new Error(`SEO test failed: ${message}`);
};

const [index, shop, contact, services, sitemap, robots, vercel, app] = await Promise.all([
  readFile(new URL('../index.html', import.meta.url), 'utf8'),
  readFile(new URL('../shop/index.html', import.meta.url), 'utf8'),
  readFile(new URL('../contact/index.html', import.meta.url), 'utf8'),
  readFile(new URL('../services/index.html', import.meta.url), 'utf8'),
  readFile(new URL('../public/sitemap.xml', import.meta.url), 'utf8'),
  readFile(new URL('../public/robots.txt', import.meta.url), 'utf8'),
  readFile(new URL('../vercel.json', import.meta.url), 'utf8'),
  readFile(new URL('../src/App.jsx', import.meta.url), 'utf8'),
]);

const urls = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map(match => match[1]);
check(urls.length === 4, 'sitemap contains the four public canonical pages');
check(urls.includes('https://www.rouspa.tw/'), 'sitemap includes the homepage');
check(urls.includes('https://www.rouspa.tw/shop/'), 'sitemap includes the product page');
check(urls.includes('https://www.rouspa.tw/contact/'), 'sitemap includes the contact page');
check(urls.includes('https://www.rouspa.tw/services/'), 'sitemap includes the head-care service page');
check(urls.every(url => !url.includes('#')), 'sitemap does not contain hash routes');
check(urls.every(url => !/(admin|member|lookup|manage|review)/.test(url)), 'sitemap excludes private pages');
check(/Sitemap: https:\/\/www\.rouspa\.tw\/sitemap\.xml/.test(robots), 'robots.txt points to the canonical sitemap');
for (const path of ['admin', 'member', 'lookup', 'manage', 'review']) check(robots.includes(`Disallow: /${path}/`), `robots.txt blocks the ${path} clean path`);

check(index.includes('<link rel="canonical" href="https://www.rouspa.tw/"'), 'homepage has a canonical URL');
check(index.includes('<title>嘉義頭療｜柔療髮浴 ROU SPA・頭皮養護與髮浴</title>'), 'homepage title remains unchanged');
check(index.includes('<meta name="description" content="柔療髮浴位於嘉義市西區，主打「中式頭療」，提供頭皮養護與肌膚調理、頭部按摩、肩頸放鬆。溫和水療洗護潔淨頭皮、舒緩疲勞，滿足日常保養與放鬆需求。立即查看療程與線上預約。"'), 'homepage uses the approved meta description');
check(index.includes('property="og:image" content="https://www.rouspa.tw/rou-spa-logo.jpg"'), 'homepage has the supplied logo as its absolute social image');
check(index.includes('name="twitter:card" content="summary_large_image"'), 'Twitter large-card metadata exists');
const jsonLd = index.match(/<script type="application\/ld\+json" id="rouspa-structured-data">([\s\S]*?)<\/script>/)?.[1];
check(Boolean(jsonLd), 'LocalBusiness JSON-LD exists');
const graph = JSON.parse(jsonLd)['@graph'];
const business = graph.find(item => Array.isArray(item['@type']) && item['@type'].includes('DaySpa'));
check(business?.['@type']?.includes('LocalBusiness'), 'business schema explicitly includes LocalBusiness');
check(business?.address?.streetAddress === '蘭井街421號', 'LocalBusiness contains the public store address');
check(business?.telephone === '+886978918737', 'LocalBusiness contains a normalized telephone number');
check(business?.logo === 'https://www.rouspa.tw/rou-spa-logo.jpg', 'LocalBusiness logo uses the supplied brand image');
check(business?.sameAs?.includes('https://www.facebook.com/share/19Wj9WjiiY/') && business.sameAs.includes('https://www.instagram.com/rouliao__spa/'), 'LocalBusiness links the supplied Facebook and Instagram profiles without tracking parameters');
check(business?.openingHoursSpecification?.length === 7 && business.openingHoursSpecification.every(row => row.opens === '10:00' && row.closes === '22:00'), 'static LocalBusiness hours are 10:00–22:00 every day');
check(!business.priceRange, 'static metadata does not freeze mutable prices');
check((app.match(/<h1\b/g) || []).length === 1 && app.includes('aria-label={lang === "zh" ? "嘉義中式頭療｜柔療髮浴 ROU SPA"'), 'homepage has one semantically named H1 while preserving the visible hero copy');
check(app.includes('<h2 style={{ fontSize: lang === "zh"') && app.includes('<h3 className="service-name">{serviceMenuTitle(service,lang)}</h3>'), 'homepage keeps H2 sections with one H3 menu heading per main treatment');

JSON.parse(vercel);
check(shop.includes('<link rel="canonical" href="https://www.rouspa.tw/shop/"'), 'product HTML has a static product canonical');
check(shop.includes('<title>柔療好物選｜柔療髮浴 ROU SPA 嘉義</title>'), 'product HTML has a static product title');
check(contact.includes('<link rel="canonical" href="https://www.rouspa.tw/contact/"'), 'contact HTML has a static contact canonical');
check(contact.includes('<title>聯繫柔療髮浴｜嘉義頭療預約與門店資訊</title>'), 'contact HTML has a static contact title');
check(routeFromLocation({ pathname: '/services/', hash: '' }) === 'services', 'router recognizes the service landing page');
check(routeFromLocation({ pathname: '/shop/', hash: '' }) === 'shop', 'router recognizes the product clean URL');
check(routeFromLocation({ pathname: '/shop/', hash: '', search: '?utm_source=facebook' }) === 'shop' && PAGE_SEO.shop.canonical === '/shop/', 'tracking parameters do not change the self-referencing product canonical');
check(routeFromLocation({ pathname: '/contact/', hash: '' }) === 'contact', 'router recognizes the contact clean URL');
check(routeFromLocation({ pathname: '/', hash: '#admin' }) === 'admin', 'router keeps the private admin route');
check(routeFromLocation({ pathname: '/', hash: '#review/private-token' }) === 'review', 'router keeps private review links');

check(services.includes(`<title>${PAGE_SEO.services.zh.title}</title>`), 'service page has its own static title');
check(services.includes('href="https://www.rouspa.tw/services/"'), 'service page has its own canonical');
check((services.match(/<h1>/g) || []).length === 1, 'service article has one crawlable H1 before JavaScript');
check(services.includes('嘉義頭療，從頭開始的柔和養護') && services.includes('<details><summary>'), 'static article includes local service copy and readable FAQs');
check(services.includes('href="/#booking"') && services.includes('href="/#services"'), 'article links to live treatments and booking');

const catalog = {
  website_services: [
    { name: '45分方子', duration_minutes: 45, price_cents: 120000, category_code: 'duration_45', status: 'active' },
    { name: '120分全息', duration_minutes: 120, price_cents: 320000, category_code: 'duration_120', status: 'active' },
    { name: '不公開', duration_minutes: 90, price_cents: 100, category_code: 'duration_90', status: 'active', website_visible: false },
    { name: '已封存', duration_minutes: 90, price_cents: 100, category_code: 'duration_90', status: 'active', active: false },
    { name: '草稿', duration_minutes: 90, price_cents: 100, category_code: 'duration_90', status: 'draft' },
    { name: '加購', duration_minutes: 45, price_cents: 10000, category_code: 'add_on', status: 'active' },
  ],
  business_hours: [
    { weekday: 1, is_open: true, opening_minute: 600, closing_minute: 1560 },
    { weekday: 2, is_open: false },
    { weekday: 3, is_open: true, opening_minute: 600 },
    { weekday: 4, is_open: true, opening_minute: 0, closing_minute: 2880 },
  ],
  today_hours: { source: 'override', is_open: false },
};
const liveGraph = buildStructuredData('services', catalog)['@graph'];
const liveBusiness = liveGraph.find(item => item['@id']?.endsWith('/#business'));
const service = liveGraph.find(item => item['@type'] === 'Service');
check(liveBusiness.priceRange === 'NT$1,200–NT$3,200', 'price range converts cents to TWD and excludes hidden/inactive/add-on treatments');
check(liveBusiness.openingHoursSpecification.length === 7 && liveBusiness.openingHoursSpecification.every(row => row.opens === '10:00' && row.closes === '22:00'), 'live LocalBusiness keeps the official weekly SEO hours');
check(liveBusiness.specialOpeningHoursSpecification[0].opens === '00:00', 'today closure is reflected in special opening hours');
check(service.hasOfferCatalog.itemListElement.length === 2, 'offers use only currently public main treatments');
check(service.hasOfferCatalog.itemListElement[0].price === 1200 && service.hasOfferCatalog.itemListElement[0].priceCurrency === 'TWD', 'offer currency/unit matches the visible menu');
const liveHtml = servicePageHtml('zh', catalog);
check(liveHtml.includes('NT$1,200') && !liveHtml.includes('已封存'), 'visible article prices match schema and exclude inactive items');
const updated = structuredClone(catalog);
updated.website_services[0].price_cents = 150000;
updated.business_hours[0].opening_minute = 660;
const updatedBusiness = buildStructuredData('home', updated)['@graph'][1];
check(updatedBusiness.priceRange === 'NT$1,500–NT$3,200' && updatedBusiness.openingHoursSpecification[0].opens === '10:00', 'changed backend prices update metadata while official SEO hours remain stable');
check(!JSON.stringify(liveGraph).includes('aggregateRating'), 'no invented ratings');
check(servicePageHtml('en', catalog).includes('Head care in Chiayi') && buildStructuredData('services', catalog, 'en')['@graph'][2].inLanguage === 'en', 'English article and metadata use the selected language');
check(!servicePageHtml('zh', {website_services:[{name:'<img src=x onerror=alert(1)>',status:'active',duration_minutes:45,price_cents:100}]}).includes('<img src=x'), 'backend text is escaped in the service article');

console.log(`PASS: ${assertions} technical SEO assertions (sitemap, robots, metadata, structured data, clean routes and private exclusions).`);
