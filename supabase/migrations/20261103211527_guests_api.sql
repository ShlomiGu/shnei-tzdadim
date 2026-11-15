create or replace function public.peek_code(p_code text)
returns json language plpgsql stable security definer set search_path = public as $$
declare c text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')); w weddings;
begin
  select * into w from weddings where code_groom = c or code_bride = c or code_guest = c;
  if not found then return null; end if;
  return json_build_object('team', case when w.code_groom = c then 'groom' when w.code_bride = c then 'bride' else 'guest' end,
                           'groom', w.groom, 'bride', w.bride, 'date', w.wdate);
end $$;

create or replace function public.join_wedding(p_code text, p_name text, p_role text)
returns json language plpgsql security definer set search_path = public as $$
declare c text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')); w weddings; m members; t text; r text;
begin
  select * into w from weddings where code_groom = c or code_bride = c or code_guest = c;
  if not found then raise exception 'bad_code'; end if;
  t := case when w.code_groom = c then 'groom' when w.code_bride = c then 'bride' else 'guest' end;
  if coalesce(trim(p_name), '') = '' then raise exception 'missing_name'; end if;
  r := case when t = 'guest' then 'guest' when p_role = 'couple' then 'couple' else 'escort' end;
  insert into members (wedding_id, team, role, name) values (w.id, t, r, left(trim(p_name), 30)) returning * into m;
  return json_build_object('token', m.token, 'team', t);
end $$;

create or replace function public.update_me(p_token uuid, p_name text, p_role text)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  update members set name = coalesce(nullif(left(trim(p_name), 30), ''), name),
                     role = case when m.role in ('couple','guest') then m.role when p_role in ('escort','couple') then p_role else role end
   where id = m.id;
end $$;

create or replace function public.add_media(p_token uuid, p_kind text, p_path text, p_thumb text, p_blur text, p_w int, p_h int,
  p_duration real, p_caption text, p_vis text, p_task uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare m members; w weddings; pid uuid; v text := p_vis; esc boolean := false; k text := case when p_kind = 'video' then 'video' else 'image' end;
begin
  m := _member(p_token);
  select * into w from weddings where id = m.wedding_id;
  if p_path not like w.id::text || '/%' or p_thumb not like w.id::text || '/%' then raise exception 'bad_path'; end if;
  if p_blur is not null and (length(p_blur) > 6000 or p_blur !~ '^data:image/(jpeg|webp);base64,') then p_blur := null; end if;
  if m.role = 'guest' then v := 'team'; p_task := null;
  else
    if v = 'escorts' then v := 'team'; esc := true; end if;
    if v not in ('team','teaser','secret') then v := 'team'; end if;
    if v = 'teaser' and _revealed(w) then v := 'team'; end if;
  end if;
  insert into photos (wedding_id, team, member_id, kind, path, thumb_path, blur, w, h, duration, caption, vis, share_escorts, task_id)
  values (w.id, m.team, m.id, k, p_path, p_thumb, p_blur, p_w, p_h, p_duration, left(coalesce(p_caption, ''), 200), v, esc, p_task)
  returning id into pid;
  if p_task is not null then
    update tasks set done = true, done_by = m.id, done_side = m.team, done_at = now(), photo_id = pid
     where id = p_task and wedding_id = w.id and side in (m.team, 'all') and not done and not deleted;
  end if;
  return pid;
end $$;;
