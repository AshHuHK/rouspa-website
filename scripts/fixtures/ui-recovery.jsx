// Local, synthetic read-only fixture. Every API request is intercepted before
// importing the application; unsupported requests fail instead of reaching a store.
import React, { useState } from 'react';
import { createRoot } from 'react-dom/client';
import '../../src/public-theme.css';
import '../../src/responsive.css';
import '../../src/public-navigation.css';
import '../../src/operations.css';
import '../../src/operations-cyber.css';

const service={id:'fixture-service',name:'測試療程',duration_minutes:45,price_cents:110000,active:true};
const staff={id:'fixture-staff',name:'測試技師',active:true};
const catalog={services:[service,{...service,id:'fixture-90',name:'90分方子',duration_minutes:90},{...service,id:'fixture-120',name:'120分方子',duration_minutes:120}],staff:[staff],skills:[{service_id:service.id,staff_id:staff.id,enabled:true}],settings:{booking_days:60}};
const params=new URLSearchParams(location.search);
const fixture={calendarReads:0,slotReads:0,shopReads:0,planReads:0,createRequests:[],bookings:0,adminReads:{},failShop:params.has('fail'),failPlan:params.has('fail'),failSession:params.has('fail'),signedOut:0,noSlots:false};
const role=params.get('role');
const openAttendance=params.has('working')?{id:'fixture-attendance',clock_in:'2026-10-06T20:00:00+08:00',break_minutes:0}:null;
const breaks=[];
const batchAttendance=['batch-1','batch-2'].map((id,index)=>({id,version:1,staff_id:staff.id,employee:staff.name,work_date:'2026-11-10',status:'pending',effective_start:'2026-11-10T10:00:00+08:00',effective_end:'2026-11-10T18:00:00+08:00',break_minutes:60,flags:[]}));

const adminRules=[1,3,5,6,7,8].map(version=>({id:`rule-${version}`,version_no:version,
 name:version===8?'技師薪資制度告知書 03-1':`測試薪資版本 ${version}`,
 effective_from:'2026-01-01',status:version===8?'draft':version===7?'active':'archived',calculation_engine:version>=7?'notice_v1':'ordered_v2'}));
const customers=[{id:'member-1',name:'測試會員 甲',phone:'0911222333',tier:'一般會員',customer_type:'member',balance_cents:10000,visits:1},{id:'guest-2',name:'測試顧客 乙',phone:'0922333444',customer_type:'guest',balance_cents:0,visits:0}];
window.uiFixture=fixture;
const NativeSocket=window.WebSocket;
window.WebSocket=class extends EventTarget {
  constructor(url,...args){super();if(new URL(url,location.href).hostname===location.hostname)return new NativeSocket(url,...args);this.readyState=0;}
  send(){} close(){this.readyState=3;}
  static CONNECTING=0;static OPEN=1;static CLOSING=2;static CLOSED=3;
};
window.fetch=async(input,init={})=>{
  const url=new URL(typeof input==='string'?input:input.url,location.href);
  const body=JSON.parse(init.body||'{}'),name=url.pathname==='/api/public-rpc'?body.rpc:url.pathname.split('/').pop(),args=body.args||body;
  const response=data=>new Response(JSON.stringify(data),{status:200,headers:{'content-type':'application/json'}});
  const failure=()=>new Response(JSON.stringify({message:'PUBLIC_NETWORK_ERROR'}),{status:503,headers:{'content-type':'application/json'}});
  if(role)fixture.adminReads[name]=(fixture.adminReads[name]||0)+1;
  if(name==='spa_server_time')return response(new Date().toISOString());
  if(name==='spa_session')return fixture.failSession?new Response(JSON.stringify({message:'No suitable key or wrong key type',code:'PGRST301'}),{status:401}):response(role?{role:role==='restricted'?'therapist':role,staff_id:role==='owner'?null:staff.id,permissions:role==='restricted'?[]:['dashboard.view','appointments.view','reviews.view'] }:{role:null});
  if(name==='spa_catalog')return response(catalog);
  if(name==='spa_dashboard')return response({date:new Date().toISOString().slice(0,10),appointments:4,pending:0,completed:2,staff_working:1,simultaneous_capacity:4,
   ...role==='owner'?{revenue_cents:100000,unsettled_completed:0,low_stock:0}:null,next_appointments:[],today_hours:{is_open:true,opening_minute:600,closing_minute:1560,source:'weekly'}});
  if(name==='spa_monthly_operations')return response({month:args.p_month.slice(0,7),days:[{
   date:args.p_month,shift_count:1,off_count:2,appointment_count:0,peak_simultaneous_count:0,
   store_hours:{is_open:true,opening_minute:600,closing_minute:1560},shifts:[],rests:[],leaves:[],appointments:[]
  }]});
  if(name==='spa_operations_convenience')return response({is_owner:role==='owner',todos:[]});
  if(name==='spa_admin_bookings')return response([]);
  if(name==='spa_customers_list')return response(customers);
  if(name==='spa_team_os')return response({staff:[{...staff,phone:'0912000800',email:null,title:'試用技師',
   employment_type_name:'正職',hire_date:null,is_bookable:true,website_visible:true}],accounts:[],shifts:[],daily_shifts:[],time_off:[]});
  if(name==='spa_schedule_admin')return response({target_month:'2026-12-01',edit_open:false,staff:[],requests:[]});
  if(name==='spa_public_reviews')return response([]);
  if(name==='spa_attendance_queue')return response({settings:{address:'測試門店'},rows:batchAttendance,events:[],breaks:[],requests:[],period:{from:'2026-11-01',to:'2026-11-15'},periods:[{from:'2026-11-01',to:'2026-11-15',pending_count:2,request_count:0}]});
  if(name==='spa_attendance_batch_review'){
   fixture.batchRequest=args;
   for(const row of batchAttendance)if(args.p_rows.some(picked=>picked.id===row.id))row.status='approved';
   return response({approved_count:args.p_rows.length});
  }
  if(name==='spa_attendance_admin')return response({settings:{address:'測試門店'},rows:[],events:[],requests:[],staff:[]});
  if(name==='spa_reviews_admin')return response({reviews:[],feedback:[]});
  if(name==='spa_payroll_admin')return response({rules:adminRules,staff:[],runs:[{id:'saved-run',rule_version_id:'rule-5',period_start:'2026-01-01',period_end:'2026-01-31',status:'finalized'}],preview:[],rates:[],tiers:[]});
  if(name==='spa_payroll_preview')return response([]);
  if(name==='spa_attendance_self')return response({settings:{address:'測試門店',radius_m:100,max_accuracy_m:100},open:openAttendance,rows:[],events:[],breaks,requests:[]});
  if(name==='spa_attendance_break_add'&&openAttendance){
   breaks.push({id:args.p_request,attendance_id:args.p_attendance,starts_at:args.p_start,ends_at:args.p_end});
   openAttendance.break_minutes=breaks.reduce((n,row)=>n+(Date.parse(row.ends_at)-Date.parse(row.starts_at))/60000,0);
   return response(args.p_request);
  }
  if(name==='spa_attendance_request_quick'&&openAttendance)return response(args.p_request);
  if(name==='spa_staff_self')return response({profile:{id:staff.id,name:staff.name,title:'技師'},metrics:{completed:0,settled_completed:0,unsettled_completed:0,minutes:0,commission_cents:0,reviews:0,total_cents:0},lifetime_completed:0,reviews:[],daily_shifts:[],shifts:[],time_off:[]});
  if(name==='spa_booking_calendar'){
    fixture.calendarReads++;await new Promise(resolve=>setTimeout(resolve,250));
    const [y,m]=args.p_month.slice(0,7).split('-').map(Number),count=new Date(Date.UTC(y,m,0)).getUTCDate();
    return response({month:args.p_month.slice(0,7),days:Array.from({length:count},(_,i)=>({date:`${args.p_month.slice(0,7)}-${String(i+1).padStart(2,'0')}`,status:'open',available_staff:1,start_minute:600,end_minute:1560}))});
  }
  if(name==='spa_public_slots'){fixture.slotReads++;return response(fixture.noSlots?[]:[{starts_at:`${args.p_date}T10:00:00+08:00`,time_label:'10:00',available:true,available_staff_count:1}]);}
  if(name==='spa_create_booking'&&params.get('mode')==='retry'){
    fixture.createRequests.push({...args});
    if(!fixture.bookings){
      fixture.bookings++;fixture.noSlots=true;
      await new Promise(resolve=>setTimeout(resolve,80));
      if(params.get('outcome')==='malformed')return response({});
      if(params.get('outcome')==='http')return new Response('HTTP 502',{status:502});
      throw new Error('PUBLIC_REQUEST_TIMEOUT');
    }
    if(JSON.stringify(args)!==JSON.stringify(fixture.createRequests[0]))return failure();
    return response({reference:'LOCAL-ONE-BOOKING',manage_token:'00000000-0000-4000-8000-000000000001',staff_name:staff.name,booking_preference:'designated'});
  }
  if(name==='spa_store_catalog'){
    fixture.shopReads++;if(fixture.failShop)return failure();
    return response({categories:[{id:'hair',name:'髮浴'},{id:'tea',name:'茶飲'}],products:[{id:'hair-product',category_id:'hair',name:'測試洗髮',price_cents:10000,inventory:1},{id:'tea-product',category_id:'tea',name:'測試茶飲',price_cents:20000,inventory:1}]});
  }
  if(name==='spa_staff_schedule_plan'){
    fixture.planReads++;if(fixture.failPlan)return failure();
    const d=new Date(),month=new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,1)).toISOString().slice(0,7);
    const [y,m]=month.split('-').map(Number);
    return response({target_month:`${month}-01`,edit_open:true,max_off_per_day:2,days:Array.from({length:new Date(Date.UTC(y,m,0)).getUTCDate()},(_,i)=>({business_date:`${month}-${String(i+1).padStart(2,'0')}`,is_working:true,start_minute:600,end_minute:1560,appointment_count:0,off_count:0,can_turn_off:true})),requests:[]});
  }
  return failure();
};
const [{default:Booking},{default:Home},{default:Shop},{EmployeeSchedulePlanner},{default:Admin},{ApplicationBoundary},{supabase}]=await Promise.all([import('../../src/PublicBookingExperience.jsx'),import('../../src/App.jsx'),import('../../src/Shop.jsx'),import('../../src/StaffPortal.jsx'),import('../../src/Admin.jsx'),import('../../src/ApplicationBoundary.jsx'),import('../../src/lib/spa.js')]);
let authListener;
supabase.auth.getSession=async()=>{if(params.get('outcome')==='session-read'&&fixture.failSession)throw new TypeError('Failed to fetch');return {data:{session:{user:{id:'fixture-user',email:'fixture@example.invalid'}}},error:null};};
supabase.auth.onAuthStateChange=callback=>{authListener=callback;return {data:{subscription:{unsubscribe(){}}}};};
supabase.auth.signOut=async()=>{fixture.signedOut++;authListener?.('SIGNED_OUT',null);return {error:null};};
function FailedScreen(){throw new Error('Synthetic render failure');}
function Fixture(){
  const [data,setData]=useState(catalog),[version,setVersion]=useState(0);
  fixture.setCatalog=kind=>setData(kind==='loading'?null:kind==='empty'?{...catalog,services:[]}:kind==='no-staff'?{...catalog,staff:[]}: {...catalog});
  fixture.refreshBooking=()=>setData(current=>({...current}));
  fixture.reloadPlan=()=>setVersion(value=>value+1);
  const mode=new URLSearchParams(location.search).get('mode');
  if(mode==='home')return <Home/>;
  if(mode==='shop')return <Shop onNavigateHome={()=>{}}/>;
  if(mode==='staff')return <div className="ops"><main><EmployeeSchedulePlanner refreshToken={version}/></main></div>;
  if(mode==='admin')return <ApplicationBoundary><Admin/></ApplicationBoundary>;
  if(mode==='boundary')return <ApplicationBoundary><FailedScreen/></ApplicationBoundary>;
  return <div className="public-home"><nav className="public-nav" style={{height:73}}>測試導覽</nav><div style={{height:2200}}/><section className="booking-section" style={{maxWidth:700,margin:'auto',padding:16}}><Booking catalog={data}/></section><section style={{height:1600,padding:30}}>測試下方內容</section></div>;
}
createRoot(document.getElementById('root')).render(<Fixture/>);
