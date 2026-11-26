import {useEffect,useRef,useState} from 'react';
import {rpc,dateTime,errorText,taipeiDate,exportCSV} from './lib/spa.js';
import { createRequestId } from './lib/request-id.js';
import {attendanceStatuses,attendanceFlags,attendanceMinutes,taipeiInput,attendanceStamp,getPunchLocation,canPunch} from './lib/attendance.js';
import {Field,Modal,MutationForm,Empty} from './OperationsShared.jsx';
import './attendance.css';
import {useLiveRefresh} from './lib/useLiveRefresh.js';

function useAttendance(name,from,to){
 const [data,setData]=useState(null),[error,setError]=useState(''),[loading,setLoading]=useState(false);const sequence=useRef(0);
 async function load(){const id=++sequence.current;setLoading(true);try{const next=await rpc(name,{p_from:from,p_to:to});if(id===sequence.current){setData(next);setError('');}return next;}catch(e){if(id===sequence.current){setError(errorText(e));if(e.message?.includes('FORBIDDEN'))setData(null);}return null;}finally{if(id===sequence.current)setLoading(false);}}
 useEffect(()=>{setData(null);load();return()=>{sequence.current++;};},[name,from,to]);
 useLiveRefresh(load,{audience:'operations',scopes:['attendance','schedule','settings','team','payroll'],paused:loading});
 return {data,error,loading,load};
}
function Flags({flags=[]}){return <div className="attendance-flags">{(flags||[]).map(flag=><span className="badge" key={flag}>{attendanceFlags[flag]||flag}</span>)}</div>;}
function Evidence({events=[]}){return <details className="attendance-evidence"><summary>原始打卡與定位紀錄</summary>{events.length?events.map(e=><div key={e.id}><strong>{e.kind==='in'?'上班':'下班'} · {dateTime(e.recorded_at)}</strong><p>{e.distance_m==null?'未取得定位':`距門店 ${Math.round(e.distance_m)} 公尺 · 定位誤差 ±${Math.round(e.accuracy_m)} 公尺`}</p>{e.latitude!=null&&<a href={`https://www.google.com/maps?q=${e.latitude},${e.longitude}`} target="_blank" rel="noreferrer">查看打卡位置（Google 地圖）</a>}{e.reason&&<p>備註：{e.reason}</p>}<Flags flags={e.flags}/><small className="muted">當時範圍：{e.geofence_snapshot.radius_m} 公尺 · {e.geofence_snapshot.address}</small></div>):<p className="muted">此筆為補打卡，沒有原始定位紀錄。</p>}</details>;}
function AttendanceRow({row,events,breaks=[],action}){return <article className={`attendance-row ${row.status}`}><div className="row"><strong>{row.employee?`${row.employee} · `:''}{row.work_date}</strong><span className="badge">{attendanceStatuses[row.status]}</span></div><p>原始上班：{row.clock_in?dateTime(row.clock_in):'補打卡'}<br/>原始下班：{row.clock_out?dateTime(row.clock_out):(row.clock_in?'尚未打下班卡':'補打卡')}</p><p className="muted">核算時段：{row.effective_start?dateTime(row.effective_start):'—'} ～ {row.effective_end?dateTime(row.effective_end):'—'} · 休息 {row.break_minutes} 分鐘{row.effective_end&&<> · 淨工時 {attendanceMinutes(row)} 分鐘</>}</p>{row.shift_start&&<p className="muted">打卡時班表：{dateTime(row.shift_start)} ～ {dateTime(row.shift_end)}</p>}<Flags flags={row.flags}/>{row.review_note&&<p>審核說明：{row.review_note}</p>}{row.time_entry_id&&row.status==='approved'&&<small className="muted">已連動薪資工時 · {row.time_entry_id.slice(0,8)}</small>}<BreakList rows={breaks}/><Evidence events={events}/>{action}</article>;}

export function AttendanceEmployee({from,to,compact=false}){
 const {data,error,loading,load}=useAttendance('spa_attendance_self',from,to),[savingBreak,setSavingBreak]=useState(false),[busy,setBusy]=useState(false),[message,setMessage]=useState(''),[punchError,setPunchError]=useState(''),[modal,setModal]=useState(null);
 const request=useRef(null),running=useRef(false);const punchState={open:data?.open,loading:loading||!data,busy:busy||savingBreak,error};
 const saved=async()=>{setModal(null);await load();};
 async function punch(kind){if(running.current||!canPunch(kind,punchState))return;running.current=true;setBusy(true);setPunchError('');setMessage('正在取得本次定位…');
  try{const loc=await getPunchLocation();if(loc.error){setMessage('');setPunchError(loc.message);return;}
   if(!request.current||request.current.kind!==kind)request.current={kind,id:createRequestId()};
   await rpc('spa_attendance_punch_v2',{p_request:request.current.id,p_kind:kind,p_latitude:loc.latitude,p_longitude:loc.longitude,p_accuracy:loc.accuracy});
   request.current=null;setMessage(kind==='in'?'已記錄上班。下班時請再次打卡。':'已記錄下班，待店主審核後計入薪資工時。');await load();
  }catch(e){setMessage('');setPunchError(errorText(e));await load();}finally{running.current=false;setBusy(false);}
 }
 const breaksFor=id=>(data?.breaks||[]).filter(row=>row.attendance_id===id);
 const records=data&&<>
 <h3>本期出勤紀錄</h3>{!data.rows.length&&<Empty>所選期間沒有出勤紀錄。</Empty>}{data.rows.map(row=><AttendanceRow key={row.id} row={row} breaks={breaksFor(row.id)} events={data.events.filter(e=>e.attendance_id===row.id)} action={<div className="actions"><button disabled={busy||data.requests.some(r=>r.attendance_id===row.id&&r.status==='pending')} onClick={()=>setModal({row})}>申請補卡／更正</button></div>}/>)}
 {data.open&&!data.rows.some(r=>r.id===data.open.id)&&<AttendanceRow row={data.open} breaks={breaksFor(data.open.id)} events={data.events.filter(e=>e.attendance_id===data.open.id)} action={<button onClick={()=>setModal({row:data.open})}>申請補卡／更正</button>}/>}
 <h3>補打卡與更正申請</h3>{!data.requests.length&&<Empty>目前沒有申請。</Empty>}{data.requests.map(r=><div className="attendance-row" key={r.id}><strong>{r.work_date} · {{pending:'待審核',approved:'已核准',rejected:'已退回'}[r.status]}</strong><RequestTimes row={r}/><p>{r.reason}</p>{r.review_note&&<p className="muted">審核：{r.review_note}</p>}</div>)}
 </>;
 return <section id="my-attendance" className="card attendance-workspace"><div className="os-page-title"><div><p className="eyebrow">ATTENDANCE</p><h2>我的出勤打卡</h2></div><button disabled={busy||loading} onClick={load}>更新出勤</button></div>
 {error&&<p className="alert" role="alert">{error}</p>}{data&&<><div className="attendance-punch-layout">
  <div><span role="status" className={data.open?'attendance-state is-working':'attendance-state'}><i/>{data.open?'上班中':'未上班／已下班'}</span>{data.open&&<p>上班時間：{dateTime(data.open.clock_in)}</p>}
   <div className="attendance-punch-actions"><button className="primary attendance-punch" disabled={!canPunch('in',punchState)} onClick={()=>punch('in')}>上班打卡</button><button className="primary attendance-punch" disabled={!canPunch('out',punchState)} onClick={()=>punch('out')}>下班打卡</button></div>
  </div>
  <CorrectionForm saved={load} disabled={busy}/>
 </div>
 <div className="attendance-break-section"><h3>休息時間</h3>{data.open?<BreakRecorder key={data.open.id} attendance={data.open} rows={breaksFor(data.open.id)} disabled={busy||loading} setSaving={setSavingBreak} saved={load}/>:<p className="muted">上班打卡後可記錄休息。</p>}</div>
 {message&&<p role="status">{message}</p>}{punchError&&<p className="alert" role="alert">{punchError}</p>}<div className="attendance-summary"><span>本期核准工時 <strong>{data.rows.filter(r=>r.status==='approved').reduce((sum,r)=>sum+attendanceMinutes(r),0)} 分鐘</strong></span><span>待審核 <strong>{data.rows.filter(r=>r.status==='pending').length} 筆</strong></span></div>
 {compact?<details className="attendance-records"><summary>本期出勤紀錄與更正申請</summary>{records}</details>:records}
 </>}{!data&&!error&&<Empty>載入出勤資料…</Empty>}{modal&&<Modal title="補打卡／工時更正申請" onClose={()=>setModal(null)}><CorrectionForm row={modal.row} saved={saved}/></Modal>}</section>;
}
function BreakList({rows}){
 if(!rows.length)return null;
 return <ul className="attendance-break-list">{rows.map((row,index)=><li key={row.id}>第 {index+1} 段 · <time dateTime={row.starts_at}>{dateTime(row.starts_at)}</time> 至 <time dateTime={row.ends_at}>{dateTime(row.ends_at)}</time></li>)}</ul>;
}
function BreakRecorder({attendance,rows,disabled,setSaving,saved}){
 const [adding,setAdding]=useState(rows.length===0),[start,setStart]=useState(''),[end,setEnd]=useState('');
 const earliest=taipeiInput(attendance.clock_in);
 return <><BreakList rows={rows}/>{rows.length>0&&<p>合計休息 {attendance.break_minutes} 分鐘</p>}{adding?
  <MutationForm disabled={disabled} submit="確認送出" action={async id=>{
   setSaving(true);
   try{await rpc('spa_attendance_break_add',{p_request:id,p_attendance:attendance.id,p_start:attendanceStamp(start),p_end:attendanceStamp(end)});}finally{setSaving(false);}
  }} onSaved={async()=>{setAdding(false);setStart('');setEnd('');await saved();}}>
   <div className="form-grid"><Field label="開始休息（台灣時間）"><input type="datetime-local" required min={earliest} value={start} onChange={e=>setStart(e.target.value)}/></Field><Field label="結束休息（台灣時間）"><input type="datetime-local" required min={start||earliest} value={end} onChange={e=>setEnd(e.target.value)}/></Field></div>
   <small className="muted">送出後即鎖定此段時間。</small>
  </MutationForm>:<button type="button" disabled={disabled} onClick={()=>setAdding(true)}>{rows.length===1?'＋ 新增第二段休息':'＋ 新增休息時段'}</button>}</>;
}
function CorrectionForm({row,saved,disabled}){
 const [reason,setReason]=useState(''),[sent,setSent]=useState(false);
 return <div className="attendance-quick-request"><MutationForm disabled={disabled||!reason.trim()} action={id=>rpc('spa_attendance_request_quick',{p_request:id,p_attendance:row?.id||null,p_reason:reason})} onSaved={async()=>{setReason('');setSent(true);await saved();}} submit="送出">
  <Field label="補打卡原因"><input required maxLength={1000} placeholder="例如：昨晚 22:15 漏打下班卡" value={reason} onChange={e=>{setReason(e.target.value);setSent(false);}}/></Field>
 </MutationForm>{sent&&<p role="status">已送交店主審核。</p>}</div>;
}
function RequestTimes({row}){
 return row.proposed_start?<p>{dateTime(row.proposed_start)} ～ {dateTime(row.proposed_end)} · 休息 {row.break_minutes} 分鐘</p>:null;
}
function TimeFields({date,setDate,start,setStart,end,setEnd,rest,setRest,lockRest=false}){return <div className="form-grid"><Field label="營業日"><input type="date" required max={taipeiDate()} disabled={!setDate} value={date} onChange={e=>setDate?.(e.target.value)}/></Field><Field label="不計薪休息（分鐘）"><input required type="number" min="0" step="1" readOnly={lockRest} value={rest} onChange={e=>setRest(e.target.value)}/></Field><Field label="實際開始（台灣時間）"><input required type="datetime-local" value={start} onChange={e=>setStart(e.target.value)}/></Field><Field label="實際結束（台灣時間）"><input required type="datetime-local" min={start} value={end} onChange={e=>setEnd(e.target.value)}/></Field></div>;}

export function AttendanceManager({initialRange}={}){
 const [period,setPeriod]=useState(null),[filter,setFilter]=useState('attention'),[person,setPerson]=useState('all'),[modal,setModal]=useState(null),[selected,setSelected]=useState([]);
 const from=period?.from??null,to=period?.to??null;
 useEffect(()=>{if(initialRange)setPeriod(null);},[initialRange]);
 const {data,error,loading,load}=useAttendance('spa_attendance_queue',from,to);
 useEffect(()=>setSelected([]),[data]);
 const saved=async()=>{setModal(null);await load();};
 const pending=(data?.rows||[]).filter(row=>row.status==='pending'&&(person==='all'||row.staff_id===person)&&!(data?.requests||[]).some(request=>request.attendance_id===row.id&&request.status==='pending'));
 const picked=pending.filter(row=>selected.some(item=>item.id===row.id&&item.version===row.version));
 const toggle=row=>setSelected(items=>items.some(item=>item.id===row.id)?items.filter(item=>item.id!==row.id):[...items,{id:row.id,version:row.version}]);
 const breaksFor=id=>(data?.breaks||[]).filter(row=>row.attendance_id===id);
 const rows=(data?.rows||[]).filter(r=>(person==='all'||r.staff_id===person)&&(filter==='all'||filter==='attention'&&['open','pending'].includes(r.status)||r.status===filter));
 return <section id="attendance-review" className="card attendance-workspace"><div className="os-page-title"><div><p className="eyebrow">ATTENDANCE CONTROL</p><h2>出勤與打卡審核</h2><p className="muted">店主專用。核准工時直接進入薪資；加班費仍使用「薪資與提成」的加班核准流程。</p></div><div className="actions"><button disabled={!data} onClick={()=>setModal({kind:'settings'})}>打卡範圍設定</button><button disabled={loading} onClick={load}>更新</button></div></div>
 <div className="toolbar"><Field label="半月審核批次"><select disabled={!data||loading} value={data?.period?.from||''} onChange={e=>{const next=data.periods.find(row=>row.from===e.target.value);setPeriod(next);setSelected([]);}}>
 {(data?.periods||[]).map(row=><option key={row.from} value={row.from}>{row.from} ～ {row.to}{row.pending_count+row.request_count>0?' · 待處理 '+(row.pending_count+row.request_count)+' 筆':''}</option>)}</select></Field><Field label="出勤狀態"><select value={filter} onChange={e=>setFilter(e.target.value)}><option value="attention">待審核</option><option value="all">全部出勤</option>{Object.entries(attendanceStatuses).filter(([id])=>id!=='open').map(([id,label])=><option key={id} value={id}>{label}</option>)}</select></Field><Field label="出勤人員"><select value={person} onChange={e=>setPerson(e.target.value)}><option value="all">全部人員</option>{[...new Map((data?.rows||[]).map(r=>[r.staff_id,r])).values()].map(r=><option key={r.staff_id} value={r.staff_id}>{r.employee}</option>)}</select></Field><button disabled={!rows.length} onClick={()=>exportCSV('出勤紀錄.csv',rows.map(r=>({人員:r.employee,營業日:r.work_date,原始上班:r.clock_in?dateTime(r.clock_in):'',原始下班:r.clock_out?dateTime(r.clock_out):'',核算開始:r.effective_start?dateTime(r.effective_start):'',核算結束:r.effective_end?dateTime(r.effective_end):'',休息分鐘:r.break_minutes,休息時段:breaksFor(r.id).map(b=>dateTime(b.starts_at)+' 至 '+dateTime(b.ends_at)).join('；'),淨工時分鐘:attendanceMinutes(r),狀態:attendanceStatuses[r.status],異常:(r.flags||[]).map(f=>attendanceFlags[f]||f).join('、'),審核說明:r.review_note})))}>匯出出勤 CSV</button></div>
 {error&&<p role="alert" className="alert">{error}</p>}{data&&<><p className="muted">1～15 日於每月 16 日開放審核；16 日～月底於月底開放。尚未審核的批次會持續保留。</p>
 {Number(data.unclosed_count)>0&&<p className="alert">{data.unclosed_count} 筆仍未打下班卡，補齊後會加入本批次。</p>}<div className="attendance-summary"><span>待審核 <strong>{data.rows.filter(r=>r.status==='pending').length} 筆</strong></span><span>待處理申請 <strong>{data.requests.filter(r=>r.status==='pending').length} 筆</strong></span></div>
 <h3>補打卡與更正申請</h3>{!data.requests.some(r=>r.status==='pending')&&<Empty>沒有待處理申請。</Empty>}{data.requests.filter(r=>r.status==='pending'&&(person==='all'||r.staff_id===person)).map(r=><article className="attendance-row" key={r.id}><strong>{r.employee} · {r.work_date}</strong><RequestTimes row={r}/><p>{r.reason}</p><button onClick={()=>setModal({kind:'request',row:r,attendance:[...data.rows,...(data.request_attendance||[])].find(row=>row.id===r.attendance_id),breaks:breaksFor(r.attendance_id)})}>審核申請</button></article>)}
 <div className="attendance-batch-toolbar">
 <label className="attendance-select"><input type="checkbox" disabled={!pending.length} checked={pending.length>0&&picked.length===pending.length} onChange={e=>setSelected(e.target.checked?pending.map(row=>({id:row.id,version:row.version})):[])}/>選取本批次待審核紀錄</label>
 <button className="primary" disabled={!picked.length||loading} onClick={()=>setModal({kind:'batch',rows:picked})}>核准所選 {picked.length} 筆</button>
 </div>
 <h3>出勤紀錄</h3>{!rows.length&&<Empty>此篩選沒有出勤紀錄。</Empty>}{rows.map(row=><AttendanceRow key={row.id} row={row} breaks={breaksFor(row.id)} events={data.events.filter(e=>e.attendance_id===row.id)} action={<div className="actions">{row.status==='pending'&&<label className="attendance-select"><input type="checkbox" disabled={!pending.some(item=>item.id===row.id)} checked={picked.some(item=>item.id===row.id)} onChange={()=>toggle(row)}/>加入批次核准</label>}<button onClick={()=>setModal({kind:'review',row})}>{row.status==='approved'?'更正／撤回核准':'審核工時'}</button></div>}/>)}</>}
 {modal&&<Modal title={{settings:'門店打卡範圍',request:'審核補打卡／更正',review:'審核出勤工時',batch:'確認批次核准'}[modal.kind]} onClose={()=>setModal(null)}>{modal.kind==='batch'?<BatchReview rows={modal.rows} saved={saved}/>:modal.kind==='settings'?<AttendanceSettings value={data.settings} saved={saved}/>:modal.kind==='request'?<RequestReview row={modal.row} attendance={modal.attendance} breaks={modal.breaks} saved={saved}/>:<AttendanceReview row={modal.row} breaks={breaksFor(modal.row.id)} saved={saved}/>}</Modal>}</section>;
}
function BatchReview({rows,saved}){
 const [reason,setReason]=useState('');
 return <MutationForm submit={'確認核准 '+rows.length+' 筆'} action={()=>rpc('spa_attendance_batch_review',{p_rows:rows.map(row=>({id:row.id,version:row.version})),p_reason:reason})} onSaved={saved}>
  <p>所選合計 {rows.reduce((sum,row)=>sum+attendanceMinutes(row),0)} 淨工時分鐘。請核對原始打卡、休息及異常標記。</p>
  <ul>{rows.map(row=><li key={row.id}>{row.employee} · {row.work_date} · {attendanceMinutes(row)} 分鐘<Flags flags={row.flags}/></li>)}</ul>
  <Field label="批次審核說明"><input required maxLength={1000} value={reason} onChange={e=>setReason(e.target.value)}/></Field>
 </MutationForm>;
}
function AttendanceReview({row,breaks,saved}){
 const [start,setStart]=useState(taipeiInput(row.effective_start)),[end,setEnd]=useState(taipeiInput(row.effective_end)),[rest,setRest]=useState(row.break_minutes),[approve,setApprove]=useState(true),[reason,setReason]=useState('');
 return <MutationForm action={()=>rpc('spa_attendance_review',{p_attendance:row.id,p_version:row.version,p_approve:approve,p_start:attendanceStamp(start,row?.effective_start),p_end:attendanceStamp(end,row?.effective_end),p_break_minutes:Number(rest),p_reason:reason})} onSaved={saved} submit={approve?'核准並同步薪資工時':'退回／撤回核准'}><p>{row.employee} · {row.work_date}</p><BreakList rows={breaks}/><Field label="審核結果"><select value={String(approve)} onChange={e=>setApprove(e.target.value==='true')}><option value="true">核准工時</option><option value="false">退回／撤回核准</option></select></Field>{approve&&<TimeFields date={row.work_date} start={start} setStart={setStart} end={end} setEnd={setEnd} rest={rest} setRest={setRest} lockRest={breaks.length>0}/>}<Field label="審核原因（必填）"><textarea required maxLength={1000} value={reason} onChange={e=>setReason(e.target.value)}/></Field><p className="muted">核准後自動連動薪資工時。修改保留原始紀錄；已結算期間須先在薪資系統重新開啟，重複工時會被阻止。</p></MutationForm>;
}
function RequestReview({row,attendance,breaks,saved}){
 const [approve,setApprove]=useState(true),[reason,setReason]=useState(''),[date,setDate]=useState(row.work_date);
 const [start,setStart]=useState(taipeiInput(attendance?.effective_start)),[end,setEnd]=useState(taipeiInput(attendance?.effective_end)),[rest,setRest]=useState(attendance?.break_minutes??0);
 const missing=Boolean(row.attendance_id&&!attendance);
 return <MutationForm disabled={approve&&row.reason_only&&missing} action={()=>rpc('spa_attendance_request_review_v2',{p_request:row.id,p_approve:approve,p_reason:reason,p_date:date,p_start:attendanceStamp(start,attendance?.effective_start),p_end:attendanceStamp(end,attendance?.effective_end),p_break_minutes:Number(rest),p_version:attendance?.version??null})} onSaved={saved} submit="確認審核">
  <p>{row.employee} · {row.work_date}</p><RequestTimes row={row}/><p>員工原因：{row.reason}</p><BreakList rows={breaks}/>
  <Field label="審核結果"><select value={String(approve)} onChange={e=>setApprove(e.target.value==='true')}><option value="true">核准並同步薪資工時</option><option value="false">退回</option></select></Field>
  {approve&&row.reason_only&&(missing?<p className="alert">請先更新出勤資料。</p>:<TimeFields date={date} setDate={row.attendance_id?null:setDate} start={start} setStart={setStart} end={end} setEnd={setEnd} rest={rest} setRest={setRest} lockRest={breaks.length>0}/>)}
  <Field label="審核原因"><textarea required maxLength={1000} value={reason} onChange={e=>setReason(e.target.value)}/></Field>
 </MutationForm>;
}
export function AttendanceSettings({value,saved}){
 const [f,setF]=useState(value);const set=(key,v)=>setF(s=>({...s,[key]:v}));
 return <MutationForm action={()=>rpc('spa_attendance_setting_save',{p_latitude:Number(f.latitude),p_longitude:Number(f.longitude),p_radius:Number(f.radius_m),p_accuracy:Number(f.max_accuracy_m),p_grace:Number(f.grace_minutes),p_max_shift:Number(f.max_shift_minutes),p_address:f.address})} onSaved={saved} submit="儲存打卡範圍"><p className="muted">預設沿用官網地址的地圖標記。修改只影響新的打卡；舊紀錄保留當時的範圍設定。</p><div className="form-grid"><Field wide label="門店定位地址"><input required maxLength={200} value={f.address} onChange={e=>set('address',e.target.value)}/></Field><Field label="門店緯度"><input required type="number" step="any" min="-90" max="90" value={f.latitude} onChange={e=>set('latitude',e.target.value)}/></Field><Field label="門店經度"><input required type="number" step="any" min="-180" max="180" value={f.longitude} onChange={e=>set('longitude',e.target.value)}/></Field>{[['radius_m','打卡半徑（公尺）',20,2000],['max_accuracy_m','定位誤差上限（公尺）',5,500],['grace_minutes','遲到／早退寬限（分鐘）',0,60],['max_shift_minutes','未下班異常門檻（分鐘）',60,2880]].map(([key,label,min,max])=><Field label={label} key={key}><input required type="number" step="1" min={min} max={max} value={f[key]} onChange={e=>set(key,e.target.value)}/></Field>)}</div><p><a href={`https://www.google.com/maps?q=${f.latitude},${f.longitude}`} target="_blank" rel="noreferrer">核對門店地圖標記</a></p><p className="muted">瀏覽器定位可能被偽造，位置紀錄供店主審核參考。未取得定位不能打卡，請改送補打卡申請。</p></MutationForm>;
}
