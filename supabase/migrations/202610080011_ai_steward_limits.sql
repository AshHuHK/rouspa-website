begin;

-- Only reservation counters are retained. Prompts and model responses never
-- enter this table, and callers cannot choose the account or server date.
create table if not exists spa_private.ai_steward_usage (
 user_id uuid primary key references auth.users(id) on delete cascade,
 usage_day date not null,
 day_requests int not null default 0 check(day_requests>=0),
 minute_start timestamptz not null,
 minute_requests int not null default 0 check(minute_requests between 0 and 3),
 updated_at timestamptz not null default now()
);
alter table spa_private.ai_steward_usage enable row level security;
revoke all on table spa_private.ai_steward_usage from public,anon,authenticated,service_role;

create or replace function public.spa_ai_reserve_request() returns jsonb
language plpgsql security definer set search_path='' as $$
declare
 person uuid:=auth.uid();
 instant timestamptz:=clock_timestamp();
 today date:=(instant at time zone 'Asia/Taipei')::date;
 minute_boundary timestamptz:=date_trunc('minute',instant);
 daily_limit int;
 usage spa_private.ai_steward_usage;
 wait_seconds int;
begin
 -- Reuse the current role identity guard, including inactive roles/personnel
 -- and JWT revocation after a password reset. A service-role caller must also
 -- carry an actual, valid team user identity; the role alone grants no quota.
 perform spa_private.require_team();
 if person is null then raise exception 'FORBIDDEN' using errcode='42501'; end if;
 daily_limit:=case when spa_private.role_name()='owner' then 100 else 40 end;

 insert into spa_private.ai_steward_usage(user_id,usage_day,minute_start)
 values(person,today,minute_boundary) on conflict(user_id) do nothing;
 select * into usage from spa_private.ai_steward_usage where user_id=person for update;

 -- Waiting for another reservation may cross a minute or Taipei midnight.
 -- Use the server time after acquiring the row, rather than transaction start.
 instant:=clock_timestamp();
 today:=(instant at time zone 'Asia/Taipei')::date;
 minute_boundary:=date_trunc('minute',instant);

 if usage.usage_day<>today then usage.usage_day:=today; usage.day_requests:=0; end if;
 if usage.minute_start<>minute_boundary then usage.minute_start:=minute_boundary; usage.minute_requests:=0; end if;

 -- Return denials normally so the caller can commit any window reset. Never
 -- raise a quota exception, which would roll back this transaction's counters.
 if usage.day_requests>=daily_limit then
  wait_seconds:=greatest(1,ceil(extract(epoch from (((today+1)::timestamp at time zone 'Asia/Taipei')-instant)))::int);
  update spa_private.ai_steward_usage set usage_day=usage.usage_day,day_requests=usage.day_requests,
   minute_start=usage.minute_start,minute_requests=usage.minute_requests,updated_at=instant where user_id=person;
  return jsonb_build_object('allowed',false,'reason','daily_limit','retry_after',wait_seconds,'remaining',0);
 end if;
 if usage.minute_requests>=3 then
  wait_seconds:=greatest(1,ceil(extract(epoch from (minute_boundary+interval '1 minute'-instant)))::int);
  update spa_private.ai_steward_usage set usage_day=usage.usage_day,day_requests=usage.day_requests,
   minute_start=usage.minute_start,minute_requests=usage.minute_requests,updated_at=instant where user_id=person;
  return jsonb_build_object('allowed',false,'reason','minute_limit','retry_after',wait_seconds,'remaining',daily_limit-usage.day_requests);
 end if;

 update spa_private.ai_steward_usage set usage_day=usage.usage_day,day_requests=usage.day_requests+1,
  minute_start=usage.minute_start,minute_requests=usage.minute_requests+1,updated_at=instant where user_id=person;
 return jsonb_build_object('allowed',true,'reason',null,'retry_after',0,'remaining',daily_limit-usage.day_requests-1);
end $$;

revoke all on function public.spa_ai_reserve_request() from public,anon,authenticated,service_role;
grant execute on function public.spa_ai_reserve_request() to authenticated,service_role;
notify pgrst,'reload schema';
commit;
