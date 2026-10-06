const ORIGIN = 'https://www.rouspa.tw';
const IMAGE = `${ORIGIN}/og-image.jpg`;

const COPY = {
  home: {
    zh: {
      title: '柔療髮浴 ROU SPA｜嘉義東方頭療・經絡舒緩',
      description: '柔療髮浴 ROU SPA 位於嘉義市西區蘭井街421號，提供東方頭療、經絡舒緩與養生髮浴。查看療程、技師與營業資訊，立即線上預約。',
    },
    en: {
      title: 'ROU SPA Chiayi | Head therapy and meridian relaxation',
      description: 'Head therapy, meridian relaxation and wellness hair bathing in West District, Chiayi. View treatments, therapists and opening information, then book online.',
    },
    canonical: '/',
  },
  shop: {
    zh: {
      title: '柔療好物選｜柔療髮浴 ROU SPA 嘉義',
      description: '瀏覽柔療髮浴門店精選養生、頭皮與居家保養商品；價格、分類與門店庫存即時更新。',
    },
    en: {
      title: 'Curated wellness products | ROU SPA Chiayi',
      description: 'Browse wellness, scalp-care and home-care products curated by ROU SPA, with current store pricing and availability.',
    },
    canonical: '/shop/',
  },
  contact: {
    zh: {
      title: '聯繫柔療髮浴｜嘉義頭療預約與門店資訊',
      description: '柔療髮浴 ROU SPA 位於嘉義市西區蘭井街421號。查看電話、LINE、營業時間與交通資訊。',
    },
    en: {
      title: 'Contact ROU SPA | Chiayi store information',
      description: 'Find ROU SPA at No. 421, Lanjing St., West District, Chiayi City. View phone, LINE, opening hours and directions.',
    },
    canonical: '/contact/',
  },
};

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
    return;
  }

  const page = COPY[route] || COPY.home;
  const copy = page[lang] || page.zh;
  const canonical = `${ORIGIN}${page.canonical}`;
  document.title = copy.title;
  document.documentElement.lang = lang === 'en' ? 'en' : 'zh-Hant';
  setCanonical(page.canonical);
  upsertMeta('meta[name="description"]', { name: 'description', content: copy.description });
  upsertMeta('meta[name="robots"]', { name: 'robots', content: 'index, follow, max-image-preview:large' });
  upsertMeta('meta[name="googlebot"]', { name: 'googlebot', content: 'index, follow, max-image-preview:large' });
  upsertMeta('meta[property="og:title"]', { property: 'og:title', content: copy.title });
  upsertMeta('meta[property="og:description"]', { property: 'og:description', content: copy.description });
  upsertMeta('meta[property="og:url"]', { property: 'og:url', content: canonical });
  upsertMeta('meta[property="og:image"]', { property: 'og:image', content: IMAGE });
  upsertMeta('meta[property="og:locale"]', { property: 'og:locale', content: lang === 'en' ? 'en_US' : 'zh_TW' });
  upsertMeta('meta[name="twitter:title"]', { name: 'twitter:title', content: copy.title });
  upsertMeta('meta[name="twitter:description"]', { name: 'twitter:description', content: copy.description });
  upsertMeta('meta[name="twitter:image"]', { name: 'twitter:image', content: IMAGE });
}
