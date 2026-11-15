create or replace function delete_sched(p_token uuid, p_id uuid) returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member_staff(p_token);
  update sched set deleted = true, reveal = false
   where id = p_id and wedding_id = m.wedding_id and side in (m.team, 'all') and (not reveal or _can_cover(m));
end $$;

create or replace function report_content(p_token uuid, p_kind text, p_id uuid, p_reason text, p_block boolean default false) returns json
language plpgsql security definer set search_path = public as $$
declare m members; tm uuid; n int := 0; moder boolean; hid boolean := false; mods uuid[];
begin
  m := _member(p_token);
  if (select count(*) from reports where reporter_id = m.id and created_at > now() - interval '1 hour') >= 15 then
    raise exception 'too_many' using errcode = 'P0001';
  end if;
  if p_kind = 'photo' then select member_id into tm from photos where id = p_id and wedding_id = m.wedding_id;
  elsif p_kind = 'teaser' then select member_id into tm from teasers where id = p_id and wedding_id = m.wedding_id;
  elsif p_kind = 'member' then select id into tm from members where id = p_id and wedding_id = m.wedding_id;
  else raise exception 'bad_kind' using errcode = 'P0001'; end if;
  if tm is null then raise exception 'not_found' using errcode = 'P0001'; end if;
  if tm = m.id then raise exception 'own_content' using errcode = 'P0001'; end if;
  insert into reports (wedding_id, reporter_id, kind, target_id, target_member, reason)
  values (m.wedding_id, m.id, p_kind, p_id, tm, left(coalesce(p_reason, ''), 300));
  moder := _can_cover(m);
  if p_kind in ('photo', 'teaser') then
    select count(distinct r.reporter_id) into n from reports r join members x on x.id = r.reporter_id
     where r.target_id = p_id and r.kind = p_kind and x.deleted_at is null and x.created_at < now() - interval '30 minutes';
    if moder or n >= 2 then
      hid := true;
      if p_kind = 'photo' then update photos set hidden_at = now(), hidden_by = m.id where id = p_id and hidden_at is null;
      else update teasers set hidden_at = now() where id = p_id and hidden_at is null; end if;
    end if;
  end if;
  if p_block then
    insert into blocks (wedding_id, blocker_id, blocked_id) values (m.wedding_id, m.id, tm)
    on conflict (blocker_id, blocked_id) do update set active = true, created_at = now();
  end if;
  if not hid and not exists (select 1 from notified x where x.kind = 'report' and x.ref = m.wedding_id and x.at > now() - interval '10 minutes') then
    insert into notified (kind, ref, val) values ('report', m.wedding_id, null) on conflict (kind, ref) do update set at = now();
    select array_agg(x.id) into mods from members x where x.wedding_id = m.wedding_id and x.deleted_at is null and x.id <> m.id and x.id <> tm and _can_cover(x);
    perform _notify(mods, 'דיווח על תוכן בחתונה', case when p_kind = 'teaser' then 'מישהו דיווח על טיזר. פתחו כדי לבדוק' else 'מישהו דיווח על תמונה. פתחו את האלבום כדי לבדוק ולהסיר אם צריך' end, '#album', 'report');
  end if;
  update weddings set version = version + 1 where id = m.wedding_id;
  return json_build_object('ok', true, 'hidden', hid);
end $$;

create or replace function save_push(p_token uuid, p_endpoint text, p_p256dh text, p_auth text) returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  if coalesce(p_endpoint, '') !~ '^https://(fcm\.googleapis\.com|android\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9-]+\.push\.apple\.com|[a-z0-9.-]+\.notify\.windows\.com)/'
     or length(p_endpoint) > 1000 or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then raise exception 'bad_input'; end if;
  insert into push_subs (endpoint, member_id, p256dh, auth) values (p_endpoint, m.id, left(p_p256dh, 200), left(p_auth, 100))
  on conflict (endpoint) do update set member_id = excluded.member_id, p256dh = excluded.p256dh, auth = excluded.auth, created_at = now();
  update push_subs set endpoint = 'gone:' || gen_random_uuid()::text, p256dh = '', auth = ''
   where member_id = m.id and endpoint like 'https://%'
     and endpoint not in (select endpoint from push_subs where member_id = m.id and endpoint like 'https://%' order by created_at desc limit 5);
end $$;

create or replace function save_device(p_token uuid, p_device text) returns void language plpgsql security definer set search_path to 'public' as $$
declare m members;
begin
  m := _member(p_token);
  if coalesce(p_device, '') !~ '^[0-9a-fA-F]{32,200}$' then raise exception 'bad_input'; end if;
  insert into push_subs (endpoint, member_id, p256dh, auth) values ('apns:' || lower(p_device), m.id, '', '')
  on conflict (endpoint) do update set member_id = excluded.member_id, p256dh = '', auth = '', created_at = now();
  update push_subs set endpoint = 'gone:' || gen_random_uuid()::text
   where member_id = m.id and endpoint like 'apns:%'
     and endpoint not in (select endpoint from push_subs where member_id = m.id and endpoint like 'apns:%' order by created_at desc limit 5);
end $$;

create or replace function _on_teaser() returns trigger language plpgsql security definer set search_path to 'public' as $$
declare other text := case when new.team = 'groom' then 'bride' else 'groom' end; k text := 'teaser-' || new.team;
begin
  begin
    if new.team = 'guest' or new.hidden_at is not null then return null; end if;
    if exists (select 1 from notified x where x.kind = k and x.ref = new.wedding_id and x.at > now() - interval '90 seconds') then return null; end if;
    insert into notified (kind, ref, val) values (k, new.wedding_id, null) on conflict (kind, ref) do update set at = now();
    perform _notify(_recips(new.wedding_id, array[other], '{couple,escort}', 'teasers', new.member_id),
      'טיזר חדש מ' || case when new.team = 'groom' then 'חבורת החתן' else 'חבורת הכלה' end,
      coalesce(nullif(new.body, ''), case when cardinality(new.photo_ids) > 0 then 'תמונה מטושטשת מחכה לכם' else 'פתחו לראות' end),
      '#teasers', 'teaser');
  exception when others then raise warning 'teaser notify failed: %', sqlerrm;
  end;
  return null;
end $$;

create or replace function backup_manifest(p_token uuid) returns json language plpgsql security definer set search_path = public as $$
declare m members; w weddings; rv boolean;
begin
  m := _member(p_token);
  select * into w from weddings where id = m.wedding_id;
  rv := _revealed(w);
  return coalesce((select json_agg(json_build_object('id', p.id, 'kind', p.kind, 'team', p.team, 'path', p.path, 'caption', p.caption,
      'by', (select name from members x where x.id = p.member_id), 'at', p.created_at) order by p.created_at)
    from photos p where p.wedding_id = w.id and p.deleted_at is null and p.hidden_at is null
      and not exists (select 1 from blocks b where b.blocker_id = m.id and b.blocked_id = p.member_id and b.active)
      and not exists (select 1 from reports r where r.reporter_id = m.id and r.target_id = p.id)
      and (p.team = m.team or (p.vis <> 'secret' and (rv or (p.share_escorts and m.role = 'escort'))))), '[]'::json);
end $$;

do $$ declare d text; a text := 'case when not g and not exists (select 1 from members x where x.wedding_id = w.id and x.team = other)'; begin
  select pg_get_functiondef('public.get_state(uuid)'::regprocedure) into d;
  if position('not g and _can_cover(m) and not exists' in d) = 0 then
    if position(a in d) = 0 then raise exception 'get_state: other_code anchor not found'; end if;
    d := replace(d, a, 'case when not g and _can_cover(m) and not exists (select 1 from members x where x.wedding_id = w.id and x.team = other)');
    execute d;
  end if;
end $$;;
