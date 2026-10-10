import { taipeiDate } from './date-range.js';

// Tenure is calculated, never persisted as a number that grows stale. Missing
// dates stay missing; a profile's creation date is not an employment start date.
export function staffTenure(person, today = taipeiDate()) {
  const start = person?.hire_date;
  const end = person?.departed_on && person.departed_on < today ? person.departed_on : today;
  const realDate = value => /^\d{4}-\d{2}-\d{2}$/.test(value || '') && Number.isFinite(Date.parse(`${value}T00:00:00Z`)) && new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) === value;
  if (!realDate(start) || !realDate(end)) return { status: 'missing', hire_date: start || null, as_of: end };
  if (start > end) return { status: person?.departed_on ? 'invalid' : 'not_started', hire_date: start, as_of: end, days: 0, years: 0, months: 0 };
  const [sy, sm, sd] = start.split('-').map(Number), [ey, em, ed] = end.split('-').map(Number);
  let months = (ey - sy) * 12 + em - sm - (ed < sd ? 1 : 0);
  months = Math.max(0, months);
  return { status: 'known', hire_date: start, as_of: end, days: Math.floor((Date.parse(`${end}T00:00:00Z`) - Date.parse(`${start}T00:00:00Z`)) / 86400000), years: Math.floor(months / 12), months: months % 12 };
}

export function tenureLabel(person, today) {
  const value = person?.tenure || staffTenure(person, today);
  if (value.status === 'missing') return '到職日尚未設定';
  if (value.status === 'not_started') return '尚未到職';
  if (value.status === 'invalid') return '請核對到職與離職日期';
  return `${value.years} 年 ${value.months} 個月${person?.departed_on ? '（計至離職日）' : ''}`;
}
