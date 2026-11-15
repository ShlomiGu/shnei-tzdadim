revoke execute on function public._bump() from public, anon, authenticated;
revoke execute on function public._code() from public, anon, authenticated;
revoke execute on function public._member(uuid) from public, anon, authenticated;
revoke execute on function public._revealed(public.weddings) from public, anon, authenticated;
revoke execute on function public._hhmm(int, int) from public, anon, authenticated;
revoke execute on function public._template(uuid, text) from public, anon, authenticated;
revoke all on table public.weddings, public.members, public.photos, public.hearts, public.teasers, public.reacts, public.sched, public.tasks, public.letters from anon, authenticated;;
