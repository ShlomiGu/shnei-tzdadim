create extension if not exists pgcrypto with schema extensions;

create table public.weddings (
  id          uuid primary key default gen_random_uuid(),
  groom       text not null,
  bride       text not null,
  wdate       date not null,
  reveal_at   timestamptz not null,
  revealed_at timestamptz,
  venue       text not null default '',
  contacts    jsonb not null default '[]'::jsonb,
  code_groom  text not null unique,
  code_bride  text not null unique,
  version     bigint not null default 1,
  created_at  timestamptz not null default now()
);

create table public.members (
  id         uuid primary key default gen_random_uuid(),
  wedding_id uuid not null references public.weddings on delete cascade,
  team       text not null check (team in ('groom','bride')),
  role       text not null default 'escort' check (role in ('escort','couple')),
  name       text not null,
  token      uuid not null unique default gen_random_uuid(),
  created_at timestamptz not null default now()
);
create index members_wedding on public.members (wedding_id);

create table public.photos (
  id         uuid primary key default gen_random_uuid(),
  wedding_id uuid not null references public.weddings on delete cascade,
  team       text not null check (team in ('groom','bride')),
  member_id  uuid references public.members on delete set null,
  path       text not null,
  thumb_path text not null,
  blur       text,
  w          int,
  h          int,
  caption    text not null default '',
  vis        text not null default 'team' check (vis in ('team','teaser','secret')),
  task_id    uuid,
  created_at timestamptz not null default now()
);
create index photos_wedding on public.photos (wedding_id, created_at desc);
create index photos_member on public.photos (member_id);

create table public.hearts (
  wedding_id uuid not null references public.weddings on delete cascade,
  photo_id   uuid not null references public.photos on delete cascade,
  member_id  uuid not null references public.members on delete cascade,
  created_at timestamptz not null default now(),
  primary key (photo_id, member_id)
);
create index hearts_wedding on public.hearts (wedding_id);
create index hearts_member on public.hearts (member_id);

create table public.teasers (
  id         uuid primary key default gen_random_uuid(),
  wedding_id uuid not null references public.weddings on delete cascade,
  team       text not null check (team in ('groom','bride')),
  member_id  uuid references public.members on delete set null,
  body       text not null default '',
  photo_ids  uuid[] not null default '{}',
  created_at timestamptz not null default now()
);
create index teasers_wedding on public.teasers (wedding_id, created_at);
create index teasers_member on public.teasers (member_id);

create table public.reacts (
  wedding_id uuid not null references public.weddings on delete cascade,
  teaser_id  uuid not null references public.teasers on delete cascade,
  member_id  uuid not null references public.members on delete cascade,
  emoji      text not null,
  primary key (teaser_id, member_id)
);
create index reacts_wedding on public.reacts (wedding_id);
create index reacts_member on public.reacts (member_id);

create table public.sched (
  id         uuid primary key default gen_random_uuid(),
  wedding_id uuid not null references public.weddings on delete cascade,
  t          text not null check (t ~ '^\d\d:\d\d$'),
  title      text not null,
  place      text not null default '',
  note       text not null default '',
  side       text not null default 'all' check (side in ('all','groom','bride')),
  done       boolean not null default false,
  reveal     boolean not null default false,
  created_at timestamptz not null default now()
);
create index sched_wedding on public.sched (wedding_id);

create table public.tasks (
  id         uuid primary key default gen_random_uuid(),
  wedding_id uuid not null references public.weddings on delete cascade,
  title      text not null,
  side       text not null default 'all' check (side in ('all','groom','bride')),
  pts        int not null default 10 check (pts between 0 and 100),
  mission    boolean not null default false,
  who        uuid references public.members on delete set null,
  done       boolean not null default false,
  done_by    uuid references public.members on delete set null,
  done_side  text,
  done_at    timestamptz,
  photo_id   uuid references public.photos on delete set null,
  ord        int not null default 0,
  created_at timestamptz not null default now()
);
create index tasks_wedding on public.tasks (wedding_id);
create index tasks_who on public.tasks (who);
create index tasks_done_by on public.tasks (done_by);
create index tasks_photo on public.tasks (photo_id);

create table public.letters (
  id         uuid primary key default gen_random_uuid(),
  wedding_id uuid not null references public.weddings on delete cascade,
  from_team  text not null check (from_team in ('groom','bride')),
  member_id  uuid not null references public.members on delete cascade,
  body       text not null,
  open_at    timestamptz not null,
  created_at timestamptz not null default now()
);
create index letters_wedding on public.letters (wedding_id);
create index letters_member on public.letters (member_id);

alter table public.weddings enable row level security;
alter table public.members enable row level security;
alter table public.photos enable row level security;
alter table public.hearts enable row level security;
alter table public.teasers enable row level security;
alter table public.reacts enable row level security;
alter table public.sched enable row level security;
alter table public.tasks enable row level security;
alter table public.letters enable row level security;;
