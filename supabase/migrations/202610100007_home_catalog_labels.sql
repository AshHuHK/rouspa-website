-- Display names only; IDs, service durations and historical snapshots stay put.
begin;
update public.spa_services set name='120分方子'
where code='formula120' and name='120分全息';
update public.spa_service_categories set name='另外項目',name_en='Other services'
where code='add_on';
notify pgrst,'reload schema';
commit;
