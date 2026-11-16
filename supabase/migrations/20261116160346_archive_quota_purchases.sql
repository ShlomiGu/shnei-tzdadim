-- Storage plans: every wedding gets 1 GB free and is archived 60 days after its date
-- (originals are removed, the small copies stay). Anyone in the wedding can buy:
--   keep     - the wedding is never archived
--   storage5 - 5 GB more for this wedding
alter table public.weddings
  add column if not exists keep_forever boolean not null default false,
  add column if not exists protected boolean not null default false,   -- set by the owner only, never archived
  add column if not exists extra_bytes bigint not null default 0,
  add column if not exists archived_at timestamptz;
alter table public.photos add column if not exists archived_at timestamptz;

-- Roy and Adi's wedding is never archived
update public.weddings set protected = true, keep_forever = true where id = '2bf3364f-742b-4d42-b526-11dfbc6219c4';

create table if not exists public.purchases (
  id         uuid primary key default gen_random_uuid(),
  wedding_id uuid not null references public.weddings on delete cascade,
  member_id  uuid references public.members on delete set null,
  provider   text not null check (provider in ('apple', 'web', 'gift')),
  txn        text not null,
  product    text not null check (product in ('keep', 'storage5')),
  raw        jsonb,
  created_at timestamptz not null default now(),
  unique (provider, txn)
);
create index if not exists purchases_wedding on public.purchases (wedding_id);
alter table public.purchases enable row level security;
revoke all on public.purchases from anon, authenticated;

create or replace function public._wedding_bytes(p_wid uuid) returns bigint
language sql stable security definer set search_path = public, storage as $$
  select coalesce(sum((metadata->>'size')::bigint), 0) from storage.objects where bucket_id = 'photos' and name like p_wid::text || '/%'
$$;
revoke execute on function public._wedding_bytes(uuid) from public, anon, authenticated;

create or replace function public._plan(w weddings) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'bytes', _wedding_bytes(w.id),
    'quota_bytes', 1073741824 + w.extra_bytes,
    'keep_forever', w.keep_forever or w.protected,
    'archive_on', case when w.keep_forever or w.protected then null else w.wdate + 60 end,
    'days_left', case when w.keep_forever or w.protected then null else (w.wdate + 60) - (now() at time zone 'Asia/Jerusalem')::date end,
    'archived', w.archived_at is not null,
    'purchases', coalesce((select json_agg(json_build_object('product', p.product, 'at', p.created_at, 'by', coalesce(mm.name, '')) order by p.created_at)
                            from purchases p left join members mm on mm.id = p.member_id where p.wedding_id = w.id), '[]'::json))
$$;
revoke execute on function public._plan(weddings) from public, anon, authenticated;

-- what the app shows in "storage and keeping": everyone in the wedding may see it
create or replace function public.wedding_plan(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare m members; w weddings;
begin
  m := _member(p_token);
  select * into w from weddings where id = m.wedding_id;
  return _plan(w);
end $$;
revoke execute on function public.wedding_plan(uuid) from public;
grant execute on function public.wedding_plan(uuid) to anon, authenticated;

-- called only by the payment functions (pay-apple, and later the web provider) after they verified the payment
create or replace function public.apply_purchase(p_token uuid, p_provider text, p_txn text, p_product text, p_raw jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare m members; w weddings; new_id uuid; who text;
begin
  m := _member(p_token);
  if p_product not in ('keep', 'storage5') then raise exception 'bad_product' using errcode = 'P0001'; end if;
  insert into purchases (wedding_id, member_id, provider, txn, product, raw)
  values (m.wedding_id, m.id, p_provider, left(p_txn, 200), p_product, p_raw)
  on conflict (provider, txn) do nothing
  returning id into new_id;
  if new_id is not null then
    if p_product = 'keep' then update weddings set keep_forever = true, version = version + 1 where id = m.wedding_id;
    else update weddings set extra_bytes = extra_bytes + 5368709120, version = version + 1 where id = m.wedding_id; end if;
    who := m.name;
    perform _notify(_recips(m.wedding_id, '{groom,bride,guest}', '{couple,escort,guest}', null, m.id),
      case when p_product = 'keep' then 'התמונות נשמרות לתמיד 💛' else 'נוסף מקום לתמונות' end,
      case when p_product = 'keep' then who || ' דאג/ה שהאלבום של החתונה יישאר לתמיד' else who || ' הוסיף/ה 5GB לאלבום של החתונה' end,
      '#plan', 'plan');
  end if;
  select * into w from weddings where id = m.wedding_id;
  return _plan(w);
end $$;
revoke execute on function public.apply_purchase(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.apply_purchase(uuid, text, text, text, jsonb) to service_role;

-- uploads stop at the wedding's quota, and an archived wedding takes no new photos
create or replace function public.add_media(p_token uuid, p_kind text, p_path text, p_thumb text, p_blur text, p_w integer, p_h integer, p_duration real, p_caption text, p_vis text, p_task uuid)
 returns uuid language plpgsql security definer set search_path = public as $function$
declare m members; w weddings; pid uuid; v text := p_vis; esc boolean := false; k text := case when p_kind = 'video' then 'video' else 'image' end; re text;
begin
  m := _member(p_token);
  select * into w from weddings where id = m.wedding_id;
  re := '^' || w.id::text || '/[A-Za-z0-9_-]{8,80}\.(jpg|webp|mp4|mov|webm)$';
  if coalesce(p_path, '') !~ re or coalesce(p_thumb, '') !~ re or p_path like '%/cover-%' or p_thumb like '%/cover-%' then raise exception 'bad_path'; end if;
  select id into pid from photos where path = p_path and member_id = m.id;
  if pid is not null then return pid; end if;
  if w.archived_at is not null then raise exception 'archived' using errcode = 'P0001'; end if;
  if _wedding_bytes(w.id) > 1073741824 + w.extra_bytes then raise exception 'quota_full' using errcode = 'P0001'; end if;
  if exists (select 1 from photos where path in (p_path, p_thumb) or thumb_path in (p_path, p_thumb))
     or w.cover_path in (p_path, p_thumb) or w.cover_thumb in (p_path, p_thumb) or w.share_path in (p_path, p_thumb) then
    raise exception 'bad_path';
  end if;
  if p_blur is not null and (length(p_blur) > 6000 or p_blur !~ '^data:image/(jpeg|webp);base64,') then p_blur := null; end if;
  if m.role = 'guest' then v := 'team'; p_task := null;
  else
    if v = 'escorts' then v := 'team'; esc := true; end if;
    if v not in ('team','teaser','secret') then v := 'team'; end if;
    if v = 'teaser' and _revealed(w) then v := 'team'; end if;
  end if;
  insert into photos (wedding_id, team, member_id, kind, path, thumb_path, blur, w, h, duration, caption, vis, share_escorts, task_id)
  values (w.id, m.team, m.id, k, p_path, p_thumb, p_blur, p_w, p_h, p_duration, left(coalesce(p_caption, ''), 200), v, esc, p_task)
  returning id into pid;
  if p_task is not null then
    update tasks set done = true, done_by = m.id, done_side = m.team, done_at = now(), photo_id = pid
     where id = p_task and wedding_id = w.id and side in (m.team, 'all') and not done and not deleted;
  end if;
  return pid;
end $function$;

-- daily, from the purge function: warn 30, 7 and 1 days before, then list the originals to remove
create or replace function public.archive_tick(p_limit int default 300) returns json
language plpgsql security definer set search_path = public as $$
declare wr record; d int; k text;
begin
  for wr in select * from weddings x where not x.keep_forever and not x.protected and x.archived_at is null loop
    d := (wr.wdate + 60) - (now() at time zone 'Asia/Jerusalem')::date;
    k := case when d = 30 then 'archive30' when d = 7 then 'archive7' when d = 1 then 'archive1' end;
    if k is not null and not exists (select 1 from notified n where n.kind = k and n.ref = wr.id) then
      insert into notified (kind, ref, val) values (k, wr.id, d::text) on conflict do nothing;
      perform _notify(_recips(wr.id, '{groom,bride,guest}', '{couple,escort,guest}', null, null),
        case when d = 1 then 'מחר האלבום עובר לארכיון' else 'בעוד ' || d || ' ימים האלבום עובר לארכיון' end,
        'אחרי זה יישארו רק תמונות מוקטנות. אפשר להוריד הכל עכשיו או לשמור את האלבום לתמיד', '#plan', 'archive');
    end if;
  end loop;
  return (
    with due as (
      select p.id, p.path from photos p join weddings w on w.id = p.wedding_id
       where not w.keep_forever and not w.protected and w.archived_at is null
         and (w.wdate + 60) <= (now() at time zone 'Asia/Jerusalem')::date
         and p.archived_at is null and p.path <> p.thumb_path
       limit p_limit)
    select json_build_object(
      'ids', coalesce((select json_agg(id) from due), '[]'::json),
      'paths', coalesce((select json_agg(due.path) from due
                          where not exists (select 1 from photos q where q.thumb_path = due.path)
                            and not exists (select 1 from weddings w where due.path in (w.cover_path, w.cover_thumb, w.share_path))), '[]'::json)));
end $$;
revoke execute on function public.archive_tick(int) from public, anon, authenticated;
grant execute on function public.archive_tick(int) to service_role;

-- after the files are gone: keep the small copy as the photo, and close weddings that have nothing left to archive
create or replace function public.archive_done(p_ids uuid[]) returns json
language plpgsql security definer set search_path = public as $$
declare n int; wr record;
begin
  update photos set path = thumb_path, kind = 'image', duration = null, archived_at = now()
   where id = any (coalesce(p_ids, '{}')) and archived_at is null;
  get diagnostics n = row_count;
  for wr in select w.* from weddings w
             where not w.keep_forever and not w.protected and w.archived_at is null
               and (w.wdate + 60) <= (now() at time zone 'Asia/Jerusalem')::date
               and not exists (select 1 from photos p where p.wedding_id = w.id and p.archived_at is null and p.path <> p.thumb_path) loop
    update weddings set archived_at = now(), version = version + 1 where id = wr.id;
    perform _notify(_recips(wr.id, '{groom,bride,guest}', '{couple,escort,guest}', null, null),
      'האלבום עבר לארכיון', 'התמונות המוקטנות נשארות באפליקציה. תודה שחגגתם איתנו 💛', '#album', 'archive');
  end loop;
  return json_build_object('archived_photos', n);
end $$;
revoke execute on function public.archive_done(uuid[]) from public, anon, authenticated;
grant execute on function public.archive_done(uuid[]) to service_role;
