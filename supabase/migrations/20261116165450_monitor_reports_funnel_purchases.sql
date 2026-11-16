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
  'reports', coalesce((select json_agg(r) from (
      select r.id, r.created_at as at, r.kind, left(r.reason, 120) as reason, r.target_id,
             (select count(*) from reports r2 where r2.target_id = r.target_id and r2.handled_at is null) as n,
             case when r.kind = 'photo' then (select ph.thumb_path from photos ph where ph.id = r.target_id) end as thumb,
             case when r.kind = 'photo' then (select ph.hidden_at is not null from photos ph where ph.id = r.target_id)
                  when r.kind = 'teaser' then (select t.hidden_at is not null from teasers t where t.id = r.target_id) end as hidden,
             case when r.kind = 'teaser' then (select left(t.body, 200) from teasers t where t.id = r.target_id)
                  when r.kind = 'member' then (select mm.name from members mm where mm.id = r.target_id) end as text
        from reports r join w on w.id = r.wedding_id where r.handled_at is null order by r.created_at desc limit 20) r), '[]'::json),
  'funnel', json_build_object(
    'created', (select count(*) from w),
    'both_sides', (select count(*) from w where exists (select 1 from members x where x.wedding_id = w.id and x.team = 'groom' and x.deleted_at is null)
                                          and exists (select 1 from members x where x.wedding_id = w.id and x.team = 'bride' and x.deleted_at is null)),
    'with_photos', (select count(*) from w where exists (select 1 from photos x where x.wedding_id = w.id and x.deleted_at is null)),
    'revealed', (select count(*) from w where w.revealed_at is not null or w.reveal_at <= now()),
    'guests', (select count(*) from w where exists (select 1 from members x where x.wedding_id = w.id and x.team = 'guest'))),
  'purchases', json_build_object(
    'total', (select count(*) from purchases pu join w on w.id = pu.wedding_id),
    'last_30d', (select count(*) from purchases pu join w on w.id = pu.wedding_id where pu.created_at > now() - interval '30 days'),
    'by_product', coalesce((select json_object_agg(product, n) from (select pu.product, count(*) n from purchases pu join w on w.id = pu.wedding_id group by pu.product) x), '{}'::json),
    'recent', coalesce((select json_agg(x) from (select pu.created_at as at, pu.product, pu.provider, w.groom || ' ו' || w.bride as wedding,
                          pu.raw->>'environment' as env from purchases pu join w on w.id = pu.wedding_id order by pu.created_at desc limit 10) x), '[]'::json)),
  'archive', json_build_object(
    'kept', (select count(*) from w where w.keep_forever or w.protected),
    'archived', (select count(*) from w where w.archived_at is not null),
    'next_30d', coalesce((select json_agg(x) from (select w.groom || ' ו' || w.bride as wedding, w.wdate + 60 as on_date from w
                  where not w.keep_forever and not w.protected and w.archived_at is null and w.wdate + 60 <= (now() at time zone 'Asia/Jerusalem')::date + 30
                  order by w.wdate) x), '[]'::json)),
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

-- the owner's decision on a report, from the monitor page: hide the content for everyone, or keep it and close the report
create or replace function public.monitor_report(p_report uuid, p_hide boolean) returns json
language plpgsql security definer set search_path = public as $$
declare r reports;
begin
  select * into r from reports where id = p_report;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  if r.kind = 'photo' then update photos set hidden_at = case when p_hide then coalesce(hidden_at, now()) end where id = r.target_id;
  elsif r.kind = 'teaser' then update teasers set hidden_at = case when p_hide then coalesce(hidden_at, now()) end where id = r.target_id; end if;
  update reports set handled_at = now() where target_id = r.target_id and kind = r.kind and handled_at is null;
  return json_build_object('ok', true);
end $$;
revoke execute on function public.monitor_report(uuid, boolean) from public, anon, authenticated;
grant execute on function public.monitor_report(uuid, boolean) to service_role;
