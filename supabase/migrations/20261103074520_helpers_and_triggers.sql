create or replace function public._bump() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update weddings set version = version + 1
   where id = (case when tg_op = 'DELETE' then old.wedding_id else new.wedding_id end);
  return null;
end $$;

create trigger bump after insert or update or delete on public.members for each row execute function public._bump();
create trigger bump after insert or update or delete on public.photos for each row execute function public._bump();
create trigger bump after insert or update or delete on public.hearts for each row execute function public._bump();
create trigger bump after insert or update or delete on public.teasers for each row execute function public._bump();
create trigger bump after insert or update or delete on public.reacts for each row execute function public._bump();
create trigger bump after insert or update or delete on public.sched for each row execute function public._bump();
create trigger bump after insert or update or delete on public.tasks for each row execute function public._bump();
create trigger bump after insert or update or delete on public.letters for each row execute function public._bump();

create or replace function public._code() returns text
language plpgsql security definer set search_path = public, extensions as $$
declare a text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; c text; i int;
begin
  loop
    c := '';
    for i in 1..6 loop
      c := c || substr(a, 1 + (get_byte(gen_random_bytes(1), 0) % length(a)), 1);
    end loop;
    exit when not exists (select 1 from weddings where code_groom = c or code_bride = c);
  end loop;
  return c;
end $$;

create or replace function public._member(p_token uuid) returns public.members
language plpgsql stable security definer set search_path = public as $$
declare m members;
begin
  select * into m from members where token = p_token;
  if not found then raise exception 'bad_token' using errcode = 'P0001'; end if;
  return m;
end $$;

create or replace function public._revealed(w public.weddings) returns boolean
language sql stable set search_path = public as $$
  select (w.revealed_at is not null and w.revealed_at <= now()) or now() >= w.reveal_at
$$;

create or replace function public._hhmm(base int, off int) returns text
language sql immutable set search_path = public as $$
  select lpad(((((base + off) % 1440) + 1440) % 1440 / 60)::text, 2, '0') || ':' ||
         lpad(((((base + off) % 1440) + 1440) % 1440 % 60)::text, 2, '0')
$$;

create or replace function public._template(p_wid uuid, p_time text) returns void
language plpgsql security definer set search_path = public as $$
declare base int := split_part(p_time, ':', 1)::int * 60 + split_part(p_time, ':', 2)::int;
begin
  insert into sched (wedding_id, t, title, side, note, reveal)
  select p_wid, _hhmm(base, v.off), v.title, v.side, v.note, v.rev from (values
    (-540, 'ארוחת בוקר עם החבר׳ה', 'groom', 'קפה, שקשוקה, והחתן עוד רגוע', false),
    (-540, 'בראנץ׳ בנות', 'bride', '', false),
    (-450, 'איפור ושיער', 'bride', '', false),
    (-420, 'מספרה וגילוח', 'groom', '', false),
    (-300, 'התארגנות ולבוש', 'all', '', false),
    (-240, 'צילומי זוג וחוץ', 'all', 'הצלם מתאם מיקום', false),
    (-150, 'נסיעה לאולם', 'all', '', false),
    (-90,  'קבלת פנים', 'all', '', false),
    (-25,  'כיסוי הכלה', 'all', '', false),
    (0,    'חופה', 'all', 'כל התמונות נפתחות לשני הצדדים', true),
    (45,   'כניסה לאולם וריקוד ראשון', 'all', '', false),
    (90,   'מנה ראשונה וברכות', 'all', '', false),
    (180,  'סט רחבה שני', 'all', '', false)
  ) as v(off, title, side, note, rev);

  insert into tasks (wedding_id, title, side, pts, mission, ord)
  select p_wid, v.title, v.side, v.pts, v.mission, v.ord from (values
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
    (14, 'לתאם מי אוסף את המתנות והמעטפות', 'all', 10, false)
  ) as v(ord, title, side, pts, mission);
end $$;

create or replace function public.wedding_exists(p_id text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from weddings where id::text = p_id)
$$;;
