create or replace function _selftest_security() returns jsonb language plpgsql security definer set search_path = public as $$
declare
  res jsonb := '[]'::jsonb; w weddings; w2 uuid; org uuid; e1 uuid; e2 uuid; b1 uuid;
  t_org uuid := gen_random_uuid(); t_e1 uuid := gen_random_uuid(); t_e2 uuid := gen_random_uuid(); t_b1 uuid := gen_random_uuid();
  e text; pid uuid; pid2 uuid; j json; n int; v jsonb; sid uuid; i int; p1 text; p2 text;
  procedure_ok boolean;
begin
  begin
    insert into weddings (groom, bride, wdate, reveal_at, code_groom, code_bride)
    values ('אבי', 'רוני', current_date + 10, now() + interval '10 days', 'SECG' || upper(substr(md5(random()::text), 1, 2)), 'SECB' || upper(substr(md5(random()::text), 1, 2))) returning * into w;
    insert into members (wedding_id, team, role, name, token, created_at) values (w.id, 'groom', 'escort', 'מארגן', t_org, now() - interval '2 hours') returning id into org;
    insert into members (wedding_id, team, role, name, token, created_at) values (w.id, 'groom', 'escort', 'אחד', t_e1, now() - interval '1 hour') returning id into e1;
    insert into members (wedding_id, team, role, name, token) values (w.id, 'groom', 'escort', 'שניים', t_e2) returning id into e2;
    insert into members (wedding_id, team, role, name, token) values (w.id, 'bride', 'escort', 'כלה-מלווה', t_b1) returning id into b1;
    p1 := w.id || '/' || replace(gen_random_uuid()::text, '-', '') || '.jpg';
    p2 := w.id || '/' || replace(gen_random_uuid()::text, '-', '') || '_t.jpg';

    -- H1
    pid := add_media(t_e1, 'image', p1, p2, null, 10, 10, null, '', 'team', null);
    pid2 := add_media(t_e1, 'image', p1, p2, null, 10, 10, null, '', 'team', null);
    res := res || jsonb_build_object('t', 'retry of my own upload returns the same photo', 'ok', pid = pid2);
    begin perform add_media(t_e2, 'image', p1, p2, null, 10, 10, null, '', 'team', null); e := 'none'; exception when others then e := sqlerrm; end;
    res := res || jsonb_build_object('t', 'someone else cannot claim my file', 'ok', e = 'bad_path', 'got', e);
    begin perform add_media(t_e2, 'image', w.id || '/' || md5('x') || '.jpg', p1, null, 10, 10, null, '', 'team', null); e := 'none'; exception when others then e := sqlerrm; end;
    res := res || jsonb_build_object('t', 'nor use it as a thumbnail', 'ok', e = 'bad_path');
    begin perform add_media(t_e2, 'image', w.id || '/../x.jpg', w.id || '/abcdefgh_t.jpg', null, 10, 10, null, '', 'team', null); e := 'none'; exception when others then e := sqlerrm; end;
    res := res || jsonb_build_object('t', 'odd paths are refused', 'ok', e = 'bad_path');
    begin perform add_media(t_e2, 'image', w.id || '/cover-' || md5('y') || '.jpg', w.id || '/cover-' || md5('y') || '-t.jpg', null, 10, 10, null, '', 'team', null); e := 'none'; exception when others then e := sqlerrm; end;
    res := res || jsonb_build_object('t', 'couple-photo files are refused', 'ok', e = 'bad_path');

    -- H2
    j := join_wedding(w.code_groom, 'החתן', 'couple');
    res := res || jsonb_build_object('t', 'first groom can join as groom', 'ok', j->>'token' is not null);
    begin j := join_wedding(w.code_groom, 'עוד חתן', 'couple'); e := 'none'; exception when others then e := sqlerrm; end;
    res := res || jsonb_build_object('t', 'a second groom is refused', 'ok', e = 'couple_taken');
    begin perform update_me(t_e1, 'אחד', 'couple'); e := 'none'; exception when others then e := sqlerrm; end;
    res := res || jsonb_build_object('t', 'an escort cannot switch to groom when there is one', 'ok', e = 'couple_taken');
    j := join_wedding(w.code_bride, 'הכלה', 'couple');
    perform update_me((j->>'token')::uuid, 'הכלה', 'escort');
    select role into e from members where token = (j->>'token')::uuid;
    res := res || jsonb_build_object('t', 'the bride can step down to escort', 'ok', e = 'escort');

    -- M1
    begin perform set_reveal(t_e1, true); e := 'none'; exception when others then e := sqlerrm; end;
    res := res || jsonb_build_object('t', 'an escort cannot reveal', 'ok', e = 'reveal_owner');
    perform set_reveal(t_org, true); perform set_reveal(t_org, false);
    res := res || jsonb_build_object('t', 'the organiser can reveal and undo', 'ok', (select revealed_at is null from weddings where id = w.id));
    begin perform update_wedding(t_e1, jsonb_build_object('reveal_at', now() + interval '1 hour')); e := 'none'; exception when others then e := sqlerrm; end;
    res := res || jsonb_build_object('t', 'an escort cannot move the reveal', 'ok', e = 'reveal_owner');
    perform update_wedding(t_e1, jsonb_build_object('venue', 'גן', 'contacts', (select jsonb_agg(jsonb_build_object('name', repeat('א', 90), 'phone', '050')) from generate_series(1, 50))));
    select jsonb_array_length(contacts), length(contacts->0->>'name') into n, i from weddings where id = w.id;
    res := res || jsonb_build_object('t', 'escort can still edit details; contacts capped at 30 short rows', 'ok', n = 30 and i = 40);

    -- L1
    sid := save_sched(t_e1, null, '12:00', 'פריט', '', '', 'bride', false, false, null);
    res := res || jsonb_build_object('t', 'an item for the other side becomes mine', 'ok', (select side from sched where id = sid) = 'groom');
    sid := save_sched(t_b1, null, '13:00', 'של הכלה', '', '', 'bride', false, false, null);
    perform delete_sched(t_e1, sid);
    res := res || jsonb_build_object('t', 'the other side cannot delete my item', 'ok', (select not deleted from sched where id = sid));

    -- M3
    insert into photos (wedding_id, team, member_id, path, thumb_path, vis, kind) values (w.id, 'groom', org, w.id || '/r1abcdefg.jpg', w.id || '/r1abcdefg_t.jpg', 'team', 'image') returning id into pid;
    perform report_content(t_e2, 'photo', pid, 'x', false);
    j := report_content((select token from members where wedding_id = w.id and name = 'החתן'), 'photo', pid, 'x', false);
    res := res || jsonb_build_object('t', 'the groom (couple) still removes at once', 'ok', (j->>'hidden')::boolean);
    insert into photos (wedding_id, team, member_id, path, thumb_path, vis, kind) values (w.id, 'groom', org, w.id || '/r2abcdefg.jpg', w.id || '/r2abcdefg_t.jpg', 'team', 'image') returning id into pid;
    perform report_content(t_e2, 'photo', pid, 'x', false);
    perform report_content(t_b1, 'photo', pid, 'x', false);
    res := res || jsonb_build_object('t', 'two brand-new accounts cannot hide a photo', 'ok', (select hidden_at is null from photos where id = pid));
    j := report_content(t_e1, 'photo', pid, 'x', false);
    insert into photos (wedding_id, team, member_id, path, thumb_path, vis, kind) values (w.id, 'groom', org, w.id || '/r3abcdefg.jpg', w.id || '/r3abcdefg_t.jpg', 'team', 'image') returning id into pid2;
    update members set created_at = now() - interval '3 hours' where id = e2;
    perform report_content(t_e1, 'photo', pid2, 'x', false);
    j := report_content(t_e2, 'photo', pid2, 'x', false);
    res := res || jsonb_build_object('t', 'two people who were there a while do hide it', 'ok', (j->>'hidden')::boolean);
    begin
      for i in 1..20 loop
        insert into photos (wedding_id, team, member_id, path, thumb_path, vis, kind) values (w.id, 'groom', org, w.id || '/s' || i || 'abcdefgh.jpg', w.id || '/s' || i || 'abcdefgh_t.jpg', 'team', 'image') returning id into pid;
        perform report_content(t_b1, 'photo', pid, 'x', false);
      end loop; e := 'none';
    exception when others then e := sqlerrm; end;
    res := res || jsonb_build_object('t', 'at most 15 reports an hour', 'ok', e = 'too_many');

    -- M6
    begin perform save_push(t_e1, 'https://evil.example.com/x', 'k', 'a'); e := 'none'; exception when others then e := sqlerrm; end;
    res := res || jsonb_build_object('t', 'push address from an unknown host is refused', 'ok', e = 'bad_input');
    for i in 1..7 loop perform save_push(t_e1, 'https://fcm.googleapis.com/fcm/send/test' || i || md5(random()::text), 'k', 'a'); end loop;
    select count(*) into n from push_subs where member_id = e1 and endpoint like 'https://%';
    res := res || jsonb_build_object('t', 'at most 5 browsers per person', 'ok', n = 5, 'got', n);

    -- M4
    v := get_state(t_e1)::jsonb;
    res := res || jsonb_build_object('t', 'escort does not get the other side code', 'ok', v->'wedding'->>'other_code' is null);

    -- H3 (partial)
    res := res || jsonb_build_object('t', 'uploads allowed into an active wedding', 'ok', wedding_upload_ok(w.id::text));
    update weddings set wdate = current_date - 61 where id = w.id;
    res := res || jsonb_build_object('t', 'not into one that ended 2 months ago', 'ok', not wedding_upload_ok(w.id::text));
    res := res || jsonb_build_object('t', 'not into a folder that is no wedding', 'ok', not wedding_upload_ok(gen_random_uuid()::text));

    -- M2
    j := join_wedding('ZZZZZZ', 'x', 'escort');
    res := res || jsonb_build_object('t', 'wrong code answers bad_code', 'ok', j->>'error' = 'bad_code');
    begin for i in 1..25 loop perform peek_code('QQQQ' || i); end loop; e := 'none'; exception when others then e := sqlerrm; end;
    res := res || jsonb_build_object('t', 'after 20 wrong codes: too_many', 'ok', e = 'too_many');
    begin perform peek_code(w.code_bride); e := 'none'; exception when others then e := sqlerrm; end;
    res := res || jsonb_build_object('t', 'and then even a right code waits', 'ok', e = 'too_many');

    raise exception 'selftest_rollback';
  exception when others then
    if sqlerrm <> 'selftest_rollback' then res := res || jsonb_build_object('t', 'crashed', 'ok', false, 'err', sqlerrm); end if;
  end;
  return jsonb_build_object('passed', (select count(*) from jsonb_array_elements(res) x where x->>'ok' = 'true'),
                            'failed', (select coalesce(jsonb_agg(x), '[]') from jsonb_array_elements(res) x where x->>'ok' = 'false'));
end $$;
revoke all on function _selftest_security() from public, anon, authenticated;;
