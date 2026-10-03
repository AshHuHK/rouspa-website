begin;

-- ROU SPA Business Operating System
-- This migration extends the existing operational core. It preserves every
-- appointment, checkout, member balance, review and staff account.

create table if not exists public.spa_employment_types (
 code text primary key check(code ~ '^[a-z][a-z0-9_]{1,31}$'),
 name text not null check(length(btrim(name)) between 1 and 80),
 active boolean not null default true,
 display_order int not null default 0,
 archived_at timestamptz
);
insert into public.spa_employment_types(code,name,display_order) values
 ('full_time','正職',10),('part_time','兼職',20),('contractor','承攬',30)
on conflict(code) do nothing;

create table if not exists public.spa_job_titles (
 id uuid primary key default gen_random_uuid(),
 code text unique not null check(code ~ '^[a-z][a-z0-9_]{1,31}$'),
 name text not null check(length(btrim(name)) between 1 and 80),
 active boolean not null default true,
 display_order int not null default 0,
 archived_at timestamptz
);
insert into public.spa_job_titles(code,name,display_order) values
 ('owner','店主',10),('manager','主管',20),('head_therapist','首席調理師',30),
 ('senior_therapist','資深調理師',40),('therapist','調理師',50),('reception','櫃台',60),('part_time','兼職',70)
on conflict(code) do nothing;

create table if not exists public.spa_permission_definitions (
 code text primary key,
 name text not null,
 module text not null,
 display_order int not null default 0
);
insert into public.spa_permission_definitions(code,name,module,display_order) values
 ('dashboard.view','查看營運首頁','dashboard',10),
 ('appointments.view','查看日程','operations',20),('appointments.manage','管理預約','operations',21),
 ('customers.view','查看會員','operations',30),('customers.manage','管理會員與餘額','operations',31),
 ('reviews.manage','管理評價','operations',40),('pos.use','使用 POS／結帳','operations',50),
 ('team.view','查看人員','team',60),('team.manage','管理人員與排班','team',61),
 ('payroll.view','查看薪資','finance',70),('payroll.manage','管理薪資規則與結算','finance',71),
 ('finance.view','查看營收','finance',80),('finance.manage','管理收支','finance',81),
 ('catalog.view','查看商品與服務','catalog',90),('catalog.manage','管理商品與服務','catalog',91),
 ('reports.view','查看報表','reports',100),('settings.manage','管理設定與權限','settings',110),
 ('website.manage','管理官網內容','settings',120)
on conflict(code) do update set name=excluded.name,module=excluded.module,display_order=excluded.display_order;

create table if not exists public.spa_role_profiles (
 code text primary key check(code ~ '^[a-z][a-z0-9_]{1,31}$'),
 name text not null check(length(btrim(name)) between 1 and 80),
 active boolean not null default true,
 system_role boolean not null default false,
 display_order int not null default 0,
 archived_at timestamptz
);
insert into public.spa_role_profiles(code,name,system_role,display_order) values
 ('owner','店主',true,10),('manager','主管',true,20),('receptionist','櫃台',true,30),('therapist','技師',true,40)
on conflict(code) do update set name=excluded.name,system_role=excluded.system_role;

create table if not exists public.spa_role_permissions (
 role_code text not null references public.spa_role_profiles(code),
 permission_code text not null references public.spa_permission_definitions(code),
 primary key(role_code,permission_code)
);
insert into public.spa_role_permissions(role_code,permission_code)
select 'owner',code from public.spa_permission_definitions on conflict do nothing;
insert into public.spa_role_permissions(role_code,permission_code) values
 ('manager','dashboard.view'),('manager','appointments.view'),('manager','appointments.manage'),
 ('manager','customers.view'),('manager','customers.manage'),('manager','reviews.manage'),('manager','pos.use'),
 ('manager','team.view'),('manager','team.manage'),('manager','finance.view'),('manager','catalog.view'),
 ('manager','catalog.manage'),('manager','reports.view'),
 ('receptionist','dashboard.view'),('receptionist','appointments.view'),('receptionist','appointments.manage'),
 ('receptionist','customers.view'),('receptionist','pos.use'),('receptionist','catalog.view'),
 ('therapist','dashboard.view'),('therapist','appointments.view'),('therapist','customers.view')
on conflict do nothing;

alter table public.spa_roles drop constraint if exists spa_roles_role_check;
alter table public.spa_roles drop constraint if exists spa_roles_role_fkey;
alter table public.spa_roles add constraint spa_roles_role_fkey foreign key(role) references public.spa_role_profiles(code);

alter table public.spa_staff add column if not exists photo_url text not null default '';
alter table public.spa_staff add column if not exists phone text not null default '';
alter table public.spa_staff add column if not exists email text not null default '';
alter table public.spa_staff add column if not exists birth_date date;
alter table public.spa_staff add column if not exists address text not null default '';
alter table public.spa_staff add column if not exists hire_date date;
alter table public.spa_staff add column if not exists employment_type_code text references public.spa_employment_types(code);
alter table public.spa_staff add column if not exists job_title_id uuid references public.spa_job_titles(id);
alter table public.spa_staff add column if not exists is_bookable boolean not null default true;
alter table public.spa_staff add column if not exists website_visible boolean not null default true;
update public.spa_staff set employment_type_code=coalesce(employment_type_code,'full_time'),
 job_title_id=coalesce(job_title_id,(select id from public.spa_job_titles where code=case
  when title like '%首席%' then 'head_therapist' when title like '%資深%' then 'senior_therapist' else 'therapist' end));

create table if not exists public.spa_service_categories (
 id uuid primary key default gen_random_uuid(), code text unique not null,
 name text not null, name_en text not null default '', active boolean not null default true,
 display_order int not null default 0, archived_at timestamptz
);
insert into public.spa_service_categories(code,name,name_en,display_order) values
 ('head_spa','頭療','Head spa',10),('scalp_care','洗護','Scalp care',20),('add_on','加購','Add-on',30)
on conflict(code) do nothing;
alter table public.spa_services add column if not exists category_id uuid references public.spa_service_categories(id);
alter table public.spa_services add column if not exists description text not null default '';
alter table public.spa_services add column if not exists description_en text not null default '';
alter table public.spa_services add column if not exists image_url text not null default '';
alter table public.spa_services add column if not exists member_price_cents bigint check(member_price_cents is null or member_price_cents>=0);
alter table public.spa_services add column if not exists online_booking_enabled boolean not null default true;
alter table public.spa_services add column if not exists website_visible boolean not null default true;
alter table public.spa_services add column if not exists status text not null default 'active' check(status in ('draft','active','archived'));
alter table public.spa_services add column if not exists website_content jsonb not null default '{}'::jsonb;
update public.spa_services set category_id=coalesce(category_id,(select id from public.spa_service_categories where code='head_spa'));

alter table public.spa_staff_services add column if not exists enabled boolean not null default true;
alter table public.spa_staff_services add column if not exists price_override_cents bigint check(price_override_cents is null or price_override_cents>=0);
alter table public.spa_staff_services add column if not exists duration_override_minutes int check(duration_override_minutes is null or duration_override_minutes between 15 and 480);
alter table public.spa_staff_services add column if not exists commission_override_bps int check(commission_override_bps is null or commission_override_bps between 0 and 10000);

alter table public.spa_customers add column if not exists birthday date;
alter table public.spa_customers add column if not exists gender text not null default '';
alter table public.spa_customers add column if not exists status text not null default 'active' check(status in ('active','inactive','blocked'));
alter table public.spa_customers add column if not exists preferences text not null default '';
alter table public.spa_customers add column if not exists preferred_staff_id uuid references public.spa_staff;

alter table public.spa_appointments drop constraint if exists spa_appointments_status_check;
alter table public.spa_appointments add constraint spa_appointments_status_check check(status in ('pending','confirmed','checked_in','in_service','completed','cancelled','no_show'));
alter table public.spa_appointments add column if not exists service_name_snapshot text;
alter table public.spa_appointments add column if not exists duration_minutes_snapshot int;
alter table public.spa_appointments add column if not exists buffer_minutes_snapshot int;
alter table public.spa_appointments add column if not exists staff_name_snapshot text;
update public.spa_appointments a set
 service_name_snapshot=coalesce(a.service_name_snapshot,a.service_name),
 duration_minutes_snapshot=coalesce(a.duration_minutes_snapshot,greatest(1,(extract(epoch from a.ends_at-a.starts_at)/60)::int)),
 buffer_minutes_snapshot=coalesce(a.buffer_minutes_snapshot,greatest(0,(extract(epoch from a.blocked_until-a.ends_at)/60)::int)),
 staff_name_snapshot=coalesce(a.staff_name_snapshot,(select s.name from public.spa_staff s where s.id=a.staff_id));

create table if not exists public.spa_product_categories (
 id uuid primary key default gen_random_uuid(), code text unique not null,
 name text not null, name_en text not null default '', active boolean not null default true,
 display_order int not null default 0, archived_at timestamptz
);
insert into public.spa_product_categories(code,name,name_en,display_order) values
 ('tea_cake','茶餅','Tea cakes',10),('shampoo_bar','洗頭餅','Shampoo bars',20),
 ('essential_oil','精油','Essential oils',30),('tea_bag','養生茶包','Herbal tea bags',40)
on conflict(code) do nothing;

create table if not exists public.spa_products (
 id uuid primary key default gen_random_uuid(), sku text unique not null,
 category_id uuid references public.spa_product_categories(id), name text not null, name_en text not null default '',
 description text not null default '', description_en text not null default '', image_url text not null default '',
 price_cents bigint not null check(price_cents>=0), compare_price_cents bigint check(compare_price_cents is null or compare_price_cents>=0),
 cost_cents bigint check(cost_cents is null or cost_cents>=0), barcode text not null default '', unit_label text not null default '', unit_label_en text not null default '',
 low_stock_threshold int not null default 2 check(low_stock_threshold>=0), status text not null default 'draft' check(status in ('draft','active','archived')),
 website_visible boolean not null default false, store_visible boolean not null default false,
 display_order int not null default 0, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.spa_inventory_entries (
 id uuid primary key default gen_random_uuid(), product_id uuid not null references public.spa_products,
 delta int not null check(delta<>0), reason text not null, reference_type text not null default 'adjustment',
 reference_id uuid, created_by uuid references auth.users, created_at timestamptz not null default now()
);
create index if not exists spa_inventory_product on public.spa_inventory_entries(product_id,created_at);

create table if not exists public.spa_orders (
 id uuid primary key default gen_random_uuid(), reference text unique not null default ('SALE-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10))),
 request_id uuid unique not null default gen_random_uuid(),
 customer_id uuid references public.spa_customers, status text not null default 'draft' check(status in ('draft','paid','void','refunded')),
 subtotal_cents bigint not null default 0, discount_cents bigint not null default 0, total_cents bigint not null default 0,
 method text check(method is null or method in ('cash','card','transfer')), note text not null default '',
 created_by uuid not null references auth.users, paid_at timestamptz, created_at timestamptz not null default now()
);
create table if not exists public.spa_order_items (
 id uuid primary key default gen_random_uuid(), order_id uuid not null references public.spa_orders on delete cascade,
 product_id uuid references public.spa_products, service_id uuid references public.spa_services,
 item_type text not null check(item_type in ('product','service')),
 name_snapshot text not null, sku_snapshot text not null default '', unit_price_cents bigint not null check(unit_price_cents>=0),
 cost_snapshot_cents bigint, quantity int not null check(quantity>0), line_total_cents bigint not null check(line_total_cents>=0),
 staff_id uuid references public.spa_staff, commission_cents bigint not null default 0
);

create table if not exists public.spa_time_entries (
 id uuid primary key default gen_random_uuid(), staff_id uuid not null references public.spa_staff,
 work_date date not null, started_at timestamptz not null, ended_at timestamptz not null,
 break_minutes int not null default 0 check(break_minutes>=0), status text not null default 'approved' check(status in ('draft','approved','rejected')),
 note text not null default '', created_by uuid references auth.users, created_at timestamptz not null default now(), check(ended_at>started_at)
);
create table if not exists public.spa_overtime_entries (
 id uuid primary key default gen_random_uuid(), staff_id uuid not null references public.spa_staff,
 work_date date not null, overtime_type text not null check(overtime_type in ('weekday','rest_day','national_holiday','regular_holiday')),
 minutes int not null check(minutes between 1 and 720), reason text not null,
 status text not null default 'approved' check(status in ('draft','approved','rejected')),
 created_by uuid references auth.users, created_at timestamptz not null default now()
);

create table if not exists public.spa_payroll_rule_versions (
 id uuid primary key default gen_random_uuid(), version_no int unique not null,
 name text not null, effective_from date not null, status text not null default 'draft' check(status in ('draft','active','archived')),
 hourly_divisor int not null default 240 check(hourly_divisor>0), include_regular_commission boolean not null default true,
 monthly_overtime_limit_minutes int not null default 2760, agreed_monthly_limit_minutes int not null default 3240,
 quarterly_overtime_limit_minutes int not null default 8280,
 created_by uuid references auth.users, created_at timestamptz not null default now()
);
create table if not exists public.spa_payroll_overtime_rates (
 rule_version_id uuid not null references public.spa_payroll_rule_versions on delete cascade,
 employment_type_code text not null references public.spa_employment_types(code),
 overtime_type text not null check(overtime_type in ('weekday','rest_day','national_holiday','regular_holiday')),
 start_minute int not null, end_minute int not null, multiplier_bps int not null check(multiplier_bps between 0 and 100000),
 primary key(rule_version_id,employment_type_code,overtime_type,start_minute), check(end_minute>start_minute)
);
create table if not exists public.spa_payroll_commission_tiers (
 id uuid primary key default gen_random_uuid(), rule_version_id uuid not null references public.spa_payroll_rule_versions on delete cascade,
 metric text not null check(metric in ('service_minutes','service_count','service_sales_cents','product_sales_cents')),
 threshold_from bigint not null default 0, threshold_to bigint,
 rate_bps int not null check(rate_bps between 0 and 10000),
 service_category_id uuid references public.spa_service_categories,
 check(threshold_to is null or threshold_to>threshold_from)
);
create table if not exists public.spa_payroll_adjustments (
 id uuid primary key default gen_random_uuid(), staff_id uuid not null references public.spa_staff,
 period_start date not null, kind text not null check(kind in ('bonus','allowance','deduction','designated_bonus')),
 amount_cents bigint not null check(amount_cents>=0), note text not null,
 created_by uuid references auth.users, created_at timestamptz not null default now()
);
create table if not exists public.spa_payroll_runs (
 id uuid primary key default gen_random_uuid(), period_start date not null, period_end date not null,
 rule_version_id uuid not null references public.spa_payroll_rule_versions,
 status text not null default 'draft' check(status in ('draft','finalized')),
 calculation_snapshot jsonb not null default '{}'::jsonb, created_by uuid not null references auth.users,
 finalized_by uuid references auth.users, finalized_at timestamptz, reopened_by uuid references auth.users, reopened_at timestamptz,
 created_at timestamptz not null default now(), unique(period_start,period_end)
);
create table if not exists public.spa_payroll_items (
 id uuid primary key default gen_random_uuid(), run_id uuid not null references public.spa_payroll_runs on delete cascade,
 staff_id uuid not null references public.spa_staff, employment_type_snapshot text not null, role_snapshot text not null,
 work_minutes int not null default 0, service_minutes int not null default 0, service_sales_cents bigint not null default 0,
 product_sales_cents bigint not null default 0, designated_clients int not null default 0,
 base_cents bigint not null default 0, service_commission_cents bigint not null default 0,
 product_commission_cents bigint not null default 0, designated_bonus_cents bigint not null default 0,
 overtime_cents bigint not null default 0, bonus_cents bigint not null default 0, allowance_cents bigint not null default 0,
 deduction_cents bigint not null default 0, total_cents bigint not null default 0,
 calculation_snapshot jsonb not null default '{}'::jsonb, unique(run_id,staff_id)
);

create table if not exists public.spa_business_settings (
 key text primary key, value jsonb not null, updated_by uuid references auth.users, updated_at timestamptz not null default now()
);
insert into public.spa_business_settings(key,value) values
 ('business',jsonb_build_object('name','柔療髮浴','phone','0978-918-737','address','嘉義市西區蘭井街421號','timezone','Asia/Taipei')),
 ('website',jsonb_build_object('booking_cta',true,'show_staff',true,'show_products',true,'line_url','https://line.me/R/ti/p/@258llual')),
 ('inventory',jsonb_build_object('zero_stock_behavior','sold_out')),
 ('assignment',jsonb_build_object('enabled',true,'strategy','lowest_workload'))
on conflict(key) do nothing;

-- Default product master data replaces the previous hardcoded storefront list.
insert into public.spa_products(sku,category_id,name,name_en,description,description_en,price_cents,unit_label,unit_label_en,status,website_visible,store_visible,display_order)
select v.sku,c.id,v.name,v.name_en,v.description,v.description_en,v.price_cents,v.unit_label,v.unit_label_en,'active',true,true,v.ord
from (values
 ('TEA-001','tea_cake','雲南古樹普洱茶餅','Yunnan Ancient Tree Pu''er Cake','精選古樹茶菁，傳統手工壓製，陳香醇厚。','Hand-pressed ancient-tree Pu''er with a rich aged aroma.',128000,'357 g / 餅','357 g',10),
 ('TEA-002','tea_cake','桂花普洱小茶餅','Osmanthus Pu''er Mini Cake','普洱熟茶搭配天然桂花，甜潤順口。','Ripe Pu''er blended with natural osmanthus.',68000,'200 g / 餅','200 g',20),
 ('TEA-003','tea_cake','玫瑰花茶餅','Rose Flower Tea Cake','玫瑰花瓣與白茶壓製，花香與茶香交融。','Rose petals pressed with white tea.',58000,'150 g / 餅','150 g',30),
 ('TEA-004','tea_cake','陳皮老白茶餅','Aged Tangerine White Tea Cake','陳皮搭配老白茶，茶香醇和。','Aged tangerine peel with mellow white tea.',88000,'300 g / 餅','300 g',40),
 ('TEA-005','tea_cake','茉莉龍珠禮盒','Jasmine Dragon Pearl Gift Box','手工搓揉成珠，茉莉花香馥郁。','Hand-rolled jasmine pearls in a gift box.',96000,'12顆入 / 盒','12 pearls',50),
 ('BAR-001','shampoo_bar','何首烏養髮洗頭餅','He Shou Wu Hair Nourish Bar','何首烏、側柏葉與生薑萃取。','He Shou Wu, biota leaf and ginger extract.',48000,'80 g / 顆','80 g',60),
 ('BAR-002','shampoo_bar','茶籽控油洗頭餅','Tea Seed Oil Control Bar','苦茶籽油與薄荷，適合油性頭皮。','Camellia seed oil with cooling mint.',42000,'80 g / 顆','80 g',70),
 ('BAR-003','shampoo_bar','艾草淨化洗頭餅','Mugwort Purifying Bar','艾草與薰衣草精油的草本香氣。','Mugwort and lavender oil.',45000,'80 g / 顆','80 g',80),
 ('BAR-004','shampoo_bar','生薑暖養洗頭餅','Ginger Warming Bar','老薑精華帶來暖感與草本香氣。','Ginger essence with a warming herbal aroma.',45000,'80 g / 顆','80 g',90),
 ('OIL-001','essential_oil','頭療專用複方精油','Head Therapy Blend Oil','薰衣草、迷迭香、薄荷與天竺葵調配。','Lavender, rosemary, peppermint and geranium.',168000,'30 ml','30 ml',100),
 ('OIL-002','essential_oil','安神助眠精油','Sleep Well Essential Oil','柔和香氣，適合營造放鬆的居家氛圍。','A gentle aroma for a relaxing home atmosphere.',128000,'15 ml','15 ml',110),
 ('OIL-003','essential_oil','活血通絡按摩油','Circulation Massage Oil','草本浸泡油搭配甜杏仁基底油。','Herbal infused oil in a sweet-almond base.',98000,'50 ml','50 ml',120),
 ('OIL-004','essential_oil','艾草薰香精油','Mugwort Diffuser Oil','純天然艾草蒸餾精油。','Steam-distilled mugwort diffuser oil.',78000,'15 ml','15 ml',130),
 ('BAG-001','tea_bag','養生暖身茶（禮盒）','Warming Qi Tea Gift Box','紅棗、枸杞、桂圓與黃耆草本暖飲。','Red date, goji, longan and astragalus.',58000,'12包入','12 bags',140),
 ('BAG-002','tea_bag','漢方安神茶','Calming Sleep Tea','酸棗仁、茯苓、百合與甘草。','Jujube seed, poria, lily and licorice.',68000,'15包入','15 bags',150),
 ('BAG-003','tea_bag','活血美人茶','Beauty Bloom Tea','玫瑰、丹參、紅棗與桂花。','Rose, salvia, red date and osmanthus.',62000,'15包入','15 bags',160),
 ('BAG-004','tea_bag','清肝明目茶','Refreshing Eye Tea','菊花、決明子、枸杞與桑葉。','Chrysanthemum, cassia seed, goji and mulberry leaf.',56000,'15包入','15 bags',170),
 ('BAG-005','tea_bag','四季養生茶禮盒','Four Seasons Tea Gift Set','四款草本風味的季節禮盒。','Four seasonal herbal blends in a gift box.',168000,'4款各6包','4 × 6 bags',180)
) as v(sku,category_code,name,name_en,description,description_en,price_cents,unit_label,unit_label_en,ord)
join public.spa_product_categories c on c.code=v.category_code
on conflict(sku) do nothing;
insert into public.spa_inventory_entries(product_id,delta,reason,reference_type)
select id,20,'系統導入初始庫存','opening_balance' from public.spa_products p
where not exists(select 1 from public.spa_inventory_entries i where i.product_id=p.id);

update public.spa_services set description='完整頭療流程，包含清潔、舒緩與收尾。',description_en='A complete cleansing and relaxation head-therapy ritual.',
 website_content=case code
 when 'formula45' then '{"zh":[{"name":"苦茶籽潔淨髮浴","sub":"","steps":["頭肩頸筋絡按摩","頭皮洗淨","水療眼部","手技收尾"]}],"en":[{"name":"Camellia seed cleansing hair bath","sub":"","steps":["Head, shoulder and neck massage","Scalp cleanse","Eye-area water treatment","Finishing massage"]}]}'::jsonb
 when 'formula90' then '{"zh":[{"stamp":"清","name":"森呼吸","sub":"柔禾角質調理","steps":["頭肩頸筋絡按摩","臉部牛角刷去角質","綠豆泥頭皮去角質","舒緩泡腳","水療眼部","四肢放鬆","手技收尾"]},{"stamp":"養","name":"墨玉烏","sub":"60天木質萃湯浴","steps":["頭肩頸筋絡按摩","木質萃湯浴養髮","舒緩泡腳","水療眼部","四肢放鬆","手技收尾"]},{"stamp":"通","name":"薑暖陽","sub":"鮮薑溫通舒筋","steps":["頭肩頸筋絡按摩","鮮生薑頭部敷泥","舒緩泡腳","水療眼部","四肢放鬆","手技收尾"]}],"en":[{"stamp":"清","name":"Forest breath","sub":"Gentle exfoliating care","steps":["Head, shoulder and neck massage","Facial exfoliation with a horn brush","Mung bean scalp exfoliation","Relaxing foot soak","Eye-area water treatment","Arm and leg relaxation","Finishing massage"]},{"stamp":"養","name":"Jade botanical care","sub":"60-day botanical bath","steps":["Head, shoulder and neck massage","Botanical hair bath","Relaxing foot soak","Eye-area water treatment","Arm and leg relaxation","Finishing massage"]},{"stamp":"通","name":"Ginger warmth","sub":"Fresh ginger care","steps":["Head, shoulder and neck massage","Fresh ginger scalp mask","Relaxing foot soak","Eye-area water treatment","Arm and leg relaxation","Finishing massage"]}]}'::jsonb
 when 'formula120' then '{"zh":[{"stamp":"清","name":"森呼吸","sub":"柔禾角質調理","steps":["頭肩頸筋絡按摩","耳穴撥筋","眼部清濁","臉部牛角刷去角質","綠豆泥頭皮去角質","水乳面膜","舒緩泡腳","水療眼部","四肢放鬆","羽式采耳","手技收尾"]},{"stamp":"養","name":"墨玉烏","sub":"60天木質萃湯浴","steps":["頭肩頸筋絡按摩","耳穴撥筋","眼部清濁","木質萃湯浴養髮","水乳面膜","舒緩泡腳","水療眼部","四肢放鬆","羽式采耳","手技收尾"]},{"stamp":"通","name":"薑暖陽","sub":"鮮薑溫通舒筋","steps":["頭肩頸筋絡按摩","耳穴撥筋","眼部清濁","鮮生薑頭部敷泥","水乳面膜","舒緩泡腳","水療眼部","四肢放鬆","羽式采耳","手技收尾"]}],"en":[{"stamp":"清","name":"Forest breath","sub":"Gentle exfoliating care","steps":["Head, shoulder and neck massage","Ear-area massage","Eye-area care","Facial exfoliation with a horn brush","Mung bean scalp exfoliation","Hydrating face mask","Relaxing foot soak","Eye-area water treatment","Arm and leg relaxation","Gentle ear care","Finishing massage"]},{"stamp":"養","name":"Jade botanical care","sub":"60-day botanical bath","steps":["Head, shoulder and neck massage","Ear-area massage","Eye-area care","Botanical hair bath","Hydrating face mask","Relaxing foot soak","Eye-area water treatment","Arm and leg relaxation","Gentle ear care","Finishing massage"]},{"stamp":"通","name":"Ginger warmth","sub":"Fresh ginger care","steps":["Head, shoulder and neck massage","Ear-area massage","Eye-area care","Fresh ginger scalp mask","Hydrating face mask","Relaxing foot soak","Eye-area water treatment","Arm and leg relaxation","Gentle ear care","Finishing massage"]}]}'::jsonb
 else website_content end;

create or replace function spa_private.has_permission(p_permission text) returns boolean
language sql stable security definer set search_path='' as $$
 select coalesce(spa_private.role_name()='owner' or exists(
  select 1 from public.spa_roles r join public.spa_role_permissions rp on rp.role_code=r.role
  where r.user_id=auth.uid() and r.active and rp.permission_code=p_permission
 ),false)
$$;
create or replace function spa_private.require_permission(p_permission text) returns void
language plpgsql stable security definer set search_path='' as $$
begin
 if not spa_private.has_permission(p_permission) then raise exception 'FORBIDDEN' using errcode='42501'; end if;
end $$;

create or replace function spa_private.snapshot_appointment() returns trigger
language plpgsql security definer set search_path='' as $$
declare service_row public.spa_services; staff_row public.spa_staff;
begin
 select * into service_row from public.spa_services where id=new.service_id;
 select * into staff_row from public.spa_staff where id=new.staff_id;
 new.service_name_snapshot:=coalesce(new.service_name_snapshot,new.service_name,service_row.name);
 new.duration_minutes_snapshot:=coalesce(new.duration_minutes_snapshot,service_row.duration_minutes,(extract(epoch from new.ends_at-new.starts_at)/60)::int);
 new.buffer_minutes_snapshot:=coalesce(new.buffer_minutes_snapshot,service_row.buffer_minutes,(extract(epoch from new.blocked_until-new.ends_at)/60)::int);
 new.staff_name_snapshot:=coalesce(new.staff_name_snapshot,staff_row.name);
 return new;
end $$;
drop trigger if exists spa_appointment_snapshot on public.spa_appointments;
create trigger spa_appointment_snapshot before insert on public.spa_appointments for each row execute function spa_private.snapshot_appointment();

create or replace function public.spa_catalog() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
 'settings',(select to_jsonb(s) from public.spa_settings s),
 'business',(select value from public.spa_business_settings where key='business'),
 'website',(select value from public.spa_business_settings where key='website'),
 'services',coalesce((select jsonb_agg(to_jsonb(s) order by display_order) from public.spa_services s
   where active and status='active' and online_booking_enabled),'[]'),
 'website_services',coalesce((select jsonb_agg(to_jsonb(s) order by display_order) from public.spa_services s
   where active and status='active' and website_visible),'[]'),
 'staff',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'name_en',name_en,'title',title,
   'specialty',specialty,'bio',bio,'photo_url',photo_url) order by display_order) from public.spa_staff
   where active and archived_at is null and is_bookable),'[]'),
 'website_staff',coalesce((select jsonb_agg(jsonb_build_object('id',id,'name',name,'name_en',name_en,'title',title,
   'specialty',specialty,'bio',bio,'photo_url',photo_url) order by display_order) from public.spa_staff
   where active and archived_at is null and website_visible),'[]'),
 'skills',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_staff_services s where enabled),'[]'))
$$;

create or replace function public.spa_store_catalog() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
  'settings',(select value from public.spa_business_settings where key='inventory'),
  'categories',coalesce((select jsonb_agg(to_jsonb(c) order by display_order) from public.spa_product_categories c where active and archived_at is null),'[]'),
  'products',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('inventory',coalesce((select sum(i.delta) from public.spa_inventory_entries i where i.product_id=p.id),0)) order by p.display_order)
   from public.spa_products p where p.status='active' and p.website_visible and p.store_visible),'[]'))
$$;

create or replace function public.spa_session() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('role',spa_private.role_name(),
 'role_name',(select p.name from public.spa_role_profiles p where p.code=spa_private.role_name()),
 'permissions',coalesce((select jsonb_agg(rp.permission_code order by rp.permission_code) from public.spa_role_permissions rp where rp.role_code=spa_private.role_name()),'[]'),
 'staff_id',(select staff_id from public.spa_roles where user_id=auth.uid() and active),
 'username',(select login_name from public.spa_roles where user_id=auth.uid() and active),
 'customer_id',(select id from public.spa_customers where auth_user_id=auth.uid()))
$$;

create or replace function public.spa_dashboard() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare today date:=(now() at time zone 'Asia/Taipei')::date;
begin
 perform spa_private.require_permission('dashboard.view');
 return jsonb_build_object(
  'date',today,
  'appointments',(select count(*) from public.spa_appointments where business_date=today),
  'pending',(select count(*) from public.spa_appointments where business_date=today and status='pending'),
  'completed',(select count(*) from public.spa_appointments where business_date=today and status='completed'),
  'cancelled',(select count(*) from public.spa_appointments where business_date=today and status in ('cancelled','no_show')),
  'revenue_cents',coalesce((select sum(ch.revenue_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.business_date=today and ch.refunded_at is null),0),
  'staff_working',(select count(distinct sh.staff_id) from public.spa_shifts sh join public.spa_staff s on s.id=sh.staff_id where sh.weekday=extract(dow from today)::int and s.active and s.archived_at is null),
  'rooms_active',(select count(*) from public.spa_rooms where active),
  'new_members',(select count(*) from public.spa_customers where (created_at at time zone 'Asia/Taipei')::date=today),
  'low_stock',(select count(*) from public.spa_products p where p.status='active' and coalesce((select sum(i.delta) from public.spa_inventory_entries i where i.product_id=p.id),0)<=p.low_stock_threshold),
  'next_appointments',coalesce((select jsonb_agg(to_jsonb(x)) from (select a.id,a.reference,a.starts_at,a.status,a.service_name_snapshot service_name,
    c.name customer_name,s.name staff_name,r.name resource_name from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id
    join public.spa_staff s on s.id=a.staff_id join public.spa_rooms r on r.id=a.room_id
    where a.business_date=today and a.status not in ('cancelled','no_show') order by a.starts_at limit 8) x),'[]'));
end $$;

create or replace function public.spa_global_search(p_query text) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare q text:='%'||lower(btrim(coalesce(p_query,'')))||'%';
begin
 perform spa_private.require_permission('dashboard.view');
 if length(btrim(coalesce(p_query,'')))<2 then return '[]'::jsonb; end if;
 return coalesce((select jsonb_agg(to_jsonb(x)) from (
  select 'customer' kind,c.id::text id,c.name title,c.phone subtitle from public.spa_customers c where spa_private.has_permission('customers.view') and (lower(c.name) like q or c.phone like q)
  union all select 'appointment',a.id::text,a.reference,c.name||' · '||a.service_name_snapshot from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id where spa_private.has_permission('appointments.view') and (lower(a.reference) like q or lower(c.name) like q)
  union all select 'staff',s.id::text,s.name,s.title from public.spa_staff s where spa_private.has_permission('team.view') and lower(s.name) like q
  union all select 'service',s.id::text,s.name,s.code from public.spa_services s where spa_private.has_permission('catalog.view') and lower(s.name) like q
  union all select 'product',p.id::text,p.name,p.sku from public.spa_products p where spa_private.has_permission('catalog.view') and (lower(p.name) like q or lower(p.sku) like q)
  limit 30) x),'[]');
end $$;

create or replace function public.spa_team_os() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('team.view');
 return jsonb_build_object(
  'staff',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('employment_type_name',e.name,'job_title_name',j.name) order by s.display_order,s.created_at)
    from public.spa_staff s left join public.spa_employment_types e on e.code=s.employment_type_code left join public.spa_job_titles j on j.id=s.job_title_id),'[]'),
  'employment_types',coalesce((select jsonb_agg(to_jsonb(e) order by display_order) from public.spa_employment_types e),'[]'),
  'job_titles',coalesce((select jsonb_agg(to_jsonb(j) order by display_order) from public.spa_job_titles j),'[]'),
  'role_profiles',coalesce((select jsonb_agg(to_jsonb(r) order by display_order) from public.spa_role_profiles r),'[]'),
  'shifts',coalesce((select jsonb_agg(to_jsonb(s)) from public.spa_shifts s),'[]'),
  'time_off',coalesce((select jsonb_agg(to_jsonb(t) order by starts_at) from public.spa_time_off t where ends_at>now()-interval '30 days'),'[]'),
  'accounts',case when spa_private.has_permission('team.manage') then coalesce((select jsonb_agg(jsonb_build_object('user_id',r.user_id,'role',r.role,'staff_id',r.staff_id,'active',r.active,'username',r.login_name,'email',case when r.role='owner' then u.email end)) from public.spa_roles r join auth.users u on u.id=r.user_id),'[]') else '[]'::jsonb end);
end $$;

create or replace function public.spa_access_admin() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('settings.manage');
 return jsonb_build_object(
  'roles',coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('permissions',coalesce((select jsonb_agg(rp.permission_code order by rp.permission_code) from public.spa_role_permissions rp where rp.role_code=r.code),'[]'::jsonb)) order by r.display_order) from public.spa_role_profiles r),'[]'),
  'permissions',coalesce((select jsonb_agg(to_jsonb(p) order by p.display_order) from public.spa_permission_definitions p),'[]'));
end $$;

create or replace function public.spa_role_profile_save(p_code text,p_name text,p_permissions text[],p_active boolean,p_display_order int) returns void
language plpgsql security definer set search_path='' as $$
declare normalized text:=lower(btrim(p_code)); old jsonb;
begin
 perform spa_private.require_permission('settings.manage');
 if normalized='owner' then raise exception 'OWNER_PROTECTED'; end if;
 if normalized !~ '^[a-z][a-z0-9_]{1,31}$' or length(btrim(p_name)) not between 1 and 80 then raise exception 'INVALID_INPUT'; end if;
 if exists(select 1 from unnest(coalesce(p_permissions,'{}'::text[])) x where not exists(select 1 from public.spa_permission_definitions p where p.code=x)) then raise exception 'INVALID_PERMISSION'; end if;
 select to_jsonb(r)||jsonb_build_object('permissions',coalesce((select jsonb_agg(permission_code) from public.spa_role_permissions where role_code=r.code),'[]'::jsonb)) into old from public.spa_role_profiles r where code=normalized;
 insert into public.spa_role_profiles(code,name,active,display_order) values(normalized,btrim(p_name),p_active,p_display_order)
 on conflict(code) do update set name=excluded.name,active=excluded.active,display_order=excluded.display_order,archived_at=case when excluded.active then null else coalesce(spa_role_profiles.archived_at,now()) end;
 delete from public.spa_role_permissions where role_code=normalized;
 insert into public.spa_role_permissions(role_code,permission_code) select normalized,unnest(coalesce(p_permissions,'{}'::text[]));
 perform spa_private.audit('role_profile.saved',normalized,jsonb_build_object('old',old,'new',jsonb_build_object('name',p_name,'active',p_active,'permissions',p_permissions)));
end $$;

create or replace function public.spa_reference_save(p_kind text,p_code text,p_name text,p_active boolean,p_display_order int,p_id uuid default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid; normalized text:=lower(btrim(p_code));
begin
 perform spa_private.require_permission('team.manage');
 if normalized !~ '^[a-z][a-z0-9_]{1,31}$' or length(btrim(p_name)) not between 1 and 80 then raise exception 'INVALID_INPUT'; end if;
 if p_kind='employment' then
  insert into public.spa_employment_types(code,name,active,display_order,archived_at) values(normalized,btrim(p_name),p_active,p_display_order,case when p_active then null else now() end)
  on conflict(code) do update set name=excluded.name,active=excluded.active,display_order=excluded.display_order,archived_at=case when excluded.active then null else coalesce(spa_employment_types.archived_at,now()) end;
  perform spa_private.audit('employment_type.saved',normalized,jsonb_build_object('name',p_name,'active',p_active)); return null;
 elsif p_kind='title' then
  if p_id is null then insert into public.spa_job_titles(code,name,active,display_order) values(normalized,btrim(p_name),p_active,p_display_order) returning id into result;
  else update public.spa_job_titles set code=normalized,name=btrim(p_name),active=p_active,display_order=p_display_order,archived_at=case when p_active then null else coalesce(archived_at,now()) end where id=p_id returning id into result; end if;
  perform spa_private.audit('job_title.saved',result::text,jsonb_build_object('name',p_name,'active',p_active)); return result;
 end if;
 raise exception 'INVALID_INPUT';
end $$;

create or replace function public.spa_staff_profile_save_v2(p_payload jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid:=nullif(p_payload->>'id','')::uuid; old jsonb; services uuid[];
begin
 perform spa_private.require_permission('team.manage');
 if length(btrim(coalesce(p_payload->>'name',''))) not between 1 and 80 then raise exception 'INVALID_INPUT'; end if;
 select to_jsonb(s) into old from public.spa_staff s where s.id=result;
 if result is null then
  insert into public.spa_staff(name,name_en,title,specialty,bio,commission_bps,active,pay_basis,base_pay_cents,photo_url,phone,email,birth_date,address,hire_date,employment_type_code,job_title_id,is_bookable,website_visible)
  values(btrim(p_payload->>'name'),coalesce(p_payload->>'name_en',''),coalesce(p_payload->>'title','調理師'),coalesce(p_payload->>'specialty',''),coalesce(p_payload->>'bio',''),
   coalesce((p_payload->>'commission_bps')::int,0),coalesce((p_payload->>'active')::boolean,true),coalesce(p_payload->>'pay_basis','monthly'),nullif(p_payload->>'base_pay_cents','')::bigint,
   coalesce(p_payload->>'photo_url',''),coalesce(p_payload->>'phone',''),coalesce(p_payload->>'email',''),nullif(p_payload->>'birth_date','')::date,coalesce(p_payload->>'address',''),nullif(p_payload->>'hire_date','')::date,
   coalesce(p_payload->>'employment_type_code','full_time'),nullif(p_payload->>'job_title_id','')::uuid,coalesce((p_payload->>'is_bookable')::boolean,true),coalesce((p_payload->>'website_visible')::boolean,true)) returning id into result;
 else
  update public.spa_staff set name=btrim(p_payload->>'name'),name_en=coalesce(p_payload->>'name_en',''),title=coalesce(p_payload->>'title',title),specialty=coalesce(p_payload->>'specialty',''),bio=coalesce(p_payload->>'bio',''),
   commission_bps=coalesce((p_payload->>'commission_bps')::int,commission_bps),active=coalesce((p_payload->>'active')::boolean,active),pay_basis=coalesce(p_payload->>'pay_basis',pay_basis),base_pay_cents=nullif(p_payload->>'base_pay_cents','')::bigint,
   photo_url=coalesce(p_payload->>'photo_url',''),phone=coalesce(p_payload->>'phone',''),email=coalesce(p_payload->>'email',''),birth_date=nullif(p_payload->>'birth_date','')::date,address=coalesce(p_payload->>'address',''),hire_date=nullif(p_payload->>'hire_date','')::date,
   employment_type_code=coalesce(p_payload->>'employment_type_code',employment_type_code),job_title_id=nullif(p_payload->>'job_title_id','')::uuid,is_bookable=coalesce((p_payload->>'is_bookable')::boolean,is_bookable),website_visible=coalesce((p_payload->>'website_visible')::boolean,website_visible)
  where id=result and archived_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
 end if;
 services:=array(select jsonb_array_elements_text(coalesce(p_payload->'services','[]'::jsonb))::uuid);
 delete from public.spa_staff_services where staff_id=result;
 insert into public.spa_staff_services(staff_id,service_id,enabled) select result,unnest(services),true;
 perform spa_private.audit('staff.profile_saved',result::text,jsonb_build_object('old',old,'new',p_payload-'services'));
 return result;
end $$;

create or replace function public.spa_catalog_admin() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('catalog.view');
 return jsonb_build_object(
  'service_categories',coalesce((select jsonb_agg(to_jsonb(c) order by display_order) from public.spa_service_categories c),'[]'),
  'services',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('category_name',c.name) order by s.display_order) from public.spa_services s left join public.spa_service_categories c on c.id=s.category_id),'[]'),
  'product_categories',coalesce((select jsonb_agg(to_jsonb(c) order by display_order) from public.spa_product_categories c),'[]'),
  'products',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('category_name',c.name,'inventory',coalesce((select sum(i.delta) from public.spa_inventory_entries i where i.product_id=p.id),0)) order by p.display_order)
    from public.spa_products p left join public.spa_product_categories c on c.id=p.category_id),'[]'));
end $$;

create or replace function public.spa_service_save_v2(p_payload jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid:=nullif(p_payload->>'id','')::uuid; old jsonb;
begin
 perform spa_private.require_permission('catalog.manage');
 if length(btrim(coalesce(p_payload->>'name',''))) not between 1 and 120 or coalesce((p_payload->>'duration_minutes')::int,0) not between 15 and 480 or coalesce((p_payload->>'price_cents')::bigint,-1)<0 then raise exception 'INVALID_INPUT'; end if;
 select to_jsonb(s) into old from public.spa_services s where s.id=result;
 if result is null then
  insert into public.spa_services(code,name,name_en,duration_minutes,buffer_minutes,price_cents,active,display_order,category_id,description,description_en,image_url,member_price_cents,online_booking_enabled,website_visible,status,website_content)
  values(coalesce(nullif(p_payload->>'code',''),'service_'||substr(replace(gen_random_uuid()::text,'-',''),1,10)),btrim(p_payload->>'name'),coalesce(p_payload->>'name_en',''),(p_payload->>'duration_minutes')::int,coalesce((p_payload->>'buffer_minutes')::int,15),(p_payload->>'price_cents')::bigint,
   coalesce((p_payload->>'status')='active',true),coalesce((p_payload->>'display_order')::int,0),nullif(p_payload->>'category_id','')::uuid,coalesce(p_payload->>'description',''),coalesce(p_payload->>'description_en',''),coalesce(p_payload->>'image_url',''),nullif(p_payload->>'member_price_cents','')::bigint,
   coalesce((p_payload->>'online_booking_enabled')::boolean,false),coalesce((p_payload->>'website_visible')::boolean,false),coalesce(p_payload->>'status','draft'),coalesce(p_payload->'website_content','{}'::jsonb)) returning id into result;
 else
  update public.spa_services set name=btrim(p_payload->>'name'),name_en=coalesce(p_payload->>'name_en',''),duration_minutes=(p_payload->>'duration_minutes')::int,buffer_minutes=coalesce((p_payload->>'buffer_minutes')::int,buffer_minutes),price_cents=(p_payload->>'price_cents')::bigint,
   active=coalesce((p_payload->>'status')='active',active),display_order=coalesce((p_payload->>'display_order')::int,display_order),category_id=nullif(p_payload->>'category_id','')::uuid,description=coalesce(p_payload->>'description',''),description_en=coalesce(p_payload->>'description_en',''),image_url=coalesce(p_payload->>'image_url',''),
   member_price_cents=nullif(p_payload->>'member_price_cents','')::bigint,online_booking_enabled=coalesce((p_payload->>'online_booking_enabled')::boolean,online_booking_enabled),website_visible=coalesce((p_payload->>'website_visible')::boolean,website_visible),status=coalesce(p_payload->>'status',status),website_content=coalesce(p_payload->'website_content',website_content)
  where id=result;
  if not found then raise exception 'NOT_FOUND'; end if;
 end if;
 perform spa_private.audit('service.saved',result::text,jsonb_build_object('old',old,'new',p_payload)); return result;
end $$;

create or replace function public.spa_product_save(p_payload jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid:=nullif(p_payload->>'id','')::uuid; old jsonb;
begin
 perform spa_private.require_permission('catalog.manage');
 if length(btrim(coalesce(p_payload->>'name',''))) not between 1 and 120 or length(btrim(coalesce(p_payload->>'sku',''))) not between 1 and 80 or coalesce((p_payload->>'price_cents')::bigint,-1)<0 then raise exception 'INVALID_INPUT'; end if;
 select to_jsonb(p) into old from public.spa_products p where p.id=result;
 if result is null then
  insert into public.spa_products(sku,category_id,name,name_en,description,description_en,image_url,price_cents,compare_price_cents,cost_cents,barcode,unit_label,unit_label_en,low_stock_threshold,status,website_visible,store_visible,display_order)
  values(upper(btrim(p_payload->>'sku')),nullif(p_payload->>'category_id','')::uuid,btrim(p_payload->>'name'),coalesce(p_payload->>'name_en',''),coalesce(p_payload->>'description',''),coalesce(p_payload->>'description_en',''),coalesce(p_payload->>'image_url',''),(p_payload->>'price_cents')::bigint,nullif(p_payload->>'compare_price_cents','')::bigint,nullif(p_payload->>'cost_cents','')::bigint,coalesce(p_payload->>'barcode',''),coalesce(p_payload->>'unit_label',''),coalesce(p_payload->>'unit_label_en',''),coalesce((p_payload->>'low_stock_threshold')::int,2),coalesce(p_payload->>'status','draft'),coalesce((p_payload->>'website_visible')::boolean,false),coalesce((p_payload->>'store_visible')::boolean,false),coalesce((p_payload->>'display_order')::int,0)) returning id into result;
 else
  update public.spa_products set sku=upper(btrim(p_payload->>'sku')),category_id=nullif(p_payload->>'category_id','')::uuid,name=btrim(p_payload->>'name'),name_en=coalesce(p_payload->>'name_en',''),description=coalesce(p_payload->>'description',''),description_en=coalesce(p_payload->>'description_en',''),image_url=coalesce(p_payload->>'image_url',''),price_cents=(p_payload->>'price_cents')::bigint,
   compare_price_cents=nullif(p_payload->>'compare_price_cents','')::bigint,cost_cents=nullif(p_payload->>'cost_cents','')::bigint,barcode=coalesce(p_payload->>'barcode',''),unit_label=coalesce(p_payload->>'unit_label',''),unit_label_en=coalesce(p_payload->>'unit_label_en',''),low_stock_threshold=coalesce((p_payload->>'low_stock_threshold')::int,low_stock_threshold),status=coalesce(p_payload->>'status',status),website_visible=coalesce((p_payload->>'website_visible')::boolean,website_visible),store_visible=coalesce((p_payload->>'store_visible')::boolean,store_visible),display_order=coalesce((p_payload->>'display_order')::int,display_order),updated_at=now()
  where id=result;
  if not found then raise exception 'NOT_FOUND'; end if;
 end if;
 perform spa_private.audit('product.saved',result::text,jsonb_build_object('old',old,'new',p_payload)); return result;
end $$;

create or replace function public.spa_inventory_adjust(p_product uuid,p_delta int,p_reason text) returns void language plpgsql security definer set search_path='' as $$
declare current_qty bigint;
begin
 perform spa_private.require_permission('catalog.manage');
 if p_delta=0 or length(btrim(coalesce(p_reason,'')))=0 then raise exception 'INVALID_INPUT'; end if;
 perform pg_advisory_xact_lock(hashtext(p_product::text));
 select coalesce(sum(delta),0) into current_qty from public.spa_inventory_entries where product_id=p_product;
 if current_qty+p_delta<0 then raise exception 'INSUFFICIENT_INVENTORY'; end if;
 insert into public.spa_inventory_entries(product_id,delta,reason,created_by) values(p_product,p_delta,btrim(p_reason),auth.uid());
 perform spa_private.audit('inventory.adjusted',p_product::text,jsonb_build_object('delta',p_delta,'reason',p_reason));
end $$;

create or replace function public.spa_catalog_bulk(p_kind text,p_ids uuid[],p_action text,p_value text default null) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('catalog.manage');
 if coalesce(array_length(p_ids,1),0)=0 or array_length(p_ids,1)>200 then raise exception 'INVALID_INPUT'; end if;
 if p_kind='product' and p_action in ('publish','unpublish','archive') then
  update public.spa_products set status=case when p_action='publish' then 'active' when p_action='archive' then 'archived' else status end,
   website_visible=case when p_action='publish' then true when p_action='unpublish' then false else website_visible end,
   store_visible=case when p_action='publish' then true when p_action='unpublish' then false else store_visible end where id=any(p_ids);
 elsif p_kind='service' and p_action in ('publish','unpublish','archive') then
  update public.spa_services set status=case when p_action='publish' then 'active' when p_action='archive' then 'archived' else status end,
   active=case when p_action='publish' then true when p_action='archive' then false else active end,
   website_visible=case when p_action='publish' then true when p_action='unpublish' then false else website_visible end,
   online_booking_enabled=case when p_action='publish' then true when p_action='unpublish' then false else online_booking_enabled end where id=any(p_ids);
 else raise exception 'INVALID_INPUT'; end if;
 perform spa_private.audit('catalog.bulk',p_kind,jsonb_build_object('ids',p_ids,'action',p_action,'value',p_value));
end $$;

insert into public.spa_payroll_rule_versions(version_no,name,effective_from,status,hourly_divisor,include_regular_commission)
select 1,'2026 法定加班與門店薪資規則','2026-01-01','active',240,true
where not exists(select 1 from public.spa_payroll_rule_versions);
insert into public.spa_payroll_overtime_rates(rule_version_id,employment_type_code,overtime_type,start_minute,end_minute,multiplier_bps)
select v.id,r.employment,r.kind,r.start_minute,r.end_minute,r.multiplier
from public.spa_payroll_rule_versions v cross join (values
 ('full_time','weekday',0,120,13400),('full_time','weekday',120,240,16700),('full_time','weekday',240,720,16700),
 ('part_time','weekday',0,120,13400),('part_time','weekday',120,240,16700),('part_time','weekday',240,720,16700),
 ('full_time','rest_day',0,120,13400),('full_time','rest_day',120,480,16700),('full_time','rest_day',480,720,26700),
 ('part_time','rest_day',0,120,13400),('part_time','rest_day',120,480,16700),('part_time','rest_day',480,720,26700),
 ('full_time','national_holiday',0,480,10000),('full_time','national_holiday',480,600,13400),('full_time','national_holiday',600,720,16700),
 ('part_time','national_holiday',0,480,20000),('part_time','national_holiday',480,600,13400),('part_time','national_holiday',600,720,16700),
 ('full_time','regular_holiday',0,480,10000),('full_time','regular_holiday',480,720,20000),
 ('part_time','regular_holiday',0,720,20000)
) as r(employment,kind,start_minute,end_minute,multiplier)
where v.version_no=1 on conflict do nothing;

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
  select s.id,s.name,s.title,s.employment_type_code,s.pay_basis,coalesce(s.base_pay_cents,0) base_pay_cents,s.commission_bps,
   coalesce((select sum(greatest(0,(extract(epoch from te.ended_at-te.started_at)/60)::int-te.break_minutes)) from public.spa_time_entries te where te.staff_id=s.id and te.work_date between p_from and p_to and te.status='approved'),0)::bigint work_minutes,
   coalesce((select count(*) from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint service_count,
   coalesce((select sum(a.duration_minutes_snapshot) from public.spa_appointments a where a.staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint service_minutes,
   coalesce((select sum(ch.revenue_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to and ch.refunded_at is null),0)::bigint service_sales_cents,
   coalesce((select sum(ch.commission_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to and ch.refunded_at is null),0)::bigint checkout_commission_cents,
   coalesce((select sum(oi.line_total_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and oi.item_type='product' and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0)::bigint product_sales_cents,
   coalesce((select sum(oi.commission_cents) from public.spa_order_items oi join public.spa_orders o on o.id=oi.order_id where oi.staff_id=s.id and o.status='paid' and (o.paid_at at time zone 'Asia/Taipei')::date between p_from and p_to),0)::bigint checkout_product_commission_cents,
   coalesce((select count(*) from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id where a.staff_id=s.id and c.preferred_staff_id=s.id and a.business_date between p_from and p_to and a.status='completed'),0)::bigint designated_clients,
   coalesce((select sum(case when pa.kind='designated_bonus' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint designated_bonus_cents,
   coalesce((select sum(case when pa.kind='bonus' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint bonus_cents,
   coalesce((select sum(case when pa.kind='allowance' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint allowance_cents,
   coalesce((select sum(case when pa.kind='deduction' then pa.amount_cents else 0 end) from public.spa_payroll_adjustments pa where pa.staff_id=s.id and pa.period_start=p_from),0)::bigint deduction_cents,
   coalesce((select sum(o.minutes) from public.spa_overtime_entries o where o.staff_id=s.id and o.work_date between p_from and p_to and o.status='approved'),0)::bigint overtime_minutes
  from public.spa_staff s where s.created_at::date<=p_to
 ), commission as (
  select m.*,coalesce((select round(m.service_sales_cents*t.rate_bps/10000.0)::bigint from public.spa_payroll_commission_tiers t
    where t.rule_version_id=version.id and t.metric in ('service_minutes','service_count','service_sales_cents') and ((t.metric='service_minutes' and m.service_minutes>=t.threshold_from and (t.threshold_to is null or m.service_minutes<t.threshold_to))
      or (t.metric='service_count' and m.service_count>=t.threshold_from and (t.threshold_to is null or m.service_count<t.threshold_to))
      or (t.metric='service_sales_cents' and m.service_sales_cents>=t.threshold_from and (t.threshold_to is null or m.service_sales_cents<t.threshold_to)))
    order by t.threshold_from desc limit 1),m.checkout_commission_cents) service_commission_cents,
   coalesce((select round(m.product_sales_cents*t.rate_bps/10000.0)::bigint from public.spa_payroll_commission_tiers t
    where t.rule_version_id=version.id and t.metric='product_sales_cents' and m.product_sales_cents>=t.threshold_from and (t.threshold_to is null or m.product_sales_cents<t.threshold_to)
    order by t.threshold_from desc limit 1),m.checkout_product_commission_cents) product_commission_cents
  from staff_metrics m
 ), base_calc as (
  select c.*,case when c.pay_basis='monthly' then c.base_pay_cents when c.pay_basis='hourly' then round(c.base_pay_cents*c.work_minutes/60.0)::bigint else c.base_pay_cents*c.service_count end base_cents
  from commission c
 ), overtime_calc as (
  select b.*,coalesce((select round(sum(
    (case when b.pay_basis='monthly' then (b.base_pay_cents+case when version.include_regular_commission then b.service_commission_cents+b.designated_bonus_cents else 0 end)/version.hourly_divisor::numeric
          when b.pay_basis='hourly' then b.base_pay_cents::numeric else 0 end)
    *greatest(0,least(o.minutes,r.end_minute)-r.start_minute)/60.0*r.multiplier_bps/10000.0))::bigint
   from public.spa_overtime_entries o join public.spa_payroll_overtime_rates r on r.rule_version_id=version.id and r.employment_type_code=b.employment_type_code and r.overtime_type=o.overtime_type
   where o.staff_id=b.id and o.work_date between p_from and p_to and o.status='approved' and o.minutes>r.start_minute),0) overtime_cents
  from base_calc b
 )
 select jsonb_agg(jsonb_build_object(
  'staff_id',id,'employee',name,'role',title,'employment_type',employment_type_code,'work_minutes',work_minutes,'service_count',service_count,'service_minutes',service_minutes,
  'service_sales_cents',service_sales_cents,'product_sales_cents',product_sales_cents,'designated_clients',designated_clients,'overtime_minutes',overtime_minutes,
  'base_cents',base_cents,'service_commission_cents',service_commission_cents,'product_commission_cents',product_commission_cents,'designated_bonus_cents',designated_bonus_cents,
  'overtime_cents',overtime_cents,'bonus_cents',bonus_cents,'allowance_cents',allowance_cents,'deduction_cents',deduction_cents,
  'total_cents',greatest(0,base_cents+service_commission_cents+product_commission_cents+designated_bonus_cents+overtime_cents+bonus_cents+allowance_cents-deduction_cents),
  'overtime_warning',case when overtime_minutes>version.agreed_monthly_limit_minutes then '超過每月 54 小時上限' when overtime_minutes>version.monthly_overtime_limit_minutes then '超過一般每月 46 小時上限' else '' end,
  'calculation',jsonb_build_object('rule_version',version.version_no,'hourly_divisor',version.hourly_divisor,'include_regular_commission',version.include_regular_commission)) order by name)
 from overtime_calc),'[]');
end $$;

create or replace function public.spa_payroll_admin(p_from date,p_to date,p_rule uuid default null) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.view');
 return jsonb_build_object(
  'staff',coalesce((select jsonb_agg(to_jsonb(s) order by display_order,name) from public.spa_staff s),'[]'),
  'rules',coalesce((select jsonb_agg(to_jsonb(v) order by version_no desc) from public.spa_payroll_rule_versions v),'[]'),
  'rates',coalesce((select jsonb_agg(to_jsonb(r) order by overtime_type,employment_type_code,start_minute) from public.spa_payroll_overtime_rates r),'[]'),
  'tiers',coalesce((select jsonb_agg(to_jsonb(t) order by metric,threshold_from) from public.spa_payroll_commission_tiers t),'[]'),
  'overtime',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('employee',s.name) order by work_date desc) from public.spa_overtime_entries o join public.spa_staff s on s.id=o.staff_id where o.work_date between p_from and p_to),'[]'),
  'adjustments',coalesce((select jsonb_agg(to_jsonb(a)||jsonb_build_object('employee',s.name) order by a.created_at desc) from public.spa_payroll_adjustments a join public.spa_staff s on s.id=a.staff_id where a.period_start=p_from),'[]'),
  'runs',coalesce((select jsonb_agg(to_jsonb(r) order by period_start desc) from public.spa_payroll_runs r limit 24),'[]'),
  'preview',public.spa_payroll_preview(p_from,p_to,p_rule));
end $$;

create or replace function public.spa_overtime_save(p_staff uuid,p_date date,p_type text,p_minutes int,p_reason text) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 perform spa_private.require_permission('payroll.manage');
 if p_type not in ('weekday','rest_day','national_holiday','regular_holiday') or p_minutes not between 1 and 720 or length(btrim(coalesce(p_reason,'')))=0 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_overtime_entries(staff_id,work_date,overtime_type,minutes,reason,created_by) values(p_staff,p_date,p_type,p_minutes,btrim(p_reason),auth.uid()) returning id into result;
 perform spa_private.audit('overtime.created',result::text,jsonb_build_object('staff_id',p_staff,'date',p_date,'type',p_type,'minutes',p_minutes)); return result;
end $$;

create or replace function public.spa_payroll_adjustment_save(p_staff uuid,p_period date,p_kind text,p_cents bigint,p_note text) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 perform spa_private.require_permission('payroll.manage');
 if p_kind not in ('bonus','allowance','deduction','designated_bonus') or p_cents<0 or length(btrim(coalesce(p_note,'')))=0 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_payroll_adjustments(staff_id,period_start,kind,amount_cents,note,created_by) values(p_staff,p_period,p_kind,p_cents,btrim(p_note),auth.uid()) returning id into result;
 perform spa_private.audit('payroll.adjustment_created',result::text,jsonb_build_object('staff_id',p_staff,'period',p_period,'kind',p_kind,'cents',p_cents)); return result;
end $$;

create or replace function public.spa_payroll_rule_create(p_name text,p_effective date,p_divisor int,p_include_commission boolean,p_monthly_limit int,p_agreed_limit int,p_quarter_limit int) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid; source uuid; next_version int;
begin
 perform spa_private.require_permission('payroll.manage');
 if length(btrim(coalesce(p_name,'')))=0 or p_divisor<=0 or p_monthly_limit<=0 or p_agreed_limit<p_monthly_limit or p_quarter_limit<p_agreed_limit then raise exception 'INVALID_INPUT'; end if;
 select id into source from public.spa_payroll_rule_versions where status='active' order by effective_from desc,version_no desc limit 1;
 select coalesce(max(version_no),0)+1 into next_version from public.spa_payroll_rule_versions;
 update public.spa_payroll_rule_versions set status='archived' where status='active';
 insert into public.spa_payroll_rule_versions(version_no,name,effective_from,status,hourly_divisor,include_regular_commission,monthly_overtime_limit_minutes,agreed_monthly_limit_minutes,quarterly_overtime_limit_minutes,created_by)
 values(next_version,btrim(p_name),p_effective,'active',p_divisor,p_include_commission,p_monthly_limit,p_agreed_limit,p_quarter_limit,auth.uid()) returning id into result;
 insert into public.spa_payroll_overtime_rates select result,employment_type_code,overtime_type,start_minute,end_minute,multiplier_bps from public.spa_payroll_overtime_rates where rule_version_id=source;
 insert into public.spa_payroll_commission_tiers(rule_version_id,metric,threshold_from,threshold_to,rate_bps,service_category_id) select result,metric,threshold_from,threshold_to,rate_bps,service_category_id from public.spa_payroll_commission_tiers where rule_version_id=source;
 perform spa_private.audit('payroll.rule_created',result::text,jsonb_build_object('version',next_version,'effective_from',p_effective)); return result;
end $$;

create or replace function public.spa_payroll_components_save(p_rule uuid,p_rates jsonb,p_tiers jsonb) returns void language plpgsql security definer set search_path='' as $$
declare v_status text;
begin
 perform spa_private.require_permission('payroll.manage');
 select status into v_status from public.spa_payroll_rule_versions where id=p_rule;
 if v_status is null then raise exception 'NOT_FOUND'; end if;
 if v_status<>'active' then raise exception 'PAYROLL_RULE_READ_ONLY'; end if;
 if jsonb_typeof(coalesce(p_rates,'[]'::jsonb))<>'array' or jsonb_typeof(coalesce(p_tiers,'[]'::jsonb))<>'array'
   or jsonb_array_length(coalesce(p_rates,'[]'::jsonb))=0 or jsonb_array_length(coalesce(p_rates,'[]'::jsonb))>100
   or jsonb_array_length(coalesce(p_tiers,'[]'::jsonb))>100 then raise exception 'INVALID_INPUT'; end if;
 if exists(select 1 from jsonb_to_recordset(p_rates) as x(employment_type_code text,overtime_type text,start_minute int,end_minute int,multiplier_bps int)
   where x.overtime_type not in ('weekday','rest_day','national_holiday','regular_holiday') or x.start_minute<0 or x.end_minute<=x.start_minute or x.end_minute>720 or x.multiplier_bps<0 or x.multiplier_bps>100000) then raise exception 'INVALID_RATE'; end if;
 if exists(select 1 from jsonb_to_recordset(coalesce(p_tiers,'[]'::jsonb)) as x(metric text,threshold_from bigint,threshold_to bigint,rate_bps int)
   where x.metric not in ('service_minutes','service_count','service_sales_cents','product_sales_cents') or x.threshold_from<0 or (x.threshold_to is not null and x.threshold_to<=x.threshold_from) or x.rate_bps<0 or x.rate_bps>10000) then raise exception 'INVALID_TIER'; end if;
 delete from public.spa_payroll_overtime_rates where rule_version_id=p_rule;
 insert into public.spa_payroll_overtime_rates(rule_version_id,employment_type_code,overtime_type,start_minute,end_minute,multiplier_bps)
 select p_rule,x.employment_type_code,x.overtime_type,x.start_minute,x.end_minute,x.multiplier_bps
 from jsonb_to_recordset(p_rates) as x(employment_type_code text,overtime_type text,start_minute int,end_minute int,multiplier_bps int);
 delete from public.spa_payroll_commission_tiers where rule_version_id=p_rule;
 insert into public.spa_payroll_commission_tiers(rule_version_id,metric,threshold_from,threshold_to,rate_bps,service_category_id)
 select p_rule,x.metric,x.threshold_from,x.threshold_to,x.rate_bps,x.service_category_id
 from jsonb_to_recordset(coalesce(p_tiers,'[]'::jsonb)) as x(metric text,threshold_from bigint,threshold_to bigint,rate_bps int,service_category_id uuid);
 perform spa_private.audit('payroll.components_updated',p_rule::text,jsonb_build_object('rates',jsonb_array_length(p_rates),'tiers',jsonb_array_length(coalesce(p_tiers,'[]'::jsonb))));
end $$;

create or replace function public.spa_payroll_run_save(p_from date,p_to date,p_rule uuid,p_finalize boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare v_run_id uuid; preview jsonb;
begin
 perform spa_private.require_permission('payroll.manage');
 if p_from is null or p_to is null or p_to<p_from then raise exception 'INVALID_DATE'; end if;
 perform pg_advisory_xact_lock(726005);
 select id into v_run_id from public.spa_payroll_runs where period_start=p_from and period_end=p_to;
 if v_run_id is not null and exists(select 1 from public.spa_payroll_runs where id=v_run_id and status='finalized') then raise exception 'PAYROLL_LOCKED'; end if;
 preview:=public.spa_payroll_preview(p_from,p_to,p_rule);
 if v_run_id is null then insert into public.spa_payroll_runs(period_start,period_end,rule_version_id,created_by) values(p_from,p_to,p_rule,auth.uid()) returning id into v_run_id;
 else update public.spa_payroll_runs set rule_version_id=p_rule where id=v_run_id; delete from public.spa_payroll_items where run_id=v_run_id; end if;
 insert into public.spa_payroll_items(run_id,staff_id,employment_type_snapshot,role_snapshot,work_minutes,service_minutes,service_sales_cents,product_sales_cents,designated_clients,base_cents,service_commission_cents,product_commission_cents,designated_bonus_cents,overtime_cents,bonus_cents,allowance_cents,deduction_cents,total_cents,calculation_snapshot)
 select v_run_id,x.staff_id,x.employment_type,x.role,x.work_minutes,x.service_minutes,x.service_sales_cents,x.product_sales_cents,x.designated_clients,x.base_cents,x.service_commission_cents,x.product_commission_cents,x.designated_bonus_cents,x.overtime_cents,x.bonus_cents,x.allowance_cents,x.deduction_cents,x.total_cents,x.calculation
 from jsonb_to_recordset(preview) as x(staff_id uuid,employment_type text,role text,work_minutes int,service_minutes int,service_sales_cents bigint,product_sales_cents bigint,designated_clients int,base_cents bigint,service_commission_cents bigint,product_commission_cents bigint,designated_bonus_cents bigint,overtime_cents bigint,bonus_cents bigint,allowance_cents bigint,deduction_cents bigint,total_cents bigint,calculation jsonb);
 update public.spa_payroll_runs set calculation_snapshot=jsonb_build_object('rule_version_id',p_rule,'rows',preview),status=case when p_finalize then 'finalized' else 'draft' end,finalized_by=case when p_finalize then auth.uid() end,finalized_at=case when p_finalize then now() end where id=v_run_id;
 perform spa_private.audit(case when p_finalize then 'payroll.finalized' else 'payroll.saved' end,v_run_id::text,jsonb_build_object('from',p_from,'to',p_to,'rule',p_rule)); return v_run_id;
end $$;

create or replace function public.spa_payroll_reopen(p_run uuid,p_reason text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('payroll.manage');
 if length(btrim(coalesce(p_reason,'')))=0 then raise exception 'REASON_REQUIRED'; end if;
 update public.spa_payroll_runs set status='draft',reopened_by=auth.uid(),reopened_at=now() where id=p_run and status='finalized';
 if not found then raise exception 'NOT_FOUND'; end if;
 perform spa_private.audit('payroll.reopened',p_run::text,jsonb_build_object('reason',p_reason));
end $$;

create or replace function public.spa_category_save(p_kind text,p_payload jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid:=nullif(p_payload->>'id','')::uuid; normalized text:=lower(btrim(coalesce(p_payload->>'code','')));
begin
 perform spa_private.require_permission('catalog.manage');
 if normalized !~ '^[a-z][a-z0-9_]{1,31}$' or length(btrim(coalesce(p_payload->>'name',''))) not between 1 and 80 then raise exception 'INVALID_INPUT'; end if;
 if p_kind='service' then
  if result is null then insert into public.spa_service_categories(code,name,name_en,active,display_order) values(normalized,btrim(p_payload->>'name'),coalesce(p_payload->>'name_en',''),coalesce((p_payload->>'active')::boolean,true),coalesce((p_payload->>'display_order')::int,0)) returning id into result;
  else update public.spa_service_categories set code=normalized,name=btrim(p_payload->>'name'),name_en=coalesce(p_payload->>'name_en',''),active=coalesce((p_payload->>'active')::boolean,active),display_order=coalesce((p_payload->>'display_order')::int,display_order),archived_at=case when coalesce((p_payload->>'active')::boolean,active) then null else coalesce(archived_at,now()) end where id=result; end if;
 elsif p_kind='product' then
  if result is null then insert into public.spa_product_categories(code,name,name_en,active,display_order) values(normalized,btrim(p_payload->>'name'),coalesce(p_payload->>'name_en',''),coalesce((p_payload->>'active')::boolean,true),coalesce((p_payload->>'display_order')::int,0)) returning id into result;
  else update public.spa_product_categories set code=normalized,name=btrim(p_payload->>'name'),name_en=coalesce(p_payload->>'name_en',''),active=coalesce((p_payload->>'active')::boolean,active),display_order=coalesce((p_payload->>'display_order')::int,display_order),archived_at=case when coalesce((p_payload->>'active')::boolean,active) then null else coalesce(archived_at,now()) end where id=result; end if;
 else raise exception 'INVALID_INPUT'; end if;
 perform spa_private.audit('category.saved',result::text,jsonb_build_object('kind',p_kind,'value',p_payload)); return result;
end $$;

create or replace function public.spa_settings_os() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('settings.manage');
 return jsonb_build_object(
  'business',coalesce((select value from public.spa_business_settings where key='business'),'{}'),
  'website',coalesce((select value from public.spa_business_settings where key='website'),'{}'),
  'inventory',coalesce((select value from public.spa_business_settings where key='inventory'),'{}'),
  'assignment',coalesce((select value from public.spa_business_settings where key='assignment'),'{}'),
  'booking',(select to_jsonb(s) from public.spa_settings s),
  'resources',coalesce((select jsonb_agg(to_jsonb(r) order by name) from public.spa_rooms r),'[]'));
end $$;

create or replace function public.spa_business_setting_save(p_key text,p_value jsonb) returns void language plpgsql security definer set search_path='' as $$
declare old jsonb;
begin
 perform spa_private.require_permission(case when p_key='website' then 'website.manage' else 'settings.manage' end);
 if p_key not in ('business','website','inventory','assignment') or p_value is null or jsonb_typeof(p_value)<>'object' then raise exception 'INVALID_INPUT'; end if;
 select value into old from public.spa_business_settings where key=p_key;
 insert into public.spa_business_settings(key,value,updated_by,updated_at) values(p_key,p_value,auth.uid(),now())
 on conflict(key) do update set value=excluded.value,updated_by=excluded.updated_by,updated_at=excluded.updated_at;
 perform spa_private.audit('setting.saved',p_key,jsonb_build_object('old',old,'new',p_value));
end $$;

create or replace function public.spa_pos_checkout(p_request uuid,p_customer uuid,p_items jsonb,p_discount bigint,p_method text,p_note text default '') returns jsonb language plpgsql security definer set search_path='' as $$
declare result public.spa_orders; item jsonb; product public.spa_products; qty int; subtotal bigint:=0; line bigint; staff uuid; commission bigint;
begin
 perform spa_private.require_permission('pos.use');
 if p_request is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>100 or p_discount<0 or p_method not in ('cash','card','transfer') then raise exception 'INVALID_INPUT'; end if;
 select * into result from public.spa_orders where request_id=p_request;
 if found then return to_jsonb(result); end if;
 perform pg_advisory_xact_lock(726006);
 insert into public.spa_orders(request_id,customer_id,created_by,note) values(p_request,p_customer,auth.uid(),coalesce(p_note,'')) returning * into result;
 for item in select * from jsonb_array_elements(p_items) loop
  qty:=coalesce((item->>'quantity')::int,0); staff:=nullif(item->>'staff_id','')::uuid;
  select * into product from public.spa_products where id=(item->>'product_id')::uuid and status='active' for update;
  if not found or qty<=0 then raise exception 'INVALID_PRODUCT'; end if;
  if coalesce((select sum(delta) from public.spa_inventory_entries where product_id=product.id),0)<qty then raise exception 'INSUFFICIENT_INVENTORY'; end if;
  line:=product.price_cents*qty; subtotal:=subtotal+line;
  commission:=case when staff is null then 0 else round(line*(select commission_bps from public.spa_staff where id=staff)/10000.0)::bigint end;
  insert into public.spa_order_items(order_id,product_id,item_type,name_snapshot,sku_snapshot,unit_price_cents,cost_snapshot_cents,quantity,line_total_cents,staff_id,commission_cents)
  values(result.id,product.id,'product',product.name,product.sku,product.price_cents,product.cost_cents,qty,line,staff,coalesce(commission,0));
  insert into public.spa_inventory_entries(product_id,delta,reason,reference_type,reference_id,created_by) values(product.id,-qty,'POS 銷售 '||result.reference,'order',result.id,auth.uid());
 end loop;
 if p_discount>subtotal then raise exception 'INVALID_INPUT'; end if;
 update public.spa_orders set subtotal_cents=subtotal,discount_cents=p_discount,total_cents=subtotal-p_discount,status='paid',method=p_method,paid_at=now() where id=result.id returning * into result;
 insert into public.spa_cash_entries(request_id,customer_id,amount_cents,category,method,note,created_by) values(p_request,p_customer,result.total_cents,'product',p_method,result.reference,auth.uid());
 perform spa_private.audit('order.paid',result.id::text,jsonb_build_object('reference',result.reference,'total_cents',result.total_cents)); return to_jsonb(result);
end $$;

-- Existing operational RPCs now enforce the configurable permission matrix too.
create or replace function public.spa_customer_save(p_id uuid,p_name text,p_phone text,p_email text,p_tier text,p_notes text,p_user uuid default null) returns uuid language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 perform spa_private.require_permission('customers.manage');
 if length(btrim(coalesce(p_name,'')))=0 or length(coalesce(p_notes,''))>4000 or length(coalesce(p_email,''))>254 then raise exception 'INVALID_INPUT'; end if;
 if p_id is null then insert into public.spa_customers(name,phone,email,tier,notes,auth_user_id) values(btrim(p_name),spa_private.phone(p_phone),coalesce(p_email,''),coalesce(p_tier,'一般會員'),coalesce(p_notes,''),p_user) returning id into result;
 else update public.spa_customers set name=btrim(p_name),phone=spa_private.phone(p_phone),email=coalesce(p_email,''),tier=coalesce(p_tier,'一般會員'),notes=coalesce(p_notes,''),auth_user_id=p_user where id=p_id returning id into result; end if;
 if result is null then raise exception 'NOT_FOUND'; end if;
 perform spa_private.audit('customer.saved',result::text); return result;
end $$;

create or replace function public.spa_customer_detail(p_customer uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if not exists(select 1 from public.spa_customers where id=p_customer and auth_user_id=auth.uid()) then perform spa_private.require_permission('customers.manage'); end if;
 return jsonb_build_object('wallet',coalesce((select jsonb_agg(to_jsonb(w) order by created_at desc) from public.spa_wallet_entries w where customer_id=p_customer),'[]'),
 'packages',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('remaining',p.sessions+coalesce((select sum(delta) from public.spa_package_entries where package_id=p.id),0),'service_name',s.name)) from public.spa_packages p join public.spa_services s on s.id=p.service_id where p.customer_id=p_customer),'[]'),
 'appointments',coalesce((select jsonb_agg(jsonb_build_object('id',a.id,'reference',a.reference,'service_name',coalesce(a.service_name_snapshot,a.service_name),'starts_at',a.starts_at,'status',a.status,'review_token',case when a.status='completed' then a.review_token end,'manage_token',a.manage_token) order by a.starts_at desc) from public.spa_appointments a where a.customer_id=p_customer),'[]'));
end $$;

create or replace function public.spa_topup(p_request uuid,p_customer uuid,p_cents bigint,p_method text,p_note text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('customers.manage'); perform 1 from public.spa_customers where id=p_customer for update;
 if not found or p_cents is null or p_cents<=0 or p_cents>100000000 or p_method not in ('cash','card','transfer') or length(btrim(p_note))=0 then raise exception 'INVALID_INPUT'; end if;
 if exists(select 1 from public.spa_wallet_entries where request_id=p_request) then return; end if;
 insert into public.spa_wallet_entries(customer_id,amount_cents,kind,request_id,note,created_by) values(p_customer,p_cents,'topup',p_request,p_note,auth.uid());
 insert into public.spa_cash_entries(request_id,customer_id,amount_cents,category,method,note,created_by) values(p_request,p_customer,p_cents,'topup',p_method,p_note,auth.uid());
 perform spa_private.audit('wallet.topup',p_customer::text,jsonb_build_object('cents',p_cents));
end $$;

create or replace function public.spa_wallet_adjust(p_request uuid,p_customer uuid,p_cents bigint,p_note text) returns void language plpgsql security definer set search_path='' as $$
declare balance bigint;
begin
 perform spa_private.require_permission('customers.manage'); perform 1 from public.spa_customers where id=p_customer for update;
 if not found or p_cents is null or p_cents=0 or abs(p_cents)>100000000 or length(btrim(p_note))=0 then raise exception 'INVALID_INPUT'; end if;
 if exists(select 1 from public.spa_wallet_entries where request_id=p_request) then return; end if;
 select coalesce(sum(amount_cents),0) into balance from public.spa_wallet_entries where customer_id=p_customer;
 if balance+p_cents<0 then raise exception 'INSUFFICIENT_CREDITS'; end if;
 insert into public.spa_wallet_entries(customer_id,amount_cents,kind,request_id,note,created_by) values(p_customer,p_cents,'adjustment',p_request,p_note,auth.uid());
 perform spa_private.audit('wallet.adjusted',p_customer::text,jsonb_build_object('cents',p_cents,'reason',p_note));
end $$;

create or replace function public.spa_package_sell(p_request uuid,p_customer uuid,p_service uuid,p_name text,p_sessions int,p_cents bigint,p_expires timestamptz,p_method text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('customers.manage'); perform 1 from public.spa_customers where id=p_customer for update;
 if not found or p_sessions not between 1 and 200 or p_expires is null or p_expires<=now() or p_cents is null or p_cents<=0 or p_cents>100000000 or p_method not in ('cash','card','transfer') or length(btrim(p_name))=0 then raise exception 'INVALID_INPUT'; end if;
 if exists(select 1 from public.spa_packages where request_id=p_request) then return; end if;
 insert into public.spa_packages(customer_id,service_id,name,sessions,paid_cents,expires_at,request_id) values(p_customer,p_service,p_name,p_sessions,p_cents,p_expires,p_request);
 insert into public.spa_cash_entries(request_id,customer_id,amount_cents,category,method,note,created_by) values(p_request,p_customer,p_cents,'package',p_method,p_name,auth.uid());
 perform spa_private.audit('package.sold',p_customer::text,jsonb_build_object('sessions',p_sessions,'cents',p_cents));
end $$;

create or replace function public.spa_checkout(p_request uuid,p_appointment uuid,p_discount bigint,p_wallet bigint,p_package uuid,p_tip bigint,p_method text) returns jsonb language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; pkg public.spa_packages; gross bigint; due bigint; balance bigint; cash bigint; revenue bigint; used int; commission bigint; result public.spa_checkouts;
begin
 perform spa_private.require_permission('pos.use');
 select * into a from public.spa_appointments where id=p_appointment for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 select * into result from public.spa_checkouts where request_id=p_request;
 if found then if result.appointment_id<>p_appointment then raise exception 'REQUEST_CONFLICT'; end if; return to_jsonb(result); end if;
 if a.status<>'completed' or exists(select 1 from public.spa_checkouts where appointment_id=a.id) then raise exception 'INVALID_TRANSITION'; end if;
 if p_discount is null or p_wallet is null or p_tip is null or p_discount<0 or p_wallet<0 or p_tip<0 or p_tip>100000000 or p_method not in ('cash','card','transfer') then raise exception 'INVALID_INPUT'; end if;
 perform 1 from public.spa_customers where id=a.customer_id for update; gross:=a.price_cents+a.tea_cents;
 if p_package is not null then
  select * into pkg from public.spa_packages where id=p_package for update;
  if not found or pkg.customer_id<>a.customer_id or pkg.service_id<>a.service_id or pkg.expires_at<=now() or p_discount<>0 then raise exception 'INVALID_PACKAGE'; end if;
  select -coalesce(sum(delta),0) into used from public.spa_package_entries where package_id=p_package;
  if used>=pkg.sessions then raise exception 'INSUFFICIENT_CREDITS'; end if;
  due:=a.tea_cents; revenue:=case when used=pkg.sessions-1 then pkg.paid_cents-coalesce((select sum(ch.revenue_cents-ap.tea_cents) from public.spa_checkouts ch join public.spa_appointments ap on ap.id=ch.appointment_id where ch.package_id=pkg.id and ch.refunded_at is null),0) else pkg.paid_cents/pkg.sessions end+a.tea_cents;
  insert into public.spa_package_entries(package_id,appointment_id,delta) values(p_package,a.id,-1);
 else
  if p_discount>gross then raise exception 'INVALID_INPUT'; end if;
  if p_discount>0 then perform spa_private.require_permission('finance.manage'); end if;
  due:=gross-p_discount; revenue:=due;
 end if;
 select coalesce(sum(amount_cents),0) into balance from public.spa_wallet_entries where customer_id=a.customer_id;
 if p_wallet>balance or p_wallet>due then raise exception 'INSUFFICIENT_CREDITS'; end if;
 cash:=due-p_wallet;
 if p_wallet>0 then insert into public.spa_wallet_entries(customer_id,amount_cents,kind,appointment_id,request_id,note,created_by) values(a.customer_id,-p_wallet,'redemption',a.id,p_request,'療程結帳 '||a.reference,auth.uid()); end if;
 if cash>0 then insert into public.spa_cash_entries(request_id,customer_id,appointment_id,amount_cents,category,method,note,created_by) values(p_request,a.customer_id,a.id,cash,'service',p_method,a.reference,auth.uid()); end if;
 if p_tip>0 then insert into public.spa_cash_entries(request_id,customer_id,appointment_id,amount_cents,category,method,note,created_by) values(p_request,a.customer_id,a.id,p_tip,'tip',p_method,a.reference,auth.uid()); end if;
 select round(greatest(0,revenue-a.tea_cents)*commission_bps/10000.0) into commission from public.spa_staff where id=a.staff_id;
 insert into public.spa_checkouts(appointment_id,request_id,gross_cents,discount_cents,revenue_cents,cash_cents,wallet_cents,tip_cents,package_id,method,commission_cents,created_by)
 values(a.id,p_request,gross,p_discount,revenue,cash,p_wallet,p_tip,p_package,p_method,commission,auth.uid()) returning * into result;
 perform spa_private.audit('checkout.completed',a.id::text,jsonb_build_object('revenue_cents',revenue,'cash_cents',cash)); return to_jsonb(result);
end $$;

create or replace function public.spa_refund(p_request uuid,p_appointment uuid,p_reason text) returns void language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; ch public.spa_checkouts;
begin
 perform spa_private.require_permission('finance.manage'); select * into a from public.spa_appointments where id=p_appointment for update; select * into ch from public.spa_checkouts where appointment_id=p_appointment for update;
 if not found or length(btrim(coalesce(p_reason,'')))=0 then raise exception 'INVALID_INPUT'; end if;
 if ch.refunded_at is not null then return; end if; perform 1 from public.spa_customers where id=a.customer_id for update;
 if ch.wallet_cents>0 then insert into public.spa_wallet_entries(customer_id,amount_cents,kind,appointment_id,request_id,note,created_by) values(a.customer_id,ch.wallet_cents,'refund',a.id,p_request,p_reason,auth.uid()); end if;
 if ch.package_id is not null then insert into public.spa_package_entries(package_id,appointment_id,delta) values(ch.package_id,a.id,1); end if;
 if ch.cash_cents+ch.tip_cents>0 then insert into public.spa_cash_entries(request_id,customer_id,appointment_id,amount_cents,category,method,note,created_by) values(p_request,a.customer_id,a.id,-ch.cash_cents-ch.tip_cents,'refund',ch.method,p_reason,auth.uid()); end if;
 update public.spa_checkouts set refunded_at=now(),refund_reason=p_reason where id=ch.id;
 perform spa_private.audit('checkout.refunded',a.id::text,jsonb_build_object('reason',p_reason));
end $$;

create or replace function public.spa_expense(p_request uuid,p_cents bigint,p_method text,p_note text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('finance.manage');
 if p_cents is null or p_cents<=0 or p_cents>100000000 or p_method not in ('cash','card','transfer') or length(btrim(p_note))=0 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_cash_entries(request_id,amount_cents,category,method,note,created_by) values(p_request,-p_cents,'expense',p_method,p_note,auth.uid()) on conflict(request_id,category) do nothing;
 perform spa_private.audit('expense.recorded',p_request::text,jsonb_build_object('cents',p_cents,'note',p_note));
end $$;

create or replace function public.spa_reviews_admin() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('reviews.manage');
 return jsonb_build_object('reviews',coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('customer_name',c.name,'therapist',s.name,'reference',a.reference) order by r.created_at desc) from public.spa_reviews r join public.spa_appointments a on a.id=r.appointment_id join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id),'[]'),'feedback',coalesce((select jsonb_agg(to_jsonb(f) order by f.created_at desc) from public.spa_feedback f),'[]'));
end $$;
create or replace function public.spa_moderate(p_kind text,p_id uuid,p_status text,p_reply text default '') returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('reviews.manage');
 if p_kind='review' and p_status in ('pending','published','hidden') and length(p_reply)<=1000 then update public.spa_reviews set status=p_status,reply=p_reply where id=p_id;
 elsif p_kind='feedback' and p_status in ('unread','read','resolved') then update public.spa_feedback set status=p_status where id=p_id;
 else raise exception 'INVALID_INPUT'; end if;
 if not found then raise exception 'NOT_FOUND'; end if; perform spa_private.audit(p_kind||'.moderated',p_id::text,jsonb_build_object('status',p_status));
end $$;

create or replace function public.spa_shift_save(p_staff uuid,p_weekday int,p_start int,p_end int) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('team.manage'); perform pg_advisory_xact_lock(726001);
 if p_weekday not between 0 and 6 or p_start<0 or p_end<=p_start or p_end>2880 then raise exception 'INVALID_INPUT'; end if;
 insert into public.spa_shifts(staff_id,weekday,start_minute,end_minute) values(p_staff,p_weekday,p_start,p_end) on conflict(staff_id,weekday) do update set start_minute=excluded.start_minute,end_minute=excluded.end_minute;
 perform spa_private.audit('shift.saved',p_staff::text,jsonb_build_object('weekday',p_weekday));
end $$;
create or replace function public.spa_time_off_save(p_staff uuid,p_start timestamptz,p_end timestamptz,p_reason text) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('team.manage'); perform pg_advisory_xact_lock(726001);
 if p_end<=p_start or length(btrim(coalesce(p_reason,'')))=0 then raise exception 'INVALID_INPUT'; end if;
 if exists(select 1 from public.spa_appointments where staff_id=p_staff and status in ('pending','confirmed','checked_in','in_service') and starts_at<p_end and blocked_until>p_start) then raise exception 'EXISTING_BOOKINGS'; end if;
 insert into public.spa_time_off(staff_id,starts_at,ends_at,reason) values(p_staff,p_start,p_end,p_reason); perform spa_private.audit('time_off.created',p_staff::text,jsonb_build_object('reason',p_reason));
end $$;
create or replace function public.spa_time_off_delete(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('team.manage'); delete from public.spa_time_off where id=p_id; if not found then raise exception 'NOT_FOUND'; end if; perform spa_private.audit('time_off.deleted',p_id::text);
end $$;

create or replace function public.spa_settings_save(p_open int,p_close int,p_days int,p_auto boolean,p_cancel int) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('settings.manage');
 if p_open<0 or p_close<=p_open or p_close>2880 or p_days not between 1 and 365 or p_cancel not between 0 and 720 then raise exception 'INVALID_INPUT'; end if;
 update public.spa_settings set opening_minute=p_open,closing_minute=p_close,booking_days=p_days,auto_confirm=p_auto,cancellation_hours=p_cancel; perform spa_private.audit('settings.saved','store');
end $$;
create or replace function public.spa_room_save(p_id uuid,p_name text,p_active boolean) returns void language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 perform spa_private.require_permission('settings.manage');
 if length(btrim(coalesce(p_name,''))) not between 1 and 80 then raise exception 'INVALID_INPUT'; end if;
 if p_id is null then insert into public.spa_rooms(name,active) values(btrim(p_name),p_active) returning id into result;
 else update public.spa_rooms set name=btrim(p_name),active=p_active where id=p_id returning id into result; if not found then raise exception 'NOT_FOUND'; end if; end if;
 perform spa_private.audit('room.saved',result::text);
end $$;

create or replace function public.spa_report(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare first_time timestamptz; last_time timestamptz;
begin
 perform spa_private.require_permission('reports.view');
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 first_time:=p_from::timestamp at time zone 'Asia/Taipei'; last_time:=(p_to+1)::timestamp at time zone 'Asia/Taipei';
 return jsonb_build_object(
 'bookings',(select count(*) from public.spa_appointments where business_date between p_from and p_to),
 'completed',(select count(*) from public.spa_appointments where business_date between p_from and p_to and status='completed'),
 'cancelled',(select count(*) from public.spa_appointments where business_date between p_from and p_to and status='cancelled'),
 'no_show',(select count(*) from public.spa_appointments where business_date between p_from and p_to and status='no_show'),
 'revenue_cents',coalesce((select sum(revenue_cents) from public.spa_checkouts where created_at>=first_time and created_at<last_time),0)-coalesce((select sum(revenue_cents) from public.spa_checkouts where refunded_at>=first_time and refunded_at<last_time),0),
 'cash_in_cents',coalesce((select sum(amount_cents) from public.spa_cash_entries where created_at>=first_time and created_at<last_time and amount_cents>0),0),
 'cash_out_cents',coalesce((select -sum(amount_cents) from public.spa_cash_entries where created_at>=first_time and created_at<last_time and amount_cents<0),0),
 'expenses_cents',coalesce((select -sum(amount_cents) from public.spa_cash_entries where created_at>=first_time and created_at<last_time and category='expense'),0),
 'wallet_liability_cents',coalesce((select sum(amount_cents) from public.spa_wallet_entries),0),
 'package_liability_cents',coalesce((select sum(p.paid_cents-coalesce((select sum(ch.revenue_cents-a.tea_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where ch.package_id=p.id and ch.refunded_at is null),0)) from public.spa_packages p),0),
 'cash_entries',coalesce((select jsonb_agg(to_jsonb(e) order by e.created_at desc) from public.spa_cash_entries e where e.created_at>=first_time and e.created_at<last_time),'[]'),
 'daily',coalesce((select jsonb_agg(to_jsonb(d) order by d.date) from (select (e.created_at at time zone 'Asia/Taipei')::date date,sum(e.amount_cents) net_cents from public.spa_cash_entries e where e.created_at>=first_time and e.created_at<last_time group by 1) d),'[]'),
 'staff',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,
  'completed',(select count(*) from public.spa_appointments where staff_id=s.id and business_date between p_from and p_to and status='completed'),
  'minutes',(select coalesce(sum(duration_minutes_snapshot),0) from public.spa_appointments where staff_id=s.id and business_date between p_from and p_to and status='completed'),
  'revenue_cents',(select coalesce(sum(ch.revenue_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.created_at>=first_time and ch.created_at<last_time)-(select coalesce(sum(ch.revenue_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.refunded_at>=first_time and ch.refunded_at<last_time),
  'commission_cents',(select coalesce(sum(ch.commission_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.created_at>=first_time and ch.created_at<last_time)-(select coalesce(sum(ch.commission_cents),0) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.staff_id=s.id and ch.refunded_at>=first_time and ch.refunded_at<last_time),
  'rating',(select round(avg(rv.rating),2) from public.spa_reviews rv join public.spa_appointments a on a.id=rv.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to),
  'reviews',(select count(*) from public.spa_reviews rv join public.spa_appointments a on a.id=rv.appointment_id where a.staff_id=s.id and a.business_date between p_from and p_to)) order by s.display_order) from public.spa_staff s),'[]'),
 'audit',coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc) from (select * from public.spa_audit where created_at>=first_time and created_at<last_time order by created_at desc limit 200) a),'[]'));
end $$;

alter table public.spa_cash_entries drop constraint if exists spa_cash_entries_category_check;
alter table public.spa_cash_entries add constraint spa_cash_entries_category_check check(category in ('service','product','topup','package','tip','expense','refund'));

create or replace function public.spa_admin_bookings(p_from date,p_to date) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('appointments.view');
 if p_from is null or p_to is null or p_to<p_from or p_to-p_from>366 then raise exception 'INVALID_DATE'; end if;
 return coalesce((select jsonb_agg(
  (case when spa_private.has_permission('appointments.manage') then to_jsonb(a) else jsonb_build_object('id',a.id,'reference',a.reference,'customer_id',a.customer_id,'staff_id',a.staff_id,'service_id',a.service_id,'business_date',a.business_date,'starts_at',a.starts_at,'ends_at',a.ends_at,'blocked_until',a.blocked_until,'status',a.status,'service_name',a.service_name_snapshot) end)
  ||jsonb_build_object('customer_name',c.name,'phone',c.phone,'therapist',coalesce(a.staff_name_snapshot,s.name),'room',r.name,'checkout',case when spa_private.has_permission('finance.view') then to_jsonb(ch) else null end) order by a.starts_at)
  from public.spa_appointments a join public.spa_customers c on c.id=a.customer_id join public.spa_staff s on s.id=a.staff_id join public.spa_rooms r on r.id=a.room_id left join public.spa_checkouts ch on ch.appointment_id=a.id
  where a.business_date between p_from and p_to and (spa_private.has_permission('appointments.manage') or a.staff_id=(select staff_id from public.spa_roles where user_id=auth.uid()))),'[]');
end $$;

create or replace function public.spa_set_status(p_id uuid,p_status text,p_reason text default '') returns void language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments;
begin
 perform spa_private.require_permission('appointments.manage'); perform pg_advisory_xact_lock(726001);
 select * into a from public.spa_appointments where id=p_id for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if not ((a.status='pending' and p_status in ('confirmed','cancelled')) or (a.status='confirmed' and p_status in ('checked_in','cancelled','no_show')) or (a.status='checked_in' and p_status in ('in_service','completed')) or (a.status='in_service' and p_status='completed')) then raise exception 'INVALID_TRANSITION'; end if;
 if p_status in ('cancelled','no_show') and length(btrim(coalesce(p_reason,'')))=0 then raise exception 'REASON_REQUIRED'; end if;
 if p_status in ('checked_in','in_service','completed','no_show') and a.starts_at>now() then raise exception 'TOO_EARLY'; end if;
 update public.spa_appointments set status=p_status,cancellation_reason=case when p_status in ('cancelled','no_show') then p_reason else cancellation_reason end where id=p_id;
 perform spa_private.audit('booking.'||p_status,p_id::text,jsonb_build_object('from',a.status,'reason',p_reason));
end $$;

create or replace function public.spa_reschedule(p_id uuid,p_date date,p_start timestamptz,p_staff uuid,p_reason text) returns void language plpgsql security definer set search_path='' as $$
declare a public.spa_appointments; slot record;
begin
 perform spa_private.require_permission('appointments.manage'); perform pg_advisory_xact_lock(726001);
 select * into a from public.spa_appointments where id=p_id for update;
 if not found then raise exception 'NOT_FOUND'; end if;
 if a.status not in ('pending','confirmed') or length(btrim(coalesce(p_reason,'')))=0 then raise exception 'INVALID_TRANSITION'; end if;
 update public.spa_appointments set status='cancelled' where id=p_id;
 if not exists(select 1 from public.spa_availability(a.service_id,p_date,p_staff) av where av.starts_at=p_start and av.available) then raise exception 'SLOT_TAKEN'; end if;
 select * into slot from spa_private.candidates(a.service_id,p_date,p_start,p_staff) limit 1;
 update public.spa_appointments set business_date=p_date,starts_at=p_start,
  ends_at=p_start+make_interval(mins=>a.duration_minutes_snapshot),blocked_until=p_start+make_interval(mins=>a.duration_minutes_snapshot+a.buffer_minutes_snapshot),
  staff_id=slot.staff_id,staff_name_snapshot=(select name from public.spa_staff where id=slot.staff_id),room_id=slot.room_id,status=a.status where id=p_id;
 perform spa_private.audit('booking.rescheduled',p_id::text,jsonb_build_object('old_start',a.starts_at,'new_start',p_start,'reason',p_reason));
end $$;

create or replace function public.spa_customers_list() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 perform spa_private.require_permission('customers.view');
 return coalesce((select jsonb_agg((case when spa_private.has_permission('customers.manage') then to_jsonb(c) else jsonb_build_object('id',c.id,'name',c.name,'phone',c.phone,'tier',c.tier,'status',c.status) end)
  ||jsonb_build_object('balance_cents',coalesce((select sum(amount_cents) from public.spa_wallet_entries where customer_id=c.id),0),'visits',(select count(*) from public.spa_appointments where customer_id=c.id and status='completed'),'no_shows',(select count(*) from public.spa_appointments where customer_id=c.id and status='no_show'),'total_spend_cents',coalesce((select sum(ch.revenue_cents) from public.spa_checkouts ch join public.spa_appointments a on a.id=ch.appointment_id where a.customer_id=c.id and ch.refunded_at is null),0),'last_visit',(select max(starts_at) from public.spa_appointments where customer_id=c.id and status='completed')) order by c.created_at desc) from public.spa_customers c),'[]');
end $$;

create or replace function public.spa_staff_account_link(p_staff uuid,p_user uuid,p_role text,p_active boolean,p_reset boolean default false,p_username text default null) returns void language plpgsql security definer set search_path='' as $$
begin
 perform spa_private.require_permission('settings.manage'); perform pg_advisory_xact_lock(726002);
 if p_user=auth.uid() or p_role='owner' or not exists(select 1 from public.spa_role_profiles where code=p_role and active and archived_at is null) then raise exception 'OWNER_PROTECTED'; end if;
 if not exists(select 1 from public.spa_staff where id=p_staff and archived_at is null) then raise exception 'STAFF_ARCHIVED'; end if;
 if p_username is not null then
  if lower(btrim(p_username)) !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then raise exception 'INVALID_USERNAME'; end if;
  if exists(select 1 from public.spa_roles where lower(login_name)=lower(btrim(p_username)) and user_id<>p_user) then raise exception 'USERNAME_TAKEN'; end if;
 end if;
 insert into public.spa_roles(user_id,role,staff_id,active,login_name,login_after) values(p_user,p_role,p_staff,p_active,lower(btrim(p_username)),case when p_reset or not p_active then date_trunc('second',clock_timestamp())+interval '1 second' end)
 on conflict(user_id) do update set role=excluded.role,staff_id=excluded.staff_id,active=excluded.active,login_name=coalesce(excluded.login_name,spa_roles.login_name),login_after=case when p_reset or not p_active then date_trunc('second',clock_timestamp())+interval '1 second' else spa_roles.login_after end;
 perform spa_private.audit(case when p_reset then 'account.password_reset_requested' else 'account.access_saved' end,p_staff::text,jsonb_build_object('user_id',p_user,'role',p_role,'active',p_active,'username',p_username));
end $$;

-- Browser clients never receive direct table access. All sensitive reads and writes
-- go through the security-definer functions above.
do $$ declare table_name text; begin
 foreach table_name in array array[
  'spa_employment_types','spa_job_titles','spa_permission_definitions','spa_role_profiles','spa_role_permissions',
  'spa_service_categories','spa_product_categories','spa_products','spa_inventory_entries','spa_orders','spa_order_items',
  'spa_time_entries','spa_overtime_entries','spa_payroll_rule_versions','spa_payroll_overtime_rates','spa_payroll_commission_tiers',
  'spa_payroll_adjustments','spa_payroll_runs','spa_payroll_items','spa_business_settings'
 ] loop
  execute format('alter table public.%I enable row level security',table_name);
  execute format('revoke all on public.%I from public,anon,authenticated',table_name);
  execute format('grant all on public.%I to service_role',table_name);
 end loop;
end $$;

revoke all on function spa_private.has_permission(text),spa_private.require_permission(text),spa_private.snapshot_appointment() from public,anon,authenticated;
grant execute on function spa_private.has_permission(text),spa_private.require_permission(text),spa_private.snapshot_appointment() to service_role;
revoke all on function public.spa_store_catalog() from public;
grant execute on function public.spa_store_catalog() to anon,authenticated,service_role;
revoke all on function public.spa_dashboard(),public.spa_global_search(text),public.spa_team_os(),public.spa_access_admin(),public.spa_role_profile_save(text,text,text[],boolean,int),public.spa_reference_save(text,text,text,boolean,int,uuid),public.spa_staff_profile_save_v2(jsonb),public.spa_catalog_admin(),public.spa_service_save_v2(jsonb),public.spa_product_save(jsonb),public.spa_inventory_adjust(uuid,int,text),public.spa_catalog_bulk(text,uuid[],text,text),public.spa_payroll_preview(date,date,uuid),public.spa_payroll_admin(date,date,uuid),public.spa_overtime_save(uuid,date,text,int,text),public.spa_payroll_adjustment_save(uuid,date,text,bigint,text),public.spa_payroll_rule_create(text,date,int,boolean,int,int,int),public.spa_payroll_components_save(uuid,jsonb,jsonb),public.spa_payroll_run_save(date,date,uuid,boolean),public.spa_payroll_reopen(uuid,text),public.spa_category_save(text,jsonb),public.spa_settings_os(),public.spa_business_setting_save(text,jsonb),public.spa_pos_checkout(uuid,uuid,jsonb,bigint,text,text) from public,anon,authenticated;
grant execute on function public.spa_dashboard(),public.spa_global_search(text),public.spa_team_os(),public.spa_access_admin(),public.spa_role_profile_save(text,text,text[],boolean,int),public.spa_reference_save(text,text,text,boolean,int,uuid),public.spa_staff_profile_save_v2(jsonb),public.spa_catalog_admin(),public.spa_service_save_v2(jsonb),public.spa_product_save(jsonb),public.spa_inventory_adjust(uuid,int,text),public.spa_catalog_bulk(text,uuid[],text,text),public.spa_payroll_preview(date,date,uuid),public.spa_payroll_admin(date,date,uuid),public.spa_overtime_save(uuid,date,text,int,text),public.spa_payroll_adjustment_save(uuid,date,text,bigint,text),public.spa_payroll_rule_create(text,date,int,boolean,int,int,int),public.spa_payroll_components_save(uuid,jsonb,jsonb),public.spa_payroll_run_save(date,date,uuid,boolean),public.spa_payroll_reopen(uuid,text),public.spa_category_save(text,jsonb),public.spa_settings_os(),public.spa_business_setting_save(text,jsonb),public.spa_pos_checkout(uuid,uuid,jsonb,bigint,text,text) to authenticated,service_role;

notify pgrst,'reload schema';
commit;
