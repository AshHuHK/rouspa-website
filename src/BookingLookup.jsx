import { useEffect, useRef, useState } from 'react';
import { publicRpc, errorText, dateTime, money, statusNames, taipeiDate, dateAfter } from './lib/spa.js';
import { isInactiveBooking, canChangeBooking } from './lib/booking-state.js';
import { useBookingClock } from './lib/useBookingClock.js';
import { useLiveRefresh } from './lib/useLiveRefresh.js';
import { nextMonthEnd } from './lib/date-range.js';
import { createRequestId } from './lib/request-id.js';
import { canRebookBooking } from './lib/rebooking.js';
import { statusNamesEn, therapistLabel, slotLabel } from './lib/public-copy.js';
import './booking-lookup.css';

export default function BookingLookup({ lang = 'zh', standalone = false, privateToken = null, onRebook }) {
  const [phone, setPhone] = useState(''), [name, setName] = useState('');
  const [access, setAccess] = useState(null), [rows, setRows] = useState([]), [searched, setSearched] = useState(false);
  const [busy, setBusy] = useState(false), [error, setError] = useState(''), [notice, setNotice] = useState('');
  const [editing, setEditing] = useState(null), [view, setView] = useState('active');
  const now = useBookingClock(rows.flatMap(row => [row.ends_at, Date.parse(row.change_before) + 1])), request = useRef(0), inFlight = useRef(null);
  const en = lang === 'en', t = (zh, english) => en ? english : zh;

  async function refresh(token = access) {
    if (!token) return;
    const sequence = request.current;
    while (inFlight.current) await inFlight.current;
    if (sequence !== request.current) return;
    const task = (async () => {
      try {
        const next = await publicRpc('spa_customer_booking_list', { p_access: token });
        if (sequence === request.current) { setRows(next); setError(''); }
      } catch (e) {
        if (sequence === request.current) {
          setError(errorText(e, lang));
          if (e.message?.includes('BOOKING_ACCESS_EXPIRED')) { request.current++;setAccess(null);setRows([]);setSearched(false);setEditing(null); }
        }
      }
    })();
    inFlight.current = task;
    try { await task; }
    finally { if (inFlight.current === task) inFlight.current = null; }
  }
  useEffect(() => {
    if (!privateToken) return;
    let live = true;
    setBusy(true);setError('');setAccess(null);setRows([]);setSearched(false);setEditing(null);
    publicRpc('spa_booking_link_access', { p_token: privateToken }).then(result => {
      if (!live) return;
      if (!result) { setError(t('此私人預約連結無效。', 'This private booking link is invalid.')); return; }
      setAccess(result.access_token);setRows(result.appointments);setSearched(true);
      if (result.appointments.every(a => isInactiveBooking(a))) setView('inactive');
    }).catch(e => { if (live) setError(errorText(e, lang)); }).finally(() => { if (live) setBusy(false); });
    return () => { live = false;request.current++; };
  }, [privateToken]);
  useLiveRefresh(() => refresh(access), { audience: 'public', enabled: !!access, paused: !!editing || busy, protectEditing: false });
  useEffect(() => () => { request.current++; }, []);

  async function lookup(e) {
    e.preventDefault();if (busy) return;
    const sequence = ++request.current;
    setBusy(true);setAccess(null);setRows([]);setError('');setNotice('');setSearched(false);setEditing(null);
    try {
      const result = await publicRpc('spa_lookup_bookings', { p_phone: phone.trim(), p_name: name.trim() });
      if (sequence !== request.current) return;
      setRows(result.appointments);setAccess(result.access_token || null);setSearched(true);
      setView(result.appointments.some(a => !isInactiveBooking(a, now)) ? 'active' : 'inactive');
    } catch (e) { if (sequence === request.current) setError(errorText(e, lang)); }
    finally { if (sequence === request.current) setBusy(false); }
  }
  function openEditor(row, kind) { request.current++;setEditing({ row, kind }); }
  function closeEditor() { setEditing(null);refresh(); }
  const active = rows.filter(a => !isInactiveBooking(a, now)).sort((a, b) => Date.parse(a.starts_at) - Date.parse(b.starts_at));
  const inactive = rows.filter(a => isInactiveBooking(a, now)).sort((a, b) => Date.parse(b.starts_at) - Date.parse(a.starts_at));
  const selected = [...(view === 'active' ? active : inactive)];
  const editedRow = editing && rows.find(row => row.id === editing.row.id);
  if (editedRow && !selected.some(row => row.id === editedRow.id)) selected.push(editedRow);
  async function changed(result, kind) {
    request.current++; // Discard any list response fetched before this mutation succeeded.
    setRows(previous => previous.map(row => row.id === result.id ? result : row));
    setEditing(null);setView(['cancel','review'].includes(kind) ? 'inactive' : 'active');
    setNotice(kind === 'review' ? t('謝謝您的評價，NT$50 優惠券已發放到會員中心。', 'Thank you. Your NT$50 coupon is now in your member centre.') : kind === 'cancel' ? t('預約已取消，門店後台已同步。', 'Booking cancelled and saved to the store system.')
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
        <div className="lookup-card-heading"><h3>{row.service_name}</h3><span className="lookup-status">{(en ? statusNamesEn : statusNames)[row.status]}</span></div>
        <p className="lookup-reference">{row.reference}</p><p>{dateTime(row.starts_at, lang)} → {dateTime(row.ends_at, lang)}</p>
        <p>{t('服務技師', 'Therapist')}：{therapistLabel(row,lang)} · {money(row.price_cents)}</p>
        {isInactiveBooking(row, now) && !['completed', 'cancelled', 'no_show'].includes(row.status) && <p className="lookup-help">{t('服務時間已過；到店及完成狀態由門店核對。', 'Service time has passed; the store confirms attendance.')}</p>}
        {canChangeBooking(row, now) ? <div className="lookup-actions"><button onClick={() => openEditor(row, 'reschedule')}>{t('改期預約', 'Reschedule')}</button><button className="lookup-danger" onClick={() => openEditor(row, 'cancel')}>{t('取消預約', 'Cancel booking')}</button></div>
          : !isInactiveBooking(row, now) && <p className="lookup-help">{t('已超過線上修改期限，請聯絡門店。', 'The online change deadline has passed. Please contact the store.')}</p>}
        {row.review_submitted && <p className="lookup-success">{t('已評價，謝謝您的回饋。', 'Review submitted. Thank you.')}</p>}
        {row.can_review && !row.review_submitted && <div className="lookup-actions"><button className="lookup-primary" onClick={() => openEditor(row, 'review')}>{t('評價技師 · 領 NT$50 優惠券', 'Review therapist · Get NT$50')}</button></div>}
        {onRebook && canRebookBooking(row) && <div className="lookup-actions"><button onClick={() => onRebook(row)}>{t('再次預約', 'Book again')}</button></div>}
        {isInactiveBooking(row,now) && !['completed','cancelled','no_show'].includes(row.status) && <p className="lookup-help">{t('待門店確認完成療程後，即可評價服務技師。', 'You can review your therapist once the store confirms completion.')}</p>}
        {editing?.row.id === row.id && editing.kind === 'review' && <BookingReview key={row.id} access={access} row={row} lang={lang} close={closeEditor} changed={changed}/>}
        {editing?.row.id === row.id && editing.kind !== 'review' && <BookingChange key={`${row.id}-${editing.kind}`} access={access} row={row} kind={editing.kind} lang={lang} now={now} close={closeEditor} changed={changed} />}
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
  const slotNow = useBookingClock(slots.filter(slot => slot.available).map(slot => Date.parse(slot.starts_at) - 30 * 60000));
  const attempt = useRef(null), en = lang === 'en', t = (zh, english) => en ? english : zh;
  useLiveRefresh(() => setReload(value => value + 1), { audience: 'public', scopes: ['catalog', 'hours', 'availability'], enabled: kind === 'reschedule', paused: busy, protectEditing: false });
  useEffect(() => { if (kind !== 'reschedule' || busy) return;let live = true;publicRpc('spa_catalog').then(c => { if (live) setCatalog(c); }).catch(e => { if (live) setError(errorText(e, lang)); });return () => { live = false; }; }, [kind, reload, busy]);
  useEffect(() => { setStart(''); }, [date, staff]);
  useEffect(() => {
    if (kind !== 'reschedule' || !date || busy) return;
    let live = true;setError('');setLoading(true);
    publicRpc('spa_customer_availability', { p_access: access, p_appointment: row.id, p_date: date, p_staff: staff || null })
      .then(next => { if (live) { setSlots(next);setStart(selected => next.some(slot => slot.starts_at === selected && slot.available) ? selected : ''); } }).catch(e => { if (live) { setSlots([]);setStart('');setError(errorText(e, lang)); } }).finally(() => { if (live) setLoading(false); });
    return () => { live = false; };
  }, [access, row.id, kind, date, staff, reload, busy]);
  useEffect(() => {
    if (busy || !slots.some(slot => slot.available && Date.parse(slot.starts_at) <= slotNow + 30 * 60000)) return;
    setSlots(previous => previous.map(slot => Date.parse(slot.starts_at) > slotNow + 30 * 60000 ? slot : { ...slot, available: false }));
    setStart(selected => Date.parse(selected) > slotNow + 30 * 60000 ? selected : '');
  }, [slotNow, slots, busy]);
  async function submit(e) {
    e.preventDefault();if (busy || !canChangeBooking(row, now) || (kind === 'reschedule' && (loading || !slots.some(slot => slot.starts_at === start && slot.available && Date.parse(slot.starts_at) > slotNow + 30 * 60000)))) return;
    const payload = { p_access: access, p_appointment: row.id, p_reason: reason.trim(), ...(kind === 'reschedule' ? { p_date: date, p_start: start, p_staff: staff || null } : {}) };
    const fingerprint = JSON.stringify(payload);
    setBusy(true);setError('');
    try {
      if (attempt.current?.fingerprint !== fingerprint) attempt.current = { fingerprint, id: createRequestId() };
      const result = await publicRpc(kind === 'cancel' ? 'spa_customer_cancel' : 'spa_customer_reschedule', { ...payload, p_request: attempt.current.id });
      await changed(result, kind);
    } catch (e) { setError(errorText(e, lang));if (e.message?.includes('SLOT_TAKEN')) { setStart('');setReload(n => n + 1); } }
    finally { setBusy(false); }
  }
  return <form className="lookup-change" onSubmit={submit}>
    <h4>{kind === 'cancel' ? t('確認取消這筆預約', 'Confirm cancellation') : t('選擇新的日期與時段', 'Choose a new date and time')}</h4>
    {kind === 'reschedule' && <div className="lookup-fields">
      <label>{t('新日期', 'New date')}<input required type="date" min={taipeiDate(new Date(now))} max={nextMonthEnd(taipeiDate(new Date(now)))} value={date} onChange={e => setDate(e.target.value)} /></label>
      <label>{t('技師', 'Therapist')}<select value={staff} onChange={e => setStaff(e.target.value)}><option value="">{t('不指定技師', 'Any therapist')}</option>{catalog?.staff.filter(s => catalog.skills.some(sk => sk.staff_id === s.id && sk.service_id === row.service_id)).map(s => <option key={s.id} value={s.id}>{therapistLabel(s, lang)}</option>)}</select></label>
      <label className="lookup-wide">{t('可用時段', 'Available time')}<select required disabled={loading} value={start} onChange={e => setStart(e.target.value)}><option value="">{loading ? t('時段載入中…', 'Loading…') : t('請選擇時段', 'Choose a time')}</option>{slots.filter(s => s.available).map(s => <option key={s.starts_at} value={s.starts_at}>{slotLabel(s.time_label, lang)}</option>)}</select></label>
      {!loading && !slots.some(s => s.available) && <p className="lookup-help lookup-wide">{t('此日期／技師沒有可用時段，請更換選擇。', 'No available times. Choose another date or therapist.')}</p>}
    </div>}
    <label>{kind === 'cancel' ? t('取消原因', 'Cancellation reason') : t('改期原因', 'Reschedule reason')}<textarea required maxLength={1000} rows={2} value={reason} onChange={e => setReason(e.target.value)} /></label>
    <p className="lookup-help">{kind === 'cancel' ? t('取消後將釋放原時段；如需再次預約，請重新選擇時段。', 'Cancelling releases the slot. A new booking is needed to reserve it again.') : t('原療程與價格不變，實際可用技師與床位會在儲存時再次確認。', 'Your treatment and booked price stay the same. Availability is checked again when saving.')}</p>
    {error && <><p className="lookup-alert" role="alert">{error}</p>{kind === 'reschedule' && <button type="button" disabled={busy || loading} onClick={() => setReload(value => value + 1)}>{t('重新載入時段', 'Reload availability')}</button>}</>}
    <div className="lookup-actions"><button type="button" disabled={busy} onClick={close}>{t('返回', 'Back')}</button><button className={kind === 'cancel' ? 'lookup-danger' : 'lookup-primary'} disabled={busy || !canChangeBooking(row, now) || (kind === 'reschedule' && (!start || loading))}>{busy ? t('處理中…', 'Saving…') : kind === 'cancel' ? t('確認取消', 'Confirm cancellation') : t('確認改期', 'Confirm reschedule')}</button></div>
  </form>;
}

function BookingReview({access,row,lang,close,changed}) {
 const [rating,setRating]=useState('5'),[comment,setComment]=useState(''),[busy,setBusy]=useState(false),[error,setError]=useState('');
 const t=(zh,en)=>lang==='en'?en:zh;
 return <form className="lookup-change" onSubmit={async e=>{e.preventDefault();if(busy)return;setBusy(true);setError('');try{const result=await publicRpc('spa_customer_review',{p_access:access,p_appointment:row.id,p_rating:Number(rating),p_comment:comment});await changed(result,'review');}catch(e){setError(errorText(e, lang));}finally{setBusy(false);}}}>
 <h4>{t('評價服務技師','Review therapist')} · {therapistLabel(row,lang)}</h4><label>{t('服務評分','Rating')}<select aria-label={t('服務評分','Rating')} value={rating} onChange={e=>setRating(e.target.value)}>{[5,4,3,2,1].map(n=><option key={n} value={n}>{'★'.repeat(n)} {n} / 5</option>)}</select></label>
 <label>{t('您的體驗（最多 1000 字）','Your experience (up to 1000 characters)')}<textarea maxLength={1000} rows={3} value={comment} onChange={e=>setComment(e.target.value)}/></label>
 <p className="lookup-help">{t('提交後立即發放 NT$50 優惠券到會員中心；每次療程限評價和領取一次。門店審核後可公開，公開內容不顯示姓名和手機。','An NT$50 coupon is issued to your member centre immediately. One review and reward per completed visit. Public reviews omit your name and phone.')}</p>
 {error&&<p className="lookup-alert" role="alert">{error}</p>}<div className="lookup-actions"><button type="button" disabled={busy} onClick={close}>{t('返回','Back')}</button><button className="lookup-primary" disabled={busy}>{busy?t('提交中…','Submitting…'):t('提交評價並領券','Submit and get coupon')}</button></div></form>;
}
