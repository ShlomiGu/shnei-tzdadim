alter table public.weddings add column status_groom text not null default '', add column status_groom_at timestamptz,
  add column status_bride text not null default '', add column status_bride_at timestamptz;

create or replace function public.set_status(p_token uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare m members; s text := left(coalesce(trim(p_status), ''), 40);
begin
  m := _member_staff(p_token);
  if m.team = 'groom' then update weddings set status_groom = s, status_groom_at = now(), version = version + 1 where id = m.wedding_id;
  else update weddings set status_bride = s, status_bride_at = now(), version = version + 1 where id = m.wedding_id; end if;
end $$;

-- expose statuses inside get_state without touching the rest of it
do $$
declare def text;
begin
  def := pg_get_functiondef('public.get_state(uuid)'::regprocedure);
  def := replace(def, $q$'guest_code', w.code_guest,$q$,
    $q$'guest_code', case when g then null else w.code_guest end,
      'status', json_build_object('groom', w.status_groom, 'groom_at', w.status_groom_at, 'bride', w.status_bride, 'bride_at', w.status_bride_at),$q$);
  if position('status_groom_at' in def) = 0 then raise exception 'patch failed'; end if;
  execute def;
end $$;;
