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
  <p className="muted">制度只管理計算規則；技師類型與職級在人員檔案維護。</p>
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
   ...settings,monthly_base_cents:settings.monthly_base_cents==null?null:cents(settings.monthly_base_cents),...Object.fromEntries(thresholds.map(([id])=>[id,Math.round(Number(settings[id])*60)])),
  },p_ranks:ranks.map(rank=>({...rank,monthly_base_cents:cents(settings.monthly_base_cents??rank.monthly_base_cents)}))})} onSaved={refresh} submit="儲存制度">
   <fieldset disabled={!editable} className="payroll-notice-fields">
    <div className="form-grid">{thresholds.map(([id,label])=><Field key={id} label={label+'（小時）'}>
     <input type="number" required min={id==='step_minutes'?'0.1':'0'} max={id==='step_minutes'?100:500} step="0.1" value={settings[id]} onChange={event=>update(id,event.target.value)}/>
    </Field>)}</div>

    <div className="table-wrap"><table><caption>01／02 職級</caption><thead><tr><th>職級</th><th>01 起抽</th><th>02 起抽</th>{settings.monthly_base_cents==null&&<th>舊版 02 月薪（NT$）</th>}</tr></thead><tbody>
     {ranks.map(rank=><tr key={rank.rank_no}><th scope="row">{rankNames[rank.rank_no-1]}</th>
      <td><Rates value={rank.full_time_start_bps} onChange={value=>updateRank(rank.rank_no,'full_time_start_bps',value)}/></td>
      <td><Rates max={25} value={rank.monthly_start_bps} onChange={value=>updateRank(rank.rank_no,'monthly_start_bps',value)}/></td>
      {settings.monthly_base_cents==null&&<td>{money(cents(rank.monthly_base_cents))}</td>}
     </tr>)}
    </tbody></table></div>
    <p className="muted">02 普通抽成最高 25%，指定客另加 5%，合計最高 30%。01／02 起抽 0% 為試用，試用服務時數不累計。四類技師的商品和課程券銷售均按實收 5%。</p>
   </fieldset>
  </MutationForm>
 </article>;
}

export default function PayrollNoticeEditor({rule,canManage,onReload,onPreview,onDelete,inUse,onManageStaff}){
 const [packet,setPacket]=useState(null),[error,setError]=useState(''),[revision,setRevision]=useState(0),[confirm,setConfirm]=useState(false);
 useEffect(()=>{let live=true;
  rpc('spa_payroll_notice_get',{p_rule:rule.id}).then(value=>{if(live){setPacket(value);setError('');}}).catch(value=>{if(live)setError(errorText(value));});
  return ()=>{live=false;};
 },[rule.id,revision]);
 const refresh=()=>{setRevision(value=>value+1);return onReload();};
 if(error)return <p className="alert" role="alert">{error}</p>;
 if(packet?.rule_id!==rule.id)return <p className="muted" role="status">正在載入制度…</p>;
 const draft=rule.status==='draft';
 const editable=canManage&&(draft||rule.status==='active');
 const editableNotice={...packet,monthly_base_cents:packet.monthly_base_cents==null?null:Number(packet.monthly_base_cents)/100,...Object.fromEntries(thresholds.map(([id])=>[id,Number(packet[id])/60])),
  ranks:packet.ranks.map(rank=>({...rank,monthly_base_cents:Number(rank.monthly_base_cents)/100}))};
 return <section className="payroll-panel payroll-notice-editor">
  <div className="payroll-policy-grid">{[
   ['01',money(3100000)+'／月',packet.full_time_threshold_minutes],
   ['02',packet.monthly_base_cents==null?'舊版職級月薪':money(packet.monthly_base_cents)+'／月',packet.monthly_threshold_minutes],
   ['03',money(20500)+'／小時',packet.hourly_threshold_minutes],
   ['04','滿六個月 30% → 40%',null],
  ].map(([id,pay,threshold])=><article className="card" key={id}><h3>{id} {categories[id]}</h3><strong>{pay}</strong>
   {threshold!==null&&<p className="muted">普通抽成從超過 {threshold/60} 個服務小時開始</p>}</article>)}</div>
  <NoticeSettings key={rule.id+':'+revision} notice={editableNotice} editable={editable} refresh={refresh}/>
  {canManage&&onManageStaff&&<div className="actions"><button type="button" onClick={onManageStaff}>管理技師類型與職級</button></div>}
  <article className="card"><div className="actions">
   <button onClick={onPreview}>試算生效月份</button>
   {canManage&&draft&&<button className="primary" type="button" onClick={()=>setConfirm(value=>!value)}>準備啟用</button>}
   {canManage&&draft&&!inUse&&<button className="danger" type="button" onClick={onDelete}>刪除草稿</button>}
  </div>
   {editable&&<p className="muted">修改規則後請核對試算；已結算金額仍採保存紀錄。</p>}
   {canManage&&draft&&confirm&&<MutationForm action={()=>rpc('spa_payroll_notice_activate',{p_rule:rule.id})} onSaved={()=>{setConfirm(false);return refresh();}} submit="確認啟用">
    <p>將從 {rule.effective_from} 起用此正式制度結算；生效日前沿用原制度。</p>
   </MutationForm>}
  </article>
 </section>;
}
