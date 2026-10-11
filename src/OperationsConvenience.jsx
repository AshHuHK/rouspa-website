import { dateTime } from './lib/spa.js';
import { useOperationsSnapshot } from './lib/useOperationsSnapshot.js';
import { activeOperationsTodos, operationsTodoTotal } from './lib/operations-notifications.js';
import './convenience.css';

const taskLabels={urgent:'待處理',normal:'待核對',waiting:'等待確認'};

export function OperationsConvenience({refreshToken,onNavigate,allowed,userKey}){
 const {data,busy,error,refresh:load}=useOperationsSnapshot({userKey,refreshToken});
 const canOpen=module=>!!onNavigate&&(!allowed||allowed(module));
 const go=(module,context)=>{if(canOpen(module))onNavigate(module,context);};
 const capacity=data?.capacity||{},todos=activeOperationsTodos(data,allowed),todoTotal=operationsTodoTotal(todos);
 return <div className="ops-convenience">
  <section className="card ops-capacity-board" aria-labelledby="ops-capacity-title">
   <div className="ops-convenience-heading"><div><p className="eyebrow">LIVE CAPACITY</p><h2 id="ops-capacity-title">時段接客容量</h2><p className="muted">不記錄床位編號；預約依技師班表與空檔成立，超過建議人數時保留預約並提醒電話協調。</p></div><button disabled={busy} onClick={load}>{busy?'更新中…':'更新狀態'}</button></div>
   {error&&<p className="alert" role="alert">{error}{data?'；以下保留上次成功讀取的狀態。':''}</p>}
   {!data&&busy&&<p className="empty" role="status">正在讀取容量與待辦…</p>}
   {data&&<>
    <div className="ops-capacity-grid">
     <article><span>建議同時接客</span><strong>{capacity.limit??4}</strong><small>位</small></article>
     <article className={capacity.currently_exceeded?'is-warning':''}><span>目前療程中／已保留</span><strong>{capacity.current_guests??0}</strong><small>位</small></article>
     <article className={Number(capacity.pending_attention_count)>0?'is-warning':''}><span>超額待聯絡</span><strong>{capacity.pending_attention_count??0}</strong><small>筆</small></article>
    </div>
    {capacity.currently_exceeded&&<p className="alert" role="alert">目前同時服務人數已超過建議值，請依已確認安排留意現場接待；尚待聯絡的預約會另外列入待辦。</p>}
    {Number(capacity.pending_attention_count)>0&&canOpen('bookings')&&<button className="primary ops-capacity-open" onClick={()=>go('bookings',{from:data.window.from,to:data.window.to,status:'pending',capacity_attention:true})}>查看超額待聯絡預約</button>}
    <p className="ops-convenience-footnote">建議容量是營運提醒，不會阻止顧客提交。沒有合格且空閒的技師時，時段仍不可預約。人數按實際療程開始至結束計算；技師清潔緩衝繼續阻止該技師接下一位。<span>台灣伺服器時間：{dateTime(data.server_time)} · 資料變更時同步更新</span></p>
   </>}
  </section>
  {data&&<section className="card ops-todo-center" aria-labelledby="ops-todo-title"><div className="ops-convenience-heading"><div><p className="eyebrow">NEXT ACTIONS</p><h2 id="ops-todo-title">{data.is_owner?'營運待辦中心':'我的工作提醒'}</h2><p className="muted">{data.is_owner?'從提醒直接前往原本的處理頁面，核對後再操作。':'查看自己的排程、出勤與班表提交狀態。'}</p></div><span className="ops-todo-total">{todoTotal} 項待辦 · {todos.length} 類提醒</span></div>
   {todos.length?<div className="ops-todo-grid">{todos.map(task=><button key={task.key} className={`ops-todo ${task.severity}`} disabled={!canOpen(task.module)} onClick={()=>go(task.module,task.context)}><span className="ops-todo-tag">{taskLabels[task.severity]||taskLabels.normal}</span><strong className="ops-todo-count">{task.count}</strong><h3>{task.title}</h3><p>{task.description}</p><span className="ops-todo-open">{task.severity==='waiting'?'查看狀態':'前往查看'} <i aria-hidden="true">↗</i></span></button>)}</div>:<p className="empty">目前沒有需要處理的提醒。</p>}
   <p className="ops-convenience-footnote">一般待辦涵蓋 {data.window.from} ～ {data.window.to}；到店與近期服務依今日及跨日排程顯示。下月班表為 {data.target_month.slice(0,7)}，商品庫存以目前啟用項目為準。</p>
  </section>}
 </div>;
}
