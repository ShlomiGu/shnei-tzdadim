// Self-check for verify.js with a locally generated fake Apple-style chain (no network, no Deno).
// Run:  npm install @peculiar/x509@1.12.3 (in any dir)  then
//       NODE_PATH=<that dir>/node_modules node supabase/functions/pay-apple/test.mjs
import { createRequire } from "node:module";
import { createVerifier, OID_LEAF, OID_INTERMEDIATE } from "./verify.js";

const x509 = createRequire(import.meta.url)("@peculiar/x509"); // CommonJS require honours NODE_PATH
const wc = globalThis.crypto;
x509.cryptoProvider.set(wc);

const P256 = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" };
const SIGN = { name: "ECDSA", hash: "SHA-256" };
const DAY = 86400000;
const now = new Date();
const marker = (oid) => new x509.Extension(oid, false, new Uint8Array([5, 0])); // DER NULL, as Apple uses

const b64u = (bytes) => Buffer.from(bytes).toString("base64url");
const b64 = (buf) => Buffer.from(buf).toString("base64");
const hex = (buf) => Buffer.from(buf).toString("hex");
const gen = () => wc.subtle.generateKey(P256, true, ["sign", "verify"]);

async function chain({ leafOid = true, interOid = true, leafNotAfter } = {}) {
  const rootKeys = await gen(), interKeys = await gen(), leafKeys = await gen();
  const root = await x509.X509CertificateGenerator.createSelfSigned({
    serialNumber: "01", name: "CN=Fake Root", notBefore: new Date(+now - DAY), notAfter: new Date(+now + 3650 * DAY),
    signingAlgorithm: SIGN, keys: rootKeys, extensions: [new x509.BasicConstraintsExtension(true, undefined, true)],
  });
  const inter = await x509.X509CertificateGenerator.create({
    serialNumber: "02", subject: "CN=Fake WWDR", issuer: root.subject,
    notBefore: new Date(+now - DAY), notAfter: new Date(+now + 365 * DAY),
    signingAlgorithm: SIGN, publicKey: interKeys.publicKey, signingKey: rootKeys.privateKey,
    extensions: [new x509.BasicConstraintsExtension(true, 0, true), ...(interOid ? [marker(OID_INTERMEDIATE)] : [])],
  });
  const leaf = await x509.X509CertificateGenerator.create({
    serialNumber: "03", subject: "CN=Fake StoreKit Signing", issuer: inter.subject,
    notBefore: new Date(+now - DAY), notAfter: leafNotAfter || new Date(+now + 365 * DAY),
    signingAlgorithm: SIGN, publicKey: leafKeys.publicKey, signingKey: interKeys.privateKey,
    extensions: leafOid ? [marker(OID_LEAF)] : [],
  });
  return { certs: [leaf, inter, root], leafKey: leafKeys.privateKey, rootFp: hex(await wc.subtle.digest("SHA-256", root.rawData)) };
}

async function sign(c, payload, certs = c.certs) {
  const h = b64u(new TextEncoder().encode(JSON.stringify({ alg: "ES256", x5c: certs.map((x) => b64(x.rawData)) })));
  const p = b64u(new TextEncoder().encode(JSON.stringify(payload)));
  const sig = await wc.subtle.sign(SIGN, c.leafKey, new TextEncoder().encode(h + "." + p));
  return `${h}.${p}.${b64u(new Uint8Array(sig))}`;
}

const payload = {
  transactionId: "2000000123456789", bundleId: "com.shneitzdadim.app", productId: "com.shneitzdadim.app.keep",
  type: "Consumable", environment: "Sandbox", appAccountToken: "6f1c1a52-1111-4222-8333-944455556666",
};

let fails = 0;
async function expect(name, shouldPass, fn) {
  let err = null;
  try { await fn(); } catch (e) { err = e; }
  const ok = shouldPass ? !err : !!err;
  if (!ok) fails++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${err ? `  (${err.message})` : ""}`);
}

const good = await chain();
const verify = createVerifier(x509, { rootFingerprint: good.rootFp });
const jws = await sign(good, payload);

await expect("valid JWS verifies and returns payload", true, async () => {
  const p = await verify(jws);
  if (p.productId !== payload.productId || p.transactionId !== payload.transactionId) throw new Error("payload mismatch");
});
await expect("tampered payload rejected", false, () => {
  const [h, , s] = jws.split(".");
  const p = b64u(new TextEncoder().encode(JSON.stringify({ ...payload, productId: "com.shneitzdadim.app.storage5" })));
  return verify(`${h}.${p}.${s}`);
});
await expect("tampered signature rejected", false, () => {
  const [h, p, s] = jws.split(".");
  const b = Buffer.from(s, "base64url"); b[10] ^= 1;
  return verify(`${h}.${p}.${b64u(b)}`);
});
await expect("wrong root (fake chain vs pinned Apple Root G3) rejected", false, () => createVerifier(x509)(jws));
await expect("other root swapped in rejected", false, async () => {
  const other = await chain();
  return verify(await sign(good, payload, [good.certs[0], good.certs[1], other.certs[2]]));
});
await expect("intermediate not signed by root rejected", false, async () => {
  const other = await chain();
  const v = createVerifier(x509, { rootFingerprint: good.rootFp });
  return v(await sign(other, payload, [other.certs[0], other.certs[1], good.certs[2]]));
});
await expect("leaf missing Apple OID rejected", false, async () => {
  const c = await chain({ leafOid: false });
  return createVerifier(x509, { rootFingerprint: c.rootFp })(await sign(c, payload));
});
await expect("intermediate missing Apple OID rejected", false, async () => {
  const c = await chain({ interOid: false });
  return createVerifier(x509, { rootFingerprint: c.rootFp })(await sign(c, payload));
});
await expect("expired leaf rejected", false, async () => {
  const c = await chain({ leafNotAfter: new Date(+now - 1000) });
  return createVerifier(x509, { rootFingerprint: c.rootFp })(await sign(c, payload));
});
await expect("alg other than ES256 rejected", false, () => {
  const [, p, s] = jws.split(".");
  const h = b64u(new TextEncoder().encode(JSON.stringify({ alg: "none", x5c: good.certs.map((x) => b64(x.rawData)) })));
  return verify(`${h}.${p}.${s}`);
});

console.log(fails ? `\n${fails} FAILED` : "\nall passed");
process.exit(fails ? 1 : 0);
