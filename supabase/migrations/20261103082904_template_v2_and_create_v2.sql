create or replace function public._template2(p_wid uuid, p_time text, p_venue text) returns void
language plpgsql security definer set search_path = public as $$
declare
  base int := split_part(p_time, ':', 1)::int * 60 + split_part(p_time, ':', 2)::int;
  f numeric := 1;
  v text := coalesce(nullif(trim(p_venue), ''), 'האולם');
begin
  -- an early chuppah compresses the morning so nothing starts before 07:00
  if base - 540 < 420 then f := greatest(0.35, (base - 420) / 540.0); end if;
  insert into sched (wedding_id, t, title, side, place, note, reveal)
  select p_wid, _hhmm(base, case when x.off < 0 then round(x.off * f)::int else x.off end), x.title, x.side, x.place, x.note, x.rev from (values
    (-540, 'ארוחת בוקר עם החבר׳ה', 'groom', '', 'קפה, שקשוקה, והחתן עוד רגוע', false),
    (-540, 'בראנץ׳ בנות', 'bride', '', '', false),
    (-450, 'איפור ושיער', 'bride', '', 'לוודא שהמאפרת יודעת את הכתובת', false),
    (-420, 'מספרה וגילוח', 'groom', '', '', false),
    (-330, 'ארוחת צהריים קלה', 'all', '', 'לא לוותר, היום ארוך', false),
    (-300, 'התארגנות ולבוש', 'all', '', '', false),
    (-240, 'צילומי זוג וחוץ', 'all', '', 'הצלם מתאם מיקום', false),
    (-165, 'נסיעה ל' || v, 'all', v, 'לבדוק פקקים בווייז ולצאת עם מרווח', false),
    (-120, 'הגעה ל' || v || ' ובדיקת הכנות', 'all', v, 'עיצוב, מוזיקה, טבעות, כוס לשבירה', false),
    (-90,  'קבלת פנים', 'all', v, '', false),
    (-45,  'חתימה על הכתובה', 'all', v, 'עם הרב והעדים', false),
    (-25,  'כיסוי הכלה', 'all', v, '', false),
    (0,    'חופה', 'all', v, 'כל התמונות נפתחות לשני הצדדים', true),
    (40,   'כניסה לאולם וריקוד ראשון', 'all', v, '', false),
    (80,   'מנה ראשונה וברכות', 'all', v, '', false),
    (150,  'מנה עיקרית', 'all', v, '', false),
    (190,  'סט רחבה שני', 'all', v, '', false),
    (270,  'קינוחים וסיום', 'all', v, '', false)
  ) as x(off, title, side, place, note, rev);

  insert into tasks (wedding_id, title, side, pts, mission, ord)
  select p_wid, x.title, x.side, x.pts, x.mission, x.ord from (values
    (1,  'לוודא שהטבעת אצל מי שצריך', 'groom', 10, false),
    (2,  'ערכת חירום לחתן: מטען נייד, טישו, מסטיק', 'groom', 10, false),
    (3,  'לגהץ ולהכין את החולצה והחליפה', 'groom', 10, false),
    (4,  'משימת צילום: החתן מתאמן על שבירת הכוס', 'groom', 20, true),
    (5,  'משימת צילום: החתן מקריא את הנאום מול המראה', 'groom', 20, true),
    (6,  'משימת צילום: סלפי של כל החבורה', 'groom', 15, true),
    (7,  'ערכת חירום לכלה: סיכות, מחט וחוט, פלסטרים', 'bride', 10, false),
    (8,  'לוודא שזר הכלה הגיע', 'bride', 10, false),
    (9,  'נעליים נוחות לרחבה בתיק', 'bride', 10, false),
    (10, 'משימת צילום: הכלה צוחקת בלי לדעת שמצלמים', 'bride', 20, true),
    (11, 'משימת צילום: פרט קטן מהשמלה, בלי לגלות הכל', 'bride', 20, true),
    (12, 'משימת צילום: סלפי של כל החבורה', 'bride', 15, true),
    (13, 'להביא את הכוס לשבירה לחופה', 'all', 10, false),
    (14, 'לתאם מי אוסף את המתנות והמעטפות', 'all', 10, false),
    (15, 'לשלוח לכולם את הכתובת של ' || v, 'all', 5, false)
  ) as x(ord, title, side, pts, mission);
end $$;
revoke execute on function public._template2(uuid, text, text) from public, anon, authenticated;

create or replace function public.create_wedding_v2(
  p_groom text, p_bride text, p_date date, p_time text, p_reveal_at timestamptz,
  p_venue text, p_venue_city text, p_venue_custom boolean,
  p_team text, p_role text, p_name text, p_template boolean)
returns json language plpgsql security definer set search_path = public as $$
declare w weddings; m members; cg text; cb text;
begin
  if coalesce(trim(p_groom), '') = '' or coalesce(trim(p_bride), '') = '' then raise exception 'missing_names'; end if;
  if p_team not in ('groom','bride') then raise exception 'bad_team'; end if;
  if p_time !~ '^\d\d:\d\d$' then raise exception 'bad_time'; end if;
  cg := _code();
  loop cb := _code(); exit when cb <> cg; end loop;
  insert into weddings (groom, bride, wdate, reveal_at, venue, venue_city, code_groom, code_bride)
  values (left(trim(p_groom), 40), left(trim(p_bride), 40), p_date, p_reveal_at, left(coalesce(trim(p_venue), ''), 80), left(coalesce(trim(p_venue_city), ''), 40), cg, cb)
  returning * into w;
  insert into members (wedding_id, team, role, name)
  values (w.id, p_team, case when p_role = 'couple' then 'couple' else 'escort' end, left(coalesce(nullif(trim(p_name), ''), 'מארגן/ת'), 30))
  returning * into m;
  if p_venue_custom and coalesce(trim(p_venue), '') <> '' then
    insert into venues_custom (name, city, wedding_id) values (left(trim(p_venue), 80), left(coalesce(trim(p_venue_city), ''), 40), w.id)
    on conflict do nothing;
  end if;
  if p_template then perform _template2(w.id, p_time, p_venue); end if;
  return json_build_object('token', m.token, 'team', m.team);
end $$;

create or replace function public.list_custom_venues()
returns json language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('he', name, 'city', city)), '[]'::json) from (select name, city from venues_custom order by created_at desc limit 500) v
$$;

create or replace function public.update_wedding(p_token uuid, p jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := _member(p_token);
  update weddings set
    groom = coalesce(nullif(left(trim(p->>'groom'), 40), ''), groom),
    bride = coalesce(nullif(left(trim(p->>'bride'), 40), ''), bride),
    wdate = coalesce((p->>'date')::date, wdate),
    venue = case when p ? 'venue' then left(coalesce(p->>'venue', ''), 80) else venue end,
    venue_city = case when p ? 'venue_city' then left(coalesce(p->>'venue_city', ''), 40) else venue_city end,
    contacts = case when jsonb_typeof(p->'contacts') = 'array' then p->'contacts' else contacts end,
    reveal_at = coalesce((p->>'reveal_at')::timestamptz, reveal_at),
    version = version + 1
  where id = m.wedding_id;
  if coalesce((p->>'venue_custom')::boolean, false) and coalesce(trim(p->>'venue'), '') <> '' then
    insert into venues_custom (name, city, wedding_id) values (left(trim(p->>'venue'), 80), left(coalesce(trim(p->>'venue_city'), ''), 40), m.wedding_id)
    on conflict do nothing;
  end if;
end $$;

create or replace function public.add_media(p_token uuid, p_kind text, p_path text, p_thumb text, p_blur text, p_w int, p_h int,
  p_duration real, p_caption text, p_vis text, p_task uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare m members; w weddings; pid uuid; v text := p_vis; k text := case when p_kind = 'video' then 'video' else 'image' end;
begin
  m := _member(p_token);
  select * into w from weddings where id = m.wedding_id;
  if p_path not like w.id::text || '/%' or p_thumb not like w.id::text || '/%' then raise exception 'bad_path'; end if;
  if p_blur is not null and (length(p_blur) > 6000 or p_blur !~ '^data:image/(jpeg|webp);base64,') then p_blur := null; end if;
  if v not in ('team','teaser','secret') then v := 'team'; end if;
  if v = 'teaser' and _revealed(w) then v := 'team'; end if;
  insert into photos (wedding_id, team, member_id, kind, path, thumb_path, blur, w, h, duration, caption, vis, task_id)
  values (w.id, m.team, m.id, k, p_path, p_thumb, p_blur, p_w, p_h, p_duration, left(coalesce(p_caption, ''), 200), v, p_task)
  returning id into pid;
  if p_task is not null then
    update tasks set done = true, done_by = m.id, done_side = m.team, done_at = now(), photo_id = pid
     where id = p_task and wedding_id = w.id and side in (m.team, 'all') and not done and not deleted;
  end if;
  return pid;
end $$;;
