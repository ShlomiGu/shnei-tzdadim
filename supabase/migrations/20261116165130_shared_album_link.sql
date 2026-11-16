-- A read-only album link for family and friends who are not in the app.
-- Only the couple or whoever opened the wedding can create it, it works only after the reveal,
-- it expires, it can be revoked, and it never shows secret, deleted or hidden photos.
alter table public.weddings
  add column if not exists share_token uuid unique,
  add column if not exists share_until timestamptz;

create or replace function public.album_link(p_token uuid, p_days int) returns json
language plpgsql security definer set search_path = public as $$
declare m members; w weddings;
begin
  m := _member_staff(p_token);
  if not _can_cover(m) then raise exception 'couple_only' using errcode = 'P0001'; end if;
  if p_days is null or p_days <= 0 then
    update weddings set share_token = null, share_until = null where id = m.wedding_id returning * into w;
  else
    update weddings set share_token = coalesce(share_token, gen_random_uuid()),
                        share_until = now() + make_interval(days => least(p_days, 730))
     where id = m.wedding_id returning * into w;
  end if;
  return json_build_object('token', w.share_token, 'until', w.share_until);
end $$;
revoke execute on function public.album_link(uuid, int) from public;
grant execute on function public.album_link(uuid, int) to anon, authenticated;

-- the couple sees whether a link is on
create or replace function public.album_link_state(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare m members; w weddings;
begin
  m := _member_staff(p_token);
  select * into w from weddings where id = m.wedding_id;
  return json_build_object('can', _can_cover(m), 'token', case when _can_cover(m) then w.share_token end,
                           'until', w.share_until, 'revealed', _revealed(w));
end $$;
revoke execute on function public.album_link_state(uuid) from public;
grant execute on function public.album_link_state(uuid) to anon, authenticated;

-- what the link shows: only after the reveal, only while it is valid, never secret/deleted/hidden photos
create or replace function public.public_album(p_share uuid) returns json
language plpgsql volatile security definer set search_path = public as $$
declare w weddings;
begin
  if not _rate_ok('album', 120, interval '15 minutes', 5000) then raise exception 'too_many' using errcode = 'P0001'; end if;
  select * into w from weddings where share_token = p_share and share_until > now();
  if not found or not _revealed(w) then
    insert into rate_hits (kind, ip) values ('album', _client_ip());
    return json_build_object('error', 'not_found');   -- not raised: an exception would undo the counted attempt
  end if;
  return json_build_object(
    'groom', w.groom, 'bride', w.bride, 'date', w.wdate, 'venue', w.venue, 'cover', w.cover_thumb, 'until', w.share_until,
    'photos', coalesce((select json_agg(json_build_object('path', p.path, 'thumb', p.thumb_path, 'kind', p.kind, 'w', p.w, 'h', p.h,
                                                          'caption', p.caption, 'team', p.team) order by p.created_at)
                          from photos p
                         where p.wedding_id = w.id and p.vis <> 'secret' and p.deleted_at is null and p.hidden_at is null
                           and p.purged_at is null and p.purge_at is null), '[]'::json));
end $$;
revoke execute on function public.public_album(uuid) from public;
grant execute on function public.public_album(uuid) to anon, authenticated;
