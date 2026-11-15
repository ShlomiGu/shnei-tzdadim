// push-send: delivers a notification to every device of the given members.
// Website / home-screen app: web push (VAPID). iPhone app: Apple Push Notification service (APNs).
// Called only from the database (_notify) with the secret push_key.
import webpush from "npm:web-push@3.6.7";

const SB = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const HS = { apikey: SR, Authorization: `Bearer ${SR}` };
const TOPIC = "com.shneitzdadim.app";
const COLLAPSE = new Set(["photos", "soon", "status-groom", "status-bride", "reveal", "after"]);
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { "Content-Type": "application/json" } });
let secrets: Record<string, string> | null = null;

async function loadSecrets() {
  if (secrets) return secrets;
  const rows = await fetch(`${SB}/rest/v1/app_secrets?select=name,value&name=in.(push_key,vapid_public,vapid_private,vapid_subject,apns_team,apns_key_id)`, { headers: HS }).then((r) => r.json());
  secrets = Object.fromEntries(rows.map((r: { name: string; value: string }) => [r.name, r.value]));
  webpush.setVapidDetails(secrets!.vapid_subject, secrets!.vapid_public, secrets!.vapid_private);
  return secrets!;
}

const b64u = (b: ArrayBuffer | Uint8Array) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const enc = (o: unknown) => b64u(new TextEncoder().encode(JSON.stringify(o)));

async function signJwt(key: CryptoKey, kid: string, team: string) {
  const head = enc({ alg: "ES256", kid }), claims = enc({ iss: team, iat: Math.floor(Date.now() / 1000) });
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${head}.${claims}`));
  return `${head}.${claims}.${b64u(sig)}`;
}

let apnsJwt = { v: "", t: 0 };
async function apnsToken(s: Record<string, string>) {
  const kid = (Deno.env.get("APNS_KEY_ID") || s.apns_key_id || "").trim();
  const team = (Deno.env.get("APNS_TEAM_ID") || s.apns_team || "").trim();
  const p8 = Deno.env.get("APNS_KEY_P8") || "";
  if (!kid || !team || !p8) return null;
  if (apnsJwt.v && Date.now() - apnsJwt.t < 40 * 60 * 1000) return apnsJwt.v;
  const raw = p8.replace(/\\n/g, "\n").replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(raw), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  apnsJwt = { v: await signJwt(key, kid, team), t: Date.now() };
  return apnsJwt.v;
}

async function apnsPost(host: string, device: string, jwt: string, body: string, collapse: string) {
  const r = await fetch(`https://${host}/3/device/${device}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`, "apns-topic": TOPIC, "apns-push-type": "alert", "apns-priority": "10",
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 3600), "content-type": "application/json",
      ...(collapse ? { "apns-collapse-id": collapse } : {}),
    },
    body,
  });
  let reason = "";
  if (r.status !== 200) { try { reason = (await r.json()).reason || ""; } catch { /* empty */ } } else { await r.body?.cancel(); }
  return { status: r.status, reason };
}

Deno.serve(async (req) => {
  let body: any; try { body = await req.json(); } catch { return json({ error: "bad_input" }, 400); }
  const s = await loadSecrets();
  if (!body?.key || body.key !== s.push_key) return json({ error: "forbidden" }, 403);

  // connectivity check: a throwaway key must be refused by Apple with InvalidProviderToken (proves HTTP/2 to APNs works)
  if (body.probe) {
    const k = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    let jwt = await signJwt(k.privateKey, "ABCDEFGHIJ", "ABCDEFGHIJ");
    const out: Record<string, unknown> = {};
    try { const real = await apnsToken(s); out.configured = !!real; if (real) jwt = real; } catch (e) { out.configured = false; out.key_error = String(e).slice(0, 200); }
    out.kid = !!(Deno.env.get("APNS_KEY_ID") || s.apns_key_id); out.team = !!(Deno.env.get("APNS_TEAM_ID") || s.apns_team); out.p8 = !!Deno.env.get("APNS_KEY_P8");
    // with the real key Apple must answer BadDeviceToken for a made-up device (the key itself is accepted)
    for (const host of ["api.push.apple.com", "api.sandbox.push.apple.com"]) {
      try { out[host] = await apnsPost(host, "0".repeat(64), jwt, JSON.stringify({ aps: { alert: "probe" } }), ""); } catch (e) { out[host] = String(e); }
    }
    return json(out);
  }

  const members: string[] = (Array.isArray(body.members) ? body.members : []).filter((x: unknown) => typeof x === "string" && /^[0-9a-f-]{36}$/.test(x as string)).slice(0, 500);
  if (!members.length) return json({ sent: 0 });
  const or = encodeURIComponent('(p256dh.neq."",endpoint.like.apns:*)');
  const subs = await fetch(`${SB}/rest/v1/push_subs?select=endpoint,p256dh,auth&member_id=in.(${members.join(",")})&or=${or}`, { headers: HS }).then((r) => r.json());
  const title = String(body.title || "שני צדדים").slice(0, 120), text = String(body.body || "").slice(0, 240);
  const url = String(body.url || "").slice(0, 40), tag = String(body.tag || "").slice(0, 30);
  const payload = JSON.stringify({ title, body: text, url, tag });
  const apnsBody = JSON.stringify({ aps: { alert: { title, body: text }, sound: "default", "thread-id": tag.replace(/-.*/, "") || "general" }, url, tag });
  const collapse = COLLAPSE.has(tag) ? tag : "";
  const gone = async (endpoint: string) => fetch(`${SB}/rest/v1/push_subs?endpoint=eq.${encodeURIComponent(endpoint)}`, { method: "DELETE", headers: HS });

  let sent = 0, removed = 0, failed = 0, jwt: string | null = null, jwtErr = "";
  const reasons: Record<string, number> = {};
  if ((subs || []).some((x: { endpoint: string }) => x.endpoint.startsWith("apns:"))) {
    try { jwt = await apnsToken(s); if (!jwt) jwtErr = "apns key not configured"; } catch (e) { jwtErr = `apns key error: ${e}`; }
  }
  await Promise.all((subs || []).map(async (sub: { endpoint: string; p256dh: string; auth: string }) => {
    if (sub.endpoint.startsWith("apns:")) {
      if (!jwt) { failed++; return; }
      const device = sub.endpoint.slice(5);
      try {
        let r = await apnsPost("api.push.apple.com", device, jwt, apnsBody, collapse);
        if (r.status === 400 && r.reason === "BadDeviceToken") r = await apnsPost("api.sandbox.push.apple.com", device, jwt, apnsBody, collapse);
        if (r.status === 200) { sent++; return; }
        reasons[r.reason || String(r.status)] = (reasons[r.reason || String(r.status)] || 0) + 1;
        if (r.status === 410 || r.reason === "BadDeviceToken" || r.reason === "Unregistered" || r.reason === "DeviceTokenNotForTopic") { removed++; await gone(sub.endpoint); }
        else { failed++; if (r.status === 403) apnsJwt = { v: "", t: 0 }; }
      } catch (e) { failed++; console.error("apns failed", String(e).slice(0, 200)); }
      return;
    }
    try {
      await webpush.sendNotification({ endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } }, payload, { TTL: 3600, urgency: "high" });
      sent++;
    } catch (e: any) {
      if (e?.statusCode === 404 || e?.statusCode === 410) { removed++; await gone(sub.endpoint); }
      else { failed++; console.error("push failed", e?.statusCode, String(e?.body || e).slice(0, 200)); }
    }
  }));
  if (jwtErr) console.error(jwtErr);
  if (Object.keys(reasons).length) console.error("apns", JSON.stringify(reasons));
  return json({ sent, gone: removed, failed, ...(jwtErr ? { apns: jwtErr } : {}), ...(Object.keys(reasons).length ? { reasons } : {}) });
});
