-- AI: record the outcome of every call, and cap a wedding's calls per day (protects the API budget)
alter table public.ai_log
  add column if not exists wedding_id uuid,
  add column if not exists model text,
  add column if not exists status text,
  add column if not exists in_tok int,
  add column if not exists out_tok int,
  add column if not exists ms int,
  add column if not exists error text;
create index if not exists ai_log_at on public.ai_log (created_at);
create index if not exists ai_log_wedding on public.ai_log (wedding_id, created_at);

create or replace function public.ai_context(p_token uuid, p_kind text)
returns json language plpgsql security definer set search_path = public as $$
declare m members; w weddings; n int; lid bigint;
begin
  m := _member_staff(p_token);
  select count(*) into n from ai_log where member_id = m.id and created_at > now() - interval '1 hour';
  if n >= 30 then raise exception 'rate_limited'; end if;
  select count(*) into n from ai_log where wedding_id = m.wedding_id and created_at > now() - interval '1 day';
  if n >= 150 then raise exception 'rate_limited'; end if;
  insert into ai_log (member_id, wedding_id, kind, status) values (m.id, m.wedding_id, p_kind, 'started') returning id into lid;
  select * into w from weddings where id = m.wedding_id;
  return json_build_object(
    'log_id', lid,
    'me', json_build_object('team', m.team, 'role', m.role, 'name', m.name),
    'wedding', json_build_object('groom', w.groom, 'bride', w.bride, 'date', w.wdate, 'reveal_at', w.reveal_at, 'venue', w.venue, 'venue_city', w.venue_city),
    'members', coalesce((select json_agg(json_build_object('id', x.id, 'name', x.name, 'team', x.team, 'role', x.role)) from members x
                 where x.wedding_id = w.id and x.deleted_at is null and x.team <> 'guest'), '[]'::json),
    'sched', case when p_kind = 'sched' then coalesce((select json_agg(json_build_object('id', s.id, 't', s.t, 'title', s.title, 'place', s.place, 'note', s.note, 'side', s.side, 'done', s.done, 'reveal', s.reveal) order by s.t)
                from sched s where s.wedding_id = w.id and not s.deleted and s.side in (m.team, 'all')), '[]'::json) end,
    'sched_other', case when p_kind = 'sched' then coalesce((select json_agg(json_build_object('t', s.t, 'title', s.title) order by s.t)
                from sched s where s.wedding_id = w.id and not s.deleted and s.side not in (m.team, 'all')), '[]'::json) end,
    'tasks', case when p_kind = 'tasks' then coalesce((select json_agg(json_build_object('id', k.id, 'title', k.title, 'side', k.side, 'pts', k.pts, 'mission', k.mission, 'who', k.who, 'done', k.done) order by k.ord)
                from tasks k where k.wedding_id = w.id and not k.deleted and k.side in (m.team, 'all')), '[]'::json) end
  );
end $$;
revoke execute on function public.ai_context(uuid, text) from public, anon, authenticated;
grant execute on function public.ai_context(uuid, text) to service_role;

-- Monitoring (owner only): errors from the servers and the app, and the results of health checks
create table if not exists public.app_events (
  id     bigint generated always as identity primary key,
  at     timestamptz not null default now(),
  source text not null,
  level  text not null default 'error',
  msg    text not null,
  detail jsonb
);
create index if not exists app_events_at on public.app_events (at desc);
alter table public.app_events enable row level security;
revoke all on public.app_events from anon, authenticated;

create table if not exists public.health_runs (
  id       bigint generated always as identity primary key,
  at       timestamptz not null default now(),
  deep     boolean not null default false,
  ok       boolean not null,
  problems jsonb not null default '[]'::jsonb,
  results  jsonb
);
create index if not exists health_runs_at on public.health_runs (at desc);
alter table public.health_runs enable row level security;
revoke all on public.health_runs from anon, authenticated;

insert into public.app_secrets (name, value) values ('monitor_key', encode(extensions.gen_random_bytes(24), 'hex'))
on conflict (name) do nothing;

-- the app reports its own crashes here; capped so nobody can flood it
create or replace function public.log_client_error(p_msg text, p_detail jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from app_events where source = 'client' and at > now() - interval '1 hour') >= 300 then return; end if;
  insert into app_events (source, msg, detail) values ('client', left(coalesce(p_msg, ''), 300),
    case when p_detail is null then null when length(p_detail::text) > 2000 then jsonb_build_object('cut', left(p_detail::text, 2000)) else p_detail end);
end $$;
revoke execute on function public.log_client_error(text, jsonb) from public;
grant execute on function public.log_client_error(text, jsonb) to anon, authenticated;

-- one snapshot of the whole system for the owner's monitor page (test weddings are left out)
create or replace function public.monitor_stats()
returns json language sql stable security definer set search_path = public, storage, cron as $$
with w as (select * from weddings where groom <> '__selftest__'),
     m as (select x.* from members x join w on w.id = x.wedding_id),
     p as (select x.* from photos x join w on w.id = x.wedding_id),
     a as (select x.* from ai_log x join m on m.id = x.member_id where x.created_at > now() - interval '7 days')
select json_build_object(
  'at', now(),
  'weddings', json_build_object(
    'total', (select count(*) from w),
    'new_7d', (select count(*) from w where created_at > now() - interval '7 days'),
    'today', (select count(*) from w where wdate = (now() at time zone 'Asia/Jerusalem')::date),
    'next_30d', (select count(*) from w where wdate > (now() at time zone 'Asia/Jerusalem')::date and wdate <= (now() at time zone 'Asia/Jerusalem')::date + 30)),
  'members', json_build_object(
    'total', (select count(*) from m where deleted_at is null),
    'new_24h', (select count(*) from m where created_at > now() - interval '1 day'),
    'by_team', (select json_object_agg(team, n) from (select team, count(*) n from m where deleted_at is null group by team) t)),
  'photos', json_build_object(
    'total', (select count(*) from p where deleted_at is null),
    'new_24h', (select count(*) from p where created_at > now() - interval '1 day'),
    'videos', (select count(*) from p where deleted_at is null and kind = 'video')),
  'storage', json_build_object(
    'bytes', (select coalesce(sum((metadata->>'size')::bigint), 0) from storage.objects where bucket_id = 'photos'),
    'limit_bytes', 1073741824),
  'ai', (select json_build_object(
    'calls_24h', count(*) filter (where created_at > now() - interval '1 day'),
    'calls_7d', count(*),
    'errors_24h', count(*) filter (where created_at > now() - interval '1 day' and status = 'error'),
    'off_topic_7d', count(*) filter (where status = 'off_topic'),
    'in_tok_7d', coalesce(sum(in_tok), 0),
    'out_tok_7d', coalesce(sum(out_tok), 0),
    'avg_ms', round(avg(ms)),
    'models', coalesce(json_agg(distinct model) filter (where model is not null), '[]'::json),
    'last_errors', coalesce((select json_agg(e) from (select created_at as at, kind, left(error, 200) as error from a where status = 'error' order by created_at desc limit 5) e), '[]'::json))
    from a),
  'push', json_build_object(
    'devices', (select count(*) from push_subs),
    'sent_24h', (select count(*) from notify_log where at > now() - interval '1 day')),
  'reports_open', (select count(*) from reports where handled_at is null),
  'reports', coalesce((select json_agg(r) from (select created_at as at, kind, left(reason, 120) as reason from reports where handled_at is null order by created_at desc limit 10) r), '[]'::json),
  'events_24h', (select count(*) from app_events where at > now() - interval '1 day'),
  'events_1h', (select count(*) from app_events where at > now() - interval '1 hour'),
  'events', coalesce((select json_agg(e) from (select at, source, level, msg, detail from app_events order by at desc limit 60) e), '[]'::json),
  'cron_failed_24h', (select count(*) from cron.job_run_details where status <> 'succeeded' and start_time > now() - interval '1 day'),
  'cron', coalesce((select json_agg(c) from (select j.jobname, d.status, d.start_time as at, left(d.return_message, 200) as msg
            from cron.job_run_details d join cron.job j on j.jobid = d.jobid
           where d.status <> 'succeeded' and d.start_time > now() - interval '1 day' order by d.start_time desc limit 10) c), '[]'::json),
  'health', coalesce((select json_agg(h) from (select at, deep, ok, problems from health_runs order by at desc limit 48) h), '[]'::json)
);
$$;
revoke execute on function public.monitor_stats() from public, anon, authenticated;
grant execute on function public.monitor_stats() to service_role;

-- health checks: a quick one every hour, a full end-to-end one every night
select cron.schedule('shnei-tzdadim-health', '41 * * * *', $job$
  select net.http_post(
    url := 'https://yexzrxygjzzgsweiaqcm.supabase.co/functions/v1/monitor',
    body := jsonb_build_object('key', (select value from public.app_secrets where name = 'monitor_key'), 'action', 'check', 'deep', extract(hour from now() at time zone 'Asia/Jerusalem') = 4),
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InlleHpyeHlnanp6Z3N3ZWlhcWNtIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTM2ODk0NzksImV4cCI6MjEwOTI2NTQ3OX0.oxbOFBA4XqjFJ4-WsBSNyh-60_4Rm8Me8CVxzpPKrJY'),
    timeout_milliseconds := 300000)
$job$);
