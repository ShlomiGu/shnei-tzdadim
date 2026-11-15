create or replace function _on_teaser() returns trigger language plpgsql security definer set search_path to 'public' as $$
declare other text := case when new.team = 'groom' then 'bride' else 'groom' end;
begin
  begin
    if new.team = 'guest' or new.hidden_at is not null then return null; end if;
    perform _notify(_recips(new.wedding_id, array[other], '{couple,escort}', 'teasers', new.member_id),
      'טיזר חדש מ' || case when new.team = 'groom' then 'חבורת החתן' else 'חבורת הכלה' end,
      coalesce(nullif(new.body, ''), case when cardinality(new.photo_ids) > 0 then 'תמונה מטושטשת מחכה לכם' else 'פתחו לראות' end),
      '#teasers', 'teaser');
  exception when others then raise warning 'teaser notify failed: %', sqlerrm;
  end;
  return null;
end $$;

create or replace function _on_early_photo() returns trigger language plpgsql security definer set search_path to 'public' as $$
declare wd weddings; other text := case when new.team = 'groom' then 'bride' else 'groom' end;
begin
  begin
    if not new.share_escorts or new.deleted_at is not null or new.hidden_at is not null or new.team = 'guest' or (tg_op = 'UPDATE' and old.share_escorts) then return null; end if;
    select * into wd from weddings where id = new.wedding_id;
    if _revealed(wd) then return null; end if;
    perform _notify(_recips(new.wedding_id, array[other], '{escort}', 'teasers', new.member_id),
      'נשלח אליכם משהו מהצד של ' || case when new.team = 'groom' then wd.groom else wd.bride end,
      case when new.kind = 'video' then 'סרטון חדש, רק למלווים' else 'תמונה חדשה, רק למלווים' end || '. ' ||
        case when new.team = 'groom' then wd.bride else wd.groom end || ' לא רואה את זה.',
      '#album', 'early');
  exception when others then raise warning 'early notify failed: %', sqlerrm;
  end;
  return null;
end $$;

create or replace function _notify_due() returns void language plpgsql security definer set search_path to 'public' as $$
declare wr record; lr record;
begin
  for wr in select x.* from weddings x where not x.reveal_notified and ((x.revealed_at is not null and x.revealed_at <= now()) or now() >= x.reveal_at) for update skip locked loop
    update weddings set reveal_notified = true where id = wr.id;
    perform _notify(_recips(wr.id, '{groom,bride,guest}', '{couple,escort,guest}', null),
      'מזל טוב! ' || wr.groom || ' ו' || wr.bride, 'האלבומים של שני הצדדים נפתחו. בואו לראות הכל', '#album', 'reveal');
  end loop;
  for lr in select le.id, le.wedding_id, le.from_team, le.member_id, wd.groom, wd.bride from letters le join weddings wd on wd.id = le.wedding_id
           where not le.open_notified and not le.deleted and le.open_at <= now() for update of le skip locked loop
    update letters set open_notified = true where id = lr.id;
    perform _notify(_recips(lr.wedding_id, array[case when lr.from_team = 'groom' then 'bride' else 'groom' end], '{couple}', 'teasers'),
      'מכתב מ' || case when lr.from_team = 'groom' then lr.groom else lr.bride end, 'המכתב החתום נפתח עכשיו', '#teasers', 'letter');
  end loop;
exception when others then
  raise warning 'notify_due failed: %', sqlerrm;
end $$;

create or replace function _on_task_who() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.who is not null and new.who::text = coalesce(current_setting('app.actor', true), '') then
    insert into notified (kind, ref, val) values ('task', new.id, new.who::text) on conflict (kind, ref) do update set val = excluded.val, at = now();
  end if;
  return null;
exception when others then return null;
end $$;
create or replace trigger notify_task after insert or update of who on tasks for each row execute function _on_task_who();

create or replace function save_device(p_token uuid, p_device text) returns void language plpgsql security definer set search_path to 'public' as $$
declare m members;
begin
  m := _member(p_token);
  if coalesce(p_device, '') !~ '^[0-9a-fA-F]{32,200}$' then raise exception 'bad_input'; end if;
  insert into push_subs (endpoint, member_id, p256dh, auth) values ('apns:' || lower(p_device), m.id, '', '')
  on conflict (endpoint) do update set member_id = excluded.member_id, p256dh = '', auth = '', created_at = now();
end $$;

create or replace function set_notify(p_token uuid, p_prefs jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare m members; v jsonb;
begin
  m := _member(p_token);
  select coalesce(jsonb_object_agg(k, p_prefs->k), '{}'::jsonb) into v
    from unnest(array['teasers', 'photos', 'schedule', 'tasks', 'status']) k where jsonb_typeof(p_prefs->k) = 'boolean';
  update members set notify = notify || v where id = m.id returning notify into v;
  return v;
end $$;;
