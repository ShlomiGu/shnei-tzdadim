create or replace function _notify_tick() returns void language plpgsql security definer set search_path to 'public' as $$
declare r record; n int; today date := (now() at time zone 'Asia/Jerusalem')::date; ttl text; body text; k int;
begin
  perform _notify_due();

  -- a quarter of an hour before the reveal
  begin
    for r in select w.* from weddings w
              where w.revealed_at is null and now() >= w.reveal_at - interval '15 minutes' and now() < w.reveal_at - interval '90 seconds'
                and not exists (select 1 from notified x where x.kind = 'soon' and x.ref = w.id and x.val = extract(epoch from w.reveal_at)::bigint::text)
    loop
      insert into notified (kind, ref, val) values ('soon', r.id, extract(epoch from r.reveal_at)::bigint::text)
        on conflict (kind, ref) do update set val = excluded.val, at = now();
      n := ceil(extract(epoch from r.reveal_at - now()) / 60);
      perform _notify(_recips(r.id, '{groom,bride}', '{couple,escort}', 'schedule'),
        'עוד ' || n || ' דקות החשיפה ✨',
        'זה הזמן להעלות את התמונות האחרונות. ב-' || to_char(r.reveal_at at time zone 'Asia/Jerusalem', 'HH24:MI') || ' שני האלבומים נפתחים', '#album', 'soon');
      perform _notify(_recips(r.id, '{guest}', '{guest}', 'schedule'),
        'עוד ' || n || ' דקות האלבום נפתח ✨',
        'ב-' || to_char(r.reveal_at at time zone 'Asia/Jerusalem', 'HH24:MI') || ' כל התמונות מהחתונה נפתחות לכולם', '#album', 'soon');
    end loop;
  exception when others then raise warning 'soon failed: %', sqlerrm;
  end;

  -- ten minutes before each schedule item (same time and side are combined)
  begin
    for r in
      select s.wedding_id wid, s.side, s.at_ts, string_agg(s.title, ' · ' order by s.title) titles,
             (array_agg(nullif(s.place, '') order by s.title) filter (where coalesce(s.place, '') <> ''))[1] place,
             array_agg(s.id) ids, array_agg(s.t) ts
        from (select s.*, (((w.wdate + case when s.t < '05:00' then 1 else 0 end) + (case when s.t ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then s.t else '00:00' end)::time) at time zone 'Asia/Jerusalem') at_ts
                from sched s join weddings w on w.id = s.wedding_id
               where not s.deleted and not coalesce(s.done, false) and not coalesce(s.reveal, false)
                 and s.t ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' and coalesce(s.title, '') <> ''
                 and w.wdate between today - 1 and today + 1
                 and not exists (select 1 from notified x where x.kind = 'sched' and x.ref = s.id and x.val = s.t)) s
       where s.at_ts > now() + interval '1 minute' and s.at_ts <= now() + interval '10 minutes'
       group by s.wedding_id, s.side, s.at_ts
    loop
      insert into notified (kind, ref, val) select 'sched', u.id, u.t from unnest(r.ids, r.ts) u(id, t)
        on conflict (kind, ref) do update set val = excluded.val, at = now();
      n := round(extract(epoch from r.at_ts - now()) / 60);
      perform _notify(_recips(r.wid, case when r.side in ('groom', 'bride') then array[r.side] else '{groom,bride}'::text[] end, '{couple,escort}', 'schedule'),
        'בעוד ' || n || ' דקות: ' || left(r.titles, 80),
        to_char(r.at_ts at time zone 'Asia/Jerusalem', 'HH24:MI') || coalesce(' · ' || r.place, ''), '#schedule', 'sched-' || left(r.ids[1]::text, 8));
    end loop;
  exception when others then raise warning 'sched failed: %', sqlerrm;
  end;

  -- each side's status, once it stayed the same for 45 seconds
  begin
    for r in
      select w.id, w.groom, w.bride, x.side, x.st, x.st_at from weddings w
       cross join lateral (values ('groom', w.status_groom, w.status_groom_at), ('bride', w.status_bride, w.status_bride_at)) x(side, st, st_at)
       where w.wdate between today - 1 and today + 1
         and coalesce(x.st_at, now()) < now() - interval '45 seconds'
         and coalesce(x.st, '') is distinct from coalesce((select y.val from notified y where y.kind = 'status-' || x.side and y.ref = w.id), '')
    loop
      insert into notified (kind, ref, val) values ('status-' || r.side, r.id, coalesce(r.st, ''))
        on conflict (kind, ref) do update set val = excluded.val, at = now();
      if coalesce(r.st, '') <> '' and r.st_at > now() - interval '30 minutes' then
        perform _notify(_recips(r.id, array[case when r.side = 'groom' then 'bride' else 'groom' end], '{couple,escort}', 'status'),
          case when r.side = 'groom' then r.groom else r.bride end || ': ' || left(r.st, 60),
          'עדכון מהצד של ' || case when r.side = 'groom' then 'החתן' else 'הכלה' end, '#home', 'status-' || r.side);
      end if;
    end loop;
  exception when others then raise warning 'status failed: %', sqlerrm;
  end;

  -- new photos, gathered: every 20 minutes before the reveal, every hour after it
  begin
    for r in
      select m.id mid, ((w.revealed_at is not null and w.revealed_at <= now()) or now() >= w.reveal_at) rv, x.at last_at,
             count(p.id) cnt, count(p.id) filter (where p.kind = 'video') vids, min(p.created_at) first_at,
             array_agg(distinct a.name) names
        from members m
        join weddings w on w.id = m.wedding_id
        left join notified x on x.kind = 'photos' and x.ref = m.id
        join photos p on p.wedding_id = m.wedding_id and p.member_id <> m.id and p.deleted_at is null and p.hidden_at is null
                     and p.created_at > coalesce(x.at, m.created_at)
                     and (p.team = m.team or (((w.revealed_at is not null and w.revealed_at <= now()) or now() >= w.reveal_at) and p.vis <> 'secret'))
        join members a on a.id = p.member_id
       where m.deleted_at is null and m.role in ('couple', 'escort') and _want(m.notify, 'photos')
         and w.wdate between today - 1 and today + 1
         and exists (select 1 from push_subs s where s.member_id = m.id and (s.p256dh <> '' or s.endpoint like 'apns:%'))
         and not exists (select 1 from blocks b where b.blocker_id = m.id and b.blocked_id = p.member_id and b.active)
         and not exists (select 1 from reports q where q.reporter_id = m.id and q.target_id = p.id)
       group by m.id, w.id, x.at
    loop
      continue when r.last_at is not null and now() - r.last_at < case when r.rv then interval '60 minutes' else interval '20 minutes' end;
      continue when r.first_at > now() - interval '3 minutes' and r.cnt < 10;
      insert into notified (kind, ref, val) values ('photos', r.mid, null) on conflict (kind, ref) do update set at = now();
      ttl := case when r.cnt = 1 then case when r.vids = 1 then 'סרטון חדש באלבום' else 'תמונה חדשה באלבום' end
                  when r.vids = r.cnt then r.cnt || ' סרטונים חדשים באלבום'
                  when r.vids > 0 then r.cnt || ' תמונות וסרטונים חדשים באלבום'
                  else r.cnt || ' תמונות חדשות באלבום' end;
      k := cardinality(r.names);
      body := 'מ' || r.names[1] || case when k = 2 then ' ו' || r.names[2] when k > 2 then ', ' || r.names[2] || ' ועוד ' || (k - 2) else '' end;
      perform _notify(array[r.mid], ttl, body, '#album', 'photos');
    end loop;
  exception when others then raise warning 'photos failed: %', sqlerrm;
  end;

  -- tasks someone else gave me
  begin
    for r in
      select t.who, count(*) cnt, (array_agg(t.title order by t.ord, t.created_at))[1] title, array_agg(t.id) ids
        from tasks t join members m on m.id = t.who
       where t.who is not null and not t.deleted and not coalesce(t.done, false) and m.deleted_at is null
         and not exists (select 1 from notified x where x.kind = 'task' and x.ref = t.id and x.val = t.who::text)
       group by t.who
    loop
      insert into notified (kind, ref, val) select 'task', u, r.who::text from unnest(r.ids) u
        on conflict (kind, ref) do update set val = excluded.val, at = now();
      if (select _want(notify, 'tasks') from members where id = r.who) then
        perform _notify(array[r.who],
          case when r.cnt = 1 then 'משימה בשבילך' else r.cnt || ' משימות חדשות בשבילך' end,
          left(r.title, 100) || case when r.cnt > 1 then ' ועוד ' || (r.cnt - 1) else '' end, '#tasks', 'task');
      end if;
    end loop;
  exception when others then raise warning 'tasks failed: %', sqlerrm;
  end;

  -- the morning after
  begin
    for r in select w.* from weddings w
              where now() >= (((w.wdate + 1) + time '10:30') at time zone 'Asia/Jerusalem')
                and now() < (((w.wdate + 1) + time '20:00') at time zone 'Asia/Jerusalem')
                and not exists (select 1 from notified x where x.kind = 'after' and x.ref = w.id and x.val = w.wdate::text)
    loop
      insert into notified (kind, ref, val) values ('after', r.id, r.wdate::text) on conflict (kind, ref) do update set val = excluded.val, at = now();
      perform _notify(_recips(r.id, '{groom,bride,guest}', '{couple,escort,guest}', null),
        'בוקר טוב 💛', 'כל התמונות מהחתונה של ' || r.groom || ' ו' || r.bride || ' מחכות לכם. אפשר גם להכין סרטון סיכום עם שיר', '#album', 'after');
    end loop;
  exception when others then raise warning 'after failed: %', sqlerrm;
  end;
exception when others then
  raise warning 'notify_tick failed: %', sqlerrm;
end $$;;
