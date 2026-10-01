import { useEffect, useRef, useState } from 'react';
import { rpc, errorText, dateTime, money, statusNames, taipeiDate, dateAfter } from './lib/spa.js';
import { isInactiveBooking, canChangeBooking } from './lib/booking-state.js';
import { useBookingClock } from './lib/useBookingClock.js';
import './booking-lookup.css';

export default function BookingLookup({ lang = 'zh', standalone = false, privateToken = null }) {
  const [phone, setPhone] = useState(''), [name, setName] = useState('');
  const [access, setAccess] = useState(null), [rows, setRows] = useState([]), [searched, setSearched] = useState(false);
  const [busy, setBusy] = useState(false), [error, setError] = useState(''), [notice, setNotice] = useState('');
  const [editing, setEditing] = useState(null), [view, setView] = useState('active');
  const now = useBookingClock(), request = useRef(0), inFlight = useRef(false);
  const en = lang === 'en', t = (zh, english) => en ? english : zh;

  async function refresh(token = access) {
    if (!token || inFlight.current) return;
    const sequence = request.current;
    inFlight.current = true;
    try {
      const next = await rpc('spa_customer_booking_list', { p_access: token });
      if (sequence === request.current) { setRows(next); setError(''); }
    } catch (e) {
      if (sequence === request.current) {
        setError(errorText(e));
        if (e.message?.includes('BOOKING_ACCESS_EXPIRED')) setAccess(null);
      }
    } finally { inFlight.current = false; }
  }
  useEffect(() => {
    if (!privateToken) return;
    let live = true;
    setBusy(true);setError('');
    rpc('spa_booking_link_access', { p_token: privateToken }).then(result => {
      if (!live) return;
      if (!result) { setError('此私人預約連結無效。'); return; }
      setAccess(result.access_token);setRows(result.appointments);setSearched(true);
      if (result.appointments.every(a => isInactiveBooking(a))) setView('inactive');
    }).catch(e => { if (live) setError(errorText(e)); }).finally(() => { if (live) setBusy(false); });
    return () => { live = false;request.current++; };
  }, [privateToken]);
  useEffect(() => {
    if (!access || editing) return;
    const poll = () => { if (document.visibilityState === 'visible' && navigator.onLine !== false) refresh(access); };
    const timer = window.setInterval(poll, 15000);
    window.addEventListener('focus', poll);window.addEventListener('online', poll);document.addEventListener('visibilitychange', poll);
    return () => { window.clearInterval(timer);window.removeEventListener('focus', poll);window.removeEventListener('online', poll);document.removeEventListener('visibilitychange', poll); };
  }, [access, editing]);
  useEffect(() => () => { request.current++; }, []);

  async function lookup(e) {
    e.preventDefault();if (busy) return;
    const sequence = ++request.current;
    setBusy(true);setAccess(null);setRows([]);setError('');setNotice('');setSearched(false);setEditing(null);
    try {
      const result = await rpc('spa_lookup_bookings', { p_phone: phone.trim(), p_name: name.trim() });
      if (sequence !== request.current) return;
      setRows(result.appointments);setAccess(result.access_token || null);setSearched(true);
      setView(result.appointments.some(a => !isInactiveBooking(a, now)) ? 'active' : 'inactive');
    } catch (e) { if (sequence === request.current) setError(errorText(e)); }
    finally { if (sequence === request.current) setBusy(false); }
  }
  const active = rows.filter(a => !isInactiveBooking(a, now)).sort((a, b) => Date.parse(a.starts_at) - Date.parse(b.starts_at));
  const inactive = rows.filter(a => isInactiveBooking(a, now)).sort((a, b) => Date.parse(b.starts_at) - Date.parse(a.starts_at));
  const selected = view === 'active' ? active : inactive;
  async function changed(result, kind) {
    request.current++; // Discard any list response fetched before this mutation succeeded.
    setRows(previous => previous.map(row => row.id === result.id ? result : row));
    setEditing(null);setView(kind === 'cancel' ? 'inactive' : 'active');
    setNotice(kind === 'cancel' ? t('預約已取消，門店後台已同步。', 'Booking cancelled and saved to the store system.')
      : result.status === 'pending' ? t('改期已送出，等待門店確認；後台已同步。', 'Reschedule saved; awaiting store confirmation.')
      : t('預約已改期，門店後台已同步。', 'Booking rescheduled and saved to the store system.'));
    await refresh();
  }
  const content = <div className="booking-lookup">
    {standalone && <header className="lookup-header"><div><p className="lookup-eyebrow">ROU SPA</p><h1>{t('查詢與管理預約', 'Find and manage bookings')}</h1></div><a href="#">{t('返回首頁', 'Home')}</a></header>}
    {!privateToken && <form className="lookup-form" onSubmit={lookup}>
      <p className="lookup-intro">{t('輸入預約時留下的手機號碼與完整姓名，查看預約、取消或改期。', 'Enter the phone number and full name used for your booking.')}</p>
      <div className="lookup-fields"><label>{t('手機號碼', 'Phone number')}<input required type="tel" inputMode="tel" autoComplete="tel" maxLength={25} value={phone} onChange={e => setPhone(e.target.value)} placeholder="09xxxxxxxx" /></label>
      <label>{t('預約姓名', 'Full name')}<input required autoComplete="name" maxLength={80} value={name} onChange={e => setName(e.target.value)} placeholder={t('請輸入完整姓名', 'Your full name')} /></label></div>
      <button className="lookup-primary" disabled={busy}>{busy ? t('查詢中…', 'Searching…') : t('查詢預約', 'Find bookings')}</button>
      <p className="lookup-help">{t('姓名與手機需和預約資料一致。若無法查到，請使用預約成功時的私人連結或聯絡門店。', 'Both details must match your booking. You can also use your private booking link or contact the store.')}</p>
    </form>}
    {error && <p className="lookup-alert" role="alert">{error}</p>}
    {notice && <p className="lookup-success" role="status">{notice}</p>}
    {busy && privateToken && <p role="status">{t('正在載入預約…', 'Loading booking…')}</p>}
    {searched && !rows.length && <p className="lookup-empty">{t('未找到符合的預約，請確認手機與姓名。', 'No matching bookings. Please check the phone and full name.')}</p>}
    {rows.length > 0 && <>
      <div className="lookup-tabs" role="tablist" aria-label={t('預約分組', 'Booking groups')}>
        <button role="tab" aria-selected={view === 'active'} aria-controls="lookup-results" onClick={() => setView('active')}>Active · {t('有效預約', 'Upcoming')} ({active.length})</button>
        <button role="tab" aria-selected={view === 'inactive'} aria-controls="lookup-results" onClick={() => setView('inactive')}>Nonactive · {t('已結束／取消', 'Past / cancelled')} ({inactive.length})</button>
      </div>
      <p className="lookup-help">{t('依台灣時間即時分類。已完成、取消、未到店或服務結束時間已過，會歸入 Nonactive。', 'Updated using Taiwan time. Completed, cancelled, no-show and expired bookings are Nonactive.')}</p>
      <div id="lookup-results" role="tabpanel">
      {!selected.length && <p className="lookup-empty">{t('這個分組目前沒有預約。', 'No bookings in this group.')}</p>}
      {selected.map(row => <article key={row.id} className={`lookup-card ${isInactiveBooking(row, now) ? 'is-inactive' : ''}`} data-booking-id={row.id}>
        <div className="lookup-card-heading"><h3>{row.service_name}</h3><span className="lookup-status">{statusNames[row.status]}</span></div>
        <p className="lookup-reference">{row.reference}</p><p>{dateTime(row.starts_at)} → {dateTime(row.ends_at)}</p>
        <p>{t('服務技師', 'Therapist')}：{row.therapist} · {money(row.price_cents)}</p>
        {isInactiveBooking(row, now) && !['completed', 'cancelled', 'no_show'].includes(row.status) && <p className="lookup-help">{t('服務時間已過；到店及完成狀態由門店核對。', 'Service time has passed; the store confirms attendance.')}</p>}
        {canChangeBooking(row, now) ? <div className="lookup-actions"><button onClick={() => setEditing({ row, kind: 'reschedule' })}>{t('改期預約', 'Reschedule')}</button><button className="lookup-danger" onClick={() => setEditing({ row, kind: 'cancel' })}>{t('取消預約', 'Cancel booking')}</button></div>
          : !isInactiveBooking(row, now) && <p className="lookup-help">{t('已超過線上修改期限，請聯絡門店。', 'The online change deadline has passed. Please contact the store.')}</p>}
        {editing?.row.id === row.id && <BookingChange key={`${row.id}-${editing.kind}`} access={access} row={row} kind={editing.kind} lang={lang} now={now} close={() => setEditing(null)} changed={changed} />}
      </article>)}
      </div>
    </>}
  </div>;
  return standalone ? <main className="lookup-page">{content}</main> : content;
}

function BookingChange({ access, row, kind, lang, now, close, changed }) {
  const [reason, setReason] = useState(''), [busy, setBusy] = useState(false), [error, setError] = useState('');
  const [date, setDate] = useState(row.business_date), [staff, setStaff] = useState(row.staff_id), [start, setStart] = useState('');
  const [catalog, setCatalog] = useState(null), [slots, setSlots] = useState([]), [loading, setLoading] = useState(false), [reload, setReload] = useState(0);
  const attempt = useRef(null), en = lang === 'en', t = (zh, english) => en ? english : zh;
  useEffect(() => { if (kind !== 'reschedule') return;let live = true;rpc('spa_catalog').then(c => { if (live) setCatalog(c); }).catch(e => { if (live) setError(errorText(e)); });return () => { live = false; }; }, [kind]);
  useEffect(() => {
    if (kind !== 'reschedule' || !date) return;
    let live = true;setStart('');setSlots([]);setError('');setLoading(true);
    rpc('spa_customer_availability', { p_access: access, p_appointment: row.id, p_date: date, p_staff: staff || null })
      .then(next => { if (live) setSlots(next); }).catch(e => { if (live) setError(errorText(e)); }).finally(() => { if (live) setLoading(false); });
    return () => { live = false; };
  }, [access, row.id, kind, date, staff, reload]);
  async function submit(e) {
    e.preventDefault();if (busy || !canChangeBooking(row, now)) return;
    const payload = { p_access: access, p_appointment: row.id, p_reason: reason.trim(), ...(kind === 'reschedule' ? { p_date: date, p_start: start, p_staff: staff || null } : {}) };
    const fingerprint = JSON.stringify(payload);
    if (attempt.current?.fingerprint !== fingerprint) attempt.current = { fingerprint, id: crypto.randomUUID() };
    setBusy(true);setError('');
    try {
      const result = await rpc(kind === 'cancel' ? 'spa_customer_cancel' : 'spa_customer_reschedule', { ...payload, p_request: attempt.current.id });
      await changed(result, kind);
    } catch (e) { setError(errorText(e));if (e.message?.includes('SLOT_TAKEN')) { setStart('');setReload(n => n + 1); } }
    finally { setBusy(false); }
  }
  return <form className="lookup-change" onSubmit={submit}>
    <h4>{kind === 'cancel' ? t('確認取消這筆預約', 'Confirm cancellation') : t('選擇新的日期與時段', 'Choose a new date and time')}</h4>
    {kind === 'reschedule' && <div className="lookup-fields">
      <label>{t('新日期', 'New date')}<input required type="date" min={taipeiDate(new Date(now))} max={dateAfter(catalog?.settings.booking_days || 30, taipeiDate(new Date(now)))} value={date} onChange={e => setDate(e.target.value)} /></label>
      <label>{t('技師', 'Therapist')}<select value={staff} onChange={e => setStaff(e.target.value)}><option value="">{t('不指定技師', 'Any therapist')}</option>{catalog?.staff.filter(s => catalog.skills.some(sk => sk.staff_id === s.id && sk.service_id === row.service_id)).map(s => <option key={s.id} value={s.id}>{s.name}</option>)}</select></label>
      <label className="lookup-wide">{t('可用時段', 'Available time')}<select required disabled={loading} value={start} onChange={e => setStart(e.target.value)}><option value="">{loading ? t('時段載入中…', 'Loading…') : t('請選擇時段', 'Choose a time')}</option>{slots.filter(s => s.available).map(s => <option key={s.starts_at} value={s.starts_at}>{s.time_label}</option>)}</select></label>
      {!loading && !slots.some(s => s.available) && <p className="lookup-help lookup-wide">{t('此日期／技師沒有可用時段，請更換選擇。', 'No available times. Choose another date or therapist.')}</p>}
    </div>}
    <label>{kind === 'cancel' ? t('取消原因', 'Cancellation reason') : t('改期原因', 'Reschedule reason')}<textarea required maxLength={1000} rows={2} value={reason} onChange={e => setReason(e.target.value)} /></label>
    <p className="lookup-help">{kind === 'cancel' ? t('取消後將釋放原時段；如需再次預約，請重新選擇時段。', 'Cancelling releases the slot. A new booking is needed to reserve it again.') : t('原療程與價格不變，實際可用技師與床位會在儲存時再次確認。', 'Your treatment and booked price stay the same. Availability is checked again when saving.')}</p>
    {error && <p className="lookup-alert" role="alert">{error}</p>}
    <div className="lookup-actions"><button type="button" disabled={busy} onClick={close}>{t('返回', 'Back')}</button><button className={kind === 'cancel' ? 'lookup-danger' : 'lookup-primary'} disabled={busy || !canChangeBooking(row, now) || (kind === 'reschedule' && (!start || loading))}>{busy ? t('處理中…', 'Saving…') : kind === 'cancel' ? t('確認取消', 'Confirm cancellation') : t('確認改期', 'Confirm reschedule')}</button></div>
  </form>;
}
