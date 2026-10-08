export function taipeiDate(date = new Date()) {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Taipei', year: 'numeric', month: '2-digit', day: '2-digit' }).format(date);
}
export function dateAfter(days, base = taipeiDate()) {
  const d = new Date(`${base}T12:00:00+08:00`);
  d.setUTCDate(d.getUTCDate() + days);
  return taipeiDate(d);
}
export function nextMonthEnd(base = taipeiDate()) {
  const [year, month] = base.slice(0, 7).split('-').map(Number);
  return taipeiDate(new Date(Date.UTC(year, month + 1, 0)));
}
export function sevenDayRange(base = taipeiDate()) {
  return { from: base, to: dateAfter(6, base) };
}
export function rangeDays({ from, to }) {
  return Math.round((Date.parse(`${to}T00:00:00+08:00`) - Date.parse(`${from}T00:00:00+08:00`)) / 86400000) + 1;
}
export function validRange(range) {
  const realDate = value => /^\d{4}-\d{2}-\d{2}$/.test(value) && Number.isFinite(Date.parse(`${value}T12:00:00+08:00`)) && taipeiDate(new Date(`${value}T12:00:00+08:00`)) === value;
  return realDate(range.from) && realDate(range.to) && rangeDays(range) > 0 && rangeDays(range) <= 367;
}
export function shiftRange(range, direction) {
  const offset = rangeDays(range) * direction;
  return { from: dateAfter(offset, range.from), to: dateAfter(offset, range.to) };
}
