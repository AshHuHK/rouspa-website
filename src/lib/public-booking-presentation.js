import { businessTimeText } from './public-copy.js';

export function bookingDayClock(minutes, lang = 'zh') {
  return businessTimeText(minutes, lang).replace(/^翌日\s*/, '翌').replace(/^Next day\s*/, '↳');
}

export function bookingDayHours(day, lang = 'zh') {
  if (!Number.isInteger(day?.start_minute) || !Number.isInteger(day?.end_minute)) return '';
  return `${businessTimeText(day.start_minute, lang)}–${businessTimeText(day.end_minute, lang)}`;
}

// A calendar cell's accessible name includes its month and full shift range.
// The compact visual cell is not a separate source of availability truth.
export function bookingDayLabel(date, day, { lang = 'zh', method = 'any' } = {}) {
  const en = lang === 'en';
  const status = { open: en ? 'Available' : '可預約', full: en ? 'Full' : '已滿', past: en ? 'Past date' : '已過日期', off: en ? 'Unavailable' : '休班／不可預約' };
  const label = `${date} · ${status[day?.status] || status.off}`;
  if (day?.status !== 'open') return label;
  if (method === 'staff') {
    const hours = bookingDayHours(day, lang);
    return hours ? `${label} · ${en ? 'Shift hours' : '上班時段'} ${hours}` : label;
  }
  return `${label} · ${Number(day.available_staff) || 0} ${en ? 'available' : '位可約'}`;
}
