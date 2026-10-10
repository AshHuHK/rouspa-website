import { STORE, hoursText } from './public-copy.js';
import { publicTreatments } from './seo-content.js';

export const SERVICE_COPY = {
  zh: {
    home: '返回首頁', book: '線上預約', eyebrow: 'HEAD & SCALP CARE · CHIAYI',
    title: '嘉義頭療，從頭開始的柔和養護',
    intro: '柔療髮浴 ROU SPA 位於嘉義市西區，以東方養護的手法結合頭皮清潔、頭肩頸按摩與養生髮浴。讓洗頭成為一段慢下來、放鬆身心的時間。',
    careTitle: '頭療與髮浴，照顧哪些地方？',
    care: [
      ['頭皮清潔與養護', '從頭皮洗淨開始，依所選療程搭配頭皮去角質或植物髮浴，照顧日常清潔與頭皮養護需求。'],
      ['頭部按摩與頭肩頸舒緩', '以手技按摩頭部、肩頸，提供溫和的經絡舒緩，適合想在忙碌生活中放鬆的人。'],
      ['髮浴與感官放鬆', '結合水療、洗淨與手技收尾，在安靜的空間裡體驗東方頭療；各項步驟以所選療程內容為準。'],
    ],
    chooseTitle: '45、90、120分鐘療程怎麼選？',
    durations: [
      ['45', '日常頭療', '想先體驗頭療，或安排一段較短的放鬆時間，可從45分鐘療程開始。'],
      ['90', '進階養護', '希望多一些頭皮養護與舒緩步驟，可比較90分鐘各款植物髮浴的內容。'],
      ['120', '完整體驗', '想留更充裕的時間體驗多項養護步驟，可查看120分方子的完整內容。'],
    ],
    minutes: '分鐘', chooseNote: '另外項目獨立列於療程菜單，可依需求搭配。實際項目、價格與是否開放預約，請以當前菜單為準。',
    menu: '查看完整療程與另外項目', liveTitle: '目前開放的療程', price: '價格', liveNote: '以下為目前公開的主要療程；完整步驟與另外項目請至療程菜單查看。',
    faqTitle: '預約與到店常見問題',
    faq: [
      ['第一次預約需要註冊或綁定電子郵件嗎？', '不需要。選擇療程、技師、日期與時段，再填寫姓名和手機號碼即可預約。首次預約會以這些資料建立顧客檔案，之後可查詢預約或登入會員中心。'],
      ['可以指定按摩師嗎？', '可以在預約流程選擇當日可預約的按摩師，並查看職稱。可選技師及時段依門店排班與現有預約而定。'],
      ['療程分鐘數就是預約占用的時間嗎？', '45、90、120分鐘為療程分類。門店會另預留準備與整理時間，因此預約時段以系統顯示的可用時間為準。'],
      ['頭皮養護、髮浴和另外項目要如何選擇？', '先查看各療程的完整步驟，再選擇合適的時間長度。若不確定植物髮浴或其他項目是否適合，可先透過LINE向門店詢問。'],
    ],
    visitTitle: '在嘉義，留一段時間給自己', visitIntro: '柔療髮浴 ROU SPA｜嘉義市西區蘭井街421號', contact: '營業時間與交通資訊', line: 'LINE 療程諮詢', hours: '營業資訊', footer: '柔療髮浴 ROU SPA · 以柔養生',
  },
  en: {
    home: 'Back to home', book: 'Book online', eyebrow: 'HEAD & SCALP CARE · CHIAYI',
    title: 'Head care in Chiayi, with a gentle touch',
    intro: 'At ROU SPA in West District, Chiayi, Eastern-inspired care brings together scalp cleansing, head and shoulder massage, and wellness hair bathing. Take time to slow down and unwind.',
    careTitle: 'What does a head-care visit include?',
    care: [
      ['Scalp cleansing and care', 'Begin with scalp cleansing. Selected treatments include scalp exfoliation or botanical hair bathing for your everyday care routine.'],
      ['Head, neck and shoulder massage', 'Gentle massage techniques help you relax your head, neck and shoulders in a calm setting.'],
      ['Hair bathing and relaxation', 'Water, cleansing and finishing massage come together in an Eastern-inspired ritual. The included steps depend on your selected treatment.'],
    ],
    chooseTitle: 'Choose your treatment length',
    durations: [
      ['45', 'Everyday head care', 'A shorter visit for your first head-care experience or a brief break in your day.'],
      ['90', 'Extended scalp care', 'Explore a longer ritual with additional care steps and your choice of botanical hair-bathing options.'],
      ['120', 'The full experience', 'Allow more time to experience the wider range of care steps in our full-length ritual.'],
    ],
    minutes: 'minutes', chooseNote: 'Other services are listed separately and can complement your visit. The current menu shows available treatments, prices and booking options.',
    menu: 'View treatments and other services', liveTitle: 'Current treatments', price: 'Price', liveNote: 'These are our currently published main treatments. Visit the full menu for care steps and other services.',
    faqTitle: 'Before your visit',
    faq: [
      ['Do I need an email account to book?', 'No. Choose a treatment, therapist, date and time, then enter your name and phone number. Your first booking creates a customer record so you can look up bookings and access the member centre.'],
      ['Can I choose a massage therapist?', 'You can select an available therapist and view their professional title during booking. Availability depends on the daily roster and existing appointments.'],
      ['Is the treatment length the entire appointment slot?', 'The 45, 90 and 120-minute categories describe treatments. The store reserves additional preparation and cleanup time, so use the available slots shown during booking.'],
      ['How do I choose hair bathing and other services?', 'Compare the care steps and choose a treatment length. Contact us on LINE if you need help choosing a botanical hair bath or another service.'],
    ],
    visitTitle: 'Make time for yourself in Chiayi', visitIntro: `ROU SPA | ${STORE.ADDRESS_EN}`, contact: 'Opening hours and directions', line: 'Ask us on LINE', hours: 'Opening information', footer: 'ROU SPA · Gentle care',
  },
};

export const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character]));

// Build-time HTML and React share the same visible, crawlable service copy.
export function servicePageHtml(lang = 'zh', catalog = null) {
  const t = SERVICE_COPY[lang] || SERVICE_COPY.zh;
  const e = escapeHtml;
  const treatments = publicTreatments(catalog);
  return `<nav class="care-nav" aria-label="${lang === 'en' ? 'Main navigation' : '主要導覽'}"><a class="care-brand" href="/">柔療髮浴 <span>ROU SPA</span></a><a href="/" class="care-back">← ${e(t.home)}</a></nav>
    <main class="care-main">
      <header class="care-intro"><p class="care-eyebrow">${e(t.eyebrow)}</p><h1>${e(t.title)}</h1><p>${e(t.intro)}</p><div class="care-actions"><a class="care-button" href="/#booking">${e(t.book)}</a><a class="care-text-link" href="/#services">${e(t.menu)} ↗</a></div></header>
      <img class="care-photo" src="/og-image.jpg" alt="${lang === 'en' ? 'Hair-bathing care at ROU SPA' : '柔療髮浴的頭療與髮浴服務'}" width="1200" height="630" decoding="async" />
      <section class="care-section"><h2>${e(t.careTitle)}</h2><div class="care-grid">${t.care.map(([title, body], i) => `<article class="care-card"><span class="care-number" aria-hidden="true">0${i + 1}</span><h3>${e(title)}</h3><p>${e(body)}</p></article>`).join('')}</div></section>
      <section class="care-section"><h2>${e(t.chooseTitle)}</h2><div class="care-grid">${t.durations.map(([minutes, title, body]) => `<article class="care-card care-duration"><p class="care-time"><strong>${e(minutes)}</strong> ${e(t.minutes)}</p><h3>${e(title)}</h3><p>${e(body)}</p></article>`).join('')}</div><p class="care-note">${e(t.chooseNote)}</p><a class="care-text-link" href="/#services">${e(t.menu)} →</a></section>
      ${treatments.length ? `<section class="care-section care-current"><h2>${e(t.liveTitle)}</h2><p>${e(t.liveNote)}</p><ul>${treatments.map(service => `<li><span>${e(lang === 'en' ? service.name_en || service.name : service.name)} <small>${e(service.duration_minutes)} ${e(t.minutes)}</small></span><strong>NT$${e((Number(service.price_cents) / 100).toLocaleString('en-US'))}</strong></li>`).join('')}</ul></section>` : ''}
      <section class="care-section care-faq"><h2>${e(t.faqTitle)}</h2>${t.faq.map(([question, answer]) => `<details><summary>${e(question)}</summary><p>${e(answer)}</p></details>`).join('')}</section>
      <section class="care-section care-visit"><p class="care-eyebrow">VISIT ROU SPA</p><h2>${e(t.visitTitle)}</h2><p>${e(t.visitIntro)}</p>${catalog ? `<p class="care-hours">${e(hoursText(catalog.settings, lang, catalog.business_hours, catalog.today_hours))}</p>` : ''}<a class="care-phone" href="tel:+886978918737">${e(STORE.PHONE)}</a><div class="care-actions"><a class="care-button" href="/#booking">${e(t.book)}</a><a class="care-text-link" href="${e(STORE.LINE_URL)}" target="_blank" rel="noopener noreferrer">${e(t.line)} ↗</a></div><a class="care-text-link" href="/contact/">${e(t.contact)} →</a></section>
    </main><footer class="care-footer"><p>${e(t.footer)}</p><a href="/shop/">${lang === 'en' ? 'Wellness products' : '柔療好物選'}</a> · <a href="/contact/">${lang === 'en' ? 'Contact' : '聯繫我們'}</a></footer>`;
}
