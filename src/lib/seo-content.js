import { STORE } from './public-copy.js';

export const ORIGIN = 'https://www.rouspa.tw';
export const SEO_IMAGE = `${ORIGIN}/rou-spa-logo.jpg`;
export const PAGE_SEO = {
  home: {
    canonical: '/',
    zh: {
      title: '嘉義頭療｜柔療髮浴 ROU SPA・頭皮養護與髮浴',
      description: '柔療髮浴 ROU SPA 位於嘉義市西區蘭井街421號，以東方頭療結合頭皮清潔、頭肩頸按摩與養生髮浴。查看45、90、120分鐘療程、技師排班與今日營業時間，線上預約。',
      metaDescription: '柔療髮浴位於嘉義市西區，主打「中式頭療」，提供頭皮養護與肌膚調理、頭部按摩、肩頸放鬆。溫和水療洗護潔淨頭皮、舒緩疲勞，滿足日常保養與放鬆需求。立即查看療程與線上預約。',
    },
    en: { title: 'ROU SPA Chiayi | Head massage, scalp care & hair bathing', description: 'Discover Eastern-inspired head massage, scalp cleansing and wellness hair bathing at ROU SPA in Chiayi. Explore 45, 90 and 120-minute treatments, opening hours and online booking.' },
  },
  services: {
    canonical: '/services/',
    zh: { title: '嘉義頭療服務｜頭皮養護・頭肩頸按摩・髮浴｜柔療髮浴', description: '認識柔療髮浴的東方頭療、頭皮養護、頭肩頸舒緩與髮浴，了解45、90、120分鐘療程如何選擇、加購項目與預約常見問題。門店位於嘉義市西區蘭井街421號。' },
    en: { title: 'Head massage & scalp-care treatments in Chiayi | ROU SPA', description: 'Explore head massage, scalp care and wellness hair bathing at ROU SPA, Chiayi. Compare 45, 90 and 120-minute treatments and learn how to book your visit.' },
  },
  shop: {
    canonical: '/shop/',
    zh: { title: '柔療好物選｜柔療髮浴 ROU SPA 嘉義', description: '瀏覽柔療髮浴精選養生、頭皮與居家保養商品，查看目前價格與門市供貨狀態，歡迎至嘉義門店選購。' },
    en: { title: 'Curated wellness products | ROU SPA Chiayi', description: 'Browse wellness, scalp-care and home-care products curated by ROU SPA. View current pricing and store availability, then visit our Chiayi store.' },
  },
  contact: {
    canonical: '/contact/',
    zh: { title: '聯繫柔療髮浴｜嘉義頭療預約與門店資訊', description: '柔療髮浴 ROU SPA 位於嘉義市西區蘭井街421號。查看電話、LINE、營業時間與交通資訊，諮詢頭療、髮浴與線上預約。' },
    en: { title: 'Contact ROU SPA | Chiayi store information', description: 'Find ROU SPA at No. 421, Lanjing St., West District, Chiayi City. View phone, LINE, opening hours and directions for head massage and hair bathing.' },
  },
};

const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const clock = minute => `${String(Math.floor(minute / 60) % 24).padStart(2, '0')}:${String(minute % 60).padStart(2, '0')}`;
const validWindow = row => Number.isInteger(row?.opening_minute) && Number.isInteger(row?.closing_minute)
  && row.opening_minute >= 0 && row.opening_minute < 1440 && row.closing_minute > row.opening_minute && // Longer windows cannot be accurately encoded as a single overnight clock range.
  row.closing_minute - row.opening_minute < 1440;

// Only public, published main treatments contribute to the price range/offers.
export function publicTreatments(catalog) {
  return (catalog?.website_services || []).filter(service => service.active !== false && service.status === 'active'
    && service.website_visible !== false && service.category_code !== 'add_on'
    && [45, 90, 120].includes(Number(service.duration_minutes))
    && Number.isFinite(Number(service.price_cents)) && Number(service.price_cents) >= 0);
}

export function buildStructuredData(route = 'home', catalog = null, lang = 'zh') {
  const page = PAGE_SEO[route] || PAGE_SEO.home;
  const copy = page[lang] || page.zh;
  const businessId = `${ORIGIN}/#business`;
  const business = {
    '@type': ['LocalBusiness', 'DaySpa', 'HealthAndBeautyBusiness'], '@id': businessId,
    name: '柔療髮浴 ROU SPA', url: `${ORIGIN}/`, image: SEO_IMAGE, logo: SEO_IMAGE,
    description: lang === 'en' ? 'Chinese-style head therapy, scalp care and hair bathing in Chiayi.' : '柔療髮浴位於嘉義市西區，提供嘉義中式頭療、頭皮養護、頭部按摩與肩頸放鬆。',
    telephone: '+886978918737', email: STORE.EMAIL, currenciesAccepted: 'TWD',
    address: { '@type': 'PostalAddress', streetAddress: '蘭井街421號', addressLocality: '西區', addressRegion: '嘉義市', addressCountry: 'TW' },
    sameAs: [
      'https://www.facebook.com/share/19Wj9WjiiY/',
      'https://www.instagram.com/rouliao__spa/',
      STORE.LINE_URL,
    ],
    hasMap: 'https://www.google.com/maps/search/?api=1&query=' + encodeURIComponent(STORE.ADDRESS_ZH),
  };
  // Keep the LocalBusiness weekly hours at the official SEO value supplied by
  // the store. Same-day closures/special hours can still override one date.
  const hours = DAYS.map((_, weekday) => ({ weekday, is_open: true, opening_minute: 600, closing_minute: 1320 }));
  if (hours.length) business.openingHoursSpecification = hours.map(row => ({
    '@type': 'OpeningHoursSpecification', dayOfWeek: DAYS[row.weekday],
    opens: row.is_open ? clock(row.opening_minute) : '00:00', closes: row.is_open ? clock(row.closing_minute) : '00:00',
  }));
  const today = catalog?.today_hours;
  if (today?.source === 'override' && (today.is_open === false || validWindow(today))) {
    const date = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Taipei', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
    business.specialOpeningHoursSpecification = [{ '@type': 'OpeningHoursSpecification', validFrom: date, validThrough: date,
      opens: today.is_open ? clock(today.opening_minute) : '00:00', closes: today.is_open ? clock(today.closing_minute) : '00:00' }];
  }
  const services = publicTreatments(catalog);
  const prices = services.map(service => Number(service.price_cents)).filter(price => Number.isFinite(price) && price >= 0);
  if (prices.length) business.priceRange = `NT$${(Math.min(...prices) / 100).toLocaleString('en-US')}–NT$${(Math.max(...prices) / 100).toLocaleString('en-US')}`;
  const graph = [
    { '@type': 'WebSite', '@id': `${ORIGIN}/#website`, url: `${ORIGIN}/`, name: '柔療髮浴 ROU SPA', inLanguage: ['zh-Hant', 'en'] },
    business,
    { '@type': 'WebPage', '@id': `${ORIGIN}${page.canonical}#webpage`, url: `${ORIGIN}${page.canonical}`, name: copy.title, description: copy.description,
      inLanguage: lang === 'en' ? 'en' : 'zh-Hant', isPartOf: { '@id': `${ORIGIN}/#website` }, about: { '@id': businessId } },
  ];
  if (route === 'services') {
    graph.push({ '@type': 'Service', '@id': `${ORIGIN}/services/#head-care`, url: `${ORIGIN}/services/`,
      name: lang === 'en' ? 'Head massage, scalp care and hair bathing' : '東方頭療・頭皮養護・髮浴',
      serviceType: lang === 'en' ? 'Head and scalp care' : '頭療與髮浴', provider: { '@id': businessId }, areaServed: { '@type': 'City', name: '嘉義市' },
      ...(services.length ? { hasOfferCatalog: { '@type': 'OfferCatalog', name: lang === 'en' ? 'Treatments' : '頭療療程', itemListElement: services.map(service => ({
        '@type': 'Offer', price: Number(service.price_cents) / 100, priceCurrency: 'TWD', url: `${ORIGIN}/#booking`,
        itemOffered: { '@type': 'Service', name: lang === 'en' ? service.name_en || service.name : service.name, provider: { '@id': businessId } },
      })) } } : {}),
    });
    graph.push({ '@type': 'BreadcrumbList', itemListElement: [
      { '@type': 'ListItem', position: 1, name: lang === 'en' ? 'Home' : '首頁', item: `${ORIGIN}/` },
      { '@type': 'ListItem', position: 2, name: lang === 'en' ? 'Treatments' : '頭療服務', item: `${ORIGIN}/services/` },
    ] });
  }
  return { '@context': 'https://schema.org', '@graph': graph };
}
