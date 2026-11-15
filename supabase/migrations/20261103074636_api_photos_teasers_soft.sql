create or replace function public.add_photo(p_token uuid, p_path text, p_thumb text, p_blur text, p_w int, p_h int,
  p_caption text, p_vis text, p_task uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare m members; w weddings; pid uuid; v text := p_vis;
begin
  m := _member(p_token);
  select * into w from weddings where id = m.wedding_id;
  if p_path not like w.id::text || '/%' or p_thumb not like w.id::text || '/%' then raise exception 'bad_path'; end if;
  if p_blur is not null and (length(p_blur) > 6000 or p_blur not like 'data:image/jpeg;base64,%') then p_blur := null; end if;
  if v not in ('team','teaser','secret') then v := 'team'; end if;
  if v = 'teaser' and _revealed(w) then v := 'team'; end if;
  insert into photos (wedding_id, team, member_id, path, thumb_path, blur, w, h, caption, vis, task_id)
  values (w.id, m.team, m.id, p_path, p_thumb, p_blur, p_w, p_h, left(coalesce(p_caption, ''), 200), v, p_task)
  returning id into pid;
  if p_task is not null then
    update tasks set done = true, done_by = m.id, done_side = m.team, done_at = now(), photo_id = pid
     where id = p_task and wedding_id = w.id and side in (m.team, 'all') and not done and not deleted;
  end if;
  return pid;
end $$;

create or replace function public.set_photo_vis(p_token uuid, p_id uuid, p_vis text)
returns void language plpgsql security definer set search_path = public as $$
declare m members; p photos;
begin
  m := _member(p_token);
  if p_vis not in ('team','teaser','secret') then raise exception 'bad_vis'; end if;
  select * into p from photos where id = p_id and wedding_id = m.wedding_id and team = m.team and deleted_at is null;
  if not found then raise exception 'not_found'; end if;
  update photos set vis = p_vis where id = p.id;
  if p_vis = 'teaser' and not exists (select 1 from teasers t where t.wedding_id = m.wedding_id and p.id = any (t.photo_ids)) then
    insert into teasers (wedding_id, team, member_id, body, photo_ids) values (m.wedding_id, m.team, m.id, p.caption, array[p.id]);
  end if;
end $$;

create or replace function public.delete_photo(p_token uuid, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  update photos set deleted_at = now() where id = p_id and wedding_id = m.wedding_id and member_id = m.id and deleted_at is null;
  if not found then raise exception 'not_found'; end if;
end $$;

create or replace function public.toggle_heart(p_token uuid, p_photo uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m members; wd weddings;
begin
  m := _member(p_token);
  select * into wd from weddings where id = m.wedding_id;
  if not exists (select 1 from photos p where p.id = p_photo and p.wedding_id = wd.id and p.deleted_at is null
                 and (p.team = m.team or (_revealed(wd) and p.vis <> 'secret'))) then raise exception 'not_found'; end if;
  insert into hearts (wedding_id, photo_id, member_id, active) values (wd.id, p_photo, m.id, true)
  on conflict (photo_id, member_id) do update set active = not hearts.active, created_at = now();
end $$;

create or replace function public.send_teaser(p_token uuid, p_body text, p_photos uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare m members; wd weddings; ids uuid[];
begin
  m := _member(p_token);
  select * into wd from weddings where id = m.wedding_id;
  select coalesce(array_agg(p.id), '{}') into ids from photos p
   where p.id = any (coalesce(p_photos, '{}')) and p.wedding_id = wd.id and p.team = m.team and p.vis <> 'secret' and p.deleted_at is null;
  if coalesce(trim(p_body), '') = '' and cardinality(ids) = 0 then raise exception 'empty'; end if;
  if not _revealed(wd) then update photos set vis = 'teaser' where id = any (ids) and vis = 'team'; end if;
  insert into teasers (wedding_id, team, member_id, body, photo_ids) values (wd.id, m.team, m.id, left(coalesce(trim(p_body), ''), 300), ids[1:4]);
end $$;

create or replace function public.react(p_token uuid, p_teaser uuid, p_emoji text)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  if p_emoji not in ('😍','😂','🔥','🥹') then raise exception 'bad_emoji'; end if;
  if not exists (select 1 from teasers t where t.id = p_teaser and t.wedding_id = m.wedding_id and t.team <> m.team) then raise exception 'not_found'; end if;
  insert into reacts (wedding_id, teaser_id, member_id, emoji) values (m.wedding_id, p_teaser, m.id, p_emoji)
  on conflict (teaser_id, member_id) do update set emoji = case when reacts.emoji = excluded.emoji then '' else excluded.emoji end;
end $$;;
