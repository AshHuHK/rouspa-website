-- Create the owner's account under Supabase Authentication first.
-- Replace only the email below; do not put a password or privileged API key in this file.
do $$
declare owner_user uuid;
begin
 select id into owner_user from auth.users where lower(email)=lower('OWNER_EMAIL_HERE');
 if owner_user is null then raise exception '先在 Authentication 建立此電子郵件的帳號'; end if;
 insert into public.spa_roles(user_id,role,active) values(owner_user,'owner',true)
 on conflict(user_id) do update set role='owner',active=true;
end $$;
