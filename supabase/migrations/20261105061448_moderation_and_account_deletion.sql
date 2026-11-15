alter table public.photos add column if not exists hidden_at timestamptz, add column if not exists hidden_by uuid,
  add column if not exists purge_at timestamptz, add column if not exists purged_at timestamptz;
alter table public.teasers add column if not exists hidden_at timestamptz;
alter table public.members add column if not exists deleted_at timestamptz;

create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(), wedding_id uuid not null, reporter_id uuid not null,
  kind text not null, target_id uuid, target_member uuid, reason text, created_at timestamptz not null default now(), handled_at timestamptz);
alter table public.reports enable row level security;
create table if not exists public.blocks (
  wedding_id uuid not null, blocker_id uuid not null, blocked_id uuid not null,
  created_at timestamptz not null default now(), active boolean not null default true, primary key (blocker_id, blocked_id));
alter table public.blocks enable row level security;

-- report a photo, a teaser or a person; the couple/organiser takes content down at once, otherwise two reporters do
create or replace function public.report_content(p_token uuid, p_kind text, p_id uuid, p_reason text, p_block boolean default false)
returns json language plpgsql security definer set search_path to 'public' as $$
declare m members; tm uuid; n int := 0; moder boolean; hid boolean := false;
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
  update weddings set version = version + 1 where id = m.wedding_id;
  return json_build_object('ok', true, 'hidden', hid);
end $$;

create or replace function public.block_member(p_token uuid, p_member uuid, p_on boolean)
returns json language plpgsql security definer set search_path to 'public' as $$
declare m members;
begin
  m := _member(p_token);
  if p_member = m.id or not exists (select 1 from members where id = p_member and wedding_id = m.wedding_id) then
    raise exception 'not_found' using errcode = 'P0001'; end if;
  insert into blocks (wedding_id, blocker_id, blocked_id, active) values (m.wedding_id, m.id, p_member, p_on)
  on conflict (blocker_id, blocked_id) do update set active = p_on, created_at = now();
  update weddings set version = version + 1 where id = m.wedding_id;
  return json_build_object('ok', true);
end $$;

-- deleting your account: your name, devices and reactions go at once; your uploads too if you choose
create or replace function public.delete_account(p_token uuid, p_content boolean)
returns json language plpgsql security definer set search_path to 'public' as $$
declare m members; k int := 0;
begin
  m := _member(p_token);
  update members set deleted_at = now(), name = 'חשבון שנמחק', token = gen_random_uuid() where id = m.id;
  update push_subs set endpoint = 'gone:' || gen_random_uuid()::text, p256dh = '', auth = '' where member_id = m.id;
  update hearts set active = false where member_id = m.id;
  update reacts set emoji = '' where member_id = m.id;
  update letters set deleted = true, body = '' where member_id = m.id;
  update teasers set hidden_at = coalesce(hidden_at, now()), body = '' where member_id = m.id;
  update tasks set who = null where who = m.id;
  update blocks set active = false where blocker_id = m.id or blocked_id = m.id;
  if p_content then
    update photos set deleted_at = coalesce(deleted_at, now()), purge_at = now() + interval '1 day', caption = null
     where member_id = m.id and purged_at is null;
    get diagnostics k = row_count;
  end if;
  update weddings set version = version + 1 where id = m.wedding_id;
  return json_build_object('ok', true, 'files', k);
end $$;

revoke all on function public.report_content(uuid, text, uuid, text, boolean) from public;
revoke all on function public.block_member(uuid, uuid, boolean) from public;
revoke all on function public.delete_account(uuid, boolean) from public;
grant execute on function public.report_content(uuid, text, uuid, text, boolean) to anon, authenticated;
grant execute on function public.block_member(uuid, uuid, boolean) to anon, authenticated;
grant execute on function public.delete_account(uuid, boolean) to anon, authenticated;

-- a deleted account can never sign in again
create or replace function public._member(p_token uuid) returns members
language plpgsql stable security definer set search_path to 'public' as $function$
declare m members;
begin
  select * into m from members where token = p_token and deleted_at is null;
  if not found then raise exception 'bad_token' using errcode = 'P0001'; end if;
  return m;
end $function$;

-- what each person receives now leaves out hidden content, what they reported, people they blocked and deleted accounts
do $$
declare d text; c int;
begin
  d := pg_get_functiondef('public.get_state(uuid)'::regprocedure);
  c := (select count(*) from regexp_matches(d, 'where p\.wedding_id = w\.id and p\.deleted_at is null(\s+)and \(p\.team = m\.team', 'g'));
  if c <> 1 then raise exception 'photos filter not found (%)', c; end if;
  d := regexp_replace(d, 'where p\.wedding_id = w\.id and p\.deleted_at is null(\s+)and \(p\.team = m\.team',
    'where p.wedding_id = w.id and p.deleted_at is null and p.hidden_at is null\1and not exists (select 1 from blocks b where b.blocker_id = m.id and b.blocked_id = p.member_id and b.active)\1and not exists (select 1 from reports r where r.reporter_id = m.id and r.target_id = p.id)\1and (p.team = m.team');
  if position($x$from teasers t where t.wedding_id = w.id), '[]'::json) end,$x$ in d) = 0 then raise exception 'teasers filter not found'; end if;
  d := replace(d, $x$from teasers t where t.wedding_id = w.id), '[]'::json) end,$x$,
    $x$from teasers t where t.wedding_id = w.id and t.hidden_at is null and not exists (select 1 from blocks b where b.blocker_id = m.id and b.blocked_id = t.member_id and b.active) and not exists (select 1 from reports r where r.reporter_id = m.id and r.target_id = t.id)), '[]'::json) end,$x$);
  if position($x$from members x where x.wedding_id = w.id and (not g or x.team <> 'guest' or x.id = m.id)$x$ in d) = 0 then raise exception 'members filter not found'; end if;
  d := replace(d, $x$from members x where x.wedding_id = w.id and (not g or x.team <> 'guest' or x.id = m.id)$x$,
    $x$from members x where x.wedding_id = w.id and x.deleted_at is null and (not g or x.team <> 'guest' or x.id = m.id)$x$);
  if position($x$'letters', case when g$x$ in d) = 0 then raise exception 'letters key not found'; end if;
  d := replace(d, $x$'letters', case when g$x$,
    $x$'blocked', coalesce((select json_agg(json_build_object('id', b.blocked_id, 'name', x.name)) from blocks b join members x on x.id = b.blocked_id where b.blocker_id = m.id and b.active), '[]'::json),
    'letters', case when g$x$);
  execute d;
end $$;

insert into public.app_secrets(name, value) values ('purge_key', encode(extensions.gen_random_bytes(24), 'hex')) on conflict (name) do nothing;;
