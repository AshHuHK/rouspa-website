-- ============================================================
-- 匿名意見回饋 feedback
-- 在 Supabase Dashboard → SQL Editor 貼上執行一次即可
-- ============================================================

create table if not exists public.feedback (
  id          bigint generated always as identity primary key,
  message     text not null,
  status      text not null default 'unread',   -- unread 未讀 / read 已讀 / resolved 已處理
  created_at  timestamptz not null default now(),
  constraint feedback_message_len check (char_length(btrim(message)) between 5 and 500),
  constraint feedback_status_valid check (status in ('unread', 'read', 'resolved'))
);

comment on table  public.feedback is '顧客匿名意見回饋，不含任何個資';
comment on column public.feedback.status is 'unread=未讀, read=已讀, resolved=已處理';

create index if not exists feedback_status_created_idx
  on public.feedback (status, created_at desc);

-- ------------------------------------------------------------
-- RLS：匿名只能新增，永遠無法讀取／修改／刪除
-- 前台使用的是公開的 anon key，因此只開放 INSERT，
-- 留言僅能在 Supabase 後台（service role）檢視。
-- ------------------------------------------------------------
alter table public.feedback enable row level security;

drop policy if exists "anon can insert feedback" on public.feedback;
create policy "anon can insert feedback"
  on public.feedback
  for insert
  to anon
  with check (true);

grant insert on public.feedback to anon;
revoke select, update, delete on public.feedback from anon;
