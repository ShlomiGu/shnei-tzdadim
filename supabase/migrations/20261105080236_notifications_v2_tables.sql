create table if not exists notify_log (id bigserial primary key, at timestamptz not null default now(), members uuid[] not null, title text, body text, url text, tag text);
alter table notify_log enable row level security;
create index if not exists notify_log_at on notify_log (at);

create table if not exists notified (kind text not null, ref uuid not null, val text, at timestamptz not null default now(), primary key (kind, ref));
alter table notified enable row level security;

alter table members add column if not exists notify jsonb not null default '{}'::jsonb;

insert into notified (kind, ref, val) select 'photos', id, null from members on conflict do nothing;
insert into notified (kind, ref, val) select 'task', id, who::text from tasks where who is not null on conflict do nothing;
insert into notified (kind, ref, val) select 'status-groom', id, coalesce(status_groom, '') from weddings on conflict do nothing;
insert into notified (kind, ref, val) select 'status-bride', id, coalesce(status_bride, '') from weddings on conflict do nothing;
insert into notified (kind, ref, val) select 'after', id, wdate::text from weddings where wdate < (now() at time zone 'Asia/Jerusalem')::date on conflict do nothing;;
