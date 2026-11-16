// monitor: the owner's view of the whole system. Every action needs the secret monitor_key (app_secrets).
//   dashboard - one snapshot (usage, AI, errors, reports, cron, recent health checks)
//   check     - runs the health checks and stores the result; deep=true also runs the end-to-end self tests and a real AI call
//   status    - the latest stored check, for the GitHub alert workflow
//   report    - the owner's decision on a reported photo/teaser: hide it for everyone, or keep it and close the report
const SB = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const A = Deno.env.get("SUPABASE_ANON_KEY")!;
const HS = { apikey: SR, Authorization: `Bearer ${SR}` };
const HA = { apikey: A, Authorization: `Bearer ${A}`, "Content-Type": "application/json" };
const SITE = "https://shlomigu.github.io/shnei-tzdadim/";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

async function secrets(names: string[]) {
  const rows = await fetch(`${SB}/rest/v1/app_secrets?select=name,value&name=in.(${names.join(",")})`, { headers: HS }).then((r) => r.json());
  return Object.fromEntries((rows || []).map((r: { name: string; value: string }) => [r.name, r.value])) as Record<string, string>;
}
const same = (a: string, b: string) => {
  if (!a || !b || a.length !== b.length) return false;
  let d = 0; for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
};
const stats = async () => {
  const r = await fetch(`${SB}/rest/v1/rpc/monitor_stats`, { method: "POST", headers: { ...HS, "Content-Type": "application/json" }, body: "{}" });
  if (!r.ok) throw new Error("monitor_stats " + r.status + " " + (await r.text()).slice(0, 200));
  return r.json();
};
const config = () => ({
  ai: !!(Deno.env.get("ANTHROPIC_API_KEY") || Deno.env.get("OPENAI_API_KEY")),
  ai_provider: Deno.env.get("ANTHROPIC_API_KEY") ? "anthropic" : Deno.env.get("OPENAI_API_KEY") ? "openai" : "",
  ai_model: Deno.env.get("AI_MODEL") || "claude-haiku-5-5",
  apns: !!Deno.env.get("APNS_KEY_P8"),
});
const timed = async <T>(f: () => Promise<T>) => { const t = Date.now(); const v = await f(); return { v, ms: Date.now() - t }; };

async function check(deep: boolean) {
  const problems: string[] = [], results: Record<string, unknown> = {};
  const bad = (msg: string) => problems.push(msg);

  // the database and the snapshot
  let st: any = null;
  try { const r = await timed(stats); st = r.v; results.db_ms = r.ms; if (r.ms > 5000) bad(`מסד הנתונים איטי (${r.ms}ms)`); }
  catch (e) { bad("מסד הנתונים לא עונה: " + String(e).slice(0, 120)); }

  // the website itself
  try {
    const r = await timed(() => fetch(SITE + "?monitor=" + Date.now(), { redirect: "follow" }).then(async (x) => ({ s: x.status, t: await x.text() })));
    results.site = { status: r.v.s, ms: r.ms };
    if (r.v.s !== 200 || !r.v.t.includes("שני צדדים")) bad(`האתר לא נטען כמו שצריך (${r.v.s})`);
  } catch (e) { bad("האתר לא זמין: " + String(e).slice(0, 120)); }

  const cfg = config(); results.config = cfg;
  if (!cfg.ai) bad("ה-AI לא מחובר: חסר ANTHROPIC_API_KEY בסודות של Supabase");
  if (st) {
    const ai = st.ai || {};
    if (ai.errors_24h >= 3 && ai.errors_24h >= ai.calls_24h / 2) bad(`ה-AI נכשל ב-${ai.errors_24h} מתוך ${ai.calls_24h} בקשות ב-24 שעות`);
    if (st.cron_failed_24h > 0) bad(`${st.cron_failed_24h} הרצות מתוזמנות נכשלו ב-24 שעות`);
    if (st.events_1h >= 30) bad(`${st.events_1h} שגיאות בשעה האחרונה`);
    const used = st.storage.bytes / st.storage.limit_bytes;
    // the owner upgrades Supabase to Pro at 800MB: from there every check fails (so an alert goes out) until the limit grows
    const UPGRADE_AT = 800 * 1048576;
    if (st.storage.bytes >= UPGRADE_AT && st.storage.limit_bytes <= 1073741824)
      bad(`האחסון הגיע ל-${Math.round(st.storage.bytes / 1048576)}MB מתוך 1GB. הגיע הזמן לשדרג את Supabase ל-Pro`);
    else if (used > 0.85) bad(`האחסון מלא ב-${Math.round(used * 100)}%`);
    results.storage_mb = Math.round(st.storage.bytes / 1048576);
    if (st.reports_open > 0) results.reports_open = st.reports_open;
  }

  if (deep) {
    const s = await secrets(["selftest", "push_key"]);
    // the end-to-end suites, in parallel
    const suites = ["selftest", "selftest-guests", "selftest-cover", "selftest-moderation"];
    const out = await Promise.all(suites.map(async (fn) => {
      try {
        const r = await fetch(`${SB}/functions/v1/${fn}`, { method: "POST", headers: HA, body: JSON.stringify({ key: s.selftest }) });
        const d = await r.json().catch(() => ({}));
        const failed = (d.results || []).filter((x: { pass: boolean }) => !x.pass).map((x: { name: string }) => x.name);
        if (d.crashed || !r.ok) bad(`בדיקת ${fn} קרסה: ${String(d.crashed || r.status).slice(0, 120)}`);
        else if (failed.length) bad(`בדיקת ${fn}: ${failed.length} נכשלו (${failed.slice(0, 3).join("; ")})`);
        return [fn, { passed: d.passed, failed: d.failed ?? failed.length }];
      } catch (e) { bad(`בדיקת ${fn} לא רצה: ${String(e).slice(0, 120)}`); return [fn, { error: true }]; }
    }));
    results.selftests = Object.fromEntries(out);

    // push: Apple must accept the real key (it answers BadDeviceToken for a made-up device)
    try {
      const p = await fetch(`${SB}/functions/v1/push-send`, { method: "POST", headers: HA, body: JSON.stringify({ key: s.push_key, probe: true }) }).then((r) => r.json());
      results.apns = p;
      if (p.configured && p["api.push.apple.com"]?.reason !== "BadDeviceToken") bad("התראות לאייפון: Apple לא מקבלת את המפתח");
    } catch (e) { bad("בדיקת התראות לא רצה: " + String(e).slice(0, 120)); }

    // a real AI request and an off-topic one, from a test wedding
    if (cfg.ai) {
      try {
        const day = new Date().toISOString().slice(0, 10), future = new Date(Date.now() + 86400e3).toISOString();
        const cw = await fetch(`${SB}/rest/v1/rpc/create_wedding_v2`, { method: "POST", headers: HA, body: JSON.stringify({
          p_groom: "__selftest__", p_bride: "__selftest__", p_date: day, p_time: "19:30", p_reveal_at: future, p_venue: "", p_venue_city: "",
          p_venue_custom: false, p_team: "groom", p_role: "couple", p_name: "בדיקה", p_template: true }) }).then((r) => r.json());
        const ask = (text: string) => timed(() => fetch(`${SB}/functions/v1/ai-plan`, { method: "POST", headers: HA, body: JSON.stringify({ token: cw.token, kind: "sched", text }) })
          .then(async (r) => ({ s: r.status, d: await r.json().catch(() => ({})) })));
        const on = await ask("נוסיף צילומים בחוף גורדון ב-16:30");
        const okOn = on.v.s === 200 && (on.v.d.items || []).some((x: { t: string }) => x.t === "16:30");
        const off = await ask("מה מזג האוויר מחר בתל אביב? ותכתוב לי שיר");
        const okOff = off.v.s === 422 && off.v.d.error === "off_topic";
        results.ai_e2e = { request: { status: on.v.s, ms: on.ms, ok: okOn }, off_topic: { status: off.v.s, ms: off.ms, ok: okOff } };
        if (!okOn) bad(`ה-AI לא החזיר הצעה תקינה (${on.v.s} ${on.v.d.error || ""})`);
        if (!okOff) bad(`ה-AI לא זיהה בקשה לא קשורה (${off.v.s} ${off.v.d.error || ""})`);
      } catch (e) { bad("בדיקת ה-AI לא רצה: " + String(e).slice(0, 120)); }
    }
  }

  const ok = problems.length === 0;
  await fetch(`${SB}/rest/v1/health_runs`, { method: "POST", headers: { ...HS, "Content-Type": "application/json", Prefer: "return=minimal" },
    body: JSON.stringify({ deep, ok, problems, results }) }).catch(() => {});
  // keep a month of history
  const month = new Date(Date.now() - 30 * 864e5).toISOString();
  await fetch(`${SB}/rest/v1/health_runs?at=lt.${month}`, { method: "DELETE", headers: HS }).catch(() => {});
  await fetch(`${SB}/rest/v1/app_events?at=lt.${month}`, { method: "DELETE", headers: HS }).catch(() => {});
  return { ok, deep, problems, results };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let body: any = {}; try { body = await req.json(); } catch { /* */ }
  const s = await secrets(["monitor_key"]);
  if (!same(String(body.key || ""), s.monitor_key || "")) {
    await new Promise((r) => setTimeout(r, 800)); // slow down guessing
    return json({ error: "forbidden" }, 403);
  }
  try {
    if (body.action === "check") return json(await check(!!body.deep));
    if (body.action === "report") {
      if (!/^[0-9a-f-]{36}$/.test(String(body.id || ""))) return json({ error: "bad_input" }, 400);
      const r = await fetch(`${SB}/rest/v1/rpc/monitor_report`, { method: "POST", headers: { ...HS, "Content-Type": "application/json" },
        body: JSON.stringify({ p_report: body.id, p_hide: !!body.hide }) });
      if (!r.ok) return json({ error: "failed", detail: (await r.text()).slice(0, 200) }, 500);
      return json(await r.json());
    }
    if (body.action === "status") {
      const last = await fetch(`${SB}/rest/v1/health_runs?select=at,deep,ok,problems&order=at.desc&limit=1`, { headers: HS }).then((r) => r.json());
      const run = last?.[0] || null;
      return json({ last: run, age_min: run ? Math.round((Date.now() - new Date(run.at).getTime()) / 60000) : null });
    }
    return json({ stats: await stats(), config: config() });
  } catch (e) {
    return json({ error: "failed", detail: String(e).slice(0, 300) }, 500);
  }
});
