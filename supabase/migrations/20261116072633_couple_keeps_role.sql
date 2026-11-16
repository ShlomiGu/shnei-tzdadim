-- the couple keeps its role: switching to escort would reveal the photos meant only for the escorts before the reveal
create or replace function public.update_me(p_token uuid, p_name text, p_role text) returns void
language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  if p_role = 'couple' and m.role = 'escort'
     and exists (select 1 from members x where x.wedding_id = m.wedding_id and x.team = m.team and x.role = 'couple' and x.deleted_at is null and x.id <> m.id) then
    raise exception 'couple_taken' using errcode = 'P0001';
  end if;
  update members set name = coalesce(nullif(left(trim(p_name), 30), ''), name),
                     role = case when m.role in ('couple', 'guest') then m.role when p_role in ('escort', 'couple') then p_role else role end
   where id = m.id;
end $$;
