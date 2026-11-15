// Self test for reporting, blocking and account deletion (App Store guidelines 1.2 and 5.1.1(v)).
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
const up = async (path: string, body: Uint8Array) => { const r = await fetch(`${SB}/storage/v1/object/photos/${path}`, { method: "POST", headers: { ...H, "Content-Type": "image/jpeg" }, body }); await r.text(); return r.status; };
const pubStatus = async (path: string) => { const r = await fetch(`${SB}/storage/v1/object/public/photos/${path}?t=${Date.now()}`); await r.text(); return r.status; };
Deno.serve(async (req) => {
  let body: any = {}; try { body = await req.json(); } catch { /* */ }
  const sec = await fetch(`${SB}/rest/v1/app_secrets?name=in.(selftest,purge_key)&select=name,value`, { headers: HS }).then((r) => r.json());
  const key = (n: string) => sec.find((x: any) => x.name === n)?.value;
  if (!body.key || body.key !== key("selftest")) return json({ error: "forbidden" }, 403);
  const R: { name: string; pass: boolean; detail?: string }[] = [];
  const check = (name: string, pass: unknown, detail = "") => R.push({ name, pass: !!pass, detail: pass ? undefined : detail });
  const day = new Date().toISOString().slice(0, 10), future = new Date(Date.now() + 86400e3).toISOString();
  try {
    const cw = await rpc("create_wedding_v2", { p_groom: "__selftest__", p_bride: "__selftest__", p_date: day, p_time: "23:59", p_reveal_at: future,
      p_venue: "", p_venue_city: "", p_venue_custom: false, p_team: "groom", p_role: "couple", p_name: "Groom", p_template: false });
    const tG = cw.data.token, s0 = await state(tG), wid = s0.wedding.id, codeG = s0.wedding.my_code;
    const tA = (await rpc("join_wedding", { p_code: codeG, p_name: "A", p_role: "escort" })).data.token;
    const tB = (await rpc("join_wedding", { p_code: codeG, p_name: "B", p_role: "escort" })).data.token;
    const tC = (await rpc("join_wedding", { p_code: codeG, p_name: "C", p_role: "escort" })).data.token;
    const add = async (t: string, tag: string) => {
      const id = crypto.randomUUID(), p = `${wid}/${id}.jpg`, th = `${wid}/${id}_t.jpg`;
      await up(th, bytes(tag + "t")); await up(p, bytes(tag));
      const r = await rpc("add_media", { p_token: t, p_kind: "image", p_path: p, p_thumb: th, p_blur: null, p_w: 10, p_h: 10, p_duration: null, p_caption: tag, p_vis: "team", p_task: null });
      return { id: r.data, path: p, thumb: th };
    };
    const has = async (t: string, id: string) => (await state(t)).photos.some((p: any) => p.id === id);
    const meA = (await state(tA)).me.id, meC = (await state(tC)).me.id;
    const P1 = await add(tC, "P1"), P2 = await add(tC, "P2"), P3 = await add(tC, "P3"), PA = await add(tA, "PA");
    check("you cannot report your own photo", (await rpc("report_content", { p_token: tC, p_kind: "photo", p_id: P1.id, p_reason: "x" })).status >= 400);
    check("an escort can report a photo", (await rpc("report_content", { p_token: tA, p_kind: "photo", p_id: P1.id, p_reason: "offensive" })).ok);
    check("the reporter stops seeing it at once", !(await has(tA, P1.id)));
    check("one report alone does not hide it from others", await has(tB, P1.id));
    await rpc("report_content", { p_token: tB, p_kind: "photo", p_id: P1.id, p_reason: "offensive" });
    check("two people reporting hide it from everyone", !(await has(tG, P1.id)) && !(await has(tC, P1.id)));
    await rpc("report_content", { p_token: tG, p_kind: "photo", p_id: P2.id, p_reason: "moderator" });
    check("the couple or organiser takes a photo down with one report", !(await has(tA, P2.id)) && !(await has(tB, P2.id)));
    await rpc("send_teaser", { p_token: tC, p_body: "teaser-from-C", p_photos: [] });
    check("blocking works", (await rpc("block_member", { p_token: tA, p_member: meC, p_on: true })).ok);
    const sa = await state(tA);
    check("a blocked person's photos disappear for the blocker", !sa.photos.some((p: any) => p.member_id === meC));
    check("a blocked person's teasers disappear for the blocker", !sa.teasers.some((t: any) => t.member_id === meC));
    check("the blocker sees who they blocked", sa.blocked.some((b: any) => b.id === meC));
    check("others still see that person", await has(tB, P3.id));
    await rpc("block_member", { p_token: tA, p_member: meC, p_on: false });
    check("unblocking brings them back", await has(tA, P3.id));
    check("you cannot block yourself", (await rpc("block_member", { p_token: tA, p_member: meA, p_on: true })).status >= 400);
    const del = await rpc("delete_account", { p_token: tC, p_content: true });
    check("an account can be deleted", del.ok && del.data.files === 3, JSON.stringify(del.data));
    check("the deleted account can no longer sign in", (await rpc("get_state", { p_token: tC })).status >= 400);
    const sg = await state(tG);
    check("the person is gone from the member list", !sg.members.some((m: any) => m.id === meC));
    check("their photos and teasers are gone for everyone", !sg.photos.some((p: any) => p.member_id === meC) && !sg.teasers.some((t: any) => t.member_id === meC));
    check("the old token can no longer post", (await rpc("send_teaser", { p_token: tC, p_body: "x", p_photos: [] })).status >= 400);
    await fetch(`${SB}/rest/v1/photos?wedding_id=eq.${wid}&purge_at=not.is.null`, { method: "PATCH", headers: { ...HS, "Content-Type": "application/json", Prefer: "return=minimal" }, body: JSON.stringify({ purge_at: new Date(Date.now() - 1000).toISOString() }) });
    const pr = await fetch(`${SB}/functions/v1/purge`, { method: "POST", headers: { ...H, "Content-Type": "application/json" }, body: JSON.stringify({ key: key("purge_key") }) }).then((r) => r.json());
    check("the purge job removes their files", pr.purged >= 3 && (await pubStatus(P3.path)) >= 400 && (await pubStatus(P3.thumb)) >= 400, JSON.stringify(pr) + " " + (await pubStatus(P3.path)));
    check("the purge job keeps everyone else's files", (await pubStatus(PA.path)) === 200 && await has(tG, PA.id));
    return json({ passed: R.filter((x) => x.pass).length, failed: R.filter((x) => !x.pass).length, wedding: wid, results: R });
  } catch (e) { return json({ crashed: String(e), results: R }, 500); }
});
