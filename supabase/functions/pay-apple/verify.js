// Verification of a StoreKit 2 signed transaction (JWS, ES256 with an x5c chain).
// Plain ES module so it runs both in the Supabase edge runtime (Deno) and under Node for test.mjs.
// The @peculiar/x509 module is passed in, so this file has no imports of its own.

/** SHA-256 of the DER of "Apple Root CA - G3" (apple.com/certificateauthority/AppleRootCA-G3.cer). */
export const APPLE_ROOT_G3_SHA256 = "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179";
export const OID_LEAF = "1.2.840.113635.100.6.11.1"; // Mac App Store receipt signing
export const OID_INTERMEDIATE = "1.2.840.113635.100.6.2.1"; // Apple WWDR intermediate

/** @param {string} s */
function b64ToBytes(s) {
  const t = s.replace(/-/g, "+").replace(/_/g, "/").replace(/\s+/g, "");
  const bin = atob(t + "===".slice((t.length + 3) % 4));
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/** @param {ArrayBuffer} buf */
function hex(buf) {
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * @param {any} x509 the @peculiar/x509 module
 * @param {{ rootFingerprint?: string, crypto?: Crypto }} [opts] rootFingerprint is only overridden by tests
 * @returns {(jws: string, now?: Date) => Promise<Record<string, any>>} resolves to the decoded payload, throws on any failure
 */
export function createVerifier(x509, opts = {}) {
  const wc = opts.crypto || globalThis.crypto;
  const rootFp = (opts.rootFingerprint || APPLE_ROOT_G3_SHA256).toLowerCase();
  x509.cryptoProvider.set(wc);

  return async function verifyAppleJws(jws, now = new Date()) {
    if (typeof jws !== "string") throw new Error("jws not a string");
    const parts = jws.split(".");
    if (parts.length !== 3 || parts.some((p) => !p)) throw new Error("jws must have 3 parts");
    const [h64, p64, s64] = parts;

    /** @type {{ alg?: string, x5c?: string[] }} */
    let header;
    try { header = JSON.parse(new TextDecoder().decode(b64ToBytes(h64))); } catch { throw new Error("bad header"); }
    if (header.alg !== "ES256") throw new Error("alg is not ES256");
    if (!Array.isArray(header.x5c) || header.x5c.length !== 3) throw new Error("x5c must have 3 certificates");

    const certs = header.x5c.map((c) => {
      if (typeof c !== "string") throw new Error("bad x5c entry");
      return new x509.X509Certificate(b64ToBytes(c));
    });
    const [leaf, inter, root] = certs;

    // pinned root
    const fp = hex(await wc.subtle.digest("SHA-256", root.rawData));
    if (fp !== rootFp) throw new Error("root is not Apple Root CA - G3");

    // validity dates
    for (const c of certs) {
      if (now < c.notBefore || now > c.notAfter) throw new Error("certificate outside validity: " + c.subject);
    }

    // each certificate signed by the next (root is self-signed)
    const pairs = [[leaf, inter], [inter, root], [root, root]];
    for (const [child, issuer] of pairs) {
      const ok = await child.verify({ publicKey: issuer.publicKey, signatureOnly: true });
      if (!ok) throw new Error("chain signature failed: " + child.subject);
    }

    // Apple marker OIDs
    if (!leaf.getExtension(OID_LEAF)) throw new Error("leaf missing Apple OID");
    if (!inter.getExtension(OID_INTERMEDIATE)) throw new Error("intermediate missing Apple OID");

    // JWS signature (ES256: raw r||s, which is what WebCrypto ECDSA expects)
    const key = await leaf.publicKey.export({ name: "ECDSA", namedCurve: "P-256" }, ["verify"], wc);
    const sig = b64ToBytes(s64);
    if (sig.length !== 64) throw new Error("bad signature length");
    const ok = await wc.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" }, key, sig, new TextEncoder().encode(h64 + "." + p64),
    );
    if (!ok) throw new Error("jws signature failed");

    try { return JSON.parse(new TextDecoder().decode(b64ToBytes(p64))); } catch { throw new Error("bad payload"); }
  };
}
