import { ORIGIN, SEO_IMAGE as IMAGE, PAGE_SEO as COPY, buildStructuredData } from './seo-content.js';

let publicCatalog = null;

const PRIVATE_TITLES = {
  admin: { zh: '門店管理後台｜柔療髮浴', en: 'Store administration | ROU SPA' },
  member: { zh: '會員中心｜柔療髮浴', en: 'Member centre | ROU SPA' },
  lookup: { zh: '查詢與管理預約｜柔療髮浴', en: 'Find and manage booking | ROU SPA' },
  manage: { zh: '私人預約管理｜柔療髮浴', en: 'Private booking management | ROU SPA' },
  review: { zh: '療程評價｜柔療髮浴', en: 'Treatment review | ROU SPA' },
};

function upsertMeta(selector, attributes) {
  let element = document.head.querySelector(selector);
  if (!element) {
    element = document.createElement('meta');
    document.head.appendChild(element);
  }
  Object.entries(attributes).forEach(([name, value]) => element.setAttribute(name, value));
  return element;
}

function removeCanonical() {
  document.head.querySelector('link[rel="canonical"]')?.remove();
}

function setCanonical(path) {
  let link = document.head.querySelector('link[rel="canonical"]');
  if (!link) {
    link = document.createElement('link');
    link.rel = 'canonical';
    document.head.appendChild(link);
  }
  link.href = `${ORIGIN}${path}`;
}

export function routeFromLocation(location = window.location) {
  const hash = location.hash || '';
  if (hash === '#admin') return 'admin';
  if (hash === '#member') return 'member';
  if (hash === '#lookup') return 'lookup';
  if (hash.startsWith('#manage/')) return 'manage';
  if (hash.startsWith('#review/')) return 'review';
  if (hash === '#shop') return 'shop';
  if (hash === '#contact') return 'contact';
  const path = (location.pathname || '/').replace(/\/+$/, '') || '/';
  if (path === '/shop') return 'shop';
  if (path === '/contact') return 'contact';
  if (path === '/services') return 'services';
  return 'home';
}

export function applySeo(route, lang = 'zh') {
  const privateCopy = PRIVATE_TITLES[route];
  if (privateCopy) {
    document.title = privateCopy[lang] || privateCopy.zh;
    document.documentElement.lang = lang === 'en' && route !== 'admin' ? 'en' : 'zh-Hant';
    upsertMeta('meta[name="robots"]', { name: 'robots', content: 'noindex, nofollow, noarchive' });
    upsertMeta('meta[name="googlebot"]', { name: 'googlebot', content: 'noindex, nofollow, noarchive' });
    removeCanonical();
    document.getElementById('rouspa-structured-data')?.remove();
    return;
  }

  setStructuredData(route, lang);
  const page = COPY[route] || COPY.home;
  const copy = page[lang] || page.zh;
  const canonical = `${ORIGIN}${page.canonical}`;
  document.title = copy.title;
  document.documentElement.lang = lang === 'en' ? 'en' : 'zh-Hant';
  setCanonical(page.canonical);
  upsertMeta('meta[name="description"]', { name: 'description', content: copy.metaDescription || copy.description });
  upsertMeta('meta[name="robots"]', { name: 'robots', content: 'index, follow, max-image-preview:large' });
  upsertMeta('meta[name="googlebot"]', { name: 'googlebot', content: 'index, follow, max-image-preview:large' });
  upsertMeta('meta[property="og:title"]', { property: 'og:title', content: copy.title });
  upsertMeta('meta[property="og:description"]', { property: 'og:description', content: copy.description });
  upsertMeta('meta[property="og:url"]', { property: 'og:url', content: canonical });
  upsertMeta('meta[property="og:image"]', { property: 'og:image', content: IMAGE });
  upsertMeta('meta[property="og:image:alt"]', { property: 'og:image:alt', content: lang === 'en' ? 'ROU SPA brand logo' : '柔療髮浴 ROU SPA 品牌標誌' });
  upsertMeta('meta[property="og:locale"]', { property: 'og:locale', content: lang === 'en' ? 'en_US' : 'zh_TW' });
  upsertMeta('meta[name="twitter:title"]', { name: 'twitter:title', content: copy.title });
  upsertMeta('meta[name="twitter:description"]', { name: 'twitter:description', content: copy.description });
  upsertMeta('meta[name="twitter:image"]', { name: 'twitter:image', content: IMAGE });
  upsertMeta('meta[name="twitter:image:alt"]', { name: 'twitter:image:alt', content: lang === 'en' ? 'ROU SPA brand logo' : '柔療髮浴 ROU SPA 品牌標誌' });
}

function setStructuredData(route, lang) {
  let script = document.getElementById('rouspa-structured-data');
  if (!script) { script = document.createElement('script'); script.type = 'application/ld+json'; script.id = 'rouspa-structured-data'; document.head.appendChild(script); }
  script.textContent = JSON.stringify(buildStructuredData(route, publicCatalog, lang));
}

export function updateBusinessSeo(catalog, route, lang = 'zh') {
  publicCatalog = catalog;
  if (!PRIVATE_TITLES[routeFromLocation()] && routeFromLocation() === route) setStructuredData(route, lang);
}
