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
  'reports_open', (select count(*) from reports r join w on w.id = r.wedding_id where r.handled_at is null),
  'reports', coalesce((select json_agg(r) from (select r.created_at as at, r.kind, left(r.reason, 120) as reason from reports r join w on w.id = r.wedding_id where r.handled_at is null order by r.created_at desc limit 10) r), '[]'::json),
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