import { createClient } from '@supabase/supabase-js';
import { PUBLIC_SUPABASE_URL, PUBLIC_SUPABASE_KEY } from './public-config.js';

export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL || PUBLIC_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY || PUBLIC_SUPABASE_KEY,
  { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: 'pkce' } }
);
const errors = {
  BOOKING_ACCESS_EXPIRED: '查詢已逾時，請重新輸入手機與姓名；私人連結可重新開啟。',
  RESCHEDULE_CUTOFF: '已超過線上改期期限，請聯絡門店。',
  SLOT_TAKEN: '此時段已無可用技師或療程室，請重新選擇。',
  INVALID_DATE: '日期或時段不在可預約範圍。', INVALID_INPUT: '請檢查輸入資料。',
  FORBIDDEN: '此帳號沒有執行這項操作的權限。', INVALID_TRANSITION: '目前狀態無法執行此操作，請重新整理。',
  INSUFFICIENT_CREDITS: '會員餘額或療程次數不足。', INVALID_PACKAGE: '療程套票不適用、已到期或無法搭配折扣。',
  CANCELLATION_CUTOFF: '已超過線上取消期限，請聯絡門店。', NOT_FOUND: '找不到這筆記錄。',
  RATE_LIMIT: '提交次數較多，請稍後再試或聯絡門店。', REVIEW_NOT_ELIGIBLE: '療程完成後才能評價。',
  EXISTING_BOOKINGS: '此時段已有預約，請先改期再設定休假。', REASON_REQUIRED: '請填寫原因。',
  TOO_EARLY: '尚未到預約時間，無法到店、完成或標記未到。', OWNER_SELF_CHANGE: '不能停用或降級自己的店主帳號。',
  REQUEST_CONFLICT: '此操作編號已用於其他記錄，請重新整理。'
};
export function errorText(error) {
  const message = error?.message || String(error);
  for (const [key, value] of Object.entries(errors)) if (message.includes(key)) return value;
  if (error?.code === 'PGRST202' || message.includes('schema cache')) return '預約系統尚未啟用，請透過 LINE 聯絡門店。';
  if (message.includes('Invalid login')) return '電子郵件或密碼不正確。';
  if (error?.code === '23505') return '這筆資料已存在，請檢查手機號碼或帳號。';
  return '操作未成功，請稍後重試。若持續出現，請聯絡門店。';
}
export async function rpc(name, args = {}) {
  const { data, error } = await supabase.rpc(name, args);
  if (error) throw error;
  return data;
}
export function money(cents = 0) {
  return new Intl.NumberFormat('zh-TW', { style: 'currency', currency: 'TWD', maximumFractionDigits: 2 }).format(Number(cents) / 100);
}
export function cents(value) {
  const text = String(value).trim();
  if (!/^-?\d+(\.\d{1,2})?$/.test(text)) throw new Error('INVALID_INPUT');
  const [whole, fractional = ''] = text.replace('-', '').split('.');
  const n = Number(whole) * 100 + Number(fractional.padEnd(2, '0'));
  if (!Number.isSafeInteger(n)) throw new Error('INVALID_INPUT');
  return text.startsWith('-') ? -n : n;
}
export { taipeiDate, dateAfter } from './date-range.js';
export function dateTime(iso) {
  return new Intl.DateTimeFormat('zh-TW', { timeZone: 'Asia/Taipei', dateStyle: 'short', timeStyle: 'short', hour12: false }).format(new Date(iso));
}
export const statusNames = { pending: '待確認', confirmed: '已確認', checked_in: '已到店', completed: '已完成', cancelled: '已取消', no_show: '未到店' };
export function exportCSV(name, rows) {
  if (!rows.length) return;
  const columns = Object.keys(rows[0]);
  const quote = value => {
    let s = String(value ?? '');
    if (/^[=+@\-\t\r]/.test(s)) s = `'${s}`;
    return `"${s.replace(/"/g, '""')}"`;
  };
  const csv = '\ufeff' + [columns, ...rows.map(r => columns.map(c => r[c]))].map(r => r.map(quote).join(',')).join('\r\n');
  const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv;charset=utf-8' }));
  const a = document.createElement('a'); a.href = url; a.download = name; a.click(); URL.revokeObjectURL(url);
}
