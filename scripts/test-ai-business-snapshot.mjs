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
create function public.snapshot_test_now() returns timestamptz language sql stable as $$select '2026-10-08T16:05:00Z'::timestamptz$$;`);
const directory=new URL('../supabase/migrations/',import.meta.url);
for(const file of(await readdir(directory)).filter(file=>file.endsWith('.sql')).sort())await db.exec((await readFile(new URL(file,directory),'utf8')).replaceAll('now()','public.snapshot_test_now()'));
const owner=randomUUID(),employee=randomUUID(),outsider=randomUUID(),manager=randomUUID();
await db.query('insert into auth.users(id,email) values($1,$2),($3,$4),($5,$6),($7,$8)',[owner,'owner@snapshot.test',employee,'employee@snapshot.test',outsider,'outsider@snapshot.test',manager,'manager@snapshot.test']);
const staff=(await db.query("select * from spa_staff where active and employment_status='active' order by display_order limit 2")).rows;
await db.query("insert into spa_roles(user_id,role,staff_id,login_name) values($1,'owner',null,null),($2,'therapist',$3,'snapshot_employee'),($4,'manager',null,'snapshot_manager')",[owner,employee,staff[0].id,manager]);
async function as(user,sql,args=[],role=user?'authenticated':'anon',iat=2000000000){await db.exec('begin');try{await db.exec(`set local role ${role}`);await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)",[user||'',JSON.stringify({iat})]);const result=await db.query(sql,args);await db.exec('commit');return result.rows;}catch(error){await db.exec('rollback');throw error;}}
const snapshot=async(user,from='2026-10-01',to='2026-10-31',role,iat)=>(await as(user,'select public.spa_ai_business_snapshot($1,$2) result',[from,to],role,iat))[0].result;
const admin=async(name,args=[])=>(await as(owner,`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`,args))[0].result;
await reject(()=>snapshot(null),/permission denied/);
await reject(()=>snapshot(owner,null,null,'service_role'),/permission denied/);
await reject(()=>snapshot(null,null,null,'authenticated'),/FORBIDDEN/);
await reject(()=>snapshot(outsider),/FORBIDDEN/);
await reject(()=>snapshot(manager),/FORBIDDEN/);
for(const [from,to] of [['2026-10-10','2026-10-01'],['1899-12-31','2026-10-01'],['-infinity','2026-10-01'],['2026-10-01','infinity']])await reject(()=>snapshot(owner,from,to),/INVALID_DATE/);
const definition=(await db.query("select p.prosecdef,p.provolatile,p.proconfig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='spa_ai_business_snapshot'")).rows[0];
check(definition.prosecdef&&definition.provolatile==='s'&&definition.proconfig.includes('search_path=""'),'read-only stable security definer with empty search path');
const privileges=(await db.query("select has_function_privilege('anon','public.spa_ai_business_snapshot(date,date)','execute') anonymous,has_function_privilege('authenticated','public.spa_ai_business_snapshot(date,date)','execute') authenticated,has_function_privilege('service_role','public.spa_ai_business_snapshot(date,date)','execute') service")).rows[0];
check(!privileges.anonymous&&privileges.authenticated&&!privileges.service,'only authenticated role has execution grant');
let result=await snapshot(owner);check(result.scope==='store'&&result.schema_version===1,'owner store contract works before fixtures');
const service=(await db.query("select * from spa_services where duration_minutes=45 order by display_order limit 1")).rows[0];
const product=(await db.query("select * from spa_products where status='active' order by display_order limit 1")).rows[0];
const room=(await db.query('select id from spa_rooms limit 1')).rows[0].id;
const customer=await admin('spa_customer_save_v2',[null,'PRIVATE_CUSTOMER_SECRET','0988123456','private@example.test','一般會員','PRIVATE_MEDICAL_SECRET','guest',null]);
await db.query("update spa_customers set created_at='2023-01-01T00:00:00+08:00' where id=$1",[customer]);
let appointmentIndex=0;
async function appointment(day,status,s=staff[0].id){return(await db.query(`insert into spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents,tea_cents,note)
 values($1,$2,$3,$4,$5,$6,($6::date::timestamp+make_interval(mins=>$8)) at time zone 'Asia/Taipei',($6::date::timestamp+make_interval(mins=>$8+45)) at time zone 'Asia/Taipei',($6::date::timestamp+make_interval(mins=>$8+60)) at time zone 'Asia/Taipei',$7,'service',10000,1000,'PRIVATE_APPOINTMENT_SECRET') returning id`,[randomUUID(),customer,s,room,service.id,day,status,appointmentIndex++*75])).rows[0].id;}
async function checkout(id,amount,refunded=false){await db.query(`insert into spa_checkouts(appointment_id,request_id,gross_cents,revenue_cents,cash_cents,wallet_cents,created_by,method,refunded_at) values($1,$2,$3,$3,$3,0,$4,'cash',case when $5 then '2026-10-08T01:00:00Z'::timestamptz end)`,[id,randomUUID(),amount,owner,refunded]);}
const historical=await appointment('2023-02-02','completed');await checkout(historical,12345);
const settled=await appointment('2026-10-08','completed');await checkout(settled,10001);
await appointment('2026-10-08','completed');
const refunded=await appointment('2026-10-08','completed');await checkout(refunded,20002,true);
const other=await appointment('2026-10-08','completed',staff[1].id);await checkout(other,30003);
for(const status of ['pending','confirmed','checked_in','in_service','cancelled','no_show'])await appointment('2026-10-08',status);
await db.query("insert into spa_reviews(appointment_id,rating,comment,reply) values($1,5,'PRIVATE_REVIEW_SECRET','PRIVATE_REPLY_SECRET')",[settled]);
// Multiple reassignment events remain one appointment fact and use current staff.
await db.query('insert into spa_appointment_staff_changes(appointment_id,previous_staff_id,new_staff_id,reason,changed_by) values($1,$2,$3,$4,$5),($1,$3,$2,$4,$5)',[settled,staff[1].id,staff[0].id,'PRIVATE_REASSIGN_SECRET',owner]);
await db.query("insert into spa_staff_schedule_submissions(staff_id,schedule_month,submitted_by) values($1,'2026-10-01',$2),($3,'2026-10-01',$2)",[staff[0].id,owner,staff[1].id]);
await db.query("insert into spa_staff_schedule_change_requests(staff_id,business_date,desired_working,desired_start_minute,desired_end_minute,reason,requested_by,status) values($1,'2026-10-12',true,600,1080,'PRIVATE_REQUEST_SECRET',$2,'pending'),($3,'2026-10-12',true,600,1080,'OTHER_REQUEST_SECRET',$2,'approved')",[staff[0].id,owner,staff[1].id]);
await db.query("insert into spa_time_off(staff_id,starts_at,ends_at,reason) values($1,'2026-10-12T10:00:00+08:00','2026-10-12T11:00:00+08:00','PRIVATE_TIME_OFF_SECRET')",[staff[0].id]);
const pos=await admin('spa_pos_checkout',[randomUUID(),customer,[{item_type:'service',item_id:service.id,quantity:2,staff_id:staff[0].id},{item_type:'product',item_id:product.id,quantity:3,staff_id:staff[1].id}],12345,'cash','PRIVATE_POS_SECRET']);
await db.query("update spa_orders set paid_at='2026-10-08T16:00:00Z' where id=$1",[pos.id]);
const lines=(await db.query('select * from spa_order_items where order_id=$1',[pos.id])).rows;
const serviceLine=lines.find(i=>i.item_type==='service'),productLine=lines.find(i=>i.item_type==='product');
await db.query("insert into spa_cash_entries(request_id,amount_cents,category,method,created_by,created_at,note) values($1,-3456,'expense','cash',$2,'2026-10-08T15:59:59Z','PRIVATE_EXPENSE_SECRET'),($3,-20002,'refund','cash',$2,'2026-10-08T01:00:00Z','PRIVATE_REFUND_SECRET')",[randomUUID(),owner,randomUUID()]);
await db.query("insert into spa_wallet_entries(customer_id,amount_cents,kind,request_id,note) values($1,45678,'adjustment',$2,'PRIVATE_WALLET_SECRET')",[customer,randomUUID()]);
await admin('spa_time_entry_save',[null,staff[0].id,'2026-10-08','2026-10-08T10:00:00+08:00','2026-10-08T11:00:59+08:00',5,'PRIVATE_TIME_SECRET']);
await admin('spa_time_entry_save',[null,staff[1].id,'2026-10-08','2026-10-08T10:00:00+08:00','2026-10-08T12:00:00+08:00',0,'OTHER_TIME_SECRET']);
await db.query("insert into spa_attendance(staff_id,work_date,clock_in,status,review_note) values($1,'2026-10-08','2026-10-08T10:00:00+08:00','open','PRIVATE_GEO_NOTE'),($2,'2026-10-08','2026-10-08T10:00:00+08:00','pending','OTHER_GEO_NOTE')",[staff[0].id,staff[1].id]);
await db.query("insert into spa_daily_shifts(staff_id,business_date,is_working,start_minute,end_minute,note) values($1,'2026-10-10',true,600,1080,'PRIVATE_SHIFT_SECRET'),($2,'2026-10-10',false,600,1080,'OTHER_SHIFT_SECRET')",[staff[0].id,staff[1].id]);
result=await snapshot(owner);
check(result.bookings.total===10&&result.bookings.completed===4&&result.bookings.settled_completed===2&&result.bookings.unsettled_completed===1&&result.bookings.refunded_completed===1,'all booking statuses and settlements count independently');
check(result.sales.appointment_service_cents===9001+29003&&result.sales.appointment_tea_cents===2000,'settled services exclude refunded/unsettled and separate tea');
check(result.sales.pos_service_cents===Number(serviceLine.net_total_cents)&&result.sales.pos_product_cents===Number(productLine.net_total_cents),'paid POS sums exact discounted net lines with distinct service/product attribution');
check(result.sales.total_net_cents===10001+30003+Number(pos.total_cents),'totals count each appointment/order line once');
check(result.finances.expenses_cents===3456&&result.finances.checkout_refunds_cents===20002&&result.finances.cash_refunds_cents===20002,'refunds and expenses have positive safely named amounts');
check(result.current.wallet_liability_cents===45678,'current liability is distinct from selected period');
check(result.attendance.approved_work_minutes===175&&result.attendance.open===1&&result.attendance.pending===1&&result.attendance.missing_clock_out===2,'approved time floor/breaks and independent attendance states');
check(result.scheduling.daily_rows===2&&result.scheduling.working_rows===1&&result.scheduling.off_rows===1&&result.scheduling.planned_minutes===480,'dated roster coverage never multiplies service data');
check(result.bookings.reassigned===1&&result.staff.find(s=>s.id===staff[0].id).reassigned===1,'many reassignment events never duplicate current performer metrics');
check(result.scheduling.submissions===2&&result.scheduling.submitted_staff===2&&result.scheduling.submission_months===1&&result.scheduling.requests_pending===1&&result.scheduling.requests_approved===1&&result.scheduling.time_off_count===1,'schedule submission coverage and request/time-off counts are aggregate only');
check(result.payroll.status==='preview'&&result.payroll.pending_sources,'pending attendance explicitly labels unfinalized wages');
const serialized=JSON.stringify(result);
for(const secret of ['PRIVATE_','0988123456','private@example.test','manage_token','latitude','longitude','password','review_note'])check(!serialized.includes(secret),`snapshot excludes private ${secret}`);
const self=await snapshot(employee);
check(self.scope==='self'&&self.staff.length===1&&self.staff[0].id===staff[0].id,'staff identities are exclusively own personnel');
check(!('finances' in self)&&!('current' in self)&&!('customers' in self),'personal scope omits all store finances and customer contact/count context');
check(self.sales.pos_product_cents===0&&self.sales.pos_service_cents===Number(serviceLine.net_total_cents)&&self.sales.appointment_service_cents===9001,'self sales use actual performer/seller rather than order/customer owner');
check(self.attendance.approved_work_minutes===55&&self.attendance.pending===0&&self.scheduling.daily_rows===1,'self attendance and roster exclude other staff');
check(self.scheduling.submissions===1&&self.scheduling.submitted_staff===1&&self.scheduling.requests_approved===0&&self.scheduling.requests_pending===1,'self submission/request coverage excludes other personnel');
check(self.payroll.rows.every(row=>row.staff_id===staff[0].id),'personal payroll never returns another wage row');
// An export-sized history is aggregated without a row cap.
await db.query(`insert into spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents)
 select gen_random_uuid(),$1,$2,$3,$4,'2024-01-01','2024-01-01T10:00:00+08:00','2024-01-01T10:45:00+08:00','2024-01-01T11:00:00+08:00','cancelled','service',10000 from generate_series(1,550)`,[customer,staff[0].id,room,service.id]);
const wide=await snapshot(owner,'2023-01-01','2026-10-31');
check(wide.bookings.completed===5&&wide.sales.appointment_service_cents===11345+9001+29003&&wide.payroll.status==='unsupported_range'&&wide.payroll.total_cents===null&&wide.payroll.rows.length===0,'multi-year exact totals work without pretending unsupported wage preview is zero');
check(wide.bookings.total===561&&wide.bookings.cancelled===551,'history beyond common 500-row limits is counted exactly');
const all=await snapshot(owner,null,null);
check(all.period.from==='2023-01-01'&&all.period.to==='2026-10-09'&&all.snapshot_date==='2026-10-09'&&all.earliest_date==='2023-01-01','all history resolves real source boundary and Taipei date across UTC midnight');
const selfAll=await snapshot(employee,null,null);
check(selfAll.period.from==='2023-02-02'&&selfAll.earliest_date==='2023-02-02','personal earliest business date never reveals earlier customer creation');
const eighth=await snapshot(owner,'2026-10-08','2026-10-08'),ninth=await snapshot(owner,'2026-10-09','2026-10-09');
check(eighth.sales.pos_service_cents===0&&ninth.sales.pos_service_cents===Number(serviceLine.net_total_cents),'POS Taipei midnight uses half-open boundaries');
// Current membership semantics include archived accounts only in total/archive.
const archived=await admin('spa_customer_save_v2',[null,'ARCHIVED_CUSTOMER_SECRET','0988123457','archive@example.test','一般會員','PRIVATE_ARCHIVE_SECRET','member',null]);
await db.query("update spa_customers set archived_at=public.snapshot_test_now() where id=$1",[archived]);
result=await snapshot(owner);
check(result.customers.current_members===1&&result.customers.current_guests===0&&result.customers.current_archived===1&&result.customers.new_in_period===1,'booked guest is promoted to member; archived membership is excluded from active member totals');
// Saved payroll JSON is re-projected, including for a finalized exact period.
const rule=(await db.query("select id from spa_payroll_rule_versions where status='active' limit 1")).rows[0].id;
await db.query("update spa_staff set contract_started_on='2026-10-01' where id=any($1::uuid[])",[[staff[0].id,staff[1].id]]);
const wageRow={staff_id:staff[0].id,role:'初級技師',employment_type:'兼職',employment_type_code:'part_time',pay_basis:'hourly',total_cents:56789,work_minutes:55,
 minimum_service_minutes:2400,self_sourced_commission_bps:5000,service_commission_mode:'ordered_tiers',contractor_count_scope:'lifetime',service_policy_status:'needs_confirmation',commission_policy_ready:false,
 commission_warning:'PRIVATE_WARNING_SECRET',calculation:{rule_version:4,calculation_engine:'ordered_v2',profile_source:'rule_version_snapshot',tier_mode:'chronological_per_service',tier_reset:'calendar_month',product_commission_basis:'sale_percentage_snapshot',self_sourced_basis:'explicit_settlement_snapshot',component_total_before_floor_cents:56789,private_note:'PRIVATE_CALCULATION_SECRET'},
 private_note:'PRIVATE_PAYROLL_SECRET',customer_phone:'0988123456'};
await db.query("insert into spa_payroll_runs(period_start,period_end,rule_version_id,status,created_by,calculation_snapshot) values('2026-10-01','2026-10-31',$1,'finalized',$2,$3)",[rule,owner,{rows:[wageRow,{staff_id:staff[1].id,role:'承攬技師',employment_type_code:'contractor',contract_started_on:'2026-09-01',contract_start_pending:false,total_cents:98765,private_note:'OTHER_PAYROLL_SECRET'}]}]);
result=await snapshot(employee);
check(result.payroll.status==='finalized'&&result.payroll.total_cents===56789&&result.payroll.rows.length===1&&!JSON.stringify(result).includes('PAYROLL_SECRET')&&!JSON.stringify(result).includes('customer_phone'),'finalized payroll retains own saved amount while re-projecting raw snapshot fields');
check(result.payroll.rows[0].role==='初級技師'&&result.payroll.rows[0].employment_type==='兼職'&&result.payroll.rows[0].employment_type_code==='part_time'&&result.payroll.rows[0].pay_basis==='hourly','saved wage title, employment and pay basis survive the safe snapshot projection');
check(result.payroll.rows[0].minimum_service_minutes===2400&&result.payroll.rows[0].self_sourced_commission_bps===5000&&result.payroll.rows[0].contractor_count_scope==='lifetime'&&result.payroll.rows[0].service_policy_status==='needs_confirmation'&&result.payroll.rows[0].commission_policy_ready===false,'new rule gates and unresolved contractor rules are preserved without inventing eligibility');
check(result.payroll.rows[0].calculation.calculation_engine==='ordered_v2'&&result.payroll.rows[0].calculation.profile_source==='rule_version_snapshot'&&result.payroll.rows[0].calculation.tier_reset==='calendar_month','history carries explicit ordered engine and versioned profile calculation basis');
check(result.payroll.rows[0].has_commission_warning===true&&!JSON.stringify(result).includes('WARNING_SECRET')&&!JSON.stringify(result).includes('CALCULATION_SECRET'),'warning presence is boolean and arbitrary nested calculation notes never cross the RPC boundary');
check(result.payroll.rows[0].contract_started_on===null&&result.payroll.rows[0].contract_start_pending===null,'legacy wage cooperation fields remain unknown instead of being filled from current personnel');
const ownerHistory=await snapshot(owner);
const savedCooperation=ownerHistory.payroll.rows.find(row=>row.staff_id===staff[1].id);
check(savedCooperation.contract_started_on==='2026-09-01'&&savedCooperation.contract_start_pending===false,'safe historical projection preserves the saved cooperation start despite a different current staff date');
check(result.payroll.rows.length===1&&!JSON.stringify(result.payroll).includes('2026-09-01'),'employee cannot read another staff member cooperation date through payroll snapshots');
const promotedTitle=(await db.query("select id,name from spa_job_titles where code='ft_senior_advanced'")).rows[0];
await db.query("update spa_staff set job_title_id=$2,employment_type_code='full_time' where id=$1",[staff[0].id,promotedTitle.id]);
result=await snapshot(employee);
check(result.staff[0].title===promotedTitle.name&&result.payroll.rows[0].role==='初級技師'&&result.payroll.rows[0].employment_type_code==='part_time','later current-personnel promotion cannot rewrite historical finalized wage classification');
await db.query('update spa_roles set active=false where user_id=$1',[employee]);await reject(()=>snapshot(employee),/FORBIDDEN/);
await db.query("update spa_roles set active=true,login_after='2026-10-09T00:00:00+08:00' where user_id=$1",[employee]);await reject(()=>snapshot(employee,null,null,'authenticated',1),/FORBIDDEN/);
check((await snapshot(employee)).scope==='self','fresh JWT retains personal access after revocation boundary');
await db.query("update spa_staff set active=false,employment_status='departed',departed_on='2026-10-09',departure_reason='PRIVATE_DEPARTURE_SECRET' where id=$1",[staff[1].id]);
result=await snapshot(owner);
check(result.staff.find(s=>s.id===staff[1].id).employment_status==='departed'&&result.staff.find(s=>s.id===staff[1].id).service_sales_cents===29003,'departed staff contribution remains in exact historical operating totals');
// The RPC also works in a read-only transaction: no audit, quota or source write.
await db.exec('begin read only');
try{
 await db.exec('set local role authenticated');
 await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)",[owner,JSON.stringify({iat:2000000000})]);
 const readOnly=(await db.query("select public.spa_ai_business_snapshot('2023-01-01','2026-10-31') result")).rows[0].result;
 check(readOnly.bookings.total===561,'historical snapshot runs inside a PostgreSQL read-only transaction');
}finally{await db.exec('rollback');}
await db.query("update spa_role_profiles set active=false where code='therapist'");await reject(()=>snapshot(employee),/FORBIDDEN/);
await db.query("update spa_role_profiles set active=true where code='therapist'");
for(const change of ["active=false","employment_status='departed',departed_on='2026-10-09',departure_reason='fixture'","archived_at=public.snapshot_test_now()"]){
 await db.query(`update spa_staff set ${change} where id=$1`,[staff[0].id]);await reject(()=>snapshot(employee),/FORBIDDEN/);
 await db.query("update spa_staff set active=true,employment_status='active',departed_on=null,departure_reason='',archived_at=null where id=$1",[staff[0].id]);
}
await db.close();console.log(`AI business snapshot checks passed: ${checks}`);
