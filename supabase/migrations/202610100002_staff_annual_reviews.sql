begin;

-- Employment dates are facts. Never substitute profile creation dates or fill
-- historical hire dates during this migration.
create or replace function spa_private.staff_employment_dates_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.hire_date is not null and new.hire_date<'1900-01-01'::date then raise exception 'INVALID_HIRE_DATE'; end if;
 if new.hire_date is not null and new.departed_on is not null and new.departed_on<new.hire_date then raise exception 'INVALID_EMPLOYMENT_DATES'; end if;
 return new;
end $$;
drop trigger if exists spa_staff_employment_dates_guard on public.spa_staff;
create trigger spa_staff_employment_dates_guard before insert or update of hire_date,departed_on on public.spa_staff
 for each row execute function spa_private.staff_employment_dates_guard();

create or replace function spa_private.staff_tenure(p_hire date,p_departed date,p_today date) returns jsonb
language sql immutable set search_path='' as $$
 select case when p_hire is null then jsonb_build_object('status','missing','hire_date',null,'as_of',least(coalesce(p_departed,p_today),p_today))
  when p_hire>least(coalesce(p_departed,p_today),p_today) then jsonb_build_object('status',case when p_departed is null then 'not_started' else 'invalid' end,'hire_date',p_hire,'as_of',least(coalesce(p_departed,p_today),p_today),'days',0,'years',0,'months',0)
  else jsonb_build_object('status','known','hire_date',p_hire,'as_of',least(coalesce(p_departed,p_today),p_today),
   'days',least(coalesce(p_departed,p_today),p_today)-p_hire,
   'years',extract(year from age(least(coalesce(p_departed,p_today),p_today),p_hire))::int,
   'months',extract(month from age(least(coalesce(p_departed,p_today),p_today),p_hire))::int) end
$$;
revoke all on function spa_private.staff_tenure(date,date,date),spa_private.staff_employment_dates_guard() from public,anon,authenticated;

create table if not exists public.spa_staff_review_policy(
 id boolean primary key default true check(id),
 criteria jsonb not null,
 pass_score numeric(5,2) not null check(pass_score between 0 and 100),
 version integer not null default 1,
 updated_by uuid references auth.users(id),
 updated_at timestamptz not null default now()
);
-- Configurable initial examples; the supplied wage document does not specify
-- review weights or a numerical pass mark. These do not alter pay or titles.
insert into public.spa_staff_review_policy(id,criteria,pass_score) values(true,
 '[{"key":"technique","name":"專業技術／工作能力","weight":25,"description":"依實際職務考核專業能力"},{"key":"service","name":"服務品質","weight":25,"description":"顧客服務與協作表現"},{"key":"performance","name":"工作表現","weight":25,"description":"依職務目標核對工作成果"},{"key":"standards","name":"工作規範","weight":25,"description":"流程、出勤及門店規範"}]',70)
on conflict(id) do nothing;

create table if not exists public.spa_staff_annual_reviews(
 id uuid primary key default gen_random_uuid(),
 staff_id uuid not null references public.spa_staff(id),
 review_year integer not null check(review_year between 2000 and 2200),
 status text not null default 'draft' check(status in('draft','published')),
 criteria_snapshot jsonb not null,
 scores jsonb not null default '{}',
 total_score numeric(5,2) check(total_score between 0 and 100),
 pass_score numeric(5,2) not null check(pass_score between 0 and 100),
 comment text not null default '' check(length(comment)<=4000),
 reviewed_by uuid not null references auth.users(id),
 reviewer_name text not null,
 reviewed_on date not null,
 published_at timestamptz,
 version integer not null default 1,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(staff_id,review_year)
);
alter table public.spa_staff_review_policy enable row level security;
alter table public.spa_staff_annual_reviews enable row level security;
revoke all on public.spa_staff_review_policy,public.spa_staff_annual_reviews from public,anon,authenticated;
grant all on public.spa_staff_review_policy,public.spa_staff_annual_reviews to service_role;

create or replace function spa_private.validate_review_criteria(p_criteria jsonb) returns void
language plpgsql immutable set search_path='' as $$
declare criterion jsonb; keys text[]:='{}'; total numeric:=0; weight numeric;
begin
 if jsonb_typeof(p_criteria) is distinct from 'array' then raise exception 'INVALID_REVIEW_CRITERIA'; end if;
 if jsonb_array_length(p_criteria) not between 1 and 12 then raise exception 'INVALID_REVIEW_CRITERIA'; end if;
 for criterion in select value from jsonb_array_elements(p_criteria) loop
  if jsonb_typeof(criterion) is distinct from 'object' or coalesce(criterion->>'key','') !~ '^[a-z][a-z0-9_]{0,39}$'
    or length(btrim(coalesce(criterion->>'name',''))) not between 1 and 80
    or length(coalesce(criterion->>'description',''))>500 or jsonb_typeof(criterion->'weight') is distinct from 'number'
    or (criterion->>'key')=any(keys) then raise exception 'INVALID_REVIEW_CRITERIA'; end if;
  weight:=(criterion->>'weight')::numeric;
  if weight<=0 or weight>100 then raise exception 'INVALID_REVIEW_CRITERIA'; end if;
  keys:=keys||(criterion->>'key');total:=total+weight;
 end loop;
 if total<>100 then raise exception 'INVALID_REVIEW_WEIGHTS'; end if;
end $$;
revoke all on function spa_private.validate_review_criteria(jsonb) from public,anon,authenticated;

create or replace function public.spa_staff_annual_reviews(p_staff uuid default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare person uuid; owner boolean:=coalesce(spa_private.role_name()='owner',false); today date:=(now() at time zone 'Asia/Taipei')::date;
begin
 perform spa_private.require_team();
 select staff_id into person from public.spa_roles where user_id=auth.uid() and active;
 if owner then person:=coalesce(p_staff,person);
 elsif p_staff is not null and p_staff is distinct from person then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 if person is null or not exists(select 1 from public.spa_staff where id=person) then raise exception 'NOT_FOUND'; end if;
 return jsonb_build_object('today',today,'profile',(select jsonb_build_object('id',s.id,'name',s.name,'hire_date',s.hire_date,'departed_on',s.departed_on,'employment_status',s.employment_status,'tenure',spa_private.staff_tenure(s.hire_date,s.departed_on,today)) from public.spa_staff s where id=person),
 'policy',case when owner then (select jsonb_build_object('criteria',criteria,'pass_score',pass_score,'version',version,'initial_example',true) from public.spa_staff_review_policy where id) else null end,
 'reviews',coalesce((select jsonb_agg(to_jsonb(r)-'reviewed_by' order by r.review_year desc) from public.spa_staff_annual_reviews r where r.staff_id=person and (owner or r.status='published')),'[]'));
end $$;

create or replace function public.spa_staff_review_policy_save(p_criteria jsonb,p_pass_score numeric,p_version integer) returns integer
language plpgsql security definer set search_path='' as $$
declare prior public.spa_staff_review_policy; next_version integer;
begin
 perform spa_private.require_role(array['owner']);
 perform spa_private.validate_review_criteria(p_criteria);
 if p_pass_score is null or p_pass_score<0 or p_pass_score>100 then raise exception 'INVALID_REVIEW_SCORE'; end if;
 select * into prior from public.spa_staff_review_policy where id for update;
 if p_version is null or prior.version<>p_version then raise exception 'REVIEW_VERSION_CONFLICT'; end if;
 update public.spa_staff_review_policy set criteria=p_criteria,pass_score=round(p_pass_score,2),version=version+1,updated_by=auth.uid(),updated_at=now() where id returning version into next_version;
 perform spa_private.audit('staff.review_policy_saved','annual',jsonb_build_object('old',to_jsonb(prior),'new',jsonb_build_object('criteria',p_criteria,'pass_score',p_pass_score,'version',next_version)));
 return next_version;
end $$;

create or replace function public.spa_staff_annual_review_save(p_payload jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare person uuid:=nullif(p_payload->>'staff_id','')::uuid; year_value integer:=nullif(p_payload->>'review_year','')::integer;
 today date:=(now() at time zone 'Asia/Taipei')::date; state text:=coalesce(p_payload->>'status','draft');
 prior public.spa_staff_annual_reviews; result uuid; criteria jsonb:=p_payload->'criteria'; scores_value jsonb:=coalesce(p_payload->'scores','{}');
 threshold numeric:=nullif(p_payload->>'pass_score','')::numeric; criterion jsonb; key_value text; score numeric; total numeric:=0; complete boolean:=true; keys text[]:='{}'; reviewer text;
begin
 perform spa_private.require_role(array['owner']);
 if person is null or not exists(select 1 from public.spa_staff where id=person) then raise exception 'NOT_FOUND'; end if;
 if year_value is null or year_value<2000 or year_value>extract(year from today)::integer then raise exception 'INVALID_REVIEW_YEAR'; end if;
 if state not in('draft','published') or length(coalesce(p_payload->>'comment',''))>4000 then raise exception 'INVALID_INPUT'; end if;
 perform spa_private.validate_review_criteria(criteria);
 if threshold is null or threshold<0 or threshold>100 or jsonb_typeof(scores_value) is distinct from 'object' then raise exception 'INVALID_REVIEW_SCORE'; end if;
 for criterion in select value from jsonb_array_elements(criteria) loop
  key_value:=criterion->>'key';keys:=keys||key_value;
  if not scores_value ? key_value then complete:=false;continue;end if;
  if jsonb_typeof(scores_value->key_value) is distinct from 'number' then raise exception 'INVALID_REVIEW_SCORE'; end if;
  score:=(scores_value->>key_value)::numeric;
  if score<0 or score>100 then raise exception 'INVALID_REVIEW_SCORE'; end if;
  total:=total+score*(criterion->>'weight')::numeric/100.0;
 end loop;
 if exists(select 1 from jsonb_object_keys(scores_value) k where not k=any(keys)) then raise exception 'INVALID_REVIEW_SCORE'; end if;
 if state='published' and not complete then raise exception 'REVIEW_INCOMPLETE'; end if;
 perform pg_advisory_xact_lock(hashtextextended('staff-review:'||person::text||':'||year_value::text,0));
 select * into prior from public.spa_staff_annual_reviews where staff_id=person and review_year=year_value for update;
 if prior.id is not null and coalesce(nullif(p_payload->>'version','')::integer,0)<>prior.version then raise exception 'REVIEW_VERSION_CONFLICT'; end if;
 if prior.id is null and coalesce(nullif(p_payload->>'version','')::integer,0)<>0 then raise exception 'REVIEW_VERSION_CONFLICT'; end if;
 select coalesce(nullif(s.name,''),'店主') into reviewer from public.spa_roles r left join public.spa_staff s on s.id=r.staff_id where r.user_id=auth.uid() and r.active;
 insert into public.spa_staff_annual_reviews(staff_id,review_year,status,criteria_snapshot,scores,total_score,pass_score,comment,reviewed_by,reviewer_name,reviewed_on,published_at)
 values(person,year_value,state,criteria,scores_value,case when complete then round(total,2) end,round(threshold,2),coalesce(p_payload->>'comment',''),auth.uid(),coalesce(reviewer,'店主'),today,case when state='published' then now() end)
 on conflict(staff_id,review_year) do update set status=excluded.status,criteria_snapshot=excluded.criteria_snapshot,scores=excluded.scores,total_score=excluded.total_score,pass_score=excluded.pass_score,comment=excluded.comment,
 reviewed_by=excluded.reviewed_by,reviewer_name=excluded.reviewer_name,reviewed_on=excluded.reviewed_on,published_at=case when excluded.status='published' then coalesce(spa_staff_annual_reviews.published_at,now()) end,version=spa_staff_annual_reviews.version+1,updated_at=now() returning id into result;
 perform spa_private.audit('staff.annual_review_saved',result::text,jsonb_build_object('old',to_jsonb(prior),'new',(select to_jsonb(r) from public.spa_staff_annual_reviews r where id=result)));
 return result;
end $$;

create or replace function public.spa_staff_annual_review_delete(p_id uuid,p_version integer) returns void
language plpgsql security definer set search_path='' as $$
declare prior public.spa_staff_annual_reviews;
begin
 perform spa_private.require_role(array['owner']);
 select * into prior from public.spa_staff_annual_reviews where id=p_id for update;
 if prior.id is null then raise exception 'NOT_FOUND'; end if;
 if prior.status<>'draft' then raise exception 'REVIEW_PUBLISHED'; end if;
 if p_version is null or p_version<>prior.version then raise exception 'REVIEW_VERSION_CONFLICT'; end if;
 delete from public.spa_staff_annual_reviews where id=p_id;
 perform spa_private.audit('staff.annual_review_deleted',p_id::text,jsonb_build_object('old',to_jsonb(prior)));
end $$;

revoke all on function public.spa_staff_annual_reviews(uuid),public.spa_staff_review_policy_save(jsonb,numeric,integer),public.spa_staff_annual_review_save(jsonb),public.spa_staff_annual_review_delete(uuid,integer) from public,anon,authenticated;
grant execute on function public.spa_staff_annual_reviews(uuid),public.spa_staff_review_policy_save(jsonb,numeric,integer),public.spa_staff_annual_review_save(jsonb),public.spa_staff_annual_review_delete(uuid,integer) to authenticated,service_role;

-- Only generic team invalidation is broadcast. Annual feedback, scores and
-- employee identities never leave the permission-checked RPCs above.
create trigger spa_live_invalidation after insert or update or delete or truncate on public.spa_staff_review_policy
 for each statement execute function spa_private.queue_live_invalidation('team','');
create trigger spa_live_invalidation after insert or update or delete or truncate on public.spa_staff_annual_reviews
 for each statement execute function spa_private.queue_live_invalidation('team','');

notify pgrst,'reload schema';
commit;
