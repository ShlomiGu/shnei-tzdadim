// pay-apple: delivers an Apple In-App Purchase (StoreKit 2 consumable) to a wedding.
// The app sends the signed transaction (JWS) it got from StoreKit; we verify Apple's signature chain,
// check the payload, then record it with apply_purchase (idempotent per provider + transaction id).
// The app finishes the StoreKit transaction only after this returns 200.
import * as x509 from "npm:@peculiar/x509@1.12.3";
import { createVerifier } from "./verify.js";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const SB = Deno.env.get("SUPABASE_URL")!;
const SR = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUNDLE_ID = "com.shneitzdadim.app";
const PRODUCTS: Record<string, string> = {
  "com.shneitzdadim.app.keep": "keep",
  "com.shneitzdadim.app.storage5": "storage5",
};

const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const verifyAppleJws = createVerifier(x509);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method" }, 405);
  let body: { token?: string; jws?: string };
  try { body = await req.json(); } catch { return json({ error: "bad_input" }, 400); }
  const { token, jws } = body || {};
  if (typeof token !== "string" || !/^[0-9a-f-]{36}$/i.test(token) ||
      typeof jws !== "string" || jws.length < 100 || jws.length > 20000) return json({ error: "bad_input" }, 400);

  // deno-lint-ignore no-explicit-any
  let p: Record<string, any>;
  try {
    // like Apple's own library, check the certificates as of when Apple signed the purchase, so a purchase the
    // app retries later (after a crash) is still accepted; the signature itself still has to verify against Apple's root
    let at = new Date();
    try {
      const claimed = Number(JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(jws.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0)))).signedDate);
      if (claimed > 0 && claimed <= Date.now() + 60_000) at = new Date(claimed);
    } catch { /* keep now */ }
    p = await verifyAppleJws(jws, at);
  } catch (e) {
    console.error("pay-apple invalid_signature", String((e as Error)?.message || e));
    return json({ error: "invalid_signature" }, 400);
  }

  const product = PRODUCTS[p.productId];
  if (p.bundleId !== BUNDLE_ID || !product || p.revocationDate || p.type !== "Consumable" || !p.transactionId) {
    console.error("pay-apple bad payload", JSON.stringify({
      bundleId: p.bundleId, productId: p.productId, type: p.type, revoked: !!p.revocationDate, txn: p.transactionId,
    }));
    return json({ error: "invalid_purchase" }, 400);
  }

  const r = await fetch(`${SB}/rest/v1/rpc/apply_purchase`, {
    method: "POST",
    headers: { apikey: SR, Authorization: `Bearer ${SR}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      p_token: token,
      p_provider: "apple",
      // every consumable purchase is its own transaction
      p_txn: String(p.transactionId),
      p_product: product,
      p_raw: {
        environment: p.environment,
        transactionId: p.transactionId,
        purchaseDate: p.purchaseDate,
        appAccountToken: p.appAccountToken,
        price: p.price,
        currency: p.currency,
        storefront: p.storefront,
      },
    }),
  });
  const text = await r.text();
  if (!r.ok) {
    if (text.includes("bad_token")) return json({ error: "bad_token" }, 401);
    console.error("pay-apple apply_purchase", r.status, text.slice(0, 500));
    return json({ error: "apply_failed" }, 500);
  }
  let out: unknown = null;
  try { out = JSON.parse(text); } catch { /* empty body */ }
  return json(out ?? { ok: true });
});
