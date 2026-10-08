import { useEffect, useRef, useState } from 'react';
import { supabase, rpc, errorText, money, dateTime } from './lib/spa.js';
import { Field, MutationForm, Empty } from './OperationsShared.jsx';
import { AttendanceEmployee } from './Attendance.jsx';

export const staffRoleNames = {owner:'店主',manager:'主管',receptionist:'櫃台',therapist:'技師'};
export const payBasisNames = {monthly:'月薪',hourly:'時薪',session:'每堂薪酬'};
export function payLabel(person) {
 return person.base_pay_cents == null ? '薪酬尚未設定' : `${payBasisNames[person.pay_basis]} ${money(person.base_pay_cents)}`;
}
async function accountAction(body) {
 const {data,error} = await supabase.functions.invoke('staff-accounts',{body});
 if (error) {
  let code = '';
  try { code = (await error.context?.json())?.error || ''; } catch {}
  throw new Error(code || 'ACCOUNT_SERVICE_UNAVAILABLE');
 }
 if (data?.error) throw new Error(data.error);
 return data;
}
export function StaffAccountForm({row,account,saved,roles=[]}) {
 const [mode,setMode] = useState(account?'access':'create'), [username,setUsername] = useState(account?.username || ''), [password,setPassword] = useState('');
 const [role,setRole] = useState(account?.role || 'therapist'), [active,setActive] = useState(account?.active ?? true);
 const choices=roles.filter(r=>r.code!=='owner'&&r.active).length?roles.filter(r=>r.code!=='owner'&&r.active):Object.entries(staffRoleNames).filter(([id])=>id!=='owner').map(([code,name])=>({code,name}));
 return <><p>{row.name} · {account?.username || '尚未建立登入帳號'}</p>
 {account && <nav>{[['access','角色與登入權限'],['password','重設密碼'],['username','修改登入帳號']].map(([id,label])=><button key={id} onClick={()=>{setMode(id);setPassword('');}} className={mode===id?'active':''}>{label}</button>)}</nav>}
 <MutationForm key={mode} action={()=>accountAction({action:mode,staff_id:row.id,...(mode==='create'?{username,password,role}:mode==='password'?{password}:mode==='username'?{username}:{role,active})})} onSaved={saved} submit={mode==='create'?'建立帳號':mode==='password'?'確認重設密碼':mode==='username'?'確認修改登入帳號':'儲存登入權限'}>
 <div className="form-grid">
 {['create','username'].includes(mode) && <Field wide label="登入使用者名稱"><input required autoComplete="off" minLength={3} maxLength={32} pattern="[A-Za-z0-9][A-Za-z0-9._-]{2,31}" value={username} onChange={e=>setUsername(e.target.value)}/></Field>}
 {['create','password'].includes(mode) && <Field wide label="設定密碼（至少 12 個字元）"><input required type="password" autoComplete="new-password" minLength={12} maxLength={128} value={password} onChange={e=>setPassword(e.target.value)}/></Field>}
 {['create','access'].includes(mode) && <Field label="後台角色"><select value={role} onChange={e=>setRole(e.target.value)}>{choices.map(item=><option key={item.code} value={item.code}>{item.name}</option>)}</select></Field>}
 {mode==='access' && <Field label="後台登入"><select value={String(active)} onChange={e=>setActive(e.target.value==='true')}><option value="true">啟用</option><option value="false">停用</option></select></Field>}
 </div><p className="muted">角色權限由店主在「角色與權限」統一設定；職稱、薪酬與登入角色彼此獨立，店主帳號保持不變。</p>
 {mode==='password' && <p className="muted">密碼無法查看。重設後舊後台會話失效，請由門店把新密碼交給本人，再重新登入。</p>}
 {mode==='username' && <p className="muted">修改後請使用新使用者名稱登入。原密碼不變，舊後台會話失效。</p>}
 {mode==='create' && <p className="muted">使用者名稱限 3～32 字元的英文字母、數字、點、底線或連字號，忽略大小寫。員工不需要提供電子郵件。</p>}
 </MutationForm></>;
}
export function StaffArchiveForm({row,saved}) {
 const [reason,setReason]=useState('');
 const archived=!!row.archived_at;
 return <MutationForm action={()=>accountAction({action:archived?'restore':'archive',staff_id:row.id,reason})} onSaved={saved} submit={archived?'恢復人員資料':'確認封存並停用登入'}>
 <p>{row.name}</p><p>{archived?'恢復後預設不接單、不可登入，請再設定排班、接單與登入權限。':'封存後停止接單並停用後台登入。歷史療程、薪酬設定、提成與評價保留。已有未結束預約時，請先處理預約。'}</p>
 <Field label="處理原因"><textarea required maxLength={1000} value={reason} onChange={e=>setReason(e.target.value)}/></Field></MutationForm>;
}
function scheduleCells(month){const [y,m]=month.split('-').map(Number),first=new Date(Date.UTC(y,m-1,1)),pad=(first.getUTCDay()+6)%7,last=new Date(Date.UTC(y,m,0)).getUTCDate(),out=Array(pad).fill(null);for(let day=1;day<=last;day++)out.push(`${month}-${String(day).padStart(2,'0')}`);while(out.length%7)out.push(null);return out;}
function ScheduleTime({label,value,onChange,disabled}){return <Field label={label}><select disabled={disabled} value={value} onChange={e=>onChange(Number(e.target.value))}>{Array.from({length:97},(_,i)=>i*30).map(n=><option key={n} value={n}>{minutes(n)}</option>)}</select></Field>}
function EmployeeSchedulePlanner({refreshToken,onReload}){
 const [plan,setPlan]=useState(null),[draft,setDraft]=useState({}),[selected,setSelected]=useState(''),[reason,setReason]=useState(''),[busy,setBusy]=useState(false),[error,setError]=useState(''),[notice,setNotice]=useState('');
 const sequence=useRef(0);
 const changed=(plan?.days||[]).some(day=>{const next=draft[day.business_date];return next&&(next.is_working!==day.is_working||Number(next.start_minute)!==Number(day.start_minute)||Number(next.end_minute)!==Number(day.end_minute));});
 const load=async(preserveDraft=false)=>{const request=++sequence.current;try{const next=await rpc('spa_staff_schedule_plan');if(request!==sequence.current)return;setPlan(next);setError('');setDraft(previous=>Object.fromEntries((next.days||[]).map(day=>{const local=preserveDraft&&previous[day.business_date];return [day.business_date,local?{...day,is_working:local.is_working,start_minute:local.start_minute,end_minute:local.end_minute}:{...day}];})));setSelected(value=>value&&next.days.some(day=>day.business_date===value)?value:next.days[0]?.business_date||'');}catch(e){if(request===sequence.current)setError(errorText(e));}};
 useEffect(()=>{if(!busy)load(changed);return()=>{sequence.current++;};},[refreshToken]);
 if(!plan)return <section className="card staff-schedule-self"><h2>下月班表</h2>{error?<p className="alert">{error}</p>:<p className="muted">正在讀取班表…</p>}</section>;
 const month=plan.target_month.slice(0,7),current=draft[selected];
 const setCurrent=patch=>setDraft(rows=>({...rows,[selected]:{...rows[selected],...patch}}));
 async function submit(){if(busy)return;setBusy(true);setError('');setNotice('');try{await rpc('spa_staff_schedule_submit',{p_month:plan.target_month,p_days:Object.values(draft).map(day=>({date:day.business_date,is_working:day.is_working,start_minute:Number(day.start_minute),end_minute:Number(day.end_minute)}))});setNotice('下月班表已完成提交，店主後台和營運月表已同步。');await load();await onReload?.();}catch(e){setError(errorText(e));}finally{setBusy(false);}}
 async function request(){if(busy||!current)return;setBusy(true);setError('');setNotice('');try{await rpc('spa_staff_schedule_request',{p_date:selected,p_working:current.is_working,p_start:Number(current.start_minute),p_end:Number(current.end_minute),p_reason:reason});setReason('');setNotice('更動申請已送出，店主核准後會自動套用。');await load();await onReload?.();}catch(e){setError(errorText(e));}finally{setBusy(false);}}
 return <section className="card staff-schedule-self"><div className="staff-schedule-heading"><div><p className="eyebrow">NEXT MONTH ROSTER</p><h2>{month.replace('-',' 年 ')} 月自助排班</h2><p className="muted">每月 1–7 日可編輯下個月；只在按「完成修改」後一次寫入正式班表。8 日起由台灣伺服器鎖定，需改用更動申請。</p></div><span className={`badge ${plan.edit_open?'ok':'locked'}`}>{plan.edit_open?'開放編輯':'已經鎖定'}</span></div>
 <div className="staff-schedule-status"><span>{plan.submission?`已提交第 ${plan.submission.version} 版 · ${dateTime(plan.submission.submitted_at)}`:'本月尚未提交'}</span><span>每日最多 {plan.max_off_per_day} 人休班</span></div>
 <div className="staff-schedule-layout"><div><div className="schedule-weekdays">{['一','二','三','四','五','六','日'].map(x=><span key={x}>週{x}</span>)}</div><div className="schedule-month-grid">{scheduleCells(month).map((date,i)=>date?<button type="button" key={date} className={`${selected===date?'selected':''} ${draft[date]?.is_working?'working':'off'} ${draft[date]?.appointment_count?'booked':''}`} onClick={()=>setSelected(date)}><strong>{Number(date.slice(-2))}</strong><small>{draft[date]?.is_working?`${minutes(draft[date].start_minute)}–${minutes(draft[date].end_minute)}`:'休班'}</small>{draft[date]?.appointment_count>0&&<em>{draft[date].appointment_count} 約</em>}</button>:<span className="outside" key={`blank-${i}`}/>)}</div></div>
 {current&&<aside className="schedule-self-editor"><p className="eyebrow">SELECTED DAY</p><h3>{selected}</h3><Field label="當天狀態"><select value={String(current.is_working)} onChange={e=>{const working=e.target.value==='true';if(!working&&!current.can_turn_off){setError('當天已有預約，員工不能自行改為休班；請先交由店主處理預約。');return;}setError('');setCurrent({is_working:working});}}><option value="true">上班／開放預約</option><option value="false">休班／不開放預約</option></select></Field>{current.is_working&&<div className="form-grid"><ScheduleTime label="開始" value={current.start_minute} onChange={value=>setCurrent({start_minute:value})}/><ScheduleTime label="結束" value={current.end_minute} onChange={value=>setCurrent({end_minute:value})}/></div>}<p className="muted">目前已有 {current.appointment_count} 筆預約；當天休班人數 {current.off_count} 人。</p>{plan.edit_open?<button className="primary" disabled={busy||!changed} onClick={submit}>{busy?'提交中…':'完成修改並同步'}</button>:<><Field label="更動原因"><textarea required maxLength="1000" value={reason} onChange={e=>setReason(e.target.value)} placeholder="說明為什麼需要更改這一天"/></Field><button className="primary" disabled={busy||reason.trim().length<2} onClick={request}>{busy?'送出中…':'送出更動申請'}</button></>}</aside>}</div>
 {error&&<p className="alert" role="alert">{error}</p>}{notice&&<p className="success" role="status">{notice}</p>}
 {(plan.requests||[]).length>0&&<details className="schedule-request-history"><summary>查看我的更動申請（{plan.requests.length}）</summary>{plan.requests.map(row=><p key={row.id}><strong>{row.business_date}</strong> · {row.desired_working?`${minutes(row.desired_start_minute)}–${minutes(row.desired_end_minute)}`:'休班'} · {{pending:'待店主確認',approved:'已核准並套用',rejected:'未核准'}[row.status]}<br/><span className="muted">{row.reason}{row.review_note?` · 店主備註：${row.review_note}`:''}</span></p>)}</details>}
 </section>;
}
export function StaffSelf({data,from,to,onReload}) {
 if (!data.profile) return <Empty>此帳號尚未綁定人員資料，請由店主在「人員管理」配置登入帳號。</Empty>;
 const s=data.profile,m=data.metrics;
 return <><AttendanceEmployee from={from} to={to}/><EmployeeSchedulePlanner refreshToken={data} onReload={onReload}/><div className="card"><h2>{s.name}</h2><p>{s.title} · {s.employment_type} · {payLabel(s)}</p><p>基本服務提成 {(Number(s.commission_bps)/100).toFixed(2)}% · 商品銷售提成 {(Number(s.product_commission_bps)/100).toFixed(2)}% · 指定客服務加成 {(Number(s.designated_client_bonus_bps||0)/100).toFixed(2)}%</p><p className="muted">薪酬依職稱與聘僱類型規則套用；服務階梯依薪資規則版本計算。累計完成 {data.lifetime_completed} 堂；以下為所選期間的業績與薪資試算。</p></div>
 <div className="grid">{[['實際完成療程',m.completed],['已結帳／待結帳',`${m.settled_completed} / ${m.unsettled_completed}`],['已結帳服務分鐘',m.minutes],[m.payroll_status==='finalized'?'已結算提成':'本期試算提成',money(m.commission_cents)],['平均評分／評價數',`${m.rating??'—'} / ${m.reviews}`]].map(([label,value])=><div className="card" key={label}><p className="muted">{label}</p><div className="metric">{value}</div></div>)}</div>
 <p className="muted">完成堂數、提成與評價均依門店最後確認的實際服務技師計入。提成只計算已結帳且未退款的療程。</p>
 <h2>我的評價</h2>{!data.reviews.length&&<Empty>這段期間尚未收到評價。</Empty>}{data.reviews.map((r,i)=><article className="card" key={i} style={{marginTop:12}}><h3>{'★'.repeat(r.rating)} · {r.service_name}</h3><p className="muted">{r.reference} · {dateTime(r.created_at)} · {{pending:'待審核',published:'已公開',hidden:'未公開'}[r.status]}</p><p style={{whiteSpace:'pre-wrap',overflowWrap:'anywhere'}}>{r.comment || '僅評分'}</p>{r.reply&&<p>店家回覆：{r.reply}</p>}</article>)}
 <p className="muted">最多顯示最近 100 則，評價總數包含整個所選期間。</p><h2>我的每日排班</h2>{(data.daily_shifts||[]).map(s=><p key={s.id}>{s.business_date} · {s.is_working?`${minutes(s.start_minute)}–${minutes(s.end_minute)}`:'休班'}{s.note?` · ${s.note}`:''}</p>)}{!(data.daily_shifts||[]).length&&<p className="muted">所選期間沒有每日覆蓋設定，使用下方每週排班設定。</p>}<h2>我的每週排班設定</h2>{data.shifts.map(s=><p key={s.id}>週{'日一二三四五六'[s.weekday]} · {minutes(s.start_minute)}–{minutes(s.end_minute)}</p>)}{!data.shifts.length&&<Empty/>}
 <h2>我的休假</h2>{data.time_off.map(t=><p key={t.id}>{dateTime(t.starts_at)}–{dateTime(t.ends_at)} · {t.reason}</p>)}{!data.time_off.length&&<Empty/>}</>;
}
const minutes=n=>`${n>=1440?'翌日 ':''}${String(Math.floor(n/60)%24).padStart(2,'0')}:${String(n%60).padStart(2,'0')}`;
export function EmployeeCustomer({row}) {
 const [detail,setDetail]=useState(null),[error,setError]=useState('');
 useEffect(()=>{let live=true;rpc('spa_employee_customer',{p_customer:row.id}).then(d=>{if(live)setDetail(d);}).catch(e=>{if(live)setError(errorText(e));});return()=>{live=false;};},[row.id]);
 return <><p>{row.name} · {row.phone} · {row.tier}</p><p>儲值餘額 {money(row.balance_cents)} · 完成 {row.visits} 堂</p>{error&&<p role="alert" className="alert">{error}</p>}<h3>會員療程套票</h3>{detail?detail.packages.length?detail.packages.map(p=><div className="card" key={p.id}><p>{p.name} · {p.service_name}</p><p>剩 {p.remaining} / {p.sessions} 次 · 到期 {dateTime(p.expires_at)}</p></div>):<Empty>尚無療程套票。</Empty>:!error&&<Empty>載入中…</Empty>}<p className="muted">員工僅可查看會員資料。加值、扣款、編輯及完整帳務由店主處理。</p></>;
}
