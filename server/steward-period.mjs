import { taipeiDate, dateAfter } from '../src/lib/date-range.js';

const labels = { month: '本月', last_month: '上個月', last_30_days: '最近 30 天', last_90_days: '最近 90 天', all: '全部歷史', page: '頁面所選期間', today: '今天', yesterday: '昨天', year: '今年', last_year: '去年', week: '本週', last_week: '上週', custom: '指定期間' };
export class PeriodError extends Error {
 constructor(message) { super(message); this.status = 400; this.code = 'INVALID_RANGE'; }
}
const pad = value => String(value).padStart(2, '0');
const monthStart = (year, month) => `${year}-${pad(month)}-01`;
const monthEnd = (year, month) => new Date(Date.UTC(year, month, 0)).toISOString().slice(0, 10);
function realDate(value) {
 if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value) || value < '1900-01-01' || value > '2100-12-31') return false;
 const instant = new Date(`${value}T00:00:00Z`);
 return Number.isFinite(instant.getTime()) && instant.toISOString().slice(0, 10) === value;
}
function checked(range, legacy = false) {
 if (!range || !realDate(range.from) || !realDate(range.to) || range.from > range.to || (legacy && (Date.parse(range.to) - Date.parse(range.from)) / 86400000 > 366)) {
  throw new PeriodError(legacy ? '請選擇有效日期，頁面期間不超過一年。' : '請使用有效日期，且開始日期不能晚於結束日期。');
 }
 return { from: range.from, to: range.to };
}

// Resolve only a fixed vocabulary. Questions cannot provide SQL, RPC names or
// authorization. Every relative period uses server time in Asia/Taipei.
export function resolveStewardPeriod({ question = '', period, range, scope = 'business' }, now = new Date()) {
 if (!['business', 'page'].includes(scope)) throw new PeriodError('請選擇有效的分析範圍。');
 const today = taipeiDate(now), [year, month] = today.split('-').map(Number);
 let chosen = period ?? (range == null ? 'month' : 'page');
 if (!Object.hasOwn(labels, chosen)) throw new PeriodError('請選擇有效的分析期間。');
 // Reject malformed supplied dates, even when the question selects another period.
 if (range != null) checked(range, chosen === 'page');
 let explicit;
 const dates = [...question.matchAll(/(?<!\d)(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?!\d)/g)];
 if (dates.length > 2) throw new PeriodError('一次請指定一段日期範圍，最多包含開始及結束日期。');
 if (dates.length) {
  const values = dates.map(match => `${match[1]}-${pad(Number(match[2]))}-${pad(Number(match[3]))}`);
  explicit = checked({ from: values[0], to: values[1] ?? values[0] }); chosen = 'custom';
 } else {
  const namedMonth = question.match(/(?:(\d{4})\s*年\s*)?(?<!\d)(\d{1,2})\s*月(?!\s*[\d一二三四五六七八九十]+\s*[日號号])/);
  const numericMonth = question.match(/(?<!\d)(\d{4})[-/](\d{1,2})(?![-/\d])/);
  if (namedMonth || numericMonth) {
   const y = numericMonth ? Number(numericMonth[1]) : Number(namedMonth[1] || year);
   const m = Number((numericMonth || namedMonth)[2]);
   if (m < 1 || m > 12 || y < 1900 || y > 2100) throw new PeriodError('月份必須介於 1 到 12 月。');
   explicit = checked({ from: monthStart(y, m), to: monthEnd(y, m) }); chosen = 'custom';
  } else {
   const recent = question.match(/(?:最近|近|過去|过去)\s*(\d{1,4})\s*(?:天|日)/);
   if (recent) {
    const days = Number(recent[1]);
    if (days < 1 || days > 3660) throw new PeriodError('最近天數請介於 1 到 3,660 天。');
    explicit = { from: dateAfter(1 - days, today), to: today }; chosen = 'custom';
   } else {
    const phrases = [ ['all', /全部歷史|全部历史|所有歷史|所有历史|歷來|历来|從開店|从开店/], ['last_month', /上個月|上个月|上月/], ['month', /本月|這個月|这个月/], ['last_year', /去年/], ['year', /今年/], ['last_week', /上週|上周|上個星期|上个星期/], ['week', /本週|本周|這週|这周|這個星期|这个星期/], ['yesterday', /昨天|昨日/], ['today', /今天|今日/] ];
    // Multiple phrases resolve to the first mentioned period; the selected range
    // is exposed in the UI and model must not fabricate an unqueried comparison.
    const matches = phrases.map(([key, expression]) => ({ key, index: question.search(expression) })).filter(item => item.index >= 0).sort((a, b) => a.index - b.index);
    if (matches.length) chosen = matches[0].key;
   }
  }
 }
 let selected = explicit;
 if (!selected) {
  const last = new Date(Date.UTC(year, month - 2, 1)), lastYear = last.getUTCFullYear(), lastMonth = last.getUTCMonth() + 1;
  const weekDay = (new Date(`${today}T00:00:00Z`).getUTCDay() + 6) % 7;
  switch (chosen) {
   case 'month': selected = { from: monthStart(year, month), to: today }; break;
   case 'last_month': selected = { from: monthStart(lastYear, lastMonth), to: monthEnd(lastYear, lastMonth) }; break;
   case 'last_30_days': selected = { from: dateAfter(-29, today), to: today }; break;
   case 'last_90_days': selected = { from: dateAfter(-89, today), to: today }; break;
   case 'all': selected = { from: '1900-01-01', to: today }; break;
   case 'page': selected = checked(range, true); break;
   case 'today': selected = { from: today, to: today }; break;
   case 'yesterday': selected = { from: dateAfter(-1, today), to: dateAfter(-1, today) }; break;
   case 'year': selected = { from: `${year}-01-01`, to: today }; break;
   case 'last_year': selected = { from: `${year - 1}-01-01`, to: `${year - 1}-12-31` }; break;
   case 'week': selected = { from: dateAfter(-weekDay, today), to: today }; break;
   case 'last_week': selected = { from: dateAfter(-weekDay - 7, today), to: dateAfter(-weekDay - 1, today) }; break;
   default: throw new PeriodError('請指定有效的分析期間。');
  }
 }
 checked(selected, scope === 'page');
 return { range: selected, scope, period: chosen, periodLabel: labels[chosen] };
}
