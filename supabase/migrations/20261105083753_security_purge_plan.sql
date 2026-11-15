-- which photo rows are due for file removal, and which of their files are safe to remove (used by no other photo and not the couple photo)
create or replace function purge_plan(p_limit int default 200) returns json language sql stable security definer set search_path = public as $$
  with due as (select id, path, thumb_path from photos where purge_at <= now() and purged_at is null order by purge_at limit p_limit),
  files as (select distinct f from due, unnest(array[due.path, due.thumb_path]) f where f is not null)
  select json_build_object(
    'ids', coalesce((select json_agg(id) from due), '[]'::json),
    'paths', coalesce((select json_agg(files.f) from files
                        where not exists (select 1 from photos q where q.id not in (select id from due) and (q.path = files.f or q.thumb_path = files.f))
                          and not exists (select 1 from weddings w where files.f in (w.cover_path, w.cover_thumb, w.share_path))), '[]'::json))
$$;
revoke all on function purge_plan(int) from public, anon, authenticated;
grant execute on function purge_plan(int) to service_role;;
