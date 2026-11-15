// End-to-end checks for guests and side status, as real browsers (anon key only).
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
  const ids = (s: any) => (s?.photos || []).map((p: any) => p.id);
  const day = new Date().toISOString().slice(0, 10), future = new Date(Date.now() + 86400e3).toISOString();
  try {
    const tG = (await rpc("create_wedding_v2", { p_groom: "__selftest__", p_bride: "__selftest__", p_date: day, p_time: "23:59", p_reveal_at: future,
      p_venue: "", p_venue_city: "", p_venue_custom: false, p_team: "groom", p_role: "couple", p_name: "G1", p_template: true })).data.token;
    let sG = await state(tG);
    const wid = sG.wedding.id, codeB = sG.wedding.other_code, codeQ = sG.wedding.guest_code;
    check("a new wedding gets a guest code", typeof codeQ === "string" && codeQ.length === 6 && codeQ !== sG.wedding.my_code && codeQ !== codeB);
    const tB = (await rpc("join_wedding", { p_code: codeB, p_name: "B1", p_role: "couple" })).data.token;
    check("the bride side also sees the guest code", (await state(tB)).wedding.guest_code === codeQ);
    const pk = (await rpc("peek_code", { p_code: codeQ })).data;
    check("the guest code is recognised as guests", pk?.team === "guest");
    const jq = (await rpc("join_wedding", { p_code: codeQ, p_name: "Q1", p_role: "couple" })).data;
    const tQ = jq?.token;
    let sQ = await state(tQ);
    check("joining with the guest code makes you a guest even if you ask for couple", sQ.me.team === "guest" && sQ.me.role === "guest", JSON.stringify(sQ?.me));
    check("guests do not receive the groom or bride codes", sQ.wedding.my_code === codeQ && !sQ.wedding.other_code && !sQ.wedding.guest_code && !JSON.stringify(sQ).includes(codeB) && !JSON.stringify(sQ).includes(sG.wedding.my_code));

    const add = async (token: string, vis: string, tag: string) => {
      const id = crypto.randomUUID(), p = `${wid}/${id}.jpg`, t = `${wid}/${id}_t.jpg`;
      await up(t, bytes(tag)); await up(p, bytes(tag));
      const r = await rpc("add_media", { p_token: token, p_kind: "image", p_path: p, p_thumb: t, p_blur: null, p_w: 1, p_h: 1, p_duration: null, p_caption: tag, p_vis: vis, p_task: null });
      return { id: r.data, path: p, ok: r.ok };
    };
    const G1 = await add(tG, "team", "G1"), GT = await add(tG, "teaser", "GT"), GE = await add(tG, "escorts", "GE"), GS = await add(tG, "secret", "GS");
    const Q1 = await add(tQ, "secret", "Q1"), Q2 = await add(tQ, "escorts", "Q2");
    check("guests can upload", Q1.ok && Q2.ok);
    sQ = await state(tQ); const sQs = JSON.stringify(sQ);
    check("guests do not receive any couple-side photo before the reveal (not even teasers)", ![G1, GT, GE, GS].some((x) => ids(sQ).includes(x.id) || sQs.includes(x.path)));
    check("guests see their own uploads", ids(sQ).includes(Q1.id) && ids(sQ).includes(Q2.id));
    check("guests do not receive teasers, tasks, letters or phone numbers", sQ.teasers.length === 0 && sQ.tasks.length === 0 && sQ.letters.length === 0 && sQ.wedding.contacts.length === 0);
    check("guests only see shared schedule items", sQ.sched.length > 0 && sQ.sched.every((s: any) => s.side === "all"));
    sG = await state(tG);
    check("the couple sides do not receive guest photos before the reveal", !ids(sG).includes(Q1.id) && !ids(await state(tB)).includes(Q2.id) && !JSON.stringify(sG).includes(Q1.path));
    const tE = (await rpc("join_wedding", { p_code: codeB, p_name: "B2", p_role: "escort" })).data.token;
    check("guest photos marked escorts are not shared early with escorts", !ids(await state(tE)).includes(Q2.id));

    // guests cannot change the plan
    const tries: [string, Record<string, unknown>][] = [
      ["save_sched", { p_token: tQ, p_id: null, p_t: "10:00", p_title: "x", p_place: "", p_note: "", p_side: "all", p_done: false, p_reveal: true, p_reveal_at: new Date().toISOString() }],
      ["delete_sched", { p_token: tQ, p_id: sQ.sched[0].id }],
      ["save_task", { p_token: tQ, p_id: null, p_title: "x", p_side: "all", p_pts: 10, p_mission: false, p_who: null }],
      ["toggle_task", { p_token: tQ, p_id: sG.tasks.find((t: any) => t.side === "all").id }],
      ["set_reveal", { p_token: tQ, p_now: true }],
      ["update_wedding", { p_token: tQ, p: { groom: "hacked" } }],
      ["send_teaser", { p_token: tQ, p_body: "x", p_photos: [] }],
      ["set_photo_vis", { p_token: tQ, p_id: Q1.id, p_vis: "secret" }],
      ["write_letter", { p_token: tQ, p_body: "x", p_open_at: future }],
      ["set_status", { p_token: tQ, p_status: "x" }],
      ["ai_apply_sched", { p_token: tQ, p_items: [], p_reveal_at: null }],
      ["ai_apply_tasks", { p_token: tQ, p_items: [] }],
    ];
    const allowed: string[] = [];
    for (const [fn, args] of tries) if ((await rpc(fn, args)).ok) allowed.push(fn);
    check("guests are refused every planning and editing action", allowed.length === 0, allowed.join(","));
    sG = await state(tG);
    check("nothing a guest tried changed the wedding", sG.wedding.groom === "__selftest__" && !sG.revealed && sG.sched.every((s: any) => s.title !== "x"));
    await rpc("update_me", { p_token: tQ, p_name: "Q1b", p_role: "escort" });
    check("a guest cannot promote themselves to escort", (await state(tQ)).me.role === "guest");
    check("a guest cannot delete a couple-side photo", (await rpc("delete_photo", { p_token: tQ, p_id: G1.id })).status >= 400);
    check("a guest cannot like a hidden couple photo", (await rpc("toggle_heart", { p_token: tQ, p_photo: G1.id })).status >= 400);
    const rowQ = await fetch(`${SB}/rest/v1/photos?id=in.(${Q1.id},${Q2.id})&select=vis,share_escorts,team`, { headers: HS }).then((r) => r.json());
    check("guest uploads are stored as plain guest photos", rowQ.length === 2 && rowQ.every((r: any) => r.vis === "team" && !r.share_escorts && r.team === "guest"), JSON.stringify(rowQ));

    // status
    await rpc("set_status", { p_token: tG, p_status: "יצאנו לדרך" });
    const sb = await state(tB);
    check("the groom side's status reaches the bride side", sb.wedding.status?.groom === "יצאנו לדרך" && sb.wedding.status?.groom_at);
    check("guests see both statuses", (await state(tQ)).wedding.status?.groom === "יצאנו לדרך");

    // after the reveal
    await rpc("set_reveal", { p_token: tG, p_now: true });
    sQ = await state(tQ);
    check("after the reveal guests receive couple-side photos in full", [G1, GT, GE].every((x) => sQ.photos.some((p: any) => p.id === x.id && p.mode === "full" && p.path === x.path)));
    check("secret photos stay hidden from guests", !ids(sQ).includes(GS.id) && !JSON.stringify(sQ).includes(GS.path));
    check("after the reveal the couple sides receive the guest photos", [Q1, Q2].every((x) => ids(sG = sG) && true) && [tG, tB].length === 2 &&
      (await Promise.all([state(tG), state(tB)])).every((s) => [Q1, Q2].every((x) => s.photos.some((p: any) => p.id === x.id && p.mode === "full"))));
    check("guests still get no tasks or teasers after the reveal", sQ.tasks.length === 0 && sQ.teasers.length === 0);
    const mq = (await rpc("backup_manifest", { p_token: tQ })).data;
    check("a guest's backup has guest and shared photos, never secrets", Array.isArray(mq) && mq.length === 5 && !mq.some((x: any) => x.id === GS.id), JSON.stringify(mq?.length));
    return json({ passed: R.filter((x) => x.pass).length, failed: R.filter((x) => !x.pass).length, results: R });
  } catch (e) { return json({ crashed: String(e), results: R }, 500); }
});
