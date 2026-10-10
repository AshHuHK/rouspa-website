import { useEffect, useMemo, useRef, useState } from 'react';
import { errorText, money, publicRpc, taipeiDate } from './lib/spa.js';
import { publicName, publicTitle, therapistLabel, slotLabel } from './lib/public-copy.js';
import { useBookingClock } from './lib/useBookingClock.js';
import { resolveRebookingIntent } from './lib/rebooking.js';
import { useLiveRefresh } from './lib/useLiveRefresh.js';
import { createRequestId } from './lib/request-id.js';
import { PUBLIC_BOOKING_RELEASE } from './lib/public-rpc.js';

const copy={zh:{steps:['選擇服務','預約方式','日期時段','確認預約'],service:'請選擇服務項目',method:'您想怎麼找時間？',staff:'指定技師',staffSub:'先選技師，再看她本月與下月的班表。',time:'挑時間',timeSub:'先挑日期與時間，再看當時有空的技師。',any:'不指定技師，由店家安排',anySub:'系統會在有空的合格技師中，優先安排當天服務分鐘較少的人。',next:'下一步',back:'上一步',chooseStaff:'選擇指定技師',chooseDate:'只開放本月與下個月',chooseSlot:'選擇可預約時段',chooseAfter:'這個時間可選的技師',noPreference:'不指定，由店家安排',open:'可約',full:'已滿',off:'休',people:'位可約',loading:'正在計算正式班表與空檔…',summary:'預約摘要',name:'您的姓名',phone:'您的手機號碼',note:'備註（選填）',confirm:'確認預約',submitting:'預約中…',success:'預約已送出',again:'重新預約',manage:'查看、取消或改期（請保存此私人連結）',member:'首次預約會以姓名與手機號碼自動建立會員資料，無需 Email 或另外註冊。',assigned:'實際安排技師',designated:'指定技師',automatic:'店家自動安排'},en:{steps:['Service','Booking method','Date & time','Confirm'],service:'Choose a service',method:'How would you like to book?',staff:'Choose a therapist',staffSub:'Select a therapist, then view their roster for this and next month.',time:'Choose a time',timeSub:'Select a date and time, then choose from available therapists.',any:'No preference',anySub:'We assign an available qualified therapist with the lightest workload that day.',next:'Next',back:'Back',chooseStaff:'Select your therapist',chooseDate:'Available for this and next month',chooseSlot:'Choose an available time',chooseAfter:'Therapists available at this time',noPreference:'No preference — let the store assign',open:'Open',full:'Full',off:'Off',people:'available',loading:'Checking the live roster and availability…',summary:'Booking summary',name:'Full name',phone:'Phone number',note:'Notes (optional)',confirm:'Confirm booking',submitting:'Submitting…',success:'Booking received',again:'Book again',manage:'Manage booking — save this private link',member:'Your first booking creates a member profile with your name and phone. No email or separate registration is needed.',assigned:'Assigned therapist',designated:'Requested therapist',automatic:'Assigned by store'}};

function monthKey(value,step=0){const [y,m]=value.slice(0,7).split('-').map(Number),d=new Date(Date.UTC(y,m-1+step,1));return `${d.getUTCFullYear()}-${String(d.getUTCMonth()+1).padStart(2,'0')}`;}
function monthCells(month){const [y,m]=month.split('-').map(Number),first=new Date(Date.UTC(y,m-1,1)),pad=(first.getUTCDay()+6)%7,last=new Date(Date.UTC(y,m,0)).getUTCDate(),cells=Array(pad).fill(null);for(let d=1;d<=last;d++)cells.push(`${month}-${String(d).padStart(2,'0')}`);while(cells.length%7)cells.push(null);return cells;}
function monthLabel(month,lang){const [year,value]=month.split('-');return lang==='zh'?`${year} 年 ${Number(value)} 月`:new Intl.DateTimeFormat('en',{month:'long',year:'numeric',timeZone:'UTC'}).format(new Date(`${month}-01T00:00:00Z`));}
function periodOf(label){const clean=label.replace('翌日 ','');const hour=Number(clean.slice(0,2));return label.startsWith('翌日')||hour>=17?'evening':hour<12?'morning':'afternoon';}
const periodNames={zh:{morning:'上午',afternoon:'下午',evening:'晚間'},en:{morning:'Morning',afternoon:'Afternoon',evening:'Evening'}};

export default function PublicBookingExperience({catalog:originalCatalog,catalogError,onCatalogRetry,lang='zh',rebookingIntent,onRebookingApplied}){
 const [rebookingCatalog,setRebookingCatalog]=useState(null),[rebookingBusy,setRebookingBusy]=useState(false),[rebookingRetry,setRebookingRetry]=useState(0),[rebookingNotice,setRebookingNotice]=useState('');
 const catalog=rebookingCatalog||originalCatalog;
 const [availabilityVersion,setAvailabilityVersion]=useState(0),[availabilityNotice,setAvailabilityNotice]=useState('');
 const [submissionError,setSubmissionError]=useState('');
 const draftService=useRef(null),draft=useRef(null);
 useEffect(()=>{if(originalCatalog)setRebookingCatalog(null);},[originalCatalog]);
 const c=copy[lang],services=(catalog?.services||[]).filter(row=>row.active!==false&&!['draft','archived'].includes(row.status)&&row.online_booking_enabled!==false),[step,setStep]=useState(0),[serviceId,setServiceId]=useState(''),[method,setMethod]=useState(''),[staffId,setStaffId]=useState(''),[calendars,setCalendars]=useState([]),[calendarBusy,setCalendarBusy]=useState(false),[date,setDate]=useState(''),[slots,setSlots]=useState([]),[slotBusy,setSlotBusy]=useState(false),[start,setStart]=useState(''),[availableStaff,setAvailableStaff]=useState([]),[staffBusy,setStaffBusy]=useState(false),[name,setName]=useState(''),[phone,setPhone]=useState(''),[note,setNote]=useState(''),[error,setError]=useState(''),[submitting,setSubmitting]=useState(false),[receipt,setReceipt]=useState(null);
 const now=useBookingClock(slots.filter(row=>row.available).map(row=>Date.parse(row.starts_at)-30*60000)),request=useRef(null),today=taipeiDate(new Date(now)),currentMonth=monthKey(today),months=[currentMonth,monthKey(today,1)],availabilityStaff=method==='staff'?staffId:null,service=services.find(row=>row.id===serviceId),qualified=(catalog?.staff||[]).filter(st=>st.active!==false&&(!st.employment_status||st.employment_status==='active')&&!st.archived_at&&st.is_bookable!==false&&(catalog?.skills||[]).some(sk=>sk.staff_id===st.id&&sk.service_id===serviceId&&sk.enabled!==false));
 const chosenStaff=(catalog?.staff||[]).find(row=>row.id===staffId);
 draft.current={start,staffId,now};
 const availabilityActive=step>=2&&!receipt&&!submitting&&!rebookingBusy;
 useLiveRefresh(()=>setAvailabilityVersion(value=>value+1),{audience:'public',scopes:['catalog','hours','availability'],enabled:!!catalog&&!receipt,paused:submitting||rebookingBusy,protectEditing:false});
 useEffect(()=>{
  if(!catalog||submitting||receipt)return;
  if(!serviceId){draftService.current=null;return;}
  if(!service||service.active===false||['draft','archived'].includes(service.status)||service.online_booking_enabled===false){
   setStep(0);setStart('');setAvailabilityNotice(lang==='zh'?'所選療程已停止線上預約，請選擇其他服務。您填寫的聯絡資料已保留。':'This treatment is no longer available online. Choose another service; your contact details are saved.');return;
  }
  const previous=draftService.current;
  if(previous?.id===service.id&&(previous.price_cents!==service.price_cents||previous.duration_minutes!==service.duration_minutes||previous.buffer_minutes!==service.buffer_minutes))setAvailabilityNotice(lang==='zh'?'療程價格或時間已更新，請確認目前顯示的內容。':'The treatment price or duration has changed. Please check the updated details.');
  draftService.current={id:service.id,price_cents:service.price_cents,duration_minutes:service.duration_minutes,buffer_minutes:service.buffer_minutes};
  if(method==='staff'&&staffId&&!qualified.some(row=>row.id===staffId)){
   setStep(1);setStaffId('');setStart('');setAvailabilityNotice(lang==='zh'?'原技師目前無法提供此療程，請重新選擇技師。聯絡資料已保留。':'This therapist can no longer provide the treatment. Choose another therapist; your contact details are saved.');
  }
 },[catalog,serviceId,method,staffId,submitting,receipt]);
 useEffect(()=>{
  if(!rebookingIntent)return;
  let live=true;setRebookingBusy(true);setError('');setSubmissionError('');
  publicRpc('spa_catalog').then(current=>{
   if(!live)return;
   const next=resolveRebookingIntent(rebookingIntent,current);
   setRebookingCatalog(current);setServiceId(next.serviceId);setStaffId(next.staffId);setMethod(next.method);setStep(next.step);
   setCalendars([]);setDate('');setStart('');setSlots([]);setAvailableStaff([]);
   setName('');setPhone('');setNote('');setReceipt(null);request.current=null;
   setRebookingNotice(next.reason);setAvailabilityNotice('');setRebookingBusy(false);onRebookingApplied?.(rebookingIntent.id);
  }).catch(e=>{if(live)setError(errorText(e,lang));}).finally(()=>{if(live)setRebookingBusy(false);});
  return()=>{live=false;};
 },[rebookingIntent?.id,rebookingRetry]);
 // Only explicit new search choices clear the date. Server updates keep it.
 function resetAvailability(){setCalendars([]);setDate('');setStart('');setSlots([]);setAvailableStaff([]);setSubmissionError('');}
 useEffect(()=>{
  if(!availabilityActive||!serviceId||!service||!method||(method==='staff'&&!availabilityStaff))return;
  let live=true;setCalendarBusy(true);setError('');
  Promise.all(months.map(month=>publicRpc('spa_booking_calendar',{p_service:serviceId,p_month:`${month}-01`,p_staff:availabilityStaff})))
   .then(rows=>{if(live)setCalendars(rows);})
   .catch(e=>{if(live){setCalendars([]);setError(errorText(e,lang));}})
   .finally(()=>{if(live)setCalendarBusy(false);});
  return()=>{live=false;};
 },[availabilityActive,serviceId,method,availabilityStaff,today,catalog,availabilityVersion]);
 useEffect(()=>{
  if(!availabilityActive||!date||!serviceId||!service)return;
  let live=true;setSlotBusy(true);setError('');
  publicRpc('spa_public_slots',{p_service:serviceId,p_date:date,p_staff:availabilityStaff}).then(rows=>{
   if(!live)return;
   setSlots(rows);
   const selected=draft.current.start;
   if(selected&&!rows.some(row=>row.starts_at===selected&&row.available&&Date.parse(row.starts_at)>draft.current.now+30*60000)){
    setStart('');setAvailabilityNotice(lang==='zh'?'所選時段已無法預約，請選擇其他時間。日期和聯絡資料已保留。':'The selected time is no longer available. Choose another time; your date and contact details are saved.');setStep(2);
   }
  }).catch(e=>{if(live){setSlots([]);setStart('');setStep(2);setError(errorText(e,lang));}}).finally(()=>{if(live)setSlotBusy(false);});
  return()=>{live=false;};
 },[availabilityActive,date,serviceId,method,availabilityStaff,today,catalog,availabilityVersion]);
 useEffect(()=>{
  if(!availabilityActive||method!=='time'||!start){setAvailableStaff([]);return;}
  let live=true;setStaffBusy(true);
  publicRpc('spa_public_available_staff',{p_service:serviceId,p_date:date,p_start:start}).then(rows=>{
   if(!live)return;
   setAvailableStaff(rows);
   const selected=draft.current.staffId;
   if(selected&&!(selected==='any'&&rows.length)&&!rows.some(row=>row.id===selected)){
    setStaffId('');setAvailabilityNotice(lang==='zh'?'所選技師已無法服務此時段，請重新選擇。聯絡資料已保留。':'The selected therapist is no longer available at this time. Choose another therapist; your contact details are saved.');setStep(2);
   }
  }).catch(e=>{if(live){setAvailableStaff([]);setStaffId('');setStep(2);setError(errorText(e,lang));}}).finally(()=>{if(live)setStaffBusy(false);});
  return()=>{live=false;};
 },[availabilityActive,method,start,date,serviceId,catalog,availabilityVersion]);
 useEffect(()=>{
  if(submitting||receipt||!slots.some(row=>row.available&&Date.parse(row.starts_at)<=now+30*60000))return;
  setSlots(previous=>previous.map(row=>Date.parse(row.starts_at)>now+30*60000?row:{...row,available:false}));
  if(start&&Date.parse(start)<=now+30*60000){setStart('');setStep(2);setAvailabilityNotice(lang==='zh'?'所選時段已超過線上預約期限，請選擇其他時間。聯絡資料已保留。':'The selected time has passed the online booking deadline. Choose another time; your contact details are saved.');}
 },[now,slots,start,submitting,receipt]);
 const grouped=useMemo(()=>Object.fromEntries(['morning','afternoon','evening'].map(period=>[period,slots.filter(row=>row.available&&Date.parse(row.starts_at)>now+30*60000&&periodOf(row.time_label)===period)])),[slots,now]);
 const canLeaveMethod=service&&method&&!(method==='staff'&&!staffId),canLeaveTime=service&&(method!=='staff'||qualified.some(row=>row.id===staffId))&&calendars.some(calendar=>calendar.days.some(day=>day.date===date&&day.status==='open'))&&!calendarBusy&&!slotBusy&&date&&start&&slots.some(row=>row.starts_at===start&&row.available&&Date.parse(row.starts_at)>now+30*60000)&&(method!=='time'||(!staffBusy&&availableStaff.length>0&&(staffId==='any'||availableStaff.some(row=>row.id===staffId))));
 function reset(){setStep(0);setServiceId('');setMethod('');setStaffId('');setCalendars([]);setDate('');setStart('');setSlots([]);setAvailableStaff([]);setName('');setPhone('');setNote('');setError('');setSubmissionError('');setReceipt(null);setRebookingNotice('');setAvailabilityNotice('');draftService.current=null;request.current=null;}
 async function submit(){
  if(submitting||!canLeaveTime||catalogError||!name.trim()||!phone.trim())return;
  setSubmitting(true);setError('');setSubmissionError('');
  try{
   const assigned=method==='any'||staffId==='any'?null:staffId;
   const payload={p_service:serviceId,p_date:date,p_start:start,p_staff:assigned,p_name:name.trim(),p_phone:phone.trim(),p_tea:0,p_note:note},fingerprint=JSON.stringify(payload);
   if(request.current?.fingerprint!==fingerprint)request.current={fingerprint,id:createRequestId()};
   setReceipt(await publicRpc('spa_create_booking',{p_request:request.current.id,...payload}));
  }catch(e){
   setSubmissionError(errorText(e,lang));
   if(e.message?.includes('SLOT_TAKEN')||e.message?.includes('INVALID_DATE')){setStep(2);setStart('');setAvailabilityVersion(value=>value+1);}
  }finally{setSubmitting(false);}
 }
 if(rebookingIntent||rebookingBusy)return <div className="booking-experience"><p className="booking-loading" role="status">{lang==='zh'?'正在核對目前療程、技師與價格…':'Checking current services, therapists and prices…'}</p>{error&&<><p className="booking-error" role="alert">{error}</p><div className="booking-actions"><button className="outline-btn" onClick={()=>{onRebookingApplied?.(rebookingIntent?.id);setRebookingBusy(false);reset();}}>{lang==='zh'?'重新選擇服務':'Choose a service'}</button><button className="gold-btn" disabled={rebookingBusy} onClick={()=>setRebookingRetry(value=>value+1)}>{lang==='zh'?'重新載入':'Try again'}</button></div></>}</div>;
 if(receipt)return <div className="booking-experience booking-success"><div className="booking-check">✓</div><h3>{c.success}</h3><p><strong>{receipt.reference}</strong></p><div className="booking-receipt"><span>{c.assigned}</span><strong>{receipt.staff_name}</strong><small>{receipt.booking_preference==='designated'?c.designated:c.automatic}</small></div><a href={`#manage/${receipt.manage_token}`}>{c.manage}</a><button className="outline-btn" onClick={reset}>{c.again}</button></div>;
 return <div className="booking-experience">
  {(submitting||submissionError)&&<p className="lookup-help" role="status">{submitting?(lang==='zh'?'正在送出預約，請稍候。':'Submitting your booking. Please wait.')+' ':''}{lang==='zh'?'預約服務檢查碼：':'Booking service check: '}{PUBLIC_BOOKING_RELEASE}</p>}
  {(catalogError||submissionError||error)&&<><p className="booking-error" role="alert">{catalogError||submissionError||error}</p><button className="outline-btn" disabled={calendarBusy||slotBusy||staffBusy||submitting} onClick={()=>{if(catalogError)onCatalogRetry?.();setAvailabilityVersion(value=>value+1);}}>{catalogError?(lang==='zh'?'重新載入服務':'Reload services'):(lang==='zh'?'重新載入時段':'Reload availability')}</button></>}
  {availabilityNotice&&<p className="lookup-help" role="status">{availabilityNotice}</p>}
  {rebookingNotice&&<p className="lookup-help" role="status">{rebookingNotice==='service-unavailable'?(lang==='zh'?'原療程目前無法線上預約，請選擇其他服務。':'The previous treatment is unavailable online. Please choose another service.'):rebookingNotice==='therapist-unavailable'?(lang==='zh'?'已選好原療程；原技師目前無法提供此療程，請重新選擇預約方式。':'Your previous treatment is selected. Please choose a booking method because the previous therapist is unavailable for it.'):(lang==='zh'?'已選好原療程與實際服務技師。請重新選擇日期與時間，費用以目前顯示的價格為準。':'Your previous treatment and actual therapist are selected. Choose a new date and time; current displayed prices apply.')}</p>}
  <ol className="booking-flow-progress">{c.steps.map((label,i)=><li className={i===step?'active':i<step?'done':''} key={label}><i>{i<step?'✓':i+1}</i><span>{label}</span></li>)}</ol>
  {step===0&&<section><h3>{c.service}</h3><div className="booking-service-grid">{services.map(row=><button key={row.id} className={serviceId===row.id?'selected':''} onClick={()=>{setServiceId(row.id);resetAvailability();}}><strong>{publicName(row,lang)}</strong><span>{row.duration_minutes} min · {money(row.price_cents)}</span></button>)}</div><div className="booking-actions"><button className="gold-btn" disabled={!service} onClick={()=>setStep(1)}>{c.next}</button></div></section>}
  {step===1&&<section><h3>{c.method}</h3><div className="booking-method-grid"><button className={method==='staff'?'selected':''} onClick={()=>{setMethod('staff');setStaffId('');resetAvailability();}}><b>◎</b><strong>{c.staff}</strong><span>{c.staffSub}</span></button><button className={method==='time'?'selected':''} onClick={()=>{setMethod('time');setStaffId('');resetAvailability();}}><b>◷</b><strong>{c.time}</strong><span>{c.timeSub}</span></button></div><button className={`booking-any-method ${method==='any'?'selected':''}`} onClick={()=>{setMethod('any');setStaffId('any');resetAvailability();}}><span><strong>{c.any}</strong><small>{c.anySub}</small></span><b>›</b></button>{method==='staff'&&<><h4>{c.chooseStaff}</h4><div className="booking-staff-grid">{qualified.map(row=><button key={row.id} className={staffId===row.id?'selected':''} onClick={()=>{setStaffId(row.id);resetAvailability();}}><i>{row.name.slice(0,1)}</i><span><strong>{publicName(row,lang)}</strong><small>{publicTitle(row,lang)}</small></span></button>)}</div></>}<div className="booking-actions"><button className="outline-btn" onClick={()=>setStep(0)}>{c.back}</button><button className="gold-btn" disabled={!canLeaveMethod} onClick={()=>setStep(2)}>{c.next}</button></div></section>}
  {step===2&&<section><h3>{c.chooseDate}</h3>{calendarBusy?<p className="booking-loading">{c.loading}</p>:<div className="booking-two-months">{calendars.map(calendar=><article key={calendar.month}><h4>{monthLabel(calendar.month,lang)}</h4><div className="booking-calendar-week">{(lang==='zh'?['一','二','三','四','五','六','日']:['M','T','W','T','F','S','S']).map((x,i)=><span key={`${x}-${i}`}>{x}</span>)}</div><div className="booking-calendar-grid">{monthCells(calendar.month).map((day,i)=>{if(!day)return <span className="blank" key={`blank-${i}`}/>;const row=calendar.days.find(item=>item.date===day),enabled=row?.status==='open';return <button key={day} disabled={!enabled} className={`${row?.status||'off'} ${date===day?'selected':''}`} onClick={()=>{setDate(day);setStart('');setAvailableStaff([]);}}><strong>{Number(day.slice(-2))}</strong><small>{row?.status==='open'?(method==='staff'?`${String(Math.floor(row.start_minute/60)%24).padStart(2,'0')}:${String(row.start_minute%60).padStart(2,'0')}–${String(Math.floor(row.end_minute/60)%24).padStart(2,'0')}:${String(row.end_minute%60).padStart(2,'0')}`:`${row.available_staff} ${c.people}`):row?.status==='full'?c.full:row?.status==='past'?'':c.off}</small></button>;})}</div></article>)}</div>}
  {date&&<><h4>{c.chooseSlot} · {date}</h4>{slotBusy?<p className="booking-loading">{c.loading}</p>:<div className="booking-slot-groups">{Object.entries(grouped).map(([period,rows])=>rows.length?<div key={period}><h5>{periodNames[lang][period]}</h5><div>{rows.map(row=><button key={row.starts_at} className={start===row.starts_at?'selected':''} onClick={()=>{setStart(row.starts_at);if(method==='time')setStaffId('');}}><strong>{slotLabel(row.time_label,lang)}</strong>{method!=='staff'&&<small>{row.available_staff_count} {c.people}</small>}</button>)}</div></div>:null)}</div>}</>}
  {method==='time'&&start&&<><h4>{c.chooseAfter}</h4><div className="booking-staff-grid after-time"><button className={staffId==='any'?'selected':''} onClick={()=>setStaffId('any')}><i>✦</i><span><strong>{c.noPreference}</strong><small>{c.automatic}</small></span></button>{availableStaff.map(row=><button key={row.id} className={staffId===row.id?'selected':''} onClick={()=>setStaffId(row.id)}><i>{row.name.slice(0,1)}</i><span><strong>{publicName(row,lang)}</strong><small>{publicTitle(row,lang)}</small></span></button>)}</div></>}
  <div className="booking-actions"><button className="outline-btn" onClick={()=>setStep(1)}>{c.back}</button><button className="gold-btn" disabled={!canLeaveTime} onClick={()=>setStep(3)}>{c.next}</button></div></section>}
  {step===3&&<section><h3>{c.summary}</h3><dl className="booking-summary"><dt>{lang==='zh'?'服務':'Service'}</dt><dd>{publicName(service,lang)}</dd><dt>{lang==='zh'?'預約方式':'Method'}</dt><dd>{method==='staff'?therapistLabel(chosenStaff,lang):method==='time'&&staffId!=='any'?therapistLabel(chosenStaff,lang):c.any}</dd><dt>{lang==='zh'?'日期／時間':'Date / time'}</dt><dd>{date} · {slotLabel(slots.find(row=>row.starts_at===start)?.time_label,lang)}</dd><dt>{lang==='zh'?'費用':'Price'}</dt><dd>{money(service?.price_cents)}</dd></dl><div className="booking-contact-form"><input autoComplete="name" maxLength="80" value={name} onChange={e=>setName(e.target.value)} placeholder={c.name}/><input autoComplete="tel" type="tel" maxLength="25" value={phone} onChange={e=>setPhone(e.target.value)} placeholder={c.phone}/><p>{c.member}</p><textarea maxLength="1000" rows="3" value={note} onChange={e=>setNote(e.target.value)} placeholder={c.note}/></div><div className="booking-actions"><button className="outline-btn" onClick={()=>setStep(2)}>{c.back}</button><button className="gold-btn" disabled={!name.trim()||!phone.trim()||submitting||!canLeaveTime||!!catalogError} onClick={submit}>{submitting?c.submitting:c.confirm}</button></div></section>}
 </div>;
}
