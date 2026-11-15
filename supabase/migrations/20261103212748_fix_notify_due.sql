create or replace function public._notify_due() returns void
language plpgsql security definer set search_path = public as $$
declare wr record; lr record;
begin
  for wr in select x.* from weddings x where not x.reveal_notified and ((x.revealed_at is not null and x.revealed_at <= now()) or now() >= x.reveal_at) for update skip locked loop
    update weddings set reveal_notified = true where id = wr.id;
    perform _notify(array(select m.id from members m where m.wedding_id = wr.id),
      'מזל טוב! ' || wr.groom || ' ו' || wr.bride, 'האלבומים של שני הצדדים נפתחו. בואו לראות הכל', '#album', 'reveal');
  end loop;
  for lr in select le.id, le.wedding_id, le.from_team, wd.groom, wd.bride from letters le join weddings wd on wd.id = le.wedding_id
           where not le.open_notified and not le.deleted and le.open_at <= now() for update of le skip locked loop
    update letters set open_notified = true where id = lr.id;
    perform _notify(array(select m.id from members m where m.wedding_id = lr.wedding_id and m.role = 'couple' and m.team <> lr.from_team),
      'מכתב מ' || case when lr.from_team = 'groom' then lr.groom else lr.bride end, 'המכתב החתום נפתח עכשיו', '#teasers', 'letter');
  end loop;
exception when others then
  raise warning 'notify_due failed: %', sqlerrm;
end $$;
revoke execute on function public._notify_due() from public, anon, authenticated;

-- a failing notification must never block the reveal itself
create or replace function public._on_reveal_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  begin
    if new.revealed_at is not null and old.revealed_at is null then perform _notify_due(); end if;
    if new.revealed_at is null and old.revealed_at is not null and now() < new.reveal_at then
      update weddings set reveal_notified = false where id = new.id and reveal_notified;
    end if;
  exception when others then raise warning 'reveal notify failed: %', sqlerrm;
  end;
  return null;
end $$;

create or replace function public._on_teaser() returns trigger
language plpgsql security definer set search_path = public as $$
declare other text := case when new.team = 'groom' then 'bride' else 'groom' end;
begin
  begin
    perform _notify(array(select m.id from members m where m.wedding_id = new.wedding_id and m.team = other),
      'טיזר חדש מ' || case when new.team = 'groom' then 'חבורת החתן' else 'חבורת הכלה' end,
      coalesce(nullif(new.body, ''), case when cardinality(new.photo_ids) > 0 then 'תמונה מטושטשת מחכה לכם' else 'פתחו לראות' end),
      '#teasers', 'teaser');
  exception when others then raise warning 'teaser notify failed: %', sqlerrm;
  end;
  return null;
end $$;

create or replace function public._on_early_photo() returns trigger
language plpgsql security definer set search_path = public as $$
declare wd weddings; other text := case when new.team = 'groom' then 'bride' else 'groom' end;
begin
  begin
    if not new.share_escorts or new.deleted_at is not null or new.team = 'guest' or (tg_op = 'UPDATE' and old.share_escorts) then return null; end if;
    select * into wd from weddings where id = new.wedding_id;
    if _revealed(wd) then return null; end if;
    perform _notify(array(select m.id from members m where m.wedding_id = new.wedding_id and m.team = other and m.role = 'escort'),
      'נשלח אליכם משהו מהצד של ' || case when new.team = 'groom' then wd.groom else wd.bride end,
      case when new.kind = 'video' then 'סרטון חדש, רק למלווים' else 'תמונה חדשה, רק למלווים' end || '. ' ||
        case when new.team = 'groom' then wd.bride else wd.groom end || ' לא רואה את זה.',
      '#album', 'early');
  exception when others then raise warning 'early notify failed: %', sqlerrm;
  end;
  return null;
end $$;;
