create or replace function public.save_sched(p_token uuid, p_id uuid, p_t text, p_title text, p_place text, p_note text,
  p_side text, p_done boolean, p_reveal boolean, p_reveal_at timestamptz)
returns uuid language plpgsql security definer set search_path = public as $$
declare m members; sid uuid;
begin
  m := _member(p_token);
  if p_t !~ '^\d\d:\d\d$' or coalesce(trim(p_title), '') = '' then raise exception 'bad_input'; end if;
  if p_side not in ('all','groom','bride') then p_side := 'all'; end if;
  if p_id is null then
    insert into sched (wedding_id, t, title, place, note, side, done, reveal)
    values (m.wedding_id, p_t, left(trim(p_title), 80), left(coalesce(p_place, ''), 80), left(coalesce(p_note, ''), 160), p_side, coalesce(p_done, false), coalesce(p_reveal, false))
    returning id into sid;
  else
    update sched set t = p_t, title = left(trim(p_title), 80), place = left(coalesce(p_place, ''), 80), note = left(coalesce(p_note, ''), 160),
                     side = p_side, done = coalesce(p_done, false), reveal = coalesce(p_reveal, false)
     where id = p_id and wedding_id = m.wedding_id and not deleted returning id into sid;
    if sid is null then raise exception 'not_found'; end if;
  end if;
  if p_reveal then
    update sched set reveal = false where wedding_id = m.wedding_id and id <> sid and reveal;
    if p_reveal_at is not null then update weddings set reveal_at = p_reveal_at, version = version + 1 where id = m.wedding_id; end if;
  end if;
  return sid;
end $$;

create or replace function public.delete_sched(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  update sched set deleted = true, reveal = false where id = p_id and wedding_id = m.wedding_id;
end $$;

create or replace function public.save_task(p_token uuid, p_id uuid, p_title text, p_side text, p_pts int, p_mission boolean, p_who uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare m members; tid uuid;
begin
  m := _member(p_token);
  if coalesce(trim(p_title), '') = '' then raise exception 'bad_input'; end if;
  if p_side is null or p_side not in (m.team, 'all') then p_side := m.team; end if;
  if p_who is not null and not exists (select 1 from members x where x.id = p_who and x.wedding_id = m.wedding_id) then p_who := null; end if;
  if p_id is null then
    insert into tasks (wedding_id, title, side, pts, mission, who, ord)
    values (m.wedding_id, left(trim(p_title), 120), p_side, greatest(0, least(100, coalesce(p_pts, 10))), coalesce(p_mission, false), p_who,
            coalesce((select max(ord) + 1 from tasks where wedding_id = m.wedding_id), 0))
    returning id into tid;
  else
    update tasks set title = left(trim(p_title), 120), side = p_side, pts = greatest(0, least(100, coalesce(p_pts, 10))),
                     mission = coalesce(p_mission, false), who = p_who
     where id = p_id and wedding_id = m.wedding_id and side in (m.team, 'all') and not deleted returning id into tid;
    if tid is null then raise exception 'not_found'; end if;
  end if;
  return tid;
end $$;

create or replace function public.toggle_task(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  update tasks set
    done = not done,
    done_by = case when done then null else m.id end,
    done_side = case when done then null else m.team end,
    done_at = case when done then null else now() end,
    photo_id = case when done then null else photo_id end
  where id = p_id and wedding_id = m.wedding_id and side in (m.team, 'all') and not deleted;
end $$;

create or replace function public.claim_task(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  update tasks set who = case when who = m.id then null else m.id end
   where id = p_id and wedding_id = m.wedding_id and side in (m.team, 'all') and not deleted;
end $$;

create or replace function public.delete_task(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  update tasks set deleted = true where id = p_id and wedding_id = m.wedding_id and side in (m.team, 'all');
end $$;

create or replace function public.write_letter(p_token uuid, p_body text, p_open_at timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  if m.role <> 'couple' then raise exception 'couple_only'; end if;
  if coalesce(trim(p_body), '') = '' then raise exception 'empty'; end if;
  insert into letters (wedding_id, from_team, member_id, body, open_at) values (m.wedding_id, m.team, m.id, left(p_body, 6000), p_open_at);
end $$;

create or replace function public.delete_letter(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  update letters set deleted = true where id = p_id and member_id = m.id;
end $$;

create or replace function public.update_wedding(p_token uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  update weddings set
    groom = coalesce(nullif(left(trim(p->>'groom'), 40), ''), groom),
    bride = coalesce(nullif(left(trim(p->>'bride'), 40), ''), bride),
    wdate = coalesce((p->>'date')::date, wdate),
    venue = case when p ? 'venue' then left(coalesce(p->>'venue', ''), 80) else venue end,
    contacts = case when jsonb_typeof(p->'contacts') = 'array' then p->'contacts' else contacts end,
    reveal_at = coalesce((p->>'reveal_at')::timestamptz, reveal_at),
    version = version + 1
  where id = m.wedding_id;
end $$;

create or replace function public.set_reveal(p_token uuid, p_now boolean)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  update weddings set revealed_at = case when p_now then now() else null end, version = version + 1 where id = m.wedding_id;
end $$;

create or replace function public.update_me(p_token uuid, p_name text, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  update members set name = coalesce(nullif(left(trim(p_name), 30), ''), name),
                     role = case when p_role in ('escort','couple') then p_role else role end
   where id = m.id;
end $$;;
