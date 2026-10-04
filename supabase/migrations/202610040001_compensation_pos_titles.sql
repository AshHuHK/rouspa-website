begin;

-- Compensation belongs to a job title + employment type, rather than to an
-- individual employee. Existing values seed the shared rules so the migration
-- does not invent or erase the store's current settings.
alter table public.spa_job_titles add column if not exists name_en text not null default '';
update public.spa_job_titles set name_en=case code
 when 'owner' then 'Owner' when 'manager' then 'Manager' when 'head_therapist' then 'Lead therapist'
 when 'senior_therapist' then 'Senior therapist' when 'therapist' then 'Therapist'
 when 'reception' then 'Receptionist' when 'part_time' then 'Part-time therapist' else name_en end
where name_en='';

update public.spa_staff
set job_title_id=(select id from public.spa_job_titles where code='therapist')
where job_title_id is null;
update public.spa_staff s set title=j.name from public.spa_job_titles j where j.id=s.job_title_id;
alter table public.spa_staff alter column job_title_id set not null;

create table if not exists public.spa_compensation_profiles (
 job_title_id uuid not null references public.spa_job_titles,
 employment_type_code text not null references public.spa_employment_types(code),
 pay_basis text not null default 'monthly' check(pay_basis in ('monthly','hourly','session')),
 base_pay_cents bigint not null default 0 check(base_pay_cents>=0),
 service_commission_bps int not null default 0 check(service_commission_bps between 0 and 10000),
 product_commission_bps int not null default 0 check(product_commission_bps between 0 and 10000),
 designated_client_bonus_cents bigint not null default 0 check(designated_client_bonus_cents>=0),
 active boolean not null default true,
 updated_by uuid references auth.users,
 updated_at timestamptz not null default now(),
 primary key(job_title_id,employment_type_code)
);

insert into public.spa_compensation_profiles(job_title_id,employment_type_code,pay_basis,base_pay_cents,service_commission_bps,product_commission_bps,designated_client_bonus_cents)
select j.id,e.code,
 coalesce((array_agg(s.pay_basis order by (s.employment_status='active') desc,s.created_at desc) filter(where s.id is not null))[1],case when e.code='part_time' then 'hourly' else 'monthly' end),
 coalesce(max(s.base_pay_cents),0),coalesce(max(s.commission_bps),0),coalesce(max(s.commission_bps),0),0
from public.spa_job_titles j cross join public.spa_employment_types e
left join public.spa_staff s on s.job_title_id=j.id and s.employment_type_code=e.code
group by j.id,e.code
on conflict(job_title_id,employment_type_code) do nothing;

-- Keep legacy columns synchronized for older snapshots and functions. They are
-- no longer editable from personnel records or used as the source of truth.
update public.spa_staff s set pay_basis=c.pay_basis,base_pay_cents=c.base_pay_cents,commission_bps=c.service_commission_bps
from public.spa_compensation_profiles c where c.job_title_id=s.job_title_id and c.employment_type_code=s.employment_type_code;
update public.spa_staff_services set commission_override_bps=null;

alter table public.spa_compensation_profiles enable row level security;
revoke all on public.spa_compensation_profiles from public,anon,authenticated;
grant all on public.spa_compensation_profiles to service_role;

create or replace function public.spa_compensation_profile_save(
 p_job_title uuid,p_employment_type text,p_pay_basis text,p_base_pay bigint,
 p_service_commission int,p_product_commission int,p_designated_bonus bigint,p_active boolean default true
) returns void language plpgsql security definer set search_path='' as $$
declare old jsonb;
begin
 perform spa_private.require_permission('payroll.manage');
 if not exists(select 1 from public.spa_job_titles where id=p_job_title)
  or not exists(select 1 from public.spa_employment_types where code=p_employment_type)
  or p_pay_basis not in ('monthly','hourly','session') or p_base_pay<0
  or p_service_commission not between 0 and 10000 or p_product_commission not between 0 and 10000
  or p_designated_bonus<0 or p_active is null then raise exception 'INVALID_INPUT'; end if;
 select to_jsonb(c) into old from public.spa_compensation_profiles c where c.job_title_id=p_job_title and c.employment_type_code=p_employment_type;
 insert into public.spa_compensation_profiles(job_title_id,employment_type_code,pay_basis,base_pay_cents,service_commission_bps,product_commission_bps,designated_client_bonus_cents,active,updated_by,updated_at)
 values(p_job_title,p_employment_type,p_pay_basis,p_base_pay,p_service_commission,p_product_commission,p_designated_bonus,p_active,auth.uid(),now())
 on conflict(job_title_id,employment_type_code) do update set pay_basis=excluded.pay_basis,base_pay_cents=excluded.base_pay_cents,
  service_commission_bps=excluded.service_commission_bps,product_commission_bps=excluded.product_commission_bps,
  designated_client_bonus_cents=excluded.designated_client_bonus_cents,active=excluded.active,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 update public.spa_staff set pay_basis=p_pay_basis,base_pay_cents=p_base_pay,commission_bps=p_service_commission
 where job_title_id=p_job_title and employment_type_code=p_employment_type;
 perform spa_private.audit('compensation.profile_saved',p_job_title::text||':'||p_employment_type,
  jsonb_build_object('old',old,'pay_basis',p_pay_basis,'base_pay_cents',p_base_pay,'service_commission_bps',p_service_commission,
   'product_commission_bps',p_product_commission,'designated_client_bonus_cents',p_designated_bonus,'active',p_active));
end $$;

create or replace function public.spa_staff_profile_save_v2(p_payload jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare
 result uuid:=nullif(p_payload->>'id','')::uuid; old jsonb; services uuid[];
 work_status text:=coalesce(nullif(p_payload->>'employment_status',''),case when coalesce((p_payload->>'active')::boolean,true) then 'active' else 'inactive' end);
 leave_date date:=nullif(p_payload->>'departed_on','')::date; leave_reason text:=btrim(coalesce(p_payload->>'departure_reason',''));
 is_current boolean; title_id uuid:=nullif(p_payload->>'job_title_id','')::uuid; title_name text; employment_code text:=coalesce(nullif(p_payload->>'employment_type_code',''),'full_time');
begin
 perform spa_private.require_permission('team.manage');
 if length(btrim(coalesce(p_payload->>'name',''))) not between 1 and 80 or work_status not in ('active','departed','inactive') or title_id is null then raise exception 'INVALID_INPUT'; end if;
 select name into title_name from public.spa_job_titles where id=title_id and active;
 if title_name is null or not exists(select 1 from public.spa_employment_types where code=employment_code and active) then raise exception 'INVALID_INPUT'; end if;
 if work_status='departed' and (leave_date is null or length(leave_reason) not between 1 and 1000) then raise exception 'DEPARTURE_DETAILS_REQUIRED'; end if;
 if work_status<>'departed' then leave_date:=null;leave_reason:=''; end if;
 is_current:=work_status='active'; select to_jsonb(s) into old from public.spa_staff s where s.id=result;
 if result is null then
  insert into public.spa_staff(name,name_en,title,specialty,bio,active,photo_url,phone,email,birth_date,address,hire_date,employment_type_code,job_title_id,is_bookable,website_visible,employment_status,departed_on,departure_reason)
  values(btrim(p_payload->>'name'),coalesce(p_payload->>'name_en',''),title_name,coalesce(p_payload->>'specialty',''),coalesce(p_payload->>'bio',''),is_current,
   coalesce(p_payload->>'photo_url',''),coalesce(p_payload->>'phone',''),coalesce(p_payload->>'email',''),nullif(p_payload->>'birth_date','')::date,
   coalesce(p_payload->>'address',''),nullif(p_payload->>'hire_date','')::date,employment_code,title_id,
   is_current and coalesce((p_payload->>'is_bookable')::boolean,true),is_current and coalesce((p_payload->>'website_visible')::boolean,true),work_status,leave_date,leave_reason)
  returning id into result;
 else
  update public.spa_staff set name=btrim(p_payload->>'name'),name_en=coalesce(p_payload->>'name_en',''),title=title_name,
   specialty=coalesce(p_payload->>'specialty',''),bio=coalesce(p_payload->>'bio',''),active=is_current,photo_url=coalesce(p_payload->>'photo_url',''),
   phone=coalesce(p_payload->>'phone',''),email=coalesce(p_payload->>'email',''),birth_date=nullif(p_payload->>'birth_date','')::date,
   address=coalesce(p_payload->>'address',''),hire_date=nullif(p_payload->>'hire_date','')::date,employment_type_code=employment_code,job_title_id=title_id,
   is_bookable=is_current and coalesce((p_payload->>'is_bookable')::boolean,is_bookable),website_visible=is_current and coalesce((p_payload->>'website_visible')::boolean,website_visible),
   employment_status=work_status,departed_on=leave_date,departure_reason=leave_reason
  where id=result and archived_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
 end if;
 update public.spa_staff s set pay_basis=c.pay_basis,base_pay_cents=c.base_pay_cents,commission_bps=c.service_commission_bps
 from public.spa_compensation_profiles c where s.id=result and c.job_title_id=s.job_title_id and c.employment_type_code=s.employment_type_code;
 services:=array(select jsonb_array_elements_text(coalesce(p_payload->'services','[]'::jsonb))::uuid);
 delete from public.spa_staff_services where staff_id=result;
 insert into public.spa_staff_services(staff_id,service_id,enabled) select result,unnest(services),true;
 if not is_current then update public.spa_roles set active=false,login_after=date_trunc('second',clock_timestamp())+interval '1 second' where staff_id=result; end if;
 perform spa_private.audit('staff.profile_saved',result::text,jsonb_build_object('old',old,'new',p_payload-'services'-'pay_basis'-'base_pay_cents'-'commission_bps','employment_status',work_status,'departed_on',leave_date));
 return result;
end $$;

create or replace function public.spa_team_os() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('team.view');
 return jsonb_build_object(
  'staff',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('employment_type_name',e.name,'job_title_name',j.name,'job_title_name_en',j.name_en) order by s.display_order,s.created_at)
   from public.spa_staff s left join public.spa_employment_types e on e.code=s.employment_type_code left join public.spa_job_titles j on j.id=s.job_title_id),'[]'),
  'employment_types',coalesce((select jsonb_agg(to_jsonb(e) order by display_order) from public.spa_employment_types e),'[]'),
  'job_titles',coalesce((select jsonb_agg(to_jsonb(j) order by display_order) from public.spa_job_titles j),'[]'),
  'compensation_profiles',case when spa_private.has_permission('payroll.view') then coalesce((select jsonb_agg(to_jsonb(c)||jsonb_build_object('job_title_name',j.name,'employment_type_name',e.name) order by j.display_order,e.display_order)
   from public.spa_compensation_profiles c join public.spa_job_titles j on j.id=c.job_title_id join public.spa_employment_types e on e.code=c.employment_type_code),'[]') else '[]'::jsonb end,
  'role_profiles',coalesce((select jsonb_agg(to_jsonb(r) order by display_order) from public.spa_role_profiles r),'[]'),
  'shifts',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_shifts s),'[]'),
  'daily_shifts',coalesce((select jsonb_agg(to_jsonb(d) order by business_date,staff_id) from public.spa_daily_shifts d where d.business_date>=(now() at time zone 'Asia/Taipei')::date-7 and d.business_date<=(now() at time zone 'Asia/Taipei')::date+366),'[]'),
  'time_off',coalesce((select jsonb_agg(to_jsonb(t) order by starts_at) from public.spa_time_off t where ends_at>now()-interval '30 days'),'[]'),
  'accounts',case when spa_private.has_permission('team.manage') then coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'role',r.role,'staff_id',r.staff_id,'active',r.active,'username',r.login_name,'email',case when r.role='owner' then u.email end)) from public.spa_roles r join auth.users u on u.id=r.user_id),'[]') else '[]'::jsonb end);
end $$;

create or replace function public.spa_catalog() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
 'settings',(select to_jsonb(s) from public.spa_settings s),'business',(select value from public.spa_business_settings where key='business'),'website',(select value from public.spa_business_settings where key='website'),
 'business_hours',coalesce((select jsonb_agg(to_jsonb(h) order by weekday) from public.spa_business_hours h),'[]'),
 'today_hours',(select to_jsonb(w) from spa_private.business_window((now() at time zone 'Asia/Taipei')::date) w),
 'services',coalesce((select jsonb_agg(to_jsonb(s) order by display_order) from public.spa_services s where active and status='active' and online_booking_enabled),'[]'),
 'website_services',coalesce((select jsonb_agg(to_jsonb(s) order by display_order) from public.spa_services s where active and status='active' and website_visible),'[]'),
 'staff',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'name_en',s.name_en,'title',j.name,'title_en',j.name_en,'job_title_id',j.id,'specialty',s.specialty,'bio',s.bio,'photo_url',s.photo_url) order by s.display_order)
  from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.active and s.employment_status='active' and s.archived_at is null and s.is_bookable),'[]'),
 'website_staff',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'name_en',s.name_en,'title',j.name,'title_en',j.name_en,'job_title_id',j.id,'specialty',s.specialty,'bio',s.bio,'photo_url',s.photo_url) order by s.display_order)
  from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.active and s.employment_status='active' and s.archived_at is null and s.website_visible),'[]'),
 'skills',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_staff_services s where enabled),'[]'))
$$;

create or replace function public.spa_catalog_admin() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('catalog.view');
 return jsonb_build_object(
  'service_categories',coalesce((select jsonb_agg(to_jsonb(c) order by display_order) from public.spa_service_categories c),'[]'),
  'services',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('category_name',c.name) order by s.display_order) from public.spa_services s left join public.spa_service_categories c on c.id=s.category_id),'[]'),
  'product_categories',coalesce((select jsonb_agg(to_jsonb(c) order by display_order) from public.spa_product_categories c),'[]'),
  'products',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('category_name',c.name,'inventory',coalesce((select sum(i.delta) from public.spa_inventory_entries i where i.product_id=p.id),0)) order by p.display_order)
   from public.spa_products p left join public.spa_product_categories c on c.id=p.category_id),'[]'),
  'staff',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'job_title_name',j.name) order by s.display_order) from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.active and s.employment_status='active' and s.archived_at is null),'[]'),
  'skills',coalesce((select jsonb_agg(to_jsonb(sk)) from public.spa_staff_services sk where sk.enabled),'[]'));
end $$;

create or replace function public.spa_catalog_delete(p_kind text,p_id uuid,p_confirmation text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare used boolean:=false; item_name text; result text;
begin
 perform spa_private.require_permission('catalog.manage');
 if p_confirmation<>'DELETE' or p_kind not in ('service','product') or p_id is null then raise exception 'INVALID_CONFIRMATION'; end if;
 if p_kind='service' then
  select name into item_name from public.spa_services where id=p_id for update;
  if item_name is null then raise exception 'NOT_FOUND'; end if;
  used:=exists(select 1 from public.spa_appointments where service_id=p_id)
    or exists(select 1 from public.spa_packages where service_id=p_id)
    or exists(select 1 from public.spa_order_items where service_id=p_id);
  if used then
   update public.spa_services set status='archived',active=false,online_booking_enabled=false,website_visible=false where id=p_id; result:='archived';
  else
   delete from public.spa_staff_services where service_id=p_id; delete from public.spa_services where id=p_id; result:='deleted';
  end if;
 else
  select name into item_name from public.spa_products where id=p_id for update;
  if item_name is null then raise exception 'NOT_FOUND'; end if;
  used:=exists(select 1 from public.spa_order_items where product_id=p_id);
  if used then
   update public.spa_products set status='archived',website_visible=false,store_visible=false where id=p_id; result:='archived';
  else
   delete from public.spa_inventory_entries where product_id=p_id; delete from public.spa_products where id=p_id; result:='deleted';
  end if;
 end if;
 perform spa_private.audit('catalog.'||result,p_id::text,jsonb_build_object('kind',p_kind,'name',item_name));
 return jsonb_build_object('result',result,'name',item_name);
end $$;

create or replace function spa_private.booking_summary(a public.spa_appointments) returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('id',a.id,'reference',a.reference,'service_id',a.service_id,'service_name',coalesce(a.service_name_snapshot,a.service_name),
 'business_date',a.business_date,'starts_at',a.starts_at,'ends_at',a.ends_at,'status',a.status,'staff_id',a.staff_id,
 'therapist',st.name,'therapist_title',j.name,'therapist_title_en',j.name_en,'price_cents',a.price_cents+a.tea_cents,
 'change_before',a.starts_at-make_interval(hours=>cfg.cancellation_hours),'can_change',a.status in ('pending','confirmed') and a.starts_at>=now()+make_interval(hours=>cfg.cancellation_hours),
 'can_review',a.status='completed' and not exists(select 1 from public.spa_reviews where appointment_id=a.id),
 'review_submitted',exists(select 1 from public.spa_reviews where appointment_id=a.id))
 from public.spa_settings cfg join public.spa_staff st on st.id=a.staff_id join public.spa_job_titles j on j.id=st.job_title_id
$$;

create or replace function spa_private.checkout_commission_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare rate int; tea bigint;
begin
 select coalesce(c.service_commission_bps,0),a.tea_cents into rate,tea
 from public.spa_appointments a join public.spa_staff s on s.id=a.staff_id
 left join public.spa_compensation_profiles c on c.job_title_id=s.job_title_id and c.employment_type_code=s.employment_type_code and c.active
 where a.id=new.appointment_id;
 if rate is null then raise exception 'STAFF_COMPENSATION_REQUIRED'; end if;
 new.commission_cents:=round(greatest(0,new.revenue_cents-tea)*rate/10000.0); return new;
end $$;

alter table public.spa_cash_entries drop constraint if exists spa_cash_entries_category_check;
alter table public.spa_cash_entries add constraint spa_cash_entries_category_check check(category in ('service','product','pos','topup','package','tip','expense','refund'));

create or replace function public.spa_pos_checkout(p_request uuid,p_customer uuid,p_items jsonb,p_discount bigint,p_method text,p_note text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare result public.spa_orders; item jsonb; product public.spa_products; service public.spa_services; qty int; subtotal bigint:=0; line bigint; staff uuid; commission bigint; kind text; item_id uuid; rate int;
begin
 perform spa_private.require_permission('pos.use');
 if p_request is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>100 or p_discount<0 or p_method not in ('cash','card','transfer') then raise exception 'INVALID_INPUT'; end if;
 select * into result from public.spa_orders where request_id=p_request;
 if found then return to_jsonb(result); end if;
 perform pg_advisory_xact_lock(726006);
 if p_customer is not null and not exists(select 1 from public.spa_customers where id=p_customer and archived_at is null) then raise exception 'INVALID_CUSTOMER'; end if;
 insert into public.spa_orders(request_id,customer_id,created_by,note) values(p_request,p_customer,auth.uid(),coalesce(p_note,'')) returning * into result;
 for item in select * from jsonb_array_elements(p_items) loop
  qty:=coalesce((item->>'quantity')::int,0); staff:=nullif(item->>'staff_id','')::uuid;
  kind:=coalesce(nullif(item->>'item_type',''),case when item ? 'service_id' then 'service' else 'product' end);
  item_id:=coalesce(nullif(item->>'item_id',''),nullif(item->>'product_id',''),nullif(item->>'service_id',''))::uuid;
  if qty<=0 or kind not in ('product','service') then raise exception 'INVALID_ITEM'; end if;
  if staff is not null and not exists(select 1 from public.spa_staff where id=staff and active and employment_status='active' and archived_at is null) then raise exception 'STAFF_NOT_ACTIVE'; end if;
  if kind='product' then
   select * into product from public.spa_products where id=item_id and status='active' for update;
   if not found then raise exception 'INVALID_PRODUCT'; end if;
   if coalesce((select sum(delta) from public.spa_inventory_entries where product_id=product.id),0)<qty then raise exception 'INSUFFICIENT_INVENTORY'; end if;
   line:=product.price_cents*qty; subtotal:=subtotal+line;
   select coalesce(c.product_commission_bps,0) into rate from public.spa_staff s left join public.spa_compensation_profiles c on c.job_title_id=s.job_title_id and c.employment_type_code=s.employment_type_code and c.active where s.id=staff;
   commission:=case when staff is null then 0 else round(line*coalesce(rate,0)/10000.0)::bigint end;
   insert into public.spa_order_items(order_id,product_id,item_type,name_snapshot,sku_snapshot,unit_price_cents,cost_snapshot_cents,quantity,line_total_cents,staff_id,commission_cents)
   values(result.id,product.id,'product',product.name,product.sku,product.price_cents,product.cost_cents,qty,line,staff,commission);
   insert into public.spa_inventory_entries(product_id,delta,reason,reference_type,reference_id,created_by) values(product.id,-qty,'POS 銷售 '||result.reference,'order',result.id,auth.uid());
  else
   if staff is null then raise exception 'SERVICE_STAFF_REQUIRED'; end if;
   select * into service from public.spa_services where id=item_id and active and status='active';
   if not found then raise exception 'INVALID_SERVICE'; end if;
   if not exists(select 1 from public.spa_staff_services where staff_id=staff and service_id=service.id and enabled) then raise exception 'STAFF_SKILL_REQUIRED'; end if;
   line:=service.price_cents*qty; subtotal:=subtotal+line;
   select coalesce(c.service_commission_bps,0) into rate from public.spa_staff s left join public.spa_compensation_profiles c on c.job_title_id=s.job_title_id and c.employment_type_code=s.employment_type_code and c.active where s.id=staff;
   commission:=round(line*coalesce(rate,0)/10000.0)::bigint;
   insert into public.spa_order_items(order_id,service_id,item_type,name_snapshot,unit_price_cents,quantity,line_total_cents,staff_id,commission_cents)
   values(result.id,service.id,'service',service.name,service.price_cents,qty,line,staff,commission);
  end if;
 end loop;
 if p_discount>subtotal then raise exception 'INVALID_INPUT'; end if;
 update public.spa_orders set subtotal_cents=subtotal,discount_cents=p_discount,total_cents=subtotal-p_discount,status='paid',method=p_method,paid_at=now() where id=result.id returning * into result;
 insert into public.spa_cash_entries(request_id,customer_id,amount_cents,category,method,note,created_by) values(p_request,p_customer,result.total_cents,'pos',p_method,result.reference,auth.uid());
 perform spa_private.audit('order.paid',result.id::text,jsonb_build_object('reference',result.reference,'total_cents',result.total_cents,'items',jsonb_array_length(p_items))); return to_jsonb(result);
end $$;

create or replace function public.spa_payroll_preview(p_from date,p_to date,p_rule uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare version public.spa_payroll_rule_versions;
begin
 perform spa_private.require_permission('payroll.view');
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 if p_rule is null then select * into version from public.spa_payroll_rule_versions where status='active' and effective_from<=p_to order by effective_from desc,version_no desc limit 1;
 else select * into version from public.spa_payroll_rule_versions where id=p_rule; end if;
 if version.id is null then raise exception 'PAYROLL_RULE_REQUIRED'; end if;
 return coalesce((
 with staff_metrics as (
  select s.id,s.name,j.name title,e.name employment_type,s.employment_type_code,s.employment_status,s.departed_on,
   coalesce(cp.pay_basis,'monthly') pay_basis,coalesce(cp.base_pay_cents,0) base_pay_cents,coalesce(cp.service_commission_bps,0) service_commission_bps,
   coalesce(cp.product_commission_bps,0) product_commission_bps,coalesce(cp.designated_client_bonus_cents,0) designated_rate_cents,
   coalesce((select sum(greatest(0,(extract(epoch from te.ended_at-te.started_at)/60)::int-te.break_minutes)) from public.spa_time_entries te where te.staff_id=s.id and te.work_date between p_from and p_to and te.status='approved'),0)::bigint work_minutes,
   (coalesce((select count(*) from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint completed_count,
   (coalesce((select count(*) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint service_count,
   coalesce((select count(*) from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed' and not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id)),0)::bigint unsettled_completed_count,
   coalesce((select count(*) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is not null where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint refunded_service_count,
   (coalesce((select sum(a.duration_minutes_snapshot) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)+coalesce((select sum(oi.quantity*svc.duration_minutes) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id join public.spa_services svc on svc.id=oi.service_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint service_minutes,
   (coalesce((select sum(ch.revenue_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed' and ch.refunded_at is null),0)+coalesce((select sum(oi.line_total_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint service_sales_cents,
   (coalesce((select sum(ch.commission_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed' and ch.refunded_at is null),0)+coalesce((select sum(oi.commission_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0))::bigint checkout_commission_cents,
   coalesce((select count(distinct o.id) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0)::bigint product_order_count,
   coalesce((select sum(oi.line_total_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0)::bigint product_sales_cents,
   coalesce((select sum(oi.commission_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0)::bigint checkout_product_commission_cents,
   coalesce((select count(*) from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=s.id and c.preferred_staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint designated_clients,
   coalesce((select sum(case when pa.kind='designated_bonus' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint manual_designated_bonus_cents,
   coalesce((select sum(case when pa.kind='bonus' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint bonus_cents,
   coalesce((select sum(case when pa.kind='allowance' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint allowance_cents,
   coalesce((select sum(case when pa.kind='deduction' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint deduction_cents,
   coalesce((select sum(o.minutes) from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved'),0)::bigint overtime_minutes,
   coalesce((select count(*) from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved'),0)::bigint overtime_occurrences,
   coalesce((select sum(o.minutes) from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date>=date_trunc('quarter',p_to::timestamp)::date and o.work_date<=p_to and o.status='approved'),0)::bigint quarter_overtime_minutes,
   exists(select 1 from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved' and o.overtime_type='weekday' and o.minutes>240) daily_limit_exceeded
  from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id join public.spa_employment_types e on e.code=s.employment_type_code
  left join public.spa_compensation_profiles cp on cp.job_title_id=s.job_title_id and cp.employment_type_code=s.employment_type_code and cp.active
  where coalesce(s.hire_date,s.created_at::date)<=p_to and ((s.employment_status='active' and s.active and s.archived_at is null)
   or (s.employment_status='departed' and s.departed_on is not null and s.departed_on>=p_from)
   or exists(select 1 from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to)
   or exists(select 1 from public.spa_time_entries te where te.staff_id=s.id and te.work_date between p_from and p_to and te.status='approved')
   or exists(select 1 from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved')
   or exists(select 1 from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to)
   or exists(select 1 from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from))
 ), commission as (
  select m.*,coalesce((select round(m.service_sales_cents*t.rate_bps/10000.0)::bigint from public.spa_payroll_commission_tiers t where t.rule_version_id=version.id and t.metric in ('service_minutes','service_count','service_sales_cents') and ((t.metric='service_minutes' and m.service_minutes>=t.threshold_from and (t.threshold_to is null or m.service_minutes<t.threshold_to)) or (t.metric='service_count' and m.service_count>=t.threshold_from and (t.threshold_to is null or m.service_count<t.threshold_to)) or (t.metric='service_sales_cents' and m.service_sales_cents>=t.threshold_from and (t.threshold_to is null or m.service_sales_cents<t.threshold_to))) order by t.threshold_from desc limit 1),m.checkout_commission_cents) calculated_service_commission_cents,
   coalesce((select round(m.product_sales_cents*t.rate_bps/10000.0)::bigint from public.spa_payroll_commission_tiers t where t.rule_version_id=version.id and t.metric='product_sales_cents' and m.product_sales_cents>=t.threshold_from and (t.threshold_to is null or m.product_sales_cents<t.threshold_to) order by t.threshold_from desc limit 1),m.checkout_product_commission_cents) calculated_product_commission_cents
  from staff_metrics m
 ), base_calc as (
  select c.*,c.designated_clients*c.designated_rate_cents+c.manual_designated_bonus_cents designated_bonus_cents,
   case when c.pay_basis='monthly' then c.base_pay_cents when c.pay_basis='hourly' then round(c.base_pay_cents*c.work_minutes/60.0)::bigint else c.base_pay_cents*c.service_count end base_cents from commission c
 ), overtime_calc as (
  select b.*,coalesce((select round(sum((case when b.pay_basis='monthly' then (b.base_pay_cents+case when version.include_regular_commission then b.calculated_service_commission_cents+b.calculated_product_commission_cents+b.designated_bonus_cents else 0 end)/version.hourly_divisor::numeric when b.pay_basis='hourly' then b.base_pay_cents::numeric else 0 end)*greatest(0,least(o.minutes,r.end_minute)-r.start_minute)/60.0*r.multiplier_bps/10000.0))::bigint from public.spa_overtime_entries o join public.spa_payroll_overtime_rates r on r.rule_version_id=version.id and r.employment_type_code=b.employment_type_code and r.overtime_type=o.overtime_type where o.staff_id=b.id and o.work_date between p_from and p_to and o.status='approved' and o.minutes>r.start_minute),0) overtime_cents from base_calc b
 )
 select jsonb_agg(jsonb_build_object('staff_id',id,'employee',name,'role',title,'employment_type',employment_type,'employment_type_code',employment_type_code,'employment_status',employment_status,'departed_on',departed_on,
  'pay_basis',pay_basis,'base_pay_rate_cents',base_pay_cents,'commission_bps',service_commission_bps,'service_commission_bps',service_commission_bps,'product_commission_bps',product_commission_bps,'designated_rate_cents',designated_rate_cents,
  'work_minutes',work_minutes,'completed_count',completed_count,'service_count',service_count,'unsettled_completed_count',unsettled_completed_count,'refunded_service_count',refunded_service_count,'service_minutes',service_minutes,'service_sales_cents',service_sales_cents,
  'product_order_count',product_order_count,'product_sales_cents',product_sales_cents,'designated_clients',designated_clients,'overtime_occurrences',overtime_occurrences,'overtime_minutes',overtime_minutes,'quarter_overtime_minutes',quarter_overtime_minutes,
  'base_cents',base_cents,'service_commission_cents',calculated_service_commission_cents,'product_commission_cents',calculated_product_commission_cents,'designated_bonus_cents',designated_bonus_cents,'overtime_cents',overtime_cents,
  'bonus_cents',bonus_cents,'allowance_cents',allowance_cents,'deduction_cents',deduction_cents,'total_cents',greatest(0,base_cents+calculated_service_commission_cents+calculated_product_commission_cents+designated_bonus_cents+overtime_cents+bonus_cents+allowance_cents-deduction_cents),
  'overtime_warning',case when quarter_overtime_minutes>version.quarterly_overtime_limit_minutes then '超過季度加班上限' when overtime_minutes>version.agreed_monthly_limit_minutes then '超過勞資會議同意月上限' when overtime_minutes>version.monthly_overtime_limit_minutes then '超過一般月上限，需勞資會議同意' when daily_limit_exceeded then '平日單日延長工時超過 4 小時' else '' end,
  'calculation',jsonb_build_object('rule_version',version.version_no,'hourly_divisor',version.hourly_divisor,'include_regular_commission',version.include_regular_commission,'compensation_source','job_title_and_employment_type','service_basis','completed_and_settled','attribution_source','actual_staff')) order by name) from overtime_calc),'[]');
end $$;

create or replace function public.spa_payroll_admin(p_from date,p_to date,p_rule uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.view');
 return jsonb_build_object(
  'staff',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('job_title_name',j.name,'employment_type_name',e.name) order by s.display_order,s.name) from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id join public.spa_employment_types e on e.code=s.employment_type_code),'[]'),
  'job_titles',coalesce((select jsonb_agg(to_jsonb(j) order by display_order) from public.spa_job_titles j where j.active),'[]'),
  'employment_types',coalesce((select jsonb_agg(to_jsonb(e) order by display_order) from public.spa_employment_types e where e.active),'[]'),
  'compensation_profiles',coalesce((select jsonb_agg(to_jsonb(c)||jsonb_build_object('job_title_name',j.name,'employment_type_name',e.name) order by j.display_order,e.display_order) from public.spa_compensation_profiles c join public.spa_job_titles j on j.id=c.job_title_id join public.spa_employment_types e on e.code=c.employment_type_code),'[]'),
  'rules',coalesce((select jsonb_agg(to_jsonb(v) order by version_no desc) from public.spa_payroll_rule_versions v),'[]'),
  'rates',coalesce((select jsonb_agg(to_jsonb(r) order by overtime_type,employment_type_code,start_minute) from public.spa_payroll_overtime_rates r),'[]'),
  'tiers',coalesce((select jsonb_agg(to_jsonb(t) order by metric,threshold_from) from public.spa_payroll_commission_tiers t),'[]'),
  'overtime',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('employee',s.name) order by work_date desc) from public.spa_overtime_entries o join public.spa_staff s on s.id=o.staff_id where o.work_date between p_from and p_to),'[]'),
  'adjustments',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('employee',s.name) order by a.created_at desc) from public.spa_payroll_adjustments a join public.spa_staff s on s.id=a.staff_id where a.period_start=p_from),'[]'),
  'runs',coalesce((select jsonb_agg(to_jsonb(r) order by period_start desc) from public.spa_payroll_runs r limit 24),'[]'),
  'preview',public.spa_payroll_preview(p_from,p_to,p_rule));
end $$;

create or replace function public.spa_payroll_staff_detail(p_staff uuid,p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.view');
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 if not exists(select 1 from public.spa_staff where id=p_staff) then raise exception 'NOT_FOUND'; end if;
 return jsonb_build_object(
  'profile',(select to_jsonb(s)||jsonb_build_object('job_title_name',j.name,'employment_type_name',e.name) from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id join public.spa_employment_types e on e.code=s.employment_type_code where s.id=p_staff),
  'services',coalesce((select jsonb_agg(to_jsonb(x) order by x.business_date,x.starts_at) from (select a.id,a.reference,a.business_date,a.starts_at,a.service_name_snapshot service_name,a.duration_minutes_snapshot service_minutes,case when ch.id is null then 'unsettled' when ch.refunded_at is not null then 'refunded' else 'settled' end settlement_status,ch.revenue_cents,ch.commission_cents,(select count(*) from public.spa_reviews r where r.appointment_id=a.id) review_count from public.spa_appointments a left join public.spa_checkouts ch on ch.appointment_id=a.id where a.staff_id=p_staff and a.business_date between p_from and p_to and a.status='completed') x),'[]'),
  'pos_services',coalesce((select jsonb_agg(to_jsonb(x) order by x.paid_at) from (select o.id,o.reference,o.paid_at,oi.name_snapshot,oi.quantity,oi.line_total_cents,oi.commission_cents from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=p_staff and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to) x),'[]'),
  'product_orders',coalesce((select jsonb_agg(to_jsonb(x) order by x.paid_at) from (select o.id,o.reference,o.paid_at,oi.name_snapshot,oi.quantity,oi.line_total_cents,oi.commission_cents from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=p_staff and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to) x),'[]'),
  'overtime',coalesce((select jsonb_agg(to_jsonb(o) order by work_date) from public.spa_overtime_entries o where o.staff_id=p_staff and o.work_date between p_from and p_to and o.status='approved'),'[]'),
  'adjustments',coalesce((select jsonb_agg(to_jsonb(a) order by created_at) from public.spa_payroll_adjustments a where a.staff_id=p_staff and a.period_start=p_from),'[]'));
end $$;

create or replace function public.spa_staff_self(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare person uuid;
begin
 perform spa_private.require_team();
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 select staff_id into person from public.spa_roles where user_id=auth.uid() and active;
 if person is null then return jsonb_build_object('profile',null); end if;
 return jsonb_build_object(
 'profile',(select jsonb_build_object('id',s.id,'name',s.name,'title',j.name,'employment_type',e.name,'pay_basis',c.pay_basis,'base_pay_cents',c.base_pay_cents,'commission_bps',c.service_commission_bps,'product_commission_bps',c.product_commission_bps,'designated_client_bonus_cents',c.designated_client_bonus_cents,'active',s.active) from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id join public.spa_employment_types e on e.code=s.employment_type_code left join public.spa_compensation_profiles c on c.job_title_id=s.job_title_id and c.employment_type_code=s.employment_type_code where s.id=person),
 'lifetime_completed',(select count(*) from public.spa_appointments where staff_id=person and status='completed')+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=person and oi.item_type='service' and o.status='paid'),0),
 'metrics',jsonb_build_object(
  'completed',(select count(*) from public.spa_appointments where staff_id=person and status='completed' and business_date between p_from and p_to)+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=person and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0),
  'settled_completed',(select count(*) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=person and a.status='completed' and a.business_date between p_from and p_to)+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=person and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0),
  'unsettled_completed',(select count(*) from public.spa_appointments a where a.staff_id=person and a.status='completed' and a.business_date between p_from and p_to and not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id)),
  'minutes',coalesce((select sum(a.duration_minutes_snapshot) from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null where a.staff_id=person and a.status='completed' and a.business_date between p_from and p_to),0)+coalesce((select sum(oi.quantity*s.duration_minutes) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id join public.spa_services s on s.id=oi.service_id where oi.staff_id=person and oi.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0),
  'commission_cents',coalesce((select sum(ch.commission_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=person and a.business_date between p_from and p_to and a.status='completed' and ch.refunded_at is null),0)+coalesce((select sum(oi.commission_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=person and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0),
  'rating',(select round(avg(r.rating),2) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where a.staff_id=person and a.business_date between p_from and p_to),'reviews',(select count(*) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where a.staff_id=person and a.business_date between p_from and p_to)),
 'reviews',coalesce((select jsonb_agg(to_jsonb(x)) from (select r.rating,r.comment,r.reply,r.status,r.created_at,a.reference,a.service_name from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where a.staff_id=person and a.business_date between p_from and p_to order by r.created_at desc limit 100) x),'[]'),
 'shifts',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_shifts s where s.staff_id=person),'[]'),'daily_shifts',coalesce((select jsonb_agg(to_jsonb(d) order by business_date) from public.spa_daily_shifts d where d.staff_id=person and d.business_date between p_from and p_to),'[]'),'time_off',coalesce((select jsonb_agg(to_jsonb(t) order by starts_at) from public.spa_time_off t where t.staff_id=person and t.ends_at>now()-interval '7 days'),'[]'));
end $$;

create or replace function public.spa_report(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare first_time timestamptz; last_time timestamptz;
begin
 perform spa_private.require_permission('reports.view'); if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 first_time:=p_from::timestamp at time zone 'Asia/Taipei';last_time:=(p_to+1)::timestamp at time zone 'Asia/Taipei';
 return jsonb_build_object(
 'bookings',(select count(*) from public.spa_appointments where business_date between p_from and p_to),'completed',(select count(*) from public.spa_appointments where business_date between p_from and p_to and status='completed'),'cancelled',(select count(*) from public.spa_appointments where business_date between p_from and p_to and status='cancelled'),'no_show',(select count(*) from public.spa_appointments where business_date between p_from and p_to and status='no_show'),
 'service_revenue_cents',coalesce((select sum(revenue_cents) from public.spa_checkouts where created_at>=first_time and created_at<last_time),0)-coalesce((select sum(revenue_cents) from public.spa_checkouts where refunded_at>=first_time and refunded_at<last_time),0),
 'pos_revenue_cents',coalesce((select sum(total_cents) from public.spa_orders where status='paid' and paid_at>=first_time and paid_at<last_time),0),
 'revenue_cents',coalesce((select sum(revenue_cents) from public.spa_checkouts where created_at>=first_time and created_at<last_time),0)-coalesce((select sum(revenue_cents) from public.spa_checkouts where refunded_at>=first_time and refunded_at<last_time),0)+coalesce((select sum(total_cents) from public.spa_orders where status='paid' and paid_at>=first_time and paid_at<last_time),0),
 'cash_in_cents',coalesce((select sum(amount_cents) from public.spa_cash_entries where created_at>=first_time and created_at<last_time and amount_cents>0),0),'cash_out_cents',coalesce((select -sum(amount_cents) from public.spa_cash_entries where created_at>=first_time and created_at<last_time and amount_cents<0),0),'expenses_cents',coalesce((select -sum(amount_cents) from public.spa_cash_entries where created_at>=first_time and created_at<last_time and category='expense'),0),
 'wallet_liability_cents',coalesce((select sum(amount_cents) from public.spa_wallet_entries),0),'package_liability_cents',coalesce((select sum(p.paid_cents-coalesce((select sum(ch.revenue_cents-a.tea_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where ch.package_id=p.id and ch.refunded_at is null),0)) from public.spa_packages p),0),
 'cash_entries',coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc) from public.spa_cash_entries e where e.created_at>=first_time and e.created_at<last_time),'[]'),'daily',coalesce((select jsonb_agg(to_jsonb(d) order by d.date) from (select (e.created_at at time zone 'Asia/Taipei')::date date,sum(e.amount_cents) net_cents from public.spa_cash_entries e where e.created_at>=first_time and e.created_at<last_time group by 1) d),'[]'),
 'staff',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'job_title_name',j.name,
  'completed',(select count(*) from public.spa_appointments where staff_id=s.id and business_date between p_from and p_to and status='completed')+coalesce((select sum(oi.quantity) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and o.paid_at>=first_time and o.paid_at<last_time),0),
  'minutes',(select coalesce(sum(duration_minutes_snapshot),0) from public.spa_appointments where staff_id=s.id and business_date between p_from and p_to and status='completed')+coalesce((select sum(oi.quantity*svc.duration_minutes) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id join public.spa_services svc on svc.id=oi.service_id where oi.staff_id=s.id and oi.item_type='service' and o.status='paid' and o.paid_at>=first_time and o.paid_at<last_time),0),
  'revenue_cents',(select coalesce(sum(ch.revenue_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.created_at>=first_time and ch.created_at<last_time)-(select coalesce(sum(ch.revenue_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.refunded_at>=first_time and ch.refunded_at<last_time)+coalesce((select sum(oi.line_total_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and o.status='paid' and o.paid_at>=first_time and o.paid_at<last_time),0),
  'commission_cents',(select coalesce(sum(ch.commission_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.created_at>=first_time and ch.created_at<last_time)-(select coalesce(sum(ch.commission_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.refunded_at>=first_time and ch.refunded_at<last_time)+coalesce((select sum(oi.commission_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and o.status='paid' and o.paid_at>=first_time and o.paid_at<last_time),0),
  'rating',(select round(avg(rv.rating),2) from public.spa_reviews rv join public.spa_appointments a on a.id=rv.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to),'reviews',(select count(*) from public.spa_reviews rv join public.spa_appointments a on a.id=rv.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to)) order by s.display_order)
  from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.active and s.employment_status='active' and s.archived_at is null),'[]'),
 'audit',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc) from (select * from public.spa_audit where created_at>=first_time and created_at<last_time order by created_at desc limit 200) a),'[]'));
end $$;

revoke all on function public.spa_compensation_profile_save(uuid,text,text,bigint,int,int,bigint,boolean) from public,anon,authenticated;
grant execute on function public.spa_compensation_profile_save(uuid,text,text,bigint,int,int,bigint,boolean) to authenticated,service_role;
revoke all on function public.spa_catalog_delete(text,uuid,text) from public,anon,authenticated;
grant execute on function public.spa_catalog_delete(text,uuid,text) to authenticated,service_role;
revoke all on function public.spa_pos_checkout(uuid,uuid,jsonb,bigint,text,text) from public,anon,authenticated;
grant execute on function public.spa_pos_checkout(uuid,uuid,jsonb,bigint,text,text) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
