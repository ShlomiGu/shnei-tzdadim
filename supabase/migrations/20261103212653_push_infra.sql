insert into public.app_secrets(name,value) values
  ('vapid_public','BMm4tqW2sO8vdjX9e2ZcNgbQzBuUQ5YTXUH2e7MpCeCn2DCmlm5ixTaFTgxGDphehd4QqLjXJ7jYvHBV7tG7UWc'),
  ('vapid_private','_CBPCTK5cDnzXhouArGLLZY5AzdA3s1EuQrsOrCG1i0'),
  ('vapid_subject','https://shlomigu.github.io/shnei-tzdadim/'),
  ('push_key', encode(extensions.gen_random_bytes(24),'hex'))
on conflict (name) do nothing;

create table public.push_subs (
  endpoint   text primary key,
  member_id  uuid not null references public.members on delete cascade,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
create index push_subs_member on public.push_subs (member_id);
alter table public.push_subs enable row level security;
revoke all on public.push_subs from anon, authenticated;

alter table public.weddings add column reveal_notified boolean not null default false;
update public.weddings set reveal_notified = true where (revealed_at is not null and revealed_at <= now()) or now() >= reveal_at;
alter table public.letters add column open_notified boolean not null default false;
update public.letters set open_notified = true where open_at <= now();

create or replace function public.save_push(p_token uuid, p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then raise exception 'bad_input'; end if;
  insert into push_subs (endpoint, member_id, p256dh, auth) values (p_endpoint, m.id, left(p_p256dh, 200), left(p_auth, 100))
  on conflict (endpoint) do update set member_id = excluded.member_id, p256dh = excluded.p256dh, auth = excluded.auth, created_at = now();
end $$;

create or replace function public.remove_push(p_token uuid, p_endpoint text)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  update push_subs set p256dh = '', auth = '' where endpoint = p_endpoint and member_id = m.id;
end $$;

-- queue a notification to a set of members through the push-send edge function
create or replace function public._notify(p_members uuid[], p_title text, p_body text, p_url text, p_tag text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if p_members is null or cardinality(p_members) = 0 then return; end if;
  if not exists (select 1 from push_subs where member_id = any (p_members) and p256dh <> '') then return; end if;
  perform net.http_post(
    url := 'https://yexzrxygjzzgsweiaqcm.supabase.co/functions/v1/push-send',
    body := jsonb_build_object('key', (select value from app_secrets where name = 'push_key'), 'members', to_jsonb(p_members),
                               'title', p_title, 'body', p_body, 'url', p_url, 'tag', p_tag),
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlleHpyeHlnanp6Z3N3ZWlhcWNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTM2ODk0NzksImV4cCI6MjEwOTI2NTQ3OX0.oxbOFBA4XqjFJ4-WsBSNyh-60_4Rm8Me8CVxzpPKrJY'),
    timeout_milliseconds := 20000);
exception when others then
  -- a notification must never break the action that triggered it
  raise warning 'notify failed: %', sqlerrm;
end $$;
revoke execute on function public._notify(uuid[], text, text, text, text) from public, anon, authenticated;

create or replace function public._on_teaser() returns trigger
language plpgsql security definer set search_path = public as $$
declare w weddings; other text := case when new.team = 'groom' then 'bride' else 'groom' end;
begin
  select * into w from weddings where id = new.wedding_id;
  perform _notify(array(select id from members where wedding_id = new.wedding_id and team = other),
    'טיזר חדש מ' || case when new.team = 'groom' then 'חבורת החתן' else 'חבורת הכלה' end,
    coalesce(nullif(new.body, ''), case when cardinality(new.photo_ids) > 0 then 'תמונה מטושטשת מחכה לכם' else 'פתחו לראות' end),
    '#teasers', 'teaser');
  return null;
end $$;
create trigger notify_teaser after insert on public.teasers for each row execute function public._on_teaser();

create or replace function public._on_early_photo() returns trigger
language plpgsql security definer set search_path = public as $$
declare w weddings; other text := case when new.team = 'groom' then 'bride' else 'groom' end;
begin
  if not new.share_escorts or new.deleted_at is not null or (tg_op = 'UPDATE' and old.share_escorts) then return null; end if;
  select * into w from weddings where id = new.wedding_id;
  if _revealed(w) then return null; end if;
  perform _notify(array(select id from members where wedding_id = new.wedding_id and team = other and role = 'escort'),
    'נשלח אליכם משהו מהצד של ' || case when new.team = 'groom' then w.groom else w.bride end,
    case when new.kind = 'video' then 'סרטון חדש, רק למלווים' else 'תמונה חדשה, רק למלווים' end || '. ' ||
      case when new.team = 'groom' then w.bride else w.groom end || ' לא רואה את זה.',
    '#album', 'early');
  return null;
end $$;
create trigger notify_early after insert or update of share_escorts on public.photos for each row execute function public._on_early_photo();

-- time-based: the reveal and sealed letters
create or replace function public._notify_due() returns void
language plpgsql security definer set search_path = public as $$
declare w record; l record;
begin
  for w in select * from weddings where not reveal_notified and ((revealed_at is not null and revealed_at <= now()) or now() >= reveal_at) for update skip locked loop
    update weddings set reveal_notified = true where id = w.id;
    perform _notify(array(select id from members where wedding_id = w.id),
      'מזל טוב! ' || w.groom || ' ו' || w.bride, 'האלבומים של שני הצדדים נפתחו. בואו לראות הכל', '#album', 'reveal');
  end loop;
  for l in select l.*, w.groom, w.bride from letters l join weddings w on w.id = l.wedding_id
           where not l.open_notified and not l.deleted and l.open_at <= now() for update of l skip locked loop
    update letters set open_notified = true where id = l.id;
    perform _notify(array(select id from members where wedding_id = l.wedding_id and role = 'couple' and team <> l.from_team),
      'מכתב מ' || case when l.from_team = 'groom' then l.groom else l.bride end, 'המכתב החתום נפתח עכשיו', '#teasers', 'letter');
  end loop;
end $$;
revoke execute on function public._notify_due() from public, anon, authenticated;
revoke execute on function public._on_teaser() from public, anon, authenticated;
revoke execute on function public._on_early_photo() from public, anon, authenticated;

-- a manual reveal notifies right away instead of waiting for the next minute
create or replace function public._on_reveal_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.revealed_at is not null and (old.revealed_at is null) then perform _notify_due(); end if;
  if new.revealed_at is null and old.revealed_at is not null and now() < new.reveal_at then
    update weddings set reveal_notified = false where id = new.id and reveal_notified;
  end if;
  return null;
end $$;
create trigger notify_reveal after update of revealed_at on public.weddings for each row execute function public._on_reveal_change();
revoke execute on function public._on_reveal_change() from public, anon, authenticated;

create extension if not exists pg_cron;
select cron.schedule('shnei-tzdadim-notify', '* * * * *', 'select public._notify_due()');;
