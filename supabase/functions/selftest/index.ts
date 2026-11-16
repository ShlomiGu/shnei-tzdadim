// End-to-end self test. Acts like real browsers: only the public anon key, real HTTP, real storage uploads.
// The service-role key is used only to read the test key and to confirm soft-deleted rows still exist.
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
async function up(path: string, body: Uint8Array, type = "image/jpeg", upsert = false) {
  const r = await fetch(`${SB}/storage/v1/object/photos/${path}`, { method: "POST", headers: { ...H, "Content-Type": type, "x-upsert": String(upsert) }, body });
  await r.text(); return r.status;
}
const pubGet = async (path: string) => { const r = await fetch(`${SB}/storage/v1/object/public/photos/${path}?t=${Date.now()}`); return { status: r.status, text: await r.text() }; };

Deno.serve(async (req) => {
  let body: any = {}; try { body = await req.json(); } catch { /* */ }
  const sec = await fetch(`${SB}/rest/v1/app_secrets?name=eq.selftest&select=value`, { headers: HS }).then((r) => r.json());
  if (!body.key || !sec?.[0] || body.key !== sec[0].value) return json({ error: "forbidden" }, 403);

  const R: { name: string; pass: boolean; detail?: string }[] = [];
  const check = (name: string, pass: unknown, detail = "") => R.push({ name, pass: !!pass, detail: pass ? undefined : detail });
  const ids = (s: any) => (s?.photos || []).map((p: any) => p.id);
  const day = new Date().toISOString().slice(0, 10);
  const future = new Date(Date.now() + 86400e3).toISOString();

  try {
    // ---- setup: a wedding, 2 people per side ----
    const cw = await rpc("create_wedding_v2", { p_groom: "__selftest__", p_bride: "__selftest__", p_date: day, p_time: "23:59", p_reveal_at: future,
      p_venue: "", p_venue_city: "", p_venue_custom: false, p_team: "groom", p_role: "couple", p_name: "G1", p_template: true });
    const tG = cw.data.token;
    let sG = await state(tG);
    const wid = sG.wedding.id, codeG = sG.wedding.my_code, codeB = sG.wedding.other_code, v0 = sG.version;
    check("creator gets two different codes", codeG && codeB && codeG !== codeB, JSON.stringify(sG.wedding));
    check("default schedule and tasks were created", sG.sched.length >= 10 && sG.tasks.length >= 5);
    const tB = (await rpc("join_wedding", { p_code: codeB.toLowerCase().slice(0, 3) + "-" + codeB.slice(3), p_name: "B1", p_role: "couple" })).data?.token;
    const tG2 = (await rpc("join_wedding", { p_code: codeG, p_name: "G2", p_role: "escort" })).data?.token;
    const tB2 = (await rpc("join_wedding", { p_code: codeB, p_name: "B2", p_role: "escort" })).data?.token;
    check("code works with lowercase and a dash", !!tB);
    const sB = await state(tB);
    check("bride code puts you on the bride side", sB.me.team === "bride" && (await state(tG2)).me.team === "groom");
    check("groom side stops seeing the bride code once she joined", (await state(tG)).wedding.other_code == null);
    check("bride side sees only its own code", sB.wedding.my_code === codeB && sB.wedding.other_code == null);
    const wc = await rpc("join_wedding", { p_code: "ZZZZZZ", p_name: "x", p_role: "escort" });
    check("wrong code is refused", (wc.status >= 400 || wc.data?.error === "bad_code") && !wc.data?.token, JSON.stringify(wc));
    check("random token is refused", (await rpc("get_state", { p_token: crypto.randomUUID() })).status >= 400);

    // ---- uploads ----
    const add = async (token: string, vis: string, tag: string, kind = "image") => {
      const id = crypto.randomUUID(), ext = kind === "video" ? "mp4" : "jpg";
      const p = `${wid}/${id}.${ext}`, t = `${wid}/${id}_t.jpg`;
      const s1 = await up(t, bytes(tag + "-thumb")), s2 = await up(p, bytes(tag), kind === "video" ? "video/mp4" : "image/jpeg");
      const r = await rpc("add_media", { p_token: token, p_kind: kind, p_path: p, p_thumb: t, p_blur: null, p_w: 10, p_h: 10, p_duration: kind === "video" ? 3 : null, p_caption: "cap-" + tag, p_vis: vis, p_task: null });
      return { id: r.data, path: p, thumb: t, ok: s1 === 200 && s2 === 200 && r.ok, tag };
    };
    const P1 = await add(tG, "team", "P1"), P2 = await add(tG, "teaser", "P2"), P3 = await add(tG, "secret", "P3"), PV = await add(tG2, "team", "PV", "video");
    const PE = await add(tG2, "escorts", "PE");
    const B1 = await add(tB, "team", "B1");
    check("photos and a video upload and register", [P1, P2, P3, PV, PE, B1].every((x) => x.ok), JSON.stringify([P1, P2, P3, PV, PE, B1].map((x) => x.ok)));

    // ---- what each side receives before the reveal ----
    const vb = await state(tB2), vbs = JSON.stringify(vb);
    check("bride side does not receive the groom's private photo", !ids(vb).includes(P1.id) && !vbs.includes(P1.path));
    check("bride side does not receive the groom's secret photo", !ids(vb).includes(P3.id) && !vbs.includes(P3.path));
    check("bride side does not receive the groom's private video", !ids(vb).includes(PV.id) && !vbs.includes(PV.path));
    const t2 = vb.photos.find((p: any) => p.id === P2.id);
    check("teaser arrives blurred only, with no file address", t2 && t2.mode === "blur" && !t2.path && !t2.thumb_path && !vbs.includes(P2.path) && !vbs.includes(P2.thumb), JSON.stringify(t2));
    check("bride escorts are told how many photos wait (2)", vb.hidden === 2, String(vb.hidden));
    const vg = await state(tG2), vgs = JSON.stringify(vg);
    check("groom teammates see every groom photo with its file", [P1, P2, P3, PV, PE].every((x) => vg.photos.find((p: any) => p.id === x.id && p.path === x.path)));
    check("groom side does not receive the bride's private photo", !ids(vg).includes(B1.id) && !vgs.includes(B1.path));

    // ---- "for the other side's escorts" ----
    const pe = vb.photos.find((p: any) => p.id === PE.id);
    check("bride escorts get the escorts-only photo in full, marked as sent to them", pe && pe.mode === "full" && pe.path === PE.path && pe.early === true, JSON.stringify(pe));
    const vc = await state(tB), vcs = JSON.stringify(vc);
    check("the bride herself does not receive the escorts-only photo", !ids(vc).includes(PE.id) && !vcs.includes(PE.path) && !vcs.includes(PE.thumb));
    check("the bride is told 3 photos wait", vc.hidden === 3, String(vc.hidden));
    check("the groom side sees it labelled escorts", vg.photos.find((p: any) => p.id === PE.id)?.vis === "escorts");
    check("bride escorts can like it, the bride cannot", (await rpc("toggle_heart", { p_token: tB2, p_photo: PE.id })).ok && (await rpc("toggle_heart", { p_token: tB, p_photo: PE.id })).status >= 400);
    await rpc("update_me", { p_token: tB, p_name: "B1", p_role: "escort" });
    const vc2 = await state(tB);
    check("the bride cannot switch herself to escort to peek", vc2.me.role === "couple" && !ids(vc2).includes(PE.id));
    const mb0 = (await rpc("backup_manifest", { p_token: tB })).data;
    check("the bride's backup does not include it before the reveal", Array.isArray(mb0) && !mb0.some((x: any) => x.id === PE.id));

    // ---- tampering through the API ----
    check("other side cannot like a hidden photo", (await rpc("toggle_heart", { p_token: tB, p_photo: P1.id })).status >= 400);
    check("other side cannot change a photo's visibility", (await rpc("set_photo_vis", { p_token: tB2, p_id: PE.id, p_vis: "team" })).status >= 400);
    check("other side cannot delete a photo", (await rpc("delete_photo", { p_token: tB, p_id: P1.id })).status >= 400);
    check("a teammate cannot delete someone else's photo", (await rpc("delete_photo", { p_token: tG2, p_id: P1.id })).status >= 400);
    await rpc("send_teaser", { p_token: tB, p_body: "hijack", p_photos: [P1.id] });
    const hij = (await state(tG)).teasers.find((t: any) => t.body === "hijack");
    check("a teaser cannot attach the other side's photo", hij && hij.photo_ids.length === 0, JSON.stringify(hij));

    // ---- tampering with storage ----
    check("an existing file cannot be overwritten", (await up(P1.path, bytes("EVIL"))) >= 400);
    check("an existing file cannot be replaced with upsert", (await up(P1.path, bytes("EVIL"), "image/jpeg", true)) >= 400);
    await fetch(`${SB}/storage/v1/object/photos/${P1.path}`, { method: "DELETE", headers: H }).then((r) => r.text());
    await fetch(`${SB}/storage/v1/object/photos`, { method: "DELETE", headers: { ...H, "Content-Type": "application/json" }, body: JSON.stringify({ prefixes: [P1.path, P2.path] }) }).then((r) => r.text());
    const g1 = await pubGet(P1.path), g2 = await pubGet(P2.path);
    check("files cannot be deleted or altered from the browser", g1.status === 200 && g1.text.startsWith("P1") && g2.status === 200 && g2.text.startsWith("P2"), g1.status + " " + g1.text.slice(0, 8));
    const lst = await fetch(`${SB}/storage/v1/object/list/photos`, { method: "POST", headers: { ...H, "Content-Type": "application/json" }, body: JSON.stringify({ prefix: wid, limit: 100 }) });
    const lj = await lst.json().catch(() => null);
    check("nobody can list the photo folder", !(Array.isArray(lj) && lj.length), JSON.stringify(lj).slice(0, 120));
    check("uploads into a made-up wedding folder are refused", (await up(`${crypto.randomUUID()}/x.jpg`, bytes("x"))) >= 400);
    check("non-image file types are refused", (await up(`${wid}/${crypto.randomUUID()}.jpg`, bytes("<html>"), "text/html")) >= 400);

    // ---- direct database access ----
    for (const t of ["weddings", "members", "photos", "teasers", "letters", "tasks", "app_secrets", "ai_log", "venues_custom"]) {
      const r = await fetch(`${SB}/rest/v1/${t}?select=*&limit=5`, { headers: H }); const j = await r.json().catch(() => null);
      check(`table "${t}" is not readable from outside`, r.status >= 400 || (Array.isArray(j) && j.length === 0), r.status + " " + JSON.stringify(j).slice(0, 80));
    }
    const w1 = await fetch(`${SB}/rest/v1/photos?id=eq.${P1.id}`, { method: "PATCH", headers: { ...H, "Content-Type": "application/json", Prefer: "return=representation" }, body: JSON.stringify({ vis: "team", team: "bride", share_escorts: true }) });
    const w1j = await w1.json().catch(() => null);
    check("tables cannot be edited from outside", w1.status >= 400 || (Array.isArray(w1j) && w1j.length === 0));
    check("internal functions are locked", (await rpc("ai_context", { p_token: tG, p_kind: "sched" })).status >= 400
      && (await rpc("_member", { p_token: tG })).status >= 400 && (await rpc("_template2", { p_wid: wid, p_time: "10:00", p_venue: "x" })).status >= 400);

    // ---- tasks and letters ----
    const gTask = (await state(tG)).tasks.find((t: any) => t.side === "groom");
    check("bride side does not receive groom-only tasks", !(await state(tB)).tasks.some((t: any) => t.side === "groom"));
    await rpc("toggle_task", { p_token: tB, p_id: gTask.id });
    check("bride side cannot tick a groom task", !(await state(tG)).tasks.find((t: any) => t.id === gTask.id).done);
    await rpc("write_letter", { p_token: tB, p_body: "secret-letter-xyz", p_open_at: future });
    check("escorts cannot read the sealed letter", !JSON.stringify(await state(tG2)).includes("secret-letter-xyz") && !JSON.stringify(await state(tB2)).includes("secret-letter-xyz"));
    check("the groom cannot read it before its time", !JSON.stringify(await state(tG)).includes("secret-letter-xyz"));
    check("the author can read her own letter", JSON.stringify(await state(tB)).includes("secret-letter-xyz"));
    check("escorts cannot write sealed letters", (await rpc("write_letter", { p_token: tG2, p_body: "x", p_open_at: future })).status >= 400);

    // ---- the reveal ----
    await rpc("set_reveal", { p_token: tG, p_now: true });
    const rb = await state(tB2), rbs = JSON.stringify(rb);
    check("after the reveal the bride side gets the groom photos and video", [P1, P2, PV, PE].every((x) => rb.photos.find((p: any) => p.id === x.id && p.mode === "full" && p.path === x.path)));
    const rc = await state(tB);
    check("after the reveal the bride gets the escorts-only photo too", rc.photos.some((p: any) => p.id === PE.id && p.mode === "full" && !p.early));
    check("a secret photo stays hidden after the reveal", !rb.photos.some((p: any) => p.id === P3.id) && !rbs.includes(P3.path) && !JSON.stringify(rc).includes(P3.path));
    check("after the reveal the groom side gets the bride photo", (await state(tG2)).photos.some((p: any) => p.id === B1.id && p.path === B1.path));
    check("other side can like photos after the reveal", (await rpc("toggle_heart", { p_token: tB, p_photo: P1.id })).ok);

    // ---- nothing is lost ----
    await rpc("delete_photo", { p_token: tG, p_id: P1.id });
    check("a deleted photo disappears from the app", !(await state(tG)).photos.some((p: any) => p.id === P1.id) && !(await state(tB)).photos.some((p: any) => p.id === P1.id));
    const row = await fetch(`${SB}/rest/v1/photos?id=eq.${P1.id}&select=id,deleted_at`, { headers: HS }).then((r) => r.json());
    check("the deleted photo is still kept in the database", row.length === 1 && row[0].deleted_at);
    check("the deleted photo's file is still stored", (await pubGet(P1.path)).status === 200);
    check("only the uploader can restore it", (await rpc("restore_photo", { p_token: tG2, p_id: P1.id })).status >= 400);
    await rpc("restore_photo", { p_token: tG, p_id: P1.id });
    check("restoring brings it back for everyone", (await state(tG)).photos.some((p: any) => p.id === P1.id) && (await state(tB)).photos.some((p: any) => p.id === P1.id));
    sG = await state(tG);
    check("every change bumps the version phones poll for", sG.version > v0, `${v0} -> ${sG.version}`);
    check("all 6 uploads are still there", sG.photos.length === 6, String(sG.photos.length));

    // ---- backup ----
    const mg = (await rpc("backup_manifest", { p_token: tG })).data, mb = (await rpc("backup_manifest", { p_token: tB })).data;
    check("groom backup lists all 6 files", Array.isArray(mg) && mg.length === 6, JSON.stringify(mg?.length));
    check("bride backup lists 5 files and never the groom secret", Array.isArray(mb) && mb.length === 5 && !mb.some((x: any) => x.id === P3.id), JSON.stringify(mb?.length));
    const us = (await rpc("storage_usage", { p_token: tG })).data;
    check("storage usage is reported", us && us.wedding_bytes > 0, JSON.stringify(us));

    return json({ passed: R.filter((x) => x.pass).length, failed: R.filter((x) => !x.pass).length, wedding: wid, results: R });
  } catch (e) {
    return json({ crashed: String(e), results: R }, 500);
  }
});
