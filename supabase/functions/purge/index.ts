// Daily cleanup, from pg_cron:
// - removes the files of people who deleted their account (a day after they asked), but never a file
//   that another photo or the couple photo still uses (purge_plan decides that in the database)
// - drops the notification log after 3 days and the wrong-code counters after a day
// - archives weddings 60 days after their date (warns 30/7/1 days before): originals are removed, the small copies stay;
//   weddings that were kept forever (or protected by the owner) are never touched
const SB = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const HS = { apikey: SR, Authorization: `Bearer ${SR}` };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });

const rpc = (fn: string, args: unknown) => fetch(`${SB}/rest/v1/rpc/${fn}`, { method: "POST", headers: { ...HS, "Content-Type": "application/json" }, body: JSON.stringify(args) })
  .then(async (r) => { if (!r.ok) throw new Error(fn + " " + r.status + " " + (await r.text()).slice(0, 200)); return r.json(); });

// sends the archive warnings, then removes the originals of weddings that are due, a batch at a time
async function runArchive() {
  let photos = 0, files = 0;
  try {
    for (let round = 0; round < 10; round++) {
      const plan = await rpc("archive_tick", { p_limit: 300 });
      const ids: string[] = Array.isArray(plan?.ids) ? plan.ids : [];
      const paths: string[] = Array.isArray(plan?.paths) ? plan.paths : [];
      if (!ids.length) break;
      if (paths.length) {
        const del = await fetch(`${SB}/storage/v1/object/photos`, { method: "DELETE", headers: { ...HS, "Content-Type": "application/json" }, body: JSON.stringify({ prefixes: paths }) });
        if (!del.ok) throw new Error("storage " + del.status + " " + (await del.text()).slice(0, 200));
        files += paths.length;
      }
      const done = await rpc("archive_done", { p_ids: ids });
      photos += done?.archived_photos || 0;
    }
    return { photos, files };
  } catch (e) {
    console.error("archive", e);
    await fetch(`${SB}/rest/v1/app_events`, { method: "POST", headers: { ...HS, "Content-Type": "application/json", Prefer: "return=minimal" },
      body: JSON.stringify({ source: "archive", msg: String(e).slice(0, 300) }) }).catch(() => {});
    return { photos, files, error: String(e).slice(0, 200) };
  }
}

Deno.serve(async (req) => {
  let body: any = {}; try { body = await req.json(); } catch { /* */ }
  const sec = await fetch(`${SB}/rest/v1/app_secrets?name=eq.purge_key&select=value`, { headers: HS }).then((r) => r.json());
  if (!body.key || !sec?.[0] || body.key !== sec[0].value) return json({ error: "forbidden" }, 403);
  const now = new Date().toISOString();
  const ago = (d: number) => new Date(Date.now() - d * 864e5).toISOString();
  const log = await fetch(`${SB}/rest/v1/notify_log?at=lt.${ago(3)}`, { method: "DELETE", headers: { ...HS, Prefer: "return=minimal" } }).then((r) => r.ok).catch(() => false);
  const hits = await fetch(`${SB}/rest/v1/rate_hits?at=lt.${ago(1)}`, { method: "DELETE", headers: { ...HS, Prefer: "return=minimal" } }).then((r) => r.ok).catch(() => false);
  const archive = await runArchive();
  const plan = await fetch(`${SB}/rest/v1/rpc/purge_plan`, { method: "POST", headers: { ...HS, "Content-Type": "application/json" }, body: "{}" }).then((r) => r.json());
  const ids: string[] = Array.isArray(plan?.ids) ? plan.ids : [];
  const paths: string[] = Array.isArray(plan?.paths) ? plan.paths : [];
  if (!ids.length) return json({ purged: 0, log, hits, archive });
  if (paths.length) {
    const del = await fetch(`${SB}/storage/v1/object/photos`, { method: "DELETE", headers: { ...HS, "Content-Type": "application/json" }, body: JSON.stringify({ prefixes: paths }) });
    if (!del.ok) return json({ error: "storage", status: del.status, detail: await del.text() }, 500);
  }
  const up = await fetch(`${SB}/rest/v1/photos?id=in.(${ids.join(",")})`, { method: "PATCH", headers: { ...HS, "Content-Type": "application/json", Prefer: "return=minimal" }, body: JSON.stringify({ purged_at: now }) });
  return json({ purged: ids.length, files: paths.length, marked: up.ok, log, hits, archive });
});
