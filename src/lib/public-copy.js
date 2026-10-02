// Public store details shared by the homepage, contact page and product page.
export const STORE = {
  ADDRESS_ZH: '嘉義市西區蘭井街421號',
  ADDRESS_EN: 'No. 421, Lanjing St., West Dist., Chiayi City',
  PHONE: '0978-918-737',
  EMAIL: 'rosa12345@gmail.com',
  LINE_URL: 'https://line.me/R/ti/p/@258llual',
  LINE_ID: '@258llual',
  WECHAT_ID: '',
  FACEBOOK_URL: '',
  FACEBOOK_NAME: '柔療髮浴 ROU SPA',
};

export function hoursText(settings, lang = 'zh') {
  if (!Number.isInteger(settings?.opening_minute) || !Number.isInteger(settings?.closing_minute))
    return lang === 'en' ? 'Contact us to confirm opening hours.' : '請聯絡門店確認營業時間。';
  const time = n => `${String(Math.floor(n / 60) % 24).padStart(2, '0')}:${String(n % 60).padStart(2, '0')}`;
  return `${time(settings.opening_minute)}–${time(settings.closing_minute)}${settings.closing_minute >= 1440 ? (lang === 'en' ? ' (next day)' : '（翌日）') : ''}`;
}

export const statusNamesEn = {pending:'Awaiting confirmation',confirmed:'Confirmed',checked_in:'Checked in',completed:'Completed',cancelled:'Cancelled',no_show:'No-show'};
export const publicName = (item, lang = 'zh') => lang === 'en' ? item?.name_en || item?.name : item?.name;
export const slotLabel = (label, lang = 'zh') => lang === 'en' ? label?.replace(/^翌日\s*/, 'Next day ') : label;
