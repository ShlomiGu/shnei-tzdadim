alter table public.weddings add column code_guest text unique;
alter table public.members drop constraint members_team_check;
alter table public.members add constraint members_team_check check (team in ('groom','bride','guest'));
alter table public.members drop constraint members_role_check;
alter table public.members add constraint members_role_check check (role in ('escort','couple','guest'));
alter table public.photos drop constraint photos_team_check;
alter table public.photos add constraint photos_team_check check (team in ('groom','bride','guest'));

create or replace function public._code() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare a text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; c text; i int;
begin
  loop
    c := '';
    for i in 1..6 loop
      c := c || substr(a, 1 + (get_byte(gen_random_bytes(1), 0) % length(a)), 1);
    end loop;
    exit when not exists (select 1 from weddings where code_groom = c or code_bride = c or code_guest = c);
  end loop;
  return c;
end $$;

do $$ declare r record; begin
  for r in select id from weddings where code_guest is null loop
    update weddings set code_guest = _code() where id = r.id;
  end loop;
end $$;

create or replace function public._fill_guest_code() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.code_guest is null then new.code_guest := _code(); end if;
  return new;
end $$;
create trigger fill_guest_code before insert on public.weddings for each row execute function public._fill_guest_code();
revoke execute on function public._fill_guest_code() from public, anon, authenticated;

-- members who may change the plan: everyone except guests
create or replace function public._member_staff(p_token uuid) returns public.members
language plpgsql stable security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  if m.role = 'guest' then raise exception 'guests_cannot' using errcode = 'P0001'; end if;
  return m;
end $$;
revoke execute on function public._member_staff(uuid) from public, anon, authenticated;

-- switch every planning/editing function to the staff check, keeping their bodies otherwise identical
do $$
declare f record; def text;
begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('save_sched','delete_sched','save_task','toggle_task','claim_task','delete_task',
             'write_letter','delete_letter','update_wedding','set_reveal','send_teaser','react','set_photo_vis',
             'ai_apply_sched','ai_apply_tasks','ai_context') loop
    def := pg_get_functiondef(f.oid);
    if position('_member(p_token)' in def) = 0 then raise exception 'unexpected body in %', f.oid::regprocedure; end if;
    execute replace(def, '_member(p_token)', '_member_staff(p_token)');
  end loop;
end $$;;
