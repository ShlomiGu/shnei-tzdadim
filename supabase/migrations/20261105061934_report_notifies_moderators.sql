create or replace function public.report_content(p_token uuid, p_kind text, p_id uuid, p_reason text, p_block boolean default false)
returns json language plpgsql security definer set search_path to 'public' as $$
declare m members; tm uuid; n int := 0; moder boolean; hid boolean := false; mods uuid[];
begin
  m := _member(p_token);
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
    select count(distinct reporter_id) into n from reports where target_id = p_id and kind = p_kind;
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
  -- the couple and the organiser hear about it at once, so they can take it down for everyone
  if not hid then
    select array_agg(x.id) into mods from members x where x.wedding_id = m.wedding_id and x.deleted_at is null and x.id <> m.id and x.id <> tm and _can_cover(x);
    perform _notify(mods, 'דיווח על תוכן בחתונה', case when p_kind = 'teaser' then 'מישהו דיווח על טיזר. פתחו כדי לבדוק' else 'מישהו דיווח על תמונה. פתחו את האלבום כדי לבדוק ולהסיר אם צריך' end, '#album', 'report');
  end if;
  update weddings set version = version + 1 where id = m.wedding_id;
  return json_build_object('ok', true, 'hidden', hid);
end $$;;
