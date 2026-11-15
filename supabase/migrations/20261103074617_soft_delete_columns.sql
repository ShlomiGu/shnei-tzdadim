alter table public.photos  add column deleted_at timestamptz;
alter table public.sched   add column deleted boolean not null default false;
alter table public.tasks   add column deleted boolean not null default false;
alter table public.letters add column deleted boolean not null default false;
alter table public.hearts  add column active boolean not null default true;
alter table public.reacts  alter column emoji set default '';;
