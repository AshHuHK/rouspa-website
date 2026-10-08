import { useEffect, useRef, useState } from 'react';
import { rpc, errorText, dateTime } from './lib/spa.js';
import './convenience.css';

const bedNames={free:'空檔',reserved:'預定',treatment:'療程中',buffer:'緩衝'};
const taskLabels={urgent:'待處理',normal:'待核對',waiting:'等待確認'};
const time=value=>new Intl.DateTimeFormat('zh-TW',{timeZone:'Asia/Taipei',hour:'2-digit',minute:'2-digit',hour12:false}).format(new Date(value));

export function OperationsConvenience({refreshToken,onNavigate,allowed}){
 const [data,setData]=useState(null),[busy,setBusy]=useState(true),[error,setError]=useState('');
 const sequence=useRef(0),running=useRef(false),loadRef=useRef(null);
 async function load(){if(running.current)return;running.current=true;const request=++sequence.current;setBusy(true);try{const next=await rpc('spa_operations_convenience');if(request===sequence.current){setData(next);setError('');}}catch(e){if(request===sequence.current){setError(errorText(e));if(e.message?.includes('FORBIDDEN'))setData(null);}}finally{running.current=false;if(request===sequence.current)setBusy(false);}}
 loadRef.current=load;
 useEffect(()=>{loadRef.current();const update=()=>{if(document.visibilityState==='visible'&&navigator.onLine!==false)loadRef.current();};const timer=window.setInterval(update,15000);window.addEventListener('focus',update);window.addEventListener('online',update);document.addEventListener('visibilitychange',update);return()=>{window.clearInterval(timer);window.removeEventListener('focus',update);window.removeEventListener('online',update);document.removeEventListener('visibilitychange',update);};},[refreshToken]);
 useEffect(()=>()=>{sequence.current++;},[]);
 const canOpen=module=>!!onNavigate&&(!allowed||allowed(module));
 const go=(module,context)=>{if(canOpen(module))onNavigate(module,context);};
 const beds=data?.beds||[],todos=(data?.todos||[]).filter(task=>task.count>0&&(!allowed||allowed(task.module)));
 return <div className="ops-convenience">
  <section className="card ops-bed-board" aria-labelledby="ops-bed-board-title">
   <div className="ops-convenience-heading"><div><p className="eyebrow">LIVE RESOURCES</p><h2 id="ops-bed-board-title">床位即時總覽</h2><p className="muted">同時查看預約、到店狀態與清潔緩衝，床位和預約共用正式排程。</p></div><button disabled={busy} onClick={load}>{busy?'更新中…':'更新狀態'}</button></div>
   {error&&<p className="alert" role="alert">{error}{data?'；以下保留上次成功讀取的狀態。':''}</p>}
   {!data&&busy&&<p className="empty" role="status">正在讀取床位與待辦…</p>}
   {data&&<><div className="ops-bed-legend" aria-label="床位狀態統計">{Object.entries(bedNames).map(([state,label])=><span className={state} key={state}><i/>{label} <b>{beds.filter(bed=>bed.state===state).length}</b></span>)}</div>
    <div className="ops-bed-grid">{beds.map(bed=>{
     const booking=bed.current||(bed.state==='reserved'?bed.next:null),contextBooking=booking||bed.next;
     return <article className={`ops-bed ${bed.state}`} key={bed.id} aria-label={`${bed.name}，${bedNames[bed.state]}`}>
      <header><span className="ops-bed-icon" aria-hidden="true"><svg viewBox="0 0 36 30" fill="none"><path d="M5 4v22M31 15v11M5 22h26M9 14h19a3 3 0 0 1 3 3v5H5v-8h4Z"/><rect x="8" y="8" width="9" height="6" rx="2"/></svg></span><div><h3>{bed.name}</h3><span className="ops-bed-state">{bedNames[bed.state]}</span></div></header>
      {booking?<div className={`ops-bed-booking ${booking.is_own?'is-own':''}`}><p><strong>{booking.customer_name}</strong><span>{booking.staff_name} · {booking.staff_title}</span></p><p>{booking.service_name}</p><p className="ops-bed-time">{time(booking.starts_at)}–{time(booking.ends_at)}<small>{booking.business_date} 營業日</small></p>{bed.state==='buffer'?<p className="ops-bed-note">保留緩衝至 {time(booking.blocked_until)}</p>:bed.state==='reserved'?<p className="ops-bed-note">{bed.current?'尚未確認到店，請核對預約狀態。':'30 分鐘內有預約，請預先準備。'}</p>:<p className="ops-bed-note">已到店 · 依療程排定時間顯示</p>}{booking.is_own&&<span className="ops-own-badge">我的服務</span>}</div>:<div className="ops-bed-empty"><strong>目前沒有佔用排程</strong><p>{bed.next?`空檔至 ${dateTime(bed.next.starts_at)}`:'未來 48 小時沒有已排定預約。'}</p></div>}
      {bed.next&&bed.next.id!==booking?.id&&<div className="ops-bed-next"><span>下一筆</span><strong>{dateTime(bed.next.starts_at)}</strong><small>{bed.next.customer_name} · {bed.next.staff_name}</small></div>}
      {bed.overlap_count>1&&<p className="alert" role="alert">這張床有重疊排程，請核對工作台。</p>}
      {contextBooking&&canOpen('bookings')&&<button onClick={()=>go('bookings',{from:contextBooking.business_date,to:contextBooking.business_date,room_id:bed.id})}>查看這一天的排程</button>}
     </article>;
    })}</div>{!beds.length&&<p className="empty">目前沒有啟用的床位，請由店主核對資源設定。</p>}
    <p className="ops-convenience-footnote">「療程中」需已到店，並在排定服務時間內；「緩衝」依預約保留到清潔緩衝結束，僅表示排程狀態。實際清潔與是否可接客仍由門店核對。<span>台灣伺服器時間：{dateTime(data.server_time)} · 每 15 秒更新</span></p>
   </>}
  </section>
  {data&&<section className="card ops-todo-center" aria-labelledby="ops-todo-title"><div className="ops-convenience-heading"><div><p className="eyebrow">NEXT ACTIONS</p><h2 id="ops-todo-title">{data.is_owner?'營運待辦中心':'我的工作提醒'}</h2><p className="muted">{data.is_owner?'從提醒直接前往原本的處理頁面，核對後再操作。':'查看自己的排程、出勤與班表提交狀態。'}</p></div><span className="ops-todo-total">{todos.length} 類提醒</span></div>
   {todos.length?<div className="ops-todo-grid">{todos.map(task=><button key={task.key} className={`ops-todo ${task.severity}`} disabled={!canOpen(task.module)} onClick={()=>go(task.module,task.context)}><span className="ops-todo-tag">{taskLabels[task.severity]||taskLabels.normal}</span><strong className="ops-todo-count">{task.count}</strong><h3>{task.title}</h3><p>{task.description}</p><span className="ops-todo-open">{task.severity==='waiting'?'查看狀態':'前往查看'} <i aria-hidden="true">↗</i></span></button>)}</div>:<p className="empty">目前沒有需要處理的提醒。</p>}
   <p className="ops-convenience-footnote">一般待辦涵蓋 {data.window.from} ～ {data.window.to}；到店與近期服務依今日及跨日排程顯示。下月班表為 {data.target_month.slice(0,7)}，商品庫存以目前啟用項目為準。</p>
  </section>}
 </div>;
}
