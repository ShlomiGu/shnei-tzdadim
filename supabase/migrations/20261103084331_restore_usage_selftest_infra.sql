create or replace function public.restore_photo(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  update photos set deleted_at = null where id = p_id and wedding_id = m.wedding_id and member_id = m.id and deleted_at is not null;
  if not found then raise exception 'not_found'; end if;
end $$;

-- bytes stored for this wedding, and the whole project's total (free plan cap is 1 GB)
create or replace function public.storage_usage(p_token uuid)
returns json language plpgsql stable security definer set search_path = public, storage as $$
declare m members; mine bigint; total bigint;
begin
  m := _member(p_token);
  select coalesce(sum((metadata->>'size')::bigint), 0) into mine from storage.objects where bucket_id = 'photos' and name like m.wedding_id::text || '/%';
  select coalesce(sum((metadata->>'size')::bigint), 0) into total from storage.objects where bucket_id = 'photos';
  return json_build_object('wedding_bytes', mine, 'project_bytes', total, 'limit_bytes', 1073741824);
end $$;

-- backup manifest: every file this member is allowed to see, with metadata
create or replace function public.backup_manifest(p_token uuid)
returns json language plpgsql stable security definer set search_path = public as $$
declare m members; w weddings; rv boolean;
begin
  m := _member(p_token);
  select * into w from weddings where id = m.wedding_id;
  rv := _revealed(w);
  return coalesce((select json_agg(json_build_object('id', p.id, 'kind', p.kind, 'team', p.team, 'path', p.path, 'caption', p.caption,
      'by', (select name from members x where x.id = p.member_id), 'at', p.created_at) order by p.created_at)
    from photos p where p.wedding_id = w.id and p.deleted_at is null
      and (p.team = m.team or (rv and p.vis <> 'secret'))), '[]'::json);
end $$;

create extension if not exists pg_net with schema extensions;

create table if not exists public.app_secrets (name text primary key, value text not null);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;
insert into public.app_secrets (name, value) values ('selftest', encode(extensions.gen_random_bytes(24), 'hex'))
on conflict (name) do nothing;;
