create or replace function _want(n jsonb, cat text) returns boolean language sql immutable set search_path = public as $$
  select cat is null or coalesce(n->>cat, 'true') <> 'false'
$$;

create or replace function _recips(p_wedding uuid, p_teams text[], p_roles text[], p_cat text, p_author uuid default null) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(m.id), '{}') from members m
   where m.wedding_id = p_wedding and m.deleted_at is null and m.team = any (p_teams) and m.role = any (p_roles)
     and _want(m.notify, p_cat)
     and (p_author is null or (m.id <> p_author and not exists (select 1 from blocks b where b.blocker_id = m.id and b.blocked_id = p_author and b.active)))
$$;

create or replace function _member(p_token uuid) returns members language plpgsql stable security definer set search_path to 'public' as $$
declare m members;
begin
  select * into m from members where token = p_token and deleted_at is null;
  if not found then raise exception 'bad_token' using errcode = 'P0001'; end if;
  perform set_config('app.actor', m.id::text, true);
  return m;
end $$;

create or replace function _notify(p_members uuid[], p_title text, p_body text, p_url text, p_tag text) returns void
language plpgsql security definer set search_path to 'public', 'extensions' as $$
begin
  if p_members is null or cardinality(p_members) = 0 then return; end if;
  insert into notify_log (members, title, body, url, tag) values (p_members, p_title, p_body, p_url, p_tag);
  if not exists (select 1 from push_subs where member_id = any (p_members) and (p256dh <> '' or endpoint like 'apns:%')) then return; end if;
  perform net.http_post(
    url := 'https://yexzrxygjzzgsweiaqcm.supabase.co/functions/v1/push-send',
    body := jsonb_build_object('key', (select value from app_secrets where name = 'push_key'), 'members', to_jsonb(p_members),
                               'title', p_title, 'body', p_body, 'url', p_url, 'tag', p_tag),
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlleHpyeHlnanp6Z3N3ZWlhcWNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTM2ODk0NzksImV4cCI6MjEwOTI2NTQ3OX0.oxbOFBA4XqjFJ4-WsBSNyh-60_4Rm8Me8CVxzpPKrJY'),
    timeout_milliseconds := 20000);
exception when others then
  raise warning 'notify failed: %', sqlerrm;
end $$;;
