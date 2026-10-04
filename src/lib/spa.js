import { createClient } from '@supabase/supabase-js';
import { PUBLIC_SUPABASE_URL, PUBLIC_SUPABASE_KEY } from './public-config.js';

export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL || PUBLIC_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY || PUBLIC_SUPABASE_KEY,
  { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: 'pkce' } }
);
const errors = {
  ACCOUNT_AUTH_SYNC_REQUIRED: '後台存取權限已儲存，但登入系統尚未同步；請重新執行啟用／停用，或聯絡店主。',
  ACCOUNT_LINK_CLEANUP_REQUIRED: '帳號綁定失敗且清理未完成，請由店主核對登入系統後再重試。',
  INVALID_USERNAME: '使用者名稱需為 3～32 字元的英文字母、數字、點、底線或連字號。',
  USERNAME_TAKEN: '這個使用者名稱已被使用，請換一個名稱。',
  INVALID_LOGIN: '使用者名稱或密碼不正確，或帳號已停用。',
  ACCOUNT_CREATE_FAILED: '無法建立帳號，請確認使用者名稱尚未被使用，並使用至少 12 字元的密碼。',
  ACCOUNT_EXISTS: '此人員已有登入帳號，請重新整理後修改登入權限或重設密碼。',
  ACCOUNT_NOT_FOUND: '此人員尚未建立登入帳號。',
  ACCOUNT_CONFLICT: '帳號與人員資料不一致，請重新整理後核對；同一帳號只能綁定一位人員。',
  PASSWORD_TOO_SHORT: '密碼請使用 12～128 個字元。', PASSWORD_RESET_FAILED: '密碼重設未成功，請重試；舊後台會話已停用。',
  OWNER_PROTECTED: '店主帳號保持不變，不能透過人員管理修改或停用。', STAFF_ARCHIVED: '此人員已封存，請先恢復人員資料。',
  ACCOUNT_SERVICE_UNAVAILABLE: '人員帳號服務暫時無法連線，請稍後重試。',
  BOOKING_ACCESS_EXPIRED: '查詢已逾時，請重新輸入手機與姓名；私人連結可重新開啟。',
  RESCHEDULE_CUTOFF: '已超過線上改期期限，請聯絡門店。',
  SLOT_TAKEN: '此時段已無可用技師或療程室，請重新選擇。',
  INVALID_DATE: '日期或時段不在可預約範圍。', INVALID_INPUT: '請檢查輸入資料。',
  FORBIDDEN: '此帳號沒有執行這項操作的權限。', INVALID_TRANSITION: '目前狀態無法執行此操作，請重新整理。',
  INSUFFICIENT_CREDITS: '會員餘額或療程次數不足。', INVALID_PACKAGE: '療程套票不適用、已到期或無法搭配折扣。',
  CANCELLATION_CUTOFF: '已超過線上取消期限，請聯絡門店。', NOT_FOUND: '找不到這筆記錄。',
  RATE_LIMIT: '提交次數較多，請稍後再試或聯絡門店。', REVIEW_NOT_ELIGIBLE: '療程完成後才能評價。',
  EXISTING_BOOKINGS: '此時段已有預約，請先改期再設定休假。', REASON_REQUIRED: '請填寫原因。',
  SAME_STAFF: '所選技師與目前實際技師相同。', STAFF_NOT_ACTIVE: '此人員已停用或封存，無法排班或接受療程。',
  STAFF_SKILL_REQUIRED: '此技師尚未取得該療程的服務資格，請先在人員檔案啟用療程。',
  STAFF_NOT_AVAILABLE: '此技師不在當日排班內、正在休假或同時段已有其他預約。',
  TOO_EARLY: '尚未到預約時間，無法到店、完成或標記未到。', OWNER_SELF_CHANGE: '不能停用或降級自己的店主帳號。',
  REQUEST_CONFLICT: '此操作編號已用於其他記錄，請重新整理。',
  STAFF_PERMISSION_LIMIT: '員工角色只能使用營運首頁、預約與日程、評價及自己的薪資與績效。',
  RESET_CONFIRMATION_REQUIRED: '請輸入 RESET 才能執行資料重設。',
  CUSTOMER_DELETE_CONFIRMATION_REQUIRED: '請輸入 DELETE 才能刪除或封存顧客檔案。'
};
const publicErrorsEn = {
  BOOKING_ACCESS_EXPIRED: 'Your booking access has expired. Search again or reopen your private link.',
  RESCHEDULE_CUTOFF: 'The online rescheduling deadline has passed. Please contact the store.',
  CANCELLATION_CUTOFF: 'The online cancellation deadline has passed. Please contact the store.',
  SLOT_TAKEN: 'This time is no longer available. Please choose another time.',
  INVALID_DATE: 'Choose a date and time within the booking period.',
  INVALID_INPUT: 'Please check the information you entered.',
  FORBIDDEN: 'You do not have permission to perform this action.',
  NOT_FOUND: 'This record could not be found.',
  RATE_LIMIT: 'Too many attempts. Please try again later or contact the store.',
  REVIEW_NOT_ELIGIBLE: 'Reviews are available after the store confirms your treatment is completed.',
  REASON_REQUIRED: 'Please enter a reason.',
  INVALID_TRANSITION: 'This booking cannot be changed in its current state. Please refresh.',
  REQUEST_CONFLICT: 'Please refresh before trying again.'
};
export function errorText(error, lang = 'zh') {
  const message = error?.message || String(error);
  if (lang === 'en') {
    for (const [key, value] of Object.entries(publicErrorsEn)) if (message.includes(key)) return value;
    if (error?.code === 'PGRST202' || message.includes('schema cache')) return 'Online booking is unavailable. Please contact us on LINE.';
    return 'The action could not be completed. Please try again or contact the store.';
  }
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
  return 'NT$' + new Intl.NumberFormat('zh-TW', { minimumFractionDigits: 0, maximumFractionDigits: 2 }).format(Number(cents) / 100);
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
export function dateTime(iso, lang = 'zh') {
  return new Intl.DateTimeFormat(lang === 'en' ? 'en-GB' : 'zh-TW', { timeZone: 'Asia/Taipei', dateStyle: 'short', timeStyle: 'short', hour12: false }).format(new Date(iso));
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
