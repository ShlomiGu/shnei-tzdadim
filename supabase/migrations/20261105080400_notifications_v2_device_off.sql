create or replace function remove_device(p_token uuid, p_device text) returns void language plpgsql security definer set search_path to 'public' as $$
declare m members;
begin
  m := _member(p_token);
  update push_subs set endpoint = 'gone:' || gen_random_uuid()::text, p256dh = '', auth = ''
   where endpoint = 'apns:' || lower(coalesce(p_device, '')) and member_id = m.id;
end $$;
grant execute on function save_device(uuid, text), remove_device(uuid, text), set_notify(uuid, jsonb) to anon, authenticated;;
