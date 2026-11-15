revoke all on function _want(jsonb, text), _recips(uuid, text[], text[], text, uuid), _notify_tick(), _on_task_who() from public, anon, authenticated;
revoke all on table notify_log, notified from anon, authenticated;;
