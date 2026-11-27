import {useEffect,useRef,useState} from 'react';
import {cents,errorText,money,rpc,taipeiDate} from './lib/spa.js';
import {Field,MutationForm} from './OperationsShared.jsx';

const rankNames=['試用技師','初級技師','資深初級技師','中階技師','資深中階技師','高階技師'];
const categories={
 '01':'正職技師',
 '02':'兼職技師（月薪）',
 '03':'兼職技師（時薪）',
 '04':'承攬技師',
};
const startRates=[0,5,10,15,20,25,30];
const thresholds=[
 ['full_time_threshold_minutes','01 正職服務門檻'],
 ['monthly_threshold_minutes','02 兼職月薪服務門檻'],
 ['hourly_threshold_minutes','03 兼職時薪服務門檻'],
 ['step_minutes','每段服務時數'],
];

export function PayrollNoticeSetup({month,saved}){
 const [effective,setEffective]=useState(month),created=useRef('');
 return <MutationForm action={async()=>{created.current=await rpc('spa_payroll_notice_setup',{p_effective:effective+'-01'});}} onSaved={()=>saved(created.current)} submit="建立制度草稿">
  <Field label="首個生效月份"><input type="month" required value={effective} onChange={event=>setEffective(event.target.value)}/></Field>
  <p className="muted">建立後可指定薪資類別和試算。由店主核對後另行啟用。</p>
 </MutationForm>;
}

function Rates({value,onChange,inherit,max=30}){
 return <select aria-label="起抽比例" value={value??''} onChange={event=>onChange(event.target.value===''?'':Number(event.target.value))}>
  {inherit&&<option value="">依職級預設</option>}
  {startRates.filter(rate=>rate<=max).map(rate=><option key={rate} value={rate*100}>{rate}%</option>)}
 </select>;
}

function NoticeSettings({notice,editable,refresh}){
 const [settings,setSettings]=useState(notice);
 const [ranks,setRanks]=useState(notice.ranks);
 const update=(id,value)=>setSettings(current=>({...current,[id]:value}));
 const updateRank=(number,id,value)=>setRanks(current=>current.map(rank=>rank.rank_no===number?{...rank,[id]:value}:rank));
 return <article className="card"><h3>服務時數與起抽</h3>
  <MutationForm disabled={!editable} action={()=>rpc('spa_payroll_notice_save',{p_rule:notice.rule_id,p_settings:{
   ...settings,...Object.fromEntries(thresholds.map(([id])=>[id,Math.round(Number(settings[id])*60)])),
  },p_ranks:ranks.map(rank=>({...rank,monthly_base_cents:cents(rank.monthly_base_cents)}))})} onSaved={refresh} submit="儲存制度">
   <fieldset disabled={!editable} className="payroll-notice-fields">
    <div className="form-grid">{thresholds.map(([id,label])=><Field key={id} label={label+'（小時）'}>
     <input type="number" required min={id==='step_minutes'?'0.1':'0'} max={id==='step_minutes'?100:500} step="0.1" value={settings[id]} onChange={event=>update(id,event.target.value)}/>
    </Field>)}</div>
    <div className="table-wrap"><table><caption>01／02 職級</caption><thead><tr><th>職級</th><th>01 起抽</th><th>02 起抽</th><th>02 月薪（NT$）</th></tr></thead><tbody>
     {ranks.map(rank=><tr key={rank.rank_no}><th scope="row">{rankNames[rank.rank_no-1]}</th>
      <td><Rates value={rank.full_time_start_bps} onChange={value=>updateRank(rank.rank_no,'full_time_start_bps',value)}/></td>
      <td><Rates max={25} value={rank.monthly_start_bps} onChange={value=>updateRank(rank.rank_no,'monthly_start_bps',value)}/></td>
      <td><input type="number" required min="0" step="0.01" aria-label={rankNames[rank.rank_no-1]+'月薪'} value={rank.monthly_base_cents} onChange={event=>updateRank(rank.rank_no,'monthly_base_cents',event.target.value)}/></td>
     </tr>)}
    </tbody></table></div>
    <p className="muted">02 普通抽成最高 25%，指定客另加 5%，合計最高 30%。01／02 起抽 0% 為試用，試用服務時數不累計。四類技師的商品和課程券銷售均按實收 5%。</p>
   </fieldset>
  </MutationForm>
 </article>;
}

function StaffAssignment({people,notice,rule,editable,canAddMissing,refresh}){
 const [person,setPerson]=useState(people[0]?.id||'');
 const current=notice.assignments.find(row=>row.staff_id===person);
 const staff=people.find(row=>row.id===person);
 const rank=notice.ranks.find(row=>row.rank_no===current?.rank_no);
 const monthly=current?.category==='02';
 const probation=(monthly||current?.category==='01')&&(current.start_bps??(monthly?rank?.monthly_start_bps:rank?.full_time_start_bps))===0;
 return <article className="card"><h3>技師薪資類別</h3>
  <Field label="選擇技師"><select value={person} onChange={event=>setPerson(event.target.value)}>
   <option value="">選擇技師</option>{people.map(row=><option key={row.id} value={row.id}>{row.name}{row.employment_status==='departed'?'（已離職）':''}{notice.assignments.some(item=>item.staff_id===row.id)?'':'（待設定）'}</option>)}
  </select></Field>
  {staff&&<AssignmentForm key={person} staff={staff} current={current} rule={notice.rule_id} editable={editable||(canAddMissing&&!current)} saved={refresh}/>}
  {canAddMissing&&probation&&staff?.active&&<ProbationPass key={person+':'+(current.passed_on||'')} rule={rule} staff={staff} current={current} ranks={notice.ranks} saved={refresh}/>}
 </article>;
}

function ProbationPass({rule,staff,current,ranks,saved}){
 const monthly=current.category==='02';
 const available=ranks.filter(row=>row.rank_no>1&&(monthly?row.monthly_start_bps:row.full_time_start_bps)>0);
 const [date,setDate]=useState(current.passed_on||taipeiDate()),[rank,setRank]=useState(current.passed_rank_no||available[0]?.rank_no||'');
 return <details><summary>{current.passed_on?'調整試用通過紀錄':'登錄試用考核通過'}</summary>
  <MutationForm disabled={!available.length} action={()=>rpc('spa_payroll_notice_pass',{p_rule:rule.id,p_staff:staff.id,p_on:date,p_rank:Number(rank)})} onSaved={saved} submit="儲存通過紀錄">
   <div className="form-grid">
    <Field label="通過生效日"><input required type="date" min={rule.effective_from} max={taipeiDate()} value={date} onChange={event=>setDate(event.target.value)}/></Field>
    <Field label="確認職級"><select value={rank} onChange={event=>setRank(event.target.value)}>{available.map(row=><option key={row.rank_no} value={row.rank_no}>{rankNames[row.rank_no-1]} · {(monthly?row.monthly_start_bps:row.full_time_start_bps)/100}%</option>)}</select></Field>
   </div>
   <p className="muted">店主於三個月試用期屆滿或提前通過考核時確認。普通抽成自生效日起重新累計。{monthly&&'月中通過時，新職級月薪從下一個完整月份起適用。'}</p>
  </MutationForm>
 </details>;
}

function AssignmentForm({staff,current,rule,editable,saved}){
 const [form,setForm]=useState({...{category:'',rank_no:1,start_bps:'',contract_from:staff.contract_started_on||'',credited_from:''},...current, ...(staff.payroll_category_code&&(editable||!current)?{category:staff.payroll_category_code,rank_no:staff.hr_rank_no||null}:{})});
 const set=(id,value)=>setForm(data=>({...data,[id]:value}));
 const ranked=form.category==='01'||form.category==='02', contractor=form.category==='04';
 if(!staff.payroll_category_code)return <p className="muted">請先到「人員與排班」確認職務、聘僱類型及職級，再設定本制度。</p>;
 return <MutationForm disabled={!editable} action={()=>rpc('spa_payroll_notice_assign',{p_rule:rule,p_staff:staff.id,p_assignment:{
  category:form.category,rank_no:ranked?Number(form.rank_no||1):null,start_bps:ranked&&form.start_bps!==''?form.start_bps:null,
  contract_from:contractor?form.contract_from:null,credited_from:contractor?form.credited_from:null,
 }})} onSaved={saved} submit="儲存人員類別">
  <fieldset disabled={!editable} className="payroll-notice-fields"><div className="form-grid">
   <Field label={editable||!current?"人事薪資類別":"本版本薪資類別"}><input readOnly value={form.category+' '+categories[form.category]}/></Field>
   {ranked&&<><Field label={editable||!current?"人事職級":"本版本職級"}><input readOnly value={rankNames[Number(form.rank_no)-1]||'待設定'}/></Field>
    <Field label="個人起抽（選填）"><Rates max={form.category==='02'?25:30} value={form.start_bps} inherit onChange={value=>set('start_bps',value)}/></Field></>}
   {contractor&&<><Field label="承攬契約開始"><input required type="date" value={form.contract_from||''} onChange={event=>set('contract_from',event.target.value)}/></Field>
    <Field label="併入原在職期間（起日，選填）"><input type="date" min={staff.hire_date||undefined} max={form.contract_from||undefined} value={form.credited_from||''} onChange={event=>set('credited_from',event.target.value)}/></Field></>}
  </div></fieldset>
 </MutationForm>;
}

export default function PayrollNoticeEditor({rule,staff,canManage,onReload,onPreview,onDelete,inUse}){
 const [packet,setPacket]=useState(null),[error,setError]=useState(''),[revision,setRevision]=useState(0),[confirm,setConfirm]=useState(false);
 useEffect(()=>{let live=true;
  rpc('spa_payroll_notice_get',{p_rule:rule.id}).then(value=>{if(live){setPacket(value);setError('');}}).catch(value=>{if(live)setError(errorText(value));});
  return ()=>{live=false;};
 },[rule.id,revision]);
 const refresh=()=>{setRevision(value=>value+1);return onReload();};
 if(error)return <p className="alert" role="alert">{error}</p>;
 if(packet?.rule_id!==rule.id)return <p className="muted" role="status">正在載入制度…</p>;
 const people=staff.filter(row=>packet.technician_ids.includes(row.id));
 const pending=people.filter(row=>!row.archived_at&&row.active&&row.employment_status!=='departed'&&!packet.assignments.some(item=>item.staff_id===row.id));
 const editable=canManage&&rule.status==='draft';
 const editableNotice={...packet,...Object.fromEntries(thresholds.map(([id])=>[id,Number(packet[id])/60])),
  ranks:packet.ranks.map(rank=>({...rank,monthly_base_cents:Number(rank.monthly_base_cents)/100}))};
 return <section className="payroll-panel payroll-notice-editor">
  <div className="payroll-policy-grid">{[
   ['01',money(3100000)+'／月',packet.full_time_threshold_minutes],
   ['02','依職級月薪',packet.monthly_threshold_minutes],
   ['03',money(20500)+'／小時',packet.hourly_threshold_minutes],
   ['04','滿六個月 30% → 40%',null],
  ].map(([id,pay,threshold])=><article className="card" key={id}><h3>{id} {categories[id]}</h3><strong>{pay}</strong>
   {threshold!==null&&<p className="muted">普通抽成從超過 {threshold/60} 個服務小時開始</p>}</article>)}</div>
  <NoticeSettings key={rule.id+':'+revision} notice={editableNotice} editable={editable} refresh={refresh}/>
  <StaffAssignment key={rule.id} people={people} notice={packet} rule={rule} editable={editable} canAddMissing={canManage&&rule.status==='active'} refresh={refresh}/>
  <article className="card"><div className="actions">
   <button onClick={onPreview}>試算生效月份</button>
   {editable&&<button className="primary" type="button" disabled={pending.length>0} onClick={()=>setConfirm(value=>!value)}>準備啟用</button>}
   {editable&&!inUse&&<button className="danger" type="button" onClick={onDelete}>刪除草稿</button>}
  </div>
   {editable&&<p className="muted">{pending.length?pending.length+' 位在職技師待設定。':''} 請先儲存制度，試算並核對金額。</p>}
   {editable&&confirm&&<MutationForm action={()=>rpc('spa_payroll_notice_activate',{p_rule:rule.id})} onSaved={()=>{setConfirm(false);return refresh();}} submit="確認啟用">
    <p>將從 {rule.effective_from} 起用此正式制度結算；生效日前沿用原制度。</p>
   </MutationForm>}
  </article>
 </section>;
}
