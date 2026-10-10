import {PGlite} from '@electric-sql/pglite';
import {readFile,readdir,writeFile} from 'node:fs/promises';
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
create function public.payroll_source_test_now() returns timestamptz language sql stable as $$select '2026-10-06T10:00:00+08:00'::timestamptz$$;`);
const directory=new URL('../supabase/migrations/',import.meta.url);
for(const file of(await readdir(directory)).filter(file=>file.endsWith('.sql')).sort())await db.exec((await readFile(new URL(file,directory),'utf8')).replaceAll('now()','public.payroll_source_test_now()'));
const owner=randomUUID(),employee=randomUUID(),outsider=randomUUID();
const people=(await db.query("select * from spa_staff where active and employment_status='active' order by display_order limit 2")).rows;
const staff=people[0],other=people[1],range=['2026-10-05','2026-10-15'];
await db.query('insert into auth.users(id,email) values($1,$2),($3,$4),($5,$6)',[owner,'owner@sources.test',employee,'staff@sources.test',outsider,'outsider@sources.test']);
await db.query("insert into spa_roles(user_id,role,staff_id,login_name) values($1,'owner',null,null),($2,'therapist',$3,'source_staff')",[owner,employee,staff.id]);
async function as(user,sql,args=[]){await db.exec('begin');try{await db.exec('set local role '+(user?'authenticated':'anon'));await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)",[user||'',JSON.stringify({iat:Math.floor(Date.now()/1000)+60})]);const result=await db.query(sql,args);await db.exec('commit');return result.rows;}catch(error){await db.exec('rollback');throw error;}}
async function call(user,name,args=[]){return(await as(user,`select public.${name}(${args.map((_,index)=>'$'+(index+1)).join(',')}) result`,args))[0]?.result;}
const admin=(name,args=[])=>call(owner,name,args);
const sources=(id=staff.id,rule=null,user=owner)=>call(user,'spa_payroll_sources',[id,...range,rule]);
const service=(await db.query("select * from spa_services where active and duration_minutes=45 order by display_order limit 1")).rows[0];
const product=(await db.query("select * from spa_products where status='active' order by display_order limit 1")).rows[0];
const room=(await db.query('select id from spa_rooms where active order by name limit 1')).rows[0].id;
// These arbitrary-period/source-snapshot assertions intentionally exercise the
// preserved legacy engine. Keep all migrations loaded and activate it explicitly;
// the chronological full-month engine has its own test-payroll-redesign.mjs.
const rule=(await db.query("select id from spa_payroll_rule_versions where calculation_engine='legacy_period_average' and effective_from<=(public.payroll_source_test_now() at time zone 'Asia/Taipei')::date order by effective_from desc,version_no desc limit 1")).rows[0].id;
await admin('spa_payroll_rule_activate',[rule]);
for(const person of people){
 await db.query('delete from spa_payroll_commission_tiers where job_title_id=$1 and employment_type_code=$2',[person.job_title_id,person.employment_type_code]);
 await admin('spa_compensation_profile_save_v2',[person.job_title_id,person.employment_type_code,'hourly',20000,1000,2000,500,0,0,true]);
}
await db.query('update spa_payroll_rule_versions set include_regular_commission=false where id=$1',[rule]);
const customer=await admin('spa_customer_save',[null,'来源完整隐私测试','0988111222','','一般會員','',null]);
await db.query('update spa_customers set preferred_staff_id=$2 where id=$1',[customer,staff.id]);
await db.query("insert into spa_wallet_entries(customer_id,request_id,amount_cents,kind,note,created_by) values($1,$2,200000,'topup','fixture',$3)",[customer,randomUUID(),owner]);
async function appointment(date,time,person=staff.id,tea=0){
 return (await db.query(`insert into spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents,tea_cents,booking_preference)
 values($1,$2,$3,$4,$5,$6,$7::timestamptz,$7::timestamptz+interval '45 minutes',$7::timestamptz+interval '60 minutes','completed',$8,$9,$10,'designated') returning *`,[randomUUID(),customer,person,room,service.id,date,`${date}T${time}:00+08:00`,service.name,service.price_cents,tea])).rows[0];
}
const settled=await appointment('2026-10-06','10:00',staff.id,10000),unsettled=await appointment('2026-10-07','10:00'),refunded=await appointment('2026-10-08','10:00');
const checkout=await admin('spa_checkout',[randomUUID(),settled.id,5000,20000,null,3000,'cash']);
await admin('spa_checkout',[randomUUID(),refunded.id,0,0,null,0,'cash']);
await admin('spa_refund',[randomUUID(),refunded.id,'測試退款']);
await appointment('2026-10-09','10:00',other.id);
const sale=await admin('spa_pos_checkout',[randomUUID(),customer,[{item_type:'service',item_id:service.id,quantity:2,staff_id:staff.id},{item_type:'product',item_id:product.id,quantity:2,staff_id:staff.id},{item_type:'product',item_id:product.id,quantity:1,staff_id:other.id}],12345,'cash','來源折扣']);
const time=await admin('spa_time_entry_save',[null,staff.id,'2026-10-06','2026-10-06T10:00:00+08:00','2026-10-06T18:00:35+08:00',30,'核准工時']);
const attendance=(await db.query(`insert into spa_attendance(staff_id,work_date,clock_in,clock_out,effective_start,effective_end,break_minutes,status,time_entry_id)
 values($1,'2026-10-06','2026-10-06T10:00:00+08:00','2026-10-06T18:00:35+08:00','2026-10-06T10:00:00+08:00','2026-10-06T18:00:35+08:00',30,'approved',$2) returning id`,[staff.id,time])).rows[0].id;
await db.query(`insert into spa_time_entries(staff_id,work_date,started_at,ended_at,status,note) values
 ($1,'2026-10-07','2026-10-07T10:00:00+08:00','2026-10-07T11:00:00+08:00','draft','未核准不計薪'),
 ($1,'2026-10-08','2026-10-08T10:00:00+08:00','2026-10-08T11:00:00+08:00','rejected','退回不計薪'),
 ($2,'2026-10-06','2026-10-06T10:00:00+08:00','2026-10-06T18:00:00+08:00','approved','其他人')`,[staff.id,other.id]);
await admin('spa_overtime_save',[staff.id,'2026-10-06','weekday',120,'第一段']);
await admin('spa_overtime_save',[staff.id,'2026-10-06','weekday',120,'第二段']);
await admin('spa_overtime_save',[staff.id,'2026-10-01','weekday',50,'本期外但月與季內']);
await admin('spa_overtime_save',[staff.id,'2026-09-30','weekday',60,'上一季不計上限']);
await db.query("insert into spa_overtime_entries(staff_id,work_date,overtime_type,minutes,reason,status) values($1,'2026-10-06','weekday',30,'未核准','draft')",[staff.id]);
for(const [kind,amount]of[['bonus',500],['allowance',1234],['deduction',345],['designated_bonus',777]])await admin('spa_payroll_adjustment_save',[staff.id,'2026-10-12',kind,amount,`${kind} 來源`]);
await admin('spa_payroll_adjustment_save',[staff.id,'2026-10-16','bonus',10000,'本期外']);
await admin('spa_payroll_adjustment_save',[other.id,'2026-10-12','bonus',99999,'其他人獎金']);

await reject(()=>sources(staff.id,null,null),/permission denied|FORBIDDEN/);
await reject(()=>sources(staff.id,null,outsider),/FORBIDDEN/);
await reject(()=>sources(other.id,null,employee),/FORBIDDEN/);
await reject(()=>sources(staff.id,rule,employee),/FORBIDDEN/);
await reject(()=>as(employee,'select * from spa_payroll_source_snapshots'),/permission denied/);
await reject(()=>as(employee,'select spa_private.payroll_source_records($1,$2,$3)',[staff.id,...range]),/permission denied/);
await reject(()=>admin('spa_payroll_sources',[staff.id,'2026-10-15','2026-10-05',null]),/INVALID_DATE/);
await reject(()=>admin('spa_payroll_sources',[staff.id,null,range[1],null]),/INVALID_DATE/);
await reject(()=>admin('spa_payroll_sources',[randomUUID(),...range,null]),/NOT_FOUND/);
let packet=await sources(),preview=(await admin('spa_payroll_preview',[...range,null])).find(row=>row.staff_id===staff.id);
check(packet.basis==='preview'&&packet.evidence_mode==='live','unsaved payroll reads current evidence without claiming a historical capture');
check(JSON.stringify(packet.wage)===JSON.stringify(preview),'drilldown uses the same selected-period payroll calculation as summary');
check(packet.reconciliation.checks.length===19&&packet.reconciliation.checks.every(item=>item.matches===true),'all 19 source metrics and adjustment components reconcile exactly');
check(packet.reconciliation.source_matches&&packet.reconciliation.formula_matches,'formula and source reconciliation both pass');
check(packet.sources.services.length===3&&packet.sources.pos_services.length===1&&packet.sources.products.length===1,'appointment, POS service and product records are separate and scoped to actual staff');
check(packet.source_totals.completed_count===5&&packet.source_totals.service_count===3,'POS quantity and refunded/unsettled appointments reconcile to completed versus payable service counts');
check(packet.source_totals.refunded_service_count===1&&packet.source_totals.unsettled_completed_count===1,'unpaid or refunded service rows remain traceable with zero contribution');
check(packet.sources.services.filter(row=>!row.contributes).every(row=>row.net_cents===0),'nonpayable service rows never inflate sales or designation');
const serviceSource=packet.sources.services.find(row=>row.id===settled.id),posSource=packet.sources.pos_services[0],productSource=packet.sources.products[0];
check(serviceSource.checkout_id===checkout.id&&serviceSource.reference===settled.reference,'appointment contribution has both booking reference and checkout identity');
check(serviceSource.net_cents===Number(checkout.revenue_cents)-10000,'service contribution subtracts tea exactly once and uses recognized revenue');
check(serviceSource.net_cents!==Number(checkout.cash_cents)+3000,'wallet payment and tips are not additional wage revenue');
const lines=(await db.query('select * from spa_order_items where order_id=$1',[sale.id])).rows;
check(posSource.order_id===sale.id&&productSource.order_id===sale.id&&posSource.id!==productSource.id,'mixed POS order keeps separate original line IDs with a shared order reference');
check(posSource.net_cents===Number(lines.find(line=>line.id===posSource.id).net_total_cents)&&productSource.net_cents===Number(lines.find(line=>line.id===productSource.id).net_total_cents),'source net amounts equal the discount allocations actually posted to POS');
check(packet.source_totals.service_sales_cents===serviceSource.net_cents+posSource.net_cents&&packet.source_totals.product_sales_cents===productSource.net_cents,'category totals sum only their own actual revenue');
check(packet.source_totals.designated_clients===3&&packet.source_totals.designated_service_sales_cents===packet.source_totals.service_sales_cents,'designation sources preserve both appointment and POS snapshot quantity');
check(packet.sources.time_entries.length===1&&packet.sources.time_entries[0].id===time&&packet.sources.time_entries[0].attendance_id===attendance&&packet.source_totals.work_minutes===450,'approved attendance links original punches, floors seconds and deducts break once');
check(packet.sources.overtime.length===2&&packet.source_totals.overtime_minutes===240&&packet.source_totals.quarter_overtime_minutes===290&&packet.source_totals.max_month_overtime_minutes===290,'current-period overtime and contextual month/quarter limit counters reconcile');
check(packet.sources.overtime_context.length===3&&packet.sources.overtime_context.some(row=>row.date==='2026-10-01'&&!row.in_period&&row.in_quarter),'out-of-period overtime evidence is visible only where needed for cap calculations');
check(packet.sources.adjustments.length===4&&packet.source_totals.manual_designated_bonus_cents===777&&packet.source_totals.bonus_cents===500,'manual designated bonus maps to its own component without doubling other bonus');
check(Number(packet.wage.designated_bonus_cents)===Math.round(packet.source_totals.designated_service_sales_cents*.05)+777,'designated percentage and manual additions reconcile to actual payable component');
check(packet.rule_reference.profile.job_title_id===staff.job_title_id&&packet.rule_reference.rates.every(row=>row.employment_type_code===staff.employment_type_code),'rule reference includes only applicable title and employment rates');
check(!JSON.stringify(packet).includes('0988111222')&&!JSON.stringify(packet).includes('来源完整隐私测试')&&!JSON.stringify(packet).includes('customer_id')&&!JSON.stringify(packet).includes('manage_token'),'sources contain no customer phone, full identity, customer IDs or access tokens');
const own=await sources(null,null,employee);
check(own.staff_id===staff.id&&JSON.stringify(own.wage)===JSON.stringify(packet.wage),'employee automatically maps to own personnel row and same payable calculation');
check(!JSON.stringify(own).includes(other.id)&&!JSON.stringify(own).includes('其他人獎金'),'employee sees no other personnel record or private wage source');

// Catalogue edits and member preferences cannot rewrite already sold facts.
await db.query('update spa_services set duration_minutes=90 where id=$1',[service.id]);
await db.query('update spa_customers set preferred_staff_id=$2 where id=$1',[customer,other.id]);
packet=await sources();
check(packet.sources.pos_services[0].duration_minutes===45&&packet.sources.pos_services[0].designated&&packet.sources.services.find(row=>row.id===settled.id).designated,'source durations and designated facts are frozen at service sale');
check(packet.reconciliation.source_matches,'source totals stay reconciled after unrelated catalogue/member edits');
const draft=await admin('spa_payroll_run_save',[...range,rule,false]);
let saved=(await db.query('select packet from spa_payroll_source_snapshots where run_id=$1 and staff_id=$2',[draft,staff.id])).rows[0].packet;
check(saved.sources.time_entries[0].id===time&&saved.sources.adjustments.length===4,'saving draft atomically stores exact contributing source IDs');
check((await sources()).evidence_mode==='live','draft detail remains current; saved draft is never misrepresented as finalized');
await db.query('update spa_time_entries set note=$2 where id=$1',[time,'核准工時補充']);
check((await sources()).run.needs_recalculation,'updated wage source surfaces stale saved draft status');
await admin('spa_payroll_run_save',[...range,rule,false]);
saved=(await db.query('select packet from spa_payroll_source_snapshots where run_id=$1 and staff_id=$2',[draft,staff.id])).rows[0].packet;
check(saved.sources.time_entries[0].note==='核准工時補充','resaving recaptures references even when all numerical wage rows remain identical');
check(!(await sources()).run.needs_recalculation,'successful source recapture clears recalculation status through existing save workflow');

// Finalization first resolves the same blockers as ordinary payroll. The new
// evidence trigger does not bypass attendance, unsettled service or OT guards.
await reject(()=>admin('spa_payroll_run_save',[...range,rule,true]),/PAYROLL_PENDING_TIME_ENTRIES|PAYROLL_PENDING_OVERTIME/);
await db.query("update spa_time_entries set status='rejected' where status='draft'");
await db.query("update spa_overtime_entries set status='rejected' where status='draft'");
await reject(()=>admin('spa_payroll_run_save',[...range,rule,true]),/PAYROLL_UNSETTLED_SERVICES/);
await admin('spa_checkout',[randomUUID(),unsettled.id,0,0,null,0,'cash']);
const otherUnsettled=(await db.query("select id from spa_appointments where staff_id=$1 and status='completed' and not exists(select 1 from spa_checkouts where appointment_id=spa_appointments.id)",[other.id])).rows[0].id;
await admin('spa_checkout',[randomUUID(),otherUnsettled,0,0,null,0,'cash']);
await admin('spa_payroll_run_save',[...range,rule,true]);
const closed=await sources(),frozen=JSON.stringify(closed.wage),frozenSources=JSON.stringify(closed.sources),frozenRules=JSON.stringify(closed.rule_reference);
check(closed.basis==='finalized'&&closed.evidence_mode==='snapshot'&&closed.reconciliation.historical_sources_complete,'finalized detail uses retained wage and source snapshot');
check(closed.sources.services.find(row=>row.id===unsettled.id).contributes&&closed.reconciliation.source_matches,'finalization recaptures newly settled services atomically');
const closedSelf=await sources(null,null,employee),self=await call(employee,'spa_staff_self',range);
check(JSON.stringify(closedSelf.wage)===JSON.stringify(self.payroll)&&self.profile.id===staff.id,'employee source view and own payroll total share exact finalized row and retained personnel identity');
await reject(()=>admin('spa_payroll_adjustment_save',[staff.id,'2026-10-12','bonus',1,'locked']),/PAYROLL_LOCKED/);
await admin('spa_compensation_profile_save_v2',[staff.job_title_id,staff.employment_type_code,'hourly',25000,1500,2500,800,0,0,true]);
await db.query('update spa_payroll_overtime_rates set multiplier_bps=multiplier_bps+1000 where rule_version_id=$1 and employment_type_code=$2',[rule,staff.employment_type_code]);
let later=await sources();
check(JSON.stringify(later.wage)===frozen&&JSON.stringify(later.sources)===frozenSources&&JSON.stringify(later.rule_reference)===frozenRules,'later compensation and overtime-rate edits cannot rewrite finalized money, references or applied rules');
check(later.rule_reference.profile.base_pay_rate_cents===20000&&later.current_wage.base_pay_rate_cents===25000,'stored applied rate stays distinguishable from later current trial settings');
const trial=await sources(staff.id,rule);
check(trial.basis==='preview'&&trial.evidence_mode==='live'&&JSON.stringify(trial.finalized_wage)===frozen&&Number(trial.wage.total_cents)!==Number(closed.wage.total_cents),'owner selected-rule trial exposes current calculation alongside original finalized total');
check(trial.reconciliation.source_matches&&trial.reconciliation.formula_matches,'current trial also reconciles source categories and full component formula');

// A retained old run without source capture is honest about evidence gaps.
await db.query('delete from spa_payroll_source_snapshots where run_id=$1 and staff_id=$2',[draft,staff.id]);
const legacy=await sources();
check(legacy.basis==='finalized'&&legacy.evidence_mode==='legacy_current_records'&&!legacy.reconciliation.historical_sources_complete&&JSON.stringify(legacy.wage)===frozen,'preexisting finalized wages lacking source snapshots retain original amounts and flag incomplete history');
// Simulate a legacy calculation row without later-added source counters. Null
// checks must never invent zero or claim that missing evidence reconciles.
await db.exec('alter table spa_payroll_runs disable trigger spa_payroll_capture_sources');
await db.query("update spa_payroll_runs set calculation_snapshot=jsonb_set(calculation_snapshot,'{rows}',(select jsonb_agg(case when value->>'staff_id'=$2 then value-'quarter_overtime_minutes' else value end) from jsonb_array_elements(calculation_snapshot->'rows'))) where id=$1",[draft,staff.id]);
await db.exec('alter table spa_payroll_runs enable trigger spa_payroll_capture_sources');
check((await sources()).reconciliation.checks.find(item=>item.key==='quarter_overtime_minutes').matches===null,'missing legacy metric is explicitly unknown rather than fabricated as matched');
await db.exec('alter table spa_payroll_runs disable trigger spa_payroll_capture_sources');
await db.query("update spa_payroll_runs set calculation_snapshot=jsonb_set(calculation_snapshot,'{rows}',(select jsonb_agg(value) from jsonb_array_elements(calculation_snapshot->'rows') where value->>'staff_id'<>$2)) where id=$1",[draft,staff.id]);
await db.exec('alter table spa_payroll_runs enable trigger spa_payroll_capture_sources');
const itemFallback=await sources();
check(itemFallback.basis==='finalized'&&itemFallback.evidence_mode==='legacy_current_records'&&itemFallback.wage.total_cents===closed.wage.total_cents&&itemFallback.wage.base_pay_rate_cents===20000,'legacy runs missing detailed row JSON use saved payroll items rather than current recalculation');
check(itemFallback.wage.job_title_id==null&&itemFallback.wage.product_commission_bps==null&&itemFallback.reconciliation.checks.find(item=>item.key==='designated_service_sales_cents').matches===null,'legacy item fallback never fabricates missing historical title, product rate or designated revenue');
await db.query('delete from spa_payroll_items where run_id=$1 and staff_id=$2',[draft,staff.id]);
await reject(()=>sources(),/NOT_FOUND/);
await admin('spa_payroll_reopen',[draft,'來源重建測試']);
await admin('spa_payroll_run_save',[...range,rule,false]);
check((await db.query('select count(*)::int count from spa_payroll_source_snapshots where run_id=$1',[draft])).rows[0].count>=2,'reopened draft save rebuilds source evidence through normal explicit save');
const backup=await admin('spa_backup_export',['all',null,null]);
check(backup.payroll_source_snapshots.some(row=>row.run_id===draft&&row.staff_id===staff.id),'reset backup includes source snapshots together with saved payroll');
await db.query('delete from spa_payroll_runs where id=$1',[draft]);
check((await db.query('select count(*)::int count from spa_payroll_source_snapshots where run_id=$1',[draft])).rows[0].count===0,'deleting a run cascades its source packets and leaves no orphan payroll evidence');
await db.query('update spa_roles set active=false where user_id=$1',[employee]);
await reject(()=>sources(null,null,employee),/FORBIDDEN/);
if(process.env.PAYROLL_SOURCES_QA_FILE)await writeFile(process.env.PAYROLL_SOURCES_QA_FILE,JSON.stringify({owner:trial,employee:closedSelf,legacy},null,2));
await db.close();console.log(`Payroll sources checks passed: ${checks}`);
