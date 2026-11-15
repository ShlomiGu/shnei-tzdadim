alter table public.photos add column kind text not null default 'image' check (kind in ('image','video'));
alter table public.photos add column duration real;
alter table public.weddings add column venue_city text not null default '';

update storage.buckets
   set file_size_limit = 52428800,
       allowed_mime_types = array['image/jpeg','image/png','image/webp','video/mp4','video/quicktime','video/webm']
 where id = 'photos';

create table public.ai_log (
  id         bigint generated always as identity primary key,
  member_id  uuid not null references public.members on delete cascade,
  kind       text not null,
  created_at timestamptz not null default now()
);
create index ai_log_member on public.ai_log (member_id, created_at);
alter table public.ai_log enable row level security;
revoke all on public.ai_log from anon, authenticated;

create table public.venues_custom (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  city       text not null default '',
  wedding_id uuid references public.weddings on delete set null,
  created_at timestamptz not null default now()
);
create unique index venues_custom_name_city on public.venues_custom (lower(name), lower(city));
create index venues_custom_wedding on public.venues_custom (wedding_id);
alter table public.venues_custom enable row level security;
revoke all on public.venues_custom from anon, authenticated;;
