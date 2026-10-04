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

export function businessTimeText(minutes, lang = 'zh') {
  if (!Number.isInteger(minutes)) return '';
  const clock = `${String(Math.floor(minutes / 60) % 24).padStart(2, '0')}:${String(minutes % 60).padStart(2, '0')}`;
  return `${minutes >= 1440 ? (lang === 'en' ? 'Next day ' : '翌日 ') : ''}${clock}`;
}

export function hoursText(settings, lang = 'zh', businessHours = [], todayHours = null) {
  const time = n => businessTimeText(n, lang);
  const ordered = [1,2,3,4,5,6,0].map(day => businessHours.find(row => row.weekday === day)).filter(Boolean);
  let weekly = '';
  if (ordered.length === 7) {
    const dayNames = lang === 'en' ? ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'] : ['週日','週一','週二','週三','週四','週五','週六'];
    const key = row => row.is_open ? `${row.opening_minute}-${row.closing_minute}` : 'closed';
    const groups = [];
    ordered.forEach(row => { const last = groups.at(-1); if (last && key(last.rows[0]) === key(row)) last.rows.push(row); else groups.push({ rows:[row] }); });
    weekly = groups.map(({rows}) => { const first=dayNames[rows[0].weekday],last=dayNames[rows.at(-1).weekday],days=rows.length===1?first:`${first}–${last}`,row=rows[0]; return `${days} ${row.is_open?`${time(row.opening_minute)}–${time(row.closing_minute)}`:(lang==='en'?'closed':'休息')}`; }).join(lang === 'en' ? '; ' : ' · ');
  } else if (Number.isInteger(settings?.opening_minute) && Number.isInteger(settings?.closing_minute)) {
    weekly = `${time(settings.opening_minute)}–${time(settings.closing_minute)}`;
  }
  if (!weekly) return lang === 'en' ? 'Contact us to confirm opening hours.' : '請聯絡門店確認營業時間。';
  if (todayHours?.source === 'override') {
    const today = todayHours.is_open ? `${lang === 'en'?'Today':'今日'} ${time(todayHours.opening_minute)}–${time(todayHours.closing_minute)}` : (lang === 'en' ? 'Closed today' : '今日休假');
    return `${today}${todayHours.note?`（${todayHours.note}）`:''} · ${weekly}`;
  }
  return weekly;
}

export const statusNamesEn = {pending:'Awaiting confirmation',confirmed:'Confirmed',checked_in:'Checked in',completed:'Completed',cancelled:'Cancelled',no_show:'No-show'};
export const publicName = (item, lang = 'zh') => lang === 'en' ? item?.name_en || item?.name : item?.name;
export const publicTitle = (item, lang = 'zh') => lang === 'en' ? item?.title_en || item?.therapist_title_en || item?.title || item?.therapist_title : item?.title || item?.therapist_title;
export const therapistLabel = (item, lang = 'zh') => [publicName(item, lang) || item?.therapist, publicTitle(item, lang)].filter(Boolean).join(' · ');
export const slotLabel = (label, lang = 'zh') => lang === 'en' ? label?.replace(/^翌日\s*/, 'Next day ') : label;
