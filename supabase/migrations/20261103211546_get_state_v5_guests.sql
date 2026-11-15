create or replace function public.get_state(p_token uuid)
returns json language plpgsql stable security definer set search_path = public as $$
declare m members; w weddings; rv boolean; other text; esc boolean; g boolean;
begin
  m := _member(p_token);
  select * into w from weddings where id = m.wedding_id;
  rv := _revealed(w);
  g := m.role = 'guest';
  esc := m.role = 'escort';
  other := case when m.team = 'groom' then 'bride' when m.team = 'bride' then 'groom' else null end;
  return json_build_object(
    'now', now(),
    'version', w.version,
    'revealed', rv,
    'me', json_build_object('id', m.id, 'team', m.team, 'role', m.role, 'name', m.name),
    'wedding', json_build_object(
      'id', w.id, 'groom', w.groom, 'bride', w.bride, 'date', w.wdate,
      'reveal_at', w.reveal_at, 'revealed_at', w.revealed_at, 'venue', w.venue, 'venue_city', w.venue_city, 'contacts', case when g then '[]'::jsonb else w.contacts end,
      'my_code', case when m.team = 'groom' then w.code_groom when m.team = 'bride' then w.code_bride else w.code_guest end,
      'guest_code', w.code_guest,
      'other_code', case when not g and not exists (select 1 from members x where x.wedding_id = w.id and x.team = other)
                         then case when other = 'groom' then w.code_groom else w.code_bride end end),
    'members', coalesce((select json_agg(json_build_object('id', x.id, 'team', x.team, 'role', x.role, 'name', x.name) order by x.created_at)
                         from members x where x.wedding_id = w.id and (not g or x.team <> 'guest' or x.id = m.id)), '[]'::json),
    'photos', coalesce((select json_agg(ph order by ph.created_at desc) from (
        select p.id, p.team, p.member_id, p.created_at, p.task_id, p.w, p.h, p.blur, p.kind, p.duration,
               case when p.team = m.team or rv or (p.share_escorts and esc) then 'full' else 'blur' end as mode,
               case when p.team = m.team or rv or (p.share_escorts and esc) then p.path end as path,
               case when p.team = m.team or rv or (p.share_escorts and esc) then p.thumb_path end as thumb_path,
               p.caption,
               case when p.team = m.team and not g then (case when p.share_escorts and p.vis = 'team' then 'escorts' else p.vis end) end as vis,
               (p.team <> m.team and not rv and p.share_escorts and esc) as early,
               (select count(*) from hearts h where h.photo_id = p.id and h.active)::int as hearts,
               exists (select 1 from hearts h where h.photo_id = p.id and h.member_id = m.id and h.active) as hearted
          from photos p
         where p.wedding_id = w.id and p.deleted_at is null
           and (p.team = m.team
                or (p.vis <> 'secret' and (rv or (not g and p.team <> 'guest' and (p.vis = 'teaser' or (p.share_escorts and esc))))))
      ) ph), '[]'::json),
    'hidden', case when g then 0 else (select count(*) from photos p where p.wedding_id = w.id and p.deleted_at is null and p.team = other and p.vis = 'team'
                 and not rv and not (p.share_escorts and esc))::int end,
    'teasers', case when g then '[]'::json else coalesce((select json_agg(json_build_object(
        'id', t.id, 'team', t.team, 'member_id', t.member_id, 'body', t.body, 'photo_ids', t.photo_ids, 'created_at', t.created_at,
        'reacts', coalesce((select json_object_agg(r.emoji, r.n) from (select emoji, count(*)::int n from reacts r where r.teaser_id = t.id and r.emoji <> '' group by emoji) r), '{}'::json),
        'my_react', (select nullif(r.emoji, '') from reacts r where r.teaser_id = t.id and r.member_id = m.id)
      ) order by t.created_at) from teasers t where t.wedding_id = w.id), '[]'::json) end,
    'sched', coalesce((select json_agg(json_build_object('id', s.id, 't', s.t, 'title', s.title, 'place', s.place, 'note', s.note,
        'side', s.side, 'done', s.done, 'reveal', s.reveal) order by s.t, s.created_at) from sched s where s.wedding_id = w.id and not s.deleted and (not g or s.side = 'all')), '[]'::json),
    'tasks', case when g then '[]'::json else coalesce((select json_agg(json_build_object('id', k.id, 'title', k.title, 'side', k.side, 'pts', k.pts, 'mission', k.mission,
        'who', k.who, 'done', k.done, 'done_by', k.done_by, 'done_at', k.done_at, 'photo_id', k.photo_id) order by k.ord, k.created_at)
        from tasks k where k.wedding_id = w.id and not k.deleted and k.side in (m.team, 'all')), '[]'::json) end,
    'scores', json_build_object(
      'groom', coalesce((select sum(pts) from tasks k where k.wedding_id = w.id and k.done and not k.deleted and coalesce(nullif(k.side, 'all'), k.done_side) = 'groom'), 0)
             + 2 * (select count(*) from photos p where p.wedding_id = w.id and p.deleted_at is null and p.team = 'groom'),
      'bride', coalesce((select sum(pts) from tasks k where k.wedding_id = w.id and k.done and not k.deleted and coalesce(nullif(k.side, 'all'), k.done_side) = 'bride'), 0)
             + 2 * (select count(*) from photos p where p.wedding_id = w.id and p.deleted_at is null and p.team = 'bride')),
    'letters', case when g then '[]'::json else coalesce((select json_agg(json_build_object(
        'id', l.id, 'from_team', l.from_team, 'member_id', l.member_id, 'open_at', l.open_at, 'created_at', l.created_at,
        'body', case when l.member_id = m.id or (m.role = 'couple' and m.team <> l.from_team and now() >= l.open_at) then l.body end
      ) order by l.created_at) from letters l where l.wedding_id = w.id and not l.deleted), '[]'::json) end
  );
end $$;;
