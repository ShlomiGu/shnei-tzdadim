// Self test for the couple photo: who may set it, what paths are accepted, and who receives it.
const SB = Deno.env.get("SUPABASE_URL")!;
const A = Deno.env.get("SUPABASE_ANON_KEY")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const H = { apikey: A, Authorization: `Bearer ${A}` };
const HS = { apikey: SR, Authorization: `Bearer ${SR}` };
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b, null, 1), { status: s, headers: { "Content-Type": "application/json" } });
async function rpc(fn: string, args: Record<string, unknown>) {
  const r = await fetch(`${SB}/rest/v1/rpc/${fn}`, { method: "POST", headers: { ...H, "Content-Type": "application/json" }, body: JSON.stringify(args) });
  const t = await r.text(); let d: any = null; try { d = t ? JSON.parse(t) : null; } catch { d = t; }
  return { ok: r.ok, status: r.status, data: d };
}
const state = async (t: string) => (await rpc("get_state", { p_token: t })).data;
const bytes = (s: string) => new TextEncoder().encode(s.padEnd(600, "."));
async function up(path: string, body: Uint8Array, type = "image/jpeg") {
  const r = await fetch(`${SB}/storage/v1/object/photos/${path}`, { method: "POST", headers: { ...H, "Content-Type": type, "x-upsert": "false" }, body });
  await r.text(); return r.status;
}
Deno.serve(async (req) => {
  let body: any = {}; try { body = await req.json(); } catch { /* */ }
  const sec = await fetch(`${SB}/rest/v1/app_secrets?name=eq.selftest&select=value`, { headers: HS }).then((r) => r.json());
  if (!body.key || !sec?.[0] || body.key !== sec[0].value) return json({ error: "forbidden" }, 403);
  const R: { name: string; pass: boolean; detail?: string }[] = [];
  const check = (name: string, pass: unknown, detail = "") => R.push({ name, pass: !!pass, detail: pass ? undefined : detail });
  const day = new Date().toISOString().slice(0, 10), future = new Date(Date.now() + 86400e3).toISOString();
  try {
    const cw = await rpc("create_wedding_v2", { p_groom: "__selftest__", p_bride: "__selftest__", p_date: day, p_time: "23:59", p_reveal_at: future,
      p_venue: "", p_venue_city: "", p_venue_custom: false, p_team: "groom", p_role: "escort", p_name: "Opener", p_template: false });
    const tO = cw.data.token; const s0 = await state(tO); const wid = s0.wedding.id, codeG = s0.wedding.my_code, codeB = s0.wedding.other_code;
    const tB = (await rpc("join_wedding", { p_code: codeB, p_name: "Bride", p_role: "couple" })).data?.token;
    const tB2 = (await rpc("join_wedding", { p_code: codeB, p_name: "B-escort", p_role: "escort" })).data?.token;
    const tG2 = (await rpc("join_wedding", { p_code: codeG, p_name: "G-escort", p_role: "escort" })).data?.token;
    const gcode = (await state(tO)).wedding.guest_code;
    const tGu = gcode ? (await rpc("join_wedding", { p_code: gcode, p_name: "Guest", p_role: "guest" })).data?.token : null;
    check("the escort who opened the wedding may set the couple photo", s0.me.can_cover === true);
    check("the bride may, other escorts may not", (await state(tB)).me.can_cover === true && (await state(tB2)).me.can_cover === false && (await state(tG2)).me.can_cover === false);
    const id = crypto.randomUUID(), cv = `${wid}/cover-${id}.webp`, cvt = `${wid}/cover-${id}-t.webp`, cvs = `${wid}/cover-${id}-share.jpg`;
    check("cover files upload", (await up(cv, bytes("CV"), "image/webp")) === 200 && (await up(cvt, bytes("CVT"), "image/webp")) === 200 && (await up(cvs, bytes("CVS"))) === 200);
    check("an escort who did not open it is refused", (await rpc("set_cover", { p_token: tB2, p_path: cv, p_thumb: cvt, p_share: cvs })).status >= 400);
    if (tGu) check("a guest is refused", (await rpc("set_cover", { p_token: tGu, p_path: cv, p_thumb: cvt, p_share: cvs })).status >= 400);
    check("a path from another wedding is refused", (await rpc("set_cover", { p_token: tB, p_path: `${crypto.randomUUID()}/x.webp`, p_thumb: null, p_share: null })).status >= 400);
    check("a path with odd characters is refused", (await rpc("set_cover", { p_token: tB, p_path: `${wid}/../x.webp`, p_thumb: null, p_share: null })).status >= 400);
    const pid = crypto.randomUUID(), pp = `${wid}/${pid}.jpg`; await up(pp, bytes("SECRET"));
    await rpc("add_media", { p_token: tG2, p_kind: "image", p_path: pp, p_thumb: pp, p_blur: null, p_w: 10, p_h: 10, p_duration: null, p_caption: null, p_vis: "secret", p_task: null });
    check("a secret photo cannot become the couple photo", (await rpc("set_cover", { p_token: tO, p_path: pp, p_thumb: null, p_share: null })).status >= 400);
    check("the bride sets it", (await rpc("set_cover", { p_token: tB, p_path: cv, p_thumb: cvt, p_share: cvs })).ok);
    const sg = await state(tG2), pk = (await rpc("peek_code", { p_code: codeG })).data;
    check("the other side receives it at once", sg.wedding.cover === cv && sg.wedding.cover_thumb === cvt);
    check("the join screen gets the round photo and the preview card", pk && pk.cover === cvt && pk.share === cvs, JSON.stringify(pk));
    if (tGu) check("guests see it too", (await state(tGu)).wedding.cover_thumb === cvt);
    check("it can be removed", (await rpc("set_cover", { p_token: tO, p_path: null, p_thumb: null, p_share: null })).ok && (await state(tB)).wedding.cover == null);
    return json({ passed: R.filter((x) => x.pass).length, failed: R.filter((x) => !x.pass).length, wedding: wid, results: R });
  } catch (e) { return json({ crashed: String(e), results: R }, 500); }
});
