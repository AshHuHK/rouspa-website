import { useEffect, useState } from 'react';
import { supabase, rpc, errorText, money, dateTime } from './lib/spa.js';
import { Field, MutationForm, Empty } from './OperationsShared.jsx';

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
export function StaffSelf({data}) {
 if (!data.profile) return <Empty>此帳號尚未綁定人員資料，請由店主在「人員管理」配置登入帳號。</Empty>;
 const s=data.profile,m=data.metrics;
 return <><div className="card"><h2>{s.name}</h2><p>{s.title} · {s.employment_type} · {payLabel(s)}</p><p>基本服務提成 {(Number(s.commission_bps)/100).toFixed(2)}% · 商品銷售提成 {(Number(s.product_commission_bps)/100).toFixed(2)}% · 指定客服務加成 {(Number(s.designated_client_bonus_bps||0)/100).toFixed(2)}%</p><p className="muted">薪酬依職稱與聘僱類型規則套用；服務階梯依薪資規則版本計算。累計完成 {data.lifetime_completed} 堂；以下為所選期間的業績與薪資試算。</p></div>
 <div className="grid">{[['實際完成療程',m.completed],['已結帳／待結帳',`${m.settled_completed} / ${m.unsettled_completed}`],['已結帳服務分鐘',m.minutes],['已結帳提成',money(m.commission_cents)],['平均評分／評價數',`${m.rating??'—'} / ${m.reviews}`]].map(([label,value])=><div className="card" key={label}><p className="muted">{label}</p><div className="metric">{value}</div></div>)}</div>
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
