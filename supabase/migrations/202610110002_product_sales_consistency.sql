begin;

-- Serialize the schema/backfill step with every financial write path. The two
-- payroll guards are removed only while adding deterministic metadata: existing
-- finalized wage facts and their saved packets are never recalculated here.
select pg_advisory_xact_lock(726001);
select pg_advisory_xact_lock(726005);
select pg_advisory_xact_lock(726006);
select pg_advisory_xact_lock(726099);

-- A product has one public publication state. The two legacy columns remain
-- for compatibility with the public catalogue, but every supported write now
-- keeps them identical. Preserve the effective outcome when old rows disagree:
-- the catalogue already required both flags, so ambiguity stays hidden instead
-- of accidentally publishing a product intended only for in-store POS sales.
update public.spa_products
set website_visible=false,store_visible=false,updated_at=now()
where website_visible is distinct from store_visible;
update public.spa_products
set website_visible=false,store_visible=false,updated_at=now()
where status<>'active' and (website_visible or store_visible);

create or replace function public.spa_product_save(p_payload jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid:=nullif(p_payload->>'id','')::uuid; old jsonb; category uuid:=nullif(p_payload->>'category_id','')::uuid; available boolean;
 state text; public_visible boolean;
begin
 perform spa_private.require_permission('catalog.manage');
 perform pg_advisory_xact_lock(hashtext('spa-product-category-maintenance'));
 if jsonb_typeof(p_payload) is distinct from 'object'
  or length(btrim(coalesce(p_payload->>'name',''))) not between 1 and 120
  or length(btrim(coalesce(p_payload->>'sku',''))) not between 1 and 80
  or coalesce((p_payload->>'price_cents')::bigint,-1)<0 then raise exception 'INVALID_INPUT'; end if;
 select to_jsonb(p) into old from public.spa_products p where p.id=result for update;
 if result is not null and not found then raise exception 'NOT_FOUND'; end if;
 state:=coalesce(nullif(p_payload->>'status',''),old->>'status','draft');
 if state not in ('draft','active','archived') then raise exception 'INVALID_INPUT'; end if;
 if category is null then
  category:=nullif(old->>'category_id','')::uuid;
  if category is null then
   insert into public.spa_product_categories(code,name,name_en,display_order)
   values('uncategorized','未分類','Uncategorized',900) on conflict(code) do nothing;
   select id into category from public.spa_product_categories where code='uncategorized';
  end if;
 end if;
 select active and archived_at is null into available from public.spa_product_categories where id=category;
 if not found then raise exception 'PRODUCT_CATEGORY_UNAVAILABLE'; end if;
 if not available and (result is null or category is distinct from nullif(old->>'category_id','')::uuid)
 then raise exception 'PRODUCT_CATEGORY_UNAVAILABLE'; end if;
 public_visible:=case
  when state<>'active' then false
  when p_payload ? 'public_visible' then coalesce((p_payload->>'public_visible')::boolean,false)
  else coalesce((p_payload->>'website_visible')::boolean,coalesce((old->>'website_visible')::boolean,false))
   and coalesce((p_payload->>'store_visible')::boolean,coalesce((old->>'store_visible')::boolean,false))
 end;
	 if public_visible and not available then raise exception 'PRODUCT_CATEGORY_UNAVAILABLE'; end if;
 if result is null then
  insert into public.spa_products(sku,category_id,name,name_en,description,description_en,image_url,price_cents,compare_price_cents,cost_cents,barcode,unit_label,unit_label_en,low_stock_threshold,status,website_visible,store_visible,display_order)
  values(upper(btrim(p_payload->>'sku')),category,btrim(p_payload->>'name'),coalesce(p_payload->>'name_en',''),coalesce(p_payload->>'description',''),coalesce(p_payload->>'description_en',''),coalesce(p_payload->>'image_url',''),(p_payload->>'price_cents')::bigint,nullif(p_payload->>'compare_price_cents','')::bigint,nullif(p_payload->>'cost_cents','')::bigint,coalesce(p_payload->>'barcode',''),coalesce(p_payload->>'unit_label',''),coalesce(p_payload->>'unit_label_en',''),coalesce((p_payload->>'low_stock_threshold')::int,2),state,public_visible,public_visible,coalesce((p_payload->>'display_order')::int,0)) returning id into result;
 else
  update public.spa_products set sku=upper(btrim(p_payload->>'sku')),category_id=category,name=btrim(p_payload->>'name'),name_en=coalesce(p_payload->>'name_en',''),description=coalesce(p_payload->>'description',''),description_en=coalesce(p_payload->>'description_en',''),image_url=coalesce(p_payload->>'image_url',''),price_cents=(p_payload->>'price_cents')::bigint,
   compare_price_cents=nullif(p_payload->>'compare_price_cents','')::bigint,cost_cents=nullif(p_payload->>'cost_cents','')::bigint,barcode=coalesce(p_payload->>'barcode',''),unit_label=coalesce(p_payload->>'unit_label',''),unit_label_en=coalesce(p_payload->>'unit_label_en',''),low_stock_threshold=coalesce((p_payload->>'low_stock_threshold')::int,low_stock_threshold),status=state,website_visible=public_visible,store_visible=public_visible,display_order=coalesce((p_payload->>'display_order')::int,display_order),updated_at=now() where id=result;
 end if;
 perform spa_private.audit('product.saved',result::text,jsonb_build_object('old',old,'new',p_payload||jsonb_build_object('category_id',category,'public_visible',public_visible)));
 return result;
end $$;

-- POS and manual stock corrections lock the same product row before reading
-- the inventory ledger. The operation id also makes an unknown network result
-- safe to retry without adding or removing stock twice.
alter table public.spa_inventory_entries add column if not exists request_id uuid;
create unique index if not exists spa_inventory_entries_request on public.spa_inventory_entries(request_id) where request_id is not null;
create or replace function public.spa_inventory_adjust(p_request uuid,p_product uuid,p_delta int,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare current_qty bigint; locked_product uuid; prior public.spa_inventory_entries; normalized_reason text:=btrim(coalesce(p_reason,''));
begin
 perform spa_private.require_permission('catalog.manage');
 if p_request is null or p_delta is null or p_delta=0 or length(normalized_reason)=0 then raise exception 'INVALID_INPUT'; end if;
 select * into prior from public.spa_inventory_entries where request_id=p_request;
 if found then
  if prior.product_id is distinct from p_product or prior.delta is distinct from p_delta or prior.reason is distinct from normalized_reason or prior.reference_type<>'adjustment' then raise exception 'REQUEST_CONFLICT'; end if;
  return;
 end if;
 select id into locked_product from public.spa_products where id=p_product for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 select * into prior from public.spa_inventory_entries where request_id=p_request;
 if found then
  if prior.product_id is distinct from p_product or prior.delta is distinct from p_delta or prior.reason is distinct from normalized_reason or prior.reference_type<>'adjustment' then raise exception 'REQUEST_CONFLICT'; end if;
  return;
 end if;
 select coalesce(sum(delta),0) into current_qty from public.spa_inventory_entries where product_id=p_product;
 if current_qty+p_delta<0 then raise exception 'INSUFFICIENT_INVENTORY'; end if;
 insert into public.spa_inventory_entries(product_id,delta,reason,request_id,created_by) values(p_product,p_delta,normalized_reason,p_request,auth.uid());
 perform spa_private.audit('inventory.adjusted',p_product::text,jsonb_build_object('request_id',p_request,'delta',p_delta,'reason',normalized_reason));
end $$;

-- Persist the cart order so proportional discount rounding is deterministic.
-- Existing rows retain their already-used UUID order; future rows receive the
-- JSON/cart insertion order in the sale snapshot trigger.
drop trigger if exists spa_payroll_order_item_guard on public.spa_order_items;
alter table public.spa_order_items
 add column if not exists line_position int,
 add column if not exists commission_rule_version_id uuid references public.spa_payroll_rule_versions;
with ranked as (
 select id,row_number() over(partition by order_id order by id)::int position
 from public.spa_order_items
) update public.spa_order_items i set line_position=r.position from ranked r where r.id=i.id and i.line_position is null;
alter table public.spa_order_items alter column line_position set not null;
alter table public.spa_order_items drop constraint if exists spa_order_items_line_position_check;
alter table public.spa_order_items add constraint spa_order_items_line_position_check check(line_position>0);
create unique index if not exists spa_order_items_order_position on public.spa_order_items(order_id,line_position);
update public.spa_order_items i set commission_rule_version_id=(
 select v.id from public.spa_orders o join public.spa_payroll_rule_versions v
  on v.status in ('active','archived') and v.effective_from<=(coalesce(o.paid_at,o.created_at) at time zone 'Asia/Taipei')::date
 where o.id=i.order_id order by v.effective_from desc,v.version_no desc limit 1
) where i.commission_rule_version_id is null;
create trigger spa_payroll_order_item_guard before insert or update or delete on public.spa_order_items
for each row execute function spa_private.payroll_input_guard();

-- The formal ordered-v2 engine uses the same persisted cart order as the
-- discount allocator. Keep helper sort columns out of the returned JSON so
-- saved source-packet and UI contracts remain unchanged.
create or replace function spa_private.payroll_ordered_commissions(p_staff uuid,p_from date,p_to date,p_rule uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare profile public.spa_payroll_version_profiles; title public.spa_job_titles; chosen_metric text; units jsonb; result jsonb:='[]'; item jsonb; segments jsonb; unit_metric bigint; before_metric bigint; after_metric bigint; income bigint; amount bigint; designated bigint; eligible boolean; attendance bigint; service_minutes bigint; month_key text; month_metrics jsonb:='{}'; month_service_metrics jsonb:='{}'; before_service_minutes bigint; after_service_minutes bigint; month_facts jsonb; lifetime_count bigint:=0; contract_start date; band record; lo bigint; hi bigint; net_segment bigint;
begin
 select j.* into title from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id where s.id=p_staff;
 select p.* into profile from public.spa_payroll_version_profiles p join public.spa_staff s on s.job_title_id=p.job_title_id and s.employment_type_code=p.employment_type_code where p.rule_version_id=p_rule and s.id=p_staff;
 if profile.job_title_id is null then return result; end if;
 select contract_started_on into contract_start from public.spa_staff where id=p_staff;
 if profile.employment_type_code='contractor' and contract_start is null then return result; end if;
 select metric into chosen_metric from public.spa_payroll_commission_tiers where rule_version_id=p_rule and job_title_id=profile.job_title_id and employment_type_code=profile.employment_type_code and metric in ('service_minutes','service_count','service_sales_cents') order by case metric when 'service_minutes' then 1 when 'service_count' then 2 else 3 end limit 1;
 chosen_metric:=coalesce(chosen_metric,'service_minutes');
 select coalesce(jsonb_agg((to_jsonb(q)-'source_order_id'-'line_position') order by event_time,source_kind,source_order_id,line_position,unit_index,source_id),'[]') into units from (
  select 'appointment'::text source_kind,a.id source_id,a.id source_order_id,0 line_position,a.reference,a.business_date date,a.starts_at event_time,1 unit_index,1 quantity,a.duration_minutes_snapshot duration_minutes,
   greatest(0,ch.revenue_cents-a.tea_cents)::bigint net_cents,ch.designated_client_snapshot designated,ch.self_sourced_client_snapshot self_sourced
  from public.spa_appointments a join public.spa_checkouts ch on ch.appointment_id=a.id and ch.refunded_at is null
  where a.staff_id=p_staff and a.status='completed' and a.business_date<=p_to
   and (profile.employment_type_code<>'contractor' or a.business_date>=contract_start)
   and (profile.contractor_count_scope='lifetime' or a.business_date>=date_trunc('month',p_from::timestamp)::date)
  union all
  select 'pos_service',i.id,o.id,i.line_position,o.reference,(o.paid_at at time zone 'Asia/Taipei')::date,o.paid_at,n,1,i.duration_minutes_snapshot,
   (floor(i.net_total_cents*n::numeric/i.quantity)-floor(i.net_total_cents*(n-1)::numeric/i.quantity))::bigint,i.designated_client_snapshot,i.self_sourced_client_snapshot
  from public.spa_order_items i join public.spa_orders o on o.id=i.order_id cross join lateral generate_series(1,i.quantity)n
  where i.staff_id=p_staff and i.item_type='service' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date<=p_to
   and (profile.employment_type_code<>'contractor' or (o.paid_at at time zone 'Asia/Taipei')::date>=contract_start)
   and (profile.contractor_count_scope='lifetime' or (o.paid_at at time zone 'Asia/Taipei')::date>=date_trunc('month',p_from::timestamp)::date)
 )q;
 select coalesce(jsonb_object_agg(month_label,jsonb_build_object('service_minutes',minutes,'work_minutes',
  (select coalesce(sum(greatest(0,floor(extract(epoch from ended_at-started_at)/60)::int-break_minutes)),0) from public.spa_time_entries where staff_id=p_staff and status='approved' and work_date<=p_to and substring(work_date::text from 1 for 7)=m.month_label))),'{}') into month_facts
 from (select substring(x->>'date' from 1 for 7) as month_label,sum((x->>'duration_minutes')::bigint)minutes from jsonb_array_elements(units)x group by 1)m;
 for item in select value from jsonb_array_elements(units) loop
  month_key:=substring(item->>'date' from 1 for 7); income:=(item->>'net_cents')::bigint;
  unit_metric:=case chosen_metric when 'service_count' then 1 when 'service_sales_cents' then income else (item->>'duration_minutes')::bigint end;
  before_metric:=case when chosen_metric='service_count' and profile.contractor_count_scope='lifetime' then lifetime_count else coalesce((month_metrics->>month_key)::bigint,0) end;
  after_metric:=before_metric+unit_metric;
  month_metrics:=jsonb_set(month_metrics,array[month_key],to_jsonb(after_metric),true); lifetime_count:=lifetime_count+1;
  before_service_minutes:=coalesce((month_service_metrics->>month_key)::bigint,0); after_service_minutes:=before_service_minutes+(item->>'duration_minutes')::bigint;
  month_service_metrics:=jsonb_set(month_service_metrics,array[month_key],to_jsonb(after_service_minutes),true);
  if (item->>'date')::date not between p_from and p_to then continue; end if;
  attendance:=coalesce((month_facts->month_key->>'work_minutes')::bigint,0); service_minutes:=coalesce((month_facts->month_key->>'service_minutes')::bigint,0);
  eligible:=title.work_category='technician' and not title.legacy and profile.active and profile.service_policy_status='confirmed' and attendance>=profile.minimum_attendance_minutes and case when profile.employment_type_code='part_time' then service_minutes>profile.minimum_service_minutes else service_minutes>=profile.minimum_service_minutes end;
  amount:=0; designated:=0; segments:='[]';
  if eligible then
   if (item->>'self_sourced')::boolean and profile.employment_type_code='contractor' then
    amount:=round(income*profile.self_sourced_commission_bps/10000.0)::bigint;
    segments:=jsonb_build_array(jsonb_build_object('basis','self_sourced','net_cents',income,'rate_bps',profile.self_sourced_commission_bps,'commission_cents',amount));
   elsif profile.service_commission_mode='flat' then
    if after_service_minutes>before_service_minutes then
     lo:=least(after_service_minutes,greatest(before_service_minutes,profile.commission_start_service_minutes));
     net_segment:=income-floor(income*(lo-before_service_minutes)::numeric/(after_service_minutes-before_service_minutes))::bigint;
     amount:=round(net_segment*profile.service_commission_bps/10000.0)::bigint;
     if lo>before_service_minutes then segments:=jsonb_build_array(jsonb_build_object('basis','flat_salary_covered','metric','service_minutes','from',before_service_minutes,'to',lo,'net_cents',income-net_segment,'rate_bps',0,'commission_cents',0)); end if;
     if after_service_minutes>lo then segments:=segments||jsonb_build_array(jsonb_build_object('basis','flat','metric','service_minutes','from',lo,'to',after_service_minutes,'net_cents',net_segment,'rate_bps',profile.service_commission_bps,'commission_cents',amount)); end if;
    end if;
   elsif profile.service_commission_mode='ordered_tiers' and unit_metric>0 then
    for band in select * from public.spa_payroll_commission_tiers where rule_version_id=p_rule and job_title_id=profile.job_title_id and employment_type_code=profile.employment_type_code and metric=chosen_metric and calculation_mode='progressive' and threshold_from<after_metric and coalesce(threshold_to,after_metric)>before_metric order by threshold_from,id loop
     lo:=greatest(before_metric,band.threshold_from); hi:=least(after_metric,coalesce(band.threshold_to,after_metric));
     net_segment:=(floor(income*(hi-before_metric)::numeric/unit_metric)-floor(income*(lo-before_metric)::numeric/unit_metric))::bigint;
     amount:=amount+round(net_segment*band.rate_bps/10000.0)::bigint;
     segments:=segments||jsonb_build_array(jsonb_build_object('tier_id',band.id,'metric',chosen_metric,'from',lo,'to',hi,'net_cents',net_segment,'rate_bps',band.rate_bps,'commission_cents',round(net_segment*band.rate_bps/10000.0)::bigint));
    end loop;
    if not exists(select 1 from public.spa_payroll_commission_tiers where rule_version_id=p_rule and job_title_id=profile.job_title_id and employment_type_code=profile.employment_type_code and metric=chosen_metric) and after_metric>profile.commission_start_service_minutes then
     net_segment:=(income-floor(income*greatest(0,profile.commission_start_service_minutes-before_metric)::numeric/unit_metric))::bigint;
     amount:=round(net_segment*profile.service_commission_bps/10000.0)::bigint;
     segments:=jsonb_build_array(jsonb_build_object('basis','fallback','net_cents',net_segment,'rate_bps',profile.service_commission_bps,'commission_cents',amount));
    end if;
   end if;
   if (item->>'designated')::boolean and not ((item->>'self_sourced')::boolean and profile.employment_type_code='contractor') then designated:=round(income*profile.designated_client_bonus_bps/10000.0)::bigint; end if;
  end if;
  result:=result||jsonb_build_array(item||jsonb_build_object('metric',chosen_metric,'metric_from',before_metric,'metric_to',after_metric,'service_minutes_from',before_service_minutes,'service_minutes_to',after_service_minutes,'eligible',eligible,'qualification_work_minutes',attendance,'qualification_service_minutes',service_minutes,'service_commission_cents',amount,'designated_bonus_cents',designated,'commission_segments',segments));
 end loop;
 return result;
end $$;

-- New transactions use the versioned job-title rule effective on the business
-- date. Legacy compensation remains the fallback for old/legacy role records.
create or replace function spa_private.sale_commission_rate(p_staff uuid,p_kind text,p_on date,p_self_sourced boolean default false,p_rule uuid default null) returns int
language plpgsql stable security definer set search_path='' as $$
declare version public.spa_payroll_rule_versions; staff public.spa_staff; profile public.spa_payroll_version_profiles; rate int;
begin
 if p_staff is null or p_on is null or p_kind not in ('service','product') then raise exception 'INVALID_INPUT'; end if;
 select * into staff from public.spa_staff where id=p_staff;
 if not found then raise exception 'STAFF_NOT_ACTIVE'; end if;
 if p_rule is not null then select * into version from public.spa_payroll_rule_versions where id=p_rule;
 else select * into version from public.spa_payroll_rule_versions where status='active' and effective_from<=p_on order by effective_from desc,version_no desc limit 1; end if;
 if version.id is not null and version.calculation_engine='ordered_v2' then
  select * into profile from public.spa_payroll_version_profiles where rule_version_id=version.id and job_title_id=staff.job_title_id and employment_type_code=staff.employment_type_code;
  if profile.job_title_id is null or not profile.active then raise exception 'STAFF_COMPENSATION_REQUIRED'; end if;
  rate:=case when p_kind='product' then profile.product_commission_bps when p_self_sourced then profile.self_sourced_commission_bps else profile.service_commission_bps end;
 else
  select case when p_kind='service' then c.service_commission_bps else c.product_commission_bps end into rate
  from public.spa_compensation_profiles c where c.job_title_id=staff.job_title_id and c.employment_type_code=staff.employment_type_code and c.active limit 1;
  rate:=coalesce(rate,0);
 end if;
 if rate not between 0 and 10000 then raise exception 'INVALID_COMMISSION_RATE'; end if;
 return rate;
end $$;

drop trigger if exists spa_payroll_checkout_guard on public.spa_checkouts;
alter table public.spa_checkouts
 add column if not exists commission_bps_snapshot int,
 add column if not exists commission_rule_version_id uuid references public.spa_payroll_rule_versions;
update public.spa_checkouts ch set commission_bps_snapshot=case
 when greatest(0,ch.revenue_cents-a.tea_cents)>0 then least(10000,greatest(0,round(ch.commission_cents*10000.0/greatest(0,ch.revenue_cents-a.tea_cents))::int))
 else 0 end
from public.spa_appointments a where a.id=ch.appointment_id and ch.commission_bps_snapshot is null;
update public.spa_checkouts set commission_bps_snapshot=0 where commission_bps_snapshot is null;
update public.spa_checkouts ch set commission_rule_version_id=(
 select v.id from public.spa_payroll_rule_versions v
 where v.status in ('active','archived') and v.effective_from<=(ch.created_at at time zone 'Asia/Taipei')::date
 order by v.effective_from desc,v.version_no desc limit 1
) where ch.commission_rule_version_id is null;
alter table public.spa_checkouts alter column commission_bps_snapshot set default 0,alter column commission_bps_snapshot set not null;
alter table public.spa_checkouts drop constraint if exists spa_checkouts_commission_bps_snapshot_check;
alter table public.spa_checkouts add constraint spa_checkouts_commission_bps_snapshot_check check(commission_bps_snapshot between 0 and 10000);
create trigger spa_payroll_checkout_guard before insert or update or delete on public.spa_checkouts
for each row execute function spa_private.payroll_input_guard();

-- Draft packets can be regenerated with the deterministic transaction order.
-- Finalized packets remain byte-for-byte historical records.
update public.spa_payroll_runs set needs_recalculation=true where status='draft';

create or replace function spa_private.payroll_sale_snapshot() returns trigger
language plpgsql security definer set search_path='' as $$
declare sale_day date;
begin
 if tg_table_name='spa_order_items' then
  perform 1 from public.spa_orders where id=new.order_id for update;
  new.line_position:=coalesce(new.line_position,(select coalesce(max(i.line_position),0)+1 from public.spa_order_items i where i.order_id=new.order_id));
  new.duration_minutes_snapshot:=case when new.item_type='service' then (select duration_minutes from public.spa_services where id=new.service_id) else 0 end;
  if not new.designation_explicit then
   new.designated_client_snapshot:=coalesce(new.item_type='service' and new.staff_id=(select c.preferred_staff_id from public.spa_orders o join public.spa_customers c on c.id=o.customer_id where o.id=new.order_id),false);
  end if;
  sale_day:=(now() at time zone 'Asia/Taipei')::date;
  select id into new.commission_rule_version_id from public.spa_payroll_rule_versions where status='active' and effective_from<=sale_day order by effective_from desc,version_no desc limit 1;
  new.commission_bps_snapshot:=spa_private.sale_commission_rate(new.staff_id,new.item_type,sale_day,coalesce(new.self_sourced_client_snapshot,false),new.commission_rule_version_id);
  new.net_total_cents:=new.line_total_cents;
 else
  select coalesce(a.booking_preference='designated' or (a.booking_preference='legacy' and c.preferred_staff_id=a.staff_id),false),a.self_sourced_client
  into new.designated_client_snapshot,new.self_sourced_client_snapshot
  from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id where a.id=new.appointment_id;
 end if;
 return new;
end $$;

create or replace function spa_private.checkout_commission_guard() returns trigger
language plpgsql security definer set search_path='' as $$
declare rate int; tea bigint; self_sourced boolean;
begin
 select v.id into new.commission_rule_version_id from public.spa_payroll_rule_versions v where v.status='active' and v.effective_from<=(coalesce(new.created_at,now()) at time zone 'Asia/Taipei')::date order by v.effective_from desc,v.version_no desc limit 1;
 select spa_private.sale_commission_rate(a.staff_id,'service',(coalesce(new.created_at,now()) at time zone 'Asia/Taipei')::date,a.self_sourced_client,new.commission_rule_version_id),a.tea_cents,a.self_sourced_client into rate,tea,self_sourced
 from public.spa_appointments a where a.id=new.appointment_id;
 if rate is null then raise exception 'STAFF_SKILL_REQUIRED'; end if;
 new.commission_bps_snapshot:=rate;
 new.commission_cents:=round(greatest(0,new.revenue_cents-tea)*rate/10000.0);
 return new;
end $$;

create or replace function spa_private.payroll_pos_allocate() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.status='paid' and (tg_op='INSERT' or old.status is distinct from new.status or old.total_cents is distinct from new.total_cents) then
  with allocation as (
   select i.id,i.line_total_cents,sum(i.line_total_cents) over() gross,
    sum(i.line_total_cents) over(order by i.line_position,i.id rows unbounded preceding) cumulative
   from public.spa_order_items i where i.order_id=new.id
  ), net as (
   select id,case when gross>0 then floor(cumulative*new.total_cents::numeric/gross)-floor((cumulative-line_total_cents)*new.total_cents::numeric/gross) else 0 end::bigint amount from allocation
  ) update public.spa_order_items i set net_total_cents=n.amount,commission_cents=round(n.amount*i.commission_bps_snapshot/10000.0)::bigint from net n where i.id=n.id;
 end if;
 return new;
end $$;

-- Reassignment updates the same transaction-time estimate and its audit row.
-- Formal ordered payroll still recomputes from its selected version and facts.
create or replace function public.spa_appointment_reassign(p_appointment uuid,p_staff uuid,p_reason text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; old_staff public.spa_staff; new_staff public.spa_staff; roster record; cfg public.spa_settings;
 old_commission bigint; new_commission bigint; has_review boolean; rate int;
begin
 perform spa_private.require_permission('appointments.manage'); perform pg_advisory_xact_lock(726001); perform pg_advisory_xact_lock(726099);
 select * into a from public.spa_appointments where id=p_appointment for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if a.status not in ('pending','confirmed','checked_in','in_service','completed') then raise exception 'INVALID_TRANSITION'; end if;
 if p_staff=a.staff_id then raise exception 'SAME_STAFF'; end if;
 if length(btrim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'REASON_REQUIRED'; end if;
 select * into old_staff from public.spa_staff where id=a.staff_id;
 select * into new_staff from public.spa_staff where id=p_staff and active and employment_status='active' and archived_at is null;
 if not found then raise exception 'STAFF_NOT_ACTIVE'; end if;
 if not exists(select 1 from public.spa_job_titles where id=new_staff.job_title_id and work_category='technician') then raise exception 'SERVICE_COMMISSION_TECHNICIAN_ONLY'; end if;
 if not exists(select 1 from public.spa_staff_services where staff_id=p_staff and service_id=a.service_id and enabled) then raise exception 'STAFF_SKILL_REQUIRED'; end if;
 if a.status<>'completed' then
  select * into roster from spa_private.staff_shift_window(p_staff,a.business_date);
  select * into cfg from public.spa_settings;
  if not coalesce(roster.is_working,false)
   or a.starts_at<((a.business_date::timestamp+make_interval(mins=>roster.start_minute)) at time zone cfg.timezone)
   or a.blocked_until>((a.business_date::timestamp+make_interval(mins=>roster.end_minute)) at time zone cfg.timezone)
   or exists(select 1 from public.spa_time_off o where o.staff_id=p_staff and o.starts_at<a.blocked_until and o.ends_at>a.starts_at)
   or exists(select 1 from public.spa_appointments other where other.id<>a.id and other.staff_id=p_staff and other.status in ('pending','confirmed','checked_in','in_service','completed') and other.starts_at<a.blocked_until and other.blocked_until>a.starts_at)
  then raise exception 'STAFF_NOT_AVAILABLE'; end if;
 end if;
 select commission_cents into old_commission from public.spa_checkouts where appointment_id=a.id;
 update public.spa_appointments set staff_id=p_staff,staff_name_snapshot=new_staff.name,self_sourced_client=false where id=a.id;
 select spa_private.sale_commission_rate(p_staff,'service',(coalesce(ch.created_at,now()) at time zone 'Asia/Taipei')::date,false,ch.commission_rule_version_id)
 into rate from public.spa_checkouts ch where ch.appointment_id=a.id;
 rate:=coalesce(rate,spa_private.sale_commission_rate(p_staff,'service',(now() at time zone 'Asia/Taipei')::date,false,null));
 update public.spa_checkouts ch set commission_bps_snapshot=rate,
  commission_cents=round(greatest(0,ch.revenue_cents-a.tea_cents)*rate/10000.0),self_sourced_client_snapshot=false
 where ch.appointment_id=a.id;
 select commission_cents into new_commission from public.spa_checkouts where appointment_id=a.id;
 select exists(select 1 from public.spa_reviews where appointment_id=a.id) into has_review;
 insert into public.spa_appointment_staff_changes(appointment_id,previous_staff_id,new_staff_id,reason,previous_commission_cents,new_commission_cents,changed_by)
 values(a.id,a.staff_id,p_staff,btrim(p_reason),old_commission,new_commission,auth.uid());
 perform spa_private.audit('appointment.staff_reassigned',a.id::text,jsonb_build_object('previous_staff_id',a.staff_id,'previous_staff',old_staff.name,'new_staff_id',p_staff,'new_staff',new_staff.name,'reason',p_reason,'review_reassigned',has_review,'previous_commission_cents',old_commission,'new_commission_cents',new_commission,'self_sourced_cleared',a.self_sourced_client));
 return jsonb_build_object('appointment_id',a.id,'previous_staff',old_staff.name,'actual_staff',new_staff.name,'review_reassigned',has_review,'commission_cents',new_commission,'self_sourced_cleared',a.self_sourced_client);
end $$;

create or replace function public.spa_appointment_commission_flags(p_id uuid,p_self_sourced boolean,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare appointment public.spa_appointments; checkout public.spa_checkouts; old_rate int; new_rate int;
begin
 perform spa_private.require_permission('payroll.manage'); perform pg_advisory_xact_lock(726001); perform pg_advisory_xact_lock(726099);
 if p_self_sourced is null or length(btrim(coalesce(p_reason,''))) not between 1 and 1000 then raise exception 'REASON_REQUIRED'; end if;
 select * into appointment from public.spa_appointments where id=p_id for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if p_self_sourced and not exists(
  select 1 from public.spa_staff s join public.spa_job_titles j on j.id=s.job_title_id
  where s.id=appointment.staff_id and s.employment_type_code='contractor' and j.work_category='technician'
 ) then raise exception 'SELF_SOURCED_CONTRACTOR_ONLY'; end if;
 select * into checkout from public.spa_checkouts where appointment_id=p_id for update;
 old_rate:=checkout.commission_bps_snapshot;
 update public.spa_appointments set self_sourced_client=p_self_sourced where id=p_id;
 if checkout.id is not null then
  new_rate:=spa_private.sale_commission_rate(appointment.staff_id,'service',(checkout.created_at at time zone 'Asia/Taipei')::date,p_self_sourced,checkout.commission_rule_version_id);
  update public.spa_checkouts set self_sourced_client_snapshot=p_self_sourced,commission_bps_snapshot=new_rate,
   commission_cents=round(greatest(0,revenue_cents-appointment.tea_cents)*new_rate/10000.0)
  where id=checkout.id;
 end if;
 perform spa_private.audit('appointment.commission_flags',p_id::text,jsonb_build_object('old_self_sourced',appointment.self_sourced_client,'self_sourced',p_self_sourced,'old_rate_bps',old_rate,'new_rate_bps',new_rate,'rule_version_id',checkout.commission_rule_version_id,'reason',btrim(p_reason)));
end $$;

-- A review reward is for a later visit. Because reviews can be submitted as
-- soon as a treatment is completed (before the cashier settles it), reject the
-- reward issued by the very appointment currently being checked out. The same
-- coupon remains valid for another appointment or a POS sale.
create or replace function public.spa_customer_coupons_admin(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('pos.use');
 return coalesce((select jsonb_agg(jsonb_build_object(
  'id',id,'code',code,'title',title,'amount_cents',amount_cents,
  'expires_at',expires_at,'appointment_id',appointment_id
 ) order by expires_at)
 from public.spa_coupons where customer_id=p_customer and status='active' and expires_at>now()),'[]'::jsonb);
end $$;

create or replace function public.spa_checkout_with_coupon(p_request uuid,p_appointment uuid,p_discount bigint,p_wallet bigint,p_package uuid,p_tip bigint,p_method text,p_coupon uuid default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; reward public.spa_coupons; prior public.spa_sale_requests; sale jsonb; payload jsonb;
begin
 perform spa_private.require_permission('pos.use');
 if p_request is null then raise exception 'INVALID_INPUT'; end if;
 perform pg_advisory_xact_lock(726001);perform pg_advisory_xact_lock(726005);perform pg_advisory_xact_lock(726006);perform pg_advisory_xact_lock(726099);
 payload:=jsonb_build_object('appointment',p_appointment,'discount',p_discount,'wallet',p_wallet,'package',p_package,'tip',p_tip,'method',p_method,'coupon',p_coupon);
 select * into prior from public.spa_sale_requests where request_id=p_request;
 if found then if prior.kind<>'appointment' or prior.payload<>payload then raise exception 'REQUEST_CONFLICT'; end if; return prior.result; end if;
 if exists(select 1 from public.spa_checkouts where request_id=p_request) or exists(select 1 from public.spa_orders where request_id=p_request) then raise exception 'REQUEST_CONFLICT'; end if;
 select * into a from public.spa_appointments where id=p_appointment for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if p_coupon is not null then
  if p_package is not null then raise exception 'COUPON_WITH_PACKAGE'; end if;
  select * into reward from public.spa_coupons where id=p_coupon for update;
  if not found or reward.customer_id<>a.customer_id or reward.status<>'active' or reward.expires_at<=now() then raise exception 'COUPON_UNAVAILABLE'; end if;
  if reward.appointment_id=p_appointment then raise exception 'COUPON_SOURCE_APPOINTMENT'; end if;
 end if;
 sale:=public.spa_checkout(p_request,p_appointment,p_discount+coalesce(reward.amount_cents,0),p_wallet,p_package,p_tip,p_method);
 if p_coupon is not null then
  update public.spa_coupons set status='redeemed',redeemed_at=now(),checkout_id=(sale->>'id')::uuid,order_id=null where id=reward.id;
  perform spa_private.audit('coupon.redeemed',reward.id::text,jsonb_build_object('checkout',sale->>'id','amount_cents',reward.amount_cents));
 end if;
 sale:=sale||jsonb_build_object('coupon_id',p_coupon,'coupon_discount_cents',coalesce(reward.amount_cents,0));
 insert into public.spa_sale_requests(request_id,kind,payload,result,checkout_id) values(p_request,'appointment',payload,sale,(sale->>'id')::uuid);
 return sale;
end $$;

-- Refund request ids are first-class records. Retrying the same normalized
-- request is a no-op; reusing it for another appointment/reason is rejected,
-- including refunds that restore only a package and create no cash row.
create table if not exists public.spa_refund_requests (
 request_id uuid primary key,
 appointment_id uuid not null references public.spa_appointments on delete cascade,
 checkout_id uuid not null unique references public.spa_checkouts on delete cascade,
 reason text not null check(length(btrim(reason)) between 1 and 1000),
 created_at timestamptz not null default now()
);
alter table public.spa_refund_requests enable row level security;
revoke all on public.spa_refund_requests from public,anon,authenticated;
grant all on public.spa_refund_requests to service_role;

create or replace function spa_private.refund_request_conflict_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.request_id is not null and exists(select 1 from public.spa_refund_requests r where r.request_id=new.request_id) then raise exception 'REQUEST_CONFLICT'; end if;
 return new;
end $$;
drop trigger if exists spa_order_refund_request_conflict on public.spa_orders;
create trigger spa_order_refund_request_conflict before insert on public.spa_orders for each row execute function spa_private.refund_request_conflict_guard();
drop trigger if exists spa_checkout_refund_request_conflict on public.spa_checkouts;
create trigger spa_checkout_refund_request_conflict before insert on public.spa_checkouts for each row execute function spa_private.refund_request_conflict_guard();
drop trigger if exists spa_package_refund_request_conflict on public.spa_packages;
create trigger spa_package_refund_request_conflict before insert on public.spa_packages for each row execute function spa_private.refund_request_conflict_guard();
drop trigger if exists spa_wallet_refund_request_conflict on public.spa_wallet_entries;
create trigger spa_wallet_refund_request_conflict before insert on public.spa_wallet_entries for each row execute function spa_private.refund_request_conflict_guard();
drop trigger if exists spa_cash_refund_request_conflict on public.spa_cash_entries;
create trigger spa_cash_refund_request_conflict before insert on public.spa_cash_entries for each row execute function spa_private.refund_request_conflict_guard();

create or replace function public.spa_refund(p_request uuid,p_appointment uuid,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; ch public.spa_checkouts; prior public.spa_refund_requests; normalized_reason text:=btrim(coalesce(p_reason,''));
 legacy_refund_match boolean; request_conflict boolean;
begin
 perform spa_private.require_permission('finance.manage'); perform pg_advisory_xact_lock(726001); perform pg_advisory_xact_lock(726099);
 if p_request is null or p_appointment is null or length(normalized_reason) not between 1 and 1000 then raise exception 'INVALID_INPUT'; end if;
 select * into prior from public.spa_refund_requests where request_id=p_request for update;
 if found then
  if prior.appointment_id is distinct from p_appointment or prior.reason is distinct from normalized_reason then raise exception 'REQUEST_CONFLICT'; end if;
  return;
 end if;
 legacy_refund_match:=exists(select 1 from public.spa_wallet_entries where request_id=p_request and appointment_id=p_appointment and kind='refund')
  or exists(select 1 from public.spa_cash_entries where request_id=p_request and appointment_id=p_appointment and category='refund');
 request_conflict:=exists(select 1 from public.spa_sale_requests where request_id=p_request)
  or exists(select 1 from public.spa_checkouts where request_id=p_request)
  or exists(select 1 from public.spa_orders where request_id=p_request)
  or exists(select 1 from public.spa_packages where request_id=p_request)
  or exists(select 1 from public.spa_wallet_entries where request_id=p_request and (appointment_id is distinct from p_appointment or kind<>'refund'))
  or exists(select 1 from public.spa_cash_entries where request_id=p_request and (appointment_id is distinct from p_appointment or category<>'refund'));
 if request_conflict then raise exception 'REQUEST_CONFLICT'; end if;
 select * into a from public.spa_appointments where id=p_appointment for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 select * into ch from public.spa_checkouts where appointment_id=p_appointment for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if legacy_refund_match and ch.refunded_at is null then raise exception 'REQUEST_CONFLICT'; end if;
 if ch.refunded_at is not null then raise exception 'ALREADY_REFUNDED'; end if;
 perform 1 from public.spa_customers where id=a.customer_id for update;
 if ch.wallet_cents>0 then insert into public.spa_wallet_entries(customer_id,amount_cents,kind,appointment_id,request_id,note,created_by) values(a.customer_id,ch.wallet_cents,'refund',a.id,p_request,normalized_reason,auth.uid()); end if;
 if ch.package_id is not null then insert into public.spa_package_entries(package_id,appointment_id,delta) values(ch.package_id,a.id,1); end if;
 if ch.cash_cents+ch.tip_cents>0 then insert into public.spa_cash_entries(request_id,customer_id,appointment_id,amount_cents,category,method,note,created_by) values(p_request,a.customer_id,a.id,-ch.cash_cents-ch.tip_cents,'refund',ch.method,normalized_reason,auth.uid()); end if;
 update public.spa_checkouts set refunded_at=now(),refund_reason=normalized_reason where id=ch.id;
 insert into public.spa_refund_requests(request_id,appointment_id,checkout_id,reason) values(p_request,a.id,ch.id,normalized_reason);
 perform spa_private.audit('checkout.refunded',a.id::text,jsonb_build_object('request_id',p_request,'reason',normalized_reason));
end $$;

-- Appointment resets delete refund request fingerprints through the checkout
-- foreign key. Export them with the rest of the appointment chain first.
create or replace function public.spa_backup_export(p_scope text,p_from date default null,p_to date default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare b record;
begin
 perform spa_private.require_permission('settings.manage'); if spa_private.role_name()<>'owner' then raise exception 'FORBIDDEN'; end if;
 if p_scope not in ('appointments','orders','reviews','payroll','expenses','all') then raise exception 'INVALID_INPUT'; end if; select * into b from spa_private.reset_bounds(p_from,p_to);
 return jsonb_build_object('exported_at',now(),'scope',p_scope,'from',p_from,'to',p_to,'preview',public.spa_reset_preview(p_scope,p_from,p_to),
  'appointments',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(a)) from public.spa_appointments a where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'checkouts',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(ch)) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_reviews',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_wallet_entries',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_wallet_entries e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_package_entries',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_package_entries e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'appointment_cash_entries',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_cash_entries e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'booking_actions',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_booking_actions e join public.spa_appointments a on a.id=e.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'orders',case when p_scope in ('orders','all') then coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('items',(select coalesce(jsonb_agg(to_jsonb(i)),'[]') from public.spa_order_items i where i.order_id=o.id))) from public.spa_orders o where coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time),'[]') else '[]'::jsonb end,
  'order_inventory_entries',case when p_scope in ('orders','all') then coalesce((select jsonb_agg(to_jsonb(i)) from public.spa_inventory_entries i join public.spa_orders o on o.id=i.reference_id where i.reference_type='order' and coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time),'[]') else '[]'::jsonb end,
  'order_cash_entries',case when p_scope in ('orders','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_cash_entries e join public.spa_orders o on o.request_id=e.request_id where e.category in ('product','pos') and coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time),'[]') else '[]'::jsonb end,
  'reviews',case when p_scope in ('reviews','all') then coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_reviews r where r.created_at>=b.first_time and r.created_at<b.last_time),'[]') else '[]'::jsonb end,
  'feedback',case when p_scope in ('reviews','all') then coalesce((select jsonb_agg(to_jsonb(f)) from public.spa_feedback f where f.created_at>=b.first_time and f.created_at<b.last_time),'[]') else '[]'::jsonb end,
  'payroll_runs',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('items',(select coalesce(jsonb_agg(to_jsonb(i)),'[]') from public.spa_payroll_items i where i.run_id=r.id))) from public.spa_payroll_runs r where p_from is null or (r.period_start<=p_to and r.period_end>=p_from)),'[]') else '[]'::jsonb end,
  'payroll_source_snapshots',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(snap)) from public.spa_payroll_source_snapshots snap join public.spa_payroll_runs r on r.id=snap.run_id where p_from is null or (r.period_start<=p_to and r.period_end>=p_from)),'[]') else '[]'::jsonb end,
  'time_entries',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_time_entries e where p_from is null or e.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'overtime_entries',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_overtime_entries e where p_from is null or e.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'payroll_adjustments',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_payroll_adjustments e where p_from is null or e.period_start between p_from and p_to),'[]') else '[]'::jsonb end,
  'attendance',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(a)) from public.spa_attendance a where p_from is null or a.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'attendance_events',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_attendance_events e join public.spa_attendance a on a.id=e.attendance_id where p_from is null or a.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'attendance_requests',case when p_scope in ('payroll','all') then coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_attendance_requests r where p_from is null or r.work_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'coupons',coalesce((select jsonb_agg(to_jsonb(c)) from public.spa_coupons c where (p_scope in ('appointments','all') and exists(select 1 from public.spa_appointments a where (a.id=c.appointment_id or a.id=(select appointment_id from public.spa_checkouts where id=c.checkout_id)) and (p_from is null or a.business_date between p_from and p_to))) or (p_scope in ('orders','all') and exists(select 1 from public.spa_orders o where o.id=c.order_id and coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time))),'[]'),
  'sale_requests',coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_sale_requests r where (p_scope in ('appointments','all') and exists(select 1 from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where ch.id=r.checkout_id and (p_from is null or a.business_date between p_from and p_to))) or (p_scope in ('orders','all') and exists(select 1 from public.spa_orders o where o.id=r.order_id and coalesce(o.paid_at,o.created_at)>=b.first_time and coalesce(o.paid_at,o.created_at)<b.last_time))),'[]'),
  'refund_requests',case when p_scope in ('appointments','all') then coalesce((select jsonb_agg(to_jsonb(r)) from public.spa_refund_requests r join public.spa_checkouts ch on ch.id=r.checkout_id join public.spa_appointments a on a.id=ch.appointment_id where p_from is null or a.business_date between p_from and p_to),'[]') else '[]'::jsonb end,
  'expenses',case when p_scope in ('expenses','all') then coalesce((select jsonb_agg(to_jsonb(e)) from public.spa_cash_entries e where e.category='expense' and e.created_at>=b.first_time and e.created_at<b.last_time),'[]') else '[]'::jsonb end);
end $$;

create or replace function public.spa_catalog_bulk(p_kind text,p_ids uuid[],p_action text,p_value text default null) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('catalog.manage');
 if coalesce(array_length(p_ids,1),0)=0 or array_length(p_ids,1)>200 then raise exception 'INVALID_INPUT'; end if;
 if p_kind='product' and p_action in ('publish','unpublish','archive') then
  perform pg_advisory_xact_lock(hashtext('spa-product-category-maintenance'));
  if p_action='publish' and exists(
   select 1 from public.spa_products p left join public.spa_product_categories c on c.id=p.category_id
   where p.id=any(p_ids) and (c.id is null or not c.active or c.archived_at is not null)
  ) then raise exception 'PRODUCT_CATEGORY_UNAVAILABLE'; end if;
  update public.spa_products set
   status=case when p_action='publish' then 'active' when p_action='archive' then 'archived' else status end,
   website_visible=case when p_action='publish' then true when p_action in ('unpublish','archive') then false else website_visible end,
   store_visible=case when p_action='publish' then true when p_action in ('unpublish','archive') then false else store_visible end,
   updated_at=now() where id=any(p_ids);
 elsif p_kind='service' and p_action in ('publish','unpublish','archive') then
  update public.spa_services set status=case when p_action='publish' then 'active' when p_action='archive' then 'archived' else status end,
   active=case when p_action='publish' then true when p_action='archive' then false else active end,
   website_visible=case when p_action='publish' then true when p_action='unpublish' then false else website_visible end,
   online_booking_enabled=case when p_action='publish' then true when p_action='unpublish' then false else online_booking_enabled end where id=any(p_ids);
 else raise exception 'INVALID_INPUT'; end if;
 perform spa_private.audit('catalog.bulk',p_kind,jsonb_build_object('ids',p_ids,'action',p_action,'value',p_value));
end $$;

-- Everyone allowed to manage appointments needs a non-financial settlement
-- state. Monetary checkout details remain limited to finance.view.
create or replace function public.spa_admin_bookings(p_from date,p_to date) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare can_manage boolean:=spa_private.has_permission('appointments.manage'); can_view_finance boolean:=spa_private.has_permission('finance.view'); capacity int:=(select simultaneous_capacity from public.spa_settings limit 1);
begin
 perform spa_private.require_permission('appointments.view');
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 return coalesce((select jsonb_agg(
  (case when can_manage then to_jsonb(a)-'room_id' else jsonb_build_object('id',a.id,'reference',a.reference,'staff_id',a.staff_id,'service_id',a.service_id,'business_date',a.business_date,'starts_at',a.starts_at,'ends_at',a.ends_at,'blocked_until',a.blocked_until,'status',a.status,'service_name',a.service_name_snapshot,'capacity_attention_required',a.capacity_attention_required,'capacity_count_snapshot',a.capacity_count_snapshot,'capacity_limit_snapshot',a.capacity_limit_snapshot) end)
  ||jsonb_build_object('customer_name',case when can_manage then c.name else left(btrim(c.name),1)||'客人' end,'phone',case when can_manage then c.phone else null end,'therapist',s.name,
   'capacity_exceeded',spa_private.capacity_exceeded(a.id),'capacity_current_count',spa_private.capacity_peak(a.starts_at,a.ends_at,null),'capacity_limit',capacity,
   'original_staff_id',coalesce(first_change.previous_staff_id,a.staff_id),'original_therapist',coalesce(original_staff.name,s.name),'staff_change_count',(select count(*) from public.spa_appointment_staff_changes x where x.appointment_id=a.id),
   'last_reassignment_reason',case when can_manage then (select x.reason from public.spa_appointment_staff_changes x where x.appointment_id=a.id order by x.changed_at desc limit 1) end,
   'has_checkout',ch.id is not null,'checkout_refunded',ch.refunded_at is not null,'checkout',case when can_view_finance then to_jsonb(ch) else null end) order by a.starts_at)
  from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id
  left join public.spa_checkouts ch on ch.appointment_id=a.id
  left join lateral (select x.previous_staff_id from public.spa_appointment_staff_changes x where x.appointment_id=a.id order by x.changed_at limit 1) first_change on true
  left join public.spa_staff original_staff on original_staff.id=first_change.previous_staff_id
  where a.business_date between p_from and p_to),'[]');
end $$;

-- Keep the dashboard's revenue label aligned with the report: treatment
-- checkouts/refunds by transaction time plus paid POS orders. This is earned
-- revenue, not cash receipts (wallet/package payments are handled separately).
create or replace function public.spa_dashboard() returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare today date:=(now() at time zone 'Asia/Taipei')::date; first_time timestamptz:=today::timestamp at time zone 'Asia/Taipei'; last_time timestamptz:=(today+1)::timestamp at time zone 'Asia/Taipei'; owner_view boolean:=spa_private.role_name()='owner'; can_manage boolean:=spa_private.has_permission('appointments.manage'); capacity int:=(select simultaneous_capacity from public.spa_settings limit 1);
begin
 perform spa_private.require_permission('dashboard.view');
 return jsonb_build_object('date',today,'appointments',(select count(*) from public.spa_appointments where business_date=today),'pending',(select count(*) from public.spa_appointments where business_date=today and status='pending'),'completed',(select count(*) from public.spa_appointments where business_date=today and status='completed'),'cancelled',(select count(*) from public.spa_appointments where business_date=today and status in ('cancelled','no_show')),
  'revenue_cents',case when owner_view then coalesce((select sum(revenue_cents) from public.spa_checkouts where created_at>=first_time and created_at<last_time),0)-coalesce((select sum(revenue_cents) from public.spa_checkouts where refunded_at>=first_time and refunded_at<last_time),0)+coalesce((select sum(total_cents) from public.spa_orders where status='paid' and paid_at>=first_time and paid_at<last_time),0) end,
  'unsettled_completed',case when owner_view then (select count(*) from public.spa_appointments a where a.business_date=today and a.status='completed' and not exists(select 1 from public.spa_checkouts ch where ch.appointment_id=a.id)) end,
  'staff_working',(select count(*) from public.spa_staff s join lateral spa_private.staff_shift_window(s.id,today) roster on roster.is_working where s.active and s.employment_status='active' and s.archived_at is null),
  'simultaneous_capacity',capacity,'capacity_attention_count',(select count(*) from public.spa_appointments a where a.business_date=today and spa_private.capacity_exceeded(a.id)),
  'new_members',case when owner_view then (select count(*) from public.spa_customers where (created_at at time zone 'Asia/Taipei')::date=today) end,
  'low_stock',case when owner_view then (select count(*) from public.spa_products p where p.status='active' and coalesce((select sum(i.delta) from public.spa_inventory_entries i where i.product_id=p.id),0)<=p.low_stock_threshold) end,
  'today_hours',(select to_jsonb(w) from spa_private.business_window(today) w),
  'next_appointments',coalesce((select jsonb_agg(to_jsonb(x)) from (select a.id,a.reference,a.starts_at,a.status,a.service_name_snapshot service_name,case when can_manage then c.name else left(btrim(c.name),1)||'小姐' end customer_name,s.name staff_name,spa_private.capacity_exceeded(a.id) capacity_exceeded from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id where a.business_date=today and a.status not in ('cancelled','no_show') order by a.starts_at limit 8) x),'[]'));
end $$;

revoke all on function spa_private.sale_commission_rate(uuid,text,date,boolean,uuid),spa_private.payroll_sale_snapshot(),spa_private.checkout_commission_guard(),spa_private.payroll_pos_allocate(),spa_private.refund_request_conflict_guard() from public,anon,authenticated;
grant execute on function spa_private.sale_commission_rate(uuid,text,date,boolean,uuid),spa_private.payroll_sale_snapshot(),spa_private.checkout_commission_guard(),spa_private.payroll_pos_allocate(),spa_private.refund_request_conflict_guard() to service_role;
revoke all on function public.spa_inventory_adjust(uuid,int,text) from public,anon,authenticated;
revoke all on function public.spa_checkout(uuid,uuid,bigint,bigint,uuid,bigint,text),public.spa_pos_checkout(uuid,uuid,jsonb,bigint,text,text) from public,anon,authenticated;
grant execute on function public.spa_checkout(uuid,uuid,bigint,bigint,uuid,bigint,text),public.spa_pos_checkout(uuid,uuid,jsonb,bigint,text,text) to service_role;
revoke all on function public.spa_product_save(jsonb),public.spa_inventory_adjust(uuid,uuid,int,text),public.spa_catalog_bulk(text,uuid[],text,text),public.spa_backup_export(text,date,date),public.spa_admin_bookings(date,date),public.spa_dashboard(),public.spa_appointment_reassign(uuid,uuid,text),public.spa_appointment_commission_flags(uuid,boolean,text),public.spa_customer_coupons_admin(uuid),public.spa_checkout_with_coupon(uuid,uuid,bigint,bigint,uuid,bigint,text,uuid),public.spa_pos_checkout_with_coupon(uuid,uuid,jsonb,bigint,text,text,uuid,bigint),public.spa_refund(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.spa_product_save(jsonb),public.spa_inventory_adjust(uuid,uuid,int,text),public.spa_catalog_bulk(text,uuid[],text,text),public.spa_backup_export(text,date,date),public.spa_admin_bookings(date,date),public.spa_dashboard(),public.spa_appointment_reassign(uuid,uuid,text),public.spa_appointment_commission_flags(uuid,boolean,text),public.spa_customer_coupons_admin(uuid),public.spa_checkout_with_coupon(uuid,uuid,bigint,bigint,uuid,bigint,text,uuid),public.spa_pos_checkout_with_coupon(uuid,uuid,jsonb,bigint,text,text,uuid,bigint),public.spa_refund(uuid,uuid,text) to authenticated,service_role;
notify pgrst,'reload schema';
commit;
