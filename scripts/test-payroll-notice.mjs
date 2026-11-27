import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFile,readdir} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';

const db=new PGlite();
const month=['2026-11-01','2026-11-30'];
const nextMonth=['2026-12-01','2026-12-31'];
const owner=randomUUID(),employee=randomUUID();
const query=async(sql,params=[]) => (await db.query(sql,params)).rows;
const one=async(sql,params=[]) => (await query(sql,params))[0];
async function rpc(name,args=[],user=owner){
 await db.exec('begin');
 try{
  await db.exec('set local role '+(user?'authenticated':'anon'));
  await query("select set_config('request.jwt.claim.sub',$1,true)",[user||'']);
  const {result}=await one('select public.'+name+'('+args.map((_,index)=>'$'+(index+1)).join(',')+') result',args);
  await db.exec('commit');
  return result;
 }catch(error){
  await db.exec('rollback');
  throw error;
 }
}

try{
 await db.exec(`
  create role anon; create role authenticated; create role service_role;
  create schema auth; create table auth.users(id uuid primary key,email text);
  create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
  create function auth.jwt() returns jsonb language sql stable as $$select '{}'::jsonb$$;
  grant usage on schema auth to anon,authenticated;
  create schema realtime; create function realtime.send(jsonb,text,text,boolean) returns void language sql as $$select$$;
  create function public.notice_test_clock() returns timestamptz language sql stable as $$select '2026-11-21T12:00:00+08:00'::timestamptz$$;
 `);
 const migrations=new URL('../supabase/migrations/',import.meta.url);
 for(const file of (await readdir(migrations)).sort()){
  await db.exec((await readFile(new URL(file,migrations),'utf8')).replaceAll('now()','public.notice_test_clock()'));
 }
 const {id:oldRule}=await one("select id from spa_payroll_rule_versions where status='active'");
 assert.equal((await one("select count(*)::int n from spa_payroll_rule_versions where calculation_engine='notice_v1'")).n,0);
 await query("insert into auth.users values($1,'owner@example.test'),($2,'employee@example.test')",[owner,employee]);
 await query("insert into spa_roles(user_id,role,active) values($1,'owner',true)",[owner]);
 await db.exec("update spa_staff set active=false,employment_status='inactive'");
 async function staff(name,code,employment,contract=null){
  return (await one(`insert into spa_staff(name,title,job_title_id,employment_type_code,hire_date,contract_started_on,active,employment_status,is_bookable)
   select $1,j.name,j.id,$3,'2026-01-01',$4,true,'active',true from spa_job_titles j where j.code=$2 returning id`,[name,code,employment,contract])).id;
 }
 const full=await staff('測試正職','ft_junior','full_time');
 const trial=await staff('測試試用','ft_probation','full_time');
 const monthly=await staff('測試月薪','pt_technician','part_time');
 const hourly=await staff('測試時薪','pt_technician','part_time');
 const contractor=await staff('測試承攬','contract_technician','contractor','2026-09-01');
 const sampleAssignments=[
  [full,{category:'01',rank_no:2}],[trial,{category:'01',rank_no:1}],
  [monthly,{category:'02',rank_no:6,start_bps:2500}],[hourly,{category:'03'}],
  [contractor,{category:'04',contract_from:'2026-09-01',credited_from:'2026-05-15'}],
 ];
 await query("insert into spa_roles(user_id,role,staff_id,active,login_name)values($1,'therapist',$2,true,'notice_test')",[employee,full]);
 await assert.rejects(()=>rpc('spa_payroll_notice_setup',[month[0]],employee),/FORBIDDEN/);
 await assert.rejects(()=>rpc('spa_payroll_notice_setup',['2026-11-02']),/PAYROLL_FULL_MONTH_REQUIRED/);
 // Exercise a first release on today's Taipei date with an otherwise empty
 // month, including the normal full-month payroll query and locking route.
 await db.exec('begin');
 try{
  await query("select set_config('request.jwt.claim.sub',$1,true)",[owner]);
  const quick=await one("select spa_payroll_notice_setup('2026-11-21') id");
  for(const [person,assignment] of sampleAssignments)await query('select spa_payroll_notice_assign($1,$2,$3)',[quick.id,person,assignment]);
  await query('select spa_payroll_notice_activate($1)',[quick.id]);
  assert.equal((await one("select spa_private.payroll_notice_rule_on('2026-11-20') id")).id,oldRule);
  assert.equal((await one("select spa_private.payroll_notice_rule_on('2026-11-21') id")).id,quick.id);
  assert.equal((await one('select spa_payroll_preview($1,$2,$3) wage',[...month,quick.id])).wage.find(row=>row.staff_id===full).base_cents,3100000);
  assert.ok((await one('select spa_payroll_run_save($1,$2,$3,true) id',[...month,quick.id])).id);
 }finally{await db.exec('rollback');}
 const rule=await rpc('spa_payroll_notice_setup',[month[0]]);
 const settings=await rpc('spa_payroll_notice_get',[rule]);
 assert.deepEqual(settings.ranks.map(row=>row.monthly_base_cents),Array(6).fill(2520000));
 assert.equal(settings.technician_ids.includes(hourly),true);
 await assert.rejects(()=>rpc('spa_payroll_rule_activate',[rule]),/PAYROLL_NOTICE_NOT_ACTIVE/);
 await assert.rejects(()=>rpc('spa_payroll_notice_activate',[rule]),/PAYROLL_CLASSIFICATION_REQUIRED/);
 await assert.rejects(()=>rpc('spa_payroll_notice_assign',[rule,monthly,{category:'02',rank_no:6,start_bps:3000}]),/check constraint/);
 await rpc('spa_payroll_notice_save',[rule,settings,settings.ranks]);
 for(const [person,assignment] of sampleAssignments)await rpc('spa_payroll_notice_assign',[rule,person,assignment]);
 await assert.rejects(()=>rpc('spa_payroll_run_save',[...month,rule,true]),/PAYROLL_NOTICE_NOT_ACTIVE/);
 await rpc('spa_payroll_notice_activate',[rule]);
 assert.equal((await one("select spa_private.payroll_notice_rule_on('2026-10-20') id")).id,oldRule);
 assert.equal((await one("select spa_private.payroll_notice_rule_on('2026-11-20') id")).id,rule);
 const wage=async(person,period=month,id=rule)=>(await rpc('spa_payroll_preview',[...period,id])).find(row=>row.staff_id===person);

 async function service(minutes,price){
  const {id}=await one(`insert into spa_services(code,name,duration_minutes,buffer_minutes,price_cents,category_id,active,status,online_booking_enabled)
   values($1,'薪資測試服務',$2,0,$3,(select id from spa_service_categories where code='addons'),true,'active',false) returning id`,['t_'+randomUUID().slice(0,8),minutes,price]);
  for(const person of [full,trial,monthly,hourly,contractor])await query('insert into spa_staff_services values($1,$2,true)',[person,id]);
  return id;
 }
 const regular=await service(60,100000),crossing=await service(120,200000);
 async function sale(person,item,quantity,date,{kind='service',designated=false,self=false,discount=0}={}){
  const order=await rpc('spa_pos_checkout_with_coupon',[randomUUID(),null,[{item_type:kind,item_id:item,quantity,staff_id:person,designated_client:designated,self_sourced_client:self}],discount,'cash','合成薪資測試',null,null]);
  await query('update spa_orders set paid_at=$2 where id=$1',[order.id,date+'T10:00:00+08:00']);
  return one('select id,commission_cents,net_total_cents from spa_order_items where order_id=$1',[order.id]);
 }
 await sale(full,regular,69,'2026-11-01');
 const boundary=await sale(full,crossing,1,'2026-11-02',{designated:true,discount:20000});
 let result=await wage(full);
 assert.equal(result.base_cents,3100000);
 assert.equal(result.service_minutes,4260);
 assert.equal(result.service_commission_cents,4500);
 assert.equal(result.designated_bonus_cents,9000);
 const details=await rpc('spa_payroll_sources',[full,...month,rule]);
 assert.equal(details.reconciliation.source_matches,true,JSON.stringify(details.reconciliation));
 assert.equal(details.reconciliation.formula_matches,true);
 assert.deepEqual(details.sources.commission_details.find(row=>row.source_id===boundary.id).commission_segments.map(row=>row.net_cents),[90000,90000]);
 await rpc('spa_payroll_notice_minutes_save',['pos_service',boundary.id,60]);
 assert.equal((await wage(full)).service_commission_cents,0);
 assert.equal((await rpc('spa_payroll_sources',[full,...month,rule])).reconciliation.source_matches,true);
 await rpc('spa_payroll_notice_minutes_save',['pos_service',boundary.id,null]);

 await sale(trial,regular,85,'2026-11-01');
 await sale(trial,regular,1,'2026-11-02',{designated:true});
 assert.equal((await wage(trial)).service_commission_cents,0);
 assert.equal((await wage(trial)).designated_bonus_cents,5000);
 assert.equal((await wage(trial)).ordinary_qualified_minutes,0);
 await assert.rejects(()=>rpc('spa_payroll_notice_pass',[rule,trial,'2026-11-21',2],employee),/FORBIDDEN/);
 await rpc('spa_payroll_notice_pass',[rule,trial,'2026-11-21',2]);
 await sale(trial,regular,1,'2026-11-21');
 assert.equal((await wage(trial)).ordinary_qualified_minutes,60);
 assert.equal((await wage(trial)).service_commission_cents,0,'trial minutes cannot qualify post-probation services');
 await sale(monthly,regular,66,'2026-11-03');
 assert.equal((await wage(monthly)).base_cents,2520000);
 assert.equal((await wage(monthly)).service_commission_cents,25000);
 await sale(hourly,regular,41,'2026-11-04');
 await rpc('spa_time_entry_save',[null,hourly,'2026-11-04','2026-11-04T10:00:00+08:00','2026-11-04T18:00:00+08:00',60,'測試出勤']);
 result=await wage(hourly);
 assert.equal(result.base_cents,143500);
 assert.equal(result.service_commission_cents,5000);
 assert.equal(result.work_minutes,420);

 await sale(contractor,regular,1,'2026-11-14');
 await sale(contractor,regular,1,'2026-11-15',{self:true});
 result=await wage(contractor);
 assert.equal(result.base_cents,0);
 assert.equal(result.service_commission_cents,70000);
 assert.equal(result.designated_bonus_cents,5000);
 const product=await one("select id from spa_products where status='active' order by display_order limit 1");
 await query("insert into spa_inventory_entries(product_id,delta,reason,reference_type,created_by) values($1,20,'測試庫存','adjustment',$2)",[product.id,owner]);
 const soldProduct=await sale(contractor,product.id,1,'2026-11-16',{kind:'product'});
 const productBonus=Math.round(Number(soldProduct.net_total_cents)*0.05);
 assert.equal(Number(soldProduct.commission_cents),productBonus);
 assert.equal((await wage(contractor)).product_commission_cents,productBonus);
 await rpc('spa_payroll_notice_return',[randomUUID(),'product',soldProduct.id,'2026-11-18',soldProduct.net_total_cents,'試算商品退回']);
 assert.equal((await wage(contractor)).product_commission_cents,0);
 const employeeProduct=await sale(full,product.id,1,'2026-11-16',{kind:'product'});
 assert.equal(Number(employeeProduct.commission_cents),Math.round(Number(employeeProduct.net_total_cents)*0.05));

 const customer=(await one("insert into spa_customers(name,phone) values('測試會員','0912345678') returning id")).id;
 const packageRequest=randomUUID();
 const packageArgs=[packageRequest,customer,regular,'測試七堂券',7,1000000,'2027-11-30T23:59:59+08:00','cash'];
 await assert.rejects(()=>rpc('spa_package_sell',packageArgs),/PAYROLL_PACKAGE_SELLER_REQUIRED/);
 await rpc('spa_package_sell_v2',[...packageArgs,trial]);
 await rpc('spa_package_sell_v2',[...packageArgs,trial]);
 await assert.rejects(()=>rpc('spa_package_sell_v2',[...packageArgs,full]),/REQUEST_CONFLICT/);
 const pkg=await one('select id,payroll_sale_bonus_cents from spa_packages where request_id=$1',[packageRequest]);
 assert.equal(Number(pkg.payroll_sale_bonus_cents),50000);
 assert.equal((await wage(trial)).package_bonus_cents,50000);
 const booking=await one(`insert into spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,service_name_snapshot,duration_minutes_snapshot,price_cents,booking_preference)
  values($1,$2,$3,(select id from spa_rooms order by name limit 1),$4,'2026-11-21','2026-11-21T09:00:00+08:00','2026-11-21T10:00:00+08:00','2026-11-21T10:00:00+08:00',
   'completed','測試包堂','測試包堂',60,100000,'designated') returning id`,[randomUUID(),customer,full,regular]);
 await rpc('spa_checkout_with_coupon',[randomUUID(),booking.id,0,0,pkg.id,0,'cash',null]);
 const withPackage=await rpc('spa_payroll_sources',[full,...month,rule]);
 const redemption=withPackage.sources.commission_details.find(line=>line.source_id===booking.id);
 assert.equal(redemption.net_cents,135714);
 assert.equal(redemption.package_sale_bonus_cents,50000);
 assert.equal(withPackage.reconciliation.source_matches,true);
 await rpc('spa_payroll_notice_return',[randomUUID(),'package',pkg.id,'2026-11-21',200000,'試算部分退券']);
 assert.equal((await wage(trial)).package_bonus_cents,50000);
 assert.equal((await wage(trial,nextMonth)).package_bonus_cents,-10000);
 assert.equal((await rpc('spa_payroll_sources',[trial,...month,rule])).reconciliation.source_matches,true);
 await assert.rejects(()=>rpc('spa_payroll_notice_return',[randomUUID(),'package',pkg.id,'2026-11-21',900000,'試算超額退券']),/INVALID_INPUT/);
 await assert.rejects(()=>rpc('spa_payroll_sources',[trial,...month,null],employee),/FORBIDDEN/);
 await assert.rejects(()=>rpc('spa_payroll_run_save',['2026-11-02',month[1],rule,true]),/PAYROLL_FULL_MONTH_REQUIRED/);
 await assert.rejects(()=>rpc('spa_payroll_run_save',[...month,oldRule,true]),/PAYROLL_NOTICE_NOT_ACTIVE/);
 const locked=await rpc('spa_payroll_run_save',[...month,rule,true]);
 assert.equal((await one('select status from spa_payroll_runs where id=$1',[locked])).status,'finalized');
 assert.equal((await rpc('spa_payroll_sources',[full,...month,null],employee)).evidence_mode,'snapshot');
 assert.equal((await rpc('spa_staff_self',[...month],employee)).payroll.notice_category,'01');
 await assert.rejects(()=>rpc('spa_payroll_notice_minutes_save',['pos_service',boundary.id,120]),/PAYROLL_LOCKED/);
 await query("update spa_staff set active=false,employment_status='departed',departed_on='2026-11-21',departure_reason='測試離職',is_bookable=false where id=$1",[trial]);
 const departedReturn=await wage(trial,nextMonth);
 assert.equal(departedReturn.package_bonus_cents,-10000);
 assert.equal(departedReturn.base_cents,0);
 assert.equal(departedReturn.total_cents,0);
 assert.match(departedReturn.commission_warning,/不足扣回/);

 const revision=await rpc('spa_payroll_notice_setup',[nextMonth[0]]);
 const carried=await rpc('spa_payroll_notice_get',[revision]);
 assert.equal(carried.assignments.find(row=>row.staff_id===monthly).start_bps,2500);
 assert.equal(carried.assignments.find(row=>row.staff_id===trial).rank_no,2);
 console.log('Payroll notice checks passed for the four categories, dated sources, refunds, access and settlement.');
}finally{
 await db.close();
}
