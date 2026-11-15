alter table public.weddings
  add column if not exists cover_path text,
  add column if not exists cover_thumb text,
  add column if not exists share_path text,
  add column if not exists cover_at timestamptz,
  add column if not exists cover_photo uuid;

-- the couple, or whoever opened the wedding, may set the couple photo
create or replace function public._can_cover(m public.members) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select m.role = 'couple'
      or m.id = (select x.id from members x where x.wedding_id = m.wedding_id order by x.created_at, x.id limit 1);
$$;

create or replace function public.set_cover(p_token uuid, p_path text, p_thumb text, p_share text, p_photo uuid default null)
returns json language plpgsql security definer set search_path to 'public' as $$
declare m members; re text; ph photos;
begin
  m := _member_staff(p_token);
  if not _can_cover(m) then raise exception 'not_allowed' using errcode = 'P0001'; end if;
  re := '^' || m.wedding_id::text || '/[A-Za-z0-9_-]+\.(jpg|webp)$';
  if p_path is null then
    update weddings set cover_path = null, cover_thumb = null, share_path = null, cover_at = now(), cover_photo = null, version = version + 1
     where id = m.wedding_id;
    return json_build_object('ok', true);
  end if;
  if p_path !~ re or (p_thumb is not null and p_thumb !~ re) or (p_share is not null and p_share !~ re) then
    raise exception 'bad_path' using errcode = 'P0001';
  end if;
  if p_photo is not null then
    select * into ph from photos where id = p_photo and wedding_id = m.wedding_id and deleted_at is null;
    if not found or ph.kind <> 'image' or ph.vis = 'secret' or ph.path <> p_path then raise exception 'bad_photo' using errcode = 'P0001'; end if;
  elsif exists (select 1 from photos where wedding_id = m.wedding_id and path = p_path and vis = 'secret') then
    raise exception 'bad_photo' using errcode = 'P0001';
  end if;
  update weddings set cover_path = p_path, cover_thumb = coalesce(p_thumb, p_path), share_path = p_share,
         cover_at = now(), cover_photo = p_photo, version = version + 1
   where id = m.wedding_id;
  return json_build_object('ok', true);
end $$;
revoke all on function public.set_cover(uuid, text, text, text, uuid) from public;
grant execute on function public.set_cover(uuid, text, text, text, uuid) to anon, authenticated;
revoke all on function public._can_cover(public.members) from public, anon, authenticated;

create or replace function public.peek_code(p_code text)
returns json language plpgsql stable security definer set search_path to 'public' as $$
declare c text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')); w weddings;
begin
  select * into w from weddings where code_groom = c or code_bride = c or code_guest = c;
  if not found then return null; end if;
  return json_build_object('team', case when w.code_groom = c then 'groom' when w.code_bride = c then 'bride' else 'guest' end,
                           'groom', w.groom, 'bride', w.bride, 'date', w.wdate,
                           'cover', w.cover_thumb, 'share', w.share_path);
end $$;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.get_state(uuid)'::regprocedure);
  if position($x$'venue_city', w.venue_city,$x$ in d) = 0 or position($x$'role', m.role, 'name', m.name)$x$ in d) = 0 then
    raise exception 'get_state shape changed';
  end if;
  d := replace(d, $x$'venue_city', w.venue_city,$x$,
               $x$'venue_city', w.venue_city, 'cover', w.cover_path, 'cover_thumb', w.cover_thumb, 'cover_at', w.cover_at, 'cover_photo', w.cover_photo,$x$);
  d := replace(d, $x$'role', m.role, 'name', m.name)$x$, $x$'role', m.role, 'name', m.name, 'can_cover', _can_cover(m))$x$);
  execute d;
end $$;;
