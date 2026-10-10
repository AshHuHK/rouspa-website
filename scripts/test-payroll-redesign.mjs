import { PGlite } from '@electric-sql/pglite';
import { readFile, readdir } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';

const db = new PGlite();
let checks = 0;
const check = (value, label) => { assert.ok(value, label); checks++; };
const equal = (actual, expected, label) => { assert.equal(actual, expected, label); checks++; };
const reject = async (work, pattern) => { await assert.rejects(work, pattern); checks++; };
try {
 await db.exec(`create role anon;create role authenticated;create role service_role;
 create schema realtime;create table realtime.sent(payload jsonb,event text,topic text,private boolean);
 create function realtime.send(payload jsonb,event text,topic text,private boolean)returns void language sql as $$insert into realtime.sent values(payload,event,topic,private)$$;
 create schema auth;create table auth.users(id uuid primary key,email text);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
 grant usage on schema auth to anon,authenticated;grant execute on function auth.uid(),auth.jwt() to anon,authenticated;
 create function public.redesign_test_now() returns timestamptz language sql stable as $$select '2026-10-15T10:00:00+08:00'::timestamptz$$;`);
 const directory = new URL('../supabase/migrations/', import.meta.url);
 for (const file of (await readdir(directory)).sort()) await db.exec((await readFile(new URL(file, directory), 'utf8')).replaceAll('now()', 'public.redesign_test_now()'));
 const owner = randomUUID(), employee = randomUUID(), counterUser = randomUUID();
 await db.query('insert into auth.users(id,email) values($1,$2),($3,$4),($5,$6)', [owner,'owner@redesign.test',employee,'tech@redesign.test',counterUser,'counter@redesign.test']);
 await db.query("insert into spa_roles(user_id,role,active)values($1,'owner',true)", [owner]);
 async function call(user, name, args = []) {
  await db.exec('begin');
  try {
   await db.exec('set local role '+(user ? 'authenticated' : 'anon'));
   await db.query("select set_config('request.jwt.claim.sub',$1,true),set_config('request.jwt.claims',$2,true)", [user || '', JSON.stringify({iat: Math.floor(Date.now()/1000)})]);
   const rows = await db.query(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')}) result`, args);
   await db.exec('commit'); return rows.rows[0]?.result;
  } catch (error) { await db.exec('rollback'); throw error; }
 }
 const admin = (name,args=[]) => call(owner,name,args);
 const titles = (await db.query('select * from spa_job_titles')).rows;
 const title = code => titles.find(row=>row.code===code);
 const range = ['2026-10-01','2026-10-31'];
 const rules = (await db.query('select * from spa_payroll_rule_versions order by version_no desc')).rows;
 const rule = rules[0].id;
 equal(rules[0].calculation_engine,'ordered_v2','new policy uses ordered engine');
 equal(rules.filter(row=>row.status==='active').length,1,'exactly one active version is retained');
 check(rules.slice(1).every(row=>row.calculation_engine==='legacy_period_average'),'old versions retain old calculation engine');
 equal(titles.filter(row=>!row.legacy&&row.code.startsWith('ft_')).length,7,'only the seven confirmed ranks are initialized');
 equal(title('owner').allowed_employment_types.join(','),'owner','owner has no employee employment-type split');
 equal(title('reception').allowed_employment_types.join(','),'full_time,part_time','counter cannot be a contractor');
 const profile = async (code, employment = title(code).allowed_employment_types[0], id = rule) => (await db.query('select * from spa_payroll_version_profiles where rule_version_id=$1 and job_title_id=$2 and employment_type_code=$3',[id,title(code).id,employment])).rows[0];
 for (const [code,start] of [['ft_probation',0],['ft_junior',500],['ft_senior_junior',1000],['ft_mid',1500],['ft_senior_mid',2000],['ft_advanced',2500],['ft_senior_advanced',3000]]) {
  const p=await profile(code);
  equal(Number(p.base_pay_cents),3000000,code+' uses document base salary in cents');
  equal(p.service_commission_bps,start,code+' starts at documented rate');
  equal(p.product_commission_bps,1000,code+' has 10% default product commission');
  const tiers=(await db.query('select * from spa_payroll_commission_tiers where rule_version_id=$1 and job_title_id=$2 order by threshold_from',[rule,title(code).id])).rows;
  equal(tiers[0].threshold_from,0,code+' explicitly covers unpaid initial hours');
  equal(tiers[0].threshold_to,3900,code+' covers first 65 service hours in salary');
  equal(tiers[1].rate_bps,start,code+' first earned band matches rank');
  check(tiers.every(tier=>tier.rate_bps<=3500),'ordinary commission stays within documented cap');
  if(code==='ft_probation')check(tiers.every(tier=>tier.rate_bps===0),'probation has zero ordinary commission at every band');
 }
 const partProfile=await profile('pt_technician'),contractProfile=await profile('contract_technician');
 equal(Number(partProfile.base_pay_cents),22000,'part-time hourly pay is 220 NTD');
 equal(partProfile.minimum_attendance_minutes,2400,'part-time qualification uses 40 approved attendance hours');
 equal(partProfile.commission_start_service_minutes,2400,'part-time service commission starts after 40 service hours');
 equal(contractProfile.contractor_count_scope,'lifetime','contractor count carries across calendar months');
 equal(contractProfile.self_sourced_commission_bps,5000,'explicit self-sourced contractor rate is 50%');
 equal(contractProfile.service_policy_status,'confirmed','all ambiguous document rules use human-confirmed choices');

 const initial = await admin('spa_payroll_preview',[...range,rule]);
 check(initial.some(row=>row.classification_pending),'existing legacy technicians require explicit rank mapping');
 await reject(()=>admin('spa_payroll_run_save',[...range,rule,true]),/PAYROLL_CLASSIFICATION_REQUIRED/);
 await reject(()=>call(employee,'spa_compensation_profile_save_v3',[rule,partProfile]),/FORBIDDEN|TEAM/);
 await reject(()=>admin('spa_compensation_profile_save_v2',[title('therapist').id,'full_time','monthly',3000000,1000,1000,500,0,0,true]),/PAYROLL_VERSION_PROFILE_REQUIRED/);
 await reject(()=>admin('spa_compensation_profile_save_v3',[rule,{...partProfile,job_title_id:title('reception').id,employment_type_code:'contractor'}]),/JOB_EMPLOYMENT_MISMATCH/);
 await reject(()=>admin('spa_compensation_profile_save_v3',[rule,{...contractProfile,base_pay_cents:1}]),/CONTRACTOR_BASE_NOT_ALLOWED/);
 await reject(async()=>admin('spa_compensation_profile_save_v3',[rule,{...await profile('reception','full_time'),service_commission_bps:1000,service_commission_mode:'flat'}]),/SERVICE_COMMISSION_TECHNICIAN_ONLY/);
 await reject(()=>db.query("insert into spa_staff(name,job_title_id,employment_type_code)values('錯誤組合',$1,'part_time')",[title('ft_junior').id]),/JOB_EMPLOYMENT_MISMATCH/);
 await reject(()=>db.query("insert into spa_staff(name,job_title_id,employment_type_code)values('未指定新職級',$1,'full_time')",[title('therapist').id]),/JOB_CLASSIFICATION_REQUIRED/);
 await db.exec("update spa_staff set active=false,employment_status='inactive';");
 async function addStaff(code,name, employment=title(code).allowed_employment_types[0]) {
  return (await db.query("insert into spa_staff(name,title,job_title_id,employment_type_code,hire_date,contract_started_on,active,employment_status,is_bookable)values($1,$2,$3,$4,'2026-01-01',$5,true,'active',true)returning id",[name,title(code).name,title(code).id,employment,employment==='contractor'?'2026-01-01':null])).rows[0].id;
 }
 const junior=await addStaff('ft_junior','測試初級'),trial=await addStaff('ft_probation','測試試用'),part=await addStaff('pt_technician','測試兼職'),futurePart=await addStaff('pt_technician','測試未達出勤'),contractor=await addStaff('contract_technician','測試承攬'),counter=await addStaff('reception','測試櫃台'),ownerStaff=await addStaff('owner','測試店主');
 await db.query("insert into spa_roles(user_id,role,staff_id,active,login_name)values($1,'therapist',$2,true,'redesign_tech'),($3,'therapist',$4,true,'redesign_counter')",[employee,junior,counterUser,counter]);
 await admin('spa_compensation_profile_save_v3',[rule,{...await profile('reception','full_time'),base_pay_cents:3200000,active:true}]);
 async function service(minutes,price) {
  const id=(await db.query("insert into spa_services(code,name,duration_minutes,buffer_minutes,price_cents,category_id,active,status,online_booking_enabled)values($1,$2,$3,0,$4,(select id from spa_service_categories where code='addons'),true,'active',false)returning id",['t_'+randomUUID().replaceAll('-','').slice(0,12),'測試服務',minutes,price])).rows[0].id;
  for(const staff of [junior,trial,part,futurePart,contractor,counter,ownerStaff])await db.query('insert into spa_staff_services(staff_id,service_id,enabled)values($1,$2,true)',[staff,id]);
  return id;
 }
 const inexpensive=await service(60,10000),crossing=await service(120,1000000),normal=await service(60,100000);
 const product=(await db.query("select * from spa_products where status='active' order by display_order limit 1")).rows[0];
 await db.query("insert into spa_inventory_entries(product_id,delta,reason,reference_type,created_by)values($1,1000,'測試庫存','adjustment',$2)",[product.id,owner]);
 async function sell(staff,itemId,quantity,date,{kind='service',designated=false,self=false,discount=0}={}) {
  const request=randomUUID();
  const result=await admin('spa_pos_checkout_with_coupon',[request,null,[{item_type:kind,item_id:itemId,quantity,staff_id:staff,designated_client:designated,self_sourced_client:self}],discount,'cash','本機合成測試',null,null]);
  await db.query('update spa_orders set paid_at=$2 where id=$1',[result.id,date+'T10:00:00+08:00']);
  return result;
 }
 const wage=async(staff,period=range,id=rule)=>(await admin('spa_payroll_preview',[...period,id])).find(row=>row.staff_id===staff);
 await reject(()=>admin('spa_pos_checkout',[randomUUID(),null,[{item_type:'product',item_id:product.id,quantity:1,staff_id:null}],0,'cash','']),/SALE_STAFF_REQUIRED/);
 await reject(()=>sell(counter,normal,1,'2026-10-15'),/SERVICE_COMMISSION_TECHNICIAN_ONLY/);
 await reject(()=>sell(ownerStaff,normal,1,'2026-10-15'),/SERVICE_COMMISSION_TECHNICIAN_ONLY/);
 await reject(()=>sell(junior,normal,100,'2026-10-15'),/INVALID_ITEM/);
 await reject(()=>sell(junior,normal,1,'2026-10-15',{self:true}),/SELF_SOURCED_CONTRACTOR_ONLY/);
 await db.query('update spa_product_categories set active=false where id=$1',[product.category_id]);
 await reject(()=>sell(counter,product.id,1,'2026-10-15',{kind:'product'}),/PRODUCT_CATEGORY_UNAVAILABLE/);
 await db.query('update spa_product_categories set active=true where id=$1',[product.category_id]);

 await sell(junior,inexpensive,64,'2026-10-01');
 const crossingSale=await sell(junior,crossing,1,'2026-10-16',{designated:true});
 let row=await wage(junior);
 equal(Number(row.service_minutes),3960,'settled sales contribute precisely 66 hours');
 equal(Number(row.service_commission_cents),25000,'high-value crossing course earns only its half after 65 hours, not a period-average revenue allocation');
 equal(Number(row.designated_bonus_cents),50000,'designated +5% applies only to the explicitly designated course');
 equal(Number(row.base_cents),3000000,'full-time base salary follows rank profile');
 const packet=await admin('spa_payroll_sources',[junior,...range,rule]);
 check(packet.reconciliation.source_matches&&packet.reconciliation.formula_matches,'source commissions and payroll formula reconcile: '+JSON.stringify(packet.reconciliation));
 const crossingLine=(await db.query('select id from spa_order_items where order_id=$1',[crossingSale.id])).rows[0].id;
 const detail=packet.sources.commission_details.find(item=>item.source_id===crossingLine);
 equal(detail.commission_segments.length,2,'a course crossing 65 hours retains both explicit calculation bands');
 equal(detail.commission_segments[0].net_cents,500000,'first half of crossing course retains its revenue share');
 equal(detail.commission_segments[1].commission_cents,25000,'second half cites its exact band commission');
 equal(detail.metric_from,3840,'chronological cumulative minutes cite retained prior service count');
 const juniorProfile={...await profile('ft_junior')};
 await admin('spa_compensation_profile_save_v3',[rule,{...juniorProfile,service_commission_mode:'flat'}]);
 equal(Number((await wage(junior)).service_commission_cents),25000,'fixed-rate mode still excludes the first 65 hours and splits a high-value crossing course');
 const flatPacket=await admin('spa_payroll_sources',[junior,...range,rule]);
 check(flatPacket.sources.commission_details.find(item=>item.source_id===crossingLine).commission_segments.some(segment=>segment.basis==='flat_salary_covered'&&segment.commission_cents===0),'fixed-rate source records the zero-rate salary-covered portion');
 await admin('spa_compensation_profile_save_v3',[rule,juniorProfile]);
 await sell(trial,inexpensive,70,'2026-10-16');
 equal(Number((await wage(trial)).service_commission_cents),0,'probation does not accidentally gain later ordinary percentages');
 await db.query('update spa_services set duration_minutes=60,price_cents=123 where id=$1',[crossing]);
 equal(Number((await wage(junior)).service_commission_cents),25000,'catalogue changes do not rewrite sold duration or paid net revenue');

 async function attendance(staff,firstDay) {
  for(let offset=0;offset<5;offset++) {
   const day=String(firstDay+offset).padStart(2,'0'), date='2026-10-'+day;
   await admin('spa_time_entry_save',[null,staff,date,date+'T10:00:00+08:00',date+'T18:00:00+08:00',0,'測試核准出勤']);
  }
 }
 await sell(part,inexpensive,40,'2026-10-01',{designated:true});
 await attendance(part,1);
 const exactlyForty=await wage(part);
 check(!exactlyForty.commission_eligibility_met&&Number(exactlyForty.service_commission_cents)===0&&Number(exactlyForty.designated_bonus_cents)===0,'exactly 40 service hours cannot earn ordinary or designated commission');
 const minuteBoundary=await sell(part,normal,1,'2026-10-16');
 await db.query('update spa_order_items set duration_minutes_snapshot=1 where order_id=$1',[minuteBoundary.id]);
 const oneMinuteOver=await wage(part);
 check(oneMinuteOver.commission_eligibility_met&&Number(oneMinuteOver.service_minutes)===2401&&Number(oneMinuteOver.service_commission_cents)===5000,'an independently retained one-minute completion fact above 40 hours unlocks the next eligible service revenue');
 await db.query('update spa_order_items set duration_minutes_snapshot=60 where order_id=$1',[minuteBoundary.id]);
 row=await wage(part);
 equal(Number(row.base_cents),880000,'40 approved attendance hours produce 220 NTD per hour');
 equal(Number(row.service_commission_cents),5000,'41st service hour earns 5% after confirmed attendance qualification');
 const partial=await wage(part,['2026-10-15','2026-10-31']);
 equal(Number(partial.work_minutes),0,'selected-range attendance remains an honest range metric');
 equal(Number(partial.monthly_eligibility_work_minutes),2400,'qualification separately cites month-to-date attendance outside selected range');
 check(partial.commission_eligibility_met&&Number(partial.service_commission_cents)===5000&&!partial.commission_warning,'partial preview uses the same qualification source as actual commission');
 await sell(futurePart,inexpensive,40,'2026-10-01');await sell(futurePart,normal,1,'2026-10-16');await attendance(futurePart,20);
 const cutoff=await wage(futurePart,['2026-10-01','2026-10-16']);
 equal(Number(cutoff.service_commission_cents),0,'attendance after the preview cutoff cannot prematurely unlock commission');
 check(!cutoff.commission_eligibility_met,'qualification warning agrees with zero commission before cutoff');
 await reject(()=>admin('spa_payroll_run_save',['2026-10-15','2026-10-31',rule,true]),/PAYROLL_FULL_MONTH_REQUIRED/);

 await sell(contractor,inexpensive,99,'2026-09-01');await sell(contractor,inexpensive,1,'2026-09-02');
 await sell(contractor,normal,1,'2026-10-01');await sell(contractor,normal,1,'2026-10-02',{self:true});
 row=await wage(contractor);
 equal(Number(row.base_cents),0,'contractors have no fixed salary or hourly base');
 equal(Number(row.service_commission_cents),90000,'101st lifetime service earns 40%; explicit self-sourced service earns 50% independently');
 const contractPacket=await admin('spa_payroll_sources',[contractor,...range,rule]);
 equal(contractPacket.sources.commission_details[0].metric_from,100,'lifetime tier retains previous-month settled services');
 equal(contractPacket.sources.commission_details[1].commission_segments[0].basis,'self_sourced','self-sourced rate is saved as a replacement, not a stacked ordinary commission');
 equal(contractPacket.sources.commission_context.prior_service_count,100,'contractor lifetime count has an auditable prior-service snapshot');
 equal(contractPacket.sources.commission_context.prior_service_references.reduce((sum,item)=>sum+item.quantity,0),100,'every prior lifetime course can be traced to settled appointment/item references');
 equal(contractPacket.rule_reference.profile.contract_started_on,'2026-01-01','cooperation start is retained with the source rule snapshot');
 await db.query('update spa_staff set contract_started_on=null where id=$1',[contractor]);
 const unknownCooperation=await wage(contractor);
 check(unknownCooperation.contract_start_pending&&!unknownCooperation.commission_policy_ready&&Number(unknownCooperation.service_commission_cents)===0,'missing cooperation date never silently counts full-time employment history');
 await reject(()=>admin('spa_payroll_run_save',[...range,rule,true]),/CONTRACT_COOPERATION_DATE_REQUIRED/);
 await db.query("update spa_staff set contract_started_on='2026-01-01' where id=$1",[contractor]);
 await reject(()=>db.query("update spa_staff set contract_started_on='2025-12-31' where id=$1",[contractor]),/INVALID_CONTRACT_COOPERATION_DATE/);
 const refundedHistory=await sell(contractor,inexpensive,1,'2026-08-01');
 await db.query("update spa_orders set status='refunded' where id=$1",[refundedHistory.id]);
 equal((await admin('spa_payroll_sources',[contractor,...range,rule])).sources.commission_details[0].metric_from,100,'refunded historical service does not advance lifetime contractor count');

 const secondContractor=await addStaff('contract_technician','測試承攬改派');
 await db.query('insert into spa_staff_services(staff_id,service_id,enabled)values($1,$2,true)',[secondContractor,normal]);
 const customer=await admin('spa_customer_save',[null,'合成指定測試','0988333444','','一般會員','',null]);
 const appointment=(await db.query(`insert into spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,service_name_snapshot,duration_minutes_snapshot,price_cents,booking_preference)
 values($1,$2,$3,(select id from spa_rooms where active order by name limit 1),$4,'2026-10-18','2026-10-18T10:00:00+08:00','2026-10-18T11:00:00+08:00','2026-10-18T11:00:00+08:00','completed','合成療程','合成療程',60,100000,'designated')returning id`,[randomUUID(),customer,contractor,normal])).rows[0].id;
 await reject(()=>call(employee,'spa_appointment_commission_flags',[appointment,true,'非店主不能認定']),/FORBIDDEN/);
 await admin('spa_appointment_commission_flags',[appointment,true,'確認此堂由原承攬者自帶']);
 check((await admin('spa_admin_bookings',range)).find(row=>row.id===appointment).self_sourced_client,'owner appointment list exposes the confirmed self-sourced flag');
 await admin('spa_checkout',[randomUUID(),appointment,0,0,null,0,'cash']);
 check((await admin('spa_payroll_sources',[contractor,...range,rule])).sources.services.find(row=>row.id===appointment).self_sourced_client,'appointment source uses retained self-sourced settlement snapshot');
 await reject(()=>admin('spa_appointment_reassign',[appointment,counter,'錯誤指定櫃台']),/SERVICE_COMMISSION_TECHNICIAN_ONLY/);
 const reassigned=await admin('spa_appointment_reassign',[appointment,secondContractor,'改由另一位實際服務']);
 check(reassigned.self_sourced_cleared,'actual-person reassignment clears prior-person self-sourced qualification');
 equal(Number((await wage(secondContractor)).service_commission_cents),30000,'new actual contractor receives ordinary first-service rate until separately confirmed');
 equal(Number((await wage(contractor)).service_commission_cents),90000,'original contractor no longer receives reassigned service wages');
 check(!(await db.query('select self_sourced_client_snapshot from spa_checkouts where appointment_id=$1',[appointment])).rows[0].self_sourced_client_snapshot,'reassignment clears both appointment and settlement snapshot atomically');
 await admin('spa_appointment_commission_flags',[appointment,true,'另行核對認定為新實際技師自帶客']);
 equal(Number((await wage(secondContractor)).service_commission_cents),50000,'owner can explicitly re-confirm the new actual contractor self-sourced arrangement');
 await admin('spa_refund',[randomUUID(),appointment,'測試全額退回']);
 equal(Number((await wage(secondContractor)).service_commission_cents),0,'refunded appointment contributes no contractor commission');
 equal((await admin('spa_payroll_sources',[secondContractor,...range,rule])).sources.commission_details.length,0,'refunded course leaves source history but not payable calculation details');

 const converted=await addStaff('ft_probation','測試正職轉承攬');
 await db.query('insert into spa_staff_services(staff_id,service_id,enabled)values($1,$2,true)',[converted,inexpensive]);
 await sell(converted,inexpensive,99,'2026-09-01');
 await admin('spa_staff_profile_save_v2',[{id:converted,name:'測試正職轉承攬',job_title_id:title('contract_technician').id,employment_type_code:'contractor',employment_status:'active',hire_date:'2026-01-01',contract_started_on:'2026-10-01',is_bookable:true,website_visible:false,services:[normal,inexpensive]}]);
 await sell(converted,normal,2,'2026-10-19');
 const convertedWage=await wage(converted);
 equal(Number(convertedWage.service_commission_cents),60000,'99 prior full-time services do not advance the first 100 contractor-cooperation courses');
 const convertedPacket=await admin('spa_payroll_sources',[converted,...range,rule]);
 equal(convertedPacket.sources.commission_details[0].metric_from,0,'lifetime contractor metric begins at the separately confirmed cooperation start');
 equal(convertedPacket.sources.commission_context.prior_service_count,0,'prior full-time records are excluded from auditable contractor count');
 check((await admin('spa_team_os')).staff.find(person=>person.id===converted).contract_started_on==='2026-10-01','owner personnel projection exposes the confirmed cooperation date');
 await admin('spa_staff_profile_save_v2',[{id:converted,name:'測試正職轉承攬',job_title_id:title('contract_technician').id,employment_type_code:'contractor',employment_status:'active',hire_date:'2026-01-01',is_bookable:true,website_visible:false,services:[normal,inexpensive]}]);
 equal((await db.query('select contract_started_on::text contract_started_on from spa_staff where id=$1',[converted])).rows[0].contract_started_on,'2026-10-01','legacy personnel callers omitting cooperation date preserve its confirmed value');

 await db.query('update spa_staff set is_bookable=true where id=$1',[counter]);
 check(!(await db.query('select is_bookable from spa_staff where id=$1',[counter])).rows[0].is_bookable,'crafted updates cannot make a counter bookable despite retained historical skill rows');

 const sale=await sell(counter,product.id,2,'2026-10-16',{kind:'product',discount:12345});
 const sold=(await db.query('select * from spa_order_items where order_id=$1',[sale.id])).rows[0];
 equal(sold.commission_bps_snapshot,1000,'counter with technician login permissions still receives its product rate by job function');
 equal(Number(sold.commission_cents),Math.round(Number(sold.net_total_cents)*0.1),'discounted product net amount determines actual item commission');
 equal(Number((await wage(counter)).product_commission_cents),Number(sold.commission_cents),'counter product sale is credited only to its actual named seller');
 equal(Number((await wage(junior)).product_commission_cents),0,'cashier/technician other than specified seller gains no product credit');
 const sellerPacket=await admin('spa_payroll_sources',[counter,...range,rule]);
 equal(sellerPacket.sources.products[0].commission_bps_snapshot,1000,'product source exposes retained sale percentage');
 equal(Number(sellerPacket.source_totals.product_commission_cents),Number(sold.commission_cents),'product source amount reconciles exactly to payroll');
 await admin('spa_compensation_profile_save_v3',[rule,{...await profile('reception','full_time'),product_commission_bps:2000}]);
 equal(Number((await wage(counter)).product_commission_cents),Number(sold.commission_cents),'rate edits affect future sales and preserve already sold product wages');
 const sale2=await sell(counter,product.id,1,'2026-10-17',{kind:'product'});
 equal((await db.query('select commission_bps_snapshot from spa_order_items where order_id=$1',[sale2.id])).rows[0].commission_bps_snapshot,2000,'next sale records owner edited product rate');
 const mixedRequest=randomUUID();
 const mixedItems=[{item_type:'service',item_id:normal,quantity:1,staff_id:secondContractor,designated_client:false,self_sourced_client:false},{item_type:'product',item_id:product.id,quantity:1,staff_id:ownerStaff},{item_type:'product',item_id:product.id,quantity:1,staff_id:counter}];
 const counterBeforeMixed=Number((await wage(counter)).product_commission_cents);
 const mixed=await admin('spa_pos_checkout_with_coupon',[mixedRequest,null,mixedItems,11111,'cash','多人分項歸屬測試',null,null]);
 const retry=await admin('spa_pos_checkout_with_coupon',[mixedRequest,null,mixedItems,11111,'cash','多人分項歸屬測試',null,null]);
 equal(retry.id,mixed.id,'retrying the same POS request cannot duplicate commission-generating sales');
 const mixedLines=(await db.query('select * from spa_order_items where order_id=$1 order by item_type,staff_id',[mixed.id])).rows;
 equal(mixedLines.length,3,'mixed service/product checkout retains three independently assigned lines');
 equal(mixedLines.filter(line=>line.item_type==='service')[0].staff_id,secondContractor,'mixed POS service is attributed only to its specified actual technician');
 for (const line of mixedLines.filter(line=>line.item_type==='product'))equal(line.commission_bps_snapshot,line.staff_id===counter?2000:1000,'each mixed product uses its own specified seller rate');
 equal(Number((await wage(secondContractor)).service_commission_cents),Math.round(Number(mixedLines.find(line=>line.item_type==='service').net_total_cents)*0.3),'mixed discount allocates service net revenue before the actual contractor percentage');
 equal(Number((await wage(ownerStaff)).product_commission_cents),Number(mixedLines.find(line=>line.staff_id===ownerStaff).commission_cents),'owner seller receives only their separately attributed product line');
 equal(Number((await wage(counter)).product_commission_cents)-counterBeforeMixed,Number(mixedLines.find(line=>line.staff_id===counter).commission_cents),'counter seller receives exactly their own mixed product line');
 check((await admin('spa_payroll_sources',[secondContractor,...range,rule])).reconciliation.source_matches,'mixed service source reconciliation agrees with exact payroll');
 const own=await call(employee,'spa_staff_self',range);
 equal(own.payroll.staff_id,junior,'staff portal uses its mapped personnel record');
 equal(Number(own.metrics.commission_cents),Number((await wage(junior)).service_commission_cents)+Number((await wage(junior)).designated_bonus_cents),'employee and owner salary use exactly the same engine');
 await reject(()=>call(counterUser,'spa_payroll_sources',[junior,...range,null]),/FORBIDDEN/);
 await reject(()=>call(null,'spa_payroll_sources',[junior,...range,null]),/permission denied|FORBIDDEN|TEAM/);
 const catalog=await call(null,'spa_catalog');
 check(catalog.staff.every(person=>person.work_category==='technician'),'public bookable staff excludes counter and owner');
 check(catalog.staff.every(person=>!('base_pay_cents'in person)&&!('hire_date'in person)&&!('contract_started_on'in person)),'public staff metadata does not expose HR or compensation');

 const rates=(await db.query('select * from spa_payroll_overtime_rates where rule_version_id=$1',[rule])).rows;
 const allTiers=(await db.query('select * from spa_payroll_commission_tiers where rule_version_id=$1',[rule])).rows;
 const ownTier=allTiers.find(tier=>tier.job_title_id===title('ft_junior').id);
 await reject(()=>admin('spa_payroll_components_save_v2',[rule,rates,[{...ownTier,calculation_mode:'flat'}]]),/PAYROLL_ORDERED_TIER_UNSUPPORTED/);
 await reject(()=>admin('spa_payroll_components_save_v2',[rule,rates,[{...ownTier,metric:'product_sales_cents'}]]),/PAYROLL_ORDERED_TIER_UNSUPPORTED/);
 await reject(()=>admin('spa_payroll_components_save_v2',[rule,rates,[{...ownTier,service_category_id:product.category_id}]]),/PAYROLL_ORDERED_TIER_UNSUPPORTED/);
 await reject(()=>admin('spa_payroll_components_save_v2',[rule,rates,[{...ownTier,threshold_from:1,threshold_to:null}]]),/PAYROLL_TIER_GAP/);
 const liveBefore=(await db.query('select count(*)::int n from realtime.sent')).rows[0]?.n;
 await admin('spa_compensation_profile_save_v3',[rule,{...await profile('ft_junior'),base_pay_cents:3100000}]);
 if(liveBefore!==undefined)check((await db.query('select count(*)::int n from realtime.sent')).rows[0].n>liveBefore,'profile-only changes produce event-driven invalidation');
 const oldProfile={...await profile('ft_junior')};
 await reject(()=>admin('spa_payroll_rule_create',['未來不可立即啟用','2026-11-01',240,true,2760,3240,8280]),/FUTURE_PAYROLL_ACTIVATION_NOT_SUPPORTED/);
 const next=await admin('spa_payroll_rule_create',['測試下一版本','2026-10-01',240,true,2760,3240,8280]);
 equal((await profile('ft_junior','full_time',next)).base_pay_cents,oldProfile.base_pay_cents,'version cloning copies editable salary profile');
 await admin('spa_compensation_profile_save_v3',[next,{...await profile('ft_junior','full_time',next),base_pay_cents:3300000}]);
 equal(Number((await wage(junior,range,rule)).base_cents),3100000,'later version changes do not leak into a prior ordered version');
 equal(Number((await wage(junior,range,next)).base_cents),3300000,'new version uses its own salary settings');
 await reject(()=>admin('spa_compensation_profile_save_v3',[rule,{...oldProfile,base_pay_cents:1}]),/PAYROLL_RULE_ARCHIVED/);
 await db.query("update spa_payroll_rule_versions set effective_from='2026-11-01' where id=$1",[rule]);
 await reject(()=>admin('spa_payroll_rule_activate',[rule]),/FUTURE_PAYROLL_ACTIVATION_NOT_SUPPORTED/);
 await db.query("update spa_payroll_rule_versions set effective_from='2026-10-10' where id=$1",[rule]);
 await admin('spa_payroll_rule_activate',[rule]);
 const run=await admin('spa_payroll_run_save',[...range,rule,true]);
 const frozen=await call(employee,'spa_payroll_sources',[junior,...range,null]);
 equal(frozen.basis,'finalized','employee source uses saved finalized wage');
 equal(frozen.evidence_mode,'snapshot','ordered calculation evidence is retained with the run');
 check(frozen.sources.commission_details.length>0&&frozen.reconciliation.source_matches,'finalized packet preserves per-course calculation and exact reconciliation');
 await admin('spa_compensation_profile_save_v3',[rule,{...await profile('ft_junior'),base_pay_cents:3500000}]);
 equal(Number((await call(employee,'spa_payroll_sources',[junior,...range,null])).wage.total_cents),Number(frozen.wage.total_cents),'later profile edits cannot change saved employee payroll');
 await reject(()=>sell(counter,product.id,1,'2026-10-18',{kind:'product'}),/PAYROLL_LOCKED/);
 await reject(()=>admin('spa_payroll_rule_delete',[rule,'DELETE']),/PAYROLL_RULE_ACTIVE/);
 await admin('spa_payroll_reopen',[run,'測試重開']);
 equal((await call(employee,'spa_staff_self',range)).metrics.payroll_status,'preview','owner reopen returns employee to the live calculation');
 console.log(`Payroll redesign checks passed (${checks} assertions).`);
} catch(error) {
 console.error(error.message);if(error.where)console.error(error.where);process.exitCode=1;
} finally {await db.close();}
