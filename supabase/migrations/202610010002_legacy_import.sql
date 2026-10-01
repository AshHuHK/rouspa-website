begin;
create table public.spa_legacy_imports (
 source_id text primary key, original jsonb not null, appointment_id uuid references public.spa_appointments,
 outcome text not null check(outcome in ('imported','needs_review')), reason text, imported_at timestamptz not null default now()
);
alter table public.spa_legacy_imports enable row level security;
revoke all on public.spa_legacy_imports from public,anon,authenticated;
grant all on public.spa_legacy_imports to service_role;
insert into public.spa_services(code,name,name_en,duration_minutes,buffer_minutes,price_cents,active,display_order) values
 ('legacy_classic','經典頭療（舊資料）','Legacy Classic',60,15,180000,false,100),
 ('legacy_herbal','御方草本頭療（舊資料）','Legacy Herbal',90,15,280000,false,101),
 ('legacy_moxa','艾灸通絡頭療（舊資料）','Legacy Moxa',75,15,220000,false,102),
 ('legacy_holistic','全息頭部SPA（舊資料）','Legacy Holistic',120,15,380000,false,103);
-- Keep all source rows. Unknown therapist/service, invalid phone or conflicts go to review.
-- Historical "confirmed" is NOT guessed to mean completed or paid.
do $$
declare old jsonb; src text; st uuid; svc public.spa_services; customer uuid; room uuid; at_time timestamptz; result uuid; tel text; service_code text; tea int;
begin
 if to_regclass('public.bookings') is null then return; end if;
 perform pg_advisory_xact_lock(726001);
 for old in execute 'select to_jsonb(b) from public.bookings b order by b.id' loop
  src:=old->>'id';
  begin
   st:=null; customer:=null; room:=null; result:=null;
   select id into st from public.spa_staff where display_order=(old->>'therapist_index')::int;
   if st is null then raise exception '無法對應舊技師，需人工核對'; end if;
   service_code:=case old->>'service' when '經典頭療' then 'legacy_classic' when '御方草本頭療' then 'legacy_herbal' when '艾灸通絡頭療' then 'legacy_moxa' when '全息頭部SPA' then 'legacy_holistic' when '45分方子' then 'formula45' when '90分方子' then 'formula90' when '120分方子' then 'formula120' when '120分全息' then 'formula120' end;
   select * into svc from public.spa_services where spa_services.code=service_code;
   if svc.id is null then raise exception '無法對應舊療程，需人工核對'; end if;
   tel:=spa_private.phone(old->>'phone');
   if tel is null or tel !~ '^\+?[0-9]{8,15}$' then raise exception '舊手機號碼格式不完整，需人工核對'; end if;
   if old->>'status' not in ('confirmed','cancelled') then raise exception '無法對應舊狀態'; end if;
   at_time:=((old->>'booking_date')::date+(old->>'booking_time')::time) at time zone 'Asia/Taipei';
   select id into room from public.spa_rooms r where not exists(select 1 from public.spa_appointments a where a.room_id=r.id and a.status in ('pending','confirmed','checked_in','completed') and a.starts_at<at_time+make_interval(mins=>svc.duration_minutes+svc.buffer_minutes) and a.blocked_until>at_time) order by r.name limit 1;
   if room is null then raise exception '舊預約床位衝突'; end if;
   select id into customer from public.spa_customers where phone=tel;
   if customer is null then insert into public.spa_customers(name,phone) values(coalesce(nullif(btrim(old->>'customer_name'),''),'舊會員'),tel) returning id into customer; end if;
   tea:=case old->>'tea' when '漢方安神茶' then 1 when '活血通絡茶' then 2 when '清肝明目茶' then 3 when '養顏美肌茶' then 4 else 0 end;
   insert into public.spa_appointments(request_id,customer_id,staff_id,room_id,service_id,business_date,starts_at,ends_at,blocked_until,status,service_name,price_cents,tea_code,tea_cents,note,created_at)
   values(gen_random_uuid(),customer,st,room,svc.id,(old->>'booking_date')::date,at_time,at_time+make_interval(mins=>svc.duration_minutes),at_time+make_interval(mins=>svc.duration_minutes+svc.buffer_minutes),old->>'status',old->>'service',svc.price_cents,tea,(array[0,12000,15000,12000,18000])[tea+1],coalesce(old->>'note','')||' [舊資料：金額依舊目錄重建，未推定收款]',coalesce((old->>'created_at')::timestamptz,now())) returning id into result;
   insert into public.spa_legacy_imports values(src,old,result,'imported',null,now());
  exception when others then
   insert into public.spa_legacy_imports(source_id,original,outcome,reason) values(src,old,'needs_review',sqlerrm);
  end;
 end loop;
end $$;
create function public.spa_legacy_report() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_role(array['owner','manager']);
 return coalesce((select jsonb_agg(jsonb_build_object('source_id',source_id,'outcome',outcome,'reason',reason,'service',original->>'service','date',original->>'booking_date','staff_index',original->>'therapist_index') order by source_id) from public.spa_legacy_imports),'[]');
end $$;
revoke all on function public.spa_legacy_report() from public,anon,authenticated;
grant execute on function public.spa_legacy_report() to authenticated,service_role;
notify pgrst,'reload schema';
commit;
