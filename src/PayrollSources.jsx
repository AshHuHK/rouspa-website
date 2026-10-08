import {useEffect,useRef,useState} from 'react';
import {rpc,errorText,money,dateTime} from './lib/spa.js';
import {Empty} from './OperationsShared.jsx';
import './payroll-sources.css';

const tabs=[['summary','應發核對'],['sales','療程與商品'],['work','出勤與加班'],['adjustments','本期加扣'],['rules','制度引用']];
const overtimeNames={weekday:'平日',rest_day:'休息日',national_holiday:'國定假日',regular_holiday:'例假日'};
const adjustmentNames={bonus:'獎金',allowance:'津貼',deduction:'扣款',designated_bonus:'指定客獎金'};
const checkNames={completed_count:'實際完成堂數',service_count:'計薪服務堂數',unsettled_completed_count:'待結帳堂數',refunded_service_count:'退款堂數',service_minutes:'計薪服務分鐘',service_sales_cents:'計抽服務收入',product_order_count:'商品訂單數',product_sales_cents:'商品淨收入',designated_clients:'指定客堂數',designated_service_sales_cents:'指定客服務收入',work_minutes:'核准出勤分鐘',overtime_minutes:'本期核准加班分鐘',overtime_occurrences:'本期加班紀錄數',quarter_overtime_minutes:'季度核准加班分鐘',max_month_overtime_minutes:'期間內最高月加班分鐘',manual_designated_bonus_cents:'手動指定客獎金',bonus_cents:'獎金',allowance_cents:'津貼',deduction_cents:'扣款'};
const componentRows=[['base_cents','本薪','rules',1],['service_commission_cents','療程提成','sales',1],['product_commission_cents','商品提成','sales',1],['designated_bonus_cents','指定客獎金','sales',1],['overtime_cents','加班費','work',1],['bonus_cents','其他獎金','adjustments',1],['allowance_cents','津貼','adjustments',1],['deduction_cents','扣款','adjustments',-1]];
const metricNames={service_minutes:'服務小時',service_count:'服務堂數',service_sales_cents:'服務收入',product_sales_cents:'商品收入'};
const count=value=>Number(value||0).toLocaleString('zh-TW');
const percentage=value=>`${(Number(value||0)/100).toLocaleString('zh-TW',{maximumFractionDigits:2})}%`;
const hours=value=>`${(Number(value||0)/60).toLocaleString('zh-TW',{maximumFractionDigits:2})} 小時`;
const metricValue=(metric,value)=>value==null?'以上':metric.endsWith('_cents')?money(value):metric==='service_minutes'?hours(value):`${count(value)} 堂`;

function Reference({row,label}){
 return <details className="payroll-source-reference"><summary>{row.reference||label}</summary><dl><dt>紀錄 ID</dt><dd>{row.id}</dd>{row.checkout_id&&<><dt>療程收款 ID</dt><dd>{row.checkout_id}</dd></>}{row.order_id&&<><dt>訂單 ID</dt><dd>{row.order_id}</dd></>}{row.attendance_id&&<><dt>打卡 ID</dt><dd>{row.attendance_id}</dd></>}</dl></details>;
}
function SourceTable({title,rows,columns,empty='本期沒有這類來源。'}){
 const [showAll,setShowAll]=useState(false),[query,setQuery]=useState('');
 const filtered=rows.filter(row=>!query||[row.reference,row.id,row.order_id,row.checkout_id,row.attendance_id,row.name,row.date,row.note,row.reason].some(value=>String(value||'').toLowerCase().includes(query.toLowerCase())));
 const displayed=showAll?filtered:filtered.slice(0,20);
 return <section className="payroll-source-section"><div className="payroll-source-section-head"><h3>{title} <span className="badge">{rows.length} 筆</span></h3>{rows.length>6&&<input type="search" value={query} onChange={event=>{setQuery(event.target.value);setShowAll(false);}} placeholder="搜尋引用編號、日期或內容" aria-label={`搜尋${title}`}/>}</div>{rows.length?<><div className="table-wrap"><table><thead><tr>{columns.map(column=><th key={column.label}>{column.label}</th>)}</tr></thead><tbody>{displayed.map(row=><tr key={row.id}>{columns.map(column=><td key={column.label} className={column.className||''}>{column.render(row)}</td>)}</tr>)}</tbody></table></div>{!filtered.length&&<Empty>沒有符合搜尋的來源。</Empty>}{filtered.length>20&&<button type="button" className="link-button" onClick={()=>setShowAll(value=>!value)}>{showAll?'收起為前 20 筆':`顯示全部 ${filtered.length} 筆`}</button>}<p className="muted payroll-source-count">顯示 {displayed.length} / {filtered.length} 筆。搜尋與收起僅影響列表，合計仍包含全部來源。</p></>:<Empty>{empty}</Empty>}</section>;
}
function CheckTable({checks}){
 return <div className="table-wrap"><table className="payroll-source-check-table"><thead><tr><th>核對項目</th><th>來源合計</th><th>薪資採用</th><th>核對</th></tr></thead><tbody>{checks.map(item=><tr key={item.key}><td>{checkNames[item.key]||item.key}</td><td>{item.key.endsWith('_cents')?money(item.actual):count(item.actual)}</td><td>{item.expected==null?'未保存':item.key.endsWith('_cents')?money(item.expected):count(item.expected)}</td><td><span className={`badge ${item.matches===false?'source-mismatch':''}`}>{item.matches==null?'歷史未保存':item.matches?'一致':'有差異'}</span></td></tr>)}</tbody></table></div>;
}

export default function PayrollSources({staffId,from,to,ruleId,expectedRow}){
 const [data,setData]=useState(null),[error,setError]=useState(''),[tab,setTab]=useState('summary'),[retry,setRetry]=useState(0);
 const tabButtons=useRef([]);
 useEffect(()=>{let live=true;setData(null);setError('');if(!staffId){setError('此帳號尚未綁定人員資料。');return()=>{live=false;};}rpc('spa_payroll_sources',{p_staff:staffId,p_from:from,p_to:to,p_rule:ruleId||null}).then(value=>{if(live)setData(value);}).catch(value=>{if(live)setError(errorText(value));});return()=>{live=false;};},[staffId,from,to,ruleId,retry]);
 if(error)return <div className="payroll-sources"><p className="alert" role="alert">{error}</p><button type="button" onClick={()=>setRetry(value=>value+1)}>重新載入薪資來源</button></div>;
 if(!data)return <div className="payroll-sources"><Empty>正在核對薪資與來源紀錄…</Empty></div>;
 const wage=data.wage,sources=data.sources,totals=data.source_totals,finalized=data.finalized_wage,reference=data.rule_reference||{},profile=reference.profile||{},version=reference.version||{};
 const stale=expectedRow&&['total_cents','work_minutes','service_count','service_sales_cents','product_sales_cents',...componentRows.map(row=>row[0])].some(key=>expectedRow[key]!=null&&Number(expectedRow[key])!==Number(wage[key]));
 const difference=finalized?Number(wage.total_cents||0)-Number(finalized.total_cents||0):0;
 const checks=data.reconciliation.checks||[],mismatches=checks.filter(check=>check.matches===false);
 const dayReference=row=><><span>{row.date}</span><Reference row={row} label="展開引用紀錄"/></>;
 const serviceName=row=><><strong>{row.name}</strong><small>{row.quantity} 堂 · {Number(row.duration_minutes||0)*Number(row.quantity||1)} 分鐘</small></>;
 const amount=row=><><strong>{money(row.net_cents)}</strong>{row.gross_cents!=null&&Number(row.gross_cents)!==Number(row.net_cents)&&<small>原始金額 {money(row.gross_cents)}</small>}{Number(row.tea_cents)>0&&<small>茶飲 {money(row.tea_cents)} 不計提成</small>}</>;
 const designation=row=>row.designated&&row.contributes?<span className="badge">指定客</span>:'—';
 const keysFor=prefixes=>checks.filter(item=>prefixes.includes(item.key));
 const switchTab=(event,index)=>{const keys={ArrowRight:1,ArrowLeft:-1,Home:0,End:tabs.length-1};if(!(event.key in keys))return;event.preventDefault();const next=event.key==='Home'?0:event.key==='End'?tabs.length-1:(index+keys[event.key]+tabs.length)%tabs.length;setTab(tabs[next][0]);tabButtons.current[next]?.focus();};
 return <div className="payroll-sources">
  <div className="payroll-source-heading"><div><p className="eyebrow">PAYROLL REFERENCES</p><h2>{wage.employee} · 薪資來源</h2><p className="muted">{from} ～ {to} · {wage.role} · {wage.employment_type}</p></div><span className="badge">{data.basis==='finalized'?'已結算快照':'目前試算'}</span></div>
  {stale&&<p className="alert" role="status">來源資料已更新，與剛才列表的數字不同。以下顯示重新讀取後的薪資；關閉後請重新整理列表。</p>}
  {data.evidence_mode==='legacy_current_records'&&<p className="alert">此歷史結算未保存完整來源與制度快照。應發金額使用原結算，以下紀錄是目前仍保留的來源，不能當作當時的完整快照。</p>}
  {mismatches.length>0&&<p className="alert" role="alert">有 {mismatches.length} 個來源合計與薪資採用值不一致，請查看「應發核對」。歷史已結算金額不會因此被改寫。</p>}
  <div className="payroll-source-kpis"><article><span>{data.basis==='finalized'?'已結算應發':'試算應發'}</span><strong>{money(wage.total_cents)}</strong><small>制度 v{wage.calculation?.rule_version||version.version_no||'—'}</small></article><article><span>計薪服務</span><strong>{count(wage.service_count)} 堂</strong><small>{hours(wage.service_minutes)} · {money(wage.service_sales_cents)}</small></article><article><span>核准出勤</span><strong>{hours(wage.work_minutes)}</strong><small>加班 {hours(wage.overtime_minutes)}</small></article>{finalized&&data.basis==='preview'&&<article><span>原結算應發</span><strong>{money(finalized.total_cents)}</strong><small>本次試算差額 {difference>0?'+':''}{money(difference)}</small></article>}</div>
  <nav className="payroll-source-tabs" role="tablist" aria-label="薪資來源分類">{tabs.map(([id,label],index)=><button ref={element=>{tabButtons.current[index]=element;}} type="button" role="tab" id={`payroll-source-tab-${id}`} aria-controls={`payroll-source-panel-${id}`} aria-selected={tab===id} tabIndex={tab===id?0:-1} className={tab===id?'active':''} key={id} onClick={()=>setTab(id)} onKeyDown={event=>switchTab(event,index)}>{label}</button>)}</nav>
  <section role="tabpanel" id={`payroll-source-panel-${tab}`} aria-labelledby={`payroll-source-tab-${tab}`}>
   {tab==='summary'&&<>
    <div className="table-wrap"><table className="payroll-source-components"><thead><tr><th>應發組成（點選可看來源）</th><th>採用金額</th>{finalized&&data.basis==='preview'&&<th>原結算</th>}</tr></thead><tbody>{componentRows.map(([key,label,target,sign])=><tr key={key}><td><button type="button" className="link-button" onClick={()=>setTab(target)}>{sign<0?'−':'＋'} {label} →</button></td><td>{sign<0?'−':''}{money(wage[key])}</td>{finalized&&data.basis==='preview'&&<td>{sign<0?'−':''}{money(finalized[key])}</td>}</tr>)}</tbody><tfoot><tr><td>應發合計</td><td><strong>{money(data.reconciliation.formula_total_cents)}</strong></td>{finalized&&data.basis==='preview'&&<td><strong>{money(finalized.total_cents)}</strong></td>}</tr></tfoot></table></div>
    <p className={data.reconciliation.formula_matches?'success':'alert'}>{data.reconciliation.formula_matches?'應發公式核對一致。':'應發公式與保存金額有差異，請交由店主核對。'}{Number(data.reconciliation.formula_before_floor_cents)<0?'扣款後為負數，依設定將應發最低設為 0。':''}</p>
    <details className="payroll-source-checks" open={mismatches.length>0}><summary>來源數字逐項核對（{checks.length} 項）</summary><CheckTable checks={checks}/></details>
    <p className="muted">只採用已完成、已結帳且未退款的服務、已付款商品、核准出勤及核准加班。儲值支付是付款方式，小費不會重複計入服務提成。</p>
    {data.run?.needs_recalculation&&<p className="alert">已保存草稿的來源有變更，店主需重新儲存草稿後再結算。</p>}
   </>}
   {tab==='sales'&&<>
    <CheckTable checks={keysFor(['service_count','service_minutes','service_sales_cents','product_order_count','product_sales_cents','designated_clients','designated_service_sales_cents'])}/>
    <SourceTable title="預約療程" rows={sources.services} columns={[{label:'日期／引用',render:dayReference},{label:'療程／時長',className:'source-note',render:serviceName},{label:'計薪狀態',render:row=><span className="badge">{{settled:'計入',unsettled:'待結帳・不計入',refunded:'已退款・不計入'}[row.settlement_status]}</span>},{label:'淨服務收入',render:amount},{label:'指定客',render:designation}]}/>
    <SourceTable title="POS 服務" rows={sources.pos_services} columns={[{label:'日期／訂單',render:dayReference},{label:'項目／時長',className:'source-note',render:serviceName},{label:'淨服務收入',render:amount},{label:'指定客',render:designation}]}/>
    <SourceTable title="商品銷售" rows={sources.products} columns={[{label:'日期／訂單',render:dayReference},{label:'商品',className:'source-note',render:row=><>{row.name}<small>數量 {row.quantity}</small></>},{label:'淨商品收入',render:amount}]}/>
    <p className="muted">POS 訂單折扣分配至每個明細；明細淨額合計等於訂單實收。服務時長與指定客資格使用保存快照，提成依本頁制度引用計算。</p>
    <div className="payroll-source-note">{wage.designated_bonus_bps==null?'當時的指定客計算比例未保存；原結算指定客獎金為 '+money(wage.designated_bonus_cents)+'。':<>指定客計抽收入 {money(totals.designated_service_sales_cents)} × {percentage(wage.designated_bonus_bps)} ＋ 手動指定獎金 {money(totals.manual_designated_bonus_cents)}。</>}指定資格與獎金歸最後確認的實際技師。</div>
   </>}
   {tab==='work'&&<>
    <CheckTable checks={keysFor(['work_minutes','overtime_minutes','overtime_occurrences','quarter_overtime_minutes','max_month_overtime_minutes'])}/>
    <SourceTable title="核准出勤" rows={sources.time_entries} columns={[{label:'日期／引用',render:dayReference},{label:'實際時段',render:row=><>{dateTime(row.started_at)}<small>至 {dateTime(row.ended_at)}</small></>},{label:'休息',render:row=>`${row.break_minutes} 分鐘`},{label:'計薪工時',render:row=><strong>{row.minutes} 分鐘</strong>},{label:'說明',className:'source-note',render:row=>row.note||'—'}]}/>
    <SourceTable title="核准加班" rows={sources.overtime} columns={[{label:'日期／引用',render:dayReference},{label:'類型',render:row=>overtimeNames[row.type]||row.type},{label:'分鐘',render:row=>row.minutes},{label:'原因',className:'source-note',render:row=>row.reason}]}/>
    <details className="payroll-source-checks"><summary>月／季度上限引用紀錄（包含本期之外）</summary><SourceTable title="加班上限來源" rows={sources.overtime_context} columns={[{label:'日期／引用',render:dayReference},{label:'類型',render:row=>overtimeNames[row.type]||row.type},{label:'分鐘',render:row=>row.minutes},{label:'範圍',render:row=>row.in_period?'本期':row.in_quarter?'季度內・本期之外':'月份內・本期之外'}]}/></details>
    <p className="muted">計薪分鐘＝下班減上班，捨去未滿一分鐘秒數，再扣休息。排班是預約可用性的依據，沒有核准實際出勤就不會自動產生計薪工時；同日、同類加班合併後才套用倍率。</p>
   </>}
   {tab==='adjustments'&&<>
    <CheckTable checks={keysFor(['bonus_cents','allowance_cents','deduction_cents','manual_designated_bonus_cents'])}/>
    <SourceTable title="本期加扣" rows={sources.adjustments} columns={[{label:'計入日期／引用',render:dayReference},{label:'類型',render:row=>adjustmentNames[row.kind]||row.kind},{label:'金額',render:row=><strong>{row.kind==='deduction'?'−':'＋'}{money(row.amount_cents)}</strong>},{label:'說明',className:'source-note',render:row=>row.note}]}/>
    <p className="muted">按照「計入日期」歸入本期。指定客手動獎金列入指定客獎金，不會再重複列入其他獎金；月薪休假扣款需有明確扣款紀錄。</p>
   </>}
   {tab==='rules'&&<>
    <div className="payroll-source-note"><strong>v{version.version_no||wage.calculation?.rule_version||'—'} · {version.name||'薪資制度'}</strong><p>{data.evidence_mode==='snapshot'?'以下為保存結算時的制度與職稱設定。':data.evidence_mode==='legacy_current_records'?'此結算缺少完整制度快照。下方倍率與階梯是目前同版本設定，無法證明當時設定；應發使用原結算保存金額。':'以下為本次試算實際引用的制度與職稱設定。'}</p><details><summary>展開制度引用 ID</summary><code>{version.id||data.run?.rule_version_id||'未保存'}</code><p className="muted">職稱 {profile.job_title_id||'未保存'} ／ 聘僱 {profile.employment_type_code||'未保存'}</p></details></div>
    <div className="payroll-source-rule-grid"><article><span>基本薪酬</span><strong>{wage.base_pay_rate_cents==null?'未保存':money(wage.base_pay_rate_cents)}</strong><small>{{monthly:'每月',hourly:'每小時',session:'每堂'}[wage.pay_basis]}</small></article><article><span>商品提成</span><strong>{wage.product_commission_bps==null?'未保存':percentage(wage.product_commission_bps)}</strong><small>按商品淨收入</small></article><article><span>指定客加成</span><strong>{wage.designated_bonus_bps==null?'未保存':percentage(wage.designated_bonus_bps)}</strong><small>按指定客服務淨收入</small></article><article><span>提成出勤門檻</span><strong>{wage.minimum_attendance_minutes==null?'未保存':hours(wage.minimum_attendance_minutes)}</strong><small>{wage.commission_eligibility_met==null?'當時資格未保存':wage.commission_eligibility_met?'已達門檻':'未達門檻'}</small></article></div>
    <p>本薪：{wage.pay_basis==='hourly'?`${money(wage.base_pay_rate_cents)} × ${Number(wage.work_minutes||0)} 分鐘 ÷ 60`:wage.pay_basis==='session'?`${money(wage.base_pay_rate_cents)} × ${wage.service_count} 堂`:`固定月薪 ${money(wage.base_pay_rate_cents)}`} ＝ <strong>{money(wage.base_cents)}</strong></p>
    <h3>職稱提成階梯</h3>{reference.tiers?.length?<div className="table-wrap"><table><thead><tr><th>依據</th><th>區間</th><th>比例</th><th>方式</th><th>引用</th></tr></thead><tbody>{reference.tiers.map(tier=><tr key={tier.id}><td>{metricNames[tier.metric]}</td><td>{metricValue(tier.metric,tier.threshold_from)} ～ {metricValue(tier.metric,tier.threshold_to)}</td><td>{percentage(tier.rate_bps)}</td><td>{tier.calculation_mode==='flat'?'整段':'累進'}</td><td><details className="payroll-source-reference"><summary>階梯 ID</summary><code>{tier.id}</code></details></td></tr>)}</tbody></table></div>:<p className="muted">{profile.job_title_id?<>此職稱沒有階梯，服務採基本比例 {percentage(wage.service_commission_bps)}；服務起算 {wage.commission_start_service_minutes==null?'未保存':hours(wage.commission_start_service_minutes)}，商品採基本比例。</>:'當時職稱引用未保存，無法確認採用的提成階梯。'}</p>}
    <h3>加班倍率</h3><p className="muted">月薪換算時薪除數 {version.hourly_divisor??'未保存'}；經常性提成及指定客獎金 {version.include_regular_commission==null?'設定未保存':version.include_regular_commission?'計入':'不計入'}時薪基數。</p>{reference.rates?.length?<div className="table-wrap"><table><thead><tr><th>類型</th><th>同日累計分鐘</th><th>倍率</th></tr></thead><tbody>{reference.rates.map(rate=><tr key={`${rate.overtime_type}-${rate.start_minute}`}><td>{overtimeNames[rate.overtime_type]}</td><td>{rate.start_minute} ～ {rate.end_minute}</td><td>{Number(rate.multiplier_bps)/10000} 倍</td></tr>)}</tbody></table></div>:<Empty>此聘僱類型未設定加班倍率。</Empty>}
    <p className="muted">每月一般上限 {version.monthly_overtime_limit_minutes==null?'未保存':hours(version.monthly_overtime_limit_minutes)}，同意上限 {version.agreed_monthly_limit_minutes==null?'未保存':hours(version.agreed_monthly_limit_minutes)}，季度上限 {version.quarterly_overtime_limit_minutes==null?'未保存':hours(version.quarterly_overtime_limit_minutes)}。</p>
   </>}
  </section>
  <p className="muted payroll-source-footnote">{data.evidence_mode==='snapshot'?`來源快照保存於 ${dateTime(data.captured_at)}`:'來源於本次讀取的實際紀錄'}。金額顯示為 NT$ 元、百分比顯示為 %，時間標示分鐘或小時。</p>
 </div>;
}
