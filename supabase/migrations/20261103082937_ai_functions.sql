create or replace function public.ai_context(p_token uuid, p_kind text)
returns json language plpgsql security definer set search_path = public as $$
declare m members; w weddings; n int;
begin
  m := _member(p_token);
  select count(*) into n from ai_log where member_id = m.id and created_at > now() - interval '1 hour';
  if n >= 30 then raise exception 'rate_limited'; end if;
  insert into ai_log (member_id, kind) values (m.id, p_kind);
  select * into w from weddings where id = m.wedding_id;
  return json_build_object(
    'me', json_build_object('team', m.team, 'role', m.role, 'name', m.name),
    'wedding', json_build_object('groom', w.groom, 'bride', w.bride, 'date', w.wdate, 'reveal_at', w.reveal_at, 'venue', w.venue, 'venue_city', w.venue_city),
    'members', coalesce((select json_agg(json_build_object('id', x.id, 'name', x.name, 'team', x.team, 'role', x.role)) from members x where x.wedding_id = w.id), '[]'::json),
    'sched', case when p_kind = 'sched' then coalesce((select json_agg(json_build_object('id', s.id, 't', s.t, 'title', s.title, 'place', s.place, 'note', s.note, 'side', s.side, 'done', s.done, 'reveal', s.reveal) order by s.t)
                from sched s where s.wedding_id = w.id and not s.deleted and s.side in (m.team, 'all')), '[]'::json) end,
    'sched_other', case when p_kind = 'sched' then coalesce((select json_agg(json_build_object('t', s.t, 'title', s.title) order by s.t)
                from sched s where s.wedding_id = w.id and not s.deleted and s.side not in (m.team, 'all')), '[]'::json) end,
    'tasks', case when p_kind = 'tasks' then coalesce((select json_agg(json_build_object('id', k.id, 'title', k.title, 'side', k.side, 'pts', k.pts, 'mission', k.mission, 'who', k.who, 'done', k.done) order by k.ord)
                from tasks k where k.wedding_id = w.id and not k.deleted and k.side in (m.team, 'all')), '[]'::json) end
  );
end $$;
revoke execute on function public.ai_context(uuid, text) from public, anon, authenticated;
grant execute on function public.ai_context(uuid, text) to service_role;

create or replace function public.ai_apply_sched(p_token uuid, p_items jsonb, p_reveal_at timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare m members; e jsonb; sid uuid; keep uuid[] := '{}'; s text; tt text; rid uuid;
begin
  m := _member(p_token);
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 60 then raise exception 'bad_input'; end if;
  for e in select * from jsonb_array_elements(p_items) loop
    tt := e->>'t';
    if tt is null or tt !~ '^\d\d:\d\d$' or coalesce(trim(e->>'title'), '') = '' then continue; end if;
    s := case when e->>'side' in (m.team, 'all') then e->>'side' else m.team end;
    sid := null;
    if coalesce(e->>'id', '') ~ '^[0-9a-f-]{36}$' then
      update sched set t = tt, title = left(trim(e->>'title'), 80), place = left(coalesce(e->>'place', ''), 80), note = left(coalesce(e->>'note', ''), 160),
                       side = s, done = coalesce((e->>'done')::boolean, done), reveal = false
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
   where wedding_id = m.wedding_id and not deleted and side in (m.team, 'all') and not (id = any (keep));
  if rid is not null then
    update sched set reveal = (id = rid) where wedding_id = m.wedding_id and (reveal or id = rid);
    if p_reveal_at is not null then update weddings set reveal_at = p_reveal_at, version = version + 1 where id = m.wedding_id; end if;
  end if;
end $$;

create or replace function public.ai_apply_tasks(p_token uuid, p_items jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare m members; e jsonb; tid uuid; keep uuid[] := '{}'; s text; wh uuid; mx int;
begin
  m := _member(p_token);
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 80 then raise exception 'bad_input'; end if;
  select coalesce(max(ord), 0) into mx from tasks where wedding_id = m.wedding_id;
  for e in select * from jsonb_array_elements(p_items) loop
    if coalesce(trim(e->>'title'), '') = '' then continue; end if;
    s := case when e->>'side' in (m.team, 'all') then e->>'side' else m.team end;
    wh := null;
    if coalesce(e->>'who', '') ~ '^[0-9a-f-]{36}$' then
      select x.id into wh from members x where x.id = (e->>'who')::uuid and x.wedding_id = m.wedding_id;
    end if;
    tid := null;
    if coalesce(e->>'id', '') ~ '^[0-9a-f-]{36}$' then
      update tasks set title = left(trim(e->>'title'), 120), side = s,
                       pts = greatest(0, least(100, coalesce((e->>'pts')::int, pts))),
                       mission = coalesce((e->>'mission')::boolean, mission),
                       who = case when e ? 'who' then wh else who end
       where id = (e->>'id')::uuid and wedding_id = m.wedding_id and not deleted and side in (m.team, 'all')
       returning id into tid;
    end if;
    if tid is null then
      mx := mx + 1;
      insert into tasks (wedding_id, title, side, pts, mission, who, ord)
      values (m.wedding_id, left(trim(e->>'title'), 120), s, greatest(0, least(100, coalesce((e->>'pts')::int, 10))), coalesce((e->>'mission')::boolean, false), wh, mx)
      returning id into tid;
    end if;
    keep := keep || tid;
  end loop;
  update tasks set deleted = true
   where wedding_id = m.wedding_id and not deleted and side in (m.team, 'all') and not (id = any (keep));
end $$;;
