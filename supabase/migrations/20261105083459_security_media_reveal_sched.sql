create unique index if not exists photos_path_uq on photos (path);
create unique index if not exists photos_thumb_uq on photos (thumb_path);

create or replace function add_media(p_token uuid, p_kind text, p_path text, p_thumb text, p_blur text, p_w integer, p_h integer, p_duration real, p_caption text, p_vis text, p_task uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare m members; w weddings; pid uuid; v text := p_vis; esc boolean := false; k text := case when p_kind = 'video' then 'video' else 'image' end; re text;
begin
  m := _member(p_token);
  select * into w from weddings where id = m.wedding_id;
  re := '^' || w.id::text || '/[A-Za-z0-9_-]{8,80}\.(jpg|webp|mp4|mov|webm)$';
  if coalesce(p_path, '') !~ re or coalesce(p_thumb, '') !~ re or p_path like '%/cover-%' or p_thumb like '%/cover-%' then raise exception 'bad_path'; end if;
  select id into pid from photos where path = p_path and member_id = m.id;
  if pid is not null then return pid; end if;
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
end $$;

create or replace function set_reveal(p_token uuid, p_now boolean) returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member_staff(p_token);
  if not _can_cover(m) then raise exception 'reveal_owner' using errcode = 'P0001'; end if;
  update weddings set revealed_at = case when p_now then now() else null end, version = version + 1 where id = m.wedding_id;
end $$;

create or replace function update_wedding(p_token uuid, p jsonb) returns void language plpgsql security definer set search_path = public as $$
declare m members; w weddings; c jsonb;
begin
  m := _member_staff(p_token);
  select * into w from weddings where id = m.wedding_id;
  if p ? 'reveal_at' and (p->>'reveal_at')::timestamptz is distinct from w.reveal_at and not _can_cover(m) then
    raise exception 'reveal_owner' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p->'contacts') = 'array' then
    select coalesce(jsonb_agg(jsonb_build_object('name', left(coalesce(x->>'name', ''), 40), 'role', left(coalesce(x->>'role', ''), 40), 'phone', left(coalesce(x->>'phone', ''), 30))), '[]'::jsonb)
      into c from (select x from jsonb_array_elements(p->'contacts') x where jsonb_typeof(x) = 'object' limit 30) q;
  end if;
  update weddings set
    groom = coalesce(nullif(left(trim(p->>'groom'), 40), ''), groom),
    bride = coalesce(nullif(left(trim(p->>'bride'), 40), ''), bride),
    wdate = coalesce((p->>'date')::date, wdate),
    venue = case when p ? 'venue' then left(coalesce(p->>'venue', ''), 80) else venue end,
    venue_city = case when p ? 'venue_city' then left(coalesce(p->>'venue_city', ''), 40) else venue_city end,
    contacts = coalesce(c, contacts),
    reveal_at = coalesce((p->>'reveal_at')::timestamptz, reveal_at),
    version = version + 1
  where id = m.wedding_id;
  if coalesce((p->>'venue_custom')::boolean, false) and coalesce(trim(p->>'venue'), '') <> '' then
    insert into venues_custom (name, city, wedding_id, hidden) values (left(trim(p->>'venue'), 80), left(coalesce(trim(p->>'venue_city'), ''), 40), m.wedding_id, true)
    on conflict do nothing;
  end if;
end $$;

create or replace function save_sched(p_token uuid, p_id uuid, p_t text, p_title text, p_place text, p_note text, p_side text, p_done boolean, p_reveal boolean, p_reveal_at timestamp with time zone)
returns uuid language plpgsql security definer set search_path = public as $$
declare m members; sid uuid;
begin
  m := _member_staff(p_token);
  if p_t !~ '^\d\d:\d\d$' or coalesce(trim(p_title), '') = '' then raise exception 'bad_input'; end if;
  if p_side not in ('all', m.team) then p_side := case when p_side in ('groom', 'bride') then m.team else 'all' end; end if;
  if p_id is null then
    insert into sched (wedding_id, t, title, place, note, side, done, reveal)
    values (m.wedding_id, p_t, left(trim(p_title), 80), left(coalesce(p_place, ''), 80), left(coalesce(p_note, ''), 160), p_side, coalesce(p_done, false), coalesce(p_reveal, false) and _can_cover(m))
    returning id into sid;
  else
    update sched set t = case when reveal and not _can_cover(m) then t else p_t end, title = left(trim(p_title), 80), place = left(coalesce(p_place, ''), 80), note = left(coalesce(p_note, ''), 160),
                     side = p_side, done = coalesce(p_done, false), reveal = case when _can_cover(m) then coalesce(p_reveal, false) else reveal end
     where id = p_id and wedding_id = m.wedding_id and not deleted and side in (m.team, 'all') returning id into sid;
    if sid is null then raise exception 'not_found'; end if;
  end if;
  if p_reveal and _can_cover(m) then
    update sched set reveal = false where wedding_id = m.wedding_id and id <> sid and reveal;
    if p_reveal_at is not null then update weddings set reveal_at = p_reveal_at, version = version + 1 where id = m.wedding_id; end if;
  end if;
  return sid;
end $$;

create or replace function ai_apply_sched(p_token uuid, p_items jsonb, p_reveal_at timestamp with time zone) returns void language plpgsql security definer set search_path = public as $$
declare m members; e jsonb; sid uuid; keep uuid[] := '{}'; s text; tt text; rid uuid; own boolean;
begin
  m := _member_staff(p_token);
  own := _can_cover(m);
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 60 then raise exception 'bad_input'; end if;
  for e in select * from jsonb_array_elements(p_items) loop
    tt := e->>'t';
    if tt is null or tt !~ '^\d\d:\d\d$' or coalesce(trim(e->>'title'), '') = '' then continue; end if;
    s := case when e->>'side' in (m.team, 'all') then e->>'side' else m.team end;
    sid := null;
    if coalesce(e->>'id', '') ~ '^[0-9a-f-]{36}$' then
      update sched set t = case when reveal and not own then t else tt end, title = left(trim(e->>'title'), 80), place = left(coalesce(e->>'place', ''), 80), note = left(coalesce(e->>'note', ''), 160),
                       side = s, done = coalesce((e->>'done')::boolean, done), reveal = case when own then false else reveal end
       where id = (e->>'id')::uuid and wedding_id = m.wedding_id and not deleted and side in (m.team, 'all')
       returning id into sid;
    end if;
    if sid is null then
      insert into sched (wedding_id, t, title, place, note, side, done)
      values (m.wedding_id, tt, left(trim(e->>'title'), 80), left(coalesce(e->>'place', ''), 80), left(coalesce(e->>'note', ''), 160), s, coalesce((e->>'done')::boolean, false))
      returning id into sid;
    end if;
    keep := keep || sid;
    if coalesce((e->>'reveal')::boolean, false) then rid := sid; end if;
  end loop;
  update sched set deleted = true, reveal = false
   where wedding_id = m.wedding_id and not deleted and side in (m.team, 'all') and not (id = any (keep)) and (own or not reveal);
  if rid is not null and own then
    update sched set reveal = (id = rid) where wedding_id = m.wedding_id and (reveal or id = rid);
    if p_reveal_at is not null then update weddings set reveal_at = p_reveal_at, version = version + 1 where id = m.wedding_id; end if;
  end if;
end $$;;
