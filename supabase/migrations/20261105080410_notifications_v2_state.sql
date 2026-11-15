do $$ declare d text; begin
  select pg_get_functiondef('public.get_state(uuid)'::regprocedure) into d;
  if position('''notify'', m.notify' in d) = 0 then
    if position('''can_cover'', _can_cover(m))' in d) = 0 then raise exception 'get_state: anchor not found'; end if;
    d := replace(d, '''can_cover'', _can_cover(m))', '''can_cover'', _can_cover(m), ''notify'', m.notify)');
    execute d;
  end if;
end $$;;
