create table if not exists rate_hits (kind text not null, ip text not null, at timestamptz not null default now());
create index if not exists rate_hits_kind_ip_at on rate_hits (kind, ip, at);
alter table rate_hits enable row level security;
revoke all on table rate_hits from anon, authenticated;

create or replace function _client_ip() returns text language plpgsql stable set search_path = public as $$
declare h json;
begin
  begin h := nullif(current_setting('request.headers', true), '')::json; exception when others then h := null; end;
  return coalesce(nullif(trim(split_part(coalesce(h->>'cf-connecting-ip', h->>'x-real-ip', h->>'x-forwarded-for', ''), ',', 1)), ''), 'unknown');
end $$;

create or replace function _rate_ok(p_kind text, p_per_ip int, p_window interval, p_global int) returns boolean
language sql stable security definer set search_path = public as $$
  select (select count(*) from rate_hits where kind = p_kind and ip = _client_ip() and at > now() - p_window) < p_per_ip
     and (select count(*) from rate_hits where kind = p_kind and at > now() - p_window) < p_global
$$;
revoke all on function _client_ip(), _rate_ok(text, int, interval, int) from public, anon, authenticated;

create or replace function peek_code(p_code text) returns json language plpgsql volatile security definer set search_path = public as $$
declare c text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')); w weddings;
begin
  if not _rate_ok('code', 20, interval '15 minutes', 600) then raise exception 'too_many' using errcode = 'P0001'; end if;
  select * into w from weddings where code_groom = c or code_bride = c or code_guest = c;
  if not found then insert into rate_hits (kind, ip) values ('code', _client_ip()); return null; end if;
  return json_build_object('team', case when w.code_groom = c then 'groom' when w.code_bride = c then 'bride' else 'guest' end,
                           'groom', w.groom, 'bride', w.bride, 'date', w.wdate,
                           'cover', w.cover_thumb, 'share', w.share_path);
end $$;

create or replace function join_wedding(p_code text, p_name text, p_role text) returns json language plpgsql security definer set search_path = public as $$
declare c text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')); w weddings; m members; t text; r text;
begin
  if not _rate_ok('code', 20, interval '15 minutes', 600) then raise exception 'too_many' using errcode = 'P0001'; end if;
  select * into w from weddings where code_groom = c or code_bride = c or code_guest = c;
  if not found then insert into rate_hits (kind, ip) values ('code', _client_ip()); return json_build_object('error', 'bad_code'); end if;
  t := case when w.code_groom = c then 'groom' when w.code_bride = c then 'bride' else 'guest' end;
  if coalesce(trim(p_name), '') = '' then raise exception 'missing_name'; end if;
  r := case when t = 'guest' then 'guest' when p_role = 'couple' then 'couple' else 'escort' end;
  if r = 'couple' and exists (select 1 from members x where x.wedding_id = w.id and x.team = t and x.role = 'couple' and x.deleted_at is null) then
    raise exception 'couple_taken' using errcode = 'P0001';
  end if;
  insert into members (wedding_id, team, role, name) values (w.id, t, r, left(trim(p_name), 30)) returning * into m;
  return json_build_object('token', m.token, 'team', t);
end $$;

create or replace function create_wedding_v2(p_groom text, p_bride text, p_date date, p_time text, p_reveal_at timestamp with time zone, p_venue text, p_venue_city text, p_venue_custom boolean, p_team text, p_role text, p_name text, p_template boolean)
returns json language plpgsql security definer set search_path = public as $$
declare w weddings; m members; cg text; cb text;
begin
  if not _rate_ok('create', 6, interval '1 day', 300) then raise exception 'too_many' using errcode = 'P0001'; end if;
  if coalesce(trim(p_groom), '') = '' or coalesce(trim(p_bride), '') = '' then raise exception 'missing_names'; end if;
  if p_team not in ('groom','bride') then raise exception 'bad_team'; end if;
  if p_time !~ '^\d\d:\d\d$' then raise exception 'bad_time'; end if;
  cg := _code();
  loop cb := _code(); exit when cb <> cg; end loop;
  insert into weddings (groom, bride, wdate, reveal_at, venue, venue_city, code_groom, code_bride)
  values (left(trim(p_groom), 40), left(trim(p_bride), 40), p_date, p_reveal_at, left(coalesce(trim(p_venue), ''), 80), left(coalesce(trim(p_venue_city), ''), 40), cg, cb)
  returning * into w;
  insert into members (wedding_id, team, role, name)
  values (w.id, p_team, case when p_role = 'couple' then 'couple' else 'escort' end, left(coalesce(nullif(trim(p_name), ''), 'מארגן/ת'), 30))
  returning * into m;
  if p_venue_custom and coalesce(trim(p_venue), '') <> '' then
    insert into venues_custom (name, city, wedding_id, hidden) values (left(trim(p_venue), 80), left(coalesce(trim(p_venue_city), ''), 40), w.id, true)
    on conflict do nothing;
  end if;
  if p_template then perform _template2(w.id, p_time, p_venue); end if;
  insert into rate_hits (kind, ip) values ('create', _client_ip());
  return json_build_object('token', m.token, 'team', m.team);
end $$;

create or replace function update_me(p_token uuid, p_name text, p_role text) returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  if p_role = 'couple' and m.role = 'escort'
     and exists (select 1 from members x where x.wedding_id = m.wedding_id and x.team = m.team and x.role = 'couple' and x.deleted_at is null and x.id <> m.id) then
    raise exception 'couple_taken' using errcode = 'P0001';
  end if;
  update members set name = coalesce(nullif(left(trim(p_name), 30), ''), name),
                     role = case when m.role = 'guest' then 'guest' when p_role in ('escort', 'couple') then p_role else role end
   where id = m.id;
end $$;;
