create or replace function public.delete_account(p_token uuid, p_content boolean)
returns json language plpgsql security definer set search_path to 'public' as $$
declare m members; k int := 0;
begin
  m := _member(p_token);
  update members set deleted_at = now(), name = 'חשבון שנמחק', token = gen_random_uuid() where id = m.id;
  update push_subs set endpoint = 'gone:' || gen_random_uuid()::text, p256dh = '', auth = '' where member_id = m.id;
  update hearts set active = false where member_id = m.id;
  update reacts set emoji = '' where member_id = m.id;
  update letters set deleted = true, body = '' where member_id = m.id;
  update teasers set hidden_at = coalesce(hidden_at, now()), body = '' where member_id = m.id;
  update tasks set who = null where who = m.id;
  update blocks set active = false where blocker_id = m.id or blocked_id = m.id;
  if p_content then
    update photos set deleted_at = coalesce(deleted_at, now()), purge_at = now() + interval '1 day', caption = ''
     where member_id = m.id and purged_at is null;
    get diagnostics k = row_count;
  end if;
  update weddings set version = version + 1 where id = m.wedding_id;
  return json_build_object('ok', true, 'files', k);
end $$;;
