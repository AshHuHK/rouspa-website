import {PGlite} from '@electric-sql/pglite';
import {readFile,readdir} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
process.on('uncaughtException',error=>{console.error(error.message);if(error.where)console.error(error.where);process.exit(1);});

const db=new PGlite();let checks=0;
const check=(value,label)=>{assert.ok(value,label);checks++;};
const reject=async(fn,pattern)=>{await assert.rejects(fn,pattern);checks++;};
await db.exec(`create role anon;create role authenticated;create role service_role;
create schema auth;create table auth.users(id uuid primary key,email text);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
grant usage on schema auth to anon,authenticated;grant execute on function auth.uid(),auth.jwt() to anon,authenticated;
create function public.consistency_test_now() returns timestamptz language sql stable as $$select '2026-10-06T10:00:00+08:00'::timestamptz$$;`);
const directory=new URL('../supabase/migrations/',import.meta.url);
for(const file of(await readdir(directory)).sort())await db.exec((await readFile(new URL(file,directory),'utf8')).replaceAll('now()','public.consistency_test_now()'));
const owner=randomUUID(),employee=randomUUID(),otherEmployee=randomUUID();
const staff=(await db.query("select id,job_title_id,employment_type_code from spa_staff where active and employment_status='active' order by display_order limit 2")).rows;
await db.query('insert into auth.users(id,email) values($1,$2),($3,$4),($5,$6)',[owner,'owner@example.test',employee,'staff@example.test',otherEmployee,'other@example.test']);
await db.query("insert into spa_roles(user_id,role,staff_id,active,login_name) values($1,'owner',null,true,null),($2,'therapist',$3,true,'payroll_test'),($4,'therapist',$5,true,'payroll_other')",[owner,employee,staff[0].id,otherEmployee,staff[1].id]);
async function as(user,sql,args=[]){await db.exec('begin');try{await db.exec('set local role '+(user?'authenticated':'anon'));await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)",[user||'',JSON.stringify({iat:Math.floor(Date.now()/1000)})]);const result=await db.query(sql,args);await db.exec('commit');return result.rows;}catch(error){await db.exec('rollback');throw error;}}
async function call(user,name,args=[]){return(await as(user,`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args))[0]?.result;}
const admin=(name,args=[])=>call(owner,name,args);
const range=['2026-10-01','2026-10-31'];
const rowFor=async(id=staff[0].id)=>(await admin('spa_payroll_preview',[...range,null])).find(row=>row.staff_id===id);
const service=(await db.query("select * from spa_services where code='45' or duration_minutes=45 order by display_order limit 1")).rows[0];
const product=(await db.query("select * from spa_products where status='active' order by display_order limit 1")).rows[0];
const rule=(await db.query("select id from spa_payroll_rule_versions where status='active' limit 1")).rows[0].id;

// Explicitly configured rates isolate each business mapping from document tier
// defaults. All amounts below are integer cents; no production data is touched.
for(const s of staff){
 await db.query('delete from spa_payroll_commission_tiers where job_title_id=$1 and employment_type_code=$2',[s.job_title_id,s.employment_type_code]);
 await admin('spa_compensation_profile_save_v2',[s.job_title_id,s.employment_type_code,'hourly',20000,1000,2000,500,0,0,true]);
}
await db.query('update spa_payroll_rule_versions set include_regular_commission=false where id=$1',[rule]);
await reject(()=>call(employee,'spa_payroll_preview',[...range,null]),/FORBIDDEN/);
await reject(()=>as(employee,'select spa_private.payroll_preview($1,$2,null)',range),/permission denied/);

const customer=await admin('spa_customer_save',[null,'薪資連動測試','0988111222','','一般會員','',null]);
await db.query('update spa_customers set preferred_staff_id=$2 where id=$1',[customer,staff[0].id]);
const request=randomUUID(),sale=await admin('spa_pos_checkout',[request,customer,[{item_type:'service',item_id:service.id,quantity:1,staff_id:staff[0].id},{item_type:'product',item_id:product.id,quantity:2,staff_id:staff[0].id}],12345,'cash','折扣分配測試']);
let lines=(await db.query('select * from spa_order_items where order_id=$1',[sale.id])).rows;
const serviceLine=lines.find(line=>line.item_type==='service'),productLine=lines.find(line=>line.item_type==='product');
check(lines.reduce((sum,line)=>sum+Number(line.net_total_cents),0)===Number(sale.total_cents),'net POS lines reconcile exactly to actual discounted cash total');
check(serviceLine.net_total_cents<serviceLine.line_total_cents&&productLine.net_total_cents<productLine.line_total_cents,'mixed order discounts apply to both service and product revenue');
check(serviceLine.duration_minutes_snapshot===45&&serviceLine.designated_client_snapshot===true,'POS captures service duration and designated-client facts at sale');
check(Number(productLine.commission_cents)===Math.round(Number(productLine.net_total_cents)*0.2),'product commission is based on net amount after discount');
check((await admin('spa_pos_checkout',[request,customer,[{item_type:'product',item_id:product.id,quantity:1,staff_id:null}],0,'cash','retry'])).id===sale.id,'POS request retries do not create duplicate wages or inventory movements');
let wage=await rowFor();
check(Number(wage.service_sales_cents)===Number(serviceLine.net_total_cents)&&Number(wage.product_sales_cents)===Number(productLine.net_total_cents),'salary reads the same discounted line amounts as POS');
check(Number(wage.service_commission_cents)===Math.round(Number(serviceLine.net_total_cents)*0.1)&&Number(wage.product_commission_cents)===Number(productLine.commission_cents),'salary service/product percentage units reconcile with net line amounts');
check(Number(wage.designated_bonus_cents)===Math.round(Number(serviceLine.net_total_cents)*0.05),'designated bonus derives from actual net service revenue');
await db.query('update spa_services set duration_minutes=90,price_cents=price_cents+10000 where id=$1',[service.id]);
await db.query('update spa_customers set preferred_staff_id=$2 where id=$1',[customer,staff[1].id]);
wage=await rowFor();
check(Number(wage.service_minutes)===45,'catalogue edits do not retroactively change sold service duration or salary tiers');
check(Number(wage.designated_clients)===1,'member preference changes do not retroactively remove the sold designated-client bonus');
const detail=await admin('spa_payroll_staff_detail',[staff[0].id,...range]);
check(Number(detail.pos_services[0].line_total_cents)===Number(wage.service_sales_cents)&&Number(detail.product_orders[0].line_total_cents)===Number(wage.product_sales_cents),'payroll source detail reconciles with summary net revenue');
const report=await admin('spa_report',range);
check(Number(report.staff.find(s=>s.id===staff[0].id).revenue_cents)===Number(sale.total_cents),'staff operating report uses net line revenue consistent with store total');
check(Number(report.staff.find(s=>s.id===staff[0].id).minutes)===45,'staff operating report uses frozen POS duration');
await db.query('update spa_services set duration_minutes=45 where id=$1',[service.id]);
const zeroRequest=randomUUID(),zeroSale=await admin('spa_pos_checkout',[zeroRequest,null,[{item_type:'product',item_id:product.id,quantity:1,staff_id:staff[0].id}],Number(product.price_cents),'cash','全額折扣']);
check(Number(zeroSale.total_cents)===0&&zeroSale.status==='paid','fully discounted POS orders complete with a valid zero total');
check((await db.query('select count(*)::int n from spa_cash_entries where request_id=$1',[zeroRequest])).rows[0].n===0,'zero-total order creates no fake zero-dollar cash movement');
await reject(()=>admin('spa_pos_checkout',[randomUUID(),null,null,0,'cash','invalid']),/INVALID_INPUT/);

// Approved attendance is the wage source; roster hours alone never manufacture
// payable attendance. Seconds round down, matching attendance review/export.
await db.query("insert into spa_daily_shifts(staff_id,business_date,is_working,start_minute,end_minute) values($1,'2026-10-09',true,600,1080)",[staff[0].id]);
check(Number((await rowFor()).work_minutes)===0,'planned shifts do not count as approved actual wage hours');
await admin('spa_time_entry_save',[null,staff[0].id,'2026-10-06','2026-10-06T10:00:00+08:00','2026-10-06T11:00:35+08:00',0,'秒數一致性']);
await admin('spa_overtime_save',[staff[0].id,'2026-10-06','weekday',120,'第一段']);
await admin('spa_overtime_save',[staff[0].id,'2026-10-06','weekday',120,'第二段']);
wage=await rowFor();
check(Number(wage.work_minutes)===60&&Number(wage.base_cents)===20000,'attendance seconds do not round up paid minutes');
check(Number(wage.overtime_cents)===120400,'same-day overtime bands apply to combined minutes rather than restarting on each record');
await admin('spa_payroll_adjustment_save',[staff[0].id,'2026-10-12','allowance',1234,'範圍內津貼']);
await admin('spa_payroll_adjustment_save',[staff[0].id,'2026-10-13','deduction',345,'範圍內扣款']);
wage=await rowFor();
check(Number(wage.allowance_cents)===1234&&Number(wage.deduction_cents)===345,'adjustment records are included by effective date throughout the selected range');
const componentTotal=Number(wage.base_cents)+Number(wage.service_commission_cents)+Number(wage.product_commission_cents)+Number(wage.designated_bonus_cents)+Number(wage.overtime_cents)+Number(wage.bonus_cents)+Number(wage.allowance_cents)-Number(wage.deduction_cents);
check(Number(wage.total_cents)===Math.max(0,componentTotal),'all payroll components reconcile exactly to total');
const self=await call(employee,'spa_staff_self',range);
check(self.payroll.staff_id===staff[0].id&&self.metrics.payroll_status==='preview','employee own wage preview is scoped to their personnel record');
check(Number(self.metrics.commission_cents)===Number(wage.service_commission_cents)+Number(wage.product_commission_cents)+Number(wage.designated_bonus_cents),'employee commission equals owner payroll rules rather than incompatible POS snapshot sum');
check((await call(otherEmployee,'spa_staff_self',range)).payroll.staff_id===staff[1].id,'another employee gets only their own wage row');

// Draft snapshot status tracks later mutations, even when an old saved total
// remains available for reference.
const draft=await admin('spa_payroll_run_save',[...range,null,false]);
check((await db.query('select rule_version_id,needs_recalculation from spa_payroll_runs where id=$1',[draft])).rows[0].rule_version_id===rule,'saving a default rule resolves and records its actual version ID');
await admin('spa_payroll_adjustment_save',[staff[0].id,'2026-10-14','bonus',100,'draft changed']);
check((await db.query('select needs_recalculation from spa_payroll_runs where id=$1',[draft])).rows[0].needs_recalculation,'new wage input marks previously saved draft as needing recalculation');
await admin('spa_payroll_run_save',[...range,null,false]);
check(!(await db.query('select needs_recalculation from spa_payroll_runs where id=$1',[draft])).rows[0].needs_recalculation,'resaving draft clears its stale-input marker');

const rates=(await db.query('select employment_type_code,overtime_type,start_minute,end_minute,multiplier_bps from spa_payroll_overtime_rates where rule_version_id=$1',[rule])).rows;
const tier={job_title_id:staff[0].job_title_id,employment_type_code:staff[0].employment_type_code,metric:'service_minutes',threshold_from:0,threshold_to:120,rate_bps:1000,calculation_mode:'progressive'};
await reject(()=>admin('spa_payroll_components_save_v2',[rule,[...rates,{...rates[0],start_minute:1}],[]]),/PAYROLL_RATE_OVERLAP/);
await reject(()=>admin('spa_payroll_components_save_v2',[rule,rates,[tier,{...tier,threshold_from:60,threshold_to:null}]]),/PAYROLL_TIER_OVERLAP/);
await reject(()=>admin('spa_payroll_components_save_v2',[rule,rates,[tier,{...tier,metric:'service_count',threshold_from:0,threshold_to:null}]]),/PAYROLL_TIER_METRIC_CONFLICT/);
await reject(()=>admin('spa_payroll_components_save_v2',[rule,rates,[tier,{...tier,threshold_from:120,threshold_to:null,calculation_mode:'flat'}]]),/PAYROLL_TIER_MODE_CONFLICT/);

// Finalization has to surface pending attendance instead of silently paying zero.
const attendance=(await db.query("insert into spa_attendance(staff_id,work_date,clock_in,effective_start,status) values($1,'2026-10-06','2026-10-06T10:00:00+08:00','2026-10-06T10:00:00+08:00','open') returning id",[staff[1].id])).rows[0].id;
await reject(()=>admin('spa_payroll_run_save',[...range,null,true]),/PAYROLL_PENDING_ATTENDANCE/);
await db.query("update spa_attendance set status='pending',clock_out='2026-10-06T11:00:00+08:00',effective_end='2026-10-06T11:00:00+08:00' where id=$1",[attendance]);
await reject(()=>admin('spa_payroll_run_save',[...range,null,true]),/PAYROLL_PENDING_ATTENDANCE/);
await db.query("update spa_attendance set status='rejected' where id=$1",[attendance]);
const overtimeDraft=(await db.query("insert into spa_overtime_entries(staff_id,work_date,overtime_type,minutes,reason,status,created_by) values($1,'2026-10-06','weekday',30,'待核准','draft',$2) returning id",[staff[0].id,owner])).rows[0].id;
await reject(()=>admin('spa_payroll_run_save',[...range,null,true]),/PAYROLL_PENDING_OVERTIME/);
await db.query("update spa_overtime_entries set status='rejected' where id=$1",[overtimeDraft]);
const draftTime=(await db.query("insert into spa_time_entries(staff_id,work_date,started_at,ended_at,status,note,created_by) values($1,'2026-10-07','2026-10-07T10:00:00+08:00','2026-10-07T11:00:00+08:00','draft','待核准',$2) returning id",[staff[1].id,owner])).rows[0].id;
await reject(()=>admin('spa_payroll_run_save',[...range,null,true]),/PAYROLL_PENDING_TIME_ENTRIES/);
await db.query('delete from spa_time_entries where id=$1',[draftTime]);
const correction=await call(employee,'spa_attendance_request',[randomUUID(),null,'2026-10-05','2026-10-05T10:00:00+08:00','2026-10-05T11:00:00+08:00',0,'漏打補登']);
await reject(()=>admin('spa_payroll_run_save',[...range,null,true]),/PAYROLL_PENDING_ATTENDANCE/);
await admin('spa_attendance_request_review',[correction,false,'測試退回']);
const missingBand=(await db.query("select * from spa_payroll_overtime_rates where rule_version_id=$1 and employment_type_code=$2 and overtime_type='weekday' and start_minute=120",[rule,staff[0].employment_type_code])).rows[0];
await db.query('delete from spa_payroll_overtime_rates where rule_version_id=$1 and employment_type_code=$2 and overtime_type=$3 and start_minute=$4',[missingBand.rule_version_id,missingBand.employment_type_code,missingBand.overtime_type,missingBand.start_minute]);
check(Number((await rowFor()).unpriced_overtime_minutes)===120,'an uncovered overtime band is surfaced instead of silently losing wages');
await reject(()=>admin('spa_payroll_run_save',[...range,null,true]),/PAYROLL_OVERTIME_RATE_REQUIRED/);
await db.query('insert into spa_payroll_overtime_rates(rule_version_id,employment_type_code,overtime_type,start_minute,end_minute,multiplier_bps) values($1,$2,$3,$4,$5,$6)',[missingBand.rule_version_id,missingBand.employment_type_code,missingBand.overtime_type,missingBand.start_minute,missingBand.end_minute,missingBand.multiplier_bps]);
await db.query('update spa_compensation_profiles set active=false where job_title_id=$1 and employment_type_code=$2',[staff[0].job_title_id,staff[0].employment_type_code]);
await reject(()=>admin('spa_payroll_run_save',[...range,null,true]),/PAYROLL_COMPENSATION_REQUIRED/);
await db.query('update spa_compensation_profiles set active=true where job_title_id=$1 and employment_type_code=$2',[staff[0].job_title_id,staff[0].employment_type_code]);

// Explicit designation survives reassignment and is paid to the actual tech.
const slot=(await as(null,'select * from spa_availability($1,$2,$3)',[service.id,'2026-10-08',staff[0].id])).find(s=>s.available);
check(Boolean(slot),'controlled booking has a roster-based available slot');
const booking=await call(null,'spa_create_booking',[randomUUID(),service.id,'2026-10-08',slot.starts_at,staff[0].id,'指定客測試','0988333444',0,'']);
const appointment=(await db.query('select id from spa_appointments where manage_token=$1',[booking.manage_token])).rows[0].id;
await admin('spa_appointment_reassign',[appointment,staff[1].id,'現場改派']);
await db.query("update spa_appointments set status='completed' where id=$1",[appointment]);
await reject(()=>admin('spa_payroll_run_save',[...range,null,true]),/PAYROLL_UNSETTLED_SERVICES/);
const checkout=await admin('spa_checkout',[randomUUID(),appointment,0,0,null,0,'cash']);
const actual=await rowFor(staff[1].id);
check(Number(actual.designated_clients)===1&&Number(actual.designated_bonus_cents)===Math.round(Number(checkout.revenue_cents)*0.05),'requested designation maps its bonus to actual reassigned therapist even without current member preference');
await db.query('update spa_customers set preferred_staff_id=null where id=(select customer_id from spa_appointments where id=$1)',[appointment]);
check(Number((await rowFor(staff[1].id)).designated_clients)===1,'designation remains frozen after member profile edits');

const finalized=await admin('spa_payroll_run_save',[...range,null,true]);
const finalizedSelf=await call(employee,'spa_staff_self',range);
check(finalizedSelf.metrics.payroll_status==='finalized','employee wage switches to the exact finalized period snapshot');
const frozen=JSON.stringify(finalizedSelf.payroll);
await reject(()=>admin('spa_payroll_adjustment_save',[staff[0].id,'2026-10-14','bonus',1,'locked']),/PAYROLL_LOCKED/);
await reject(()=>admin('spa_overtime_save',[staff[0].id,'2026-10-14','weekday',1,'locked']),/PAYROLL_LOCKED/);
await reject(()=>admin('spa_refund',[randomUUID(),appointment,'locked']),/PAYROLL_LOCKED/);
await reject(()=>admin('spa_appointment_reassign',[appointment,staff[0].id,'locked']),/PAYROLL_LOCKED/);
await reject(()=>admin('spa_pos_checkout',[randomUUID(),null,[{item_type:'product',item_id:product.id,quantity:1,staff_id:staff[0].id}],0,'cash','locked']),/PAYROLL_LOCKED/);
await reject(()=>admin('spa_payroll_run_save',['2026-10-15','2026-11-14',null,false]),/PAYROLL_OVERLAP/);
await db.query('update spa_appointments set note=$2 where id=$1',[appointment,'不影響薪資的備註']);
await db.query('update spa_orders set note=$2 where id=$1',[sale.id,'不影響薪資的備註']);
check(JSON.stringify((await call(employee,'spa_staff_self',range)).payroll)===frozen,'unrelated appointment and order notes stay editable without changing finalized wages');
await admin('spa_compensation_profile_save_v2',[staff[0].job_title_id,staff[0].employment_type_code,'hourly',25000,1500,2500,800,0,0,true]);
check(JSON.stringify((await call(employee,'spa_staff_self',range)).payroll)===frozen,'later salary configuration edits do not alter the employee finalized wage snapshot');
check(Number((await call(employee,'spa_staff_self',range)).profile.base_pay_cents)===Number(finalizedSelf.profile.base_pay_cents),'employee finalized period displays the same wage rate as its retained snapshot');
await admin('spa_payroll_reopen',[finalized,'更正測試']);
await admin('spa_payroll_adjustment_save',[staff[0].id,'2026-10-14','bonus',1,'reopened']);
check((await call(employee,'spa_staff_self',range)).metrics.payroll_status==='preview','explicit owner reopen restores live recalculation');

console.log(`Payroll consistency checks passed (${checks} assertions).`);
await db.close();
