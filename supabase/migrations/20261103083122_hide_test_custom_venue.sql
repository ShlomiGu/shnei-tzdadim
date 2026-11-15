alter table public.venues_custom add column hidden boolean not null default false;
update public.venues_custom set hidden = true where name = 'אולם בדיקות פיקטיבי';
create or replace function public.list_custom_venues()
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('he', name, 'city', city)), '[]'::json)
    from (select name, city from venues_custom where not hidden order by created_at desc limit 500) v
$$;;
