create or replace function wedding_upload_ok(p_id text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from weddings w where w.id::text = p_id and now() < (w.wdate + 60)::timestamptz)
     and (select coalesce(sum((o.metadata->>'size')::bigint), 0) from storage.objects o where o.bucket_id = 'photos' and o.name like p_id || '/%') < 4294967296
$$;
grant execute on function wedding_upload_ok(text) to anon, authenticated;
alter policy "upload into an existing wedding folder" on storage.objects
  with check (bucket_id = 'photos' and wedding_upload_ok((storage.foldername(name))[1]));

revoke all on function add_photo(uuid, text, text, text, integer, integer, text, text, uuid) from public, anon, authenticated;
revoke all on function create_wedding(text, text, date, text, timestamp with time zone, text, text, text, text, boolean) from public, anon, authenticated;
revoke all on table blocks, reports from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;;
