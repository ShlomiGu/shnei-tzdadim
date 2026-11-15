create or replace function _selftest_notify() returns jsonb language plpgsql security definer set search_path = public as $$
declare
  res jsonb := '[]'::jsonb; w uuid; g1 uuid; g2 uuid; gc uuid; b1 uuid; b2 uuid; b3 uuid; bc uuid; gu uuid;
  tb1 uuid := gen_random_uuid(); tg1 uuid := gen_random_uuid(); start bigint; n1 int; n2 int; v jsonb; e text;
  hh text := to_char((now() + interval '8 minutes') at time zone 'Asia/Jerusalem', 'HH24:MI');
  dev text := md5(random()::text) || md5(random()::text);
  logs jsonb;
begin
  select coalesce(max(id), 0) into start from notify_log;
  begin
    insert into weddings (groom, bride, wdate, reveal_at, code_groom, code_bride)
    values ('יואב', 'נועה', (now() at time zone 'Asia/Jerusalem')::date, now() + interval '10 minutes',
            upper(substr(md5(random()::text), 1, 6)), upper(substr(md5(random()::text), 1, 6))) returning id into w;
    insert into members (wedding_id, team, role, name, token) values (w, 'groom', 'escort', 'אורי', tg1) returning id into g1;
    insert into members (wedding_id, team, role, name) values (w, 'groom', 'escort', 'דן') returning id into g2;
    insert into members (wedding_id, team, role, name) values (w, 'groom', 'couple', 'יואב') returning id into gc;
    insert into members (wedding_id, team, role, name, token, notify) values (w, 'bride', 'escort', 'שירה', tb1, '{"teasers": false}') returning id into b1;
    insert into members (wedding_id, team, role, name) values (w, 'bride', 'escort', 'מאיה') returning id into b2;
    insert into members (wedding_id, team, role, name) values (w, 'bride', 'escort', 'טל') returning id into b3;
    insert into members (wedding_id, team, role, name) values (w, 'bride', 'couple', 'נועה') returning id into bc;
    insert into members (wedding_id, team, role, name) values (w, 'guest', 'guest', 'אורח') returning id into gu;
    insert into blocks (wedding_id, blocker_id, blocked_id, active) values (w, b2, g1, true);
    insert into push_subs (endpoint, member_id, p256dh, auth) values ('apns:' || md5(random()::text), g2, '', '');
    insert into notified (kind, ref, val, at) values ('photos', g2, null, now() - interval '30 minutes');

    -- teaser: other side, minus the one who turned teasers off and the one who blocked the author
    insert into teasers (wedding_id, team, member_id, body) values (w, 'groom', g1, 'מה אתן לובשות?');
    select members into v from (select to_jsonb(members) members from notify_log where id > start and tag = 'teaser' order by id desc limit 1) x;
    res := res || jsonb_build_object('t', 'teaser goes to bride couple + escorts minus muted and blocked', 'ok', v = to_jsonb(array[b3, bc]) or v = to_jsonb(array[bc, b3]), 'got', v);

    -- early photo for the other side's escorts
    insert into photos (wedding_id, team, member_id, path, thumb_path, vis, share_escorts, kind) values (w, 'groom', g1, 'x', 'x', 'team', true, 'image');
    select members into v from (select to_jsonb(members) members from notify_log where id > start and tag = 'early' order by id desc limit 1) x;
    res := res || jsonb_build_object('t', 'early photo to bride escorts minus muted and blocked', 'ok', v = to_jsonb(array[b3]), 'got', v);

    -- material for the minute job
    insert into photos (wedding_id, team, member_id, path, thumb_path, vis, kind, created_at) values
      (w, 'groom', g1, 'x', 'x', 'team', 'image', now() - interval '5 minutes'),
      (w, 'groom', g1, 'x', 'x', 'team', 'video', now() - interval '5 minutes'),
      (w, 'groom', gc, 'x', 'x', 'secret', 'image', now() - interval '4 minutes'),
      (w, 'bride', b1, 'x', 'x', 'team', 'image', now() - interval '4 minutes');
    insert into sched (wedding_id, t, title, side, place) values (w, hh, 'צילומי זוג', 'groom', 'הגן הבוטני'), (w, hh, 'קבלת פנים', 'all', null);
    update weddings set status_groom = 'יצאנו לדרך', status_groom_at = now() - interval '2 minutes' where id = w;
    insert into tasks (wedding_id, title, side, who) values (w, 'להביא את הטבעות', 'bride', b1);
    perform set_config('app.actor', b3::text, true);
    insert into tasks (wedding_id, title, side, who) values (w, 'לקחתי לעצמי', 'bride', b3);
    perform set_config('app.actor', '', true);

    perform _notify_tick();
    select jsonb_agg(jsonb_build_object('tag', tag, 'n', cardinality(members), 'title', title, 'body', body) order by id) into logs from notify_log where id > start and members && array[g1, g2, gc, b1, b2, b3, bc, gu];
    res := res || jsonb_build_object('t', 'log', 'rows', logs);

    select count(*) into n1 from notify_log where id > start and tag = 'soon' and members @> array[g1, g2, gc, b1, b2, b3, bc] and cardinality(members) = 7;
    res := res || jsonb_build_object('t', 'reveal soon to all 7 squad members', 'ok', n1 = 1);
    select count(*) into n1 from notify_log where id > start and tag = 'soon' and members = array[gu];
    res := res || jsonb_build_object('t', 'reveal soon to the guest separately', 'ok', n1 = 1);
    select count(*) into n1 from notify_log where id > start and tag like 'sched-%' and members @> array[g1, g2, gc] and cardinality(members) = 3 and title like 'בעוד % דקות: צילומי זוג' and body like '% · הגן הבוטני';
    res := res || jsonb_build_object('t', 'groom-side schedule item to groom side only, with place', 'ok', n1 = 1);
    select count(*) into n1 from notify_log where id > start and tag like 'sched-%' and cardinality(members) = 7 and title like '%קבלת פנים';
    res := res || jsonb_build_object('t', 'shared schedule item to both sides', 'ok', n1 = 1);
    select count(*) into n1 from notify_log where id > start and tag = 'status-groom' and members @> array[b1, b2, b3, bc] and cardinality(members) = 4 and title = 'יואב: יצאנו לדרך';
    res := res || jsonb_build_object('t', 'groom status to bride side', 'ok', n1 = 1);
    select count(*) into n1 from notify_log where id > start and tag = 'photos' and members = array[g2] and title like '4 תמונות וסרטונים חדשים באלבום' and body like 'מ%';
    res := res || jsonb_build_object('t', 'photo digest counts own side only (4), not the bride photo', 'ok', n1 = 1);
    select count(*) into n1 from notify_log where id > start and tag = 'task' and members = array[b1] and body = 'להביא את הטבעות';
    res := res || jsonb_build_object('t', 'task given by someone else is announced', 'ok', n1 = 1);
    select count(*) into n1 from notify_log where id > start and tag = 'task' and members = array[b3];
    res := res || jsonb_build_object('t', 'task taken for myself is not announced', 'ok', n1 = 0);

    select count(*) into n1 from notify_log where id > start;
    perform _notify_tick();
    select count(*) into n2 from notify_log where id > start;
    res := res || jsonb_build_object('t', 'second run sends nothing new', 'ok', n1 = n2, 'before', n1, 'after', n2);

    update weddings set status_groom = 'הגענו לאולם', status_groom_at = now() where id = w;
    perform _notify_tick();
    select count(*) into n1 from notify_log where id > start and tag = 'status-groom';
    res := res || jsonb_build_object('t', 'status waits 45 seconds before announcing', 'ok', n1 = 1);

    v := set_notify(tb1, '{"photos": false, "bogus": true, "tasks": "x"}');
    res := res || jsonb_build_object('t', 'set_notify keeps known boolean keys only', 'ok', v = '{"teasers": false, "photos": false}'::jsonb, 'got', v);
    v := get_state(tb1)::jsonb -> 'me' -> 'notify';
    res := res || jsonb_build_object('t', 'get_state returns my notification choices', 'ok', v = '{"teasers": false, "photos": false}'::jsonb);

    begin perform save_device(tg1, 'not-a-token'); e := 'none'; exception when others then e := sqlerrm; end;
    res := res || jsonb_build_object('t', 'save_device rejects junk', 'ok', e = 'bad_input');
    perform save_device(tg1, upper(dev));
    select count(*) into n1 from push_subs where endpoint = 'apns:' || dev and member_id = g1;
    res := res || jsonb_build_object('t', 'save_device stores the device (lowercase)', 'ok', n1 = 1);
    perform remove_device(tg1, dev);
    select count(*) into n1 from push_subs where member_id = g1 and (p256dh <> '' or endpoint like 'apns:%');
    res := res || jsonb_build_object('t', 'remove_device turns it off', 'ok', n1 = 0);

    raise exception 'selftest_rollback';
  exception when others then
    if sqlerrm <> 'selftest_rollback' then res := res || jsonb_build_object('t', 'crashed', 'ok', false, 'err', sqlerrm); end if;
  end;
  return jsonb_build_object('passed', (select count(*) from jsonb_array_elements(res) x where x->>'ok' = 'true'),
                            'failed', (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(res) x where x->>'ok' = 'false'),
                            'log', (select x->'rows' from jsonb_array_elements(res) x where x->>'t' = 'log'));
end $$;
revoke all on function _selftest_notify() from public, anon, authenticated;;
