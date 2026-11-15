do $$ declare d text; begin
  select pg_get_functiondef('public._selftest_notify()'::regprocedure) into d;
  d := replace(d, '''קבלת פנים'', ''all'', null)', '''קבלת פנים'', ''all'', '''')');
  execute d;
end $$;;
