// Daily cleanup, from pg_cron:
// - removes the files of people who deleted their account (a day after they asked), but never a file
//   that another photo or the couple photo still uses (purge_plan decides that in the database)
// - drops the notification log after 3 days and the wrong-code counters after a day
const SB = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const HS = { apikey: SR, Authorization: `Bearer ${SR}` };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  let body: any = {}; try { body = await req.json(); } catch { /* */ }
  const sec = await fetch(`${SB}/rest/v1/app_secrets?name=eq.purge_key&select=value`, { headers: HS }).then((r) => r.json());
  if (!body.key || !sec?.[0] || body.key !== sec[0].value) return json({ error: "forbidden" }, 403);
  const now = new Date().toISOString();
  const ago = (d: number) => new Date(Date.now() - d * 864e5).toISOString();
  const log = await fetch(`${SB}/rest/v1/notify_log?at=lt.${ago(3)}`, { method: "DELETE", headers: { ...HS, Prefer: "return=minimal" } }).then((r) => r.ok).catch(() => false);
  const hits = await fetch(`${SB}/rest/v1/rate_hits?at=lt.${ago(1)}`, { method: "DELETE", headers: { ...HS, Prefer: "return=minimal" } }).then((r) => r.ok).catch(() => false);
  const plan = await fetch(`${SB}/rest/v1/rpc/purge_plan`, { method: "POST", headers: { ...HS, "Content-Type": "application/json" }, body: "{}" }).then((r) => r.json());
  const ids: string[] = Array.isArray(plan?.ids) ? plan.ids : [];
  const paths: string[] = Array.isArray(plan?.paths) ? plan.paths : [];
  if (!ids.length) return json({ purged: 0, log, hits });
  if (paths.length) {
    const del = await fetch(`${SB}/storage/v1/object/photos`, { method: "DELETE", headers: { ...HS, "Content-Type": "application/json" }, body: JSON.stringify({ prefixes: paths }) });
    if (!del.ok) return json({ error: "storage", status: del.status, detail: await del.text() }, 500);
  }
  const up = await fetch(`${SB}/rest/v1/photos?id=in.(${ids.join(",")})`, { method: "PATCH", headers: { ...HS, "Content-Type": "application/json", Prefer: "return=minimal" }, body: JSON.stringify({ purged_at: now }) });
  return json({ purged: ids.length, files: paths.length, marked: up.ok, log, hits });
});
